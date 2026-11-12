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

/// One recording, written to a temporary .mov that `Mixdown` later turns
/// into the final file.
///
/// - Sound comes straight from Core Audio (`SystemAudioTap` for what the Mac
///   plays, `MicrophoneSource` for the mic), so it never stops when the screen
///   locks or the display turns off. Each goes to its own track.
/// - The screen comes from ScreenCaptureKit. When macOS takes the display away
///   (it turned off), the video holds its last picture and Intercept keeps
///   trying to reconnect; once the display is back, video carries on in the
///   same file.
/// - Several displays: each gets its own stream, and a 30 fps timer pastes the
///   latest frame from each onto one canvas laid out like System Settings.
final class CaptureSession: NSObject, SCStreamOutput, SCStreamDelegate {
    let mode: RecordingMode
    let displayChoice: DisplayChoice
    let rawURL: URL
    /// Test hook: also record displays that mirror another one.
    var includeMirrors = false
    /// Test hook: record the main display twice, side by side, to exercise
    /// multi-display compositing on a machine with one display.
    var duplicateMainForTest = false

    /// Called if you stop sharing from macOS's own screen-recording menu.
    var onUserStopped: (() -> Void)?

    /// How many displays the recording covers (known after `start`).
    private(set) var displayCount = 0
    private(set) var videoSize: CGSize = .zero
    /// How many times the display went away during this recording (for tests).
    private(set) var videoInterruptions = 0

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var systemTrack: AudioTrackWriter?
    private var micTrack: AudioTrackWriter?
    private var systemSource: SystemAudioTap?
    private var micSource: MicrophoneSource?

    private let queue = DispatchQueue(label: "intercept.capture", qos: .userInitiated)
    private var sessionStart: CMTime = .invalid
    private var lastVideoTime: CMTime = .invalid
    private var stopping = false

    // Screen capture. Everything below is touched on `queue` only.
    private var targetIDs: [CGDirectDisplayID] = []      // index = stream index
    private var streamSizes: [Int: (Int, Int)] = [:]
    private var streams: [SCStream] = []
    private var streamIndex: [ObjectIdentifier: Int] = [:]
    private var videoLost = false
    private var reconnecting = false
    private var reconnectTimer: DispatchSourceTimer?

    // Multi-display compositing.
    private var compositing = false
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var placement: [Int: CGRect] = [:]   // canvas pixels, origin bottom-left
    private var latestFrame: [Int: CVPixelBuffer] = [:]
    private var frameDirty = false
    private var drewComposite = false
    private var compositeTimer: DispatchSourceTimer?
    private lazy var ciContext = CIContext(options: [.cacheIntermediates: false])

    // Shared with the UI thread.
    private let lock = NSLock()
    private var _inLevel: Float = 0
    private var _outLevel: Float = 0
    private var _videoPaused = false

    init(mode: RecordingMode, displays: DisplayChoice = .main, rawURL: URL) {
        self.mode = mode
        self.displayChoice = displays
        self.rawURL = rawURL
    }

    /// Returns the latest input (mic) and output (system) peaks and resets them.
    func takeLevels() -> (input: Float, output: Float) {
        lock.withLock {
            let r = (_inLevel, _outLevel)
            _inLevel = 0; _outLevel = 0
            return r
        }
    }

    /// True while the display is off and only sound is being recorded.
    var isVideoPaused: Bool { lock.withLock { _videoPaused } }

    // MARK: Start

