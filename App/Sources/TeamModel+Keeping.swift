import AgentKit
import Craft
import SwiftUI
import UserNotifications
import UIKit

extension TeamModel {
    // MARK: Keeping

    struct InitialData: Sendable {
        let settings: TeamSettings
        let bots: [BotInfo]
        let rooms: [RoomInfo]
        let memory: MemoryBook
        let suppressedMemoryHashes: Set<String>
        let pinnedMemoryIDs: Set<String>
        let laters: [Later]
        let routines: [Routine]
        let queued: [String: [StoredQueuedMessage]]

        nonisolated static func read() -> Self {
            let barrierBlocked = QueuedStore.reconcilePreRestoreBarrier(teamRoot: Disk.root)
            QueuedStore.reconcilePendingLeafOpens(teamRoot: Disk.root)
            let settings = Disk.load(TeamSettings.self, "settings.json") ?? TeamSettings()
            let botsIndex = loadIndex([BotInfo].self, "bots.json")
            let roomsIndex = loadIndex([RoomInfo].self, "rooms.json")
            let bots = botsIndex.value ?? []
            let rooms = roomsIndex.value ?? []
            let memoryBoot = MemoryStoreBridge.shared.bootstrapOnLaunch(
                bots: bots,
                mainBotId: settings.mainBotId ?? bots.first?.id
            )
            let memory = memoryBoot.book
            let laters = Disk.load([Later].self, "later.json") ?? []
            let routines = Disk.load([Routine].self, "routines.json") ?? []
            let rawSlots = QueuedStore.loadAllSlots()
            let blockedSlots = QueuedStore.loadBlockedSlots().union(barrierBlocked)

            let queued = reconcileQueued(
                rawSlots,
                blockedSlots: blockedSlots,
                bots: bots,
                rooms: rooms,
                botsReadable: botsIndex.readable,
                roomsReadable: roomsIndex.readable
            )

            return Self(
                settings: settings,
                bots: bots,
                rooms: rooms,
                memory: memory,
                suppressedMemoryHashes: memoryBoot.suppressedHashes,
                pinnedMemoryIDs: memoryBoot.pinnedIDs,
                laters: laters,
                routines: routines,
                queued: queued
            )
        }

        private struct LeafID: Decodable { let id: String }

        private nonisolated static func loadIndex<Value: Decodable>(_ type: Value.Type, _ name: String) -> (value: Value?, readable: Bool) {
            let url = Disk.url(name)
            guard FileManager.default.fileExists(atPath: url.path) else { return (nil, true) }
            guard let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode(type, from: data) else {
                return (nil, false)
            }
            return (decoded, true)
        }

