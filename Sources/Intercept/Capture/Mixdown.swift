import Foundation
import AVFoundation

/// Turns the temporary capture file (video + system-audio track + mic track)
/// into the final file: the video is copied as-is, and both audio tracks are
/// mixed into one AAC track so every player hears both sides.
enum Mixdown {

    /// Uncompressed 48 kHz stereo float audio: the capture file's audio
    /// tracks, and what the mixer outputs before AAC encoding.
    static let pcmSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false,
        AVLinearPCMIsBigEndianKey: false,
    ]

    /// Turn a capture file into the final recording at `out` and delete the
    /// capture. If mixing fails, keep the capture instead, renamed to
    /// `<out name>.mov` (separate mic and system tracks), so nothing is lost.
    /// Returns where the recording ended up and the mixing error, if any.
    static func finish(raw: URL, to out: URL, fileType: AVFileType) async -> (url: URL, error: Error?) {
        do {
            try await run(raw: raw, to: out, fileType: fileType)
            try? FileManager.default.removeItem(at: raw)
            return (out, nil)
        } catch {
            try? FileManager.default.removeItem(at: out)
            let keep = out.deletingPathExtension().appendingPathExtension("mov").uniqued()
            try? FileManager.default.moveItem(at: raw, to: keep)
            return (keep, error)
        }
    }

    static func run(raw: URL, to out: URL, fileType: AVFileType) async throws {
        let asset = AVURLAsset(url: raw)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)

        let reader = try AVAssetReader(asset: asset)
        try? FileManager.default.removeItem(at: out)
        let writer = try AVAssetWriter(outputURL: out, fileType: fileType)

        var pairs: [(AVAssetReaderOutput, AVAssetWriterInput)] = []

        if let vt = videoTracks.first {
            let output = AVAssetReaderTrackOutput(track: vt, outputSettings: nil)   // no re-encode
            output.alwaysCopiesSampleData = false
            reader.add(output)
            let hint = try await vt.load(.formatDescriptions).first
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: hint)
            input.transform = try await vt.load(.preferredTransform)
            writer.add(input)
            pairs.append((output, input))
        }

        if !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: pcmSettings)
            reader.add(output)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 256_000,
            ])
            writer.add(input)
            pairs.append((output, input))
        }

        guard reader.startReading() else {
            throw CaptureError.writerFailed(reader.error?.localizedDescription ?? "couldn't read capture")
        }
        guard writer.startWriting() else {
            throw CaptureError.writerFailed(writer.error?.localizedDescription ?? "couldn't write file")
        }
        writer.startSession(atSourceTime: .zero)
        let end = try await asset.load(.duration)

        await withTaskGroup(of: Void.self) { group in
            for (i, pair) in pairs.enumerated() {
                // Stretch the last video frame to the end of the recording, so
                // if the display was off at the end the picture holds instead
                // of the video stopping early.
                let stretchTo: CMTime? = pair.1.mediaType == .video ? end : nil
                group.addTask {
                    await pump(from: pair.0, into: pair.1, stretchLastTo: stretchTo, label: "intercept.mixdown.\(i)")
                }
            }
        }

        if reader.status == .failed {
            writer.cancelWriting()
            throw CaptureError.writerFailed(reader.error?.localizedDescription ?? "read failed")
        }
        writer.endSession(atSourceTime: end)
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw CaptureError.writerFailed(writer.error?.localizedDescription ?? "write failed")
        }
    }

    /// Copy samples from `output` to `input`. With `stretchLastTo`, the last
    /// sample is held back and its duration extended to reach that time.
    private static func pump(from output: AVAssetReaderOutput, into input: AVAssetWriterInput,
                             stretchLastTo end: CMTime?, label: String) async {
        let queue = DispatchQueue(label: label)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            var done = false
            var held: CMSampleBuffer?
            func finish() {
                done = true
                input.markAsFinished()
                cont.resume()
            }
            input.requestMediaDataWhenReady(on: queue) {
                guard !done else { return }
                while input.isReadyForMoreMediaData {
                    guard let next = output.copyNextSampleBuffer() else {
                        // Out of samples: write the held one, stretched.
                        if let last = held {
                            held = nil
                            _ = input.append(stretched(last, to: end) ?? last)
                            continue
                        }
                        return finish()
                    }
                    // Pass through as-is when not stretching, and for empty
                    // marker buffers, which carry no picture to hold.
                    guard end != nil, CMSampleBufferGetNumSamples(next) > 0 else {
                        if !input.append(next) { return finish() }
                        continue
                    }
                    if let prev = held, !input.append(prev) { return finish() }
                    held = next
                }
            }
        }
    }

    /// A copy of `sb` whose duration runs to `end`, if that makes it longer.
    private static func stretched(_ sb: CMSampleBuffer, to end: CMTime?) -> CMSampleBuffer? {
        guard let end else { return nil }
        let pts = sb.presentationTimeStamp
        let wanted = end - pts
        guard wanted.isValid, wanted > sb.duration || !sb.duration.isValid else { return nil }
        var timing = CMSampleTimingInfo(duration: wanted, presentationTimeStamp: pts,
                                        decodeTimeStamp: sb.decodeTimeStamp)
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: 1,
                                              sampleTimingArray: &timing, sampleBufferOut: &out)
        return out
    }
}
