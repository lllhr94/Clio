import Foundation
import SQLite3

private let experienceSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Provenance gate for persisting reusable procedural experiences.
/// Only interactive main conversation, explicit user edits, or user-initiated imports may write.
public enum ExperienceWriteSource: String, Codable, Hashable, Sendable {
    case mainChat = "main_chat"
    case user = "user"
    case importAction = "import"
    case subtask = "subtask"
    case casualTrack = "casual_track"
    case routine = "routine"

    public var isAllowedToPersist: Bool {
        switch self {
        case .mainChat, .user, .importAction:
            return true
        case .subtask, .casualTrack, .routine:
            return false
        }
    }
}

public enum ExperienceStoreError: Error, LocalizedError, Equatable, Sendable {
    case writeNotAllowed(ExperienceWriteSource)
    case emptyContent
    case suppressedByTombstone
    case canonicalReadOnly(String)
    case sqlite(code: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case .writeNotAllowed(let source):
            return "当前来源（\(source.rawValue)）不允许写入经验库。"
        case .emptyContent:
            return "经验内容不能为空或仅包含敏感密钥。"
        case .suppressedByTombstone:
            return "该条经验已列入撤回名单，已阻止再次写入。"
        case .canonicalReadOnly(let detail):
            return "经验档案暂不可写：\(detail)"
        case .sqlite(let code, let message):
            return "经验索引数据库异常 (\(code)): \(message)"
        }
    }
}

public struct ExperienceRecord: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var content: String
    public var tags: [String]
    public var contentSHA256: String
    public var createdAtMs: Double
    public var updatedAtMs: Double
    public var usedAtMs: Double?
    public var useCount: Int
    public var deletedAtMs: Double?
    public var source: ExperienceWriteSource

    public init(
        id: String = UUID().uuidString.lowercased(),
        title: String,
        content: String,
        tags: [String] = [],
        contentSHA256: String? = nil,
        createdAtMs: Double = Date().timeIntervalSince1970 * 1000,
        updatedAtMs: Double? = nil,
        usedAtMs: Double? = nil,
        useCount: Int = 0,
        deletedAtMs: Double? = nil,
        source: ExperienceWriteSource = .mainChat
    ) {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = trimmedID.isEmpty ? UUID().uuidString.lowercased() : trimmedID
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = cleanTitle
        self.content = cleanContent
        self.tags = tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let hashInput = cleanTitle.isEmpty ? cleanContent : "\(cleanTitle)\n\(cleanContent)"
        self.contentSHA256 = (contentSHA256?.isEmpty == false ? contentSHA256! : MemorySafety.retractionHash(hashInput)).lowercased()
        self.createdAtMs = createdAtMs
        self.updatedAtMs = updatedAtMs ?? createdAtMs
        self.usedAtMs = usedAtMs
        self.useCount = Self.clampUseCount(useCount)
        self.deletedAtMs = deletedAtMs
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, content, tags, contentSHA256, createdAtMs, updatedAtMs, usedAtMs, useCount, deletedAtMs, source
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(String.self, forKey: .id)
        let title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        let content = try c.decode(String.self, forKey: .content)
        let tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        let contentSHA256 = try c.decodeIfPresent(String.self, forKey: .contentSHA256)
        let createdAtMs = try c.decodeIfPresent(Double.self, forKey: .createdAtMs) ?? 0
        let updatedAtMs = try c.decodeIfPresent(Double.self, forKey: .updatedAtMs)
        let usedAtMs = try c.decodeIfPresent(Double.self, forKey: .usedAtMs)
        let rawUseCount = try c.decodeIfPresent(Int64.self, forKey: .useCount) ?? 0
        let deletedAtMs = try c.decodeIfPresent(Double.self, forKey: .deletedAtMs)
        let source = try c.decodeIfPresent(ExperienceWriteSource.self, forKey: .source) ?? .mainChat
        self.init(
            id: id,
            title: title,
            content: content,
            tags: tags,
            contentSHA256: contentSHA256,
            createdAtMs: createdAtMs,
            updatedAtMs: updatedAtMs,
            usedAtMs: usedAtMs,
            useCount: Self.clampUseCount(Int(clamping: rawUseCount)),
            deletedAtMs: deletedAtMs,
            source: source
        )
    }

    static func clampUseCount(_ value: Int) -> Int {
        max(0, min(Int(Int32.max), value))
    }

    static func clampedIncrement(_ value: Int) -> Int {
        value >= Int(Int32.max) ? Int(Int32.max) : max(0, value) + 1
    }
}

