import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

public struct MemoryRevisionHealth: Codable, Equatable, Sendable {
    public var consecutiveFailures: Int
    public var lastFailureAtMs: Double?
    public var lastFailureMessage: String?
    public var lastSuccessAtMs: Double?
    public var lastRecoveryReason: String?

    public init(
        consecutiveFailures: Int = 0,
        lastFailureAtMs: Double? = nil,
        lastFailureMessage: String? = nil,
        lastSuccessAtMs: Double? = nil,
        lastRecoveryReason: String? = nil
    ) {
        self.consecutiveFailures = max(0, consecutiveFailures)
        self.lastFailureAtMs = lastFailureAtMs
        self.lastFailureMessage = lastFailureMessage
        self.lastSuccessAtMs = lastSuccessAtMs
        self.lastRecoveryReason = lastRecoveryReason
    }
}

public struct MemoryPendingJournal: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case prepared
        case committed
    }

    public var id: String
    public var createdAtMs: Double
    public var phase: Phase
    public var targetCanonicalGeneration: UInt64
    public var preCommitSHA256: String
    public var postCommitSHA256: String
    public var preCommitSnapshotID: String?

    public init(
        id: String = UUID().uuidString.lowercased(),
        createdAtMs: Double = Date().timeIntervalSince1970 * 1000,
        phase: Phase,
        targetCanonicalGeneration: UInt64,
        preCommitSHA256: String,
        postCommitSHA256: String,
        preCommitSnapshotID: String? = nil
    ) {
        self.id = id
        self.createdAtMs = createdAtMs
        self.phase = phase
        self.targetCanonicalGeneration = targetCanonicalGeneration
        self.preCommitSHA256 = preCommitSHA256
        self.postCommitSHA256 = postCommitSHA256
        self.preCommitSnapshotID = preCommitSnapshotID
    }
}

public struct MemoryRevisionSnapshot: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var createdAtMs: Double
    public var reason: String
    public var canonicalSHA256: String
    public var canonicalGeneration: UInt64
    public var itemCount: Int
    public var pinnedCount: Int
    public var surfaceCount: Int
    public var deepCount: Int
    public var book: CanonicalMemoryBook

    public init(
        id: String = UUID().uuidString.lowercased(),
        createdAtMs: Double,
        reason: String,
        canonicalSHA256: String,
        canonicalGeneration: UInt64,
        book: CanonicalMemoryBook
    ) {
        self.id = id
        self.createdAtMs = createdAtMs
        self.reason = reason
        self.canonicalSHA256 = canonicalSHA256
        self.canonicalGeneration = canonicalGeneration
        self.itemCount = book.memories.count
        self.pinnedCount = book.memories.filter { $0.resolvedLayer == .pinned }.count
        self.surfaceCount = book.memories.filter { $0.resolvedLayer == .surface }.count
        self.deepCount = book.memories.filter { $0.resolvedLayer == .deep }.count
        self.book = book
    }
}

public enum MemoryJournalRecoveryOutcome: Equatable, Sendable {
    case none
    case finalizedCommittedJournal(journalID: String)
    case rolledBackToSnapshot(journalID: String, snapshotID: String)
    case discardedStaleJournal(journalID: String)
}

public enum MemoryRevisionStoreError: Error, LocalizedError, Equatable, Sendable {
    case snapshotNotFound(String)
    case corruptSnapshot(String)
    case canonicalReadOnly(String)
    case rollbackUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .snapshotNotFound(let id):
            return "找不到记忆快照 \(id)。"
        case .corruptSnapshot(let detail):
            return "记忆快照已损坏：\(detail)"
        case .canonicalReadOnly(let detail):
            return "记忆主文件暂不可写：\(detail)"
        case .rollbackUnavailable(let detail):
            return "无法回滚未完成的记忆写入：\(detail)"
        }
    }
}

