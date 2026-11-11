import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import CoreImage

enum RecordingMode: String, CaseIterable, Identifiable {
    case screenOnly        // the screen, no sound
    case audio             // mic + system sound
    case screen            // the screen plus mic + system sound ("screen" kept for saved settings)

    var id: String { rawValue }
    var title: String {
        switch self {
        case .screenOnly: return "Screen"
        case .audio: return "Audio"
        case .screen: return "Screen + Audio"
        }
    }
    var hasVideo: Bool { self != .audio }
    var hasAudio: Bool { self != .screenOnly }
    var fileExtension: String { hasVideo ? "mp4" : "m4a" }
    var fileType: AVFileType { hasVideo ? .mp4 : .m4a }
}

/// Which displays a screen recording covers.
enum DisplayChoice: String, CaseIterable, Identifiable {
    case main   // the display with the menu bar
    case all    // every distinct display, side by side in one video

    var id: String { rawValue }
}

enum CaptureError: LocalizedError {
    case noDisplay
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "No display found to record."
        case .writerFailed(let msg): return "Couldn't write the recording: \(msg)"
        }
    }
}

enum Displays {
    /// Active displays that show their own picture. A display that mirrors
    /// another one is left out, because the other one already has its picture.
    static func distinctIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let distinct = ids.prefix(Int(count)).filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
        let main = CGMainDisplayID()
        return distinct.sorted { a, _ in a == main }
    }
}

/// One recording. ScreenCaptureKit delivers the screen, the sound the Mac
/// plays ("out") and the microphone ("in") on one clock. We write them into a
/// temporary .mov with one video track and two audio tracks; `Mixdown` later
/// merges the two audio tracks into one.
///
/// Recording several displays: each display gets its own stream, and a 30 fps
/// timer pastes the latest frame from each one onto a single canvas laid out
/// like System Settings › Displays.
final class CaptureSession: NSObject, SCStreamOutput, SCStreamDelegate {
    let mode: RecordingMode
    let displayChoice: DisplayChoice
    let rawURL: URL
    /// Test hook: also record displays that mirror another one.
    var includeMirrors = false
    /// Test hook: record the main display twice, side by side, to exercise
    /// multi-display compositing on a machine with one display.
    var duplicateMainForTest = false

    /// Called (on the capture queue) if the system stops a stream, e.g. the
    /// user clicked "Stop" in the macOS screen-recording menu.
    var onUnexpectedStop: ((Error?) -> Void)?

    /// How many displays the recording covers (known after `start`).
    private(set) var displayCount = 0
    private(set) var videoSize: CGSize = .zero

    private var streams: [SCStream] = []
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var systemInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?

    private let queue = DispatchQueue(label: "intercept.capture", qos: .userInitiated)
    private var sessionStart: CMTime = .invalid
    private var lastTime: CMTime = .invalid
    private var stopping = false

    // Multi-display compositing (used only when recording more than one display).
    private var compositing = false
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    // Keyed by stream index (0 = main display).
    private var streamIndex: [ObjectIdentifier: Int] = [:]
    private var placement: [Int: CGRect] = [:]   // canvas pixels, origin bottom-left
    private var latestFrame: [Int: CVPixelBuffer] = [:]
    private var frameDirty = false
    private var compositeTimer: DispatchSourceTimer?
    private lazy var ciContext = CIContext(options: [.cacheIntermediates: false])

    // Live peak levels (0...1), read by the UI.
    private let levelLock = NSLock()
    private var _inLevel: Float = 0
    private var _outLevel: Float = 0

    init(mode: RecordingMode, displays: DisplayChoice = .main, rawURL: URL) {
        self.mode = mode
        self.displayChoice = displays
        self.rawURL = rawURL
    }

    /// Returns the latest input (mic) and output (system) peaks and resets them.
    func takeLevels() -> (input: Float, output: Float) {
        levelLock.lock(); defer { levelLock.unlock() }
        let r = (_inLevel, _outLevel)
        _inLevel = 0; _outLevel = 0
        return r
    }

    // MARK: Start

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let mainDisplay = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                ?? content.displays.first else { throw CaptureError.noDisplay }

        // Pick the displays to record.
        var targets = [mainDisplay]
        if mode.hasVideo && displayChoice == .all {
            let others = content.displays.filter { d in
                d.displayID != mainDisplay.displayID &&
                (includeMirrors || CGDisplayMirrorsDisplay(d.displayID) == kCGNullDirectDisplay)
            }
            targets += others
            if duplicateMainForTest { targets.append(mainDisplay) }
        }
        compositing = mode.hasVideo && targets.count > 1
        displayCount = mode.hasVideo ? targets.count : 0

