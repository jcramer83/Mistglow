import Foundation
import CoreGraphics
import ScreenCaptureKit
import CoreMedia
import CoreImage

final class PreviewCapture: @unchecked Sendable {
    private let appState: AppState
    private var timer: DispatchSourceTimer?
    private var frameCount = 0
    private var scStream: SCStream?
    private var streamHandler: StreamHandler?
    private let ciContext = CIContext()
    private let captureQueue = DispatchQueue(label: "com.mistglow.preview", qos: .userInitiated)

    init(appState: AppState) {
        self.appState = appState
    }

    func start() async {
        let settings = await MainActor.run { appState.settings }

        // Try ScreenCaptureKit first
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if !content.displays.isEmpty {
                let idx = min(settings.displayIndex, content.displays.count - 1)
                let display = content.displays[idx]
                await appState.log("Preview: display \(idx + 1) (\(display.width)x\(display.height))")
                await startSCKCapture(display: display)
                return
            }
        } catch {
            await appState.log("SCK unavailable, using CGDisplay fallback: \(error.localizedDescription)")
        }

        // Fallback: CGDisplayCreateImage timer
        await startCGCapture(displayIndex: settings.displayIndex)
    }

    private func startSCKCapture(display: SCDisplay) async {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 10)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 2
        config.showsCursor = true

        let handler = StreamHandler(appState: appState, ciContext: ciContext, frameCounter: { [weak self] in
            self?.frameCount += 1
            return self?.frameCount ?? 0
        })
        self.streamHandler = handler

        do {
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream.addStreamOutput(handler, type: .screen, sampleHandlerQueue: captureQueue)
            try await stream.startCapture()
            self.scStream = stream
            await appState.log("Preview running (ScreenCaptureKit)")
        } catch {
            await appState.logError("SCK capture failed: \(error.localizedDescription)")
            // Fall back to CG
            await startCGCapture(displayIndex: 0)
        }
    }

    private func startCGCapture(displayIndex: Int) async {
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        CGGetActiveDisplayList(8, &displayIDs, &count)

        guard count > 0 else {
            await appState.logError("No displays found")
            await MainActor.run { appState.isPreviewing = false }
            return
        }

        let idx = min(displayIndex, Int(count) - 1)
        let displayID = displayIDs[idx]
        await appState.log("Preview running (CGDisplay fallback)")

        let source = DispatchSource.makeTimerSource(queue: captureQueue)
        source.schedule(deadline: .now(), repeating: .milliseconds(100)) // 10fps
        source.setEventHandler { [weak self] in
            guard let self else { return }
            guard let cgImage = CGDisplayCreateImage(displayID) else { return }
            self.frameCount += 1
            DispatchQueue.main.async {
                self.appState.previewImage = cgImage
                if self.frameCount == 1 {
                    self.appState.log("Preview: first frame (\(cgImage.width)x\(cgImage.height))")
                }
            }
        }
        source.resume()
        self.timer = source
    }

    func stop() async {
        timer?.cancel()
        timer = nil
        if let stream = scStream {
            try? await stream.stopCapture()
            scStream = nil
        }
        await appState.log("Preview stopped (\(frameCount) frames)")
    }
}

// Separate class for SCStreamOutput conformance
private final class StreamHandler: NSObject, SCStreamOutput, @unchecked Sendable {
    private let appState: AppState
    private let ciContext: CIContext
    private let frameCounter: () -> Int
    private var logged = false

    init(appState: AppState, ciContext: CIContext, frameCounter: @escaping () -> Int) {
        self.appState = appState
        self.ciContext = ciContext
        self.frameCounter = frameCounter
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        guard let cgImage = ciContext.createCGImage(ciImage, from: CGRect(x: 0, y: 0, width: width, height: height)) else {
            return
        }

        let count = frameCounter()

        DispatchQueue.main.async { [weak self] in
            self?.appState.previewImage = cgImage
            if count == 1 {
                self?.appState.log("Preview: receiving frames (\(width)x\(height))")
            }
        }
    }
}