/// Manages crash-safe two-phase commit journaling, SHA-256 optimistic generation guards,
/// rolling `rev-*.json` snapshots, and review health tracking for `Team/memory.json`.
public final class MemoryRevisionStore: @unchecked Sendable {
    public static let maxRollingSnapshots = 10
    public static let journalFileName = "commit.journal"
    public static let rollbackBackupFileName = "commit-prev.bak.journal"
    public static let healthFileName = "health.json"

    public let memoryFileURL: URL
    public let retractedFileURL: URL?
    public let revisionsDirectoryURL: URL
    public let maxSnapshots: Int

    private let lock = NSLock()
    private let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    public init(
        memoryFileURL: URL,
        retractedFileURL: URL? = nil,
        revisionsDirectoryURL: URL,
        maxSnapshots: Int = maxRollingSnapshots
    ) {
        self.memoryFileURL = memoryFileURL
        self.retractedFileURL = retractedFileURL
        self.revisionsDirectoryURL = revisionsDirectoryURL
        self.maxSnapshots = max(1, maxSnapshots)
    }

    public var journalFileURL: URL {
        revisionsDirectoryURL.appendingPathComponent(Self.journalFileName)
    }

    public var rollbackBackupURL: URL {
        revisionsDirectoryURL.appendingPathComponent(Self.rollbackBackupFileName)
    }

    public var healthFileURL: URL {
        revisionsDirectoryURL.appendingPathComponent(Self.healthFileName)
    }

    // MARK: - Crash-Safe Two-Phase Canonical Commit

    @discardableResult
    public func commitWithJournal(
        _ book: CanonicalMemoryBook,
        snapshotReason: String? = nil,
        nowMs: Double = Date().timeIntervalSince1970 * 1000
    ) throws -> (book: CanonicalMemoryBook, digest: String, snapshot: MemoryRevisionSnapshot?) {
        lock.lock()
        defer { lock.unlock() }

        let fm = FileManager.default
        try fm.createDirectory(at: memoryFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: revisionsDirectoryURL, withIntermediateDirectories: true)

        if fm.fileExists(atPath: memoryFileURL.path), !fm.isWritableFile(atPath: memoryFileURL.path) {
            throw MemoryRevisionStoreError.canonicalReadOnly(memoryFileURL.lastPathComponent)
        }

        let currentDiskData = try? Data(contentsOf: memoryFileURL)
        let preCommitSHA256 = currentDiskData.map(Self.sha256Hex) ?? ""
        let diskBook = currentDiskData.flatMap { try? JSONDecoder().decode(CanonicalMemoryBook.self, from: $0) }
        let diskGeneration = diskBook?.generation ?? 0
        let targetGeneration = max(diskGeneration + 1, book.generation + 1)

        var nextBook = book
        nextBook.generation = targetGeneration

        let nextData = try jsonEncoder.encode(nextBook)
        let postCommitSHA256 = Self.sha256Hex(nextData)

        // Persist transient pre-commit fallback backup (excluded from backups via `.journal`)
        if let currentDiskData, !currentDiskData.isEmpty {
            try Self.atomicWrite(data: currentDiskData, to: rollbackBackupURL)
        } else {
            let emptyData = try jsonEncoder.encode(CanonicalMemoryBook())
            try Self.atomicWrite(data: emptyData, to: rollbackBackupURL)
        }

        // Optionally capture a rolling user-visible snapshot before overwriting disk
        var createdSnapshot: MemoryRevisionSnapshot?
        let shouldCreateSnapshot = snapshotReason != nil || (try? listSnapshotFilesLocked())?.isEmpty == true
        if shouldCreateSnapshot, let baselineBook = diskBook ?? (currentDiskData == nil ? nextBook : nil) {
            let reason = snapshotReason ?? "baseline"
            let snapSHA = preCommitSHA256.isEmpty ? postCommitSHA256 : preCommitSHA256
            createdSnapshot = try writeSnapshotLocked(
                book: baselineBook,
                reason: reason,
                canonicalSHA256: snapSHA,
                nowMs: nowMs
            )
        }

        // Phase 1: write `.prepared` journal
        var journal = MemoryPendingJournal(
            id: UUID().uuidString.lowercased(),
            createdAtMs: nowMs,
            phase: .prepared,
            targetCanonicalGeneration: targetGeneration,
            preCommitSHA256: preCommitSHA256,
            postCommitSHA256: postCommitSHA256,
            preCommitSnapshotID: createdSnapshot?.id
        )
        try writeJournalLocked(journal)

        // Write Canonical `memory.json` atomically
        try Self.atomicWrite(data: nextData, to: memoryFileURL)

        // Phase 2: mark `.committed`, then remove transient journal & fallback backup
        journal.phase = .committed
        try writeJournalLocked(journal)

        try? fm.removeItem(at: journalFileURL)
        try? fm.removeItem(at: rollbackBackupURL)

        return (book: nextBook, digest: postCommitSHA256, snapshot: createdSnapshot)
    }