public struct CanonicalExperienceBook: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var updatedAtMs: Double
    public var records: [ExperienceRecord]
    public var retractedHashes: [String]

    public init(
        schemaVersion: Int = CanonicalExperienceBook.currentSchemaVersion,
        updatedAtMs: Double = 0,
        records: [ExperienceRecord] = [],
        retractedHashes: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAtMs = updatedAtMs
        self.records = records
        self.retractedHashes = Array(Set(retractedHashes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })).sorted()
    }

    /// Merges external retraction hashes into this book and tombstones matching experience entries.
    public mutating func mergeRetractionsAndPrune(hashes externalHashes: Set<String>, nowMs: Double) {
        let normalized = Set(externalHashes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })
        guard !normalized.isEmpty else { return }
        var combined = Set(retractedHashes.map { $0.lowercased() })
        combined.formUnion(normalized)
        retractedHashes = combined.sorted()

        for index in records.indices {
            guard records[index].deletedAtMs == nil else { continue }
            let hash = records[index].contentSHA256.lowercased()
            let contentOnlyHash = MemorySafety.retractionHash(records[index].content)
            if combined.contains(hash) || (!contentOnlyHash.isEmpty && combined.contains(contentOnlyHash)) {
                records[index].deletedAtMs = nowMs
                records[index].updatedAtMs = max(records[index].updatedAtMs, nowMs)
            }
        }
        updatedAtMs = max(updatedAtMs, nowMs)
    }
}

public struct ExperienceHit: Equatable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var content: String
    public var tags: [String]
    public var contentSHA256: String
    public var score: Double
    public var useCount: Int
    public var updatedAtMs: Double
    public var usedAtMs: Double?

    public init(
        id: String,
        title: String,
        content: String,
        tags: [String],
        contentSHA256: String,
        score: Double,
        useCount: Int,
        updatedAtMs: Double,
        usedAtMs: Double?
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.tags = tags
        self.contentSHA256 = contentSHA256
        self.score = score
        self.useCount = useCount
        self.updatedAtMs = updatedAtMs
        self.usedAtMs = usedAtMs
    }
}

/// Reusable procedural experience store combining a backup-included canonical JSON (`Team/experiences.json`)
/// with an off-backup SQLite + FTS5 hybrid (`NLTokenizer` + CJK Bigram) search projection in `ClioMemory/clio-memory.db`.
public final class ExperienceStore: @unchecked Sendable {
    public let canonicalFileURL: URL?
    public let databaseURL: URL?
    private let forceDisableFTS5: Bool
    private let lock = NSLock()
    private var db: OpaquePointer?
    private var fts5Enabled = false
    private var lastSyncedCanonicalKey: String?
    private var openedDatabaseEpoch: UInt64 = 0
    private var openedFileInode: UInt64?

    public init(
        canonicalFileURL: URL?,
        databaseURL: URL?,
        forceDisableFTS5ForTesting: Bool = false
    ) {
        self.canonicalFileURL = canonicalFileURL
        self.databaseURL = databaseURL
        self.forceDisableFTS5 = forceDisableFTS5ForTesting
    }

    public static func inMemory(forceDisableFTS5ForTesting: Bool = false) -> ExperienceStore {
        ExperienceStore(
            canonicalFileURL: nil,
            databaseURL: nil,
            forceDisableFTS5ForTesting: forceDisableFTS5ForTesting
        )
    }

    deinit {
        lock.lock()
        closeLocked()
        lock.unlock()
    }

    public var isFTS5Active: Bool {
        lock.lock()
        defer { lock.unlock() }
        _ = try? openOrSyncLocked(secrets: [])
        return fts5Enabled
    }

    public func loadAll(includeDeleted: Bool = false, secrets: [String] = []) throws -> [ExperienceRecord] {
        lock.lock()
        defer { lock.unlock() }

        let orderedSecrets = Self.orderSecrets(secrets)
        if canonicalFileURL != nil {
            let book = try readCanonicalBookLocked()
            return book.records
                .filter { includeDeleted || $0.deletedAtMs == nil }
                .map { Self.redactedRecord($0, orderedSecrets: orderedSecrets) }
                .sorted { lhs, rhs in
                    if lhs.updatedAtMs != rhs.updatedAtMs { return lhs.updatedAtMs > rhs.updatedAtMs }
                    return lhs.id < rhs.id
                }
        }

        try openOrSyncLocked(secrets: orderedSecrets)
        return try readSQLiteRecordsLocked(includeDeleted: includeDeleted, orderedSecrets: orderedSecrets)
    }

    public func readBook() throws -> CanonicalExperienceBook {
        lock.lock()
        defer { lock.unlock() }
        return try readCanonicalBookLocked()
    }

