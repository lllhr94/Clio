import AgentKit
import Craft
import SwiftUI
import UserNotifications
import UIKit

extension TeamModel {
    // MARK: Later

    func later(_ text: String, at date: Date, bot: String, chat: String) {
        let item = Later(id: UUID().uuidString, chat: chat, botId: bot, text: text, at: date.timeIntervalSince1970)
        laters.append(item)
        saveLaters()
        Notify.schedule(item, from: bots.first { $0.id == bot }?.name ?? L.t("nav.assistant"))
    }

    /// Messages whose time has come go into their chats.
    func deliverDue() {
        guard keeping, phase == .ready else { return }
        let now = Date().timeIntervalSince1970
        let due = laters.filter { $0.at <= now && canAcceptInput(for: $0.chat) }.sorted { $0.at < $1.at }
        guard !due.isEmpty else { return }
        let deliveredIds = Set(due.map(\.id))
        laters.removeAll { deliveredIds.contains($0.id) }
        saveLaters()
        for item in due {
            let speaker = item.chat.hasPrefix("room-") ? item.botId : nil
            append(Entry(id: UUID().uuidString, at: item.at * 1000, message: .assistant(item.text), speaker: speaker), to: item.chat)
            touch(item.chat, preview: item.text, speaker: speaker)
        }
    }

    /// The soonest message a companion has set for later.
    var nextLetter: Later? { laters.min { $0.at < $1.at } }

    // MARK: 定时

    /// Adds a routine, or changes the one with its id.
    func setRoutine(_ routine: Routine) {
        if let index = routines.firstIndex(where: { $0.id == routine.id }) { routines[index] = routine } else { routines.append(routine) }
        saveRoutines()
        Notify.schedule(routine, from: bots.first { $0.id == routine.botId }?.name ?? L.t("nav.assistant"))
    }

    func removeRoutine(_ id: String) {
        routines.removeAll { $0.id == id }
        saveRoutines()
        Notify.unschedule(routine: id)
    }

    /// Routines whose time has come start now, one per conversation at a time; a busy conversation waits for the next look.
    func routinesIfDue() {
        guard keeping, phase == .ready else { return }
        let now = Date()
        for routine in routines {
            guard let due = routine.due(now: now), bots.contains(where: { $0.id == routine.botId }) else { continue }
            let key = Self.key(bot: routine.botId)
            guard canAcceptInput(for: key), !isWorking(key) else { continue }
            var words = "【定时 · \(routine.title)】\(routine.prompt)"
            if now.timeIntervalSince(due.at) > 600 { words += "\n（本该 \(When.show(due.at)) 做，现在补上。）" }
            if due.missed > 0 { words += "\n（之前还错过了 \(due.missed) 次，没有补。）" }
            guard send(words, photos: [], to: key, userInitiated: false) else { continue }
            var done = routine
            done.lastRun = now.timeIntervalSince1970
            if let index = routines.firstIndex(where: { $0.id == routine.id }) { routines[index] = done }
            saveRoutines()
            Diag.note("定时任务开始：\(routine.title)")
        }
    }

    /// Called when the app comes back to the front.
    func wake() {
        guard !loading else { return }
        BackgroundTurn.stop = { [weak self] key, token in
            guard let self, runs[key]?.token == token else { return }
            stop(key)
        }
        LiveTurns.sweep()
        deliverDue()
        routinesIfDue()
        morningIfDue()
        TideBook.shared.refresh()
        resumePaused()
    }

    /// Back on screen: each turn iOS paused goes on from where it stopped, without a tap.
    func resumePaused() {
        let waiting = pausedAway
        pausedAway.removeAll()
        for key in waiting {
            // Still winding down: picked up when it has (see where the pause note is written).
            if runs[key] == nil { resume(key) } else { pausedAway.insert(key) }
        }
    }

    // MARK: 晨信

    private static func localDayString(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Once a day, after the hour the user chose, the main companion writes a short morning letter.
    func morningIfDue() {
        guard phase == .ready, Pref.morningOn, let main = mainBotId, bots.contains(where: { $0.id == main }) else { return }
        let now = Date()
        let calendar = Calendar.current
        guard calendar.component(.hour, from: now) >= Pref.morningHour else { return }
        let today = Self.localDayString(now, calendar: calendar)
        guard UserDefaults.standard.string(forKey: "morning.last") != today else { return }
        let key = Self.key(bot: main)
        // Busy (a routine, say): tried again on the next look, not marked done for the day.
        guard canAcceptInput(for: key), !isWorking(key) else { return }
        let prompt = "早。请给我一封今天的晨信：看看今天和明天的日程、还没做完的提醒；能查天气就说一句天气；再挑一两件今天值得留意的事。短一些，像一封便笺。"
        if send(prompt, photos: [], to: key, userInitiated: false) {
            UserDefaults.standard.set(today, forKey: "morning.last")
        }
    }

    private static var morningScheduleTask: Task<Void, Never>?

    /// The daily nudge, at the hour the user chose; opening it lets the letter be written.
    /// Debounced so rapid StopRow / toggle interactions do not thrash `UNUserNotificationCenter`.
    static func scheduleMorning() {
        morningScheduleTask?.cancel()
        morningScheduleTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return
            }
            applyMorningSchedule()
        }
    }

    private static func applyMorningSchedule() {
        let enabled = Pref.morningOn
        let hour = Pref.morningHour
        let title = L.t("agent.morningBrief")
        let body = Words.t("新的一天，打开看看旅伴给你写了什么。")
        Task.detached(priority: .utility) {
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: ["clio.morning"])
            guard enabled else { return }
            center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            var parts = DateComponents()
            parts.hour = hour
            parts.minute = 0
            center.add(UNNotificationRequest(identifier: "clio.morning", content: content, trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: true)))
        }
    }
}
