import SwiftUI

struct StreamTab: View {
    @Environment(AppState.self) private var appState
    @State private var showHelp = false
    @State private var showPermissions = false

    var body: some View {
        @Bindable var state = appState

        VStack(spacing: 0) {
            VStack(spacing: 12) {
                SettingsRow("Target") {
                    TextField("IP or hostname", text: $state.settings.targetIP)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                        .disabled(appState.isStreaming)
                }

                SettingsRow("Modeline") {
                    Picker("", selection: $state.selectedPresetIndex) {
                        ForEach(Array(Modeline.presets.enumerated()), id: \.offset) { index, preset in
                            Text(preset.name).tag(index)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                    .onChange(of: appState.selectedPresetIndex) { _, newValue in
                        appState.applyPreset(newValue)
                        appState.updateCropForMode()
                    }
                }

                SettingsRow("Interlaced") {
                    Toggle("", isOn: $state.settings.modeline.interlace)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }

                SettingsRow("Audio") {
                    Toggle("", isOn: $state.settings.audioEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            // Permission warning
            if appState.needsScreenRecording {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .font(.system(size: 11))
                    Text("Screen Recording permission required")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Fix") {
                        appState.openScreenRecordingSettings()
                    }
                    .font(.system(size: 11, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.yellow.opacity(0.1))
                        .strokeBorder(.yellow.opacity(0.2), lineWidth: 0.5)
                )
                .padding(.horizontal, 20)
                .padding(.top, 4)
            }

            Spacer()

            // Status indicator
            if appState.isStreaming {
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

            // Stream button
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if appState.isStreaming {
                        appState.stopStreaming()
                    } else {
                        appState.settings.save()
                        appState.startStreaming()
                    }
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: appState.isStreaming ? "stop.fill" : "play.fill")
                        .font(.system(size: 10))
                    Text(appState.isStreaming ? "Stop Streaming" : "Start Streaming")
                        .font(.system(size: 12, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .foregroundStyle(.white)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .glassButton(
                tint: appState.isStreaming ? .red : .accentColor,
                interactive: true,
                shape: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .padding(.horizontal, 20)

            // Bottom toolbar
            HStack {
                HoverButton(icon: "info.circle", label: "Permissions") {
                    showPermissions = true
                }
                .popover(isPresented: $showPermissions, arrowEdge: .top) {
                    PermissionsInfoView()
                }

                Spacer()

                HoverButton(icon: "questionmark.circle", label: "Help") {
                    showHelp = true
                }
                .sheet(isPresented: $showHelp) {
                    HelpView()
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
    }
}

struct PermissionsInfoView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Required Permissions")
                .font(.system(size: 13, weight: .semibold))

            PermissionRow(
                icon: "rectangle.dashed.badge.record",
                title: "Screen Recording",
                description: "Capture your display to stream to MiSTer",
                granted: !appState.needsScreenRecording
            )

            PermissionRow(
                icon: "mic.fill",
                title: "Microphone / Audio",
                description: "Capture system audio for streaming",
                granted: true // Audio uses SCStream which is covered by Screen Recording
            )

            Divider()

            Button(action: {
                appState.openScreenRecordingSettings()
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "gear")
                        .font(.system(size: 11))
                    Text("Open System Settings")
                        .font(.system(size: 12))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
        .padding(16)
        .frame(width: 260)
    }
}

struct PermissionRow: View {
    let icon: String
    let title: String
    let description: String
    let granted: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(granted ? .green : .orange)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                    Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(granted ? .green : .orange)
                }
                Text(description)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct HoverButton: View {
    let icon: String
    let label: String?
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                if let label {
                    Text(label)
                        .font(.system(size: 11))
                }
            }
            .foregroundStyle(isHovered ? .primary : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassHover(isHovered: isHovered)
        .onHover { h in
            withAnimation(.easeInOut(duration: 0.12)) { isHovered = h }
        }
    }
}
