import Foundation
import Observation

/// Names, project jargon, and slang the base model mangles.
///
/// Words bias recognition. Explicit replacements and personal details resolve
/// locally before cleanup, so they also work without a language model.
@MainActor @Observable
final class Lexicon {
    struct PersonalDetails: Codable, Equatable, Sendable {
        var name = ""
        var email = ""
        var phone = ""
        var company = ""
        var address = ""
        var custom: [CustomDetail] = []

        init() {}

        // Details saved before custom fields existed have no "custom" key.
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
            email = try values.decodeIfPresent(String.self, forKey: .email) ?? ""
            phone = try values.decodeIfPresent(String.self, forKey: .phone) ?? ""
            company = try values.decodeIfPresent(String.self, forKey: .company) ?? ""
            address = try values.decodeIfPresent(String.self, forKey: .address) ?? ""
            custom = try values.decodeIfPresent([CustomDetail].self, forKey: .custom) ?? []
        }
    }

    /// A detail you name yourself, such as "GitHub" or "work email". Saying
    /// "my GitHub" inserts its value.
    struct CustomDetail: Codable, Equatable, Hashable, Identifiable, Sendable {
        var id = UUID()
        var label = ""
        /// What the value is, for the model: "personal profile link".
        var description = ""
        var value = ""
        /// Sent as context with every cleanup request, not only when you say it.
        var alwaysInPrompt = false

        init(label: String = "", description: String = "", value: String = "", alwaysInPrompt: Bool = false) {
            self.label = label
            self.description = description
            self.value = value
            self.alwaysInPrompt = alwaysInPrompt
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            label = try values.decodeIfPresent(String.self, forKey: .label) ?? ""
            description = try values.decodeIfPresent(String.self, forKey: .description) ?? ""
            value = try values.decodeIfPresent(String.self, forKey: .value) ?? ""
            alwaysInPrompt = try values.decodeIfPresent(Bool.self, forKey: .alwaysInPrompt) ?? false
        }

        /// "My GitHub" and "GitHub" name the same field.
        var spokenLabel: String {
            var label = self.label.trimmingCharacters(in: .whitespacesAndNewlines)
            if label.lowercased().hasPrefix("my ") { label = String(label.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
            return label
        }

        var isComplete: Bool {
            !spokenLabel.isEmpty && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var personalDetails = PersonalDetails() {
        didSet {
            if let data = try? JSONEncoder().encode(personalDetails) {
                defaults.set(data, forKey: "lexiconPersonalDetails")
            }
        }
    }
    /// A time you fixed the model's output by hand or by voice.
    struct Correction: Codable, Hashable, Identifiable, Sendable {
        var id = UUID()
        var from: String
        var to: String
        var at: Date = .now
    }

    private(set) var words: [String] = []
    private(set) var corrections: [Correction] = []
    /// What a custom word means, keyed by the word in lowercase. Kept apart from
    /// `words` so the saved word list and speech-model training stay plain strings.
    private(set) var wordDescriptions: [String: String] = [:]

    private let defaults: UserDefaults
    private static let wordsKey = "lexiconWords"
    private static let correctionsKey = "lexiconCorrections"
    private static let wordDescriptionsKey = "lexiconWordDescriptions"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "lexiconPersonalDetails"),
           let details = try? JSONDecoder().decode(PersonalDetails.self, from: data) {
            personalDetails = details
        }
        words = defaults.stringArray(forKey: Self.wordsKey) ?? []
        wordDescriptions = defaults.dictionary(forKey: Self.wordDescriptionsKey) as? [String: String] ?? [:]
        if let data = defaults.data(forKey: Self.correctionsKey),
           let decoded = try? JSONDecoder().decode([Correction].self, from: data) {
            corrections = decoded
        }
    }

    func addWord(_ word: String) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !contains(trimmed) else { return }
        words.append(trimmed)
        persistWords()
    }

    /// Bulk add, for pasting a glossary in or importing a file. Accepts newline, comma,
    /// semicolon, or tab separated input, which covers a pasted column, a CSV, and a
    /// plain list without asking anyone to care about the difference.
    ///
    /// Returns how many were actually new, so the UI can say so.
    @discardableResult
    func addWords(_ text: String) -> Int {
        let before = words.count
        let tokens = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "," || $0 == ";" || $0 == "\t" })
        for token in tokens {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !contains(trimmed) else { continue }
            words.append(trimmed)
        }
        if words.count != before { persistWords() }
        return words.count - before
    }

    /// The word list as a file: one per line, stable order.
    var exportedWords: String { words.joined(separator: "\n") }

    func contains(_ word: String) -> Bool {
        words.contains { $0.caseInsensitiveCompare(word) == .orderedSame }
    }

    func removeWord(_ word: String) {
        words.removeAll { $0 == word }
        persistWords()
        if !contains(word) { setDescription("", for: word) }
    }

    func description(for word: String) -> String { wordDescriptions[word.lowercased()] ?? "" }

    /// Saved as typed, so a live text field keeps the space you just typed. The prompt
    /// trims it.
    func setDescription(_ description: String, for word: String) {
        let key = word.lowercased()
        let stored = description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : description
        guard wordDescriptions[key] != stored else { return }
        wordDescriptions[key] = stored
        defaults.set(wordDescriptions, forKey: Self.wordDescriptionsKey)
    }

    func record(from: String, to: String) {
        let from = from.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = to.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !from.isEmpty, !to.isEmpty, from != to else { return }
        corrections.removeAll { $0.from.caseInsensitiveCompare(from) == .orderedSame }
        corrections.append(Correction(from: from, to: to))
        if corrections.count > 200 { corrections.removeFirst(corrections.count - 200) }
        persistCorrections()
    }

    func removeCorrection(_ correction: Correction) {
        corrections.removeAll { $0.id == correction.id }
        persistCorrections()
    }

    var substitutions: DictationSubstitutions {
        var rules = corrections.map { DictationSubstitutions.Rule(from: $0.from, to: $0.to) }
        let details = personalDetails
        for (aliases, value) in [
            (["my name", "my full name"], details.name),
            (["my email", "my email address"], details.email),
            (["my phone", "my phone number", "my mobile number"], details.phone),
            (["my company", "my company name"], details.company),
            (["my address", "my mailing address"], details.address),
        ] where !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rules += aliases.map { .init(from: $0, to: value.trimmingCharacters(in: .whitespacesAndNewlines), personal: true) }
        }
        for detail in details.custom where detail.isComplete {
            rules.append(.init(from: "my " + detail.spokenLabel.lowercased(),
                               to: detail.value.trimmingCharacters(in: .whitespacesAndNewlines), personal: true))
        }
        return DictationSubstitutions(rules: rules, vocabulary: recognitionWords)
    }

    func removeCustomDetail(_ id: CustomDetail.ID) {
        personalDetails.custom.removeAll { $0.id == id }
    }

    /// Custom details you chose to send with every request, as the model reads them.
    var promptDetails: [SpeakerDetail] {
        personalDetails.custom.filter { $0.alwaysInPrompt && $0.isComplete }.map {
            SpeakerDetail(name: $0.spokenLabel, description: $0.description.trimmingCharacters(in: .whitespacesAndNewlines),
                          value: $0.value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    var recognitionWords: [String] {
        words + (personalDetails.name.isEmpty ? [] : [personalDetails.name])
    }

    /// Only the custom words that plausibly show up in this transcript. Sending all of
    /// them every time is how you blow a 3B model's attention on a glossary.
    func matches(in raw: String) -> [String] {
        let haystack = raw.lowercased()
        return words.filter { word in
            let needle = word.lowercased()
            if haystack.contains(needle) { return true }
            // Catch near misses too: "tashif" heard as "tashiff", "taashif".
            return haystack.split(separator: " ").contains { token in
                token.count >= 4 && Self.close(String(token), needle)
            }
        }
    }

    /// Cheap edit-distance gate: within one edit, or a shared prefix of four.
    private static func close(_ a: String, _ b: String) -> Bool {
        if abs(a.count - b.count) > 2 { return false }
        if a.prefix(4) == b.prefix(4) { return true }
        return distance(Array(a), Array(b)) <= 1
    }

    private static func distance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    private func persistWords() { defaults.set(words, forKey: Self.wordsKey) }

    private func persistCorrections() {
        if let data = try? JSONEncoder().encode(corrections) {
            defaults.set(data, forKey: Self.correctionsKey)
        }
    }
}
