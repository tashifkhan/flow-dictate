import Foundation
import FoundationModels
import OSLog

/// What the model decided your speech was.
enum DictationMode: String, Sendable, CaseIterable {
    case insert, replace, delete, format
}

/// One round trip covers both dictation and voice commands, so "scratch that" and a
/// sentence about lunch cost the same.
struct Decision: Sendable {
    var mode: DictationMode
    /// Text to insert. For `replace`, the replacement.
    var text: String
    /// Target of a replace or delete.
    var target: String?

    static func raw(_ text: String) -> Decision {
        Decision(mode: .insert, text: text, target: nil)
    }
}

/// Everything the model is told before it sees a word you said.
struct CleanupContext: Sendable {
    var appName: String
    var bundleID: String
    var axRole: String
    var appDescription: String
    var writingContext: WritingContext
    var transcriptionLanguage: TranscriptionLanguage
    var vocabulary: [String] = []
    var corrections: [(said: String, meant: String)] = []
    /// The last thing Flow typed, so "scratch that" has a referent.
    var lastInsert: String?
}

/// Why cleanup is off, in words a person can act on.
enum CleanupAvailability: Equatable, Sendable {
    case available
    case disabledBySetting
    case appleIntelligenceOff
    case deviceNotEligible
    case modelNotReady
    case unsupportedLanguage(String)
    case unknown

    var isAvailable: Bool { self == .available }

    var label: String {
        switch self {
        case .available: "Cleanup on"
        case .disabledBySetting: "Cleanup off"
        case .appleIntelligenceOff: "Cleanup off · Apple Intelligence disabled"
        case .deviceNotEligible: "Cleanup off · this Mac can't run it"
        case .modelNotReady: "Cleanup off · model not ready"
        case .unsupportedLanguage: "Cleanup off · unsupported language"
        case .unknown: "Cleanup off"
        }
    }

    var detail: String? {
        switch self {
        case .appleIntelligenceOff:
            "Turn on Apple Intelligence in System Settings to strip filler and fix punctuation. Dictation works either way."
        case .deviceNotEligible:
            "Cleanup needs an Apple silicon Mac. Flow will insert the raw transcript."
        case .modelNotReady:
            if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 {
                "macOS 27 has not enabled the on-device model. Make the Siri language match the macOS language, then turn on Apple Intelligence if the option appears. Install the latest macOS beta if it stays unavailable."
            } else {
                "macOS says the Apple Intelligence model is still downloading or unavailable for a system reason. Keep the Mac awake, plugged in, and on Wi-Fi. Flow will detect it automatically. Dictation already works without cleanup."
            }
        case .unsupportedLanguage(let language):
            "Apple's on-device model does not support \(language) on this Mac. Set both macOS and Siri to the same supported language, such as English (US), English (UK), or English (Australia)."
        default: nil
        }
    }
}

