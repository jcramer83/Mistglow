import SwiftUI

struct SettingsRow<Content: View>: View {
    let label: String
    let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(label)
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
                .frame(width: 85, alignment: .trailing)
                .padding(.trailing, 12)
            content
            Spacer(minLength: 0)
        }
        .frame(height: 24)
    }
}

struct SectionHeader: View {
    let title: String

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .tracking(0.5)
            Rectangle()
                .fill(.quaternary)
                .frame(height: 0.5)
        }
        .padding(.horizontal, 20)
    }
}
