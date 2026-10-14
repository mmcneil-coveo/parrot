import Foundation

/// Turns hotkey edges into dictation actions (ADR-003). Pure, so the rules
/// are tested without an event tap.
///
/// The tap sees modifier changes only, so it cannot see the C in ⌘C. Two
/// rules keep a shortcut typed on the hotkey from producing text:
/// - A hold shorter than `minimumHold` is discarded without transcribing.
/// - A recording is cancelled if another modifier changes while the hotkey
///   is held, and a press while another modifier is already held does not
///   record. Either way the rest of that hold is ignored.
///
/// Recording still starts on key-down, so press latency is unchanged; a
/// discarded hold just throws its audio away.
public struct Gesture {
    /// Holds shorter than this are taps or shortcuts, not dictation.
    public static let minimumHold: TimeInterval = 0.3

    /// Hold at least this long and the recording latches on release: it keeps
    /// running hands-free until the hotkey is pressed again. Off when nil.
    public var latchAfter: TimeInterval?

    /// A latched recording stops itself after this long. ADR-003 rejected
    /// latching partly because a missed stop leaves it recording forever; the
    /// cap is what answers that, so latching is never offered without one.
    public var maximumLatched: TimeInterval = 300

    public enum Input: Equatable {
        /// The hotkey went down. `othersHeld`: another modifier was already
        /// down, so this is a chord.
        case hotkeyDown(othersHeld: Bool)
        /// The hotkey went up.
        case hotkeyUp
        /// Another modifier changed while the hotkey was down.
        case otherModifier
    }

    public enum Action: Equatable {
        /// Start recording.
        case start
        /// Stop recording and transcribe.
        case transcribe
        /// Stop recording and discard it.
        case cancel
    }

    private enum Phase: Equatable {
        case idle
        /// Recording since this time.
        case recording(since: TimeInterval)
        /// Recording hands-free since this time; the hotkey is not held.
        case latched(since: TimeInterval)
        /// The hotkey is down but this hold is a chord: ignore it until release.
        case ignoring
    }

    private var phase: Phase = .idle

    public init(latchAfter: TimeInterval? = nil, maximumLatched: TimeInterval = 300) {
        self.latchAfter = latchAfter
        self.maximumLatched = maximumLatched
    }

    /// Whether a hands-free recording is running.
    public var isLatched: Bool {
        if case .latched = phase { return true }
        return false
    }

    /// Whether the hotkey is down, as far as the edges seen so far say.
    public var isHeld: Bool {
        switch phase {
        case .idle, .latched: return false
        case .recording, .ignoring: return true
        }
    }

    /// Feed one edge at `time` (seconds on a monotonic clock).
    public mutating func handle(_ input: Input, at time: TimeInterval) -> Action? {
        switch (phase, input) {
        case (.idle, .hotkeyDown(let othersHeld)):
            if othersHeld {
                phase = .ignoring
                return nil
            }
            phase = .recording(since: time)
            return .start
        case (.recording(let since), .hotkeyUp):
            let held = time - since
            if held < Self.minimumHold {
                phase = .idle
                return .cancel
            }
            if let latchAfter, held >= latchAfter {
                // Held long enough to mean "keep going": stay recording with
                // the key released, until the next press.
                phase = .latched(since: since)
                return nil
            }
            phase = .idle
            return .transcribe
        case (.recording, .otherModifier):
            phase = .ignoring
            return .cancel
        case (.latched, .hotkeyDown):
            // The press that ends a hands-free recording. Ignore its release.
            phase = .ignoring
            return .transcribe
        case (.latched, _):
            // Other modifiers move freely while latched: the hotkey is not
            // held, so these are ordinary typing, not a chord.
            return nil
        case (.ignoring, .hotkeyUp):
            phase = .idle
            return nil
        default:
            // A repeated down, an up with no down seen, or a modifier change
            // outside a recording.
            return nil
        }
    }

    /// Call periodically while latched. Stops and transcribes once the
    /// recording has run past `maximumLatched`, so a forgotten stop costs one
    /// long transcript rather than an unbounded recording.
    public mutating func tick(at time: TimeInterval) -> Action? {
        guard case .latched(let since) = phase, time - since >= maximumLatched else { return nil }
        phase = .idle
        return .transcribe
    }

    /// Forget the current hold, for a switch to another key. A recording in
    /// progress is cancelled.
    public mutating func reset() -> Action? {
        defer { phase = .idle }
        switch phase {
        case .recording, .latched: return .cancel
        case .idle, .ignoring: return nil
        }
    }
}
