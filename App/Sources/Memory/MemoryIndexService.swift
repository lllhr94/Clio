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

    private struct SlotKey: Hashable {
        let chatKey: String
        let leafID: String
    }

    private struct PendingSlot {
        let key: SlotKey
        let chatName: String
        let leafTitle: String
        let entries: [Entry]
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
    private var pendingSlots: [SlotKey: PendingSlot] = [:]
    private var scheduledFlushItem: DispatchWorkItem?

    init(databaseURL: URL = MemoryIndexService.defaultDatabaseURL, teamRoot: URL = Disk.root) {
        self.database = MemoryIndexDatabase(databaseURL: databaseURL)
        self.teamRoot = teamRoot
    }

    /// Reconciles `clio-index.db` against canonical JSONs on disk without touching the main thread.
    func warmup(catalog: [ChatDescriptor]) {
        queue.async { [weak self] in
            self?.reconcileAndFlushLocked(catalog: catalog)
        }
    }

    /// Coalesces an incremental live-chat or leaf update and writes it on the background index queue.
    func scheduleSync(
        chatKey: String,
        chatName: String,
        leafID: String = "",
        leafTitle: String = "",
        entries: [Entry]
    ) {
        let slotKey = SlotKey(chatKey: chatKey, leafID: leafID)
        let pending = PendingSlot(key: slotKey, chatName: chatName, leafTitle: leafTitle, entries: entries)
        pendingLock.lock()
        pendingSlots[slotKey] = pending
        if scheduledFlushItem == nil {
            let item = DispatchWorkItem { [weak self] in
                self?.flushPendingSlots()
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
                    let fp = self.computeSourceFingerprint(catalog: catalog)
                    try self.database.updateLeafTitle(chatKey: chatKey, leafID: leafID, leafTitle: title, sourceFingerprint: fp)
                }
            } catch {
                // Derived index is strictly fail-safe and rebuilds automatically on next access.
            }
        }
    }

    func scheduleDeleteChat(chatKey: String, includingLeaves: Bool = true, leafID: String? = nil, catalog: [ChatDescriptor]) {
        pendingLock.lock()
        if let leafID {
            pendingSlots.removeValue(forKey: SlotKey(chatKey: chatKey, leafID: leafID))
        } else if includingLeaves {
            pendingSlots = pendingSlots.filter { $0.key.chatKey != chatKey }
        } else {
            pendingSlots.removeValue(forKey: SlotKey(chatKey: chatKey, leafID: ""))
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
                    let fp = self.computeSourceFingerprint(catalog: catalog)
                    try self.database.deleteChat(
                        chatKey: chatKey,
                        includingLeaves: includingLeaves,
                        leafID: leafID,
                        sourceFingerprint: fp
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

    /// Flushes pending incremental writes, self-heals/rebuilds if missing, corrupt, or stale, and executes SQL-isolated search.
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

    private func flushPendingSlots() {
        flushPendingSlotsLocked(catalog: nil)
    }

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
            let fingerprint = catalog.map { computeSourceFingerprint(catalog: $0) }
            for item in batch {
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
                    sourceFingerprint: fingerprint,
                    secrets: secrets
                )
            }
        } catch {
            // Leave recovery for next search/warmup.
        }
    }

    private func reconcileAndFlushLocked(catalog: [ChatDescriptor]) {
        flushPendingSlotsLocked(catalog: catalog)
        do {
            _ = try database.openOrRecover()
            ChatDisk.finishWrites()
            let diskFingerprint = computeSourceFingerprint(catalog: catalog)
            let state = try database.buildState()
            if database.needsRebuildFromSource || state.state != "ready" || state.sourceFingerprint != diskFingerprint {
                try rebuildFromDiskLocked(catalog: catalog, precomputedFingerprint: diskFingerprint)
            }
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
            flushPendingSlotsLocked(catalog: catalog)
            _ = try database.openOrRecover()
            ChatDisk.finishWrites()
            let diskFingerprint = computeSourceFingerprint(catalog: catalog)
            let state = try database.buildState()
            if database.needsRebuildFromSource || state.state != "ready" || state.sourceFingerprint != diskFingerprint {
                try rebuildFromDiskLocked(catalog: catalog, precomputedFingerprint: diskFingerprint)
            }
            return try database.search(query: query, context: context)
        } catch {
            return []
        }
    }

    private func rebuildFromDiskLocked(
        catalog: [ChatDescriptor],
        precomputedFingerprint: String? = nil
    ) throws {
        ChatDisk.finishWrites()
        let fingerprint = precomputedFingerprint ?? computeSourceFingerprint(catalog: catalog)
        let secrets = Vault.allStrings()
        let allRecords = loadAllCanonicalRecords(catalog: catalog)
        try database.rebuild(records: allRecords, sourceFingerprint: fingerprint, secrets: secrets)
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

    // MARK: - Read-Only Canonical JSON Scanning

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

    private func computeSourceFingerprint(catalog: [ChatDescriptor]) -> String {
        var lines: [String] = []
        let sortedCatalog = catalog.sorted { $0.key < $1.key }
        for chat in sortedCatalog {
            lines.append("c:\(chat.key)=\(chat.name)")
        }

        let chatsDir = teamRoot.appendingPathComponent("chats", isDirectory: true)
        let fm = FileManager.default
        if let items = try? fm.contentsOfDirectory(
            at: chatsDir,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            let sortedItems = items.sorted { $0.lastPathComponent < $1.lastPathComponent }
            for item in sortedItems {
                let name = item.lastPathComponent
                guard name.hasSuffix(".json"),
                      !name.hasSuffix("~options.json"),
                      !name.hasSuffix("~summary.json"),
                      !name.contains(".broken-") else { continue }
                guard let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                      values.isRegularFile == true else { continue }
                let size = values.fileSize ?? 0
                let mtimeMs = Int64(((values.contentModificationDate ?? .distantPast).timeIntervalSince1970) * 1000)
                lines.append("f:\(name):\(size):\(mtimeMs)")
            }
        }

        let payload = lines.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
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
