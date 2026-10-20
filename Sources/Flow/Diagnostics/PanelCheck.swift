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
        func snapshot(_ name: String, after delay: Duration = .milliseconds(350)) async {
            try? await Task.sleep(for: delay)
            guard let window = presenter.diagnosticWindow else { return }
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), folder.appending(path: name + ".png").path]
            try? capture.run()
            capture.waitUntilExit()
            print("\(name) keyboard owner: \(String(describing: NSWorkspace.shared.frontmostApplication?.processIdentifier))")
        }
        func findScrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { findScrollView(in: $0) }.first
        }
        func screenPoint(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - point.y)
        }
        func scrollBack(in scroll: NSScrollView, window: NSWindow) async {
            let rect = window.convertToScreen(scroll.convert(scroll.bounds, to: nil))
            for phase in [NSEvent.Phase.began, .changed, .ended] {
                let event = CGEvent(scrollWheelEvent2Source: CGEventSource(stateID: .privateState),
                                    units: .pixel, wheelCount: 1,
                                    wheel1: phase == .ended ? 0 : 180, wheel2: 0, wheel3: 0)
                event?.location = screenPoint(CGPoint(x: rect.midX, y: rect.midY))
                event?.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
                event?.post(tap: .cghidEventTap)
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
        for size in PanelSize.allCases {
            Settings.shared.panelSize = size
            await controller.previewPanelForCheck(.recording)
            for level: Float in [0.1, 0.2, 0.4, 0.6, 0.85, 0.55, 0.35, 0.15, 0.05] { controller.levels.push(level) }
            presenter.show()
            let frame = presenter.diagnosticWindow?.frame
            print("\(size.rawValue) initial frame: \(String(describing: frame))")
            await snapshot(size.rawValue + "-waveform")
            await controller.previewPanelForCheck(.processing, toField: true)
            for step in 1...5 {
                await controller.previewPanelForCheck(.processing, text: String(repeating: "Streaming into the field. ", count: step),
                                                      toField: true)
            }
            report[size.rawValue + "NoPillWhileFieldStreams"] = !controller.showsStreamingPreview
                && presenter.diagnosticPreview?.isVisible == false
            await snapshot(size.rawValue + "-field-progress")
            await controller.previewPanelForCheck(.processing, text: "A short reply.")
            await snapshot(size.rawValue + "-short-preview")
            if let preview = presenter.diagnosticPreview {
                report[size.rawValue + "ShortPreviewFitsContent"] = preview.isVisible
                    && preview.viewportHeight < 40
                    && StreamingPreviewState.contentWidth(for: preview.displayedText) < 292
            }
            for step in 1...20 {
                await controller.previewPanelForCheck(.processing, text: String(repeating: "A calm live preview with the complete response. ", count: step))
                try? await Task.sleep(for: .milliseconds(30))
            }
            let longText = String(repeating: "The preview keeps earlier lines so you can scroll back and read them. ", count: 30)
            await controller.previewPanelForCheck(.processing, text: longText)
            presenter.diagnosticPreview?.update(longText, animated: false)
            await snapshot(size.rawValue + "-fallback")
            if let preview = presenter.diagnosticPreview {
                report[size.rawValue + "LongPreviewHasBoundedHeight"] = preview.contentHeight > preview.viewportHeight
                    && preview.viewportHeight <= 126 && preview.displayedText == longText
            }
            if let window = presenter.diagnosticWindow, let root = window.contentView,
               let scroll = findScrollView(in: root), let preview = presenter.diagnosticPreview {
                let bottom = scroll.contentView.bounds.minY
                await scrollBack(in: scroll, window: window)
                await snapshot(size.rawValue + "-scrolled-back")
                let readingAt = scroll.contentView.bounds.minY
                report[size.rawValue + "ScrollBackPausesFollowing"] = !preview.followsLatest && readingAt < bottom - 20
                let continued = longText + "These new words should not interrupt reading earlier lines."
                await controller.previewPanelForCheck(.processing, text: continued)
                preview.update(continued, animated: false)
                try? await Task.sleep(for: .milliseconds(300))
                report[size.rawValue + "IncomingWordsPreserveScrollPosition"] = !preview.followsLatest
                    && abs(scroll.contentView.bounds.minY - readingAt) < 3
                let rect = window.convertToScreen(scroll.convert(scroll.bounds, to: nil))
                let button = screenPoint(CGPoint(x: rect.midX, y: rect.minY - 16))
                let source = CGEventSource(stateID: .privateState)
                CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: button, mouseButton: .left)?.post(tap: .cghidEventTap)
                CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: button, mouseButton: .left)?.post(tap: .cghidEventTap)
                await snapshot(size.rawValue + "-following-latest")
                report[size.rawValue + "BackToLatestResumesFollowing"] = preview.followsLatest
                    && scroll.contentView.bounds.maxY >= scroll.documentView!.bounds.height - 20
            } else {
                report[size.rawValue + "ScrollViewAvailable"] = false
            }
            print("\(size.rawValue) fallback frame: \(String(describing: presenter.diagnosticWindow?.frame))")
            report[size.rawValue + "StableFrame"] = presenter.diagnosticWindow?.frame == frame
            await controller.previewPanelForCheck(.processing, text: "", toField: true)
            report[size.rawValue + "PreviewLatched"] = controller.showsStreamingPreview
            await controller.previewPanelForCheck(.copied("Flow panel copy check"))
            await snapshot(size.rawValue + "-copy-drawing", after: .milliseconds(120))
            await snapshot(size.rawValue + "-copy-tick", after: .milliseconds(450))
            await snapshot(size.rawValue + "-copy", after: .milliseconds(700))
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
            await controller.previewPanelForCheck(.processing, toField: true)
            await controller.previewPanelForCheck(.inserted("The completed response"))
            await snapshot(size.rawValue + "-tick-drawing", after: .milliseconds(120))
            await snapshot(size.rawValue + "-tick", after: .milliseconds(500))
            report[size.rawValue + "CompletionFrameStable"] = presenter.diagnosticWindow?.frame == frame
            await controller.previewPanelForCheck(.idle)
            let burst = "A complete response arriving in one chunk still appears word by word before the bubble closes."
            await controller.previewPanelForCheck(.processing, text: burst)
            await controller.previewPanelForCheck(.inserted(burst))
            if let preview = presenter.diagnosticPreview {
                report[size.rawValue + "SingleChunkStillRevealsWords"] = preview.isVisible && preview.displayedText != burst
                await snapshot(size.rawValue + "-single-chunk", after: .milliseconds(80))
                try? await Task.sleep(for: .milliseconds(750))
                report[size.rawValue + "SingleChunkFinishesBeforeDismissal"] = !preview.isVisible && preview.displayedText == burst
            }
            presenter.hide()
            try? await Task.sleep(for: .milliseconds(500))
            report[size.rawValue + "SurvivesPanelDismissal"] = !presenter.isVisible
            // Reopen and dismiss again. Previously the process exited before this ran.
            await controller.previewPanelForCheck(.recording)
            presenter.show()
            await snapshot(size.rawValue + "-recording-pill")
            presenter.hide()
            try? await Task.sleep(for: .milliseconds(500))
            report[size.rawValue + "SurvivesRepeatedDismissal"] = !presenter.isVisible
        }
    }
}
