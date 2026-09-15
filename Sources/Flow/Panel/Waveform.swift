import SwiftUI

/// Nine capsules that move with your voice, newest on the right. Sotto's meter, bar for
/// bar: 3 pt bars, 3 pt gaps, a 3 pt floor, and a 50 ms linear glide between samples.
struct Waveform: View {
    var levels: [Float]
    var tint: Color = HUDPalette.accent
    var height: CGFloat = 28
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var barHeights: [CGFloat] {
        let count = AudioLevels.barCount
        let recent = Array(levels.suffix(count))
        let history = Array(repeating: Float(0), count: count - recent.count) + recent
        return history.map { level in
            let normalized = level.isFinite ? min(1, max(0, level)) : 0
            return 3 + max(0, height - 3) * CGFloat(normalized)
        }
    }

    var body: some View {
        let heights = barHeights
        HStack(spacing: 3) {
            ForEach(heights.indices, id: \.self) { index in
                Capsule()
                    .fill(tint)
                    .frame(width: 3, height: heights[index])
            }
        }
        .frame(width: 51, height: height)
        .animation(reduceMotion ? nil : .linear(duration: 0.05), value: heights)
        .accessibilityHidden(true)
    }
}
