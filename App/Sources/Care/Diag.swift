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
}

/// 诊断: the last few things that went wrong, kept for the 诊断 page.
enum Diag {
    private static let key = "diag.log"

    static func note(_ text: String) {
        var log = UserDefaults.standard.stringArray(forKey: key) ?? []
        let stamp = DiagStamp.string(from: Date())
        // The log is copied out to share when something breaks: no kept secret goes with it.
        log.append("\(stamp)  \(Shell.mask(text, secrets: Vault.allStrings()))")
        UserDefaults.standard.set(Array(log.suffix(60)), forKey: key)
    }

    static var log: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }
    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
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

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storeKey), let kept = try? JSONDecoder().decode([Hitch].self, from: data) {
            recent = kept
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

    func enter(_ page: String) { pages.append(page) }

    func leave(_ page: String) {
        if let index = pages.lastIndex(of: page), index > 0 { pages.remove(at: index) }
    }

    /// Says what is going on in one slot; nil clears it.
    func doing(_ what: String?, as slot: String) {
        if let what, !what.isEmpty { actions[slot] = what } else { actions[slot] = nil }
    }

    func clear() {
        recent = []
        version &+= 1
        newSinceSave = 0
        writes.async { UserDefaults.standard.removeObject(forKey: Self.storeKey) }
    }

    func save() {
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
        var byPage: [String: Int] = [:]
        for hitch in recent { byPage[hitch.page, default: 0] += 1 }
        let pages = byPage.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value) 次" }.joined(separator: "，")
        let rows: [Hitch]
        if let limit {
            rows = Array(recent.suffix(limit).reversed())
        } else {
            rows = Array(recent.reversed())
        }
        return (["掉帧记录：共 \(recent.count) 次，最长 \(worst) ms；\(pages)"] + rows.map(\.line)).joined(separator: "\n")
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
        let action = actions.sorted { $0.key < $1.key }.map(\.value).joined(separator: "，")
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
