import SwiftUI
import GraphiteEmber
import AppKit

/// Menu-bar dropdown panel (MenuBarExtra `.window` style).
struct MenuPanel: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuPanelHeader(title: "Intercept", badge: state.status.badge, subtitle: subtitle) {
                LogoSquircle(side: 24)
            }

            VStack(spacing: 2) {
                MenuRow(title: state.isActive ? "Stop recording" : "Start recording",
                        systemImage: state.isActive ? "stop.circle" : "record.circle") {
                    state.toggle()
                }
                .disabled(state.isBusy)
                MenuRow(title: "Open main window", systemImage: "macwindow") {
                    openWindow(id: "home")
                    NSApp.activate(ignoringOtherApps: true)
                }
                MenuRow(title: "Show recordings folder", systemImage: "folder") {
                    state.revealFolder()
                }
                MenuRow(title: "Quit Intercept", systemImage: "power") {
                    NSApp.terminate(nil)
                }
                .disabled(state.isLocked)
            }
            .padding(6)
        }
        .frame(width: 280)
        .background(Theme.windowBG)
    }

    private var subtitle: String {
        switch state.status {
        case .recording: return "\(Format.clock(state.elapsed)) · \(state.settings.summary)"
        case .saving: return "Saving file…"
        default: return "Mode: \(state.settings.summary)"
        }
    }
}
