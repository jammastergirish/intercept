import Foundation
import GraphiteEmber
import AVFoundation

/// A finished recording on disk.
struct RecordingItem: Identifiable, Equatable {
    let url: URL
    let date: Date
    let bytes: Int64
    var duration: TimeInterval?
    var hasTranscript = false
    var id: URL { url }

    /// The file name without extension, e.g. "Intercept 2026-11-12 at 19.53.40".
    var name: String { url.deletingPathExtension().lastPathComponent }

    /// What the table shows: your name for it, or, for an untouched
    /// "Intercept <date> at <time>", just the date ("Today 19:53").
    var displayName: String {
        name.range(of: #"^Intercept \d{4}-\d{2}-\d{2} at \d{2}\.\d{2}\.\d{2}( \d+)?$"#, options: .regularExpression) != nil
            ? Format.when(date) : name
    }
    var isVideo: Bool { url.pathExtension.lowercased() != "m4a" }
}

/// Lists the recordings in a folder, newest first. Durations are read from
/// the files and cached, since that's the slow part.
enum RecordingLibrary {
    private static let extensions: Set<String> = ["mp4", "m4a", "mov"]
    private static var durationCache: [String: TimeInterval] = [:]   // key: path + mtime
    private static let lock = NSLock()

    static func scan(_ folder: URL) async -> [RecordingItem] {
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .fileSizeKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []

        var items: [RecordingItem] = []
        for url in files where extensions.contains(url.pathExtension.lowercased()) {
            let v = try? url.resourceValues(forKeys: Set(keys))
            let date = v?.creationDate ?? v?.contentModificationDate ?? .distantPast
            let bytes = Int64(v?.fileSize ?? 0)
            let key = "\(url.path)|\(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)"

            var duration = lock.withLock { durationCache[key] }
            if duration == nil, let seconds = try? await AVURLAsset(url: url).load(.duration).seconds,
               seconds.isFinite {
                duration = seconds
                lock.withLock { durationCache[key] = seconds }
            }
            items.append(RecordingItem(url: url, date: date, bytes: bytes, duration: duration,
                                       hasTranscript: Transcript.exists(for: url)))
        }
        return items.sorted { $0.date > $1.date }
    }
}
