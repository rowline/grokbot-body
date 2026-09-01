@preconcurrency import AVFoundation
import CoreImage
import Foundation

final class FrameGrabber: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let ciContext = CIContext()
    private let lock = NSLock()
    private var latestJPEG: Data?
    private let targetWidth: CGFloat = 480
    private var lastEncode: TimeInterval = 0

    var jpegData: Data? {
        lock.lock()
        defer { lock.unlock() }
        return latestJPEG
    }

    var jpegBase64: String? {
        jpegData?.base64EncodedString()
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = Date().timeIntervalSince1970
        if now - lastEncode < 0.5 { return }
        lastEncode = now
        guard let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        var ci = CIImage(cvPixelBuffer: pixel)
        let width = ci.extent.width
        if width > targetWidth {
            let scale = targetWidth / width
            ci = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        guard let jpeg = ciContext.jpegRepresentation(
            of: ci,
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            options: [:]
        ) else { return }
        lock.lock()
        latestJPEG = jpeg
        lock.unlock()
    }
}
