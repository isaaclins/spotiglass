import AudioToolbox
import CoreAudio
import Foundation

protocol MacDefaultAudioOutputProviding: AnyObject {
    var currentOutputDisplayName: String { get }
    /// Identity of the device behind ``currentOutputDisplayName``. The
    /// equalizer route reconciliation needs the ID, not the name, to tell an
    /// external hardware selection from its own virtual device (#253).
    var currentOutputDeviceID: AudioDeviceID? { get }
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

    var currentOutputDeviceID: AudioDeviceID? {
        MacAudioOutputHardware.defaultOutputDeviceID()
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
        guard let id = MacAudioOutputHardware.defaultOutputDeviceID() else { return nil }
        return MacAudioOutputHardware.copyDeviceDisplayName(deviceID: id)
    }
}
