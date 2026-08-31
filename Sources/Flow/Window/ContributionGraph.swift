import SwiftUI

/// Words dictated per day, a year at a glance.
///
/// Sequential encoding: one hue, light→dark, because the value is a magnitude. Both
/// mode ramps were validated against their own surface rather than flipped from each
/// other — see `VizPalette`.
struct ContributionGraph: View {
    var stats: Stats
    /// Nil while nothing is hovered.
    @State private var hovered: Day?
    @Environment(\.colorScheme) private var scheme

    struct Day: Hashable {
        var date: Date
        var words: Int
        var level: Int
    }

    private let cell: CGFloat = 11
    private let gap: CGFloat = 3
    private let weeks = 53

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            grid
            footer
        }
        .padding(16)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 12))
    }

    // MARK: - Grid

    private var grid: some View {
        let columns = buildColumns()
        return VStack(alignment: .leading, spacing: 4) {
            monthLabels(columns)
            HStack(alignment: .top, spacing: gap) {
                weekdayLabels
                ForEach(Array(columns.enumerated()), id: \.offset) { _, week in
                    VStack(spacing: gap) {
                        ForEach(week, id: \.self) { day in
                            cellView(day)
                        }
                    }
                }
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
            .accessibilityLabel(Self.describe(day))
    }

    private var weekdayLabels: some View {
        VStack(alignment: .trailing, spacing: gap) {
            ForEach(0..<7, id: \.self) { row in
                Text(row % 2 == 1 ? Self.weekdaySymbols[row] : "")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: cell, alignment: .trailing)
            }
        }
    }

    private func monthLabels(_ columns: [[Day]]) -> some View {
        HStack(alignment: .bottom, spacing: gap) {
            Spacer().frame(width: 24)
            ForEach(Array(columns.enumerated()), id: \.offset) { index, week in
                // Label a column when its first day starts a new month.
                Text(monthLabel(week, at: index, in: columns))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .frame(width: cell, alignment: .leading)
                    .fixedSize()
                    .frame(width: cell, alignment: .leading)
                    .clipped()
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

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if let hovered {
                Text(Self.describe(hovered))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(Stats.compactCount(stats.wordsByDay.values.reduce(0, +))) words in the last year")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
        let thresholds = stats.intensityThresholds()
        let today = calendar.startOfDay(for: .now)

        // Walk back to the most recent week boundary, then back `weeks` weeks.
        let weekday = calendar.component(.weekday, from: today) - 1
        guard let lastColumnStart = calendar.date(byAdding: .day, value: -weekday, to: today),
              let start = calendar.date(byAdding: .day, value: -(weeks - 1) * 7, to: lastColumnStart)
        else { return [] }

        return (0..<weeks).map { week in
            (0..<7).compactMap { row -> Day? in
                guard let date = calendar.date(byAdding: .day, value: week * 7 + row, to: start) else { return nil }
                let words = date > today ? 0 : (stats.wordsByDay[date] ?? 0)
                return Day(date: date, words: words, level: stats.level(for: words, thresholds: thresholds))
            }
        }
    }

    private static func describe(_ day: Day) -> String {
        let date = day.date.formatted(.dateTime.month(.wide).day().year())
        return day.words == 0 ? "No words on \(date)" : "\(day.words) words on \(date)"
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
