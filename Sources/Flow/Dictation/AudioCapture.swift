import AVFoundation
import Foundation
import OSLog
import Speech

/// Mic capture, format conversion, and amplitude, in one place.
///
/// The transcriber consumes the audio it needs; the panel wants amplitude. Both come
/// off the same capture callback, so there is exactly one mic session and the system mic
/// indicator tells the truth about when we are listening.
final class AudioCapture: @unchecked Sendable {
    private var microphone: MicrophoneInput?
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
    private var recordedSamples: [Int16] = []
    private var samplePosition = 0.0
    private var recordingTruncated = false

    /// Serialises capture start, restart, and stop. Separate from `lock` because
    /// stopping capture waits for an in-flight callback, and that callback takes `lock`.
    private let captureLock = NSLock()
    private let recoveryQueue = DispatchQueue(label: "sh.taf.flow.audio-recovery")
    private var capturing = false
    private var captureID = UUID()
    private var recoveryPending = false
    private var preferredInputUID = ""

    /// Roughly 60 s at 16 kHz. A dictation that outruns the model loading is already
    /// pathological; past this the oldest audio is dropped rather than the memory.
    private static let maxBacklogFrames: AVAudioFrameCount = 16_000 * 60

    /// Called on the audio thread with a 0...1 amplitude. Keep the work here trivial.
    private let onLevel: @Sendable (Float) -> Void

    /// Keep a copy of the audio for cloud models. Off unless a ready cloud config
    /// takes audio, so a local-only dictation holds nothing beyond the backlog.
    private let recordsAudio: Bool

    init(recordsAudio: Bool = false, onLevel: @escaping @Sendable (Float) -> Void) {
        self.recordsAudio = recordsAudio
        self.onLevel = onLevel
    }