    @discardableResult
    public func record(
        id: String? = nil,
        title: String,
        content: String,
        tags: [String] = [],
        source: ExperienceWriteSource,
        nowMs: Double = Date().timeIntervalSince1970 * 1000,
        secrets: [String] = [],
        suppressedHashes: Set<String> = []
    ) throws -> ExperienceRecord {
        guard source.isAllowedToPersist else {
            throw ExperienceStoreError.writeNotAllowed(source)
        }

        let orderedSecrets = Self.orderSecrets(secrets)
        let safeTitle = MemorySafety.redactSecrets(title, secrets: orderedSecrets)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safeContent = MemorySafety.redactSecrets(content, secrets: orderedSecrets)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutMask = safeContent.replacingOccurrences(of: "〔隐去〕", with: "")
        guard !safeContent.isEmpty, !MemorySafety.normalizedFactKey(withoutMask).isEmpty else {
            throw ExperienceStoreError.emptyContent
        }
        let safeTags = tags
            .map { MemorySafety.redactSecrets($0, secrets: orderedSecrets).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.replacingOccurrences(of: "〔隐去〕", with: "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        let normalizedHashInput = safeTitle.isEmpty ? safeContent : "\(safeTitle)\n\(safeContent)"
        let safeHash = MemorySafety.retractionHash(normalizedHashInput)
        let contentHash = MemorySafety.retractionHash(safeContent)
        let externalSuppressed = Set(suppressedHashes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })

        lock.lock()
        defer { lock.unlock() }

        var book = canonicalFileURL != nil ? try readCanonicalBookLocked() : CanonicalExperienceBook(
            records: (try? loadInMemorySQLiteSnapshotLocked(orderedSecrets: orderedSecrets)) ?? []
        )

        let storedSuppressed = Set(book.retractedHashes.map { $0.lowercased() })
        let allSuppressed = externalSuppressed.union(storedSuppressed)
        if source != .user && source != .importAction {
            if allSuppressed.contains(safeHash) || (!contentHash.isEmpty && allSuppressed.contains(contentHash)) {
                throw ExperienceStoreError.suppressedByTombstone
            }
        }

        let existingIndex = id.flatMap { targetID in book.records.firstIndex(where: { $0.id == targetID }) }
            ?? book.records.firstIndex(where: {
                $0.deletedAtMs == nil &&
                MemorySafety.normalizedFactKey($0.title) == MemorySafety.normalizedFactKey(safeTitle) &&
                MemorySafety.normalizedFactKey($0.content) == MemorySafety.normalizedFactKey(safeContent)
            })

        let saved: ExperienceRecord
        if let idx = existingIndex {
            var updated = book.records[idx]
            updated.title = safeTitle
            updated.content = safeContent
            updated.tags = safeTags
            updated.contentSHA256 = safeHash
            updated.updatedAtMs = max(updated.updatedAtMs, nowMs)
            updated.deletedAtMs = nil
            updated.source = source
            book.records[idx] = updated
            saved = updated
        } else {
            let candidate = ExperienceRecord(
                id: id ?? UUID().uuidString.lowercased(),
                title: safeTitle,
                content: safeContent,
                tags: safeTags,
                contentSHA256: safeHash,
                createdAtMs: nowMs,
                updatedAtMs: nowMs,
                usedAtMs: nil,
                useCount: 0,
                deletedAtMs: nil,
                source: source
            )
            book.records.append(candidate)
            saved = candidate
        }

        if source == .user || source == .importAction {
            book.retractedHashes.removeAll { $0 == safeHash || $0 == contentHash }
        }
        book.updatedAtMs = max(book.updatedAtMs, nowMs)

        let writtenDigest = try writeCanonicalBookIfConfiguredLocked(book)
        try openOrSyncLocked(secrets: orderedSecrets, skipSyncIfAlreadyOpen: db != nil && canonicalFileURL != nil)
        try upsertSQLiteRecordLocked(saved, orderedSecrets: orderedSecrets)
        if let writtenDigest {
            lastSyncedCanonicalKey = Self.syncKey(digest: writtenDigest, orderedSecrets: orderedSecrets)
        }
        return saved
    }

    public func delete(
        id: String,
        nowMs: Double = Date().timeIntervalSince1970 * 1000,
        secrets: [String] = []
    ) throws {
        let orderedSecrets = Self.orderSecrets(secrets)
        lock.lock()
        defer { lock.unlock() }

        var deletedRecord: ExperienceRecord?
        if canonicalFileURL != nil {
            var book = try readCanonicalBookLocked()
            if let idx = book.records.firstIndex(where: { $0.id == id }) {
                var target = book.records[idx]
                target.deletedAtMs = nowMs
                target.updatedAtMs = max(target.updatedAtMs, nowMs)
                book.records[idx] = target
                deletedRecord = target
                var hashes = Set(book.retractedHashes)
                if !target.contentSHA256.isEmpty { hashes.insert(target.contentSHA256.lowercased()) }
                let bodyHash = MemorySafety.retractionHash(target.content)
                if !bodyHash.isEmpty { hashes.insert(bodyHash) }
                book.retractedHashes = hashes.sorted()
                book.updatedAtMs = max(book.updatedAtMs, nowMs)
                let writtenDigest = try writeCanonicalBookIfConfiguredLocked(book)
                try openOrSyncLocked(secrets: orderedSecrets, skipSyncIfAlreadyOpen: db != nil)
                try upsertSQLiteRecordLocked(target, orderedSecrets: orderedSecrets)
                if let writtenDigest {
                    lastSyncedCanonicalKey = Self.syncKey(digest: writtenDigest, orderedSecrets: orderedSecrets)
                }
                return
            }
        }

        try openOrSyncLocked(secrets: orderedSecrets)
        if let deletedRecord {
            try upsertSQLiteRecordLocked(deletedRecord, orderedSecrets: orderedSecrets)
        } else {
            try runPreparedLocked("UPDATE experiences SET deleted_at_ms = ?, updated_at_ms = ? WHERE id = ?;", bindings: [
                .double(nowMs),
                .double(nowMs),
                .text(id),
            ])
        }
    }

    public func search(
        query: String,
        limit: Int = 5,
        suppressedHashes: Set<String> = [],
        secrets: [String] = [],
        markUsedNowMs: Double? = nil
    ) throws -> [ExperienceHit] {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuery.isEmpty, limit > 0 else { return [] }
        let analysis = MemoryRecall.analyzeQuery(cleanQuery)
        guard !analysis.isEmpty else { return [] }

        let orderedSecrets = Self.orderSecrets(secrets)
        let normalizedSuppressed = Set(suppressedHashes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })

        lock.lock()
        defer { lock.unlock() }

        let bookRetracted: Set<String>
        if canonicalFileURL != nil {
            let book = try readCanonicalBookLocked()
            bookRetracted = Set(book.retractedHashes.map { $0.lowercased() })
        } else {
            bookRetracted = []
        }
        let allSuppressed = normalizedSuppressed.union(bookRetracted)

        try openOrSyncLocked(secrets: orderedSecrets)
        var hits = try searchSQLiteLocked(
            cleanQuery: cleanQuery,
            analysis: analysis,
            limit: limit,
            suppressedHashes: allSuppressed,
            orderedSecrets: orderedSecrets
        )

        if let markUsedNowMs, !hits.isEmpty {
            let hitIDs = Set(hits.map(\.id))
            if canonicalFileURL != nil {
                var book = try readCanonicalBookLocked()
                for idx in book.records.indices where hitIDs.contains(book.records[idx].id) {
                    book.records[idx].useCount = ExperienceRecord.clampedIncrement(book.records[idx].useCount)
                    book.records[idx].usedAtMs = max(book.records[idx].usedAtMs ?? 0, markUsedNowMs)
                    book.records[idx].updatedAtMs = max(book.records[idx].updatedAtMs, markUsedNowMs)
                }
                book.updatedAtMs = max(book.updatedAtMs, markUsedNowMs)
                if let writtenDigest = try writeCanonicalBookIfConfiguredLocked(book) {
                    lastSyncedCanonicalKey = Self.syncKey(digest: writtenDigest, orderedSecrets: orderedSecrets)
                }
            }
            for id in hitIDs {
                try runPreparedLocked(
                    """
                    UPDATE experiences
                    SET use_count = CASE WHEN use_count >= 2147483647 THEN 2147483647 ELSE use_count + 1 END,
                        used_at_ms = CASE WHEN used_at_ms IS NULL OR used_at_ms < ? THEN ? ELSE used_at_ms END,
                        updated_at_ms = CASE WHEN updated_at_ms < ? THEN ? ELSE updated_at_ms END
                    WHERE id = ? AND deleted_at_ms IS NULL;
                    """,
                    bindings: [
                        .double(markUsedNowMs), .double(markUsedNowMs),
                        .double(markUsedNowMs), .double(markUsedNowMs),
                        .text(id),
                    ]
                )
            }
            for idx in hits.indices {
                hits[idx].useCount = ExperienceRecord.clampedIncrement(hits[idx].useCount)
                hits[idx].usedAtMs = max(hits[idx].usedAtMs ?? 0, markUsedNowMs)
                hits[idx].updatedAtMs = max(hits[idx].updatedAtMs, markUsedNowMs)
            }
        }

        return hits
    }

