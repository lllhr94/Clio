import Craft
import QuartzCore
import SwiftUI
import UIKit

private enum DiagStamp {
    private static let lock = NSLock()
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("MdHms")
        return formatter
    }()

    static func string(from date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return formatter.string(from: date)
    }

    static func preciseString(from date: Date) -> String {
        let tenth = Int((date.timeIntervalSince1970.truncatingRemainder(dividingBy: 1) * 10).rounded(.down))
        let digit = min(max(tenth, 0), 9)
        return "\(string(from: date)).\(digit)"
    }
}

/// 诊断: the last few things that went wrong, kept for the 诊断 page.
enum Diag {
    private static let key = "diag.log"
    private static let queue = DispatchQueue(label: "clio.diag.log", qos: .utility)

    static func note(_ text: String) {
        let now = Date()
        // Keep Keychain masking and UserDefaults persistence off the main thread so logging never triggers a hitch.
        queue.async {
            var log = UserDefaults.standard.stringArray(forKey: key) ?? []
            let stamp = DiagStamp.string(from: now)
            // The log is copied out to share when something breaks: no kept secret goes with it.
            log.append("\(stamp)  \(Shell.mask(text, secrets: Vault.allStrings()))")
            UserDefaults.standard.set(Array(log.suffix(60)), forKey: key)
        }
    }

    /// Reads the log in FIFO order after any queued `note(...)` writes without blocking the main thread.
    static func snapshot(suffix limit: Int? = nil) async -> [String] {
        await withCheckedContinuation { continuation in
            queue.async {
                let all = UserDefaults.standard.stringArray(forKey: key) ?? []
                if let limit {
                    continuation.resume(returning: Array(all.suffix(limit)))
                } else {
                    continuation.resume(returning: all)
                }
            }
        }
    }

    static func clear() {
        DiagTrail.clear()
        queue.async { UserDefaults.standard.removeObject(forKey: key) }
    }
}

/// Lightweight in-memory ring buffer of privacy-safe UI events (never message text, paths, URLs, or secrets)
/// so diagnostic reports show what happened right before a jump or hitch without asking the user to recall it.
enum DiagTrail {
    private struct Entry: Sendable {
        let at: Date
        let uptime: TimeInterval
        let event: String
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var entries: [Entry] = []
    private static let limit = 40

    static func record(_ event: String) {
        let now = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        lock.withLock {
            if let last = entries.last, last.event == event, uptime - last.uptime < 0.25 {
                return
            }
            entries.append(Entry(at: now, uptime: uptime, event: event))
            if entries.count > limit {
                entries.removeFirst(entries.count - limit)
            }
        }
    }

    /// Recent events within `window` seconds, oldest first, formatted with relative age (e.g. "-0.4s 收键盘").
    static func recentContext(within window: TimeInterval = 4, limit count: Int = 6) -> [String] {
        let now = ProcessInfo.processInfo.systemUptime
        let picked: [Entry] = lock.withLock {
            Array(entries.filter { now - $0.uptime <= window }.suffix(count))
        }
        return picked.map { entry in
            let age = max(0, now - entry.uptime)
            return String(format: "-%.1fs %@", age, entry.event)
        }
    }

    /// Most recent UI event within `window` seconds, attached to hitches so idle stutters identify their trigger.
    static func latest(within window: TimeInterval = 1.5) -> String? {
        let now = ProcessInfo.processInfo.systemUptime
        return lock.withLock {
            guard let last = entries.last, now - last.uptime <= window else { return nil }
            return last.event
        }
    }

    /// Chronological timestamped lines for the copied diagnostic report.
    static func reportLines(limit count: Int = 25) -> [String] {
        let snapshot: [Entry] = lock.withLock { Array(entries.suffix(count)) }
        return snapshot.map { "\(DiagStamp.preciseString(from: $0.at))  \($0.event)" }
    }

