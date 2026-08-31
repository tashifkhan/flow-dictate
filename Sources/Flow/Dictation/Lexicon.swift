import Foundation
import Observation

/// Names, project jargon, and slang the base model mangles.
///
/// Two uses, both cheap: the words go to the recogniser as contextual strings, and
/// the recent corrections go into the cleanup instructions. This is the "have stuff
/// prepopulated, like a coding agent" idea from the note, and it is most of the win.
@MainActor @Observable
final class Lexicon {
    /// A time you fixed the model's output by hand or by voice.
    struct Correction: Codable, Hashable, Identifiable, Sendable {
        var id = UUID()
        var from: String
        var to: String
        var at: Date = .now
    }

    private(set) var words: [String] = []
    private(set) var corrections: [Correction] = []

    private let defaults = UserDefaults.standard
    private static let wordsKey = "lexiconWords"
    private static let correctionsKey = "lexiconCorrections"

    /// How many corrections ride along in the instructions. The on-device model has a
    /// small context and a short prompt beats a complete one.
    private static let recentLimit = 12

    init() {
        words = defaults.stringArray(forKey: Self.wordsKey) ?? []
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

    /// The newest corrections, as "said → meant" pairs for the prompt.
    var recent: [Correction] {
        Array(corrections.suffix(Self.recentLimit).reversed())
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
