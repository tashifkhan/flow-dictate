import CoreAudio
import Foundation
import OSLog

/// The input devices macOS is offering, and which one Flow should record from.
///
/// Flow follows the system default unless you pick a device explicitly. That default is
/// worth distrusting: pairing a Bluetooth speaker makes it the default input, macOS puts
/// it in the 8 kHz hands-free profile, and the "microphone" on the other end delivers
/// silence. Picking the built-in mic here survives that.
enum AudioDevices {
    private static let log = Logger(subsystem: "sh.taf.flow", category: "audio")

    struct Device: Identifiable, Hashable, Sendable {
        let id: AudioDeviceID
        /// Stable across reboots and re-pairings, unlike the numeric id.
        let uid: String
        let name: String
        let sampleRate: Double

        /// 8 kHz means a Bluetooth headset profile: usable for a call, poor for dictation.
        var isTelephonyQuality: Bool { sampleRate > 0 && sampleRate <= 8000 }

        var label: String {
            isTelephonyQuality ? "\(name) (8 kHz)" : name
        }
    }

    // MARK: - Enumeration

    /// Every device with at least one input channel, in the order macOS reports them.
    static func inputs() -> [Device] {
        allDeviceIDs().compactMap { id in
            guard inputChannelCount(id) > 0, let uid = uid(id), let name = name(id) else { return nil }
            return Device(id: id, uid: uid, name: name, sampleRate: sampleRate(id))
        }
    }

    /// The device a given UID refers to now, if it is still attached.
    static func device(uid: String) -> Device? {
        inputs().first { $0.uid == uid }
    }

    static var systemDefaultInput: Device? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id
        ) == noErr else { return nil }
        return inputs().first { $0.id == id }
    }

    // MARK: - CoreAudio plumbing

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids
        ) == noErr else { return [] }
        return ids
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }

        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        guard let value else { return nil }
        let string = value.takeUnretainedValue() as String
        return string.isEmpty ? nil : string
    }

    private static func uid(_ id: AudioDeviceID) -> String? {
        stringProperty(id, kAudioDevicePropertyDeviceUID)
    }

    private static func name(_ id: AudioDeviceID) -> String? {
        stringProperty(id, kAudioObjectPropertyName)
    }

    private static func sampleRate(_ id: AudioDeviceID) -> Double {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var rate = Double(0)
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate) == noErr else { return 0 }
        return rate
    }
}
