import Foundation

@MainActor
private final class CheckStreamingField: StreamingTextField {
    var state: StreamingFieldState
    var focused = true
    var delayed = false
    var delay: Duration = .milliseconds(30)
    var refusesEdits = false
    var canExposeEmptyParagraph = false
    var syntheticParagraph = false
    var paragraphAfterRewrite = false
    var paragraphOffsets = false
    /// Paragraph separators before the caret that the selection range leaves out, as
    /// Chromium does once a rich editor already holds paragraphs.
    var uncountedSeparators = 0
    /// Parses pasted text the way Markdown composers do: a blank line becomes one
    /// paragraph break and "- " list markers disappear into list items.
    var parsesMarkdown = false
    init(_ text: String, location: Int? = nil, length: Int = 0) {
        state = .init(text: text, location: location ?? text.utf16.count, length: length)
    }
    func read() -> StreamingFieldState? {
        guard focused else { return nil }
        return .init(text: state.text, location: state.location - uncountedSeparators, length: state.length)
    }
    func replace(location: Int, length: Int, with text: String) -> Bool {
        guard !refusesEdits else { return false }
        let location = location + uncountedSeparators
        var text = text
        if parsesMarkdown {
            while text.contains("\n\n") { text = text.replacingOccurrences(of: "\n\n", with: "\n") }
            text = text.replacingOccurrences(of: "(?m)^- ", with: "", options: .regularExpression)
        }
        let value = NSMutableString(string: state.text)
        value.replaceCharacters(in: NSRange(location: location, length: length), with: text)
        var next = StreamingFieldState(text: value as String, location: location + text.utf16.count, length: 0)
        if syntheticParagraph {
            if state.text == "\n", location == 0, length == 0 { next.text = text }
            if paragraphAfterRewrite, length > 0, !text.isEmpty { next.text += "\n" }
            if next.text.isEmpty { next.text = "\n" }
        }
        if paragraphOffsets { next.location -= text.filter { $0 == "\n" }.count }
        if delayed {
            Task { @MainActor in
                try? await Task.sleep(for: self.delay)
                self.state = next
            }
        } else { state = next }
        return true
    }
}

/// Firefox reports an empty composer's CSS placeholder as its value, with the caret
/// after it, until the first paste replaces it.
@MainActor
private final class PlaceholderField: StreamingTextField {
    let placeholder = "Ask Gemini\n"
    var content = ""
    var caret = 0
    var canExposeEmptyParagraph: Bool { true }
    func read() -> StreamingFieldState? {
        content.isEmpty ? .init(text: placeholder, location: 10, length: 0) : .init(text: content, location: caret, length: 0)
    }
    func replace(location: Int, length: Int, with text: String) -> Bool {
        if content.isEmpty { content = text; caret = text.utf16.count; return true }
        let value = NSMutableString(string: content)
        value.replaceCharacters(in: NSRange(location: location, length: length), with: text)
        content = value as String
        caret = location + text.utf16.count
        return true
    }
    func replaceEntireDraft(with text: String) -> Bool? {
        content = text
        caret = text.utf16.count
        return true
    }
}

