import Foundation
import UIKit
import WidgetKit

/// Keeps the home-screen widget's snapshot fresh: the main companion, what it is doing, its last words.
@MainActor
enum WidgetFeed {
    private static var last: WidgetSnapshot?
    private static var pendingSnapshot: WidgetSnapshot?
    private static var pendingPublishTask: Task<Void, Never>?
    private static var activeBgTasks: [UUID: UIBackgroundTaskIdentifier] = [:]
    private static let workerQueue = DispatchQueue(label: "io.github.lllhr94.clio.widgetfeed", qos: .utility)

    private static let toldKey = "widget.toldNoKeychain"

    static func sanitizedPreviewLine(
        _ raw: String?,
        faceIDLocked: Bool = UserDefaults.standard.bool(forKey: "lock.faceid")
    ) -> String {
        if faceIDLocked { return "" }
        let cleanedLine = (raw ?? "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleanedLine.prefix(120))
    }

    static func publish(_ team: TeamModel, immediate: Bool = false) {
        guard let id = team.mainBotId, let bot = team.bots.first(where: { $0.id == id }) else { return }
        let key = TeamModel.key(bot: id)
        let kind: WidgetSnapshot.Kind
        let status: String
        if team.approvals.contains(where: { $0.chat == key }) {
            kind = .waiting
            status = L.t("pet.needsApproval")
        } else if team.isWorking(key) {
            kind = .working
            status = "正在干活"
        } else {
            kind = .idle
            status = L.t("chat.idle")
        }
        let snapshot = WidgetSnapshot(
            name: bot.name,
            status: status,
            line: sanitizedPreviewLine(bot.preview),
            at: (bot.lastAt ?? 0) / 1000,
            chat: key,
            kind: kind,
            oled: Theme.shared.oled,
            plain: Theme.shared.plain
        )
        guard snapshot != last else {
            if immediate, let pending = pendingSnapshot {
                pendingPublishTask?.cancel()
                pendingPublishTask = nil
                pendingSnapshot = nil
                enqueueFlush(pending)
            }
            return
        }
        last = snapshot
        if immediate {
            pendingPublishTask?.cancel()
            pendingPublishTask = nil
            pendingSnapshot = nil
            enqueueFlush(snapshot)
            return
        }
        pendingSnapshot = snapshot
        guard pendingPublishTask == nil else { return }
        pendingPublishTask = Task { @MainActor in
            // Coalesce rapid state updates on the main actor before writing keychain & reloading timelines.
            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch {
                return
            }
            pendingPublishTask = nil
            guard let next = pendingSnapshot else { return }
            pendingSnapshot = nil
            enqueueFlush(next)
        }
    }

    private static func enqueueFlush(_ snapshot: WidgetSnapshot) {
        let flushID = UUID()
        let bgTask = UIApplication.shared.beginBackgroundTask(withName: "clio-widgetfeed") {
            Task { @MainActor in
                endBackgroundTask(for: flushID)
            }
        }
        if bgTask != .invalid {
            activeBgTasks[flushID] = bgTask
        }
        workerQueue.async {
            flushSnapshot(snapshot, flushID: flushID)
        }
    }

    private static func endBackgroundTask(for flushID: UUID) {
        guard let bgTask = activeBgTasks.removeValue(forKey: flushID), bgTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTask)
    }

    nonisolated private static func flushSnapshot(_ snapshot: WidgetSnapshot, flushID: UUID) {
        let saved = Shelf.put(snapshot)
        if saved {
            WidgetCenter.shared.reloadAllTimelines()
        }
        Task { @MainActor in
            defer { endBackgroundTask(for: flushID) }
            if !saved {
                if Self.last == snapshot { Self.last = nil }
                if !UserDefaults.standard.bool(forKey: Self.toldKey) {
                    // The signing will not change by itself: say it once, not every time the widget is fed.
                    UserDefaults.standard.set(true, forKey: Self.toldKey)
                    Diag.note("小组件：这个签名不让 app 和小组件共用钥匙串，小组件拿不到近况（只记这一次）")
                }
            }
        }
    }
}
