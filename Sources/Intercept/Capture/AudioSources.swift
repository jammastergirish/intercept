import Foundation
import AVFoundation
import CoreAudio
import CoreMedia

// Sound is captured straight from Core Audio, not through ScreenCaptureKit, so
// it keeps going when the screen locks or the display turns off. Every source
// converts what it hears into one format (48 kHz stereo float, interleaved)
// and stamps it with the host clock, the same clock ScreenCaptureKit uses for
// video frames, so the two line up in the file.

/// 48 kHz stereo float, interleaved: the format every audio source delivers.
enum CanonicalAudio {
    static let sampleRate: Double = 48_000
    static let channels = 2

    /// A chunk of canonical audio with its host-clock start time.
    struct Chunk {
        var samples: [Float]          // interleaved L R L R …
        var frames: Int { samples.count / CanonicalAudio.channels }
        let hostTime: UInt64          // mach_absolute_time of the first frame

        var peak: Float {
            var p: Float = 0
            for i in stride(from: 0, to: samples.count, by: 4) { p = max(p, abs(samples[i])) }
            return min(p, 1)
        }
    }

    /// Converts any PCM buffer to canonical stereo at 48 kHz. Mono is copied
    /// to both channels; extra channels beyond two are dropped.
    final class Converter {
        private var converter: AVAudioConverter?
        private var source: AVAudioFormat?
        private var target: AVAudioFormat?

        func convert(_ buffer: AVAudioPCMBuffer) -> [Float]? {
            let fmt = buffer.format
            if source != fmt {
                source = fmt
                target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: CanonicalAudio.sampleRate,
                                       channels: fmt.channelCount, interleaved: false)
                converter = target.flatMap { AVAudioConverter(from: fmt, to: $0) }
            }
            guard let converter, let target else { return nil }

            let ratio = target.sampleRate / fmt.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, let ch = out.floatChannelData else { return nil }

            let n = Int(out.frameLength)
            let left = ch[0]
            let right = out.format.channelCount > 1 ? ch[1] : ch[0]
            var samples = [Float](repeating: 0, count: n * 2)
            for i in 0..<n {
                samples[2 * i] = left[i]
                samples[2 * i + 1] = right[i]
            }
            return samples
        }
    }

    static func format() -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: AVAudioChannelCount(channels), interleaved: true)!
    }
}

/// Turn a Core Audio status code into a readable error.
private func check(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else { throw CaptureError.writerFailed("couldn't \(what) (error \(status))") }
}

// MARK: - The sound the Mac plays

/// Records everything the Mac plays, using a Core Audio process tap on all
/// processes (macOS 14.4+). Needs the "System Audio Recording" permission;
/// macOS asks for it the first time.
final class SystemAudioTap {
    var onChunk: ((CanonicalAudio.Chunk) -> Void)?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var tapFormat: AVAudioFormat?
    private let converter = CanonicalAudio.Converter()
    private let queue = DispatchQueue(label: "intercept.systemaudio", qos: .userInitiated)
    private var outputListener: AudioObjectPropertyListenerBlock?

    func start() throws {
        try build()
        // If you switch speakers or headphones, rebuild on the new device.
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.teardown()
            try? self.build()
        }
        outputListener = listener
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, listener)
    }

    func stop() {
        if let listener = outputListener {
            var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, listener)
            outputListener = nil
        }
        queue.sync { teardown() }
    }

    private func build() throws {
        let tap = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tap.uuid = UUID()
        tap.name = "Intercept"
        tap.isPrivate = true
        tap.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(tap, &tapID), "create the system-audio tap")

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd), "read the tap format")
        tapFormat = AVAudioFormat(streamDescription: &asbd)

        let outputUID = try Self.defaultOutputUID()
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Intercept system audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tap.uuid.uuidString,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID),
                  "create the system-audio device")

        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, inputTime, _, _ in
            self?.handle(input, hostTime: inputTime.pointee.mHostTime)
        }, "listen to system audio")
        try check(AudioDeviceStart(aggregateID, procID), "start system audio")
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func handle(_ input: UnsafePointer<AudioBufferList>, hostTime: UInt64) {
        guard let tapFormat,
              let buffer = AVAudioPCMBuffer(pcmFormat: tapFormat, bufferListNoCopy: input, deallocator: nil),
              buffer.frameLength > 0,
              let samples = converter.convert(buffer) else { return }
        onChunk?(CanonicalAudio.Chunk(samples: samples, hostTime: hostTime))
    }

    private static func defaultOutputUID() throws -> String {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device),
                  "find the output device")
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        addr.mSelector = kAudioDevicePropertyDeviceUID
        try check(AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &uid), "read the output device")
        guard let uid else { throw CaptureError.writerFailed("no output device") }
        return uid.takeRetainedValue() as String
    }
}

