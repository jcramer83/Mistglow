import Foundation
import AppKit
import WebKit

final class WebFrameRenderer: NSObject, @unchecked Sendable {
    private let width: Int
    private let height: Int

    private var window: NSWindow?
    private var webView: WKWebView?
    private var captureTimer: DispatchSourceTimer?
    private let frameLock = NSLock()
    private var _latestFrame: Data?
    private var hasFinishedLoading = false

    // Audio: callback receives Int16 PCM stereo 48kHz data
    var onAudioPCM: ((Data) -> Void)?

    // Pre-allocated CGContext for reuse
    private let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
    private var reusableContext: CGContext?

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        super.init()
    }

    /// Must be called on main thread
    @MainActor
    func load(url: URL) {
        // Create off-screen window
        let win = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: width, height: height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.level = NSWindow.Level(rawValue: -1000)
        win.isReleasedWhenClosed = false
        win.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        win.orderBack(nil)
        self.window = win

        // Configure WKWebView with audio message handler
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(self, name: "audioPCM")

        // Inject audio capture BEFORE page scripts run
        let earlyJS = """
        (function() {
            var ctx = new AudioContext({sampleRate: 48000});
            var proc = ctx.createScriptProcessor(4096, 2, 2);
            var sending = false;
            proc.onaudioprocess = function(e) {
                var L = e.inputBuffer.getChannelData(0);
                var R = e.inputBuffer.getChannelData(1);
                var buf = new Int16Array(L.length * 2);
                for (var i = 0; i < L.length; i++) {
                    buf[i*2]   = Math.max(-32768, Math.min(32767, Math.round(L[i] * 32767)));
                    buf[i*2+1] = Math.max(-32768, Math.min(32767, Math.round(R[i] * 32767)));
                }
                var bytes = new Uint8Array(buf.buffer);
                var chunks = [];
                for (var j = 0; j < bytes.length; j += 512) {
                    chunks.push(String.fromCharCode.apply(null, bytes.subarray(j, Math.min(j+512, bytes.length))));
                }
                window.webkit.messageHandlers.audioPCM.postMessage(btoa(chunks.join('')));
                if (!sending) { sending = true; console.log('audioPCM: first buffer sent to Swift'); }
            };
            // Connect through zero-gain node to keep audio graph alive (no speaker output)
            var silence = ctx.createGain();
            silence.gain.value = 0;
            proc.connect(silence);
            silence.connect(ctx.destination);

            window._mgAudioCtx = ctx;
            window._mgProc = proc;

            function hookElement(el) {
                try {
                    if (el._mgHooked) return;
                    el._mgHooked = true;
                    var src = ctx.createMediaElementSource(el);
                    src.connect(proc);
                    console.log('audioPCM: hooked', el.tagName, el.src || '');
                } catch(e) { console.log('audioPCM: hook failed', e.message); }
            }
            window._mgHookElement = hookElement;

            // Monkey-patch Audio constructor
            var OrigAudio = window.Audio;
            function PatchedAudio(src) {
                var el = src !== undefined ? new OrigAudio(src) : new OrigAudio();
                setTimeout(function() { hookElement(el); }, 0);
                return el;
            }
            PatchedAudio.prototype = OrigAudio.prototype;
            Object.defineProperty(PatchedAudio, 'name', {value: 'Audio'});
            window.Audio = PatchedAudio;

            // Monkey-patch createElement
            var origCreate = document.createElement.bind(document);
            document.createElement = function(tag) {
                var el = origCreate(tag);
                if (tag.toLowerCase() === 'audio' || tag.toLowerCase() === 'video') {
                    setTimeout(function() { hookElement(el); }, 0);
                }
                return el;
            };
        })();
        """
        let earlyScript = WKUserScript(source: earlyJS, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        config.userContentController.addUserScript(earlyScript)

        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height), configuration: config)
        wv.wantsLayer = true
        win.contentView = wv
        wv.navigationDelegate = self
        self.webView = wv

        // Pre-allocate reusable context
        reusableContext = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: rgbColorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )

        // Load the URL
        wv.load(URLRequest(url: url))
        NSLog("WebFrameRenderer: %dx%d, loading %@", width, height, url.absoluteString)
    }

    /// Start capturing frames at the given interval (microseconds)
    @MainActor
    func startCapture(intervalUs: Int) {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .microseconds(intervalUs))
        timer.setEventHandler { [weak self] in
            self?.captureFrame()
        }
        timer.resume()
        self.captureTimer = timer
        NSLog("WebFrameRenderer: capture started (%dµs interval)", intervalUs)
    }

    /// Thread-safe read of the latest captured frame
    func currentFrameRGB24() -> Data? {
        frameLock.lock()
        let frame = _latestFrame
        frameLock.unlock()
        return frame
    }

    /// Must be called on main queue (CALayer.render requires it)
    private func captureFrame() {
        guard let webView, let ctx = reusableContext else { return }

        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        if let layer = webView.layer {
            layer.render(in: ctx)
        }

        guard let data = ctx.data else { return }
        let ptr = data.assumingMemoryBound(to: UInt8.self)
        let pixelCount = width * height

        // Check if frame is blank (first 100 pixels all zero) — GPU compositing issue
        var isBlank = true
        let checkCount = min(100, pixelCount)
        for i in 0..<checkCount {
            if ptr[i * 4] != 0 || ptr[i * 4 + 1] != 0 || ptr[i * 4 + 2] != 0 {
                isBlank = false
                break
            }
        }

        if isBlank && hasFinishedLoading {
            webView.takeSnapshot(with: nil) { [weak self] image, _ in
                guard let self, let image else { return }
                self.convertSnapshotToRGB24(image)
            }
            return
        }

        // Convert BGRA to RGB24, flipping vertically (CALayer renders bottom-up)
        let rowBytes3 = width * 3
        let rowBytes4 = width * 4
        var rgb = Data(count: pixelCount * 3)
        rgb.withUnsafeMutableBytes { dstBuf in
            let dst = dstBuf.bindMemory(to: UInt8.self)
            for y in 0..<height {
                let srcRow = (height - 1 - y) * rowBytes4
                let dstRow = y * rowBytes3
                for x in 0..<width {
                    let s = srcRow + x * 4
                    let d = dstRow + x * 3
                    dst[d]     = ptr[s]
                    dst[d + 1] = ptr[s + 1]
                    dst[d + 2] = ptr[s + 2]
                }
            }
        }

        frameLock.lock()
        _latestFrame = rgb
        frameLock.unlock()
    }

    private func convertSnapshotToRGB24(_ nsImage: NSImage) {
        guard let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = reusableContext else { return }

        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let data = ctx.data else { return }
        let ptr = data.assumingMemoryBound(to: UInt8.self)

        let rowBytes3 = width * 3
        let rowBytes4 = width * 4
        var rgb = Data(count: width * height * 3)
        rgb.withUnsafeMutableBytes { dstBuf in
            let dst = dstBuf.bindMemory(to: UInt8.self)
            for y in 0..<height {
                let srcRow = (height - 1 - y) * rowBytes4
                let dstRow = y * rowBytes3
                for x in 0..<width {
                    let s = srcRow + x * 4
                    let d = dstRow + x * 3
                    dst[d]     = ptr[s]
                    dst[d + 1] = ptr[s + 1]
                    dst[d + 2] = ptr[s + 2]
                }
            }
        }

        frameLock.lock()
        _latestFrame = rgb
        frameLock.unlock()
    }

    @MainActor
    func tearDown() {
        captureTimer?.cancel()
        captureTimer = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "audioPCM")
        webView?.stopLoading()
        webView = nil
        window?.close()
        window = nil
        reusableContext = nil
        onAudioPCM = nil
        frameLock.lock()
        _latestFrame = nil
        frameLock.unlock()
        NSLog("WebFrameRenderer: torn down")
    }
}

