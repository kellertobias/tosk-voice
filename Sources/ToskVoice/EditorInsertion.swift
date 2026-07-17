import Foundation

/// Spacing rules for splicing dictated text into an existing document at an
/// arbitrary caret position or over a selection.
enum EditorInsertion {
    /// Returns `text` padded with a leading and/or trailing space so the
    /// splice at `range` in `document` does not glue words together. A
    /// trailing space is omitted before closing punctuation, and at the end
    /// of the document (the next utterance pads its own left side).
    static func padded(_ text: String, in document: String, replacing range: NSRange) -> String {
        guard !text.isEmpty else { return text }
        let ns = document as NSString
        var result = text
        if range.location > 0, range.location <= ns.length,
           let before = UnicodeScalar(ns.character(at: range.location - 1)),
           !CharacterSet.whitespacesAndNewlines.contains(before),
           !result.hasPrefix(" ") {
            result = " " + result
        }
        let afterIndex = range.location + range.length
        if afterIndex < ns.length, let after = UnicodeScalar(ns.character(at: afterIndex)),
           !CharacterSet.whitespacesAndNewlines.contains(after),
           !Self.closingPunctuation.contains(after),
           !result.hasSuffix(" ") {
            result += " "
        }
        return result
    }

    private static let closingPunctuation = CharacterSet(charactersIn: ".,;:!?)]}»›’”")
}

/// Standalone spoken replacements ("replace A with B", "ersetze A durch B").
/// The editor routes them to the correction model and, when the model is
/// unavailable or declines, applies them literally.
enum SpokenReplacement {
    static func parse(_ utterance: String) -> (target: String, replacement: String)? {
        let patterns = [
            #"(?i)^replace\s+(.+?)\s+with\s+(.+?)[.!?]?$"#,
            #"(?i)^ersetze\s+(.+?)\s+durch\s+(.+?)[.!?]?$"#,
        ]
        let trimmed = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        let ns = trimmed as NSString
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(location: 0, length: ns.length)
            guard let match = expression.firstMatch(in: trimmed, range: range), match.numberOfRanges == 3 else { continue }
            return (ns.substring(with: match.range(at: 1)), ns.substring(with: match.range(at: 2)))
        }
        return nil
    }

    static func apply(to document: String, utterance: String) -> String? {
        guard let (target, replacement) = parse(utterance),
              document.range(of: target, options: [.caseInsensitive, .diacriticInsensitive]) != nil else { return nil }
        return document.replacingOccurrences(of: target, with: replacement, options: [.caseInsensitive, .diacriticInsensitive])
    }
}
