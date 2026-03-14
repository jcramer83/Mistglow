import SwiftUI

struct WebTab: View {
    @Environment(AppState.self) private var appState
    @State private var urlText: String = ""
    @State private var initialized = false
    @State private var showHistory = false

    private var isActive: Bool {
        appState.webController?.isStreaming == true || appState.webController?.isLoading == true
    }

    private var history: [String] {
        appState.settings.webURLHistory
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                // URL input with history dropdown
                VStack(alignment: .leading, spacing: 4) {
                    Text("Web Page URL")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        TextField("https://example.com", text: $urlText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                            .disabled(isActive)
                            .onSubmit {
                                if !isActive && !urlText.isEmpty {
                                    startWeb()
                                }
                            }
                        if !history.isEmpty && !isActive {
                            Menu {
                                ForEach(history, id: \.self) { url in
                                    Button(action: { urlText = url }) {
                                        Text(displayName(for: url))
                                    }
                                }
                            } label: {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24, height: 22)
                                    .contentShape(Rectangle())
                            }
                            .menuStyle(.borderlessButton)
                            .frame(width: 24)
                        }
                    }
                }

                // Info text
                if !isActive {
                    Text("Streams a web page to MiSTer at the current modeline resolution. Audio from the page is captured automatically.")
                        .font(.system(size: 11))
                        .foregroundStyle(.quaternary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)

            Spacer()

            // Status indicator
            if isActive {
                HStack(spacing: 6) {
                    if appState.webController?.isLoading == true {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading page...")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        Circle()
                            .fill(.green)
                            .frame(width: 6, height: 6)
                            .shadow(color: .green.opacity(0.6), radius: 4)
                        Text("Streaming to \(appState.settings.targetIP)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 8)
            }

            // Start/Stop button
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isActive {
                        stopWeb()
                    } else {
                        startWeb()
                    }
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: isActive ? "stop.fill" : "globe")
                        .font(.system(size: 10))
                    Text(isActive ? "Stop Web Stream" : "Stream Web Page")
                        .font(.system(size: 12, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .foregroundStyle(.white)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .glassButton(
                tint: isActive ? .red : .cyan,
                interactive: true,
                shape: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .disabled(urlText.isEmpty && !isActive)
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .onAppear {
            if !initialized {
                urlText = appState.settings.webURL
                initialized = true
            }
        }
        .onChange(of: urlText) { _, newValue in
            appState.settings.webURL = newValue
            appState.settings.save()
        }
    }

    private func startWeb() {
        // Stop other sources
        if appState.plexController != nil {
            appState.stopPlexReceiver()
            appState.settings.plexEnabled = false
            appState.settings.save()
        }
        if appState.isStreaming {
            appState.stopStreaming()
        }

        // Add to history (most recent first, max 5, no duplicates)
        addToHistory(urlText)

        let controller = WebStreamController(appState: appState)
        appState.webController = controller
        controller.startStreaming(url: urlText)
    }

    private func stopWeb() {
        appState.webController?.stopStreaming()
        appState.webController = nil
    }

    private func addToHistory(_ url: String) {
        var hist = appState.settings.webURLHistory
        hist.removeAll { $0 == url }
        hist.insert(url, at: 0)
        if hist.count > 5 {
            hist = Array(hist.prefix(5))
        }
        appState.settings.webURLHistory = hist
        appState.settings.save()
    }

    /// Show a readable name for the URL in the history menu
    private func displayName(for url: String) -> String {
        guard let parsed = URL(string: url) else { return url }
        let host = parsed.host ?? url
        if host.count > 30 {
            return String(host.prefix(30)) + "..."
        }
        return host
    }
}
