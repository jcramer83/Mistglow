import SwiftUI

enum AppTab: Int, CaseIterable {
    case settings, plex, capture, debug

    var title: String {
        switch self {
        case .settings: "Settings"
        case .plex: "Plex"
        case .capture: "Desktop"
        case .debug: "Debug"
        }
    }

    var icon: String {
        switch self {
        case .settings: "gear"
        case .plex: "play.tv"
        case .capture: "display"
        case .debug: "wrench.and.screwdriver"
        }
    }
}

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedTab: AppTab = .settings

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            GlassContainer(spacing: 8) {
                HStack(spacing: 4) {
                    ForEach(AppTab.allCases, id: \.self) { tab in
                        TabButton(tab: tab, isSelected: selectedTab == tab) {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedTab = tab
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 10)

            // Separator
            Rectangle()
                .fill(.quaternary)
                .frame(height: 0.5)

            // Tab content with crossfade
            ZStack {
                switch selectedTab {
                case .settings:
                    StreamTab()
                        .transition(.opacity)
                case .plex:
                    PlexTab()
                        .transition(.opacity)
                case .capture:
                    CaptureTab()
                        .transition(.opacity)
                case .debug:
                    DebugTab()
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.15), value: selectedTab)
        }
        .frame(width: 400, height: 420)
        .background(VisualEffectBackground())
        .background(WindowAccessor())
        .task {
            appState.initialize()
            await appState.refreshDisplays()
        }
        .onChange(of: appState.settings.targetIP) { _, _ in appState.settings.save() }
        .onChange(of: appState.selectedPresetIndex) { _, _ in appState.settings.save() }
        .onChange(of: appState.settings.modeline.interlace) { _, _ in appState.settings.save() }
        .onChange(of: appState.settings.displayIndex) { _, _ in appState.settings.save() }
        .onChange(of: appState.settings.cropMode) { _, _ in appState.settings.save() }
        .onChange(of: appState.settings.alignment) { _, _ in appState.settings.save() }
        .onChange(of: appState.settings.rotation) { _, _ in appState.settings.save() }
        .onChange(of: appState.settings.plexEnabled) { _, _ in appState.settings.save() }
    }
}

// MARK: - Tab Button

struct TabButton: View {
    let tab: AppTab
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: tab.icon)
                    .font(.system(size: 18, weight: isSelected ? .medium : .regular))
                    .symbolRenderingMode(.hierarchical)
                    .frame(height: 20)
                Text(tab.title)
                    .font(.system(size: 10, weight: isSelected ? .medium : .regular))
            }
            .frame(width: 58, height: 46)
            .foregroundStyle(isSelected ? .white : (isHovered ? .primary : .secondary))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .glassTab(isSelected: isSelected, tint: .accentColor)
        .background(
            !isSelected && isHovered
                ? AnyShapeStyle(.quaternary)
                : AnyShapeStyle(Color.clear),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Visual Effect Background

struct VisualEffectBackground: View {
    var body: some View {
        Color(nsColor: NSColor(white: 0.18, alpha: 1.0))
    }
}

// MARK: - Window Configuration

struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.backgroundColor = NSColor(white: 0.18, alpha: 1.0)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.remove(.resizable)
            window.isMovableByWindowBackground = true

            // Add centered title label in the titlebar
            let titleLabel = NSTextField(labelWithString: "Mistglow")
            titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
            titleLabel.textColor = NSColor.white.withAlphaComponent(0.85)
            titleLabel.alignment = .left
            titleLabel.translatesAutoresizingMaskIntoConstraints = false

            let titleContainer = NSView()
            titleContainer.addSubview(titleLabel)
            NSLayoutConstraint.activate([
                titleLabel.leadingAnchor.constraint(equalTo: titleContainer.leadingAnchor, constant: 8),
                titleLabel.centerYAnchor.constraint(equalTo: titleContainer.centerYAnchor),
            ])

            let accessory = NSTitlebarAccessoryViewController()
            accessory.view = titleContainer
            accessory.layoutAttribute = .top
            window.addTitlebarAccessoryViewController(accessory)
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
