import AppKit
import ApplicationServices

/// Explicit, reversible desktop diagnostic. Never submits a composer.
enum TargetInsertionCheck {
    @MainActor
    static func run(bundleID: String, output: String) async {
        let previous = NSWorkspace.shared.frontmostApplication
        var report: [String: Any] = ["passed": false, "bundleID": bundleID]
        defer {
            previous?.activate(options: [.activateAllWindows])
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: output), options: .atomic)
            }
            NSApp.terminate(nil)
        }
        guard Permissions.hasAccessibility,
              let target = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            report["error"] = "Target unavailable"; return
        }
        target.activate(options: [.activateAllWindows])
        try? await Task.sleep(for: .milliseconds(500))
        FrontApp.prepareAccessibility(for: target)
        await Inserter().waitForModifierRelease()
        let app = FrontApp.current()
        guard app.bundleID == bundleID, app.hasTextTarget, !app.isSecure,
              let element = FrontApp.focusedElement(pid: app.processID) else { report["error"] = "No tracked field"; return }
        guard let original = FrontApp.string(element, kAXValueAttribute),
              let stream = StreamingInsertion.capture(in: app) else { report["error"] = "No tracked field"; return }
        let recovery = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "flow-target-original-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: recovery.path, contents: Data(original.utf8),
                                              attributes: [.posixPermissions: 0o600]) else {
            report["error"] = "Could not save original draft"; return
        }
        report["recoveryFile"] = recovery.path
        report["pasteMenuAvailable"] = NativePasteCommand.find(for: app.processID) != nil
        report["isElectron"] = app.isElectron
        report["isWebContent"] = app.isWebContent
        func describe(_ label: String, success: Bool) {
            report[label] = success
            report[label + "ModifiersHeld"] = Inserter.modifiersAreHeld
            report[label + "FieldLength"] = FrontApp.string(element, kAXValueAttribute)?.utf16.count
            let current = FrontApp.focusedElement(pid: app.processID)
            report[label + "FocusedAppPID"] = FrontApp.systemFocus()?.appPID
            report[label + "CurrentRole"] = current.flatMap { FrontApp.string($0, kAXRoleAttribute) }
            var originalValue: CFTypeRef?
            report[label + "OriginalValueStatus"] = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString,
                                                                                    &originalValue).rawValue
            report[label + "FocusMatches"] = current.map { CFEqual(element, $0) } ?? false
            report[label + "CurrentFieldLength"] = current.flatMap { FrontApp.string($0, kAXValueAttribute)?.utf16.count }
            report[label + "OriginalWasEmpty"] = original.isEmpty
            report[label + "OriginalWasNewline"] = original == "\n"
            var characters: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &characters) == .success {
                report[label + "CharacterCount"] = characters as? Int
            }
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
               let value, CFGetTypeID(value) == AXValueGetTypeID() {
                var range = CFRange()
                if AXValueGetValue(value as! AXValue, .cfRange, &range) {
                    report[label + "Caret"] = range.location
                    report[label + "Selection"] = range.length
                }
            }
        }
        describe("before", success: true)
        let first = await stream.update("Flow streaming check")
        describe("first", success: first)
        let next = await stream.update("Flow streaming check continues with the entire sentence 👩🏽‍💻")
        describe("extended", success: next)
        let final = await stream.update("Flow streaming check continues with the entire sentence 👩🏽‍💻\nand a second line.")
        describe("final", success: final)
        let reconciled = await stream.update("The complete revised answer 👩🏽‍💻\nwith a second line.")
        describe("reconciled", success: reconciled)
        let restored = await stream.rollback()
        describe("rollback", success: restored)
        report["originalTextRestored"] = FrontApp.string(element, kAXValueAttribute) == original
        report["passed"] = first && next && final && reconciled && restored && FrontApp.string(element, kAXValueAttribute) == original
        if report["originalTextRestored"] as? Bool == true { try? FileManager.default.removeItem(at: recovery) }
    }
}
