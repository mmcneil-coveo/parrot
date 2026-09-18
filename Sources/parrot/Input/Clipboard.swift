import AppKit
import Foundation

/// Writes transcripts to the system pasteboard.
///
/// Copying happens *before* injection so the text survives even when
/// `TextInjector` drops characters — some Electron apps and secure fields
/// swallow synthesized key events, and ⌘V is the fallback in those cases.
enum Clipboard {
    /// Replace the pasteboard contents with `text`.
    @MainActor
    static func copy(_ text: String) {
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
