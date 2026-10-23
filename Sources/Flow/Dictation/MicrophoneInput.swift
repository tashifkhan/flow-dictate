import AVFoundation
import Foundation

/// Records one device without creating an audio playback graph. In particular, choosing
/// the Mac microphone must not open the system-default Bluetooth microphone first.
final class MicrophoneInput: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    static let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "sh.taf.flow.microphone-buffers")
    private let onBuffer: @Sendable (AVAudioPCMBuffer) -> Void
    private var observers: [NSObjectProtocol] = []

    init(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        self.onBuffer = onBuffer
    }

    func start(uid: String, onFailure: @escaping @Sendable () -> Void) throws {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        ).devices
        guard let device = devices.first(where: { $0.uniqueID == uid }) else {
            throw AudioCapture.CaptureError.inputUnavailable
        }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw AudioCapture.CaptureError.inputUnavailable
        }
        session.addInput(input)
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(output)
        session.commitConfiguration()
        observers = [
            NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                                                   object: session, queue: nil) { _ in onFailure() },
            NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification,
                                                   object: device, queue: nil) { _ in onFailure() },
        ]
        session.startRunning()
        guard session.isRunning else {
            stop()
            throw AudioCapture.CaptureError.inputUnavailable
        }
    }

    /// Called off the delegate queue. Drain callbacks before releasing capture state.
    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        output.setSampleBufferDelegate(nil, queue: nil)
        session.stopRunning()
        queue.sync {}
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let buffer = Self.copyPCM(sampleBuffer) else { return }
        onBuffer(buffer)
    }

    /// Copy before returning the sample buffer to AVFoundation. Core Media handles
    /// the buffer layout rather than assuming the device produces planar Float32.
    static func copyPCM(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0, frames <= Int(Int32.max),
              let description = CMSampleBufferGetFormatDescription(sampleBuffer)
        else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList
        ) == noErr else { return nil }
        return buffer
    }
}