        private nonisolated static func reconcileQueued(
            _ raw: [String: StoredQueuedSlot],
            blockedSlots: Set<String>,
            bots: [BotInfo],
            rooms: [RoomInfo],
            botsReadable: Bool,
            roomsReadable: Bool
        ) -> [String: [StoredQueuedMessage]] {
            // Clear stale blocked markers whose slot folders are already gone.
            for slotKey in blockedSlots where raw[slotKey] == nil {
                QueuedStore.clearBlockedSlot(slotKey)
            }
            guard !raw.isEmpty else { return [:] }
            let baseKeys = bots.map { TeamModel.key(bot: $0.id) } + rooms.map { TeamModel.key(room: $0.id) }
            let validBaseKeys = Set(baseKeys)
            var validLeafKeys: Set<String> = []
            var leavesByBase: [String: [String]] = [:]
            var leafIndexReadable: [String: Bool] = [:]
            for base in baseKeys {
                let index = loadIndex([LeafID].self, TeamModel.leafList(base))
                leafIndexReadable[base] = index.readable
                let ids = (index.value ?? []).map(\.id)
                leavesByBase[base] = ids
                for leafId in ids {
                    validLeafKeys.insert(TeamModel.threadKey(base, leaf: leafId))
                }
            }

            let fm = FileManager.default
            var kept: [String: [StoredQueuedMessage]] = [:]
            for (chatKey, slot) in raw {
                let parts = chatKey.split(separator: "~", maxSplits: 1)
                let isLeafSlot = parts.count == 2
                let baseKey = String(parts[0])
                let baseIndexReadable = baseKey.hasPrefix("bot-") ? botsReadable : roomsReadable
                let existsInIndex: Bool
                let indexReadable: Bool
                if isLeafSlot {
                    existsInIndex = validLeafKeys.contains(chatKey)
                    let baseExists = validBaseKeys.contains(baseKey)
                    let leafReadable = baseExists ? (leafIndexReadable[baseKey] ?? false) : baseIndexReadable
                    indexReadable = baseIndexReadable && leafReadable
                } else {
                    existsInIndex = validBaseKeys.contains(chatKey)
                    indexReadable = baseIndexReadable
                }

                let chatFileURL = Disk.url(Disk.chatFile(chatKey))
                let chatFileExists = fm.fileExists(atPath: chatFileURL.path)
                let loadedEntries: [Entry]?
                if !chatFileExists {
                    loadedEntries = []
                } else if (try? Data(contentsOf: chatFileURL)) != nil {
                    loadedEntries = Disk.loadChat(chatKey)
                } else {
                    loadedEntries = nil
                }

                let disposition = QueuedMessageStore.evaluateSlot(
                    existsInIndex: existsInIndex,
                    indexReadable: indexReadable,
                    chatFileExists: chatFileExists,
                    anchor: slot.anchor,
                    chatEntryIds: loadedEntries?.map(\.id),
                    isBlockedByRestore: blockedSlots.contains(chatKey)
                )

                switch disposition {
                case .deleteOrphan:
                    QueuedStore.saveDetached([], for: chatKey)
                    continue
                case .retryIsolation:
                    let report = QueuedStore.isolateSlot(chatKey)
                    if report.failedMessages == 0 {
                        QueuedStore.clearBlockedSlot(chatKey)
                        if report.isolatedMessages > 0 {
                            let exportHint = report.readableExportSucceeded
                                ? Words.t("并另存到书案「恢复前排队」")
                                : Words.t("（导出到书案失败，原始副本留在应用隔离目录）")
                            DispatchQueue.main.async {
                                Diag.note("启动检查：已完成 \(chatKey) 恢复前 \(report.isolatedMessages) 条排队消息的隔离\(exportHint)。")
                            }
                        }
                    } else {
                        DispatchQueue.main.async {
                            Diag.note("启动检查：\(chatKey) 的 \(report.failedMessages) 条恢复前排队消息仍未能移出，已继续拦截不会自动发出。")
                        }
                    }
                    continue
                case .preserveUnreadable:
                    DispatchQueue.main.async {
                        Diag.note("启动检查：\(chatKey) 的对话索引暂时不可读，已保留排队文件未清理。")
                    }
                    continue
                case .isolateMismatched:
                    // If a crash occurred right after shelving/opening a leaf (moving the queue to a sibling slot)
                    // and before clearing the source slot, every item is already safely in the sibling slot: clear without exporting.
                    let siblingIds: Set<UUID>
                    if isLeafSlot {
                        siblingIds = Set(raw[baseKey]?.items.map(\.id) ?? [])
                    } else {
                        let leafIds = leavesByBase[chatKey] ?? []
                        var ids: Set<UUID> = []
                        for leafId in leafIds {
                            let leafKey = TeamModel.threadKey(chatKey, leaf: leafId)
                            if let leafSlot = raw[leafKey] {
                                ids.formUnion(leafSlot.items.map(\.id))
                            }
                        }
                        siblingIds = ids
                    }
                    if !slot.items.isEmpty && slot.items.allSatisfy({ siblingIds.contains($0.id) }) {
                        QueuedStore.saveDetached([], for: chatKey)
                        continue
                    }
                    let report = QueuedStore.isolateSlot(chatKey)
                    if report.isolatedMessages > 0 {
                        let exportHint = report.readableExportSucceeded
                            ? Words.t("已隔离到书案「恢复前排队」")
                            : Words.t("已移出活跃队列（导出到书案失败，原始副本保留在隔离目录）")
                        DispatchQueue.main.async {
                            Diag.note("启动检查：\(chatKey) 的 \(report.isolatedMessages) 条排队消息不属于当前对话（可能恢复了旧备份），\(exportHint)。")
                        }
                    } else if report.failedMessages > 0 {
                        DispatchQueue.main.async {
                            Diag.note("启动检查：\(chatKey) 的 \(report.failedMessages) 条不匹配排队消息未能移出，已标记拦截不会自动发出。")
                        }
                    }
                    continue
                case .restore:
                    break
                }

                var persistedInChat = Set((loadedEntries ?? []).flatMap { $0.queuedIds ?? [] })
                if !isLeafSlot, let leafIds = leavesByBase[chatKey] {
                    // If a crash occurred right after shelving an entry whose queued IDs had not yet been cleared,
                    // also check shelved leaves under this conversation so we never duplicate it.
                    for leafId in leafIds {
                        let leafKey = TeamModel.threadKey(chatKey, leaf: leafId)
                        for entry in Disk.loadChat(leafKey) {
                            if let ids = entry.queuedIds { persistedInChat.formUnion(ids) }
                        }
                    }
                }
                let persistedInDraftText = isLeafSlot ? Set<UUID>() : DraftTextStore.storedQueuedIds(for: chatKey)
                let persistedInDraftAttachments = isLeafSlot ? Set<UUID>() : DraftAttachments.storedQueuedIds(for: chatKey)
                let cleaned = QueuedMessageStore.deduplicated(
                    slot.items,
                    persistedInChat: persistedInChat,
                    persistedInDraftText: persistedInDraftText,
                    persistedInDraftAttachments: persistedInDraftAttachments
                )
                if cleaned != slot.items {
                    QueuedStore.saveDetached(cleaned, for: chatKey, anchor: slot.anchor)
                }
                if !cleaned.isEmpty {
                    kept[chatKey] = cleaned
                }
            }
            // If a crash happened after writing a destination slot during shelve/openLeaf and before clearing the source slot,
            // deduplicate any ID appearing in both `base` and `base~leaf`.
            for (base, leafIds) in leavesByBase {
                guard let activeItems = kept[base], !activeItems.isEmpty else { continue }
                let activeIsEmptyOnDisk = Disk.loadChat(base).isEmpty
                var activeFiltered = activeItems
                for leafId in leafIds {
                    let leafKey = TeamModel.threadKey(base, leaf: leafId)
                    guard let leafItems = kept[leafKey], !leafItems.isEmpty else { continue }
                    let leafIdsSet = Set(leafItems.map(\.id))
                    let activeIdsSet = Set(activeFiltered.map(\.id))
                    let overlap = activeIdsSet.intersection(leafIdsSet)
                    guard !overlap.isEmpty else { continue }
                    if activeIsEmptyOnDisk {
                        activeFiltered.removeAll { overlap.contains($0.id) }
                    } else {
                        let dedupedLeaf = leafItems.filter { !overlap.contains($0.id) }
                        QueuedStore.saveDetached(dedupedLeaf, for: leafKey, anchor: raw[leafKey]?.anchor)
                        kept[leafKey] = dedupedLeaf.isEmpty ? nil : dedupedLeaf
                    }
                }
                if activeFiltered != activeItems {
                    QueuedStore.saveDetached(activeFiltered, for: base, anchor: raw[base]?.anchor)
                    kept[base] = activeFiltered.isEmpty ? nil : activeFiltered
                }
            }
            return kept
        }
    }

