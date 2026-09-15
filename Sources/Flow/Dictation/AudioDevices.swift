import CoreAudio
import Foundation
import Observation

/// How a microphone is attached, for the icon next to its name.
enum AudioInputTransport: String, Codable, CaseIterable, Sendable {
    case builtIn, usb, bluetooth, virtual, aggregate, other

    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: rawValue) ?? .other
    }

    var symbol: String {
        switch self {
        case .builtIn: "laptopcomputer"
        case .usb: "mic"
        case .bluetooth: "headphones"
        case .virtual: "waveform.path"
        case .aggregate: "square.stack.3d.up"
        case .other: "mic"
        }
    }
}

/// The input devices macOS is offering.
///
/// Worth distrusting the system default here: pairing a Bluetooth speaker makes it the
/// default input, macOS puts it in the 8 kHz hands-free profile, and the "microphone" on
/// the other end delivers silence. A priority list or a fixed device survives that.
enum AudioDevices {
    struct Device: Identifiable, Hashable, Sendable {
        /// A HAL handle. Fine for this recording, never for saving: macOS reassigns it.
        let id: AudioDeviceID
        /// Stable across reboots and re-pairings, unlike the numeric id.
        let uid: String
        let name: String
        let transport: AudioInputTransport
        let sampleRate: Double

        /// 8 kHz means a Bluetooth headset profile: usable for a call, poor for dictation.
        var isTelephonyQuality: Bool { sampleRate > 0 && sampleRate <= 8000 }

        var label: String {
            isTelephonyQuality ? "\(name) (8 kHz)" : name
        }

        var saved: SavedMicrophone {
            SavedMicrophone(uid: uid, name: name, transport: transport)
        }
    }

    struct Snapshot: Equatable, Sendable {
        /// Every device, inputs or not, so the monitor can watch one grow an input stream.
        let deviceIDs: [AudioDeviceID]
        let inputs: [Device]
        let systemDefaultUID: String?
    }

    // MARK: - Enumeration

    /// Live devices with at least one input channel, sorted by name. Core Audio's own
    /// order shifts between launches, so it is no use as a display order.
    static func snapshot() -> Snapshot {
        let ids = allDeviceIDs()
        var seen = Set<String>()
        let inputs = ids.compactMap { id -> Device? in
            guard isAvailable(id), let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  seen.insert(uid).inserted else { return nil }
            return Device(
                id: id,
                uid: uid,
                name: stringProperty(id, kAudioObjectPropertyName) ?? "Unnamed microphone",
                transport: transport(uint32Property(id, kAudioDevicePropertyTransportType)),
                sampleRate: sampleRate(id)
            )
        }.sorted { left, right in
            let order = left.name.localizedStandardCompare(right.name)
            return order == .orderedSame ? left.uid < right.uid : order == .orderedAscending
        }
        let defaultID = uint32Property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice)
        return Snapshot(
            deviceIDs: ids,
            inputs: inputs,
            systemDefaultUID: inputs.first { $0.id == defaultID }?.uid
        )
    }

    static func inputs() -> [Device] {
        snapshot().inputs
    }

    /// The device a given UID refers to now, if it is still attached.
    static func device(uid: String) -> Device? {
        inputs().first { $0.uid == uid }
    }

    static var systemDefaultInput: Device? {
        let snapshot = snapshot()
        return snapshot.inputs.first { $0.uid == snapshot.systemDefaultUID }
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
        let system = AudioObjectID(kAudioObjectSystemObject)
        let stride = UInt32(MemoryLayout<AudioDeviceID>.stride)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr,
              size > 0, size <= 1_048_576, size % stride == 0 else { return [] }

        var ids = [AudioDeviceID](repeating: 0, count: Int(size / stride))
        let status = ids.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(system, &addr, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else { return [] }
        // A device can disappear between the size query and the read.
        return Array(ids.prefix(Int(size / stride)))
    }

    private static func isAvailable(_ id: AudioDeviceID) -> Bool {
        id != kAudioObjectUnknown
            && uint32Property(id, kAudioDevicePropertyDeviceIsAlive) == 1
            && hasInputChannels(id)
    }

    private static func hasInputChannels(_ id: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr,
              size >= MemoryLayout<UInt32>.size, size <= 1_048_576 else { return false }

        let byteCount = max(Int(size), MemoryLayout<AudioBufferList>.stride)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return false }

        // Trust mNumberBuffers only as far as the bytes the HAL actually wrote.
        let list = raw.assumingMemoryBound(to: AudioBufferList.self)
        let bufferOffset = MemoryLayout<AudioBufferList>.stride - MemoryLayout<AudioBuffer>.stride
        guard Int(size) >= bufferOffset,
              Int(list.pointee.mNumberBuffers) <= (Int(size) - bufferOffset) / MemoryLayout<AudioBuffer>.stride
        else { return false }
        return UnsafeMutableAudioBufferListPointer(list).contains { $0.mNumberChannels > 0 }
    }

    private static func uint32Property(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr,
              size == MemoryLayout<UInt32>.size else { return nil }
        return value
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value)
        // The HAL hands these strings over retained. Taking them unretained leaks one per read.
        let string = value?.takeRetainedValue() as String?
        guard status == noErr, let string, !string.isEmpty else { return nil }
        return string
    }

    private static func sampleRate(_ id: AudioDeviceID) -> Double {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var rate = Double(0)
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate) == noErr else { return 0 }
        return rate
    }

    private static func transport(_ rawValue: UInt32?) -> AudioInputTransport {
        switch rawValue {
        case kAudioDeviceTransportTypeBuiltIn: .builtIn
        case kAudioDeviceTransportTypeUSB: .usb
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: .bluetooth
        case kAudioDeviceTransportTypeVirtual: .virtual
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: .aggregate
        default: .other
        }
    }
}

