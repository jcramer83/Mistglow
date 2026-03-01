import Foundation
import SwiftUI
import ScreenCaptureKit
import CoreMedia

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let message: String
    let isError: Bool

    init(_ message: String, isError: Bool = false) {
        self.timestamp = Date()
        self.message = message
        self.isError = isError
    }
}

struct FPGAStatus {
    var frame: UInt32 = 0
    var frameEcho: UInt32 = 0
    var vCount: UInt16 = 0
    var vCountEcho: UInt16 = 0
    var vramEndFrame: Bool = false
    var vramReady: Bool = false
    var vramSynced: Bool = false
    var vgaFrameskip: Bool = false
    var vgaVblank: Bool = false
    var vgaF1: Bool = false
    var audio: Bool = false
    var vramQueue: Bool = false
}

@MainActor
@Observable
final class AppState {
    var settings = AppSettings.load()
    var isStreaming = false
    var isPreviewing = false
    var logEntries: [LogEntry] = []
    var fpgaStatus = FPGAStatus()
    var previewImage: CGImage?
    var availableDisplays: [SCDisplay] = []
    var cgDisplayIDs: [CGDirectDisplayID] = []
    var selectedPresetIndex: Int = 3 // 640x480i NTSC
    var needsScreenRecording = false

    var displayCount: Int {
        if !availableDisplays.isEmpty { return availableDisplays.count }
        return max(cgDisplayIDs.count, 1)
    }

    var streamEngine: StreamEngine?
    var previewCapture: PreviewCapture?
    var plexController: PlexPlaybackController?

    func log(_ message: String) {
        logEntries.append(LogEntry(message))
    }

    func logError(_ message: String) {
        logEntries.append(LogEntry(message, isError: true))
    }

    func applyPreset(_ index: Int) {
        guard index >= 0 && index < Modeline.presets.count else { return }
        selectedPresetIndex = index
        settings.modeline = Modeline.presets[index]
    }

    func updateCropForMode() {
        let m = settings.modeline
        let modeW = Int(m.hActive)
        let modeH = Int(m.vActive)

        // Get actual display pixel dimensions
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        CGGetActiveDisplayList(8, &displayIDs, &count)
        let dispW: Int
        let dispH: Int
        if count > 0 {
            let idx = min(settings.displayIndex, Int(count) - 1)
            dispW = CGDisplayPixelsWide(displayIDs[idx])
            dispH = CGDisplayPixelsHigh(displayIDs[idx])
        } else {
            dispW = modeW
            dispH = modeH
        }

        switch settings.cropMode {
        case .custom:
            return // Don't update offsets for custom
        case .scale1x:
            settings.cropWidth = modeW
            settings.cropHeight = modeH
        case .scale2x:
            settings.cropWidth = modeW * 2
            settings.cropHeight = modeH * 2
        case .scale3x:
            settings.cropWidth = modeW * 3
            settings.cropHeight = modeH * 3
        case .scale4x:
            settings.cropWidth = modeW * 4
            settings.cropHeight = modeH * 4
        case .scale5x:
            settings.cropWidth = modeW * 5
            settings.cropHeight = modeH * 5
        case .full43:
            settings.cropHeight = dispH
            settings.cropWidth = (dispH * 4) / 3
        case .full54:
            settings.cropHeight = dispH
            settings.cropWidth = (dispH * 5) / 4
        }

        // Apply alignment to compute crop offset
        let extraX = max(0, dispW - settings.cropWidth)
        let extraY = max(0, dispH - settings.cropHeight)

        switch settings.alignment {
        case .topLeft, .middleLeft, .bottomLeft:
            settings.cropOffsetX = 0
        case .topCenter, .center, .bottomCenter:
            settings.cropOffsetX = extraX / 2
        case .topRight, .middleRight, .bottomRight:
            settings.cropOffsetX = extraX
        }

        switch settings.alignment {
        case .topLeft, .topCenter, .topRight:
            settings.cropOffsetY = 0
        case .middleLeft, .center, .middleRight:
            settings.cropOffsetY = extraY / 2
        case .bottomLeft, .bottomCenter, .bottomRight:
            settings.cropOffsetY = extraY
        }
    }

    func startPreview() {
        guard !isPreviewing else { return }
        log("Starting preview...")
        isPreviewing = true
        let capture = PreviewCapture(appState: self)
        self.previewCapture = capture
        Task {
            await capture.start()
        }
    }

    func stopPreview() {
        guard isPreviewing else { return }
        log("Stopping preview...")
        Task {
            await previewCapture?.stop()
            await MainActor.run {
                self.previewCapture = nil
                self.isPreviewing = false
                self.previewImage = nil
            }
        }
    }

    func startStreaming() {
        guard !isStreaming else { return }
        log("Starting stream to \(settings.targetIP)...")
        isStreaming = true
        let engine = StreamEngine(appState: self)
        self.streamEngine = engine
        Task {
            await engine.start()
        }
    }

    func stopStreaming() {
        guard isStreaming else { return }
        log("Stopping stream...")
        let engine = streamEngine
        streamEngine = nil
        Task {
            await engine?.stop()
        }
    }

    func startPlexReceiver() {
        guard plexController == nil else { return }
        let controller = PlexPlaybackController(appState: self)
        self.plexController = controller
        controller.enable()
    }

    func stopPlexReceiver() {
        plexController?.disable()
        plexController = nil
    }

    func initialize() {
        // Kill any orphaned FFmpeg processes from previous app sessions
        PlexAVPlayerRenderer.killOrphanedFFmpeg()

        // Apply crop mode on startup
        if settings.cropMode != .custom {
            updateCropForMode()
        }
        // Auto-start Plex receiver if enabled
        if settings.plexEnabled {
            startPlexReceiver()
        }
    }

    func refreshDisplays() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            self.availableDisplays = content.displays
            self.needsScreenRecording = false
            if content.displays.isEmpty {
                log("No displays found")
            } else {
                log("Found \(content.displays.count) display(s)")
            }
            return
        } catch {
            needsScreenRecording = true
            logError("Screen Recording permission required")
            log("Go to System Settings > Privacy & Security > Screen Recording")
            log("Enable Mistglow, then restart the app")
        }

        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 8)
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(8, &displayIDs, &displayCount)
        if displayCount > 0 {
            cgDisplayIDs = Array(displayIDs.prefix(Int(displayCount)))
        } else {
            logError("No displays found")
        }
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