    func prepare() async {
        guard let startup else { return }
        let data = await startup.value
        guard loading else { return }
        load(data)
        startupCompleted()
    }

    func startupCompleted() {
        startup = nil
        loading = false
    }

    func load(_ data: InitialData) {
        settings = data.settings
        if Self.settle(&settings) { saveSettings() }
        bots = data.bots
        rooms = data.rooms
        memoryBook = data.memory
        memories = memoryBook.memories
        memoryReviews = memoryBook.reviews
        cleanReviewTails = [:]
        laters = data.laters
        routines = data.routines
        entries = [:]
        modelInputLog.reset()
        approvals = []
        phase = settings.endpoints.isEmpty ? .setup : .ready
        var restored: [String: [Queued]] = [:]
        for (chatKey, stored) in data.queued {
            restored[chatKey] = stored.map {
                Queued(id: $0.id, text: $0.text, photos: $0.photos, interject: $0.interject, userInitiated: $0.userInitiated)
            }
        }
        queued = restored
        inFlightQueued = [:]
        pendingInterjects = [:]
        unresolvedLeafOpenChats = []
        sortBots()
        ensureRetractedFlushHashesLoaded()
        memoryPromptState.mergeSuppressedFlushHashes(Array(data.suppressedMemoryHashes))
        MemoryStoreBridge.shared.attach(
            to: self,
            pinnedIDs: data.pinnedMemoryIDs,
            bots: bots,
            mainBotId: mainBotId
        )
        deliverDue()
    }

