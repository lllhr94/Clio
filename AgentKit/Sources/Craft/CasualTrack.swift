import Foundation
import SQLite3

private let casualSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Policy constants and pure rules enforcing Casual Track isolation from formal chat, memory, and skills.
public enum CasualTrackPolicy {
    /// Skills strictly suppressed in Casual Track (zero prompt injection).
    public static let hiddenSkillIDs: Set<String> = ["quiet-musing", "user-guide"]

    /// Minimal read-only/lightweight tools permitted inside Casual Track.
    public static let allowedTools: Set<String> = [
        "web_search", "web_read", "weather",
        "recall", "recall_experience", "search_history",
        "current_status", "device_status",
    ]

    /// Default debounce window for merging rapid burst messages in Casual Track (2.5 seconds).
    public static let mergeWindowSeconds: TimeInterval = 2.5

    /// Hard cap on custom stickers per assistant turn in Casual Track.
    public static let maxStickersPerTurn = 1

    /// Casual Track NEVER allows automatic assistant writes to long-term memory or procedural experience stores.
    public static func allowsAutomaticMemoryOrExperienceWrite(isCasualTrack: Bool) -> Bool {
        !isCasualTrack
    }

    /// Only explicit user promotion ("收入拾遗候选") may enter the manual memory review queue.
    public static func allowsExplicitUserPromotionToMemoryCandidate(userInitiated: Bool) -> Bool {
        userInitiated
    }

    /// Strips `quiet-musing` and `user-guide` from the skill catalog for Casual Track prompts
    /// (matching both bare names like `quiet-musing` and scoped IDs like `builtin/quiet-musing`).
    public static func filterSkills<T>(_ skills: [T], id: (T) -> String) -> [T] {
        skills.filter { item in
            let normalized = id(item).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let basename = normalized.split(separator: "/").last.map(String.init) ?? normalized
            return !hiddenSkillIDs.contains(normalized) && !hiddenSkillIDs.contains(basename)
        }
    }

    public static func isToolAllowed(_ toolName: String) -> Bool {
        allowedTools.contains(toolName)
    }

    public static func allowsSticker(usedInCurrentTurn: Int, isCasualTrack: Bool) -> Bool {
        isCasualTrack && usedInCurrentTurn < maxStickersPerTurn
    }
}

/// One message entry in Canonical `Team/casual/<botID>.jsonl`.
public struct CasualEntry: Codable, Equatable, Hashable, Identifiable, Sendable {
    public enum Role: String, Codable, Equatable, Hashable, Sendable {
        case user
        case assistant
    }

    public var id: String
    public var botID: String
    public var role: Role
    public var text: String
    public var stickerID: String?
    public var batchID: String?
    public var handoffSuggested: Bool
    public var createdAtMs: Double

    public init(
        id: String = UUID().uuidString.lowercased(),
        botID: String,
        role: Role,
        text: String,
        stickerID: String? = nil,
        batchID: String? = nil,
        handoffSuggested: Bool = false,
        createdAtMs: Double = Date().timeIntervalSince1970 * 1000
    ) {
        self.id = id
        self.botID = botID
        self.role = role
        self.text = text
        self.stickerID = stickerID
        self.batchID = batchID
        self.handoffSuggested = handoffSuggested
        self.createdAtMs = createdAtMs
    }
}

/// Unified permanent deletion tombstone for Casual Track entries (`Team/casual/<botID>.tombstones.json`).
public struct CasualTombstone: Codable, Equatable, Hashable, Sendable {
    public var entryID: String
    public var deletedAtMs: Double

    public init(entryID: String, deletedAtMs: Double = Date().timeIntervalSince1970 * 1000) {
        self.entryID = entryID
        self.deletedAtMs = deletedAtMs
    }
}

/// Canonical draft retained quietly on disk when switching tracks or crashing before outbox Step 1.
public struct CasualDraft: Codable, Equatable, Hashable, Sendable {
    public var botID: String
    public var casualSessionID: String
    public var segments: [String]
    public var updatedAtMs: Double

    public var combinedText: String {
        segments.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n")
    }

    public var isEmpty: Bool {
        combinedText.isEmpty
    }

