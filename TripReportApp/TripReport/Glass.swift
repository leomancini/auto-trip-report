import SwiftUI

/// One gap and one corner radius for the whole app.
enum Metrics {
    static let gap: CGFloat = 20
    static let radius: CGFloat = 16
}

// Liquid Glass on macOS 26+, system materials before that. Standard controls
// (toolbar, sidebar, buttons, menus) pick up the new design on their own.

extension View {
    /// The slight shadow shared by every card and photo.
    func cardShadow() -> some View {
        shadow(color: .black.opacity(0.25), radius: 14, y: 4)
    }

    /// A floating panel surface.
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = Metrics.radius) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    /// A colored panel: tinted glass on macOS 26, a soft gradient before that.
    @ViewBuilder
    func tintedCard(_ color: Color, foreground: Color = .white,
                    cornerRadius: CGFloat = Metrics.radius) -> some View {
        if #available(macOS 26.0, *) {
            foregroundStyle(foreground)
                .glassEffect(.regular.tint(color.opacity(0.75)), in: .rect(cornerRadius: cornerRadius))
                .cardShadow()
        } else {
            foregroundStyle(foreground)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .cardShadow()
        }
    }

    /// A small floating badge.
    @ViewBuilder
    func glassBadge() -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: .capsule)
        } else {
            background(.thinMaterial, in: Capsule())
        }
    }

    @ViewBuilder
    func prominentActionStyle() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    func secondaryActionStyle() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }
}

/// Groups nearby glass surfaces so they blend and morph together on macOS 26.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 10
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}
