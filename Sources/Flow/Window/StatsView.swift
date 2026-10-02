import Charts
import SwiftUI

/// Statistics as one page: the past year at a glance, then everything else for the
/// range picked in the row above it.
///
/// The year card sits above the range picker because it always covers a year. Every
/// card below the picker uses the same range, so the numbers agree with each other.
struct StatsView: View {
    @Bindable var env: AppEnvironment
    @AppStorage("statsRange") private var rangeID = StatsRange.month.rawValue
    @State private var activityMetric: ContributionGraph.Metric = .words

    private var range: StatsRange { StatsRange(rawValue: rangeID) ?? .month }

    var body: some View {
        let days = env.library.dailyStats
        let stats = Stats.compute(from: days, range: range)
        let previous = range.previousWindow().map { Stats.compute(from: days, start: $0.start, end: $0.end) }
        let series = range == .today
            ? Stats.hourly(env.library.dictations, on: .now)
            : Stats.series(from: days, range: range)
        let breakdown = DictationBreakdown.compute(env.library.dictations, start: range.cutoff)
        let usesCloud = env.library.cloudRequests.contains(where: \.isInference)

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                yearCard(stats)
                rangeBar
                kpis(stats, previous: previous, series: series)
                TrendChart(points: series, range: range)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 16, alignment: .top)],
                          alignment: .leading, spacing: 16) {
                    // Today's trend chart is already split by hour.
                    if range != .today {
                        HourChart(breakdown: breakdown, caveat: keptHistoryCaveat)
                    }
                    TopApps(breakdown: breakdown, caveat: keptHistoryCaveat)
                }
                if usesCloud {
                    Divider().padding(.vertical, 4)
                    CloudCostSection(requests: range.requests(env.library.cloudRequests),
                                     allRequests: env.library.cloudRequests,
                                     range: range)
                }
            }
            .padding(24)
            .frame(maxWidth: 1000, alignment: .leading)
            .animation(.easeOut(duration: 0.2), value: rangeID)
        }
        .frame(maxWidth: .infinity)
        .navigationTitle("Statistics")
    }

    /// Per-app and per-hour numbers come from transcripts, which retention deletes.
    private var keptHistoryCaveat: String {
        if !env.library.query.isEmpty { return "From kept dictations matching your search" }
        let retention = Settings.shared.retention
        return retention == .forever ? "From kept dictations" : "From kept dictations (history keeps \(retention.label.lowercased()))"
    }

    // MARK: Year

    private func yearCard(_ stats: Stats) -> some View {
        let streaks = Stats.streaks(stats.wordsByDay)
        return SectionCard(title: "Past year", subtitle: "Every day you dictated. Hover a day for its total.") {
            Picker("Activity measure", selection: $activityMetric) {
                ForEach(ContributionGraph.Metric.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("What the colour of each day measures")
        } content: {
            ContributionGraph(stats: stats, requests: env.library.cloudRequests, metric: activityMetric)
            Divider()
            HStack(spacing: 28) {
                streakStat("Current streak", Fmt.count(streaks.current, "day"), icon: "flame",
                           help: streaks.current > 0
                               ? "Days in a row with at least one dictation, ending today or yesterday"
                               : "Dictate today to start a streak")
                streakStat("Longest streak", Fmt.count(streaks.longest, "day"), icon: "trophy",
                           help: "Your longest run of consecutive days with a dictation")
                if let best = streaks.bestDay {
                    streakStat("Best day", "\(Stats.compactCount(streaks.bestWords)) words",
                               icon: "star", detail: best.formatted(.dateTime.day().month(.abbreviated).year()),
                               help: "The day you dictated the most words")
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func streakStat(_ title: String, _ value: String, icon: String, detail: String? = nil, help: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(value).font(.callout.weight(.semibold))
                    if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .help(help)
        .accessibilityElement(children: .combine)
    }

    // MARK: Range

    private var rangeBar: some View {
        HStack(spacing: 10) {
            Picker("Range", selection: $rangeID) {
                ForEach(StatsRange.allCases) { Text($0.shortLabel).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("The period every card below covers")
            Text(range == .allTime ? "Everything Flow has counted" : range.label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            if !env.library.query.isEmpty {
                Chip("Search: \(env.library.query)", systemImage: "magnifyingglass")
                    .help("Hourly and per-app numbers only count dictations matching the search. Totals are unaffected.")
            }
        }
    }

    // MARK: Headline numbers

    private func kpis(_ stats: Stats, previous: Stats?, series: [StatsPoint]) -> some View {
        let typing = Stats.typingWordsPerMinute
        let saved = Stats.humanDuration(stats.timeSaved)
        let speaking = Stats.humanDuration(stats.totalDuration)
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
            StatCard(title: "Words", value: stats.totalWords.formatted(),
                     delta: change(stats.totalWords, previous?.totalWords),
                     trend: series.map { Double($0.words) },
                     help: "Words inserted in this range. Counted from daily totals, so it includes days whose text retention has deleted.")
            StatCard(title: "Dictations", value: stats.dictationCount.formatted(),
                     delta: change(stats.dictationCount, previous?.dictationCount),
                     trend: series.map { Double($0.dictations) },
                     help: "Dictations in this range. You spoke for \(speaking.value)\(speaking.unit) in total.")
            StatCard(title: "Speaking pace", value: stats.wordsPerMinute.formatted(), unit: "wpm",
                     delta: change(stats.wordsPerMinute, previous?.wordsPerMinute),
                     trend: series.map(\.wordsPerMinute),
                     help: "Words per minute while the microphone was recording.")
            StatCard(title: "Time saved", value: saved.value, unit: saved.unit,
                     delta: previous.flatMap { $0.timeSaved > 0 ? (stats.timeSaved - $0.timeSaved) / $0.timeSaved : nil },
                     trend: series.map { max(0, Double($0.words) / typing * 60 - $0.duration) },
                     help: "An estimate: how long typing these words at \(Int(typing)) wpm would take, minus the time you spent speaking them.")
        }
    }

    private func change(_ now: Int, _ before: Int?) -> Double? {
        guard let before, before > 0 else { return nil }
        return Double(now - before) / Double(before)
    }
}

// MARK: - Over time

private struct TrendChart: View {
    var points: [StatsPoint]
    var range: StatsRange
    @State private var metric: Metric = .words
    @State private var hovered: Date?
    @State private var width: CGFloat = 600
    @Environment(\.colorScheme) private var scheme

    enum Metric: String, CaseIterable, Identifiable {
        case words = "Words", dictations = "Dictations", minutes = "Minutes"
        var id: String { rawValue }
    }

    private var component: Calendar.Component { range.bucket }

    private func value(_ point: StatsPoint) -> Double {
        switch metric {
        case .words: Double(point.words)
        case .dictations: Double(point.dictations)
        case .minutes: point.minutes
        }
    }

    private var title: String {
        let per = switch component {
        case .hour: "hour"
        case .weekOfYear: "week"
        case .month: "month"
        default: "day"
        }
        return "\(metric.rawValue) per \(per)"
    }

    private var domain: ClosedRange<Date> {
        let calendar = Calendar.current
        let first = points.first?.date ?? .now
        let last = points.last.flatMap { calendar.dateInterval(of: component, for: $0.date)?.end } ?? .now
        return first...last
    }

    private var hoveredPoint: StatsPoint? {
        guard let hovered else { return nil }
        let calendar = Calendar.current
        return points.first { calendar.dateInterval(of: component, for: $0.date)?.contains(hovered) ?? false }
    }

    private var barWidth: CGFloat {
        max(2, min(24, width / CGFloat(max(points.count, 1)) * 0.7))
    }

    var body: some View {
        let selected = hoveredPoint
        let color = VizPalette.series(0, scheme: scheme)
        SectionCard(title: title, subtitle: subtitle) {
            Picker("Measure", selection: $metric) {
                ForEach(Metric.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        } content: {
            Chart {
                ForEach(points) { point in
                    BarMark(x: .value("Date", point.date, unit: component),
                            y: .value(metric.rawValue, value(point)),
                            width: .fixed(barWidth))
                        .foregroundStyle(color)
                        .cornerRadius(2)
                        .opacity(selected == nil || selected == point ? 1 : 0.45)
                }
                if let selected {
                    RuleMark(x: .value("Date", selected.date, unit: component))
                        .foregroundStyle(.clear)
                        .annotation(position: .top, spacing: 4,
                                    overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                            ChartTooltip(title: label(selected.date), rows: [
                                .init(color: metric == .words ? color : nil, label: "words", value: selected.words.formatted()),
                                .init(color: metric == .dictations ? color : nil, label: selected.dictations == 1 ? "dictation" : "dictations",
                                      value: selected.dictations.formatted()),
                                .init(color: metric == .minutes ? color : nil, label: "speaking", value: Fmt.duration(selected.duration)),
                            ])
                        }
                }
            }
            .chartXScale(domain: domain)
            .chartXSelection(value: $hovered)
            .quietXAxis()
            .quietYAxis()
            .frame(height: 200)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 - 50 }
            .overlay {
                if points.allSatisfy({ $0.dictations == 0 }) {
                    Text(range == .today ? "Nothing dictated yet today." : "No dictations in this range.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel(title)
        }
    }

    private var subtitle: String {
        let total = points.reduce(0) { $0 + value($1) }
        let active = points.filter { $0.dictations > 0 }.count
        let amount = metric == .minutes ? Fmt.duration(total * 60) : Int(total).formatted() + " " + metric.rawValue.lowercased()
        return "\(amount) across \(Fmt.count(active, unitName)) with activity"
    }

    private var unitName: String {
        switch component {
        case .hour: "hour"
        case .weekOfYear: "week"
        case .month: "month"
        default: "day"
        }
    }

    private func label(_ date: Date) -> String {
        switch component {
        case .hour: date.formatted(.dateTime.hour())
        case .weekOfYear: "Week of " + date.formatted(.dateTime.day().month(.abbreviated))
        case .month: date.formatted(.dateTime.month(.wide).year())
        default: date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
        }
    }
}

// MARK: - Hours and apps

private struct HourChart: View {
    var breakdown: DictationBreakdown
    var caveat: String
    @State private var hovered: String?
    @Environment(\.colorScheme) private var scheme

    private static let hours = (0..<24).map(String.init)

    var body: some View {
        let color = VizPalette.series(0, scheme: scheme)
        let selected = hovered.flatMap(Int.init)
        SectionCard(title: "When you dictate", subtitle: "Words by hour of day. \(caveat).") {
            Chart {
                ForEach(0..<24, id: \.self) { hour in
                    BarMark(x: .value("Hour", Self.hours[hour]),
                            y: .value("Words", breakdown.wordsByHour[hour]),
                            width: .ratio(0.7))
                        .foregroundStyle(color)
                        .cornerRadius(2)
                        .opacity(selected == nil || selected == hour ? 1 : 0.45)
                }
                if let selected {
                    RuleMark(x: .value("Hour", Self.hours[selected]))
                        .foregroundStyle(.clear)
                        .annotation(position: .top, spacing: 4,
                                    overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                            ChartTooltip(title: Self.label(selected) + " to " + Self.label((selected + 1) % 24), rows: [
                                .init(color: color, label: "words", value: breakdown.wordsByHour[selected].formatted()),
                                .init(label: breakdown.dictationsByHour[selected] == 1 ? "dictation" : "dictations",
                                      value: breakdown.dictationsByHour[selected].formatted()),
                            ])
                        }
                }
            }
            .chartXScale(domain: Self.hours)
            .chartXSelection(value: $hovered)
            .quietYAxis()
            .chartXAxis {
                AxisMarks(values: ["6", "12", "18"]) { value in
                    AxisValueLabel {
                        if let hour = value.as(String.self).flatMap(Int.init) { Text(Self.label(hour)) }
                    }
                    .foregroundStyle(ChartInk.label)
                }
            }
            .frame(height: 160)
            .overlay {
                if breakdown.count == 0 {
                    Text("No kept dictations in this range.").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    static func label(_ hour: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now) ?? .now
        return date.formatted(.dateTime.hour())
    }
}

private struct TopApps: View {
    var breakdown: DictationBreakdown
    var caveat: String
    private let shown = 6

    var body: some View {
        let apps = Array(breakdown.apps.prefix(shown))
        let most = max(apps.first?.words ?? 1, 1)
        SectionCard(title: "Top apps", subtitle: "Where your words went. \(caveat).") {
            if apps.isEmpty {
                Text("No kept dictations in this range.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                VStack(spacing: 10) {
                    ForEach(apps) { app in
                        AppShareRow(app: app, fraction: Double(app.words) / Double(most),
                                    share: breakdown.totalWords > 0 ? Double(app.words) / Double(breakdown.totalWords) : 0)
                    }
                    if breakdown.apps.count > shown {
                        let rest = breakdown.apps.dropFirst(shown)
                        Text("\(Fmt.count(rest.count, "more app")) · \(Stats.compactCount(rest.reduce(0) { $0 + $1.words })) words")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}

private struct AppShareRow: View {
    var app: DictationBreakdown.App
    var fraction: Double
    var share: Double
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 10) {
            AppIconView(bundleID: app.bundleID, size: 22)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(app.name).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(Stats.compactCount(app.words)).monospacedDigit()
                    Text(Fmt.percent(share))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 38, alignment: .trailing)
                }
                .font(.callout)
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary.opacity(0.6))
                        Capsule().fill(VizPalette.series(0, scheme: scheme))
                            .frame(width: max(4, geometry.size.width * fraction))
                    }
                }
                .frame(height: 5)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(hovering ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 6))
        .onHover { hovering = $0 }
        .help("\(app.name): \(app.words.formatted()) words in \(Fmt.count(app.dictations, "dictation"))")
        .accessibilityElement(children: .combine)
    }
}
