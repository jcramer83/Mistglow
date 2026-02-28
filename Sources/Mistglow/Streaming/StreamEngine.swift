import Foundation
import CoreGraphics
import ScreenCaptureKit
import CoreMedia
import CoreImage

final class StreamEngine: NSObject, @unchecked Sendable {
    private let appState: AppState
    private var connection: GroovyConnection?
    private var isRunning = false
    private var captureTimer: DispatchSourceTimer?
    private var frameCount: UInt32 = 0
    private var currentField: UInt8 = 0
    private let sendQueue = DispatchQueue(label: "com.mistglow.stream", qos: .userInteractive)
    private var isSending = false

    // Audio
    private var scStream: SCStream?
    private var audioEnabled = false
    private let audioQueue = DispatchQueue(label: "com.mistglow.audio", qos: .userInteractive)
    private var pendingAudio: Data?
    private let audioLock = NSLock()
    private var audioFormatLogged = false

    // Interlaced: cache fields from one capture
    private var cachedField1: Data?

    init(appState: AppState) {
        self.appState = appState
    }

    func start() async {
        let settings = await MainActor.run { appState.settings }
        let m = settings.modeline
        self.audioEnabled = settings.audioEnabled

        // Connect
        let conn = GroovyConnection(host: settings.targetIP)
        do {
            try await conn.connect()
        } catch {
            await appState.logError("Connection failed: \(error.localizedDescription)")
            await MainActor.run { appState.isStreaming = false }
            return
        }
        self.connection = conn
        await appState.log("Connected to \(settings.targetIP)")

        // INIT
        let initPacket = GroovyProtocol.buildInit(
            compression: 0,
            sampleRate: audioEnabled ? 3 : 0,
            channels: 2,
            rgbMode: 0
        )
        conn.sendSync(initPacket)
        await appState.log("INIT: compression=RAW, audio=\(audioEnabled ? "48kHz" : "off")")
        try? await Task.sleep(nanoseconds: 200_000_000)

        // SWITCHRES
        let switchresPacket = GroovyProtocol.buildSwitchres(m)
        conn.sendSync(switchresPacket)
        await appState.log("SWITCHRES: \(Int(m.hActive))x\(Int(m.vActive))\(m.interlace ? "i" : "p") @ \(String(format: "%.2f", m.pClock))MHz")
        try? await Task.sleep(nanoseconds: 500_000_000)

        self.isRunning = true
        self.frameCount = 0

        // Output dimensions - field height for interlaced
        let fieldH = m.interlace ? Int(m.vActive) / 2 : Int(m.vActive)
        let outW = Int(m.hActive)
        let fullH = Int(m.vActive) // Full frame height (for interlaced capture)

        if m.interlace {
            await appState.log("Output: \(outW)x\(fullH) -> \(outW)x\(fieldH) per field, \(outW * fieldH * 3) bytes/field")
        } else {
            await appState.log("Output: \(outW)x\(fieldH), \(outW * fieldH * 3) bytes/frame")
        }

        // Start audio capture via ScreenCaptureKit if enabled
        if audioEnabled {
            await startAudioCapture(displayIndex: settings.displayIndex)
        }

        // Get display for capture
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 8)
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(8, &displayIDs, &displayCount)
        guard displayCount > 0 else {
            await appState.logError("No displays")
            await stop()
            return
        }

        let displayID = displayIDs[min(settings.displayIndex, Int(displayCount) - 1)]
        let modeline = m
        // For interlaced, vTotal covers both fields, so fps = frame rate (~30).
        // We need to send fields at 2x that rate (~60fps).
        let frameRate = Double(m.pClock) * 1_000_000.0 / (Double(m.hTotal) * Double(m.vTotal))
        let fieldRate = m.interlace ? frameRate * 2.0 : frameRate
        let intervalMs = max(8, Int(1000.0 / fieldRate))
        await appState.log("Capture: \(String(format: "%.1f", fieldRate)) \(m.interlace ? "fields" : "fps")/s, \(intervalMs)ms interval")

        let cropW = settings.cropWidth
        let cropH = settings.cropHeight
        let cropX = settings.cropOffsetX
        let cropY = settings.cropOffsetY
        let rotation = settings.rotation
        if cropW > 0 && cropH > 0 {
            await appState.log("Crop: \(cropW)x\(cropH) at (\(cropX),\(cropY)), rotation=\(rotation.displayName)")
        }

