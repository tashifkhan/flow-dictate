import Foundation

/// The window the Overview numbers are computed over.
enum StatsRange: String, CaseIterable, Identifiable, Sendable {
    case today, week, month, year, allTime

    var id: String { rawValue }

    var label: String {
        switch self {
        case .today: "Today"
        case .week: "Last 7 Days"
        case .month: "Last 30 Days"
        case .year: "Last Year"
        case .allTime: "All Time"
        }
    }

    var cutoff: Date? {
        cutoff(at: .now)
    }

    /// Daily aggregates and cloud calls use the same local-day boundaries.
    func cutoff(at date: Date, calendar: Calendar = .current) -> Date? {
        let start: Date?
        switch self {
        case .today: start = date
        case .week: start = calendar.date(byAdding: .day, value: -7, to: date)
        case .month: start = calendar.date(byAdding: .day, value: -30, to: date)
        case .year: start = calendar.date(byAdding: .year, value: -1, to: date)
        case .allTime: return nil
        }
        return start.map { calendar.startOfDay(for: $0) }
    }

    func requests(_ all: [CloudRequestRecord], at date: Date = .now, calendar: Calendar = .current) -> [CloudRequestRecord] {
        let cutoff = cutoff(at: date, calendar: calendar)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) ?? date
        return all.filter { request in
            request.isInference && request.startedAt < tomorrow && (cutoff.map { request.startedAt >= $0 } ?? true)
        }
    }
}

/// Everything the statistics screen shows, derived from the history table.
struct Stats: Sendable {
    var totalWords = 0
    var totalDuration: TimeInterval = 0
    var dictationCount = 0
    /// Words per minute while actually speaking.
    var wordsPerMinute = 0
    /// Time not spent typing, in seconds. See `typingWordsPerMinute`.
    var timeSaved: TimeInterval = 0
    /// Words dictated per day, keyed by the start of that day.
    var wordsByDay: [Date: Int] = [:]

    /// Sustained prose typing for a competent typist. Used only for the "time saved"
    /// comparison, which is a rough number and is presented as one.
    static let typingWordsPerMinute = 40.0

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    /// Computed from the daily aggregates rather than the transcripts, so the numbers
    /// still cover days whose text has since been purged by the retention setting.
    static func compute(from days: [DailyStat], range: StatsRange) -> Stats {
        let calendar = Calendar.current
        return compute(from: days, start: range.cutoff.map { calendar.startOfDay(for: $0) }, end: nil)
    }

    /// Totals over `start..<end`; either bound may be open.
    static func compute(from days: [DailyStat], start: Date?, end: Date?) -> Stats {
        var stats = Stats()

        for day in days {
            // The activity graph always covers a trailing year regardless of range.
            stats.wordsByDay[day.day, default: 0] += day.words

            if let start, day.day < start { continue }
            if let end, day.day >= end { continue }
            stats.totalWords += day.words
            stats.totalDuration += day.duration
            stats.dictationCount += day.dictations
        }

        if stats.totalDuration > 0 {
            stats.wordsPerMinute = Int((Double(stats.totalWords) / (stats.totalDuration / 60)).rounded())
        }

        // What typing the same words would have cost, minus what saying them did.
        let typingSeconds = Double(stats.totalWords) / typingWordsPerMinute * 60
        stats.timeSaved = max(0, typingSeconds - stats.totalDuration)

        return stats
    }

    /// Quartile thresholds over the non-empty days, so a light week still shows shape
    /// instead of collapsing to one flat colour.
    func intensityThresholds() -> [Int] {
        let counts = wordsByDay.values.filter { $0 > 0 }.sorted()
        guard !counts.isEmpty else { return [1, 2, 3, 4] }
        func quantile(_ q: Double) -> Int {
            let index = Int((Double(counts.count - 1) * q).rounded())
            return max(1, counts[index])
        }
        // Strictly increasing, so equal quantiles on sparse data still bucket sanely.
        var thresholds = [quantile(0.25), quantile(0.50), quantile(0.75), quantile(1.0)]
        for i in 1..<thresholds.count where thresholds[i] <= thresholds[i - 1] {
            thresholds[i] = thresholds[i - 1] + 1
        }
        return thresholds
    }

    /// 0 for a day with nothing, else 1...4.
    func level(for words: Int, thresholds: [Int]) -> Int {
        guard words > 0 else { return 0 }
        for (index, threshold) in thresholds.enumerated() where words <= threshold {
            return index + 1
        }
        return 4
    }

    /// "1h 29m", "12m", "48s" — matching how the number is actually read aloud.
    static func humanDuration(_ seconds: TimeInterval) -> (value: String, unit: String) {
        let total = Int(seconds.rounded())
        if total >= 3600 {
            let h = total / 3600, m = (total % 3600) / 60
            return m > 0 ? ("\(h)h \(m)m", "") : ("\(h)", "h")
        }
        if total >= 60 { return ("\(total / 60)", "m") }
        return ("\(total)", "s")
    }

    /// 12.7k, 950
    static func compactCount(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fk", Double(value) / 1_000) }
        return "\(value)"
    }
}

extension StatsRange {
    var shortLabel: String {
        switch self {
        case .today: "Today"
        case .week: "7 days"
        case .month: "30 days"
        case .year: "Year"
        case .allTime: "All time"
        }
    }

    /// One bar per bucket. Today buckets by hour, which only the kept transcripts can do.
    var bucket: Calendar.Component {
        switch self {
        case .today: .hour
        case .week, .month: .day
        case .year: .weekOfYear
        case .allTime: .month
        }
    }

