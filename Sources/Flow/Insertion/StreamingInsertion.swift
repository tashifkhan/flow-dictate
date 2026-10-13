import AppKit
import ApplicationServices
import OSLog

struct StreamingFieldState: Equatable {
    var text: String
    var location: Int
    var length: Int
}

@MainActor
protocol StreamingTextField: AnyObject {
    var canExposeEmptyParagraph: Bool { get }
    func prepareForEdit() async
    func read() -> StreamingFieldState?
    func replace(location: Int, length: Int, with text: String) -> Bool
    func replaceEntireDraft(with text: String) -> Bool?
    func finishEdit()
}

extension StreamingTextField {
    var canExposeEmptyParagraph: Bool { false }
    func prepareForEdit() async {}
    func finishEdit() {}
    func replaceEntireDraft(with text: String) -> Bool? { nil }
}

@MainActor
final class ClosureStreamingTextField: StreamingTextField {
    let readState: () -> StreamingFieldState?
    let replaceText: (Int, Int, String) -> Bool
    init(read: @escaping () -> StreamingFieldState?, replace: @escaping (Int, Int, String) -> Bool) {
        readState = read
        replaceText = replace
    }
    func read() -> StreamingFieldState? { readState() }
    func replace(location: Int, length: Int, with text: String) -> Bool { replaceText(location, length, text) }
}

@MainActor
struct StreamingFocus {
    private let pid: pid_t
    private let element: AXUIElement?
    init?(app: FrontApp) {
        guard app.hasTextTarget, !app.isSecure, app.processID > 0 else { return nil }
        let element = FrontApp.focusedElement(pid: app.processID)
        guard element != nil || FrontApp.isZed(app.bundleID) else { return nil }
        pid = app.processID
        self.element = element
    }
    var isCurrent: Bool {
        guard FrontApp.systemFocus()?.appPID == pid else { return false }
        let current = FrontApp.focusedElement(pid: pid)
        // Zed exposes its editor only as a window, sometimes with no element at all.
        guard let element else { return current == nil }
        guard let current else { return false }
        return CFEqual(element, current)
    }
}

/// Owns only the selected range and the draft that replaces it. Every edit checks
/// focus, field contents, and caret position before touching the field again.
@MainActor
final class StreamingInsertion {
    private let field: any StreamingTextField
    private let original: StreamingFieldState
    private var expected: StreamingFieldState
    private(set) var text = ""
    private(set) var detached = false
    private(set) var didWrite = false
    private var pending: Task<Bool, Never>?
    private var cancelled = false
    private var awaitingConfirmation = false
    private var pendingEmptyParagraph = false
    private var ownsWholeRichEditor: Bool

    init?(field: any StreamingTextField) {
        guard let state = field.read(), state.location >= 0, state.length >= 0,
              state.location + state.length <= state.text.utf16.count else { return nil }
        self.field = field
        original = state
        expected = state
        ownsWholeRichEditor = field.canExposeEmptyParagraph && state.text.isEmpty && state.location == 0 && state.length == 0
    }

    static func capture(in app: FrontApp) -> StreamingInsertion? {
        guard app.hasTextTarget, !app.isSecure, Permissions.hasAccessibility,
              let field = AccessibilityStreamingField(app: app) else { return nil }
        return StreamingInsertion(field: field)
    }

    func update(_ next: String) async -> Bool {
        let previous = pending
        let task = Task { @MainActor in
            _ = await previous?.value
            guard !self.cancelled else { return false }
            return await self.write(next)
        }
        pending = task
        return await task.value
    }

    func invalidate() { cancelled = true }

    private func write(_ next: String) async -> Bool {
        // A slow renderer may confirm after the polling deadline. Resume only
        // when both its exact text and selection still match the edit we sent.
        if awaitingConfirmation, confirmsExpectedState() {
            detached = false
            awaitingConfirmation = false
        }
        guard !detached else { return false }
        await field.prepareForEdit()
        guard !cancelled else { return false }
        guard field.read() == expected else { detached = true; return false }
        if !didWrite, next.isEmpty { return true }
        if didWrite, next == text { return true }
        // Preserve the common prefix so each new token normally appends at the caret.
        let prefix = zip(text, next).prefix { $0 == $1 }.map { $0.0 }
        let prefixText = String(prefix)
        let suffix = String(next.dropFirst(prefix.count))
        let location = original.location + prefixText.utf16.count
        let length = didWrite ? text.utf16.count - prefixText.utf16.count : original.length
        let mutable = NSMutableString(string: expected.text)
        if ownsWholeRichEditor { mutable.setString(next) }
        else { mutable.replaceCharacters(in: NSRange(location: location, length: length), with: suffix) }
        let after = StreamingFieldState(text: mutable as String,
                                       location: original.location + next.utf16.count, length: 0)
        let emptyParagraph = field.canExposeEmptyParagraph
            && original.text == "\n" && original.location == 0 && original.length == 0
        let replaced = ownsWholeRichEditor
            ? field.replaceEntireDraft(with: next) ?? field.replace(location: 0, length: expected.text.utf16.count, with: next)
            : field.replace(location: location, length: length, with: suffix)
        guard replaced else {
            detached = true
            return false
        }
        defer { field.finishEdit() }
        // The app may publish its AX value a few milliseconds after the edit.
        expected = after
        pendingEmptyParagraph = emptyParagraph
        text = next
        didWrite = true
        for attempt in 0..<51 {
            if confirmsExpectedState() { return true }
            if attempt < 50 { try? await Task.sleep(for: .milliseconds(20)) }
        }
        detached = true
        awaitingConfirmation = true
        return false
    }