        // Start capture+send loop
        let isInterlaced = m.interlace
        let timer = DispatchSource.makeTimerSource(queue: sendQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(intervalMs))
        timer.setEventHandler { [weak self] in
            self?.captureAndSend(
                displayID: displayID, modeline: modeline,
                outW: outW, fieldH: fieldH, fullH: fullH,
                cropW: cropW, cropH: cropH,
                cropX: cropX, cropY: cropY,
                rotation: rotation, isInterlaced: isInterlaced
            )
        }
        timer.resume()
        self.captureTimer = timer
    }

    // MARK: - Audio Capture

    private func startAudioCapture(displayIndex: Int) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard !content.displays.isEmpty else {
                await appState.log("Audio: no displays for SCK")
                return
            }
            let idx = min(displayIndex, content.displays.count - 1)
            let display = content.displays[idx]

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.queueDepth = 1
            config.capturesAudio = true
            config.sampleRate = 48000
            config.channelCount = 2
            config.excludesCurrentProcessAudio = true

            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: audioQueue)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
            try await stream.startCapture()
            self.scStream = stream
            await appState.log("Audio capture started (48kHz stereo)")
        } catch {
            await appState.logError("Audio capture failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Frame Capture

    private func captureAndSend(
        displayID: CGDirectDisplayID, modeline: Modeline,
        outW: Int, fieldH: Int, fullH: Int,
        cropW: Int, cropH: Int,
        cropX: Int, cropY: Int,
        rotation: Rotation, isInterlaced: Bool
    ) {
        guard isRunning, let connection, !isSending else { return }
        isSending = true
        defer { isSending = false }

        let fieldData: Data
        let field: UInt8

        if isInterlaced {
            // Interlaced: on field 0, capture full frame and split into even/odd fields
            // On field 1, use the cached odd field from the same capture
            if currentField == 0 {
                guard let screenshot = CGDisplayCreateImage(displayID) else { return }

                // Render to full frame height (e.g. 480 lines)
                let fullRGB = convertToRGB24(
                    image: screenshot, outW: outW, outH: fullH,
                    cropX: cropX, cropY: cropY, cropW: cropW, cropH: cropH,
                    rotation: rotation
                )
                guard fullRGB.count == outW * fullH * 3 else { return }

                // Split into even (field 0) and odd (field 1) scanlines
                let rowBytes = outW * 3
                var field0 = Data(count: outW * fieldH * 3)
                var field1 = Data(count: outW * fieldH * 3)
                fullRGB.withUnsafeBytes { src in
                    let srcPtr = src.bindMemory(to: UInt8.self)
                    field0.withUnsafeMutableBytes { dst0 in
                        let d0 = dst0.bindMemory(to: UInt8.self)
                        field1.withUnsafeMutableBytes { dst1 in
                            let d1 = dst1.bindMemory(to: UInt8.self)
                            for y in 0..<fieldH {
                                let evenRow = y * 2       // even scanlines -> field 0
                                let oddRow = y * 2 + 1    // odd scanlines -> field 1
                                let dstOffset = y * rowBytes
                                memcpy(d0.baseAddress! + dstOffset, srcPtr.baseAddress! + evenRow * rowBytes, rowBytes)
                                if oddRow < fullH {
                                    memcpy(d1.baseAddress! + dstOffset, srcPtr.baseAddress! + oddRow * rowBytes, rowBytes)
                                }
                            }
                        }
                    }
                }

                cachedField1 = field1
                fieldData = field0
                field = 0
                currentField = 1
            } else {
                // Use cached field 1
                guard let cached = cachedField1 else { return }
                fieldData = cached
                cachedField1 = nil
                field = 1
                currentField = 0
            }
        } else {
            // Progressive: capture and send full frame
            guard let screenshot = CGDisplayCreateImage(displayID) else { return }

            let rgb = convertToRGB24(
                image: screenshot, outW: outW, outH: fieldH,
                cropX: cropX, cropY: cropY, cropW: cropW, cropH: cropH,
                rotation: rotation
            )
            guard rgb.count == outW * fieldH * 3 else { return }
            fieldData = rgb
            field = 0
        }

        frameCount += 1

        let header = GroovyProtocol.buildBlitFieldVsync(
            frame: frameCount,
            field: field,
            vSync: modeline.vBegin,
            compressedSize: nil,
            isDelta: false
        )
        connection.sendFrame(header: header, payload: fieldData)

        // Send pending audio after frame
        if audioEnabled {
            audioLock.lock()
            let audio = pendingAudio
            pendingAudio = nil
            audioLock.unlock()

            if let audio, !audio.isEmpty {
                let size = min(Int(UInt16.max), audio.count)
                let audioHeader = GroovyProtocol.buildAudio(size: UInt16(size))
                connection.sendFrame(header: audioHeader, payload: audio.prefix(size))
            }
        }

        if frameCount <= 5 || frameCount % 600 == 0 {
            let c = frameCount
            DispatchQueue.main.async { [weak self] in
                self?.appState.log("Frame \(c) (\(fieldData.count)B, field=\(field))")
            }
        }
    }

    // MARK: - Stop

    func stop() async {
        isRunning = false
        captureTimer?.cancel()
        captureTimer = nil

        if let stream = scStream {
            try? await stream.stopCapture()
            scStream = nil
        }

        if let conn = connection {
            let closePacket = GroovyProtocol.buildClose()
            conn.sendSync(closePacket)
            conn.disconnect()
        }
        connection = nil

        let sent = frameCount
        await MainActor.run {
            appState.log("Stopped (\(sent) frames)")
            appState.isStreaming = false
            appState.streamEngine = nil
        }
    }

    /// Synchronous cleanup for app termination - sends CLOSE and disconnects immediately
    func stopSync() {
        isRunning = false
        captureTimer?.cancel()
        captureTimer = nil

        if let conn = connection {
            let closePacket = GroovyProtocol.buildClose()
            conn.sendSync(closePacket)
            conn.disconnect()
        }
        connection = nil
    }

    // MARK: - Pixel Conversion

    private func convertToRGB24(
        image: CGImage,
        outW: Int, outH: Int,
        cropX: Int, cropY: Int,
        cropW: Int, cropH: Int,
        rotation: Rotation
    ) -> Data {
        let srcW = image.width
        let srcH = image.height

        // Crop
        let drawImage: CGImage
        if cropW > 0 && cropH > 0 && (cropW != srcW || cropH != srcH || cropX != 0 || cropY != 0) {
            let cx = max(0, min(cropX, srcW - 1))
            let cy = max(0, min(cropY, srcH - 1))
            let cw = max(1, min(cropW, srcW - cx))
            let ch = max(1, min(cropH, srcH - cy))
            drawImage = image.cropping(to: CGRect(x: cx, y: cy, width: cw, height: ch)) ?? image
        } else {
            drawImage = image
        }

        let bytesPerRow = outW * 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: outW, height: outH,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return Data() }

        ctx.interpolationQuality = .low

        // Apply rotation
        switch rotation {
        case .none:
            ctx.draw(drawImage, in: CGRect(x: 0, y: 0, width: outW, height: outH))
        case .cw90:
            // 90° clockwise: translate to right edge, rotate -90°
            ctx.translateBy(x: CGFloat(outW), y: 0)
            ctx.rotate(by: .pi / 2)
            ctx.draw(drawImage, in: CGRect(x: 0, y: 0, width: outH, height: outW))
        case .ccw90:
            // 90° counter-clockwise: translate to top edge, rotate +90°
            ctx.translateBy(x: 0, y: CGFloat(outH))
            ctx.rotate(by: -.pi / 2)
            ctx.draw(drawImage, in: CGRect(x: 0, y: 0, width: outH, height: outW))
        case .rotate180:
            ctx.translateBy(x: CGFloat(outW), y: CGFloat(outH))
            ctx.rotate(by: .pi)
            ctx.draw(drawImage, in: CGRect(x: 0, y: 0, width: outW, height: outH))
        }

        guard let data = ctx.data else { return Data() }
        let ptr = data.assumingMemoryBound(to: UInt8.self)

        var rgb = Data(count: outW * outH * 3)
        rgb.withUnsafeMutableBytes { dstBuf in
            let dst = dstBuf.bindMemory(to: UInt8.self)
            for i in 0..<(outW * outH) {
                let s = i * 4
                let d = i * 3
                dst[d]     = ptr[s]
                dst[d + 1] = ptr[s + 1]
                dst[d + 2] = ptr[s + 2]
            }
        }
        return rgb
    }
}

// MARK: - SCStreamOutput (Audio)

extension StreamEngine: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }

        if !audioFormatLogged {
            audioFormatLogged = true
            let fmt = AudioCapture.describeFormat(sampleBuffer)
            DispatchQueue.main.async { [weak self] in
                self?.appState.log("Audio format: \(fmt)")
            }
        }

        guard let pcm = AudioCapture.convertToInt16PCM(sampleBuffer) else { return }

        audioLock.lock()
        if let existing = pendingAudio {
            pendingAudio = existing + pcm
        } else {
            pendingAudio = pcm
        }
        audioLock.unlock()
    }
}

extension Data {
    var hexDump: String {
        self.map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}