// MARK: - The microphone

/// Records the default microphone with AVAudioEngine. Restarts by itself if
/// the input device changes (e.g. AirPods connect).
final class MicrophoneSource {
    var onChunk: ((CanonicalAudio.Chunk) -> Void)?

    private let engine = AVAudioEngine()
    private let converter = CanonicalAudio.Converter()
    private var observer: NSObjectProtocol?

    func start() throws {
        try install()
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.engine.stop()
            self.engine.inputNode.removeTap(onBus: 0)
            try? self.install()
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func install() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.writerFailed("no microphone available")
        }
        input.installTap(onBus: 0, bufferSize: 4800, format: format) { [weak self] buffer, when in
            guard let self, let samples = self.converter.convert(buffer) else { return }
            let host = when.isHostTimeValid ? when.hostTime : mach_absolute_time()
            self.onChunk?(CanonicalAudio.Chunk(samples: samples, hostTime: host))
        }
        engine.prepare()
        try engine.start()
    }
}

// MARK: - Writing a continuous track

/// Appends canonical audio to one writer track at the right place on the
/// recording's timeline. Gaps (a stalled device, the Mac sleeping) are filled
/// with silence, and if a source's clock drifts more than 50 ms from the host
/// clock it is pulled back into line, so sound and video stay in sync over a
/// whole day.
final class AudioTrackWriter {
    let input: AVAssetWriterInput
    private var nextFrame: Int64 = 0                 // frames since the session start
    private let tolerance: Int64 = 2_400             // 50 ms at 48 kHz
    private static let formatDescription: CMAudioFormatDescription = {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: CanonicalAudio.sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                       formatDescriptionOut: &fmt)
        return fmt!
    }()

    init(input: AVAssetWriterInput) { self.input = input }

    /// Call on the capture queue only.
    func append(_ chunk: CanonicalAudio.Chunk, sessionStart: CMTime) {
        let pts = CMClockMakeHostTimeFromSystemUnits(chunk.hostTime)
        let position = Int64(((pts - sessionStart).seconds * CanonicalAudio.sampleRate).rounded())
        var samples = chunk.samples[...]

        if position > nextFrame + tolerance {
            // Something stalled: fill the hole with silence, one second at a time.
            var missing = position - nextFrame
            while missing > 0 {
                let n = Int(min(missing, Int64(CanonicalAudio.sampleRate)))
                write([Float](repeating: 0, count: n * 2)[...], frames: n, sessionStart: sessionStart)
                missing -= Int64(n)
            }
        } else if position < nextFrame - tolerance {
            // The source ran ahead of the host clock: skip what overlaps.
            let skip = Int(min(nextFrame - position, Int64(chunk.frames)))
            samples = samples.dropFirst(skip * 2)
        }
        let frames = samples.count / 2
        if frames > 0 { write(samples, frames: frames, sessionStart: sessionStart) }
    }

    private func write(_ samples: ArraySlice<Float>, frames: Int, sessionStart: CMTime) {
        let pts = sessionStart + CMTime(value: nextFrame, timescale: CMTimeScale(CanonicalAudio.sampleRate))
        nextFrame += Int64(frames)
        guard input.isReadyForMoreMediaData, let sb = Self.sampleBuffer(samples, frames: frames, pts: pts) else { return }
        input.append(sb)
    }

    private static func sampleBuffer(_ samples: ArraySlice<Float>, frames: Int, pts: CMTime) -> CMSampleBuffer? {
        let bytes = frames * 8
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes,
                                                 blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        let ok = samples.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) == noErr
        }
        guard ok else { return nil }
        var sb: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block,
                                                             formatDescription: formatDescription,
                                                             sampleCount: frames, presentationTimeStamp: pts,
                                                             packetDescriptions: nil, sampleBufferOut: &sb)
        return sb
    }
}
