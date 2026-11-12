import AVFoundation
import AppKit
import CoreGraphics

/// The macOS permissions Intercept asks for: Microphone, Camera, and Screen &
/// System Audio Recording. (System sound has its own permission, which macOS
/// asks for the first time Intercept records it.)
enum Permissions {

    // MARK: Microphone and camera

    /// `.audio` for the microphone, `.video` for the camera.
    static func authorized(_ media: AVMediaType) -> Bool {
        AVCaptureDevice.authorizationStatus(for: media) == .authorized
    }

    /// Ask the first time; after that macOS only lets you change it in
    /// System Settings, so open the right page there.
    static func request(_ media: AVMediaType) async {
        if AVCaptureDevice.authorizationStatus(for: media) == .notDetermined {
            await AVCaptureDevice.requestAccess(for: media)
        } else {
            open("x-apple.systempreferences:com.apple.preference.security?" +
                 (media == .video ? "Privacy_Camera" : "Privacy_Microphone"))
        }
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
