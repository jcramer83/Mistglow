import SwiftUI

struct CaptureTab: View {
    @Environment(AppState.self) private var appState
    @State private var showDesktopInfo = false

    private var plexActive: Bool {
        appState.settings.plexEnabled
    }

    var body: some View {
        @Bindable var state = appState

        VStack(spacing: 0) {
            // Info line
            HStack(spacing: 4) {
                Button(action: { showDesktopInfo = true }) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showDesktopInfo, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Desktop Streaming")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Captures the selected display and streams it to your MiSTer FPGA in real-time. Audio is captured and sent alongside video.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .frame(width: 260)
                }

                Text("Streams Display \(appState.settings.displayIndex + 1) to MiSTer")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 4)

            VStack(spacing: 12) {
                SettingsRow("Display") {
                    Picker("", selection: $state.settings.displayIndex) {
                        ForEach(0..<max(appState.displayCount, 1), id: \.self) { index in
                            Text("Display \(index + 1)").tag(index)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 180, alignment: .leading)
                }

                SettingsRow("Crop") {
                    Picker("", selection: $state.settings.cropMode) {
                        ForEach(CropMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 180, alignment: .leading)
                    .onChange(of: appState.settings.cropMode) { _, _ in
                        appState.updateCropForMode()
                    }
                }

                SettingsRow("Alignment") {
                    Picker("", selection: $state.settings.alignment) {
                        ForEach(Alignment.allCases, id: \.self) { align in
                            Text(align.displayName).tag(align)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 180, alignment: .leading)
                    .onChange(of: appState.settings.alignment) { _, _ in
                        appState.updateCropForMode()
                    }
                }

                SettingsRow("Rotation") {
                    Picker("", selection: $state.settings.rotation) {
                        ForEach(Rotation.allCases, id: \.self) { rot in
                            Text(rot.displayName).tag(rot)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 180, alignment: .leading)
                }

                SettingsRow("Preview") {
                    Toggle("", isOn: Binding(
                        get: { appState.isPreviewing },
                        set: { newValue in
                            withAnimation(.easeInOut(duration: 0.25)) {
                                if newValue { appState.startPreview() }
                                else { appState.stopPreview() }
                            }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }

                if appState.settings.cropMode == .custom {
                    SettingsRow("Size") {
                        HStack(spacing: 4) {
                            CompactField(value: $state.settings.cropWidth, placeholder: "W")
                            Text("\u{00D7}")
                                .foregroundStyle(.tertiary)
                                .font(.system(size: 11))
                            CompactField(value: $state.settings.cropHeight, placeholder: "H")
                        }
                    }
                    SettingsRow("Offset") {
                        HStack(spacing: 4) {
                            CompactField(value: $state.settings.cropOffsetX, placeholder: "X")
                            Text(",")
                                .foregroundStyle(.tertiary)
                                .font(.system(size: 11))
                            CompactField(value: $state.settings.cropOffsetY, placeholder: "Y")
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            Spacer()

            // Status indicator
            if appState.isStreaming && appState.plexController == nil {
                HStack(spacing: 6) {
                    Circle()
                        .fill(.green)
                        .frame(width: 6, height: 6)
                        .shadow(color: .green.opacity(0.6), radius: 4)
                    Text("Streaming to \(appState.settings.targetIP)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            // Preview area
            if appState.isPreviewing {
                if let image = appState.previewImage {
                    Image(decorative: image, scale: 1.0)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
                        )
                        .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.black.opacity(0.2))
                        .frame(height: 60)
                        .overlay(ProgressView().controlSize(.small))
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                }
            }

            // Stream Desktop button
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if appState.isStreaming && appState.plexController == nil {
                        appState.stopStreaming()
                    } else {
                        // Stop Plex if active
                        if appState.plexController != nil {
                            appState.stopPlexReceiver()
                            appState.settings.plexEnabled = false
                            appState.settings.save()
                        }
                        if appState.isStreaming { appState.stopStreaming() }
                        appState.settings.save()
                        appState.startStreaming()
                    }
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: (appState.isStreaming && appState.plexController == nil) ? "stop.fill" : "play.fill")
                        .font(.system(size: 10))
                    Text((appState.isStreaming && appState.plexController == nil) ? "Stop Streaming" : "Stream Desktop")
                        .font(.system(size: 12, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .foregroundStyle(.white)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .glassButton(
                tint: (appState.isStreaming && appState.plexController == nil) ? .red : .accentColor,
                interactive: true,
                shape: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .disabled(plexActive)
            .opacity(plexActive ? 0.4 : 1.0)
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
    }
}

struct CompactField: View {
    @Binding var value: Int
    let placeholder: String

    var body: some View {
        TextField(placeholder, value: $value, format: .number)
            .textFieldStyle(.roundedBorder)
            .frame(width: 56)
            .font(.system(size: 11))
    }
}

struct PreviewWindowView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            if let image = appState.previewImage {
                Image(decorative: image, scale: 1.0)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Text("Waiting for frames...")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
            }
        }
    }
}
