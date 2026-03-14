import Foundation
import AppKit
import os

@MainActor
@Observable
final class PlexPlaybackController {
    var isPlaying = false
    var isPaused = false
    var nowPlayingTitle: String?
    var nowPlayingShowName: String?
    var nowPlayingEpisodeInfo: String?
    var currentTimeMs: Int = 0
    var durationMs: Int = 0
    var thumbImage: NSImage?

    private var gdmAdvertiser: PlexGDMAdvertiser?
    private var companionServer: PlexCompanionServer?
    private var renderer: PlexAVPlayerRenderer?
    private weak var appState: AppState?
    private var mediaKey: String = ""
    private var machineIdentifier: String = ""
    private var serverAddress: String = ""
    private var serverPort: Int = 32400
    private var serverProtocol: String = "http"
    private var serverToken: String = ""
    private var containerKey: String = ""
    private var playQueueItemID: Int = 0
    private var playQueueID: Int = 0
    private var playQueueVersion: Int = 1
    private var sessionIdentifier: String = UUID().uuidString
    private var timelineTimer: Timer?
    private var playbackStartDate: Date?
    private var playbackStartOffsetMs: Int = 0
    private var totalPausedMs: Int = 0
    private var pauseStartDate: Date?

    // Thread-safe timeline cache for companion server access
    private let _cachedTimeline = OSAllocatedUnfairLock(initialState: PlexTimeline())

    init(appState: AppState) {
        self.appState = appState
    }

    func enable() {
        guard let appState else { return }
        let resourceId = appState.settings.plexResourceIdentifier

        // Start GDM advertiser
        let advertiser = PlexGDMAdvertiser(resourceIdentifier: resourceId)
        advertiser.logHandler = { [weak appState] msg in
            DispatchQueue.main.async {
                appState?.log(msg)
            }
        }
        advertiser.start()
        self.gdmAdvertiser = advertiser

        // Start companion HTTP server
        let server = PlexCompanionServer()
        server.delegate = self
        server.resourceIdentifier = resourceId
        server.logHandler = { [weak appState] msg in
            DispatchQueue.main.async {
                appState?.log(msg)
            }
        }
        do {
            try server.start()
            self.companionServer = server
            appState.log("Plex receiver started (port 3005)")
        } catch {
            appState.logError("Plex server failed: \(error.localizedDescription)")
        }
    }

    func disable() {
        stopPlayback()
        // Fully clear source so screen capture can resume
        appState?.streamEngine?.externalFrameSourceRGB24 = nil
        gdmAdvertiser?.stop()
        gdmAdvertiser = nil
        companionServer?.stop()
        companionServer = nil
        appState?.log("Plex receiver stopped")
    }

    private var fallbackURL: URL?

    /// Pick the best modeline for detected video dimensions when auto-modeline is enabled.
    /// Returns nil if no match (falls back to user-selected modeline).
    private func autoModeline(videoHeight: Int?, videoWidth: Int?) -> Modeline? {
        guard let h = videoHeight else { return nil }
        // PAL SD: 576 lines → 720x576i PAL
        if h == 576 {
            return Modeline.presets.first { $0.name == "720x576i PAL" }
        }
        // NTSC SD: 480 lines → 720x480i NTSC
        if h == 480 {
            return Modeline.presets.first { $0.name == "720x480i NTSC" }
        }
        return nil
    }

    private func startPlayback(url: URL, title: String, duration: Int, offset: Int, fallback: URL? = nil, audioStreamIndex: Int? = nil) {
        self.fallbackURL = fallback
        let renderer = PlexAVPlayerRenderer()
        self.renderer = renderer

        renderer.onPlaybackEnded = { [weak self] in
            DispatchQueue.main.async {
                self?.handlePlaybackEnded()
            }
        }

        renderer.onError = { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.appState?.logError("Plex playback error: \(error)")
                // Try transcode fallback URL if direct play failed
                if let fallback = self.fallbackURL {
                    self.fallbackURL = nil
                    self.appState?.log("Plex: Trying transcode fallback...")
                    self.renderer?.stop()
                    self.renderer = nil
                    self.startPlayback(url: fallback, title: title, duration: duration, offset: offset)
                } else {
                    self.stopPlayback()
                }
            }
        }