// MARK: - Monitoring

/// Keeps the connected inputs current while Flow runs, so plugging in a headset shows up
/// in the microphone pane without reopening it. Reads metadata only: no capture session,
/// no permission prompt, and no change to the macOS default input.
@MainActor @Observable
final class AudioDeviceMonitor {
    private(set) var inputs: [AudioDevices.Device] = []
    private(set) var systemDefaultUID: String?
    @ObservationIgnored var onChange: (([AudioDevices.Device]) -> Void)?

    @ObservationIgnored private var systemObservers: [AudioPropertyObservation] = []
    @ObservationIgnored private var deviceObservers: [AudioDeviceID: [AudioPropertyObservation]] = [:]
    @ObservationIgnored private var monitoring = false

    func start() {
        guard !monitoring else { return }
        monitoring = true
        let system = AudioObjectID(kAudioObjectSystemObject)
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            if let observer = observe(system, selector, kAudioObjectPropertyScopeGlobal) {
                systemObservers.append(observer)
            }
        }
        refresh()
    }

    func refresh() {
        let snapshot = AudioDevices.snapshot()
        if monitoring { updateDeviceObservers(snapshot.deviceIDs) }
        let changed = inputs != snapshot.inputs || systemDefaultUID != snapshot.systemDefaultUID
        guard changed else { return }
        inputs = snapshot.inputs
        systemDefaultUID = snapshot.systemDefaultUID
        onChange?(inputs)
    }

    func stop() {
        monitoring = false
        systemObservers.forEach { $0.cancel() }
        deviceObservers.values.flatMap { $0 }.forEach { $0.cancel() }
        systemObservers.removeAll()
        deviceObservers.removeAll()
    }

    private func observe(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope
    ) -> AudioPropertyObservation? {
        AudioPropertyObservation.observe(object, selector, scope) { [weak self] in
            guard let self, self.monitoring else { return }
            self.refresh()
        }
    }

    private func updateDeviceObservers(_ deviceIDs: [AudioDeviceID]) {
        let connected = Set(deviceIDs)
        for id in Set(deviceObservers.keys).subtracting(connected) {
            deviceObservers.removeValue(forKey: id)?.forEach { $0.cancel() }
        }
        // Output-only devices too: a device can gain an input stream, or come alive,
        // without macOS allocating it a new id.
        for id in connected where deviceObservers[id] == nil {
            deviceObservers[id] = [
                observe(id, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal),
                observe(id, kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal),
                observe(id, kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput),
            ].compactMap { $0 }
        }
    }
}

/// One Core Audio property listener. Holds the exact block and queue that removal needs.
/// Cancelling twice is safe, and deallocation cancels.
final class AudioPropertyObservation {
    private var cancellation: (() -> Void)?

    private init(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
    }

    func cancel() {
        let action = cancellation
        cancellation = nil
        action?()
    }

    deinit { cancel() }

    static func observe(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope,
        _ onChange: @escaping @MainActor () -> Void
    ) -> AudioPropertyObservation? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            // Registered on the main queue below, and none of these are IO-thread properties.
            MainActor.assumeIsolated { onChange() }
        }
        guard AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr else { return nil }
        return AudioPropertyObservation {
            var removalAddress = address
            AudioObjectRemovePropertyListenerBlock(object, &removalAddress, .main, block)
        }
    }
}
