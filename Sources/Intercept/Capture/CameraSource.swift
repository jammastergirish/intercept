import Foundation
import AVFoundation
import CoreMedia

/// Records a camera (built-in, external or iPhone via Continuity Camera) and
/// hands each frame to `onFrame`. Frames come as BGRA pixel buffers so the
/// compositor can paste them straight onto the canvas.
final class CameraSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onFrame: ((CVPixelBuffer) -> Void)?

    private let session = AVCaptureSession()
    private let deviceID: String?
    private let queue = DispatchQueue(label: "intercept.camera", qos: .userInitiated)

    /// Picture size in pixels, known after `start`.
    private(set) var size: CGSize = CGSize(width: 1920, height: 1080)

    init(deviceID: String?) {
        self.deviceID = deviceID
    }

    func start() throws {
        guard let device = deviceID.flatMap(AVCaptureDevice.init(uniqueID:)) ?? AVCaptureDevice.default(for: .video) else {
            throw CaptureError.writerFailed("no camera found")
        }
        session.beginConfiguration()
        session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CaptureError.writerFailed("can't use \(device.localizedName)") }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw CaptureError.writerFailed("can't read \(device.localizedName)") }
        session.addOutput(output)
        session.commitConfiguration()

        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        if dims.width > 0, dims.height > 0 {
            size = CGSize(width: Int(dims.width) & ~1, height: Int(dims.height) & ~1)
        }
        session.startRunning()
    }

    func stop() {
        session.stopRunning()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pb = sampleBuffer.imageBuffer else { return }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        if w > 0, h > 0, CGSize(width: w, height: h) != size { size = CGSize(width: w & ~1, height: h & ~1) }
        onFrame?(pb)
    }
}
