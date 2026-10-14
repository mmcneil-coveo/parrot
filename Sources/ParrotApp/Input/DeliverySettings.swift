import Foundation

/// Where a finished transcript ends up, beyond the cursor.
///
/// The `settings.json` field for this feature; see `Settings`.
struct DeliverySettings: Codable, Equatable {
    /// Leave each transcript on the clipboard after pasting it, instead of
    /// restoring what was there before. Paste mode normally borrows the
    /// clipboard and puts it back; this keeps the transcript so it can be
    /// pasted again.
    var keepOnClipboard: Bool = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keepOnClipboard = try c.decodeIfPresent(Bool.self, forKey: .keepOnClipboard) ?? false
    }
}
