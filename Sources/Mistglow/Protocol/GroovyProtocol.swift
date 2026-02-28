import Foundation

enum GroovyCommand: UInt8 {
    case close = 0x01
    case `init` = 0x02
    case switchres = 0x03
    case audio = 0x04
    case getStatus = 0x05
    case blitVsync = 0x06
    case blitFieldVsync = 0x07
    case getVersion = 0x08
}

enum GroovyProtocol {
    static let udpPort: UInt16 = 32100
    static let mtuHeader: Int = 28
    static let defaultMTU: Int = 1472
    static let bufferSize: Int = 1_245_312
    static let maxSlices: Int = 846
    static let socketSendBuffer: Int = 2_097_152

    // MARK: - Command Builders

    static func buildInit(compression: UInt8 = 1, sampleRate: UInt8 = 3, channels: UInt8 = 2, rgbMode: UInt8 = 0) -> Data {
        var data = Data(count: 5)
        data[0] = GroovyCommand.`init`.rawValue
        data[1] = compression
        data[2] = sampleRate
        data[3] = channels
        data[4] = rgbMode
        return data
    }

    static func buildSwitchres(_ modeline: Modeline) -> Data {
        var data = Data(count: 26)
        data[0] = GroovyCommand.switchres.rawValue
        withUnsafeBytes(of: modeline.pClock) { bytes in
            data.replaceSubrange(1..<9, with: bytes)
        }
        withUnsafeBytes(of: modeline.hActive.littleEndian) { data.replaceSubrange(9..<11, with: $0) }
        withUnsafeBytes(of: modeline.hBegin.littleEndian) { data.replaceSubrange(11..<13, with: $0) }
        withUnsafeBytes(of: modeline.hEnd.littleEndian) { data.replaceSubrange(13..<15, with: $0) }
        withUnsafeBytes(of: modeline.hTotal.littleEndian) { data.replaceSubrange(15..<17, with: $0) }
        withUnsafeBytes(of: modeline.vActive.littleEndian) { data.replaceSubrange(17..<19, with: $0) }
        withUnsafeBytes(of: modeline.vBegin.littleEndian) { data.replaceSubrange(19..<21, with: $0) }
        withUnsafeBytes(of: modeline.vEnd.littleEndian) { data.replaceSubrange(21..<23, with: $0) }
        withUnsafeBytes(of: modeline.vTotal.littleEndian) { data.replaceSubrange(23..<25, with: $0) }
        data[25] = modeline.interlace ? 1 : 0
        return data
    }

    static func buildBlitFieldVsync(frame: UInt32, field: UInt8, vSync: UInt16, compressedSize: UInt32?, isDelta: Bool) -> Data {
        if let cSize = compressedSize {
            if isDelta {
                var data = Data(count: 13)
                data[0] = GroovyCommand.blitFieldVsync.rawValue
                withUnsafeBytes(of: frame.littleEndian) { data.replaceSubrange(1..<5, with: $0) }
                data[5] = field
                withUnsafeBytes(of: vSync.littleEndian) { data.replaceSubrange(6..<8, with: $0) }
                withUnsafeBytes(of: cSize.littleEndian) { data.replaceSubrange(8..<12, with: $0) }
                data[12] = 0x01
                return data
            } else {
                var data = Data(count: 12)
                data[0] = GroovyCommand.blitFieldVsync.rawValue
                withUnsafeBytes(of: frame.littleEndian) { data.replaceSubrange(1..<5, with: $0) }
                data[5] = field
                withUnsafeBytes(of: vSync.littleEndian) { data.replaceSubrange(6..<8, with: $0) }
                withUnsafeBytes(of: cSize.littleEndian) { data.replaceSubrange(8..<12, with: $0) }
                return data
            }
        } else {
            var data = Data(count: 8)
            data[0] = GroovyCommand.blitFieldVsync.rawValue
            withUnsafeBytes(of: frame.littleEndian) { data.replaceSubrange(1..<5, with: $0) }
            data[5] = field
            withUnsafeBytes(of: vSync.littleEndian) { data.replaceSubrange(6..<8, with: $0) }
            return data
        }
    }

    static func buildBlitDuplicate(frame: UInt32, field: UInt8, vSync: UInt16) -> Data {
        var data = Data(count: 9)
        data[0] = GroovyCommand.blitFieldVsync.rawValue
        withUnsafeBytes(of: frame.littleEndian) { data.replaceSubrange(1..<5, with: $0) }
        data[5] = field
        withUnsafeBytes(of: vSync.littleEndian) { data.replaceSubrange(6..<8, with: $0) }
        data[8] = 0x01
        return data
    }

    static func buildAudio(size: UInt16) -> Data {
        var data = Data(count: 3)
        data[0] = GroovyCommand.audio.rawValue
        withUnsafeBytes(of: size.littleEndian) { data.replaceSubrange(1..<3, with: $0) }
        return data
    }

    static func buildGetStatus() -> Data {
        Data([GroovyCommand.getStatus.rawValue])
    }

    static func buildClose() -> Data {
        Data([GroovyCommand.close.rawValue])
    }

    static func buildGetVersion() -> Data {
        Data([GroovyCommand.getVersion.rawValue])
    }

    // MARK: - Status Parser

    static func parseStatus(_ data: Data) -> FPGAStatus? {
        guard data.count >= 13 else { return nil }
        let bytes = [UInt8](data)
        var status = FPGAStatus()

        status.frameEcho = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        status.vCountEcho = UInt16(bytes[4]) | UInt16(bytes[5]) << 8
        status.frame = UInt32(bytes[6]) | UInt32(bytes[7]) << 8 | UInt32(bytes[8]) << 16 | UInt32(bytes[9]) << 24
        status.vCount = UInt16(bytes[10]) | UInt16(bytes[11]) << 8

        let bits = bytes[12]
        status.vramReady = (bits & 0x01) != 0
        status.vramEndFrame = (bits & 0x02) != 0
        status.vramSynced = (bits & 0x04) != 0
        status.vgaFrameskip = (bits & 0x08) != 0
        status.vgaVblank = (bits & 0x10) != 0
        status.vgaF1 = (bits & 0x20) != 0
        status.audio = (bits & 0x40) != 0
        status.vramQueue = (bits & 0x80) != 0

        return status
    }
}
