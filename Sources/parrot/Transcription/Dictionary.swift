import Foundation

/// User-supplied word replacements applied to transcripts before they are
/// copied or injected.
///
/// The file is JSON: `replacements` maps category names to `heard → typed`
/// pairs. Categories exist purely so a large file stays readable; they are
/// flattened on load. Keys starting with `_` are treated as notes and skipped.
///
/// A missing file is not an error — the dictionary is optional. A malformed
/// one is reported but does NOT stop parrot: losing dictation entirely is a
/// worse failure than losing replacements.
struct ReplacementDictionary {
    /// Compiled patterns, longest key first so "us foods" wins over "foods".
    private let rules: [(regex: NSRegularExpression, replacement: String)]

    /// Number of active replacements.
    var count: Int { rules.count }

    static var defaultPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.config/parrot/dictionary.json"
    }

    /// An empty dictionary — every transcript passes through untouched.
    static let empty = ReplacementDictionary(rules: [])

    private init(rules: [(regex: NSRegularExpression, replacement: String)]) {
        self.rules = rules
    }

    enum LoadError: Error, CustomStringConvertible {
        case notJSON
        case missingReplacements

        var description: String {
            switch self {
            case .notJSON: return "not valid JSON"
            case .missingReplacements: return "no top-level \"replacements\" object"
            }
        }
    }

    /// Parse the file at `path`. Returns nil if the file simply isn't there.
    /// Throws only when the file exists but can't be understood.
    static func load(path: String) throws -> ReplacementDictionary? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LoadError.notJSON
        }
        guard let replacements = root["replacements"] as? [String: Any] else {
            throw LoadError.missingReplacements
        }

        // Flatten: values are either category dictionaries or direct pairs.
        var pairs: [(String, String)] = []
        for (key, value) in replacements {
            if key.hasPrefix("_") { continue }
            if let heard = value as? String {
                pairs.append((key, heard))
            } else if let category = value as? [String: Any] {
                for (h, t) in category {
                    guard !h.hasPrefix("_"), let typed = t as? String else { continue }
                    pairs.append((h, typed))
                }
            }
        }

        // Longest first: a longer phrase must win before a shorter substring
        // of it gets a chance to match.
        pairs.sort { $0.0.count > $1.0.count }

        var rules: [(NSRegularExpression, String)] = []
        for (heard, typed) in pairs {
            let escaped = NSRegularExpression.escapedPattern(for: heard)
            // \b is unreliable next to non-word characters (apostrophes,
            // hyphens), so only anchor the sides that begin/end with a word
            // character.
            let lead = heard.first.map(isWordish) == true ? #"\b"# : ""
            let tail = heard.last.map(isWordish) == true ? #"\b"# : ""
            guard let regex = try? NSRegularExpression(
                pattern: lead + escaped + tail,
                options: [.caseInsensitive]
            ) else { continue }
            rules.append((regex, typed))
        }

        return ReplacementDictionary(rules: rules)
    }

    private static func isWordish(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }

    /// Apply every rule to `text`, in longest-key-first order.
    func apply(to text: String) -> String {
        guard !rules.isEmpty else { return text }
        var out = text
        for (regex, replacement) in rules {
            let range = NSRange(out.startIndex..., in: out)
            out = regex.stringByReplacingMatches(
                in: out,
                range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: replacement)
            )
        }
        return out
    }
}
