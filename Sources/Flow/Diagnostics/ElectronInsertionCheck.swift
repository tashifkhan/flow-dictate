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
        // A draft that already holds text, with the caret after it: the usual second dictation.
        let prefilled: [(label: String, command: [String: Any])] = [
            ("prefilledTextarea", ["mode": "textarea", "text": "Existing note.", "caretAtEnd": true]),
            ("prefilledLine", ["mode": "contenteditable", "text": "Existing line", "caretAtEnd": true]),
            ("prefilledTrailingSpace", ["mode": "contenteditable", "text": "Existing line ", "caretAtEnd": true]),
            ("prefilledParagraphs", ["mode": "contenteditable", "text": "",
                                     "html": "<p>First paragraph.</p><p>Second paragraph.</p>", "caretAtEnd": true]),
            ("prefilledBlankLine", ["mode": "contenteditable", "text": "",
                                    "html": "<p>First paragraph.</p><p><br></p><p>Third paragraph.</p>", "caretAtEnd": true]),
            ("prefilledParagraphsMultiline", ["mode": "contenteditable", "text": "", "multiline": true,
                                              "html": "<p>First paragraph.</p><p>Second paragraph.</p>", "caretAtEnd": true]),
        ]
        for (label, base) in prefilled {
            let revision = UUID().uuidString
            var command = base
            command["revision"] = revision
            command["menu"] = true
            try? JSONSerialization.data(withJSONObject: command).write(to: folder.appending(path: "command.json"), options: .atomic)
            fixture.activate(options: [.activateAllWindows])
            for _ in 0..<50 {
                if read("state.json")?["revision"] as? String == revision, FrontApp.systemFocus()?.appPID == pid { break }
                try? await Task.sleep(for: .milliseconds(40))
            }
            let before = read("state.json")?["saved"] as? String ?? ""
            let target = FrontApp.current()
            report[label + "AXBefore"] = axState(pid: pid)
            guard target.processID == pid, target.hasTextTarget, let stream = StreamingInsertion.capture(in: target) else {
                report[label + "Capture"] = false; passed = false; continue
            }
            await Inserter().waitForModifierRelease()
            let multiline = base["multiline"] as? Bool == true
            let separator = multiline ? "\n" : " "
            let clock = ContinuousClock()
            var durations: [Int] = []
            func timed(_ text: String) async -> Bool {
                let began = clock.now
                let updated = await stream.update(text)
                durations.append(Int((clock.now - began).timeInterval * 1000))
                return updated
            }
            let first = await timed("Hello")
            report[label + "AXAfterFirst"] = axState(pid: pid)
            let next = await timed("Hello\(separator)world and the rest")
            let finalText = "Hi\(separator)world and the rest!"
            let final = await timed(finalText)
            report[label + "UpdateMilliseconds"] = durations
            report[label + "AXAfterFinal"] = axState(pid: pid)
            try? await Task.sleep(for: .milliseconds(150))
            let saved = read("state.json")?["saved"] as? String
            // A pasted line break becomes a new block, which innerText spells its own way.
            let landed = multiline
                ? saved?.hasPrefix(before + "Hi") == true && saved?.hasSuffix("world and the rest!") == true
                : saved == before + finalText
            let complete = first && next && final && landed
            report[label + "Updates"] = [first, next, final]
            report[label + "Saved"] = saved
            report[label + "Complete"] = complete
            let rollback = await stream.rollback()
            try? await Task.sleep(for: .milliseconds(150))
            let restored = rollback && read("state.json")?["saved"] as? String == before
            report[label + "Rollback"] = restored
            passed = passed && complete && restored
        }
        report["passed"] = passed
    }

    @MainActor
    private static func axState(pid: pid_t) -> [String: Any] {
        guard let element = FrontApp.focusedElement(pid: pid) else { return [:] }
        var state: [String: Any] = ["value": FrontApp.string(element, kAXValueAttribute) ?? NSNull()]
        var value: CFTypeRef?
        var range = CFRange()
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
           let value, CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetValue(value as! AXValue, .cfRange, &range) {
            state["location"] = range.location
            state["length"] = range.length
        }
        return state
    }
}
