import Foundation

/// Explicit user rules run locally, including when model cleanup is disabled.
struct DictationSubstitutions: Sendable {
    struct Rule: Sendable {
        var from: String
        var to: String
        var personal = false
    }
    var rules: [Rule] = []
    var vocabulary: [String] = []

    func apply(_ text: String) -> String {
        let text = normalizeVocabulary(in: text)
        let lookup = ruleLookup
        guard !lookup.isEmpty else { return text }
        let alternatives = Self.alternatives(lookup)
        if let value = directInsertion(text, lookup: lookup, alternatives: alternatives) { return value }
        guard let regex = try? NSRegularExpression(pattern: "(?i)(?<![\\p{L}\\p{N}_])(?:" + alternatives + ")(?![\\p{L}\\p{N}_])") else { return text }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var result = text
        // One pass prevents a replacement value from triggering another rule.
        for match in matches.reversed() {
            guard let originalRange = Range(match.range, in: text),
                  let range = Range(match.range, in: result),
                  let value = lookup[String(text[originalRange]).lowercased()] else { continue }
            if value.personal {
                let following = String(text[originalRange.upperBound...])
                // A statement about a detail is ordinary dictation, not a placeholder.
                if following.range(of: #"(?i)^\s+(?:is|was|isn't|wasn't|has|will|should|would|account|settings|provider)\b"#,
                                   options: .regularExpression) != nil { continue }
            }
            result.replaceSubrange(range, with: value.to)
        }
        return result
    }

    func relevantRules(in text: String) -> [Rule] {
        rules.filter { DictationSubstitutions(rules: [$0]).apply(text) != text }
    }

    func preservesValues(in text: String, source: String) -> Bool {
        let resolved = apply(source)
        return relevantRules(in: normalizeVocabulary(in: source))
            .filter { resolved.contains($0.to) }
            .allSatisfy { text.contains($0.to) }
    }

    /// A request for one saved value needs no model call or extra punctuation.
    func directInsertion(_ text: String) -> String? {
        let lookup = ruleLookup
        guard !lookup.isEmpty else { return nil }
        return directInsertion(text, lookup: lookup, alternatives: Self.alternatives(lookup))
    }

    private var ruleLookup: [String: Rule] {
        var lookup: [String: Rule] = [:]
        for rule in rules where !rule.from.isEmpty && !rule.to.isEmpty { lookup[rule.from.lowercased()] = rule }
        return lookup
    }

    private static func alternatives(_ lookup: [String: Rule]) -> String {
        lookup.keys.sorted { $0.count == $1.count ? $0 < $1 : $0.count > $1.count }
            .map(NSRegularExpression.escapedPattern).joined(separator: "|")
    }

    private func directInsertion(_ text: String, lookup: [String: Rule], alternatives: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = "(?i)^(?:(?:please[,.]?\\s+)?(?:add|insert|type|write|enter|put|fill in)\\s+)?("
            + alternatives + ")(?:\\s+(?:here|there))?(?:\\s+please)?[.!?]?$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let range = Range(match.range(at: 1), in: trimmed) else { return nil }
        return lookup[String(trimmed[range]).lowercased()]?.to
    }

    func normalizeVocabulary(in text: String) -> String {
        let words = vocabulary.filter { $0.allSatisfy(\.isLetter) }
        guard !words.isEmpty, let regex = try? NSRegularExpression(pattern: "[\\p{L}\\p{M}]+") else { return text }
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let sourceRange = Range(match.range, in: text), let range = Range(match.range, in: result) else { continue }
            let token = String(text[sourceRange])
            let candidates = words.filter {
                $0.caseInsensitiveCompare(token) == .orderedSame
                    || (token.count >= 4 && $0.count >= 4 && Self.oneEdit(token.lowercased(), $0.lowercased()))
            }
            let exact = candidates.first { $0.caseInsensitiveCompare(token) == .orderedSame }
            if let canonical = exact ?? (candidates.count == 1 ? candidates.first : nil) {
                result.replaceSubrange(range, with: canonical)
            }
        }
        return result
    }

    private static func oneEdit(_ a: String, _ b: String) -> Bool {
        let a = Array(a), b = Array(b)
        guard abs(a.count - b.count) <= 1 else { return false }
        var i = 0, j = 0, edits = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] { i += 1; j += 1; continue }
            edits += 1
            if edits > 1 { return false }
            if a.count >= b.count { i += 1 }
            if b.count >= a.count { j += 1 }
        }
        return edits + (a.count - i) + (b.count - j) <= 1
    }
}
