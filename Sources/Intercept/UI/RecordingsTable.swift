import SwiftUI
import AppKit

/// All recordings in the folder, newest first. Double-click opens a file;
/// hovering shows Show-in-Finder and Open buttons; right-click for more.
struct RecordingsTable: View {
    @EnvironmentObject var state: AppState
    var maxHeight: CGFloat = 248

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.divider)
            if state.recordings.isEmpty {
                Text("Nothing recorded yet. Press the record button.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 14)
            } else if state.recordings.count <= 7 {
                rows   // short list: no scroll area needed
            } else {
                ScrollView { rows }
                    .frame(height: maxHeight)
            }
        }
        .background(Theme.cardBG, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.fieldBorder, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(Array(state.recordings.enumerated()), id: \.element.id) { i, item in
                RecordingRow(item: item)
                if i < state.recordings.count - 1 {
                    Divider().overlay(Theme.divider).padding(.leading, 34)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 16, height: 1)
            column("Recorded", alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
            column("Length", alignment: .trailing).frame(width: 64, alignment: .trailing)
            column("Size", alignment: .trailing).frame(width: 58, alignment: .trailing)
            Color.clear.frame(width: 44, height: 1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func column(_ title: String, alignment: Alignment) -> some View {
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
            Text(Self.when(item.date))
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(item.duration.map(Self.length) ?? "—")
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
            }
            .frame(width: 44)
            .opacity(hover ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(hover ? Theme.emberTint : Color.clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
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

    // "Today 19:53", "Yesterday 08:12", "Mon 9 Nov 14:03", "9 Nov 2025 14:03"
    static func when(_ date: Date) -> String {
        let cal = Calendar.current
        let time = timeFmt.string(from: date)
        if cal.isDateInToday(date) { return "Today \(time)" }
        if cal.isDateInYesterday(date) { return "Yesterday \(time)" }
        if cal.isDate(date, equalTo: Date(), toGranularity: .year) { return "\(dayFmt.string(from: date)) \(time)" }
        return "\(yearFmt.string(from: date)) \(time)"
    }

    static func length(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }

    private static let timeFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
    private static let dayFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE d MMM"; return f }()
    private static let yearFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "d MMM yyyy"; return f }()
}
