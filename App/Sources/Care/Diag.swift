import QuartzCore
import SwiftUI
import UIKit

/// 诊断: the last few things that went wrong, kept for the 诊断 page.
enum Diag {
    private static let key = "diag.log"

    static func note(_ text: String) {
        var log = UserDefaults.standard.stringArray(forKey: key) ?? []
        let stamp = Date().formatted(.dateTime.month().day().hour().minute().second())
        log.append("\(stamp)  \(text)")
        UserDefaults.standard.set(Array(log.suffix(60)), forKey: key)
    }

    static var log: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }
    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}

/// 掉帧记录仪: every frame that took longer than 16 ms, with the page on screen and what was going on,
/// for 养护 to show and copy. It runs only while switched on: its clock keeps the screen at its full rate, which costs a little battery.
@MainActor
final class Hitches: ObservableObject {
    static let shared = Hitches()

    struct Hitch: Codable, Hashable {
        var at: Date
        var ms: Int
        var page: String
        var action: String

        var line: String {
            "\(at.formatted(.dateTime.month().day().hour().minute().second()))  \(ms) ms  \(page)" + (action.isEmpty ? "" : "  · \(action)")
        }
    }

    /// The newest last.
    @Published private(set) var recent: [Hitch] = []
    /// Pages on screen, the one in front last.
    private var pages: [String] = ["案头"]
    /// What is going on, by slot: scrolling, typing, a companion at work.
    private var actions: [String: String] = [:]
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var watchers: [NSObjectProtocol] = []
    private static let storeKey = "diag.hitches"

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
        UserDefaults.standard.removeObject(forKey: Self.storeKey)
    }

    func save() {
        if let data = try? JSONEncoder().encode(recent) { UserDefaults.standard.set(data, forKey: Self.storeKey) }
    }

    /// For pasting: a line of totals, then every hitch, newest first.
    var report: String {
        guard !recent.isEmpty else { return "掉帧记录：没有超过 16 ms 的帧。" }
        let worst = recent.map(\.ms).max() ?? 0
        var byPage: [String: Int] = [:]
        for hitch in recent { byPage[hitch.page, default: 0] += 1 }
        let pages = byPage.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value) 次" }.joined(separator: "，")
        return (["掉帧记录：共 \(recent.count) 次，最长 \(worst) ms；\(pages)"] + recent.reversed().map(\.line)).joined(separator: "\n")
    }

    fileprivate func tick(_ time: CFTimeInterval) {
        defer { last = time }
        guard last > 0 else { return }
        let gap = Int(((time - last) * 1000).rounded())
        // A frame at 60 Hz is 16.7 ms; anything past 17 ms missed at least one refresh.
        guard gap > 17 else { return }
        let now = Date()
        let page = pages.last ?? "案头"
        let action = actions.sorted { $0.key < $1.key }.map(\.value).joined(separator: "，")
        // Slow frames in a row are one stutter: keep its worst frame.
        if let previous = recent.last, now.timeIntervalSince(previous.at) < 0.3, previous.page == page {
            if gap > previous.ms { recent[recent.count - 1].ms = gap }
            return
        }
        recent.append(Hitch(at: now, ms: gap, page: page, action: action))
        if recent.count > 200 { recent.removeFirst(recent.count - 200) }
        if recent.count % 20 == 0 { save() }
    }

    /// CADisplayLink holds its target strongly; this keeps the recorder free to go.
    private final class Ticker: NSObject {
        weak var hitches: Hitches?
        init(_ hitches: Hitches) { self.hitches = hitches }
        @objc func tick(_ link: CADisplayLink) {
            let time = link.timestamp
            MainActor.assumeIsolated { hitches?.tick(time) }
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
