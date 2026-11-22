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
        let laters: [Later]
        let routines: [Routine]
        let queued: [String: [StoredQueuedMessage]]

        nonisolated static func read() -> Self {
            let settings = Disk.load(TeamSettings.self, "settings.json") ?? TeamSettings()
            let bots = Disk.load([BotInfo].self, "bots.json") ?? []
            let rooms = Disk.load([RoomInfo].self, "rooms.json") ?? []
            let memory = Disk.load(MemoryBook.self, "memory.json") ?? MemoryBook(memories: Disk.load([Memory].self, "memory.json") ?? [])
            let laters = Disk.load([Later].self, "later.json") ?? []
            let routines = Disk.load([Routine].self, "routines.json") ?? []
            let rawQueued = QueuedStore.loadAll()

            let queued = reconcileQueued(rawQueued, bots: bots, rooms: rooms)

            return Self(
                settings: settings,
                bots: bots,
                rooms: rooms,
                memory: memory,
                laters: laters,
                routines: routines,
                queued: queued
            )
        }

        private struct LeafID: Decodable { let id: String }

        private nonisolated static func reconcileQueued(
            _ raw: [String: [StoredQueuedMessage]],
            bots: [BotInfo],
            rooms: [RoomInfo]
        ) -> [String: [StoredQueuedMessage]] {
            guard !raw.isEmpty else { return [:] }
            let baseKeys = bots.map { TeamModel.key(bot: $0.id) } + rooms.map { TeamModel.key(room: $0.id) }
            var validKeys = Set(baseKeys)
            var leavesByBase: [String: [String]] = [:]
            for base in baseKeys {
                let ids = (Disk.load([LeafID].self, TeamModel.leafList(base)) ?? []).map(\.id)
                leavesByBase[base] = ids
                for leafId in ids {
                    validKeys.insert(TeamModel.threadKey(base, leaf: leafId))
                }
            }

            var kept: [String: [StoredQueuedMessage]] = [:]
            for (chatKey, items) in raw {
                guard validKeys.contains(chatKey) else {
                    QueuedStore.saveDetached([], for: chatKey)
                    continue
                }
                var persistedInChat = Set(Disk.loadChat(chatKey).flatMap { $0.queuedIds ?? [] })
                let isLeafSlot = chatKey.contains("~")
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
                let persistedInDraftText = isLeafSlot ? Set<UUID>() : ChatDraft.storedQueuedIds(for: chatKey)
                let persistedInDraftAttachments = isLeafSlot ? Set<UUID>() : DraftAttachments.storedQueuedIds(for: chatKey)
                let cleaned = QueuedMessageStore.deduplicated(
                    items,
                    persistedInChat: persistedInChat,
                    persistedInDraftText: persistedInDraftText,
                    persistedInDraftAttachments: persistedInDraftAttachments
                )
                if cleaned != items {
                    QueuedStore.saveDetached(cleaned, for: chatKey)
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
                        QueuedStore.saveDetached(dedupedLeaf, for: leafKey)
                        kept[leafKey] = dedupedLeaf.isEmpty ? nil : dedupedLeaf
                    }
                }
                if activeFiltered != activeItems {
                    QueuedStore.saveDetached(activeFiltered, for: base)
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
        sortBots()
        deliverDue()
    }

    var keeping: Bool { phase != .demo }
    func saveSettings() { if keeping { Disk.save(settings, "settings.json") } }
    func saveBots() { if keeping { Disk.save(bots, "bots.json") } }
    func saveRooms() { if keeping { Disk.save(rooms, "rooms.json") } }
    func saveMemory() {
        guard keeping else { return }
        memoryBook.memories = memories
        if memoryBook.budgetDay == nil && memoryBook.reviewFromDay == nil { Disk.save(memories, "memory.json") }
        else { Disk.save(memoryBook, "memory.json") }
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
