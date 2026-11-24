import Combine
import Craft
import CryptoKit
import Foundation
import UIKit

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

    static let shared = MemoryStoreBridge()

    private static let pendingRestoreRebuildDefaultsKey = "clio.memoryStore.pendingRestoreRebuild"
    private static let retractedFileName = "memory-retracted.json"
    private static let memoryFileName = "memory.json"

    nonisolated static var defaultDatabaseURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClioMemory", isDirectory: true)
            .appendingPathComponent("clio-memory.db")
    }

    private let store: MemoryStore
    private let teamRoot: URL
    private let mirrorRoot: URL
    private let queue = DispatchQueue(label: "clio.memory-store", qos: .utility)

    private let stateLock = NSLock()
    private var pinnedIDs: Set<String> = []
    private var archivedRecords: [MemoryRecord] = []
    private var tombstoneShadow: [String: MemoryTombstone] = [:]
    private var recordShadowByID: [String: MemoryRecord] = [:]
    private var lastSyncedMemories: [Memory] = []
    private var lastSyncedBookDigest: String = ""
    private var syncSequence: UInt64 = 0
    private var botSummaries: [MemoryMirrorBot] = []
    private var canonicalLoadFailed: Bool = false
    private var sqliteNeedsReconcile: Bool = false

    @MainActor private var observerCancellables: Set<AnyCancellable> = []
    @MainActor private weak var observedTeam: TeamModel?

    init(
        databaseURL: URL = MemoryStoreBridge.defaultDatabaseURL,
        teamRoot: URL = Disk.root,
        mirrorRoot: URL = MemoryMarkdownMirror.defaultRoot
    ) {
        self.store = MemoryStore(databaseURL: databaseURL)
        self.teamRoot = teamRoot
        self.mirrorRoot = mirrorRoot
    }

    // MARK: - Synchronous Shadow Reads (Thread-Safe)

    func pinnedIDsSnapshot() -> Set<String> {
        stateLock.lock()
        defer { stateLock.unlock() }
        return pinnedIDs
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
        return queue.sync {
            bootstrapOnLaunchLocked()
        }
    }

    private func bootstrapOnLaunchLocked() -> BootstrapResult {
        let memoryURL = teamRoot.appendingPathComponent(Self.memoryFileName)
        let retractedURL = teamRoot.appendingPathComponent(Self.retractedFileName)
        let secrets = Self.orderedSecrets(Vault.allStrings())

        let diskLoad = loadCanonicalBookFromDisk(at: memoryURL)
        let retractedHashes = loadRetractedHashes(at: retractedURL)

        let pendingRebuild = UserDefaults.standard.bool(forKey: Self.pendingRestoreRebuildDefaultsKey)
        if pendingRebuild {
            UserDefaults.standard.removeObject(forKey: Self.pendingRestoreRebuildDefaultsKey)
            store.destroyFiles()
            MemoryMarkdownMirror.clearMirrors(mirrorsRoot: mirrorRoot)
        }

        let incomingBook: CanonicalMemoryBook?
        let initialDigest: String?
        let jsonNeedsRewrite: Bool
        switch diskLoad {
        case .missing:
            stateLock.withLock { canonicalLoadFailed = false }
            incomingBook = nil
            initialDigest = nil
            jsonNeedsRewrite = false
        case .unreadable:
            stateLock.withLock { canonicalLoadFailed = true }
            incomingBook = nil
            initialDigest = nil
            jsonNeedsRewrite = false
        case .corrupt(let rawData):
            stateLock.withLock { canonicalLoadFailed = false }
            if !Disk.frozen {
                let aside = memoryURL.deletingLastPathComponent()
                    .appendingPathComponent("memory.broken-\(Int(Date().timeIntervalSince1970)).json")
                try? rawData.write(to: aside, options: .atomic)
            }
            incomingBook = nil
            initialDigest = nil
            jsonNeedsRewrite = true
        case .decoded(let decoded, let digest):
            stateLock.withLock { canonicalLoadFailed = false }
            incomingBook = decoded
            initialDigest = digest
            jsonNeedsRewrite = false
        }

        do {
            _ = try store.openOrRecover()

            var bookToReconcile = incomingBook ?? CanonicalMemoryBook()
            var combinedSuppressed = Set(bookToReconcile.suppressedFlushHashes)
            combinedSuppressed.formUnion(retractedHashes)
            bookToReconcile.suppressedFlushHashes = combinedSuppressed.sorted()

            let reconciled = try store.reconcile(
                book: bookToReconcile,
                secrets: secrets,
                nowMs: Now.ms,
                jsonDigest: initialDigest
            )
            try? store.checkpoint()

            let liveRecords = try store.list(layer: nil, includeDeleted: false, secrets: secrets)
            let canWriteJSON = !Disk.frozen && !stateLock.withLock { canonicalLoadFailed }

            if canWriteJSON && (jsonNeedsRewrite || (incomingBook != nil && reconciled != bookToReconcile) || (incomingBook == nil && !liveRecords.isEmpty)) {
                if let newDigest = try? writeCanonicalBookToDisk(reconciled, at: memoryURL) {
                    _ = try? store.reconcile(book: reconciled, secrets: secrets, nowMs: Now.ms, jsonDigest: newDigest)
                    try? store.checkpoint()
                }
            }

            if canWriteJSON {
                syncRetractedHashesFileIfNeeded(
                    Set(reconciled.suppressedFlushHashes),
                    existing: retractedHashes,
                    at: retractedURL
                )
            }

            let appBook = Self.toAppMemoryBook(reconciled)
            updateShadowState(
                liveRecords: liveRecords,
                tombstones: reconciled.tombstones,
                appBook: appBook,
                sqliteFailed: false
            )

            let currentBots = stateLock.withLock { botSummaries }
            if !Disk.frozen {
                MemoryMarkdownMirror.sync(
                    records: liveRecords,
                    bots: currentBots,
                    secrets: secrets,
                    mirrorsRoot: mirrorRoot
                )
            }

            return BootstrapResult(
                book: appBook,
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
        UserDefaults.standard.set(true, forKey: Self.pendingRestoreRebuildDefaultsKey)
        queue.async { [weak self] in
            guard let self else { return }
            self.store.destroyFiles()
            MemoryMarkdownMirror.clearMirrors(mirrorsRoot: self.mirrorRoot)
        }
    }

    // MARK: - Explicit Mutation Hooks (MainActor callers -> synchronous shadow + async SQLite)

    func recordRemember(
        memory: Memory,
        explicitUserAction: Bool,
        layer: MemoryLayer? = nil,
        kind: String = "fact",
        topic: String = "",
        sourceChat: String? = nil,
        sourceEntryID: String? = nil,
        nowMs: Double = Now.ms
    ) {
        let hash = MemorySafety.retractionHash(memory.text)
        let resolvedLayer = layer ?? (memory.deep == true ? .deep : .surface)

        stateLock.lock()
        let existing = recordShadowByID[memory.id]
        let finalLayer: MemoryLayer = (existing?.pinned == true && layer == nil) ? .pinned : resolvedLayer
        let record = MemoryRecord(
            id: memory.id,
            text: memory.text,
            textSHA256: hash,
            layer: finalLayer,
            pinned: finalLayer == .pinned,
            kind: kind == "fact" ? (existing?.kind ?? "fact") : kind,
            topic: topic.isEmpty ? (existing?.topic ?? "") : topic,
            sourceChat: sourceChat ?? existing?.sourceChat,
            sourceEntryID: sourceEntryID ?? existing?.sourceEntryID,
            confidence: existing?.confidence ?? 1.0,
            createdAtMs: memory.at,
            updatedAtMs: max(existing?.updatedAtMs ?? 0, nowMs),
            usedAtMs: memory.used ?? nowMs,
            byBot: memory.by ?? existing?.byBot,
            automatic: memory.automatic == true,
            editedByUser: memory.editedByUser == true || existing?.editedByUser == true,
            deletedAtMs: nil
        )
        recordShadowByID[record.id] = record
        if record.pinned {
            pinnedIDs.insert(record.id)
        } else {
            pinnedIDs.remove(record.id)
        }
        if let tomb = tombstoneShadow[hash] {
            if explicitUserAction || (!record.automatic && nowMs > tomb.deletedAtMs) {
                tombstoneShadow.removeValue(forKey: hash)
            }
        }
        stateLock.unlock()

        queue.async { [weak self] in
            guard let self, !Disk.frozen else { return }
            let secrets = Self.orderedSecrets(Vault.allStrings())
            _ = try? self.store.upsert(record, explicitUserAction: explicitUserAction, secrets: secrets)
        }
    }

    func recordRecall(ids: Set<String>, nowMs: Double = Now.ms) {
        guard !ids.isEmpty else { return }
        var updates: [(id: String, layer: MemoryLayer, record: MemoryRecord)] = []

        stateLock.lock()
        for id in ids {
            guard var record = recordShadowByID[id] else { continue }
            let nextLayer: MemoryLayer = record.pinned ? .pinned : .surface
            record.layer = nextLayer
            record.usedAtMs = nowMs
            record.updatedAtMs = max(record.updatedAtMs, nowMs)
            recordShadowByID[id] = record
            updates.append((id, nextLayer, record))
        }
        stateLock.unlock()

        guard !updates.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, !Disk.frozen else { return }
            let secrets = Self.orderedSecrets(Vault.allStrings())
            for item in updates {
                if (try? self.store.setLayer(id: item.id, layer: item.layer, nowMs: nowMs)) == nil {
                    _ = try? self.store.upsert(item.record, explicitUserAction: true, secrets: secrets)
                }
            }
        }
    }

    func recordSetDeep(id: String, deep: Bool, nowMs: Double = Now.ms) {
        let nextLayer: MemoryLayer = deep ? .deep : .surface
        stateLock.lock()
        if var record = recordShadowByID[id] {
            record.layer = nextLayer
            record.pinned = false
            record.usedAtMs = nowMs
            record.updatedAtMs = max(record.updatedAtMs, nowMs)
            recordShadowByID[id] = record
        }
        pinnedIDs.remove(id)
        stateLock.unlock()

        queue.async { [weak self] in
            guard let self, !Disk.frozen else { return }
            _ = try? self.store.setLayer(id: id, layer: nextLayer, nowMs: nowMs)
        }
    }

    func recordPin(id: String, pinned: Bool, nowMs: Double = Now.ms) {
        let nextLayer: MemoryLayer = pinned ? .pinned : .surface
        stateLock.lock()
        if var record = recordShadowByID[id] {
            record.pinned = pinned
            record.layer = nextLayer
            record.usedAtMs = nowMs
            record.updatedAtMs = max(record.updatedAtMs, nowMs)
            recordShadowByID[id] = record
        }
        if pinned {
            pinnedIDs.insert(id)
        } else {
            pinnedIDs.remove(id)
        }
        stateLock.unlock()

        queue.async { [weak self] in
            guard let self, !Disk.frozen else { return }
            _ = try? self.store.pin(id: id, pinned: pinned, nowMs: nowMs)
        }
    }

    func recordLayerAndMetadata(
        id: String,
        layer: MemoryLayer,
        kind: String? = nil,
        topic: String? = nil,
        confidence: Double? = nil,
        nowMs: Double = Now.ms
    ) {
        stateLock.lock()
        if var record = recordShadowByID[id] {
            record.layer = layer
            record.pinned = (layer == .pinned)
            if let kind, !kind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                record.kind = kind.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let topic {
                record.topic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let confidence {
                record.confidence = min(1.0, max(0.0, confidence))
            }
            record.updatedAtMs = max(record.updatedAtMs, nowMs)
            if layer == .archived {
                recordShadowByID.removeValue(forKey: id)
                archivedRecords.removeAll { $0.id == id }
                archivedRecords.append(record)
            } else {
                archivedRecords.removeAll { $0.id == id }
                recordShadowByID[id] = record
            }
        }
        if layer == .pinned {
            pinnedIDs.insert(id)
        } else {
            pinnedIDs.remove(id)
        }
        stateLock.unlock()

        queue.async { [weak self] in
            guard let self, !Disk.frozen else { return }
            let secrets = Self.orderedSecrets(Vault.allStrings())
            _ = try? self.store.setLayer(id: id, layer: layer, nowMs: nowMs)
            if kind != nil || topic != nil || confidence != nil {
                _ = try? self.store.setMetadata(
                    id: id,
                    kind: kind,
                    topic: topic,
                    confidence: confidence,
                    nowMs: nowMs,
                    secrets: secrets
                )
            }
        }
    }

    func recordArchive(id: String, nowMs: Double = Now.ms) {
        recordLayerAndMetadata(id: id, layer: .archived, nowMs: nowMs)
    }

    func recordRestore(id: String, nowMs: Double = Now.ms) -> Memory? {
        var restoredMemory: Memory?
        stateLock.lock()
        if let idx = archivedRecords.firstIndex(where: { $0.id == id }) {
            var rec = archivedRecords.remove(at: idx)
            rec.layer = .surface
            rec.pinned = false
            rec.deletedAtMs = nil
            rec.updatedAtMs = max(rec.updatedAtMs, nowMs)
            rec.usedAtMs = nowMs
            recordShadowByID[rec.id] = rec
            tombstoneShadow.removeValue(forKey: rec.textSHA256)
            restoredMemory = Self.toAppMemory(rec)
        }
        stateLock.unlock()

        if let restoredMemory {
            queue.async { [weak self] in
                guard let self, !Disk.frozen else { return }
                _ = try? self.store.restore(id: id, layer: .surface, nowMs: nowMs)
            }
            return restoredMemory
        }

        let restoredFromDB: MemoryRecord? = queue.sync {
            guard !Disk.frozen else { return nil }
            return try? store.restore(id: id, layer: .surface, nowMs: nowMs)
        }
        guard let restoredFromDB else { return nil }
        stateLock.lock()
        recordShadowByID[restoredFromDB.id] = restoredFromDB
        tombstoneShadow.removeValue(forKey: restoredFromDB.textSHA256)
        stateLock.unlock()
        return Self.toAppMemory(restoredFromDB)
    }

    func recordSoftDelete(
        items: [(id: String, text: String?)],
        nowMs: Double = Now.ms,
        reason: String = "user_delete"
    ) {
        guard !items.isEmpty else { return }
        var idsToDelete: Set<String> = []

        stateLock.lock()
        for item in items {
            idsToDelete.insert(item.id)
            let removedShadow = recordShadowByID.removeValue(forKey: item.id)
            archivedRecords.removeAll { $0.id == item.id }
            pinnedIDs.remove(item.id)
            let textToHash = item.text ?? removedShadow?.text
            if let textToHash {
                let hash = MemorySafety.retractionHash(textToHash)
                if !hash.isEmpty {
                    tombstoneShadow[hash] = MemoryTombstone(
                        textSHA256: hash,
                        memoryID: item.id,
                        deletedAtMs: nowMs,
                        reason: reason
                    )
                }
            }
        }
        stateLock.unlock()

        queue.async { [weak self] in
            guard let self, !Disk.frozen else { return }
            let secrets = Self.orderedSecrets(Vault.allStrings())
            for item in items {
                if (try? self.store.softDelete(id: item.id, nowMs: nowMs, reason: reason, secrets: secrets)) == nil,
                   let text = item.text {
                    _ = try? self.store.softDelete(text: text, nowMs: nowMs, reason: reason, secrets: secrets)
                }
            }
            try? self.store.pruneReviewDetails(memoryIDs: idsToDelete)
        }
    }

    // MARK: - Unified Canonical Book Commit (Throws on disk failure before mutating caller state)

    @discardableResult
    @MainActor
    func commitAppBook(
        _ book: MemoryBook,
        suppressedHashes: Set<String>,
        bots: [BotInfo],
        mainBotId: String?,
        secrets: [String]
    ) throws -> (book: MemoryBook, editedTexts: [String]) {
        guard !Disk.frozen else {
            throw TeamError(message: "刚恢复了备份，重新打开 Clio 后才能保存。")
        }
        let loadBlocked = stateLock.withLock { canonicalLoadFailed }
        guard !loadBlocked else {
            throw TeamError(message: "记忆文件暂不可读，已跳过覆盖写入以防丢失原有记忆。")
        }

        let orderedSecrets = Self.orderedSecrets(secrets)
        let summaries = Self.makeBotSummaries(bots: bots, mainBotId: mainBotId)
        let nowMs = Now.ms

        let prepared = buildCommitSnapshot(
            book: book,
            suppressedHashes: suppressedHashes,
            botSummaries: summaries,
            secrets: orderedSecrets,
            nowMs: nowMs
        )

        let memoryURL = teamRoot.appendingPathComponent(Self.memoryFileName)
        let writtenDigest = try writeCanonicalBookToDisk(prepared.canonical, at: memoryURL)

        applyCommittedShadow(prepared.shadowUpdate)

        let retractedURL = teamRoot.appendingPathComponent(Self.retractedFileName)
        syncRetractedHashesFileIfNeeded(
            Set(prepared.canonical.suppressedFlushHashes),
            existing: suppressedHashes,
            at: retractedURL
        )

        queue.async { [weak self] in
            guard let self, !Disk.frozen else { return }
            self.applyBackgroundPersist(
                canonical: prepared.canonical,
                liveRecords: prepared.liveRecords,
                bots: summaries,
                secrets: orderedSecrets,
                jsonDigest: writtenDigest,
                sequence: prepared.shadowUpdate.seq,
                editEvents: prepared.editEvents,
                layerEvents: prepared.layerEvents,
                nowMs: nowMs
            )
        }

        return (prepared.sanitizedAppBook, prepared.editEvents.map(\.text))
    }

    @MainActor
    func resetAll(team: TeamModel) {
        let summaries = Self.makeBotSummaries(bots: team.bots, mainBotId: team.mainBotId)
        stateLock.withLock {
            pinnedIDs.removeAll()
            archivedRecords.removeAll()
            tombstoneShadow.removeAll()
            recordShadowByID.removeAll()
            lastSyncedMemories = []
            lastSyncedBookDigest = Self.bookDigest(MemoryBook())
            botSummaries = summaries
            canonicalLoadFailed = false
            sqliteNeedsReconcile = false
            syncSequence &+= 1
        }
        guard !Disk.frozen else { return }
        let emptyBook = CanonicalMemoryBook()
        _ = try? writeCanonicalBookToDisk(emptyBook, at: teamRoot.appendingPathComponent(Self.memoryFileName))
        try? FileManager.default.removeItem(at: teamRoot.appendingPathComponent(Self.retractedFileName))
        queue.async { [weak self] in
            guard let self, !Disk.frozen else { return }
            try? self.store.resetAll(clearTombstones: true)
            MemoryMarkdownMirror.sync(records: [], bots: summaries, secrets: [], mirrorsRoot: self.mirrorRoot)
        }
    }

    func flushSync() {
        queue.sync {}
    }

    // MARK: - Private Sync Helpers

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
        guard team.keeping, !Disk.frozen else { return }
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
            team.invalidateMemoryPromptCache()
        }
    }

    private func buildCommitSnapshot(
        book: MemoryBook,
        suppressedHashes: Set<String>,
        botSummaries: [MemoryMirrorBot],
        secrets: [String],
        nowMs: Double
    ) -> (
        canonical: CanonicalMemoryBook,
        sanitizedAppBook: MemoryBook,
        liveRecords: [MemoryRecord],
        editEvents: [(id: String, text: String, editedByUser: Bool)],
        layerEvents: [(id: String, layer: MemoryLayer)],
        shadowUpdate: CommittedShadowUpdate
    ) {
        stateLock.lock()
        defer { stateLock.unlock() }

        var workingTombstones = tombstoneShadow
        var nextShadowByID: [String: MemoryRecord] = [:]
        var nextPinnedIDs: Set<String> = []
        var editEvents: [(id: String, text: String, editedByUser: Bool)] = []
        var layerEvents: [(id: String, layer: MemoryLayer)] = []
        var canonicalItems: [CanonicalMemoryItem] = []

        for mem in book.memories {
            let safeText = Self.redact(mem.text, orderedSecrets: secrets)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !safeText.isEmpty else { continue }
            let hash = MemorySafety.retractionHash(safeText)
            guard !hash.isEmpty else { continue }

            // Enforce active tombstones if an automatic/stale writer passed a retracted entry.
            if let tomb = workingTombstones[hash] {
                let effectiveUpdated = max(mem.used ?? mem.at, mem.at)
                let isAutomaticOnly = (mem.automatic == true) && (mem.editedByUser != true)
                let existingEditedText = recordShadowByID[mem.id].map { $0.text != safeText } ?? false
                if !existingEditedText && (isAutomaticOnly || tomb.deletedAtMs >= effectiveUpdated) {
                    continue
                }
                workingTombstones.removeValue(forKey: hash)
            }

            let existing = recordShadowByID[mem.id]
            let isPinned = (pinnedIDs.contains(mem.id) || existing?.pinned == true) && mem.deep != true
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
            if textChanged {
                editEvents.append((mem.id, safeText, mem.editedByUser == true))
                workingTombstones.removeValue(forKey: hash)
            }
            if layerChanged {
                layerEvents.append((mem.id, layer))
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

        // Also re-redact any retained archived items and tombstone reasons against live Vault secrets.
        let scrubbedArchived: [MemoryRecord] = archivedRecords.compactMap { archived in
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

        // Seed untimestamped suppressedHashes not already live or in workingTombstones.
        for rawHash in suppressedHashes {
            let clean = rawHash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard MemorySafety.isSHA256Hex(clean),
                  workingTombstones[clean] == nil,
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
        combinedHashes.formUnion(suppressedHashes.filter(MemorySafety.isSHA256Hex))
        for edit in editEvents {
            let editedHash = MemorySafety.retractionHash(edit.text)
            if !editedHash.isEmpty { combinedHashes.remove(editedHash) }
        }

        let canonicalReviews = book.reviews.map { log in
            CanonicalMemoryReviewLog(
                id: log.id,
                at: log.at,
                day: log.day,
                conversation: Self.redact(log.conversation, orderedSecrets: secrets),
                added: log.added.map {
                    .init(memoryID: $0.memoryID, text: Self.redact($0.text, orderedSecrets: secrets))
                },
                merged: log.merged.map {
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
        return (canonical, sanitizedAppBook, liveRecords, editEvents, layerEvents, shadowUpdate)
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
        editEvents: [(id: String, text: String, editedByUser: Bool)],
        layerEvents: [(id: String, layer: MemoryLayer)],
        nowMs: Double
    ) {
        do {
            _ = try store.openOrRecover()
            for edit in editEvents {
                _ = try store.editText(
                    id: edit.id,
                    text: edit.text,
                    editedByUser: edit.editedByUser,
                    nowMs: nowMs,
                    secrets: secrets
                )
            }
            for layerEvent in layerEvents {
                _ = try store.setLayer(id: layerEvent.id, layer: layerEvent.layer, nowMs: nowMs)
            }
            _ = try store.reconcile(
                book: canonical,
                secrets: secrets,
                nowMs: nowMs,
                jsonDigest: jsonDigest
            )
            try? store.checkpoint()
            stateLock.withLock { self.sqliteNeedsReconcile = false }
        } catch {
            // Canonical Team/memory.json is already written atomically; mark for reconcile when DB recovers.
            stateLock.withLock { self.sqliteNeedsReconcile = true }
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
            guard let self, !Disk.frozen else { return }
            try? self.store.checkpoint()
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
        var combinedSuppressed = Set(tombstonesByHash.keys)
        combinedSuppressed.formUnion(canonical.suppressedFlushHashes.filter(MemorySafety.isSHA256Hex))
        combinedSuppressed.formUnion(retractedHashes.filter(MemorySafety.isSHA256Hex))

        for item in canonical.memories {
            let safeText = Self.redact(item.text, orderedSecrets: secrets).trimmingCharacters(in: .whitespacesAndNewlines)
            let hash = MemorySafety.retractionHash(safeText)
            guard !safeText.isEmpty, !hash.isEmpty else { continue }
            let layer = item.resolvedLayer
            if layer == .pinned { pins.insert(item.id) }
            liveRecords.append(MemoryRecord(
                id: item.id,
                text: safeText,
                textSHA256: hash,
                layer: layer,
                pinned: layer == .pinned,
                kind: item.kind ?? "fact",
                topic: Self.redact(item.topic ?? "", orderedSecrets: secrets),
                sourceChat: item.sourceChat,
                sourceEntryID: item.sourceEntryID,
                confidence: item.confidence ?? 1.0,
                createdAtMs: item.at,
                updatedAtMs: item.effectiveUpdatedAtMs,
                usedAtMs: item.used,
                byBot: item.by,
                automatic: item.automatic == true,
                editedByUser: item.editedByUser == true,
                deletedAtMs: nil
            ))
        }
        for item in canonical.archived {
            let safeText = Self.redact(item.text, orderedSecrets: secrets).trimmingCharacters(in: .whitespacesAndNewlines)
            let hash = MemorySafety.retractionHash(safeText)
            guard !safeText.isEmpty, !hash.isEmpty else { continue }
            liveRecords.append(MemoryRecord(
                id: item.id,
                text: safeText,
                textSHA256: hash,
                layer: .archived,
                pinned: false,
                kind: item.kind ?? "fact",
                topic: Self.redact(item.topic ?? "", orderedSecrets: secrets),
                sourceChat: item.sourceChat,
                sourceEntryID: item.sourceEntryID,
                confidence: item.confidence ?? 1.0,
                createdAtMs: item.at,
                updatedAtMs: item.effectiveUpdatedAtMs,
                usedAtMs: item.used,
                byBot: item.by,
                automatic: item.automatic == true,
                editedByUser: item.editedByUser == true,
                deletedAtMs: nil
            ))
        }
        for hash in combinedSuppressed where tombstonesByHash[hash] == nil {
            if !liveRecords.contains(where: { $0.textSHA256 == hash }) {
                tombstonesByHash[hash] = MemoryTombstone(
                    textSHA256: hash,
                    memoryID: nil,
                    deletedAtMs: nowMs,
                    reason: "retracted"
                )
            }
        }

        let appBook = Self.toAppMemoryBook(canonical)
        updateShadowState(
            liveRecords: liveRecords,
            tombstones: Array(tombstonesByHash.values),
            appBook: appBook,
            sqliteFailed: true
        )
        return (
            BootstrapResult(book: appBook, suppressedHashes: combinedSuppressed, pinnedIDs: pins),
            liveRecords
        )
    }

    private func updateShadowState(
        liveRecords: [MemoryRecord],
        tombstones: [MemoryTombstone],
        appBook: MemoryBook,
        sqliteFailed: Bool
    ) {
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
        sqliteNeedsReconcile = sqliteFailed
        stateLock.unlock()
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
        guard !Disk.frozen else { return }
        let clean = merged.filter(MemorySafety.isSHA256Hex).sorted()
        guard Set(clean) != existing else { return }
        if clean.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else if let data = try? JSONEncoder().encode(clean) {
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
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
