import AppKit
import SwiftUI

/// A panel that never takes focus.
///
/// `.nonactivatingPanel` is the whole point: the target app keeps key focus, so the
/// cursor stays put and the paste lands where you are looking.
final class FloatingPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        animationBehavior = .utilityWindow
    }

    /// Without this a borderless panel refuses key events, and Escape stops working.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns the panel window and decides where it sits.
@MainActor
final class PanelPresenter {
    private var panel: FloatingPanel?
    private let controller: DictationController

    private static let size = CGSize(width: 380, height: 128)

    init(controller: DictationController) {
        self.controller = controller
    }

    func show() {
        let panel = panel ?? make()
        self.panel = panel
        position(panel)
        // orderFrontRegardless, not makeKeyAndOrderFront: the whole point is not to
        // disturb whoever has focus.
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func toggle() {
        if panel?.isVisible == true { hide() } else { show() }
    }

    var isVisible: Bool { panel?.isVisible == true }

    private func make() -> FloatingPanel {
        let panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: Self.size))
        let root = PanelView(controller: controller) { [weak self] in
            self?.controller.cancel()
            self?.hide()
        }
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = [.preferredContentSize]
        panel.contentView = hosting
        return panel
    }

    private func position(_ panel: FloatingPanel) {
        let size = panel.frame.size == .zero ? Self.size : panel.frame.size

        switch Settings.shared.placement {
        case .nearCursor:
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
            guard let visible = screen?.visibleFrame else { return }
            // Below the cursor, nudged so it never runs off an edge.
            var origin = CGPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height - 24)
            origin.x = min(max(origin.x, visible.minX + 12), visible.maxX - size.width - 12)
            origin.y = min(max(origin.y, visible.minY + 12), visible.maxY - size.height - 12)
            panel.setFrameOrigin(origin)

        case .bottomCenter:
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
            guard let visible = screen?.visibleFrame else { return }
            panel.setFrameOrigin(CGPoint(
                x: visible.midX - size.width / 2,
                y: visible.minY + 96
            ))
        }
    }
}
