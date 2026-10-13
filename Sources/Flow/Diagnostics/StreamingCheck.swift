import Foundation

@MainActor
private final class CheckStreamingField: StreamingTextField {
    var state: StreamingFieldState
    var focused = true
    var delayed = false
    var refusesEdits = false
    init(_ text: String, location: Int? = nil, length: Int = 0) {
        state = .init(text: text, location: location ?? text.utf16.count, length: length)
    }
    func read() -> StreamingFieldState? { focused ? state : nil }
    func replace(location: Int, length: Int, with text: String) -> Bool {
        guard !refusesEdits else { return false }
        let value = NSMutableString(string: state.text)
        value.replaceCharacters(in: NSRange(location: location, length: length), with: text)
        let next = StreamingFieldState(text: value as String, location: location + text.utf16.count, length: 0)
        if delayed {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(30))
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
        serialized.invalidate()
        let stale = await serialized.update("Stale answer")
        let restored = await serialized.rollback()
        check(!stale && restored && delayed.state.text.isEmpty, "cancelled callbacks cannot write after rollback")

        let unsupported = CheckStreamingField("")
        unsupported.refusesEdits = true
        let refused = await StreamingInsertion(field: unsupported)!.update("Answer")
        check(!refused && unsupported.state.text.isEmpty, "unsupported edits report failure without claiming insertion")
        exit(failures == 0 ? 0 : 1)
    }
}
