import AppKit
import Charts
import SwiftUI

// Small shared pieces for the main window: formatting, cards, chips, chart chrome.

/// Display formatting for numbers people scan. `RequestDisplay` keeps exact values
/// for the request-detail grid, where the sixth decimal is the point.
enum Fmt {
    /// Enough precision to tell small numbers apart, without six decimals everywhere.
    /// `column` keeps four places below a dollar, so a column of costs lines up.
    static func money(_ value: Double?, column: Bool = false) -> String {
        guard let value else { return "Unknown" }
        if column && value < 1 { return String(format: "$%.4f", value) }
        if value == 0 { return "$0" }
        if value < 0.0001 { return "<$0.0001" }
        if value < 0.01 { return String(format: "$%.4f", value) }
        if value < 1_000 { return String(format: "$%.2f", value) }
        return "$" + Int(value.rounded()).formatted()
    }

    /// "1 call", "39 calls", "1,204 words".
    static func count(_ value: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(value.formatted()) \(value == 1 ? singular : plural ?? singular + "s")"
    }

    /// "820ms", "3.5s", "1m 12s".
    static func duration(_ seconds: Double?) -> String {
        guard let seconds else { return "n/a" }
        if seconds < 1 { return "\(Int((seconds * 1000).rounded()))ms" }
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let whole = Int(seconds.rounded())
        if whole < 3600 { return "\(whole / 60)m \(whole % 60)s" }
        return "\(whole / 3600)h \((whole % 3600) / 60)m"
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    /// "Today", "Yesterday", "Wednesday, 30 Sep", and the year once it is not this one.
    static func dayTitle(_ day: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(day, inSameDayAs: yesterday) { return "Yesterday" }
        if calendar.isDate(day, equalTo: now, toGranularity: .year) {
            return day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
        }
        return day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year())
    }
}

enum Pasteboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - App icons

/// Icons of the apps dictations landed in, looked up once per bundle ID.
@MainActor
enum AppIcons {
    private static var cache: [String: NSImage?] = [:]

    static func icon(for bundleID: String) -> NSImage? {
        if let cached = cache[bundleID] { return cached }
        let image = bundleID.isEmpty ? nil : NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[bundleID] = image
        return image
    }
}

struct AppIconView: View {
    var bundleID: String
    var size: CGFloat = 20

    var body: some View {
        Group {
            if let image = AppIcons.icon(for: bundleID) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: "app.dashed").resizable().scaledToFit()
                    .foregroundStyle(.tertiary)
                    .padding(size * 0.1)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Chips, cards, buttons

/// A small capsule label. Neutral unless it carries a state.
struct Chip: View {
    var text: String
    var systemImage: String?
    var tint: Color?

    init(_ text: String, systemImage: String? = nil, tint: Color? = nil) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage).imageScale(.small) }
            Text(text).lineLimit(1)
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
        .background(tint.map { AnyShapeStyle($0.opacity(0.15)) } ?? AnyShapeStyle(.quaternary.opacity(0.7)),
                    in: Capsule())
    }
}

/// The one card surface the window uses, with an optional header row.
struct SectionCard<Accessory: View, Content: View>: View {
    var title: String?
    var subtitle: String?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if title != nil || subtitle != nil {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        if let title { Text(title).font(.headline) }
                        if let subtitle {
                            Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    accessory
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 12))
    }
}

extension SectionCard where Accessory == EmptyView {
    init(title: String? = nil, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, accessory: { EmptyView() }, content: content)
    }
}

/// Copies, then says so for a moment.
struct CopyButton: View {
    var text: String
    var label = "Copy"
    var iconOnly = false
    @State private var copied = false

