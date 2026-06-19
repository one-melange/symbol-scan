import ScreenCaptureKit
import AppKit

@MainActor
class ScreenCapture: NSObject {

    /// Captures the entire main display (excluding our overlay window).
    /// Returns a CGImage you can feed into OCREngine.
    func captureMainDisplay(excluding excludedWindows: [SCWindow] = []) async throws -> CGImage? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard let display = content.displays.first else { return nil }

        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)

        let config = SCStreamConfiguration()
        config.width  = Int(display.frame.width)
        config.height = Int(display.frame.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // single frame
        config.queueDepth = 1
        config.showsCursor = false

        // Use SCScreenshotManager for a one-shot capture (macOS 14.0+)
        if #available(macOS 14.0, *) {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        }

        // Fallback: spin up a stream, grab one frame, tear it down
        return try await captureOneFrame(filter: filter, config: config)
    }

    // MARK: - Single-frame stream fallback

    private func captureOneFrame(filter: SCContentFilter, config: SCStreamConfiguration) async throws -> CGImage? {
        return try await withCheckedThrowingContinuation { continuation in
            let delegate = SingleFrameDelegate(continuation: continuation)
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            do {
                try stream.addStreamOutput(delegate, type: .screen, sampleHandlerQueue: .global())
                stream.startCapture()
                delegate.stream = stream
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

// MARK: - Single frame delegate

private class SingleFrameDelegate: NSObject, SCStreamOutput {
    var stream: SCStream?
    private let continuation: CheckedContinuation<CGImage?, Error>
    private var didResume = false

    init(continuation: CheckedContinuation<CGImage?, Error>) {
        self.continuation = continuation
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !didResume, type == .screen else { return }
        didResume = true

        let image = imageFromSampleBuffer(buffer)
        stream.stopCapture()
        continuation.resume(returning: image)
    }

    private func imageFromSampleBuffer(_ buffer: CMSampleBuffer) -> CGImage? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else { return nil }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        return context.createCGImage(ciImage, from: ciImage.extent)
    }
}
