import Foundation

/// A single dictation: what you said, and what got inserted.
///
/// `raw` is kept on purpose. When cleanup mangles something you fix the prompt,
/// not the data.
struct DictationRecord: Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var raw: String
    var cleaned: String
    var appBundleID: String
    var appName: String
    var createdAt: Date = .now
    var duration: TimeInterval
    var pinned: Bool = false
    var tags: [String] = []

    /// What actually reached the cursor.
    var inserted: String { cleaned.isEmpty ? raw : cleaned }

    /// True when the cleanup pass changed nothing, i.e. it was unavailable or a no-op.
    var wasCleaned: Bool { !cleaned.isEmpty && cleaned != raw }
}

/// A scratchpad note. A dictation is what you said to someone else; a note is what
/// you said to yourself. They stay in separate tables for that reason.
struct NoteRecord: Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var title: String = ""
    var text: String = ""
    var createdAt: Date = .now
    var updatedAt: Date = .now
    var pinned: Bool = false
    var summary: String?

    /// Title comes from the first line, per the plan.
    var displayTitle: String {
        let first = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        if !title.isEmpty { return title }
        return trimmed.isEmpty ? "New note" : String(trimmed.prefix(80))
    }

    var body: String {
        let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        return parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .newlines) : ""
    }
}

/// One day's dictation totals, kept apart from the transcripts themselves.
///
/// Retention deletes what you said; it should not delete the fact that you said it.
/// These rows are tiny, hold no content, and outlive the purge, so the activity graph
/// stays honest about a year you can no longer read back.
struct DailyStat: Identifiable, Hashable, Sendable {
    var day: Date
    var words: Int
    var dictations: Int
    var duration: TimeInterval

    var id: Date { day }
}

/// How long history sticks around. Default 90 days, it is your machine.
enum Retention: String, CaseIterable, Identifiable, Sendable {
    case forever, oneYear, ninetyDays, thirtyDays

    var id: String { rawValue }

    var label: String {
        switch self {
        case .forever: "Keep everything"
        case .oneYear: "One year"
        case .ninetyDays: "90 days"
        case .thirtyDays: "30 days"
        }
    }

    var days: Int? {
        switch self {
        case .forever: nil
        case .oneYear: 365
        case .ninetyDays: 90
        case .thirtyDays: 30
        }
    }

    var cutoff: Date? { days.map { Date.now.addingTimeInterval(-Double($0) * 86_400) } }
}
