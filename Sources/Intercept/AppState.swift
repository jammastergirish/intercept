import SwiftUI
import GraphiteEmber
import AppKit
import AVFoundation
import IOKit.pwr_mgt

@MainActor
final class AppState: ObservableObject {

    enum Status: Equatable {
        case idle, starting, recording, saving, failed(String)

        var badge: String {
            switch self {
            case .idle: return "Ready"
            case .starting: return "Starting"
            case .recording: return "Recording"
            case .saving: return "Saving"
            case .failed: return "Error"
            }
        }
    }

    // MARK: Published state

    /// What to record (screen / audio / camera and their options). Saved.
    @Published var settings: CaptureSettings {
        didSet { SettingsStore.save(settings) }
    }
    /// Microphones and cameras currently connected.
    @Published private(set) var microphones: [CaptureDevice] = CaptureDevices.microphones()
    @Published private(set) var cameras: [CaptureDevice] = CaptureDevices.cameras()
    /// Displays showing their own picture (mirrored copies don't count).
    @Published private(set) var distinctDisplayCount = Displays.distinctIDs().count
    @Published var folder: URL {
        didSet {
            UserDefaults.standard.set(folder.path, forKey: "folder")
            refreshRecordings()
        }
    }
    @Published private(set) var status: Status = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var inLevel: Float = 0     // microphone
    @Published private(set) var outLevel: Float = 0    // sound the Mac plays
    /// The display is off: only sound is being recorded until it's back.
    @Published private(set) var screenPaused = false
    /// Every recording in the folder, newest first.
    @Published private(set) var recordings: [RecordingItem] = []
    /// Message about recordings finished after a crash, shown until dismissed.
    @Published var recoveryNote: String?
    @Published private(set) var micGranted = Permissions.authorized(.audio)
    @Published private(set) var screenGranted = Permissions.screenAuthorized()
    @Published private(set) var cameraGranted = Permissions.authorized(.video)

    var isRecording: Bool { status == .recording }
    /// A recording is running. (Kept separate from `isRecording` for the UI.)
    var isActive: Bool { status == .recording }
    var isBusy: Bool { status == .starting || status == .saving }
    /// Settings and Quit are locked while a recording is running or saving.
    var isLocked: Bool { isActive || isBusy }
    /// Each permission matters only if what you've chosen to record needs it.
    /// (System sound has its own permission, which macOS asks for on first use.)
    var needsMic: Bool { settings.recordsMic }
    var needsScreen: Bool { settings.screen }
    var needsCamera: Bool { settings.camera }
    var neededPermissionsGranted: Bool {
        (micGranted || !needsMic) && (screenGranted || !needsScreen) && (cameraGranted || !needsCamera)
    }

    // MARK: Private

    private var session: CaptureSession?
    private var startedAt: Date?
    private var ticker: Timer?
    private var finalURL: URL?
    /// Keeps the Mac from sleeping on its own while recording.
    private var noSleepAssertion: IOPMAssertionID = 0

