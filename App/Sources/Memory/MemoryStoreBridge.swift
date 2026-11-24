import Combine
import Craft
import CryptoKit
import Foundation
import UIKit

/// Off-MainActor coordinator for authoritative `clio-memory.db` (`MemoryStore`), canonical `memory.json`
/// bidirectional synchronization, Vault secret redaction, and `书案` Markdown mirrors.
final class MemoryStoreBridge: @unchecked Sendable {
    struct BootstrapResult: Sendable {
        let book: MemoryBook
        let suppressedHashes: Set<String>
        let pinnedIDs: Set<String>
    }

    static let shared = MemoryStoreBridge()

    private static let pendingRestoreDefaultsKey = "clio.memoryStore.pendingRestore"
    private static let retractedFileName = "memory-retracted.json"
    private static let memoryFileName = "memory.json"

    private let store: MemoryStore
    private let teamRoot: URL
    private let deskRoot: URL
    private let queue = DispatchQueue(label: "clio.memory-store", qos: .utility)

    private let stateLock = NSLock()
    private var pinnedIDs: Set<String> = []
    private var archivedRecords: [MemoryRecord] = []
    private var tombstoneShadow: [String: MemoryTombstone] = [:]
    private var recordShadowByID: [String: MemoryRecord] = [:]
    private var lastSyncedMemories: [Memory] = []
    private var lastSyncedBookDigest: String = ""
    private var syncSequence: UInt64 = 0
    private var currentMeta: MemoryStoreMeta?
    private var botSummaries: [MemoryMirrorBot] = []

    @MainActor private var observerCancellables: Set<AnyCancellable> = []
    @MainActor private weak var observedTeam: TeamModel?

