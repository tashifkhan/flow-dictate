import AppKit
import SwiftUI

/// The dictation HUD's colors. System colors throughout, so the bars follow the macOS
/// accent color and the text reads correctly on clear glass in either appearance.
enum HUDPalette {
    static let ink = Color.primary
    static let muted = Color.secondary
    static let surface = Color(nsColor: .windowBackgroundColor)
    static let accent = Color.accentColor
    static let accentInk = Color.accentColor
    static let warning = Color(nsColor: .systemOrange)
}

/// Clear Liquid Glass for the floating panel, untinted, with a solid fallback when
/// Reduce Transparency or Increase Contrast is on.
private struct HUDSurface: ViewModifier {
    var cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency || contrast == .increased {
            content
                .background(HUDPalette.surface, in: shape)
                .overlay { shape.strokeBorder(HUDPalette.ink.opacity(0.35), lineWidth: 1) }
        } else {
            content
                .glassEffect(.regular, in: shape)
                .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
        }
    }
}

extension View {
    func hudSurface(cornerRadius: CGFloat) -> some View {
        modifier(HUDSurface(cornerRadius: cornerRadius))
    }
}

/// "0:07", "1:42".
func hudDuration(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.isFinite ? seconds : 0))
    return String(format: "%d:%02d", total / 60, total % 60)
}
