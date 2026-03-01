import SwiftUI
import AppKit

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?
    var appState: AppState?
    private var statusItem: NSStatusItem?
    private var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        setupStatusItem()

        // Find and configure the main window to hide on close instead of destroying
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.hookMainWindow()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showWindow()
        }
        return true
    }

    private func hookMainWindow() {
        if let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.title != "Preview" }) {
            self.mainWindow = window
            window.delegate = self
        }
    }

    // MARK: - Menu Bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            let image = NSImage(systemSymbolName: "play.tv", accessibilityDescription: "Mistglow")
            image?.isTemplate = true
            button.image = image
            button.action = #selector(statusItemClicked)
            button.target = self
        }
    }

    @objc func statusItemClicked() {
        let menu = NSMenu()

        let showItem = NSMenuItem(title: "Show Window", action: #selector(showWindowAction), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Mistglow", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        DispatchQueue.main.async { [weak self] in
            self?.statusItem?.menu = nil
        }
    }

    func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let isActive = appState?.isStreaming == true || appState?.plexController != nil
        let symbolName = isActive ? "play.tv.fill" : "play.tv"
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Mistglow")
        image?.isTemplate = true
        button.image = image
    }

    @objc func showWindowAction() {
        showWindow()
    }

    func showWindow() {
        if let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func toggleStreaming() {
        guard let appState else { return }
        if appState.isStreaming {
            appState.stopStreaming()
        } else {
            appState.startStreaming()
        }
        updateStatusIcon()
    }

    @objc func togglePlex() {
        guard let appState else { return }
        if appState.plexController != nil {
            appState.stopPlexReceiver()
            appState.settings.plexEnabled = false
            if appState.isStreaming { appState.stopStreaming() }
        } else {
            if appState.isStreaming { appState.stopStreaming() }
            appState.settings.plexEnabled = true
            appState.startPlexReceiver()
        }
        appState.settings.save()
        updateStatusIcon()
    }

    @objc func quitApp() {
        appState?.streamEngine?.stopSync()
        appState?.settings.save()
        NSApp.terminate(nil)
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

@main
struct MistglowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .onAppear {
                    AppDelegate.shared?.appState = appState
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    appState.streamEngine?.stopSync()
                    appState.plexController?.disable()
                    appState.settings.save()
                }
                .onChange(of: appState.isStreaming) { _, _ in
                    AppDelegate.shared?.updateStatusIcon()
                }
        }
        .windowResizability(.contentSize)

        Window("Preview", id: "preview") {
            PreviewWindowView()
                .environment(appState)
        }
        .defaultSize(width: 640, height: 480)
    }
}
