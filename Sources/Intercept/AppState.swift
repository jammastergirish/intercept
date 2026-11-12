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

    @Published var mode: RecordingMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "mode") }
    }
    @Published var displayChoice: DisplayChoice {
        didSet { UserDefaults.standard.set(displayChoice.rawValue, forKey: "displays") }
    }
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
    @Published private(set) var micGranted = Permissions.microphoneAuthorized()
    @Published private(set) var screenGranted = Permissions.screenAuthorized()

    var isRecording: Bool { status == .recording }
    /// A recording is running. (Kept separate from `isRecording` for the UI.)
    var isActive: Bool { status == .recording }
    var isBusy: Bool { status == .starting || status == .saving }
    /// Settings and Quit are locked while a recording is running or saving.
    var isLocked: Bool { isActive || isBusy }
    var allPermissionsGranted: Bool { micGranted && screenGranted }
    /// Screen-only recording doesn't use the microphone.
    /// Audio needs the microphone; anything with video needs screen recording.
    /// (System sound has its own permission, which macOS asks for on first use.)
    private var neededPermissionsGranted: Bool {
        (micGranted || !mode.hasAudio) && (screenGranted || !mode.hasVideo)
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
        mode = RecordingMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .screen
        displayChoice = DisplayChoice(rawValue: defaults.string(forKey: "displays") ?? "") ?? .main
        if let path = defaults.string(forKey: "folder") {
            folder = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Intercept", isDirectory: true)
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

    func refreshPermissions() {
        micGranted = Permissions.microphoneAuthorized()
        screenGranted = Permissions.screenAuthorized()
    }

    func grantMicrophone() {
        if Permissions.microphoneUndetermined() {
            Task {
                await Permissions.requestMicrophone()
                refreshPermissions()
            }
        } else {
            Permissions.openMicrophoneSettings()
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
            if !micGranted && mode.hasAudio { grantMicrophone() }
            if !screenGranted && mode.hasVideo { grantScreen() }
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
        let final = folder.appendingPathComponent(name).appendingPathExtension(mode.fileExtension).uniqued()
        let raw = folder.appendingPathComponent(".\(name).capture.mov")

        let session = CaptureSession(mode: mode, displays: displayChoice, rawURL: raw)
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
        let mode = session.mode
        self.session = nil

        Task {
            do {
                let raw = try await session.stop()
                let (_, mixError) = await Mixdown.finish(raw: raw, to: finalURL, fileType: mode.fileType)
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
