import SwiftUI
import AppKit
import GraphiteEmber

/// All recordings in the folder, newest first. Double-click opens a file;
/// hovering shows Show-in-Finder and Open buttons; right-click for more.
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
            column("Recorded").frame(maxWidth: .infinity, alignment: .leading)
            column("Length").frame(width: 64, alignment: .trailing)
            column("Size").frame(width: 58, alignment: .trailing)
            Color.clear.frame(width: 64, height: 1)
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
    let item: RecordingItem
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.isVideo ? "film" : "waveform")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.emberText)
                .frame(width: 16)
            Text(Format.when(item.date))
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(item.duration.map(Format.length) ?? "—")
                .font(.mono(11.5))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 64, alignment: .trailing)
            Text(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file))
                .font(.mono(11.5))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .frame(width: 58, alignment: .trailing)
            HStack(spacing: 2) {
                iconButton("magnifyingglass", help: "Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                }
                iconButton("play.fill", help: "Open") { NSWorkspace.shared.open(item.url) }
                iconButton("trash", help: "Move to Trash") { state.moveToTrash(item) }
            }
            .frame(width: 64)
            .opacity(hover ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .tableRowHover($hover)
        .onTapGesture(count: 2) { NSWorkspace.shared.open(item.url) }
        .help(item.url.lastPathComponent)
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(item.url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Divider()
            Button("Move to Trash") { state.moveToTrash(item) }
        }
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
