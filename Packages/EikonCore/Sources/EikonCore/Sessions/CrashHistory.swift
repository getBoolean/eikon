import Foundation

/// One unclean session, kept so a report can be filed later.
public struct CrashEntry: Codable, Sendable, Equatable, Identifiable {
    /// The session id.
    public var id: UUID
    public var record: SessionRecord
    public var outcome: SessionOutcome
    public var breadcrumbs: [Breadcrumb]
    public var fault: FaultRecord?
    public var recordedAt: Date

    public init(id: UUID, record: SessionRecord, outcome: SessionOutcome, breadcrumbs: [Breadcrumb],
                fault: FaultRecord?, recordedAt: Date) {
        self.id = id
        self.record = record
        self.outcome = outcome
        self.breadcrumbs = breadcrumbs
        self.fault = fault
        self.recordedAt = recordedAt
    }
}

private struct HistoryDocument: PersistedDocument {
    static let currentFormat = 1
    var entries: TolerantList<CrashEntry>
}

/// `history.json`: the newest `limitPerGame` unclean sessions per game. Ids, codes and
/// integers only. A file from a newer build is never rewritten.
public final class CrashHistory: @unchecked Sendable {
    public static let limitPerGame = 5

    private let file: PersistedFile<HistoryDocument>
    private let lock = NSLock()
    private var document: HistoryDocument
    private var readOnly: Bool

    public init(directory: URL) {
        file = PersistedFile(url: directory.appendingPathComponent("history.json"))
        do {
            let loaded = try file.load()
            document = loaded?.document ?? HistoryDocument(entries: TolerantList())
            readOnly = loaded?.isReadOnly ?? false
        } catch {
            // Present but unreadable: keep working in memory and never overwrite it.
            document = HistoryDocument(entries: TolerantList())
            readOnly = true
        }
    }

    /// Classifies, stores, trims the game's entries to the newest `limitPerGame`, persists.
    @discardableResult
    public func add(_ consumed: ConsumedSession, now: Date) -> CrashEntry {
        let entry = CrashEntry(id: consumed.record.sessionID, record: consumed.record,
                               outcome: SessionOutcome.classify(consumed), breadcrumbs: consumed.breadcrumbs,
                               fault: consumed.fault, recordedAt: now)
        lock.withLock {
            var elements = document.entries.elements.filter { $0.id != entry.id }
            elements.append(entry)
            let game = entry.record.gameID
            let keep = Set(Self.newestFirst(elements.filter { $0.record.gameID == game }).prefix(Self.limitPerGame).map(\.id))
            elements.removeAll { $0.record.gameID == game && !keep.contains($0.id) }
            document.entries.elements = elements
            if !readOnly { try? file.save(document) }
        }
        return entry
    }

    /// Newest first.
    public func entries(for game: GameID) -> [CrashEntry] {
        lock.withLock { Self.newestFirst(document.entries.elements.filter { $0.record.gameID == game }) }
    }

    public func entry(id: UUID) -> CrashEntry? {
        lock.withLock { document.entries.elements.first { $0.id == id } }
    }

    private static func newestFirst(_ entries: [CrashEntry]) -> [CrashEntry] {
        entries.sorted {
            ($0.record.startedAt, $0.recordedAt) > ($1.record.startedAt, $1.recordedAt)
        }
    }
}
