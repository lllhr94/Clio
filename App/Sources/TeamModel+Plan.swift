import AgentKit
import Foundation
import SwiftUI

extension TeamModel {
    func bumpPlanSessionEpoch(for key: String) {
        nextPlanSessionEpoch &+= 1
        planSessionEpochs[key] = nextPlanSessionEpoch
    }

    func setPlan(_ key: String, _ steps: [PlanStep], turnID: String? = nil) {
        nextPlanRevision &+= 1
        let rev = nextPlanRevision
        let resolvedTurnID: String
        if let turnID {
            resolvedTurnID = turnID
            activePlanTurnIDs[key] = turnID
        } else if let active = activePlanTurnIDs[key] {
            resolvedTurnID = active
        } else {
            let fresh = UUID().uuidString
            activePlanTurnIDs[key] = fresh
            resolvedTurnID = fresh
        }
        let sessionEpoch = planSessionEpochs[key, default: 0]
        withAnimation(.smooth) {
            if steps.isEmpty {
                plans[key] = nil
                planRecords[key] = nil
            } else {
                plans[key] = steps
                planRecords[key] = PlanRecord(steps: steps, revision: rev, turnID: resolvedTurnID, sessionEpoch: sessionEpoch)
            }
        }
    }

    func clearPlan(_ key: String) {
        guard plans[key] != nil || planRecords[key] != nil else { return }
        withAnimation(.smooth) {
            plans[key] = nil
            planRecords[key] = nil
        }
    }

    /// True ONLY when `revision` and `turnID` match the active turn's current Plan-session record and the chat is idle.
    func canExecutePlan(chat key: String, revision: UInt64, turnID: String) -> Bool {
        guard phase != .demo, canAcceptInput(for: key) else { return false }
        guard isPlanModeActive(for: key), !livePlanModeLedger.isInheritedReadOnly(key) else { return false }
        guard runs[key] == nil, !helping.contains(key) else { return false }
        guard let record = planRecords[key],
              !record.steps.isEmpty,
              record.revision == revision,
              record.turnID == turnID,
              !turnID.isEmpty,
              record.sessionEpoch == planSessionEpochs[key, default: 0] else {
            return false
        }
        if let currentTurn = activePlanTurnIDs[key], record.turnID != currentTurn {
            return false
        }
        return true
    }

    /// Unlocks Plan mode and starts execution ONLY if the caller presents the exact current `revision` and `turnID`
    /// belonging to the active turn and current Plan session.
    @discardableResult
    func unlockPlanAndExecute(chat key: String, revision: UInt64, turnID: String) -> Bool {
        guard canExecutePlan(chat: key, revision: revision, turnID: turnID) else { return false }
        setPlanMode(false, in: key)
        _ = send(L.t("plan.executePrompt"), photos: [], to: key, userInitiated: true)
        return true
    }

    /// The tool that lays out and ticks off the steps of a longer task, shown as a card above the composer.
    nonisolated static func planTool(key: String, team: TeamModel) -> AgentTool {
        DeskTool(name: "update_plan", description: """
        把一件要好几步才能做完的事列成步骤清单，显示在用户输入框上方，让用户看到进度。三步以上的事开始前先列一次；每做完一步、或开始下一步时再调一次，传完整的清单。
        state 用 todo（还没做）、doing（正在做，同时只有一个）、done（做完）。步骤写成用户看得懂的一句话。简单的事不用列。
        """, parameters: [
            "type": "object",
            "properties": [
                "steps": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "text": ["type": "string"],
                            "state": ["type": "string", "enum": ["todo", "doing", "done"]],
                        ],
                        "required": ["text", "state"],
                    ],
                ],
            ],
            "required": ["steps"],
        ], label: { arguments in
            let steps = arguments["steps"]?.array ?? []
            let done = steps.filter { $0["state"]?.string == "done" }.count
            return "清单：\(done)/\(steps.count)"
        }) { [weak team] arguments in
            let steps = (arguments["steps"]?.array ?? []).compactMap { item -> PlanStep? in
                guard let text = item["text"]?.string, !text.isEmpty else { return nil }
                return PlanStep(text: text, state: item["state"]?.string ?? "todo")
            }
            await team?.setPlan(key, steps)
            let done = steps.filter { $0.state == "done" }.count
            return ToolOutput("清单更新了：\(done)/\(steps.count) 步做完。")
        }
    }
}
