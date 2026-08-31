import Foundation
import OSLog
import UserNotifications

/// The optional "inserted" toast.
///
/// Opt-in only, and it stays that way: the panel already tells you what landed, so a
/// notification for every dictation is noise unless you asked for it.
enum Toast {
    private static let log = Logger(subsystem: "sh.taf.flow", category: "toast")

    /// Asks for notification permission. Called when the setting is switched on, not
    /// at launch, so the prompt arrives with a reason attached.
    static func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert])
        } catch {
            log.error("notification auth failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    static func inserted(_ text: String, into app: String) {
        post(title: "Inserted into \(app)", body: String(text.prefix(120)))
    }

    static func blocked(_ reason: String) {
        post(title: "Flow didn't insert", body: reason)
    }

    private static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body

        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                log.error("toast failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