    public init(
        botID: String,
        casualSessionID: String,
        segments: [String],
        updatedAtMs: Double = Date().timeIntervalSince1970 * 1000
    ) {
        self.botID = botID
        self.casualSessionID = casualSessionID
        self.segments = segments
        self.updatedAtMs = updatedAtMs
    }
}

/// Two-step crash-safe Canonical outbox batch (`queued_before_send -> in_flight -> completed | needs_reconcile`).
public struct CasualOutboxBatch: Codable, Equatable, Hashable, Identifiable, Sendable {
    public enum State: String, Codable, Equatable, Hashable, Sendable {
        /// Step 1 committed: draft consumed and batch persisted, but Step 2 (`in_flight`) has NOT run yet.
        /// On cold start, safe to advance via Step 2 and send ONCE without dropping the batch.
        case queuedBeforeSend = "queued_before_send"
        /// Step 2 committed BEFORE starting any network task.
        /// On cold start, MUST transition to `.needsReconcile` — NEVER auto-re-sent!
        case inFlight = "in_flight"
        case completed
        /// Ambiguous crash after Step 2 (`in_flight`): requires explicit user check/confirm before re-sending.
        case needsReconcile = "needs_reconcile"
        case cancelled
    }

    public var batchID: String
    public var botID: String
    public var casualSessionID: String
    public var segments: [String]
    public var combinedText: String
    public var state: State
    public var trackEpoch: UInt64
    public var createdAtMs: Double
    public var updatedAtMs: Double

    public var id: String { batchID }

    public init(
        batchID: String = "cmsg-\(UUID().uuidString.lowercased())",
        botID: String,
        casualSessionID: String,
        segments: [String],
        state: State = .queuedBeforeSend,
        trackEpoch: UInt64,
        createdAtMs: Double = Date().timeIntervalSince1970 * 1000,
        updatedAtMs: Double? = nil
    ) {
        self.batchID = batchID
        self.botID = botID
        self.casualSessionID = casualSessionID
        self.segments = segments
        self.combinedText = segments.joined(separator: "\n")
        self.state = state
        self.trackEpoch = trackEpoch
        self.createdAtMs = createdAtMs
        self.updatedAtMs = updatedAtMs ?? createdAtMs
    }
}

public struct CasualColdStartRecovery: Equatable, Sendable {
    /// Drafts left safely on disk before Step 1 (restored quietly into composer, NEVER auto-sent).
    public var restoredDrafts: [CasualDraft]
    /// Batches stuck in `queued_before_send` (after Step 1, before Step 2): safe to advance via Step 2 & send ONCE.
    public var batchesReadyForInitialSend: [CasualOutboxBatch]
    /// Batches stuck in `in_flight` (after Step 2): marked `.needsReconcile`, NEVER auto-re-sent.
    public var batchesNeedingReconcile: [CasualOutboxBatch]

    public init(
        restoredDrafts: [CasualDraft] = [],
        batchesReadyForInitialSend: [CasualOutboxBatch] = [],
        batchesNeedingReconcile: [CasualOutboxBatch] = []
    ) {
        self.restoredDrafts = restoredDrafts
        self.batchesReadyForInitialSend = batchesReadyForInitialSend
        self.batchesNeedingReconcile = batchesNeedingReconcile
    }
}

public enum CasualTrackError: Error, LocalizedError, Equatable, Sendable {
    case invalidBotID(String)
    case staleTrackEpoch(expected: UInt64, actual: UInt64)
    case emptyDraft
    case batchNotFound(String)
    case invalidStateTransition(from: CasualOutboxBatch.State, to: CasualOutboxBatch.State)

    public var errorDescription: String? {
        switch self {
        case .invalidBotID(let id): return "无效的闲谈标识：\(id)"
        case .staleTrackEpoch: return "已切换到其他轨道，本次合并发送已自动取消并保留为草稿。"
        case .emptyDraft: return "没有待发送的闲谈内容。"
        case .batchNotFound(let id): return "找不到闲谈批次：\(id)"
        case .invalidStateTransition(let from, let to): return "不允许的状态流转：\(from.rawValue) -> \(to.rawValue)"
        }
    }
}

