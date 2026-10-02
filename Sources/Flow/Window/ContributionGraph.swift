import SwiftUI

/// Words dictated per day, a year at a glance.
///
/// Sequential encoding: one hue, light→dark, because the value is a magnitude. Both
/// mode ramps were validated against their own surface rather than flipped from each
/// other — see `VizPalette`.
struct ContributionGraph: View {
    var stats: Stats
    var requests: [CloudRequestRecord] = []
    var metric: Metric = .words

    enum Metric: String, CaseIterable, Identifiable {
        case words = "Words", spend = "Cloud spend", calls = "Cloud calls"
        var id: String { rawValue }
    }
    /// Nil while nothing is hovered.
    @State private var hovered: Day?
    /// How far the weeks have scrolled, so the tooltip can follow its cell.
    @State private var scrollX: CGFloat = 0
    @State private var tooltipSize = CGSize(width: 180, height: 50)
    @Environment(\.colorScheme) private var scheme

    struct Day: Hashable {
        var date: Date
        var value: Double
        var unpricedCalls: Int = 0
        var level: Int
        var week = 0
        var weekday = 0
    }

    private let cell: CGFloat = 12
    private let gap: CGFloat = 3
    private let labelWidth: CGFloat = 24
    private let monthRowHeight: CGFloat = 11
    private let weeks = 53

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            grid
                .overlay(alignment: .topLeading) { tooltip }
                .zIndex(1)
            footer
        }
        .onChange(of: metric) { hovered = nil }
    }

    // MARK: - Grid

    /// Weekday labels stay put; the weeks scroll sideways when the card is narrower
    /// than a year, opening on the current week.
    private var grid: some View {
        let columns = buildColumns()
        return HStack(alignment: .top, spacing: gap) {
            weekdayLabels
                .padding(.top, monthRowHeight + 4)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 4) {
                        monthLabels(columns)
                        HStack(alignment: .top, spacing: gap) {
                            ForEach(Array(columns.enumerated()), id: \.offset) { index, week in
                                VStack(spacing: gap) {
                                    ForEach(week, id: \.self) { day in
                                        cellView(day)
                                    }
                                }
                                .id(index)
                            }
                        }
                    }
                    // Room for a month label that starts in the last column.
                    .padding(.trailing, 12)
                    .padding(.bottom, 10)
                }
                .frame(maxWidth: .infinity)
                .scrollIndicators(.visible, axes: .horizontal)
                .defaultScrollAnchor(.trailing)
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, offset in
                    scrollX = offset
                }
                .onAppear { proxy.scrollTo(columns.count - 1, anchor: .trailing) }
            }
        }
    }

    private func cellView(_ day: Day) -> some View {
        RoundedRectangle(cornerRadius: 2.5)
            .fill(VizPalette.heat(level: day.level, scheme: scheme))
            .frame(width: cell, height: cell)
            // The hit target is the cell plus its gap, so hovering is not fiddly.
            .contentShape(.rect.inset(by: -gap / 2))
            .onHover { hovering in
                hovered = hovering ? day : (hovered == day ? nil : hovered)
            }
            .overlay {
                if hovered == day {
                    RoundedRectangle(cornerRadius: 2.5)
                        .strokeBorder(.primary.opacity(0.6), lineWidth: 1)
                }
            }
            .accessibilityLabel(describe(day))
    }

    private var weekdayLabels: some View {
        VStack(alignment: .trailing, spacing: gap) {
            ForEach(0..<7, id: \.self) { row in
                Text(row % 2 == 1 ? Self.weekdaySymbols[row] : "")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .frame(width: labelWidth, height: cell, alignment: .trailing)
            }
        }
    }

    private func monthLabels(_ columns: [[Day]]) -> some View {
        HStack(alignment: .bottom, spacing: gap) {
            ForEach(Array(columns.enumerated()), id: \.offset) { index, week in
                // Label a column when its first day starts a new month. The text sits in
                // an overlay so it runs past its one-cell column instead of wrapping.
                Color.clear
                    .frame(width: cell, height: monthRowHeight)
                    .overlay(alignment: .leading) {
                        Text(monthLabel(week, at: index, in: columns))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
            }
        }
    }

    private func monthLabel(_ week: [Day], at index: Int, in columns: [[Day]]) -> String {
        guard let first = week.first else { return "" }
        let calendar = Calendar.current
        let month = calendar.component(.month, from: first.date)
        if index == 0 { return "" }
        guard let previous = columns[index - 1].first else { return "" }
        guard calendar.component(.month, from: previous.date) != month else { return "" }
        return Self.monthSymbols[month - 1]
    }

    /// Floats just under the hovered cell, kept inside the card's width.
    @ViewBuilder
    private var tooltip: some View {
        if let hovered {
            GeometryReader { geometry in
                let x = labelWidth + gap + CGFloat(hovered.week) * (cell + gap) - scrollX + cell / 2
                let y = monthRowHeight + 4 + CGFloat(hovered.weekday + 1) * (cell + gap) + 4
                let half = tooltipSize.width / 2
                ChartTooltip(title: hovered.date.formatted(.dateTime.weekday(.wide).day().month(.wide).year()),
                             rows: tooltipRows(hovered))
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { tooltipSize = $0 }
                    .position(x: min(max(x, half), max(half, geometry.size.width - half)),
                              y: y + tooltipSize.height / 2)
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    private func tooltipRows(_ day: Day) -> [ChartTooltip.Row] {
        switch metric {
        case .words:
            return [ChartTooltip.Row(label: day.value == 1 ? "word" : "words", value: Int(day.value).formatted())]
        case .calls:
            return [ChartTooltip.Row(label: day.value == 1 ? "cloud request" : "cloud requests",
                                     value: Int(day.value).formatted())]
        case .spend:
            var rows = [ChartTooltip.Row(label: "estimated spend", value: Fmt.money(day.value))]
            if day.unpricedCalls > 0 {
                rows.append(ChartTooltip.Row(label: "with unknown cost", value: Fmt.count(day.unpricedCalls, "request")))
            }
            return rows
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Text(totalDescription)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Text("Less").font(.system(size: 9)).foregroundStyle(.secondary)
            ForEach(0...4, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(VizPalette.heat(level: level, scheme: scheme))
                    .frame(width: cell, height: cell)
            }
            Text("More").font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .accessibilityHidden(true)
    }

    // MARK: - Data

    /// 53 columns of 7 days, ending on the week containing today.
    private func buildColumns() -> [[Day]] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let callsByDay = Dictionary(grouping: StatsRange.year.requests(requests), by: { calendar.startOfDay(for: $0.startedAt) })
        var values = stats.wordsByDay.mapValues(Double.init)
        if metric != .words {
            values = callsByDay.mapValues { calls in
                metric == .calls ? Double(calls.count) : CloudCostSummary(requests: calls).knownCost
            }
        }
        let positive = values.values.filter { $0 > 0 }.sorted()
        let thresholds = [0.25, 0.5, 0.75, 1.0].map { quantile in
            positive.isEmpty ? 1 : positive[Int((Double(positive.count - 1) * quantile).rounded())]
        }

        // Walk back to the most recent week boundary, then back `weeks` weeks.
        let weekday = calendar.component(.weekday, from: today) - 1
        guard let lastColumnStart = calendar.date(byAdding: .day, value: -weekday, to: today),
              let start = calendar.date(byAdding: .day, value: -(weeks - 1) * 7, to: lastColumnStart)
        else { return [] }

        return (0..<weeks).map { week in
            (0..<7).compactMap { row -> Day? in
                guard let date = calendar.date(byAdding: .day, value: week * 7 + row, to: start) else { return nil }
                let value = date > today ? 0 : (values[date] ?? 0)
                let level = value == 0 ? 0 : (thresholds.firstIndex(where: { value <= $0 }).map { $0 + 1 } ?? 4)
                let unpriced = CloudCostSummary(requests: callsByDay[date] ?? []).unpricedCalls
                return Day(date: date, value: value, unpricedCalls: unpriced, level: level, week: week, weekday: row)
            }
        }
    }

    private func describe(_ day: Day) -> String {
        let date = day.date.formatted(.dateTime.month(.wide).day().year())
        switch metric {
        case .words: return day.value == 0 ? "No words on \(date)" : "\(Int(day.value)) words on \(date)"
        case .calls: return "\(Int(day.value)) cloud calls on \(date)"
        case .spend:
            return "\(Fmt.money(day.value)) estimated spend on \(date)"
                + (day.unpricedCalls > 0 ? " · \(day.unpricedCalls) calls with unknown cost" : "")
        }
    }

    private var totalDescription: String {
        let days = buildColumns().flatMap { $0 }
        let total = days.reduce(0) { $0 + $1.value }
        switch metric {
        case .words: return "\(Stats.compactCount(Int(total))) words in the last year"
        case .calls: return "\(Stats.compactCount(Int(total))) cloud calls in the last year"
        case .spend:
            let unknown = days.reduce(0) { $0 + $1.unpricedCalls }
            return "\(Fmt.money(total)) estimated spend in the last year"
                + (unknown > 0 ? " · \(unknown) calls with unknown cost" : "")
        }
    }

    private static let weekdaySymbols = ["", "Mon", "", "Wed", "", "Fri", ""]
    private static let monthSymbols = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                       "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
}

/// Chart colours, kept out of the views so both modes are visible in one place.
enum VizPalette {
    /// Sequential blue, one hue, light→dark. Level 0 is absence, so it is neutral gray
    /// rather than the lightest blue: "nothing happened" is not a small magnitude.
    ///
    /// Each mode's steps were chosen for that mode's surface and validated, rather
    /// than flipping one set for the other.
    static func heat(level: Int, scheme: ColorScheme) -> Color {
        let light = ["#f0efec", "#86b6ef", "#3987e5", "#1c5cab", "#0d366b"]
        let dark  = ["#383835", "#184f95", "#256abf", "#3987e5", "#86b6ef"]
        let steps = scheme == .dark ? dark : light
        return Color(hex: steps[min(max(level, 0), 4)])
    }

    /// Categorical hues in a fixed order. The order is what keeps neighbours apart
    /// for colour-blind readers, so slots are assigned in sequence and never cycled.
    /// Past the last slot a series folds into `other`.
    static let seriesCount = 8
    static func series(_ index: Int, scheme: ColorScheme) -> Color {
        let light = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300", "#4a3aa7", "#e34948"]
        let dark  = ["#3987e5", "#d95926", "#199e70", "#c98500", "#d55181", "#008300", "#9085e9", "#e66767"]
        let steps = scheme == .dark ? dark : light
        return index < steps.count ? Color(hex: steps[index]) : other
    }

    /// For the series that do not get a hue of their own.
    static let other = Color(hex: "#898781")

    /// Status colours are reserved for state and always ship with an icon or label.
    static func good(_ scheme: ColorScheme) -> Color { Color(hex: scheme == .dark ? "#0ca30c" : "#006300") }
    static let warning = Color(hex: "#fab219")
    static let critical = Color(hex: "#d03b3b")
}

extension Color {
    /// `#rrggbb`.
    init(hex: String) {
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let value = UInt32(cleaned, radix: 16) ?? 0
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255
        )
    }
}
