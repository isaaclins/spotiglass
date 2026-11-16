import AudioToolbox
import CoreAudio
import Foundation

/// One Core Audio output-capable device (HAL).
struct MacAudioOutputDevice: Identifiable, Equatable, Hashable {
    let id: AudioDeviceID
    let name: String
}

/// Enumerates output devices and sets the system default output (same net effect as Control Center).
enum MacAudioOutputHardware {
    static func defaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID()
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        let status = AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return deviceID
    }

    /// Sets macOS **system-wide** default output device.
    static func setDefaultOutputDevice(_ deviceID: AudioDeviceID) -> OSStatus {
        var id = deviceID
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectSetPropertyData(systemObject, &address, 0, nil, size, &id)
    }

    /// The device's nominal sample rate in Hz, `nil` when it can't be read.
    static func nominalSampleRate(deviceID: AudioDeviceID) -> Float64? {
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
        guard status == noErr, rate > 0 else { return nil }
        return rate
    }

    static func copyDeviceDisplayName(deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard status == noErr else { return nil }

        let rawName = UnsafeMutablePointer<CFString>.allocate(capacity: 1)
        defer { rawName.deallocate() }
        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, rawName)
        guard status == noErr else { return nil }
        return rawName.pointee as String
    }

    static func enumerateOutputDevices() -> [MacAudioOutputDevice] {
        let ids = allAudioDeviceIDs().filter { outputChannelCount(deviceID: $0) > 0 }
        var rows: [MacAudioOutputDevice] = []
        rows.reserveCapacity(ids.count)
        for id in ids {
            guard let name = copyDeviceDisplayName(deviceID: id), !name.isEmpty else { continue }
            rows.append(MacAudioOutputDevice(id: id, name: name))
        }
        return rows.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func allAudioDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0
        else {
            return []
        }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        let status = AudioObjectGetPropertyData(systemObject, &address, 0, nil, &dataSize, &devices)
        guard status == noErr else { return [] }
        return devices.filter { $0 != AudioObjectID(kAudioObjectUnknown) }
    }

    private static func outputChannelCount(deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var propertySize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &propertySize) == noErr,
              propertySize > 0
        else {
            return 0
        }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(propertySize), alignment: 16)
        defer { raw.deallocate() }
        var sz = propertySize
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &sz, raw) == noErr else {
            return 0
        }
        let abl = raw.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
        var channels = 0
        for buffer in buffers {
            channels += Int(buffer.mNumberChannels)
        }
        return channels
    }
}

/// Logs the sound path for the playback log (#590): the system's default output, every output
/// device with its nominal sample rate, and each change to them. A song that plays too fast or
/// cuts out is often two devices on different rates, so the log has to show them.
@MainActor
final class AudioOutputTrace {
    static let shared = AudioOutputTrace()

    /// Where lines go; `nil` writes them to the playback log.
    private let write: ((String) -> Void)?
    private var started = false
    private var lastLine: String?
    private var rateListeners: [AudioDeviceID: AudioObjectPropertyListenerBlock] = [:]
    private var systemListeners: [(AudioObjectPropertySelector, AudioObjectPropertyListenerBlock)] = []

    init(write: ((String) -> Void)? = nil) {
        self.write = write
    }

    /// Stops listening. The app's trace runs for the app's lifetime; tests stop the ones they start.
    // periphery:ignore
    func stop() {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        for (selector, block) in systemListeners {
            var address = Self.address(selector)
            AudioObjectRemovePropertyListenerBlock(systemObject, &address, DispatchQueue.main, block)
        }
        systemListeners = []
        for (id, block) in rateListeners {
            var address = Self.address(kAudioDevicePropertyNominalSampleRate)
            AudioObjectRemovePropertyListenerBlock(id, &address, DispatchQueue.main, block)
        }
        rateListeners = [:]
        started = false
    }

