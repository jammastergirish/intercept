import SwiftUI
import GraphiteEmber
import AppKit

/// Main window — "Graphite & Ember": mono titlebar, mode picker, inverse
/// record banner with live levels, permissions, last-recording card, footer.
struct HomeView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            WindowTitleBar(title: "Intercept", badge: state.status.badge)
            Divider().overlay(Theme.divider)
            content
        }
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)   // window hugs its content
        .background(Theme.windowBG)
        .onAppear { state.refreshPermissions(); state.refreshDisplays(); state.refreshRecordings() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            state.refreshDisplays()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            state.refreshPermissions()
            state.refreshRecordings()
        }
    }

    // MARK: Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            SegmentPicker(segments: [
                Segment(value: RecordingMode.screenOnly, title: RecordingMode.screenOnly.title, systemImage: "display"),
                Segment(value: RecordingMode.audio, title: RecordingMode.audio.title, systemImage: "waveform"),
                Segment(value: RecordingMode.screen, title: RecordingMode.screen.title, systemImage: "film"),
            ], selection: $state.mode, disabled: state.isLocked)

            // Only worth asking when there's more than one display to choose from.
            if state.mode.hasVideo && state.distinctDisplayCount > 1 {
                displaysRow
            }

            recordBanner

            if case .failed(let message) = state.status {
                NoticeBanner(message)
            }

            if let note = state.recoveryNote {
                NoticeBanner(note) { state.recoveryNote = nil }
            }

            if !state.allPermissionsGranted {
                permissionsCard
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    MonoLabel(text: "Recordings", size: 11, tracking: 1.0, color: Theme.textSecondary)
                    Spacer()
                    if !state.recordings.isEmpty {
                        Text("\(state.recordings.count)").font(.mono(11)).foregroundStyle(Theme.monoFaint)
                    }
                }
                RecordingsTable()
            }

            footer
        }
        .padding(20)
    }


    // MARK: Displays

    private var displaysRow: some View {
        HStack(spacing: 12) {
            MonoLabel(text: "Displays", size: 11, tracking: 1.0, color: Theme.textSecondary)
            Spacer()
            Text(displaysNote)
                .font(.mono(11))
                .foregroundStyle(Theme.monoFaint)
            SegmentPicker(segments: [
                Segment(value: DisplayChoice.main, title: "Main", systemImage: nil),
                Segment(value: DisplayChoice.all, title: "All", systemImage: nil),
            ], selection: $state.displayChoice, disabled: state.isLocked, compact: true)
            .frame(width: 130)
        }
    }

    private var displaysNote: String {
        let n = state.distinctDisplayCount
        return state.displayChoice == .main ? "1 of \(n)" : "\(n) side by side"
    }


    // MARK: Record banner

    private var recordBanner: some View {
        HStack(spacing: 16) {
            RecordButton(recording: state.isActive, busy: state.isBusy) { state.toggle() }
                .keyboardShortcut("r", modifiers: [.command, .shift])

            VStack(alignment: .leading, spacing: 4) {
                Text(Format.clock(state.elapsed))
                    .font(.mono(22, weight: .medium))
                    .foregroundStyle(state.isRecording ? .white : Theme.inverseText)
                    .monospacedDigit()
                Text(bannerSubtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.overlayDim)
            }

            Spacer(minLength: 8)

            VStack(alignment: .leading, spacing: 6) {
                LevelMeter(label: "In", level: state.inLevel)
                LevelMeter(label: "Out", level: state.outLevel)
            }
            .opacity(state.mode.hasAudio ? 1 : 0.3)   // no sound recorded in Screen mode
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Theme.inversePanelBG, in: RoundedRectangle(cornerRadius: 10))
    }

    private var bannerSubtitle: String {
        switch state.status {
        case .starting: return "Starting…"
        case .saving: return "Saving file…"
        case .recording where state.screenPaused:
            return state.mode.hasAudio ? "Display off · still recording sound" : "Display off · waiting for it"
        case .recording:
            switch state.mode {
            case .screenOnly: return "Screen only, no sound"
            case .audio: return "Mic and system audio"
            case .screen: return "Screen, mic and system audio"
            }
        default:
            return "⇧⌘R to record"
        }
    }

    // MARK: Permissions

    private var permissionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            MonoLabel(text: "Permissions", size: 11, tracking: 1.0, color: Theme.textSecondary)
            permissionRow(icon: "mic", title: "Microphone",
                          detail: "Records what goes in",
                          granted: state.micGranted) { state.grantMicrophone() }
            Divider().overlay(Theme.divider)
            permissionRow(icon: "rectangle.dashed.badge.record", title: "Screen & System Audio",
                          detail: "Records the screen and what comes out",
                          granted: state.screenGranted) { state.grantScreen() }
            if !state.screenGranted {
                HStack {
                    Text("After allowing Screen & System Audio Recording, macOS needs Intercept to relaunch.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Relaunch") { Permissions.relaunch() }
                        .buttonStyle(EmberLinkButtonStyle())
                }
            }
        }
        .padding(14)
        .background(Theme.cardBG, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.fieldBorder, lineWidth: 1))
    }

    private func permissionRow(icon: String, title: String, detail: String,
                               granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13)).foregroundStyle(Theme.textPrimary)
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            if granted {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                    Text("Allowed").font(.system(size: 12))
                }
                .foregroundStyle(Theme.successText)
            } else {
                Button("Grant", action: action).buttonStyle(EmberLinkButtonStyle())
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                state.chooseFolder()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder").font(.system(size: 11))
                    Text(abbreviated(state.folder.path))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .disabled(state.isLocked)
            .help("Choose where recordings are saved")

            Button("Show") { state.revealFolder() }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .disabled(state.isLocked)
        }
        .buttonStyle(GraphiteButtonStyle())
    }

    // MARK: Helpers

    private func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// Big round ember record button. A circle when idle, a rounded square while recording.
struct RecordButton: View {
    var recording: Bool
    var busy: Bool
    var action: () -> Void
    @State private var pulse = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(Theme.ember.opacity(recording ? 0.9 : 0.5), lineWidth: 2)
                    .frame(width: 46, height: 46)
                    .scaleEffect(recording && pulse ? 1.08 : 1)
                if busy {
                    EmberSpinner(size: 18)
                } else if recording {
                    RoundedRectangle(cornerRadius: 4).fill(Theme.ember).frame(width: 16, height: 16)
                } else {
                    Circle().fill(Theme.ember).frame(width: 30, height: 30)
                }
            }
            .frame(width: 50, height: 50)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .help(recording ? "Stop recording" : "Start recording")
        .onChange(of: recording) { _, now in
            if now {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
            } else {
                withAnimation(.default) { pulse = false }
            }
        }
    }
}
