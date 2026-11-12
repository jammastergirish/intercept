import Foundation

/// Transcribes while you record, with ElevenLabs' realtime Scribe over a
/// WebSocket. The microphone and the Mac's sound are mixed to mono 48 kHz and
/// sent every 100 ms. `ticker` holds the latest words; `lines` the finished
/// ones, with speakers when ElevenLabs reports them. This is the rough,
/// as-you-go version: when recording stops, the whole file is transcribed
/// again properly (`Scribe.transcribe`).
@MainActor
final class LiveTranscriber: ObservableObject {
    @Published private(set) var lines: [Transcript.Line] = []
    @Published private(set) var partial = ""
    @Published private(set) var problem: String?

    /// The tail of what's been said, for the one-line ticker.
    var ticker: String {
        let said = (lines.suffix(4).map(\.text) + [partial]).filter { !$0.isEmpty }.joined(separator: " ")
        return said.count > 220 ? "…" + String(said.suffix(220)) : said
    }

    /// The transcript so far, to save if the full transcription can't be done.
    var transcript: Transcript { Transcript(lines: lines, model: "live") }

    private let started = Date()
    private var socket: URLSessionWebSocketTask?
    private let mixer: Mixer

    init(mic: Bool, macSound: Bool) {
        mixer = Mixer(mic: mic, macSound: macSound)
    }

    func start() {
        guard let key = APIKeyStore.read() else { problem = "Add your ElevenLabs API key."; return }
        var url = URLComponents(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")!
        url.queryItems = [
            .init(name: "model_id", value: "scribe_v2_realtime"),
            .init(name: "audio_format", value: "pcm_48000"),
            .init(name: "commit_strategy", value: "vad"),
            .init(name: "include_timestamps", value: "true"),
            .init(name: "diarize", value: "true"),
        ]
        var request = URLRequest(url: url.url!)
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        let socket = URLSession.shared.webSocketTask(with: request)
        self.socket = socket
        socket.resume()
        receive()
        mixer.onPacket = { [weak socket] base64 in
            let msg = #"{"message_type":"input_audio_chunk","audio_base_64":"\#(base64)","commit":false,"sample_rate":48000}"#
            socket?.send(.string(msg)) { _ in }
        }
        mixer.start()
    }

    /// Hand over sound as it's recorded. Safe to call from any thread.
    nonisolated func feed(_ chunk: CanonicalAudio.Chunk, isMic: Bool) {
        mixer.add(chunk, isMic: isMic)
    }

    /// Stop sending; give ElevenLabs a moment to finish the last words.
    func finish() async {
        mixer.stop()
        let msg = #"{"message_type":"input_audio_chunk","audio_base_64":"","commit":true,"sample_rate":48000}"#
        try? await socket?.send(.string(msg))
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        if !partial.isEmpty { append(partial, words: []) }
        partial = ""
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
    }

    // MARK: Messages from ElevenLabs

    private func receive() {
        socket?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(.string(let text)): self.handle(Data(text.utf8))
                case .success(.data(let data)): self.handle(data)
                case .failure:
                    if self.socket != nil, self.problem == nil { self.problem = "Live transcription disconnected." }
                    return
                @unknown default: break
                }
                self.receive()
            }
        }
    }

    private func handle(_ data: Data) {
        guard let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = msg["message_type"] as? String else { return }
        switch type {
        case "partial_transcript":
            partial = msg["text"] as? String ?? ""
        case "committed_transcript_with_timestamps":
            let words = Scribe.words(from: msg["words"] as? [[String: Any]] ?? [])
            append(msg["text"] as? String ?? "", words: words)
            partial = ""
        case "committed_transcript":
            // Comes before the timestamped version; keep the ticker moving.
            partial = msg["text"] as? String ?? partial
        case "diarized_transcript":
            // Who said a line we already have: the most common speaker in it.
            guard let i = msg["segment_index"] as? Int, lines.indices.contains(i) else { return }
            let speakers = Scribe.words(from: msg["words"] as? [[String: Any]] ?? []).compactMap(\.speaker)
            if let top = Dictionary(grouping: speakers, by: { $0 }).max(by: { $0.value.count < $1.value.count })?.key {
                lines[i].speaker = top
            }
        case "auth_error":
            problem = "ElevenLabs rejected the API key."
        case "quota_exceeded":
            problem = "Your ElevenLabs quota is used up."
        case let t where t.hasSuffix("error"):
            problem = (msg["error"] as? String).map { "Live transcription: \($0)" } ?? "Live transcription failed."
        default:
            break
        }
    }

    private func append(_ text: String, words: [Transcript.Word]) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let now = Date().timeIntervalSince(started)
        let start = words.first(where: \.isWord)?.start ?? max(0, now - 2)
        let end = words.last(where: \.isWord)?.end ?? now
        lines.append(Transcript.Line(id: lines.count, start: start, end: end, speaker: nil, text: t))
    }
}

// MARK: - Mixing mic and Mac sound for streaming

/// Collects the two sources and, every 100 ms, sends what they have in step,
/// mixed to mono 16-bit PCM and base64-encoded. If one source falls more than
/// half a second behind (or stops), it's treated as silence.
private final class Mixer: @unchecked Sendable {
    var onPacket: ((String) -> Void)?

    private let lock = NSLock()
    private var mic: [Float] = []
    private var sys: [Float] = []
    private let useMic: Bool
    private let useSys: Bool
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "intercept.livemix")

    init(mic: Bool, macSound: Bool) {
        useMic = mic
        useSys = macSound
    }

    func add(_ chunk: CanonicalAudio.Chunk, isMic: Bool) {
        // Canonical audio is interleaved stereo; average to mono.
        var mono = [Float](repeating: 0, count: chunk.frames)
        for i in 0..<chunk.frames { mono[i] = (chunk.samples[2 * i] + chunk.samples[2 * i + 1]) * 0.5 }
        lock.withLock {
            if isMic { mic += mono } else { sys += mono }
            // Never hold more than 5 s if nothing is being sent.
            if mic.count > 240_000 { mic.removeFirst(mic.count - 240_000) }
            if sys.count > 240_000 { sys.removeFirst(sys.count - 240_000) }
        }
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.1, repeating: 0.1)
        t.setEventHandler { [weak self] in self?.flush() }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func flush() {
        let lag = 24_000   // 0.5 s at 48 kHz
        let (a, b): ([Float], [Float]) = lock.withLock {
            var counts: [Int] = []
            if useMic { counts.append(mic.count) }
            if useSys { counts.append(sys.count) }
            guard let most = counts.max(), let least = counts.min() else { return ([], []) }
            let n = max(least, most - lag)
            guard n > 0 else { return ([], []) }
            let a = Array(mic.prefix(n)); mic.removeFirst(min(n, mic.count))
            let b = Array(sys.prefix(n)); sys.removeFirst(min(n, sys.count))
            return (a, b)
        }
        let n = max(a.count, b.count)
        guard n > 0 else { return }
        var pcm = Data(count: n * 2)
        pcm.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Int16.self)
            for i in 0..<n {
                let v = (i < a.count ? a[i] : 0) + (i < b.count ? b[i] : 0)
                out[i] = Int16(max(-1, min(1, v)) * 32767).littleEndian
            }
        }
        onPacket?(pcm.base64EncodedString())
    }
}
