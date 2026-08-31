import Foundation

/// Persistence seam.
///
/// The plan calls for SwiftData. Its `@Model` macro needs the macro plugin that
/// ships with Xcode, which this toolchain does not have, so the shipping
/// implementation is `SQLiteStore`. Everything above this protocol is unaware of
/// which one it is talking to; swapping in a SwiftData-backed store later means
/// writing one new conformance and changing one line in `Library`.
protocol HistoryStore: AnyObject, Sendable {
    func insert(_ dictation: DictationRecord) throws
    func dictations(matching query: String?, limit: Int?) throws -> [DictationRecord]
    func setPinned(dictation id: UUID, _ pinned: Bool) throws
    func delete(dictation id: UUID) throws
    func purgeDictations(before cutoff: Date) throws
    /// Daily totals, which retention never touches.
    func dailyStats() throws -> [DailyStat]

    func upsert(_ note: NoteRecord) throws
    func notes(matching query: String?) throws -> [NoteRecord]
    func setPinned(note id: UUID, _ pinned: Bool) throws
    func delete(note id: UUID) throws
}