    public func mergeRetractedHashesAndPrune(
        _ externalHashes: Set<String>,
        nowMs: Double = Date().timeIntervalSince1970 * 1000,
        secrets: [String] = []
    ) throws {
        guard canonicalFileURL != nil else { return }
        let orderedSecrets = Self.orderSecrets(secrets)
        lock.lock()
        defer { lock.unlock() }
        var book = try readCanonicalBookLocked()
        book.mergeRetractionsAndPrune(hashes: externalHashes, nowMs: nowMs)
        try writeCanonicalBookIfConfiguredLocked(book)
        if db != nil || databaseURL != nil {
            try openOrSyncLocked(secrets: orderedSecrets)
        }
    }

    /// Rebuilds the SQLite projection directly from Canonical `experiences.json`.
    public func rebuildFromCanonical(secrets: [String] = []) throws {
        let orderedSecrets = Self.orderSecrets(secrets)
        lock.lock()
        defer { lock.unlock() }
        guard canonicalFileURL != nil else { return }
        closeLocked()
        lastSyncedCanonicalKey = nil
        let book = try readCanonicalBookLocked()
        try ensureDatabaseOpenLocked()
        try syncSQLiteFromBookLocked(book, orderedSecrets: orderedSecrets)
        if let raw = try? Data(contentsOf: canonicalFileURL!) {
            lastSyncedCanonicalKey = Self.syncKey(
                digest: MemoryRevisionStore.sha256Hex(raw),
                orderedSecrets: orderedSecrets
            )
        }
    }

    // MARK: - Canonical JSON Helpers

