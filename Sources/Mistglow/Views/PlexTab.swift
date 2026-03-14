import SwiftUI

struct PlexTab: View {
    @Environment(AppState.self) private var appState
    @State private var isScrubbing = false
    @State private var scrubMs: Int = 0
    @State private var showPlexHelp = false

    var body: some View {
        VStack(spacing: 0) {
            if let plex = appState.plexController, plex.isPlaying || plex.isPaused {
                nowPlayingView(plex)
            } else if appState.plexController != nil {
                waitingView
            } else {
                offView
            }

            Spacer()

            // Status indicator
            if appState.plexController != nil {
                HStack(spacing: 6) {
                    Circle()
                        .fill(.green)
                        .frame(width: 6, height: 6)
                        .shadow(color: .green.opacity(0.6), radius: 4)
                    Text(appState.isStreaming ? "Streaming to \(appState.settings.targetIP)" : "Listening on port 3005")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 8)
            }

            // Listen for Plex button
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
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
                    AppDelegate.shared?.updateStatusIcon()
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: appState.plexController != nil ? "stop.fill" : "play.tv")
                        .font(.system(size: 10))
                    Text(appState.plexController != nil ? "Stop Plex Receiver" : "Listen for Plex")
                        .font(.system(size: 12, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .foregroundStyle(.white)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .glassButton(
                tint: appState.plexController != nil ? .red : .purple,
                interactive: true,
                shape: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            // Auto modeline toggle
            @Bindable var state = appState
            Toggle("Auto PAL/NTSC modeline", isOn: $state.settings.plexAutoModeline)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
                .onChange(of: appState.settings.plexAutoModeline) { _, _ in
                    appState.settings.save()
                }
        }
    }

    // MARK: - Now Playing

    @ViewBuilder
    private func nowPlayingView(_ plex: PlexPlaybackController) -> some View {
        VStack(spacing: 12) {
            // Thumbnail + Title
            if plex.nowPlayingShowName != nil {
                // TV show: thumbnail left, title right
                HStack(spacing: 12) {
                    if let thumb = plex.thumbImage {
                        Image(nsImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 90, height: 130)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(plex.nowPlayingShowName ?? "")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        if let episodeInfo = plex.nowPlayingEpisodeInfo {
                            Text(episodeInfo)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        if plex.isPaused {
                            Text("Paused")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.orange)
                        }
                    }
                    Spacer(minLength: 0)
                }
            } else {
                // Movie: centered layout
                VStack(spacing: 8) {
                    if let thumb = plex.thumbImage {
                        Image(nsImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 90, height: 130)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
                    }
                    Text(plex.nowPlayingTitle ?? "Playing from Plex")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .multilineTextAlignment(.center)
                    if plex.isPaused {
                        Text("Paused")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity)
            }

            // Scrubbable progress bar
            if plex.durationMs > 0 {
                let displayMs = isScrubbing ? scrubMs : plex.currentTimeMs
                VStack(spacing: 4) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(.white.opacity(0.15))
                                .frame(height: 6)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(isScrubbing ? .purple.opacity(0.7) : .purple)
                                .frame(width: max(0, geo.size.width * CGFloat(displayMs) / CGFloat(plex.durationMs)), height: 6)
                        }
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let fraction = max(0, min(1, value.location.x / geo.size.width))
                                    scrubMs = Int(fraction * CGFloat(plex.durationMs))
                                    isScrubbing = true
                                }
                                .onEnded { value in
                                    let fraction = max(0, min(1, value.location.x / geo.size.width))
                                    let seekMs = Int(fraction * CGFloat(plex.durationMs))
                                    isScrubbing = false
                                    plex.seekTo(ms: seekMs)
                                }
                        )
                    }
                    .frame(height: 20)

                    HStack {
                        Text(formatTime(displayMs))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(formatTime(plex.durationMs))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Transport controls
            HStack(spacing: 20) {
                Spacer()

                Button(action: { plex.skipPrevious() }) {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)

                Button(action: { plex.togglePause() }) {
                    Image(systemName: plex.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(.purple.opacity(0.3)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)

                Button(action: { plex.skipNext() }) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)

                Button(action: { plex.stopPlaybackFromUI() }) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)

                Spacer()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    // MARK: - Idle States

    private var waitingView: some View {
        VStack(spacing: 12) {
            Image(systemName: "play.tv")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("Waiting for Plex...")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text("Cast from any Plex app to start")
                .font(.system(size: 11))
                .foregroundStyle(.quaternary)

            plexHelpButton
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private var offView: some View {
        VStack(spacing: 12) {
            Image(systemName: "play.tv")
                .font(.system(size: 32))
                .foregroundStyle(.quaternary)
            Text("Plex receiver is off")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text("Press the button below to start listening")
                .font(.system(size: 11))
                .foregroundStyle(.quaternary)

            plexHelpButton
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private var plexHelpButton: some View {
        Button(action: { showPlexHelp = true }) {
            HStack(spacing: 4) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                Text("How to cast")
                    .font(.system(size: 11))
            }
            .foregroundStyle(.blue)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPlexHelp, arrowEdge: .bottom) {
            plexHelpContent
        }
    }

    // MARK: - Help Popover

    private var plexHelpContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How to cast to Mistglow")
                .font(.system(size: 13, weight: .semibold))

            VStack(alignment: .leading, spacing: 6) {
                helpStep(1, "Open any Plex app (mobile, web, or desktop)")
                helpStep(2, "Play something and tap the cast/player icon")
                helpStep(3, "Select \"MiSTer\" from the device list")
                helpStep(4, "Content will stream to your MiSTer FPGA")
            }
        }
        .padding(16)
        .frame(width: 280)
    }

    private func helpStep(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number).")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.purple)
                .frame(width: 16, alignment: .trailing)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    private func formatTime(_ ms: Int) -> String {
        let totalSeconds = ms / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
