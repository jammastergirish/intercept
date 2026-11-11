import SwiftUI
import AppKit
import AVFoundation

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

    struct Recording: Equatable {
        let url: URL
        let mode: RecordingMode
        let finishedAt: Date
        let duration: TimeInterval
        let bytes: Int64
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
        didSet { UserDefaults.standard.set(folder.path, forKey: "folder") }
    }
    @Published private(set) var status: Status = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var inLevel: Float = 0     // microphone
    @Published private(set) var outLevel: Float = 0    // sound the Mac plays
    @Published private(set) var lastRecording: Recording?
    /// Message about recordings finished after a crash, shown until dismissed.
    @Published var recoveryNote: String?
    @Published private(set) var micGranted = Permissions.microphoneAuthorized()
    @Published private(set) var screenGranted = Permissions.screenAuthorized()

    var isRecording: Bool { status == .recording }
    var isBusy: Bool { status == .starting || status == .saving }
    var allPermissionsGranted: Bool { micGranted && screenGranted }

    // MARK: Private

    private var session: CaptureSession?
    private var startedAt: Date?
    private var ticker: Timer?
    private var finalURL: URL?

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
        if !args.contains("--selftest") && !args.contains("--snapshot") {
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
        if let newest = all.last {
            let asset = AVURLAsset(url: newest)
            let duration = (try? await asset.load(.duration).seconds) ?? 0
            let bytes = (try? newest.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
            let hasVideo = !((try? await asset.loadTracks(withMediaType: .video)) ?? []).isEmpty
            lastRecording = Recording(url: newest, mode: hasVideo ? .screen : .audio,
                                      finishedAt: Date(), duration: duration, bytes: bytes)
        }
        let n = all.count
        var note = "Intercept closed unexpectedly during \(n == 1 ? "a recording" : "\(n) recordings"). "
        note += "Saved everything up to the last 10 seconds as “(recovered)”."
        if !result.failed.isEmpty {
            note += " \(result.failed.count) couldn't be mixed and was kept as a .mov with separate mic and system tracks."
        }
        recoveryNote = note
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
        guard allPermissionsGranted else {
            if !micGranted { grantMicrophone() }
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

        let name = "Intercept \(Self.fileStamp.string(from: Date()))"
        let final = uniqueURL(folder.appendingPathComponent(name).appendingPathExtension(mode.fileExtension))
        let raw = folder.appendingPathComponent(".\(name).capture.mov")

        let session = CaptureSession(mode: mode, displays: displayChoice, rawURL: raw)
        session.onUnexpectedStop = { [weak self] _ in
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
        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? elapsed
        let mode = session.mode
        self.session = nil

        Task {
            do {
                let raw = try await session.stop()
                do {
                    try await Mixdown.run(raw: raw, to: finalURL, fileType: mode.fileType)
                    try? FileManager.default.removeItem(at: raw)
                    finish(url: finalURL, mode: mode, duration: duration)
                } catch {
                    // Keep the un-mixed capture rather than lose the recording.
                    let fallback = finalURL.deletingPathExtension().appendingPathExtension("mov")
                    try? FileManager.default.moveItem(at: raw, to: fallback)
                    finish(url: fallback, mode: mode, duration: duration)
                    status = .failed("Saved unmixed copy (\(error.localizedDescription)).")
                }
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }

    private func finish(url: URL, mode: RecordingMode, duration: TimeInterval) {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
        lastRecording = Recording(url: url, mode: mode, finishedAt: Date(), duration: duration, bytes: bytes)
        status = .idle
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

    // MARK: Helpers

    private func uniqueURL(_ url: URL) -> URL {
        var candidate = url
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let base = url.deletingPathExtension().lastPathComponent
            candidate = url.deletingLastPathComponent()
                .appendingPathComponent("\(base) \(n)").appendingPathExtension(url.pathExtension)
            n += 1
        }
        return candidate
    }

    private static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()

    static func clock(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }
}
