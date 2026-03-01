import SwiftUI

struct StreamTab: View {
    @Environment(AppState.self) private var appState
    @State private var showHelp = false
    @State private var showPermissions = false

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

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
                    .frame(maxWidth: 180, alignment: .leading)
                    .onChange(of: appState.selectedPresetIndex) { _, newValue in
                        appState.applyPreset(newValue)
                        appState.updateCropForMode()
                    }
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

            // Log (newest first, fills remaining space)
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text("Log")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)

                    Spacer()

                    HoverButton(icon: "doc.on.doc", label: nil) {
                        let text = appState.logEntries.map {
                            "\(Self.timeFormatter.string(from: $0.timestamp)) \($0.message)"
                        }.joined(separator: "\n")
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    .help("Copy Log")

                    HoverButton(icon: "trash", label: nil) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            appState.logEntries.removeAll()
                        }
                    }
                    .help("Clear Log")
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 4)

                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(appState.logEntries.reversed()) { entry in
                            HStack(alignment: .top, spacing: 6) {
                                Text(Self.timeFormatter.string(from: entry.timestamp))
                                    .foregroundStyle(.tertiary)
                                Text(entry.message)
                                    .foregroundStyle(entry.isError ? .red : .primary.opacity(0.7))
                                    .textSelection(.enabled)
                            }
                            .font(.system(size: 9, design: .monospaced))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
            }
            .background(Color.black.opacity(0.25))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.white.opacity(0.06), lineWidth: 0.5)
            )
            .padding(.horizontal, 12)
            .padding(.top, 10)
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
