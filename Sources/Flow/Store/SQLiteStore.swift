import Foundation
import SQLite3
import OSLog

/// SQLite-backed `HistoryStore`. One file in Application Support, WAL mode, guarded
/// by a lock so it is safe to touch from the dictation task and the UI alike.
final class SQLiteStore: HistoryStore, @unchecked Sendable {
    private let db: OpaquePointer
    private let lock = NSLock()
    private static let log = Logger(subsystem: "sh.taf.flow", category: "store")

    /// sqlite3 needs to copy bound strings; the default is to assume they outlive the step.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    enum StoreError: Error, LocalizedError {
        case open(String)
        case sql(String)
        var errorDescription: String? {
            switch self {
            case .open(let m): "Could not open the history database: \(m)"
            case .sql(let m): "History query failed: \(m)"
            }
        }
    }

    static func defaultURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("Flow", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("history.sqlite")
    }

    init(url: URL) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw StoreError.open(msg)
        }
        db = handle
        try migrate()
        Self.log.info("history at \(url.path, privacy: .public)")
    }

    deinit { sqlite3_close_v2(db) }

    // MARK: - Schema

    private func migrate() throws {
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA foreign_keys=ON;")
        try exec("""
            CREATE TABLE IF NOT EXISTS dictation (
                id TEXT PRIMARY KEY,
                raw TEXT NOT NULL,
                cleaned TEXT NOT NULL,
                app_bundle_id TEXT NOT NULL,
                app_name TEXT NOT NULL,
                created_at REAL NOT NULL,
                duration REAL NOT NULL,
                pinned INTEGER NOT NULL DEFAULT 0,
                tags TEXT NOT NULL DEFAULT ''
            );
            """)
        try exec("CREATE INDEX IF NOT EXISTS dictation_created ON dictation(created_at DESC);")
        try exec("""
            CREATE TABLE IF NOT EXISTS note (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                text TEXT NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                pinned INTEGER NOT NULL DEFAULT 0,
                summary TEXT
            );
            """)
        try exec("CREATE INDEX IF NOT EXISTS note_updated ON note(updated_at DESC);")
        try exec("""
            CREATE TABLE IF NOT EXISTS daily_stat (
                day REAL PRIMARY KEY,
                words INTEGER NOT NULL DEFAULT 0,
                dictations INTEGER NOT NULL DEFAULT 0,
                duration REAL NOT NULL DEFAULT 0
            );
            """)
        try backfillDailyStats()
    }

    /// Populates the aggregate table from existing transcripts the first time this
    /// version runs, so upgrading does not start the activity graph from empty.
    private func backfillDailyStats() throws {
        let existing = try read("SELECT COUNT(*) FROM daily_stat;", binds: { _ in }, row: { sqlite3_column_int($0, 0) })
        guard existing.first == 0 else { return }

        let calendar = Calendar.current
        var totals: [Date: DailyStat] = [:]
        for record in try dictations(matching: nil, limit: nil) {
            let day = calendar.startOfDay(for: record.createdAt)
            var stat = totals[day] ?? DailyStat(day: day, words: 0, dictations: 0, duration: 0)
            stat.words += Stats.wordCount(record.inserted)
            stat.dictations += 1
            stat.duration += record.duration
            totals[day] = stat
        }
        for stat in totals.values { try addDailyStat(stat) }
    }

    // MARK: - Dictations

    /// Adds one day's worth onto whatever is already recorded for that day.
    private func addDailyStat(_ stat: DailyStat) throws {
        try write("""
            INSERT INTO daily_stat (day, words, dictations, duration) VALUES (?,?,?,?)
            ON CONFLICT(day) DO UPDATE SET
                words = words + excluded.words,
                dictations = dictations + excluded.dictations,
                duration = duration + excluded.duration;
            """) { s in
            sqlite3_bind_double(s, 1, stat.day.timeIntervalSince1970)
            sqlite3_bind_int(s, 2, Int32(stat.words))
            sqlite3_bind_int(s, 3, Int32(stat.dictations))
            sqlite3_bind_double(s, 4, stat.duration)
        }
    }

    func dailyStats() throws -> [DailyStat] {
        try read("SELECT day, words, dictations, duration FROM daily_stat ORDER BY day;", binds: { _ in }) { s in
            DailyStat(
                day: Date(timeIntervalSince1970: sqlite3_column_double(s, 0)),
                words: Int(sqlite3_column_int(s, 1)),
                dictations: Int(sqlite3_column_int(s, 2)),
                duration: sqlite3_column_double(s, 3)
            )
        }
    }

    func insert(_ d: DictationRecord) throws {
        try write("""
            INSERT OR REPLACE INTO dictation
            (id, raw, cleaned, app_bundle_id, app_name, created_at, duration, pinned, tags)
            VALUES (?,?,?,?,?,?,?,?,?);
            """) { s in
            bind(s, 1, d.id.uuidString)
            bind(s, 2, d.raw)
            bind(s, 3, d.cleaned)
            bind(s, 4, d.appBundleID)
            bind(s, 5, d.appName)
            sqlite3_bind_double(s, 6, d.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(s, 7, d.duration)
            sqlite3_bind_int(s, 8, d.pinned ? 1 : 0)
            bind(s, 9, d.tags.joined(separator: "\u{1F}"))
        }

        // Mirror into the aggregate, which retention will not purge.
        try addDailyStat(DailyStat(
            day: Calendar.current.startOfDay(for: d.createdAt),
            words: Stats.wordCount(d.inserted),
            dictations: 1,
            duration: d.duration
        ))
    }

    func dictations(matching query: String?, limit: Int?) throws -> [DictationRecord] {
        // Pinned float to the top, then newest first.
        var sql = "SELECT id, raw, cleaned, app_bundle_id, app_name, created_at, duration, pinned, tags FROM dictation"
        let term = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtering = !(term ?? "").isEmpty
        if filtering { sql += " WHERE raw LIKE ?1 OR cleaned LIKE ?1 OR app_name LIKE ?1" }
        sql += " ORDER BY pinned DESC, created_at DESC"
        if let limit { sql += " LIMIT \(limit)" }

        return try read(sql) { s in
            if filtering { bind(s, 1, "%\(term!)%") }
        } row: { s in
            DictationRecord(
                id: UUID(uuidString: text(s, 0)) ?? UUID(),
                raw: text(s, 1),
                cleaned: text(s, 2),
                appBundleID: text(s, 3),
                appName: text(s, 4),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(s, 5)),
                duration: sqlite3_column_double(s, 6),
                pinned: sqlite3_column_int(s, 7) == 1,
                tags: text(s, 8).split(separator: "\u{1F}").map(String.init)
            )
        }
    }

    func setPinned(dictation id: UUID, _ pinned: Bool) throws {
        try write("UPDATE dictation SET pinned = ? WHERE id = ?;") { s in
            sqlite3_bind_int(s, 1, pinned ? 1 : 0)
            bind(s, 2, id.uuidString)
        }
    }

    func delete(dictation id: UUID) throws {
        try write("DELETE FROM dictation WHERE id = ?;") { bind($0, 1, id.uuidString) }
    }

    /// Retention sweep. Pinned rows survive; you pinned them for a reason.
    func purgeDictations(before cutoff: Date) throws {
        try write("DELETE FROM dictation WHERE created_at < ? AND pinned = 0;") {
            sqlite3_bind_double($0, 1, cutoff.timeIntervalSince1970)
        }
    }

    // MARK: - Notes

    func upsert(_ n: NoteRecord) throws {
        try write("""
            INSERT OR REPLACE INTO note
            (id, title, text, created_at, updated_at, pinned, summary)
            VALUES (?,?,?,?,?,?,?);
            """) { s in
            bind(s, 1, n.id.uuidString)
            bind(s, 2, n.title)
            bind(s, 3, n.text)
            sqlite3_bind_double(s, 4, n.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(s, 5, n.updatedAt.timeIntervalSince1970)
            sqlite3_bind_int(s, 6, n.pinned ? 1 : 0)
            if let summary = n.summary { bind(s, 7, summary) } else { sqlite3_bind_null(s, 7) }
        }
    }

    func notes(matching query: String?) throws -> [NoteRecord] {
        var sql = "SELECT id, title, text, created_at, updated_at, pinned, summary FROM note"
        let term = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtering = !(term ?? "").isEmpty
        if filtering { sql += " WHERE title LIKE ?1 OR text LIKE ?1" }
        sql += " ORDER BY pinned DESC, updated_at DESC"

        return try read(sql) { s in
            if filtering { bind(s, 1, "%\(term!)%") }
        } row: { s in
            NoteRecord(
                id: UUID(uuidString: text(s, 0)) ?? UUID(),
                title: text(s, 1),
                text: text(s, 2),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(s, 3)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(s, 4)),
                pinned: sqlite3_column_int(s, 5) == 1,
                summary: sqlite3_column_type(s, 6) == SQLITE_NULL ? nil : text(s, 6)
            )
        }
    }

    func setPinned(note id: UUID, _ pinned: Bool) throws {
        try write("UPDATE note SET pinned = ? WHERE id = ?;") { s in
            sqlite3_bind_int(s, 1, pinned ? 1 : 0)
            bind(s, 2, id.uuidString)
        }
    }

    func delete(note id: UUID) throws {
        try write("DELETE FROM note WHERE id = ?;") { bind($0, 1, id.uuidString) }
    }

    // MARK: - sqlite plumbing

    private func bind(_ s: OpaquePointer, _ i: Int32, _ value: String) {
        sqlite3_bind_text(s, i, value, -1, Self.transient)
    }

    private func text(_ s: OpaquePointer, _ i: Int32) -> String {
        sqlite3_column_text(s, i).map { String(cString: $0) } ?? ""
    }

    private func exec(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw StoreError.sql(msg)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK, let s else {
            throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
        }
        return s
    }

    private func write(_ sql: String, _ binds: (OpaquePointer) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        let s = try prepare(sql)
        defer { sqlite3_finalize(s) }
        binds(s)
        guard sqlite3_step(s) == SQLITE_DONE else {
            throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func read<T>(
        _ sql: String,
        binds: (OpaquePointer) -> Void,
        row: (OpaquePointer) -> T
    ) throws -> [T] {
        lock.lock(); defer { lock.unlock() }
        let s = try prepare(sql)
        defer { sqlite3_finalize(s) }
        binds(s)
        var out: [T] = []
        while sqlite3_step(s) == SQLITE_ROW { out.append(row(s)) }
        return out
    }
}
