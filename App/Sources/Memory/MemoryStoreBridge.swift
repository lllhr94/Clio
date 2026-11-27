import Combine
import Craft
import CryptoKit
import Foundation
import UIKit

struct MemoryImportBatchEntry: Sendable {
    let memory: Memory
    let layer: MemoryLayer
    let kind: String
    let topic: String
}

enum MemoryCommitMutation: Sendable {
    case none
    case remember(memory: Memory, explicitUserAction: Bool, nowMs: Double)
    case recall(ids: Set<String>, nowMs: Double)
    case setDeep(id: String, deep: Bool, nowMs: Double)
    case pin(id: String, pinned: Bool, nowMs: Double)
    case layerAndMetadata(
        id: String,
        layer: MemoryLayer,
        kind: String?,
        topic: String?,
        confidence: Double?,
        text: String?,
        editedByUser: Bool,
        fallbackMemory: Memory?,
        nowMs: Double
    )
    case importBatch(items: [MemoryImportBatchEntry], nowMs: Double)
    case restore(id: String, memory: Memory, layer: MemoryLayer, nowMs: Double)
    case softDelete(items: [(id: String, text: String?)], reason: String, nowMs: Double)
    case edit(id: String, text: String, editedByUser: Bool, nowMs: Double)
}

/// Off-MainActor coordinator for authoritative `ClioMemory/clio-memory.db` (`MemoryStore`),
/// canonical `Team/memory.json` bidirectional synchronization, Vault secret redaction,
/// and private `ClioMemory/Mirrors/` Markdown mirrors.
final class MemoryStoreBridge: @unchecked Sendable {
    struct BootstrapResult: Sendable {
        let book: MemoryBook
        let suppressedHashes: Set<String>
        let pinnedIDs: Set<String>
    }

    private enum DiskBookLoad {
        case missing
        case unreadable
        case corrupt(Data)
        case decoded(CanonicalMemoryBook, digest: String)
    }

    static let shared = MemoryStoreBridge(experienceBridge: .shared)

    private static let pendingRestoreRebuildDefaultsKey = "clio.memoryStore.pendingRestoreRebuild"
    private static let retractedFileName = "memory-retracted.json"
    private static let memoryFileName = "memory.json"

