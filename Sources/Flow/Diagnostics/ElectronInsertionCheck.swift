import AppKit
import ApplicationServices

enum ElectronInsertionCheck {
    @MainActor
    static func run(directory: String) async {
        let folder = URL(fileURLWithPath: directory)
        let previous = NSWorkspace.shared.frontmostApplication
        var report: [String: Any] = ["passed": false]
        let clipboard = ClipboardSnapshot(NSPasteboard.general)
        defer {
            clipboard.restore(to: .general)
            previous?.activate()
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: folder.appending(path: "results.json"), options: .atomic)
            }
            NSApp.terminate(nil)
        }
        func read(_ name: String) -> [String: Any]? {
            guard let data = try? Data(contentsOf: folder.appending(path: name)) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        guard Permissions.hasAccessibility, let ready = read("ready.json"),
              let pid = ready["pid"] as? Int32, ready["token"] as? String == folder.lastPathComponent,
              let fixture = NSRunningApplication(processIdentifier: pid),
              fixture.bundleIdentifier == "com.github.Electron" else { report["error"] = "No trusted fixture"; return }
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as CFString,
                                            &windowValue) == .success,
              let windowValue, CFGetTypeID(windowValue) == AXUIElementGetTypeID(),
              FrontApp.string(unsafeDowncast(windowValue, to: AXUIElement.self), kAXTitleAttribute)
                == "Flow Electron insertion check \(folder.lastPathComponent)" else {
            report["error"] = "Unexpected fixture window"; return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("User clipboard sentinel", forType: .string)
        var passed = true
        for (mode, menu) in [("textarea", true), ("contenteditable", true), ("textarea", false), ("contenteditable", false)] {
            let label = mode + (menu ? "Menu" : "Shortcut")
            let revision = UUID().uuidString
            let command: [String: Any] = ["revision": revision, "mode": mode, "menu": menu, "text": "Before old after"]
            try? JSONSerialization.data(withJSONObject: command).write(to: folder.appending(path: "command.json"), options: .atomic)
            fixture.activate(options: [.activateAllWindows])
            for _ in 0..<50 {
                if read("state.json")?["revision"] as? String == revision, FrontApp.systemFocus()?.appPID == pid { break }
                try? await Task.sleep(for: .milliseconds(40))
            }
            let target = FrontApp.current()
            guard target.processID == pid, target.hasTextTarget, target.isElectron,
                  let stream = StreamingInsertion.capture(in: target) else {
                report[label + "Capture"] = false; passed = false; continue
            }
            report[label + "Capture"] = true
            let menuFound = NativePasteCommand.find(for: pid) != nil
            report[label + "NativePasteAvailable"] = menuFound
            if !menu { passed = passed && !menuFound }
            let treeFocus = FrontApp.focusedTextDescendant(in: unsafeDowncast(windowValue, to: AXUIElement.self))
            let focused = FrontApp.focusedElement(pid: pid)
            let treeMatches = treeFocus.flatMap { candidate in focused.map { CFEqual(candidate, $0) } } == true
            report[label + "WindowFocusLookup"] = treeMatches
            passed = passed && treeMatches
            await Inserter().waitForModifierRelease()
            let first = await stream.update("Hello")
            let next = await stream.update("Hello 👩🏽‍💻\nworld and the entire remaining sentence")
            let finalText = "Hi 👩🏽‍💻\nworld and the entire remaining sentence!"
            let final = await stream.update(finalText)
            try? await Task.sleep(for: .milliseconds(150))
            let state = read("state.json")
            let complete = first && next && final && state?["saved"] as? String == "Before \(finalText) after"
            let events = (state?["pastes"] as? Int ?? 0) >= 3 && (state?["inputs"] as? Int ?? 0) >= 3
            report[label + "Complete"] = complete
            report[label + "PasteEvents"] = events
            report[label + "ClipboardPreserved"] = NSPasteboard.general.string(forType: .string) == "User clipboard sentinel"
            let rollback = await stream.rollback()
            try? await Task.sleep(for: .milliseconds(150))
            let restored = rollback && read("state.json")?["saved"] as? String == "Before old after"
            report[label + "Rollback"] = restored
            passed = passed && complete && events && restored && NSPasteboard.general.string(forType: .string) == "User clipboard sentinel"
        }
        report["passed"] = passed
    }
}
