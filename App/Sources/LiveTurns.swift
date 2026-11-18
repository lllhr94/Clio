import ActivityKit
import Foundation

/// Puts each running turn on the lock screen and in the Dynamic Island, and takes it down when it ends.
@MainActor
enum LiveTurns {
    private static var running: [String: Activity<TurnAttributes>] = [:]
    private static var states: [String: TurnAttributes.ContentState] = [:]
    private static var sent: [String: Date] = [:]

    static var on: Bool { UserDefaults.standard.object(forKey: "live.on") == nil ? true : UserDefaults.standard.bool(forKey: "live.on") }

    /// A turn began. Live Activities can only be started while Clio is on screen; a turn begun in the background has none.
    static func begin(chat: String, name: String) {
        guard on, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = TurnAttributes.ContentState(doing: "正在想", phase: .working, steps: 0, started: Date())
        if let activity = running[chat] {
            // A new turn in the same conversation: the same card, a fresh clock.
            states[chat] = state
            Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
            return
        }
        do {
            let activity = try Activity.request(attributes: TurnAttributes(name: name, chat: chat), content: ActivityContent(state: state, staleDate: nil), pushType: nil)
            running[chat] = activity
            states[chat] = state
        } catch {
            Diag.note("实时活动没开起来：\(error.localizedDescription)")
        }
    }

    /// What the turn is doing changed. Updates go out at most about once a second, except a change of phase.
    static func follow(chat: String, doing: String?) {
        guard let activity = running[chat], var state = states[chat], let doing, state.ended == nil else { return }
        let phase: TurnAttributes.ContentState.Phase = doing == "等你批准" ? .waiting : .working
        guard doing != state.doing || phase != state.phase else { return }
        let urgent = phase != state.phase
        state.doing = doing
        state.phase = phase
        states[chat] = state
        if !urgent, let last = sent[chat], Date().timeIntervalSince(last) < 1.2 {
            // Too soon after the last: the newest goes out a moment later, unless something else has gone first.
            guard !later.contains(chat) else { return }
            later.insert(chat)
            Task {
                try? await Task.sleep(nanoseconds: 1_300_000_000)
                later.remove(chat)
                guard let activity = running[chat], let newest = states[chat], newest.ended == nil else { return }
                sent[chat] = Date()
                await activity.update(ActivityContent(state: newest, staleDate: nil))
            }
            return
        }
        sent[chat] = Date()
        let alert = phase == .waiting ? AlertConfiguration(title: "\(activity.attributes.name)在等你批准", body: "打开 Clio 看看", sound: .default) : nil
        Task { await activity.update(ActivityContent(state: state, staleDate: nil), alertConfiguration: alert) }
    }

    private static var later: Set<String> = []

    /// A tool was used.
    static func step(chat: String) {
        guard var state = states[chat] else { return }
        state.steps += 1
        states[chat] = state
    }

    /// The turn ended: the card stays a few minutes with how it went, then goes.
    static func end(chat: String, ok: Bool, line: String?) {
        guard let activity = running.removeValue(forKey: chat), var state = states.removeValue(forKey: chat) else { return }
        sent[chat] = nil
        state.phase = ok ? .done : .failed
        state.ended = Date()
        let words = (line ?? "").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        state.doing = words.isEmpty ? (ok ? "做完了，点开看看" : "这次没做成，点开看看") : String(words.prefix(80))
        Task { await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(8 * 60))) }
    }

    /// Cards left from a run that ended while Clio was closed.
    static func sweep() {
        for activity in Activity<TurnAttributes>.activities where running[activity.attributes.chat] == nil {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
