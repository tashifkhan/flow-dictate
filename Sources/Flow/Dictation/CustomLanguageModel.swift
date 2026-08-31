import Foundation
import OSLog
import Speech

/// Trains a custom language model from your vocabulary, so the recogniser has a
/// chance at names it has never heard.
///
/// This is the heavier of the plan's two custom-vocabulary fixes, and the one that is
/// only worth reaching for when contextual strings are not enough. It comes with a
/// real trade-off: a custom model can only be attached to `DictationTranscriber`, not
/// to `SpeechTranscriber`, so turning it on swaps the primary transcriber for the
/// fallback one. That is why it is opt-in rather than automatic.
actor CustomLanguageModel {
    private let log = Logger(subsystem: "sh.taf.flow", category: "customlm")

    /// Bumped whenever the vocabulary changes, so a stale model is never reused.
    private static let version = "1"

    enum TrainingError: Error, LocalizedError {
        case noVocabulary
        case prepareFailed(String)
        var errorDescription: String? {
            switch self {
            case .noVocabulary: "Add some custom words first; there is nothing to train on."
            case .prepareFailed(let m): "Training failed: \(m)"
            }
        }
    }

    private static func directory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("Flow/LanguageModel", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static func modelURL() throws -> URL {
        try directory().appendingPathComponent("flow.lm")
    }

    private static func vocabularyURL() throws -> URL {
        try directory().appendingPathComponent("flow.vocab")
    }

    /// The configuration to hand the transcriber, if a model has been trained.
    static func existingConfiguration() -> SFSpeechLanguageModel.Configuration? {
        guard let model = try? modelURL(), let vocabulary = try? vocabularyURL(),
              FileManager.default.fileExists(atPath: model.path)
        else { return nil }
        return SFSpeechLanguageModel.Configuration(languageModel: model, vocabulary: vocabulary)
    }

    static func hasTrainedModel() -> Bool { existingConfiguration() != nil }

    /// Throws away the trained model, so the app falls back to `SpeechTranscriber`.
    static func discard() {
        for url in [try? modelURL(), try? vocabularyURL()] {
            if let url { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// Builds training data from the lexicon and compiles it. Minutes, not seconds, on
    /// a large vocabulary, so it is a button rather than something that runs on save.
    func train(words: [String], corrections: [(said: String, meant: String)], locale: Locale) async throws {
        guard !words.isEmpty || !corrections.isEmpty else { throw TrainingError.noVocabulary }

        let data = SFCustomLanguageModelData(
            locale: locale,
            identifier: "sh.taf.flow",
            version: Self.version
        )

        // Weight each term so it beats the general model's prior for similar-sounding
        // ordinary words. Bare terms get less weight than terms in a sentence frame,
        // because dictation almost never consists of a lone proper noun.
        for word in words {
            data.insert(phraseCount: .init(phrase: word, count: 12))
            for frame in Self.frames(for: word) {
                data.insert(phraseCount: .init(phrase: frame, count: 4))
            }
        }

        // What you meant is what should win next time.
        for correction in corrections {
            data.insert(phraseCount: .init(phrase: correction.meant, count: 8))
        }

        let asset = try Self.directory().appendingPathComponent("training.bin")
        try await data.export(to: asset)
        defer { try? FileManager.default.removeItem(at: asset) }

        let configuration = SFSpeechLanguageModel.Configuration(
            languageModel: try Self.modelURL(),
            vocabulary: try Self.vocabularyURL()
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            SFSpeechLanguageModel.prepareCustomLanguageModel(for: asset, configuration: configuration) { error in
                if let error {
                    continuation.resume(throwing: TrainingError.prepareFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }

        log.info("trained custom model on \(words.count) words, \(corrections.count) corrections")
    }

    /// Ordinary sentence frames, so the term is learned in the positions speech puts it.
    private static func frames(for word: String) -> [String] {
        [
            "I told \(word) about it",
            "\(word) said that",
            "about \(word)",
            "with \(word)",
        ]
    }
}
