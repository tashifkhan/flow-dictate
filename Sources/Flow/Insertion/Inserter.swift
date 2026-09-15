import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import OSLog

/// Gets text to the cursor in whatever app has focus.
///
/// With an editable cursor there are two paths: set selected text through
/// Accessibility, or save the clipboard, paste, and restore it. With no editable
/// cursor the text stays on the clipboard for the user.
@MainActor
final class Inserter {
    static let eventMarker: Int64 = 0x464C4F57

    private let log = Logger(subsystem: "sh.taf.flow", category: "insert")

    /// What Flow last typed, so "scratch that" has something to scratch.
    private(set) var lastInsert: String?

    struct Result: Sendable {
        enum Destination: Sendable { case textField, clipboard }
        var text: String
        var destination: Destination
    }

    enum InsertError: Error, LocalizedError {
        case secureField
        case noAccessibility
        case empty
        case clipboardUnavailable
        case clipboardChanged
        var errorDescription: String? {
            switch self {
            case .clipboardUnavailable: "The clipboard could not take the dictation, so nothing was pasted."
            case .clipboardChanged: "You copied something while Flow was pasting. Your copy was kept and nothing was pasted."
            case .secureField: "Flow won't type into a password field."
            case .noAccessibility: "Flow needs Accessibility access to type. Grant it in System Settings › Privacy & Security › Accessibility."
            case .empty: "Nothing was said."
            }
        }
    }

    /// How long the real clipboard stays hostage. Long enough for the target app to
    /// service the paste, short enough that a copy in that window is a rare loss.
    ///
    /// 250 ms was too tight for Chromium-based apps, which read the pasteboard on
    /// another thread after the keystroke lands; losing that race pastes the restored
    /// clipboard instead of the dictation.
    private static let clipboardRestoreDelay: Duration = .milliseconds(600)

    /// Hardware keystrokes are not instantaneous, and some apps drop a down/up pair that
    /// arrives in the same instant.
    private static let keyEventGap: useconds_t = 12_000

    // MARK: - Entry point

    /// Applies a decision at the cursor, or keeps ordinary dictated text on the
    /// clipboard when there is no editable cursor.
    @discardableResult
    func apply(_ decision: Decision, in app: FrontApp) throws -> Result {
        guard !app.isSecure else { throw InsertError.secureField }

        if !app.hasTextTarget {
            switch decision.mode {
            case .insert, .format, .replace:
                let text = decision.text
                guard !text.isEmpty else { throw InsertError.empty }
                copy(text)
                lastInsert = nil
                return Result(text: text, destination: .clipboard)
            case .delete:
                throw InsertError.empty
            }
        }

        guard Permissions.hasAccessibility else { throw InsertError.noAccessibility }

        switch decision.mode {
        case .insert, .format:
            let text = decision.text
            guard !text.isEmpty else { throw InsertError.empty }
            try insert(text, in: app)
            lastInsert = text
            return Result(text: text, destination: .textField)

        case .delete:
            // "scratch that": take back exactly what we typed, nothing more.
            guard let target = Self.retractable(target: decision.target, lastInsert: lastInsert) else {
                throw InsertError.empty
            }
            try backspace(count: target.count)
            lastInsert = nil
            return Result(text: "", destination: .textField)

        case .replace:
            guard let target = Self.retractable(target: decision.target, lastInsert: lastInsert) else {
                // Nothing of ours to take back. Insert rather than delete: the field's
                // existing contents are the user's, not ours to remove.
                let text = decision.text
                guard !text.isEmpty else { throw InsertError.empty }
                try insert(text, in: app)
                lastInsert = text
                return Result(text: text, destination: .textField)
            }
            try backspace(count: target.count)
            try insert(decision.text, in: app)
            lastInsert = decision.text
            return Result(text: decision.text, destination: .textField)
        }
    }

