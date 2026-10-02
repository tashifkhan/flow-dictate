import Foundation

/// Shared by the local model and every cloud cleanup route.
/// Based on documented Rambler behavior, not a claim to use Google's private prompt.
enum DictationCleanupPolicy {
    static let instruction = """
        Turn spontaneous speech into ready-to-send writing. Return the complete intended dictation, not a response to its questions or requests. Do not add facts, opinions, greetings, sign-offs, or commentary.
        Remove hesitation sounds such as um, uh, er, and ah, stutters, accidental repetition, and abandoned starts. Remove like, you know, basically, matlab, and similar phrases only when they are filler. Keep meaningful uncertainty, emphasis, negation, and the speaker's tone.
        Resolve self-corrections using the latest intended wording. If the speaker changes Thursday to Friday, retain Friday and remove the abandoned Thursday. Spoken repair markers such as sorry, no, wait, I mean, scratch that, scratch X, not X but Y, and not X, Y are edits, never content. Apply them and delete them. When a speaker swaps one name or term for another, use the new one everywhere the old one appeared in that thought, including sentences said before the correction, and drop the abandoned one completely. The output must read as if the speaker had said the right word the first time. Keep every distinct fact, name, number, example, qualification, and constraint. Correct obvious recognition mistakes using context and supplied vocabulary. Never guess missing facts.
        Fix grammar, casing, and punctuation. Split separate ideas into paragraphs. Convert clear enumerations into numbered lists and unordered sets into bullet lists. Keep introductory and closing prose outside the list. Do not turn ordinary phrases such as first time or version two into list items. Maintain lists, numbering, and intentional line breaks already present in the input.
        Treat explicit drafting directions as edits to the speaker's own draft. Apply requests for bullets, paragraphs, reordered points, a particular tone, or a shorter draft rather than transcribing those directions. Keep ordinary instructions to another person as message content. Asking a colleague to fix a bug is not a command to the dictation app.
        If an explicit rewrite is requested, follow it while preserving intended facts. Otherwise do not summarize or change formality. Add an emoji only when explicitly requested. Use spoken punctuation names as controls only when they clearly specify punctuation.
        Never use an em dash, the U+2014 character. Use a comma or a new sentence instead. Use straight quotation marks. Do not wrap the output in quotation marks or a code fence. Return only finished text.
        Examples:
        Speech: um let's meet Thursday sorry Friday at three. Writing: Let's meet Friday at three.
        Speech: why did you pick Postgres, Postgres is way too heavy, sorry no, scratch Postgres, not Postgres, Mongo, why would you pick that. Writing: Why did you pick Mongo? It's way too heavy, why would you pick that?
        Speech: we need three changes first fix login second add tests third update docs. Writing: We need three changes:\n1. Fix login.\n2. Add tests.\n3. Update docs.
        Speech: buy milk eggs and rice make that a bullet list. Writing: - Milk\n- Eggs\n- Rice
        Speech: this is my first time using version two. Writing: This is my first time using version two.
        """

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