    init(
        databaseURL: URL = Disk.url("clio-memory.db"),
        teamRoot: URL = Disk.root,
        deskRoot: URL = Workspace.root
    ) {
        self.store = MemoryStore(databaseURL: databaseURL)
        self.teamRoot = teamRoot
        self.deskRoot = deskRoot
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

        let loadedJSON = loadCanonicalBookFromDisk(at: memoryURL)
        let retractedHashes = loadRetractedHashes(at: retractedURL)

        let pendingRestore = UserDefaults.standard.string(forKey: Self.pendingRestoreDefaultsKey)
        if pendingRestore != nil {
            UserDefaults.standard.removeObject(forKey: Self.pendingRestoreDefaultsKey)
        }

        do {
            _ = try store.openOrRecover()
            let meta = try store.meta()

            if let pendingRestore,
               Self.shouldResetLeftoverDBAfterRestore(
                   pendingToken: pendingRestore,
                   meta: meta,
                   diskJSONDigest: loadedJSON.digest
               ) {
                try store.resetAll(clearTombstones: true)
            }

            var incomingBook = loadedJSON.book ?? CanonicalMemoryBook()
            var combinedSuppressed = Set(incomingBook.suppressedFlushHashes)
            combinedSuppressed.formUnion(retractedHashes)
            incomingBook.suppressedFlushHashes = combinedSuppressed.sorted()

            let reconciled = try store.reconcile(
                book: incomingBook,
                secrets: secrets,
                nowMs: Now.ms,
                jsonDigest: loadedJSON.digest
            )
            try? store.checkpoint()

            let liveRecords = try store.list(layer: nil, includeDeleted: false)
            let updatedMeta = try store.meta()

            let finalDigest: String?
            if !Disk.frozen && (loadedJSON.needsWrite || reconciled != incomingBook) {
                finalDigest = writeCanonicalBookToDisk(reconciled, at: memoryURL)
            } else {
                finalDigest = loadedJSON.digest
            }
            if let finalDigest {
                // Keep meta digest aligned if we normalized memory.json.
                if finalDigest != updatedMeta.lastSyncedJSONSHA256 && !Disk.frozen {
                    _ = try? store.reconcile(book: reconciled, secrets: secrets, nowMs: Now.ms, jsonDigest: finalDigest)
                    try? store.checkpoint()
                }
            }

            if !Disk.frozen {
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
                meta: try? store.meta(),
                appBook: appBook
            )

            let currentBots = stateLock.withLock { botSummaries }
            if !Disk.frozen {
                MemoryMarkdownMirror.sync(
                    records: liveRecords,
                    bots: currentBots,
                    secrets: secrets,
                    deskRoot: deskRoot
                )
            }

            return BootstrapResult(
                book: appBook,
                suppressedHashes: Set(reconciled.suppressedFlushHashes),
                pinnedIDs: Set(liveRecords.filter { $0.layer == .pinned }.map(\.id))
            )
        } catch {
            // Fail-safe fallback: return canonical JSON even if SQLite failed to open.
            let fallbackBook = loadedJSON.book.map(Self.toAppMemoryBook) ?? MemoryBook()
            return BootstrapResult(
                book: fallbackBook,
                suppressedHashes: retractedHashes,
                pinnedIDs: []
            )
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
                    self.handleBackupRestoreSucceeded()
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

    /// Closes the live SQLite handle immediately after a backup swap so stale descriptors cannot linger,
    /// and records the pre-restore DB identity/revision so relaunch detects pre-v0.36 backups lacking `clio-memory.db`.
    func handleBackupRestoreSucceeded() {
        let capturedMeta = stateLock.withLock { currentMeta }
        if let capturedMeta, !capturedMeta.instanceID.isEmpty {
            let token = "\(capturedMeta.instanceID)|\(capturedMeta.revision)"
            UserDefaults.standard.set(token, forKey: Self.pendingRestoreDefaultsKey)
        }
        queue.async { [weak self] in
            self?.store.close()
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

        // Fallback synchronous restore if item was soft-deleted and only lives in SQLite.
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

    // MARK: - Canonical Sync from `saveMemory()` & Unbridged Mutations

    @discardableResult
    @MainActor
    func persistAppSave(
        book: MemoryBook,
        suppressedHashes: Set<String>,
        bots: [BotInfo],
        mainBotId: String?,
        secrets: [String]
    ) -> [String] {
        guard !Disk.frozen else { return [] }
        let orderedSecrets = Self.orderedSecrets(secrets)
        let summaries = Self.makeBotSummaries(bots: bots, mainBotId: mainBotId)
        let nowMs = Now.ms

        let (canonical, liveRecords, seq, editEvents, layerEvents) = prepareSyncSnapshot(
            book: book,
            suppressedHashes: suppressedHashes,
            botSummaries: summaries,
            secrets: orderedSecrets,
            nowMs: nowMs
        )

        let memoryURL = teamRoot.appendingPathComponent(Self.memoryFileName)
        let writtenDigest = writeCanonicalBookToDisk(canonical, at: memoryURL)
        let retractedURL = teamRoot.appendingPathComponent(Self.retractedFileName)
        syncRetractedHashesFileIfNeeded(
            Set(canonical.suppressedFlushHashes),
            existing: suppressedHashes,
            at: retractedURL
        )

        queue.async { [weak self] in
            guard let self, !Disk.frozen else { return }
            self.applyBackgroundPersist(
                canonical: canonical,
                liveRecords: liveRecords,
                bots: summaries,
                secrets: orderedSecrets,
                jsonDigest: writtenDigest,
                sequence: seq,
                editEvents: editEvents,
                layerEvents: layerEvents,
                nowMs: nowMs
            )
        }
        return editEvents.map(\.text)
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
            syncSequence &+= 1
        }
        guard !Disk.frozen else { return }
        let emptyBook = CanonicalMemoryBook()
        _ = writeCanonicalBookToDisk(emptyBook, at: teamRoot.appendingPathComponent(Self.memoryFileName))
        try? FileManager.default.removeItem(at: teamRoot.appendingPathComponent(Self.retractedFileName))
        queue.async { [weak self] in
            guard let self, !Disk.frozen else { return }
            try? self.store.resetAll(clearTombstones: true)
            let updatedMeta = try? self.store.meta()
            self.stateLock.withLock { self.currentMeta = updatedMeta }
            MemoryMarkdownMirror.sync(records: [], bots: summaries, secrets: [], deskRoot: self.deskRoot)
        }
    }

    func flushSync() {
        queue.sync {}
    }

    // MARK: - Private Sync Helpers

    @MainActor
    private func handlePossibleExternalMemoryMutation(on team: TeamModel) {
        guard team.keeping, !Disk.frozen else { return }
        let currentBookDigest = Self.bookDigest(team.memoryBook)
        let alreadyHandled: Bool = stateLock.withLock {
            team.memories == lastSyncedMemories && currentBookDigest == lastSyncedBookDigest
        }
        guard !alreadyHandled else { return }

        let orderedSecrets = Self.orderedSecrets(Vault.allStrings())
        var sanitizedBook = team.memoryBook
        sanitizedBook.memories = team.memories

        // Enforce active tombstones & Vault redaction if an unbridged writer (e.g. reviewMemories) modified memories.
        let activeTombstones = stateLock.withLock { tombstoneShadow }
        var changedInMemory = false
        var filtered: [Memory] = []
        for var item in sanitizedBook.memories {
            let safeText = Self.redact(item.text, orderedSecrets: orderedSecrets)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !safeText.isEmpty else {
                changedInMemory = true
                continue
            }
            if safeText != item.text {
                item.text = safeText
                changedInMemory = true
            }
            let hash = MemorySafety.retractionHash(safeText)
            if let tomb = activeTombstones[hash] {
                let effectiveUpdated = max(item.used ?? item.at, item.at)
                let isAutomaticOnly = (item.automatic == true) && (item.editedByUser != true)
                if isAutomaticOnly || tomb.deletedAtMs >= effectiveUpdated {
                    changedInMemory = true
                    continue
                }
            }
            filtered.append(item)
        }
        if changedInMemory {
            sanitizedBook.memories = filtered
            team.memoryBook = sanitizedBook
            team.memories = filtered
            team.invalidateMemoryPromptCache()
        }

        let suppressed = team.memoryPromptState.suppressedFlushHashesSnapshot()
        persistAppSave(
            book: sanitizedBook,
            suppressedHashes: suppressed,
            bots: team.bots,
            mainBotId: team.mainBotId,
            secrets: orderedSecrets
        )
    }

    private func prepareSyncSnapshot(
        book: MemoryBook,
        suppressedHashes: Set<String>,
        botSummaries: [MemoryMirrorBot],
        secrets: [String],
        nowMs: Double
    ) -> (
        canonical: CanonicalMemoryBook,
        liveRecords: [MemoryRecord],
        seq: UInt64,
        editEvents: [(id: String, text: String, editedByUser: Bool)],
        layerEvents: [(id: String, layer: MemoryLayer)]
    ) {
        stateLock.lock()
        defer { stateLock.unlock() }

        self.botSummaries = botSummaries
        var editEvents: [(id: String, text: String, editedByUser: Bool)] = []
        var layerEvents: [(id: String, layer: MemoryLayer)] = []
        var nextShadowByID: [String: MemoryRecord] = [:]
        var canonicalItems: [CanonicalMemoryItem] = []

        for mem in book.memories {
            let safeText = Self.redact(mem.text, orderedSecrets: secrets)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !safeText.isEmpty else { continue }
            let hash = MemorySafety.retractionHash(safeText)
            guard !hash.isEmpty else { continue }

            let existing = recordShadowByID[mem.id]
            let isPinned = pinnedIDs.contains(mem.id) || (existing?.pinned == true && mem.deep != true)
            let layer: MemoryLayer
            if isPinned && mem.deep != true {
                layer = .pinned
            } else if mem.deep == true {
                layer = .deep
                pinnedIDs.remove(mem.id)
            } else {
                layer = .surface
            }

            let textChanged = existing != nil && existing?.text != safeText
            let layerChanged = existing != nil && existing?.layer != layer
            if textChanged {
                editEvents.append((mem.id, safeText, mem.editedByUser == true))
                tombstoneShadow.removeValue(forKey: hash)
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

            let record = MemoryRecord(
                id: mem.id,
                text: safeText,
                textSHA256: hash,
                layer: layer,
                pinned: layer == .pinned,
                kind: existing?.kind ?? "fact",
                topic: existing?.topic ?? "",
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

        // Seed any untimestamped suppressedHashes not already in tombstoneShadow
        for rawHash in suppressedHashes {
            let clean = rawHash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard MemorySafety.isSHA256Hex(clean),
                  tombstoneShadow[clean] == nil,
                  !nextShadowByID.values.contains(where: { $0.textSHA256 == clean }) else { continue }
            tombstoneShadow[clean] = MemoryTombstone(
                textSHA256: clean,
                memoryID: nil,
                deletedAtMs: nowMs,
                reason: "retracted"
            )
        }

        recordShadowByID = nextShadowByID
        lastSyncedMemories = book.memories
        lastSyncedBookDigest = Self.bookDigest(book)
        syncSequence &+= 1
        let seq = syncSequence

        let allTombstones = tombstoneShadow.values.sorted {
            if $0.deletedAtMs != $1.deletedAtMs { return $0.deletedAtMs > $1.deletedAtMs }
            return $0.textSHA256 < $1.textSHA256
        }
        var combinedHashes = Set(tombstoneShadow.keys)
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
            archived: archivedRecords.map(CanonicalMemoryItem.init(from:)),
            reviews: canonicalReviews,
            processed: book.processed,
            reviewFromDay: book.reviewFromDay,
            budgetDay: book.budgetDay,
            requests: book.requests,
            diaryRequests: book.diaryRequests,
            suppressedFlushHashes: combinedHashes.sorted(),
            tombstones: allTombstones
        )
        let liveRecords = Array(nextShadowByID.values) + archivedRecords
        return (canonical, liveRecords, seq, editEvents, layerEvents)
    }

    private func applyBackgroundPersist(
        canonical: CanonicalMemoryBook,
        liveRecords: [MemoryRecord],
        bots: [MemoryMirrorBot],
        secrets: [String],
        jsonDigest: String?,
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
            let updatedMeta = try? store.meta()
            stateLock.withLock { self.currentMeta = updatedMeta }
        } catch {
            // Best-effort DB write; canonical memory.json is already safely written on disk.
        }

        let isLatest = stateLock.withLock { sequence == syncSequence }
        if isLatest && !Disk.frozen {
            MemoryMarkdownMirror.sync(
                records: liveRecords,
                bots: bots,
                secrets: secrets,
                deskRoot: deskRoot
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
                deskRoot: self.deskRoot
            )
        }
    }

    private func checkpointAsync() {
        queue.async { [weak self] in
            guard let self, !Disk.frozen else { return }
            try? self.store.checkpoint()
        }
    }

    private func updateShadowState(
        liveRecords: [MemoryRecord],
        tombstones: [MemoryTombstone],
        meta: MemoryStoreMeta?,
        appBook: MemoryBook
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
        currentMeta = meta
        lastSyncedMemories = appBook.memories
        lastSyncedBookDigest = Self.bookDigest(appBook)
        stateLock.unlock()
    }

    // MARK: - Disk I/O Helpers

    private func loadCanonicalBookFromDisk(at url: URL) -> (book: CanonicalMemoryBook?, digest: String?, needsWrite: Bool) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return (nil, nil, false)
        }
        guard let data = try? Data(contentsOf: url) else {
            return (nil, nil, false)
        }
        let digest = Self.sha256Hex(data)
        if let decoded = try? CanonicalMemoryBook.decodeFlexible(from: data) {
            return (decoded, digest, false)
        }
        // Corrupt memory.json: preserve broken copy aside and let SQLite restore canonical JSON.
        if !Disk.frozen {
            let aside = url.deletingLastPathComponent()
                .appendingPathComponent("memory.broken-\(Int(Date().timeIntervalSince1970)).json")
            try? data.write(to: aside, options: .atomic)
        }
        return (nil, nil, true)
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
    private func writeCanonicalBookToDisk(_ book: CanonicalMemoryBook, at url: URL) -> String? {
        guard !Disk.frozen else { return nil }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(book)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return Self.sha256Hex(data)
        } catch {
            return nil
        }
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

    private static func shouldResetLeftoverDBAfterRestore(
        pendingToken: String,
        meta: MemoryStoreMeta,
        diskJSONDigest: String?
    ) -> Bool {
        let parts = pendingToken.split(separator: "|", maxSplits: 1)
        guard parts.count == 2 else { return false }
        let oldInstance = String(parts[0])
        let oldRevision = Int64(parts[1]) ?? -1
        let sameDB = (meta.instanceID == oldInstance && meta.revision == oldRevision)
        guard sameDB else { return false }
        if let diskJSONDigest {
            return diskJSONDigest != meta.lastSyncedJSONSHA256
        }
        return !meta.lastSyncedJSONSHA256.isEmpty
    }

    // MARK: - Model Mapping Helpers

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
