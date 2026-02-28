import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo

protocol ScreenCaptureDelegate: AnyObject, Sendable {
    func didCaptureVideoFrame(_ sampleBuffer: CMSampleBuffer)
    func didCaptureAudioFrame(_ sampleBuffer: CMSampleBuffer)
}

final class ScreenCapture: NSObject, @unchecked Sendable {
    private var stream: SCStream?
    private var display: SCDisplay?
    weak var delegate: ScreenCaptureDelegate?
    private let streamQueue = DispatchQueue(label: "com.mistglow.capture", qos: .userInteractive)

    /// Check if screen recording permission is granted
    static func hasPermission() async -> Bool {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            return !content.displays.isEmpty
        } catch {
            return false
        }
    }

    /// Request permission by triggering the system prompt
    static func requestPermission() async throws -> SCShareableContent {
        // This call triggers the macOS permission dialog if not yet granted
        return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    func start(displayIndex: Int, cropWidth: Int, cropHeight: Int, audioEnabled: Bool) async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw NSError(domain: "Mistglow", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Screen Recording permission denied. Go to System Settings > Privacy & Security > Screen Recording and enable Mistglow, then restart."
            ])
        }

        guard !content.displays.isEmpty else {
            throw NSError(domain: "Mistglow", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "No displays found. Grant Screen Recording permission in System Settings."
            ])
        }

        let idx = min(displayIndex, content.displays.count - 1)
        display = content.displays[idx]
        guard let display else { return }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = cropWidth
        config.height = cropHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 3
        config.showsCursor = false

        if audioEnabled {
            config.capturesAudio = true
            config.sampleRate = 48000
            config.channelCount = 2
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: streamQueue)
        if audioEnabled {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: streamQueue)
        }

        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }
}

extension ScreenCapture: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen:
            delegate?.didCaptureVideoFrame(sampleBuffer)
        case .audio:
            delegate?.didCaptureAudioFrame(sampleBuffer)
        case .microphone:
            break
        @unknown default:
            break
        }
    }
}
