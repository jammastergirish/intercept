import SwiftUI
import GraphiteEmber
import AppKit

/// Main window — "Graphite & Ember": mono titlebar, Screen / Audio / Camera
/// tick-boxes with their options, inverse record banner with live levels,
/// permissions, recordings table, footer.
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
        .onAppear {
            state.refreshPermissions(); state.refreshDisplays(); state.refreshDevices(); state.refreshRecordings()
        }
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
            sourcePicker
            optionsCard

            recordBanner

            if case .failed(let message) = state.status {
                NoticeBanner(message)
            }

            if let note = state.recoveryNote {
                NoticeBanner(note) { state.recoveryNote = nil }
            }

            if !state.neededPermissionsGranted {
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


    // MARK: What to record

    /// Screen / Audio / Camera tick-boxes. At least one stays ticked.
    private var sourcePicker: some View {
        ChipGroup(disabled: state.isLocked) {
            ToggleChip("Screen", systemImage: "display", isOn: source(\.screen))
            ToggleChip("Audio", systemImage: "waveform", isOn: source(\.audio))
            ToggleChip("Camera", systemImage: "video", isOn: source(\.camera))
        }
    }

    /// A binding to one source that refuses to untick the last one.
    private func source(_ key: WritableKeyPath<CaptureSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { state.settings[keyPath: key] },
            set: { on in
                var next = state.settings
                next[keyPath: key] = on
                if next.screen || next.audio || next.camera { state.settings = next }
            })
    }

    /// One row of options for each ticked source.
    @ViewBuilder private var optionsCard: some View {
        let rows = optionRows
        if !rows.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    if i > 0 { Divider().overlay(Theme.divider) }
                    row
                }
            }
            .padding(.horizontal, 12)
            .background(Theme.cardBG, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.fieldBorder, lineWidth: 1))
        }
    }

    private var optionRows: [AnyView] {
        var rows: [AnyView] = []
        let s = state.settings
        // Displays: only worth asking when there's more than one.
        if s.screen && state.distinctDisplayCount > 1 {
            rows.append(AnyView(optionRow("Displays") {
                Text(displaysNote).font(.mono(11)).foregroundStyle(Theme.monoFaint)
                SegmentPicker(segments: [
                    Segment(value: DisplayChoice.main, title: "Main", systemImage: nil),
                    Segment(value: DisplayChoice.all, title: "All", systemImage: nil),
                ], selection: $state.settings.displays, disabled: state.isLocked, compact: true)
                .frame(width: 130)
            }))
        }
        if s.audio {
            rows.append(AnyView(optionRow("Microphone") {
                OptionMenu(options: micOptions, selection: micSelection, disabled: state.isLocked)
                    .frame(width: 210)
            }))
            rows.append(AnyView(optionRow("Mac sound") {
                Toggle("Record what the Mac plays", isOn: $state.settings.macSound)
                    .toggleStyle(EmberCheckboxStyle(fontSize: 12))
                    .disabled(state.isLocked)
            }))
        }
        if s.camera {
            rows.append(AnyView(optionRow("Camera") {
                OptionMenu(options: cameraOptions, selection: cameraSelection, disabled: state.isLocked)
                    .frame(width: 210)
            }))
        }
        return rows
    }

    private func optionRow<Control: View>(_ label: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 10) {
            MonoLabel(text: label, size: 10.5, tracking: 0.9, color: Theme.textSecondary)
            Spacer(minLength: 8)
            control()
        }
        .padding(.vertical, 8)
    }

    private var displaysNote: String {
        let n = state.distinctDisplayCount
        return state.settings.displays == .main ? "1 of \(n)" : "\(n) side by side"
    }

    // Microphone menu: "System default (name)", each mic, "None". The value is
    // "default", "none", or a mic's ID.
    private var micOptions: [OptionMenu<String>.Option] {
        var o = [OptionMenu.Option("default", "System default" + (CaptureDevices.defaultMicName.map { " (\($0))" } ?? ""))]
        o += state.microphones.map { OptionMenu.Option($0.id, $0.name) }
        if let id = state.settings.micID, !state.microphones.contains(where: { $0.id == id }) {
            o.append(OptionMenu.Option(id, "Not connected"))
        }
        o.append(OptionMenu.Option("none", "None"))
        return o
    }

    private var micSelection: Binding<String> {
        Binding(
            get: { state.settings.useMic ? (state.settings.micID ?? "default") : "none" },
            set: { v in
                switch v {
                case "none": state.settings.useMic = false
                case "default": state.settings.useMic = true; state.settings.micID = nil
                default: state.settings.useMic = true; state.settings.micID = v
                }
            })
    }

    // Camera menu: "System default (name)" and each camera.
    private var cameraOptions: [OptionMenu<String>.Option] {
        var o = [OptionMenu.Option("default", "System default" + (CaptureDevices.defaultCameraName.map { " (\($0))" } ?? ""))]
        o += state.cameras.map { OptionMenu.Option($0.id, $0.name) }
        if let id = state.settings.cameraID, !state.cameras.contains(where: { $0.id == id }) {
            o.append(OptionMenu.Option(id, "Not connected"))
        }
        return o
    }

    private var cameraSelection: Binding<String> {
        Binding(
            get: { state.settings.cameraID ?? "default" },
            set: { state.settings.cameraID = $0 == "default" ? nil : $0 })
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
            .opacity(state.settings.hasAudio ? 1 : 0.3)   // dim when no sound is recorded
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
            return state.settings.hasAudio || state.settings.camera
                ? "Display off · still recording" : "Display off · waiting for it"
        case .recording:
            let s = state.settings
            let parts = [s.screen ? "screen" : nil, s.camera ? "camera" : nil,
                         s.recordsMic ? "mic" : nil, s.recordsMacSound ? "Mac sound" : nil].compactMap { $0 }
            return parts.joined(separator: ", ").capitalizedFirst
        default:
            return "⇧⌘R to record"
        }
    }

    // MARK: Permissions

    private var permissionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            MonoLabel(text: "Permissions", size: 11, tracking: 1.0, color: Theme.textSecondary)
            let rows = permissionRows
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                if i > 0 { Divider().overlay(Theme.divider) }
                row
            }
            if state.needsScreen && !state.screenGranted {
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

    /// Only the permissions that what you've ticked actually needs.
    private var permissionRows: [AnyView] {
        var rows: [AnyView] = []
        if state.needsMic {
            rows.append(AnyView(permissionRow(icon: "mic", title: "Microphone", detail: "Records what goes in",
                                              granted: state.micGranted) { state.grantMicrophone() }))
        }
        if state.needsCamera {
            rows.append(AnyView(permissionRow(icon: "video", title: "Camera", detail: "Records your camera",
                                              granted: state.cameraGranted) { state.grantCamera() }))
        }
        if state.needsScreen {
            rows.append(AnyView(permissionRow(icon: "rectangle.dashed.badge.record", title: "Screen Recording",
                                              detail: "Records the screen",
                                              granted: state.screenGranted) { state.grantScreen() }))
        }
        return rows
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

private extension String {
    /// "screen, mic" → "Screen, mic".
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
