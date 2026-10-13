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
    init(_ text: String, location: Int? = nil, length: Int = 0) {
        state = .init(text: text, location: location ?? text.utf16.count, length: length)
    }
    func read() -> StreamingFieldState? { focused ? state : nil }
    func replace(location: Int, length: Int, with text: String) -> Bool {
        guard !refusesEdits else { return false }
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

enum StreamingCheck {
    @MainActor
    static func run() async -> Never {
        var failures = 0
        func check(_ valid: Bool, _ label: String) {
            print("\(valid ? "ok" : "FAIL") \(label)")
            if !valid { failures += 1 }
        }
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
