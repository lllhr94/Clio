import BackgroundTasks
import UIKit

/// iOS 26's continued processing: a turn the user started keeps going after they leave the app,
/// with the system's own progress bar on the lock screen. Short turns never ask for it; only one still going after a few seconds does.
@MainActor
enum Keeper {
    /// Matches `BGTaskSchedulerPermittedIdentifiers` in Info.plist (`….turn.*`).
    static let prefix = "io.github.lllhr94.clio.turn"

    private struct Kept {
        var identifier: String
        var task: BGContinuedProcessingTask?
        var finished = false
    }

    private static var kept: [String: Kept] = [:]
    /// What the chat is doing now, for the progress bar's second line.
    static var words: (String) -> String? = { _ in nil }
    /// iOS is taking the time back before the turn is done.
    static var expired: (String) -> Void = { _ in }

    /// Asks iOS for time to finish this chat's turn. Call while the app is on screen.
    static func begin(_ key: String, title: String) {
        if let entry = kept[key], entry.finished { kept[key] = nil }
        guard Pref.keepGoing, kept[key] == nil, UIApplication.shared.applicationState == .active else { return }
        let identifier = "\(prefix).\(UUID().uuidString.prefix(8).lowercased())"
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            MainActor.assumeIsolated { arrived(task, key: key, title: title) }
        }
        guard registered else { return }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: words(key) ?? "正在干活")
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            kept[key] = Kept(identifier: identifier)
        } catch {
            Diag.note("后台续做没要到：\(error.localizedDescription)")
        }
    }

    private static func arrived(_ task: BGTask, key: String, title: String) {
        guard let task = task as? BGContinuedProcessingTask else {
            task.setTaskCompleted(success: false)
            return
        }
        guard var entry = kept[key], !entry.finished else {
            task.setTaskCompleted(success: true)
            kept[key] = nil
            return
        }
        task.progress.totalUnitCount = 100
        task.progress.completedUnitCount = 5
        task.expirationHandler = {
            Task { @MainActor in
                kept[key] = nil
                expired(key)
            }
        }
        entry.task = task
        kept[key] = entry
        Task { @MainActor in
            while let current = kept[key]?.task, current === task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard kept[key]?.task === task else { break }
                if let line = words(key) { task.updateTitle(title, subtitle: line) }
                // Nobody knows how long a turn takes: creep toward the end without reaching it.
                let done = task.progress.completedUnitCount
                task.progress.completedUnitCount = min(95, done + max(1, (95 - done) / 10))
            }
        }
    }

    /// The turn is over: give the time back.
    static func end(_ key: String, success: Bool = true) {
        guard var entry = kept[key] else { return }
        if let task = entry.task {
            task.progress.completedUnitCount = 100
            task.setTaskCompleted(success: success)
            kept[key] = nil
        } else {
            // The system has not handed the task over yet; finish it the moment it does.
            entry.finished = true
            kept[key] = entry
        }
    }
}
