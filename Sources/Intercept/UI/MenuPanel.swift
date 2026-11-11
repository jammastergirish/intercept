import SwiftUI
import AppKit

/// Menu-bar dropdown panel (MenuBarExtra `.window` style).
struct MenuPanel: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                LogoSquircle(side: 24)
                Text("Intercept")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                StatusBadge(text: state.status.badge)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 7)

            Text(subtitle)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

            Divider().overlay(Theme.divider)

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
                .disabled(state.isActive || state.isBusy)
            }
            .padding(6)
        }
        .frame(width: 280)
        .background(Theme.windowBG)
    }

    private var subtitle: String {
        switch state.status {
        case .recording: return "\(AppState.clock(state.elapsed)) · \(state.mode.title)"
        case .saving: return "Saving file…"
        case .paused: return "Paused · resumes when you unlock"
        default: return "Mode: \(state.mode.title)"
        }
    }
}

private struct MenuRow: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 12))
                    .frame(width: 16)
                    .foregroundStyle(hover ? Theme.emberText : Theme.textSecondary)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(hover ? Theme.emberTint : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
