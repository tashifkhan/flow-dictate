import AppKit
import Foundation
import Observation
import OSLog

/// The panel's three states, plus the ones that only show up when something is wrong.
enum DictationPhase: Equatable, Sendable {
    case idle
    /// First run on a locale downloads transcriber assets. Progress is nil until known.
    case preparing(Double?)
    case recording
    case processing
    /// Briefly, right after the text lands.
    case inserted(String)
    /// No editable field had focus, so the text remains on the clipboard.
    case copied(String)
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .idle, .failed, .inserted, .copied: false
        case .preparing, .recording, .processing: true
        }
    }
}

/// Where a finished dictation goes.
enum DictationTarget: Equatable, Sendable {
    /// The cursor in whatever app has focus.
    case cursor
    /// A note open in Flow's own window.
    case note(UUID)
}

/// Hotkey down to text at the cursor: the whole loop lives here.
@MainActor @Observable
final class DictationController {
    let levels = AudioLevels()

    private(set) var phase: DictationPhase = .idle
    /// The live transcript, volatile tail included. Shown, never inserted.
    private(set) var transcript = ""
    private(set) var cleanupAvailability: CleanupAvailability = .unknown
    /// Which transcriber is actually in use, for the settings window.
    private(set) var transcriberLabel = "resolving…"
    private(set) var assetStatusLabel = "checking…"
    private(set) var isTraining = false
    private(set) var trainingError: String?
    private(set) var targetApp: FrontApp = .unknown

    /// Set by the note editor while it is frontmost, so in-note dictation stays in the note.
    var target: DictationTarget = .cursor

    private let pipeline = SpeechPipeline()
    private let cleanup = CleanupService()
    private let inserter = Inserter()
    private let library: Library
    private let lexicon: Lexicon
    private let log = Logger(subsystem: "sh.taf.flow", category: "dictation")

    private var startedAt: Date?
    private var run: Task<Void, Never>?
    /// Text produced when the target is a note rather than the cursor.
    var onNoteText: ((UUID, String) -> Void)?

    init(library: Library, lexicon: Lexicon) {
        self.library = library
        self.lexicon = lexicon
    }