        renderer.onStatusChanged = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .playing:
                    self?.isPlaying = true
                    self?.isPaused = false
                case .paused:
                    self?.isPaused = true
                case .stopped:
                    self?.isPlaying = false
                    self?.isPaused = false
                case .buffering:
                    break
                }
            }
        }

        // Wire renderer as RGB24 frame source for StreamEngine (bypasses crop/scale/rotation)
        if let engine = appState?.streamEngine {
            engine.externalFrameSourceRGB24 = { [weak renderer] in
                renderer?.currentFrameRGB24()
            }
            // Route audio PCM to StreamEngine → MiSTer (instead of local speakers)
            renderer.onAudioData = { [weak engine] pcm in
                engine?.feedExternalAudio(pcm)
            }
        }

        // Use modeline resolution and frame rate for FFmpeg output
        let modeline = appState?.settings.modeline ?? Modeline.defaultPreset
        let outW = Int(modeline.hActive)
        let outH = Int(modeline.vActive)
        let baseRate = modeline.pClock * 1_000_000.0 / (Double(modeline.hTotal) * Double(modeline.vTotal))
        // For interlaced: output at field rate (2x) so each field gets a unique frame
        let frameRate = modeline.interlace ? baseRate * 2.0 : baseRate
        renderer.play(url: url, startOffset: offset, width: outW, height: outH, frameRate: frameRate, audioStreamIndex: audioStreamIndex)
        nowPlayingTitle = title
        durationMs = duration
        isPlaying = true
        playbackStartDate = Date()
        playbackStartOffsetMs = offset
        totalPausedMs = 0
        pauseStartDate = nil

        // Start timeline update timer
        timelineTimer?.invalidate()
        timelineTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateTimeline()
            }
        }

        appState?.log("Plex: Playing \"\(title)\" (offset=\(offset / 1000)s, duration=\(duration / 1000)s)")

        // Push timeline immediately so Plex sees "playing" right away
        updateTimeline()
    }

    // MARK: - UI Controls

    func pausePlayback() {
        renderer?.pause()
        isPaused = true
        pauseStartDate = Date()
        appState?.log("Plex: Paused at \(currentTimeMs / 1000)s")
        updateTimeline()
    }

    func resumePlayback() {
        renderer?.resume()
        isPaused = false
        if let pauseStart = pauseStartDate {
            totalPausedMs += Int(Date().timeIntervalSince(pauseStart) * 1000)
            pauseStartDate = nil
        }
        appState?.log("Plex: Resumed at \(currentTimeMs / 1000)s")
        updateTimeline()
    }

    func togglePause() {
        if isPaused {
            resumePlayback()
        } else {
            pausePlayback()
        }
    }

    func stopPlaybackFromUI() {
        appState?.log("Plex: Stopped from UI")
        stopPlayback()
    }

    func skipNext() {
        skipInQueue(direction: 1)
    }

    func skipPrevious() {
        skipInQueue(direction: -1)
    }

    func seekTo(ms: Int) {
        let clampedMs = max(0, min(ms, durationMs))
        appState?.log("Plex: Seek to \(clampedMs / 1000)s")

        // Update wall-clock tracking
        playbackStartDate = Date()
        playbackStartOffsetMs = clampedMs
        totalPausedMs = 0
        pauseStartDate = nil
        currentTimeMs = clampedMs

        // Restart FFmpeg at new offset
        renderer?.seek(to: clampedMs)
        updateTimeline()
    }

    /// Stop playback but keep Plex context (mediaKey, machineIdentifier) so Plex can auto-advance
    private func stopPlaybackKeepContext() {
        timelineTimer?.invalidate()
        timelineTimer = nil
        renderer?.stop()
        renderer = nil
        // Set placeholder source — keep MiSTer streaming connection alive for next track
        appState?.streamEngine?.externalFrameSourceRGB24 = { nil }
        isPlaying = false
        isPaused = false
        nowPlayingTitle = nil
        nowPlayingShowName = nil
        nowPlayingEpisodeInfo = nil
        // Report stopped with key intact so Plex knows what ended and can advance
        let time = currentTimeMs
        let dur = durationMs
        let key = mediaKey
        let mid = machineIdentifier
        let addr = serverAddress
        let port = serverPort
        let proto = serverProtocol
        let tok = serverToken
        let ckey = containerKey
        let pqItemID = playQueueItemID
        let pqID = playQueueID
        let pqVersion = playQueueVersion
        _cachedTimeline.withLock {
            $0 = PlexTimeline(state: "stopped", timeMs: time, durationMs: dur,
                              key: key, machineIdentifier: mid,
                              address: addr, port: port, protocol: proto,
                              token: tok, containerKey: ckey,
                              playQueueItemID: pqItemID, playQueueID: pqID, playQueueVersion: pqVersion)
        }

        currentTimeMs = 0
        durationMs = 0
    }

    /// Full stop — clears everything and stops streaming
    private func stopPlayback() {
        stopPlaybackKeepContext()
        appState?.streamEngine?.externalFrameSourceRGB24 = nil
        appState?.stopStreaming()
        mediaKey = ""
        machineIdentifier = ""
        serverAddress = ""
        serverPort = 32400
        serverProtocol = "http"
        serverToken = ""
        containerKey = ""
        playQueueItemID = 0
        playQueueID = 0
        playQueueVersion = 1
        thumbImage = nil
        _cachedTimeline.withLock { $0 = PlexTimeline() }
    }

    private func handlePlaybackEnded() {
        appState?.log("Plex: Playback ended naturally")
        // Keep context so we can auto-advance to next item
        stopPlaybackKeepContext()
        // Auto-play next episode/item in queue
        skipInQueue(direction: 1)
    }

    private func updateTimeline() {
        guard renderer != nil else { return }

        // Calculate current position from wall clock
        if let startDate = playbackStartDate {
            let elapsedMs = Int(Date().timeIntervalSince(startDate) * 1000)
            let pausedNow = isPaused && pauseStartDate != nil
                ? Int(Date().timeIntervalSince(pauseStartDate!) * 1000)
                : 0
            currentTimeMs = playbackStartOffsetMs + elapsedMs - totalPausedMs - pausedNow
            currentTimeMs = max(0, min(currentTimeMs, durationMs))
        }

        let state: String
        if isPlaying && !isPaused { state = "playing" }
        else if isPaused { state = "paused" }
        else { state = "stopped" }

        let tl = PlexTimeline(
            state: state, timeMs: currentTimeMs, durationMs: durationMs,
            key: mediaKey, machineIdentifier: machineIdentifier,
            address: serverAddress, port: serverPort, protocol: serverProtocol,
            token: serverToken, containerKey: containerKey,
            playQueueItemID: playQueueItemID, playQueueID: playQueueID, playQueueVersion: playQueueVersion
        )
        _cachedTimeline.withLock { $0 = tl }
    }

    /// Get the local WiFi/Ethernet IP address
    private static func getLocalIPAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            guard interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            // Prefer en0 (WiFi) or en1 (Ethernet)
            guard name.hasPrefix("en") else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                           &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: hostname)
                if ip.hasPrefix("169.254") { continue } // skip link-local
                return ip
            }
        }
        return nil
    }
}

