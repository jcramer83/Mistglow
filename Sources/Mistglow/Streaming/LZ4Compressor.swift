import Foundation
import CLZ4

struct CompressionResult {
    let data: Data
    let isDelta: Bool
    let isCompressed: Bool
}

final class LZ4Compressor {
    private static let adaptiveThreshold = 600_000
    private var previousFrame: Data?

    func compress(frame: Data, rawSize: Int) -> CompressionResult {
        let maxCompressedSize = Int(LZ4_compressBound(Int32(frame.count)))
        guard maxCompressedSize > 0 else {
            return CompressionResult(data: frame, isDelta: false, isCompressed: false)
        }

        // Step 1: LZ4 standard compress
        var compressed = Data(count: maxCompressedSize)
        let compressedSize = frame.withUnsafeBytes { srcPtr in
            compressed.withUnsafeMutableBytes { dstPtr in
                LZ4_compress_default(
                    srcPtr.baseAddress?.assumingMemoryBound(to: CChar.self),
                    dstPtr.baseAddress?.assumingMemoryBound(to: CChar.self),
                    Int32(frame.count),
                    Int32(maxCompressedSize)
                )
            }
        }

        guard compressedSize > 0 else {
            return CompressionResult(data: frame, isDelta: false, isCompressed: false)
        }

        var bestData = compressed.prefix(Int(compressedSize))
        var bestIsDelta = false

        // Step 2: Try delta compression if we have a previous frame
        if let prev = previousFrame, prev.count == frame.count {
            let matchBytes = countMatchingBytes(frame, prev)
            let ratioMatch = Double(matchBytes) / Double(rawSize)
            let ratioLZ4 = Double(compressedSize) / Double(rawSize)

            if ratioLZ4 > 0.05 && ratioMatch > 0.20 && ratioMatch > (0.9 - ratioLZ4) {
                let delta = computeDelta(frame, prev)
                let deltaMaxSize = Int(LZ4_compressBound(Int32(delta.count)))
                var deltaCompressed = Data(count: deltaMaxSize)
                let deltaSize = delta.withUnsafeBytes { srcPtr in
                    deltaCompressed.withUnsafeMutableBytes { dstPtr in
                        LZ4_compress_default(
                            srcPtr.baseAddress?.assumingMemoryBound(to: CChar.self),
                            dstPtr.baseAddress?.assumingMemoryBound(to: CChar.self),
                            Int32(delta.count),
                            Int32(deltaMaxSize)
                        )
                    }
                }

                if deltaSize > 0 {
                    let ratioDelta = Double(deltaSize) / Double(compressedSize)
                    if ratioDelta < 0.95 {
                        bestData = deltaCompressed.prefix(Int(deltaSize))
                        bestIsDelta = true
                    }
                }
            }
        }

        // Step 3: If compressed > 600KB, try LZ4 HC
        if bestData.count > Self.adaptiveThreshold {
            let sourceData = bestIsDelta ? computeDelta(frame, previousFrame!) : frame
            var hcCompressed = Data(count: maxCompressedSize)
            let hcSize = sourceData.withUnsafeBytes { srcPtr in
                hcCompressed.withUnsafeMutableBytes { dstPtr in
                    LZ4_compress_HC(
                        srcPtr.baseAddress?.assumingMemoryBound(to: CChar.self),
                        dstPtr.baseAddress?.assumingMemoryBound(to: CChar.self),
                        Int32(sourceData.count),
                        Int32(maxCompressedSize),
                        0 // LZ4HC_CLEVEL_DEFAULT
                    )
                }
            }
            if hcSize > 0 && hcSize < Int32(bestData.count) {
                bestData = hcCompressed.prefix(Int(hcSize))
            }
        }

        // Step 4: If compressed > raw, send raw
        if bestData.count >= frame.count {
            previousFrame = frame
            return CompressionResult(data: frame, isDelta: false, isCompressed: false)
        }

        previousFrame = frame
        return CompressionResult(data: Data(bestData), isDelta: bestIsDelta, isCompressed: true)
    }

    func isDuplicateFrame(_ frame: Data) -> Bool {
        guard let prev = previousFrame else { return false }
        return frame == prev
    }

    func reset() {
        previousFrame = nil
    }

    private func countMatchingBytes(_ a: Data, _ b: Data) -> Int {
        let count = min(a.count, b.count)
        var matches = 0
        a.withUnsafeBytes { aPtr in
            b.withUnsafeBytes { bPtr in
                let aBytes = aPtr.bindMemory(to: UInt8.self)
                let bBytes = bPtr.bindMemory(to: UInt8.self)
                for i in 0..<count {
                    if aBytes[i] == bBytes[i] { matches += 1 }
                }
            }
        }
        return matches
    }

    private func computeDelta(_ current: Data, _ previous: Data) -> Data {
        let count = min(current.count, previous.count)
        var delta = Data(count: count)
        current.withUnsafeBytes { curPtr in
            previous.withUnsafeBytes { prevPtr in
                delta.withUnsafeMutableBytes { dstPtr in
                    let cur = curPtr.bindMemory(to: UInt8.self)
                    let prev = prevPtr.bindMemory(to: UInt8.self)
                    let dst = dstPtr.bindMemory(to: UInt8.self)
                    for i in 0..<count {
                        dst[i] = cur[i] ^ prev[i]
                    }
                }
            }
        }
        return delta
    }
}
