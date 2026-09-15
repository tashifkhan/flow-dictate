import Foundation
import Observation

/// The level history the waveform draws from: nine samples, newest last.
///
/// The audio thread meters and smooths (see `AudioLevelMeter`); this only keeps the recent
/// history and the loudest level of the dictation.
@MainActor @Observable
final class AudioLevels {
    static let barCount = 9

    private(set) var bars: [Float] = Array(repeating: 0, count: barCount)
    /// Loudest level this dictation. Zero means the mic delivered nothing but silence,
    /// which is a different failure from "you said nothing".
    private(set) var peak: Float = 0

    func push(_ level: Float) {
        let sample = level.isFinite ? min(1, max(0, level)) : 0
        peak = max(peak, sample)
        let next = Array(bars.dropFirst()) + [sample]
        // Old peaks still drain through the history, and settled silence costs no redraw.
        if next != bars { bars = next }
    }

    func reset() {
        peak = 0
        bars = Array(repeating: 0, count: Self.barCount)
    }
}

/// A display level, not a gain or a speech detector. Ported from Sotto.
///
/// Maps -68...-18 dBFS onto 0...1, rising with a 20 ms time constant and falling with a
/// 130 ms one. Timing comes from the captured frame count, never the wall clock, so a
/// slow UI update cannot change how the bars move.
struct AudioLevelMeter: Sendable {
    private var smoothedLevel = 0.0

    var level: Float { Float(smoothedLevel) }

    @discardableResult
    mutating func update(rms: Double, frameCount: Int, sampleRate: Double) -> Float {
        guard frameCount > 0, sampleRate.isFinite, sampleRate > 0 else { return level }

        let target: Double
        if rms.isFinite, rms > 0 {
            let decibels = 20 * log10(rms)
            target = min(1, max(0, (decibels + 68) / 50))
        } else {
            target = 0
        }

        let duration = Double(frameCount) / sampleRate
        let timeConstant = target > smoothedLevel ? 0.020 : 0.130
        smoothedLevel += (target - smoothedLevel) * -expm1(-duration / timeConstant)

        // Below a fraction of a pixel, settle instead of trailing an endless exponential
        // tail. Quiet but nonzero signals are not rounded away.
        if target == 0, smoothedLevel < 0.02 { smoothedLevel = 0 }
        return level
    }
}