    init() {
        let defaults = UserDefaults.standard
        settings = SettingsStore.load()
        if let path = defaults.string(forKey: "folder") {
            folder = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Intercept", isDirectory: true)
        }

        // Keep the microphone and camera lists current as devices come and go.
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshDevices() }
            }
        }

        // Finish any recording a crash cut off. Skip in developer test runs,
        // which start a second copy of the app alongside a real one.
        let args = CommandLine.arguments
        if !args.contains("--selftest") && !args.contains("--snapshot") && !args.contains("--apptest") {
            Task { await recoverLeftovers() }
            // A second pass catches files that were too fresh to touch at launch.
            Task {
                try? await Task.sleep(nanoseconds: 75_000_000_000)
                await recoverLeftovers()
            }
        }
    }

    // MARK: Crash recovery

    func recoverLeftovers() async {
        guard !isRecording, !isBusy, !Recovery.leftovers(in: folder).isEmpty else { return }
        let result = await Recovery.run(in: folder)
        let all = result.recovered + result.failed
        guard !all.isEmpty else { return }
        let n = all.count
        var note = "Intercept closed unexpectedly during \(n == 1 ? "a recording" : "\(n) recordings"). "
        note += "Saved everything up to the last 10 seconds as “(recovered)”."
        if !result.failed.isEmpty {
            note += " \(result.failed.count) couldn't be mixed and was kept as a .mov with separate mic and system tracks."
        }
        recoveryNote = note
        refreshRecordings()
    }

    // MARK: Permissions

    func refreshDisplays() {
        distinctDisplayCount = Displays.distinctIDs().count
    }

    func refreshDevices() {
        microphones = CaptureDevices.microphones()
        cameras = CaptureDevices.cameras()
    }

    func refreshPermissions() {
        micGranted = Permissions.authorized(.audio)
        screenGranted = Permissions.screenAuthorized()
        cameraGranted = Permissions.authorized(.video)
    }

    func grantCamera() { grant(.video) }
    func grantMicrophone() { grant(.audio) }

    private func grant(_ media: AVMediaType) {
        Task {
            await Permissions.request(media)
            refreshPermissions()
        }
    }

    func grantScreen() {
        if !Permissions.requestScreen() {
            Permissions.openScreenSettings()
        }
        refreshPermissions()
    }

    // MARK: Recording

    func toggle() {
        switch status {
        case .recording: stop()
        case .idle, .failed: start()
        default: break
        }
    }

    func start() {
        refreshPermissions()
        guard neededPermissionsGranted else {
            if !micGranted && needsMic { grantMicrophone() }
            if !screenGranted && needsScreen { grantScreen() }
            if !cameraGranted && needsCamera { grantCamera() }
            status = .failed("Grant the permissions above first.")
            return
        }

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            status = .failed("Can't use folder: \(error.localizedDescription)")
            return
        }

        let name = "Intercept \(Format.fileStamp(Date()))"
        let final = folder.appendingPathComponent(name).appendingPathExtension(settings.fileExtension).uniqued()
        let raw = folder.appendingPathComponent(".\(name).capture.mov")

        let session = CaptureSession(settings: settings, rawURL: raw)
        // Pressing Stop in macOS's own screen-recording menu ends the recording.
        session.onUserStopped = { [weak self] in
            Task { @MainActor in self?.stop() }
        }
        self.session = session
        self.finalURL = final
        status = .starting

        Task {
            do {
                try await session.start()
                startedAt = Date()
                elapsed = 0
                status = .recording
                preventSleep(true)
                startTicker()
            } catch {
                self.session = nil
                try? FileManager.default.removeItem(at: raw)
                status = .failed(error.localizedDescription)
            }
        }
    }

    func stop() {
        guard status == .recording, let session, let finalURL else { return }
        status = .saving
        stopTicker()
        preventSleep(false)
        let fileType = session.settings.fileType
        self.session = nil

        Task {
            do {
                let raw = try await session.stop()
                let (_, mixError) = await Mixdown.finish(raw: raw, to: finalURL, fileType: fileType)
                refreshRecordings()
                status = mixError.map { .failed("Saved an unmixed .mov instead (\($0.localizedDescription)).") } ?? .idle
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Staying awake

    /// While recording, stop the Mac going to sleep when idle. The display may
    /// still turn off (sound keeps recording; video resumes when it's back).
    /// Closing the lid or choosing Sleep still sleeps the Mac.
    private func preventSleep(_ on: Bool) {
        if on, noSleepAssertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "Intercept is recording" as CFString, &noSleepAssertion)
        } else if !on, noSleepAssertion != 0 {
            IOPMAssertionRelease(noSleepAssertion)
            noSleepAssertion = 0
        }
    }

    // MARK: Recordings list

    func refreshRecordings() {
        let folder = self.folder
        Task {
            let items = await RecordingLibrary.scan(folder)
            if folder == self.folder { recordings = items }
        }
    }

    func moveToTrash(_ item: RecordingItem) {
        NSWorkspace.shared.recycle([item.url]) { [weak self] _, _ in
            Task { @MainActor in self?.refreshRecordings() }
        }
    }

    // MARK: Folder

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        panel.prompt = "Save Here"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { folder = url }
    }

    func revealFolder() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    // MARK: Ticker (elapsed time + level meters)

    private func startTicker() {
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
        inLevel = 0
        outLevel = 0
        screenPaused = false
    }

    private func tick() {
        if let startedAt { elapsed = Date().timeIntervalSince(startedAt) }
        guard let session else { return }
        if screenPaused != session.isVideoPaused { screenPaused = session.isVideoPaused }
        let levels = session.takeLevels()
        // Fast attack, slow release so the meters read smoothly.
        inLevel = max(Self.meter(levels.input), inLevel * 0.82)
        outLevel = max(Self.meter(levels.output), outLevel * 0.82)
    }

    /// Map a linear peak to 0...1 on a -50 dB…0 dB scale.
    private static func meter(_ peak: Float) -> Float {
        guard peak > 0 else { return 0 }
        let db = 20 * log10(peak)
        return max(0, min(1, (db + 50) / 50))
    }

}

/// Saves and loads the recording choices between launches.
enum SettingsStore {
    private static let d = UserDefaults.standard

    static func load() -> CaptureSettings {
        var s = CaptureSettings()
        if d.object(forKey: "src.screen") != nil {
            s.screen = d.bool(forKey: "src.screen")
            s.audio = d.bool(forKey: "src.audio")
            s.camera = d.bool(forKey: "src.camera")
        } else if let old = d.string(forKey: "mode") {
            // Earlier versions saved one of three modes.
            s.screen = old != "audio"
            s.audio = old != "screenOnly"
        }
        s.displays = DisplayChoice(rawValue: d.string(forKey: "displays") ?? "") ?? .main
        if d.object(forKey: "mic.use") != nil { s.useMic = d.bool(forKey: "mic.use") }
        s.micID = d.string(forKey: "mic.id")
        if d.object(forKey: "macSound") != nil { s.macSound = d.bool(forKey: "macSound") }
        s.cameraID = d.string(forKey: "camera.id")
        return s
    }

    static func save(_ s: CaptureSettings) {
        d.set(s.screen, forKey: "src.screen")
        d.set(s.audio, forKey: "src.audio")
        d.set(s.camera, forKey: "src.camera")
        d.set(s.displays.rawValue, forKey: "displays")
        d.set(s.useMic, forKey: "mic.use")
        d.set(s.micID, forKey: "mic.id")
        d.set(s.macSound, forKey: "macSound")
        d.set(s.cameraID, forKey: "camera.id")
    }
}
