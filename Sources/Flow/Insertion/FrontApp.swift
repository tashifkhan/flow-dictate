import AppKit
import ApplicationServices
import Foundation

/// The kind of writing Flow is helping with. This is deliberately small and local:
/// only a category and a recognized product name reach the cleanup model, never a
/// window title, page title, or URL.
enum WritingContext: String, Sendable {
    case chat, email, development, document, browser, general

    var description: String {
        switch self {
        case .chat: "a chat or messaging app"
        case .email: "an email composer"
        case .development: "a code editor, terminal, or developer tool"
        case .document: "a notes or document editor"
        case .browser: "a web browser"
        case .general: "a general-purpose app"
        }
    }

    /// Contextual strings bias recognition toward words the speech model often hears
    /// phonetically. Cleanup gets the same vocabulary so it can repair near misses.
    var recognitionHints: [String] {
        guard self == .development else { return [] }
        return [
            "API", "app", "async", "await", "backend", "boolean", "branch", "bug", "build",
            "changelog", "CLI", "code", "commit", "config", "CSS", "database", "debug",
            "dependency", "deploy", "dev", "Docker", "docs", "documentation", "endpoint",
            "enum", "error", "example", "file", "fix", "frontend", "function", "Git",
            "GitHub", "GraphQL", "guide", "HTML", "HTTP", "issue", "JavaScript", "JSON",
            "Kubernetes", "localhost", "log", "Markdown", "MDX", "merge", "npm", "parameter",
            "PostgreSQL", "PR", "prod", "pull request", "Python", "React", "README",
            "reference", "release", "repository", "request", "response", "runtime", "server",
            "SQL", "staging", "Swift", "terminal", "test", "TypeScript", "URL", "variable",
            "Wrangler", "YAML",
        ]
    }
}

/// Who has focus, and what kind of field the cursor is sitting in.
///
/// The cleanup pass is told both. Dictating into Slack should stay casual; dictating
/// into a code editor should keep the terms intact.
struct FrontApp: Sendable {
    var name: String
    var bundleID: String
    var axRole: String
    /// A known website inside a browser, otherwise the native application name.
    var destinationName: String
    var writingContext: WritingContext
    /// True when the focused element is a password field. Nothing is ever inserted here.
    var isSecure: Bool
    /// False when focus is on a window, button, web page, or other non-editable element.
    var hasTextTarget: Bool

    static let unknown = FrontApp(
        name: "another app", bundleID: "", axRole: "text",
        destinationName: "another app", writingContext: .general,
        isSecure: false, hasTextTarget: false
    )
    static let flowNote = FrontApp(
        name: "Flow", bundleID: "sh.taf.flow", axRole: "multi-line text",
        destinationName: "a Flow note", writingContext: .document,
        isSecure: false, hasTextTarget: true
    )

    var appDescription: String { writingContext.description }
    var recognitionHints: [String] { writingContext.recognitionHints }

    /// Electron apps report AX support ranging from fine to fiction, which is why the
    /// paste path is the default for them.
    ///
    /// Decided in `current()` rather than here: a hardcoded allowlist silently mistreats
    /// every Electron app nobody thought to add, and the failure is invisible — Electron
    /// answers "success" to an Accessibility write and then does nothing with it.
    var isElectron: Bool = false

    /// Zed's custom editor needs clipboard paste when AX cannot expose its cursor.
    var prefersClipboardPaste: Bool { isElectron || Self.isZed(bundleID) }

