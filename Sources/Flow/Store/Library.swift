import Foundation
import Observation
import OSLog

/// The observable face of the history store.
///
/// Views read the arrays; everything that mutates goes through here so the store and
/// the UI never disagree.
@MainActor @Observable
final class Library {
    private let store: any HistoryStore
    private let log = Logger(subsystem: "sh.taf.flow", category: "library")

    private(set) var dictations: [DictationRecord] = []
    private(set) var notes: [NoteRecord] = []
    /// Survives the retention purge, so statistics cover more than the kept transcripts.
    private(set) var dailyStats: [DailyStat] = []
    private(set) var loadFailure: String?

    var query: String = "" {
        didSet { guard query != oldValue else { return }; reload() }
    }

    init(store: any HistoryStore) {
        self.store = store
        applyRetention()
        reload()
    }

    /// Falls back to an in-memory store so a broken database never stops you dictating.
    static func make() -> Library {
        do {
            return Library(store: try SQLiteStore(url: try SQLiteStore.defaultURL()))
        } catch {
            let log = Logger(subsystem: "sh.taf.flow", category: "library")
            log.error("history unavailable, running in memory: \(error.localizedDescription, privacy: .public)")
            let library = Library(store: MemoryStore())
            library.loadFailure = "History is running in memory this session: \(error.localizedDescription)"
            return library
        }
    }

    func reload() {
        do {
            dictations = try store.dictations(matching: query, limit: nil)
            notes = try store.notes(matching: query)
            dailyStats = try store.dailyStats()
            loadFailure = nil
        } catch {
            log.error("reload failed: \(error.localizedDescription, privacy: .public)")
            loadFailure = error.localizedDescription
        }
    }

    // MARK: - Dictations

    func add(_ dictation: DictationRecord) {
        perform { try store.insert(dictation) }
    }

    func togglePin(_ dictation: DictationRecord) {
        perform { try store.setPinned(dictation: dictation.id, !dictation.pinned) }
    }

    func delete(_ dictation: DictationRecord) {
        perform { try store.delete(dictation: dictation.id) }
    }

    /// Newest first, for the menu bar list.
    func recent(_ count: Int) -> [DictationRecord] {
        Array(dictations.sorted { $0.createdAt > $1.createdAt }.prefix(count))
    }

    var pinnedDictations: [DictationRecord] { dictations.filter(\.pinned) }

    // MARK: - Notes

    @discardableResult
    func newNote() -> NoteRecord {
        let note = NoteRecord()
        perform { try store.upsert(note) }
        return note
    }

    func save(_ note: NoteRecord) {
        var updated = note
        updated.updatedAt = .now
        perform { try store.upsert(updated) }
    }

    func togglePin(_ note: NoteRecord) {
        perform { try store.setPinned(note: note.id, !note.pinned) }
    }

    func delete(_ note: NoteRecord) {
        perform { try store.delete(note: note.id) }
    }

    func note(_ id: UUID) -> NoteRecord? { notes.first { $0.id == id } }

    /// Grouped by day, newest day first, for the sidebar.
    func notesByDay() -> [(day: Date, notes: [NoteRecord])] {
        group(notes, by: \.updatedAt)
    }

    func dictationsByDay() -> [(day: Date, notes: [DictationRecord])] {
        group(dictations, by: \.createdAt)
    }

    private func group<T>(_ items: [T], by date: (T) -> Date) -> [(day: Date, notes: [T])] {
        let calendar = Calendar.current
        let buckets = Dictionary(grouping: items) { calendar.startOfDay(for: date($0)) }
        return buckets.keys.sorted(by: >).map { ($0, buckets[$0] ?? []) }
    }

    // MARK: - Retention

    /// Runs at launch. Pinned rows survive regardless.
    func applyRetention() {
        guard let cutoff = Settings.shared.retention.cutoff else { return }
        perform(reloading: false) { try store.purgeDictations(before: cutoff) }
    }

    private func perform(reloading: Bool = true, _ work: () throws -> Void) {
        do {
            try work()
            if reloading { reload() }
        } catch {
            log.error("store write failed: \(error.localizedDescription, privacy: .public)")
            loadFailure = error.localizedDescription
        }
    }
}

/// Used only when the database cannot be opened. Keeps the app usable for the session.
final class MemoryStore: HistoryStore, @unchecked Sendable {
    private let lock = NSLock()
    private var dictationRows: [UUID: DictationRecord] = [:]
    private var noteRows: [UUID: NoteRecord] = [:]

    func insert(_ dictation: DictationRecord) throws {
        lock.withLock { dictationRows[dictation.id] = dictation }
    }

    func dictations(matching query: String?, limit: Int?) throws -> [DictationRecord] {
        lock.withLock {
            var rows = Array(dictationRows.values)
            if let query, !query.isEmpty {
                rows = rows.filter {
                    $0.raw.localizedCaseInsensitiveContains(query)
                        || $0.cleaned.localizedCaseInsensitiveContains(query)
                }
            }
            rows.sort { ($0.pinned ? 1 : 0, $0.createdAt) > ($1.pinned ? 1 : 0, $1.createdAt) }
            return limit.map { Array(rows.prefix($0)) } ?? rows
        }
    }

    func setPinned(dictation id: UUID, _ pinned: Bool) throws {
        lock.withLock { dictationRows[id]?.pinned = pinned }
    }

    func delete(dictation id: UUID) throws {
        lock.withLock { _ = dictationRows.removeValue(forKey: id) }
    }

    func purgeDictations(before cutoff: Date) throws {
        lock.withLock { dictationRows = dictationRows.filter { $0.value.pinned || $0.value.createdAt >= cutoff } }
    }

    func dailyStats() throws -> [DailyStat] {
        lock.withLock {
            let calendar = Calendar.current
            var totals: [Date: DailyStat] = [:]
            for record in dictationRows.values {
                let day = calendar.startOfDay(for: record.createdAt)
                var stat = totals[day] ?? DailyStat(day: day, words: 0, dictations: 0, duration: 0)
                stat.words += Stats.wordCount(record.inserted)
                stat.dictations += 1
                stat.duration += record.duration
                totals[day] = stat
            }
            return totals.values.sorted { $0.day < $1.day }
        }
    }

    func upsert(_ note: NoteRecord) throws {
        lock.withLock { noteRows[note.id] = note }
    }

    func notes(matching query: String?) throws -> [NoteRecord] {
        lock.withLock {
            var rows = Array(noteRows.values)
            if let query, !query.isEmpty {
                rows = rows.filter {
                    $0.title.localizedCaseInsensitiveContains(query)
                        || $0.text.localizedCaseInsensitiveContains(query)
                }
            }
            rows.sort { ($0.pinned ? 1 : 0, $0.updatedAt) > ($1.pinned ? 1 : 0, $1.updatedAt) }
            return rows
        }
    }

    func setPinned(note id: UUID, _ pinned: Bool) throws {
        lock.withLock { noteRows[id]?.pinned = pinned }
    }

    func delete(note id: UUID) throws {
        lock.withLock { _ = noteRows.removeValue(forKey: id) }
    }
}