    enum CaptureError: Error, LocalizedError {
        case micDenied
        case noConverter
        case notCapturing
        case inputUnavailable
        var errorDescription: String? {
            switch self {
            case .micDenied: "Flow needs microphone access. Grant it in System Settings › Privacy & Security › Microphone."
            case .noConverter: "This microphone's audio format can't be converted for transcription."
            case .notCapturing: "The microphone was not running when transcription started."
            case .inputUnavailable: "The microphone is unavailable or still connecting. Try dictating again in a moment."
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

    /// Opens only the selected input. Capture starts before the speech model loads.
    func startCapturing(preferredInputUID: String) throws {
        try captureLock.withLock {
            self.preferredInputUID = preferredInputUID
            captureID = UUID()
            try startMicrophone()
            capturing = true
        }
    }

    /// Caller holds captureLock. AVCaptureSession owns hardware format negotiation,
    /// and supplies a stable mono Float32 stream without opening a playback device.
    private func startMicrophone() throws {
        let devices = AudioDevices.snapshot()
        let fallback = MicrophoneSelectionPolicy.resolve(
            preferences: MicrophonePreferences(selection: .systemDefault),
            available: devices.inputs.map(\.saved), systemDefaultUID: devices.systemDefaultUID,
            hasBluetoothOutput: devices.hasBluetoothOutput
        )
        guard let device = devices.inputs.first(where: { $0.uid == preferredInputUID })
            ?? devices.inputs.first(where: { $0.uid == fallback.device?.uid }) else {
            throw CaptureError.inputUnavailable
        }
        let input = MicrophoneInput { [weak self] buffer in
            guard let self else { return }
            self.meter(buffer)
            if self.recordsAudio { self.record(buffer) }
            self.consume(buffer)
        }
        lock.withLock { inputFormat = MicrophoneInput.format }
        do {
            try input.start(uid: device.uid) { [weak self] in
                self?.recoveryQueue.async { [weak self] in self?.scheduleRecovery() }
            }
            microphone = input
        } catch {
            input.stop()
            throw error
        }
    }

    private func scheduleRecovery() {
        captureLock.withLock {
            guard capturing, !recoveryPending else { return }
            recoveryPending = true
            enqueueRecovery(captureID: captureID, attempt: 0)
        }
    }

    /// Coalesce profile-change notifications and retry while the Bluetooth route settles.
    /// The session ID prevents a queued restart from reopening a stopped microphone.
    private func enqueueRecovery(captureID: UUID, attempt: Int) {
        recoveryQueue.asyncAfter(deadline: .now() + .milliseconds(150 * (attempt + 1))) { [weak self] in
            self?.restartAfterConfigurationChange(captureID: captureID, attempt: attempt)
        }
    }

    private func restartAfterConfigurationChange(captureID: UUID, attempt: Int) {
        captureLock.withLock {
            guard capturing, self.captureID == captureID else { return }
            log.notice("audio configuration changed; restarting the microphone")
            microphone?.stop()
            microphone = nil
            do {
                try startMicrophone()
                recoveryPending = false
            } catch {
                log.error("could not restart the microphone: \(error.localizedDescription, privacy: .public)")
                if attempt < 5 {
                    enqueueRecovery(captureID: captureID, attempt: attempt + 1)
                } else {
                    recoveryPending = false
                }
            }
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

        // Draining inside the lock keeps the ordering honest: a capture callback that fires
        // mid-drain blocks here and lands after the backlog, not in the middle of it.
        lock.withLock {
            self.converter = converter
            self.analyzerFormat = format
            self.continuation = continuation

            for buffer in backlog {
                guard let converter = converterMatching(buffer.format) else { continue }
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
            if let analyzerFormat, let continuation {
                guard let converter = converterMatching(buffer.format) else { return }
                if let converted = convert(buffer, using: converter, to: analyzerFormat) {
                    continuation.yield(AnalyzerInput(buffer: converted))
                }
                return
            }
            // MicrophoneInput already copied this buffer out of AVFoundation's pool.
            guard backlogFrames < Self.maxBacklogFrames else { return }
            backlog.append(buffer)
            backlogFrames += buffer.frameLength
        }
    }

    /// Caller holds `lock`. A restart can land on a device with a different format, so
    /// the converter is rebuilt whenever the input format stops matching it.
    private func converterMatching(_ format: AVAudioFormat) -> AVAudioConverter? {
        if let converter, converter.inputFormat == format { return converter }
        guard let analyzerFormat, let rebuilt = AVAudioConverter(from: format, to: analyzerFormat) else {
            log.error("no converter for input format \(format, privacy: .public)")
            return nil
        }
        rebuilt.primeMethod = .none
        converter = rebuilt
        return rebuilt
    }

    /// Stops capture the moment the key goes up. An app that keeps the mic dot lit
    /// while idle is malware behaviour, even when it is not.
    func stop() {
        captureLock.withLock {
            capturing = false
            captureID = UUID()
            recoveryPending = false
            microphone?.stop()
            microphone = nil
        }
        // The capture queue is drained, so nothing else is touching the meter now.
        levelMeter = AudioLevelMeter()
        meterSumSquares = 0
        meterFrames = 0
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

    /// Keep a 16 kHz mono copy for cloud transcription. A ten-minute recording is
    /// roughly 19 MB, below the inline audio limit used by Gemini.
    private func record(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let count = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        let step = buffer.format.sampleRate / 16_000
        lock.withLock {
            while samplePosition < Double(count), recordedSamples.count < 9_600_000 {
                let frame = min(Int(samplePosition), count - 1)
                var value: Float = 0
                for channel in 0..<channelCount { value += channels[channel][frame] }
                value /= Float(channelCount)
                recordedSamples.append(Int16(max(-1, min(1, value)) * 32767))
                samplePosition += step
            }
            if recordedSamples.count >= 9_600_000 { recordingTruncated = true }
            samplePosition -= Double(count)
        }
    }

    func recordedWAV() -> Data {
        lock.withLock {
            guard !recordingTruncated else { return Data() }
            let byteCount = recordedSamples.count * 2
            var data = Data()
            func append<T: FixedWidthInteger>(_ number: T) {
                var little = number.littleEndian
                withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
            }
            data.append(contentsOf: "RIFF".utf8)
            append(UInt32(byteCount + 36))
            data.append(contentsOf: "WAVEfmt ".utf8)
            append(UInt32(16))
            append(UInt16(1))
            append(UInt16(1))
            append(UInt32(16_000))
            append(UInt32(32_000))
            append(UInt16(2))
            append(UInt16(16))
            data.append(contentsOf: "data".utf8)
            append(UInt32(byteCount))
            for sample in recordedSamples { append(sample) }
            return data
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

    // Touched only by the capture callback, which never overlaps itself, and by stop() after
    // the capture queue is drained.
    private var levelMeter = AudioLevelMeter()
    private var meterSumSquares: Double = 0
    private var meterFrames = 0

    /// RMS over 50 ms windows of channel 0, smoothed by Sotto's meter. The capture session picks
    /// its own buffer size, so windows span buffers and one buffer can emit several levels.
    private func meter(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0] else { return }
        let sampleRate = buffer.format.sampleRate
        let windowFrames = max(1, Int(sampleRate * 0.05))

        for index in 0..<Int(buffer.frameLength) {
            let sample = samples[index]
            let magnitude = Double(sample.isFinite ? min(1, abs(sample)) : 0)
            meterSumSquares += magnitude * magnitude
            meterFrames += 1
            if meterFrames >= windowFrames {
                let rms = (meterSumSquares / Double(meterFrames)).squareRoot()
                onLevel(levelMeter.update(rms: rms, frameCount: meterFrames, sampleRate: sampleRate))
                meterSumSquares = 0
                meterFrames = 0
            }
        }
    }
}
