import CoreGraphics
import Foundation

/// Push-to-talk key preferences (#42).
///
/// The `settings.json` field for this feature; see `Settings`. Give each new
/// field a default and decode it in `init(from:)` with
/// `decodeIfPresent(…) ?? default`, so older files and `{}` still load.
package struct HotkeySettings: Codable, Equatable {
    /// The modifier held to dictate. An unknown name decodes to the default.
    package var key: HotkeyKey = .fn

    /// Hands-free dictation: hold the key at least this long and the
    /// recording keeps running after you let go, until you press the key
    /// again. Off (push-to-talk only) when false, which is the default and
    /// what ADR-003 specifies.
    package var latch: Bool = false

    /// How long the hold must be to latch. Shorter holds are ordinary
    /// push-to-talk, so a quick dictation still ends on release.
    package var latchAfter: TimeInterval = 2

    /// A hands-free recording stops itself after this long. ADR-003 rejected
    /// latching partly because a missed stop records forever; this is the
    /// answer to that, so it is always in force.
    package var latchMaximum: TimeInterval = 300

    package init() {}

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = try c.decodeIfPresent(String.self, forKey: .key)
        key = name.flatMap(HotkeyKey.init(rawValue:)) ?? .fn
        latch = try c.decodeIfPresent(Bool.self, forKey: .latch) ?? false
        latchAfter = try c.decodeIfPresent(TimeInterval.self, forKey: .latchAfter) ?? 2
        latchMaximum = try c.decodeIfPresent(TimeInterval.self, forKey: .latchMaximum) ?? 300
    }

    /// What to hand `HotkeyMonitor.setLatch`: nil when latching is off.
    package var latchThreshold: TimeInterval? { latch ? latchAfter : nil }
}

/// The modifiers Parrot can use as its push-to-talk key (ADR-003). The raw
/// value is the name in `settings.json` and for `--hotkey`.
public enum HotkeyKey: String, Codable, CaseIterable, Sendable {
    case fn
    case leftOption = "left-option"
    case rightOption = "right-option"
    case leftCommand = "left-command"
    case rightCommand = "right-command"
    case leftControl = "left-control"
    case rightControl = "right-control"
    case leftShift = "left-shift"
    case rightShift = "right-shift"

    /// How the key is named in the menu and the Settings window.
    package var displayName: String {
        switch self {
        case .fn: return "fn"
        case .leftOption: return "Left Option (⌥)"
        case .rightOption: return "Right Option (⌥)"
        case .leftCommand: return "Left Command (⌘)"
        case .rightCommand: return "Right Command (⌘)"
        case .leftControl: return "Left Control (⌃)"
        case .rightControl: return "Right Control (⌃)"
        case .leftShift: return "Left Shift (⇧)"
        case .rightShift: return "Right Shift (⇧)"
        }
    }

    /// The short name in the menu bar and log lines: "hold right ⌥ to dictate".
    package var shortName: String {
        switch self {
        case .fn: return "fn"
        case .leftOption: return "left ⌥"
        case .rightOption: return "right ⌥"
        case .leftCommand: return "left ⌘"
        case .rightCommand: return "right ⌘"
        case .leftControl: return "left ⌃"
        case .rightControl: return "right ⌃"
        case .leftShift: return "left ⇧"
        case .rightShift: return "right ⇧"
        }
    }

    /// The virtual keycode a `flagsChanged` event carries for this key
    /// (`kVK_Function`, `kVK_Option`, `kVK_RightOption`, …).
    package var keycode: Int64 {
        switch self {
        case .fn: return 63
        case .leftOption: return 58
        case .rightOption: return 61
        case .leftCommand: return 55
        case .rightCommand: return 54
        case .leftControl: return 59
        case .rightControl: return 62
        case .leftShift: return 56
        case .rightShift: return 60
        }
    }

    /// The device-independent flag this key sets. Left and right share it.
    package var flag: CGEventFlags {
        switch self {
        case .fn: return .maskSecondaryFn
        case .leftOption, .rightOption: return .maskAlternate
        case .leftCommand, .rightCommand: return .maskCommand
        case .leftControl, .rightControl: return .maskControl
        case .leftShift, .rightShift: return .maskShift
        }
    }
}
