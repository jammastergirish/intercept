import Foundation
import AVFoundation
import CoreAudio

/// What one recording captures. Any combination of screen, audio and camera.
struct CaptureSettings: Equatable {
    var screen = true
    var audio = true
    var camera = false

    /// Screen: the main display, or every distinct display side by side.
    var displays: DisplayChoice = .main
    /// Audio: which microphone (nil = the system default), and whether to
    /// record it at all; and whether to record the sound the Mac plays.
    var useMic = true
    var micID: String?
    var macSound = true
    /// Camera: which one (nil = the system default).
    var cameraID: String?
    /// Transcribe the sound with ElevenLabs, with speakers, once it stops.
    var transcribe = false

    var hasVideo: Bool { screen || camera }
    var recordsMic: Bool { audio && useMic }
    var recordsMacSound: Bool { audio && macSound }
    var hasAudio: Bool { recordsMic || recordsMacSound }
    var isEmpty: Bool { !hasVideo && !hasAudio }

    var fileExtension: String { hasVideo ? "mp4" : "m4a" }
    var fileType: AVFileType { hasVideo ? .mp4 : .m4a }

    /// "Screen + Audio + Camera", "Audio", …
    var summary: String {
        [screen ? "Screen" : nil, hasAudio ? "Audio" : nil, camera ? "Camera" : nil]
            .compactMap { $0 }.joined(separator: " + ")
    }
}

/// Which displays a screen recording covers.
enum DisplayChoice: String, CaseIterable, Identifiable {
    case main   // the display with the menu bar
    case all    // every distinct display, side by side in one video

    var id: String { rawValue }
}

/// A microphone or camera the user can pick.
struct CaptureDevice: Identifiable, Hashable {
    let id: String      // AVCaptureDevice.uniqueID (for mics, also the Core Audio UID)
    let name: String
}

enum CaptureDevices {
    static func microphones() -> [CaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio,
                                         position: .unspecified)
            .devices.map { CaptureDevice(id: $0.uniqueID, name: $0.localizedName) }
    }

    static func cameras() -> [CaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                         mediaType: .video, position: .unspecified)
            .devices.map { CaptureDevice(id: $0.uniqueID, name: $0.localizedName) }
    }

    static var defaultMicName: String? { AVCaptureDevice.default(for: .audio)?.localizedName }
    static var defaultCameraName: String? { AVCaptureDevice.default(for: .video)?.localizedName }

    /// The Core Audio device for a microphone's UID, so AVAudioEngine can use it.
    static func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        var device = AudioDeviceID(kAudioObjectUnknown)
        var cfUID = uid as CFString
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let status = withUnsafeMutablePointer(to: &cfUID) { ptr in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(MemoryLayout<CFString>.size), ptr, &size, &device)
        }
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }
}
