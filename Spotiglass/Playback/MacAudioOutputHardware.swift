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
