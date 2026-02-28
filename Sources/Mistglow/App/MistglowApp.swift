import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?
    var statusItem: NSStatusItem!
    var appState: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "antenna.radiowaves.left.and.right",
                                   accessibilityDescription: "Mistglow")
            button.action = #selector(statusItemClicked)
            button.target = self
        }
    }

    @objc func statusItemClicked() {
        let menu = NSMenu()
        menu.delegate = self
        populateMenu(menu)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    private func populateMenu(_ menu: NSMenu) {
        let isStreaming = appState?.isStreaming ?? false
        let target = appState?.settings.targetIP ?? "unknown"

        let statusLine = NSMenuItem(
            title: isStreaming ? "Streaming to \(target)" : "Idle",
            action: nil, keyEquivalent: ""
        )
        statusLine.isEnabled = false
        menu.addItem(statusLine)

        menu.addItem(NSMenuItem.separator())

        let toggleItem = NSMenuItem(
            title: isStreaming ? "Stop Streaming" : "Start Streaming",
            action: #selector(toggleStreaming),
            keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(NSMenuItem.separator())

        let showItem = NSMenuItem(
            title: "Show Window",
            action: #selector(showWindow),
            keyEquivalent: ""
        )
        showItem.target = self
        menu.addItem(showItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Quit Mistglow",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running in menu bar
        NSApp.setActivationPolicy(.accessory)
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showWindow()
        }
        return true
    }

    @objc func showWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            // Re-open the window group
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc func toggleStreaming() {
        guard let appState else { return }
        if appState.isStreaming {
            appState.stopStreaming()
        } else {
            appState.settings.save()
            appState.startStreaming()
        }
    }

    @objc func quitApp() {
        appState?.streamEngine?.stopSync()
        appState?.settings.save()
        NSApp.terminate(nil)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuDidClose(_ menu: NSMenu) {
        // Clear the menu so the button action fires on next click
        statusItem.menu = nil
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
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    appState.streamEngine?.stopSync()
                    appState.settings.save()
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
