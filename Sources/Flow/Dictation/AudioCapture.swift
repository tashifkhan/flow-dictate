import AVFoundation
import Foundation
import OSLog
import Speech

/// Mic capture, format conversion, and amplitude, in one place.
///
/// The transcriber consumes the audio it needs; the panel wants amplitude. Both come
/// off the same input tap, so there is exactly one mic session and the system mic
/// indicator tells the truth about when we are listening.
final class AudioCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private let log = Logger(subsystem: "sh.taf.flow", category: "audio")

    /// Called on the audio thread with a 0...1 amplitude. Keep the work here trivial.
    private let onLevel: @Sendable (Float) -> Void

    init(onLevel: @escaping @Sendable (Float) -> Void) {
        self.onLevel = onLevel
    }

    enum CaptureError: Error, LocalizedError {
        case micDenied
        case noConverter
        var errorDescription: String? {
            switch self {
            case .micDenied: "Flow needs microphone access. Grant it in System Settings › Privacy & Security › Microphone."
            case .noConverter: "This microphone's audio format can't be converted for transcription."
            }
        }
    }

    /// Asks once; macOS remembers the answer.
    static func requestMicAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// Starts the engine and returns the stream of buffers the analyzer will consume.
    /// `analyzerFormat` comes from `SpeechAnalyzer.bestAvailableAudioFormat`.
    func start(analyzerFormat: AVAudioFormat) throws -> AsyncStream<AnalyzerInput> {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        guard let converter = AVAudioConverter(from: inputFormat, to: analyzerFormat) else {
            throw CaptureError.noConverter
        }
        converter.primeMethod = .none
        self.converter = converter

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        self.continuation = continuation

        // 1024 frames at 48kHz is ~21ms: fast enough that the first waveform bar lands
        // well inside the 100ms budget.
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.onLevel(Self.rms(of: buffer))
            if let converted = self.convert(buffer, using: converter, to: analyzerFormat) {
                continuation.yield(AnalyzerInput(buffer: converted))
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            continuation.finish()
            throw error
        }
        return stream
    }

    /// Stops the tap the moment the key goes up. An app that keeps the mic dot lit
    /// while idle is malware behaviour, even when it is not.
    func stop() {
        guard engine.isRunning else {
            continuation?.finish()
            continuation = nil
            return
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
        converter = nil
    }

    // MARK: - Conversion

    private func convert(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }

        // The input block is declared @Sendable but is called synchronously on this
        // thread, once. The box hands the buffer over exactly once without pretending
        // an audio buffer is Sendable.
        let pending = PendingBuffer(buffer)
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            guard let next = pending.take() else {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            return next
        }

        switch status {
        case .haveData, .inputRanDry:
            return out.frameLength > 0 ? out : nil
        case .endOfStream:
            return nil
        case .error:
            log.error("conversion failed: \(error?.localizedDescription ?? "unknown", privacy: .public)")
            return nil
        @unknown default:
            return nil
        }
    }

    /// One-shot handoff of a buffer into the converter's input block.
    private final class PendingBuffer: @unchecked Sendable {
        private var buffer: AVAudioPCMBuffer?
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        func take() -> AVAudioPCMBuffer? {
            defer { buffer = nil }
            return buffer
        }
    }

    // MARK: - Amplitude

    /// Plain RMS across channel 0. No FFT, no DSP. Bars that move with your voice are
    /// the whole feature.
    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }

        var sum: Float = 0
        for i in 0..<count { sum += channel[i] * channel[i] }
        let rms = (sum / Float(count)).squareRoot()

        // Speech sits low in linear terms; map -50dB...0dB onto 0...1 so the bars use
        // their full height at ordinary talking volume.
        let db = 20 * log10(max(rms, 1e-7))
        return min(max((db + 50) / 50, 0), 1)
    }
}
