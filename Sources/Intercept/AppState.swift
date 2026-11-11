import SwiftUI
import GraphiteEmber
import AppKit
import AVFoundation
import ScreenCaptureKit

@MainActor
final class AppState: ObservableObject {

    enum Status: Equatable {
        case idle, starting, recording, saving, failed(String)
        /// macOS took the display away (it slept). We resume on wake/unlock.
        case paused

        var badge: String {
            switch self {
            case .idle: return "Ready"
            case .starting: return "Starting"
            case .recording: return "Recording"
            case .saving: return "Saving"
            case .failed: return "Error"
            case .paused: return "Paused"
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
    /// Every recording in the folder, newest first.
    @Published private(set) var recordings: [RecordingItem] = []
    /// Message about recordings finished after a crash, shown until dismissed.
    @Published var recoveryNote: String?
    @Published private(set) var micGranted = Permissions.microphoneAuthorized()
    @Published private(set) var screenGranted = Permissions.screenAuthorized()

    var isRecording: Bool { status == .recording }
    /// Recording, or paused and waiting to resume. Stop ends either.
    var isActive: Bool { status == .recording || status == .paused }
    var isBusy: Bool { status == .starting || status == .saving }
    /// Settings and Quit are locked while a recording is running, paused or saving.
    var isLocked: Bool { isActive || isBusy }
    var allPermissionsGranted: Bool { micGranted && screenGranted }
    /// Screen-only recording doesn't use the microphone.
    private var neededPermissionsGranted: Bool { screenGranted && (micGranted || !mode.hasAudio) }

    // MARK: Private

    private var session: CaptureSession?
    private var startedAt: Date?
    private var ticker: Timer?
    private var finalURL: URL?
    private var resumeTimer: Timer?
    private var wakeObservers: [NSObjectProtocol] = []

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
        case .paused: cancelResume(); status = .idle
        case .idle, .failed: start()
        default: break
        }
    }

    func start() { start(resuming: false) }

    private func start(resuming: Bool) {
        refreshPermissions()
        guard neededPermissionsGranted else {
            if !micGranted && mode.hasAudio { grantMicrophone() }
            if !screenGranted { grantScreen() }
            status = .failed("Grant both permissions first.")
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
        session.onUnexpectedStop = { [weak self] error in
            // If you pressed Stop in macOS's own screen-recording menu, stay
            // stopped. Anything else (display slept, screen locked with the
            // display off) means: save what we have and resume when it's back.
            let ns = error as NSError?
            let userStopped = ns?.domain == SCStreamErrorDomain
                && ns?.code == SCStreamError.Code.userStopped.rawValue
            Task { @MainActor in self?.stop(thenResume: !userStopped) }
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
                startTicker()
            } catch {
                self.session = nil
                try? FileManager.default.removeItem(at: raw)
                // While resuming, the display may simply not be back yet.
                status = resuming ? .paused : .failed(error.localizedDescription)
            }
        }
    }

    func stop() { stop(thenResume: false) }

    private func stop(thenResume: Bool) {
        guard status == .recording, let session, let finalURL else { return }
        status = .saving
        stopTicker()
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
            if thenResume { beginWaitingToResume() }
        }
    }

    // MARK: Resume after the display sleeps

    private func beginWaitingToResume() {
        status = .paused
        // Try again whenever the display wakes or the screen unlocks, and
        // every few seconds as a fallback.
        if wakeObservers.isEmpty {
            let retry: (Notification) -> Void = { [weak self] _ in
                Task { @MainActor in self?.attemptResume() }
            }
            wakeObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main, using: retry))
            wakeObservers.append(DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main, using: retry))
        }
        resumeTimer?.invalidate()
        resumeTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.attemptResume() }
        }
    }

    private func attemptResume() {
        guard status == .paused else { return }
        // Capture fails while the screen is locked, so don't even try then.
        if let d = CGSessionCopyCurrentDictionary() as? [String: Any],
           (d["CGSSessionScreenIsLocked"] as? Int ?? 0) == 1 { return }
        start(resuming: true)
        // `start` sets .recording on success or falls back to .paused.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if status == .recording { cancelResume() }
        }
    }

    private func cancelResume() {
        resumeTimer?.invalidate()
        resumeTimer = nil
        for o in wakeObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
            DistributedNotificationCenter.default().removeObserver(o)
        }
        wakeObservers = []
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
    }

    private func tick() {
        if let startedAt { elapsed = Date().timeIntervalSince(startedAt) }
        guard let session else { return }
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