        // Work out the video size and, when compositing, where each display goes.
        var streamSizes: [Int: (Int, Int)] = [:]
        if mode.hasVideo {
            if compositing {
                var bounds = targets.map { CGDisplayBounds($0.displayID) }
                if duplicateMainForTest, let first = bounds.first {
                    // Pretend the copy sits to the right of the original.
                    bounds[bounds.count - 1] = first.offsetBy(dx: first.width, dy: 0)
                }
                let union = bounds.reduce(CGRect.null) { $0.union($1) }
                let maxScale = targets.map { CGFloat(SCContentFilter(display: $0, excludingWindows: []).pointPixelScale) }.max() ?? 1
                // Keep the canvas inside what the hardware HEVC encoder handles.
                let scale = min(maxScale, 7680 / union.width, 4320 / union.height)
                let canvasW = Int(union.width * scale) & ~1
                let canvasH = Int(union.height * scale) & ~1
                videoSize = CGSize(width: canvasW, height: canvasH)
                for (i, b) in bounds.enumerated() {
                    let w = Int(b.width * scale) & ~1
                    let h = Int(b.height * scale) & ~1
                    let x = (b.minX - union.minX) * scale
                    let yFromTop = (b.minY - union.minY) * scale
                    placement[i] = CGRect(x: x, y: CGFloat(canvasH) - yFromTop - CGFloat(h),
                                                    width: CGFloat(w), height: CGFloat(h))
                    streamSizes[i] = (w, h)
                }
            } else {
                let filter = SCContentFilter(display: mainDisplay, excludingWindows: [])
                let scale = CGFloat(filter.pointPixelScale)
                let w = Int(filter.contentRect.width * scale) & ~1     // encoders want even sizes
                let h = Int(filter.contentRect.height * scale) & ~1
                videoSize = CGSize(width: w, height: h)
                streamSizes[0] = (w, h)
            }
        }

