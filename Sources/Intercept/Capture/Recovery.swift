import Foundation
import AVFoundation

/// Finishes recordings that were cut off by a crash, power loss or force quit.
///
/// While recording, Intercept writes a hidden temporary file named
/// `.<name>.capture.mov` next to where the final file will go. A normal stop
/// mixes it into the final file and deletes it, so any such file found at
/// launch belongs to a recording that never stopped properly. Because the
/// capture file is written in 10-second fragments, everything up to the last
/// fragment still plays; we mix that into `<name> (recovered).mp4/.m4a`.
enum Recovery {

    struct Result {
        var recovered: [URL] = []
        var failed: [URL] = []
    }

    static func leftovers(in folder: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [])) ?? []
        return files.filter {
            $0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent.hasSuffix(".capture.mov")
        }
    }

    static func run(in folder: URL) async -> Result {
        var result = Result()
        for raw in leftovers(in: folder) {
            // A file written to in the last minute may belong to a recording
            // that is still running (fragments land every 10 s). Leave it.
            let modified = (try? raw.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, Date().timeIntervalSince(modified) < 60 { continue }

            let name = String(raw.lastPathComponent.dropFirst().dropLast(".capture.mov".count))
            let asset = AVURLAsset(url: raw)

            // Nothing usable (the app died before the first 10-second fragment).
            let duration = (try? await asset.load(.duration).seconds) ?? 0
            guard duration.isFinite, duration >= 0.5 else {
                try? FileManager.default.removeItem(at: raw)
                continue
            }

            let hasVideo = !((try? await asset.loadTracks(withMediaType: .video)) ?? []).isEmpty
            let mode: RecordingMode = hasVideo ? .screen : .audio
            let out = folder.appendingPathComponent("\(name) (recovered)")
                .appendingPathExtension(mode.fileExtension).uniqued()
            let (saved, error) = await Mixdown.finish(raw: raw, to: out, fileType: mode.fileType)
            if error == nil { result.recovered.append(saved) } else { result.failed.append(saved) }
        }
        return result
    }
}
