import CoreAudio
import Dispatch

@MainActor
extension PlaybackSessionViewModel {
    func installAudioHardwareDevicesListener() {
        removeAudioHardwareDevicesListenerForTeardown()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                self?.refreshMacAudioOutputDevices()
            }
        }
        hardwareDevicesListener = listener
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        AudioObjectAddPropertyListenerBlock(systemObject, &address, DispatchQueue.main, listener)
    }

    func refreshMacAudioOutputDevices() {
        macAudioOutputDevices = MacAudioOutputHardware.enumerateOutputDevices()
        systemDefaultOutputDeviceID = MacAudioOutputHardware.defaultOutputDeviceID()
    }

    func setSystemDefaultOutputDevice(_ audioDeviceID: AudioDeviceID) {
        let status = MacAudioOutputHardware.setDefaultOutputDevice(audioDeviceID)
        guard status == noErr else { return }
        refreshMacAudioOutputDevices()
        refreshTrayOutputSymbol()
    }

    func refreshTrayOutputSymbol() {
        let localID = deviceID
        let active = latestPlayerSnapshot?.activeDevice

        if let localID, let active, active.deviceID == localID {
            trayOutputSymbolName = PlaybackOutputSFResolver.symbolName(
                deviceName: macAudioOutput.currentOutputDisplayName,
                spotifyDeviceType: "computer"
            )
            return
        }

        if let active {
            trayOutputSymbolName = PlaybackOutputSFResolver.symbolName(
                deviceName: active.name,
                spotifyDeviceType: active.type
            )
            return
        }

        if localID != nil {
            trayOutputSymbolName = PlaybackOutputSFResolver.symbolName(
                deviceName: macAudioOutput.currentOutputDisplayName,
                spotifyDeviceType: "computer"
            )
            return
        }

        trayOutputSymbolName = "headphones"
    }

    nonisolated func removeAudioHardwareDevicesListenerForTeardown() {
        guard let block = hardwareDevicesListener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        AudioObjectRemovePropertyListenerBlock(systemObject, &address, DispatchQueue.main, block)
        hardwareDevicesListener = nil
    }
}
