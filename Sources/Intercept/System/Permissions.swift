import AVFoundation
import AppKit
import CoreGraphics

/// The two macOS permissions Intercept needs: Microphone (what goes in) and
/// Screen & System Audio Recording (the screen and what comes out).
enum Permissions {

    // MARK: Microphone

    static func microphoneAuthorized() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func microphoneUndetermined() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
    }

    @discardableResult
    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    // MARK: Screen & System Audio Recording

    static func screenAuthorized() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Shows the system prompt the first time; afterwards it just returns the state.
    @discardableResult
    static func requestScreen() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func openScreenSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    private static func open(_ urlString: String) {
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }

    /// Relaunch the app (macOS only applies a new Screen Recording grant after a restart).
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5; open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}
