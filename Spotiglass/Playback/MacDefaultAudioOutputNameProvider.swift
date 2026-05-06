import AudioToolbox
import CoreAudio
import Foundation

protocol MacDefaultAudioOutputProviding: AnyObject {
    var currentOutputDisplayName: String { get }
    func startListening(_ onChange: @escaping () -> Void)
    func stopListening()
}

/// Reads the system default **output** device name and notifies when it changes (e.g. Control Center output switch).
final class MacDefaultAudioOutputNameProvider: MacDefaultAudioOutputProviding {
    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private let callbackQueue: DispatchQueue

    init(callbackQueue: DispatchQueue = .main) {
        self.callbackQueue = callbackQueue
    }

    var currentOutputDisplayName: String {
        Self.copyDefaultOutputDeviceName() ?? ""
    }

    func startListening(_ onChange: @escaping () -> Void) {
        stopListening()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { [callbackQueue] _, _ in
            callbackQueue.async {
                onChange()
            }
        }
        listenerBlock = listener
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        AudioObjectAddPropertyListenerBlock(systemObject, &address, callbackQueue, listener)
    }

    func stopListening() {
        guard let listenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        AudioObjectRemovePropertyListenerBlock(systemObject, &address, callbackQueue, listenerBlock)
        self.listenerBlock = nil
    }

    deinit {
        stopListening()
    }

    private static func copyDefaultOutputDeviceName() -> String? {
        var deviceID = AudioDeviceID()
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        let status = AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &deviceID)
        guard status == noErr else { return nil }
        return copyDeviceName(deviceID: deviceID)
    }

    private static func copyDeviceName(deviceID: AudioDeviceID) -> String? {
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
}