/// Canonical JSONL + tombstone store for Casual Track (`Team/casual/<botID>.jsonl`)
/// paired with a rebuildable append-only SQLite projection (`casual_entries`) and crash-safe outbox.
public final class CasualTrackStore: @unchecked Sendable {
    private let lock = NSLock()
    private let casualDir: URL
    private let outboxDir: URL
    private let sqliteURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var db: OpaquePointer?

    /// Testing hook to simulate failure during Step 2 `in_flight` commit before network dispatch.
    public var simulateOutboxWriteFailure: (@Sendable (CasualOutboxBatch) -> Error?)?

    public init(canonicalTeamDirectory: URL, projectionDatabaseURL: URL? = nil) {
        self.casualDir = canonicalTeamDirectory.appendingPathComponent("casual", isDirectory: true)
        self.outboxDir = casualDir.appendingPathComponent("outbox", isDirectory: true)
        self.sqliteURL = projectionDatabaseURL ?? canonicalTeamDirectory.appendingPathComponent("clio-casual.db")
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        self.encoder = enc
        self.decoder = JSONDecoder()
        lock.withLock {
            ensureDirectoriesLocked()
            openProjectionLocked()
        }
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    // MARK: - Entries & Unified Permanent Deletion Tombstones

    @discardableResult
    public func appendEntry(_ entry: CasualEntry) throws -> Bool {
        try lock.withLock {
            try validateBotID(entry.botID)
            let tombstones = loadTombstonesLocked(botID: entry.botID)
            if tombstones[entry.id] != nil {
                return false
            }
            ensureDirectoriesLocked()
            let jsonlURL = entriesURL(botID: entry.botID)
            let data = try encoder.encode(entry)
            var line = data
            line.append(0x0A)
            if FileManager.default.fileExists(atPath: jsonlURL.path) {
                let handle = try FileHandle(forWritingTo: jsonlURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: jsonlURL, options: .atomic)
            }
            insertProjectionEntryLocked(entry)
            return true
        }
    }

    public func entries(for botID: String) -> [CasualEntry] {
        lock.withLock {
            guard (try? validateBotID(botID)) != nil else { return [] }
            let tombstones = loadTombstonesLocked(botID: botID)
            return loadRawEntriesLocked(botID: botID).filter { tombstones[$0.id] == nil }
        }
    }

    /// Permanently deletes an entry by writing a Canonical tombstone; the entry will never resurrect
    /// on cold start or archive merge when covered by local or archive tombstones.
    public func permanentlyDelete(entryID: String, botID: String, nowMs: Double = Date().timeIntervalSince1970 * 1000) throws {
        try lock.withLock {
            try validateBotID(botID)
            var tombstones = loadTombstonesLocked(botID: botID)
            if let existing = tombstones[entryID] {
                tombstones[entryID] = max(existing, nowMs)
            } else {
                tombstones[entryID] = nowMs
            }
            try persistTombstonesLocked(tombstones, botID: botID)
            deleteProjectionEntryLocked(entryID: entryID)
        }
    }

    /// Merges restored archive entries & tombstones with local tombstones according to the unified tombstone contract:
    /// any entry covered by EITHER local tombstones OR archive tombstones is permanently suppressed.
    public func mergeRestoredArchive(
        botID: String,
        archiveEntries: [CasualEntry],
        archiveTombstones: [CasualTombstone]
    ) throws -> [CasualEntry] {
        try lock.withLock {
            try validateBotID(botID)
            var mergedTombstones = loadTombstonesLocked(botID: botID)
            for t in archiveTombstones {
                mergedTombstones[t.entryID] = max(mergedTombstones[t.entryID] ?? 0, t.deletedAtMs)
            }
            try persistTombstonesLocked(mergedTombstones, botID: botID)

            var byID: [String: CasualEntry] = [:]
            for existing in loadRawEntriesLocked(botID: botID) where mergedTombstones[existing.id] == nil {
                byID[existing.id] = existing
            }
            for incoming in archiveEntries where mergedTombstones[incoming.id] == nil {
                byID[incoming.id] = incoming
            }
            let sorted = byID.values.sorted {
                if $0.createdAtMs == $1.createdAtMs { return $0.id < $1.id }
                return $0.createdAtMs < $1.createdAtMs
            }
            try rewriteEntriesLocked(sorted, botID: botID)
            rebuildProjectionForBotLocked(botID: botID, entries: sorted)
            return sorted
        }
    }

    public func tombstones(for botID: String) -> [CasualTombstone] {
        lock.withLock {
            loadTombstonesLocked(botID: botID)
                .map { CasualTombstone(entryID: $0.key, deletedAtMs: $0.value) }
                .sorted { $0.entryID < $1.entryID }
        }
    }

    public func projectedEntryCount(for botID: String) -> Int {
        lock.withLock {
            guard let db else { return 0 }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM casual_entries WHERE bot_id = ?1;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, botID, -1, casualSQLiteTransient)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    // MARK: - Canonical Draft & Two-Step Outbox Persistence

    public func saveDraft(_ draft: CasualDraft) throws {
        try lock.withLock {
            try validateBotID(draft.botID)
            ensureDirectoriesLocked()
            let url = draftURL(botID: draft.botID)
            if draft.isEmpty {
                try? FileManager.default.removeItem(at: url)
            } else {
                let data = try encoder.encode(draft)
                try data.write(to: url, options: .atomic)
            }
        }
    }

    public func loadDraft(botID: String) -> CasualDraft? {
        lock.withLock {
            guard (try? validateBotID(botID)) != nil,
                  let data = try? Data(contentsOf: draftURL(botID: botID)) else { return nil }
            return try? decoder.decode(CasualDraft.self, from: data)
        }
    }

    public func clearDraft(botID: String) {
        lock.withLock {
            try? FileManager.default.removeItem(at: draftURL(botID: botID))
        }
    }

    public func loadAllDrafts() -> [CasualDraft] {
        lock.withLock { loadAllDraftsLocked() }
    }

    public func saveOutboxBatch(_ batch: CasualOutboxBatch) throws {
        try lock.withLock {
            try persistOutboxBatchLocked(batch)
        }
    }

    public func loadOutboxBatch(batchID: String) -> CasualOutboxBatch? {
        lock.withLock { loadOutboxBatchLocked(batchID: batchID) }
    }

    /// Step 1 atomic commit: verifies `isEpochCurrent()`, writes `queued_before_send` outbox batch, then clears draft.
    public func commitStep1QueuedBeforeSend(
        botID: String,
        casualSessionID: String,
        segments: [String],
        trackEpoch: UInt64,
        batchID: String = "cmsg-\(UUID().uuidString.lowercased())",
        isEpochCurrent: () -> Bool,
        nowMs: Double = Date().timeIntervalSince1970 * 1000
    ) throws -> CasualOutboxBatch {
        try lock.withLock {
            try validateBotID(botID)
            guard isEpochCurrent() else {
                throw CasualTrackError.staleTrackEpoch(expected: trackEpoch, actual: trackEpoch &+ 1)
            }
            let nonEmpty = segments.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard !nonEmpty.isEmpty else { throw CasualTrackError.emptyDraft }

            let batch = CasualOutboxBatch(
                batchID: batchID,
                botID: botID,
                casualSessionID: casualSessionID,
                segments: nonEmpty,
                state: .queuedBeforeSend,
                trackEpoch: trackEpoch,
                createdAtMs: nowMs,
                updatedAtMs: nowMs
            )
            try persistOutboxBatchLocked(batch)
            try? FileManager.default.removeItem(at: draftURL(botID: botID))
            return batch
        }
    }

    /// Step 2 atomic commit (MUST succeed on disk BEFORE launching any network task!):
    /// advances `queued_before_send -> in_flight` for the exact same `batchID`.
    public func commitStep2MarkInFlight(
        batchID: String,
        nowMs: Double = Date().timeIntervalSince1970 * 1000
    ) throws -> CasualOutboxBatch {
        try lock.withLock {
            guard var batch = loadOutboxBatchLocked(batchID: batchID) else {
                throw CasualTrackError.batchNotFound(batchID)
            }
            guard batch.state == .queuedBeforeSend else {
                throw CasualTrackError.invalidStateTransition(from: batch.state, to: .inFlight)
            }
            batch.state = .inFlight
            batch.updatedAtMs = nowMs
            try persistOutboxBatchLocked(batch)
            return batch
        }
    }

    public func markOutboxCompleted(
        batchID: String,
        nowMs: Double = Date().timeIntervalSince1970 * 1000
    ) throws -> CasualOutboxBatch {
        try lock.withLock {
            guard var batch = loadOutboxBatchLocked(batchID: batchID) else {
                throw CasualTrackError.batchNotFound(batchID)
            }
            batch.state = .completed
            batch.updatedAtMs = nowMs
            try persistOutboxBatchLocked(batch)
            return batch
        }
    }

    /// Cold-start recovery across all 4 crash windows:
    /// 1) Pre-Step-1 drafts stay drafts (restored quietly to composer, never auto-sent).
    /// 2) `queued_before_send` batches (after Step 1, before Step 2) -> returned for single initial dispatch via Step 2.
    /// 3) `in_flight` batches (after Step 2, whether network sent or not) -> transitioned to `.needsReconcile`, NEVER auto-re-sent.
    /// 4) Completed/cancelled batches are ignored.
    @discardableResult
    public func reconcileOnColdStart(
        nowMs: Double = Date().timeIntervalSince1970 * 1000
    ) -> CasualColdStartRecovery {
        lock.withLock {
            let drafts = loadAllDraftsLocked()
            var readyToSend: [CasualOutboxBatch] = []
            var needsReconcile: [CasualOutboxBatch] = []
            for var batch in loadAllOutboxBatchesLocked() {
                switch batch.state {
                case .queuedBeforeSend:
                    readyToSend.append(batch)
                case .inFlight:
                    batch.state = .needsReconcile
                    batch.updatedAtMs = nowMs
                    try? persistOutboxBatchLocked(batch)
                    needsReconcile.append(batch)
                case .needsReconcile:
                    needsReconcile.append(batch)
                case .completed, .cancelled:
                    break
                }
            }
            return CasualColdStartRecovery(
                restoredDrafts: drafts,
                batchesReadyForInitialSend: readyToSend.sorted { $0.createdAtMs < $1.createdAtMs },
                batchesNeedingReconcile: needsReconcile.sorted { $0.createdAtMs < $1.createdAtMs }
            )
        }
    }

    // MARK: - Private File & SQLite Helpers

    private func validateBotID(_ botID: String) throws {
        guard !botID.isEmpty, !botID.contains("/"), !botID.contains("\\"), !botID.contains(".."), !botID.hasPrefix(".") else {
            throw CasualTrackError.invalidBotID(botID)
        }
    }

    private func ensureDirectoriesLocked() {
        try? FileManager.default.createDirectory(at: casualDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: outboxDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: sqliteURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    private func entriesURL(botID: String) -> URL { casualDir.appendingPathComponent("\(botID).jsonl") }
    private func tombstonesURL(botID: String) -> URL { casualDir.appendingPathComponent("\(botID).tombstones.json") }
    private func draftURL(botID: String) -> URL { casualDir.appendingPathComponent("\(botID).draft.json") }
    private func outboxURL(batchID: String) -> URL { outboxDir.appendingPathComponent("\(batchID).json") }

    private func loadRawEntriesLocked(botID: String) -> [CasualEntry] {
        guard let data = try? Data(contentsOf: entriesURL(botID: botID)),
              let raw = String(data: data, encoding: .utf8) else { return [] }
        return raw.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            try? decoder.decode(CasualEntry.self, from: Data(line.utf8))
        }
    }

    private func rewriteEntriesLocked(_ entries: [CasualEntry], botID: String) throws {
        ensureDirectoriesLocked()
        var out = Data()
        for entry in entries {
            out.append(try encoder.encode(entry))
            out.append(0x0A)
        }
        try out.write(to: entriesURL(botID: botID), options: .atomic)
    }

    private func loadTombstonesLocked(botID: String) -> [String: Double] {
        guard let data = try? Data(contentsOf: tombstonesURL(botID: botID)),
              let list = try? decoder.decode([CasualTombstone].self, from: data) else { return [:] }
        var map: [String: Double] = [:]
        for item in list { map[item.entryID] = max(map[item.entryID] ?? 0, item.deletedAtMs) }
        return map
    }

    private func persistTombstonesLocked(_ map: [String: Double], botID: String) throws {
        ensureDirectoriesLocked()
        let list = map.map { CasualTombstone(entryID: $0.key, deletedAtMs: $0.value) }.sorted { $0.entryID < $1.entryID }
        let data = try encoder.encode(list)
        try data.write(to: tombstonesURL(botID: botID), options: .atomic)
    }

    private func loadAllDraftsLocked() -> [CasualDraft] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: casualDir, includingPropertiesForKeys: nil) else { return [] }
        return files.compactMap { url in
            guard url.lastPathComponent.hasSuffix(".draft.json"),
                  let data = try? Data(contentsOf: url),
                  let draft = try? decoder.decode(CasualDraft.self, from: data),
                  !draft.isEmpty else { return nil }
            return draft
        }
    }

    private func persistOutboxBatchLocked(_ batch: CasualOutboxBatch) throws {
        if let err = simulateOutboxWriteFailure?(batch) { throw err }
        ensureDirectoriesLocked()
        let data = try encoder.encode(batch)
        try data.write(to: outboxURL(batchID: batch.batchID), options: .atomic)
    }

    private func loadOutboxBatchLocked(batchID: String) -> CasualOutboxBatch? {
        guard let data = try? Data(contentsOf: outboxURL(batchID: batchID)) else { return nil }
        return try? decoder.decode(CasualOutboxBatch.self, from: data)
    }

    private func loadAllOutboxBatchesLocked() -> [CasualOutboxBatch] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: outboxDir, includingPropertiesForKeys: nil) else { return [] }
        return files.compactMap { url in
            guard url.pathExtension == "json",
                  let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(CasualOutboxBatch.self, from: data)
        }
    }

    private func openProjectionLocked() {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(sqliteURL.path, &handle, flags, nil) == SQLITE_OK else {
            if let handle { sqlite3_close_v2(handle) }
            return
        }
        db = handle
        let ddl = """
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS casual_entries (
            entry_id TEXT PRIMARY KEY,
            bot_id TEXT NOT NULL,
            role TEXT NOT NULL,
            text TEXT NOT NULL,
            sticker_id TEXT,
            created_at_ms REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_casual_bot ON casual_entries(bot_id, created_at_ms ASC);
        """
        sqlite3_exec(db, ddl, nil, nil, nil)
    }

    private func insertProjectionEntryLocked(_ entry: CasualEntry) {
        guard let db else { return }
        let sql = """
        INSERT OR IGNORE INTO casual_entries(entry_id, bot_id, role, text, sticker_id, created_at_ms)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, entry.id, -1, casualSQLiteTransient)
        sqlite3_bind_text(stmt, 2, entry.botID, -1, casualSQLiteTransient)
        sqlite3_bind_text(stmt, 3, entry.role.rawValue, -1, casualSQLiteTransient)
        sqlite3_bind_text(stmt, 4, entry.text, -1, casualSQLiteTransient)
        if let sticker = entry.stickerID {
            sqlite3_bind_text(stmt, 5, sticker, -1, casualSQLiteTransient)
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        sqlite3_bind_double(stmt, 6, entry.createdAtMs)
        _ = sqlite3_step(stmt)
    }

    private func deleteProjectionEntryLocked(entryID: String) {
        guard let db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM casual_entries WHERE entry_id = ?1;", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, entryID, -1, casualSQLiteTransient)
        _ = sqlite3_step(stmt)
    }

    private func rebuildProjectionForBotLocked(botID: String, entries: [CasualEntry]) {
        guard let db else { return }
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM casual_entries WHERE bot_id = ?1;", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, botID, -1, casualSQLiteTransient)
            _ = sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        for entry in entries { insertProjectionEntryLocked(entry) }
    }
}

/// Independent debounce & two-step commit queue uniquely owned per `(botID, casualSessionID)`.
/// Keyboard and focus callbacks NEVER own or mutate this queue.
public final class CasualSendQueue: @unchecked Sendable {
    public let botID: String
    public let casualSessionID: String
    public let store: CasualTrackStore
    public let mergeWindowNanoseconds: UInt64

    private let lock = NSLock()
    private var trackEpoch: UInt64 = 0
    private var pendingSegments: [String] = []
    private var debounceTask: Task<Void, Never>?

    public init(
        botID: String,
        casualSessionID: String = UUID().uuidString.lowercased(),
        store: CasualTrackStore,
        mergeWindowSeconds: TimeInterval = CasualTrackPolicy.mergeWindowSeconds
    ) {
        self.botID = botID
        self.casualSessionID = casualSessionID
        self.store = store
        self.mergeWindowNanoseconds = UInt64(max(0.01, mergeWindowSeconds) * 1_000_000_000)
    }

    public var currentTrackEpoch: UInt64 {
        lock.withLock { trackEpoch }
    }

    public var bufferedSegments: [String] {
        lock.withLock { pendingSegments }
    }

    /// Enqueues a rapid burst message, persisting to Canonical draft immediately and resetting the 2.5s timer.
    public func enqueue(
        _ text: String,
        onReadyToDispatch: @escaping @Sendable (CasualOutboxBatch) async -> Void
    ) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let (epoch, snapshot) = lock.withLock { () -> (UInt64, [String]) in
            pendingSegments.append(trimmed)
            debounceTask?.cancel()
            return (trackEpoch, pendingSegments)
        }

        // Persist draft BEFORE timer completes so a pre-Step-1 crash keeps text quietly in composer.
        try store.saveDraft(CasualDraft(
            botID: botID,
            casualSessionID: casualSessionID,
            segments: snapshot
        ))

        let delay = mergeWindowNanoseconds
        let task = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            guard let self else { return }
            await self.flushNow(expectedEpoch: epoch, onReadyToDispatch: onReadyToDispatch)
        }
        lock.withLock {
            if trackEpoch == epoch {
                debounceTask = task
            } else {
                task.cancel()
            }
        }
    }

    /// Cancels the 2.5s countdown when switching back to formal chat, atomically bumping `trackEpoch`
    /// and preserving uncommitted text safely inside the Canonical draft (never auto-sent on switch-back).
    @discardableResult
    public func cancelForTrackSwitch() -> CasualDraft? {
        let snapshot: [String] = lock.withLock {
            trackEpoch &+= 1
            debounceTask?.cancel()
            debounceTask = nil
            let copy = pendingSegments
            pendingSegments.removeAll()
            return copy
        }
        guard !snapshot.isEmpty else { return store.loadDraft(botID: botID) }
        let draft = CasualDraft(botID: botID, casualSessionID: casualSessionID, segments: snapshot)
        try? store.saveDraft(draft)
        return draft
    }

    /// Executes the exact two-step pre-write sequence under `trackEpoch` arbitration:
    /// 1) Step 1 commit (`queued_before_send` + draft consumed)
    /// 2) Step 2 commit (`in_flight` on disk) -> ONLY AFTER Step 2 succeeds is `onReadyToDispatch` invoked!
    @discardableResult
    public func flushNow(
        expectedEpoch: UInt64? = nil,
        onReadyToDispatch: @escaping @Sendable (CasualOutboxBatch) async -> Void
    ) async -> CasualOutboxBatch? {
        let targetEpoch = expectedEpoch ?? currentTrackEpoch
        let snapshot: [String] = lock.withLock {
            guard trackEpoch == targetEpoch, !pendingSegments.isEmpty else { return [] }
            debounceTask?.cancel()
            debounceTask = nil
            return pendingSegments
        }
        guard !snapshot.isEmpty else { return nil }

        // Step 1: Canonical outbox `queued_before_send` + consume draft, arbitrated by `trackEpoch`.
        guard let step1 = try? store.commitStep1QueuedBeforeSend(
            botID: botID,
            casualSessionID: casualSessionID,
            segments: snapshot,
            trackEpoch: targetEpoch,
            isEpochCurrent: { self.currentTrackEpoch == targetEpoch }
        ) else {
            return nil
        }

        lock.withLock {
            if trackEpoch == targetEpoch {
                pendingSegments.removeAll()
            }
        }

        // Step 2: Advance the SAME `batchID` to `in_flight` on disk STRICTLY BEFORE calling `onReadyToDispatch`.
        guard let step2 = try? store.commitStep2MarkInFlight(batchID: step1.batchID) else {
            return nil
        }

        await onReadyToDispatch(step2)
        return step2
    }
}