// MARK: - WKNavigationDelegate

extension WebFrameRenderer: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        hasFinishedLoading = true
        NSLog("WebFrameRenderer: page loaded")

        // Hide UI chrome and hook any remaining media elements, click unmute
        let js = """
        // Hide UI chrome so the weather display fills the view
        var style = document.createElement('style');
        style.textContent = `
            #divQuery, #divTwcBottom, .content-wrapper { display: none !important; }
            #divTwc, #divTwcMain { width: 100vw !important; height: 100vh !important; }
            body { margin: 0; padding: 0; overflow: hidden; }
        `;
        document.head.appendChild(style);

        // Hook any media elements that exist now
        if (window._mgHookElement) {
            document.querySelectorAll('video,audio').forEach(window._mgHookElement);
        }

        // Watch DOM for future media elements
        if (window._mgHookElement) {
            var obs = new MutationObserver(function(mutations) {
                mutations.forEach(function(m) {
                    m.addedNodes.forEach(function(n) {
                        if (n.tagName === 'VIDEO' || n.tagName === 'AUDIO') window._mgHookElement(n);
                        if (n.querySelectorAll) {
                            n.querySelectorAll('video,audio').forEach(window._mgHookElement);
                        }
                    });
                });
            });
            obs.observe(document.body, {childList: true, subtree: true});
        }

        // WeatherStar: click unmute to start audio playback
        var tm = document.querySelector('#ToggleMedia');
        if (tm) setTimeout(function() { tm.click(); }, 500);
        """
        webView.evaluateJavaScript(js) { _, error in
            if let error {
                NSLog("WebFrameRenderer: JS inject error: %@", error.localizedDescription)
            } else {
                NSLog("WebFrameRenderer: audio capture JS injected")
            }
        }
    }
}

// MARK: - WKScriptMessageHandler (Audio PCM from Web Audio API)

extension WebFrameRenderer: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "audioPCM",
              let b64 = message.body as? String,
              let pcmData = Data(base64Encoded: b64) else { return }
        onAudioPCM?(pcmData)
    }
}
