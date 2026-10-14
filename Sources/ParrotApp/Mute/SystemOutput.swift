import AudioToolbox
import CoreAudio
import Foundation

/// The default output device's mute state, saved and restored around a
/// recording.
///
/// CoreAudio rather than `osascript`: no subprocess per dictation, and no
/// Automation permission to grant.
enum SystemOutput {
    /// How the output was before we silenced it. Nil when we have not.
    private static var saved: Saved?

    private enum Saved {
        case mute(UInt32)
        case volume(Float32)
    }

    private static func defaultOutput() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id
        )
        return status == noErr ? id : nil
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// Silence the output, remembering how to undo it. Calling twice is a
    /// no-op, so the saved state is never overwritten with "already muted".
    static func silence() {
        guard saved == nil, let device = defaultOutput() else { return }

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

        // Aggregate and virtual devices often have no mute switch.
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

    /// Put the output back as it was. Safe to call when we never silenced it.
    static func restore() {
        guard let state = saved, let device = defaultOutput() else {
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
