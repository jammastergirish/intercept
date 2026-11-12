import Foundation
import AVFoundation

/// ElevenLabs Scribe, the same way Diwan uses it: one upload per recording,
/// `scribe_v2` with speaker detection ("diarize") and filler words removed
/// ("no_verbatim"), falling back once to `scribe_v1` if v2 is refused.
enum Scribe {
    enum Failure: LocalizedError {
        case noKey, keyRejected, quota, http(Int, String), noAudio

        var errorDescription: String? {
            switch self {
            case .noKey: return "Add your ElevenLabs API key first."
            case .keyRejected: return "ElevenLabs rejected the API key."
            case .quota: return "Your ElevenLabs quota is used up."
            case .http(let code, let msg): return "ElevenLabs returned an error (\(code)): \(msg)"
            case .noAudio: return "This recording has no sound to transcribe."
            }
        }
    }

    private static let endpoint = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!

    /// Transcribe a recording. Video files are reduced to their sound first, so
    /// the upload stays small (about 115 MB per hour).
    static func transcribe(_ recording: URL) async throws -> Transcript {
        guard let key = APIKeyStore.read() else { throw Failure.noKey }
        let audio = try await soundOnly(recording)
        defer { if audio != recording { try? FileManager.default.removeItem(at: audio) } }

        do {
            return try await upload(audio, key: key, model: "scribe_v2", noVerbatim: true)
        } catch Failure.http(let code, _) where code != 401 && code != 429 {
            return try await upload(audio, key: key, model: "scribe_v1", noVerbatim: false)
        }
    }

    private static func upload(_ audio: URL, key: String, model: String, noVerbatim: Bool) async throws -> Transcript {
        // Build the multipart form in a temporary file, so long recordings
        // aren't held in memory twice.
        let boundary = "Intercept-\(UUID().uuidString)"
        let body = FileManager.default.temporaryDirectory.appendingPathComponent("\(boundary).form")
        defer { try? FileManager.default.removeItem(at: body) }
        FileManager.default.createFile(atPath: body.path, contents: nil)
        let out = try FileHandle(forWritingTo: body)
        func field(_ name: String, _ value: String) {
            out.write(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model_id", model)
        field("diarize", "true")
        if noVerbatim { field("no_verbatim", "true") }
        out.write(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(audio.lastPathComponent)\"\r\nContent-Type: audio/mp4\r\n\r\n".utf8))
        let input = try FileHandle(forReadingFrom: audio)
        while let chunk = try input.read(upToCount: 8 << 20), !chunk.isEmpty { out.write(chunk) }
        try input.close()
        out.write(Data("\r\n--\(boundary)--\r\n".utf8))
        try out.close()

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 1800   // a long recording can take many minutes

        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: body)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            if code == 401 { throw Failure.keyRejected }
            if code == 429 { throw Failure.quota }
            throw Failure.http(code, String(data: data.prefix(300), encoding: .utf8) ?? "")
        }
        return Transcript(lines: Transcript.lines(from: words(in: data)), model: model)
    }

    /// Timed words from a Scribe response.
    static func words(in data: Data) -> [Transcript.Word] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["words"] as? [[String: Any]] else { return [] }
        return words(from: raw)
    }

    static func words(from raw: [[String: Any]]) -> [Transcript.Word] {
        raw.compactMap { w in
            let type = w["type"] as? String ?? "word"
            guard type == "word" || type == "spacing", let text = w["text"] as? String else { return nil }
            let start = (w["start"] as? Double) ?? 0
            return Transcript.Word(text: text, start: start, end: (w["end"] as? Double) ?? start,
                                   speaker: w["speaker_id"] as? String, isWord: type == "word")
        }
    }

    /// An audio-only copy of a recording (AAC in .m4a), or the file itself if
    /// it's already audio only.
    private static func soundOnly(_ recording: URL) async throws -> URL {
        let asset = AVURLAsset(url: recording)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else { throw Failure.noAudio }
        if try await asset.loadTracks(withMediaType: .video).isEmpty { return recording }

        let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw Failure.noAudio
        }
        try await export.export(to: out, as: .m4a)
        return out
    }
}
