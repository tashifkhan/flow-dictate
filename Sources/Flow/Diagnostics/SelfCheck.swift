import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

/// Verification for the parts that do not need a microphone or a person.
///
/// This lives in the app rather than a test target on purpose: `swift test` needs the
/// XCTest or swift-testing runtime, and neither ships with the Command Line Tools that
/// build this project. Run it with `Flow --self-check`; it exits non-zero on failure,
/// so CI can use it as-is.
enum SelfCheck {
    /// Opt-in integration check in a disposable local text view, never a chat composer.
    /// Launch with `open -n Flow.app --args --check-insertion /tmp/result.json`.
    @MainActor
    static func checkInsertion(output: String) async {
        let previousApp = NSWorkspace.shared.frontmostApplication
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 500, height: 180),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Flow insertion check"
        window.isReleasedWhenClosed = false
        let view = NSTextView(frame: window.contentView!.bounds)
        view.isRichText = false
        window.contentView = view
        // This window is outside SwiftUI's scene hierarchy, so give it a standard
        // responder-chain Paste menu item for Command-V.
        let menu = NSMenu()
        let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        edit.submenu = NSMenu(title: "Edit")
        edit.submenu?.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(edit)
        NSApp.mainMenu = menu
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(view)
        let monitor = HotkeyMonitor()
        var report: [String: Any] = ["accessibility": Permissions.hasAccessibility]
        do {
            try monitor.start()
            try await Task.sleep(for: .milliseconds(300))
            NSApp.mainMenu = menu
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
            report["focusedPID"] = NSWorkspace.shared.frontmostApplication?.processIdentifier
            report["checkPID"] = ProcessInfo.processInfo.processIdentifier
            let target = FrontApp.current()
            report["targetBundleID"] = target.bundleID
            report["role"] = target.axRole
            report["hasTextTarget"] = target.hasTextTarget
            // Force the paste path while retaining the actual focus classification.
            var pasteTarget = target
            pasteTarget.isElectron = true
            guard target.bundleID == Bundle.main.bundleIdentifier, target.hasTextTarget else {
                throw Inserter.InsertError.empty
            }
            let expected = "Flow insertion check"
            let result = try Inserter().apply(.raw(expected), in: pasteTarget)
            try await Task.sleep(for: .seconds(1))
            report["insertedLength"] = view.string.count
            let inserted = view.string == expected
            report["insertedInTextField"] = inserted
            report["destination"] = String(describing: result.destination)
            let snapshot = ClipboardSnapshot(NSPasteboard.general)
            defer { snapshot.restore(to: NSPasteboard.general) }
            let copied = try Inserter().apply(.raw("Flow clipboard check"), in: .unknown)
            let clipboardOK: Bool
            if case .clipboard = copied.destination {
                clipboardOK = NSPasteboard.general.string(forType: .string) == "Flow clipboard check"
            } else {
                clipboardOK = false
            }
            report["copiedWithoutTextField"] = clipboardOK
            report["passed"] = inserted && clipboardOK
        } catch {
            report["passed"] = false
            report["error"] = error.localizedDescription
        }
        monitor.stop()
        window.close()
        previousApp?.activate()
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: output), options: .atomic)
        }
        NSApp.terminate(nil)
    }

    @MainActor
    static func run() -> Never {
        var failures = 0
        var checks = 0

        func expect(_ condition: @autoclosure () throws -> Bool, _ label: String) {
            checks += 1
            do {
                if try condition() {
                    print("  ok    \(label)")
                } else {
                    failures += 1
                    print("  FAIL  \(label)")
                }
            } catch {
                failures += 1
                print("  FAIL  \(label) — threw \(error)")
            }
        }

        func section(_ name: String) { print("\n\(name)") }

        // MARK: History store

        section("history store")
        do {
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("flow-selfcheck-\(UUID().uuidString).sqlite")
            defer { try? FileManager.default.removeItem(at: url) }
            let store = try SQLiteStore(url: url)

            let record = DictationRecord(
                raw: "um so i think we should ship it",
                cleaned: "I think we should ship it.",
                appBundleID: "com.tinyspeck.slackmacgap",
                appName: "Slack",
                duration: 2.5,
                tags: ["work", "ship"]
            )
            try store.insert(record)

            let rows = try store.dictations(matching: nil, limit: nil)
            expect(rows.count == 1, "a dictation round-trips")
            expect(rows.first?.id == record.id, "the id survives")
            expect(rows.first?.raw == record.raw, "the raw transcript is kept")
            expect(rows.first?.tags == ["work", "ship"], "tags survive")
            expect(rows.first?.wasCleaned == true, "cleanup is detected")

            try store.insert(DictationRecord(raw: "lunch at one", cleaned: "Lunch at one.",
                                             appBundleID: "", appName: "Notes", duration: 1))
            expect(try store.dictations(matching: "ship", limit: nil).count == 1,
                   "search matches the raw transcript")
            expect(try store.dictations(matching: "lunch", limit: nil).count == 1,
                   "search matches the cleaned text")
            expect(try store.dictations(matching: "nonsense", limit: nil).isEmpty,
                   "search misses cleanly")
            expect(try store.dictations(matching: nil, limit: 1).count == 1, "limit applies")

            // Retention: pinned rows survive, stale ones do not.
            let old = Date.now.addingTimeInterval(-100 * 86_400)
            try store.insert(DictationRecord(raw: "keep me", cleaned: "", appBundleID: "",
                                             appName: "Notes", createdAt: old, duration: 1, pinned: true))
            try store.insert(DictationRecord(raw: "forget me", cleaned: "", appBundleID: "",
                                             appName: "Notes", createdAt: old, duration: 1))
            try store.purgeDictations(before: Retention.ninetyDays.cutoff!)
            let survivors = try store.dictations(matching: nil, limit: nil).map(\.raw)
            expect(survivors.contains("keep me"), "pinned rows survive the retention sweep")
            expect(!survivors.contains("forget me"), "stale rows are purged")

            try store.setPinned(dictation: record.id, true)
            expect(try store.dictations(matching: nil, limit: nil).first?.raw == record.raw,
                   "pinned rows sort first")

            try store.delete(dictation: record.id)
            expect(try !store.dictations(matching: nil, limit: nil).contains { $0.id == record.id },
                   "deleting removes the row")

            // Notes
            var note = NoteRecord(text: "Shower thought\nSomething about caching.")
            try store.upsert(note)
            note.text = "Shower thought\nSomething about caching, revised."
            note.summary = "A caching idea."
            try store.upsert(note)
            let notes = try store.notes(matching: nil)
            expect(notes.count == 1, "notes upsert rather than duplicate")
            expect(notes.first?.summary == "A caching idea.", "a summary persists")
            expect(try store.notes(matching: "caching").count == 1, "notes are searchable")
        } catch {
            failures += 1
            print("  FAIL  store threw: \(error)")
        }

        // MARK: Records

        section("records")
        let note = NoteRecord(text: "Ship the panel first\nThen the window.")
        expect(note.displayTitle == "Ship the panel first", "note title comes from the first line")
        expect(note.body == "Then the window.", "note body is everything after it")
        expect(NoteRecord().displayTitle == "New note", "an empty note still has a title")
        expect(NoteRecord(title: "Caching", text: "Shower thought").displayTitle == "Caching",
               "an explicit title wins")

        let uncleaned = DictationRecord(raw: "um hello", cleaned: "",
                                        appBundleID: "", appName: "x", duration: 0)
        expect(uncleaned.inserted == "um hello", "no cleanup falls back to the raw transcript")
        expect(!uncleaned.wasCleaned, "and reports itself as uncleaned")

        expect(Retention.forever.cutoff == nil, "forever has no cutoff")
        expect(Retention.thirtyDays.cutoff.map { $0 < .now } == true, "30 days cuts off in the past")

        // MARK: Cleanup faithfulness

        section("cleanup guards")
        do {
            let spoken = "How are we doing this? This is not correct. We cannot do this like this."

            expect(!CleanupService.soundsLikeCommand(spoken),
                   "a sentence about fixing something is not a command")
            expect(CleanupService.soundsLikeCommand("scratch that"),
                   "but scratch that is")
            expect(CleanupService.soundsLikeCommand("replace Tashif with Taf"),
                   "and so is an explicit replace")

            expect(!CleanupService.isFaithful("We cannot do this like this", to: spoken),
                   "dropping two thirds of a sentence is not cleanup")
            expect(CleanupService.isFaithful(
                       "How are we doing this? This is not correct. We cannot do this like this.",
                       to: spoken),
                   "punctuating the whole thing is")
            expect(CleanupService.isFaithful("I think we should ship it.",
                                             to: "um so i think we should uh ship it"),
                   "and stripping filler still counts as faithful")
            expect(CleanupService.isFaithful(
                       "I think we should ship on Friday.",
                       to: "I think I think I think we should ship on Friday"),
                   "collapsing a repeated phrase still counts as faithful")
            expect(CleanupService.wordsWithoutRepeatedPhrases(
                       "we should deploy we should deploy we should deploy today"
                   ) == ["we", "should", "deploy", "today"],
                   "repeated clauses count once in the cleanup guard")
            expect(CleanupService.isFaithful(
                       "The API is slow when the cache is cold.",
                       to: "the API is broken no that is not right the API is slow when the cache is cold"),
                   "an explicit correction may replace the abandoned version")
            expect(CleanupService.isFaithful("anything", to: ""),
                   "an empty transcript has nothing to lose")
        }

        // MARK: App-aware dictation

        section("app context")
        let gmail = FrontApp.inferContext(
            appName: "Google Chrome", bundleID: "com.google.Chrome",
            document: "https://mail.google.com/mail/u/0/#inbox"
        )
        expect(gmail.context == .email, "Gmail in a browser gets email cleanup")
        expect(gmail.destinationName == "Gmail", "a known web destination replaces the browser name")

        let whatsapp = FrontApp.inferContext(
            appName: "Safari", bundleID: "com.apple.Safari",
            document: "https://web.whatsapp.com/"
        )
        expect(whatsapp.context == .chat, "WhatsApp Web stays conversational")

        let github = FrontApp.inferContext(
            appName: "Firefox", bundleID: "org.mozilla.firefox",
            windowTitle: "Pull requests · owner/repository · GitHub"
        )
        expect(github.context == .development, "GitHub in a browser gets developer context")

        let xcode = FrontApp.inferContext(appName: "Xcode", bundleID: "com.apple.dt.Xcode")
        expect(xcode.context == .development, "Xcode gets developer context")
        expect(xcode.context.recognitionHints.contains("TypeScript"),
               "developer context supplies technical recognition hints")
        expect(["docs", "dev", "app", "bug", "build", "code", "fix", "PR", "test"]
            .allSatisfy(xcode.context.recognitionHints.contains),
            "developer hints include documentation and everyday engineering terms")

        let slack = FrontApp.inferContext(
            appName: "Slack", bundleID: "com.tinyspeck.slackmacgap"
        )
        expect(slack.context == .chat, "native Slack stays conversational")

        let mail = FrontApp.inferContext(appName: "Mail", bundleID: "com.apple.mail")
        expect(mail.context == .email, "native Mail gets email cleanup")

        let safari = FrontApp.inferContext(
            appName: "Safari", bundleID: "com.apple.Safari", document: "https://example.com/"
        )
        expect(safari.context == .browser, "an unknown website gets neutral browser cleanup")
        expect(FrontApp.roleAcceptsText(kAXTextFieldRole as String),
               "a text field is recognized as an insertion target")
        expect(FrontApp.roleAcceptsText(kAXTextAreaRole as String),
               "a text area is recognized as an insertion target")
        expect(!FrontApp.roleAcceptsText(kAXWindowRole as String),
               "a focused window is not mistaken for a text field")
        expect(!FrontApp.unknown.hasTextTarget,
               "missing focus falls back to the clipboard")

        var zedTarget = FrontApp.unknown
        zedTarget.bundleID = "dev.zed.Zed"
        expect(zedTarget.prefersClipboardPaste, "Zed bypasses direct AX insertion")

        section("shortcut isolation")
        let monitor = HotkeyMonitor()
        monitor.dispatchAction = { $0() }
        var dictating = true
        var stops = 0
        var cancels = 0
        monitor.isDictating = { dictating }
        monitor.onStop = { stops += 1; dictating = false }
        monitor.onCancel = { cancels += 1; dictating = false }
        func route(_ code: Int, down: Bool, flags: CGEventFlags = [], repeatKey: Bool = false,
                   hotkey: Hotkey = .fn) -> Bool {
            guard let event = CGEvent(keyboardEventSource: nil,
                                      virtualKey: CGKeyCode(code), keyDown: down) else { return false }
            event.flags = flags
            event.setIntegerValueField(.keyboardEventAutorepeat, value: repeatKey ? 1 : 0)
            return monitor.handle(type: down ? .keyDown : .keyUp, event: event, hotkey: hotkey)
        }
        for code in [kVK_Return, kVK_ANSI_KeypadEnter] {
            let flags: CGEventFlags = .maskCommand
            dictating = true
            let previousStops = stops
            expect(route(code, down: true, flags: flags), "stop shortcut cannot reach the chat app")
            expect(stops == previousStops + 1, "stop shortcut ends dictation once")
            expect(route(code, down: true, flags: flags, repeatKey: true),
                   "stop autorepeat stays consumed after recording ends")
            expect(stops == previousStops + 1, "autorepeat does not stop twice")
            expect(route(code, down: false), "stop release is consumed after modifiers lift")
            expect(!route(code, down: true, flags: flags), "idle submit shortcuts reach the app")
            expect(!route(code, down: false), "idle submit releases reach the app")
        }
        for code in [kVK_Return, kVK_ANSI_KeypadEnter] {
            dictating = true
            let previousStops = stops
            expect(!route(code, down: true, flags: .maskControl),
                   "Control Enter reaches the app while dictating")
            expect(stops == previousStops && dictating,
                   "Control Enter does not stop dictation")
            expect(!route(code, down: false, flags: .maskControl),
                   "Control Enter release reaches the app")
        }
        dictating = true
        expect(!route(kVK_Return, down: true), "plain Return still reaches the app")
        expect(route(kVK_Escape, down: true), "cancel does not also dismiss the app's composer")
        expect(cancels == 1, "Escape cancels dictation once")
        expect(route(kVK_Escape, down: false), "cancel release stays consumed")
        expect(!route(kVK_Escape, down: true), "idle Escape reaches the app")
        let controlReturn = Hotkey.combo(keyCode: kVK_Return, flags: .maskControl)
        expect(route(kVK_Return, down: true, flags: .maskControl, hotkey: controlReturn),
               "a configured Control Return hotkey is consumed even when idle")
        expect(route(kVK_Return, down: false, hotkey: controlReturn),
               "configured hotkey release stays consumed without modifiers")

        let deferredMonitor = HotkeyMonitor()
        var pendingActions: [@MainActor () -> Void] = []
        var didStop = false
        deferredMonitor.dispatchAction = { pendingActions.append($0) }
        deferredMonitor.isDictating = { true }
        deferredMonitor.onStop = { didStop = true }
        if let event = CGEvent(keyboardEventSource: nil,
                               virtualKey: CGKeyCode(kVK_Return), keyDown: true) {
            event.flags = .maskCommand
            expect(deferredMonitor.handle(type: .keyDown, event: event),
                   "stop is consumed before deferred work runs")
            expect(!didStop && pendingActions.count == 1,
                   "dictation work does not run inside the event callback")
            pendingActions.removeFirst()()
            expect(didStop, "queued stop runs after the callback")
            event.setIntegerValueField(.eventSourceUserData, value: Inserter.eventMarker)
            expect(!deferredMonitor.handle(type: .keyDown, event: event),
                   "Flow-generated events bypass even a consumed key")
        }
        if let paste = CGEvent(keyboardEventSource: nil,
                               virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true) {
            paste.flags = .maskCommand
            paste.setIntegerValueField(.eventSourceUserData, value: Inserter.eventMarker)
            expect(!monitor.handle(type: .keyDown, event: paste,
                                   hotkey: .combo(keyCode: kVK_ANSI_V, flags: .maskCommand)),
                   "synthetic paste cannot trigger or be swallowed by a matching hotkey")
        }

        // MARK: Single instance

        section("single instance")
        expect(!AppDelegate.shouldYieldToExistingInstance(currentPID: 100, runningPIDs: [100]),
               "a sole Flow process keeps running")
        expect(!AppDelegate.shouldYieldToExistingInstance(currentPID: 100, runningPIDs: [100, 200]),
               "the oldest Flow process owns the hotkey")
        expect(AppDelegate.shouldYieldToExistingInstance(currentPID: 200, runningPIDs: [100, 200]),
               "a second Flow process exits before installing a hotkey")

        // MARK: Retraction safety

        section("retraction")
        do {
            expect(Inserter.retractable(target: "anything", lastInsert: nil) == nil,
                   "with nothing inserted, nothing may be deleted")
            expect(Inserter.retractable(target: nil, lastInsert: "hello there") == "hello there",
                   "a bare scratch-that takes back the whole insert")
            expect(Inserter.retractable(target: "hello there", lastInsert: "hello there") == "hello there",
                   "an exact match is ours to take back")
            expect(Inserter.retractable(target: "there", lastInsert: "hello there") == "there",
                   "so is the tail of what we typed")
            expect(Inserter.retractable(target: "the user's own sentence", lastInsert: "hello there") == nil,
                   "a target we never typed is refused, so the field is left alone")
            expect(Inserter.retractable(target: "hello", lastInsert: "hello there") == nil,
                   "and a prefix is refused too: deleting it would eat the tail")
        }

        // MARK: Lexicon matching

        section("lexicon")
        let lexicon = Lexicon()
        do {
            lexicon.addWord("Tashif")
            lexicon.addWord("Cloudflare")
            expect(lexicon.matches(in: "i told tashif about it").contains("Tashif"),
                   "an exact word is matched case-insensitively")
            expect(lexicon.matches(in: "i told tashiff about it").contains("Tashif"),
                   "a near miss is matched too")
            expect(lexicon.matches(in: "lunch at one").isEmpty,
                   "unrelated speech pulls in no vocabulary")
            lexicon.removeWord("Tashif")
            lexicon.removeWord("Cloudflare")
        }

        do {
            let added = lexicon.addWords("Cloudflare, Wrangler\nDurable Objects;Hyperdrive\tR2")
            expect(added == 5, "a mixed-separator paste splits into five words")
            expect(lexicon.contains("Durable Objects"),
                   "a multi-word entry survives splitting")
            expect(lexicon.addWords("wrangler") == 0,
                   "a duplicate is refused case-insensitively")
            expect(lexicon.addWords("  \n , ; ") == 0,
                   "separators alone add nothing")
            expect(lexicon.exportedWords.split(separator: "\n").count == 5,
                   "export writes one word per line")
            for word in ["Cloudflare", "Wrangler", "Durable Objects", "Hyperdrive", "R2"] {
                lexicon.removeWord(word)
            }
            expect(lexicon.exportedWords.isEmpty, "and removal empties it again")
        }

        // MARK: Decisions

        section("decisions")
        let raw = Decision.raw("hello there")
        expect(raw.mode == .insert, "a raw decision inserts")
        expect(raw.target == nil, "a raw decision has no target")
        expect("".nilIfEmpty == nil, "empty strings normalise to nil")
        expect("x".nilIfEmpty == "x", "non-empty strings pass through")

        // MARK: Hotkey

        section("hotkey")
        expect(Hotkey.fn.isModifierOnly, "fn is a modifier-only hotkey")
        expect(Hotkey.fn.label == "fn (globe)", "and names itself the way the key is labelled")
        expect(Hotkey.rightOption.label == "Right ⌥", "right option reads as the symbol")
        expect(Hotkey.holdPresets.allSatisfy(\.isModifierOnly), "every hold preset is holdable")
        expect(Hotkey.comboPresets.allSatisfy { !$0.isModifierOnly },
               "combo presets are not modifier-only")
        expect(Hotkey.comboPresets.allSatisfy { $0.modifiers & Hotkey.modifierMask != 0 },
               "and every one carries a modifier, so it cannot fire while you type")
        expect(Hotkey.optionCommandD.label == "⌥⌘D", "a combo reads as its symbols")
        expect(Hotkey.hyperD.label == "⌃⌥⇧⌘D", "and hyper spells all four out")
        expect(Hotkey.fn.isPreset, "a preset knows it is one")

        let combo = Hotkey.combo(
            keyCode: 49,
            flags: [.maskControl, .maskAlternate, .maskNonCoalesced]
        )
        expect(!combo.isModifierOnly, "a key plus modifiers is not modifier-only")
        expect(combo.label == "⌃⌥Space", "a combo renders modifiers then key")
        expect(combo.modifiers & ~Hotkey.modifierMask == 0,
               "stray event flags are masked off, so matching stays stable")
        expect(!combo.isPreset, "a custom combo is not a preset")

        if let roundTrip = try? JSONDecoder().decode(
            Hotkey.self, from: JSONEncoder().encode(combo)
        ) {
            expect(roundTrip == combo, "a hotkey survives being stored and read back")
        } else {
            failures += 1
            print("  FAIL  hotkey did not round-trip")
        }

        expect(Hotkey.modifierOnly(keyCode: 0) == nil, "a letter is not a modifier")
        expect(Hotkey.modifierOnly(keyCode: 63) == Hotkey.fn, "keycode 63 resolves to fn")

        // MARK: Statistics

        section("statistics")
        expect(Stats.wordCount("one two three") == 3, "words are counted on whitespace")
        expect(Stats.wordCount("  padded   out  ") == 2, "padding does not inflate the count")
        expect(Stats.wordCount("") == 0, "empty text has no words")

        let calendar = Calendar.current
        let now = Date.now
        let sample = [
            // 60 words in 60s -> 60 wpm.
            DailyStat(day: calendar.startOfDay(for: now), words: 60, dictations: 1, duration: 60),
            DailyStat(day: calendar.startOfDay(for: calendar.date(byAdding: .day, value: -2, to: now)!),
                      words: 20, dictations: 1, duration: 20),
        ]

        let all = Stats.compute(from: sample, range: .allTime)
        expect(all.totalWords == 80, "all-time totals every dictation")
        expect(all.dictationCount == 2, "and counts them")
        expect(all.wordsPerMinute == 60, "wpm is words over speaking minutes")
        // 80 words at 40wpm = 120s of typing; 80s spoken -> 40s saved.
        expect(Int(all.timeSaved.rounded()) == 40, "time saved is typing time minus speaking time")
        expect(all.wordsByDay.count == 2, "the day map has one entry per active day")

        let today = Stats.compute(from: sample, range: .today)
        expect(today.totalWords == 60, "a range filter excludes older dictations")
        expect(today.wordsByDay.count == 2, "but the activity map still spans everything")

        let empty = Stats.compute(from: [], range: .allTime)
        expect(empty.wordsPerMinute == 0, "no dictations means no divide-by-zero")
        expect(empty.timeSaved == 0, "and nothing saved")

        let thresholds = all.intensityThresholds()
        expect(thresholds == thresholds.sorted(), "intensity thresholds are ascending")
        expect(Set(thresholds).count == thresholds.count, "and strictly increasing, so buckets differ")
        expect(all.level(for: 0, thresholds: thresholds) == 0, "a day with nothing is level 0")
        expect((1...4).contains(all.level(for: 999_999, thresholds: thresholds)), "a huge day clamps to level 4")

        expect(Stats.compactCount(950) == "950", "small counts print whole")
        expect(Stats.compactCount(12_700) == "12.7k", "thousands compact")
        expect(Stats.humanDuration(5_340).value == "1h 29m", "durations read the way you say them")
        expect(Stats.humanDuration(720).value == "12", "minutes split from their unit")
        expect(Stats.humanDuration(720).unit == "m", "so the unit can be styled apart")

        section("statistics survive retention")
        do {
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("flow-selfcheck-\(UUID().uuidString).sqlite")
            defer { try? FileManager.default.removeItem(at: url) }
            let store = try SQLiteStore(url: url)

            let old = Date.now.addingTimeInterval(-200 * 86_400)
            try store.insert(DictationRecord(raw: "", cleaned: "one two three four five",
                                             appBundleID: "", appName: "Notes",
                                             createdAt: old, duration: 5))
            try store.purgeDictations(before: Retention.ninetyDays.cutoff!)

            expect(try store.dictations(matching: nil, limit: nil).isEmpty,
                   "the transcript is purged by retention")
            let days = try store.dailyStats()
            expect(days.count == 1, "but the day still counts toward statistics")
            expect(days.first?.words == 5, "with its word total intact")
        } catch {
            failures += 1
            print("  FAIL  daily stats threw: \(error)")
        }

        // MARK: Custom language model

        section("custom language model")
        // Discarding when nothing is trained must be a no-op, not a crash: the settings
        // window offers the button whenever the toggle is on.
        CustomLanguageModel.discard()
        expect(!CustomLanguageModel.hasTrainedModel(), "no trained model reports as absent")
        expect(CustomLanguageModel.existingConfiguration() == nil, "and yields no configuration")
        expect(TranscriberKind.speech.label == "SpeechTranscriber", "the primary transcriber names itself")
        expect(TranscriberKind.customized.label.contains("custom"), "the customised kind says so")

        // MARK: Availability copy

        section("availability")
        expect(CleanupAvailability.available.isAvailable, "available reads as available")
        expect(!CleanupAvailability.appleIntelligenceOff.isAvailable, "disabled reads as unavailable")
        expect(CleanupAvailability.appleIntelligenceOff.detail != nil,
               "an unavailable reason explains itself")
        expect(CleanupAvailability.unsupportedLanguage("English (India)").detail?.contains("English (India)") == true,
               "a language mismatch names the current language")

        // MARK: Hinglish

        section("hinglish")
        expect(TranscriptionLanguage.hinglish.locale.identifier
            .replacingOccurrences(of: "_", with: "-").lowercased() == "hi-in",
               "Hinglish selects the Hindi recognizer")
        let roman = CleanupService.romanizeHinglish("मुझे कल deploy करना है")
        expect(!roman.contains("म"), "Hinglish fallback removes Devanagari")
        expect(roman.contains("deploy"), "Hinglish fallback preserves English words")
        expect(roman == "mujhe kal deploy karna hai",
               "Hinglish fallback removes formal Hindi schwas")
        expect(TranscriptionLanguage.hinglish.detail.contains("Roman"),
               "the language setting explains its output script")

        print("\n\(checks - failures)/\(checks) passed")
        exit(failures == 0 ? 0 : 1)
    }
}
