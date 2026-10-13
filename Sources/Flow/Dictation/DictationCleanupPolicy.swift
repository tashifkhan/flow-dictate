import Foundation

/// Shared by the local model and every cloud cleanup route.
/// Based on documented Rambler behavior, not a claim to use Google's private prompt.
enum DictationCleanupPolicy {
    /// The shared rules, from `Prompts/policy.txt`.
    static var instruction: String { PromptLibrary.render("policy.rules") }

    /// The custom words that apply here, with any description you gave them.
    static func termsLine(_ terms: [String], descriptions: [String: String]) -> String? {
        guard !terms.isEmpty else { return nil }
        let list = terms.map { term in
            let description = descriptions[term.lowercased()] ?? ""
            return description.isEmpty ? PromptLibrary.render("policy.term", ["term": term])
                : PromptLibrary.render("policy.term.described", ["term": term, "description": description])
        }
        return PromptLibrary.render("policy.terms", ["terms": list.joined(separator: ", ")])
    }

    static func replacementsLine(_ corrections: [(said: String, meant: String)]) -> String? {
        guard !corrections.isEmpty else { return nil }
        let pairs = corrections.map { PromptLibrary.render("policy.replacement", ["said": $0.said, "meant": $0.meant]) }
        return PromptLibrary.render("policy.replacements", ["pairs": pairs.joined(separator: "; ")])
    }

    /// Custom personal details the speaker chose to send every time. Context for
    /// spelling and references, never text to add on its own.
    static func speakerLine(_ details: [SpeakerDetail]) -> String? {
        guard !details.isEmpty else { return nil }
        let list = details.map { detail in
            detail.description.isEmpty
                ? PromptLibrary.render("policy.speaker.detail", ["name": detail.name, "value": detail.value])
                : PromptLibrary.render("policy.speaker.detail.described",
                                       ["name": detail.name, "description": detail.description, "value": detail.value])
        }
        return PromptLibrary.render("policy.speaker", ["details": list.joined(separator: "; ")])
    }

    static func withoutEmDashes(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s*\u{2014}\\s*", with: ", ", options: .regularExpression)
    }

    static func withoutDraftingDirections(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?i)\b(?:please\s+)?(?:make (?:that|this|it) (?:a |an )?(?:bullet(?:ed)?|numbered) list|put (?:that|this|it) (?:in|into) (?:a |an )?(?:bullet(?:ed)?|numbered) list|(?:make|keep) (?:that|this|it) (?:more professional|more casual|shorter|shorter and more direct))\s*[.!]?\s*$"#,
                                  with: "", options: .regularExpression)
    }

    static func requestsShortening(_ text: String) -> Bool {
        text.range(of: #"(?i)\b(?:make (?:that|this|it) (?:shorter|shorter and more direct)|shorten (?:that|this|it))\s*[.!]?\s*$"#,
                   options: .regularExpression) != nil
    }

    /// A model may restart a continued list at one. The local list state owns numbering.
    static func alignNumbering(_ text: String, with formatted: FormattedDictation) -> String {
        guard formatted.containsList,
              let regex = try? NSRegularExpression(pattern: "(?m)^(\\d+)\\.\\s"),
              let first = regex.firstMatch(in: formatted.text, range: NSRange(formatted.text.startIndex..., in: formatted.text)),
              let range = Range(first.range(at: 1), in: formatted.text),
              let start = Int(formatted.text[range]) else { return text }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var result = text
        for (index, match) in matches.enumerated().reversed() {
            guard let range = Range(match.range(at: 1), in: result), start <= Int.max - index else { continue }
            result.replaceSubrange(range, with: String(start + index))
        }
        return result
    }
}