        // Writer for the temporary multi-track file.
        try? FileManager.default.removeItem(at: rawURL)
        let writer = try AVAssetWriter(outputURL: rawURL, fileType: .mov)
        // Crash safety: save a small table of contents every 10 s, so if the
        // app dies the file still plays up to the last 10-second mark.
        // `Recovery` turns such leftovers into normal recordings at next launch.
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)

        if mode.hasVideo {
            let w = Int(videoSize.width), h = Int(videoSize.height)
            let bitrate = max(8_000_000, w * h * 4)   // ~4 bits/pixel/s, generous for text
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: w,
                AVVideoHeightKey: h,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitrate,
                    AVVideoExpectedSourceFrameRateKey: 30,
                    AVVideoMaxKeyFrameIntervalKey: 60,
                ],
            ]
            let vi = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            vi.expectsMediaDataInRealTime = true
            writer.add(vi)
            videoInput = vi
            if compositing {
                adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vi, sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: w,
                    kCVPixelBufferHeightKey as String: h,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                ])
            }
        }

        // Lossless PCM for the intermediate audio tracks.
        let pcm: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        if mode.hasAudio {
            let si = AVAssetWriterInput(mediaType: .audio, outputSettings: pcm)
            si.expectsMediaDataInRealTime = true
            writer.add(si)
            systemInput = si

            let mi = AVAssetWriterInput(mediaType: .audio, outputSettings: pcm)
            mi.expectsMediaDataInRealTime = true
            writer.add(mi)
            micInput = mi
        }

        guard writer.startWriting() else {
            throw CaptureError.writerFailed(writer.error?.localizedDescription ?? "unknown error")
        }
        self.writer = writer

        // One stream per display. Only the first (main display) carries audio,
        // and only in modes that record sound.
        for (i, display) in targets.enumerated() {
            let config = SCStreamConfiguration()
            if i == 0 && mode.hasAudio {
                config.capturesAudio = true
                config.captureMicrophone = true
                config.excludesCurrentProcessAudio = true
                config.sampleRate = 48_000
                config.channelCount = 2
            }
            if mode.hasVideo, let (w, h) = streamSizes[i] {
                config.width = w
                config.height = h
                config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                config.showsCursor = true
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.queueDepth = 6
            } else {
                // Audio only: ScreenCaptureKit still needs a video size, so ask
                // for a tiny, slow one and throw the frames away.
                config.width = 2
                config.height = 2
                config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                config.showsCursor = false
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            if i == 0 && mode.hasAudio {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
                try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
            }
            streamIndex[ObjectIdentifier(stream)] = i
            streams.append(stream)
        }

        do {
            for stream in streams { try await stream.startCapture() }
        } catch {
            for stream in streams { try? await stream.stopCapture() }
            writer.cancelWriting()
            throw error
        }

        if compositing { startCompositeTimer() }
    }

    // MARK: Stop

    /// Stops capture and finishes the temporary file. Returns its URL.
    func stop() async throws -> URL {
        for stream in streams { try? await stream.stopCapture() }
        streams = []
        return try await finishWriting()
    }

    private func finishWriting() async throws -> URL {
        // Hop onto the capture queue so no sample is appended mid-finish.
        let writer: AVAssetWriter? = await withCheckedContinuation { cont in
            queue.async {
                self.stopping = true
                self.compositeTimer?.cancel()
                self.compositeTimer = nil
                self.latestFrame = [:]
                cont.resume(returning: self.writer)
            }
        }
        guard let writer else { throw CaptureError.writerFailed("recording never started") }
        guard writer.status == .writing else {
            throw CaptureError.writerFailed(writer.error?.localizedDescription ?? "no audio or video arrived")
        }
        if !sessionStart.isValid {
            writer.cancelWriting()
            throw CaptureError.writerFailed("no audio or video arrived")
        }
        videoInput?.markAsFinished()
        systemInput?.markAsFinished()
        micInput?.markAsFinished()
        if lastTime.isValid { writer.endSession(atSourceTime: lastTime) }
        await writer.finishWriting()
        if writer.status != .completed {
            throw CaptureError.writerFailed(writer.error?.localizedDescription ?? "unknown error")
        }
        return rawURL
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !stopping, sb.isValid, let writer, writer.status == .writing else { return }
        let pts = sb.presentationTimeStamp

        switch type {
        case .screen:
            guard mode.hasVideo, let vi = videoInput, Self.isCompleteFrame(sb) else { return }
            if compositing {
                // Keep the newest frame per display; the timer draws the canvas.
                if let id = streamIndex[ObjectIdentifier(stream)], let pb = sb.imageBuffer {
                    latestFrame[id] = pb
                    frameDirty = true
                }
                return
            }
            startSessionIfNeeded(at: pts, writer: writer)
            guard pts >= sessionStart else { return }
            if vi.isReadyForMoreMediaData { vi.append(sb) }
            noteTime(pts)

        case .audio, .microphone:
            let peak = Self.peak(of: sb)
            levelLock.lock()
            if type == .audio { _outLevel = max(_outLevel, peak) } else { _inLevel = max(_inLevel, peak) }
            levelLock.unlock()

            // In screen mode the file starts at the first video frame.
            if mode == .audio { startSessionIfNeeded(at: pts, writer: writer) }
            guard sessionStart.isValid, pts >= sessionStart else { return }
            let input = (type == .audio) ? systemInput : micInput
            if let input, input.isReadyForMoreMediaData { input.append(sb) }
            noteTime(CMTimeAdd(pts, sb.duration))

        @unknown default:
            return
        }
    }

    private func startSessionIfNeeded(at pts: CMTime, writer: AVAssetWriter) {
        guard !sessionStart.isValid else { return }
        writer.startSession(atSourceTime: pts)
        sessionStart = pts
    }

    private func noteTime(_ t: CMTime) {
        if !lastTime.isValid || t > lastTime { lastTime = t }
    }

    // MARK: Compositing several displays

    private func startCompositeTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / 30), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.drawComposite() }
        compositeTimer = timer
        timer.resume()
    }

    private func drawComposite() {
        guard !stopping, frameDirty, let writer, writer.status == .writing,
              let adaptor, let vi = videoInput, let pool = adaptor.pixelBufferPool else { return }
        // Wait until every display has sent a picture, so the video doesn't
        // open with a black gap where a display should be.
        guard latestFrame.count == placement.count || sessionStart.isValid else { return }

        // ScreenCaptureKit stamps samples with the host clock, so "now" on that
        // clock lines the composite frames up with the audio.
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let out else { return }

        let canvas = CGRect(origin: .zero, size: videoSize)
        var image = CIImage(color: .black).cropped(to: canvas)
        for (id, pb) in latestFrame {
            guard let r = placement[id] else { continue }
            var frame = CIImage(cvPixelBuffer: pb)
            let sx = r.width / frame.extent.width, sy = r.height / frame.extent.height
            if abs(sx - 1) > 0.001 || abs(sy - 1) > 0.001 {
                frame = frame.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            }
            frame = frame.transformed(by: CGAffineTransform(translationX: r.minX, y: r.minY))
            image = frame.composited(over: image)
        }
        ciContext.render(image, to: out, bounds: canvas, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))

        startSessionIfNeeded(at: now, writer: writer)
        if vi.isReadyForMoreMediaData, adaptor.append(out, withPresentationTime: now) {
            frameDirty = false
            noteTime(now)
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onUnexpectedStop?(error)
    }

    // MARK: Helpers

    /// ScreenCaptureKit sends "idle" buffers with no image when nothing changed.
    private static func isCompleteFrame(_ sb: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }

    /// Peak absolute sample value in an audio buffer (float or 16-bit PCM).
    private static func peak(of sb: CMSampleBuffer) -> Float {
        guard let fmt = sb.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee else { return 0 }

        var sizeNeeded = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: &sizeNeeded, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard sizeNeeded > 0 else { return 0 }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: sizeNeeded, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: sizeNeeded,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &block) == noErr else { return 0 }

        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        var peak: Float = 0
        for buf in UnsafeMutableAudioBufferListPointer(list) {
            guard let data = buf.mData else { continue }
            if isFloat && asbd.mBitsPerChannel == 32 {
                let n = Int(buf.mDataByteSize) / 4
                let p = data.bindMemory(to: Float.self, capacity: n)
                for i in stride(from: 0, to: n, by: 4) { peak = max(peak, abs(p[i])) }
            } else if asbd.mBitsPerChannel == 16 {
                let n = Int(buf.mDataByteSize) / 2
                let p = data.bindMemory(to: Int16.self, capacity: n)
                for i in stride(from: 0, to: n, by: 4) { peak = max(peak, abs(Float(p[i]) / 32768)) }
            }
        }
        return min(peak, 1)
    }
}
