import Craft
import Foundation

/// JSON owns the record. The database can be removed and regenerated from it.
actor SubConversationStore {
    static let shared = SubConversationStore(teamRoot: Disk.root)
    /// Synchronous lock serializing canonical JSON writes against `Backup.restore`'s freeze barrier
    /// so no write that passed `!Disk.frozen` can cross directory staging or directory swap.
    private static let writeBarrierLock = NSLock()

    static func withBackupBarrier<T>(_ body: () throws -> T) rethrows -> T {
        try writeBarrierLock.withLock {
            try body()
        }
    }

    let directory: URL
    let projectionURL: URL
    private let respectsRestore: Bool
    private var projectionDirty = true

    init(teamRoot: URL, indexRoot: URL? = nil) {
        directory = teamRoot.appendingPathComponent("subconversations", isDirectory: true)
        projectionURL = (indexRoot ?? teamRoot.deletingLastPathComponent()
            .appendingPathComponent("ClioIndex", isDirectory: true))
            .appendingPathComponent("clio-subconv.db")
        respectsRestore = indexRoot == nil
    }

    enum Failure: Error {
        case missing, conflictingOrigin, projection, restoring
    }

    func load(_ id: UUID) throws -> SubConversationRecord {
        let data = try Data(contentsOf: path(id))
        let record = try JSONDecoder().decode(SubConversationRecord.self, from: data)
        guard record.id == id else { throw Failure.conflictingOrigin }
        return record
    }

    func save(_ record: SubConversationRecord) throws {
        if FileManager.default.fileExists(atPath: path(record.id).path) {
            let prior = try load(record.id)
            guard prior == record else { throw Failure.conflictingOrigin }
            return
        }
        try write(record)
    }

    func findOrCreate(origin: SubConversationOrigin, planMode: Bool, tainted: Bool) throws -> SubConversationRecord {
        if let existing = try records().first(where: { $0.origin == origin && $0.promotedChatKey == nil }) {
            return try update(existing.id) { $0.inheritParent(planMode: planMode, tainted: tainted) }
        }
        let record = SubConversationRecord(origin: origin, inheritedPlanMode: planMode, inheritedTaint: tainted)
        try save(record)
        return record
    }

    @discardableResult
    func update(_ id: UUID, _ change: @Sendable (inout SubConversationRecord) -> Void) throws -> SubConversationRecord {
        var record = try load(id)
        let prior = record
        change(&record)
        if prior != record { try write(record) }
        return record
    }

    func promote(_ id: UUID, summary: String) throws -> (chatKey: String, transfer: SubConversationPolicy.Transfer) {
        let record = try update(id) { item in
            _ = item.recordPromotion(to: "sub-\(id.uuidString)")
        }
        guard let key = record.promotedChatKey else { throw Failure.missing }
        return (key, SubConversationPolicy.promoteToIndependentChat(record, summary: summary))
    }

    func records() throws -> [SubConversationRecord] {
        let records = try canonicalRecords()
        if projectionDirty || !FileManager.default.fileExists(atPath: projectionURL.path) {
            try? replaceProjection(with: records)
        }
        return records
    }

    func rebuildProjection() throws {
        try replaceProjection(with: canonicalRecords())
    }

    private func path(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    private func canonicalRecords() throws -> [SubConversationRecord] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var loaded: [SubConversationRecord] = []
        for url in files {
            guard url.pathExtension == "json",
                  let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
            do {
                loaded.append(try load(id))
            } catch {
                // Keep the corrupt file untouched on disk and skip it instead of breaking the whole store.
                let name = url.lastPathComponent
                let reason = error.localizedDescription
                DispatchQueue.main.async {
                    Diag.note("子对话文件 \(name) 损坏，已跳过保留原件（\(reason)）")
                }
            }
        }
        return loaded
    }

    private func write(_ record: SubConversationRecord) throws {
        let encoded = try JSONEncoder().encode(record)
        let targetDir = directory
        let targetPath = path(record.id)
        let checkRestore = respectsRestore
        try Self.writeBarrierLock.withLock {
            guard !checkRestore || !Disk.frozen else { throw Failure.restoring }
            try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
            try encoded.write(to: targetPath, options: [.atomic, .completeFileProtection])
        }
        projectionDirty = true
        // A damaged or unavailable projection must not turn a committed JSON write into a retry.
        try? rebuildProjection()
    }

    private func replaceProjection(with records: [SubConversationRecord]) throws {
        let options = SQLiteOpenOptions(
            busyTimeoutMs: 5_000,
            enableWAL: true,
            enableForeignKeys: true,
            synchronousNormal: true,
            applyFileProtection: true,
            excludeFromBackup: true
        )

        func writeAll() throws {
            let conn = try SQLiteConnection.open(at: projectionURL, options: options)
            defer { conn.close() }
            try conn.withTransaction(immediate: true) { db in
                try db.execute("""
                    DROP TABLE IF EXISTS sub_conversations;
                    CREATE TABLE sub_conversations (
                      id TEXT PRIMARY KEY, source_chat TEXT NOT NULL, source_entry TEXT NOT NULL,
                      plan INTEGER NOT NULL, tainted INTEGER NOT NULL, promoted_chat TEXT
                    );
                    CREATE INDEX subconv_source ON sub_conversations(source_chat, source_entry);
                    """)
                let stmt = try db.prepare("INSERT INTO sub_conversations VALUES (?, ?, ?, ?, ?, ?)")
                defer { stmt.finalize() }
                for item in records {
                    try stmt.reset()
                    try stmt.bind(item.id.uuidString, at: 1)
                    try stmt.bind(item.origin.sourceChatKey, at: 2)
                    try stmt.bind(item.origin.sourceEntryID, at: 3)
                    try stmt.bind(item.inheritedPlanMode, at: 4)
                    try stmt.bind(item.tainted, at: 5)
                    try stmt.bind(item.promotedChatKey, at: 6)
                    try stmt.step()
                }
            }
            SQLiteConnection.applyFileAttributes(at: projectionURL, options: options)
            projectionDirty = false
        }

        do {
            try writeAll()
        } catch let error as SQLiteEngineError where error.isCorruption {
            // Only quarantine and rebuild on confirmed structural corruption, never on SQLITE_BUSY.
            _ = SQLiteConnection.quarantineCorruptDatabase(at: projectionURL)
            do {
                try writeAll()
            } catch {
                throw Failure.projection
            }
        } catch {
            throw Failure.projection
        }
    }
}
