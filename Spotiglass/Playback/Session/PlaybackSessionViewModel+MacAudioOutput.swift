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

    /// While the EQ is engaged, a device pick must not replace the system
    /// default: that would route audio around the virtual EQ device. The
    /// selection becomes the EQRouter's forwarding target instead, and the
    /// engine's route state records whether that target actually opened (#253).
    func setSystemDefaultOutputDevice(_ audioDeviceID: AudioDeviceID) {
        if let equalizerEngine, equalizerEngine.isEngaged {
            equalizerEngine.selectOutputDevice(audioDeviceID)
            refreshMacAudioOutputDevices()
            refreshTrayOutputSymbol()
            return
        }

        let status = MacAudioOutputHardware.setDefaultOutputDevice(audioDeviceID)
        guard status == noErr else { return }
        refreshMacAudioOutputDevices()
        refreshTrayOutputSymbol()
    }

    /// Reconciles a default-output notification after the playback UI has
    /// refreshed its own device list. A hardware device selected by Control
    /// Center or another app becomes the EQRouter target; the EQ virtual device
    /// remains the sole system default while the route is live.
    ///
    /// The re-route's own write of the virtual device raises this notification
    /// again; ``AudioEqualizerEngine/reconcileSystemDefaultOutputDevice(_:)``
    /// ignores its own device, which is what terminates the loop.
    func handleMacAudioOutputChange() {
        refreshTrayOutputSymbol()
        refreshMacAudioOutputDevices()
        guard let equalizerEngine,
              equalizerEngine.isRunning,
              let outputDeviceID = macAudioOutput.currentOutputDeviceID
        else { return }

        equalizerEngine.reconcileSystemDefaultOutputDevice(outputDeviceID)
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
