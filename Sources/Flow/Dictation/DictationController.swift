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
    /// A microphone test finished. Nothing was inserted or saved.
    case tested(String)
    /// A spoken list command, such as "start a numbered list", changed list state only.
    case listUpdated
    /// The paste went out but the field showed no sign of it, so the text is also on
    /// the clipboard.
    case unconfirmed(String)
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .idle, .failed, .inserted, .copied, .tested, .listUpdated, .unconfirmed: false
        case .preparing, .recording, .processing: true
        }
    }

    /// States the user should look at before carrying on.
    var needsAttention: Bool {
        switch self {
        case .failed, .unconfirmed: true
        default: false
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

    private(set) var phase: DictationPhase = .idle {
        didSet {
            if phase == .recording {
                if recordingStartedAt == nil {
                    recordingStartedAt = .now
                    watchRecordingLimit()
                }
            } else {
                if recordingStartedAt != nil { recordingStartedAt = nil }
                if phase == .idle, limitNotice != nil { limitNotice = nil }
            }
        }
    }
    /// When the microphone went live, for the panel's clock. Nil outside recording.
    private(set) var recordingStartedAt: Date?
    /// The input this dictation records from, for the microphone settings pane.
    private(set) var recordingInputName: String?
    /// "Recording limit in 0:30", or why the recording stopped on its own.
    private(set) var limitNotice: String?
    /// "Continuing at item 3" while a spoken list is still open where you are dictating.
    private(set) var listHint: String?
    /// True from the start of a microphone test until its result is shown.
    private(set) var isTesting = false
    /// What the last microphone test heard, for the settings pane.
    private(set) var lastTestTranscript: String?
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
    @ObservationIgnored private var limitTask: Task<Void, Never>?
    /// Open spoken lists, per place. Forgotten after 15 minutes.
    @ObservationIgnored private var continuations = DictationContinuationMemory<String>()
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
        isTesting = false
        startDictation()
    }

    /// Records from the chosen microphone and shows what Flow heard, without inserting
    /// or saving anything.
    func beginTest() {
        guard !phase.isBusy else { return }
        isTesting = true
        startDictation()
    }

    private func startDictation() {
        // Capture the target before anything else. The panel never takes focus, but
        // the answer should come from the moment you pressed the key.
        if isTesting {
            targetApp = .flowNote
        } else {
            switch target {
            case .cursor: targetApp = FrontApp.current()
            case .note: targetApp = .flowNote
            }
        }

        // Only typing into another app needs Accessibility. Dictating into a Flow note
        // or a microphone test never leaves the app, so it must not be gated on it.
        if !isTesting, case .cursor = target, !Permissions.hasAccessibility {
            fail(Inserter.InsertError.noAccessibility.localizedDescription)
            Permissions.requestAccessibility()
            return
        }
        if !isTesting, case .cursor = target, targetApp.isSecure {
            let reason = Inserter.InsertError.secureField.localizedDescription
            fail(reason)
            if Settings.shared.notifyOnInsert { Toast.blocked(reason) }
            return
        }

        let devices = AudioDevices.snapshot()
        let resolution = MicrophoneSelectionPolicy.resolve(
            preferences: Settings.shared.microphones,
            available: devices.inputs.map(\.saved),
            systemDefaultUID: devices.systemDefaultUID
        )
        guard let input = resolution.device else {
            fail("No microphone is available. Connect an input and try again.")
            return
        }
        recordingInputName = input.name
        limitNotice = nil

        let anchor = Self.continuationAnchor(isTesting ? nil : target, app: targetApp)
        if let list = continuations.continuation(for: anchor, now: Self.uptime)?.list {
            listHint = list.style == .numbered ? "Continuing at item \(list.nextNumber)" : "Continuing your list"
        } else {
            listHint = nil
        }

        transcript = ""
        levels.reset()
        startedAt = .now
        phase = .preparing(nil)

        // App-specific terms help the speech recognizer itself, before cleanup gets a
        // chance to repair words such as TypeScript, GraphQL, or Kubernetes.
        let vocabulary = Array(Set(lexicon.words + targetApp.recognitionHints)).sorted()
        // Resolved above, on the main actor; the pipeline runs off it.
        let inputDeviceUID = input.uid
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

    /// Hotkey up. Finalize, format lists, clean, insert, record.
    func end() {
        // Processing counts as busy too. A recording the limit already stopped must not
        // be finished a second time when the key comes up.
        guard phase.isBusy, phase != .processing else { return }
        let duration = startedAt.map { Date.now.timeIntervalSince($0) } ?? 0
        startedAt = nil
        phase = .processing

        let app = targetApp
        // Nil means a microphone test: shown, never delivered.
        let destination: DictationTarget? = isTesting ? nil : target
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
                if self.levels.peak <= 0.001 {
                    self.fail("No sound reached the microphone. Check the input in Flow's Microphone settings.")
                } else {
                    self.isTesting = false
                    self.phase = .idle
                }
                return
            }

            // Spoken lists first, on the raw words. Cleanup could rewrite "two, bananas"
            // into prose before the formatter ever saw the markers.
            let anchor = Self.continuationAnchor(destination, app: app)
            let openList = self.continuations.continuation(for: anchor, now: Self.uptime)
            let formatted = SpokenListFormatter.format(raw, context: openList?.list)
            let spokenList = formatted.containsList || formatted.isControlOnly
                || formatted.endedList || formatted.context != nil

            var composed: ComposedDictation?
            var decision: Decision
            if spokenList {
                let result = DictationComposer.compose(formatted, previous: openList)
                guard !result.insertion.isEmpty else {
                    // "Start a numbered list" on its own: nothing to type, only state.
                    self.continuations.remember(Self.worthKeeping(result.continuation), for: anchor, now: Self.uptime)
                    self.transcript = ""
                    self.isTesting = false
                    self.phase = formatted.isControlOnly ? .listUpdated : .idle
                    if formatted.isControlOnly { self.dismissAfterBeat() }
                    return
                }
                composed = result
                decision = .raw(result.insertion)
            } else {
                decision = await self.cleanedDecision(raw: raw, app: app, cleanup: cleanup, lexicon: lexicon)
                // Prose right after "end list" still starts its own paragraph.
                if let openList, decision.mode == .insert || decision.mode == .format {
                    let result = DictationComposer.compose(formatted.replacingText(decision.text), previous: openList)
                    composed = result
                    decision.text = result.insertion
                }
            }

            guard let destination else {
                let text = decision.text.trimmingCharacters(in: .whitespacesAndNewlines)
                self.continuations.remember(Self.worthKeeping(composed?.continuation), for: anchor, now: Self.uptime)
                self.lastTestTranscript = text
                self.transcript = text
                self.isTesting = false
                self.phase = .tested(text)
                self.dismissAfterBeat(.seconds(2))
                return
            }

            // In-note dictation skips insertion entirely: you are writing, not driving
            // another app.
            if case .note(let id) = destination {
                self.onNoteText?(id, decision.text)
                self.continuations.remember(Self.worthKeeping(composed?.continuation), for: anchor, now: Self.uptime)
                self.finish(delivery: .init(text: decision.text, destination: .textField), confirmed: true,
                            raw: raw, cleaned: decision.text, app: app, duration: duration, library: library)
                return
            }

            do {
                // Let the hotkey's modifiers come up, so a keystroke paste is plain ⌘V.
                await inserter.waitForModifierRelease()
                // Focus may have changed during recognition or cleanup. Decide whether
                // to insert or copy using the field active now.
                let current = FrontApp.current()
                let checkable = decision.mode == .insert || decision.mode == .format
                let caret = checkable ? inserter.caretSnapshot(for: current) : nil
                let delivery = try inserter.apply(decision, in: current)

                // A spoken correction is the best training signal there is.
                if decision.mode == .replace, let target = decision.target {
                    lexicon.record(from: target, to: decision.text)
                }

                var confirmed = true
                if delivery.destination == .textField, let caret {
                    confirmed = await inserter.confirmInsertion(since: caret)
                    if !confirmed {
                        inserter.keepOnClipboard(decision.text.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }

                // A list only continues where its last item verifiably landed.
                let landedAt = Self.continuationAnchor(destination, app: current)
                if confirmed, delivery.destination == .textField {
                    self.continuations.remember(Self.worthKeeping(composed?.continuation), for: landedAt, now: Self.uptime)
                } else {
                    self.continuations.forget(landedAt)
                }
                if landedAt != anchor { self.continuations.forget(anchor) }

                self.finish(delivery: delivery, confirmed: confirmed, raw: raw, cleaned: decision.text,
                            app: current, duration: duration, library: library)
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
        delivery: Inserter.Result, confirmed: Bool, raw: String, cleaned: String,
        app: FrontApp, duration: TimeInterval, library: Library
    ) {
        let cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        library.add(DictationRecord(
            raw: raw,
            cleaned: cleaned == raw ? "" : cleaned,
            appBundleID: app.bundleID,
            appName: app.name,
            duration: duration
        ))
        let shown = delivery.text.trimmingCharacters(in: .whitespacesAndNewlines)
        transcript = shown
        switch delivery.destination {
        case .textField: phase = confirmed ? .inserted(shown) : .unconfirmed(shown)
        case .clipboard: phase = .copied(shown)
        }
        if Settings.shared.playSounds { NSSound(named: confirmed ? "Tink" : "Funk")?.play() }
        if Settings.shared.notifyOnInsert {
            switch delivery.destination {
            case .textField: Toast.inserted(shown, into: app.name)
            case .clipboard: Toast.copied(shown)
            }
        }
        // "Check insertion" has to stay up long enough to read.
        dismissAfterBeat(confirmed ? .milliseconds(700) : .seconds(3))
    }

    /// Escape, or a dictation you thought better of.
    func cancel() {
        run?.cancel()
        run = nil
        startedAt = nil
        limitTask?.cancel()
        isTesting = false
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
        limitTask?.cancel()
        isTesting = false
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
    private func dismissAfterBeat(_ delay: Duration = .milliseconds(700)) {
        Task {
            try? await Task.sleep(for: delay)
            switch self.phase {
            case .inserted, .copied, .tested, .listUpdated, .unconfirmed:
                self.phase = .idle
                self.transcript = ""
                self.levels.reset()
            case .idle, .preparing, .recording, .processing, .failed:
                break
            }
        }
    }

    // MARK: - Recording limit

    /// Counts down the last 30 seconds, then stops the recording as if the key came up.
    private func watchRecordingLimit() {
        limitTask?.cancel()
        let limit = Settings.shared.recordingLimit
        guard limit != .off else { return }
        limitTask = Task { [weak self] in
            let started = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.phase == .recording else { return }
                let remaining = limit.rawValue - Int((ContinuousClock.now - started).components.seconds)
                if remaining <= 0 {
                    self.limitNotice = "Stopped at the \(limit.noticeName) limit"
                    self.end()
                    return
                }
                let notice = remaining <= 30 ? "Recording limit in \(hudDuration(TimeInterval(remaining)))" : nil
                if notice != self.limitNotice { self.limitNotice = notice }
            }
        }
    }

    // MARK: - List continuation

    private static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Lists continue per place: the microphone test, one Flow note, or one kind of field
    /// in one app. Flow never reads the document itself.
    private static func continuationAnchor(_ destination: DictationTarget?, app: FrontApp) -> String {
        switch destination {
        case nil: "test"
        case .note(let id)?: "note:\(id.uuidString)"
        case .cursor?: "app:\(app.bundleID):\(app.axRole)"
        }
    }

    /// Plain prose leaves nothing to continue. Keeping it would add a trailing space to
    /// every ordinary dictation that followed.
    private static func worthKeeping(_ continuation: DictationContinuation?) -> DictationContinuation? {
        guard let continuation, continuation.list != nil || continuation.boundary != .none else { return nil }
        return continuation
    }
}
