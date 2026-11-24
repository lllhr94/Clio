import Foundation
import SQLite3
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private let memoryStoreSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Authoritative, WAL-mode, self-healing SQLite3 memory store managing Clio's 4 memory layers,
/// persistent soft-delete tombstones, and lossless bidirectional sync with canonical `memory.json`.
public final class MemoryStore: @unchecked Sendable {
    public static let schemaVersion: Int32 = 1

    public let databaseURL: URL
    private let lock = NSLock()
    private var db: OpaquePointer?
    private var openedIdentity: FileIdentity?
    private var _lastRecoveryReason: MemoryStoreRecoveryReason = .none
    private var _needsBootstrapFromCanonical: Bool = false

    private struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    private enum SQLBinding {
        case text(String)
        case optionalText(String?)
        case int(Int32)
        case int64(Int64)
        case double(Double)
        case optionalDouble(Double?)
    }

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    deinit {
        lock.lock()
        closeLocked()
        lock.unlock()
    }

    public var lastRecoveryReason: MemoryStoreRecoveryReason {
        lock.lock()
        defer { lock.unlock() }
        return _lastRecoveryReason
    }

    public var needsBootstrapFromCanonical: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _needsBootstrapFromCanonical
    }

    // MARK: - Lifecycle & Self-Healing

    @discardableResult
    public func openOrRecover() throws -> MemoryStoreRecoveryReason {
        lock.lock()
        defer { lock.unlock() }
        return try openOrRecoverLocked()
    }

    public func meta() throws -> MemoryStoreMeta {
        lock.lock()
        defer { lock.unlock() }
        _ = try openOrRecoverLocked()
        return try readMetaStructLocked()
    }

    public func checkpoint() throws {
        lock.lock()
        defer { lock.unlock() }
        _ = try openOrRecoverLocked()
        guard let db else { return }
        let rc = sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        if rc != SQLITE_OK && rc != SQLITE_BUSY {
            throw sqliteErrorLocked(code: rc)
        }
    }

    public func close() {
        lock.lock()
        closeLocked()
        lock.unlock()
    }

    public func destroyFiles() {
        lock.lock()
        closeLocked()
        unlinkDatabaseFiles()
        _needsBootstrapFromCanonical = true
        lock.unlock()
    }

    public func resetAll(clearTombstones: Bool = true) throws {
        lock.lock()
        defer { lock.unlock() }
        _ = try openOrRecoverLocked()
        try execLocked("BEGIN IMMEDIATE;")
        do {
            try execLocked("DELETE FROM memories;")
            if clearTombstones {
                try execLocked("DELETE FROM memory_tombstones;")
            }
            try execLocked("DELETE FROM memory_reviews;")
            try execLocked("DELETE FROM memory_processed_entries;")
            try setMetaLocked("review_from_day", "")
            try setMetaLocked("budget_day", "")
            try setMetaLocked("requests", "0")
            try setMetaLocked("diary_requests", "0")
            try setMetaLocked("last_synced_json_sha256", "")
            try bumpRevisionLocked()
            try execLocked("COMMIT;")
        } catch {
            try? execLocked("ROLLBACK;")
            throw error
        }
        checkpointQuietlyLocked()
    }

    // MARK: - Read APIs

    public func list(
        layer: MemoryLayer? = nil,
        includeDeleted: Bool = false,
        secrets: [String] = []
    ) throws -> [MemoryRecord] {
        let ordered = Self.orderedSecrets(secrets)
        lock.lock()
        defer { lock.unlock() }
        _ = try openOrRecoverLocked()
        if !ordered.isEmpty {
            try scrubStoredSecretsIfNeededLocked(orderedSecrets: ordered, nowMs: Date().timeIntervalSince1970 * 1000)
        }
        return try listLocked(layer: layer, includeDeleted: includeDeleted)
    }

    public func record(id: String, includeDeleted: Bool = false) throws -> MemoryRecord? {
        lock.lock()
        defer { lock.unlock() }
        _ = try openOrRecoverLocked()
        return try fetchRecordByIDLocked(id, includeDeleted: includeDeleted)
    }

    public func tombstones() throws -> [MemoryTombstone] {
        lock.lock()
        defer { lock.unlock() }
        _ = try openOrRecoverLocked()
        return try readTombstonesLocked()
    }

    public func suppressedHashes() throws -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        _ = try openOrRecoverLocked()
        let list = try readTombstonesLocked()
        return Set(list.map(\.textSHA256))
    }

    public func isSuppressed(text: String) throws -> Bool {
        let hash = MemorySafety.retractionHash(text)
        guard !hash.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        _ = try openOrRecoverLocked()
        return try fetchTombstoneLocked(textSHA256: hash) != nil
    }

    public func activeFacts(secrets: [String] = []) throws -> [MemorySafety.Fact] {
        let ordered = Self.orderedSecrets(secrets)
        lock.lock()
        defer { lock.unlock() }
        _ = try openOrRecoverLocked()
        if !ordered.isEmpty {
            try scrubStoredSecretsIfNeededLocked(orderedSecrets: ordered, nowMs: Date().timeIntervalSince1970 * 1000)
        }
        let rows = try listLocked(layer: nil, includeDeleted: false)
        return rows.compactMap(\.safetyFact)
    }

    public func search(
        query: String,
        layers: Set<MemoryLayer> = [.pinned, .surface, .deep],
        limit: Int = 8,
        secrets: [String] = []
    ) throws -> [MemoryRecord] {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !clean.isEmpty, !layers.isEmpty else { return [] }
        var terms = clean
            .split(whereSeparator: { $0.isWhitespace || "，,、。".contains($0) })
            .map(String.init)
            .filter { !$0.isEmpty }
        for term in terms where term.count > 2 {
            let chars = Array(term)
            for idx in 0..<(chars.count - 1) {
                terms.append(String(chars[idx...idx + 1]))
            }
        }
        guard !terms.isEmpty else { return [] }

        let ordered = Self.orderedSecrets(secrets)
        lock.lock()
        defer { lock.unlock() }
        _ = try openOrRecoverLocked()
        if !ordered.isEmpty {
            try scrubStoredSecretsIfNeededLocked(orderedSecrets: ordered, nowMs: Date().timeIntervalSince1970 * 1000)
        }
        let candidates = try listLocked(layer: nil, includeDeleted: false)
            .filter { layers.contains($0.layer) }

        let scored = candidates.compactMap { row -> (MemoryRecord, Int)? in
            let haystack = (row.text + " " + row.topic).lowercased()
            let score = terms.reduce(0) { partial, term in
                partial + (haystack.contains(term) ? (term.count > 2 ? 3 : 1) : 0)
            }
            return score > 0 ? (row, score) : nil
        }.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            if lhs.0.pinned != rhs.0.pinned { return lhs.0.pinned && !rhs.0.pinned }
            return (lhs.0.usedAtMs ?? lhs.0.createdAtMs) > (rhs.0.usedAtMs ?? rhs.0.createdAtMs)
        }
        return Array(scored.prefix(max(1, limit)).map(\.0))
    }

    // MARK: - Write APIs

    @discardableResult
    public func upsert(
        _ record: MemoryRecord,
        explicitUserAction: Bool = true,
        secrets: [String] = []
    ) throws -> MemoryRecord? {
        let ordered = Self.orderedSecrets(secrets)
        let safeText = Self.redact(record.text, orderedSecrets: ordered)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safeHash = MemorySafety.retractionHash(safeText)
        guard !safeText.isEmpty, !safeHash.isEmpty else { return nil }

        var candidate = record
        candidate.text = safeText
        candidate.textSHA256 = safeHash
        candidate.topic = Self.redact(record.topic, orderedSecrets: ordered)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        candidate.deletedAtMs = nil

        lock.lock()
        defer { lock.unlock() }
        _ = try openOrRecoverLocked()

        return try performWriteTransactionLocked {
            if let tomb = try fetchTombstoneLocked(textSHA256: safeHash) {
                if explicitUserAction {
                    try deleteTombstoneLocked(textSHA256: safeHash)
                    candidate.updatedAtMs = max(candidate.updatedAtMs, tomb.deletedAtMs + 1)
                } else if candidate.automatic && !candidate.editedByUser {
                    return nil
                } else if tomb.deletedAtMs >= candidate.updatedAtMs {
                    return nil
                } else {
                    try deleteTombstoneLocked(textSHA256: safeHash)
                }
            }

            if let existingByID = try fetchRecordByIDLocked(candidate.id, includeDeleted: true) {
                var updated = candidate
                if updated.createdAtMs <= 0 { updated.createdAtMs = existingByID.createdAtMs }
                updated.updatedAtMs = max(candidate.updatedAtMs, existingByID.updatedAtMs)
                try upsertRecordRowLocked(updated)
                try bumpRevisionLocked()
                return updated
            }

            try upsertRecordRowLocked(candidate)
            try bumpRevisionLocked()
            return candidate
        }
    }

    @discardableResult
    public func pin(
        id: String,
        pinned: Bool = true,
        nowMs: Double = Date().timeIntervalSince1970 * 1000
    ) throws -> MemoryRecord? {
        lock.lock()
        defer { lock.unlock() }
        _ = try openOrRecoverLocked()

        return try performWriteTransactionLocked {
            guard var row = try fetchRecordByIDLocked(id, includeDeleted: false) else { return nil }
            row.pinned = pinned
            row.layer = pinned ? .pinned : .surface
            row.updatedAtMs = max(row.updatedAtMs, nowMs)
            row.usedAtMs = max(row.usedAtMs ?? 0, nowMs)
            try upsertRecordRowLocked(row)
            try bumpRevisionLocked()
            return row
        }
    }

    @discardableResult
    public func editText(
        id: String,
        text: String,
        editedByUser: Bool = true,
        nowMs: Double = Date().timeIntervalSince1970 * 1000,
        secrets: [String] = []
    ) throws -> MemoryRecord? {
        let ordered = Self.orderedSecrets(secrets)
        let safeText = Self.redact(text, orderedSecrets: ordered)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let newHash = MemorySafety.retractionHash(safeText)

        lock.lock()
        defer { lock.unlock() }
        _ = try openOrRecoverLocked()

        return try performWriteTransactionLocked {
            if safeText.isEmpty || newHash.isEmpty {
                _ = try softDeleteByIDLocked(id: id, nowMs: nowMs, reason: "empty_edit", orderedSecrets: ordered)
                try bumpRevisionLocked()
                return nil
            }
            guard var row = try fetchRecordByIDLocked(id, includeDeleted: false) else { return nil }
            if let tomb = try fetchTombstoneLocked(textSHA256: newHash) {
                try deleteTombstoneLocked(textSHA256: newHash)
                row.updatedAtMs = max(nowMs, tomb.deletedAtMs + 1)
            } else {
                row.updatedAtMs = max(row.updatedAtMs, nowMs)
            }
            row.text = safeText
            row.textSHA256 = newHash
            if editedByUser { row.editedByUser = true }
            try upsertRecordRowLocked(row)
            try bumpRevisionLocked()
            return row
        }
    }

    @discardableResult
    public func setLayer(
        id: String,
        layer: MemoryLayer,
        nowMs: Double = Date().timeIntervalSince1970 * 1000
    ) throws -> MemoryRecord? {
        lock.lock()
        defer { lock.unlock() }
        _ = try openOrRecoverLocked()

        return try performWriteTransactionLocked {
            guard var row = try fetchRecordByIDLocked(id, includeDeleted: false) else { return nil }
            row.layer = layer
            row.pinned = (layer == .pinned)
            row.updatedAtMs = max(row.updatedAtMs, nowMs)
            if layer == .pinned || layer == .surface {
                row.usedAtMs = max(row.usedAtMs ?? 0, nowMs)
            }
            try upsertRecordRowLocked(row)
            try bumpRevisionLocked()
            return row
        }
    }

    @discardableResult
    public func setMetadata(
        id: String,
        kind: String? = nil,
        topic: String? = nil,
        confidence: Double? = nil,
        sourceChat: String? = nil,
        sourceEntryID: String? = nil,
        nowMs: Double = Date().timeIntervalSince1970 * 1000,
        secrets: [String] = []
    ) throws -> MemoryRecord? {
        let ordered = Self.orderedSecrets(secrets)
        lock.lock()
        defer { lock.unlock() }
        _ = try openOrRecoverLocked()

        return try performWriteTransactionLocked {
            guard var row = try fetchRecordByIDLocked(id, includeDeleted: false) else { return nil }
            if let kind {
                let cleanKind = kind.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleanKind.isEmpty { row.kind = cleanKind }
            }
            if let topic {
                row.topic = Self.redact(topic, orderedSecrets: ordered).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let confidence {
                row.confidence = min(1.0, max(0.0, confidence))
            }
            if let sourceChat { row.sourceChat = sourceChat }
            if let sourceEntryID { row.sourceEntryID = sourceEntryID }
            row.updatedAtMs = max(row.updatedAtMs, nowMs)
            try upsertRecordRowLocked(row)
            try bumpRevisionLocked()
            return row
        }
    }

    @discardableResult
    public func settleSurface(
        limit: Int = 40,
        nowMs: Double = Date().timeIntervalSince1970 * 1000
    ) throws -> [String] {
        let clampedLimit = max(0, limit)
        lock.lock()
        defer { lock.unlock() }
        _ = try openOrRecoverLocked()

        return try performWriteTransactionLocked {
            let active = try listLocked(layer: nil, includeDeleted: false)
            let pinnedCount = active.filter { $0.layer == .pinned }.count
            let surfaceRows = active
                .filter { $0.layer == .surface }
                .sorted { lhs, rhs in
                    let lUsed = lhs.usedAtMs ?? lhs.createdAtMs
                    let rUsed = rhs.usedAtMs ?? rhs.createdAtMs
                    if lUsed != rUsed { return lUsed < rUsed }
                    if lhs.createdAtMs != rhs.createdAtMs { return lhs.createdAtMs < rhs.createdAtMs }
                    return lhs.id < rhs.id
                }
            let totalVisible = pinnedCount + surfaceRows.count
            guard totalVisible > clampedLimit else { return [] }
            let sinkCount = min(totalVisible - clampedLimit, surfaceRows.count)
            guard sinkCount > 0 else { return [] }
            var demoted: [String] = []
            for item in surfaceRows.prefix(sinkCount) {
                var row = item
                row.layer = .deep
                row.pinned = false
                row.updatedAtMs = max(row.updatedAtMs, nowMs)
                try upsertRecordRowLocked(row)
                demoted.append(row.id)
            }
            try bumpRevisionLocked()
            return demoted
        }
    }

    @discardableResult
    public func softDelete(
        id: String,
        nowMs: Double = Date().timeIntervalSince1970 * 1000,
        reason: String = "user_delete",
        secrets: [String] = []
    ) throws -> MemoryTombstone? {
        let ordered = Self.orderedSecrets(secrets)
        lock.lock()
        defer { lock.unlock() }
        _ = try openOrRecoverLocked()

        return try performWriteTransactionLocked {
            let tomb = try softDeleteByIDLocked(id: id, nowMs: nowMs, reason: reason, orderedSecrets: ordered)
            if tomb != nil { try bumpRevisionLocked() }
            return tomb
        }
    }

    @discardableResult
    public func softDelete(
        text: String,
        nowMs: Double = Date().timeIntervalSince1970 * 1000,
        reason: String = "retract",
        secrets: [String] = []
    ) throws -> MemoryTombstone? {
        let ordered = Self.orderedSecrets(secrets)
        let safeText = Self.redact(text, orderedSecrets: ordered)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hash = MemorySafety.retractionHash(safeText)
        guard !hash.isEmpty else { return nil }
        let safeReason = Self.redact(reason, orderedSecrets: ordered)

        lock.lock()
        defer { lock.unlock() }
        _ = try openOrRecoverLocked()

        return try performWriteTransactionLocked {
            let tomb = try softDeleteByHashLocked(
                hash: hash,
                memoryID: nil,
                nowMs: nowMs,
                reason: safeReason
            )
            try bumpRevisionLocked()
            return tomb
        }
    }

    @discardableResult
    public func restore(
        id: String,
        layer: MemoryLayer? = nil,
        nowMs: Double = Date().timeIntervalSince1970 * 1000
    ) throws -> MemoryRecord? {
        lock.lock()
        defer { lock.unlock() }
        _ = try openOrRecoverLocked()

        return try performWriteTransactionLocked {
            guard var row = try fetchRecordByIDLocked(id, includeDeleted: true) else { return nil }
            let targetLayer: MemoryLayer
            if let layer {
                targetLayer = layer
            } else if row.layer == .archived {
                targetLayer = .surface
            } else {
                targetLayer = row.layer
            }
            row.deletedAtMs = nil
            row.layer = targetLayer
            row.pinned = (targetLayer == .pinned)
            row.updatedAtMs = max(row.updatedAtMs, nowMs)
            row.usedAtMs = max(row.usedAtMs ?? 0, nowMs)
            try upsertRecordRowLocked(row)
            try deleteTombstoneLocked(textSHA256: row.textSHA256)
            try bumpRevisionLocked()
            return row
        }
    }

    @discardableResult
    public func restore(
        textSHA256: String,
        layer: MemoryLayer? = nil,
        nowMs: Double = Date().timeIntervalSince1970 * 1000
    ) throws -> MemoryRecord? {
        let cleanHash = textSHA256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard MemorySafety.isSHA256Hex(cleanHash) else { return nil }

        lock.lock()
        defer { lock.unlock() }
        _ = try openOrRecoverLocked()

        return try performWriteTransactionLocked {
            try deleteTombstoneLocked(textSHA256: cleanHash)
            guard var row = try fetchAnyRecordByHashLocked(cleanHash) else {
                try bumpRevisionLocked()
                return nil
            }
            let targetLayer: MemoryLayer = layer ?? (row.layer == .archived ? .surface : row.layer)
            row.deletedAtMs = nil
            row.layer = targetLayer
            row.pinned = (targetLayer == .pinned)
            row.updatedAtMs = max(row.updatedAtMs, nowMs)
            row.usedAtMs = max(row.usedAtMs ?? 0, nowMs)
            try upsertRecordRowLocked(row)
            try bumpRevisionLocked()
            return row
        }
    }

    @discardableResult
    public func purgeTombstone(textSHA256: String) throws -> Bool {
        let cleanHash = textSHA256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard MemorySafety.isSHA256Hex(cleanHash) else { return false }

        lock.lock()
        defer { lock.unlock() }
        _ = try openOrRecoverLocked()

        return try performWriteTransactionLocked {
            let hadTomb = try fetchTombstoneLocked(textSHA256: cleanHash) != nil
            try deleteTombstoneLocked(textSHA256: cleanHash)
            let deletedRows = try runDeleteChangesLocked(
                "DELETE FROM memories WHERE text_sha256 = ? AND deleted_at_ms IS NOT NULL;",
                bindings: [.text(cleanHash)]
            )
            if hadTomb || deletedRows > 0 {
                try bumpRevisionLocked()
                return true
            }
            return false
        }
    }

    /// Removes `memoryIDs` from stored `memory_reviews` additions/merges to keep review history aligned after deletion.
    public func pruneReviewDetails(memoryIDs: Set<String>) throws {
        guard !memoryIDs.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        _ = try openOrRecoverLocked()

        try performWriteTransactionLocked {
            let existing = try readReviewsLocked()
            guard !existing.isEmpty else { return }
            var changed = false
            let updated: [CanonicalMemoryReviewLog] = existing.map { entry in
                var copy = entry
                let beforeAdded = copy.added.count
                let beforeMerged = copy.merged.count
                copy.added.removeAll { memoryIDs.contains($0.memoryID) }
                copy.merged.removeAll { memoryIDs.contains($0.memoryID) }
                if copy.added.count != beforeAdded || copy.merged.count != beforeMerged {
                    changed = true
                }
                return copy
            }
            if changed {
                try replaceReviewsLocked(updated)
                try bumpRevisionLocked()
            }
        }
    }

    @discardableResult
    public func purgeTombstone(id: String) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        _ = try openOrRecoverLocked()

        return try performWriteTransactionLocked {
            guard let row = try fetchRecordByIDLocked(id, includeDeleted: true), row.deletedAtMs != nil else {
                return false
            }
            let removed = try runDeleteChangesLocked(
                "DELETE FROM memories WHERE id = ? AND deleted_at_ms IS NOT NULL;",
                bindings: [.text(id)]
            )
            let remainingWithHash = try countDeletedRowsByHashLocked(row.textSHA256)
            if remainingWithHash == 0 {
                try deleteTombstoneLocked(textSHA256: row.textSHA256)
            }
            if removed > 0 {
                try bumpRevisionLocked()
                return true
            }
            return false
        }
    }

    @discardableResult
    public func seedSuppressedHashes(
        _ hashes: [String],
        defaultDeletedAtMs: Double = Date().timeIntervalSince1970 * 1000
    ) throws -> Int {
        let validHashes = Set(hashes.compactMap { raw -> String? in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if MemorySafety.isSHA256Hex(trimmed) { return trimmed.lowercased() }
            let computed = MemorySafety.retractionHash(trimmed)
            return computed.isEmpty ? nil : computed
        })
        guard !validHashes.isEmpty else { return 0 }

        lock.lock()
        defer { lock.unlock() }
        _ = try openOrRecoverLocked()

        return try performWriteTransactionLocked {
            var inserted = 0
            for hash in validHashes.sorted() {
                if try fetchActiveRecordByHashLocked(hash) != nil { continue }
                if try fetchTombstoneLocked(textSHA256: hash) != nil { continue }
                try upsertTombstoneLocked(MemoryTombstone(
                    textSHA256: hash,
                    memoryID: nil,
                    deletedAtMs: defaultDeletedAtMs,
                    reason: "seeded_retraction"
                ))
                inserted += 1
            }
            if inserted > 0 { try bumpRevisionLocked() }
            return inserted
        }
    }

    // MARK: - Canonical Book Snapshot & Bidirectional Reconciliation

    public func snapshotBook(secrets: [String] = []) throws -> CanonicalMemoryBook {
        let ordered = Self.orderedSecrets(secrets)
        lock.lock()
        defer { lock.unlock() }
        _ = try openOrRecoverLocked()
        if !ordered.isEmpty {
            try scrubStoredSecretsIfNeededLocked(orderedSecrets: ordered, nowMs: Date().timeIntervalSince1970 * 1000)
        }
        return try snapshotBookLocked()
    }

    @discardableResult
    public func reconcile(
        book: CanonicalMemoryBook,
        secrets: [String] = [],
        nowMs: Double = Date().timeIntervalSince1970 * 1000,
        jsonDigest: String? = nil
    ) throws -> CanonicalMemoryBook {
        let ordered = Self.orderedSecrets(secrets)
        lock.lock()
        defer { lock.unlock() }
        _ = try openOrRecoverLocked()

        return try performWriteTransactionLocked {
            try reconcileLocked(book: book, orderedSecrets: ordered, nowMs: nowMs, jsonDigest: jsonDigest)
            let snapshot = try snapshotBookLocked()
            _needsBootstrapFromCanonical = false
            return snapshot
        }
    }

    // MARK: - Private Reconcile & Snapshot Logic

    private func scrubStoredSecretsIfNeededLocked(orderedSecrets: [String], nowMs: Double) throws {
        guard !orderedSecrets.isEmpty else { return }
        let rows = try listLocked(layer: nil, includeDeleted: true)
        let tombs = try readTombstonesLocked()
        let reviews = try readReviewsLocked()

        let hasRowSecret = rows.contains { row in
            Self.redact(row.text, orderedSecrets: orderedSecrets) != row.text
                || Self.redact(row.topic, orderedSecrets: orderedSecrets) != row.topic
        }
        let hasTombSecret = tombs.contains { tomb in
            Self.redact(tomb.reason, orderedSecrets: orderedSecrets) != tomb.reason
        }
        let hasReviewSecret = reviews.contains { review in
            Self.redact(review.conversation, orderedSecrets: orderedSecrets) != review.conversation
                || review.added.contains { Self.redact($0.text, orderedSecrets: orderedSecrets) != $0.text }
                || review.merged.contains {
                    Self.redact($0.before, orderedSecrets: orderedSecrets) != $0.before
                        || Self.redact($0.after, orderedSecrets: orderedSecrets) != $0.after
                }
        }
        guard hasRowSecret || hasTombSecret || hasReviewSecret else { return }

        _ = try performWriteTransactionLocked {
            try redactStoredStateLocked(orderedSecrets: orderedSecrets, nowMs: nowMs)
        }
    }

    private func redactStoredStateLocked(orderedSecrets: [String], nowMs: Double) throws {
        guard !orderedSecrets.isEmpty else { return }
        var changed = false

        let rows = try listLocked(layer: nil, includeDeleted: true)
        for var row in rows {
            let safeText = Self.redact(row.text, orderedSecrets: orderedSecrets)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let safeTopic = Self.redact(row.topic, orderedSecrets: orderedSecrets)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard safeText != row.text || safeTopic != row.topic else { continue }
            changed = true
            let safeHash = MemorySafety.retractionHash(safeText)
            if safeText.isEmpty || safeHash.isEmpty {
                if row.deletedAtMs == nil {
                    row.deletedAtMs = nowMs
                }
                row.text = "〔隐去〕"
                row.textSHA256 = MemorySafety.retractionHash("〔隐去〕")
            } else {
                row.text = safeText
                row.textSHA256 = safeHash
            }
            row.topic = safeTopic
            row.updatedAtMs = max(row.updatedAtMs, nowMs)
            try upsertRecordRowLocked(row)
        }

        let tombs = try readTombstonesLocked()
        for var tomb in tombs {
            let safeReason = Self.redact(tomb.reason, orderedSecrets: orderedSecrets)
            if safeReason != tomb.reason {
                tomb.reason = safeReason
                try upsertTombstoneLocked(tomb)
                changed = true
            }
        }

        let reviews = try readReviewsLocked()
        var reviewChanged = false
        let scrubbedReviews: [CanonicalMemoryReviewLog] = reviews.map { entry in
            let safeConv = Self.redact(entry.conversation, orderedSecrets: orderedSecrets)
            let safeAdded = entry.added.map {
                CanonicalMemoryReviewLog.Addition(
                    memoryID: $0.memoryID,
                    text: Self.redact($0.text, orderedSecrets: orderedSecrets)
                )
            }
            let safeMerged = entry.merged.map {
                CanonicalMemoryReviewLog.Change(
                    memoryID: $0.memoryID,
                    before: Self.redact($0.before, orderedSecrets: orderedSecrets),
                    after: Self.redact($0.after, orderedSecrets: orderedSecrets)
                )
            }
            let updated = CanonicalMemoryReviewLog(
                id: entry.id,
                at: entry.at,
                day: entry.day,
                conversation: safeConv,
                added: safeAdded,
                merged: safeMerged
            )
            if updated != entry { reviewChanged = true }
            return updated
        }
        if reviewChanged {
            try replaceReviewsLocked(scrubbedReviews)
            changed = true
        }

        if changed {
            try bumpRevisionLocked()
        }
    }

    private func reconcileLocked(
        book: CanonicalMemoryBook,
        orderedSecrets: [String],
        nowMs: Double,
        jsonDigest: String?
    ) throws {
        // Re-redact ALL retained DB rows, tombstones, and review logs against live Vault secrets first.
        if !orderedSecrets.isEmpty {
            try redactStoredStateLocked(orderedSecrets: orderedSecrets, nowMs: nowMs)
        }

        var mergedTombstones: [String: MemoryTombstone] = [:]
        for tomb in try readTombstonesLocked() {
            mergedTombstones[tomb.textSHA256] = tomb
        }
        for incoming in book.tombstones {
            let cleanHash = incoming.textSHA256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard MemorySafety.isSHA256Hex(cleanHash) else { continue }
            let safeReason = Self.redact(incoming.reason, orderedSecrets: orderedSecrets)
            if let existing = mergedTombstones[cleanHash] {
                if incoming.deletedAtMs > existing.deletedAtMs {
                    mergedTombstones[cleanHash] = MemoryTombstone(
                        textSHA256: cleanHash,
                        memoryID: incoming.memoryID ?? existing.memoryID,
                        deletedAtMs: incoming.deletedAtMs,
                        reason: safeReason.isEmpty ? existing.reason : safeReason
                    )
                }
            } else {
                mergedTombstones[cleanHash] = MemoryTombstone(
                    textSHA256: cleanHash,
                    memoryID: incoming.memoryID,
                    deletedAtMs: incoming.deletedAtMs,
                    reason: safeReason
                )
            }
        }

        // Collect all existing DB rows strictly by ID (never collapse distinct IDs by retractionHash).
        let allDBRows = try listLocked(layer: nil, includeDeleted: true)
        var rowsByID = Dictionary(allDBRows.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })

        // Enforce incoming tombstones against existing DB rows.
        for (id, var row) in rowsByID where row.deletedAtMs == nil {
            if let tomb = mergedTombstones[row.textSHA256], tomb.deletedAtMs >= row.updatedAtMs {
                row.deletedAtMs = tomb.deletedAtMs
                row.updatedAtMs = max(row.updatedAtMs, tomb.deletedAtMs)
                try upsertRecordRowLocked(row)
                rowsByID[id] = row
            }
        }

        // Reconcile incoming active + archived items from canonical book strictly by ID.
        let incomingTagged: [(item: CanonicalMemoryItem, isArchivedBucket: Bool)] =
            book.memories.map { ($0, false) } + book.archived.map { ($0, true) }

        var liveHashesInBook: Set<String> = []
        for (rawItem, isArchivedBucket) in incomingTagged {
            let safeText = Self.redact(rawItem.text, orderedSecrets: orderedSecrets)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let hash = MemorySafety.retractionHash(safeText)
            guard !safeText.isEmpty, !hash.isEmpty else { continue }
            liveHashesInBook.insert(hash)

            let incomingUpdatedAt = rawItem.effectiveUpdatedAtMs
            let isAutomaticOnly = (rawItem.automatic == true) && (rawItem.editedByUser != true)

            if let tomb = mergedTombstones[hash] {
                if isAutomaticOnly || tomb.deletedAtMs >= incomingUpdatedAt {
                    continue
                }
                // User explicitly re-added with strictly newer updatedAt > deletedAt: clear tombstone.
                mergedTombstones.removeValue(forKey: hash)
                try deleteTombstoneLocked(textSHA256: hash)
            }

            let targetLayer: MemoryLayer = isArchivedBucket ? .archived : rawItem.resolvedLayer
            let safeTopic = Self.redact(rawItem.topic ?? "", orderedSecrets: orderedSecrets)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let safeKind = (rawItem.kind?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "fact"

            if let existing = rowsByID[rawItem.id] {
                if existing.deletedAtMs != nil {
                    // DB row was tombstoned by ID; block older or automatic resurrection.
                    let deletedAt = existing.deletedAtMs ?? 0
                    if isAutomaticOnly || deletedAt >= incomingUpdatedAt {
                        continue
                    }
                }
                let merged = mergeExistingRecord(
                    existing,
                    with: rawItem,
                    safeText: safeText,
                    hash: hash,
                    targetLayer: targetLayer,
                    safeTopic: safeTopic,
                    safeKind: safeKind,
                    incomingUpdatedAt: incomingUpdatedAt
                )
                try upsertRecordRowLocked(merged)
                rowsByID[merged.id] = merged
            } else {
                let record = MemoryRecord(
                    id: rawItem.id,
                    text: safeText,
                    textSHA256: hash,
                    layer: targetLayer,
                    pinned: targetLayer == .pinned || rawItem.pinned == true,
                    kind: safeKind,
                    topic: safeTopic,
                    sourceChat: rawItem.sourceChat,
                    sourceEntryID: rawItem.sourceEntryID,
                    confidence: rawItem.confidence ?? 1.0,
                    createdAtMs: rawItem.at,
                    updatedAtMs: incomingUpdatedAt,
                    usedAtMs: rawItem.used,
                    byBot: rawItem.by,
                    automatic: rawItem.automatic == true,
                    editedByUser: rawItem.editedByUser == true,
                    deletedAtMs: nil
                )
                try upsertRecordRowLocked(record)
                rowsByID[record.id] = record
            }
        }

        // Seed untimestamped suppressedFlushHashes for items not currently live.
        for rawHash in book.suppressedFlushHashes {
            let trimmed = rawHash.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let hash = MemorySafety.isSHA256Hex(trimmed) ? trimmed.lowercased() : MemorySafety.retractionHash(trimmed)
            guard !hash.isEmpty,
                  mergedTombstones[hash] == nil,
                  !liveHashesInBook.contains(hash),
                  !rowsByID.values.contains(where: { $0.deletedAtMs == nil && $0.textSHA256 == hash }) else {
                continue
            }
            mergedTombstones[hash] = MemoryTombstone(
                textSHA256: hash,
                memoryID: nil,
                deletedAtMs: nowMs,
                reason: "suppressed_flush"
            )
        }

        for tomb in mergedTombstones.values {
            try upsertTombstoneLocked(tomb)
        }

        try mergeMetaAndLogsLocked(book: book, orderedSecrets: orderedSecrets, jsonDigest: jsonDigest)
        try bumpRevisionLocked()
    }

    private func mergeExistingRecord(
        _ existing: MemoryRecord,
        with rawItem: CanonicalMemoryItem,
        safeText: String,
        hash: String,
        targetLayer: MemoryLayer,
        safeTopic: String,
        safeKind: String,
        incomingUpdatedAt: Double
    ) -> MemoryRecord {
        if incomingUpdatedAt > existing.updatedAtMs {
            var nextLayer = targetLayer
            var nextPinned = nextLayer == .pinned || rawItem.pinned == true
            // Preserve `.pinned` if incoming item came from legacy `MemoryBook` (omits `layer`/`pinned`)
            // and did not explicitly demote to `.deep`.
            if rawItem.layer == nil && rawItem.pinned == nil && existing.pinned && rawItem.deep != true {
                nextLayer = .pinned
                nextPinned = true
            }
            return MemoryRecord(
                id: existing.id,
                text: safeText,
                textSHA256: hash,
                layer: nextLayer,
                pinned: nextPinned,
                kind: rawItem.kind != nil ? safeKind : existing.kind,
                topic: rawItem.topic != nil ? safeTopic : existing.topic,
                sourceChat: rawItem.sourceChat ?? existing.sourceChat,
                sourceEntryID: rawItem.sourceEntryID ?? existing.sourceEntryID,
                confidence: rawItem.confidence ?? existing.confidence,
                createdAtMs: min(existing.createdAtMs, rawItem.at),
                updatedAtMs: incomingUpdatedAt,
                usedAtMs: max(existing.usedAtMs ?? 0, rawItem.used ?? 0) > 0 ? max(existing.usedAtMs ?? 0, rawItem.used ?? 0) : nil,
                byBot: rawItem.by ?? existing.byBot,
                automatic: rawItem.automatic ?? existing.automatic,
                editedByUser: (rawItem.editedByUser == true) || existing.editedByUser,
                deletedAtMs: nil
            )
        }

        // DB record is newer or same timestamp: keep DB's authoritative state & enrich missing fields.
        var kept = existing
        kept.deletedAtMs = nil
        if kept.usedAtMs == nil, let used = rawItem.used { kept.usedAtMs = used }
        if !kept.editedByUser && rawItem.editedByUser == true { kept.editedByUser = true }
        if kept.topic.isEmpty && !safeTopic.isEmpty { kept.topic = safeTopic }
        if kept.kind == "fact" && safeKind != "fact" { kept.kind = safeKind }
        if kept.sourceChat == nil, let src = rawItem.sourceChat { kept.sourceChat = src }
        if kept.sourceEntryID == nil, let entry = rawItem.sourceEntryID { kept.sourceEntryID = entry }
        return kept
    }

    private func mergeMetaAndLogsLocked(
        book: CanonicalMemoryBook,
        orderedSecrets: [String],
        jsonDigest: String?
    ) throws {
        let metaMap = try readMetaMapLocked()

        let existingReviewFrom = metaMap["review_from_day"].flatMap { $0.isEmpty ? nil : $0 }
        let mergedReviewFrom = [existingReviewFrom, book.reviewFromDay].compactMap { $0 }.min() ?? ""
        try setMetaLocked("review_from_day", mergedReviewFrom)

        let existingBudgetDay = metaMap["budget_day"].flatMap { $0.isEmpty ? nil : $0 }
        let existingReq = Int(metaMap["requests"] ?? "") ?? 0
        let existingDiaryReq = Int(metaMap["diary_requests"] ?? "") ?? 0

        let mergedBudgetDay: String
        let mergedReq: Int
        let mergedDiaryReq: Int
        if let dbDay = existingBudgetDay, let bookDay = book.budgetDay {
            if bookDay > dbDay {
                mergedBudgetDay = bookDay
                mergedReq = book.requests
                mergedDiaryReq = book.diaryRequests
            } else if dbDay > bookDay {
                mergedBudgetDay = dbDay
                mergedReq = existingReq
                mergedDiaryReq = existingDiaryReq
            } else {
                mergedBudgetDay = dbDay
                mergedReq = max(existingReq, book.requests)
                mergedDiaryReq = max(existingDiaryReq, book.diaryRequests)
            }
        } else if let bookDay = book.budgetDay {
            mergedBudgetDay = bookDay
            mergedReq = book.requests
            mergedDiaryReq = book.diaryRequests
        } else if let dbDay = existingBudgetDay {
            mergedBudgetDay = dbDay
            mergedReq = existingReq
            mergedDiaryReq = existingDiaryReq
        } else {
            mergedBudgetDay = ""
            mergedReq = max(existingReq, book.requests)
            mergedDiaryReq = max(existingDiaryReq, book.diaryRequests)
        }

        try setMetaLocked("budget_day", mergedBudgetDay)
        try setMetaLocked("requests", String(mergedReq))
        try setMetaLocked("diary_requests", String(mergedDiaryReq))

        if let jsonDigest {
            try setMetaLocked("last_synced_json_sha256", jsonDigest)
        }

        // Merge processed entry IDs (union per day).
        if !book.processed.isEmpty {
            let sql = "INSERT OR IGNORE INTO memory_processed_entries(day, entry_id) VALUES (?, ?);"
            guard let db else { throw MemoryStoreError.sqlite(code: SQLITE_MISUSE, message: "database closed") }
            var stmt: OpaquePointer?
            let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            guard rc == SQLITE_OK, let stmt else { throw sqliteErrorLocked(code: rc) }
            defer { sqlite3_finalize(stmt) }
            for (day, ids) in book.processed {
                for entryID in ids {
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                    try bind([.text(day), .text(entryID)], to: stmt)
                    let stepRC = sqlite3_step(stmt)
                    guard stepRC == SQLITE_DONE else { throw sqliteErrorLocked(code: stepRC) }
                }
            }
        }

        // Merge review logs (dedup by id, redact secrets, keep newest 100).
        if !book.reviews.isEmpty {
            var byID: [UUID: CanonicalMemoryReviewLog] = [:]
            for existing in try readReviewsLocked() {
                byID[existing.id] = existing
            }
            for incoming in book.reviews {
                let sanitized = CanonicalMemoryReviewLog(
                    id: incoming.id,
                    at: incoming.at,
                    day: incoming.day,
                    conversation: Self.redact(incoming.conversation, orderedSecrets: orderedSecrets),
                    added: incoming.added.map {
                        .init(memoryID: $0.memoryID, text: Self.redact($0.text, orderedSecrets: orderedSecrets))
                    },
                    merged: incoming.merged.map {
                        .init(
                            memoryID: $0.memoryID,
                            before: Self.redact($0.before, orderedSecrets: orderedSecrets),
                            after: Self.redact($0.after, orderedSecrets: orderedSecrets)
                        )
                    }
                )
                byID[sanitized.id] = sanitized
            }
            let sorted = Array(byID.values.sorted { $0.at > $1.at }.prefix(100))
            try replaceReviewsLocked(sorted)
        }
    }

    private func snapshotBookLocked() throws -> CanonicalMemoryBook {
        let activeRows = try listLocked(layer: nil, includeDeleted: false)
        let activeItems = activeRows.filter { $0.layer != .archived }.map(CanonicalMemoryItem.init(from:))
        let archivedItems = activeRows.filter { $0.layer == .archived }.map(CanonicalMemoryItem.init(from:))
        let tombs = try readTombstonesLocked()
        let reviews = try readReviewsLocked()
        let processed = try readProcessedLocked()
        let metaMap = try readMetaMapLocked()

        let reviewFromDay = metaMap["review_from_day"].flatMap { $0.isEmpty ? nil : $0 }
        let budgetDay = metaMap["budget_day"].flatMap { $0.isEmpty ? nil : $0 }
        let requests = Int(metaMap["requests"] ?? "") ?? 0
        let diaryRequests = Int(metaMap["diary_requests"] ?? "") ?? 0
        let hashes = tombs.map(\.textSHA256).sorted()

        return CanonicalMemoryBook(
            memories: activeItems,
            archived: archivedItems,
            reviews: reviews,
            processed: processed,
            reviewFromDay: reviewFromDay,
            budgetDay: budgetDay,
            requests: requests,
            diaryRequests: diaryRequests,
            suppressedFlushHashes: hashes,
            tombstones: tombs
        )
    }

    // MARK: - Private SQLite Operations

    private enum ValidationOutcome {
        case valid
        case recover(MemoryStoreRecoveryReason)
        case transient(MemoryStoreError)
    }

    private func performWriteTransactionLocked<T>(_ body: () throws -> T) throws -> T {
        do {
            try execLocked("BEGIN IMMEDIATE;")
            do {
                let result = try body()
                try execLocked("COMMIT;")
                return result
            } catch {
                try? execLocked("ROLLBACK;")
                throw error
            }
        } catch {
            if isCorruptionError(error) {
                try? recreateFreshDatabaseLocked(reason: .corrupt)
            }
            throw error
        }
    }

    private func openOrRecoverLocked() throws -> MemoryStoreRecoveryReason {
        if db != nil {
            if let currentIdentity = Self.fileIdentity(databaseURL) {
                if currentIdentity == openedIdentity {
                    return .none
                }
                closeLocked()
            } else {
                closeLocked()
                unlinkDatabaseFiles()
                try createFreshDatabaseLocked(reason: .externalDeletion)
                return .externalDeletion
            }
        }

        let fm = FileManager.default
        let parentDir = databaseURL.deletingLastPathComponent()
        try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)

        guard fm.fileExists(atPath: databaseURL.path) else {
            unlinkDatabaseFiles()
            try createFreshDatabaseLocked(reason: .missing)
            return .missing
        }

        var candidate: OpaquePointer?
        let openRC = sqlite3_open_v2(
            databaseURL.path,
            &candidate,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openRC == SQLITE_OK, let validCandidate = candidate else {
            let errMsg = candidate.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite open error \(openRC)"
            if let candidate { sqlite3_close_v2(candidate) }
            if isCorruptionCode(openRC) {
                try recreateFreshDatabaseLocked(reason: .corrupt)
                return .corrupt
            }
            // Transient errors (SQLITE_BUSY / SQLITE_LOCKED / SQLITE_PERM / SQLITE_CANTOPEN) must preserve the DB file.
            throw MemoryStoreError.openFailed(code: openRC, message: errMsg)
        }

        self.db = validCandidate

        switch validateOpenedDatabaseLocked() {
        case .valid:
            do {
                try configureRuntimePragmasLocked()
                self.openedIdentity = Self.fileIdentity(databaseURL)
                _lastRecoveryReason = .none
                return .none
            } catch {
                if isCorruptionError(error) {
                    try recreateFreshDatabaseLocked(reason: .corrupt)
                    return .corrupt
                }
                closeLocked()
                throw error
            }
        case .recover(let reason):
            try recreateFreshDatabaseLocked(reason: reason)
            return reason
        case .transient(let error):
            closeLocked()
            throw error
        }
    }

    private func validateOpenedDatabaseLocked() -> ValidationOutcome {
        do {
            try execLocked("PRAGMA busy_timeout = 5000;")

            let check = try scalarStringLocked("PRAGMA quick_check(1);")
            guard check == "ok" else { return .recover(.corrupt) }

            let userVer = try scalarInt32Locked("PRAGMA user_version;")
            guard userVer == Self.schemaVersion else { return .recover(.schemaMismatch) }

            let expectedTables: Set<String> = [
                "store_meta",
                "memories",
                "memory_tombstones",
                "memory_reviews",
                "memory_processed_entries",
            ]
            let foundTables = try existingTableNamesLocked()
            guard expectedTables.isSubset(of: foundTables) else { return .recover(.schemaMismatch) }

            let metaMap = try readMetaMapLocked()
            guard metaMap["schema_version"] == String(Self.schemaVersion) else { return .recover(.schemaMismatch) }
            return .valid
        } catch let storeError as MemoryStoreError {
            if isCorruptionError(storeError) {
                return .recover(.corrupt)
            }
            return .transient(storeError)
        } catch {
            return .transient(.sqlite(code: SQLITE_ERROR, message: error.localizedDescription))
        }
    }

    private func recreateFreshDatabaseLocked(reason: MemoryStoreRecoveryReason) throws {
        closeLocked()
        if reason == .corrupt || reason == .schemaMismatch {
            quarantineCorruptDatabaseFilesLocked()
        } else {
            unlinkDatabaseFiles()
        }
        try createFreshDatabaseLocked(reason: reason)
    }

    private func quarantineCorruptDatabaseFilesLocked() {
        let fm = FileManager.default
        if fm.fileExists(atPath: databaseURL.path) {
            let stamp = Int64(Date().timeIntervalSince1970 * 1000)
            let suffix = UUID().uuidString.prefix(6)
            let quarantineURL = databaseURL
                .deletingLastPathComponent()
                .appendingPathComponent("\(databaseURL.lastPathComponent).corrupt-\(stamp)-\(suffix)")
            do {
                try fm.moveItem(at: databaseURL, to: quarantineURL)
            } catch {
                try? fm.removeItem(at: databaseURL)
            }
        }
        for sidecar in ["-wal", "-shm", "-journal"] {
            try? fm.removeItem(atPath: databaseURL.path + sidecar)
        }
    }

    private func createFreshDatabaseLocked(reason: MemoryStoreRecoveryReason) throws {
        let fm = FileManager.default
        let parentDir = databaseURL.deletingLastPathComponent()
        try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)

        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(
            databaseURL.path,
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard rc == SQLITE_OK, let opened = handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown open error"
            if let handle { sqlite3_close_v2(handle) }
            throw MemoryStoreError.openFailed(code: rc, message: msg)
        }

        self.db = opened
        do {
            try configureRuntimePragmasLocked()
            try createSchemaLocked()
            self.openedIdentity = Self.fileIdentity(databaseURL)
            _lastRecoveryReason = reason
            _needsBootstrapFromCanonical = true
        } catch {
            closeLocked()
            unlinkDatabaseFiles()
            throw error
        }
    }

    private func configureRuntimePragmasLocked() throws {
        try execLocked("PRAGMA busy_timeout = 5000;")
        try execLocked("PRAGMA journal_mode = WAL;")
        try execLocked("PRAGMA synchronous = NORMAL;")
        try execLocked("PRAGMA foreign_keys = ON;")
    }

    private func createSchemaLocked() throws {
        try execLocked("BEGIN IMMEDIATE;")
        do {
            try execLocked("""
            CREATE TABLE store_meta (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            """)
            try execLocked("""
            CREATE TABLE memories (
                id TEXT PRIMARY KEY,
                text TEXT NOT NULL,
                text_sha256 TEXT NOT NULL,
                layer TEXT NOT NULL CHECK (layer IN ('pinned', 'surface', 'deep', 'archived')),
                pinned INTEGER NOT NULL DEFAULT 0 CHECK (pinned IN (0, 1)),
                kind TEXT NOT NULL DEFAULT 'fact',
                topic TEXT NOT NULL DEFAULT '',
                source_chat TEXT,
                source_entry_id TEXT,
                confidence REAL NOT NULL DEFAULT 1.0,
                created_at_ms REAL NOT NULL,
                updated_at_ms REAL NOT NULL,
                used_at_ms REAL,
                by_bot TEXT,
                automatic INTEGER NOT NULL DEFAULT 0 CHECK (automatic IN (0, 1)),
                edited_by_user INTEGER NOT NULL DEFAULT 0 CHECK (edited_by_user IN (0, 1)),
                deleted_at_ms REAL
            );
            """)
            try execLocked("CREATE INDEX idx_memories_active_layer ON memories(deleted_at_ms, layer, created_at_ms, id);")
            try execLocked("CREATE INDEX idx_memories_sha256 ON memories(text_sha256);")

            try execLocked("""
            CREATE TABLE memory_tombstones (
                text_sha256 TEXT PRIMARY KEY,
                memory_id TEXT,
                deleted_at_ms REAL NOT NULL,
                reason TEXT NOT NULL DEFAULT ''
            );
            """)
            try execLocked("CREATE INDEX idx_memory_tombstones_deleted_at ON memory_tombstones(deleted_at_ms DESC);")

            try execLocked("""
            CREATE TABLE memory_reviews (
                id TEXT PRIMARY KEY,
                at_sec REAL NOT NULL,
                day TEXT NOT NULL,
                conversation TEXT NOT NULL,
                payload_json TEXT NOT NULL,
                sort_order INTEGER NOT NULL DEFAULT 0
            );
            """)

            try execLocked("""
            CREATE TABLE memory_processed_entries (
                day TEXT NOT NULL,
                entry_id TEXT NOT NULL,
                PRIMARY KEY (day, entry_id)
            );
            """)

            try setMetaLocked("schema_version", String(Self.schemaVersion))
            try setMetaLocked("instance_id", UUID().uuidString)
            try setMetaLocked("revision", "0")
            try setMetaLocked("last_synced_json_sha256", "")
            try setMetaLocked("review_from_day", "")
            try setMetaLocked("budget_day", "")
            try setMetaLocked("requests", "0")
            try setMetaLocked("diary_requests", "0")
            try execLocked("PRAGMA user_version = \(Self.schemaVersion);")
            try execLocked("COMMIT;")
        } catch {
            try? execLocked("ROLLBACK;")
            throw error
        }
    }

    private func closeLocked() {
        guard let db else { return }
        sqlite3_close_v2(db)
        self.db = nil
        self.openedIdentity = nil
    }

    private func checkpointQuietlyLocked() {
        guard let db else { return }
        _ = sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
    }

    private func unlinkDatabaseFiles() {
        let fm = FileManager.default
        let paths = [
            databaseURL.path,
            databaseURL.path + "-wal",
            databaseURL.path + "-shm",
            databaseURL.path + "-journal",
        ]
        for path in paths {
            try? fm.removeItem(atPath: path)
        }
    }

    // MARK: - Private Row Queries & Mutations

    private func upsertRecordRowLocked(_ record: MemoryRecord) throws {
        let resolvedPinned = record.pinned || record.layer == .pinned
        let resolvedLayer: MemoryLayer = resolvedPinned ? .pinned : record.layer
        let sql = """
        INSERT INTO memories (
            id, text, text_sha256, layer, pinned, kind, topic, source_chat, source_entry_id,
            confidence, created_at_ms, updated_at_ms, used_at_ms, by_bot, automatic, edited_by_user, deleted_at_ms
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            text = excluded.text,
            text_sha256 = excluded.text_sha256,
            layer = excluded.layer,
            pinned = excluded.pinned,
            kind = excluded.kind,
            topic = excluded.topic,
            source_chat = excluded.source_chat,
            source_entry_id = excluded.source_entry_id,
            confidence = excluded.confidence,
            created_at_ms = excluded.created_at_ms,
            updated_at_ms = excluded.updated_at_ms,
            used_at_ms = excluded.used_at_ms,
            by_bot = excluded.by_bot,
            automatic = excluded.automatic,
            edited_by_user = excluded.edited_by_user,
            deleted_at_ms = excluded.deleted_at_ms;
        """
        try runPreparedLocked(sql, bindings: [
            .text(record.id),
            .text(record.text),
            .text(record.textSHA256),
            .text(resolvedLayer.rawValue),
            .int(resolvedPinned ? 1 : 0),
            .text(record.kind),
            .text(record.topic),
            .optionalText(record.sourceChat),
            .optionalText(record.sourceEntryID),
            .double(min(1.0, max(0.0, record.confidence))),
            .double(record.createdAtMs),
            .double(record.updatedAtMs),
            .optionalDouble(record.usedAtMs),
            .optionalText(record.byBot),
            .int(record.automatic ? 1 : 0),
            .int(record.editedByUser ? 1 : 0),
            .optionalDouble(record.deletedAtMs),
        ])
    }

    private func softDeleteByIDLocked(
        id: String,
        nowMs: Double,
        reason: String,
        orderedSecrets: [String]
    ) throws -> MemoryTombstone? {
        guard var row = try fetchRecordByIDLocked(id, includeDeleted: true) else { return nil }
        let deletedAt = max(row.deletedAtMs ?? 0, nowMs)
        row.deletedAtMs = deletedAt
        row.updatedAtMs = max(row.updatedAtMs, deletedAt)
        try upsertRecordRowLocked(row)

        let safeReason = Self.redact(reason, orderedSecrets: orderedSecrets)
        return try softDeleteByHashLocked(
            hash: row.textSHA256,
            memoryID: row.id,
            nowMs: deletedAt,
            reason: safeReason
        )
    }

    private func softDeleteByHashLocked(
        hash: String,
        memoryID: String?,
        nowMs: Double,
        reason: String
    ) throws -> MemoryTombstone {
        let existing = try fetchTombstoneLocked(textSHA256: hash)
        let deletedAt = max(existing?.deletedAtMs ?? 0, nowMs)
        let tomb = MemoryTombstone(
            textSHA256: hash,
            memoryID: memoryID ?? existing?.memoryID,
            deletedAtMs: deletedAt,
            reason: reason.isEmpty ? (existing?.reason ?? "user_delete") : reason
        )
        try upsertTombstoneLocked(tomb)
        try runPreparedLocked(
            """
            UPDATE memories
            SET deleted_at_ms = ?,
                updated_at_ms = CASE WHEN updated_at_ms > ? THEN updated_at_ms ELSE ? END
            WHERE text_sha256 = ? AND deleted_at_ms IS NULL;
            """,
            bindings: [.double(deletedAt), .double(deletedAt), .double(deletedAt), .text(hash)]
        )
        return tomb
    }

    private func listLocked(layer: MemoryLayer?, includeDeleted: Bool) throws -> [MemoryRecord] {
        guard let db else { throw MemoryStoreError.sqlite(code: SQLITE_MISUSE, message: "database closed") }
        var clauses: [String] = []
        var bindings: [SQLBinding] = []
        if !includeDeleted { clauses.append("deleted_at_ms IS NULL") }
        if let layer {
            clauses.append("layer = ?")
            bindings.append(.text(layer.rawValue))
        }
        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        let sql = """
        SELECT id, text, text_sha256, layer, pinned, kind, topic, source_chat, source_entry_id,
               confidence, created_at_ms, updated_at_ms, used_at_ms, by_bot, automatic, edited_by_user, deleted_at_ms
        FROM memories
        \(whereSQL)
        ORDER BY created_at_ms ASC, id ASC;
        """
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw sqliteErrorLocked(code: rc) }
        defer { sqlite3_finalize(stmt) }
        try bind(bindings, to: stmt)

        var rows: [MemoryRecord] = []
        while true {
            let stepRC = sqlite3_step(stmt)
            if stepRC == SQLITE_ROW {
                rows.append(Self.decodeRecordRow(stmt))
            } else if stepRC == SQLITE_DONE {
                break
            } else {
                throw sqliteErrorLocked(code: stepRC)
            }
        }
        return rows
    }

    private func fetchRecordByIDLocked(_ id: String, includeDeleted: Bool) throws -> MemoryRecord? {
        guard let db else { throw MemoryStoreError.sqlite(code: SQLITE_MISUSE, message: "database closed") }
        let deletedFilter = includeDeleted ? "" : " AND deleted_at_ms IS NULL"
        let sql = """
        SELECT id, text, text_sha256, layer, pinned, kind, topic, source_chat, source_entry_id,
               confidence, created_at_ms, updated_at_ms, used_at_ms, by_bot, automatic, edited_by_user, deleted_at_ms
        FROM memories
        WHERE id = ?\(deletedFilter)
        LIMIT 1;
        """
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw sqliteErrorLocked(code: rc) }
        defer { sqlite3_finalize(stmt) }
        try bind([.text(id)], to: stmt)
        let stepRC = sqlite3_step(stmt)
        if stepRC == SQLITE_ROW { return Self.decodeRecordRow(stmt) }
        if stepRC == SQLITE_DONE { return nil }
        throw sqliteErrorLocked(code: stepRC)
    }

    private func fetchActiveRecordByHashLocked(_ hash: String) throws -> MemoryRecord? {
        guard let db else { throw MemoryStoreError.sqlite(code: SQLITE_MISUSE, message: "database closed") }
        let sql = """
        SELECT id, text, text_sha256, layer, pinned, kind, topic, source_chat, source_entry_id,
               confidence, created_at_ms, updated_at_ms, used_at_ms, by_bot, automatic, edited_by_user, deleted_at_ms
        FROM memories
        WHERE text_sha256 = ? AND deleted_at_ms IS NULL
        ORDER BY updated_at_ms DESC, id ASC
        LIMIT 1;
        """
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw sqliteErrorLocked(code: rc) }
        defer { sqlite3_finalize(stmt) }
        try bind([.text(hash)], to: stmt)
        let stepRC = sqlite3_step(stmt)
        if stepRC == SQLITE_ROW { return Self.decodeRecordRow(stmt) }
        if stepRC == SQLITE_DONE { return nil }
        throw sqliteErrorLocked(code: stepRC)
    }

    private func fetchAnyRecordByHashLocked(_ hash: String) throws -> MemoryRecord? {
        guard let db else { throw MemoryStoreError.sqlite(code: SQLITE_MISUSE, message: "database closed") }
        let sql = """
        SELECT id, text, text_sha256, layer, pinned, kind, topic, source_chat, source_entry_id,
               confidence, created_at_ms, updated_at_ms, used_at_ms, by_bot, automatic, edited_by_user, deleted_at_ms
        FROM memories
        WHERE text_sha256 = ?
        ORDER BY updated_at_ms DESC, id ASC
        LIMIT 1;
        """
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw sqliteErrorLocked(code: rc) }
        defer { sqlite3_finalize(stmt) }
        try bind([.text(hash)], to: stmt)
        let stepRC = sqlite3_step(stmt)
        if stepRC == SQLITE_ROW { return Self.decodeRecordRow(stmt) }
        if stepRC == SQLITE_DONE { return nil }
        throw sqliteErrorLocked(code: stepRC)
    }

    private func countDeletedRowsByHashLocked(_ hash: String) throws -> Int {
        guard let db else { throw MemoryStoreError.sqlite(code: SQLITE_MISUSE, message: "database closed") }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(
            db,
            "SELECT COUNT(*) FROM memories WHERE text_sha256 = ? AND deleted_at_ms IS NOT NULL;",
            -1,
            &stmt,
            nil
        )
        guard rc == SQLITE_OK, let stmt else { throw sqliteErrorLocked(code: rc) }
        defer { sqlite3_finalize(stmt) }
        try bind([.text(hash)], to: stmt)
        let stepRC = sqlite3_step(stmt)
        guard stepRC == SQLITE_ROW else { throw sqliteErrorLocked(code: stepRC) }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func upsertTombstoneLocked(_ tomb: MemoryTombstone) throws {
        try runPreparedLocked(
            """
            INSERT INTO memory_tombstones (text_sha256, memory_id, deleted_at_ms, reason)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(text_sha256) DO UPDATE SET
                memory_id = COALESCE(excluded.memory_id, memory_tombstones.memory_id),
                deleted_at_ms = CASE
                    WHEN excluded.deleted_at_ms > memory_tombstones.deleted_at_ms
                    THEN excluded.deleted_at_ms
                    ELSE memory_tombstones.deleted_at_ms
                END,
                reason = CASE
                    WHEN excluded.reason != '' THEN excluded.reason
                    ELSE memory_tombstones.reason
                END;
            """,
            bindings: [
                .text(tomb.textSHA256),
                .optionalText(tomb.memoryID),
                .double(tomb.deletedAtMs),
                .text(tomb.reason),
            ]
        )
    }

    private func fetchTombstoneLocked(textSHA256: String) throws -> MemoryTombstone? {
        guard let db else { throw MemoryStoreError.sqlite(code: SQLITE_MISUSE, message: "database closed") }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(
            db,
            "SELECT text_sha256, memory_id, deleted_at_ms, reason FROM memory_tombstones WHERE text_sha256 = ? LIMIT 1;",
            -1,
            &stmt,
            nil
        )
        guard rc == SQLITE_OK, let stmt else { throw sqliteErrorLocked(code: rc) }
        defer { sqlite3_finalize(stmt) }
        try bind([.text(textSHA256)], to: stmt)
        let stepRC = sqlite3_step(stmt)
        if stepRC == SQLITE_ROW {
            return MemoryTombstone(
                textSHA256: Self.columnText(stmt, 0),
                memoryID: Self.columnOptionalText(stmt, 1),
                deletedAtMs: sqlite3_column_double(stmt, 2),
                reason: Self.columnText(stmt, 3)
            )
        }
        if stepRC == SQLITE_DONE { return nil }
        throw sqliteErrorLocked(code: stepRC)
    }

    private func deleteTombstoneLocked(textSHA256: String) throws {
        try runPreparedLocked(
            "DELETE FROM memory_tombstones WHERE text_sha256 = ?;",
            bindings: [.text(textSHA256)]
        )
    }

    private func readTombstonesLocked() throws -> [MemoryTombstone] {
        guard let db else { throw MemoryStoreError.sqlite(code: SQLITE_MISUSE, message: "database closed") }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(
            db,
            "SELECT text_sha256, memory_id, deleted_at_ms, reason FROM memory_tombstones ORDER BY deleted_at_ms DESC, text_sha256 ASC;",
            -1,
            &stmt,
            nil
        )
        guard rc == SQLITE_OK, let stmt else { throw sqliteErrorLocked(code: rc) }
        defer { sqlite3_finalize(stmt) }

        var list: [MemoryTombstone] = []
        while true {
            let stepRC = sqlite3_step(stmt)
            if stepRC == SQLITE_ROW {
                list.append(MemoryTombstone(
                    textSHA256: Self.columnText(stmt, 0),
                    memoryID: Self.columnOptionalText(stmt, 1),
                    deletedAtMs: sqlite3_column_double(stmt, 2),
                    reason: Self.columnText(stmt, 3)
                ))
            } else if stepRC == SQLITE_DONE {
                break
            } else {
                throw sqliteErrorLocked(code: stepRC)
            }
        }
        return list
    }

    private func readReviewsLocked() throws -> [CanonicalMemoryReviewLog] {
        guard let db else { throw MemoryStoreError.sqlite(code: SQLITE_MISUSE, message: "database closed") }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(
            db,
            "SELECT payload_json FROM memory_reviews ORDER BY at_sec DESC, sort_order ASC;",
            -1,
            &stmt,
            nil
        )
        guard rc == SQLITE_OK, let stmt else { throw sqliteErrorLocked(code: rc) }
        defer { sqlite3_finalize(stmt) }

        let decoder = JSONDecoder()
        var list: [CanonicalMemoryReviewLog] = []
        while true {
            let stepRC = sqlite3_step(stmt)
            if stepRC == SQLITE_ROW {
                let raw = Self.columnText(stmt, 0)
                if let decoded = try? decoder.decode(CanonicalMemoryReviewLog.self, from: Data(raw.utf8)) {
                    list.append(decoded)
                }
            } else if stepRC == SQLITE_DONE {
                break
            } else {
                throw sqliteErrorLocked(code: stepRC)
            }
        }
        return list
    }

    private func replaceReviewsLocked(_ reviews: [CanonicalMemoryReviewLog]) throws {
        try execLocked("DELETE FROM memory_reviews;")
        guard !reviews.isEmpty else { return }
        guard let db else { throw MemoryStoreError.sqlite(code: SQLITE_MISUSE, message: "database closed") }
        let sql = """
        INSERT INTO memory_reviews(id, at_sec, day, conversation, payload_json, sort_order)
        VALUES (?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw sqliteErrorLocked(code: rc) }
        defer { sqlite3_finalize(stmt) }

        let encoder = JSONEncoder()
        for (index, review) in reviews.enumerated() {
            let payloadData = try encoder.encode(review)
            let payloadString = String(decoding: payloadData, as: UTF8.self)
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            try bind([
                .text(review.id.uuidString),
                .double(review.at.timeIntervalSince1970),
                .text(review.day),
                .text(review.conversation),
                .text(payloadString),
                .int(Int32(index)),
            ], to: stmt)
            let stepRC = sqlite3_step(stmt)
            guard stepRC == SQLITE_DONE else { throw sqliteErrorLocked(code: stepRC) }
        }
    }

    private func readProcessedLocked() throws -> [String: Set<String>] {
        guard let db else { throw MemoryStoreError.sqlite(code: SQLITE_MISUSE, message: "database closed") }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, "SELECT day, entry_id FROM memory_processed_entries;", -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw sqliteErrorLocked(code: rc) }
        defer { sqlite3_finalize(stmt) }

        var result: [String: Set<String>] = [:]
        while true {
            let stepRC = sqlite3_step(stmt)
            if stepRC == SQLITE_ROW {
                let day = Self.columnText(stmt, 0)
                let entryID = Self.columnText(stmt, 1)
                result[day, default: []].insert(entryID)
            } else if stepRC == SQLITE_DONE {
                break
            } else {
                throw sqliteErrorLocked(code: stepRC)
            }
        }
        return result
    }

    // MARK: - Meta & SQLite Helpers

    private func readMetaStructLocked() throws -> MemoryStoreMeta {
        let map = try readMetaMapLocked()
        return MemoryStoreMeta(
            schemaVersion: Int32(map["schema_version"] ?? "") ?? 0,
            instanceID: map["instance_id"] ?? "",
            revision: Int64(map["revision"] ?? "") ?? 0,
            lastSyncedJSONSHA256: map["last_synced_json_sha256"] ?? ""
        )
    }

    private func bumpRevisionLocked() throws {
        let map = try readMetaMapLocked()
        let current = Int64(map["revision"] ?? "") ?? 0
        try setMetaLocked("revision", String(current + 1))
    }

    private func setMetaLocked(_ key: String, _ value: String) throws {
        try runPreparedLocked(
            "INSERT OR REPLACE INTO store_meta(key, value) VALUES (?, ?);",
            bindings: [.text(key), .text(value)]
        )
    }

    private func readMetaMapLocked() throws -> [String: String] {
        guard let db else { throw MemoryStoreError.sqlite(code: SQLITE_MISUSE, message: "database closed") }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, "SELECT key, value FROM store_meta;", -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw sqliteErrorLocked(code: rc) }
        defer { sqlite3_finalize(stmt) }

        var map: [String: String] = [:]
        while true {
            let stepRC = sqlite3_step(stmt)
            if stepRC == SQLITE_ROW {
                map[Self.columnText(stmt, 0)] = Self.columnText(stmt, 1)
            } else if stepRC == SQLITE_DONE {
                break
            } else {
                throw sqliteErrorLocked(code: stepRC)
            }
        }
        return map
    }

    private func existingTableNamesLocked() throws -> Set<String> {
        guard let db else { throw MemoryStoreError.sqlite(code: SQLITE_MISUSE, message: "database closed") }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type = 'table';", -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw sqliteErrorLocked(code: rc) }
        defer { sqlite3_finalize(stmt) }

        var names: Set<String> = []
        while true {
            let stepRC = sqlite3_step(stmt)
            if stepRC == SQLITE_ROW {
                names.insert(Self.columnText(stmt, 0))
            } else if stepRC == SQLITE_DONE {
                break
            } else {
                throw sqliteErrorLocked(code: stepRC)
            }
        }
        return names
    }

    private func runDeleteChangesLocked(_ sql: String, bindings: [SQLBinding]) throws -> Int {
        guard let db else { throw MemoryStoreError.sqlite(code: SQLITE_MISUSE, message: "database closed") }
        try runPreparedLocked(sql, bindings: bindings)
        return Int(sqlite3_changes(db))
    }

    private func runPreparedLocked(_ sql: String, bindings: [SQLBinding] = []) throws {
        guard let db else { throw MemoryStoreError.sqlite(code: SQLITE_MISUSE, message: "database closed") }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw sqliteErrorLocked(code: rc) }
        defer { sqlite3_finalize(stmt) }

        try bind(bindings, to: stmt)
        let stepRC = sqlite3_step(stmt)
        guard stepRC == SQLITE_DONE else { throw sqliteErrorLocked(code: stepRC) }
    }

    private func bind(_ bindings: [SQLBinding], to stmt: OpaquePointer) throws {
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let rc: Int32
            switch value {
            case .text(let string):
                rc = string.withCString { cStr in
                    sqlite3_bind_text(stmt, index, cStr, -1, memoryStoreSQLiteTransient)
                }
            case .optionalText(let optional):
                if let string = optional {
                    rc = string.withCString { cStr in
                        sqlite3_bind_text(stmt, index, cStr, -1, memoryStoreSQLiteTransient)
                    }
                } else {
                    rc = sqlite3_bind_null(stmt, index)
                }
            case .int(let intVal):
                rc = sqlite3_bind_int(stmt, index, intVal)
            case .int64(let int64Val):
                rc = sqlite3_bind_int64(stmt, index, int64Val)
            case .double(let doubleVal):
                rc = sqlite3_bind_double(stmt, index, doubleVal)
            case .optionalDouble(let optional):
                if let doubleVal = optional {
                    rc = sqlite3_bind_double(stmt, index, doubleVal)
                } else {
                    rc = sqlite3_bind_null(stmt, index)
                }
            }
            guard rc == SQLITE_OK else { throw sqliteErrorLocked(code: rc) }
        }
    }

    private func execLocked(_ sql: String) throws {
        guard let db else { throw MemoryStoreError.sqlite(code: SQLITE_MISUSE, message: "database closed") }
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            if let errMsg { sqlite3_free(errMsg) }
            throw MemoryStoreError.sqlite(code: rc, message: msg)
        }
    }

    private func scalarStringLocked(_ sql: String) throws -> String {
        guard let db else { throw MemoryStoreError.sqlite(code: SQLITE_MISUSE, message: "database closed") }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw sqliteErrorLocked(code: rc) }
        defer { sqlite3_finalize(stmt) }
        let stepRC = sqlite3_step(stmt)
        guard stepRC == SQLITE_ROW else { throw sqliteErrorLocked(code: stepRC) }
        return Self.columnText(stmt, 0)
    }

    private func scalarInt32Locked(_ sql: String) throws -> Int32 {
        guard let db else { throw MemoryStoreError.sqlite(code: SQLITE_MISUSE, message: "database closed") }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw sqliteErrorLocked(code: rc) }
        defer { sqlite3_finalize(stmt) }
        let stepRC = sqlite3_step(stmt)
        guard stepRC == SQLITE_ROW else { throw sqliteErrorLocked(code: stepRC) }
        return sqlite3_column_int(stmt, 0)
    }

    private func sqliteErrorLocked(code: Int32) -> MemoryStoreError {
        let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite error \(code)"
        return .sqlite(code: code, message: msg)
    }

    private func isCorruptionCode(_ code: Int32) -> Bool {
        let primary = code & 0xFF
        return primary == SQLITE_CORRUPT || primary == SQLITE_NOTADB
    }

    private func isCorruptionError(_ error: Error) -> Bool {
        guard case .sqlite(let code, _) = error as? MemoryStoreError else { return false }
        return isCorruptionCode(code)
    }

    private static func decodeRecordRow(_ stmt: OpaquePointer) -> MemoryRecord {
        let rawLayer = columnText(stmt, 3)
        let layer = MemoryLayer(rawValue: rawLayer) ?? .surface
        return MemoryRecord(
            id: columnText(stmt, 0),
            text: columnText(stmt, 1),
            textSHA256: columnText(stmt, 2),
            layer: layer,
            pinned: sqlite3_column_int(stmt, 4) != 0,
            kind: columnText(stmt, 5),
            topic: columnText(stmt, 6),
            sourceChat: columnOptionalText(stmt, 7),
            sourceEntryID: columnOptionalText(stmt, 8),
            confidence: sqlite3_column_double(stmt, 9),
            createdAtMs: sqlite3_column_double(stmt, 10),
            updatedAtMs: sqlite3_column_double(stmt, 11),
            usedAtMs: columnOptionalDouble(stmt, 12),
            byBot: columnOptionalText(stmt, 13),
            automatic: sqlite3_column_int(stmt, 14) != 0,
            editedByUser: sqlite3_column_int(stmt, 15) != 0,
            deletedAtMs: columnOptionalDouble(stmt, 16)
        )
    }

    private static func columnText(_ stmt: OpaquePointer?, _ column: Int32) -> String {
        guard let cString = sqlite3_column_text(stmt, column) else { return "" }
        return String(cString: cString)
    }

    private static func columnOptionalText(_ stmt: OpaquePointer?, _ column: Int32) -> String? {
        guard let stmt, sqlite3_column_type(stmt, column) != SQLITE_NULL else { return nil }
        guard let cString = sqlite3_column_text(stmt, column) else { return nil }
        return String(cString: cString)
    }

    private static func columnOptionalDouble(_ stmt: OpaquePointer?, _ column: Int32) -> Double? {
        guard let stmt, sqlite3_column_type(stmt, column) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(stmt, column)
    }

    private static func orderedSecrets(_ secrets: [String]) -> [String] {
        secrets.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
    }

    private static func redact(_ text: String, orderedSecrets: [String]) -> String {
        orderedSecrets.isEmpty ? text : MemorySafety.redactSecrets(text, secrets: orderedSecrets)
    }

    private static func fileIdentity(_ url: URL) -> FileIdentity? {
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        return FileIdentity(
            device: UInt64(truncatingIfNeeded: st.st_dev),
            inode: UInt64(truncatingIfNeeded: st.st_ino)
        )
    }
}
