import Foundation
import CoreGraphics

/// Renders Plex media using two FFmpeg subprocesses:
/// - Video: decodes to raw BGR24 frames piped to stdout (-re for real-time)
/// - Audio: decodes to PCM s16le piped to stdout (-re for real-time)
///
/// Both launched simultaneously from the same seek position for sync.
/// Background threads read frames/audio and feed StreamEngine.
final class PlexAVPlayerRenderer: @unchecked Sendable {
    private var videoPID: pid_t = 0
    private var audioPID: pid_t = 0
    private var videoPipeHandle: FileHandle?
    private var isRunning = false
    private var _isPaused = false
    private var outputWidth: Int = 640
    private var outputHeight: Int = 480

    // Atomic latest frame: background thread writes, StreamEngine reads
    private let frameLock = NSLock()
    private var _latestFrame: Data?
    private var _seekGeneration: Int = 0
    private var _firstVideoFrameReceived = false

    // Saved for restart on seek/resume
    private var _ffmpegPath: String?
    private var _urlStr: String?
    private var _audioStreamIndex: Int?
    private var _frameRate: Double = 30.0
    private var _playbackStartTime: Date?
    private var _startOffsetMs: Int = 0
    private var _totalPausedMs: Int = 0
    private var _pauseStartTime: Date?

    var onPlaybackEnded: (() -> Void)?
    var onError: ((String) -> Void)?
    var onStatusChanged: ((PlaybackState) -> Void)?
    /// Called with raw PCM data (s16le, 48kHz, stereo) for external audio routing
    var onAudioData: ((Data) -> Void)?

    enum PlaybackState: String {
        case playing, paused, stopped, buffering
    }

    var isPlaying: Bool { isRunning && !_isPaused }
    var currentTimeMs: Int = 0
    var durationMs: Int = 0

