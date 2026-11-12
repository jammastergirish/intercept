import SwiftUI
import AppKit
import GraphiteEmber

/// All recordings in the folder, newest first. Double-click a name to rename
/// it; hovering shows Show in Finder, Open, Transcript and Trash buttons;
/// right-click for the same and more.
struct RecordingsTable: View {
    @EnvironmentObject var state: AppState
    var maxHeight: CGFloat = 248

    var body: some View {
        TableCard(state.recordings,
                  emptyMessage: "Nothing recorded yet. Press the record button.",
                  maxRowsWithoutScroll: 7,
                  scrollHeight: maxHeight,
                  dividerInset: 34) {
            header
        } row: { item in
            RecordingRow(item: item)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 16, height: 1)
            column("Name").frame(maxWidth: .infinity, alignment: .leading)
            column("Length").frame(width: 64, alignment: .trailing)
            column("Size").frame(width: 58, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func column(_ title: String) -> some View {
        MonoLabel(text: title, size: 10, tracking: 0.8, color: Theme.monoFaint)
    }
}

private struct RecordingRow: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow
    let item: RecordingItem
    @State private var hover = false
    @State private var renaming = false
    @State private var draft = ""
    @FocusState private var nameFocused: Bool

    private var transcribing: Bool { state.transcribing.contains(item.url) }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.isVideo ? "film" : "waveform")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.emberText)
                .frame(width: 16)
            nameCell
                .frame(maxWidth: .infinity, alignment: .leading)
            // Length and size; while you hover (or it's transcribing), the
            // row's buttons take their place, so names keep the full width.
            ZStack(alignment: .trailing) {
                HStack(spacing: 8) {
                    Text(item.duration.map(Format.length) ?? "—")
                        .font(.mono(11.5))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 64, alignment: .trailing)
                    Text(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file))
                        .font(.mono(11.5))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .frame(width: 58, alignment: .trailing)
                }
                .opacity(hover || transcribing ? 0 : 1)
                HStack(spacing: 2) {
                    iconButton("magnifyingglass", help: "Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([item.url])
                    }
                    iconButton("play.fill", help: "Open") { NSWorkspace.shared.open(item.url) }
                    transcriptButton
                    iconButton("trash", help: "Move to Trash") { state.moveToTrash(item) }
                }
                .opacity(hover || transcribing ? 1 : 0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .tableRowHover($hover)
        .help("\(item.url.lastPathComponent) · \(Format.when(item.date))")
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(item.url) }
            Button("Rename…") { beginRename() }
            if item.hasTranscript {
                Button("Open Transcript") { openTranscript() }
            }
            if state.hasAPIKey {
                Button(item.hasTranscript ? "Transcribe Again" : "Transcribe") { state.transcribe(item.url) }
                    .disabled(transcribing)
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Divider()
            Button("Move to Trash") { state.moveToTrash(item) }
        }
    }

    // The name, or a text field while renaming. Double-click to rename.
    @ViewBuilder private var nameCell: some View {
        if renaming {
            TextField("Name", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 4)
                .background(Theme.fieldBG, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.ember, lineWidth: 1))
                .focused($nameFocused)
                .onSubmit(commitRename)
                .onExitCommand { renaming = false }
                .onChange(of: nameFocused) { _, now in if !now && renaming { commitRename() } }
        } else {
            HStack(spacing: 5) {
                Text(item.displayName)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if item.hasTranscript {
                    Image(systemName: "text.quote")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.monoFaint)
                        .help("Has a transcript")
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: beginRename)
        }
    }

    // Open the transcript; or make one; or show progress.
    @ViewBuilder private var transcriptButton: some View {
        if transcribing {
            EmberSpinner(size: 11).frame(width: 20, height: 20).help("Transcribing…")
        } else if item.hasTranscript {
            iconButton("text.quote", help: "Open transcript", action: openTranscript)
        } else if state.hasAPIKey {
            iconButton("text.badge.plus", help: "Transcribe with ElevenLabs") { state.transcribe(item.url) }
        } else {
            Color.clear.frame(width: 20, height: 20)
        }
    }

    private func beginRename() {
        draft = item.name
        renaming = true
        nameFocused = true
    }

    private func commitRename() {
        renaming = false
        if draft != item.name { state.rename(item, to: draft) }
    }

    private func openTranscript() {
        openWindow(id: "transcript", value: item.url)
    }

    private func iconButton(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.emberText)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