    static func isZed(_ bundleID: String) -> Bool {
        ["dev.zed.Zed", "dev.zed.Zed-Preview", "dev.zed.Zed-Nightly"].contains(bundleID)
    }

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
            let inferred = inferContext(appName: name, bundleID: bundleID)
            return FrontApp(name: name, bundleID: bundleID, axRole: "text",
                            destinationName: inferred.destinationName,
                            writingContext: inferred.context,
                            isSecure: false, hasTextTarget: false,
                            isElectron: electron)
        }

        let element = focusedElement(pid: app.processIdentifier)
        let role = element.flatMap { string($0, kAXRoleAttribute) } ?? "text"
        let subrole = element.flatMap { string($0, kAXSubroleAttribute) }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let window = focusedWindow(of: appElement)
        let document = element.flatMap { metadataString($0, kAXDocumentAttribute) }
            ?? element.flatMap { metadataString($0, kAXURLAttribute) }
            ?? window.flatMap { metadataString($0, kAXDocumentAttribute) }
            ?? metadataString(appElement, kAXDocumentAttribute)
        let windowTitle = window.flatMap { string($0, kAXTitleAttribute) }
        let inferred = inferContext(
            appName: name, bundleID: bundleID, document: document, windowTitle: windowTitle
        )

        // AXSecureTextField is the password case. A dictation app that pastes your
        // grocery list into a password prompt is a one-star review generator.
        let secure = subrole == (kAXSecureTextFieldSubrole as String)
            || role == (kAXSecureTextFieldSubrole as String)
        let editable = element.map { isEditable($0, role: role) } ?? false

        return FrontApp(name: name, bundleID: bundleID, axRole: friendly(role),
                        destinationName: inferred.destinationName,
                        writingContext: inferred.context, isSecure: secure,
                        hasTextTarget: editable, isElectron: electron)
    }

    /// Classifies native apps by bundle id and web apps by hostname or window title.
    /// The raw metadata is discarded after this function returns.
    static func inferContext(
        appName: String, bundleID: String, document: String? = nil, windowTitle: String? = nil
    ) -> (context: WritingContext, destinationName: String) {
        let app = "\(bundleID) \(appName)".lowercased()
        let page = "\(document ?? "") \(windowTitle ?? "")".lowercased()
        let isBrowser = containsAny(app, [
            "safari", "chrome", "chromium", "firefox", "arc", "brave", "edge", "vivaldi", "opera",
        ])

        if isBrowser {
            if let service = matchedService(in: page) {
                return (service.context, service.name)
            }
            return (.browser, appName)
        }

        if containsAny(app, [
            "slack", "messages", "whatsapp", "beeper", "discord", "telegram", "signal",
        ]) {
            return (.chat, appName)
        }
        if containsAny(app, [
            "com.apple.mail", "outlook", "mimestream", "spark", "airmail", "superhuman",
        ]) {
            return (.email, appName)
        }
        if containsAny(app, [
            "xcode", "vscode", "visual studio code", "cursor", "windsurf", "zed", "jetbrains",
            "intellij", "webstorm", "pycharm", "goland", "rubymine", "android studio",
            "terminal", "iterm", "warp", "ghostty", "kitty", "sublime text", "nova",
        ]) {
            return (.development, appName)
        }
        if containsAny(app, [
            "notes", "notion", "obsidian", "pages", "microsoft word", "bear", "craft",
        ]) {
            return (.document, appName)
        }
        return (.general, appName)
    }

    private static func matchedService(
        in page: String
    ) -> (context: WritingContext, name: String)? {
        let services: [(needles: [String], context: WritingContext, name: String)] = [
            (["mail.google.com", "gmail"], .email, "Gmail"),
            (["outlook.office.com", "outlook.live.com", "outlook mail"], .email, "Outlook"),
            (["app.slack.com", "slack"], .chat, "Slack"),
            (["web.whatsapp.com", "whatsapp"], .chat, "WhatsApp"),
            (["messages.google.com", "google messages"], .chat, "Google Messages"),
            (["discord.com", "discord"], .chat, "Discord"),
            (["beeper.com", "beeper"], .chat, "Beeper"),
            (["github.com", "github"], .development, "GitHub"),
            (["gitlab.com", "gitlab"], .development, "GitLab"),
            (["bitbucket.org", "bitbucket"], .development, "Bitbucket"),
            (["replit.com", "codesandbox.io", "stackblitz.com"], .development, "a web development tool"),
            (["localhost", "127.0.0.1"], .development, "a local development site"),
            (["docs.google.com", "google docs"], .document, "Google Docs"),
            (["notion.so", "notion"], .document, "Notion"),
        ]
        return services.first { containsAny(page, $0.needles) }.map { ($0.context, $0.name) }
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    static func focusedElement(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func focusedWindow(of app: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let text = value as? String else { return nil }
        return text
    }

    private static func isEditable(_ element: AXUIElement, role: String) -> Bool {
        if roleAcceptsText(role) { return true }

        var editableValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element, kAXIsEditableAttribute as CFString, &editableValue
        ) == .success, let editable = editableValue as? Bool, editable {
            return true
        }

        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(
            element, kAXSelectedTextAttribute as CFString, &settable
        ) == .success && settable.boolValue
    }

    static func roleAcceptsText(_ role: String) -> Bool {
        role == (kAXTextFieldRole as String)
            || role == (kAXTextAreaRole as String)
            || role == (kAXComboBoxRole as String)
    }

    private static func metadataString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value else { return nil }
        if let text = value as? String { return text }
        if let url = value as? URL { return url.absoluteString }
        return nil
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