    nonisolated static var defaultDatabaseURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClioMemory", isDirectory: true)
            .appendingPathComponent("clio-memory.db")
    }

    private let store: MemoryStore
    let revisionStore: MemoryRevisionStore
    private let teamRoot: URL
    private let mirrorRoot: URL
    private let commitQueue = DispatchQueue(label: "clio.memory-store.commit", qos: .userInitiated)
    private let queue = DispatchQueue(label: "clio.memory-store", qos: .userInitiated)

    private let stateLock = NSLock()
    private var pinnedIDs: Set<String> = []
    private var archivedRecords: [MemoryRecord] = []
    private var tombstoneShadow: [String: MemoryTombstone] = [:]
    private var recordShadowByID: [String: MemoryRecord] = [:]
    private var lastSyncedMemories: [Memory] = []
    private var lastSyncedBookDigest: String = ""
    private var syncSequence: UInt64 = 0
    private var canonicalStateEpoch: UInt64 = 0
    private var botSummaries: [MemoryMirrorBot] = []
    private var canonicalLoadFailed: Bool = false
    private let experienceBridge: ExperienceStoreBridge?
    #if DEBUG
    var beforeRestoreCommitForTesting: (@Sendable () -> Void)?
    var onCommitAsyncEnqueuedForTesting: (@Sendable () -> Void)?
    #endif

    @MainActor private var observerCancellables: Set<AnyCancellable> = []
    @MainActor private weak var observedTeam: TeamModel?

    private var coordinatorExperienceBridge: ExperienceStoreBridge? {
        experienceBridge ?? (self === MemoryStoreBridge.shared ? .shared : nil)
    }

    init(
        databaseURL: URL = MemoryStoreBridge.defaultDatabaseURL,
        teamRoot: URL = Disk.root,
        mirrorRoot: URL = MemoryMarkdownMirror.defaultRoot,
        experienceBridge: ExperienceStoreBridge? = nil
    ) {
        self.store = MemoryStore(databaseURL: databaseURL)
        self.teamRoot = teamRoot
        self.mirrorRoot = mirrorRoot
        self.experienceBridge = experienceBridge
        self.revisionStore = MemoryRevisionStore(
            memoryFileURL: teamRoot.appendingPathComponent(Self.memoryFileName),
            retractedFileURL: teamRoot.appendingPathComponent(Self.retractedFileName),
            revisionsDirectoryURL: teamRoot.appendingPathComponent("memory-revisions", isDirectory: true)
        )
        experienceBridge?.setCoordinatorHooks(
            recoveryBlockedCheck: { [weak self] in
                self?.isSQLiteRecoveryBlockedForCoordinator ?? false
            },
            tombstoneHashesProvider: { [weak self] in
                self?.tombstoneHashesSnapshot() ?? []
            }
        )
    }

    // MARK: - Synchronous Shadow Reads (Thread-Safe)

    var isCanonicalReadOnly: Bool {
        stateLock.withLock { canonicalLoadFailed }
    }

    var isSQLiteRecoveryBlockedForCoordinator: Bool {
        isSQLiteRecoveryBlocked
    }

    private var isSQLiteRecoveryBlocked: Bool {
        Disk.frozen || stateLock.withLock { canonicalLoadFailed } || revisionStore.hasPendingProjectionRebuild
    }

    func pinnedIDsSnapshot() -> Set<String> {
        stateLock.lock()
        defer { stateLock.unlock() }
        return pinnedIDs
    }

    func tombstoneHashesSnapshot() -> Set<String> {
        var combined = stateLock.withLock { Set(tombstoneShadow.keys) }
        let retractedURL = teamRoot.appendingPathComponent(Self.retractedFileName)
        combined.formUnion(loadRetractedHashes(at: retractedURL))
        return combined
    }

    func withBackupBarrier<T>(_ work: () throws -> T) rethrows -> T {
        if let expBridge = coordinatorExperienceBridge {
            return try commitQueue.sync {
                try queue.sync {
                    try expBridge.queue.sync {
                        try work()
                    }
                }
            }
        }
        return try commitQueue.sync {
            try queue.sync {
                try work()
            }
        }
    }

    func recordsSnapshot(layer: MemoryLayer? = nil) -> [MemoryRecord] {
        stateLock.lock()
        let active = Array(recordShadowByID.values) + archivedRecords
        stateLock.unlock()
        let filtered = layer.map { target in active.filter { $0.layer == target } } ?? active
        return filtered.sorted { lhs, rhs in
            if lhs.createdAtMs != rhs.createdAtMs { return lhs.createdAtMs < rhs.createdAtMs }
            return lhs.id < rhs.id
        }
    }

    func activeFactsSnapshot() -> [MemorySafety.Fact] {
        stateLock.lock()
        let active = Array(recordShadowByID.values)
        stateLock.unlock()
        return active.compactMap(\.safetyFact).sorted { lhs, rhs in
            if lhs.at != rhs.at { return lhs.at < rhs.at }
            return lhs.id < rhs.id
        }
    }

    func isSuppressedInShadow(text: String) -> Bool {
        let hash = MemorySafety.retractionHash(text)
        guard !hash.isEmpty else { return false }
        stateLock.lock()
        defer { stateLock.unlock() }
        return tombstoneShadow[hash] != nil
    }

    // MARK: - Startup Bootstrap (Runs off MainActor in `InitialData.read()`)

    func bootstrapOnLaunch(bots: [BotInfo] = [], mainBotId: String? = nil) -> BootstrapResult {
        let initialBots = Self.makeBotSummaries(bots: bots, mainBotId: mainBotId)
        stateLock.withLock {
            if !initialBots.isEmpty { botSummaries = initialBots }
        }
        return commitQueue.sync {
            queue.sync {
                bootstrapOnLaunchLocked()
            }
        }
    }

    private func bootstrapOnLaunchLocked() -> BootstrapResult {
        let memoryURL = teamRoot.appendingPathComponent(Self.memoryFileName)
        let retractedURL = teamRoot.appendingPathComponent(Self.retractedFileName)
        let secrets = Self.orderedSecrets(Vault.allStrings())

        let expBridge = coordinatorExperienceBridge
        let retractedHashes = loadRetractedHashes(at: retractedURL)
        let hadDefaultsRebuildFlag = (self === MemoryStoreBridge.shared)
            && UserDefaults.standard.bool(forKey: Self.pendingRestoreRebuildDefaultsKey)
        var pendingRebuild = hadDefaultsRebuildFlag
        if revisionStore.hasPendingProjectionRebuild {
            pendingRebuild = true
        }
        var journalRecoveryFailed = false
        if !Disk.frozen {
            do {
                let recovery = try revisionStore.recoverPendingJournalIfNeeded(
                    extraRetractedHashes: retractedHashes,
                    nowMs: Now.ms
                )
                if case .rolledBackToSnapshot(_, _) = recovery {
                    pendingRebuild = true
                }
            } catch {
                journalRecoveryFailed = true
            }
        }
        if revisionStore.hasPendingProjectionRebuild {
            pendingRebuild = true
        }

        let diskLoad = loadCanonicalBookFromDisk(at: memoryURL)

        let incomingBook: CanonicalMemoryBook?
        let initialDigest: String?
        let jsonNeedsRewrite: Bool
        switch diskLoad {
        case .missing:
            stateLock.withLock { canonicalLoadFailed = journalRecoveryFailed }
            incomingBook = nil
            initialDigest = nil
            jsonNeedsRewrite = false
        case .unreadable:
            stateLock.withLock { canonicalLoadFailed = true }
            incomingBook = nil
            initialDigest = nil
            jsonNeedsRewrite = false
        case .corrupt(let rawData):
            if pendingRebuild || journalRecoveryFailed {
                // Corrupt `memory.json` while a projection rebuild/journal recovery is pending must block
                // destructive SQLite reset & marker deletion so old SQLite data is preserved read-only.
                stateLock.withLock { canonicalLoadFailed = true }
                incomingBook = nil
                initialDigest = nil
                jsonNeedsRewrite = false
            } else {
                stateLock.withLock { canonicalLoadFailed = false }
                if !Disk.frozen {
                    let aside = memoryURL.deletingLastPathComponent()
                        .appendingPathComponent("memory.broken-\(Int(Date().timeIntervalSince1970)).json")
                    try? rawData.write(to: aside, options: .atomic)
                }
                incomingBook = nil
                initialDigest = nil
                jsonNeedsRewrite = true
            }
        case .decoded(let decoded, let digest):
            stateLock.withLock { canonicalLoadFailed = journalRecoveryFailed }
            incomingBook = decoded
            initialDigest = digest
            jsonNeedsRewrite = false
        }

        let isCanonicalReadable = !stateLock.withLock { canonicalLoadFailed }
        if journalRecoveryFailed || !isCanonicalReadable {
            let fallbackCanonical = Self.redactCanonicalBook(
                incomingBook ?? CanonicalMemoryBook(),
                orderedSecrets: secrets
            )
            let hydrated = hydrateShadowsFromCanonical(
                fallbackCanonical,
                retractedHashes: retractedHashes,
                secrets: secrets
            )
            let currentBots = stateLock.withLock { botSummaries }
            if !Disk.frozen {
                MemoryMarkdownMirror.sync(
                    records: hydrated.liveRecords,
                    bots: currentBots,
                    secrets: secrets,
                    mirrorsRoot: mirrorRoot
                )
            }
            return hydrated.result
        }
        let shouldResetProjection = !Disk.frozen && pendingRebuild

        do {
            var bookToReconcile = incomingBook ?? CanonicalMemoryBook()
            var combinedSuppressed = Set(bookToReconcile.suppressedFlushHashes)
            combinedSuppressed.formUnion(retractedHashes)
            bookToReconcile.suppressedFlushHashes = combinedSuppressed.sorted()

            let canWriteJSON = !Disk.frozen && isCanonicalReadable

            let executeReconcile: () throws -> (reconciled: CanonicalMemoryBook, liveRecords: [MemoryRecord]) = {
                if shouldResetProjection {
                    try self.store.destroyFilesThrowing()
                    MemoryMarkdownMirror.clearMirrors(mirrorsRoot: self.mirrorRoot)
                }
                _ = try self.store.openOrRecover()

                var reconciled = try self.store.reconcile(
                    book: bookToReconcile,
                    secrets: secrets,
                    nowMs: Now.ms,
                    jsonDigest: initialDigest
                )
                try? self.store.checkpoint()

                var liveRecords = try self.store.list(layer: nil, includeDeleted: false, secrets: secrets)
                if canWriteJSON && (jsonNeedsRewrite || (incomingBook != nil && reconciled != bookToReconcile) || (incomingBook == nil && !liveRecords.isEmpty)) {
                    let newDigest = try self.writeCanonicalBookToDisk(reconciled, at: memoryURL)
                    reconciled = try self.store.reconcile(book: reconciled, secrets: secrets, nowMs: Now.ms, jsonDigest: newDigest)
                    try? self.store.checkpoint()
                    liveRecords = try self.store.list(layer: nil, includeDeleted: false, secrets: secrets)
                }
                return (reconciled: reconciled, liveRecords: liveRecords)
            }

            let outcome: (reconciled: CanonicalMemoryBook, liveRecords: [MemoryRecord])
            if let expBridge, shouldResetProjection {
                outcome = try expBridge.performDatabaseResetSync {
                    try executeReconcile()
                }
            } else {
                outcome = try executeReconcile()
            }
            let reconciled = outcome.reconciled
            let liveRecords = outcome.liveRecords

            if canWriteJSON {
                try syncRetractedHashesFileThrowing(
                    Set(reconciled.suppressedFlushHashes),
                    existing: retractedHashes,
                    at: retractedURL
                )
            }

            let appBook = Self.toAppMemoryBook(reconciled)
            let stampedEpoch = updateShadowState(
                liveRecords: liveRecords,
                tombstones: reconciled.tombstones,
                appBook: appBook
            )
            var stampedBook = appBook
            stampedBook.storeEpoch = stampedEpoch

            let currentBots = stateLock.withLock { botSummaries }
            if !Disk.frozen {
                MemoryMarkdownMirror.sync(
                    records: liveRecords,
                    bots: currentBots,
                    secrets: secrets,
                    mirrorsRoot: mirrorRoot
                )
            }
            if !Disk.frozen && !journalRecoveryFailed && isCanonicalReadable {
                if hadDefaultsRebuildFlag {
                    UserDefaults.standard.removeObject(forKey: Self.pendingRestoreRebuildDefaultsKey)
                }
                revisionStore.clearPendingProjectionRebuild()
            }

            return BootstrapResult(
                book: stampedBook,
                suppressedHashes: Set(reconciled.suppressedFlushHashes),
                pinnedIDs: Set(liveRecords.filter { $0.layer == .pinned }.map(\.id))
            )
        } catch {
            // Preserve FULL canonical JSON state (pins, archives, tombstones, metadata) if SQLite failed transiently.
            let fallbackCanonical = Self.redactCanonicalBook(
                incomingBook ?? CanonicalMemoryBook(),
                orderedSecrets: secrets
            )
            let hydrated = hydrateShadowsFromCanonical(
                fallbackCanonical,
                retractedHashes: retractedHashes,
                secrets: secrets
            )
            let currentBots = stateLock.withLock { botSummaries }
            if !Disk.frozen {
                MemoryMarkdownMirror.sync(
                    records: hydrated.liveRecords,
                    bots: currentBots,
                    secrets: secrets,
                    mirrorsRoot: mirrorRoot
                )
            }
            return hydrated.result
        }
    }

    // MARK: - MainActor Attachment & Restore/Background Observers

    @MainActor
    func attach(to team: TeamModel, pinnedIDs: Set<String>, bots: [BotInfo], mainBotId: String?) {
        let summaries = Self.makeBotSummaries(bots: bots, mainBotId: mainBotId)
        stateLock.withLock {
            self.pinnedIDs = pinnedIDs
            self.botSummaries = summaries
            self.lastSyncedMemories = team.memories
            self.lastSyncedBookDigest = Self.bookDigest(team.memoryBook)
        }

        if observedTeam !== team {
            observerCancellables.removeAll()
            observedTeam = team

            team.$memories
                .dropFirst()
                .sink { [weak self, weak team] _ in
                    Task { @MainActor [weak self, weak team] in
                        guard let self, let team else { return }
                        self.handlePossibleExternalMemoryMutation(on: team)
                    }
                }
                .store(in: &observerCancellables)

            team.$bots
                .dropFirst()
                .sink { [weak self, weak team] updatedBots in
                    Task { @MainActor [weak self, weak team] in
                        guard let self, let team else { return }
                        self.updateBotSummaries(bots: updatedBots, mainBotId: team.mainBotId)
                    }
                }
                .store(in: &observerCancellables)

            team.$queueDispatchSuspended
                .dropFirst()
                .sink { [weak self] suspended in
                    guard let self, suspended, Disk.frozen else { return }
                    self.prepareForBackupRestore()
                }
                .store(in: &observerCancellables)

            NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
                .sink { [weak self] _ in
                    self?.checkpointAsync()
                }
                .store(in: &observerCancellables)
        }

        refreshMarkdownMirrorAsync(bots: summaries)
    }

    @MainActor
    func updateBotSummaries(bots: [BotInfo], mainBotId: String?) {
        let summaries = Self.makeBotSummaries(bots: bots, mainBotId: mainBotId)
        let changed: Bool = stateLock.withLock {
            let diff = botSummaries != summaries
            botSummaries = summaries
            return diff
        }
        if changed {
            refreshMarkdownMirrorAsync(bots: summaries)
        }
    }

    /// Marks `ClioMemory` for clean unconditional rebuild on next launch and closes/quarantines
    /// the current SQLite DB + sidecars + mirrors immediately after `Backup.restore` succeeds.
    func prepareForBackupRestore() {
        if self === MemoryStoreBridge.shared {
            UserDefaults.standard.set(true, forKey: Self.pendingRestoreRebuildDefaultsKey)
        }
        let expBridge = coordinatorExperienceBridge
        commitQueue.async { [weak self] in
            guard let self else { return }
            self.queue.sync {
                let resetWork: () throws -> Void = {
                    try self.store.destroyFilesThrowing()
                    MemoryMarkdownMirror.clearMirrors(mirrorsRoot: self.mirrorRoot)
                }
                do {
                    if let expBridge {
                        try expBridge.performWithoutReopeningSync(resetWork)
                    } else {
                        try resetWork()
                    }
                } catch {
                    Diag.note("备份恢复清理旧索引失败：\(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Read-Only Snapshot Helpers (Never mutate shadow or SQLite)

    func hasRecordSnapshot(id: String) -> Bool {
        stateLock.withLock {
            recordShadowByID[id] != nil || archivedRecords.contains(where: { $0.id == id })
        }
    }

    func restorableMemorySnapshot(id: String) -> Memory? {
        let archivedCopy: MemoryRecord? = stateLock.withLock {
            archivedRecords.first(where: { $0.id == id })
        }
        if let archivedCopy {
            let secrets = Self.orderedSecrets(Vault.allStrings())
            var restored = Self.toAppMemory(archivedCopy)
            restored.text = Self.redact(restored.text, orderedSecrets: secrets)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return restored.text.isEmpty ? nil : restored
        }
        guard !isSQLiteRecoveryBlocked else { return nil }
        let dbRecord: MemoryRecord? = queue.sync {
            guard !isSQLiteRecoveryBlocked else { return nil }
            return try? store.record(id: id, includeDeleted: true)
        }
        guard let dbRecord, dbRecord.layer == .archived || dbRecord.deletedAtMs != nil else {
            return nil
        }
        let secrets = Self.orderedSecrets(Vault.allStrings())
        var restored = Self.toAppMemory(dbRecord)
        restored.text = Self.redact(restored.text, orderedSecrets: secrets)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return restored.text.isEmpty ? nil : restored
    }

    /// Returns a live `.archived` memory (`deletedAtMs == nil`) without ever resurrecting tombstoned rows.
    func archivedMemorySnapshot(id: String) -> Memory? {
        let archivedCopy: MemoryRecord? = stateLock.withLock {
            archivedRecords.first(where: { $0.id == id && $0.deletedAtMs == nil })
        }
        if let archivedCopy {
            let secrets = Self.orderedSecrets(Vault.allStrings())
            var snapshot = Self.toAppMemory(archivedCopy)
            snapshot.text = Self.redact(snapshot.text, orderedSecrets: secrets)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return snapshot.text.isEmpty ? nil : snapshot
        }
        guard !isSQLiteRecoveryBlocked else { return nil }
        let dbRecord: MemoryRecord? = queue.sync {
            guard !isSQLiteRecoveryBlocked else { return nil }
            return try? store.record(id: id, includeDeleted: false)
        }
        guard let dbRecord, dbRecord.layer == .archived, dbRecord.deletedAtMs == nil else {
            return nil
        }
        let secrets = Self.orderedSecrets(Vault.allStrings())
        var snapshot = Self.toAppMemory(dbRecord)
        snapshot.text = Self.redact(snapshot.text, orderedSecrets: secrets)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return snapshot.text.isEmpty ? nil : snapshot
    }

    // MARK: - Unified Canonical Book Commit (Throws on disk failure before mutating caller or SQLite state)

    private struct CommitPromptPayload: Sendable {
        let sanitizedAppBook: MemoryBook
        let retractItems: [(id: String, textForInFlightGuard: String?)]
        let clearRetractions: [(id: String?, text: String)]
        let shouldInvalidatePromptCache: Bool
    }

    private func performSerializedCommitOnCommitQueue(
        _ book: MemoryBook,
        mutation: MemoryCommitMutation,
        snapshotReason: String? = nil,
        suppressedHashes: Set<String>,
        bots: [BotInfo],
        mainBotId: String?,
        secrets: [String],
        expectedEpoch: UInt64? = nil
    ) throws -> CommitPromptPayload {
        guard !Disk.frozen else {
            throw TeamError(message: "刚恢复了备份，重新打开 Clio 后才能保存。")
        }
        let (loadBlocked, currentEpoch) = stateLock.withLock {
            (canonicalLoadFailed, canonicalStateEpoch)
        }
        guard !loadBlocked else {
            throw TeamError(message: "记忆文件暂不可读，已跳过覆盖写入以防丢失原有记忆。")
        }
        guard !revisionStore.hasPendingProjectionRebuild else {
            throw TeamError(message: "记忆档案或检索投影正在等待修复，已跳过覆盖写入以防覆盖最新恢复内容。")
        }
        if let expectedEpoch, currentEpoch != expectedEpoch {
            throw TeamError(message: "记忆档案版本已更新，已跳过过期覆盖写入。")
        }

        let orderedSecrets = Self.orderedSecrets(secrets)
        let summaries = Self.makeBotSummaries(bots: bots, mainBotId: mainBotId)
        let nowMs = mutationNowMs(mutation) ?? Now.ms

        let prepared = buildCommitSnapshot(
            book: book,
            mutation: mutation,
            suppressedHashes: suppressedHashes,
            botSummaries: summaries,
            secrets: orderedSecrets,
            nowMs: nowMs
        )

        let effectiveReason: String?
        if let snapshotReason {
            effectiveReason = snapshotReason
        } else if case .importBatch = mutation {
            effectiveReason = "import"
        } else {
            effectiveReason = nil
        }

        let committedResult = try revisionStore.commitWithJournal(
            prepared.canonical,
            snapshotReason: effectiveReason,
            nowMs: nowMs
        )
        let writtenCanonical = committedResult.book
        let writtenDigest = committedResult.digest

        let retractedURL = teamRoot.appendingPathComponent(Self.retractedFileName)
        let existingRetracted = loadRetractedHashes(at: retractedURL)
        syncRetractedHashesFileIfNeeded(
            Set(writtenCanonical.suppressedFlushHashes),
            existing: existingRetracted,
            at: retractedURL
        )

        applyCommittedShadow(prepared.shadowUpdate)

        queue.async { [weak self] in
            guard let self, !Disk.frozen else { return }
            self.applyBackgroundPersist(
                canonical: writtenCanonical,
                liveRecords: prepared.liveRecords,
                bots: summaries,
                secrets: orderedSecrets,
                jsonDigest: writtenDigest,
                sequence: prepared.shadowUpdate.seq,
                sqliteActions: prepared.sqliteActions,
                nowMs: nowMs
            )
        }

        var stampedAppBook = prepared.sanitizedAppBook
        stampedAppBook.storeEpoch = currentEpoch
        return CommitPromptPayload(
            sanitizedAppBook: stampedAppBook,
            retractItems: prepared.retractItems,
            clearRetractions: prepared.clearRetractions,
            shouldInvalidatePromptCache: prepared.shouldInvalidatePromptCache
        )
    }

    @MainActor
    private func applyPromptState(_ payload: CommitPromptPayload, to promptState: MemorySafety.PromptState?) {
        guard let promptState else { return }
        for item in payload.retractItems {
            promptState.retract(id: item.id, textForInFlightGuard: item.textForInFlightGuard)
        }
        for clear in payload.clearRetractions {
            promptState.clearRetraction(id: clear.id, text: clear.text)
        }
        if payload.shouldInvalidatePromptCache && payload.retractItems.isEmpty && payload.clearRetractions.isEmpty {
            promptState.invalidate()
        }
    }

    @discardableResult
    @MainActor
    func commitAppBook(
        _ book: MemoryBook,
        mutation: MemoryCommitMutation = .none,
        snapshotReason: String? = nil,
        suppressedHashes: Set<String>,
        promptState: MemorySafety.PromptState? = nil,
        bots: [BotInfo],
        mainBotId: String?,
        secrets: [String],
        expectedEpoch: UInt64? = nil
    ) throws -> (book: MemoryBook, editedTexts: [String]) {
        let capturedEpoch = expectedEpoch ?? book.storeEpoch ?? stateLock.withLock { canonicalStateEpoch }
        let payload = try commitQueue.sync {
            try performSerializedCommitOnCommitQueue(
                book,
                mutation: mutation,
                snapshotReason: snapshotReason,
                suppressedHashes: suppressedHashes,
                bots: bots,
                mainBotId: mainBotId,
                secrets: secrets,
                expectedEpoch: capturedEpoch
            )
        }
        applyPromptState(payload, to: promptState)
        return (payload.sanitizedAppBook, payload.clearRetractions.map(\.text))
    }

    @discardableResult
    @MainActor
    func commitAppBookAsync(
        _ book: MemoryBook,
        mutation: MemoryCommitMutation = .none,
        snapshotReason: String? = nil,
        suppressedHashes: Set<String>,
        promptState: MemorySafety.PromptState? = nil,
        bots: [BotInfo],
        mainBotId: String?,
        secrets: [String],
        expectedEpoch: UInt64? = nil
    ) async throws -> (book: MemoryBook, editedTexts: [String]) {
        let capturedEpoch = expectedEpoch ?? book.storeEpoch ?? stateLock.withLock { canonicalStateEpoch }
        let payload: CommitPromptPayload = try await withCheckedThrowingContinuation { continuation in
            commitQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: TeamError(message: "记忆保存已取消。"))
                    return
                }
                do {
                    let result = try self.performSerializedCommitOnCommitQueue(
                        book,
                        mutation: mutation,
                        snapshotReason: snapshotReason,
                        suppressedHashes: suppressedHashes,
                        bots: bots,
                        mainBotId: mainBotId,
                        secrets: secrets,
                        expectedEpoch: capturedEpoch
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            #if DEBUG
            self.onCommitAsyncEnqueuedForTesting?()
            #endif
        }
        applyPromptState(payload, to: promptState)
        return (payload.sanitizedAppBook, payload.clearRetractions.map(\.text))
    }

    @MainActor
    func resetAll(team: TeamModel) {
        let summaries = Self.makeBotSummaries(bots: team.bots, mainBotId: team.mainBotId)
        let memoryURL = teamRoot.appendingPathComponent(Self.memoryFileName)
        let retractedURL = teamRoot.appendingPathComponent(Self.retractedFileName)
        let nextEpoch: UInt64 = commitQueue.sync {
            let epoch: UInt64 = stateLock.withLock {
                pinnedIDs.removeAll()
                archivedRecords.removeAll()
                tombstoneShadow.removeAll()
                recordShadowByID.removeAll()
                lastSyncedMemories = []
                lastSyncedBookDigest = Self.bookDigest(MemoryBook())
                botSummaries = summaries
                canonicalLoadFailed = false
                syncSequence &+= 1
                canonicalStateEpoch &+= 1
                return canonicalStateEpoch
            }
            guard !Disk.frozen else { return epoch }
            let emptyBook = CanonicalMemoryBook()
            _ = try? writeCanonicalBookToDisk(emptyBook, at: memoryURL)
            try? FileManager.default.removeItem(at: retractedURL)
            queue.async { [weak self] in
                guard let self, !Disk.frozen else { return }
                let secrets = Self.orderedSecrets(Vault.allStrings())
                try? self.store.resetAll(clearTombstones: true)
                MemoryMarkdownMirror.sync(records: [], bots: summaries, secrets: secrets, mirrorsRoot: self.mirrorRoot)
            }
            return epoch
        }
        team.memoryBook.storeEpoch = nextEpoch
    }

    func flushSync() {
        commitQueue.sync {}
        queue.sync {}
    }

    // MARK: - Private Sync Helpers

    private struct SQLitePersistActions {
        var upsertRecords: [(record: MemoryRecord, explicitUserAction: Bool)] = []
        var recallUpdates: [(id: String, layer: MemoryLayer, record: MemoryRecord, nowMs: Double)] = []
        var editEvents: [(id: String, text: String, editedByUser: Bool)] = []
        var pinEvents: [(id: String, pinned: Bool, nowMs: Double)] = []
        var layerEvents: [(id: String, layer: MemoryLayer, nowMs: Double)] = []
        var layerMetadataEvents: [(
            id: String,
            layer: MemoryLayer,
            kind: String?,
            topic: String?,
            confidence: Double?,
            fallbackRecord: MemoryRecord?,
            nowMs: Double
        )] = []
        var restoreEvents: [(id: String, layer: MemoryLayer, nowMs: Double)] = []
        var softDeleteEvents: [(id: String, text: String?, reason: String, nowMs: Double)] = []
        var prunedReviewMemoryIDs: Set<String> = []
    }

    private struct PreparedCommit {
        let canonical: CanonicalMemoryBook
        let sanitizedAppBook: MemoryBook
        let liveRecords: [MemoryRecord]
        let sqliteActions: SQLitePersistActions
        let retractItems: [(id: String, textForInFlightGuard: String?)]
        let clearRetractions: [(id: String?, text: String)]
        let shouldInvalidatePromptCache: Bool
        let shadowUpdate: CommittedShadowUpdate
    }

    private struct CommittedShadowUpdate {
        let nextShadowByID: [String: MemoryRecord]
        let nextArchived: [MemoryRecord]
        let nextPinnedIDs: Set<String>
        let nextTombstones: [String: MemoryTombstone]
        let sanitizedBook: MemoryBook
        let botSummaries: [MemoryMirrorBot]
        let seq: UInt64
    }

    @MainActor
    private func handlePossibleExternalMemoryMutation(on team: TeamModel) {
        guard team.keeping, !Disk.frozen, !isCanonicalReadOnly else { return }
        let currentBookDigest = Self.bookDigest(team.memoryBook)
        let alreadyHandled: Bool = stateLock.withLock {
            team.memories == lastSyncedMemories && currentBookDigest == lastSyncedBookDigest
        }
        guard !alreadyHandled else { return }

        var book = team.memoryBook
        book.memories = team.memories
        let orderedSecrets = Self.orderedSecrets(Vault.allStrings())
        let suppressed = team.memoryPromptState.suppressedFlushHashesSnapshot()
        guard let result = try? commitAppBook(
            book,
            suppressedHashes: suppressed,
            promptState: team.memoryPromptState,
            bots: team.bots,
            mainBotId: team.mainBotId,
            secrets: orderedSecrets
        ) else {
            return
        }
        if team.memoryBook.memories != result.book.memories || team.memoryBook.reviews.count != result.book.reviews.count {
            team.memoryBook = result.book
        }
        if team.memories != result.book.memories {
            team.memories = result.book.memories
        }
        team.memoryReviews = result.book.reviews
        team.syncLivePromptsFromMemories()
    }

    private func mutationNowMs(_ mutation: MemoryCommitMutation) -> Double? {
        switch mutation {
        case .none:
            return nil
        case .remember(_, _, let nowMs),
             .recall(_, let nowMs),
             .setDeep(_, _, let nowMs),
             .pin(_, _, let nowMs),
             .layerAndMetadata(_, _, _, _, _, _, _, _, let nowMs),
             .importBatch(_, let nowMs),
             .restore(_, _, _, let nowMs),
             .softDelete(_, _, let nowMs),
             .edit(_, _, _, let nowMs):
            return nowMs
        }
    }

    private func applyPreLoopMutation(
        _ mutation: MemoryCommitMutation,
        workingRecordsByID: inout [String: MemoryRecord],
        workingArchived: inout [MemoryRecord],
        workingPinnedIDs: inout Set<String>,
        workingTombstones: inout [String: MemoryTombstone],
        effectiveSuppressedHashes: inout Set<String>,
        sqliteActions: inout SQLitePersistActions,
        retractItems: inout [(id: String, textForInFlightGuard: String?)],
        clearRetractions: inout [(id: String?, text: String)],
        skippedBatchIDs: inout Set<String>,
        shouldInvalidatePromptCache: inout Bool,
        secrets: [String]
    ) {
        switch mutation {
        case .none:
            break

        case .remember(let memory, let explicitUserAction, _):
            let safeText = Self.redact(memory.text, orderedSecrets: secrets)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let hash = MemorySafety.retractionHash(safeText)
            if explicitUserAction, !hash.isEmpty {
                workingTombstones.removeValue(forKey: hash)
                effectiveSuppressedHashes.remove(hash)
                clearRetractions.append((id: memory.id, text: safeText))
            } else if !explicitUserAction {
                shouldInvalidatePromptCache = true
            }

        case .recall(let ids, let recallNow):
            for id in ids {
                if var existing = workingRecordsByID[id] {
                    existing.layer = existing.pinned ? .pinned : .surface
                    existing.usedAtMs = recallNow
                    existing.updatedAtMs = max(existing.updatedAtMs, recallNow)
                    workingRecordsByID[id] = existing
                }
            }
            if !ids.isEmpty {
                shouldInvalidatePromptCache = true
            }

        case .setDeep(let id, let deep, let setNow):
            let targetLayer: MemoryLayer = deep ? .deep : .surface
            workingPinnedIDs.remove(id)
            if var existing = workingRecordsByID[id] {
                existing.layer = targetLayer
                existing.pinned = false
                existing.usedAtMs = setNow
                existing.updatedAtMs = max(existing.updatedAtMs, setNow)
                workingRecordsByID[id] = existing
            }
            sqliteActions.layerEvents.append((id: id, layer: targetLayer, nowMs: setNow))
            shouldInvalidatePromptCache = true

        case .pin(let id, let pinned, let pinNow):
            let targetLayer: MemoryLayer = pinned ? .pinned : .surface
            if pinned {
                workingPinnedIDs.insert(id)
            } else {
                workingPinnedIDs.remove(id)
            }
            if var existing = workingRecordsByID[id] {
                existing.pinned = pinned
                existing.layer = targetLayer
                existing.usedAtMs = pinNow
                existing.updatedAtMs = max(existing.updatedAtMs, pinNow)
                workingRecordsByID[id] = existing
            }
            sqliteActions.pinEvents.append((id: id, pinned: pinned, nowMs: pinNow))
            shouldInvalidatePromptCache = true

        case .layerAndMetadata(let id, let layer, let kind, let topic, let confidence, let text, let editedByUser, let fallbackMemory, let layerNow):
            if layer == .pinned {
                workingPinnedIDs.insert(id)
            } else {
                workingPinnedIDs.remove(id)
            }
            var target: MemoryRecord?
            if let active = workingRecordsByID[id] {
                target = active
            } else if let idx = workingArchived.firstIndex(where: { $0.id == id }) {
                target = workingArchived.remove(at: idx)
            } else if let fallbackMemory {
                let safeText = Self.redact(fallbackMemory.text, orderedSecrets: secrets)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let hash = MemorySafety.retractionHash(safeText)
                if !safeText.isEmpty, !hash.isEmpty {
                    target = MemoryRecord(
                        id: fallbackMemory.id,
                        text: safeText,
                        textSHA256: hash,
                        layer: layer,
                        pinned: layer == .pinned,
                        kind: "fact",
                        topic: "",
                        createdAtMs: fallbackMemory.at,
                        updatedAtMs: layerNow,
                        usedAtMs: fallbackMemory.used ?? layerNow,
                        byBot: fallbackMemory.by,
                        automatic: fallbackMemory.automatic == true,
                        editedByUser: fallbackMemory.editedByUser == true,
                        deletedAtMs: nil
                    )
                }
            }
            if var updated = target {
                updated.layer = layer
                updated.pinned = (layer == .pinned)
                if let rawText = text {
                    let safeNewText = Self.redact(rawText, orderedSecrets: secrets)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let newHash = MemorySafety.retractionHash(safeNewText)
                    if !safeNewText.isEmpty && !newHash.isEmpty {
                        workingTombstones.removeValue(forKey: newHash)
                        effectiveSuppressedHashes.remove(newHash)
                        clearRetractions.append((id: id, text: safeNewText))
                        if updated.text != safeNewText {
                            updated.text = safeNewText
                            updated.textSHA256 = newHash
                            sqliteActions.editEvents.append((id: id, text: safeNewText, editedByUser: editedByUser))
                        }
                        if editedByUser {
                            updated.editedByUser = true
                        }
                    }
                }
                if let kind {
                    let cleanKind = kind.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleanKind.isEmpty { updated.kind = cleanKind }
                }
                if let topic {
                    updated.topic = Self.redact(topic, orderedSecrets: secrets)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let confidence {
                    updated.confidence = min(1.0, max(0.0, confidence))
                }
                if layer == .pinned || layer == .surface {
                    updated.usedAtMs = max(updated.usedAtMs ?? 0, layerNow)
                }
                updated.updatedAtMs = max(updated.updatedAtMs, layerNow)
                if layer == .archived {
                    workingRecordsByID.removeValue(forKey: id)
                    workingArchived.removeAll { $0.id == id }
                    workingArchived.append(updated)
                } else {
                    workingArchived.removeAll { $0.id == id }
                    workingRecordsByID[id] = updated
                }
                target = updated
            }
            sqliteActions.layerMetadataEvents.append((
                id: id,
                layer: layer,
                kind: kind,
                topic: topic,
                confidence: confidence,
                fallbackRecord: target,
                nowMs: layerNow
            ))
            shouldInvalidatePromptCache = true

        case .importBatch(let items, let importNow):
            var seenHashes = Set(workingRecordsByID.values.map(\.textSHA256))
            seenHashes.formUnion(workingArchived.map(\.textSHA256))
            for item in items {
                let safeText = Self.redact(item.memory.text, orderedSecrets: secrets)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let hash = MemorySafety.retractionHash(safeText)
                guard !safeText.isEmpty,
                      !hash.isEmpty,
                      workingTombstones[hash] == nil,
                      !effectiveSuppressedHashes.contains(hash),
                      workingRecordsByID[item.memory.id] == nil,
                      !workingArchived.contains(where: { $0.id == item.memory.id }),
                      seenHashes.insert(hash).inserted else {
                    skippedBatchIDs.insert(item.memory.id)
                    continue
                }

                let rawKind = Self.redact(item.kind, orderedSecrets: secrets)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let safeKind = rawKind.isEmpty ? "fact" : rawKind
                let safeTopic = Self.redact(item.topic, orderedSecrets: secrets)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let isPinned = item.layer == .pinned
                let record = MemoryRecord(
                    id: item.memory.id,
                    text: safeText,
                    textSHA256: hash,
                    layer: item.layer,
                    pinned: isPinned,
                    kind: safeKind,
                    topic: safeTopic,
                    sourceChat: nil,
                    sourceEntryID: nil,
                    confidence: 1.0,
                    createdAtMs: item.memory.at,
                    updatedAtMs: max(item.memory.at, importNow),
                    usedAtMs: item.memory.used ?? importNow,
                    byBot: item.memory.by,
                    automatic: false,
                    editedByUser: true,
                    deletedAtMs: nil
                )
                if item.layer == .archived {
                    workingArchived.append(record)
                } else {
                    if isPinned {
                        workingPinnedIDs.insert(record.id)
                    }
                    workingRecordsByID[record.id] = record
                }
                sqliteActions.upsertRecords.append((record: record, explicitUserAction: false))
                shouldInvalidatePromptCache = true
            }

        case .restore(let id, let memory, let targetLayer, let restoreNow):
            let resolvedLayer: MemoryLayer = targetLayer == .archived ? .surface : targetLayer
            let isPinned = resolvedLayer == .pinned
            let safeText = Self.redact(memory.text, orderedSecrets: secrets)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let hash = MemorySafety.retractionHash(safeText)
            var restoredFromArchive: MemoryRecord?
            if let idx = workingArchived.firstIndex(where: { $0.id == id }) {
                restoredFromArchive = workingArchived.remove(at: idx)
            }
            if isPinned {
                workingPinnedIDs.insert(id)
            } else {
                workingPinnedIDs.remove(id)
            }
            if !hash.isEmpty {
                workingTombstones.removeValue(forKey: hash)
                effectiveSuppressedHashes.remove(hash)
            }
            if !safeText.isEmpty && !hash.isEmpty {
                var rec = restoredFromArchive ?? MemoryRecord(
                    id: id,
                    text: safeText,
                    textSHA256: hash,
                    layer: resolvedLayer,
                    pinned: isPinned,
                    createdAtMs: memory.at,
                    updatedAtMs: restoreNow,
                    usedAtMs: restoreNow,
                    byBot: memory.by,
                    automatic: memory.automatic == true,
                    editedByUser: memory.editedByUser == true,
                    deletedAtMs: nil
                )
                rec.text = safeText
                rec.textSHA256 = hash
                rec.layer = resolvedLayer
                rec.pinned = isPinned
                rec.deletedAtMs = nil
                rec.usedAtMs = restoreNow
                rec.updatedAtMs = max(rec.updatedAtMs, restoreNow)
                workingRecordsByID[id] = rec
                clearRetractions.append((id: id, text: safeText))
            }
            sqliteActions.restoreEvents.append((id: id, layer: resolvedLayer, nowMs: restoreNow))

        case .softDelete(let items, let reason, let deleteNow):
            let safeReason = Self.redact(reason, orderedSecrets: secrets)
            for item in items {
                sqliteActions.prunedReviewMemoryIDs.insert(item.id)
                let removedShadow = workingRecordsByID.removeValue(forKey: item.id)
                var removedArchived: MemoryRecord?
                if let idx = workingArchived.firstIndex(where: { $0.id == item.id }) {
                    removedArchived = workingArchived.remove(at: idx)
                }
                workingPinnedIDs.remove(item.id)
                let rawText = item.text ?? removedShadow?.text ?? removedArchived?.text
                let safeText = rawText
                    .map { Self.redact($0, orderedSecrets: secrets).trimmingCharacters(in: .whitespacesAndNewlines) }
                    .flatMap { $0.isEmpty ? nil : $0 }
                if let safeText {
                    let hash = MemorySafety.retractionHash(safeText)
                    if !hash.isEmpty {
                        workingTombstones[hash] = MemoryTombstone(
                            textSHA256: hash,
                            memoryID: item.id,
                            deletedAtMs: deleteNow,
                            reason: safeReason
                        )
                        effectiveSuppressedHashes.insert(hash)
                    }
                    retractItems.append((id: item.id, textForInFlightGuard: safeText))
                } else if !item.id.isEmpty {
                    retractItems.append((id: item.id, textForInFlightGuard: nil))
                }
                sqliteActions.softDeleteEvents.append((
                    id: item.id,
                    text: safeText,
                    reason: safeReason,
                    nowMs: deleteNow
                ))
            }

        case .edit(let id, let text, let editedByUser, let editNow):
            let safeText = Self.redact(text, orderedSecrets: secrets)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let newHash = MemorySafety.retractionHash(safeText)
            if !safeText.isEmpty && !newHash.isEmpty {
                workingTombstones.removeValue(forKey: newHash)
                effectiveSuppressedHashes.remove(newHash)
                sqliteActions.editEvents.append((id: id, text: safeText, editedByUser: editedByUser))
                clearRetractions.append((id: id, text: safeText))
                if var existing = workingRecordsByID[id] {
                    existing.updatedAtMs = max(existing.updatedAtMs, editNow)
                    if editedByUser { existing.editedByUser = true }
                    workingRecordsByID[id] = existing
                }
            }
        }
    }

    private func buildCommitSnapshot(
        book: MemoryBook,
        mutation: MemoryCommitMutation,
        suppressedHashes: Set<String>,
        botSummaries: [MemoryMirrorBot],
        secrets: [String],
        nowMs: Double
    ) -> PreparedCommit {
        stateLock.lock()
        defer { stateLock.unlock() }

        var workingRecordsByID = recordShadowByID
        var workingArchived = archivedRecords
        var workingPinnedIDs = pinnedIDs
        var workingTombstones = tombstoneShadow
        var effectiveSuppressedHashes = Set(suppressedHashes.compactMap { raw -> String? in
            let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return MemorySafety.isSHA256Hex(clean) ? clean : nil
        })

        var sqliteActions = SQLitePersistActions()
        var retractItems: [(id: String, textForInFlightGuard: String?)] = []
        var clearRetractions: [(id: String?, text: String)] = []
        var skippedBatchIDs: Set<String> = []
        var shouldInvalidatePromptCache = false

        applyPreLoopMutation(
            mutation,
            workingRecordsByID: &workingRecordsByID,
            workingArchived: &workingArchived,
            workingPinnedIDs: &workingPinnedIDs,
            workingTombstones: &workingTombstones,
            effectiveSuppressedHashes: &effectiveSuppressedHashes,
            sqliteActions: &sqliteActions,
            retractItems: &retractItems,
            clearRetractions: &clearRetractions,
            skippedBatchIDs: &skippedBatchIDs,
            shouldInvalidatePromptCache: &shouldInvalidatePromptCache,
            secrets: secrets
        )

        var nextShadowByID: [String: MemoryRecord] = [:]
        var nextPinnedIDs: Set<String> = []
        var canonicalItems: [CanonicalMemoryItem] = []

        // When `.recall` arrives from an asynchronous task, `book.memories` may predate concurrent `.remember`/`.edit`
        // commits that landed on `commitQueue` inside the same `canonicalStateEpoch`. Rebuild active memories from live
        // `workingRecordsByID` (already updated by `applyPreLoopMutation`), only falling back to `book.memories` if
        // `workingRecordsByID` is empty on an unbootstrapped bridge.
        let sourceMemories: [Memory]
        if case .recall = mutation, !workingRecordsByID.isEmpty {
            var remainingByID = workingRecordsByID
            var merged: [Memory] = []
            merged.reserveCapacity(remainingByID.count)
            for oldMem in book.memories {
                if let liveRec = remainingByID.removeValue(forKey: oldMem.id) {
                    merged.append(Self.toAppMemory(liveRec))
                }
            }
            let extraRecords = remainingByID.values.sorted {
                if $0.createdAtMs != $1.createdAtMs { return $0.createdAtMs < $1.createdAtMs }
                return $0.id < $1.id
            }
            merged.append(contentsOf: extraRecords.map(Self.toAppMemory))
            TeamModel.settleMemory(&merged, pinnedIDs: workingPinnedIDs)
            sourceMemories = merged
        } else {
            sourceMemories = book.memories
        }

        for mem in sourceMemories {
            guard !skippedBatchIDs.contains(mem.id) else { continue }
            let safeText = Self.redact(mem.text, orderedSecrets: secrets)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !safeText.isEmpty else { continue }
            let hash = MemorySafety.retractionHash(safeText)
            guard !hash.isEmpty else { continue }

            // Enforce active tombstones if an automatic/stale writer passed a retracted entry.
            if let tomb = workingTombstones[hash] {
                let effectiveUpdated = max(mem.used ?? mem.at, mem.at)
                let isAutomaticOnly = (mem.automatic == true) && (mem.editedByUser != true)
                let existingEditedText = workingRecordsByID[mem.id].map { $0.text != safeText } ?? false
                if !existingEditedText && (isAutomaticOnly || tomb.deletedAtMs >= effectiveUpdated) {
                    continue
                }
                workingTombstones.removeValue(forKey: hash)
                effectiveSuppressedHashes.remove(hash)
            }

            let existing = workingRecordsByID[mem.id]
            let isPinned = (workingPinnedIDs.contains(mem.id) || existing?.pinned == true) && mem.deep != true
            let layer: MemoryLayer
            if isPinned {
                layer = .pinned
                nextPinnedIDs.insert(mem.id)
            } else if mem.deep == true {
                layer = .deep
            } else {
                layer = .surface
            }

            let textChanged = existing != nil && existing?.text != safeText
            let layerChanged = existing != nil && existing?.layer != layer
            if textChanged && !sqliteActions.editEvents.contains(where: { $0.id == mem.id }) {
                sqliteActions.editEvents.append((mem.id, safeText, mem.editedByUser == true))
                workingTombstones.removeValue(forKey: hash)
                effectiveSuppressedHashes.remove(hash)
                clearRetractions.append((id: mem.id, text: safeText))
            }
            if layerChanged && !sqliteActions.layerEvents.contains(where: { $0.id == mem.id }) && !sqliteActions.pinEvents.contains(where: { $0.id == mem.id }) {
                sqliteActions.layerEvents.append((mem.id, layer, nowMs))
            }

            let updatedAt: Double
            if textChanged || layerChanged || existing == nil {
                updatedAt = max(existing?.updatedAtMs ?? 0, max(mem.used ?? 0, nowMs))
            } else {
                updatedAt = max(existing?.updatedAtMs ?? 0, max(mem.used ?? mem.at, mem.at))
            }

            let existingTopic = existing.map { Self.redact($0.topic, orderedSecrets: secrets) } ?? ""
            let record = MemoryRecord(
                id: mem.id,
                text: safeText,
                textSHA256: hash,
                layer: layer,
                pinned: layer == .pinned,
                kind: existing?.kind ?? "fact",
                topic: existingTopic,
                sourceChat: existing?.sourceChat,
                sourceEntryID: existing?.sourceEntryID,
                confidence: existing?.confidence ?? 1.0,
                createdAtMs: mem.at,
                updatedAtMs: updatedAt,
                usedAtMs: mem.used,
                byBot: mem.by,
                automatic: mem.automatic == true,
                editedByUser: mem.editedByUser == true || existing?.editedByUser == true,
                deletedAtMs: nil
            )
            nextShadowByID[record.id] = record
            canonicalItems.append(CanonicalMemoryItem(from: record))
        }

        if case .remember(let mem, let explicitUserAction, _) = mutation,
           let committed = nextShadowByID[mem.id] {
            sqliteActions.upsertRecords.append((record: committed, explicitUserAction: explicitUserAction))
        } else if case .recall(let ids, let recallNow) = mutation {
            for id in ids {
                if let committed = nextShadowByID[id] {
                    sqliteActions.recallUpdates.append((id: id, layer: committed.layer, record: committed, nowMs: recallNow))
                }
            }
        }

        // Also re-redact any retained archived items and tombstone reasons against live Vault secrets.
        let scrubbedArchived: [MemoryRecord] = workingArchived.compactMap { archived in
            let safeText = Self.redact(archived.text, orderedSecrets: secrets)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let safeHash = MemorySafety.retractionHash(safeText)
            guard !safeText.isEmpty, !safeHash.isEmpty else { return nil }
            let safeTopic = Self.redact(archived.topic, orderedSecrets: secrets)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var copy = archived
            if safeText != archived.text || safeTopic != archived.topic {
                copy.text = safeText
                copy.textSHA256 = safeHash
                copy.topic = safeTopic
                copy.updatedAtMs = max(archived.updatedAtMs, nowMs)
            }
            return copy
        }

        for (hash, var tomb) in workingTombstones {
            let safeReason = Self.redact(tomb.reason, orderedSecrets: secrets)
            if safeReason != tomb.reason {
                tomb.reason = safeReason
                workingTombstones[hash] = tomb
            }
        }

        // Seed untimestamped effectiveSuppressedHashes not already live or in workingTombstones.
        for clean in effectiveSuppressedHashes {
            guard workingTombstones[clean] == nil,
                  !nextShadowByID.values.contains(where: { $0.textSHA256 == clean }) else { continue }
            workingTombstones[clean] = MemoryTombstone(
                textSHA256: clean,
                memoryID: nil,
                deletedAtMs: nowMs,
                reason: "retracted"
            )
        }

        let allTombstones = workingTombstones.values.sorted {
            if $0.deletedAtMs != $1.deletedAtMs { return $0.deletedAtMs > $1.deletedAtMs }
            return $0.textSHA256 < $1.textSHA256
        }
        var combinedHashes = Set(workingTombstones.keys)
        combinedHashes.formUnion(effectiveSuppressedHashes)
        for clear in clearRetractions {
            let clearedHash = MemorySafety.retractionHash(clear.text)
            if !clearedHash.isEmpty { combinedHashes.remove(clearedHash) }
        }

        let prunedIDs = sqliteActions.prunedReviewMemoryIDs
        let canonicalReviews = book.reviews.map { log in
            CanonicalMemoryReviewLog(
                id: log.id,
                at: log.at,
                day: log.day,
                conversation: Self.redact(log.conversation, orderedSecrets: secrets),
                added: log.added
                    .filter { !prunedIDs.contains($0.memoryID) }
                    .map { .init(memoryID: $0.memoryID, text: Self.redact($0.text, orderedSecrets: secrets)) },
                merged: log.merged
                    .filter { !prunedIDs.contains($0.memoryID) }
                    .map {
                        .init(
                            memoryID: $0.memoryID,
                            before: Self.redact($0.before, orderedSecrets: secrets),
                            after: Self.redact($0.after, orderedSecrets: secrets)
                        )
                    }
            )
        }

        let canonical = CanonicalMemoryBook(
            memories: canonicalItems,
            archived: scrubbedArchived.map(CanonicalMemoryItem.init(from:)),
            reviews: canonicalReviews,
            processed: book.processed,
            reviewFromDay: book.reviewFromDay,
            budgetDay: book.budgetDay,
            requests: book.requests,
            diaryRequests: book.diaryRequests,
            suppressedFlushHashes: combinedHashes.sorted(),
            tombstones: allTombstones
        )
        let sanitizedAppBook = Self.toAppMemoryBook(canonical)
        let liveRecords = Array(nextShadowByID.values) + scrubbedArchived
        let nextSeq = syncSequence &+ 1
        let shadowUpdate = CommittedShadowUpdate(
            nextShadowByID: nextShadowByID,
            nextArchived: scrubbedArchived,
            nextPinnedIDs: nextPinnedIDs,
            nextTombstones: workingTombstones,
            sanitizedBook: sanitizedAppBook,
            botSummaries: botSummaries,
            seq: nextSeq
        )
        return PreparedCommit(
            canonical: canonical,
            sanitizedAppBook: sanitizedAppBook,
            liveRecords: liveRecords,
            sqliteActions: sqliteActions,
            retractItems: retractItems,
            clearRetractions: clearRetractions,
            shouldInvalidatePromptCache: shouldInvalidatePromptCache,
            shadowUpdate: shadowUpdate
        )
    }

    private func applyCommittedShadow(_ update: CommittedShadowUpdate) {
        stateLock.lock()
        recordShadowByID = update.nextShadowByID
        archivedRecords = update.nextArchived
        pinnedIDs = update.nextPinnedIDs
        tombstoneShadow = update.nextTombstones
        botSummaries = update.botSummaries
        lastSyncedMemories = update.sanitizedBook.memories
        lastSyncedBookDigest = Self.bookDigest(update.sanitizedBook)
        syncSequence = update.seq
        stateLock.unlock()
    }

    private func applyBackgroundPersist(
        canonical: CanonicalMemoryBook,
        liveRecords: [MemoryRecord],
        bots: [MemoryMirrorBot],
        secrets: [String],
        jsonDigest: String,
        sequence: UInt64,
        sqliteActions: SQLitePersistActions,
        nowMs: Double
    ) {
        guard !isSQLiteRecoveryBlocked else { return }
        do {
            _ = try store.openOrRecover()
            for restoreEvent in sqliteActions.restoreEvents {
                _ = try store.restore(id: restoreEvent.id, layer: restoreEvent.layer, nowMs: restoreEvent.nowMs)
            }
            for edit in sqliteActions.editEvents {
                _ = try store.editText(
                    id: edit.id,
                    text: edit.text,
                    editedByUser: edit.editedByUser,
                    nowMs: nowMs,
                    secrets: secrets
                )
            }
            for pinEvent in sqliteActions.pinEvents {
                _ = try store.pin(id: pinEvent.id, pinned: pinEvent.pinned, nowMs: pinEvent.nowMs)
            }
            for layerEvent in sqliteActions.layerEvents {
                _ = try store.setLayer(id: layerEvent.id, layer: layerEvent.layer, nowMs: layerEvent.nowMs)
            }
            for metaEvent in sqliteActions.layerMetadataEvents {
                if (try? store.setLayer(id: metaEvent.id, layer: metaEvent.layer, nowMs: metaEvent.nowMs)) == nil,
                   let fallback = metaEvent.fallbackRecord {
                    _ = try store.upsert(fallback, explicitUserAction: true, secrets: secrets)
                }
                if metaEvent.kind != nil || metaEvent.topic != nil || metaEvent.confidence != nil {
                    _ = try store.setMetadata(
                        id: metaEvent.id,
                        kind: metaEvent.kind,
                        topic: metaEvent.topic,
                        confidence: metaEvent.confidence,
                        nowMs: metaEvent.nowMs,
                        secrets: secrets
                    )
                }
            }
            for recallEvent in sqliteActions.recallUpdates {
                if (try? store.setLayer(id: recallEvent.id, layer: recallEvent.layer, nowMs: recallEvent.nowMs)) == nil {
                    _ = try store.upsert(recallEvent.record, explicitUserAction: true, secrets: secrets)
                }
            }
            for upsert in sqliteActions.upsertRecords {
                _ = try store.upsert(upsert.record, explicitUserAction: upsert.explicitUserAction, secrets: secrets)
            }
            for del in sqliteActions.softDeleteEvents {
                if (try? store.softDelete(id: del.id, nowMs: del.nowMs, reason: del.reason, secrets: secrets)) == nil,
                   let text = del.text {
                    _ = try store.softDelete(text: text, nowMs: del.nowMs, reason: del.reason, secrets: secrets)
                }
            }
            if !sqliteActions.prunedReviewMemoryIDs.isEmpty {
                try store.pruneReviewDetails(memoryIDs: sqliteActions.prunedReviewMemoryIDs)
            }
            _ = try store.reconcile(
                book: canonical,
                secrets: secrets,
                nowMs: nowMs,
                jsonDigest: jsonDigest
            )
            try? store.checkpoint()
        } catch {
            // Canonical Team/memory.json is already written atomically and will reconcile on next launch.
        }

        let isLatest = stateLock.withLock { sequence == syncSequence }
        if isLatest && !Disk.frozen {
            MemoryMarkdownMirror.sync(
                records: liveRecords,
                bots: bots,
                secrets: secrets,
                mirrorsRoot: mirrorRoot
            )
        }
    }

    private func refreshMarkdownMirrorAsync(bots: [MemoryMirrorBot]) {
        queue.async { [weak self] in
            guard let self, !Disk.frozen else { return }
            let secrets = Self.orderedSecrets(Vault.allStrings())
            let records = self.recordsSnapshot()
            MemoryMarkdownMirror.sync(
                records: records,
                bots: bots,
                secrets: secrets,
                mirrorsRoot: self.mirrorRoot
            )
        }
    }

    private func checkpointAsync() {
        queue.async { [weak self] in
            guard let self, !self.isSQLiteRecoveryBlocked else { return }
            try? self.store.checkpoint()
        }
    }

    #if DEBUG
    func checkpointForTestingSync() {
        checkpointAsync()
        queue.sync {}
    }
    #endif

    // MARK: - Revision Snapshots & Health

    func revisionHealthSnapshot() -> MemoryRevisionHealth {
        revisionStore.readHealth()
    }

    func recordReviewFailure(message: String) {
        queue.async { [revisionStore] in
            do {
                _ = try revisionStore.recordReviewFailureThrowing(message: message, atMs: Now.ms)
            } catch {
                Diag.note("记录记忆整理失败状态写盘出错：\(error.localizedDescription)")
            }
        }
    }

    func recordReviewSuccess() {
        queue.async { [revisionStore] in
            do {
                _ = try revisionStore.recordReviewSuccessThrowing(atMs: Now.ms)
            } catch {
                Diag.note("记录记忆整理成功状态写盘出错：\(error.localizedDescription)")
            }
        }
    }

    func listRevisionSnapshotsOffMain() async -> [MemoryRevisionSnapshot] {
        await withCheckedContinuation { continuation in
            commitQueue.async { [revisionStore] in
                continuation.resume(returning: revisionStore.listSnapshots())
            }
        }
    }

    func saveManualRevisionSnapshotOffMain() async throws -> MemoryRevisionSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            commitQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: TeamError(message: "保存快照已取消。"))
                    return
                }
                guard !Disk.frozen else {
                    continuation.resume(throwing: TeamError(message: "刚恢复了备份，重新打开 Clio 后才能保存快照。"))
                    return
                }
                let memoryURL = self.teamRoot.appendingPathComponent(Self.memoryFileName)
                guard case .decoded(let currentBook, _) = self.loadCanonicalBookFromDisk(at: memoryURL) else {
                    continuation.resume(throwing: TeamError(message: "当前没有可保存的记忆档案。"))
                    return
                }
                do {
                    let snap = try self.revisionStore.saveManualSnapshot(currentBook, reason: "manual", nowMs: Now.ms)
                    continuation.resume(returning: snap)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func restoreRevisionSnapshotOffMain(
        id: String,
        bots: [BotInfo],
        mainBotId: String?
    ) async throws -> (book: MemoryBook, preRestore: MemoryRevisionSnapshot?) {
        let summaries = Self.makeBotSummaries(bots: bots, mainBotId: mainBotId)
        let secrets = Self.orderedSecrets(Vault.allStrings())
        let isShared = (self === MemoryStoreBridge.shared)
        let expBridge = coordinatorExperienceBridge
        return try await withCheckedThrowingContinuation { continuation in
            commitQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: TeamError(message: "恢复快照已取消。"))
                    return
                }
                #if DEBUG
                self.beforeRestoreCommitForTesting?()
                #endif
                self.queue.sync {
                    guard !Disk.frozen else {
                        continuation.resume(throwing: TeamError(message: "刚恢复了备份，重新打开 Clio 后才能恢复快照。"))
                        return
                    }
                    guard !self.stateLock.withLock({ self.canonicalLoadFailed }) else {
                        continuation.resume(throwing: TeamError(message: "记忆文件暂不可读，已跳过恢复以防数据损坏。"))
                        return
                    }
                    do {
                        // Hold ExperienceStoreBridge exclusively across marking `projection-rebuild.journal`,
                        // canonical snapshot restore, and SQLite projection reset so no experience operation
                        // can slip between checking the recovery block and setting the marker / rebuilding SQLite.
                        let restoreAndResetSQLite: () throws -> (
                            reconciled: CanonicalMemoryBook,
                            liveRecords: [MemoryRecord],
                            preRestoreSnapshot: MemoryRevisionSnapshot?
                        ) = {
                            let extraTombstones = self.tombstoneHashesSnapshot()
                            let restored = try self.revisionStore.restoreSnapshot(
                                id: id,
                                extraRetractedHashes: extraTombstones,
                                nowMs: Now.ms
                            )
                            let retractedURL = self.teamRoot.appendingPathComponent(Self.retractedFileName)
                            let existingRetracted = self.loadRetractedHashes(at: retractedURL)
                            try self.syncRetractedHashesFileThrowing(
                                Set(restored.book.suppressedFlushHashes),
                                existing: existingRetracted,
                                at: retractedURL
                            )

                            try self.store.destroyFilesThrowing()
                            _ = try self.store.openOrRecover()
                            let reconciled = try self.store.reconcile(
                                book: restored.book,
                                secrets: secrets,
                                nowMs: Now.ms,
                                jsonDigest: restored.digest
                            )
                            try? self.store.checkpoint()
                            let liveRecords = try self.store.list(layer: nil, includeDeleted: false, secrets: secrets)
                            return (
                                reconciled: reconciled,
                                liveRecords: liveRecords,
                                preRestoreSnapshot: restored.preRestoreSnapshot
                            )
                        }

                        let outcome: (
                            reconciled: CanonicalMemoryBook,
                            liveRecords: [MemoryRecord],
                            preRestoreSnapshot: MemoryRevisionSnapshot?
                        )
                        if let expBridge {
                            outcome = try expBridge.performDatabaseResetSync {
                                try restoreAndResetSQLite()
                            }
                        } else {
                            outcome = try restoreAndResetSQLite()
                        }
                        let reconciled = outcome.reconciled
                        let liveRecords = outcome.liveRecords
                        let appBook = Self.toAppMemoryBook(reconciled)
                        let restoredEpoch = self.updateShadowState(
                            liveRecords: liveRecords,
                            tombstones: reconciled.tombstones,
                            appBook: appBook
                        )
                        var stampedBook = appBook
                        stampedBook.storeEpoch = restoredEpoch
                        if !Disk.frozen {
                            MemoryMarkdownMirror.sync(
                                records: liveRecords,
                                bots: summaries,
                                secrets: secrets,
                                mirrorsRoot: self.mirrorRoot
                            )
                        }
                        if isShared {
                            MemoryRecallBridge.shared.scheduleSync()
                        }
                        self.revisionStore.clearPendingProjectionRebuild()
                        continuation.resume(returning: (book: stampedBook, preRestore: outcome.preRestoreSnapshot))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    func runColdStartRecoveryForTesting(
        extraRetractedHashes: Set<String> = [],
        nowMs: Double = Now.ms
    ) throws -> MemoryJournalRecoveryOutcome {
        try commitQueue.sync {
            try queue.sync {
                try revisionStore.recoverPendingJournalIfNeeded(
                    extraRetractedHashes: extraRetractedHashes,
                    nowMs: nowMs
                )
            }
        }
    }

    private func hydrateShadowsFromCanonical(
        _ canonical: CanonicalMemoryBook,
        retractedHashes: Set<String>,
        secrets: [String]
    ) -> (result: BootstrapResult, liveRecords: [MemoryRecord]) {
        var liveRecords: [MemoryRecord] = []
        var pins: Set<String> = []
        let nowMs = Now.ms

        var tombstonesByHash: [String: MemoryTombstone] = [:]
        for tomb in canonical.tombstones {
            let clean = tomb.textSHA256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard MemorySafety.isSHA256Hex(clean) else { continue }
            tombstonesByHash[clean] = MemoryTombstone(
                textSHA256: clean,
                memoryID: tomb.memoryID,
                deletedAtMs: tomb.deletedAtMs,
                reason: Self.redact(tomb.reason, orderedSecrets: secrets)
            )
        }

        var retainedMemories: [CanonicalMemoryItem] = []
        retainedMemories.reserveCapacity(canonical.memories.count)
        for item in canonical.memories {
            let safeText = Self.redact(item.text, orderedSecrets: secrets).trimmingCharacters(in: .whitespacesAndNewlines)
            let hash = MemorySafety.retractionHash(safeText)
            guard !safeText.isEmpty, !hash.isEmpty else { continue }
            if let tomb = tombstonesByHash[hash] {
                let isAutomaticOnly = (item.automatic == true) && (item.editedByUser != true)
                if isAutomaticOnly || tomb.deletedAtMs >= item.effectiveUpdatedAtMs {
                    continue
                }
                tombstonesByHash.removeValue(forKey: hash)
            }
            var sanitized = item
            sanitized.text = safeText
            if let topic = item.topic {
                sanitized.topic = Self.redact(topic, orderedSecrets: secrets)
            }
            retainedMemories.append(sanitized)

            let layer = sanitized.resolvedLayer
            if layer == .pinned { pins.insert(sanitized.id) }
            liveRecords.append(MemoryRecord(
                id: sanitized.id,
                text: safeText,
                textSHA256: hash,
                layer: layer,
                pinned: layer == .pinned,
                kind: sanitized.kind ?? "fact",
                topic: Self.redact(sanitized.topic ?? "", orderedSecrets: secrets),
                sourceChat: sanitized.sourceChat,
                sourceEntryID: sanitized.sourceEntryID,
                confidence: sanitized.confidence ?? 1.0,
                createdAtMs: sanitized.at,
                updatedAtMs: sanitized.effectiveUpdatedAtMs,
                usedAtMs: sanitized.used,
                byBot: sanitized.by,
                automatic: sanitized.automatic == true,
                editedByUser: sanitized.editedByUser == true,
                deletedAtMs: nil
            ))
        }

        var retainedArchived: [CanonicalMemoryItem] = []
        retainedArchived.reserveCapacity(canonical.archived.count)
        for item in canonical.archived {
            let safeText = Self.redact(item.text, orderedSecrets: secrets).trimmingCharacters(in: .whitespacesAndNewlines)
            let hash = MemorySafety.retractionHash(safeText)
            guard !safeText.isEmpty, !hash.isEmpty else { continue }
            if let tomb = tombstonesByHash[hash] {
                let isAutomaticOnly = (item.automatic == true) && (item.editedByUser != true)
                if isAutomaticOnly || tomb.deletedAtMs >= item.effectiveUpdatedAtMs {
                    continue
                }
                tombstonesByHash.removeValue(forKey: hash)
            }
            var sanitized = item
            sanitized.text = safeText
            if let topic = item.topic {
                sanitized.topic = Self.redact(topic, orderedSecrets: secrets)
            }
            retainedArchived.append(sanitized)

            liveRecords.append(MemoryRecord(
                id: sanitized.id,
                text: safeText,
                textSHA256: hash,
                layer: .archived,
                pinned: false,
                kind: sanitized.kind ?? "fact",
                topic: Self.redact(sanitized.topic ?? "", orderedSecrets: secrets),
                sourceChat: sanitized.sourceChat,
                sourceEntryID: sanitized.sourceEntryID,
                confidence: sanitized.confidence ?? 1.0,
                createdAtMs: sanitized.at,
                updatedAtMs: sanitized.effectiveUpdatedAtMs,
                usedAtMs: sanitized.used,
                byBot: sanitized.by,
                automatic: sanitized.automatic == true,
                editedByUser: sanitized.editedByUser == true,
                deletedAtMs: nil
            ))
        }

        var combinedSuppressed = Set(tombstonesByHash.keys)
        let activeHashes = Set(liveRecords.map(\.textSHA256))
        for rawHash in canonical.suppressedFlushHashes + Array(retractedHashes) {
            let clean = rawHash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard MemorySafety.isSHA256Hex(clean), !activeHashes.contains(clean) else { continue }
            combinedSuppressed.insert(clean)
        }
        for hash in combinedSuppressed where tombstonesByHash[hash] == nil {
            tombstonesByHash[hash] = MemoryTombstone(
                textSHA256: hash,
                memoryID: nil,
                deletedAtMs: nowMs,
                reason: "retracted"
            )
        }

        var filteredCanonical = canonical
        filteredCanonical.memories = retainedMemories
        filteredCanonical.archived = retainedArchived
        filteredCanonical.suppressedFlushHashes = combinedSuppressed.sorted()
        filteredCanonical.tombstones = tombstonesByHash.values.sorted {
            if $0.deletedAtMs != $1.deletedAtMs { return $0.deletedAtMs > $1.deletedAtMs }
            return $0.textSHA256 < $1.textSHA256
        }

        let appBook = Self.toAppMemoryBook(filteredCanonical)
        let epoch = updateShadowState(
            liveRecords: liveRecords,
            tombstones: filteredCanonical.tombstones,
            appBook: appBook
        )
        var stampedBook = appBook
        stampedBook.storeEpoch = epoch
        return (
            BootstrapResult(book: stampedBook, suppressedHashes: combinedSuppressed, pinnedIDs: pins),
            liveRecords
        )
    }

    @discardableResult
    private func updateShadowState(
        liveRecords: [MemoryRecord],
        tombstones: [MemoryTombstone],
        appBook: MemoryBook
    ) -> UInt64 {
        stateLock.lock()
        var byID: [String: MemoryRecord] = [:]
        var archived: [MemoryRecord] = []
        var pins: Set<String> = []
        for record in liveRecords {
            if record.layer == .archived {
                archived.append(record)
            } else {
                byID[record.id] = record
                if record.layer == .pinned { pins.insert(record.id) }
            }
        }
        recordShadowByID = byID
        archivedRecords = archived
        pinnedIDs = pins
        tombstoneShadow = Dictionary(tombstones.map { ($0.textSHA256, $0) }, uniquingKeysWith: { lhs, rhs in
            lhs.deletedAtMs >= rhs.deletedAtMs ? lhs : rhs
        })
        lastSyncedMemories = appBook.memories
        lastSyncedBookDigest = Self.bookDigest(appBook)
        canonicalStateEpoch &+= 1
        let epoch = canonicalStateEpoch
        stateLock.unlock()
        return epoch
    }

    // MARK: - Disk I/O Helpers

    private func loadCanonicalBookFromDisk(at url: URL) -> DiskBookLoad {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .missing
        }
        guard let data = try? Data(contentsOf: url) else {
            return .unreadable
        }
        let digest = Self.sha256Hex(data)
        if let decoded = try? CanonicalMemoryBook.decodeFlexible(from: data) {
            return .decoded(decoded, digest: digest)
        }
        return .corrupt(data)
    }

    private func loadRetractedHashes(at url: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(raw.compactMap { entry -> String? in
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if MemorySafety.isSHA256Hex(trimmed) { return trimmed.lowercased() }
            let computed = MemorySafety.retractionHash(trimmed)
            return computed.isEmpty ? nil : computed
        })
    }

    @discardableResult
    private func writeCanonicalBookToDisk(_ book: CanonicalMemoryBook, at url: URL) throws -> String {
        guard !Disk.frozen else {
            throw TeamError(message: "刚恢复了备份，重新打开 Clio 后才能保存。")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(book)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return Self.sha256Hex(data)
    }

    private func syncRetractedHashesFileIfNeeded(_ merged: Set<String>, existing: Set<String>, at url: URL) {
        try? syncRetractedHashesFileThrowing(merged, existing: existing, at: url)
    }

    private func syncRetractedHashesFileThrowing(_ merged: Set<String>, existing: Set<String>, at url: URL) throws {
        guard !Disk.frozen else {
            throw TeamError(message: "刚恢复了备份，重新打开 Clio 后才能保存。")
        }
        let clean = merged.filter(MemorySafety.isSHA256Hex).sorted()
        guard Set(clean) != existing else { return }
        if clean.isEmpty {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        } else {
            let data = try JSONEncoder().encode(clean)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    // MARK: - Model Mapping & Redaction Helpers

    private static func redactCanonicalBook(
        _ book: CanonicalMemoryBook,
        orderedSecrets: [String]
    ) -> CanonicalMemoryBook {
        guard !orderedSecrets.isEmpty else { return book }
        var copy = book
        copy.memories = book.memories.map { item in
            var c = item
            c.text = redact(item.text, orderedSecrets: orderedSecrets)
            if let topic = item.topic { c.topic = redact(topic, orderedSecrets: orderedSecrets) }
            return c
        }
        copy.archived = book.archived.map { item in
            var c = item
            c.text = redact(item.text, orderedSecrets: orderedSecrets)
            if let topic = item.topic { c.topic = redact(topic, orderedSecrets: orderedSecrets) }
            return c
        }
        copy.reviews = book.reviews.map { log in
            CanonicalMemoryReviewLog(
                id: log.id,
                at: log.at,
                day: log.day,
                conversation: redact(log.conversation, orderedSecrets: orderedSecrets),
                added: log.added.map { .init(memoryID: $0.memoryID, text: redact($0.text, orderedSecrets: orderedSecrets)) },
                merged: log.merged.map {
                    .init(
                        memoryID: $0.memoryID,
                        before: redact($0.before, orderedSecrets: orderedSecrets),
                        after: redact($0.after, orderedSecrets: orderedSecrets)
                    )
                }
            )
        }
        copy.tombstones = book.tombstones.map { tomb in
            MemoryTombstone(
                textSHA256: tomb.textSHA256,
                memoryID: tomb.memoryID,
                deletedAtMs: tomb.deletedAtMs,
                reason: redact(tomb.reason, orderedSecrets: orderedSecrets)
            )
        }
        return copy
    }

    private static func toAppMemoryBook(_ canonical: CanonicalMemoryBook) -> MemoryBook {
        MemoryBook(
            memories: canonical.memories.map(toAppMemory),
            reviews: canonical.reviews.map { log in
                MemoryReviewLog(
                    id: log.id,
                    at: log.at,
                    day: log.day,
                    conversation: log.conversation,
                    added: log.added.map { .init(memoryID: $0.memoryID, text: $0.text) },
                    merged: log.merged.map { .init(memoryID: $0.memoryID, before: $0.before, after: $0.after) }
                )
            },
            processed: canonical.processed,
            reviewFromDay: canonical.reviewFromDay,
            budgetDay: canonical.budgetDay,
            requests: canonical.requests,
            diaryRequests: canonical.diaryRequests
        )
    }

    private static func toAppMemory(_ item: CanonicalMemoryItem) -> Memory {
        Memory(
            id: item.id,
            text: item.text,
            at: item.at,
            by: item.by,
            deep: item.resolvedLayer == .deep ? true : nil,
            used: item.used,
            automatic: item.automatic,
            editedByUser: item.editedByUser
        )
    }

    private static func toAppMemory(_ record: MemoryRecord) -> Memory {
        Memory(
            id: record.id,
            text: record.text,
            at: record.createdAtMs,
            by: record.byBot,
            deep: record.layer == .deep ? true : nil,
            used: record.usedAtMs,
            automatic: record.automatic ? true : nil,
            editedByUser: record.editedByUser ? true : nil
        )
    }

    private static func makeBotSummaries(bots: [BotInfo], mainBotId: String?) -> [MemoryMirrorBot] {
        bots.map { bot in
            MemoryMirrorBot(
                name: bot.name,
                role: bot.role,
                isMain: bot.id == mainBotId || bot.main == true
            )
        }
    }

    private static func bookDigest(_ book: MemoryBook) -> String {
        guard let data = try? JSONEncoder().encode(book) else { return "" }
        return sha256Hex(data)
    }

    private static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func orderedSecrets(_ secrets: [String]) -> [String] {
        secrets.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
    }

    private static func redact(_ text: String, orderedSecrets: [String]) -> String {
        orderedSecrets.isEmpty ? text : MemorySafety.redactSecrets(text, secrets: orderedSecrets)
    }
}
