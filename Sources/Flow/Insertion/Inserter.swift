import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import OSLog

/// Gets text to the cursor in whatever app has focus.
///
/// Two paths, in order of preference: set the selected text through Accessibility,
/// or save the clipboard, paste, and put the clipboard back. The paste path is the
/// one that makes Electron apps behave, so it is the fallback that always works.
@MainActor
final class Inserter {
    private let log = Logger(subsystem: "sh.taf.flow", category: "insert")

    /// What Flow last typed, so "scratch that" has something to scratch.
    private(set) var lastInsert: String?

    enum InsertError: Error, LocalizedError {
        case secureField
        case noAccessibility
        case empty
        var errorDescription: String? {
            switch self {
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

    /// Applies a decision at the cursor. Returns the text that actually landed.
    @discardableResult
    func apply(_ decision: Decision, in app: FrontApp) throws -> String {
        guard Permissions.hasAccessibility else { throw InsertError.noAccessibility }
        guard !app.isSecure else { throw InsertError.secureField }

        switch decision.mode {
        case .insert, .format:
            let text = decision.text
            guard !text.isEmpty else { throw InsertError.empty }
            try insert(text, in: app)
            lastInsert = text
            return text

        case .delete:
            // "scratch that": take back exactly what we typed, nothing more.
            guard let target = Self.retractable(target: decision.target, lastInsert: lastInsert) else {
                throw InsertError.empty
            }
            try backspace(count: target.count)
            lastInsert = nil
            return ""

        case .replace:
            guard let target = Self.retractable(target: decision.target, lastInsert: lastInsert) else {
                // Nothing of ours to take back. Insert rather than delete: the field's
                // existing contents are the user's, not ours to remove.
                let text = decision.text
                guard !text.isEmpty else { throw InsertError.empty }
                try insert(text, in: app)
                lastInsert = text
                return text
            }
            try backspace(count: target.count)
            try insert(decision.text, in: app)
            lastInsert = decision.text
            return decision.text
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
    func reinsert(_ text: String) throws {
        let app = FrontApp.current()
        try apply(.raw(text), in: app)
    }

    func forgetLastInsert() { lastInsert = nil }

    // MARK: - Paths

    private func insert(_ text: String, in app: FrontApp) throws {
        if Settings.shared.preferAXInsert, !app.isElectron, setViaAccessibility(text) {
            return
        }
        try paste(text)
    }

    /// The clean path. Works in Notes, Xcode, and most native apps; silently fails
    /// everywhere else, which is why it reports success as a Bool.
    private func setViaAccessibility(_ text: String) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let element = FrontApp.focusedElement(pid: app.processIdentifier)
        else { return false }

        // Read first, so the write can be checked rather than believed.
        let before = FrontApp.string(element, kAXValueAttribute as String)

        let result = AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, text as CFString
        )
        guard result == .success else {
            log.debug("AX insert unsupported here (\(result.rawValue)), falling back to paste")
            return false
        }

        // Electron and friends answer .success and then do nothing, which used to end the
        // insertion right here: no text, and no paste attempt either. Believe the field,
        // not the return code. When the value cannot be read at all there is nothing to
        // compare, so the success stands.
        if let before, let after = FrontApp.string(element, kAXValueAttribute as String), after == before {
            log.debug("AX insert reported success but changed nothing, falling back to paste")
            return false
        }
        return true
    }

    /// Save clipboard, paste, restore. The restore window is a few hundred ms; if you
    /// copy something in exactly that window you lose it. Acceptable, ship it.
    private func paste(_ text: String) throws {
        let pasteboard = NSPasteboard.general
        let snapshot = ClipboardSnapshot(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        try synthesize(keyCode: CGKeyCode(kVK_ANSI_V), flags: .maskCommand)

        Task { [snapshot] in
            try? await Task.sleep(for: Self.clipboardRestoreDelay)
            snapshot.restore(to: NSPasteboard.general)
        }
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
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        usleep(Self.keyEventGap)
        up?.post(tap: .cghidEventTap)
    }
}

/// A best-effort copy of the pasteboard, across every type it was carrying.
private struct ClipboardSnapshot: Sendable {
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
