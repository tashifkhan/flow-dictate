import SwiftUI

/// Bars that move with your voice. No FFT, no fancy DSP; that was never the feature.
struct Waveform: View {
    var levels: [Float]
    var isLive: Bool
    var tint: Color = .accentColor

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isLive)) { _ in
            Canvas { context, size in
                draw(in: &context, size: size)
            }
        }
        .accessibilityHidden(true)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        guard !levels.isEmpty else { return }

        let spacing: CGFloat = 3
        let width = (size.width - spacing * CGFloat(levels.count - 1)) / CGFloat(levels.count)
        let midY = size.height / 2
        let minHeight = width

        for (index, level) in levels.enumerated() {
            let x = CGFloat(index) * (width + spacing)
            let height = max(minHeight, CGFloat(level) * size.height)
            let rect = CGRect(x: x, y: midY - height / 2, width: width, height: height)
            let bar = Path(roundedRect: rect, cornerRadius: width / 2)

            // Fade the oldest bars out so the waveform reads as scrolling, not jittering.
            let age = Double(index) / Double(levels.count)
            let opacity = isLive ? (0.35 + 0.65 * age) : 0.25
            context.fill(bar, with: .color(tint.opacity(opacity)))
        }
    }
}