    // MARK: - Cold-Start Recovery (Serialized with Mutex)

    @discardableResult
    public func recoverPendingJournalIfNeeded(
        extraRetractedHashes: Set<String> = [],
        nowMs: Double = Date().timeIntervalSince1970 * 1000
    ) throws -> MemoryJournalRecoveryOutcome {
        lock.lock()
        defer { lock.unlock() }

        let fm = FileManager.default
        guard fm.fileExists(atPath: journalFileURL.path) else {
            return .none
        }

        let journalData = try Data(contentsOf: journalFileURL)
        guard let journal = try? JSONDecoder().decode(MemoryPendingJournal.self, from: journalData) else {
            try? fm.removeItem(at: journalFileURL)
            try? fm.removeItem(at: rollbackBackupURL)
            return .none
        }

        let diskData = try? Data(contentsOf: memoryFileURL)
        let diskSHA = diskData.map(Self.sha256Hex) ?? ""
        let diskBook = diskData.flatMap { try? JSONDecoder().decode(CanonicalMemoryBook.self, from: $0) }
        let diskGeneration = diskBook?.generation ?? 0

        // 1. Stale journal: disk already moved past the journal's target generation — never overwrite newer data.
        if diskGeneration > journal.targetCanonicalGeneration {
            try? fm.removeItem(at: journalFileURL)
            try? fm.removeItem(at: rollbackBackupURL)
            updateHealthRecoveryReasonLocked("discardedStaleJournal:\(journal.id)")
            return .discardedStaleJournal(journalID: journal.id)
        }

        // 2. Canonical on disk already matches `postCommitSHA256` — commit landed safely before crash.
        if !diskSHA.isEmpty && diskSHA == journal.postCommitSHA256 {
            try? fm.removeItem(at: journalFileURL)
            try? fm.removeItem(at: rollbackBackupURL)
            updateHealthRecoveryReasonLocked("finalizedCommittedJournal:\(journal.id)")
            return .finalizedCommittedJournal(journalID: journal.id)
        }

        // 3. Uncommitted / partial crash (`diskSHA != postCommitSHA256`): roll back to pre-commit state
        // while preserving the union of local tombstones and `memory-retracted.json`.
        var combinedRetracted = extraRetractedHashes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
            .reduce(into: Set<String>()) { $0.insert($1) }
        combinedRetracted.formUnion(readRetractedHashesFileLocked())
        if let diskBook {
            combinedRetracted.formUnion(diskBook.suppressedFlushHashes.map { $0.lowercased() })
            combinedRetracted.formUnion(diskBook.tombstones.map { $0.textSHA256.lowercased() })
        }

        let (restoredBookRaw, restoredLabel): (CanonicalMemoryBook, String)
        if let preID = journal.preCommitSnapshotID,
           let snap = try? loadSnapshotLocked(id: preID) {
            restoredBookRaw = snap.book
            restoredLabel = snap.id
        } else if fm.fileExists(atPath: rollbackBackupURL.path),
                  let backupData = try? Data(contentsOf: rollbackBackupURL),
                  let decoded = try? JSONDecoder().decode(CanonicalMemoryBook.self, from: backupData) {
            restoredBookRaw = decoded
            restoredLabel = Self.rollbackBackupFileName
        } else {
            throw MemoryRevisionStoreError.rollbackUnavailable("缺少可回滚的提交前快照")
        }

        let sanitized = Self.applyTombstoneUnion(
            to: restoredBookRaw,
            retractedHashes: combinedRetracted,
            minimumGeneration: max(diskGeneration, restoredBookRaw.generation),
            nowMs: nowMs
        )
        let sanitizedData = try jsonEncoder.encode(sanitized)
        try Self.atomicWrite(data: sanitizedData, to: memoryFileURL)

        try? fm.removeItem(at: journalFileURL)
        try? fm.removeItem(at: rollbackBackupURL)
        updateHealthRecoveryReasonLocked("rolledBack:\(journal.id)->\(restoredLabel)")
        return .rolledBackToSnapshot(journalID: journal.id, snapshotID: restoredLabel)
    }

