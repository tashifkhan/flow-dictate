import AppKit
import ApplicationServices
import Carbon.HIToolbox

struct StreamingFieldState: Equatable {
    var text: String
    var location: Int
    var length: Int
}

@MainActor
protocol StreamingTextField: AnyObject {
    func read() -> StreamingFieldState?
    func replace(location: Int, length: Int, with text: String) -> Bool
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
    private let element: AXUIElement
    init?(app: FrontApp) {
        guard app.hasTextTarget, !app.isSecure, app.processID > 0,
              let element = FrontApp.focusedElement(pid: app.processID) else { return nil }
        pid = app.processID
        self.element = element
    }
    var isCurrent: Bool {
        guard FrontApp.systemFocus()?.appPID == pid,
              let current = FrontApp.focusedElement(pid: pid) else { return false }
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

    init?(field: any StreamingTextField) {
        guard let state = field.read(), state.location >= 0, state.length >= 0,
              state.location + state.length <= state.text.utf16.count else { return nil }
        self.field = field
        original = state
        expected = state
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
        guard !detached, field.read() == expected else { detached = true; return false }
        if !didWrite, next.isEmpty { return true }
        if didWrite, next == text { return true }
        // Preserve the common prefix so each new token normally appends at the caret.
        let prefix = zip(text, next).prefix { $0 == $1 }.map { $0.0 }
        let prefixText = String(prefix)
        let suffix = String(next.dropFirst(prefix.count))
        let location = original.location + prefixText.utf16.count
        let length = didWrite ? text.utf16.count - prefixText.utf16.count : original.length
        let mutable = NSMutableString(string: expected.text)
        mutable.replaceCharacters(in: NSRange(location: location, length: length), with: suffix)
        let after = StreamingFieldState(text: mutable as String,
                                       location: original.location + next.utf16.count, length: 0)
        guard field.replace(location: location, length: length, with: suffix) else {
            detached = true
            return false
        }
        // The app may publish its AX value a few milliseconds after the edit.
        expected = after
        text = next
        didWrite = true
        for attempt in 0..<10 {
            if field.read() == after { return true }
            if attempt < 9 { try? await Task.sleep(for: .milliseconds(20)) }
        }
        detached = true
        return false
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
        guard !detached, field.read() == expected else { detached = true; return false }
        let selected = (original.text as NSString).substring(with: NSRange(location: original.location, length: original.length))
        guard field.replace(location: original.location, length: text.utf16.count, with: selected) else {
            detached = true
            return false
        }
        let restored = StreamingFieldState(text: original.text,
                                            location: original.location + original.length, length: 0)
        expected = restored
        text = ""
        didWrite = false
        for attempt in 0..<10 {
            if field.read() == restored { return true }
            if attempt < 9 { try? await Task.sleep(for: .milliseconds(20)) }
        }
        detached = true
        return false
    }
}

/// Native fields use AXSelectedText. Web and Electron fields receive Unicode key
/// events so their input handlers run, without repeatedly borrowing the clipboard.
@MainActor
private final class AccessibilityStreamingField: StreamingTextField {
    private let app: FrontApp
    private let element: AXUIElement
    private let usesKeyEvents: Bool

    init?(app: FrontApp) {
        guard app.processID > 0, let element = FrontApp.focusedElement(pid: app.processID) else { return nil }
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &settable) == .success,
              settable.boolValue else { return nil }
        self.app = app
        self.element = element
        usesKeyEvents = app.isWebContent || app.prefersClipboardPaste
        if !usesKeyEvents {
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
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return StreamingFieldState(text: text, location: range.location, length: range.length)
    }

    func replace(location: Int, length: Int, with text: String) -> Bool {
        guard read() != nil else { return false }
        var range = CFRange(location: location, length: length)
        guard let value = AXValueCreate(.cfRange, &range),
              AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success else { return false }
        if !usesKeyEvents {
            return AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
        }
        guard !Inserter.modifiersAreHeld, let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        // Unicode events have a bounded payload. Character slices keep emoji intact.
        var remaining = text[...]
        repeat {
            let piece = String(remaining.prefix(8))
            remaining = remaining.dropFirst(piece.count)
            let key = text.isEmpty ? CGKeyCode(kVK_Delete) : CGKeyCode(0)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return false }
            if !piece.isEmpty {
                let units = Array(piece.utf16)
                units.withUnsafeBufferPointer { buffer in
                    down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
                    up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
                }
            }
            for event in [down, up] {
                event.flags = []
                event.setIntegerValueField(.eventSourceUserData, value: Inserter.eventMarker)
            }
            down.postToPid(app.processID)
            usleep(12_000)
            up.postToPid(app.processID)
        } while !remaining.isEmpty
        return true
    }
}
