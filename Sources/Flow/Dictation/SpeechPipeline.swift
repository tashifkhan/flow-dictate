import AVFoundation
import Foundation
import OSLog
import Speech

/// What the panel gets while you talk.
enum TranscriptionUpdate: Sendable {
    /// The moving tail. Still changing, safe to show, never to insert.
    case volatile(String)
    /// Locked in. Appended to the running transcript.
    case finalized(String)
}

/// Which on-device transcriber we ended up with.
enum TranscriberKind: Sendable {
    /// `SpeechTranscriber`, the model family behind Notes and Voice Memos.
    case speech
    /// `DictationTranscriber`, same analyzer, wider device and locale coverage.
    case dictation
    /// `DictationTranscriber` with a trained custom language model attached.
    case customized

    var label: String {
        switch self {
        case .speech: "SpeechTranscriber"
        case .dictation: "DictationTranscriber"
        case .customized: "DictationTranscriber + custom model"
        }
    }
}

/// Speech to text: locale resolution, asset install, analyzer lifecycle, and the mic.
///
/// The analyzer is built per dictation but the *assets* are resolved once and cached,
/// so the second dictation onward starts warm.
actor SpeechPipeline {
    private let log = Logger(subsystem: "sh.taf.flow", category: "speech")

    private var capture: AudioCapture?
    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?

    private var finalizedText = ""
    private var volatileText = ""

    /// Resolved once, reused after that.
    private var resolvedLocale: Locale?
    private(set) var kind: TranscriberKind = .speech
    private var transcriptionLanguage: TranscriptionLanguage = .system

    enum PipelineError: Error, LocalizedError {
        case noLocale
        case noAudioFormat
        case notRunning
        var errorDescription: String? {
            switch self {
            case .noLocale: "No on-device transcription model covers your language."
            case .noAudioFormat: "Couldn't find an audio format the transcriber accepts."
            case .notRunning: "No dictation is running."
            }
        }
    }

    // MARK: - Preparation

    /// Resolves the locale and installs assets if this is a first run. Network is
    /// needed exactly once, here, never at dictation time.
    @discardableResult
    func prepare(progress: (@Sendable (Double) -> Void)? = nil) async throws -> Locale {
        if let resolvedLocale { return resolvedLocale }

        let locale: Locale
        let requestedLocale = transcriptionLanguage.locale
        // A custom language model only attaches to DictationTranscriber, so opting in
        // means giving up the better transcriber. The setting says so.
        if transcriptionLanguage == .system,
           useCustomModel, CustomLanguageModel.hasTrainedModel(),
           let supported = await DictationTranscriber.supportedLocale(equivalentTo: requestedLocale) {
            locale = supported
            kind = .customized
        } else if SpeechTranscriber.isAvailable,
           let supported = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) {
            locale = supported
            kind = .speech
        } else if let supported = await DictationTranscriber.supportedLocale(equivalentTo: requestedLocale) {
            locale = supported
            kind = .dictation
        } else {
            throw PipelineError.noLocale
        }

        let probe = makeModule(locale: locale)
        if await AssetInventory.status(forModules: [probe]) != .installed {
            // Reserving is what lets the assets stay on disk for us.
            _ = try? await AssetInventory.reserve(locale: locale)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
                let observation = progress.map { report in
                    request.progress.observe(\.fractionCompleted, options: [.initial, .new]) { p, _ in
                        report(p.fractionCompleted)
                    }
                }
                defer { observation?.invalidate() }
                log.info("installing speech assets for \(locale.identifier, privacy: .public)")
                try await request.downloadAndInstall()
            }
        }

        resolvedLocale = locale
        log.info("locale \(locale.identifier, privacy: .public), kind \(String(describing: self.kind), privacy: .public)")
        return locale
    }

    /// Are the assets on disk right now? Returned as a string because
    /// `AssetInventory.Status` is not Sendable and this crosses to the main actor.
    func assetStatusLabel() async -> String {
        guard let locale = resolvedLocale else { return "Not resolved yet" }
        switch await AssetInventory.status(forModules: [makeModule(locale: locale)]) {
        case .installed: return "Installed"
        case .downloading: return "Downloading"
        case .supported: return "Not downloaded yet"
        case .unsupported: return "Unsupported locale"
        @unknown default: return "Unknown"
        }
    }

    private func makeModule(locale: Locale) -> any SpeechModule {
        switch kind {
        case .speech:
            // Progressive gives volatile results, which is what makes it feel live.
            return SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        case .dictation:
            return DictationTranscriber(locale: locale, preset: .progressiveShortDictation)
        case .customized:
            guard let configuration = CustomLanguageModel.existingConfiguration() else {
                // The model was deleted out from under us; degrade rather than fail.
                kind = .dictation
                return DictationTranscriber(locale: locale, preset: .progressiveShortDictation)
            }
            return DictationTranscriber(
                locale: locale,
                contentHints: [.customizedLanguage(modelConfiguration: configuration)],
                transcriptionOptions: [],
                reportingOptions: [.volatileResults],
                attributeOptions: []
            )
        }
    }

    /// Read from settings on the main actor and handed in, so this actor stays isolated.
    private var useCustomModel = false

    /// Called before `prepare()` when the setting changes, and at launch.
    func setUsesCustomModel(_ enabled: Bool) {
        guard enabled != useCustomModel else { return }
        useCustomModel = enabled
        // Force locale and module re-resolution on the next dictation.
        resolvedLocale = nil
    }

    func setTranscriptionLanguage(_ language: TranscriptionLanguage) {
        guard language != transcriptionLanguage else { return }
        transcriptionLanguage = language
        resolvedLocale = nil
    }

    // MARK: - Run

    /// Starts the mic and the analyzer. `vocabulary` is fed to the recogniser as
    /// contextual strings, which is the cheapest way to make it spell your name right.
    func start(
        vocabulary: [String],
        inputDeviceUID: String,
        onLevel: @escaping @Sendable (Float) -> Void,
        onRecording: @escaping @Sendable () -> Void,
        onUpdate: @escaping @Sendable (TranscriptionUpdate) -> Void
    ) async throws {
        finalizedText = ""
        volatileText = ""

        // 1. Microphone first, before anything that can block. Everything below this
        //    line runs while audio is already being captured and buffered.
        let capture = AudioCapture(onLevel: onLevel)
        self.capture = capture
        try capture.startCapturing(preferredInputUID: inputDeviceUID)
        onRecording()

        do {
            // 2. Now the slow part: locale resolution, and asset install the first time.
            let locale = try await prepare()
            let module = makeModule(locale: locale)

            let context = AnalysisContext()
            if !vocabulary.isEmpty {
                context.contextualStrings = [.general: vocabulary]
            }

            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
                throw PipelineError.noAudioFormat
            }

            // 3. Attach. The backlog replays first, so nothing said during step 2 is lost.
            let inputs = try capture.attach(analyzerFormat: format)

            let analyzer = SpeechAnalyzer(modules: [module])
            self.analyzer = analyzer
            try await analyzer.setContext(context)
            try await analyzer.start(inputSequence: inputs)

            resultsTask = makeResultsTask(for: module, onUpdate: onUpdate)
        } catch {
            // The mic is already open at this point; do not leave it that way.
            capture.stop()
            self.capture = nil
            throw error
        }
    }

    /// Bridges the module's typed result stream into `TranscriptionUpdate`.
    private func makeResultsTask(
        for module: any SpeechModule,
        onUpdate: @escaping @Sendable (TranscriptionUpdate) -> Void
    ) -> Task<Void, Never> {
        Task { [weak self] in
            do {
                if let t = module as? SpeechTranscriber {
                    for try await result in t.results {
                        await self?.absorb(String(result.text.characters), isFinal: result.isFinal, onUpdate: onUpdate)
                    }
                } else if let d = module as? DictationTranscriber {
                    for try await result in d.results {
                        await self?.absorb(String(result.text.characters), isFinal: result.isFinal, onUpdate: onUpdate)
                    }
                }
            } catch is CancellationError {
                // Expected on stop.
            } catch {
                await self?.logResultsFailure(error)
            }
        }
    }

    private func logResultsFailure(_ error: any Error) {
        log.error("results stream ended: \(error.localizedDescription, privacy: .public)")
    }

    /// Finalized text accumulates; volatile text is only ever the tail.
    private func absorb(
        _ text: String,
        isFinal: Bool,
        onUpdate: @escaping @Sendable (TranscriptionUpdate) -> Void
    ) {
        if isFinal {
            finalizedText += text
            volatileText = ""
            onUpdate(.finalized(finalizedText))
        } else {
            volatileText = text
            onUpdate(.volatile(finalizedText + text))
        }
    }

    /// The live transcript, finalized plus whatever tail is still moving.
    var currentTranscript: String {
        (finalizedText + volatileText).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Stops the mic, drains the analyzer, and returns the finished transcript.
    func finish() async throws -> String {
        // A short dictation can end before the model has finished loading. Stopping the
        // capture now would throw away the backlog it is holding, so give `start` a
        // moment to reach `attach` — actor reentrancy is what lets it make progress
        // while this waits. The mic stays open a beat longer, which costs a little tail
        // audio and saves the whole utterance.
        if analyzer == nil, capture != nil {
            for _ in 0..<40 where analyzer == nil {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }

        capture?.stop()
        capture = nil

        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }

        // Never await the results task.
        //
        // `finalizeAndFinishThroughEndOfInput()` returning means every result has
        // already been delivered. But when the analyzer received no audio at all, the
        // transcriber's `results` sequence stays open forever and does not honour
        // cancellation, so awaiting it — even racing it against a timeout in a task
        // group, which cannot return until every child finishes — wedges the app in
        // "Cleaning up…" until you quit it.
        //
        // Cancel it and yield instead: the sleep is what lets any queued `absorb` hop
        // land on this actor before we read the transcript.
        resultsTask?.cancel()
        resultsTask = nil
        try? await Task.sleep(for: .milliseconds(50))
        analyzer = nil

        let text = (finalizedText + volatileText).trimmingCharacters(in: .whitespacesAndNewlines)
        finalizedText = ""
        volatileText = ""
        return text
    }

    /// Bail out without inserting anything.
    func cancel() async {
        capture?.stop()
        capture = nil
        resultsTask?.cancel()
        resultsTask = nil
        if let analyzer { await analyzer.cancelAndFinishNow() }
        analyzer = nil
        finalizedText = ""
        volatileText = ""
    }
}