    /// The same number of days immediately before this range, for "vs previous".
    /// Nil for all time, which has nothing before it.
    func previousWindow(at date: Date = .now, calendar: Calendar = .current) -> (start: Date, end: Date)? {
        guard let start = cutoff(at: date, calendar: calendar),
              let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))
        else { return nil }
        let days = calendar.dateComponents([.day], from: start, to: tomorrow).day ?? 0
        guard days > 0, let previous = calendar.date(byAdding: .day, value: -days, to: start) else { return nil }
        return (previous, start)
    }
}

/// One bar in a chart over time.
struct StatsPoint: Identifiable, Hashable, Sendable {
    var date: Date
    var words = 0
    var dictations = 0
    var duration: TimeInterval = 0

    var id: Date { date }
    var minutes: Double { duration / 60 }
    var wordsPerMinute: Double { duration > 0 ? Double(words) / (duration / 60) : 0 }
}

/// Runs of consecutive days with at least one dictation, and the biggest day.
struct Streaks: Equatable, Sendable {
    var current = 0
    var longest = 0
    var bestDay: Date?
    var bestWords = 0
}

extension Stats {
    /// Daily totals rolled up into the range's buckets. Empty buckets stay in, so a
    /// quiet week reads as a gap rather than disappearing. Today's range uses
    /// `hourly(_:on:)` instead; a daily total cannot be split into hours.
    static func series(from days: [DailyStat], range: StatsRange,
                       now: Date = .now, calendar: Calendar = .current) -> [StatsPoint] {
        let component = range == .today ? Calendar.Component.day : range.bucket
        let start = range.cutoff(at: now, calendar: calendar)
            ?? days.map(\.day).min()
            ?? calendar.startOfDay(for: now)
        guard var cursor = calendar.dateInterval(of: component, for: start)?.start else { return [] }

        var points: [StatsPoint] = []
        var index: [Date: Int] = [:]
        while cursor <= now {
            index[cursor] = points.count
            points.append(StatsPoint(date: cursor))
            guard let next = calendar.date(byAdding: component, value: 1, to: cursor) else { break }
            cursor = next
        }

        for day in days where day.day >= calendar.startOfDay(for: start) {
            guard let bucket = calendar.dateInterval(of: component, for: day.day)?.start,
                  let position = index[bucket] else { continue }
            points[position].words += day.words
            points[position].dictations += day.dictations
            points[position].duration += day.duration
        }
        return points
    }

    /// One point per hour of `day`, from the transcripts still kept.
    static func hourly(_ records: [DictationRecord], on day: Date, calendar: Calendar = .current) -> [StatsPoint] {
        let start = calendar.startOfDay(for: day)
        var points = (0..<24).compactMap { calendar.date(byAdding: .hour, value: $0, to: start) }
            .map { StatsPoint(date: $0) }
        guard points.count == 24 else { return points }
        for record in records where calendar.isDate(record.createdAt, inSameDayAs: day) {
            let hour = calendar.component(.hour, from: record.createdAt)
            points[hour].words += wordCount(record.inserted)
            points[hour].dictations += 1
            points[hour].duration += record.duration
        }
        return points
    }

    /// A streak survives an empty today: it counts back from yesterday until you
    /// dictate again or the day ends.
    static func streaks(_ wordsByDay: [Date: Int], today: Date = .now, calendar: Calendar = .current) -> Streaks {
        var result = Streaks()
        let active = Set(wordsByDay.filter { $0.value > 0 }.keys.map { calendar.startOfDay(for: $0) })
        if let best = wordsByDay.max(by: { $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value }),
           best.value > 0 {
            result.bestDay = best.key
            result.bestWords = best.value
        }

        var run = 0
        var previous: Date?
        for day in active.sorted() {
            if let previous, let next = calendar.date(byAdding: .day, value: 1, to: previous),
               calendar.isDate(next, inSameDayAs: day) {
                run += 1
            } else {
                run = 1
            }
            result.longest = max(result.longest, run)
            previous = day
        }

        var cursor = calendar.startOfDay(for: today)
        if !active.contains(cursor), let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor) {
            cursor = yesterday
        }
        while active.contains(cursor), let before = calendar.date(byAdding: .day, value: -1, to: cursor) {
            result.current += 1
            cursor = before
        }
        return result
    }
}

/// Which apps and which hours, from the transcripts still kept. Retention deletes
/// these rows, so this covers less history than the daily totals do.
struct DictationBreakdown: Sendable {
    struct App: Identifiable, Hashable, Sendable {
        var bundleID: String
        var name: String
        var words = 0
        var dictations = 0
        var id: String { bundleID.isEmpty ? name : bundleID }
    }

    var apps: [App] = []
    var wordsByHour = Array(repeating: 0, count: 24)
    var dictationsByHour = Array(repeating: 0, count: 24)
    var totalWords = 0
    var count = 0

    static func compute(_ records: [DictationRecord], start: Date?, calendar: Calendar = .current) -> DictationBreakdown {
        var result = DictationBreakdown()
        var apps: [String: App] = [:]
        for record in records {
            if let start, record.createdAt < start { continue }
            let words = Stats.wordCount(record.inserted)
            let key = record.appBundleID.isEmpty ? record.appName : record.appBundleID
            apps[key, default: App(bundleID: record.appBundleID, name: record.appName)].words += words
            apps[key]?.dictations += 1
            let hour = calendar.component(.hour, from: record.createdAt)
            result.wordsByHour[hour] += words
            result.dictationsByHour[hour] += 1
            result.totalWords += words
            result.count += 1
        }
        result.apps = apps.values.sorted { $0.words == $1.words ? $0.name < $1.name : $0.words > $1.words }
        return result
    }
}