    static func clear() {
        lock.withLock { entries.removeAll(keepingCapacity: true) }
    }
}

/// 掉帧记录仪: gaps longer than the scheduled display interval, with the current page and activity,
/// for 养护 to show and copy. It runs only while switched on: its clock keeps the screen at its full rate, which costs a little battery.
@MainActor
final class Hitches {
    static let shared = Hitches()

    struct Hitch: Codable, Hashable, Sendable {
        var at: Date
        var ms: Int
        var page: String
        var action: String
        var refreshHz: Int? = nil

        var line: String {
            let cadence = refreshHz.map { " @ \($0) Hz" } ?? ""
            return "\(DiagStamp.string(from: at))  \(ms) ms\(cadence)  \(page)"
                + (action.isEmpty ? "" : "  · \(action)")
        }
    }

    /// The newest last.
    private(set) var recent: [Hitch] = []
    /// Incremented whenever `recent` changes so the diagnostics section can refresh on a throttle without `@Published` churn.
    private(set) var version: UInt64 = 0
    /// Pages on screen, the one in front last.
    private var pages: [String] = ["案头"]
    /// What is going on, by slot: scrolling, typing, a companion at work.
    private var actions: [String: String] = [:]
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var lastInterval: CFTimeInterval = 0
    private var newSinceSave = 0
    private var watchers: [NSObjectProtocol] = []
    private nonisolated static let storeKey = "diag.hitches"
    private let writes = DispatchQueue(label: "clio.hitches.storage", qos: .utility)
    private var loadStarted = false
    private var hasLoadedStored = false
    private var pendingSaveAfterLoad = false
    private var loadGeneration: UInt64 = 0
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []

    private init() {
        loadStored()
    }

    private func loadStored() {
        guard !loadStarted else { return }
        loadStarted = true
        let token = loadGeneration
        let key = Self.storeKey
        writes.async { [weak self] in
            let kept: [Hitch]
            if let data = UserDefaults.standard.data(forKey: key),
               let decoded = try? JSONDecoder().decode([Hitch].self, from: data) {
                kept = decoded
            } else {
                kept = []
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.loadGeneration == token else { return }
                self.hasLoadedStored = true
                if !kept.isEmpty {
                    self.recent = Array((kept + self.recent).suffix(200))
                    self.version &+= 1
                }
                self.resumeLoadWaiters()
                if self.pendingSaveAfterLoad {
                    self.pendingSaveAfterLoad = false
                    self.save()
                }
            }
        }
    }

    private func resumeLoadWaiters() {
        guard !loadWaiters.isEmpty else { return }
        let waiters = loadWaiters
        loadWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitForInitialLoad() async {
        guard !hasLoadedStored else { return }
        await withCheckedContinuation { continuation in
            if hasLoadedStored {
                continuation.resume()
            } else {
                loadWaiters.append(continuation)
            }
        }
    }

    var running: Bool { link != nil }

    func set(_ on: Bool) {
        if on, link == nil {
            let link = CADisplayLink(target: Ticker(self), selector: #selector(Ticker.tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            self.link = link
            last = 0
            // Leaving the app and coming back is a long gap, not a stutter.
            let center = NotificationCenter.default
            for name in [UIApplication.willResignActiveNotification, UIApplication.didBecomeActiveNotification] {
                watchers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { Hitches.shared.last = 0 }
                })
            }
        } else if !on, let link {
            link.invalidate()
            self.link = nil
            for watcher in watchers { NotificationCenter.default.removeObserver(watcher) }
            watchers = []
            save()
        }
    }

    func enter(_ page: String) {
        pages.append(page)
        DiagTrail.record("进页：\(page)")
    }

    func leave(_ page: String) {
        if let index = pages.lastIndex(of: page), index > 0 { pages.remove(at: index) }
        DiagTrail.record("离页：\(page)")
    }

    /// Says what is going on in one slot; nil clears it.
    func doing(_ what: String?, as slot: String) {
        if let what, !what.isEmpty { actions[slot] = what } else { actions[slot] = nil }
    }

