import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// The modifier key that triggers push-to-talk.
enum HotkeyTarget: String {
    case fn
    case rightCommand = "right-command"
    case rightOption = "right-option"

    var standardMask: CGEventFlags {
        switch self {
        case .fn: return .maskSecondaryFn
        case .rightCommand: return .maskCommand
        case .rightOption: return .maskAlternate
        }
    }

    /// Apple's stable virtual keycodes (kVK_RightCommand / kVK_RightOption)
    /// let us react only to the right-hand key on flagsChanged events. `fn`
    /// has no distinct left/right pair, so its mask alone is unambiguous.
    var keyCode: Int64? {
        switch self {
        case .fn: return nil
        case .rightCommand: return 54
        case .rightOption: return 61
        }
    }
}

/// Watches a single modifier key (default: Fn) and emits press/release edges.
/// Requires Accessibility permission. If the tap fails to register, callers
/// will see an error from `start()`.
final class HotkeyMonitor {
    enum Event { case pressed, released }
    enum HotkeyError: Error { case tapCreateFailed }

    private let target: HotkeyTarget
    private let debug: Bool
    private var onEvent: ((Event) -> Void)?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isPressed = false

    init(target: HotkeyTarget = .fn, debug: Bool = false) {
        self.target = target
        self.debug = debug
    }

    func start(onEvent: @escaping (Event) -> Void) throws {
        self.onEvent = onEvent

        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        if !AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary) {
            // Stay alive while the user grants. macOS withdraws a pending
            // request when the asking process dies, so exiting immediately
            // means the Settings row never appears — and parrot can never be
            // granted. Poll instead, up to three minutes.
            FileHandle.standardError.write(Data(
                "accessibility not granted — system prompt opened.\n".utf8
            ))
            FileHandle.standardError.write(Data(
                "waiting up to 180s for you to enable parrot in System Settings → Privacy & Security → Accessibility...\n".utf8
            ))

            var granted = false
            for _ in 0..<90 {
                Thread.sleep(forTimeInterval: 2)
                if AXIsProcessTrusted() {
                    granted = true
                    break
                }
            }

            guard granted else {
                FileHandle.standardError.write(Data(
                    "still not granted after 180s — giving up.\n".utf8
                ))
                throw HotkeyError.tapCreateFailed
            }
            FileHandle.standardError.write(Data("✓ accessibility granted\n".utf8))
        }

        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        // .cgSessionEventTap is the right level for an accessibility-granted
        // user process (.cghidEventTap requires root).
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: mask,
                callback: hotkeyCallback,
                userInfo: userInfo
            )
        else {
            throw HotkeyError.tapCreateFailed
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        onEvent = nil
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        if debug {
            let flags = event.flags
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            FileHandle.standardError.write(
                Data(
                    "  [debug] type=\(type.rawValue) keycode=\(keycode) flags=\(String(flags.rawValue, radix: 16))\n"
                        .utf8
                ))
        }
        guard type == .flagsChanged else { return }
        if let keyCode = target.keyCode {
            guard event.getIntegerValueField(.keyboardEventKeycode) == keyCode else { return }
        }
        let pressed = event.flags.contains(target.standardMask)
        guard pressed != isPressed else { return }
        isPressed = pressed
        onEvent?(pressed ? .pressed : .released)
    }
}

private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        // System disabled our tap; we'll need to re-enable. For now just no-op
        // and let the user restart parrot.
        return Unmanaged.passUnretained(event)
    }

    let copy = event.copy()
    DispatchQueue.main.async {
        if let copy {
            monitor.handle(type: type, event: copy)
        }
    }
    return Unmanaged.passUnretained(event)
}
