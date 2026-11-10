import Foundation
import AVFoundation

/// Turns the temporary capture file (video + system-audio track + mic track)
/// into the final file: the video is copied as-is, and both audio tracks are
/// mixed into one AAC track so every player hears both sides.
enum Mixdown {

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
            let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
            ])
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

        await withTaskGroup(of: Void.self) { group in
            for (i, pair) in pairs.enumerated() {
                group.addTask { await pump(from: pair.0, into: pair.1, label: "intercept.mixdown.\(i)") }
            }
        }

        if reader.status == .failed {
            writer.cancelWriting()
            throw CaptureError.writerFailed(reader.error?.localizedDescription ?? "read failed")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw CaptureError.writerFailed(writer.error?.localizedDescription ?? "write failed")
        }
    }

    private static func pump(from output: AVAssetReaderOutput, into input: AVAssetWriterInput, label: String) async {
        let queue = DispatchQueue(label: label)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            var done = false
            input.requestMediaDataWhenReady(on: queue) {
                guard !done else { return }
                while input.isReadyForMoreMediaData {
                    guard let sb = output.copyNextSampleBuffer(), input.append(sb) else {
                        done = true
                        input.markAsFinished()
                        cont.resume()
                        return
                    }
                }
            }
        }
    }
}
