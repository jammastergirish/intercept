import SwiftUI
import AppKit

@main
struct InterceptApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        Window("Intercept", id: "home") {
            HomeView()
                .environmentObject(state)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuPanel()
                .environmentObject(state)
        } label: {
            HStack(spacing: 4) {
                Image(nsImage: AppArtwork.menuBarIcon(recording: state.isActive))
                if state.isRecording {
                    Text(AppState.clock(state.elapsed)).monospacedDigit()
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
