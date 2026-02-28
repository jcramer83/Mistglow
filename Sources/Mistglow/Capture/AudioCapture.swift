import Foundation
import CoreMedia
import AVFoundation

final class AudioCapture: Sendable {
    /// Convert audio samples to interleaved Int16 PCM for the Groovy protocol
    static func convertToInt16PCM(_ sampleBuffer: CMSampleBuffer) -> Data? {
        guard let formatDesc = sampleBuffer.formatDescription else { return nil }
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        guard let asbd else { return nil }

        let sampleRate = asbd.pointee.mSampleRate
        let channels = asbd.pointee.mChannelsPerFrame
        let bitsPerChannel = asbd.pointee.mBitsPerChannel
        let isFloat = (asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (asbd.pointee.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0

        guard let blockBuffer = sampleBuffer.dataBuffer else { return nil }

        var length = 0
        var dataPointer: UnsafeMutablePointer<CChar>?
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
        guard status == kCMBlockBufferNoErr, let ptr = dataPointer, length > 0 else { return nil }

        // Already Int16 interleaved - pass through
        if bitsPerChannel == 16 && !isFloat && !isNonInterleaved {
            return Data(bytes: ptr, count: length)
        }

        // Float32 conversion
        if isFloat && bitsPerChannel == 32 {
            let framesPerChannel = length / (Int(channels) * MemoryLayout<Float32>.size)

            if isNonInterleaved {
                // Non-interleaved: [L0,L1,L2,...,R0,R1,R2,...]
                // Convert to interleaved: [L0,R0,L1,R1,...]
                let floatPtr = UnsafeRawPointer(ptr).bindMemory(to: Float32.self, capacity: length / 4)
                var pcmData = Data(count: framesPerChannel * Int(channels) * MemoryLayout<Int16>.size)
                pcmData.withUnsafeMutableBytes { dstBuf in
                    let dst = dstBuf.bindMemory(to: Int16.self)
                    for frame in 0..<framesPerChannel {
                        for ch in 0..<Int(channels) {
                            let srcIdx = ch * framesPerChannel + frame
                            let dstIdx = frame * Int(channels) + ch
                            let sample = max(-1.0, min(1.0, floatPtr[srcIdx]))
                            dst[dstIdx] = Int16(sample * Float32(Int16.max))
                        }
                    }
                }
                return pcmData
            } else {
                // Already interleaved Float32
                let floatCount = length / MemoryLayout<Float32>.size
                let floatPtr = UnsafeRawPointer(ptr).bindMemory(to: Float32.self, capacity: floatCount)
                var pcmData = Data(count: floatCount * MemoryLayout<Int16>.size)
                pcmData.withUnsafeMutableBytes { dstBuf in
                    let dst = dstBuf.bindMemory(to: Int16.self)
                    for i in 0..<floatCount {
                        let sample = max(-1.0, min(1.0, floatPtr[i]))
                        dst[i] = Int16(sample * Float32(Int16.max))
                    }
                }
                return pcmData
            }
        }

        return nil
    }

    /// Log the audio format (call once for debugging)
    static func describeFormat(_ sampleBuffer: CMSampleBuffer) -> String {
        guard let formatDesc = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return "unknown"
        }
        let isFloat = (asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (asbd.pointee.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        return "\(Int(asbd.pointee.mSampleRate))Hz \(asbd.pointee.mChannelsPerFrame)ch \(asbd.pointee.mBitsPerChannel)bit \(isFloat ? "float" : "int") \(isNonInterleaved ? "non-interleaved" : "interleaved")"
    }
}