    func start() async throws {
        var content: SCShareableContent?
        if mode.hasVideo {
            let c = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            content = c
            try planVideo(c)
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
            let vi = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: w,
                AVVideoHeightKey: h,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitrate,
                    AVVideoExpectedSourceFrameRateKey: 30,
                    AVVideoMaxKeyFrameIntervalKey: 60,
                    // Frames in display order (no B-frames): suits live
                    // encoding, and lets the last picture be held to the end.
                    AVVideoAllowFrameReorderingKey: false,
                ],
            ])
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

        if mode.hasAudio {
            func track() -> AudioTrackWriter {
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: Mixdown.pcmSettings)
                input.expectsMediaDataInRealTime = true
                writer.add(input)
                return AudioTrackWriter(input: input)
            }
            systemTrack = track()
            micTrack = track()
        }

        guard writer.startWriting() else {
            throw CaptureError.writerFailed(writer.error?.localizedDescription ?? "unknown error")
        }
        self.writer = writer

        do {
            // Start the sound first: the first time, macOS may hold this up
            // while it asks for permission. The file's clock starts only once
            // that's done (host clock, the same one video frames use).
            if mode.hasAudio { try startAudio() }
            queue.sync {
                sessionStart = CMClockGetTime(CMClockGetHostTimeClock())
                writer.startSession(atSourceTime: sessionStart)
            }
            if let content { try await startVideoStreams(content) }
        } catch {
            stopAudio()
            writer.cancelWriting()
            throw error
        }
        if compositing { startCompositeTimer() }
    }

    /// Decide which displays to record, the video size, and (for several
    /// displays) where each one sits on the canvas.
    private func planVideo(_ content: SCShareableContent) throws {
        guard let mainDisplay = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                ?? content.displays.first else { throw CaptureError.noDisplay }

        var targets = [mainDisplay]
        if displayChoice == .all {
            targets += content.displays.filter { d in
                d.displayID != mainDisplay.displayID &&
                (includeMirrors || CGDisplayMirrorsDisplay(d.displayID) == kCGNullDirectDisplay)
            }
            if duplicateMainForTest { targets.append(mainDisplay) }
        }
        targetIDs = targets.map(\.displayID)
        compositing = targets.count > 1
        displayCount = targets.count

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

    // MARK: Sound

    private func startAudio() throws {
        let system = SystemAudioTap()
        system.onChunk = { [weak self] chunk in self?.queue.async { self?.write(chunk, isMic: false) } }
        let mic = MicrophoneSource()
        mic.onChunk = { [weak self] chunk in self?.queue.async { self?.write(chunk, isMic: true) } }
        try system.start()
        try mic.start()
        systemSource = system
        micSource = mic
    }

    private func stopAudio() {
        systemSource?.stop(); systemSource = nil
        micSource?.stop(); micSource = nil
    }

    private func write(_ chunk: CanonicalAudio.Chunk, isMic: Bool) {
        let peak = chunk.peak
        lock.withLock {
            if isMic { _inLevel = max(_inLevel, peak) } else { _outLevel = max(_outLevel, peak) }
        }
        guard !stopping, sessionStart.isValid, writer?.status == .writing else { return }
        (isMic ? micTrack : systemTrack)?.append(chunk, sessionStart: sessionStart)
    }

    // MARK: Screen

    /// Start one stream per display we're recording. Used at the start and to
    /// reconnect after the display comes back.
    private func startVideoStreams(_ content: SCShareableContent) async throws {
        var newStreams: [SCStream] = []
        var newIndex: [ObjectIdentifier: Int] = [:]
        for (i, id) in targetIDs.enumerated() {
            guard let display = content.displays.first(where: { $0.displayID == id }),
                  let (w, h) = streamSizes[i] else { continue }
            let config = SCStreamConfiguration()
            config.width = w
            config.height = h
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            config.showsCursor = true
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.queueDepth = 6
            let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                                  configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            newIndex[ObjectIdentifier(stream)] = i
            newStreams.append(stream)
        }
        guard !newStreams.isEmpty else { throw CaptureError.noDisplay }
        do {
            for stream in newStreams { try await stream.startCapture() }
        } catch {
            for stream in newStreams { try? await stream.stopCapture() }
            throw error
        }
        queue.sync {
            streams = newStreams
            streamIndex = newIndex
        }
    }

    /// The display went away: keep recording sound and try to reconnect the
    /// screen every few seconds. Runs on `queue`.
    private func videoWentAway() {
        guard !stopping, !videoLost else { return }
        videoLost = true
        videoInterruptions += 1
        lock.withLock { _videoPaused = true }
        streams = []
        streamIndex = [:]

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 3, repeating: 3)
        timer.setEventHandler { [weak self] in self?.tryReconnect() }
        reconnectTimer = timer
        timer.resume()
    }

    private func tryReconnect() {
        guard !stopping, videoLost, !reconnecting else { return }
        reconnecting = true
        Task {
            var ok = false
            if let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) {
                ok = (try? await startVideoStreams(content)) != nil
            }
            queue.async {
                self.reconnecting = false
                guard ok else { return }
                self.videoLost = false
                self.reconnectTimer?.cancel()
                self.reconnectTimer = nil
                self.lock.withLock { self._videoPaused = false }
            }
        }
    }

    // MARK: Stop

    /// Stops capture and finishes the temporary file. Returns its URL.
    func stop() async throws -> URL {
        let current: [SCStream] = queue.sync {
            stopping = true
            reconnectTimer?.cancel(); reconnectTimer = nil
            compositeTimer?.cancel(); compositeTimer = nil
            return streams
        }
        for stream in current { try? await stream.stopCapture() }
        stopAudio()
        return try await finishWriting()
    }

    private func finishWriting() async throws -> URL {
        // Hop onto the capture queue so nothing is appended mid-finish.
        let writer: AVAssetWriter? = await withCheckedContinuation { cont in
            queue.async {
                self.streams = []
                self.latestFrame = [:]
                cont.resume(returning: self.writer)
            }
        }
        guard let writer, writer.status == .writing else {
            throw CaptureError.writerFailed(writer?.error?.localizedDescription ?? "recording never started")
        }
        videoInput?.markAsFinished()
        systemTrack?.input.markAsFinished()
        micTrack?.input.markAsFinished()
        // Run the file right up to the moment you pressed stop, so a still
        // screen's last picture lasts until the end.
        writer.endSession(atSourceTime: CMClockGetTime(CMClockGetHostTimeClock()))
        await writer.finishWriting()
        if writer.status != .completed {
            throw CaptureError.writerFailed(writer.error?.localizedDescription ?? "nothing was recorded")
        }
        return rawURL
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !stopping, sb.isValid, let writer, writer.status == .writing,
              let vi = videoInput, Self.isCompleteFrame(sb) else { return }
        if compositing {
            // Keep the newest frame per display; the timer draws the canvas.
            if let i = streamIndex[ObjectIdentifier(stream)], let pb = sb.imageBuffer {
                latestFrame[i] = pb
                frameDirty = true
            }
            return
        }
        let pts = sb.presentationTimeStamp
        guard pts >= sessionStart, !lastVideoTime.isValid || pts > lastVideoTime else { return }
        if vi.isReadyForMoreMediaData, vi.append(sb) { lastVideoTime = pts }
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
        guard drewComposite || latestFrame.count == placement.count else { return }

        // ScreenCaptureKit stamps frames with the host clock, so "now" on that
        // clock lines the composite frames up with the sound.
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let out else { return }

        let canvas = CGRect(origin: .zero, size: videoSize)
        var image = CIImage(color: .black).cropped(to: canvas)
        for (i, pb) in latestFrame {
            guard let r = placement[i] else { continue }
            var frame = CIImage(cvPixelBuffer: pb)
            let sx = r.width / frame.extent.width, sy = r.height / frame.extent.height
            if abs(sx - 1) > 0.001 || abs(sy - 1) > 0.001 {
                frame = frame.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            }
            frame = frame.transformed(by: CGAffineTransform(translationX: r.minX, y: r.minY))
            image = frame.composited(over: image)
        }
        ciContext.render(image, to: out, bounds: canvas, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))

        if vi.isReadyForMoreMediaData, adaptor.append(out, withPresentationTime: now) {
            frameDirty = false
            drewComposite = true
            lastVideoTime = now
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let ns = error as NSError
        if ns.domain == SCStreamErrorDomain && ns.code == SCStreamError.Code.userStopped.rawValue {
            onUserStopped?()
        } else {
            queue.async { self.videoWentAway() }
        }
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
}