    /// How much Flow is allowed to delete, which is only ever text Flow itself typed.
    ///
    /// `backspace` sends real Delete keystrokes: they take out whatever sits before the
    /// cursor, with no idea who put it there. The target comes from the cleanup model,
    /// and the model does sometimes propose one that was never inserted — a phrase from
    /// the middle of your own sentence, say. Honouring that eats the user's text.
    ///
    /// So: nothing is retractable unless Flow has something to retract, and the request
    /// has to be that text or its tail.
    static func retractable(target requested: String?, lastInsert last: String?) -> String? {
        guard let last, !last.isEmpty else { return nil }
        guard let requested, !requested.isEmpty else { return last }
        if requested == last { return requested }
        // "scratch that" aimed at the end of what we typed is still ours to take back.
        if last.hasSuffix(requested) { return requested }
        return nil
    }

    /// Re-insert a history entry at the cursor.
    func reinsert(_ text: String) throws -> Result {
        let app = FrontApp.current()
        return try apply(.raw(text), in: app)
    }

    func forgetLastInsert() { lastInsert = nil }

    // MARK: - Confirmation

    /// Where the caret was before an insert. Only positions, never the field's text.
    struct CaretSnapshot: @unchecked Sendable {
        let element: AXUIElement
        let location: Int
        let length: Int
        let characters: Int?
    }

    /// Nil when the field exposes no caret metadata. Electron and Zed are skipped: they
    /// report stale ranges often enough that a check would cry wolf.
    func caretSnapshot(for app: FrontApp) -> CaretSnapshot? {
        let pid = app.processID > 0 ? app.processID : NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        guard app.hasTextTarget, !app.prefersClipboardPaste, pid > 0,
              let element = FrontApp.focusedElement(pid: pid),
              let range = Self.selectedRange(element) else { return nil }
        return CaretSnapshot(element: element, location: range.location, length: range.length,
                             characters: Self.characterCount(element))
    }

