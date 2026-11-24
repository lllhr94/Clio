import AgentKit
import Craft
import CryptoKit
import Foundation

/// Coordinates the derived, read-only rebuildable SQLite3 + FTS5 conversation index (`clio-index.db`)
/// completely off the main thread. Canonical JSON files under `Disk.root/chats/` remain the sole source of truth.
final class MemoryIndexService: @unchecked Sendable {
    struct ChatDescriptor: Sendable, Equatable {
        let key: String
        let name: String
    }

    private struct PendingSlot {
        let key: MemoryIndexSlotKey
        let chatName: String
        let leafTitle: String
        let entries: [Entry]
    }

    private struct ExpectedSlot {
        let chatName: String
        let leafTitle: String
        let digest: String
    }

    private struct StoredLeaf: Decodable {
        let id: String
        let title: String
    }

    static let shared = MemoryIndexService()

    static var defaultDatabaseURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches
            .appendingPathComponent("ClioIndex", isDirectory: true)
            .appendingPathComponent("clio-index.db")
    }

    private let database: MemoryIndexDatabase
    private let teamRoot: URL
    private let queue = DispatchQueue(label: "clio.memory-index", qos: .utility)
    private let pendingLock = NSLock()
    private var pendingSlots: [MemoryIndexSlotKey: PendingSlot] = [:]
    private var scheduledFlushItem: DispatchWorkItem?

    init(databaseURL: URL = MemoryIndexService.defaultDatabaseURL, teamRoot: URL = Disk.root) {
        self.database = MemoryIndexDatabase(databaseURL: databaseURL)
        self.teamRoot = teamRoot
    }

    /// Reconciles `clio-index.db` against canonical JSONs on disk without touching the main thread.
    func warmup(catalog: [ChatDescriptor]) {
        queue.async { [weak self] in
            self?.reconcileCatalogLocked(catalog: catalog)
        }
    }

    /// Coalesces an incremental live-chat or leaf update and writes only that slot on the background index queue.
    func scheduleSync(
        chatKey: String,
        chatName: String,
        leafID: String = "",
        leafTitle: String = "",
        entries: [Entry]
    ) {
        let slotKey = MemoryIndexSlotKey(chatKey: chatKey, leafID: leafID)
        let pending = PendingSlot(key: slotKey, chatName: chatName, leafTitle: leafTitle, entries: entries)
        pendingLock.lock()
        pendingSlots[slotKey] = pending
        if scheduledFlushItem == nil {
            let item = DispatchWorkItem { [weak self] in
                self?.flushPendingSlotsLocked(catalog: nil)
            }
            scheduledFlushItem = item
            pendingLock.unlock()
            queue.asyncAfter(deadline: .now() + .milliseconds(120), execute: item)
        } else {
            pendingLock.unlock()
        }
    }

    func scheduleUpdateLeafTitle(chatKey: String, leafID: String, title: String, catalog: [ChatDescriptor]) {
        queue.async { [weak self] in
            guard let self else { return }
            self.flushPendingSlotsLocked(catalog: catalog)
            do {
                _ = try self.database.openOrRecover()
                if self.database.needsRebuildFromSource {
                    try self.rebuildFromDiskLocked(catalog: catalog)
                } else {
                    ChatDisk.finishWrites()
                    let digest = self.computeSlotDigest(chatKey: chatKey, leafID: leafID, title: title)
                    let secrets = Vault.allStrings()
                    try self.database.updateLeafTitle(
                        chatKey: chatKey,
                        leafID: leafID,
                        leafTitle: title,
                        slotDigest: digest,
                        secrets: secrets
                    )
                }
            } catch {
                // Derived index is strictly fail-safe and rebuilds automatically on next access.
            }
        }
    }

    func scheduleDeleteChat(chatKey: String, includingLeaves: Bool = true, leafID: String? = nil, catalog: [ChatDescriptor]) {
        pendingLock.lock()
        if let leafID {
            pendingSlots.removeValue(forKey: MemoryIndexSlotKey(chatKey: chatKey, leafID: leafID))
        } else if includingLeaves {
            pendingSlots = pendingSlots.filter { $0.key.chatKey != chatKey }
        } else {
            pendingSlots.removeValue(forKey: MemoryIndexSlotKey(chatKey: chatKey, leafID: ""))
        }
        pendingLock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            self.flushPendingSlotsLocked(catalog: catalog)
            do {
                _ = try self.database.openOrRecover()
                if self.database.needsRebuildFromSource {
                    try self.rebuildFromDiskLocked(catalog: catalog)
                } else {
                    ChatDisk.finishWrites()
                    try self.database.deleteChat(
                        chatKey: chatKey,
                        includingLeaves: includingLeaves,
                        leafID: leafID
                    )
                }
            } catch {
                // Derived index is strictly fail-safe.
            }
        }
    }

    /// Removes derived index files cleanly (e.g. after backup restore) so next open/search rebuilds from restored JSONs.
    func resetForRestore() {
        pendingLock.lock()
        pendingSlots.removeAll()
        scheduledFlushItem?.cancel()
        scheduledFlushItem = nil
        pendingLock.unlock()

        queue.async { [weak self] in
            self?.database.destroyFiles()
        }
    }

    /// Flushes pending incremental writes, reconciles stale/missing slots only, and executes SQL-isolated search.
    func search(
        query: String,
        context: MemoryAccessContext,
        catalog: [ChatDescriptor]
    ) async -> [MemoryIndexHit] {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: [])
                    return
                }
                let hits = self.performSearchLocked(query: query, context: context, catalog: catalog)
                continuation.resume(returning: hits)
            }
        }
    }

    func diagnostics() async -> MemoryIndexBuildState {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: MemoryIndexBuildState(
                        state: "missing",
                        schemaVersion: 0,
                        lastBuiltAt: "",
                        sourceFingerprint: "",
                        indexedCount: 0,
                        fts5Active: MemoryIndexDatabase.isFTS5Supported
                    ))
                    return
                }
                do {
                    _ = try self.database.openOrRecover()
                    let state = try self.database.buildState()
                    continuation.resume(returning: state)
                } catch {
                    continuation.resume(returning: MemoryIndexBuildState(
                        state: "error",
                        schemaVersion: 0,
                        lastBuiltAt: "",
                        sourceFingerprint: "",
                        indexedCount: 0,
                        fts5Active: MemoryIndexDatabase.isFTS5Supported
                    ))
                }
            }
        }
    }

    // MARK: - Background Worker Execution (runs only on `queue`)

    private func flushPendingSlotsLocked(catalog: [ChatDescriptor]?) {
        let batch = drainPendingSlots()
        guard !batch.isEmpty else { return }

        do {
            _ = try database.openOrRecover()
            if database.needsRebuildFromSource, let catalog {
                try rebuildFromDiskLocked(catalog: catalog)
                return
            }
            ChatDisk.finishWrites()
            let secrets = Vault.allStrings()
            for item in batch {
                let titleForDigest = item.key.leafID.isEmpty ? item.chatName : item.leafTitle
                let digest = computeSlotDigest(chatKey: item.key.chatKey, leafID: item.key.leafID, title: titleForDigest)
                let records = Self.makeRecords(
                    from: item.entries,
                    chatKey: item.key.chatKey,
                    chatName: item.chatName,
                    leafID: item.key.leafID,
                    leafTitle: item.leafTitle
                )
                try database.replaceSlot(
                    chatKey: item.key.chatKey,
                    leafID: item.key.leafID,
                    records: records,
                    slotDigest: digest,
                    secrets: secrets
                )
            }
        } catch {
            // Leave recovery for next search/warmup.
        }
    }

    private func reconcileCatalogLocked(catalog: [ChatDescriptor]) {
        do {
            try reconcileIfNeededThrowingLocked(catalog: catalog)
        } catch {
            // Self-heals on next open/search.
        }
    }

    private func performSearchLocked(
        query: String,
        context: MemoryAccessContext,
        catalog: [ChatDescriptor]
    ) -> [MemoryIndexHit] {
        do {
            try reconcileIfNeededThrowingLocked(catalog: catalog)
            return try database.search(query: query, context: context)
        } catch {
            return []
        }
    }

    private func reconcileIfNeededThrowingLocked(catalog: [ChatDescriptor]) throws {
        flushPendingSlotsLocked(catalog: catalog)
        _ = try database.openOrRecover()
        ChatDisk.finishWrites()
        let state = try database.buildState()
        if database.needsRebuildFromSource || state.state != "ready" {
            try rebuildFromDiskLocked(catalog: catalog)
            return
        }

        let expectedSlots = buildExpectedSlots(catalog: catalog)
        let storedSlots = try database.readSlotVersions()
        let validChatKeys = Set(catalog.map(\.key))

        let hasMissingChat = storedSlots.keys.contains { !validChatKeys.contains($0.chatKey) }
        if hasMissingChat {
            try database.pruneMissingChats(validChatKeys: validChatKeys)
        }

        for slotKey in storedSlots.keys where validChatKeys.contains(slotKey.chatKey) && expectedSlots[slotKey] == nil {
            if slotKey.leafID.isEmpty {
                try database.deleteChat(chatKey: slotKey.chatKey, includingLeaves: false)
            } else {
                try database.deleteChat(chatKey: slotKey.chatKey, includingLeaves: false, leafID: slotKey.leafID)
            }
        }

        let dirtyKeys = expectedSlots.keys.filter { storedSlots[$0] != expectedSlots[$0]?.digest }
        if !dirtyKeys.isEmpty {
            let secrets = Vault.allStrings()
            let decoder = JSONDecoder()
            for slotKey in dirtyKeys {
                guard let info = expectedSlots[slotKey] else { continue }
                let relPath = slotKey.leafID.isEmpty
                    ? Disk.chatFile(slotKey.chatKey)
                    : TeamModel.leafFile(slotKey.chatKey, slotKey.leafID)
                let url = teamRoot.appendingPathComponent(relPath)
                let entries = decodeEntriesLeniently(at: url, decoder: decoder) ?? []
                let records = Self.makeRecords(
                    from: entries,
                    chatKey: slotKey.chatKey,
                    chatName: info.chatName,
                    leafID: slotKey.leafID,
                    leafTitle: info.leafTitle
                )
                try database.replaceSlot(
                    chatKey: slotKey.chatKey,
                    leafID: slotKey.leafID,
                    records: records,
                    slotDigest: info.digest,
                    secrets: secrets
                )
            }
        }

        let catalogFingerprint = computeCatalogFingerprint(expectedSlots: expectedSlots)
        if state.sourceFingerprint != catalogFingerprint {
            try database.updateSourceFingerprint(catalogFingerprint)
        }
    }

    private func rebuildFromDiskLocked(catalog: [ChatDescriptor]) throws {
        ChatDisk.finishWrites()
        let expectedSlots = buildExpectedSlots(catalog: catalog)
        let secrets = Vault.allStrings()
        let allRecords = loadAllCanonicalRecords(catalog: catalog)
        let slotDigests = expectedSlots.mapValues(\.digest)
        let fingerprint = computeCatalogFingerprint(expectedSlots: expectedSlots)
        try database.rebuild(
            records: allRecords,
            sourceFingerprint: fingerprint,
            slotDigests: slotDigests,
            secrets: secrets
        )
    }

    private func drainPendingSlots() -> [PendingSlot] {
        pendingLock.lock()
        scheduledFlushItem?.cancel()
        scheduledFlushItem = nil
        let values = Array(pendingSlots.values)
        pendingSlots.removeAll()
        pendingLock.unlock()
        return values
    }

    // MARK: - Read-Only Canonical JSON Scanning & Digests

    private func buildExpectedSlots(catalog: [ChatDescriptor]) -> [MemoryIndexSlotKey: ExpectedSlot] {
        var slots: [MemoryIndexSlotKey: ExpectedSlot] = [:]
        let decoder = JSONDecoder()

        for chat in catalog {
            let liveKey = MemoryIndexSlotKey(chatKey: chat.key, leafID: "")
            let liveDigest = computeSlotDigest(chatKey: chat.key, leafID: "", title: chat.name)
            slots[liveKey] = ExpectedSlot(chatName: chat.name, leafTitle: "", digest: liveDigest)

            let leavesURL = teamRoot.appendingPathComponent(TeamModel.leafList(chat.key))
            if let data = try? Data(contentsOf: leavesURL),
               let leaves = try? decoder.decode([StoredLeaf].self, from: data) {
                for leaf in leaves {
                    let leafKey = MemoryIndexSlotKey(chatKey: chat.key, leafID: leaf.id)
                    let leafDigest = computeSlotDigest(chatKey: chat.key, leafID: leaf.id, title: leaf.title)
                    slots[leafKey] = ExpectedSlot(chatName: chat.name, leafTitle: leaf.title, digest: leafDigest)
                }
            }
        }
        return slots
    }

    private func computeSlotDigest(chatKey: String, leafID: String, title: String) -> String {
        let relPath = leafID.isEmpty ? Disk.chatFile(chatKey) : TeamModel.leafFile(chatKey, leafID)
        let url = teamRoot.appendingPathComponent(relPath)
        let titleHash = Self.sha256Hex(Data(title.utf8))
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
              values.isRegularFile == true else {
            return "missing|\(titleHash)"
        }
        let size = values.fileSize ?? 0
        let mtimeMs = Int64(((values.contentModificationDate ?? .distantPast).timeIntervalSince1970) * 1000)
        return "\(size):\(mtimeMs)|\(titleHash)"
    }

    private func computeCatalogFingerprint(expectedSlots: [MemoryIndexSlotKey: ExpectedSlot]) -> String {
        let lines = expectedSlots.keys.sorted { lhs, rhs in
            if lhs.chatKey != rhs.chatKey { return lhs.chatKey < rhs.chatKey }
            return lhs.leafID < rhs.leafID
        }.compactMap { key -> String? in
            guard let expected = expectedSlots[key] else { return nil }
            return "\(key.chatKey)~\(key.leafID)=\(expected.digest)"
        }
        return Self.sha256Hex(Data(lines.joined(separator: "\n").utf8))
    }

    private static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func loadAllCanonicalRecords(catalog: [ChatDescriptor]) -> [MemoryIndexRecord] {
        var all: [MemoryIndexRecord] = []
        let decoder = JSONDecoder()

        for chat in catalog {
            let liveURL = teamRoot.appendingPathComponent(Disk.chatFile(chat.key))
            if let liveEntries = decodeEntriesLeniently(at: liveURL, decoder: decoder) {
                all.append(contentsOf: Self.makeRecords(
                    from: liveEntries,
                    chatKey: chat.key,
                    chatName: chat.name,
                    leafID: "",
                    leafTitle: ""
                ))
            }

            let leavesURL = teamRoot.appendingPathComponent(TeamModel.leafList(chat.key))
            if let data = try? Data(contentsOf: leavesURL),
               let leaves = try? decoder.decode([StoredLeaf].self, from: data) {
                for leaf in leaves {
                    let leafURL = teamRoot.appendingPathComponent(TeamModel.leafFile(chat.key, leaf.id))
                    if let leafEntries = decodeEntriesLeniently(at: leafURL, decoder: decoder) {
                        all.append(contentsOf: Self.makeRecords(
                            from: leafEntries,
                            chatKey: chat.key,
                            chatName: chat.name,
                            leafID: leaf.id,
                            leafTitle: leaf.title
                        ))
                    }
                }
            }
        }
        return all
    }

    private struct LenientEntry: Decodable {
        let entry: Entry?
        init(from decoder: Decoder) throws {
            entry = try? Entry(from: decoder)
        }
    }

    private func decodeEntriesLeniently(at url: URL, decoder: JSONDecoder) -> [Entry]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let entries = try? decoder.decode([Entry].self, from: data) {
            return entries
        }
        if let lenient = try? decoder.decode([LenientEntry].self, from: data) {
            return lenient.compactMap(\.entry)
        }
        return nil
    }

    static func makeRecords(
        from entries: [Entry],
        chatKey: String,
        chatName: String,
        leafID: String = "",
        leafTitle: String = ""
    ) -> [MemoryIndexRecord] {
        var result: [MemoryIndexRecord] = []
        var turnHasExplicitTaint = false
        var legacySawUntrusted = false
        var inDelegatedTurn = false

        for entry in entries {
            if entry.fold == true { continue }
            switch entry.message.role {
            case .user:
                let delegated = entry.delegated == true || MemorySafety.isLegacyDelegationText(entry.message.text)
                let explicitlyTainted = entry.tainted == true
                if delegated {
                    inDelegatedTurn = true
                    if explicitlyTainted { turnHasExplicitTaint = true }
                } else if explicitlyTainted {
                    turnHasExplicitTaint = true
                    inDelegatedTurn = false
                } else {
                    turnHasExplicitTaint = false
                    inDelegatedTurn = false
                }

                let text = entry.message.text
                guard entry.message.toolCalls.isEmpty,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                result.append(
                    MemoryIndexRecord(
                        chatKey: chatKey,
                        chatName: chatName,
                        leafID: leafID,
                        leafTitle: leafTitle,
                        entryID: entry.id,
                        role: "user",
                        atMs: entry.at,
                        tainted: explicitlyTainted,
                        delegated: delegated,
                        isNote: entry.note == true,
                        text: text
                    )
                )
            case .tool:
                if entry.tainted != true && Taint.reads(entry.message.toolName ?? "") {
                    legacySawUntrusted = true
                } else if entry.tainted == true {
                    turnHasExplicitTaint = true
                }
                continue
            case .assistant:
                if entry.tainted == true {
                    turnHasExplicitTaint = true
                }
                let effectiveTainted = entry.tainted == true || turnHasExplicitTaint || legacySawUntrusted
                let effectiveDelegated = entry.delegated == true || inDelegatedTurn
                let text = entry.message.text
                guard entry.message.toolCalls.isEmpty,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                result.append(
                    MemoryIndexRecord(
                        chatKey: chatKey,
                        chatName: chatName,
                        leafID: leafID,
                        leafTitle: leafTitle,
                        entryID: entry.id,
                        role: "assistant",
                        atMs: entry.at,
                        tainted: effectiveTainted,
                        delegated: effectiveDelegated,
                        isNote: entry.note == true,
                        text: text
                    )
                )
            }
        }
        return result
    }
}