enum StreamingCheck {
    @MainActor
    static func run() async -> Never {
        var failures = 0
        func check(_ valid: Bool, _ label: String) {
            print("\(valid ? "ok" : "FAIL") \(label)")
            if !valid { failures += 1 }
        }
        var preview = StreamingPreviewBuffer()
        preview.enqueue("Hello world, this arrived in one chunk.")
        preview.advance()
        check(preview.displayedText == "Hello ", "a whole response chunk starts with one word")
        preview.advance()
        check(preview.displayedText == "Hello world, ", "word reveal keeps punctuation and spaces")
        preview.enqueue("")
        check(preview.displayedText == "Hello world, ", "provider retries keep the readable preview")
        preview.enqueue("Hello there 👩🏽‍💻\n\nNext paragraph.")
        preview.advance()
        check(preview.displayedText == "Hello there ", "a revised response replaces stale words")
        preview.advance()
        check(preview.displayedText == "Hello there 👩🏽‍💻\n\n", "word reveal preserves emoji and paragraph breaks")
        preview.revealAll()
        check(preview.isCaughtUp && preview.displayedText == "Hello there 👩🏽‍💻\n\nNext paragraph.",
              "the preview catches up without changing the response")
        let longPreview = String(repeating: "Keep every earlier word. ", count: 100)
        preview.enqueue(longPreview)
        preview.revealAll()
        check(preview.displayedText == longPreview && preview.displayedText.count > 600,
              "long previews keep the entire response for scrolling")
        var partialWord = StreamingPreviewBuffer()
        partialWord.enqueue("Hel")
        partialWord.advance()
        partialWord.enqueue("Hello world")
        partialWord.advance()
        check(partialWord.displayedText == "Hello ", "partial word chunks join without invented spaces or duplication")
        let shortWidth = StreamingPreviewState.contentWidth(for: "Hello.")
        let longWidth = StreamingPreviewState.contentWidth(for: longPreview)
        check(shortWidth < longWidth && longWidth <= 292, "short previews fit a smaller bubble")
        let paced = StreamingPreviewState()
        paced.update("Hello world, this arrived in one chunk.")
        check(paced.isVisible && paced.displayedText == "Hello ", "a visible preview does not dump an entire chunk")
        paced.followsLatest = false
        paced.update(longPreview)
        check(!paced.followsLatest, "incoming words do not resume scrolling while reading earlier text")
        paced.finish()
        try? await Task.sleep(for: .milliseconds(850))
        check(!paced.isVisible && paced.displayedText == longPreview,
              "completion drains a large final chunk before dismissing the preview")
        paced.reset()
        paced.update("A fresh response", animated: false)
        check(paced.displayedText == "A fresh response" && paced.followsLatest,
              "Reduce Motion shows the full response and a new preview follows the latest words")
        paced.update("A fresh response with queued words")
        paced.reset()
        try? await Task.sleep(for: .milliseconds(100))
        check(!paced.isVisible && paced.displayedText.isEmpty, "cancelling a preview prevents queued words from reappearing")

        let field = CheckStreamingField("Before old after", location: 7, length: 3)
        let stream = StreamingInsertion(field: field)!
        let empty = await stream.update("")
        check(empty && field.state.text == "Before old after", "an empty initial preview preserves the selection")
        let first = await stream.update("Hello")
        check(first && field.state.text == "Before Hello after", "the first chunk replaces only the original selection")
        let extended = await stream.update("Hello 👩🏽‍💻\nworld")
        check(extended && field.state.text == "Before Hello 👩🏽‍💻\nworld after", "incremental Unicode and multiline output preserve surrounding text")
        let final = await stream.update("Hi 👩🏽‍💻\nworld!")
        check(final && field.state.text == "Before Hi 👩🏽‍💻\nworld! after", "final reconciliation replaces the draft without duplication")
        let rolledBack = await stream.rollback()
        check(rolledBack && field.state.text == "Before old after", "cancellation restores the user's selected text")

        let paragraph = CheckStreamingField("\n", location: 0)
        paragraph.canExposeEmptyParagraph = true
        paragraph.syntheticParagraph = true
        let paragraphStream = StreamingInsertion(field: paragraph)!
        let paragraphFirst = await paragraphStream.update("First")
        let paragraphFinal = await paragraphStream.update("First and the entire remaining transcription")
        paragraph.paragraphAfterRewrite = true
        let paragraphRevised = await paragraphStream.update("The complete revised answer")
        let paragraphContinued = await paragraphStream.update("The complete revised answer with more words")
        let paragraphRestored = await paragraphStream.rollback()
        check(paragraphFirst && paragraphFinal && paragraphRevised && paragraphContinued && paragraphRestored && paragraph.state.text == "\n",
              "an empty rich editor's synthetic newline does not strand its first transcription")
        let realNewline = CheckStreamingField("\n", location: 0)
        realNewline.canExposeEmptyParagraph = true
        let newlineStream = StreamingInsertion(field: realNewline)!
        let newlineFirst = await newlineStream.update("First")
        let newlineFinal = await newlineStream.update("First and the complete answer")
        check(newlineFirst && newlineFinal && realNewline.state.text == "First and the complete answer\n",
              "a real surrounding newline survives rich field streaming")

        let drafted = CheckStreamingField("First paragraph.\nSecond paragraph.")
        drafted.canExposeEmptyParagraph = true
        drafted.uncountedSeparators = 1
        let draftedStream = StreamingInsertion(field: drafted)!
        let draftedFirst = await draftedStream.update("Hello")
        let draftedNext = await draftedStream.update("Hello world and the rest")
        let draftedFinal = await draftedStream.update("Hi world and the rest!")
        check(draftedFirst && draftedNext && draftedFinal
              && drafted.state.text == "First paragraph.\nSecond paragraph.Hi world and the rest!",
              "a rich editor that already holds paragraphs keeps streaming after its last one")
        let draftedRestored = await draftedStream.rollback()
        check(draftedRestored && drafted.state.text == "First paragraph.\nSecond paragraph.",
              "cancelling after existing paragraphs restores the draft")

        let gemini = PlaceholderField()
        let geminiStream = StreamingInsertion(field: gemini)!
        let geminiFirst = await geminiStream.update("Here, why do we have")
        let geminiNext = await geminiStream.update("Here, why do we have two buttons?\nPlease remove")
        let geminiFinal = await geminiStream.update("Here, why do we have two buttons? Please remove the purple one.")
        check(geminiFirst && geminiNext && geminiFinal && gemini.content == "Here, why do we have two buttons? Please remove the purple one.",
              "a composer that reports its placeholder as text keeps receiving the whole answer")
        let geminiRestored = await geminiStream.rollback()
        check(geminiRestored && gemini.content.isEmpty, "cancelling restores the empty composer and its placeholder")
        let typed = CheckStreamingField("Hello there")
        typed.canExposeEmptyParagraph = true
        let typedStream = StreamingInsertion(field: typed)!
        _ = await typedStream.update(" and")
        typed.state = .init(text: " and", location: 4, length: 0)
        let typedNext = await typedStream.update(" and more")
        check(!typedNext && typed.state.text == " and", "real text that vanishes is never treated as a placeholder later")

        let composer = CheckStreamingField("Replay the audio:")
        composer.canExposeEmptyParagraph = true
        composer.parsesMarkdown = true
        let composerStream = StreamingInsertion(field: composer)!
        let composerFirst = await composerStream.update("\n- Why do we have")
        let composerNext = await composerStream.update("\n- Why do we have two buttons?\n\nPlease remove")
        let composerFinal = await composerStream.update("\n- Why do we have two buttons?\n\nPlease remove the purple one.")
        check(composerFirst && composerNext && composerFinal
              && composer.state.text == "Replay the audio:\nWhy do we have two buttons?\nPlease remove the purple one.",
              "a composer that parses pasted Markdown keeps receiving the whole answer")
        let composerRestored = await composerStream.rollback()
        check(composerRestored && composer.state.text == "Replay the audio:", "cancelling restores a Markdown composer")
        let reworded = CheckStreamingField("Note.")
        reworded.canExposeEmptyParagraph = true
        let rewordedStream = StreamingInsertion(field: reworded)!
        _ = await rewordedStream.update(" First")
        reworded.state.text = "Note. Fist"
        let rewordedNext = await rewordedStream.update(" First words")
        check(!rewordedNext && reworded.state.text == "Note. Fist", "a draft the user edited is never overwritten")

        let rich = CheckStreamingField("")
        rich.canExposeEmptyParagraph = true
        rich.paragraphOffsets = true
        let richStream = StreamingInsertion(field: rich)!
        let richFirst = await richStream.update("First\nline")
        let richNext = await richStream.update("First\nline and the remaining words")
        let richFinal = await richStream.update("The complete\nrevised answer")
        check(richFirst && richNext && richFinal && rich.state.text == "The complete\nrevised answer",
              "paragraph caret offsets do not truncate or duplicate an owned rich draft")
        rich.state.text += " user edit"
        rich.state.location = rich.state.text.utf16.count
        let overwrite = await richStream.update("Stale response")
        let erase = await richStream.rollback()
        check(!overwrite && !erase && rich.state.text.hasSuffix(" user edit"),
              "full rich-draft updates preserve intervening user edits")

        let edited = CheckStreamingField("Prefix ")
        let editedStream = StreamingInsertion(field: edited)!
        _ = await editedStream.update("Draft")
        edited.state.text += " user edit"
        edited.state.location = edited.state.text.utf16.count
        let allowedEdit = await editedStream.update("Final")
        let allowedRollback = await editedStream.rollback()
        check(!allowedEdit && !allowedRollback && edited.state.text == "Prefix Draft user edit", "user edits stop streaming and survive cancellation")

        let moved = CheckStreamingField("")
        let movedStream = StreamingInsertion(field: moved)!
        _ = await movedStream.update("Draft")
        moved.focused = false
        let allowedMove = await movedStream.update("Final")
        check(!allowedMove && moved.state.text == "Draft", "focus changes stop field insertion")

        let retry = CheckStreamingField("")
        let retryStream = StreamingInsertion(field: retry)!
        _ = await retryStream.update("Rejected draft")
        _ = await retryStream.update("")
        let fallback = await retryStream.update("Fallback answer")
        check(fallback && retry.state.text == "Fallback answer", "a retry replaces the failed draft")

        let delayed = CheckStreamingField("")
        delayed.delayed = true
        let serialized = StreamingInsertion(field: delayed)!
        let one = Task { await serialized.update("One") }
        await Task.yield()
        let two = Task { await serialized.update("One two") }
        let firstDone = await one.value
        let secondDone = await two.value
        check(firstDone && secondDone && delayed.state.text == "One two", "overlapping callbacks serialize asynchronous field edits")
        let slowField = CheckStreamingField("")
        slowField.delayed = true
        slowField.delay = .milliseconds(350)
        let slowStream = StreamingInsertion(field: slowField)!
        let slowFirst = await slowStream.update("First")
        let slowFinal = await slowStream.update("First word and the complete answer")
        check(slowFirst && slowFinal && slowField.state.text == "First word and the complete answer",
              "slow field metadata does not strand the first word")
        let lateField = CheckStreamingField("")
        lateField.delayed = true
        lateField.delay = .milliseconds(1200)
        let lateStream = StreamingInsertion(field: lateField)!
        let timedOut = await lateStream.update("First")
        try? await Task.sleep(for: .milliseconds(300))
        lateField.delayed = false
        let recovered = await lateStream.update("First and the final answer")
        check(!timedOut && recovered && lateField.state.text == "First and the final answer",
              "a late exact confirmation permits safe final delivery")
        serialized.invalidate()
        let stale = await serialized.update("Stale answer")
        let restored = await serialized.rollback()
        check(!stale && restored && delayed.state.text.isEmpty, "cancelled callbacks cannot write after rollback")

        let unsupported = CheckStreamingField("")
        unsupported.refusesEdits = true
        let refused = await StreamingInsertion(field: unsupported)!.update("Answer")
        check(!refused && unsupported.state.text.isEmpty, "unsupported edits report failure without claiming insertion")
        let transient = CheckStreamingField("")
        let transientStream = StreamingInsertion(field: transient)!
        _ = await transientStream.update("Draft")
        transient.refusesEdits = true
        let blocked = await transientStream.update("Draft and more words")
        transient.refusesEdits = false
        let recoveredRollback = await transientStream.rollback()
        check(!blocked && recoveredRollback && transient.state.text.isEmpty,
              "a transient edit refusal still permits rollback of an unchanged draft")
        exit(failures == 0 ? 0 : 1)
    }
}