    /// Watches for up to 700 ms for the caret or the character count to move. Metadata
    /// that stops being readable counts as delivered: that is no evidence either way.
    func confirmInsertion(since before: CaretSnapshot) async -> Bool {
        for attempt in 0..<8 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(100)) }
            guard let range = Self.selectedRange(before.element) else { return true }
            if range.location != before.location || range.length != before.length
                || Self.characterCount(before.element) != before.characters {
                return true
            }
        }
        return false
    }

    /// A backup for an insert Flow could not confirm. Runs after the paste path has
    /// already put the user's clipboard back.
    func keepOnClipboard(_ text: String) {
        guard !text.isEmpty else { return }
        copy(text)
    }

    /// A ⌘V sent while Option or Shift is still down arrives as ⌥⌘V or ⇧⌘V, which many
    /// editors bind to something else. Gives the hotkey up to 600 ms to come up, then
    /// carries on: the menu paste path does not care about held keys.
    func waitForModifierRelease() async {
        for _ in 0..<12 {
            guard Self.modifiersAreHeld else { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    static var modifiersAreHeld: Bool {
        let modifiers: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn]
        return !CGEventSource.flagsState(.hidSystemState).intersection(modifiers).isEmpty
    }

    private static func selectedRange(_ element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        // The type ID check above makes this cast safe.
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    private static func characterCount(_ element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &value) == .success
        else { return nil }
        return value as? Int
    }

    // MARK: - Paths

    private func insert(_ text: String, in app: FrontApp) throws {
        // Web pages only see a real paste; a direct write skips their input handlers.
        if Settings.shared.preferAXInsert, !app.prefersClipboardPaste, !app.isWebContent,
           setViaAccessibility(text, pid: app.processID) {
            return
        }
        try paste(text, into: app.processID)
    }

    /// The clean path. Works in Notes, Xcode, and most native apps; silently fails
    /// everywhere else, which is why it reports success as a Bool.
    private func setViaAccessibility(_ text: String, pid: pid_t) -> Bool {
        let owner = pid > 0 ? pid : NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        guard owner > 0, let element = FrontApp.focusedElement(pid: owner) else { return false }

        let result = AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, text as CFString
        )
        guard result == .success else {
            log.debug("AX insert unsupported here (\(result.rawValue)), falling back to paste")
            return false
        }

        // Some apps update AXValue asynchronously. Reading it immediately and falling
        // back when it still held the old value caused the text to land once through AX
        // and a second time through paste. Electron bypasses this path entirely.
        return true
    }

    /// An intentional copy the user keeps. Local to this Mac: a dictation should not
    /// ride Universal Clipboard to a phone.
    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.setString(text, forType: .string)
    }

    /// Save clipboard, paste, restore.
    ///
    /// The app's own Edit › Paste goes first when exactly one plain ⌘V item exists: it
    /// works on every keyboard layout and ignores modifiers still held down. The
    /// synthetic keystroke is the fallback, and only when the menu press was never sent.
    /// The old clipboard comes back only if nothing else was copied in the meantime.
    private func paste(_ text: String, into pid: pid_t) throws {
        let pasteboard = NSPasteboard.general
        let snapshot = ClipboardSnapshot(pasteboard)
        guard let owned = Self.stageTransient(text, on: pasteboard) else { throw InsertError.clipboardUnavailable }

        // Pressing our own menu over AX from the main thread would wait on itself.
        let menuPaste = pid > 0 && pid != ProcessInfo.processInfo.processIdentifier
            ? NativePasteCommand.find(for: pid)?.invoke { pasteboard.changeCount == owned }
            : nil
        switch menuPaste {
        case .dispatched?:
            log.debug("pasted through the app's Paste menu command")
        case .blocked? where pasteboard.changeCount != owned:
            throw InsertError.clipboardChanged
        case .blocked?, .unavailable?, nil:
            try synthesize(keyCode: CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
        }

        Task { [snapshot] in
            try? await Task.sleep(for: Self.clipboardRestoreDelay)
            snapshot.restore(to: NSPasteboard.general, onlyIfUnchangedSince: owned)
        }
    }

    /// Writes the dictation as a transient, this-Mac-only item and returns the pasteboard
    /// revision Flow owns. Clipboard managers skip transient items.
    private static func stageTransient(_ text: String, on pasteboard: NSPasteboard) -> Int? {
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string) else { return nil }
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let owned = pasteboard.prepareForNewContents(with: .currentHostOnly)
        guard pasteboard.writeObjects([item]), pasteboard.changeCount == owned else { return nil }
        return owned
    }

    private func backspace(count: Int) throws {
        // A long "scratch that" should not hold the keyboard hostage.
        for _ in 0..<min(count, 2000) {
            try synthesize(keyCode: CGKeyCode(kVK_Delete), flags: [])
        }
    }

    private func synthesize(keyCode: CGKeyCode, flags: CGEventFlags) throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw InsertError.noAccessibility
        }
        // Don't let our synthetic ⌘V retrigger our own event tap.
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents], state: .eventSuppressionStateSuppressionInterval
        )

        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        down?.setIntegerValueField(.eventSourceUserData, value: Self.eventMarker)
        up?.setIntegerValueField(.eventSourceUserData, value: Self.eventMarker)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        usleep(Self.keyEventGap)
        up?.post(tap: .cghidEventTap)
    }
}

/// A best-effort copy of the pasteboard, across every type it was carrying.
struct ClipboardSnapshot: Sendable {
    private let items: [[String: Data]]

    init(_ pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            var payload: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { payload[type.rawValue] = data }
            }
            return payload
        }
    }

    /// Restores only while the pasteboard is still at `expectedCount`, Flow's own write.
    /// Anything the user copied during the paste wins.
    @MainActor
    func restore(to pasteboard: NSPasteboard, onlyIfUnchangedSince expectedCount: Int) {
        guard pasteboard.changeCount == expectedCount else { return }
        restore(to: pasteboard)
    }

    @MainActor
    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { payload -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in payload {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }
        pasteboard.writeObjects(restored)
    }
}
