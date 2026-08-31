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
    var isElectron: Bool {
        let known = ["com.tinyspeck.slackmacgap", "com.microsoft.VSCode", "com.hnc.Discord",
                     "notion.id", "com.figma.Desktop", "com.spotify.client", "md.obsidian"]
        return known.contains(bundleID)
    }

    @MainActor
    static func current() -> FrontApp {
        guard let app = NSWorkspace.shared.frontmostApplication else { return .unknown }
        let name = app.localizedName ?? "another app"
        let bundleID = app.bundleIdentifier ?? ""

        guard Permissions.hasAccessibility else {
            return FrontApp(name: name, bundleID: bundleID, axRole: "text", isSecure: false)
        }

        let element = focusedElement(pid: app.processIdentifier)
        let role = element.flatMap { string($0, kAXRoleAttribute) } ?? "text"
        let subrole = element.flatMap { string($0, kAXSubroleAttribute) }

        // AXSecureTextField is the password case. A dictation app that pastes your
        // grocery list into a password prompt is a one-star review generator.
        let secure = subrole == (kAXSecureTextFieldSubrole as String)
            || role == (kAXSecureTextFieldSubrole as String)

        return FrontApp(name: name, bundleID: bundleID, axRole: friendly(role), isSecure: secure)
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
