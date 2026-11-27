import BackgroundTasks
import Craft
import UIKit

@MainActor
enum MemoryNight {
    private static let identifier = "io.github.lllhr94.clio.memory-night"
    private static let lastDelivery = "memory-night.lastDelivery"
    private static let launchGraceSeconds: TimeInterval = 15
    private static let activeCooldownSeconds: TimeInterval = 20
    private static var pending = false
    private static var scheduleQuery: UUID?
    private static var foreground: Task<Void, Never>?
    private static var backgroundRunning = false
    private static var launchUptime: TimeInterval?
    private static var lastActivityUptime: TimeInterval = 0

    static func noteLaunch() {
        if launchUptime == nil {
            launchUptime = ProcessInfo.processInfo.systemUptime
        }
    }

    static func recordActivity() {
        lastActivityUptime = ProcessInfo.processInfo.systemUptime
    }

    static func register() {
        _ = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            guard let task = task as? BGProcessingTask else { task.setTaskCompleted(success: false); return }
            MainActor.assumeIsolated { run(task) }
        }
    }

    static func schedule() {
        guard !pending, scheduleQuery == nil, TeamModel.shared.phase == .ready else { return }
        let query = UUID()
        let taskID = identifier
        scheduleQuery = query
        BGTaskScheduler.shared.getPendingTaskRequests { requests in
            let alreadyScheduled = requests.contains { $0.identifier == taskID }
            Task { @MainActor in
                guard scheduleQuery == query else { return }
                scheduleQuery = nil
                if alreadyScheduled {
                    pending = true
                } else {
                    let now = Date()
                    let night = diaryDay(at: now)
                    let eveningDue = night != nil && night != UserDefaults.standard.string(forKey: lastDelivery)
                    submit(earliest: eveningDue ? now : nextEvening(after: now))
                }
            }
        }
    }

    private static func nextEvening(after date: Date) -> Date? {
        Calendar.current.nextDate(after: date, matching: DateComponents(hour: 21), matchingPolicy: .nextTime)
    }

    private static func submit(earliest: Date?) {
        guard TeamModel.shared.phase == .ready else { return }
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.earliestBeginDate = earliest
        request.requiresNetworkConnectivity = true
        do {
            try BGTaskScheduler.shared.submit(request)
            pending = true
        } catch {
            // The system may disable background refresh.
        }
    }

    static func tick() {
        guard UIApplication.shared.applicationState == .active else { return }
        let nowUptime = ProcessInfo.processInfo.systemUptime
        if launchUptime == nil { launchUptime = nowUptime }
        schedule()
        if let launched = launchUptime, nowUptime - launched < launchGraceSeconds { return }
        if nowUptime - lastActivityUptime < activeCooldownSeconds { return }
        guard TeamModel.shared.phase == .ready, TeamModel.shared.runs.isEmpty else { return }
        guard foreground == nil, !backgroundRunning else { return }
        foreground = Task {
            defer { foreground = nil }
            await TeamModel.shared.reviewMemories(nightly: diaryDay(at: Date()) != nil)
        }
    }

    static func cancelForeground() { foreground?.cancel() }

    private static func run(_ task: BGProcessingTask) {
        scheduleQuery = nil
        pending = false
        let now = Date()
        let night = diaryDay(at: now, catchUp: true)
        backgroundRunning = true
        let previous = foreground
        previous?.cancel()
        let work = Task { @MainActor in
            defer { backgroundRunning = false }
            await previous?.value
            await TeamModel.shared.prepare()
            await TeamModel.shared.reviewMemories(nightly: true, background: true)
            let finished = !Task.isCancelled
            if finished {
                if let night {
                    UserDefaults.standard.set(night, forKey: lastDelivery)
                }
                submit(earliest: nextEvening(after: Date()))
            } else {
                submit(earliest: Date().addingTimeInterval(1800))
            }
            task.setTaskCompleted(success: finished)
        }
        task.expirationHandler = { work.cancel() }
    }

    static func diaryDay(at date: Date, catchUp: Bool = false) -> String? {
        LogicalDay.nightlyReviewDay(at: date, catchUp: catchUp)
    }
}
