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
        let calendar = Calendar.current
        switch self {
        case .today: return calendar.startOfDay(for: .now)
        case .week: return calendar.date(byAdding: .day, value: -7, to: .now)
        case .month: return calendar.date(byAdding: .day, value: -30, to: .now)
        case .year: return calendar.date(byAdding: .year, value: -1, to: .now)
        case .allTime: return nil
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
        let cutoff = range.cutoff.map { calendar.startOfDay(for: $0) }
        var stats = Stats()

        for day in days {
            // The activity graph always covers a trailing year regardless of range.
            stats.wordsByDay[day.day, default: 0] += day.words

            if let cutoff, day.day < cutoff { continue }
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