    var keeping: Bool { phase != .demo }
    func saveSettings() { if keeping { Disk.save(settings, "settings.json") } }
    func saveBots() { if keeping { Disk.save(bots, "bots.json") } }
    func saveRooms() { if keeping { Disk.save(rooms, "rooms.json") } }
    func saveMemory() {
        guard keeping, !Disk.frozen, !MemoryStoreBridge.shared.isCanonicalReadOnly else { return }
        var book = memoryBook
        book.memories = memories
        _ = try? commitMemoryBook(book)
    }

    @discardableResult
    func commitMemoryBook(
        _ book: MemoryBook,
        mutation: MemoryCommitMutation = .none
    ) throws -> MemoryBook {
        guard keeping, !Disk.frozen else {
            throw TeamError(message: "刚恢复了备份，重新打开 Clio 后才能保存。")
        }
        guard !MemoryStoreBridge.shared.isCanonicalReadOnly else {
            throw TeamError(message: "记忆文件暂不可读，已跳过覆盖写入以防丢失原有记忆。")
        }
        ensureRetractedFlushHashesLoaded()
        let orderedSecrets = Vault.allStrings().filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        let suppressed = memoryPromptState.suppressedFlushHashesSnapshot()
        let committed = try MemoryStoreBridge.shared.commitAppBook(
            book,
            mutation: mutation,
            suppressedHashes: suppressed,
            promptState: memoryPromptState,
            bots: bots,
            mainBotId: mainBotId,
            secrets: orderedSecrets
        )
        memoryBook = committed.book
        if memories != committed.book.memories {
            memories = committed.book.memories
        }
        memoryReviews = committed.book.reviews
        syncLivePromptsFromMemories()
        return committed.book
    }

    func prepareMemoryStoreForRestore() {
        MemoryStoreBridge.shared.prepareForBackupRestore()
    }

    func resetMemoryStore() {
        guard keeping, !Disk.frozen else { return }
        memoryBook = MemoryBook()
        memories = []
        memoryReviews = []
        memoryPromptState.invalidate()
        syncLivePromptsFromMemories()
        MemoryStoreBridge.shared.resetAll(team: self)
    }
    func saveLaters() { if keeping { Disk.save(laters, "later.json") } }
    func saveRoutines() { if keeping { Disk.save(routines, "routines.json") } }

    func sortBots() {
        let main = mainBotId
        bots.sort { left, right in
            if (left.id == main) != (right.id == main) { return left.id == main }
            return (left.createdAt ?? 0) < (right.createdAt ?? 0)
        }
    }
}
