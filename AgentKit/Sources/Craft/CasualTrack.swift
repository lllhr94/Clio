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
    /// Optional ID of an earlier `.needsReconcile` batch explicitly replaced by this resend batch.
    public var supersedesBatchID: String?
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
        supersedesBatchID: String? = nil,
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
        self.supersedesBatchID = supersedesBatchID
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
    case writesFrozen

    public var errorDescription: String? {
        switch self {
        case .invalidBotID(let id): return "无效的闲谈标识：\(id)"
        case .staleTrackEpoch: return "已切换到其他轨道，本次合并发送已自动取消并保留为草稿。"
        case .emptyDraft: return "没有待发送的闲谈内容。"
        case .batchNotFound(let id): return "找不到闲谈批次：\(id)"
        case .invalidStateTransition(let from, let to): return "不允许的状态流转：\(from.rawValue) -> \(to.rawValue)"
        case .writesFrozen: return "刚恢复了备份，闲谈写入已冻结，请重新打开 Clio 后再试。"
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

    /// Testing hook to simulate failure during outbox batch persistence.
    public var simulateOutboxWriteFailure: (@Sendable (CasualOutboxBatch) -> Error?)?
    /// Testing hook to simulate failure when persisting casual reply/user entries to JSONL.
    public var simulateEntryWriteFailure: (@Sendable (CasualEntry) -> Error?)?
    /// External write-freeze barrier hook (e.g. wired to `Disk.frozen` during backup restore).
    public var isWriteFrozen: (@Sendable () -> Bool)?

    public init(canonicalTeamDirectory: URL, projectionDatabaseURL: URL? = nil, isWriteFrozen: (@Sendable () -> Bool)? = nil) {
        self.casualDir = canonicalTeamDirectory.appendingPathComponent("casual", isDirectory: true)
        self.outboxDir = casualDir.appendingPathComponent("outbox", isDirectory: true)
        self.sqliteURL = projectionDatabaseURL ?? canonicalTeamDirectory.appendingPathComponent("clio-casual.db")
        self.isWriteFrozen = isWriteFrozen
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        self.encoder = enc
        self.decoder = JSONDecoder()
        lock.withLock {
            ensureDirectoriesLocked()
            openProjectionLocked()
        }
    }

    /// Serializes against all in-flight CasualTrackStore writes (e.g. during a backup restore barrier while frozen).
    public func withWriteBarrier<T>(_ body: () throws -> T) rethrows -> T {
        try lock.withLock {
            try body()
        }
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    // MARK: - Entries & Unified Permanent Deletion Tombstones

    @discardableResult
    public func appendEntry(_ entry: CasualEntry) throws -> Bool {
        try lock.withLock {
            try appendEntryLocked(entry)
        }
    }

    private static func isFileMissingError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoSuchFileError {
            return true
        }
        if ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOENT) {
            return true
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error {
            return isFileMissingError(underlying)
        }
        return false
    }

    /// Reads existing entry IDs from `botID.jsonl` while distinguishing genuine absence (`ENOENT`) from
    /// transient read errors (which MUST rethrow so write paths never clobber existing history).
    private func inspectExistingJSONLLocked(botID: String) throws -> (exists: Bool, endsWithNewline: Bool, existingIDs: Set<String>) {
        let url = entriesURL(botID: botID)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            if Self.isFileMissingError(error) {
                return (false, true, [])
            }
            throw error
        }
        let endsWithNewline = data.isEmpty || data.last == 0x0A
        var ids: Set<String> = []
        for lineSlice in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if let decoded = try? decoder.decode(CasualEntry.self, from: Data(lineSlice)) {
                ids.insert(decoded.id)
            }
        }
        return (true, endsWithNewline, ids)
    }

    /// Strictly append-only write to `botID.jsonl` preserving all pre-existing bytes (including any unreadable/legacy lines).
    private func appendLinesOnlyLocked(_ entries: [CasualEntry], botID: String, exists: Bool, endsWithNewline: Bool) throws {
        guard !entries.isEmpty else { return }
        ensureDirectoriesLocked()
        var payload = Data()
        if exists && !endsWithNewline {
            payload.append(0x0A)
        }
        for entry in entries {
            payload.append(try encoder.encode(entry))
            payload.append(0x0A)
        }
        let jsonlURL = entriesURL(botID: botID)
        if exists {
            let handle = try FileHandle(forWritingTo: jsonlURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: payload)
            try handle.synchronize()
        } else {
            try payload.write(to: jsonlURL, options: .atomic)
        }
    }

    @discardableResult
    private func appendEntryLocked(_ entry: CasualEntry) throws -> Bool {
        guard !(isWriteFrozen?() ?? false) else { throw CasualTrackError.writesFrozen }
        try validateBotID(entry.botID)
        if let err = simulateEntryWriteFailure?(entry) { throw err }
        let tombstones = loadTombstonesLocked(botID: entry.botID)
        if tombstones[entry.id] != nil {
            return false
        }
        let existing = try inspectExistingJSONLLocked(botID: entry.botID)
        if existing.existingIDs.contains(entry.id) {
            return false
        }
        try appendLinesOnlyLocked([entry], botID: entry.botID, exists: existing.exists, endsWithNewline: existing.endsWithNewline)
        insertProjectionEntryLocked(entry)
        return true
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
            guard !(isWriteFrozen?() ?? false) else { throw CasualTrackError.writesFrozen }
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
            guard !(isWriteFrozen?() ?? false) else { throw CasualTrackError.writesFrozen }
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
            guard !(isWriteFrozen?() ?? false) else { throw CasualTrackError.writesFrozen }
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
            guard !(isWriteFrozen?() ?? false) else { return }
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

    /// Persists all reply entries strictly append-only to `botID.jsonl` (preserving pre-existing bytes and
    /// rethrowing read errors rather than rewriting from empty) BEFORE marking the outbox batch `.completed`.
    @discardableResult
    public func appendEntriesAndCompleteOutbox(
        entries: [CasualEntry],
        batchID: String,
        nowMs: Double = Date().timeIntervalSince1970 * 1000
    ) throws -> CasualOutboxBatch {
        try lock.withLock {
            guard !(isWriteFrozen?() ?? false) else { throw CasualTrackError.writesFrozen }
            guard var batch = loadOutboxBatchLocked(batchID: batchID) else {
                throw CasualTrackError.batchNotFound(batchID)
            }
            if !entries.isEmpty {
                let grouped = Dictionary(grouping: entries, by: \.botID)
                for (botID, botEntries) in grouped {
                    try validateBotID(botID)
                    for entry in botEntries {
                        if let err = simulateEntryWriteFailure?(entry) { throw err }
                    }
                    let tombstones = loadTombstonesLocked(botID: botID)
                    let inspected = try inspectExistingJSONLLocked(botID: botID)
                    var existingIDs = inspected.existingIDs
                    var newlyAdded: [CasualEntry] = []
                    for entry in botEntries where tombstones[entry.id] == nil && existingIDs.insert(entry.id).inserted {
                        newlyAdded.append(entry)
                    }
                    if !newlyAdded.isEmpty {
                        try appendLinesOnlyLocked(
                            newlyAdded,
                            botID: botID,
                            exists: inspected.exists,
                            endsWithNewline: inspected.endsWithNewline
                        )
                        for entry in newlyAdded {
                            insertProjectionEntryLocked(entry)
                        }
                    }
                }
            }
            batch.state = .completed
            batch.updatedAtMs = nowMs
            try persistOutboxBatchLocked(batch)
            return batch
        }
    }

    /// Atomically replaces a `.needsReconcile` batch with a fresh resend batch carrying `supersedesBatchID`.
    /// Enforces that `oldBatchID` is STILL `.needsReconcile` and has NO existing non-cancelled replacement so at most
    /// one sendable replacement can ever exist for a given old batch.
    @discardableResult
    public func replaceReconciledBatch(
        oldBatchID: String,
        with fresh: CasualOutboxBatch,
        nowMs: Double = Date().timeIntervalSince1970 * 1000
    ) throws -> CasualOutboxBatch {
        try lock.withLock {
            guard !(isWriteFrozen?() ?? false) else { throw CasualTrackError.writesFrozen }
            guard var oldBatch = loadOutboxBatchLocked(batchID: oldBatchID) else {
                throw CasualTrackError.batchNotFound(oldBatchID)
            }
            guard oldBatch.state == .needsReconcile else {
                throw CasualTrackError.invalidStateTransition(from: oldBatch.state, to: .completed)
            }
            let existingSuperseder = loadAllOutboxBatchesLocked().first {
                $0.supersedesBatchID == oldBatchID && $0.state != .cancelled
            }
            if existingSuperseder != nil {
                // Heal stale open oldBatch if a prior rollback delete failed, and refuse creating a second replacement.
                oldBatch.state = .completed
                oldBatch.updatedAtMs = nowMs
                try? persistOutboxBatchLocked(oldBatch)
                throw CasualTrackError.invalidStateTransition(from: .completed, to: .queuedBeforeSend)
            }

            var replacement = fresh
            replacement.supersedesBatchID = oldBatchID
            replacement.updatedAtMs = nowMs
            try persistOutboxBatchLocked(replacement)

            oldBatch.state = .completed
            oldBatch.updatedAtMs = nowMs
            do {
                try persistOutboxBatchLocked(oldBatch)
            } catch {
                // Attempt rollback removal of replacement; if deletion also fails, `supersedesBatchID` stays persisted
                // so cold start and subsequent `replaceReconciledBatch` calls guarantee at most one replacement exists.
                let replacementURL = outboxURL(batchID: replacement.batchID)
                try? FileManager.default.removeItem(at: replacementURL)
                throw error
            }
            return replacement
        }
    }

    /// Read-only per-bot outbox query (safe to call when opening a companion's Casual page without
    /// touching any other companion's active `.inFlight` batches).
    public func outboxBatches(for botID: String) -> [CasualOutboxBatch] {
        lock.withLock {
            loadAllOutboxBatchesLocked()
                .filter { $0.botID == botID }
                .sorted { $0.createdAtMs < $1.createdAtMs }
        }
    }

    /// Demotes all `.queuedBeforeSend` / `.inFlight` outbox batches inside a staged backup-restored `Team/`
    /// directory to `.needsReconcile` BEFORE swap so restored casual batches NEVER auto-send on open.
    @discardableResult
    public static func demoteRestoredOutboxBatches(
        in teamDirectory: URL,
        nowMs: Double = Date().timeIntervalSince1970 * 1000
    ) throws -> Int {
        let outboxDir = teamDirectory
            .appendingPathComponent("casual", isDirectory: true)
            .appendingPathComponent("outbox", isDirectory: true)
        let fm = FileManager.default
        guard fm.fileExists(atPath: outboxDir.path) else { return 0 }
        let files = try fm.contentsOfDirectory(at: outboxDir, includingPropertiesForKeys: nil)
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var demoted = 0
        for url in files where url.pathExtension == "json" {
            let data = try Data(contentsOf: url)
            guard var batch = try? decoder.decode(CasualOutboxBatch.self, from: data) else { continue }
            if batch.state == .queuedBeforeSend || batch.state == .inFlight {
                batch.state = .needsReconcile
                batch.updatedAtMs = nowMs
                let updated = try encoder.encode(batch)
                try updated.write(to: url, options: .atomic)
                demoted += 1
            }
        }
        return demoted
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
            let allBatches = loadAllOutboxBatchesLocked()
            // Heal any crash between writing a replacement resend batch (`supersedesBatchID`) and closing the old batch.
            let supersededIDs = Set(
                allBatches
                    .filter { $0.state != .cancelled }
                    .compactMap(\.supersedesBatchID)
            )
            var readyToSend: [CasualOutboxBatch] = []
            var needsReconcile: [CasualOutboxBatch] = []
            for var batch in allBatches {
                if supersededIDs.contains(batch.batchID), batch.state != .completed, batch.state != .cancelled {
                    batch.state = .completed
                    batch.updatedAtMs = nowMs
                    try? persistOutboxBatchLocked(batch)
                    continue
                }
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
        guard let data = try? Data(contentsOf: entriesURL(botID: botID)) else { return [] }
        return data.split(separator: 0x0A, omittingEmptySubsequences: true).compactMap { lineSlice in
            try? decoder.decode(CasualEntry.self, from: Data(lineSlice))
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
        guard !(isWriteFrozen?() ?? false) else { throw CasualTrackError.writesFrozen }
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
/// All segment enqueue, draft persistence, track-switch cancellation, and Step-1 outbox claims are strictly
/// serialized via `serialLock` and consumed by stable segment IDs so concurrent flushes can never double-send or drop text.
public final class CasualSendQueue: @unchecked Sendable {
    private struct BufferedSegment: Sendable {
        let id: UUID
        let text: String
    }

    public let botID: String
    public let casualSessionID: String
    public let store: CasualTrackStore
    public let mergeWindowNanoseconds: UInt64

    /// Always acquired BEFORE any `store` method (strict lock hierarchy: `serialLock -> store.lock`).
    private let serialLock = NSLock()
    private var trackEpoch: UInt64 = 0
    private var timerGeneration: UInt64 = 0
    private var pendingSegments: [BufferedSegment] = []
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
        serialLock.withLock { trackEpoch }
    }

    public var bufferedSegments: [String] {
        serialLock.withLock { pendingSegments.map(\.text) }
    }

    /// Enqueues a rapid burst message, persisting to Canonical draft immediately and resetting the 2.5s timer
    /// ONLY AFTER draft persistence succeeds (so a failed draft write never cancels an earlier pending timer).
    public func enqueue(
        _ text: String,
        onReadyToDispatch: @escaping @Sendable (CasualOutboxBatch) async -> Void
    ) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let delay = mergeWindowNanoseconds
        try serialLock.withLock {
            let entry = BufferedSegment(id: UUID(), text: trimmed)
            let candidateTexts = pendingSegments.map(\.text) + [trimmed]

            // Persist draft FIRST without cancelling the existing debounceTask; if save fails, prior segments & timer stay intact.
            try store.saveDraft(CasualDraft(
                botID: botID,
                casualSessionID: casualSessionID,
                segments: candidateTexts
            ))

            pendingSegments.append(entry)
            debounceTask?.cancel()
            timerGeneration &+= 1
            let gen = timerGeneration
            let epoch = trackEpoch

            let task = Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
                guard let self else { return }
                await self.flushNow(expectedEpoch: epoch, expectedTimerGeneration: gen, onReadyToDispatch: onReadyToDispatch)
            }
            debounceTask = task
        }
    }

    /// Cancels the 2.5s countdown when switching back to formal chat, atomically bumping `trackEpoch`
    /// and preserving uncommitted text safely inside the Canonical draft (never auto-sent on switch-back).
    @discardableResult
    public func cancelForTrackSwitch() -> CasualDraft? {
        serialLock.withLock {
            trackEpoch &+= 1
            timerGeneration &+= 1
            debounceTask?.cancel()
            debounceTask = nil
            let snapshotTexts = pendingSegments.map(\.text)
            pendingSegments.removeAll()
            guard !snapshotTexts.isEmpty else { return store.loadDraft(botID: botID) }
            let draft = CasualDraft(botID: botID, casualSessionID: casualSessionID, segments: snapshotTexts)
            try? store.saveDraft(draft)
            return draft
        }
    }

    /// Executes the exact two-step pre-write sequence under serialized `trackEpoch` arbitration:
    /// 1) Step 1 commit (`queued_before_send` + draft consumed) atomically under `serialLock` (consumed by segment ID)
    /// 2) Step 2 commit (`in_flight` on disk) -> ONLY AFTER Step 2 succeeds is `onReadyToDispatch` invoked!
    @discardableResult
    public func flushNow(
        expectedEpoch: UInt64? = nil,
        onReadyToDispatch: @escaping @Sendable (CasualOutboxBatch) async -> Void
    ) async -> CasualOutboxBatch? {
        await flushNow(expectedEpoch: expectedEpoch, expectedTimerGeneration: nil, onReadyToDispatch: onReadyToDispatch)
    }

    private func flushNow(
        expectedEpoch: UInt64?,
        expectedTimerGeneration: UInt64?,
        onReadyToDispatch: @escaping @Sendable (CasualOutboxBatch) async -> Void
    ) async -> CasualOutboxBatch? {
        let step1: CasualOutboxBatch? = serialLock.withLock {
            let targetEpoch = expectedEpoch ?? trackEpoch
            guard trackEpoch == targetEpoch, !pendingSegments.isEmpty else { return nil }
            if let expectedGen = expectedTimerGeneration, timerGeneration != expectedGen {
                return nil
            }
            timerGeneration &+= 1
            debounceTask?.cancel()
            debounceTask = nil
            let claimed = pendingSegments
            let claimedTexts = claimed.map(\.text)
            let claimedIDs = Set(claimed.map(\.id))

            guard let committed = try? store.commitStep1QueuedBeforeSend(
                botID: botID,
                casualSessionID: casualSessionID,
                segments: claimedTexts,
                trackEpoch: targetEpoch,
                isEpochCurrent: { self.trackEpoch == targetEpoch }
            ) else {
                return nil
            }
            pendingSegments.removeAll { claimedIDs.contains($0.id) }
            return committed
        }

        guard let step1 else { return nil }

        // Step 2: Advance the SAME `batchID` to `in_flight` on disk STRICTLY BEFORE calling `onReadyToDispatch`.
        guard let step2 = try? store.commitStep2MarkInFlight(batchID: step1.batchID) else {
            return nil
        }

        await onReadyToDispatch(step2)
        return step2
    }
}
