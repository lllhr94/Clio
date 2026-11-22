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

        nonisolated static func read() -> Self {
            Self(
                settings: Disk.load(TeamSettings.self, "settings.json") ?? TeamSettings(),
                bots: Disk.load([BotInfo].self, "bots.json") ?? [],
                rooms: Disk.load([RoomInfo].self, "rooms.json") ?? [],
                memory: Disk.load(MemoryBook.self, "memory.json") ?? MemoryBook(memories: Disk.load([Memory].self, "memory.json") ?? []),
                laters: Disk.load([Later].self, "later.json") ?? [],
                routines: Disk.load([Routine].self, "routines.json") ?? []
            )
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
