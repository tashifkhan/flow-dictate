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
    private let log = Logger(subsystem: "sh.taf.flow", category: "audio")

    /// Guards everything the audio thread and the pipeline both touch.
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var inputFormat: AVAudioFormat?
    /// Audio captured before the analyzer was ready, oldest first.
    private var backlog: [AVAudioPCMBuffer] = []
    private var backlogFrames: AVAudioFrameCount = 0

    /// Roughly 60 s at 48 kHz. A dictation that outruns the model loading is already
    /// pathological; past this the oldest audio is dropped rather than the memory.
    private static let maxBacklogFrames: AVAudioFrameCount = 48_000 * 60

    /// Called on the audio thread with a 0...1 amplitude. Keep the work here trivial.
    private let onLevel: @Sendable (Float) -> Void

    init(onLevel: @escaping @Sendable (Float) -> Void) {
        self.onLevel = onLevel
    }

    enum CaptureError: Error, LocalizedError {
        case micDenied
        case noConverter
        case notCapturing
        var errorDescription: String? {
            switch self {
            case .micDenied: "Flow needs microphone access. Grant it in System Settings › Privacy & Security › Microphone."
            case .noConverter: "This microphone's audio format can't be converted for transcription."
            case .notCapturing: "The microphone was not running when transcription started."
            }
        }
    }

    /// Points the engine at the device chosen in Settings, if one is chosen and still
    /// attached. Falls through to the system default otherwise, which is what an empty
    /// setting, an unplugged device, or a failure all mean.
    private func applyPreferredInputDevice(to input: AVAudioInputNode, uid: String) {
        guard !uid.isEmpty else { return }
        guard let device = AudioDevices.device(uid: uid) else {
            log.notice("chosen input device is not attached; using the system default")
            return
        }
        do {
            try input.auAudioUnit.setDeviceID(device.id)
        } catch {
            log.error("could not select input device: \(error.localizedDescription, privacy: .public)")
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
    /// Opens the microphone. Nothing here waits on the speech model.
    ///
    /// This is the whole point of splitting capture from analysis: the model can take
    /// hundreds of milliseconds to resolve — and minutes the first time, if assets have
    /// to download — and every one of those was previously spent with the mic shut. Audio
    /// captured before `attach` accumulates in `backlog` and is replayed in order, so the
    /// first word survives however long the model takes.
    ///
    /// `preferredInputUID` is read on the main actor by the caller and passed in. This
    /// runs off the main actor, so it must not touch `Settings` itself.
    func startCapturing(preferredInputUID: String) throws {
        let input = engine.inputNode
        // Must happen before the format is read: pointing the unit at a different device
        // changes the format it reports, and the converter is built from that.
        applyPreferredInputDevice(to: input, uid: preferredInputUID)
        let format = input.outputFormat(forBus: 0)
        lock.withLock { inputFormat = format }

        // 1024 frames at 48kHz is ~21ms: fast enough that the first waveform bar lands
        // well inside the 100ms budget.
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.onLevel(Self.rms(of: buffer))
            self.consume(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    /// Hands the analyzer its input, replaying whatever was said while it was loading.
    func attach(analyzerFormat format: AVAudioFormat) throws -> AsyncStream<AnalyzerInput> {
        guard let inputFormat = lock.withLock({ self.inputFormat }) else {
            throw CaptureError.notCapturing
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: format) else {
            throw CaptureError.noConverter
        }
        converter.primeMethod = .none

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: .bufferingNewest(256)
        )

        // Draining inside the lock keeps the ordering honest: a tap callback that fires
        // mid-drain blocks here and lands after the backlog, not in the middle of it.
        lock.withLock {
            self.converter = converter
            self.analyzerFormat = format
            self.continuation = continuation

            for buffer in backlog {
                if let converted = convert(buffer, using: converter, to: format) {
                    continuation.yield(AnalyzerInput(buffer: converted))
                }
            }
            if backlogFrames > 0 {
                log.info("replayed \(self.backlogFrames) frames captured before the model was ready")
            }
            backlog.removeAll()
            backlogFrames = 0
        }
        return stream
    }

    /// Called on the audio thread for every buffer. Converts straight through once the
    /// analyzer is attached, and holds onto the audio until then.
    private func consume(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            if let converter, let analyzerFormat, let continuation {
                if let converted = convert(buffer, using: converter, to: analyzerFormat) {
                    continuation.yield(AnalyzerInput(buffer: converted))
                }
                return
            }
            // The engine reuses its buffers, so this has to be a copy, not a reference.
            guard backlogFrames < Self.maxBacklogFrames, let copy = Self.copy(buffer) else { return }
            backlog.append(copy)
            backlogFrames += copy.frameLength
        }
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
              let src = buffer.floatChannelData, let dst = out.floatChannelData
        else { return nil }
        out.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        for channel in 0..<channels {
            dst[channel].update(from: src[channel], count: frames)
        }
        return out
    }

    /// Stops the tap the moment the key goes up. An app that keeps the mic dot lit
    /// while idle is malware behaviour, even when it is not.
    func stop() {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        lock.withLock {
            continuation?.finish()
            continuation = nil
            converter = nil
            analyzerFormat = nil
            inputFormat = nil
            backlog.removeAll()
            backlogFrames = 0
        }
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
