import BackgroundTasks
import Foundation

/// A turn keeps going for a while after Clio leaves the screen (iOS 26 continued processing):
/// the system shows its own progress card, and the person can stop it there.
/// Started only while Clio is on screen, from the person's own send, as the system requires.
@MainActor
enum BackgroundTurn {
    private static let prefix = "io.github.lllhr94.clio.turn."
    private static var tasks: [String: BGContinuedProcessingTask] = [:]
    private static var steps: [String: Int64] = [:]
    /// Stops the turn of a chat; set by the team.
    static var stop: ((String) -> Void)?

    static var on: Bool { UserDefaults.standard.object(forKey: "bg.continue") == nil ? true : UserDefaults.standard.bool(forKey: "bg.continue") }

    static func begin(chat: String, name: String) {
        // Asked once per turn: a request already in (steps set) or a task already running is left alone.
        guard on, tasks[chat] == nil, steps[chat] == nil else { return }
        // A fresh name each time: a name can be registered only once per launch.
        let id = prefix + UUID().uuidString.prefix(8).lowercased()
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: .main) { task in
            guard let task = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
            MainActor.assumeIsolated { adopt(task, chat: chat) }
        }
        guard registered else { return }
        let request = BGContinuedProcessingTaskRequest(identifier: id, title: "\(name)在做事", subtitle: "回到 Clio 看进度")
        // Only now or never: a turn that can't keep going in the back simply pauses as before.
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            steps[chat] = 0
        } catch {
            Diag.note("后台续跑没开起来：\(error.localizedDescription)")
        }
    }

    private static func adopt(_ task: BGContinuedProcessingTask, chat: String) {
        tasks[chat] = task
        task.progress.totalUnitCount = 100
        task.progress.completedUnitCount = min(90, (steps[chat] ?? 0) * 8)
        task.expirationHandler = {
            Task { @MainActor in
                stop?(chat)
                tasks[chat] = nil
            }
        }
    }

    /// A step was taken: the system wants to see progress, or it ends the task.
    static func step(chat: String, doing: String?) {
        // Counted only once the request is in; before that there is nothing to report to.
        guard steps[chat] != nil else { return }
        steps[chat, default: 0] += 1
        guard let task = tasks[chat] else { return }
        task.progress.completedUnitCount = min(95, (steps[chat] ?? 0) * 8 + 4)
        if let doing { task.updateTitle(task.title, subtitle: String(doing.prefix(60))) }
    }

    static func end(chat: String, ok: Bool) {
        steps[chat] = nil
        guard let task = tasks.removeValue(forKey: chat) else { return }
        task.progress.completedUnitCount = 100
        task.setTaskCompleted(success: ok)
    }
}
