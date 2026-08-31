import AppKit
import ApplicationServices
import Foundation

/// Who has focus, and what kind of field the cursor is sitting in.
///
/// The cleanup pass is told both. Dictating into Slack should stay casual; dictating
/// into a code editor should keep the terms intact.
struct FrontApp: Sendable {
    var name: String
    var bundleID: String
    var axRole: String
    /// True when the focused element is a password field. Nothing is ever inserted here.
    var isSecure: Bool

    static let unknown = FrontApp(name: "another app", bundleID: "", axRole: "text", isSecure: false)

    /// Electron apps report AX support ranging from fine to fiction, which is why the
    /// paste path is the default for them.
    ///
    /// Decided in `current()` rather than here: a hardcoded allowlist silently mistreats
    /// every Electron app nobody thought to add, and the failure is invisible — Electron
    /// answers "success" to an Accessibility write and then does nothing with it.
    var isElectron: Bool = false

    /// The frameworks that mark a Chromium-backed app. Asking the bundle is the whole
    /// test — there is no list of app names to keep up to date, and an app Flow has
    /// never heard of is handled the same as one it has.
    private static let chromiumFrameworks = [
        "Electron Framework.framework",
        "Chromium Embedded Framework.framework",
    ]

    /// Cached per bundle id: an app does not stop being Electron while it runs, and this
    /// is on the path of every dictation.
    @MainActor private static var electronCache: [String: Bool] = [:]

    @MainActor
    private static func detectElectron(_ app: NSRunningApplication, bundleID: String) -> Bool {
        if let cached = electronCache[bundleID], !bundleID.isEmpty { return cached }

        var found = false
        if let frameworks = app.bundleURL?.appending(path: "Contents/Frameworks") {
            let fm = FileManager.default
            found = chromiumFrameworks.contains {
                fm.fileExists(atPath: frameworks.appending(path: $0).path(percentEncoded: false))
            }
        }
        if !bundleID.isEmpty { electronCache[bundleID] = found }
        return found
    }

    @MainActor
    static func current() -> FrontApp {
        guard let app = NSWorkspace.shared.frontmostApplication else { return .unknown }
        let name = app.localizedName ?? "another app"
        let bundleID = app.bundleIdentifier ?? ""

        let electron = detectElectron(app, bundleID: bundleID)

        guard Permissions.hasAccessibility else {
            return FrontApp(name: name, bundleID: bundleID, axRole: "text",
                            isSecure: false, isElectron: electron)
        }

        let element = focusedElement(pid: app.processIdentifier)
        let role = element.flatMap { string($0, kAXRoleAttribute) } ?? "text"
        let subrole = element.flatMap { string($0, kAXSubroleAttribute) }

        // AXSecureTextField is the password case. A dictation app that pastes your
        // grocery list into a password prompt is a one-star review generator.
        let secure = subrole == (kAXSecureTextFieldSubrole as String)
            || role == (kAXSecureTextFieldSubrole as String)

        return FrontApp(name: name, bundleID: bundleID, axRole: friendly(role),
                        isSecure: secure, isElectron: electron)
    }

    static func focusedElement(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value else { return nil }
        return (value as! AXUIElement)
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let text = value as? String else { return nil }
        return text
    }

    private static func friendly(_ role: String) -> String {
        switch role {
        case kAXTextFieldRole: "single-line text"
        case kAXTextAreaRole: "multi-line text"
        case kAXComboBoxRole: "combo box"
        case kAXSearchFieldSubrole: "search"
        default: "text"
        }
    }
}
