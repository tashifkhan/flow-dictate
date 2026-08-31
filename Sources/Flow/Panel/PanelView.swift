import SwiftUI

/// The floating panel's contents. One pill, three states, plus the two failure faces.
struct PanelView: View {
    @Bindable var controller: DictationController
    var onCancel: () -> Void

    private var isCompact: Bool { Settings.shared.panelSize == .compact }

    var body: some View {
        HStack(spacing: isCompact ? 9 : 14) {
            glyph
            if isCompact { compactContent } else { content }
            if isCompact, controller.phase.isBusy { stopButton }
        }
        .padding(.horizontal, isCompact ? 12 : 18)
        .padding(.vertical, isCompact ? 9 : 14)
        .frame(width: Settings.shared.panelSize.frame.width, alignment: .leading)
        .glassPill(cornerRadius: isCompact ? 15 : 22)
        .animation(.smooth(duration: 0.22), value: controller.phase)
        .onExitCommand(perform: onCancel)
    }

    // MARK: - Stop

    /// Escape already cancels from anywhere, but only if you know that. This is the
    /// discoverable version, and the only way to stop a dictation with the mouse.
    private var stopButton: some View {
        Button(action: onCancel) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(.secondary)
                .frame(width: 17, height: 17)
                .contentShape(.circle)
                .background(.quaternary, in: .circle)
        }
        .buttonStyle(.plain)
        .help("Stop and discard (Escape)")
    }

    // MARK: - Compact body
    //
    // One line, no wrapping, no transcript: the compact panel is a status light, not a
    // reading surface. Anything that needs words is in the history window afterwards.

    @ViewBuilder
    private var compactContent: some View {
        switch controller.phase {
        case .idle:
            Text("Hold \(Settings.shared.hotkey.label)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .preparing:
            Text("Preparing model")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .recording:
            Waveform(levels: controller.levels.bars, isLive: true)
                .frame(height: 16)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .processing:
            Waveform(levels: controller.levels.bars, isLive: false)
                .frame(height: 16)
                .redacted(reason: .placeholder)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .inserted:
            Text("Inserted")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .failed(let message):
            Text(message)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Left glyph

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
                    .frame(width: isCompact ? 8 : 10, height: isCompact ? 8 : 10)
                    .shadow(color: .red.opacity(0.6), radius: 4)
            case .processing:
                ProgressView().progressViewStyle(.circular).controlSize(.small)
            case .inserted:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .font(.system(size: isCompact ? 12 : 15, weight: .medium))
        .frame(width: isCompact ? 14 : 20, height: isCompact ? 14 : 20)
    }

    // MARK: - Body

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
                Waveform(levels: controller.levels.bars, isLive: true)
                    .frame(height: 26)
                transcriptLine(placeholder: "Listening…")
            }

        case .processing:
            VStack(alignment: .leading, spacing: 8) {
                Waveform(levels: controller.levels.bars, isLive: false)
                    .frame(height: 26)
                    .redacted(reason: .placeholder)
                transcriptLine(placeholder: "Cleaning up…")
            }

        case .inserted(let text):
            VStack(alignment: .leading, spacing: 2) {
                Text("Inserted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(text)
                    .font(.callout)
                    .lineLimit(2)
            }

        case .failed(let message):
            Text(message)
                .font(.callout)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
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

private extension View {
    /// The new Siri look on macOS 26. Do not hand-roll blur shaders, life is short.
    func glassPill(cornerRadius: CGFloat) -> some View {
        modifier(GlassPill(cornerRadius: cornerRadius))
    }
}

private struct GlassPill: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
            .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
    }
}
