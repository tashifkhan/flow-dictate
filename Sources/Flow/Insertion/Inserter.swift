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
    private static let clipboardRestoreDelay: Duration = .milliseconds(250)

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
            let target = decision.target ?? lastInsert ?? ""
            guard !target.isEmpty else { throw InsertError.empty }
            try backspace(count: target.count)
            lastInsert = nil
            return ""

        case .replace:
            let target = decision.target ?? lastInsert ?? ""
            guard !target.isEmpty else {
                try insert(decision.text, in: app)
                lastInsert = decision.text
                return decision.text
            }
            try backspace(count: target.count)
            try insert(decision.text, in: app)
            lastInsert = decision.text
            return decision.text
        }
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

        let result = AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, text as CFString
        )
        if result != .success {
            log.debug("AX insert unsupported here (\(result.rawValue)), falling back to paste")
        }
        return result == .success
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
