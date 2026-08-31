import SwiftUI

/// The floating panel's contents. One pill, three states, plus the two failure faces.
struct PanelView: View {
    @Bindable var controller: DictationController
    var onCancel: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            glyph
            content
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(width: 380, alignment: .leading)
        .glassPill()
        .animation(.smooth(duration: 0.22), value: controller.phase)
        .onExitCommand(perform: onCancel)
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
                    .frame(width: 10, height: 10)
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
        .font(.system(size: 15, weight: .medium))
        .frame(width: 20, height: 20)
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
    func glassPill() -> some View {
        modifier(GlassPill())
    }
}

private struct GlassPill: ViewModifier {
    func body(content: Content) -> some View {
        content
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
            .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
    }
}
