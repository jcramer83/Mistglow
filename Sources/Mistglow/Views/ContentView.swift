import SwiftUI

enum AppTab: Int, CaseIterable {
    case stream, capture, log

    var title: String {
        switch self {
        case .stream: "Stream"
        case .capture: "Capture"
        case .log: "Log"
        }
    }

    var icon: String {
        switch self {
        case .stream: "antenna.radiowaves.left.and.right"
        case .capture: "display"
        case .log: "doc.text"
        }
    }
}

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedTab: AppTab = .stream

    var body: some View {
        VStack(spacing: 0) {
            // Drag area + Title
            VStack(spacing: 0) {
                Color.clear.frame(height: 8)

                Text("Mistglow")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.8))
                    .padding(.bottom, 8)

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
                .padding(.bottom, 10)
            }

            // Separator
            Rectangle()
                .fill(.quaternary)
                .frame(height: 0.5)

            // Tab content with crossfade
            ZStack {
                switch selectedTab {
                case .stream:
                    StreamTab()
                        .transition(.opacity)
                case .capture:
                    CaptureTab()
                        .transition(.opacity)
                case .log:
                    LogTab()
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.15), value: selectedTab)
        }
        .frame(width: 400, height: 380)
        .background(VisualEffectBackground())
        .background(WindowAccessor())
        .task {
            appState.initialize()
            await appState.refreshDisplays()
        }
        .onAppear {
            AppDelegate.shared?.appState = appState
        }
        .onChange(of: appState.settings.targetIP) { _, _ in appState.settings.save() }
        .onChange(of: appState.selectedPresetIndex) { _, _ in appState.settings.save() }
        .onChange(of: appState.settings.modeline.interlace) { _, _ in appState.settings.save() }
        .onChange(of: appState.settings.audioEnabled) { _, _ in appState.settings.save() }
        .onChange(of: appState.settings.displayIndex) { _, _ in appState.settings.save() }
        .onChange(of: appState.settings.cropMode) { _, _ in appState.settings.save() }
        .onChange(of: appState.settings.alignment) { _, _ in appState.settings.save() }
        .onChange(of: appState.settings.rotation) { _, _ in appState.settings.save() }
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
            .frame(width: 72, height: 46)
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

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .titlebar
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Window Configuration

struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.styleMask.remove(.resizable)
            window.isMovableByWindowBackground = true
            window.hasShadow = true
            if let contentView = window.contentView {
                contentView.wantsLayer = true
                contentView.layer?.cornerRadius = 14
                contentView.layer?.masksToBounds = true
            }
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
