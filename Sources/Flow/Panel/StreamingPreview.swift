import AppKit
import Observation
import SwiftUI

/// Reveals whole words without changing the model's text or discarding earlier lines.
struct StreamingPreviewBuffer {
    private(set) var displayedText = ""
    private var target = ""

    var isCaughtUp: Bool { displayedText == target }
    var pendingWords: Int { target.dropFirst(displayedText.count).split(whereSeparator: \.isWhitespace).count }

    mutating func enqueue(_ text: String) {
        // Providers clear their draft between attempts. Keep the last readable preview.
        guard !text.isEmpty else { return }
        target = text
        if !target.hasPrefix(displayedText) {
            let common = String(zip(displayedText, target).prefix { $0 == $1 }.map(\.0))
            displayedText = common.lastIndex(where: \.isWhitespace).map { String(common[...$0]) } ?? ""
        }
    }

    mutating func advance(words: Int = 1) {
        var end = target.index(target.startIndex, offsetBy: displayedText.count)
        for _ in 0..<max(1, words) {
            while end < target.endIndex, target[end].isWhitespace { target.formIndex(after: &end) }
            while end < target.endIndex, !target[end].isWhitespace { target.formIndex(after: &end) }
            while end < target.endIndex, target[end].isWhitespace { target.formIndex(after: &end) }
        }
        displayedText = String(target[..<end])
    }

    mutating func revealAll() { displayedText = target }
}

/// Presentation only. Field insertion never waits for the word animation.
@MainActor @Observable
final class StreamingPreviewState {
    private(set) var displayedText = ""
    private(set) var isVisible = false
    var followsLatest = true
    var contentHeight: CGFloat = 19
    var viewportHeight: CGFloat { min(126, max(19, contentHeight)) }

    @ObservationIgnored private var buffer = StreamingPreviewBuffer()
    @ObservationIgnored private var revealTask: Task<Void, Never>?
    @ObservationIgnored private var finishing = false
    @ObservationIgnored private var finishWordsPerTick = 1

    func update(_ text: String, animated: Bool = true) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        finishing = false
        buffer.enqueue(text)
        if !animated { buffer.revealAll() }
        else if buffer.displayedText.isEmpty { buffer.advance() }
        displayedText = buffer.displayedText
        isVisible = true
        startRevealing()
    }

    private func startRevealing() {
        guard revealTask == nil else { return }
        revealTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(32)) } catch { return }
                guard let self else { return }
                if !self.buffer.isCaughtUp {
                    let words = self.finishing ? self.finishWordsPerTick : max(1, self.buffer.pendingWords / 50)
                    self.buffer.advance(words: words)
                    self.displayedText = self.buffer.displayedText
                } else if self.finishing {
                    do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
                    guard !Task.isCancelled else { return }
                    guard self.finishing, self.buffer.isCaughtUp else { continue }
                    self.isVisible = false
                    self.revealTask = nil
                    return
                } else {
                    self.revealTask = nil
                    return
                }
            }
        }
    }

    func finish() {
        finishing = true
        // Drain a final burst within twelve frames, before the completion tick goes away.
        finishWordsPerTick = max(1, (buffer.pendingWords + 11) / 12)
        if isVisible { startRevealing() }
    }

    func reset() {
        revealTask?.cancel()
        revealTask = nil
        buffer = StreamingPreviewBuffer()
        displayedText = ""
        isVisible = false
        finishing = false
        followsLatest = true
        contentHeight = 19
    }

    static func contentWidth(for text: String) -> CGFloat {
        let measured = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width
        return min(292, max(96, ceil(measured) + 12))
    }
}

struct StreamingPreview: View {
    @Bindable var state: StreamingPreviewState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var userScrolling = false
    @State private var atTop = true
    @State private var atBottom = true

    private var width: CGFloat { StreamingPreviewState.contentWidth(for: state.displayedText) }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(state.displayedText)
                            .font(.system(size: 13))
                            .lineSpacing(3)
                            .foregroundStyle(HUDPalette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.trailing, 12)
                            .transaction { $0.animation = nil }
                            .accessibilityAddTraits(.updatesFrequently)
                        Color.clear.frame(height: 1).id("latest")
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { _, height in
                        state.contentHeight = height
                    }
                }
                .frame(width: width, height: state.viewportHeight)
                .scrollBounceBehavior(.basedOnSize)
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .onScrollPhaseChange { _, phase in
                    userScrolling = phase == .interacting || phase == .decelerating
                }
                .onScrollGeometryChange(for: ScrollEdges.self) { geometry in
                    ScrollEdges(top: geometry.visibleRect.minY <= 2,
                                bottom: geometry.visibleRect.maxY >= geometry.contentSize.height - 12)
                } action: { _, edges in
                    atTop = edges.top
                    atBottom = edges.bottom
                    if userScrolling { state.followsLatest = edges.bottom }
                }
                .mask {
                    VStack(spacing: 0) {
                        if !atTop {
                            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                                .frame(height: 8)
                        }
                        Color.black
                        if !atBottom {
                            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                                .frame(height: 8)
                        }
                    }
                }
                if !state.followsLatest {
                    Button {
                        state.followsLatest = true
                        scrollToLatest(proxy)
                    } label: {
                        Label("Back to latest", systemImage: "arrow.down")
                            .font(.system(size: 11, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.top, 10)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(HUDPalette.accentInk)
                }
            }
            .onChange(of: state.contentHeight) { _, _ in
                if state.followsLatest { scrollToLatest(proxy) }
            }
        }
        .padding(14)
        .hudSurface(cornerRadius: 18)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: state.viewportHeight)
        .accessibilityLabel("Dictation preview")
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
            proxy.scrollTo("latest", anchor: .bottom)
        }
    }

    private struct ScrollEdges: Equatable {
        var top: Bool
        var bottom: Bool
    }
}
