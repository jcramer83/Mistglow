import Foundation

@MainActor
@Observable
final class WebStreamController {
    var isStreaming = false
    var isLoading = false
    var currentURL: String = ""

    private var renderer: WebFrameRenderer?
    private weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
    }

    func startStreaming(url: String) {
        guard let appState, !isStreaming else { return }
        guard let parsed = URL(string: url) else {
            appState.logError("Invalid URL: \(url)")
            return
        }

        isLoading = true
        currentURL = url

        let m = appState.settings.modeline
        let width = Int(m.hActive)
        let height = Int(m.vActive)

        // Create renderer and load page
        let r = WebFrameRenderer(width: width, height: height)
        self.renderer = r
        r.load(url: parsed)

        // Compute capture interval from modeline
        let frameRate = Double(m.pClock) * 1_000_000.0 / (Double(m.hTotal) * Double(m.vTotal))
        let fieldRate = m.interlace ? frameRate * 2.0 : frameRate
        let intervalUs = max(8000, Int(1_000_000.0 / fieldRate))
        r.startCapture(intervalUs: intervalUs)

        // Create engine manually so we can set external source BEFORE start()
        // This prevents the desktop flash
        let engine = StreamEngine(appState: appState)
        appState.streamEngine = engine
        appState.isStreaming = true

        // Wire renderer frames immediately — no desktop capture will happen
        engine.externalFrameSourceRGB24 = { [weak r] in
            r?.currentFrameRGB24()
        }

        // Wire audio: Web Audio API → feedExternalAudio
        r.onAudioPCM = { [weak engine] pcmData in
            engine?.feedExternalAudio(pcmData)
        }

        Task { @MainActor in
            await engine.start()
            self.isStreaming = true
            self.isLoading = false
            appState.log("Web streaming: \(url)")
        }
    }

    func stopStreaming() {
        guard let appState else { return }

        renderer?.tearDown()
        renderer = nil

        if let engine = appState.streamEngine {
            engine.externalFrameSourceRGB24 = nil
        }

        if appState.isStreaming {
            appState.stopStreaming()
        }

        isStreaming = false
        isLoading = false
        currentURL = ""
        appState.log("Web streaming stopped")
    }
}