/// The cleanup pass, and the guardrail that it is never load-bearing.
///
/// Every failure path here returns the raw transcript rather than throwing, because a
/// dictation app that inserts nothing is worse than one that inserts "um".
actor CleanupService {
    private let log = Logger(subsystem: "sh.taf.flow", category: "cleanup")
    private let model = SystemLanguageModel.default

    /// Built once. `@Generable` would generate this, but its macro plugin ships with
    /// Xcode, so the schema is assembled through the dynamic API instead. Same
    /// guided generation, same constrained decoding.
    private lazy var decisionSchema: GenerationSchema? = {
        let mode = DynamicGenerationSchema(
            name: "mode",
            description: "insert for ordinary speech, replace/delete for corrections, format for layout commands",
            anyOf: DictationMode.allCases.map(\.rawValue)
        )
        let root = DynamicGenerationSchema(name: "Decision", properties: [
            .init(name: "mode", schema: mode),
            .init(name: "text",
                  description: "the cleaned text to insert, or the replacement text",
                  schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "target",
                  description: "the words being replaced or deleted, if any",
                  schema: DynamicGenerationSchema(type: String.self),
                  isOptional: true),
        ])
        return try? GenerationSchema(root: root, dependencies: [])
    }()

    private lazy var summarySchema: GenerationSchema? = {
        let root = DynamicGenerationSchema(name: "NoteSummary", properties: [
            .init(name: "title", description: "six words or fewer",
                  schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "summary", description: "two or three sentences",
                  schema: DynamicGenerationSchema(type: String.self)),
        ])
        return try? GenerationSchema(root: root, dependencies: [])
    }()

    var availability: CleanupAvailability {
        switch model.availability {
        case .available: return .available
        case .unavailable(.appleIntelligenceNotEnabled):
            if !model.supportedLanguages.contains(Locale.current.language) {
                let language = Locale.current.localizedString(forIdentifier: Locale.current.identifier)
                    ?? Locale.current.identifier
                return .unsupportedLanguage(language)
            }
            return .appleIntelligenceOff
        case .unavailable(.deviceNotEligible): return .deviceNotEligible
        case .unavailable(.modelNotReady): return .modelNotReady
        case .unavailable: return .unknown
        }
    }

    /// Warms the model so the first dictation is not the slow one.
    func prewarm() {
        guard case .available = model.availability else { return }
        LanguageModelSession(model: model).prewarm()
    }

    // MARK: - Cleanup

    /// Cleans a raw transcript, or classifies it as a command. Never throws.
    func clean(_ raw: String, context: CleanupContext) async -> Decision {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .raw("") }

        let fallback = context.transcriptionLanguage == .hinglish
            ? Self.romanizeHinglish(trimmed)
            : trimmed

        guard case .available = model.availability, let schema = decisionSchema else {
            return .raw(fallback)
        }

        let session = LanguageModelSession(model: model) {
            instructions(for: context)
        }

        do {
            let response = try await session.respond(
                to: trimmed,
                schema: schema,
                options: GenerationOptions(samplingMode: .greedy)
            )
            var decision = try parse(response.content, fallback: fallback, spoken: trimmed)
            if context.transcriptionLanguage == .hinglish {
                decision.text = Self.romanizeHinglish(decision.text)
            }
            return decision
        } catch {
            log.error("cleanup failed, inserting raw: \(error.localizedDescription, privacy: .public)")
            return .raw(fallback)
        }
    }

    /// The model sees the whole thought after recording ends. That lets it clean false
    /// starts and repairs that a streaming word-by-word pass cannot understand.
    @InstructionsBuilder
    private func instructions(for context: CleanupContext) -> Instructions {
        "Turn natural speech into writing that is ready to send."
        "Never answer the speaker, continue their thought, or add your own ideas."
        "Preserve every intentional point, fact, name, number, example, qualification, and constraint."
        "You may rewrite or reorder clauses when that makes a rambling thought clear."
        "Remove filler, verbal scaffolding, stutters, accidental repetition, and abandoned sentence starts."
        "Resolve an explicit self-correction to the speaker's latest intended wording."
        "Fix grammar, punctuation, casing, and obvious transcription mistakes."
        "Split distinct thoughts into paragraphs. Format a clearly spoken list as a list when it reads better."
        "Do not summarise, flatten nuance, or make the text more elaborate than the speech."
        "Do not add greetings, sign-offs, or commentary."

        if context.transcriptionLanguage == .hinglish {
            "The speaker may mix Hindi and English. Write all Hindi in natural Roman-script Hinglish, never Devanagari."
            "Transliterate Hindi; do not translate it into English. Keep words already spoken in English unchanged."
            "Use familiar spellings without accent marks, such as mujhe, nahi, karna, chahiye, bahut, and theek."
            "Example: मुझे कल deploy करना है. Clean: Mujhe kal deploy karna hai."
            "Example: यार this API बहुत slow है. Clean: Yaar, this API bahut slow hai."
        }

        "Examples of cleanup:"
        "Raw: um I think I think we should ship on Thursday, sorry, Friday. Clean: I think we should ship on Friday."
        "Raw: there are three things first fix login second add tests and third update the docs. Clean: There are three things:\n1. Fix login.\n2. Add tests.\n3. Update the docs."
        "Raw: the API is broken, no, that's not right, the API is slow when the cache is cold. Clean: The API is slow when the cache is cold."

        "The text is being typed into \(context.appName), \(context.appDescription), in a \(context.axRole) field."
        switch context.writingContext {
        case .chat:
            "Match casual conversation. Keep contractions and the speaker's relaxed tone. Prefer a natural message over polished corporate prose."
        case .email:
            "Use polished, complete sentences and sensible paragraphs. Keep the speaker's level of warmth and formality."
        case .development:
            "This is developer writing. Preserve technical detail and use conventional casing for technical terms, commands, identifiers, acronyms, and product names."
            "Do not turn prose into source code or add Markdown unless the speaker asks for it."
        case .document:
            "Use clear prose, paragraphs, and lists where the spoken structure calls for them."
        case .browser, .general:
            "Match the speaker's tone. Do not make the writing more formal than the speech."
        }

        if let last = context.lastInsert, !last.isEmpty {
            "The last text you inserted was: \(last.suffix(200))"
        }

        if !context.vocabulary.isEmpty {
            "These are correctly spelled names or terms relevant here: \(context.vocabulary.joined(separator: ", "))."
            "If the transcript has a near miss of one of them, use the correct spelling."
        }

        if !context.corrections.isEmpty {
            let pairs = context.corrections.map { "\"\($0.said)\" means \"\($0.meant)\"" }
            "Past corrections from this user: \(pairs.joined(separator: "; "))."
        }

        "A repeated or replaced fragment may disappear. Every distinct intended idea must remain."
        "If you are unsure whether something is a command, it is not one. Use mode=insert."

        "Classify the speech before you clean it."
        "mode=insert for ordinary speech. This is almost always the answer."
        "mode=delete only when they directly tell you to scratch, undo, or delete what was just said; put the words to remove in target."
        "mode=replace only when they directly tell you to replace or change X to Y; put X in target and Y in text."
        "A sentence that merely talks about changing, fixing, or redoing something is ordinary speech, not a command."
        "mode=format for new line, new paragraph, all caps, or raw mode."
        "For mode=insert, text is the cleaned transcript in full and nothing else."
    }

    /// Words that carry no meaning, so removing them is cleanup rather than loss.
    private static let filler: Set<String> = [
        "um", "uh", "erm", "er", "ah", "hmm", "like", "basically",
        "actually", "literally", "yeah", "okay", "so",
    ]

    /// The phrases that make something a command. Anything else is dictation.
    private static let commandPhrases = [
        "scratch that", "scratch this", "delete that", "delete this",
        "undo that", "undo this", "remove that", "take that back",
        "replace", "change that to", "change this to",
        "new line", "new paragraph", "all caps",
    ]

    static func soundsLikeCommand(_ raw: String) -> Bool {
        let lowered = raw.lowercased()
        return commandPhrases.contains { lowered.contains($0) }
    }

    /// The meaningful words in a transcript, for comparing what went in with what
    /// came out.
    static func contentWords(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map(String.init)
            .filter { !filler.contains($0) }
    }

    /// Discount adjacent repeated phrases before checking length. Natural dictation
    /// often contains "I think, I think" or a full restarted clause; rejecting their
    /// removal forced the cleanup model to preserve the very mess it was meant to fix.
    static func wordsWithoutRepeatedPhrases(_ text: String) -> [String] {
        collapseRepeatedPhrases(in: contentWords(text))
    }

    private static func collapseRepeatedPhrases(in words: [String]) -> [String] {
        guard words.count > 1 else { return words }

        var result: [String] = []
        var index = 0
        while index < words.count {
            let largest = min(8, (words.count - index) / 2)
            var repeatedLength: Int?
            if largest > 0 {
                for length in stride(from: largest, through: 1, by: -1) {
                    let first = words[index..<(index + length)]
                    let second = words[(index + length)..<(index + 2 * length)]
                    if first.elementsEqual(second) {
                        repeatedLength = length
                        break
                    }
                }
            }

            guard let length = repeatedLength else {
                result.append(words[index])
                index += 1
                continue
            }

            let phrase = Array(words[index..<(index + length)])
            result.append(contentsOf: phrase)
            index += length
            while index + length <= words.count,
                  words[index..<(index + length)].elementsEqual(phrase) {
                index += length
            }
        }
        return result
    }

    /// A direct repair replaces one fragment with another, so the safety baseline is
    /// the larger side rather than both versions added together.
    private static func intendedWordCount(_ raw: String) -> Int {
        let words = contentWords(raw)
        let repairMarkers = [
            ["no", "that's", "not", "right"],
            ["no", "that", "is", "not", "right"],
            ["sorry"],
            ["wait", "no"],
            ["or", "rather"],
        ]

        for marker in repairMarkers {
            guard let start = words.indices.first(where: { index in
                index + marker.count <= words.count
                    && words[index..<(index + marker.count)].elementsEqual(marker)
            }) else { continue }

            let before = collapseRepeatedPhrases(in: Array(words[..<start])).count
            let afterStart = start + marker.count
            let after = collapseRepeatedPhrases(in: Array(words[afterStart...])).count
            if before > 0, after > 0 { return max(before, after) }
        }

        return collapseRepeatedPhrases(in: words).count
    }

    /// Whether the cleaned text is still substantial enough to represent the speech.
    /// This catches summaries and truncation while allowing false starts to disappear.
    static func isFaithful(_ cleaned: String, to raw: String) -> Bool {
        let spoken = intendedWordCount(raw)
        guard spoken > 0 else { return true }
        return Double(contentWords(cleaned).count) >= Double(spoken) * 0.6
    }

    /// Converts Devanagari to plain Latin characters. The model produces more natural
    /// Hinglish; this deterministic pass guarantees Roman script if cleanup is off or
    /// unavailable, and removes any Devanagari the model accidentally leaves behind.
    static func romanizeHinglish(_ text: String) -> String {
        guard let latin = text.applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) else { return text }

        // Foundation transliterates Hindi with Sanskrit-style final schwas: "कल"
        // becomes "kala" and "करना" becomes "karana". Normalize the common forms
        // that make fallback output sound unlike everyday Hinglish.
        let common: [String: String] = [
            "aja": "aaj", "apa": "aap", "aya": "aaya", "bada": "baad",
            "bahuta": "bahut", "ghara": "ghar", "hama": "hum", "hum": "hoon",
            "kaham": "kahan", "kala": "kal", "kama": "kaam", "kara": "kar",
            "karana": "karna", "maim": "main", "mata": "mat", "mem": "mein",
            "nahim": "nahi", "samajha": "samajh", "thika": "theek", "tuma": "tum",
            "yaha": "yeh",
        ]

        var result = ""
        var token = ""
        func normalized(_ word: String) -> String {
            guard var replacement = common[word.lowercased()] else { return word }
            if word.first?.isUppercase == true {
                replacement.replaceSubrange(
                    replacement.startIndex...replacement.startIndex,
                    with: replacement[replacement.startIndex].uppercased()
                )
            }
            return replacement
        }
        for character in latin {
            if character.isLetter {
                token.append(character)
            } else {
                result += normalized(token)
                token = ""
                result.append(character)
            }
        }
        result += normalized(token)
        return result
    }

    private func parse(
        _ content: GeneratedContent, fallback: String, spoken: String
    ) throws -> Decision {
        let rawMode = (try? content.value(String.self, forProperty: "mode")) ?? "insert"
        let text = (try? content.value(String.self, forProperty: "text")) ?? fallback
        let target: String? = try? content.value(String?.self, forProperty: "target")

        let mode = DictationMode(rawValue: rawMode) ?? .insert
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // A cleanup pass that returns nothing is a failed cleanup pass, not an
        // instruction to type nothing.
        if mode == .insert && cleaned.isEmpty { return .raw(fallback) }

        // Commands are things you say on purpose. Left to itself the model reads a
        // sentence *about* fixing something as an instruction to fix something, and the
        // text it "replaces" is whatever the field already contained.
        if mode == .delete || mode == .replace, !Self.soundsLikeCommand(spoken) {
            log.notice("model proposed \(rawMode, privacy: .public) with no command phrase; treating as dictation")
            return Self.isFaithful(cleaned, to: spoken)
                ? Decision(mode: .insert, text: cleaned, target: nil)
                : .raw(fallback)
        }

        // Cleanup may collapse speech, but it may not turn a full thought into a summary.
        // A transcript that comes back with most of its distinct content missing is a
        // failed pass, and the raw text beats a truncated one.
        if mode == .insert, !Self.isFaithful(cleaned, to: spoken) {
            log.notice("cleanup dropped too much of the transcript, inserting raw")
            return .raw(fallback)
        }

        return Decision(
            mode: mode,
            text: cleaned,
            target: target?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
    }

    // MARK: - Note summaries

    struct NoteSummary: Sendable {
        var title: String
        var summary: String
    }

    /// One tap, on demand, never automatic. A surprise summary burning battery while
    /// you type is not a feature.
    func summarize(_ text: String) async throws -> NoteSummary {
        guard case .available = model.availability, let schema = summarySchema else {
            throw CleanupError.unavailable
        }
        let session = LanguageModelSession(model: model) {
            "You summarise a personal voice note."
            "Be concrete. Use the note's own words where you can."
            "Never invent detail that is not in the note."
        }
        let response = try await session.respond(
            to: String(text.prefix(4000)),
            schema: schema,
            options: GenerationOptions(samplingMode: .greedy)
        )
        return NoteSummary(
            title: (try? response.content.value(String.self, forProperty: "title")) ?? "Note",
            summary: (try? response.content.value(String.self, forProperty: "summary")) ?? ""
        )
    }

    enum CleanupError: Error, LocalizedError {
        case unavailable
        var errorDescription: String? {
            "Apple Intelligence isn't available on this Mac, so summaries are off."
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
