import BackgroundTasks
import Foundation
import UIKit

/// A user-initiated turn may keep going after Clio leaves the screen.
@MainActor
enum BackgroundTurn {
    private static let prefix = "io.github.lllhr94.clio.turn."
    private struct Turn {
        let token: UUID
        let identifier: String
        var steps: Int64 = 0
        var task: BGContinuedProcessingTask?
    }
    private static var turns: [String: Turn] = [:]
    static var stop: ((String, UUID) -> Void)?

    /// Off unless asked for: the system shows its own progress card.
    static var on: Bool { UserDefaults.standard.bool(forKey: "bg.continue") }

    static func begin(chat: String, name: String, token: UUID) {
        guard on, UIApplication.shared.applicationState == .active, turns[chat] == nil else { return }
        let id = prefix + token.uuidString.lowercased()
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: .main) { task in
            guard let task = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
            MainActor.assumeIsolated { adopt(task, chat: chat, token: token) }
        }
        guard registered else {
            Diag.note("后台续跑没能注册")
            return
        }
        let request = BGContinuedProcessingTaskRequest(identifier: id, title: "\(name)在做事", subtitle: "回到 Clio 看进度")
        request.strategy = .fail
        turns[chat] = Turn(token: token, identifier: id)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            turns[chat] = nil
            Diag.note("后台续跑没开起来：\(error.localizedDescription)")
        }
    }

    private static func adopt(_ task: BGContinuedProcessingTask, chat: String, token: UUID) {
        guard let turn = turns[chat], turn.token == token else {
            task.setTaskCompleted(success: false)
            return
        }
        turns[chat]?.task = task
        task.progress.totalUnitCount = 100
        task.progress.completedUnitCount = min(90, turn.steps * 8)
        task.expirationHandler = {
            Task { @MainActor in
                guard turns[chat]?.token == token else { return }
                stop?(chat, token)
                end(chat: chat, token: token, ok: false)
            }
        }
    }

    static func step(chat: String, doing: String?) {
        guard var turn = turns[chat] else { return }
        turn.steps = min(12, turn.steps + 1)
        turns[chat] = turn
        guard let task = turn.task else { return }
        task.progress.completedUnitCount = min(95, turn.steps * 8 + 4)
        if let doing {
            let shown = doing == "等你批准" ? L.t("pet.needsApproval") : Words.t(doing)
            task.updateTitle(task.title, subtitle: String(shown.prefix(60)))
        }
    }

    static func end(chat: String, token: UUID, ok: Bool) {
        guard let turn = turns[chat], turn.token == token else { return }
        turns[chat] = nil
        if let task = turn.task {
            task.expirationHandler = nil
            if ok { task.progress.completedUnitCount = 100 }
            task.setTaskCompleted(success: ok)
        } else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: turn.identifier)
        }
    }
}
