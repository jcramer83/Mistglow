import Foundation
import CoreMedia
import CoreVideo
import CoreGraphics

final class FrameProcessor: Sendable {
    struct Config: Sendable {
        let outputWidth: Int
        let outputHeight: Int
        let rotation: Rotation
        let alignment: Alignment
        let cropWidth: Int
        let cropHeight: Int
        let cropOffsetX: Int
        let cropOffsetY: Int
    }

    static func processFrame(_ sampleBuffer: CMSampleBuffer, config: Config) -> (rgb: Data, preview: CGImage?)? {
        guard let pixelBuffer = sampleBuffer.imageBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let srcWidth = CVPixelBufferGetWidth(pixelBuffer)
        let srcHeight = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let srcPtr = baseAddress.assumingMemoryBound(to: UInt8.self)

        // Compute crop region
        let cropX = clamp(config.cropOffsetX, 0, max(0, srcWidth - config.cropWidth))
        let cropY = clamp(config.cropOffsetY, 0, max(0, srcHeight - config.cropHeight))
        let cropW = min(config.cropWidth, srcWidth - cropX)
        let cropH = min(config.cropHeight, srcHeight - cropY)

        // Scale to output size
        let outW = config.outputWidth
        let outH = config.outputHeight
        var rgb = Data(count: outW * outH * 3)

        rgb.withUnsafeMutableBytes { dstPtr in
            let dst = dstPtr.bindMemory(to: UInt8.self)
            for y in 0..<outH {
                let srcY = cropY + (y * cropH) / outH
                for x in 0..<outW {
                    let srcX = cropX + (x * cropW) / outW

                    // Apply rotation to source coordinates
                    let (finalX, finalY) = applyRotation(x: srcX, y: srcY, width: srcWidth, height: srcHeight, rotation: config.rotation)

                    let srcOffset = finalY * bytesPerRow + finalX * 4
                    let dstOffset = (y * outW + x) * 3

                    if srcOffset + 3 < srcHeight * bytesPerRow && dstOffset + 2 < outW * outH * 3 {
                        // BGRA → RGB
                        dst[dstOffset] = srcPtr[srcOffset + 2]     // R
                        dst[dstOffset + 1] = srcPtr[srcOffset + 1] // G
                        dst[dstOffset + 2] = srcPtr[srcOffset]     // B
                    }
                }
            }
        }

        // Generate preview CGImage
        let preview = createPreviewImage(from: rgb, width: outW, height: outH)

        return (rgb, preview)
    }

    private static func applyRotation(x: Int, y: Int, width: Int, height: Int, rotation: Rotation) -> (Int, Int) {
        switch rotation {
        case .none:
            return (x, y)
        case .cw90:
            return (height - 1 - y, x)
        case .ccw90:
            return (y, width - 1 - x)
        case .rotate180:
            return (width - 1 - x, height - 1 - y)
        }
    }

    private static func clamp(_ value: Int, _ low: Int, _ high: Int) -> Int {
        max(low, min(high, value))
    }

    static func createPreviewImage(from rgb: Data, width: Int, height: Int) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: rgb as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 24,
            bytesPerRow: width * 3,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