    // MARK: - Rolling Snapshots & Reversible Restore

    public func listSnapshots() -> [MemoryRevisionSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return loadAllSnapshotsLocked()
    }

    @discardableResult
    public func saveManualSnapshot(
        _ book: CanonicalMemoryBook,
        reason: String = "manual",
        nowMs: Double = Date().timeIntervalSince1970 * 1000
    ) throws -> MemoryRevisionSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        try fm.createDirectory(at: revisionsDirectoryURL, withIntermediateDirectories: true)
        let data = try jsonEncoder.encode(book)
        return try writeSnapshotLocked(
            book: book,
            reason: reason,
            canonicalSHA256: Self.sha256Hex(data),
            nowMs: nowMs
        )
    }

    @discardableResult
    public func restoreSnapshot(
        id: String,
        extraRetractedHashes: Set<String> = [],
        nowMs: Double = Date().timeIntervalSince1970 * 1000
    ) throws -> (book: CanonicalMemoryBook, preRestoreSnapshot: MemoryRevisionSnapshot?, digest: String) {
        lock.lock()
        defer { lock.unlock() }

        let target = try loadSnapshotLocked(id: id)
        let fm = FileManager.default
        try fm.createDirectory(at: memoryFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: revisionsDirectoryURL, withIntermediateDirectories: true)

        if fm.fileExists(atPath: memoryFileURL.path), !fm.isWritableFile(atPath: memoryFileURL.path) {
            throw MemoryRevisionStoreError.canonicalReadOnly(memoryFileURL.lastPathComponent)
        }

        // Read live canonical first so user can undo this restore and tombstones are preserved.
        let liveData = try? Data(contentsOf: memoryFileURL)
        let liveBook = liveData.flatMap { try? JSONDecoder().decode(CanonicalMemoryBook.self, from: $0) }
        var preRestore: MemoryRevisionSnapshot?
        if let liveBook, let liveData {
            preRestore = try writeSnapshotLocked(
                book: liveBook,
                reason: "pre_restore",
                canonicalSHA256: Self.sha256Hex(liveData),
                nowMs: nowMs
            )
        }

        var combinedRetracted = Set(
            extraRetractedHashes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
        )
        combinedRetracted.formUnion(readRetractedHashesFileLocked())
        if let liveBook {
            combinedRetracted.formUnion(liveBook.suppressedFlushHashes.map { $0.lowercased() })
            combinedRetracted.formUnion(liveBook.tombstones.map { $0.textSHA256.lowercased() })
        }

        let nextGeneration = max((liveBook?.generation ?? 0) + 1, target.canonicalGeneration + 1)
        let restoredBook = Self.applyTombstoneUnion(
            to: target.book,
            retractedHashes: combinedRetracted,
            minimumGeneration: nextGeneration,
            nowMs: nowMs
        )
        let encoded = try jsonEncoder.encode(restoredBook)
        let digest = Self.sha256Hex(encoded)
        try Self.atomicWrite(data: encoded, to: memoryFileURL)
        return (book: restoredBook, preRestoreSnapshot: preRestore, digest: digest)
    }

    // MARK: - Review Health Counter

    public func readHealth() -> MemoryRevisionHealth {
        lock.lock()
        defer { lock.unlock() }
        return readHealthLocked()
    }

    @discardableResult
    public func recordReviewFailure(
        message: String,
        atMs: Double = Date().timeIntervalSince1970 * 1000
    ) -> MemoryRevisionHealth {
        lock.lock()
        defer { lock.unlock() }
        var health = readHealthLocked()
        health.consecutiveFailures += 1
        health.lastFailureAtMs = atMs
        health.lastFailureMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        try? writeHealthLocked(health)
        return health
    }

    @discardableResult
    public func recordReviewSuccess(
        atMs: Double = Date().timeIntervalSince1970 * 1000
    ) -> MemoryRevisionHealth {
        lock.lock()
        defer { lock.unlock() }
        var health = readHealthLocked()
        health.consecutiveFailures = 0
        health.lastFailureMessage = nil
        health.lastSuccessAtMs = atMs
        try? writeHealthLocked(health)
        return health
    }

    // MARK: - Internal Helpers

    private func writeSnapshotLocked(
        book: CanonicalMemoryBook,
        reason: String,
        canonicalSHA256: String,
        nowMs: Double
    ) throws -> MemoryRevisionSnapshot {
        let id = UUID().uuidString.lowercased()
        let snapshot = MemoryRevisionSnapshot(
            id: id,
            createdAtMs: nowMs,
            reason: reason,
            canonicalSHA256: canonicalSHA256,
            canonicalGeneration: book.generation,
            book: book
        )
        let stamp = String(format: "%015.0f", max(0, nowMs))
        let fileURL = revisionsDirectoryURL.appendingPathComponent("rev-\(stamp)-\(id).json")
        let data = try jsonEncoder.encode(snapshot)
        try Self.atomicWrite(data: data, to: fileURL)
        pruneExcessSnapshotsLocked()
        return snapshot
    }

    private func listSnapshotFilesLocked() throws -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: revisionsDirectoryURL.path) else { return [] }
        let items = try fm.contentsOfDirectory(at: revisionsDirectoryURL, includingPropertiesForKeys: nil)
        return items
            .filter { url in
                let name = url.lastPathComponent
                return name.hasPrefix("rev-") && name.hasSuffix(".json")
            }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func loadAllSnapshotsLocked() -> [MemoryRevisionSnapshot] {
        guard let urls = try? listSnapshotFilesLocked() else { return [] }
        return urls.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(MemoryRevisionSnapshot.self, from: data)
        }.sorted { lhs, rhs in
            if lhs.createdAtMs != rhs.createdAtMs { return lhs.createdAtMs > rhs.createdAtMs }
            return lhs.id > rhs.id
        }
    }

    private func loadSnapshotLocked(id: String) throws -> MemoryRevisionSnapshot {
        let all = loadAllSnapshotsLocked()
        guard let match = all.first(where: { $0.id == id }) else {
            throw MemoryRevisionStoreError.snapshotNotFound(id)
        }
        return match
    }

    private func pruneExcessSnapshotsLocked() {
        guard let urls = try? listSnapshotFilesLocked(), urls.count > maxSnapshots else { return }
        let loaded = urls.compactMap { url -> (url: URL, createdAtMs: Double, id: String)? in
            guard let data = try? Data(contentsOf: url),
                  let snap = try? JSONDecoder().decode(MemoryRevisionSnapshot.self, from: data) else {
                return nil
            }
            return (url, snap.createdAtMs, snap.id)
        }.sorted { lhs, rhs in
            if lhs.createdAtMs != rhs.createdAtMs { return lhs.createdAtMs > rhs.createdAtMs }
            return lhs.id > rhs.id
        }

        guard loaded.count > maxSnapshots else { return }
        let fm = FileManager.default
        for entry in loaded.dropFirst(maxSnapshots) {
            try? fm.removeItem(at: entry.url)
        }
    }

    private func writeJournalLocked(_ journal: MemoryPendingJournal) throws {
        let data = try jsonEncoder.encode(journal)
        try Self.atomicWrite(data: data, to: journalFileURL)
    }

    private func readHealthLocked() -> MemoryRevisionHealth {
        guard let data = try? Data(contentsOf: healthFileURL),
              let health = try? JSONDecoder().decode(MemoryRevisionHealth.self, from: data) else {
            return MemoryRevisionHealth()
        }
        return health
    }

    private func writeHealthLocked(_ health: MemoryRevisionHealth) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: revisionsDirectoryURL, withIntermediateDirectories: true)
        let data = try jsonEncoder.encode(health)
        try Self.atomicWrite(data: data, to: healthFileURL)
    }

    private func updateHealthRecoveryReasonLocked(_ reason: String) {
        var health = readHealthLocked()
        health.lastRecoveryReason = reason
        try? writeHealthLocked(health)
    }

    private func readRetractedHashesFileLocked() -> Set<String> {
        guard let url = retractedFileURL,
              let data = try? Data(contentsOf: url),
              let hashes = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(hashes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })
    }

    /// Merges live tombstones & retraction hashes into a historical or rolled-back `CanonicalMemoryBook`
    /// so no previously deleted fact can ever resurrect across rollback or snapshot restoration.
    public static func applyTombstoneUnion(
        to book: CanonicalMemoryBook,
        retractedHashes: Set<String>,
        minimumGeneration: UInt64,
        nowMs: Double
    ) -> CanonicalMemoryBook {
        var combinedSuppressed = Set(
            book.suppressedFlushHashes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
        )
        combinedSuppressed.formUnion(
            retractedHashes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
        )

        var tombstoneByHash: [String: MemoryTombstone] = [:]
        for ts in book.tombstones {
            let key = ts.textSHA256.lowercased()
            guard !key.isEmpty else { continue }
            tombstoneByHash[key] = ts
            combinedSuppressed.insert(key)
        }
        for hash in combinedSuppressed where tombstoneByHash[hash] == nil {
            tombstoneByHash[hash] = MemoryTombstone(
                textSHA256: hash,
                memoryID: nil,
                deletedAtMs: nowMs,
                reason: "tombstone_union"
            )
        }

        func isSuppressed(_ item: CanonicalMemoryItem) -> Bool {
            let hash = MemorySafety.retractionHash(item.text)
            return !hash.isEmpty && combinedSuppressed.contains(hash)
        }

        var next = book
        next.memories = book.memories.filter { !isSuppressed($0) }
        next.archived = book.archived.filter { !isSuppressed($0) }
        next.suppressedFlushHashes = combinedSuppressed.sorted()
        next.tombstones = tombstoneByHash.values.sorted { lhs, rhs in
            if lhs.deletedAtMs != rhs.deletedAtMs { return lhs.deletedAtMs < rhs.deletedAtMs }
            return lhs.textSHA256 < rhs.textSHA256
        }
        next.generation = max(minimumGeneration, book.generation)
        return next
    }

    public static func sha256Hex(_ data: Data) -> String {
        #if canImport(CryptoKit)
        let digest = CryptoKit.SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
        #else
        return MemorySafety.retractionHash(String(decoding: data, as: UTF8.self))
        #endif
    }

    private static func atomicWrite(data: Data, to url: URL) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
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
            throw error
        }
    }
}
