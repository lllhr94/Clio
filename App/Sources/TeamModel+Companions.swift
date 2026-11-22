import AgentKit
import Craft
import SwiftUI
import UserNotifications
import UIKit

extension TeamModel {
    // MARK: Bots and groups

    func ensureMainBot() {
        guard bots.isEmpty else { return }
        bots = [BotInfo(id: UUID().uuidString, name: "团子", role: "你的贴身助理", color: "orange", main: true,
                        instructions: "温柔、机灵，有点小调皮。记性很好，会主动关心用户。", createdAt: Now.ms)]
        settings.mainBotId = bots[0].id
        saveSettings()
        saveBots()
    }

    /// Saves a companion and returns its id. `avatar`: nil leaves it as it is, "" goes back to the default pet.
    @discardableResult
    func saveBot(id: String?, name: String, role: String, color: String, model: String? = nil, instructions: String? = nil,
                 avatar: String? = nil, temper: String? = nil, style: String? = nil, seal: String? = nil) async throws -> String {
        let saved: String
        if let id, let index = bots.firstIndex(where: { $0.id == id }) {
            bots[index].name = name
            bots[index].role = role
            bots[index].color = color
            if let model { bots[index].model = model.isEmpty ? nil : model }
            if let instructions { bots[index].instructions = instructions }
            if let avatar { bots[index].avatar = avatar.isEmpty ? nil : avatar }
            if let temper { bots[index].temper = temper.isEmpty ? nil : temper }
            if let style { bots[index].style = style.isEmpty ? nil : style }
            if let seal { bots[index].seal = seal.isEmpty ? nil : seal }
            saved = id
        } else {
            saved = UUID().uuidString
            bots.append(BotInfo(id: saved, name: name, role: role, color: color, instructions: instructions,
                                model: model?.isEmpty == false ? model : nil, createdAt: Now.ms,
                                temper: temper?.isEmpty == false ? temper : nil, style: style?.isEmpty == false ? style : nil,
                                seal: seal?.isEmpty == false ? seal : nil,
                                avatar: avatar?.isEmpty == false ? avatar : nil))
        }
        withAnimation(.smooth(duration: 0.35)) { sortBots() }
        saveBots()
        return saved
    }

    func deleteBot(_ id: String) async throws {
        guard bots.count > 1 else { throw TeamError(message: "至少要留一个 Bot。") }
        stop(Self.key(bot: id))
        Avatars.forget(id)
        withAnimation(.smooth(duration: 0.35)) {
            bots.removeAll { $0.id == id }
            for index in rooms.indices { rooms[index].members?.removeAll { $0 == id } }
        }
        if settings.mainBotId == id {
            settings.mainBotId = bots.first?.id
            saveSettings()
        }
        if threadLabels[Self.key(bot: id)] != nil { setThreadLabel("", for: Self.key(bot: id)) }
        let key = Self.key(bot: id)
        // What it was set to do later goes with it: no routine or message fires for a companion that is gone.
        for routine in routines where routine.botId == id { removeRoutine(routine.id) }
        let letters = laters.filter { $0.botId == id || $0.chat == key }
        if !letters.isEmpty {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: letters.map(\.id))
            laters.removeAll { item in letters.contains { $0.id == item.id } }
            saveLaters()
        }
        // And its conversation's other files: leaves put aside, the 前情提要, settings, copies kept for 「重来」.
        if keeping {
            for leaf in leaves(key) {
                Disk.remove(Self.leafFile(key, leaf.id))
                Disk.remove(Self.leafSummary(key, leaf.id))
            }
            Disk.remove(Self.leafList(key))
            Disk.remove(Self.summaryFile(key))
            Disk.remove(Self.optionsFile(key))
        }
        leafBook[key] = nil
        optionBook[key] = nil
        Snapshots.shared.forget(key)
        entries[key] = nil
        modelInputLog.clear(key)
        if keeping { ChatDisk.remove(key) }
        saveBots()
        saveRooms()
    }

    @discardableResult
    func createRoom(name: String, members: [String]) -> RoomInfo {
        let room = RoomInfo(id: UUID().uuidString, name: name, members: members, lastAt: Now.ms)
        withAnimation(.smooth(duration: 0.35)) { rooms.insert(room, at: 0) }
        saveRooms()
        return room
    }

    func updateRoom(_ id: String, name: String, members: [String]) {
        guard let index = rooms.firstIndex(where: { $0.id == id }) else { return }
        rooms[index].name = name
        rooms[index].members = members
        saveRooms()
    }

    func deleteRoom(_ id: String) {
        stop(Self.key(room: id))
        withAnimation(.smooth(duration: 0.35)) { rooms.removeAll { $0.id == id } }
        if threadLabels[Self.key(room: id)] != nil { setThreadLabel("", for: Self.key(room: id)) }
        let key = Self.key(room: id)
        let letters = laters.filter { $0.chat == key }
        if !letters.isEmpty {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: letters.map(\.id))
            laters.removeAll { $0.chat == key }
            saveLaters()
        }
        if keeping {
            for leaf in leaves(key) {
                Disk.remove(Self.leafFile(key, leaf.id))
                Disk.remove(Self.leafSummary(key, leaf.id))
            }
            Disk.remove(Self.leafList(key))
            Disk.remove(Self.summaryFile(key))
            Disk.remove(Self.optionsFile(key))
        }
        leafBook[key] = nil
        optionBook[key] = nil
        Snapshots.shared.forget(key)
        entries[key] = nil
        modelInputLog.clear(key)
        if keeping { ChatDisk.remove(key) }
        saveRooms()
    }

    /// What a Bot is up to, in a few words, and the color of its light.
    func status(of bot: BotInfo) -> (text: String, light: Color) {
        if approvals.contains(where: { $0.botId == bot.id }) { return ("等你批准", Ink.warn) }
        if doing[Self.key(bot: bot.id)] != nil || busyBots.contains(bot.id) { return ("正在干活", Ink.accent) }
        if phase == .ready, resolve(bot.model ?? settings.defaultModel) == nil { return ("还没有模型", Ink.stop) }
        return ("空闲", Ink.ok)
    }
}
