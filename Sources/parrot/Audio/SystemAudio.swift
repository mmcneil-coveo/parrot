import AudioToolbox
import CoreAudio
import Foundation

/// Mutes the default output device while recording, so playing audio doesn't
/// bleed into the mic or talk over you, then puts it back exactly as it was.
///
/// Uses CoreAudio rather than shelling out to `osascript` — no subprocess on
/// every hotkey press, and no Automation permission to grant.
enum SystemAudio {
    /// What the output was before we touched it. nil = we haven't muted.
    private static var saved: SavedState?

    private enum SavedState {
        case mute(UInt32)      // device supports a real mute switch
        case volume(Float32)   // it doesn't; we dropped the volume instead
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID
        )
        return status == noErr ? deviceID : nil
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// Silence the default output, remembering how to undo it.
    /// Safe to call twice — the second call is a no-op, so we never overwrite
    /// the saved state with the already-muted value.
    static func mute() {
        guard saved == nil, let device = defaultOutputDevice() else { return }

        var muteAddr = address(kAudioDevicePropertyMute)
        if AudioObjectHasProperty(device, &muteAddr) {
            var current: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(device, &muteAddr, 0, nil, &size, &current) == noErr {
                var on: UInt32 = 1
                if AudioObjectSetPropertyData(
                    device, &muteAddr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &on
                ) == noErr {
                    saved = .mute(current)
                    return
                }
            }
        }

        // No mute switch (common on aggregate/virtual devices) — drop volume.
        var volAddr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        guard AudioObjectHasProperty(device, &volAddr) else { return }
        var current: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &volAddr, 0, nil, &size, &current) == noErr else { return }
        var zero: Float32 = 0
        if AudioObjectSetPropertyData(
            device, &volAddr, 0, nil, UInt32(MemoryLayout<Float32>.size), &zero
        ) == noErr {
            saved = .volume(current)
        }
    }

    /// Put the output back the way we found it.
    static func restore() {
        guard let state = saved, let device = defaultOutputDevice() else {
            saved = nil
            return
        }
        switch state {
        case .mute(var previous):
            var addr = address(kAudioDevicePropertyMute)
            _ = AudioObjectSetPropertyData(
                device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &previous
            )
        case .volume(var previous):
            var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
            _ = AudioObjectSetPropertyData(
                device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &previous
            )
        }
        saved = nil
    }
}
