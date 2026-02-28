import Foundation

actor FrameTransmitter {
    private let connection: GroovyConnection
    private let mtu: Int
    private var frameCounter: UInt32 = 0
    private let congestionSize = 500_000
    private let congestionDelay: UInt64 = 11_000_000 // 11ms in nanoseconds
    private var lastFrameWasLarge = false

    init(connection: GroovyConnection, mtu: Int = GroovyProtocol.defaultMTU) {
        self.connection = connection
        self.mtu = mtu
    }

    func sendFrame(rgbData: Data, compressed: CompressionResult, modeline: Modeline, field: UInt8 = 0) async {
        if lastFrameWasLarge {
            try? await Task.sleep(nanoseconds: congestionDelay)
        }

        frameCounter += 1
        let vSync: UInt16 = modeline.vActive

        if compressed.isCompressed {
            let header = GroovyProtocol.buildBlitFieldVsync(
                frame: frameCounter,
                field: field,
                vSync: vSync,
                compressedSize: UInt32(compressed.data.count),
                isDelta: compressed.isDelta
            )
            await connection.send(header)
            await sendChunked(compressed.data)
            lastFrameWasLarge = compressed.data.count > congestionSize
        } else if compressed.data.isEmpty {
            // Duplicate frame
            let header = GroovyProtocol.buildBlitDuplicate(
                frame: frameCounter,
                field: field,
                vSync: vSync
            )
            await connection.send(header)
            lastFrameWasLarge = false
        } else {
            // Raw uncompressed
            let header = GroovyProtocol.buildBlitFieldVsync(
                frame: frameCounter,
                field: field,
                vSync: vSync,
                compressedSize: nil,
                isDelta: false
            )
            await connection.send(header)
            await sendChunked(rgbData)
            lastFrameWasLarge = rgbData.count > congestionSize
        }
    }

    func sendAudio(_ pcmData: Data) async {
        guard !pcmData.isEmpty else { return }
        let size = min(Int(UInt16.max), pcmData.count)
        let header = GroovyProtocol.buildAudio(size: UInt16(size))
        await connection.send(header)
        await sendChunked(pcmData.prefix(size))
    }

    private func sendChunked(_ data: Data) async {
        var offset = 0
        while offset < data.count {
            let end = min(offset + mtu, data.count)
            let chunk = data[offset..<end]
            await connection.send(Data(chunk))
            offset = end
        }
    }

    func reset() {
        frameCounter = 0
        lastFrameWasLarge = false
    }
}
