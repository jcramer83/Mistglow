import SwiftUI

struct DebugTab: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        VStack(spacing: 0) {
            // Warning banner
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 11))
                Text("Advanced settings — only change if you know what you're doing")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.orange.opacity(0.08))
                    .strokeBorder(.orange.opacity(0.15), lineWidth: 0.5)
            )
            .padding(.horizontal, 20)
            .padding(.top, 12)

            VStack(spacing: 12) {
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

            // Current modeline details
            VStack(spacing: 0) {
                HStack {
                    Text("Current Modeline")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 4)

                let m = appState.settings.modeline
                VStack(alignment: .leading, spacing: 2) {
                    debugRow("Name", m.name)
                    debugRow("pClock", String(format: "%.3f MHz", m.pClock))
                    debugRow("H", "\(m.hActive) \(m.hBegin) \(m.hEnd) \(m.hTotal)")
                    debugRow("V", "\(m.vActive) \(m.vBegin) \(m.vEnd) \(m.vTotal)")
                    debugRow("Interlace", m.interlace ? "Yes" : "No")

                    let frameRate = Double(m.pClock) * 1_000_000.0 / (Double(m.hTotal) * Double(m.vTotal))
                    let fieldRate = m.interlace ? frameRate * 2.0 : frameRate
                    debugRow("Frame rate", String(format: "%.3f fps", frameRate))
                    if m.interlace {
                        debugRow("Field rate", String(format: "%.3f fields/s", fieldRate))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            .background(Color.black.opacity(0.25))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.white.opacity(0.06), lineWidth: 0.5)
            )
            .padding(.horizontal, 12)
            .padding(.top, 12)

            Spacer()
        }
    }

    private func debugRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(.tertiary)
                .frame(width: 70, alignment: .trailing)
            Text(value)
                .foregroundStyle(.primary.opacity(0.7))
        }
        .font(.system(size: 9, design: .monospaced))
    }
}
