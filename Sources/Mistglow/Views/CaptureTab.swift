import SwiftUI

struct CaptureTab: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        VStack(spacing: 0) {
            VStack(spacing: 12) {
                SettingsRow("Display") {
                    Picker("", selection: $state.settings.displayIndex) {
                        ForEach(0..<max(appState.displayCount, 1), id: \.self) { index in
                            Text("Display \(index + 1)").tag(index)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }

                SettingsRow("Crop") {
                    Picker("", selection: $state.settings.cropMode) {
                        ForEach(CropMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
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
                    .frame(width: 180)
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
                    .frame(width: 180)
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

            // Preview button
            Button(action: {
                withAnimation(.easeInOut(duration: 0.25)) {
                    if appState.isPreviewing {
                        appState.stopPreview()
                    } else {
                        appState.startPreview()
                    }
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: appState.isPreviewing ? "eye.slash.fill" : "eye.fill")
                        .font(.system(size: 10))
                    Text(appState.isPreviewing ? "Stop Preview" : "Start Preview")
                        .font(.system(size: 12, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .foregroundStyle(appState.isPreviewing ? .white : .primary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .glassButton(
                tint: appState.isPreviewing ? .orange : nil,
                interactive: true,
                shape: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
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