    /// Starts listening and logs the current path. Later calls do nothing.
    func start() {
        guard !started else { return }
        started = true
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices] {
            var address = Self.address(selector)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.changed() }
            }
            if AudioObjectAddPropertyListenerBlock(systemObject, &address, DispatchQueue.main, block) == noErr {
                systemListeners.append((selector, block))
            }
        }
        changed()
    }

    /// Logs the path now, with `reason` (an equalizer route change), even if it didn't change.
    func log(reason: String) {
        lastLine = nil
        report(reason: reason)
    }

    private func changed() {
        listenToRates()
        report(reason: nil)
    }

    private func report(reason: String?) {
        let defaultID = MacAudioOutputHardware.defaultOutputDeviceID()
        let devices = MacAudioOutputHardware.enumerateOutputDevices().map { device in
            Self.describe(device.id, name: device.name)
        }
        let defaultName = defaultID.map { id in
            Self.describe(id, name: MacAudioOutputHardware.copyDeviceDisplayName(deviceID: id) ?? "?")
        } ?? "none"
        let line = "default output \(defaultName); outputs: \(devices.joined(separator: ", "))"
        guard line != lastLine else { return }
        lastLine = line
        let entry = reason.map { "\(line) [\($0)]" } ?? line
        if let write { write(entry) } else { PlaybackTrace.shared.audio(entry) }
    }

    /// Follows the nominal sample rate of every output device, so a rate change is logged.
    private func listenToRates() {
        let current = Set(MacAudioOutputHardware.enumerateOutputDevices().map(\.id))
        for (id, block) in rateListeners where !current.contains(id) {
            var address = Self.address(kAudioDevicePropertyNominalSampleRate)
            AudioObjectRemovePropertyListenerBlock(id, &address, DispatchQueue.main, block)
            rateListeners[id] = nil
        }
        for id in current where rateListeners[id] == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.report(reason: "sample rate of \(id) changed") }
            }
            var address = Self.address(kAudioDevicePropertyNominalSampleRate)
            if AudioObjectAddPropertyListenerBlock(id, &address, DispatchQueue.main, block) == noErr {
                rateListeners[id] = block
            }
        }
    }

    /// "MacBook Pro Speakers (built-in, 91) 48000 Hz". The log gets attached to public issues,
    /// so wireless devices, whose names carry their owner in any language ("AirPods Max von
    /// Isaac"), are named only by their kind.
    nonisolated static func describe(_ id: AudioDeviceID, name: String) -> String {
        "\(publicName(name, transport: transport(id))) (\(transport(id)), \(id)) \(rate(id))"
    }

    nonisolated static func publicName(_ name: String, transport: String) -> String {
        switch transport {
        case "built-in", "usb", "hdmi", "displayport", "virtual", "thunderbolt": name
        default: "\(transport) device"
        }
    }

    /// The device behind a Core Audio UID, described like the others. A Bluetooth UID is the
    /// device's hardware address, so it never goes into the log itself.
    nonisolated static func describe(uid: String) -> String {
        var cfUID = uid as CFString
        var id = AudioDeviceID(kAudioObjectUnknown)
        var translation = AudioValueTranslation(
            mInputData: &cfUID,
            mInputDataSize: UInt32(MemoryLayout<CFString>.size),
            mOutputData: &id,
            mOutputDataSize: UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
        var address = Self.address(kAudioHardwarePropertyDeviceForUID)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &translation)
        guard status == noErr, id != AudioDeviceID(kAudioObjectUnknown) else { return "a device that is gone" }
        return describe(id, name: MacAudioOutputHardware.copyDeviceDisplayName(deviceID: id) ?? "?")
    }

    nonisolated private static func transport(_ id: AudioDeviceID) -> String {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = Self.address(kAudioDevicePropertyTransportType)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return "unknown" }
        switch value {
        case kAudioDeviceTransportTypeBuiltIn: return "built-in"
        case kAudioDeviceTransportTypeUSB: return "usb"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "bluetooth"
        case kAudioDeviceTransportTypeAirPlay: return "airplay"
        case kAudioDeviceTransportTypeHDMI: return "hdmi"
        case kAudioDeviceTransportTypeDisplayPort: return "displayport"
        case kAudioDeviceTransportTypeVirtual: return "virtual"
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: return "aggregate"
        case kAudioDeviceTransportTypeThunderbolt: return "thunderbolt"
        default: return "other"
        }
    }

    nonisolated private static func rate(_ id: AudioDeviceID) -> String {
        MacAudioOutputHardware.nominalSampleRate(deviceID: id).map { "\(Int($0)) Hz" } ?? "? Hz"
    }

    nonisolated private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