// MARK: - PlexCompanionDelegate

extension PlexPlaybackController: PlexCompanionDelegate {
    nonisolated func plexPlayMedia(serverAddress: String, serverPort: Int, serverProtocol: String,
                                    key: String, token: String, offset: Int, machineIdentifier: String,
                                    audioStreamID: String?, containerKey: String?) {
        Task { @MainActor [weak self] in
            guard let self, let appState = self.appState else { return }

            // Stop current renderer but keep MiSTer streaming connection alive
            self.timelineTimer?.invalidate()
            self.timelineTimer = nil
            self.renderer?.stop()
            self.renderer = nil
            self.mediaKey = key
            self.machineIdentifier = machineIdentifier
            self.serverAddress = serverAddress
            self.serverPort = serverPort
            self.serverProtocol = serverProtocol
            self.serverToken = token
            self.containerKey = containerKey ?? ""
            // Extract playQueueID from containerKey like "/playQueues/10472?own=1"
            if let ckey = containerKey, ckey.contains("/playQueues/") {
                let path = ckey.split(separator: "?").first ?? Substring(ckey)
                if let idStr = path.split(separator: "/").last, let qid = Int(idStr) {
                    self.playQueueID = qid
                }
            }
            // Fetch play queue to get our item's queue ID for timeline reporting
            if let ckey = containerKey, !ckey.isEmpty {
                do {
                    let result = try await PlexPlayQueueManager.fetch(
                        containerKey: ckey, address: serverAddress, port: serverPort,
                        serverProtocol: serverProtocol, token: token, currentMediaKey: key
                    )
                    if let idx = result.currentIndex, idx < result.items.count {
                        self.playQueueItemID = result.items[idx].playQueueItemID
                        self.playQueueVersion = result.playQueueVersion
                    }
                } catch {
                    NSLog("Plex: Could not fetch play queue: %@", error.localizedDescription)
                }
            }

            do {
                let media = try await PlexMediaResolver.resolve(
                    address: serverAddress, port: serverPort,
                    serverProtocol: serverProtocol, key: key, token: token,
                    clientIdentifier: appState.settings.plexResourceIdentifier,
                    sessionIdentifier: self.sessionIdentifier
                )

                // Fetch thumbnail async
                self.thumbImage = nil
                if let thumbURL = media.thumbURL {
                    Task { [weak self] in
                        do {
                            let (data, _) = try await URLSession.shared.data(from: thumbURL)
                            if let image = NSImage(data: data) {
                                await MainActor.run {
                                    self?.thumbImage = image
                                }
                            }
                        } catch {
                            NSLog("Plex: Thumbnail fetch failed: %@", error.localizedDescription)
                        }
                    }
                }

                // Auto-select modeline from source video dimensions when enabled
                if appState.settings.plexAutoModeline,
                   let detected = self.autoModeline(videoHeight: media.videoHeight, videoWidth: media.videoWidth),
                   detected != appState.settings.modeline {
                    appState.settings.modeline = detected
                    // Find preset index for UI sync
                    if let idx = Modeline.presets.firstIndex(of: detected) {
                        appState.selectedPresetIndex = idx
                    }
                    appState.settings.save()
                    appState.log("Plex: Auto-selected modeline \(detected.name) (source: \(media.videoWidth ?? 0)x\(media.videoHeight ?? 0))")
                    // Restart stream with new modeline dimensions
                    if appState.isStreaming {
                        appState.stopStreaming()
                    }
                }

                // Start streaming if not already (or restarting for modeline change)
                if !appState.isStreaming {
                    appState.settings.save()
                    appState.startStreaming()
                    // Immediately set a placeholder source so StreamEngine doesn't capture desktop
                    appState.streamEngine?.externalFrameSourceRGB24 = { nil }
                    // Give StreamEngine time to connect
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                } else {
                    // Already streaming — set placeholder to stop screen capture immediately
                    appState.streamEngine?.externalFrameSourceRGB24 = { nil }
                }

                // Use Plex-requested audio stream ID if available, otherwise metadata selection
                let audioIdx: Int?
                if let reqID = audioStreamID,
                   let match = media.audioStreams.first(where: { $0.plexID == reqID }) {
                    audioIdx = match.index
                } else if let reqID = audioStreamID, let idx = Int(reqID) {
                    audioIdx = idx
                } else {
                    audioIdx = media.audioStreamIndex
                }

                // Set title info for multi-line display
                self.nowPlayingShowName = media.showTitle
                if let s = media.seasonNumber, let e = media.episodeNumber {
                    self.nowPlayingEpisodeInfo = "S\(s)E\(e) — \(media.title)"
                } else {
                    self.nowPlayingEpisodeInfo = nil
                }

                self.startPlayback(url: media.directPlayURL, title: media.displayTitle,
                                   duration: media.duration, offset: offset,
                                   fallback: media.transcodeURL,
                                   audioStreamIndex: audioIdx)
            } catch {
                appState.logError("Plex: Failed to resolve media: \(error.localizedDescription)")
            }
        }
    }

