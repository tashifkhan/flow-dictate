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
    /// The process that owns the focused field, for its own Paste menu command. Zero
    /// when unknown.
    var processID: pid_t = 0
    /// The focused field sits inside web content, where only a real paste reaches the
    /// page's editor.
    var isWebContent: Bool = false

    /// Zed's custom editor needs clipboard paste when AX cannot expose its cursor.
    var prefersClipboardPaste: Bool { isElectron || Self.isZed(bundleID) }

    static func isZed(_ bundleID: String) -> Bool {
        ["dev.zed.Zed", "dev.zed.Zed-Preview", "dev.zed.Zed-Nightly"].contains(bundleID)
    }

    /// Whether Flow should type here or leave the text on the clipboard.
    ///
    /// Zed draws its editor on the GPU and exposes no text element at all: with the
    /// cursor in a buffer, Accessibility reports the focused element as the window
    /// itself (AXWindow, no selected-text range), and asking for a fuller tree through
    /// AXManualAccessibility or AXEnhancedUserInterface is refused. Judged by roles
    /// alone, Zed never has a text field, so its paste path never ran. A Zed window
    /// with focus is treated as its editor. Other apps still need a real editable field,
    /// so a Finder window keeps getting the clipboard.
    static func acceptsText(bundleID: String, focusedRole: String?, fieldIsEditable: Bool) -> Bool {
        if fieldIsEditable { return true }
        guard isZed(bundleID) else { return false }
        return focusedRole == nil || focusedRole == (kAXWindowRole as String)
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

    /// Electron processes already asked to build their accessibility tree.
    @MainActor private static var accessibleProcesses: Set<pid_t> = []

    /// Sets `AXManualAccessibility` on a Chromium-backed process, once per process. This
    /// is the switch VoiceOver-style clients use; without it Electron exposes no text
    /// fields. Returns true only when this call turned it on.
    @MainActor @discardableResult
    static func enableAccessibilityTree(pid: pid_t) -> Bool {
        guard !accessibleProcesses.contains(pid) else { return false }
        let status = AXUIElementSetAttributeValue(
            AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue
        )
        // A refusal (no Accessibility grant yet) is retried the next time.
        guard status == .success else { return false }
        accessibleProcesses.insert(pid)
        return true
    }

    /// Called as apps come to the front, so an Electron app's tree is already built by
    /// the time you dictate into it.
    @MainActor
    static func prepareAccessibility(for app: NSRunningApplication) {
        guard Permissions.hasAccessibility, let bundleID = app.bundleIdentifier,
              detectElectron(app, bundleID: bundleID) else { return }
        enableAccessibilityTree(pid: app.processIdentifier)
    }

    @MainActor
    static func current() -> FrontApp {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return .unknown }
        let app = keyboardOwner(frontmost: frontmost)
        let name = app.localizedName ?? "another app"
        let bundleID = app.bundleIdentifier ?? ""

        let electron = detectElectron(app, bundleID: bundleID)

        guard Permissions.hasAccessibility else {
            let inferred = inferContext(appName: name, bundleID: bundleID)
            return FrontApp(name: name, bundleID: bundleID, axRole: "text",
                            destinationName: inferred.destinationName,
                            writingContext: inferred.context,
                            isSecure: false, hasTextTarget: false,
                            isElectron: electron, processID: app.processIdentifier)
        }

        // Chromium builds its accessibility tree only after a client asks for it. Until
        // then an Electron app reports no focused element at all, and Flow would copy
        // instead of pasting. Ask, then give the tree a moment to appear.
        var element = focusedElement(pid: app.processIdentifier)
        if element == nil, electron {
            enableAccessibilityTree(pid: app.processIdentifier)
            for _ in 0..<6 where element == nil {
                usleep(50_000)
                element = focusedElement(pid: app.processIdentifier)
            }
        }
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
            || element.map(isProtectedContent) == true
        let editable = acceptsText(
            bundleID: bundleID,
            focusedRole: element == nil ? nil : role,
            fieldIsEditable: element.map { isEditable($0, role: role) } ?? false
        )

        let web = editable && element.map(isInsideWebArea) == true

        return FrontApp(name: name, bundleID: bundleID, axRole: friendly(role),
                        destinationName: inferred.destinationName,
                        writingContext: inferred.context, isSecure: secure,
                        hasTextTarget: editable, isElectron: electron,
                        processID: app.processIdentifier, isWebContent: web)
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
        // System-wide focus names the keyboard's actual recipient. An app's own
        // AXFocusedUIElement can describe a stale responder, so it is only the fallback.
        if let focus = systemFocus(), focus.appPID == pid, let element = focus.element { return element }
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

    /// The application and element macOS routes keystrokes to. The application comes from
    /// AXFocusedApplication, not the element's pid: web content can live in a helper
    /// process such as Safari's WebContent.
    static func systemFocus() -> (appPID: pid_t, element: AXUIElement?)? {
        let system = AXUIElementCreateSystemWide()
        var appValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &appValue) == .success,
              let appValue, CFGetTypeID(appValue) == AXUIElementGetTypeID() else { return nil }
        var appPID: pid_t = 0
        guard AXUIElementGetPid(unsafeDowncast(appValue, to: AXUIElement.self), &appPID) == .success,
              appPID > 0 else { return nil }
        var elementValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &elementValue) == .success,
              let elementValue, CFGetTypeID(elementValue) == AXUIElementGetTypeID() else {
            return (appPID, nil)
        }
        return (appPID, unsafeDowncast(elementValue, to: AXUIElement.self))
    }

    /// The app receiving keystrokes. Usually the frontmost app, but a launcher's floating
    /// panel owns keyboard focus without ever becoming frontmost. Flow's own windows are
    /// ignored, so the menu bar popover never steals a re-insert.
    @MainActor
    private static func keyboardOwner(frontmost: NSRunningApplication) -> NSRunningApplication {
        guard Permissions.hasAccessibility, let focus = systemFocus(),
              focus.appPID != frontmost.processIdentifier,
              focus.appPID != ProcessInfo.processInfo.processIdentifier,
              let owner = NSRunningApplication(processIdentifier: focus.appPID),
              !owner.isTerminated, owner.activationPolicy != .prohibited
        else { return frontmost }
        return owner
    }

    /// Password managers and some banking fields mark protected content without using
    /// the secure-text subrole.
    private static func isProtectedContent(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, "AXProtectedContent" as CFString, &value) == .success
            && (value as? Bool) == true
    }

    /// True when the field lives inside a web page. Web editors (React inputs,
    /// ProseMirror, Lexical) need a real paste: a direct AX write can change the DOM
    /// without the page's input handlers ever hearing about it.
    private static func isInsideWebArea(_ element: AXUIElement) -> Bool {
        var current = element
        for _ in 0..<12 {
            if string(current, kAXRoleAttribute) == "AXWebArea" { return true }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            current = unsafeDowncast(parent, to: AXUIElement.self)
        }
        return false
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
