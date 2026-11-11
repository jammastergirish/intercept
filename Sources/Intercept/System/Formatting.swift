import Foundation

/// Every time, date and file-name format the app shows, in one place.
enum Format {
    /// Running timer: "00:12:34".
    static func clock(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }

    /// Recording length: "0:05", "12:34", "1:02:03".
    static func length(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// When something was recorded: "Today 19:53", "Yesterday 08:12",
    /// "Mon 9 Nov 14:03", "9 Nov 2025 14:03".
    static func when(_ date: Date) -> String {
        let cal = Calendar.current
        let time = timeFmt.string(from: date)
        if cal.isDateInToday(date) { return "Today \(time)" }
        if cal.isDateInYesterday(date) { return "Yesterday \(time)" }
        if cal.isDate(date, equalTo: Date(), toGranularity: .year) { return "\(dayFmt.string(from: date)) \(time)" }
        return "\(yearFmt.string(from: date)) \(time)"
    }

    /// Timestamp used in file names: "2026-11-10 at 19.53.40".
    static func fileStamp(_ date: Date) -> String { stampFmt.string(from: date) }

    private static func formatter(_ pattern: String) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = pattern
        return f
    }
    private static let timeFmt = formatter("HH:mm")
    private static let dayFmt = formatter("EEE d MMM")
    private static let yearFmt = formatter("d MMM yyyy")
    private static let stampFmt = formatter("yyyy-MM-dd 'at' HH.mm.ss")
}

extension URL {
    /// Size on disk in bytes (0 if it can't be read).
    var fileSize: Int64 {
        Int64((try? resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    /// This URL, or "<name> 2.ext", "<name> 3.ext", … if the name is taken.
    func uniqued() -> URL {
        var candidate = self
        var n = 2
        let base = deletingPathExtension().lastPathComponent
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = deletingLastPathComponent()
                .appendingPathComponent("\(base) \(n)").appendingPathExtension(pathExtension)
            n += 1
        }
        return candidate
    }
}