    var body: some View {
        Button {
            Pasteboard.copy(text)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            if iconOnly {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
            } else {
                Label(copied ? "Copied" : label, systemImage: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .disabled(text.isEmpty)
        .help("Copy to the clipboard")
        .accessibilityLabel(label)
    }
}

/// Long explanations live behind this instead of under every control.
struct InfoButton: View {
    var text: String
    var link: (title: String, url: URL)?
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("More about this")
        .accessibilityLabel("More information")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(text).font(.callout)
                if let link { Link(link.title, destination: link.url).font(.callout) }
            }
            .padding(14)
            .frame(width: 320, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A System Settings style icon: a white glyph on a small coloured square.
struct SettingIcon: View {
    var systemName: String
    var color: Color

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(color.gradient, in: .rect(cornerRadius: 6))
            .accessibilityHidden(true)
    }
}

/// A settings row label with its icon.
struct SettingLabel: View {
    var title: String
    var icon: String
    var color: Color

    init(_ title: String, icon: String, color: Color) {
        self.title = title
        self.icon = icon
        self.color = color
    }

    var body: some View {
        Label { Text(title) } icon: { SettingIcon(systemName: icon, color: color) }
    }
}

/// Lays children out in rows, wrapping when a row is full. For word chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row(y: current.y + current.height + spacing)
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - Stat cards

/// A headline number with how it moved against the previous period.
///
/// The value wears text ink, not a series colour: nothing here encodes a category.
struct StatCard: View {
    var title: String
    var value: String
    var unit = ""
    /// Fractional change against the previous period, nil when there is none.
    var delta: Double?
    var higherIsBetter = true
    var trend: [Double] = []
    var help: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 26, weight: .semibold))
                    .contentTransition(.numericText())
                if !unit.isEmpty {
                    Text(unit).font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            HStack(alignment: .bottom) {
                DeltaLabel(delta: delta, higherIsBetter: higherIsBetter)
                Spacer(minLength: 4)
                if trend.count > 1 && trend.contains(where: { $0 > 0 }) {
                    Sparkline(values: trend).frame(width: 64, height: 22)
                }
            }
            .frame(height: 22)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 12))
        .help(help)
        .accessibilityElement(children: .combine)
    }
}

/// Up or down, with an arrow, so the colour never carries the meaning alone.
struct DeltaLabel: View {
    var delta: Double?
    var higherIsBetter = true
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let delta {
            let flat = abs(delta) < 0.005
            let good = (delta > 0) == higherIsBetter
            HStack(spacing: 2) {
                Image(systemName: flat ? "equal" : delta > 0 ? "arrow.up.right" : "arrow.down.right")
                    .imageScale(.small)
                Text(flat ? "No change" : Fmt.percent(abs(delta)))
            }
            .font(.caption2.weight(.medium))
            .help(flat ? "About the same as the previous period"
                  : "\(delta > 0 ? "Up" : "Down") \(Fmt.percent(abs(delta))) on the previous period of the same length")
            .foregroundStyle(flat ? AnyShapeStyle(.secondary)
                             : AnyShapeStyle(good ? VizPalette.good(scheme) : VizPalette.critical))
        } else {
            Text("No earlier period").font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

struct Sparkline: View {
    var values: [Double]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Chart(Array(values.enumerated()), id: \.offset) { index, value in
            AreaMark(x: .value("Bucket", index), y: .value("Value", value))
                .foregroundStyle(VizPalette.series(0, scheme: scheme).opacity(0.12))
                .interpolationMethod(.monotone)
            LineMark(x: .value("Bucket", index), y: .value("Value", value))
                .foregroundStyle(VizPalette.series(0, scheme: scheme))
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.monotone)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .accessibilityHidden(true)
    }
}

// MARK: - Chart chrome

/// The hover readout every chart shares. The value leads; the label follows.
struct ChartTooltip: View {
    struct Row: Identifiable {
        var id: String { label }
        var color: Color?
        var label: String
        var value: String
    }

    var title: String
    var rows: [Row]
    var hint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            ForEach(rows) { row in
                HStack(spacing: 6) {
                    if let color = row.color {
                        RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 10, height: 2.5)
                    }
                    Text(row.value).font(.callout.weight(.semibold)).monospacedDigit()
                    Text(row.label).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let hint {
                Text(hint).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }
}

/// Chart chrome stays neutral gray. Hierarchical styles like `.secondary` resolve
/// against the chart's tint inside axis marks, so these are concrete colours.
enum ChartInk {
    static let grid = Color.gray.opacity(0.22)
    static let label = Color.secondary
}

extension View {
    /// Solid hairline grid and quiet labels on the value axis.
    func quietYAxis() -> some View {
        chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(ChartInk.grid)
                AxisValueLabel().foregroundStyle(ChartInk.label)
            }
        }
    }

    /// Labels only on the time axis, so vertical lines never compete with the bars.
    func quietXAxis() -> some View {
        chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                AxisValueLabel().foregroundStyle(ChartInk.label)
            }
        }
    }
}
