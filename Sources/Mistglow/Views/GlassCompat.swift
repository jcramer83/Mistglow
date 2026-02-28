import SwiftUI

// Compatibility wrapper for Liquid Glass on macOS 26+
// Falls back to custom styling on older systems

extension View {
    @ViewBuilder
    func glassButton(tint: Color? = nil, interactive: Bool = false, shape: some Shape = Capsule()) -> some View {
        if #available(macOS 26.0, *) {
            let base = Glass.regular
            let tinted = tint != nil ? base.tint(tint!) : base
            let final_ = interactive ? tinted.interactive() : tinted
            self.glassEffect(final_, in: shape)
        } else {
            self.background(shape.fill(tint ?? Color.accentColor))
        }
    }

    @ViewBuilder
    func glassTab(isSelected: Bool, tint: Color, shape: some Shape = RoundedRectangle(cornerRadius: 10, style: .continuous)) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(
                isSelected ? .regular.tint(tint).interactive() : .identity,
                in: shape
            )
        } else {
            self.background(
                shape.fill(isSelected ? AnyShapeStyle(tint) : AnyShapeStyle(Color.clear))
            )
        }
    }

    @ViewBuilder
    func glassHover(isHovered: Bool, shape: some Shape = Capsule()) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(
                isHovered ? .regular : .identity,
                in: shape
            )
        } else {
            self.background(
                shape.fill(isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.clear))
            )
        }
    }

    @ViewBuilder
    func glassPill(shape: some Shape = Capsule()) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(shape.fill(.quaternary))
        }
    }
}

// Wrapper for GlassEffectContainer
struct GlassContainer<Content: View>: View {
    let spacing: CGFloat
    let content: Content

    init(spacing: CGFloat = 8, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}
