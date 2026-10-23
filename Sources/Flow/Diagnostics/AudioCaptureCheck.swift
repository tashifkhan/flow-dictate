import AVFoundation
import Foundation

/// Opt-in hardware check. Keeps only buffer counts and levels, never microphone audio.
enum AudioCaptureCheck {
    static func sampleBuffer(from buffer: AVAudioPCMBuffer) -> CMSampleBuffer? {
        var description: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
            asbd: buffer.format.streamDescription, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &description) == noErr, let description else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(buffer.format.sampleRate)),
                                        presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: description,
            sampleCount: Int(buffer.frameLength), sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr,
            let sample,
            CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: buffer.audioBufferList) == noErr,
            CMSampleBufferSetDataReady(sample) == noErr else { return nil }
        return sample
    }

    static func run(output: String) async -> Never {
        guard await AudioCapture.requestMicAccess() else {
            print(AudioCapture.CaptureError.micDenied.localizedDescription)
            exit(1)
        }
        let devices = AudioDevices.inputs().filter { [.builtIn, .bluetooth, .usb].contains($0.transport) }
        var results: [[String: Any]] = []
        var passed = !devices.isEmpty
        // Repeated takes exercise the Bluetooth profile transitions on open and close.
        for round in 1...2 {
            for device in devices {
                let levels = Levels()
                let capture = AudioCapture(recordsAudio: true) { levels.add($0) }
                do {
                    try capture.startCapturing(preferredInputUID: device.uid)
                    let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                               channels: 1, interleaved: false)!
                    let stream = try capture.attach(analyzerFormat: format)
                    let reader = Task {
                        var frames = 0
                        for await input in stream { frames += Int(input.buffer.frameLength) }
                        return frames
                    }
                    try await Task.sleep(for: .seconds(2))
                    capture.stop()
                    let frames = await reader.value
                    let wavBytes = capture.recordedWAV().count
                    let measurements = levels.snapshot()
                    let ok = frames >= 8_000 && wavBytes >= 16_044 && measurements.count > 0
                    passed = passed && ok
                    results.append(["device": device.name, "round": round, "passed": ok,
                                    "analyzerFrames": frames, "wavBytes": wavBytes,
                                    "levelCallbacks": measurements.count, "peak": measurements.peak])
                } catch {
                    capture.stop()
                    passed = false
                    results.append(["device": device.name, "round": round, "passed": false,
                                    "error": error.localizedDescription])
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        let report: [String: Any] = ["passed": passed, "captures": results]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: output), options: .atomic)
        }
        exit(passed ? 0 : 1)
    }

    private final class Levels: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var peak: Float = 0

        func add(_ value: Float) {
            lock.withLock {
                count += 1
                peak = max(peak, value)
            }
        }

        func snapshot() -> (count: Int, peak: Float) {
            lock.withLock { (count, peak) }
        }
    }
}
