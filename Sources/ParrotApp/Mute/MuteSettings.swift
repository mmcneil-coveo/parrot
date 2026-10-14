import Foundation

/// Output-muting preferences.
///
/// The `settings.json` field for this feature; see `Settings`.
struct MuteSettings: Codable, Equatable {
    /// Silence the default output device while recording, so playing audio
    /// does not bleed into the mic or talk over you. The previous state is
    /// restored when the recording stops.
    var whileRecording: Bool = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        whileRecording = try c.decodeIfPresent(Bool.self, forKey: .whileRecording) ?? false
    }
}
