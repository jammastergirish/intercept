import Foundation
import GraphiteEmber

// Date labels, lengths and the running timer come from GraphiteEmber's
// `Format`; Intercept adds the timestamp it puts in file names.
extension Format {
    /// Timestamp used in file names: "2026-11-10 at 19.53.40".
    static func fileStamp(_ date: Date) -> String { stampFmt.string(from: date) }

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