    private func confirmsExpectedState() -> Bool {
        guard let actual = field.read() else { return false }
        if actual == expected { pendingEmptyParagraph = false; return true }
        if ownsWholeRichEditor, actual.length == 0 {
            // Rich editors count paragraph separators differently in AXValue and
            // AXSelectedTextRange. We own the whole initially empty editor and
            // use its select-all command, so subsequent edits need no guessed offsets.
            let bodyMatches = actual.text == expected.text || actual.text == expected.text + "\n"
                || (expected.text.hasSuffix("\n") && actual.text == String(expected.text.dropLast()))
            let paragraphCount = expected.text.filter { $0 == "\n" }.count
            if bodyMatches, actual.location == expected.location
                || actual.location == expected.location - paragraphCount {
                expected = actual
                pendingEmptyParagraph = false
                return true
            }
        }
        // A rich editor's placeholder paragraph can disappear on the first
        // paste and reappear after a full rewrite. Allow only one trailing LF
        // to change, only in an originally empty field, with the exact caret.
        guard pendingEmptyParagraph,
              actual.location == expected.location, actual.length == expected.length else { return false }
        let removed = expected.text.hasSuffix("\n") && actual.text == String(expected.text.dropLast())
        let added = actual.text == expected.text + "\n"
        guard removed || added else { return false }
        if removed { ownsWholeRichEditor = true }
        expected = actual
        pendingEmptyParagraph = false
        return true
    }

    /// Restore the user's original selection only while our draft still owns it.
    func rollback() async -> Bool {
        cancelled = true
        let previous = pending
        let task = Task { @MainActor in
            _ = await previous?.value
            return await self.restore()
        }
        pending = task
        return await task.value
    }

    private func restore() async -> Bool {
        guard didWrite else { return !detached }
        await field.prepareForEdit()
        if awaitingConfirmation, confirmsExpectedState() { detached = false; awaitingConfirmation = false }
        guard field.read() == expected else { detached = true; return false }
        let selected = (original.text as NSString).substring(with: NSRange(location: original.location, length: original.length))
        let replaced = ownsWholeRichEditor
            ? field.replaceEntireDraft(with: selected) ?? field.replace(location: 0, length: expected.text.utf16.count, with: selected)
            : field.replace(location: original.location, length: text.utf16.count, with: selected)
        guard replaced else {
            detached = true
            return false
        }
        defer { field.finishEdit() }
        let restored = StreamingFieldState(text: original.text,
                                            location: original.location + original.length, length: 0)
        expected = restored
        text = ""
        didWrite = false
        for attempt in 0..<51 {
            if field.read() == restored { return true }
            if attempt < 50 { try? await Task.sleep(for: .milliseconds(20)) }
        }
        detached = true
        return false
    }
}

/// Native fields use AXSelectedText. Web and Electron fields use real paste events
/// so the editor receives the entire chunk and runs its input handlers.
@MainActor
private final class AccessibilityStreamingField: StreamingTextField {
    private let app: FrontApp
    private let element: AXUIElement
    private let usesPaste: Bool
    private let inserter = Inserter()
    private var restoreClipboard: (() -> Void)?
    private let log = Logger(subsystem: "sh.taf.flow", category: "insert")
    var canExposeEmptyParagraph: Bool { usesPaste && (app.isWebContent || app.isElectron) }

    init?(app: FrontApp) {
        guard app.processID > 0, let element = FrontApp.focusedElement(pid: app.processID) else { return nil }
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &settable) == .success,
              settable.boolValue else { return nil }
        self.app = app
        self.element = element
        usesPaste = app.isWebContent || app.prefersClipboardPaste
        if !usesPaste {
            guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
                  settable.boolValue else { return nil }
        }
    }

    func read() -> StreamingFieldState? {
        guard FrontApp.systemFocus()?.appPID == app.processID,
              let focused = FrontApp.focusedElement(pid: app.processID), CFEqual(focused, element),
              let text = FrontApp.string(element, kAXValueAttribute as String), text.utf16.count <= 1_000_000 else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range),
              range.location >= 0, range.length >= 0, range.location <= text.utf16.count,
              range.length <= text.utf16.count - range.location else { return nil }
        return StreamingFieldState(text: text, location: range.location, length: range.length)
    }

    func prepareForEdit() async {
        if usesPaste { await inserter.waitForModifierRelease() }
    }

    func replace(location: Int, length: Int, with text: String) -> Bool {
        guard read() != nil else { log.notice("stream field unavailable before edit"); return false }
        guard !usesPaste || !Inserter.modifiersAreHeld else { log.notice("stream edit blocked by held modifiers"); return false }
        var range = CFRange(location: location, length: length)
        guard let value = AXValueCreate(.cfRange, &range) else { return false }
        let selected = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
        guard selected == .success else {
            log.notice("stream selection failed: \(selected.rawValue, privacy: .public)")
            return false
        }
        if !usesPaste {
            return AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
        }
        do {
            // Pasting an empty string does not delete a selection in Chromium.
            if text.isEmpty { return inserter.deleteStreamingSelection() }
            restoreClipboard = try inserter.pasteForStreaming(text, into: app.processID)
            return true
        } catch { return false }
    }

    func replaceEntireDraft(with text: String) -> Bool? {
        guard usesPaste else { return nil }
        guard read() != nil, !Inserter.modifiersAreHeld, inserter.selectAllForStreaming() else { return false }
        do {
            if text.isEmpty { return inserter.deleteStreamingSelection() }
            restoreClipboard = try inserter.pasteForStreaming(text, into: app.processID)
            return true
        } catch { return false }
    }

    func finishEdit() {
        restoreClipboard?()
        restoreClipboard = nil
    }
}
