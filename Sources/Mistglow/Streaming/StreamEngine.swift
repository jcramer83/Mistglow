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
    private let rgbColorSpace = CGColorSpaceCreateDeviceRGB()

    // Audio
    private var scStream: SCStream?
    private var audioEnabled = false
    private let audioQueue = DispatchQueue(label: "com.mistglow.audio", qos: .userInteractive)
    private var pendingAudio = Data()
    private let audioLock = NSLock()
    private var audioFormatLogged = false
    private var audioSamplesReceived: Int = 0
    private var audioBytesSent: Int = 0
    private var audioPacketsSent: Int = 0
    private var audioLastCallbackTime: UInt64 = 0
    private var audioDisplayIndex: Int = 0
    private var audioSendTimer: DispatchSourceTimer?
    // FPGA audio buffer is 32768 bytes. Cap at ~half to avoid overflow.
    private let maxAudioBuffer = 16000
    // Send lock to prevent video and audio from interleaving on the wire
    private let wireLock = NSLock()

    // Interlaced: cache fields from one capture
    private var cachedField1: Data?

    /// External frame source (e.g. Plex FFmpeg). Returns raw RGB24 data at target resolution.
    /// When set, used instead of CGDisplayCreateImage — bypasses crop/scale/rotation.
    var externalFrameSourceRGB24: (() -> Data?)?

    /// External frame source as CGImage (legacy). When set, used instead of CGDisplayCreateImage.
    var externalFrameSource: (() -> CGImage?)?

    /// Feed external audio PCM data (signed 16-bit LE, 48kHz stereo) into the send buffer.
    /// Used by Plex renderer to route audio to MiSTer instead of local speakers.
    func feedExternalAudio(_ pcm: Data) {
        guard audioEnabled else { return }
        audioLock.lock()
        if pendingAudio.count < maxAudioBuffer {
            pendingAudio.append(pcm)
        }
        audioLock.unlock()
    }

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

        NSLog("Output: %dx%d%@", outW, Int(m.vActive), m.interlace ? "i" : "p")

        // Start audio capture via ScreenCaptureKit if enabled
        // Skip when external frame source is set (Plex feeds audio directly via feedExternalAudio)
        if audioEnabled && externalFrameSourceRGB24 == nil {
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
        let intervalUs = max(8000, Int(1_000_000.0 / fieldRate))
        NSLog("Capture: %.2f %@/s", fieldRate, m.interlace ? "fields" : "fps")

        let cropW = settings.cropWidth
        let cropH = settings.cropHeight
        let cropX = settings.cropOffsetX
        let cropY = settings.cropOffsetY
        let rotation = settings.rotation
        if cropW > 0 && cropH > 0 {
            NSLog("Crop: %dx%d at (%d,%d)", cropW, cropH, cropX, cropY)
        }

        // Start capture+send loop
        let isInterlaced = m.interlace
        let timer = DispatchSource.makeTimerSource(queue: sendQueue)
        timer.schedule(deadline: .now(), repeating: .microseconds(intervalUs))
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

        // Start independent audio send timer (~every 20ms = 50Hz)
        // Runs on audioQueue (separate from video sendQueue) so audio doesn't stall when frame capture is slow
        if audioEnabled {
            let audioTimer = DispatchSource.makeTimerSource(queue: audioQueue)
            audioTimer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(10))
            audioTimer.setEventHandler { [weak self] in
                self?.sendPendingAudio()
            }
            audioTimer.resume()
            self.audioSendTimer = audioTimer
            NSLog("Audio send timer: 10ms interval")
        }
    }

    // MARK: - Audio Send (independent timer)

    private func sendPendingAudio() {
        guard isRunning, audioEnabled, let connection else { return }

        audioLock.lock()
        let audio = pendingAudio
        pendingAudio = Data()
        audioLock.unlock()

        guard !audio.isEmpty else { return }

        // Acquire wire lock so we don't interleave with a video blit in progress
        wireLock.lock()
        defer { wireLock.unlock() }

        let size = min(Int(UInt16.max), audio.count)
        let audioHeader = GroovyProtocol.buildAudio(size: UInt16(size))
        connection.sendFrame(header: audioHeader, payload: audio.prefix(size))
        audioPacketsSent += 1
        audioBytesSent += size

        // Periodic audio stats logged via NSLog to avoid flooding UI
        if audioPacketsSent == 5 || audioPacketsSent % 1000 == 0 {
            NSLog("Audio sent #%d: %dB total", audioPacketsSent, audioBytesSent)
        }
    }

    // MARK: - Audio Capture

    private func startAudioCapture(displayIndex: Int) async {
        self.audioDisplayIndex = displayIndex
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
            config.queueDepth = 5
            config.capturesAudio = true
            config.sampleRate = 48000
            config.channelCount = 2
            config.excludesCurrentProcessAudio = true

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: audioQueue)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
            try await stream.startCapture()
            self.scStream = stream
            self.audioFormatLogged = false
            NSLog("Audio capture started")
        } catch {
            await appState.logError("Audio capture failed: \(error.localizedDescription)")
        }
    }

    /// Restart audio capture after an error
    private func restartAudioCapture() {
        guard isRunning, audioEnabled else { return }
        let idx = audioDisplayIndex
        NSLog("Audio: restarting capture...")
        // Stop old stream
        if let stream = scStream {
            scStream = nil
            Task {
                try? await stream.stopCapture()
                // Brief delay before restart
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard self.isRunning else { return }
                await self.startAudioCapture(displayIndex: idx)
            }
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
        autoreleasepool {
        _captureAndSendInner(
            displayID: displayID, modeline: modeline, connection: connection,
            outW: outW, fieldH: fieldH, fullH: fullH,
            cropW: cropW, cropH: cropH, cropX: cropX, cropY: cropY,
            rotation: rotation, isInterlaced: isInterlaced
        )
        }
    }

    private func _captureAndSendInner(
        displayID: CGDirectDisplayID, modeline: Modeline, connection: GroovyConnection,
        outW: Int, fieldH: Int, fullH: Int,
        cropW: Int, cropH: Int,
        cropX: Int, cropY: Int,
        rotation: Rotation, isInterlaced: Bool
    ) {

        let fieldData: Data
        let field: UInt8

        if isInterlaced {
            // Interlaced: on field 0, capture full frame and split into even/odd fields
            // On field 1, use the cached odd field from the same capture

            if currentField == 0 {
                let fullRGB: Data

                // Check external RGB24 source first (Plex FFmpeg — already at target resolution)
                if let source = externalFrameSourceRGB24 {
                    guard let rgb = source() else { return }
                    fullRGB = rgb
                } else if let source = externalFrameSource {
                    guard let frame = source() else { return }
                    fullRGB = convertToRGB24(
                        image: frame, outW: outW, outH: fullH,
                        cropX: cropX, cropY: cropY, cropW: cropW, cropH: cropH,
                        rotation: rotation
                    )
                } else {
                    // Screen capture path
                    guard let frame = CGDisplayCreateImage(displayID) else { return }
                    fullRGB = convertToRGB24(
                        image: frame, outW: outW, outH: fullH,
                        cropX: cropX, cropY: cropY, cropW: cropW, cropH: cropH,
                        rotation: rotation
                    )
                }
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
            let rgb: Data

            if let source = externalFrameSourceRGB24 {
                guard let data = source() else { return } // Plex mode but no frame yet — skip
                rgb = data
            } else if let source = externalFrameSource {
                guard let frame = source() else { return }
                rgb = convertToRGB24(
                    image: frame, outW: outW, outH: fieldH,
                    cropX: cropX, cropY: cropY, cropW: cropW, cropH: cropH,
                    rotation: rotation
                )
            } else {
                guard let frame = CGDisplayCreateImage(displayID) else { return }
                rgb = convertToRGB24(
                    image: frame, outW: outW, outH: fieldH,
                    cropX: cropX, cropY: cropY, cropW: cropW, cropH: cropH,
                    rotation: rotation
                )
            }
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

        // Wire lock prevents audio timer from sending CMD_AUDIO mid-blit
        wireLock.lock()
        connection.sendFrame(header: header, payload: fieldData)
        wireLock.unlock()

        if frameCount == 5 || frameCount % 1800 == 0 {
            NSLog("Frame %d (%dB, field=%d)", frameCount, fieldData.count, field)
        }

    }

    // MARK: - Stop

    func stop() async {
        isRunning = false
        captureTimer?.cancel()
        captureTimer = nil
        audioSendTimer?.cancel()
        audioSendTimer = nil

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
        audioSendTimer?.cancel()
        audioSendTimer = nil

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
        guard let ctx = CGContext(
            data: nil, width: outW, height: outH,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: rgbColorSpace,
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
            NSLog("Audio format: %@", fmt)
        }

        guard let pcm = AudioCapture.convertToInt16PCM(sampleBuffer) else { return }

        audioSamplesReceived += 1
        audioLastCallbackTime = mach_absolute_time()

        audioLock.lock()
        // Cap buffer to prevent unbounded growth if video is slow
        if pendingAudio.count < maxAudioBuffer {
            pendingAudio.append(pcm)
        }
        audioLock.unlock()
    }
}

// MARK: - SCStreamDelegate (Error handling + auto-restart)

extension StreamEngine: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.appState.logError("Audio stream stopped: \(error.localizedDescription)")
        }
        restartAudioCapture()
    }
}

extension Data {
    var hexDump: String {
        self.map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}
