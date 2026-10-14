import Foundation
import ParrotCore

/// Silences the output while recording and restores it the moment the
/// recording stops — before transcription, so audio returns without waiting
/// on the model.
///
/// Every ending path restores: finished, failed, and a cancelled short tap
/// or chord, which arrive as `dictationFailed(DictationError.cancelled)`.
@MainActor
final class MuteObserver: DictationObserver {
    func dictationStarted() {
        SystemOutput.silence()
    }

    func dictationTranscribing() {
        SystemOutput.restore()
    }

    func dictationFinished(_ result: DictationResult) {
        // Belt and braces: a capture that never reached `transcribing`.
        SystemOutput.restore()
    }

    func dictationFailed(_ error: Error) {
        SystemOutput.restore()
    }
}