    /// Resolve assets and warm the model at launch so the first dictation is not the
    /// slow one. Safe to call more than once.
    func warmUp() {
        let useCustom = Settings.shared.useCustomLanguageModel
        let language = Settings.shared.transcriptionLanguage
        Task { [pipeline, cleanup] in
            let availability = await cleanup.availability
            await MainActor.run {
                self.cleanupAvailability = availability
                if !availability.isAvailable { self.startAvailabilityPolling() }
            }
            await cleanup.prewarm()
            await pipeline.setUsesCustomModel(useCustom)
            await pipeline.setTranscriptionLanguage(language)
            do {
                try await pipeline.prepare { fraction in
                    Task { @MainActor in
                        if case .preparing = self.phase { self.phase = .preparing(fraction) }
                    }
                }
            } catch {
                await MainActor.run {
                    self.log.error("prepare failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            let label = await pipeline.kind.label
            let assets = await pipeline.assetStatusLabel()
            await MainActor.run {
                self.transcriberLabel = label
                self.assetStatusLabel = assets
            }
        }
    }


    /// Re-resolve the transcriber after the custom-model setting changes.
    func customModelSettingChanged() {
        let useCustom = Settings.shared.useCustomLanguageModel
        Task { [pipeline] in
            await pipeline.setUsesCustomModel(useCustom)
            _ = try? await pipeline.prepare()
            let label = await pipeline.kind.label
            await MainActor.run { self.transcriberLabel = label }
        }
    }

    /// Re-resolves speech assets when the user switches between the system language
    /// and the Hindi recognizer used for Roman-script Hinglish.
    func transcriptionLanguageChanged() {
        let language = Settings.shared.transcriptionLanguage
        Task { [pipeline] in
            await pipeline.setTranscriptionLanguage(language)
            do {
                _ = try await pipeline.prepare()
                let label = await pipeline.kind.label
                let assets = await pipeline.assetStatusLabel()
                await MainActor.run {
                    self.transcriberLabel = label
                    self.assetStatusLabel = assets
                }
            } catch {
                await MainActor.run {
                    self.assetStatusLabel = error.localizedDescription
                }
            }
        }
    }

    /// Trains a custom language model on the current vocabulary. Minutes, not seconds.
    func trainCustomModel() {
        guard !isTraining else { return }
        isTraining = true
        trainingError = nil

        let words = lexicon.words
        let corrections = lexicon.corrections.map { (said: $0.from, meant: $0.to) }

        Task { [pipeline] in
            defer { self.isTraining = false }
            do {
                let locale = try await pipeline.prepare()
                try await CustomLanguageModel().train(words: words, corrections: corrections, locale: locale)
                self.customModelSettingChanged()
            } catch {
                self.trainingError = error.localizedDescription
            }
        }
    }

    /// Throws the trained model away and goes back to `SpeechTranscriber`.
    func discardCustomModel() {
        CustomLanguageModel.discard()
        Settings.shared.useCustomLanguageModel = false
        customModelSettingChanged()
    }

    var hasTrainedModel: Bool { CustomLanguageModel.hasTrainedModel() }

    /// Availability is not observable and flips without warning — the model finishes
    /// preparing, or Apple Intelligence gets switched on. Poll while it is not ready so
    /// cleanup starts working on its own instead of needing a relaunch.
    private var availabilityPoll: Task<Void, Never>?

    private func startAvailabilityPolling() {
        availabilityPoll?.cancel()
        availabilityPoll = Task { [cleanup] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                let availability = await cleanup.availability
                await MainActor.run { self.cleanupAvailability = availability }
                if availability.isAvailable {
                    await cleanup.prewarm()
                    return
                }
            }
        }
    }

    func refreshCleanupAvailability() {
        Task { [cleanup] in
            let availability = await cleanup.availability
            await MainActor.run { self.cleanupAvailability = availability }
        }
    }

    // MARK: - The loop

    /// Hotkey down.
    func begin() {
        guard !phase.isBusy else { return }

        // Capture the target before anything else. The panel never takes focus, but
        // the answer should come from the moment you pressed the key.
        switch target {
        case .cursor: targetApp = FrontApp.current()
        case .note: targetApp = .flowNote
        }

        // Only typing into another app needs Accessibility. Dictating into a Flow note
        // never leaves the app, so it must not be gated on it.
        if case .cursor = target, !Permissions.hasAccessibility {
            fail(Inserter.InsertError.noAccessibility.localizedDescription)
            Permissions.requestAccessibility()
            return
        }
        if case .cursor = target, targetApp.isSecure {
            let reason = Inserter.InsertError.secureField.localizedDescription
            fail(reason)
            if Settings.shared.notifyOnInsert { Toast.blocked(reason) }
            return
        }

        transcript = ""
        levels.reset()
        startedAt = .now
        phase = .preparing(nil)

        // App-specific terms help the speech recognizer itself, before cleanup gets a
        // chance to repair words such as TypeScript, GraphQL, or Kubernetes.
        let vocabulary = Array(Set(lexicon.words + targetApp.recognitionHints)).sorted()
        // Read here, on the main actor; the pipeline runs off it.
        let inputDeviceUID = Settings.shared.inputDeviceUID
        run = Task { [pipeline, levels] in
            guard await AudioCapture.requestMicAccess() else {
                self.fail(AudioCapture.CaptureError.micDenied.localizedDescription)
                return
            }
            do {
                try await pipeline.start(
                    vocabulary: vocabulary,
                    inputDeviceUID: inputDeviceUID,
                    onLevel: { level in
                        Task { @MainActor in levels.push(level) }
                    },
                    onRecording: {
                        // The mic is live now, not when the model finishes loading.
                        Task { @MainActor in
                            if case .preparing = self.phase { self.phase = .recording }
                        }
                    },
                    onUpdate: { update in
                        Task { @MainActor in self.absorb(update) }
                    }
                )
                await MainActor.run {
                    // A release that beat the analyzer's start still ends the dictation.
                    if case .preparing = self.phase { self.phase = .recording }
                }
            } catch {
                self.fail(error.localizedDescription)
            }
        }
    }

    private func absorb(_ update: TranscriptionUpdate) {
        switch update {
        case .volatile(let text), .finalized(let text):
            transcript = text
        }
    }

    /// Hotkey up. Finalize, clean, insert, record.
    func end() {
        guard phase.isBusy else { return }
        let duration = startedAt.map { Date.now.timeIntervalSince($0) } ?? 0
        startedAt = nil
        phase = .processing

        let app = targetApp
        let destination = target
        let previous = run

        run = Task { [pipeline, cleanup, inserter, library, lexicon] in
            // Let start() finish before finalizing, or we finalize a dictation that
            // never began.
            _ = await previous?.result

            let raw: String
            do {
                raw = try await pipeline.finish()
            } catch {
                self.fail(error.localizedDescription)
                return
            }

            guard !raw.isEmpty else {
                // Distinguish "the mic gave us nothing" from "you did not say anything".
                await MainActor.run {
                    if self.levels.peak <= 0.001 {
                        self.fail("No sound reached the microphone. Check the input device in System Settings › Sound.")
                    } else {
                        self.phase = .idle
                    }
                }
                return
            }

            // In-note dictation skips cleanup's command handling: you are writing, not
            // driving another app.
            if case .note(let id) = destination {
                let decision = await self.cleanedDecision(raw: raw, app: app, cleanup: cleanup, lexicon: lexicon)
                await MainActor.run {
                    self.onNoteText?(id, decision.text)
                    self.finish(delivery: .init(text: decision.text, destination: .textField),
                                raw: raw, cleaned: decision.text,
                                app: app, duration: duration, library: library)
                }
                return
            }

            let decision = await self.cleanedDecision(raw: raw, app: app, cleanup: cleanup, lexicon: lexicon)

            do {
                let (delivery, insertionApp) = try await MainActor.run {
                    // Focus may have changed during recognition or cleanup. Decide
                    // whether to insert or copy using the field active now.
                    let current = FrontApp.current()
                    return (try inserter.apply(decision, in: current), current)
                }

                // A spoken correction is the best training signal there is.
                if decision.mode == .replace, let target = decision.target {
                    await MainActor.run { lexicon.record(from: target, to: decision.text) }
                }

                await MainActor.run {
                    self.finish(delivery: delivery, raw: raw, cleaned: decision.text,
                                app: insertionApp, duration: duration, library: library)
                }
            } catch {
                self.fail(error.localizedDescription)
            }
        }
    }

    private func cleanedDecision(
        raw: String, app: FrontApp, cleanup: CleanupService, lexicon: Lexicon
    ) async -> Decision {
        guard await MainActor.run(body: { Settings.shared.cleanupEnabled }) else {
            return .raw(raw)
        }
        let context = await MainActor.run {
            CleanupContext(
                appName: app.destinationName,
                bundleID: app.bundleID,
                axRole: app.axRole,
                appDescription: app.appDescription,
                writingContext: app.writingContext,
                transcriptionLanguage: Settings.shared.transcriptionLanguage,
                vocabulary: Array(Set(lexicon.matches(in: raw) + app.recognitionHints)).sorted(),
                corrections: lexicon.recent.map { (said: $0.from, meant: $0.to) },
                lastInsert: self.inserter.lastInsert
            )
        }
        return await cleanup.clean(raw, context: context)
    }

    private func finish(
        delivery: Inserter.Result, raw: String, cleaned: String,
        app: FrontApp, duration: TimeInterval, library: Library
    ) {
        library.add(DictationRecord(
            raw: raw,
            cleaned: cleaned == raw ? "" : cleaned,
            appBundleID: app.bundleID,
            appName: app.name,
            duration: duration
        ))
        transcript = delivery.text
        switch delivery.destination {
        case .textField: phase = .inserted(delivery.text)
        case .clipboard: phase = .copied(delivery.text)
        }
        if Settings.shared.playSounds { NSSound(named: "Tink")?.play() }
        if Settings.shared.notifyOnInsert {
            switch delivery.destination {
            case .textField: Toast.inserted(delivery.text, into: app.name)
            case .clipboard: Toast.copied(delivery.text)
            }
        }
        dismissAfterBeat()
    }

    /// Escape, or a dictation you thought better of.
    func cancel() {
        run?.cancel()
        run = nil
        startedAt = nil
        Task { [pipeline] in
            await pipeline.cancel()
            await MainActor.run {
                self.transcript = ""
                self.levels.reset()
                self.phase = .idle
            }
        }
    }

    /// Re-insert a history entry at the cursor.
    func reinsert(_ text: String) {
        do {
            let delivery = try inserter.reinsert(text)
            switch delivery.destination {
            case .textField: phase = .inserted(text)
            case .clipboard: phase = .copied(text)
            }
            dismissAfterBeat()
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func fail(_ message: String) {
        log.error("\(message, privacy: .public)")
        Task { [pipeline] in await pipeline.cancel() }
        transcript = ""
        levels.reset()
        phase = .failed(message)
        // Errors linger longer than successes; you have to be able to read them.
        Task {
            try? await Task.sleep(for: .seconds(4))
            if case .failed = self.phase { self.phase = .idle }
        }
    }

    /// The panel collapses the moment insertion finishes. Under 600ms, nobody notices.
    private func dismissAfterBeat() {
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            if case .inserted = self.phase {
                self.phase = .idle
                self.transcript = ""
                self.levels.reset()
            } else if case .copied = self.phase {
                self.phase = .idle
                self.transcript = ""
                self.levels.reset()
            }
        }
    }
}
