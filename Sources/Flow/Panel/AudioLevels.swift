import Foundation
import Observation

/// The RMS ring buffer the waveform draws from.
///
/// The audio thread pushes; the UI reads. Values are smoothed on the way in so the
/// bars fall off rather than snapping to zero between syllables.
@MainActor @Observable
final class AudioLevels {
    /// 24 bars, mirrored around center. That is the entire "pro audio" look.
    static let barCount = 24

    private(set) var bars: [Float] = Array(repeating: 0, count: barCount)
    /// Loudest sample this dictation. Zero means the mic delivered nothing but silence,
    /// which is a different failure from "you said nothing".
    private(set) var peak: Float = 0

    /// How fast a bar falls when you stop talking. Tuned by ear.
    private let decay: Float = 0.82
    private var smoothed: Float = 0

    func push(_ level: Float) {
        // Attack fast, release slow: speech transients should read instantly, silence
        // should fade rather than blink.
        peak = max(peak, level)
        smoothed = level > smoothed ? level : max(level, smoothed * decay)
        bars.removeFirst()
        bars.append(smoothed)
    }

    func reset() {
        smoothed = 0
        peak = 0
        bars = Array(repeating: 0, count: Self.barCount)
    }
}
