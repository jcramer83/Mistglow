import SwiftUI

struct LogTab: View {
    @Environment(AppState.self) private var appState

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var logText: String {
        appState.logEntries.map { entry in
            "\(Self.timeFormatter.string(from: entry.timestamp)) \(entry.message)"
        }.joined(separator: "\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(appState.logEntries) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Text(Self.timeFormatter.string(from: entry.timestamp))
                                    .foregroundStyle(.tertiary)
                                Text(entry.message)
                                    .foregroundStyle(entry.isError ? .red : .primary.opacity(0.8))
                                    .textSelection(.enabled)
                            }
                            .font(.system(size: 10, design: .monospaced))
                            .id(entry.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .onChange(of: appState.logEntries.count) { _, _ in
                    if let last = appState.logEntries.last {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            // Bottom toolbar
            Rectangle()
                .fill(.quaternary)
                .frame(height: 0.5)

            HStack(spacing: 6) {
                HoverButton(icon: "doc.on.doc", label: nil) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(logText, forType: .string)
                }
                .help("Copy Log")

                HoverButton(icon: "trash", label: nil) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        appState.logEntries.removeAll()
                    }
                }
                .help("Clear Log")

                Spacer()

                Text("\(appState.logEntries.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .glassPill()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }
}