    func clear() {
        loadGeneration &+= 1
        hasLoadedStored = true
        pendingSaveAfterLoad = false
        recent = []
        version &+= 1
        newSinceSave = 0
        resumeLoadWaiters()
        writes.async { UserDefaults.standard.removeObject(forKey: Self.storeKey) }
    }

    func save() {
        guard hasLoadedStored else {
            pendingSaveAfterLoad = true
            return
        }
        newSinceSave = 0
        let snapshot = recent
        writes.async {
            if let data = try? JSONEncoder().encode(snapshot) { UserDefaults.standard.set(data, forKey: Self.storeKey) }
        }
    }

    /// For pasting: a line of totals, then every hitch, newest first.
    var report: String { report(limit: nil) }

    /// For pasting: a line of totals, then up to `limit` newest hitches (all when nil), newest first.
    func report(limit: Int?) -> String {
        guard !recent.isEmpty else { return "掉帧记录：没有记录到漏刷新。" }
        let worst = recent.map(\.ms).max() ?? 0
        let over50 = recent.filter { $0.ms >= 50 }.count
        let over100 = recent.filter { $0.ms >= 100 }.count
        var byPage: [String: Int] = [:]
        for hitch in recent { byPage[hitch.page, default: 0] += 1 }
        let pages = byPage.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value) 次" }.joined(separator: "，")
        let rows: [Hitch]
        if let limit {
            rows = Array(recent.suffix(limit).reversed())
        } else {
            rows = Array(recent.reversed())
        }
        return (["掉帧记录：共 \(recent.count) 次（≥50ms \(over50) 次，≥100ms \(over100) 次），最长 \(worst) ms；\(pages)"] + rows.map(\.line)).joined(separator: "\n")
    }

    fileprivate func tick(_ time: CFTimeInterval, interval: CFTimeInterval) {
        let nextInterval = interval.isFinite && interval > 0 ? interval : 1.0 / 60
        defer { last = time; lastInterval = nextInterval }
        guard last > 0 else { return }
        // Use the longer scheduled interval during a cadence change to avoid false reports.
        let expected = max(lastInterval, nextInterval)
        let elapsed = time - last
        guard elapsed > expected * 1.5 else { return }
        let gap = Int((elapsed * 1000).rounded())
        let hz = Int((1 / expected).rounded())
        let now = Date()
        let page = pages.last ?? Words.t("案头")
        var parts = actions.sorted { $0.key < $1.key }.map(\.value)
        if let recentEvent = DiagTrail.latest(within: 1.5),
           !parts.contains(where: { $0.contains(recentEvent) }) {
            parts.append(recentEvent)
        }
        let action = parts.joined(separator: "，")
        // Slow frames in a row are one stutter: keep its worst frame.
        if let previous = recent.last, now.timeIntervalSince(previous.at) < 0.3, previous.page == page {
            if gap > previous.ms {
                recent[recent.count - 1] = Hitch(at: previous.at, ms: gap, page: page, action: action, refreshHz: hz)
                version &+= 1
            }
            return
        }
        recent.append(Hitch(at: now, ms: gap, page: page, action: action, refreshHz: hz))
        if recent.count > 200 { recent.removeFirst(recent.count - 200) }
        version &+= 1
        newSinceSave += 1
        if newSinceSave >= 20 { save() }
    }

    /// CADisplayLink holds its target strongly; this keeps the recorder free to go.
    private final class Ticker: NSObject {
        weak var hitches: Hitches?
        init(_ hitches: Hitches) { self.hitches = hitches }
        @objc func tick(_ link: CADisplayLink) {
            let time = link.timestamp
            let interval = link.targetTimestamp - time
            MainActor.assumeIsolated { hitches?.tick(time, interval: interval) }
        }
    }
}

extension View {
    /// Names this page for the 掉帧记录仪 while it is on screen.
    func hitchPage(_ name: String) -> some View {
        onAppear { Hitches.shared.enter(name) }
            .onDisappear { Hitches.shared.leave(name) }
    }
}
