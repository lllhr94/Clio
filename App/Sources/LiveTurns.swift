import ActivityKit
import Foundation
import UIKit

/// Puts each running turn on the lock screen and in the Dynamic Island, and takes it down when it ends.
@MainActor
enum LiveTurns {
    private static var running: [String: Activity<TurnAttributes>] = [:]
    private static var ending: [String: (activity: Activity<TurnAttributes>, task: Task<Void, Never>)] = [:]
    private static var states: [String: TurnAttributes.ContentState] = [:]
    private static var sent: [String: Date] = [:]

    static var on: Bool { UserDefaults.standard.object(forKey: "live.on") == nil ? true : UserDefaults.standard.bool(forKey: "live.on") }

    /// A turn began. Live Activities can only be started while Clio is on screen; a turn begun in the background has none.
    static func begin(chat: String, name: String, face: @autoclosure () -> Data? = nil) {
        guard on, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let initialDoing = L.plain ? "正在思考" : L.t("chat.thinking")
        let state = TurnAttributes.ContentState(doing: initialDoing, phase: .working, steps: 0, started: Date(), ring: Date())
        if let pending = ending.removeValue(forKey: chat) {
            pending.task.cancel()
            if pending.activity.activityState == .active {
                running[chat] = pending.activity
                states[chat] = state
                sent[chat] = Date()
                Task { await pending.activity.update(ActivityContent(state: state, staleDate: nil)) }
                return
            } else {
                Task { await pending.activity.end(nil, dismissalPolicy: .immediate) }
            }
        }
        if let activity = running[chat] {
            // A new turn in the same conversation: the same card, a fresh clock.
            states[chat] = state
            Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
            return
        }
        do {
            let attributes = TurnAttributes(name: name, chat: chat, face: face(), oled: Theme.shared.oled)
            let activity = try Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: nil), pushType: nil)
            running[chat] = activity
            states[chat] = state
        } catch {
            Diag.note("实时活动没开起来：\(error.localizedDescription)")
        }
    }

    /// What the turn is doing changed. Updates go out at most about once a second, except a change of phase.
    static func follow(chat: String, doing: String?) {
        guard let activity = running[chat], var state = states[chat], let doing, state.ended == nil else { return }
        let needsApproval = doing == "等你批准" || doing == L.t("pet.needsApproval")
        let phase: TurnAttributes.ContentState.Phase = needsApproval ? .waiting : .working
        let shown = needsApproval ? L.t("pet.needsApproval") : Words.t(doing)
        guard shown != state.doing || phase != state.phase else { return }
        let urgent = phase != state.phase
        state.doing = shown
        state.phase = phase
        if Date().timeIntervalSince(state.ring ?? state.started) > 55 { state.ring = Date() }
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
        // Never pops the island open: a wait for approval comes as a notification (see `TeamModel.ask`).
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
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
        ending.removeValue(forKey: chat)?.task.cancel()
        state.phase = ok ? .done : .failed
        state.ended = Date()
        let words = (line ?? "").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        let fallback = ok ? "\(L.t("pet.done"))，点开看看" : "\(L.t("pet.failed"))，点开看看"
        state.doing = words.isEmpty ? fallback : String(Words.t(words).prefix(80))
        // The island shows ✓ (or !) for a few seconds before the card leaves it; the lock screen keeps it a while.
        let grace = UIApplication.shared.beginBackgroundTask(withName: "clio-live-end")
        let final = ActivityContent(state: state, staleDate: nil)
        let task = Task { @MainActor in
            defer {
                if grace != .invalid { UIApplication.shared.endBackgroundTask(grace) }
            }
            await activity.update(final)
            do {
                try await Task.sleep(nanoseconds: 4_000_000_000)
            } catch {
                return
            }
            if ending[chat]?.activity.id == activity.id {
                ending.removeValue(forKey: chat)
            }
            await activity.end(final, dismissalPolicy: .after(Date().addingTimeInterval(8 * 60)))
        }
        ending[chat] = (activity, task)
    }

    /// Cards left from a run that ended while Clio was closed.
    static func sweep() {
        for (chat, pending) in ending {
            pending.task.cancel()
            ending.removeValue(forKey: chat)
        }
        for activity in Activity<TurnAttributes>.activities where running[activity.attributes.chat] == nil {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
