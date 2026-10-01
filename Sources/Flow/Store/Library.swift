import Foundation
import Observation
import OSLog

/// Each recording owns its results, including requests that finish after insertion
/// or after the next recording starts.
@MainActor
final class DictationVersionCapture {
    let id = UUID()
    private let library: Library
    private var dictationID: UUID?
    private(set) var versions: [DictationVersion] = []

    init(library: Library) { self.library = library }

    func append(_ version: DictationVersion) {
        guard !version.text.isEmpty, !versions.contains(where: { $0.id == version.id }) else { return }
        versions.append(version)
        if let dictationID { library.addVersion(version, to: dictationID) }
    }

    func attach(to dictationID: UUID) { self.dictationID = dictationID }
}

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
    private(set) var cloudRequests: [CloudRequestRecord] = []
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
            cloudRequests = try store.cloudRequests()
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

    func addVersion(_ version: DictationVersion, to dictationID: UUID) {
        perform { try store.addVersion(version, to: dictationID) }
    }

    func recordRequest(_ request: CloudRequestRecord) {
        if let previous = cloudRequests.first(where: { $0.id == request.id }),
           previous.status != .running && request.status == .running { return }
        do {
            try store.saveRequest(request)
            if let index = cloudRequests.firstIndex(where: { $0.id == request.id }) { cloudRequests[index] = request }
            else { cloudRequests.insert(request, at: 0) }
        } catch {
            loadFailure = error.localizedDescription
            log.error("request log failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func interruptOldRequests() {
        for var request in cloudRequests where request.status == .running {
            request.status = .interrupted
            recordRequest(request)
        }
    }

    func requests(for dictationID: UUID, configID: UUID? = nil) -> [CloudRequestRecord] {
        cloudRequests.filter { $0.dictationID == dictationID && (configID == nil || $0.configID == configID) }
            .sorted { $0.startedAt < $1.startedAt }
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
    private var requestRows: [UUID: CloudRequestRecord] = [:]

    func saveRequest(_ request: CloudRequestRecord) throws {
        lock.withLock { requestRows[request.id] = request }
    }

    func cloudRequests() throws -> [CloudRequestRecord] {
        lock.withLock { requestRows.values.sorted { $0.startedAt > $1.startedAt } }
    }

    func insert(_ dictation: DictationRecord) throws {
        lock.withLock { dictationRows[dictation.id] = dictation }
    }

    func addVersion(_ version: DictationVersion, to dictationID: UUID) throws {
        lock.withLock {
            guard var record = dictationRows[dictationID],
                  !record.versions.contains(where: { $0.id == version.id }) else { return }
            record.versions.append(version)
            dictationRows[dictationID] = record
        }
    }

    func dictations(matching query: String?, limit: Int?) throws -> [DictationRecord] {
        lock.withLock {
            var rows = Array(dictationRows.values)
            if let query, !query.isEmpty {
                rows = rows.filter {
                    $0.raw.localizedCaseInsensitiveContains(query)
                        || $0.cleaned.localizedCaseInsensitiveContains(query)
                        || $0.versions.contains { $0.text.localizedCaseInsensitiveContains(query) }
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
        lock.withLock {
            _ = dictationRows.removeValue(forKey: id)
            for key in requestRows.keys where requestRows[key]?.dictationID == id { requestRows[key]?.dictationID = nil }
        }
    }

    func purgeDictations(before cutoff: Date) throws {
        lock.withLock {
            let purged = Set(dictationRows.values.filter { !$0.pinned && $0.createdAt < cutoff }.map(\.id))
            dictationRows = dictationRows.filter { !purged.contains($0.key) }
            for key in requestRows.keys {
                if let id = requestRows[key]?.dictationID, purged.contains(id) { requestRows[key]?.dictationID = nil }
            }
        }
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
