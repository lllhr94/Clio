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
        entries _: [Entry]
    ) {
        let slotKey = MemoryIndexSlotKey(chatKey: chatKey, leafID: leafID)
        let pending = PendingSlot(key: slotKey, chatName: chatName, leafTitle: leafTitle)
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
                    let decoder = JSONDecoder()
                    let leafTitleResult = self.readCommittedLeafTitle(chatKey: chatKey, leafID: leafID, decoder: decoder)
                    switch leafTitleResult {
                    case .missing:
                        try self.database.deleteChat(chatKey: chatKey, includingLeaves: false, leafID: leafID)
                    case .unreadable:
                        // Do not stamp a digest when the canonical leaves file is transient/unreadable.
                        return
                    case let .found(committedTitle):
                        let leafURL = self.teamRoot.appendingPathComponent(TeamModel.leafFile(chatKey, leafID))
                        guard let stamp = self.readFileStamp(at: leafURL) else {
                            if !FileManager.default.fileExists(atPath: leafURL.path) {
                                try self.database.deleteChat(chatKey: chatKey, includingLeaves: false, leafID: leafID)
                            }
                            return
                        }
                        let digest = Self.formatSlotDigest(stamp: stamp, title: committedTitle)
                        let secrets = Vault.allStrings()
                        try self.database.updateLeafTitle(
                            chatKey: chatKey,
                            leafID: leafID,
                            leafTitle: committedTitle,
                            slotDigest: digest,
                            secrets: secrets
                        )
                    }
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
            let decoder = JSONDecoder()
            for item in batch {
                let resolvedChatName = catalog?.first(where: { $0.key == item.key.chatKey })?.name ?? item.chatName
                switch readCommittedSlotSnapshot(
                    chatKey: item.key.chatKey,
                    leafID: item.key.leafID,
                    liveTitle: resolvedChatName,
                    expectedLeafTitle: nil,
                    decoder: decoder
                ) {
                case .missing:
                    try database.deleteChat(
                        chatKey: item.key.chatKey,
                        includingLeaves: false,
                        leafID: item.key.leafID.isEmpty ? nil : item.key.leafID
                    )
                case .transientOrUnreadable:
                    // Never stamp a disk digest onto an unreadable or stale memory snapshot.
                    continue
                case let .ready(committedEntries, committedLeafTitle, digest):
                    let records = Self.makeRecords(
                        from: committedEntries,
                        chatKey: item.key.chatKey,
                        chatName: resolvedChatName,
                        leafID: item.key.leafID,
                        leafTitle: committedLeafTitle
                    )
                    try database.replaceSlot(
                        chatKey: item.key.chatKey,
                        leafID: item.key.leafID,
                        records: records,
                        slotDigest: digest,
                        secrets: secrets
                    )
                }
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
            let secrets = Vault.allStrings()
            let hits = try database.search(query: query, context: context, secrets: secrets)
            if database.consumeUnredactedSecretDetected() {
                queue.async { [weak self] in
                    try? self?.rebuildFromDiskLocked(catalog: catalog)
                }
            }
            return hits
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
                switch readCommittedSlotSnapshot(
                    chatKey: slotKey.chatKey,
                    leafID: slotKey.leafID,
                    liveTitle: info.chatName,
                    expectedLeafTitle: slotKey.leafID.isEmpty ? nil : info.leafTitle,
                    decoder: decoder
                ) {
                case .missing:
                    let titleForDigest = slotKey.leafID.isEmpty ? info.chatName : info.leafTitle
                    try database.replaceSlot(
                        chatKey: slotKey.chatKey,
                        leafID: slotKey.leafID,
                        records: [],
                        slotDigest: Self.formatMissingDigest(title: titleForDigest),
                        secrets: secrets
                    )
                case .transientOrUnreadable:
                    continue
                case let .ready(entries, leafTitle, digest):
                    let records = Self.makeRecords(
                        from: entries,
                        chatKey: slotKey.chatKey,
                        chatName: info.chatName,
                        leafID: slotKey.leafID,
                        leafTitle: leafTitle
                    )
                    try database.replaceSlot(
                        chatKey: slotKey.chatKey,
                        leafID: slotKey.leafID,
                        records: records,
                        slotDigest: digest,
                        secrets: secrets
                    )
                }
            }
        }

        let catalogFingerprint = computeCatalogFingerprint(expectedSlots: expectedSlots)
        if state.sourceFingerprint != catalogFingerprint {
            try database.updateSourceFingerprint(catalogFingerprint)
        }
    }

    private func rebuildFromDiskLocked(catalog: [ChatDescriptor]) throws {
        ChatDisk.finishWrites()
        let secrets = Vault.allStrings()
        let snapshot = loadCanonicalSnapshot(catalog: catalog)
        try database.rebuild(
            records: snapshot.records,
            sourceFingerprint: snapshot.fingerprint,
            slotDigests: snapshot.slotDigests,
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

    private struct FileStamp: Equatable {
        let size: Int
        let mtimeMs: Int64
    }

    private enum DiskReadResult {
        case missing
        case unreadable
        case stable(Data, FileStamp)
    }

    private enum CommittedLeafTitleResult {
        case missing
        case unreadable
        case found(String)
    }

    private enum CommittedSlotSnapshot {
        case missing
        case transientOrUnreadable
        case ready(entries: [Entry], leafTitle: String, digest: String)
    }

    private struct CanonicalSnapshot {
        let records: [MemoryIndexRecord]
        let slotDigests: [MemoryIndexSlotKey: String]
        let fingerprint: String
    }

    private func buildExpectedSlots(catalog: [ChatDescriptor]) -> [MemoryIndexSlotKey: ExpectedSlot] {
        var slots: [MemoryIndexSlotKey: ExpectedSlot] = [:]
        let decoder = JSONDecoder()

        for chat in catalog {
            let liveKey = MemoryIndexSlotKey(chatKey: chat.key, leafID: "")
            let liveDigest = computeSlotDigest(chatKey: chat.key, leafID: "", title: chat.name)
            slots[liveKey] = ExpectedSlot(chatName: chat.name, leafTitle: "", digest: liveDigest)

            let leavesURL = teamRoot.appendingPathComponent(TeamModel.leafList(chat.key))
            if case let .stable(data, _) = readStableFile(at: leavesURL),
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

    private func readFileStamp(at url: URL) -> FileStamp? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attrs[.type] as? FileAttributeType) == .typeRegular else {
            return nil
        }
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let modified = (attrs[.modificationDate] as? Date) ?? .distantPast
        let mtimeMs = Int64(modified.timeIntervalSince1970 * 1000)
        return FileStamp(size: size, mtimeMs: mtimeMs)
    }

    private func readStableFile(at url: URL) -> DiskReadResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .missing
        }
        guard let stamp1 = readFileStamp(at: url),
              let data = try? Data(contentsOf: url),
              let stamp2 = readFileStamp(at: url),
              stamp1 == stamp2,
              data.count == stamp2.size else {
            return FileManager.default.fileExists(atPath: url.path) ? .unreadable : .missing
        }
        return .stable(data, stamp2)
    }

    private func readCommittedLeafTitle(chatKey: String, leafID: String, decoder: JSONDecoder) -> CommittedLeafTitleResult {
        let leavesURL = teamRoot.appendingPathComponent(TeamModel.leafList(chatKey))
        switch readStableFile(at: leavesURL) {
        case .missing:
            return .missing
        case .unreadable:
            return .unreadable
        case let .stable(data, _):
            guard let leaves = try? decoder.decode([StoredLeaf].self, from: data) else {
                return .unreadable
            }
            if let leaf = leaves.first(where: { $0.id == leafID }) {
                return .found(leaf.title)
            }
            return .missing
        }
    }

    private func readCommittedSlotSnapshot(
        chatKey: String,
        leafID: String,
        liveTitle: String,
        expectedLeafTitle: String?,
        decoder: JSONDecoder
    ) -> CommittedSlotSnapshot {
        let committedLeafTitle: String
        let digestTitle: String
        if leafID.isEmpty {
            committedLeafTitle = ""
            digestTitle = liveTitle
        } else if let expectedLeafTitle {
            committedLeafTitle = expectedLeafTitle
            digestTitle = expectedLeafTitle
        } else {
            switch readCommittedLeafTitle(chatKey: chatKey, leafID: leafID, decoder: decoder) {
            case .missing:
                return .missing
            case .unreadable:
                return .transientOrUnreadable
            case let .found(title):
                committedLeafTitle = title
                digestTitle = title
            }
        }

        let relPath = leafID.isEmpty ? Disk.chatFile(chatKey) : TeamModel.leafFile(chatKey, leafID)
        let url = teamRoot.appendingPathComponent(relPath)
        switch readStableFile(at: url) {
        case .missing:
            return .missing
        case .unreadable:
            return .transientOrUnreadable
        case let .stable(data, stamp):
            guard let entries = decodeEntriesLeniently(from: data, decoder: decoder) else {
                return .transientOrUnreadable
            }
            return .ready(
                entries: entries,
                leafTitle: committedLeafTitle,
                digest: Self.formatSlotDigest(stamp: stamp, title: digestTitle)
            )
        }
    }

    private func computeSlotDigest(chatKey: String, leafID: String, title: String) -> String {
        let relPath = leafID.isEmpty ? Disk.chatFile(chatKey) : TeamModel.leafFile(chatKey, leafID)
        let url = teamRoot.appendingPathComponent(relPath)
        guard let stamp = readFileStamp(at: url) else {
            return Self.formatMissingDigest(title: title)
        }
        return Self.formatSlotDigest(stamp: stamp, title: title)
    }

    private static func formatSlotDigest(stamp: FileStamp, title: String) -> String {
        let titleHash = sha256Hex(Data(title.utf8))
        return "\(stamp.size):\(stamp.mtimeMs)|\(titleHash)"
    }

    private static func formatMissingDigest(title: String) -> String {
        let titleHash = sha256Hex(Data(title.utf8))
        return "missing|\(titleHash)"
    }

    private func computeCatalogFingerprint(expectedSlots: [MemoryIndexSlotKey: ExpectedSlot]) -> String {
        computeCatalogFingerprint(digests: expectedSlots.mapValues(\.digest))
    }

    private func computeCatalogFingerprint(digests: [MemoryIndexSlotKey: String]) -> String {
        let lines = digests.keys.sorted { lhs, rhs in
            if lhs.chatKey != rhs.chatKey { return lhs.chatKey < rhs.chatKey }
            return lhs.leafID < rhs.leafID
        }.compactMap { key -> String? in
            guard let digest = digests[key] else { return nil }
            return "\(key.chatKey)~\(key.leafID)=\(digest)"
        }
        return Self.sha256Hex(Data(lines.joined(separator: "\n").utf8))
    }

    private static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func loadCanonicalSnapshot(catalog: [ChatDescriptor]) -> CanonicalSnapshot {
        var all: [MemoryIndexRecord] = []
        var digests: [MemoryIndexSlotKey: String] = [:]
        let decoder = JSONDecoder()

        for chat in catalog {
            let liveKey = MemoryIndexSlotKey(chatKey: chat.key, leafID: "")
            switch readCommittedSlotSnapshot(
                chatKey: chat.key,
                leafID: "",
                liveTitle: chat.name,
                expectedLeafTitle: nil,
                decoder: decoder
            ) {
            case .missing:
                digests[liveKey] = Self.formatMissingDigest(title: chat.name)
            case .transientOrUnreadable:
                break
            case let .ready(liveEntries, _, digest):
                digests[liveKey] = digest
                all.append(contentsOf: Self.makeRecords(
                    from: liveEntries,
                    chatKey: chat.key,
                    chatName: chat.name,
                    leafID: "",
                    leafTitle: ""
                ))
            }

            let leavesURL = teamRoot.appendingPathComponent(TeamModel.leafList(chat.key))
            if case let .stable(data, _) = readStableFile(at: leavesURL),
               let leaves = try? decoder.decode([StoredLeaf].self, from: data) {
                for leaf in leaves {
                    let leafKey = MemoryIndexSlotKey(chatKey: chat.key, leafID: leaf.id)
                    switch readCommittedSlotSnapshot(
                        chatKey: chat.key,
                        leafID: leaf.id,
                        liveTitle: chat.name,
                        expectedLeafTitle: leaf.title,
                        decoder: decoder
                    ) {
                    case .missing:
                        digests[leafKey] = Self.formatMissingDigest(title: leaf.title)
                    case .transientOrUnreadable:
                        break
                    case let .ready(leafEntries, leafTitle, digest):
                        digests[leafKey] = digest
                        all.append(contentsOf: Self.makeRecords(
                            from: leafEntries,
                            chatKey: chat.key,
                            chatName: chat.name,
                            leafID: leaf.id,
                            leafTitle: leafTitle
                        ))
                    }
                }
            }
        }
        let fingerprint = computeCatalogFingerprint(digests: digests)
        return CanonicalSnapshot(records: all, slotDigests: digests, fingerprint: fingerprint)
    }

    private struct LenientEntry: Decodable {
        let entry: Entry?
        init(from decoder: Decoder) throws {
            entry = try? Entry(from: decoder)
        }
    }

    private func decodeEntriesLeniently(from data: Data, decoder: JSONDecoder) -> [Entry]? {
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
        var slotHasTainted = false

        for entry in entries {
            if entry.isTainted || (entry.message.role == .tool && Taint.reads(entry.message.toolName ?? "")) {
                slotHasTainted = true
            }
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
                        leafTainted: false,
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
                        leafTainted: false,
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
        if slotHasTainted || result.contains(where: { $0.tainted }) {
            for index in result.indices {
                result[index].leafTainted = true
            }
        }
        return result
    }
}
