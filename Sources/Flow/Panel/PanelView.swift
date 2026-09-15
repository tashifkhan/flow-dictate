import SwiftUI

/// Bumped on every show, so the HUD replays its entrance even when a new dictation
/// interrupts the last result.
@MainActor @Observable
final class PanelPresentation {
    var id = UUID()
}

/// The floating panel's contents.
///
/// Compact is Sotto's dictation HUD without the logo: a 44 pt glass circle that widens
/// into a 160 pt capsule holding the waveform, the clock, and a cancel button while the
/// mic is live. Standard keeps the transcript under the waveform.
struct PanelView: View {
    static let hudWidth: CGFloat = 160
    static let hudHeight: CGFloat = 44
    static let noticeHeight: CGFloat = 30
    /// Room around the capsule for the glass edge, so the window never clips it.
    static let hudInset: CGFloat = 18
    /// Errors need words, so they get a wider pill than the capsule.
    static let failureWidth: CGFloat = 236
    static let morphDuration = 0.18

    @Bindable var controller: DictationController
    var presentation: PanelPresentation
    var onCancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var entered = false
    @State private var expanded = false

    private var isCompact: Bool { Settings.shared.panelSize == .compact }

    private var isCapturing: Bool {
        switch controller.phase {
        case .preparing, .recording: true
        default: false
        }
    }

    var body: some View {
        Group {
            if isCompact { hud } else { standard }
        }
        .onExitCommand(perform: onCancel)
    }

    // MARK: - Compact HUD

    private var hud: some View {
        VStack(spacing: 0) {
            ZStack {
                if case .failed(let message) = controller.phase {
                    failurePill(message)
                } else {
                    capsule
                }
            }
            .frame(minHeight: Self.hudHeight)
            limitNote
                .frame(height: Self.noticeHeight)
        }
        .scaleEffect(entered ? 1 : 0.25, anchor: .top)
        .opacity(entered ? 1 : 0)
        .padding(.top, Self.hudInset)
        // The window stays one size and the capsule morphs inside it, so the panel never
        // drifts sideways while its width animates.
        .frame(width: PanelSize.compact.frame.width, height: PanelSize.compact.frame.height, alignment: .top)
        .task(id: presentation.id) { await enter() }
        .onChange(of: isCapturing) { _, capturing in
            withAnimation(morphAnimation) { expanded = capturing }
        }
    }

    private var morphAnimation: Animation? {
        reduceMotion ? nil : .spring(duration: Self.morphDuration, bounce: 0.08)
    }

