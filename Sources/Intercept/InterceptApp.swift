import SwiftUI
import GraphiteEmber
import AppKit

@main
struct InterceptApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    init() {
        AppArtwork.writeIconsetIfRequested()
    }

    var body: some Scene {
        Window("Intercept", id: "home") {
            HomeView()
                .environmentObject(state)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        // A recording's transcript, one window per file.
        WindowGroup("Transcript", id: "transcript", for: URL.self) { $url in
            if let url {
                TranscriptWindow(recording: url).environmentObject(state)
            }
        }
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra {
            MenuPanel()
                .environmentObject(state)
        } label: {
            HStack(spacing: 4) {
                Image(nsImage: AppArtwork.menuBarIcon(recording: state.isActive))
                if state.isRecording {
                    Text(Format.clock(state.elapsed)).monospacedDigit()
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = AppArtwork.appIcon()
        NSApp.activate(ignoringOtherApps: true)
        SelfTest.runIfRequested()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NSApp.activate(ignoringOtherApps: true) }
        return true
    }
}
