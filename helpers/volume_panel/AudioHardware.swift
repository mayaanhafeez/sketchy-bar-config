import Foundation
import CoreAudio
import AudioToolbox

enum Channel: String {
    case output, input

    var scope: AudioObjectPropertyScope {
        self == .output ? kAudioDevicePropertyScopeOutput : kAudioDevicePropertyScopeInput
    }

    var defaultSelector: AudioObjectPropertySelector {
        self == .output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice
    }
}

struct Device: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
    let current: Bool
}

/// No AppleScript or SwitchAudioSource processes on the read/slider paths.
enum AudioHardware {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func read<T>(_ id: AudioObjectID, _ property: AudioObjectPropertyAddress, into value: inout T) -> Bool {
        var property = property
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &property, 0, nil, &size, $0) == noErr
        }
    }

    static func write<T>(_ id: AudioObjectID, _ property: AudioObjectPropertyAddress, _ value: T) -> Bool {
        var property = property
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(id, &property, &settable) == noErr, settable.boolValue else { return false }
        var value = value
        return withUnsafePointer(to: &value) {
            AudioObjectSetPropertyData(id, &property, 0, nil, UInt32(MemoryLayout<T>.size), $0) == noErr
        }
    }

    static func current(_ channel: Channel) -> AudioDeviceID {
        var id = AudioDeviceID(kAudioObjectUnknown)
        _ = read(system, address(channel.defaultSelector), into: &id)
        return id
    }

    static func channels(_ id: AudioDeviceID, _ channel: Channel) -> UInt32 {
        var property = address(kAudioDevicePropertyStreamConfiguration, channel.scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioBufferList>.size else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, raw) == noErr else { return 0 }
        let list = raw.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + $1.mNumberChannels }
    }

    static func devices(_ channel: Channel) -> [Device] {
        var property = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let status = ids.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(system, &property, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else { return [] }
        let selected = current(channel)
        return ids.compactMap { id in
            guard channels(id, channel) > 0 else { return nil }
            var name: CFString = "" as CFString
            guard read(id, address(kAudioObjectPropertyName), into: &name) else { return nil }
            return Device(id: id, name: name as String, current: id == selected)
        }
    }

    static func levelProperties(_ id: AudioDeviceID, _ channel: Channel) -> [AudioObjectPropertyAddress] {
        var properties = [address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, channel.scope),
                          address(kAudioDevicePropertyVolumeScalar, channel.scope)]
        let count = channels(id, channel)
        if count > 0 {
            properties += (1...count).map { address(kAudioDevicePropertyVolumeScalar, channel.scope, $0) }
        }
        return properties
    }

    static func level(_ channel: Channel) -> Double? {
        let id = current(channel)
        let properties = levelProperties(id, channel)
        for property in properties.prefix(2) {
            var value: Float32 = 0
            if read(id, property, into: &value) { return Double(value) }
        }
        let values: [Double] = properties.dropFirst(2).compactMap { property in
            var value: Float32 = 0
            return read(id, property, into: &value) ? Double(value) : nil
        }
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    @discardableResult static func setLevel(_ value: Double, on channel: Channel) -> Bool {
        let id = current(channel)
        let properties = levelProperties(id, channel)
        let level = Float32(min(max(value, 0), 1))
        for property in properties.prefix(2) {
            if write(id, property, level) { return true }
        }
        var written = false
        for property in properties.dropFirst(2) {
            if write(id, property, level) { written = true }
        }
        return written
    }

    static func outputMuted() -> Bool {
        var value: UInt32 = 0
        _ = read(current(.output), address(kAudioDevicePropertyMute, Channel.output.scope), into: &value)
        return value != 0
    }

    @discardableResult static func setOutputMuted(_ muted: Bool) -> Bool {
        write(current(.output), address(kAudioDevicePropertyMute, Channel.output.scope), UInt32(muted ? 1 : 0))
    }
}

/// Listen only while the panel exists. Device/default changes rebind the level
/// listeners, including per-channel controls on devices without a master level.
final class AudioMonitor {
    private let queue = DispatchQueue(label: "volume_panel.events", qos: .utility)
    private let changed: () -> Void
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var observedDevices: [AudioDeviceID] = []
    private var deviceListenerStart = 0

    init(changed: @escaping () -> Void) {
        self.changed = changed
        queue.async { [weak self] in self?.start() }
    }

    private func listen(_ id: AudioObjectID, _ property: AudioObjectPropertyAddress, topology: Bool = false) {
        var property = property
        guard AudioObjectHasProperty(id, &property) else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            if topology { self.bindDevices() }
            self.changed()
        }
        if AudioObjectAddPropertyListenerBlock(id, &property, queue, block) == noErr {
            listeners.append((id, property, block))
        }
    }

    private func start() {
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice,
                         kAudioHardwarePropertyDefaultInputDevice] {
            listen(AudioHardware.system, AudioHardware.address(selector), topology: true)
        }
        deviceListenerStart = listeners.count
        bindDevices()
        changed()
    }

    private func bindDevices() {
        let devices = [AudioHardware.current(.output), AudioHardware.current(.input)]
        guard devices != observedDevices else { return }
        for (id, var property, block) in listeners.dropFirst(deviceListenerStart) {
            AudioObjectRemovePropertyListenerBlock(id, &property, queue, block)
        }
        listeners.removeSubrange(deviceListenerStart...)
        observedDevices = devices
        for (channel, id) in zip([Channel.output, .input], devices) where id != kAudioObjectUnknown {
            for property in AudioHardware.levelProperties(id, channel) { listen(id, property) }
            listen(id, AudioHardware.address(kAudioDevicePropertyMute, channel.scope))
        }
    }

    deinit {
        for (id, var property, block) in listeners {
            AudioObjectRemovePropertyListenerBlock(id, &property, queue, block)
        }
    }
}
