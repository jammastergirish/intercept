import Foundation
import GraphiteEmber

/// A recording's transcript: timed lines, each tagged with who spoke (when
/// ElevenLabs could tell voices apart), plus the names you've given speakers.
/// Saved next to the recording as `<name>.transcript.json`.
struct Transcript: Codable, Equatable {
    struct Line: Codable, Equatable, Identifiable {
        var id: Int
        var start: Double          // seconds from the start of the recording
        var end: Double
        var speaker: String?       // e.g. "speaker_0"
        var text: String
    }

    var lines: [Line]
    /// Names you've typed for speakers ("speaker_0" → "Girish").
    var speakerNames: [String: String] = [:]
    /// "scribe_v2", "scribe_v1", or "live" (the rough version made while recording).
    var model: String
    var createdAt = Date()

    var isLive: Bool { model == "live" }

    // MARK: Speakers

    /// Speakers in the order they first speak.
    var speakers: [String] {
        var seen: [String] = []
        for l in lines { if let s = l.speaker, !seen.contains(s) { seen.append(s) } }
        return seen
    }

    /// More than one voice: worth showing names and colours.
    var hasSeveralSpeakers: Bool { speakers.count > 1 }

    /// Your name for a speaker, else "Speaker N" by order of first appearance.
    func name(of speaker: String) -> String {
        if let n = speakerNames[speaker], !n.isEmpty { return n }
        return "Speaker \((speakers.firstIndex(of: speaker) ?? 0) + 1)"
    }

    /// Where this speaker sits in the colour palette.
    func colorIndex(of speaker: String) -> Int { speakers.firstIndex(of: speaker) ?? 0 }

    // MARK: File next to the recording

    static func fileURL(for recording: URL) -> URL {
        recording.deletingPathExtension().appendingPathExtension("transcript.json")
    }

    static func exists(for recording: URL) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: recording).path)
    }

    static func load(for recording: URL) -> Transcript? {
        guard let data = try? Data(contentsOf: fileURL(for: recording)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Transcript.self, from: data)
    }

    func save(for recording: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: Self.fileURL(for: recording), options: .atomic)
    }

    // MARK: Building lines from timed words

    /// One timed word (or the space between words) from ElevenLabs.
    struct Word {
        let text: String
        let start: Double
        let end: Double
        let speaker: String?
        let isWord: Bool          // false for spacing
    }

    /// Group words into lines: a new line when the speaker changes, after a
    /// pause of 2 s or more, or at the end of a sentence once a line is past 30 s.
    static func lines(from words: [Word]) -> [Line] {
        var lines: [Line] = []
        var text = "", start = 0.0, end = 0.0
        var speaker: String?

        func flush() {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { lines.append(Line(id: lines.count, start: start, end: end, speaker: speaker, text: t)) }
            text = ""
        }

        for w in words {
            guard w.isWord else {
                if !text.isEmpty { text += w.text }
                continue
            }
            let startsNew = text.isEmpty
                || w.speaker != speaker
                || w.start - end >= 2
                || (end - start > 30 && [".", "?", "!"].contains(text.trimmingCharacters(in: .whitespaces).last.map(String.init) ?? ""))
            if startsNew {
                flush()
                start = w.start
                speaker = w.speaker
            }
            text += w.text
            end = w.end
        }
        flush()
        return lines
    }

    /// Plain text: "[m:ss] Name: words", one line per turn.
    var plainText: String {
        lines.map { l in
            let who = hasSeveralSpeakers ? l.speaker.map { "\(name(of: $0)): " } ?? "" : ""
            return "[\(Format.length(l.start))] \(who)\(l.text)"
        }.joined(separator: "\n")
    }
}
