import Craft
import Foundation
import SQLite3

/// JSON owns the record. The database can be removed and regenerated from it.
actor SubConversationStore {
    static let shared = SubConversationStore(teamRoot: Disk.root)
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
        guard !respectsRestore || !Disk.frozen else { throw Failure.restoring }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: path(record.id), options: [.atomic, .completeFileProtection])
        projectionDirty = true
        // A damaged or unavailable projection must not turn a committed JSON write into a retry.
        try? rebuildProjection()
    }

    private func replaceProjection(with records: [SubConversationRecord]) throws {
        try FileManager.default.createDirectory(at: projectionURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard sqlite3_open_v2(projectionURL.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw Failure.projection
        }
        func execute(_ sql: String) throws {
            guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw Failure.projection }
        }

        try execute("BEGIN IMMEDIATE")
        do {
            try execute("""
                DROP TABLE IF EXISTS sub_conversations;
                CREATE TABLE sub_conversations (
                  id TEXT PRIMARY KEY, source_chat TEXT NOT NULL, source_entry TEXT NOT NULL,
                  plan INTEGER NOT NULL, tainted INTEGER NOT NULL, promoted_chat TEXT
                );
                CREATE INDEX subconv_source ON sub_conversations(source_chat, source_entry);
                """)
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(database, "INSERT INTO sub_conversations VALUES (?, ?, ?, ?, ?, ?)", -1, &statement, nil) == SQLITE_OK else {
                throw Failure.projection
            }
            let copy = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for item in records {
                guard sqlite3_reset(statement) == SQLITE_OK,
                      sqlite3_bind_text(statement, 1, item.id.uuidString, -1, copy) == SQLITE_OK,
                      sqlite3_bind_text(statement, 2, item.origin.sourceChatKey, -1, copy) == SQLITE_OK,
                      sqlite3_bind_text(statement, 3, item.origin.sourceEntryID, -1, copy) == SQLITE_OK,
                      sqlite3_bind_int(statement, 4, item.inheritedPlanMode ? 1 : 0) == SQLITE_OK,
                      sqlite3_bind_int(statement, 5, item.tainted ? 1 : 0) == SQLITE_OK else { throw Failure.projection }
                let promoted: Int32
                if let key = item.promotedChatKey {
                    promoted = sqlite3_bind_text(statement, 6, key, -1, copy)
                } else {
                    promoted = sqlite3_bind_null(statement, 6)
                }
                guard promoted == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else { throw Failure.projection }
            }
            try execute("COMMIT")
            projectionDirty = false
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}