    private func enter() async {
        var reset = Transaction(animation: nil)
        reset.disablesAnimations = true
        withTransaction(reset) {
            entered = false
            expanded = false
        }
        if reduceMotion {
            entered = true
            expanded = isCapturing
            return
        }
        await Task.yield()
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.06)) { entered = true }
        // Only the visual waits. The microphone is already open.
        do { try await Task.sleep(for: .milliseconds(60)) } catch { return }
        withAnimation(morphAnimation) { expanded = isCapturing }
    }

    private var capsule: some View {
        ZStack {
            expandedContent
                .frame(width: Self.hudWidth, height: Self.hudHeight)
                .opacity(expanded ? 1 : 0)
                .allowsHitTesting(expanded)
                .accessibilityHidden(!expanded)
            Button(action: onCancel) {
                compactIcon
                    .frame(width: Self.hudHeight, height: Self.hudHeight)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .opacity(expanded ? 0 : 1)
            .allowsHitTesting(!expanded)
            .accessibilityHidden(expanded)
            .accessibilityLabel(controller.phase.isBusy ? "Cancel dictation" : statusLabel)
            .accessibilityHint(controller.phase.isBusy ? "Cancel this dictation" : "Dismiss status")
        }
        .frame(width: expanded ? Self.hudWidth : Self.hudHeight, height: Self.hudHeight)
        .clipped()
        .hudSurface(cornerRadius: Self.hudHeight / 2)
        .help(controller.listHint.map { "\(statusLabel) · \($0)" } ?? statusLabel)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Flow dictation")
        .accessibilityValue(statusLabel)
    }

    private var expandedContent: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                if controller.phase == .recording {
                    Waveform(levels: controller.levels.bars, height: 23)
                    ElapsedTime(startedAt: controller.recordingStartedAt)
                } else {
                    Text(startingLabel)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(HUDPalette.muted)

            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Cancel dictation (Escape)")
            .accessibilityLabel("Cancel dictation")
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private var compactIcon: some View {
        switch controller.phase {
        case .idle, .preparing, .recording:
            Image(systemName: "mic")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(HUDPalette.muted)
        case .processing:
            ProgressView().controlSize(.small)
        case .inserted, .copied, .tested, .listUpdated, .unconfirmed, .failed:
            Image(systemName: resultSymbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(controller.phase.needsAttention ? HUDPalette.warning : HUDPalette.accentInk)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
        }
    }

    /// Only the whole-second countdown and the stop reason, never the meter.
    private var limitNote: some View {
        Text(controller.limitNotice ?? "Recording limit in 0:30")
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(HUDPalette.ink)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
            .opacity(controller.limitNotice == nil ? 0 : 1)
            .accessibilityHidden(controller.limitNotice == nil)
            .accessibilityLabel(controller.limitNotice ?? "")
    }

    private func failurePill(_ message: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(HUDPalette.warning)
            Text(message)
                .font(.caption)
                .foregroundStyle(HUDPalette.ink)
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(width: Self.failureWidth)
        .frame(minHeight: Self.hudHeight)
        .hudSurface(cornerRadius: 16)
        .help(message)
    }

    private var startingLabel: String {
        if case .preparing(let fraction?) = controller.phase {
            return "Downloading \(Int(fraction * 100))%"
        }
        return "Starting"
    }

    private var resultSymbol: String {
        switch controller.phase {
        case .copied: "doc.on.clipboard"
        case .tested: "waveform"
        case .listUpdated: "list.number"
        case .unconfirmed: "questionmark"
        case .failed: "exclamationmark"
        default: "checkmark"
        }
    }

    private var statusLabel: String {
        switch controller.phase {
        case .idle: "Ready"
        case .preparing: "Starting microphone"
        case .recording: "Listening"
        case .processing: "Processing"
        case .inserted: "Pasted at your cursor"
        case .copied: "Copied to clipboard"
        case .tested: "Microphone test complete"
        case .listUpdated: "List updated"
        case .unconfirmed: "Check insertion. Also copied to clipboard"
        case .failed(let message): message
        }
    }

    // MARK: - Standard

    private var standard: some View {
        HStack(spacing: 14) {
            glyph
            content
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(width: PanelSize.standard.frame.width, alignment: .leading)
        .hudSurface(cornerRadius: 22)
        .animation(.smooth(duration: 0.22), value: controller.phase)
    }

    @ViewBuilder
    private var glyph: some View {
        ZStack {
            switch controller.phase {
            case .idle:
                Image(systemName: "waveform")
                    .foregroundStyle(.secondary)
            case .preparing(let fraction):
                if let fraction {
                    ProgressView(value: fraction).progressViewStyle(.circular).controlSize(.small)
                } else {
                    ProgressView().progressViewStyle(.circular).controlSize(.small)
                }
            case .recording:
                Circle()
                    .fill(.red)
                    .frame(width: 10, height: 10)
                    .shadow(color: .red.opacity(0.6), radius: 4)
            case .processing:
                ProgressView().progressViewStyle(.circular).controlSize(.small)
            case .inserted:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .copied:
                Image(systemName: "doc.on.clipboard.fill")
                    .foregroundStyle(.green)
            case .tested:
                Image(systemName: "waveform")
                    .foregroundStyle(HUDPalette.accentInk)
            case .listUpdated:
                Image(systemName: "list.number")
                    .foregroundStyle(.green)
            case .unconfirmed:
                Image(systemName: "questionmark.circle.fill")
                    .foregroundStyle(.orange)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .font(.system(size: 15, weight: .medium))
        .frame(width: 20, height: 20)
    }

    @ViewBuilder
    private var content: some View {
        switch controller.phase {
        case .idle:
            VStack(alignment: .leading, spacing: 2) {
                Text("Hold \(Settings.shared.hotkey.label) to talk")
                    .font(.callout)
                if !controller.cleanupAvailability.isAvailable {
                    Text(controller.cleanupAvailability.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

        case .preparing(let fraction):
            VStack(alignment: .leading, spacing: 2) {
                Text("Getting the speech model ready")
                    .font(.callout)
                Text(fraction.map { "\(Int($0 * 100))% downloaded" } ?? "One time, on this locale")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

        case .recording:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Waveform(levels: controller.levels.bars, height: 26)
                    ElapsedTime(startedAt: controller.recordingStartedAt)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(HUDPalette.muted)
                    if let notice = controller.limitNotice ?? controller.listHint {
                        Text(notice)
                            .font(.caption)
                            .foregroundStyle(controller.limitNotice == nil ? .secondary : Color.orange)
                            .lineLimit(1)
                    }
                }
                transcriptLine(placeholder: "Listening…")
            }

        case .processing:
            VStack(alignment: .leading, spacing: 8) {
                Waveform(levels: controller.levels.bars, tint: HUDPalette.muted.opacity(0.4), height: 26)
                transcriptLine(placeholder: controller.limitNotice ?? "Cleaning up…")
            }

        case .inserted(let text):
            result("Inserted", text)

        case .copied(let text):
            result("Copied to clipboard", text)

        case .tested(let text):
            result("Microphone test. Nothing was inserted", text.isEmpty ? "Nothing was heard." : text)

        case .listUpdated:
            Text("List updated. Nothing was typed.")
                .font(.callout)

        case .unconfirmed(let text):
            result("Check insertion. It is also on the clipboard", text)

        case .failed(let message):
            Text(message)
                .font(.callout)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func result(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .lineLimit(2)
        }
    }

    private func transcriptLine(placeholder: String) -> some View {
        Text(controller.transcript.isEmpty ? placeholder : controller.transcript)
            .font(.callout)
            .foregroundStyle(controller.transcript.isEmpty ? .secondary : .primary)
            .lineLimit(2)
            .truncationMode(.head)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.none, value: controller.transcript)
    }
}

/// The recording clock. Redraws once a second, not at the meter's twenty samples a second.
private struct ElapsedTime: View {
    var startedAt: Date?

    var body: some View {
        let start = startedAt ?? .now
        TimelineView(.periodic(from: start, by: 1)) { context in
            let seconds = context.date.timeIntervalSince(start)
            Text(hudDuration(seconds))
                .monospacedDigit()
                .frame(minWidth: 34, alignment: .trailing)
                .accessibilityLabel("Recording time")
                .accessibilityValue(hudDuration(seconds))
        }
    }
}
