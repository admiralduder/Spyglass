import SwiftUI

extension View {
    /// A frosted glass panel. Uses Liquid Glass on iOS 26, and a thin material
    /// with a fine light edge on earlier versions.
    func glassCard(cornerRadius: CGFloat = 16, tint: Color? = nil) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius, tint: tint))
    }
}

private struct GlassCardModifier: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color?

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous) }

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(tint.map { Glass.regular.tint($0) } ?? .regular, in: shape)
        } else {
            content
                .background {
                    ZStack {
                        shape.fill(.ultraThinMaterial)
                        if let tint { shape.fill(tint) }
                    }
                }
                .overlay { shape.strokeBorder(.white.opacity(0.22), lineWidth: 0.5) }
                .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
        }
    }
}
