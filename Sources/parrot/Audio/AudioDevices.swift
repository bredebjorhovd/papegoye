import CoreAudio
import Foundation

/// The hardware half of input-device selection: ask CoreAudio what inputs
/// exist, what they're called, and how they're attached.
///
/// Kept apart from `InputDevicePolicy` on purpose — everything here needs a
/// real audio system to answer, everything there is a pure function over the
/// list this produces.
enum AudioDevices {
    /// Every device with at least one input channel, in CoreAudio's order.
    static func inputDevices() -> [InputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }

        var ids = [AudioDeviceID](repeating: 0, count: count)
        let status = AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids)
        guard status == noErr else { return [] }

        return ids.compactMap(describe)
    }

    /// The system default input device, or nil if there isn't one.
    static func defaultInputDeviceID() -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return deviceID
    }

    /// Enumerate and choose in one step — what callers actually want.
    static func resolve(preference: InputDevicePolicy.Preference) -> InputSelection {
        InputDevicePolicy.select(
            devices: inputDevices(),
            defaultDeviceID: defaultInputDeviceID(),
            preference: preference
        )
    }

    // MARK: - Per-device properties

    private static func describe(_ id: AudioDeviceID) -> InputDevice? {
        guard inputChannelCount(id) > 0 else { return nil }
        return InputDevice(
            id: id,
            name: name(of: id) ?? "device \(id)",
            transport: InputDevice.Transport(coreAudioTransportType: transportType(of: id))
        )
    }

    /// Total input channels across the device's input streams. Zero means it's
    /// output-only, which is most of the device list.
    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }

        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self)
        )
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func name(of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // Unmanaged, not CFString?: CoreAudio hands back a +1 reference through
        // a raw pointer, and letting Swift see a managed reference there is
        // both a warning and a lie about who owns it.
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name)
        guard status == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    private static func transportType(of id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var raw: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &raw) == noErr else {
            return kAudioDeviceTransportTypeUnknown
        }
        return raw
    }
}

extension InputDevice.Transport {
    /// Map `kAudioDevicePropertyTransportType` onto the classes the policy
    /// distinguishes. Both Bluetooth flavours collapse to `.bluetooth`: BLE
    /// audio doesn't have the A2DP/HFP split, but it shares the "wireless mic
    /// that owns your playback path" problem, so the same default applies.
    init(coreAudioTransportType raw: UInt32) {
        switch raw {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            self = .bluetooth
        case kAudioDeviceTransportTypeBuiltIn:
            self = .builtIn
        case kAudioDeviceTransportTypeUSB:
            self = .usb
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate:
            self = .virtual
        default:
            self = .other
        }
    }
}