    static func killOrphanedFFmpeg() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        task.arguments = ["-9", "-f", "ffmpeg.*X-Plex-Token"]
        try? task.run()
        task.waitUntilExit()
    }

    func play(url: URL, startOffset: Int = 0, width: Int = 640, height: Int = 480, frameRate: Double = 30.0, audioStreamIndex: Int? = nil) {
        stop()

        self.outputWidth = width
        self.outputHeight = height
        self.isRunning = true
        self._isPaused = false
        frameLock.lock()
        _latestFrame = nil
        frameLock.unlock()
        _firstVideoFrameReceived = false

        let ffmpegPath = findFFmpeg()
        guard let ffmpegPath else {
            onError?("FFmpeg not found. Install via: brew install ffmpeg")
            return
        }

        onStatusChanged?(.buffering)

        self._ffmpegPath = ffmpegPath
        self._urlStr = url.absoluteString
        self._audioStreamIndex = audioStreamIndex
        self._frameRate = frameRate
        self._startOffsetMs = startOffset
        self._playbackStartTime = Date()
        self._totalPausedMs = 0
        self._pauseStartTime = nil

        let urlStr = url.absoluteString
        // Launch both processes simultaneously from the same offset
        launchVideoFFmpeg(path: ffmpegPath, url: urlStr, startOffset: startOffset, frameRate: frameRate)
        launchAudioFFmpeg(path: ffmpegPath, url: urlStr, startOffset: startOffset, audioStreamIndex: audioStreamIndex)
    }

    func pause() {
        guard isRunning, !_isPaused else { return }
        _isPaused = true
        _pauseStartTime = Date()
        if videoPID > 0 { kill(videoPID, SIGSTOP) }
        if audioPID > 0 { kill(audioPID, SIGSTOP) }
        onStatusChanged?(.paused)
    }

    func resume() {
        guard _isPaused else { return }
        _isPaused = false
        if let pauseStart = _pauseStartTime {
            _totalPausedMs += Int(Date().timeIntervalSince(pauseStart) * 1000)
            _pauseStartTime = nil
        }
        // Resume both processes together
        if videoPID > 0 { kill(videoPID, SIGCONT) }
        if audioPID > 0 { kill(audioPID, SIGCONT) }
        onStatusChanged?(.playing)
    }

    func seek(to offsetMs: Int) {
        guard isRunning, let path = _ffmpegPath, let url = _urlStr else { return }

        // Bump generation so old reader threads won't fire onPlaybackEnded
        _seekGeneration += 1

        // Kill current processes
        videoPipeHandle?.closeFile()
        videoPipeHandle = nil
        forceKill(videoPID)
        forceKill(audioPID)
        videoPID = 0
        audioPID = 0

        frameLock.lock()
        _latestFrame = nil
        frameLock.unlock()
        _firstVideoFrameReceived = false

        // Update tracking state
        _startOffsetMs = offsetMs
        _playbackStartTime = Date()
        _totalPausedMs = 0
        _pauseStartTime = nil
        _isPaused = false

        // Relaunch both from the same offset simultaneously
        launchVideoFFmpeg(path: path, url: url, startOffset: offsetMs, frameRate: _frameRate)
        launchAudioFFmpeg(path: path, url: url, startOffset: offsetMs, audioStreamIndex: _audioStreamIndex)
    }

    func stop() {
        let wasRunning = isRunning
        isRunning = false
        _isPaused = false

        videoPipeHandle?.closeFile()
        videoPipeHandle = nil

        forceKill(videoPID)
        forceKill(audioPID)
        videoPID = 0
        audioPID = 0

        frameLock.lock()
        _latestFrame = nil
        frameLock.unlock()

        if wasRunning {
            onStatusChanged?(.stopped)
        }
    }

    private func forceKill(_ pid: pid_t) {
        guard pid > 0 else { return }
        kill(pid, SIGCONT)
        kill(pid, SIGKILL)
    }

    /// Returns the latest frame instantly — no blocking, no sequential consumption.
    func currentFrameRGB24() -> Data? {
        guard isRunning else { return nil }
        frameLock.lock()
        let frame = _latestFrame
        frameLock.unlock()
        return frame
    }

    func currentFrame() -> CGImage? {
        guard let data = currentFrameRGB24() else { return nil }
        return createCGImageFromRGB24(data: data, width: outputWidth, height: outputHeight)
    }

    // MARK: - Video FFmpeg

    private func launchVideoFFmpeg(path: String, url: String, startOffset: Int, frameRate: Double) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)

        var args: [String] = ["-re"]

        if startOffset > 0 {
            let seconds = Double(startOffset) / 1000.0
            args += ["-ss", String(format: "%.3f", seconds)]
        }

        args += [
            "-i", url,
            "-map", "0:v:0",
            "-f", "rawvideo",
            "-pix_fmt", "bgr24",
            "-s", "\(outputWidth)x\(outputHeight)",
            "-r", String(format: "%.4f", frameRate),
            "-vsync", "cfr",
            "-v", "error",
            "-nostdin",
            "pipe:1"
        ]

        process.arguments = args

        let videoPipe = Pipe()
        process.standardOutput = videoPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            self.videoPID = process.processIdentifier
            self.videoPipeHandle = videoPipe.fileHandleForReading
            NSLog("FFmpeg video PID=%d, fps=%.4f", process.processIdentifier, frameRate)
        } catch {
            self.onError?("Failed to start FFmpeg video: \(error.localizedDescription)")
            self.isRunning = false
            return
        }

        // Background thread: reads video frames, atomically swaps latest
        let fh = videoPipe.fileHandleForReading
        let frameSize = outputWidth * outputHeight * 3
        let generation = _seekGeneration
        Thread.detachNewThread { [weak self] in
            var buffer = Data()
            buffer.reserveCapacity(frameSize * 2)

            while let self = self, self.isRunning, self._seekGeneration == generation {
                let needed = frameSize - buffer.count
                let chunk = fh.readData(ofLength: needed)
                if chunk.isEmpty {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.isRunning, self._seekGeneration == generation else { return }
                        self.isRunning = false
                        self.onPlaybackEnded?()
                    }
                    return
                }
                buffer.append(chunk)

                if buffer.count >= frameSize {
                    let frame = Data(buffer.prefix(frameSize))
                    buffer = Data(buffer.dropFirst(frameSize))

                    self.frameLock.lock()
                    self._latestFrame = frame
                    self._firstVideoFrameReceived = true
                    self.frameLock.unlock()
                }
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.onStatusChanged?(.playing)
        }
    }

    // MARK: - Audio FFmpeg (PCM pipe to StreamEngine)

    private func launchAudioFFmpeg(path: String, url: String, startOffset: Int, audioStreamIndex: Int?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)

        var args: [String] = ["-re"]

        if startOffset > 0 {
            let seconds = Double(startOffset) / 1000.0
            args += ["-ss", String(format: "%.3f", seconds)]
        }

        args += ["-i", url]

        if let idx = audioStreamIndex {
            args += ["-map", "0:\(idx)"]
        } else {
            args += ["-map", "0:a:0"]
        }

        // Output raw PCM (signed 16-bit LE, 48kHz stereo) to pipe
        args += ["-ac", "2", "-ar", "48000", "-f", "s16le", "-acodec", "pcm_s16le",
                 "-v", "warning", "-nostdin", "pipe:1"]

        process.arguments = args

        let audioPipe = Pipe()
        process.standardOutput = audioPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            self.audioPID = process.processIdentifier
            NSLog("FFmpeg audio PID=%d, offset=%dms", process.processIdentifier, startOffset)
        } catch {
            NSLog("FFmpeg audio launch failed: %@", error.localizedDescription)
            return
        }

        // Read PCM data and feed to StreamEngine
        // Gate on first video frame + discard extra ~75ms to compensate for decode lag
        let audioFH = audioPipe.fileHandleForReading
        let generation = _seekGeneration
        let thread = Thread { [weak self] in
            // Phase 1: Discard audio until the first video frame arrives
            while let self = self, self.isRunning, self._seekGeneration == generation {
                self.frameLock.lock()
                let ready = self._firstVideoFrameReceived
                self.frameLock.unlock()
                if ready { break }
                let discard = audioFH.readData(ofLength: 3840) // ~20ms
                if discard.isEmpty { return }
            }

            // Phase 2: Discard ~300ms more audio to align with video decode latency
            // 48000Hz * 2ch * 2bytes * 0.300s = 57600 bytes
            var discarded = 0
            while discarded < 57600, let self = self, self.isRunning, self._seekGeneration == generation {
                let remain = min(3840, 57600 - discarded)
                let discard = audioFH.readData(ofLength: remain)
                if discard.isEmpty { return }
                discarded += discard.count
            }

            // Phase 3: Feed audio to StreamEngine
            // Use 4800 bytes (~25ms) — small enough for low latency, large enough to avoid jitter
            while let self = self, self.isRunning, self._seekGeneration == generation {
                let chunk = audioFH.readData(ofLength: 4800)
                if chunk.isEmpty { break }
                self.onAudioData?(chunk)
            }
        }
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    // MARK: - Helpers

    private func createCGImageFromRGB24(data: Data, width: Int, height: Int) -> CGImage? {
        let bytesPerRow = width * 3
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 24,
            bytesPerRow: bytesPerRow, space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: provider,
            decode: nil, shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private func findFFmpeg() -> String? {
        for path in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"] {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }
}