    nonisolated func plexStop() {
        Task { @MainActor [weak self] in
            self?.appState?.log("Plex: Stop requested")
            self?.stopPlayback()
        }
    }

    nonisolated func plexPause() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Plex sometimes sends pause as a toggle
            if self.isPaused {
                self.resumePlayback()
            } else {
                self.pausePlayback()
            }
        }
    }

    nonisolated func plexResume() {
        Task { @MainActor [weak self] in
            self?.resumePlayback()
        }
    }

    nonisolated func plexSeek(to offsetMs: Int) {
        Task { @MainActor [weak self] in
            self?.seekTo(ms: offsetMs)
        }
    }

    nonisolated func plexSkipNext() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.skipInQueue(direction: 1)
        }
    }

    nonisolated func plexSkipPrevious() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.skipInQueue(direction: -1)
        }
    }

    private func skipInQueue(direction: Int) {
        guard !containerKey.isEmpty else {
            appState?.log("Plex: No play queue — cannot skip")
            return
        }
        let addr = serverAddress
        let port = serverPort
        let proto = serverProtocol
        let tok = serverToken
        let ckey = containerKey
        let currentKey = mediaKey
        let mid = machineIdentifier

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await PlexPlayQueueManager.fetch(
                    containerKey: ckey, address: addr, port: port,
                    serverProtocol: proto, token: tok, currentMediaKey: currentKey
                )

                guard let idx = result.currentIndex else { return }

                let nextIdx = idx + direction
                guard nextIdx >= 0, nextIdx < result.items.count else {
                    self.appState?.log("Plex: No \(direction > 0 ? "next" : "previous") item")
                    return
                }

                let nextItem = result.items[nextIdx]
                self.playQueueItemID = nextItem.playQueueItemID
                self.playQueueVersion = result.playQueueVersion
                self.appState?.log("Plex: \(direction > 0 ? "Next" : "Previous") → \"\(nextItem.title)\"")

                // Play the next item — reuse the same server connection info
                self.plexPlayMedia(
                    serverAddress: addr, serverPort: port, serverProtocol: proto,
                    key: nextItem.key, token: tok, offset: 0,
                    machineIdentifier: mid, audioStreamID: nil, containerKey: ckey
                )
            } catch {
                self.appState?.logError("Plex: Failed to fetch play queue: \(error.localizedDescription)")
                self.handlePlaybackEnded()
            }
        }
    }

    nonisolated func plexTimeline() -> PlexTimeline {
        _cachedTimeline.withLock { $0 }
    }
}