    private func readCanonicalBookLocked() throws -> CanonicalExperienceBook {
        guard let url = canonicalFileURL else { return CanonicalExperienceBook() }
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            return CanonicalExperienceBook()
        }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return CanonicalExperienceBook() }
        return try JSONDecoder().decode(CanonicalExperienceBook.self, from: data)
    }

    @discardableResult
    private func writeCanonicalBookIfConfiguredLocked(_ book: CanonicalExperienceBook) throws -> String? {
        guard let url = canonicalFileURL else { return nil }
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) && !fm.isWritableFile(atPath: url.path) {
            throw ExperienceStoreError.canonicalReadOnly(url.lastPathComponent)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(book)

        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        do {
            try data.write(to: tmp, options: [.atomic])
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: url)
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw ExperienceStoreError.canonicalReadOnly(error.localizedDescription)
        }
        return MemoryRevisionStore.sha256Hex(data)
    }

    // MARK: - SQLite Management & Schema

    private enum SQLBinding {
        case text(String)
        case int(Int32)
        case double(Double)
        case optionalDouble(Double?)
    }

    private func closeLocked() {
        if let db {
            sqlite3_close(db)
            self.db = nil
        }
    }

    private func openOrSyncLocked(secrets orderedSecrets: [String], skipSyncIfAlreadyOpen: Bool = false) throws {
        let wasClosed = (db == nil)
        try ensureDatabaseOpenLocked()
        guard let canonicalURL = canonicalFileURL else { return }
        if skipSyncIfAlreadyOpen && !wasClosed { return }

        let diskData = try? Data(contentsOf: canonicalURL)
        let digest = diskData.map(MemoryRevisionStore.sha256Hex) ?? "missing"
        let currentKey = Self.syncKey(digest: digest, orderedSecrets: orderedSecrets)
        if currentKey != lastSyncedCanonicalKey || sqliteRowCountLocked() == 0 {
            let book: CanonicalExperienceBook
            if let diskData, !diskData.isEmpty {
                book = try JSONDecoder().decode(CanonicalExperienceBook.self, from: diskData)
            } else {
                book = CanonicalExperienceBook()
            }
            if !book.records.isEmpty || sqliteRowCountLocked() > 0 {
                try syncSQLiteFromBookLocked(book, orderedSecrets: orderedSecrets)
            }
            lastSyncedCanonicalKey = currentKey
        }
    }

    private func sqliteRowCountLocked() -> Int {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM experiences;", -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return 0
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    private static func syncKey(digest: String, orderedSecrets: [String]) -> String {
        let secretsData = Data(orderedSecrets.joined(separator: "\u{1F}").utf8)
        return digest + "|" + MemoryRevisionStore.sha256Hex(secretsData)
    }

    private func ensureDatabaseOpenLocked() throws {
        if db != nil {
            if let databaseURL {
                let currentEpoch = ClioMemoryDatabaseCoordinator.epoch(for: databaseURL)
                let currentInode = Self.fileInode(at: databaseURL)
                if currentEpoch != openedDatabaseEpoch || currentInode != openedFileInode {
                    closeLocked()
                    lastSyncedCanonicalKey = nil
                } else {
                    return
                }
            } else {
                return
            }
        }

        if let databaseURL {
            let fm = FileManager.default
            try fm.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Bootstrap `MemoryStore` v1 base schema synchronously without swallowing errors so shared
            // `ClioMemory/clio-memory.db` always carries `user_version == 1` and `store_meta`.
            let baseStore = MemoryStore(databaseURL: databaseURL)
            _ = try baseStore.openOrRecover()
        }

        let path = databaseURL?.path ?? ":memory:"
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &opened, flags, nil)
        guard rc == SQLITE_OK, let opened else {
            let msg = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let opened { sqlite3_close(opened) }
            throw ExperienceStoreError.sqlite(code: rc, message: msg)
        }
        self.db = opened
        self.openedDatabaseEpoch = ClioMemoryDatabaseCoordinator.epoch(for: databaseURL)
        self.openedFileInode = databaseURL.flatMap(Self.fileInode(at:))

        try execLocked("PRAGMA busy_timeout = 5000;")
        if databaseURL != nil {
            try execLocked("PRAGMA journal_mode = WAL;")
        }

        try execLocked(
            """
            CREATE TABLE IF NOT EXISTS experiences (
                row_id INTEGER PRIMARY KEY AUTOINCREMENT,
                id TEXT NOT NULL UNIQUE,
                title TEXT NOT NULL,
                content TEXT NOT NULL,
                tags_json TEXT NOT NULL,
                tags_text TEXT NOT NULL,
                content_sha256 TEXT NOT NULL,
                source TEXT NOT NULL,
                use_count INTEGER NOT NULL DEFAULT 0,
                created_at_ms REAL NOT NULL,
                updated_at_ms REAL NOT NULL,
                used_at_ms REAL,
                deleted_at_ms REAL,
                normalized_text TEXT NOT NULL,
                body_tokens TEXT NOT NULL,
                cjk_unigrams TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_experiences_active ON experiences(deleted_at_ms, updated_at_ms DESC);
            """
        )

        if !forceDisableFTS5 {
            do {
                try execLocked(
                    """
                    CREATE VIRTUAL TABLE IF NOT EXISTS experiences_fts USING fts5(
                        body_tokens,
                        cjk_unigrams,
                        content='experiences',
                        content_rowid='row_id',
                        tokenize='unicode61 remove_diacritics 1'
                    );
                    CREATE TRIGGER IF NOT EXISTS experiences_ai AFTER INSERT ON experiences BEGIN
                        INSERT INTO experiences_fts(rowid, body_tokens, cjk_unigrams)
                        VALUES (new.row_id, new.body_tokens, new.cjk_unigrams);
                    END;
                    CREATE TRIGGER IF NOT EXISTS experiences_ad AFTER DELETE ON experiences BEGIN
                        INSERT INTO experiences_fts(experiences_fts, rowid, body_tokens, cjk_unigrams)
                        VALUES ('delete', old.row_id, old.body_tokens, old.cjk_unigrams);
                    END;
                    CREATE TRIGGER IF NOT EXISTS experiences_au AFTER UPDATE ON experiences BEGIN
                        INSERT INTO experiences_fts(experiences_fts, rowid, body_tokens, cjk_unigrams)
                        VALUES ('delete', old.row_id, old.body_tokens, old.cjk_unigrams);
                        INSERT INTO experiences_fts(rowid, body_tokens, cjk_unigrams)
                        VALUES (new.row_id, new.body_tokens, new.cjk_unigrams);
                    END;
                    """
                )
                fts5Enabled = true
            } catch {
                fts5Enabled = false
            }
        } else {
            fts5Enabled = false
        }
    }

    private func syncSQLiteFromBookLocked(_ book: CanonicalExperienceBook, orderedSecrets: [String]) throws {
        try execLocked("BEGIN IMMEDIATE;")
        do {
            try execLocked("DELETE FROM experiences;")
            for record in book.records {
                try upsertSQLiteRecordLocked(record, orderedSecrets: orderedSecrets)
            }
            try execLocked("COMMIT;")
        } catch {
            try? execLocked("ROLLBACK;")
            throw error
        }
    }

    private func upsertSQLiteRecordLocked(_ record: ExperienceRecord, orderedSecrets: [String]) throws {
        let redacted = Self.redactedRecord(record, orderedSecrets: orderedSecrets)
        let tagsJoined = redacted.tags.joined(separator: " ")
        let indexable = [redacted.title, redacted.content, tagsJoined]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let normalized = MemoryIndexTokenizer.normalize(indexable)
        let tokens = MemoryIndexTokenizer.hybridIndexTokens(for: indexable)
        let tagsJSONData = (try? JSONEncoder().encode(redacted.tags)) ?? Data("[]".utf8)
        let tagsJSON = String(data: tagsJSONData, encoding: .utf8) ?? "[]"

        try runPreparedLocked(
            """
            INSERT INTO experiences (
                id, title, content, tags_json, tags_text, content_sha256, source,
                use_count, created_at_ms, updated_at_ms, used_at_ms, deleted_at_ms,
                normalized_text, body_tokens, cjk_unigrams
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                title = excluded.title,
                content = excluded.content,
                tags_json = excluded.tags_json,
                tags_text = excluded.tags_text,
                content_sha256 = excluded.content_sha256,
                source = excluded.source,
                use_count = excluded.use_count,
                created_at_ms = excluded.created_at_ms,
                updated_at_ms = excluded.updated_at_ms,
                used_at_ms = excluded.used_at_ms,
                deleted_at_ms = excluded.deleted_at_ms,
                normalized_text = excluded.normalized_text,
                body_tokens = excluded.body_tokens,
                cjk_unigrams = excluded.cjk_unigrams;
            """,
            bindings: [
                .text(redacted.id),
                .text(redacted.title),
                .text(redacted.content),
                .text(tagsJSON),
                .text(tagsJoined),
                .text(redacted.contentSHA256),
                .text(redacted.source.rawValue),
                .int(Int32(ExperienceRecord.clampUseCount(redacted.useCount))),
                .double(redacted.createdAtMs),
                .double(redacted.updatedAtMs),
                .optionalDouble(redacted.usedAtMs),
                .optionalDouble(redacted.deletedAtMs),
                .text(normalized),
                .text(tokens.bodyTokens),
                .text(tokens.cjkUnigrams),
            ]
        )
    }

    private func loadInMemorySQLiteSnapshotLocked(orderedSecrets: [String]) throws -> [ExperienceRecord] {
        try ensureDatabaseOpenLocked()
        return try readSQLiteRecordsLocked(includeDeleted: true, orderedSecrets: orderedSecrets)
    }

    private func readSQLiteRecordsLocked(includeDeleted: Bool, orderedSecrets: [String]) throws -> [ExperienceRecord] {
        guard let db else { throw ExperienceStoreError.sqlite(code: SQLITE_MISUSE, message: "database closed") }
        let whereClause = includeDeleted ? "" : "WHERE deleted_at_ms IS NULL"
        let sql = """
        SELECT id, title, content, tags_json, content_sha256, source, use_count,
               created_at_ms, updated_at_ms, used_at_ms, deleted_at_ms
        FROM experiences
        \(whereClause)
        ORDER BY updated_at_ms DESC, id ASC;
        """
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw sqliteErrorLocked(code: rc) }
        defer { sqlite3_finalize(stmt) }

        var results: [ExperienceRecord] = []
        while true {
            let stepRC = sqlite3_step(stmt)
            if stepRC == SQLITE_ROW {
                let id = Self.columnText(stmt, 0)
                let title = Self.columnText(stmt, 1)
                let content = Self.columnText(stmt, 2)
                let tagsJSON = Self.columnText(stmt, 3)
                let hash = Self.columnText(stmt, 4)
                let sourceRaw = Self.columnText(stmt, 5)
                let useCount = Int(sqlite3_column_int(stmt, 6))
                let createdAt = sqlite3_column_double(stmt, 7)
                let updatedAt = sqlite3_column_double(stmt, 8)
                let usedAt = Self.columnOptionalDouble(stmt, 9)
                let deletedAt = Self.columnOptionalDouble(stmt, 10)
                let tags = (try? JSONDecoder().decode([String].self, from: Data(tagsJSON.utf8))) ?? []
                let rec = ExperienceRecord(
                    id: id,
                    title: title,
                    content: content,
                    tags: tags,
                    contentSHA256: hash,
                    createdAtMs: createdAt,
                    updatedAtMs: updatedAt,
                    usedAtMs: usedAt,
                    useCount: useCount,
                    deletedAtMs: deletedAt,
                    source: ExperienceWriteSource(rawValue: sourceRaw) ?? .mainChat
                )
                results.append(Self.redactedRecord(rec, orderedSecrets: orderedSecrets))
            } else if stepRC == SQLITE_DONE {
                break
            } else {
                throw sqliteErrorLocked(code: stepRC)
            }
        }
        return results
    }

    private func searchSQLiteLocked(
        cleanQuery: String,
        analysis: MemoryRecall.QueryAnalysis,
        limit: Int,
        suppressedHashes: Set<String>,
        orderedSecrets: [String]
    ) throws -> [ExperienceHit] {
        guard let db else { throw ExperienceStoreError.sqlite(code: SQLITE_MISUSE, message: "database closed") }
        var whereClauses = ["e.deleted_at_ms IS NULL"]
        var bindings: [SQLBinding] = []

        if fts5Enabled, let matchExpr = MemoryRecall.buildFTS5OrMatchExpression(for: cleanQuery) {
            whereClauses.append("experiences_fts MATCH ?")
            bindings.append(.text(matchExpr))
        } else {
            let terms = MemoryRecall.fallbackTerms(for: cleanQuery)
            guard !terms.isEmpty else { return [] }
            let likeClauses = terms.map { _ in "e.normalized_text LIKE ? ESCAPE '\\'" }
            whereClauses.append("(" + likeClauses.joined(separator: " OR ") + ")")
            for term in terms {
                bindings.append(.text("%\(Self.escapeLike(term))%"))
            }
        }

        let candidateCap = Int32(max(limit * 12, 48))
        bindings.append(.int(candidateCap))

        let sql: String
        if fts5Enabled && whereClauses.contains("experiences_fts MATCH ?") {
            sql = """
            SELECT
                e.id, e.title, e.content, e.tags_json, e.content_sha256,
                e.use_count, e.updated_at_ms, e.used_at_ms, bm25(experiences_fts) AS rank_score
            FROM experiences_fts
            JOIN experiences e ON e.row_id = experiences_fts.rowid
            WHERE \(whereClauses.joined(separator: " AND "))
            ORDER BY rank_score ASC, e.use_count DESC, COALESCE(e.used_at_ms, e.updated_at_ms) DESC
            LIMIT ?;
            """
        } else {
            sql = """
            SELECT
                e.id, e.title, e.content, e.tags_json, e.content_sha256,
                e.use_count, e.updated_at_ms, e.used_at_ms, 0.0 AS rank_score
            FROM experiences e
            WHERE \(whereClauses.joined(separator: " AND "))
            ORDER BY e.use_count DESC, COALESCE(e.used_at_ms, e.updated_at_ms) DESC
            LIMIT ?;
            """
        }

        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw sqliteErrorLocked(code: rc) }
        defer { sqlite3_finalize(stmt) }
        try bind(bindings, to: stmt)

        var scored: [(hit: ExperienceHit, recency: Double)] = []
        while true {
            let stepRC = sqlite3_step(stmt)
            if stepRC == SQLITE_ROW {
                let id = Self.columnText(stmt, 0)
                let rawTitle = Self.columnText(stmt, 1)
                let rawContent = Self.columnText(stmt, 2)
                let tagsJSON = Self.columnText(stmt, 3)
                let storedHash = Self.columnText(stmt, 4).lowercased()
                let useCount = Int(sqlite3_column_int(stmt, 5))
                let updatedAtMs = sqlite3_column_double(stmt, 6)
                let usedAtMs = Self.columnOptionalDouble(stmt, 7)
                let bm25Rank = sqlite3_column_double(stmt, 8)
                let rawTags = (try? JSONDecoder().decode([String].self, from: Data(tagsJSON.utf8))) ?? []

                let safeTitle = MemorySafety.redactSecrets(rawTitle, secrets: orderedSecrets)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let safeContent = MemorySafety.redactSecrets(rawContent, secrets: orderedSecrets)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let withoutMask = safeContent.replacingOccurrences(of: "〔隐去〕", with: "")
                guard !safeContent.isEmpty, !MemorySafety.normalizedFactKey(withoutMask).isEmpty else { continue }

                let safeTags = rawTags
                    .map { MemorySafety.redactSecrets($0, secrets: orderedSecrets).trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                let bodyHash = MemorySafety.retractionHash(safeContent)
                let fullHashInput = safeTitle.isEmpty ? safeContent : "\(safeTitle)\n\(safeContent)"
                let fullHash = MemorySafety.retractionHash(fullHashInput)
                guard !suppressedHashes.contains(storedHash),
                      !suppressedHashes.contains(fullHash),
                      !suppressedHashes.contains(bodyHash) else {
                    continue
                }

                let combinedText = safeTitle.isEmpty ? safeContent : "\(safeTitle) \(safeContent)"
                let relevance = MemoryRecall.scoreText(
                    analysis: analysis,
                    text: combinedText,
                    topic: safeTags.joined(separator: " "),
                    bm25Rank: fts5Enabled ? bm25Rank : nil
                )
                guard relevance > 0 else { continue }

                let usageBonus = min(3.0, Double(max(0, useCount)) * 0.25)
                let hit = ExperienceHit(
                    id: id,
                    title: safeTitle,
                    content: safeContent,
                    tags: safeTags,
                    contentSHA256: fullHash,
                    score: relevance + usageBonus,
                    useCount: useCount,
                    updatedAtMs: updatedAtMs,
                    usedAtMs: usedAtMs
                )
                scored.append((hit: hit, recency: usedAtMs ?? updatedAtMs))
            } else if stepRC == SQLITE_DONE {
                break
            } else {
                throw sqliteErrorLocked(code: stepRC)
            }
        }

        scored.sort { lhs, rhs in
            if lhs.hit.score != rhs.hit.score { return lhs.hit.score > rhs.hit.score }
            if lhs.recency != rhs.recency { return lhs.recency > rhs.recency }
            return lhs.hit.id < rhs.hit.id
        }
        return Array(scored.prefix(limit).map(\.hit))
    }

    // MARK: - Low-Level SQLite Helpers

    private static func orderSecrets(_ secrets: [String]) -> [String] {
        secrets.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
    }

    private static func fileInode(at url: URL) -> UInt64? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        return UInt64(st.st_ino)
    }

    private static func redactedRecord(_ record: ExperienceRecord, orderedSecrets: [String]) -> ExperienceRecord {
        var copy = record
        copy.title = MemorySafety.redactSecrets(record.title, secrets: orderedSecrets)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        copy.content = MemorySafety.redactSecrets(record.content, secrets: orderedSecrets)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        copy.tags = record.tags
            .map { MemorySafety.redactSecrets($0, secrets: orderedSecrets).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let input = copy.title.isEmpty ? copy.content : "\(copy.title)\n\(copy.content)"
        copy.contentSHA256 = MemorySafety.retractionHash(input)
        return copy
    }

    private static func escapeLike(_ term: String) -> String {
        term
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private func execLocked(_ sql: String) throws {
        guard let db else { throw ExperienceStoreError.sqlite(code: SQLITE_MISUSE, message: "database closed") }
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(errMsg)
            throw ExperienceStoreError.sqlite(code: rc, message: msg)
        }
    }

    private func runPreparedLocked(_ sql: String, bindings: [SQLBinding]) throws {
        guard let db else { throw ExperienceStoreError.sqlite(code: SQLITE_MISUSE, message: "database closed") }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw sqliteErrorLocked(code: rc) }
        defer { sqlite3_finalize(stmt) }
        try bind(bindings, to: stmt)
        let stepRC = sqlite3_step(stmt)
        guard stepRC == SQLITE_DONE || stepRC == SQLITE_ROW else {
            throw sqliteErrorLocked(code: stepRC)
        }
    }

    private func bind(_ bindings: [SQLBinding], to stmt: OpaquePointer) throws {
        for (idx, value) in bindings.enumerated() {
            let col = Int32(idx + 1)
            let rc: Int32
            switch value {
            case .text(let s):
                rc = sqlite3_bind_text(stmt, col, s, -1, experienceSQLiteTransient)
            case .int(let i):
                rc = sqlite3_bind_int(stmt, col, i)
            case .double(let d):
                rc = sqlite3_bind_double(stmt, col, d)
            case .optionalDouble(let d):
                if let d {
                    rc = sqlite3_bind_double(stmt, col, d)
                } else {
                    rc = sqlite3_bind_null(stmt, col)
                }
            }
            guard rc == SQLITE_OK else { throw sqliteErrorLocked(code: rc) }
        }
    }

    private func sqliteErrorLocked(code: Int32) -> ExperienceStoreError {
        let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite error"
        return .sqlite(code: code, message: msg)
    }

    private static func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String {
        guard let cString = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cString)
    }

    private static func columnOptionalDouble(_ stmt: OpaquePointer, _ index: Int32) -> Double? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(stmt, index)
    }
}
