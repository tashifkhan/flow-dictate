import AppKit
import Carbon.HIToolbox

/// Replays real HUD states in its nonactivating panel. Never opens the microphone.
enum PanelCheck {
    @MainActor
    static func run(directory: String) async {
        let folder = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let controller = AppEnvironment.shared.controller
        let presenter = PanelPresenter(controller: controller)
        let originalSize = Settings.shared.panelSize
        var previous = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let clipboard = ClipboardSnapshot(.general)
        var ownedClipboard: Int?
        var report: [String: Bool] = [:]
        defer {
            Settings.shared.panelSize = originalSize
            if let ownedClipboard { clipboard.restore(to: .general, onlyIfUnchangedSince: ownedClipboard) }
            report["focusPreserved"] = previous == NSWorkspace.shared.frontmostApplication?.processIdentifier
            report["passed"] = report.values.allSatisfy { $0 }
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: folder.appending(path: "results.json"), options: .atomic)
            }
            presenter.hide()
            NSApp.terminate(nil)
        }
        NSApp.setActivationPolicy(.accessory)
        try? await Task.sleep(for: .milliseconds(200))
        previous = NSWorkspace.shared.frontmostApplication?.processIdentifier
        print("Initial keyboard owner: \(String(describing: previous))")
        func snapshot(_ name: String) async {
            try? await Task.sleep(for: .milliseconds(350))
            guard let window = presenter.diagnosticWindow else { return }
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), folder.appending(path: name + ".png").path]
            try? capture.run()
            capture.waitUntilExit()
            print("\(name) keyboard owner: \(String(describing: NSWorkspace.shared.frontmostApplication?.processIdentifier))")
        }
        for size in PanelSize.allCases {
            Settings.shared.panelSize = size
            await controller.previewPanelForCheck(.preparing(nil))
            presenter.show()
            let frame = presenter.diagnosticWindow?.frame
            print("\(size.rawValue) initial frame: \(String(describing: frame))")
            await controller.previewPanelForCheck(.processing, toField: true)
            await snapshot(size.rawValue + "-field-progress")
            for step in 1...20 {
                await controller.previewPanelForCheck(.processing, text: String(repeating: "A calm live preview with the complete response. ", count: step))
                try? await Task.sleep(for: .milliseconds(30))
            }
            await snapshot(size.rawValue + "-fallback")
            print("\(size.rawValue) fallback frame: \(String(describing: presenter.diagnosticWindow?.frame))")
            report[size.rawValue + "StableFrame"] = presenter.diagnosticWindow?.frame == frame
            await controller.previewPanelForCheck(.processing, text: "", toField: true)
            report[size.rawValue + "PreviewLatched"] = controller.showsStreamingPreview
            await controller.previewPanelForCheck(.copied("Flow panel copy check"))
            await snapshot(size.rawValue + "-copy")
            report[size.rawValue + "PreviewCollapsed"] = !controller.showsStreamingPreview
            // Click only our own circle, while another app keeps keyboard focus.
            if let window = presenter.diagnosticWindow, let screen = NSScreen.screens.first {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("Panel clipboard sentinel", forType: .string)
                ownedClipboard = NSPasteboard.general.changeCount
                let point = CGPoint(x: window.frame.midX, y: screen.frame.maxY - (window.frame.minY + 72))
                let source = CGEventSource(stateID: .privateState)
                CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
                CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
                try? await Task.sleep(for: .milliseconds(150))
                report[size.rawValue + "CopyButton"] = NSPasteboard.general.string(forType: .string) == "Flow panel copy check"
                if report[size.rawValue + "CopyButton"] == true { ownedClipboard = NSPasteboard.general.changeCount }
            }
            await controller.previewPanelForCheck(.inserted("The completed response"))
            await snapshot(size.rawValue + "-tick")
            report[size.rawValue + "CompletionFrameStable"] = presenter.diagnosticWindow?.frame == frame
        }
    }
}
