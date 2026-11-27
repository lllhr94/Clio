import AgentKit
import Craft
import Foundation
import XCTest
@testable import Clio

private struct AppPlanMockTool: AgentTool {
    let name: String
    let runCount: AppAtomicCounter

    var spec: ToolSpec {
        ToolSpec(name: name, description: "mock \(name)", parameters: .object(["type": .string("object")]))
    }

    func label(for arguments: JSONValue) -> String { name }

    func run(_ arguments: JSONValue) async throws -> ToolOutput {
        runCount.inc()
        return ToolOutput("ran:\(name)")
    }
}

private final class AppAtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
    func inc() {
        lock.lock(); count += 1; lock.unlock()
    }
}

@MainActor
final class ClioAppPR3ATests: XCTestCase {
    private var savedPolicies: [Grant: Grant.Policy] = [:]

    override func setUp() async throws {
        try await super.setUp()
        for grant in [Grant.desk, .den, .memory, .mcp, .web, .vault] {
            savedPolicies[grant] = grant.policy
        }
    }

    override func tearDown() async throws {
        for (grant, policy) in savedPolicies {
            grant.policy = policy
        }
        savedPolicies.removeAll()
        try await super.tearDown()
    }

    func testGrantGateWrapsAllThreeBranchesWithPlanModeEnforcement() async throws {
        Grant.desk.policy = .allow
        Grant.mcp.policy = .allow

        let ledger = LivePlanModeLedger()
        ledger.setPlanMode(true, for: "bot-1")

        let writeCount = AppAtomicCounter()
        let readCount = AppAtomicCounter()
        let unknownCount = AppAtomicCounter()
        let internalCount = AppAtomicCounter()
        let mcpCount = AppAtomicCounter()

        let rawTools: [AgentTool] = [
            AppPlanMockTool(name: "write_file", runCount: writeCount),         // Branch 3: LiveGatedTool
            AppPlanMockTool(name: "read_file", runCount: readCount),           // Branch 3: allowed read-only on desk
            AppPlanMockTool(name: "custom_unmapped_x", runCount: unknownCount),// Branch 2: Asking
            AppPlanMockTool(name: "update_plan", runCount: internalCount),     // Branch 1: internalTools
            AppPlanMockTool(name: "mcp_demo_read", runCount: mcpCount),        // Branch 3: MCP hard-blocked
        ]

        let gated = Grant.gate(
            rawTools,
            workspace: ["write_file": .desk, "read_file": .desk],
            executionChat: "bot-1",
            hostID: "desk",
            hostKind: "desk",
            planModeActive: { ledger.isRestricted("bot-1") }
        )

        XCTAssertEqual(gated.count, rawTools.count)
        let byName = Dictionary(uniqueKeysWithValues: gated.map { ($0.spec.name, $0) })

        // Branch 3 mutating tool blocked.
        let writeOut = try await XCTUnwrap(byName["write_file"]).run(.object([:]))
        XCTAssertTrue(writeOut.isError)
        XCTAssertEqual(writeCount.value, 0)

        // Branch 3 read-only desk tool allowed.
        let readOut = try await XCTUnwrap(byName["read_file"]).run(.object([:]))
        XCTAssertFalse(readOut.isError)
        XCTAssertEqual(readCount.value, 1)

        // Branch 2 unmapped custom tool blocked even though it uses Asking.
        let unknownOut = try await XCTUnwrap(byName["custom_unmapped_x"]).run(.object([:]))
        XCTAssertTrue(unknownOut.isError)
        XCTAssertEqual(unknownCount.value, 0)

        // Branch 1 internal `update_plan` allowed.
        let planOut = try await XCTUnwrap(byName["update_plan"]).run(.object([:]))
        XCTAssertFalse(planOut.isError)
        XCTAssertEqual(internalCount.value, 1)

        // Branch 3 MCP tool hard-blocked in Plan mode.
        let mcpOut = try await XCTUnwrap(byName["mcp_demo_read"]).run(.object([:]))
        XCTAssertTrue(mcpOut.isError)
        XCTAssertEqual(mcpCount.value, 0)

        // Switching Plan mode OFF restores write_file immediately without mutating Grant.desk.
        XCTAssertEqual(Grant.desk.policy, .allow)
        ledger.setPlanMode(false, for: "bot-1")
        let writeAfterUnlock = try await XCTUnwrap(byName["write_file"]).run(.object([:]))
        XCTAssertFalse(writeAfterUnlock.isError)
        XCTAssertEqual(writeCount.value, 1)
    }

    func testTeamModelPlanModeIsolatesGlobalGrantsAndBlocksMemoryWriteAndPendingApprovals() {
        let team = TeamModel()
        team.phase = .demo
        Grant.desk.policy = .allow
        Grant.memory.policy = .allow

        let key = TeamModel.key(bot: "plan-test-bot-\(UUID().uuidString.lowercased())")
        XCTAssertFalse(team.isPlanModeActive(for: key))
        XCTAssertTrue(team.canWriteMemories(beforeCompressing: key))

        // Enabling Plan mode does NOT mutate global Grant policies, yet blocks memory writes.
        team.setPlanMode(true, in: key)
        XCTAssertTrue(team.isPlanModeActive(for: key))
        XCTAssertEqual(Grant.desk.policy, .allow)
        XCTAssertEqual(Grant.memory.policy, .allow)
        XCTAssertFalse(team.canWriteMemories(beforeCompressing: key))

        // Pending write approval must immediately evaluate as `.reject` when Plan mode is active.
        let writeApproval = Approval(
            id: "appr-write",
            botId: "plan-test-bot",
            roomId: nil,
            chat: key,
            executionChat: key,
            hostID: WorkPlace.desk.hostID,
            boundGrant: .desk,
            tool: "写文件",
            toolName: "write_file",
            reason: "写入配置",
            detail: nil,
            at: Now.ms,
            answerable: true,
            forced: false
        )
        XCTAssertEqual(team.pendingDecision(for: writeApproval), .reject)

        // Plain clarifying `ask_user` approval marked `planReadOnlySafe` waits even when `.vault` is `.ask`;
        // secret/unverified `ask_user` approval is rejected immediately.
        Grant.vault.policy = .ask
        let plainAskApproval = Approval(
            id: "appr-ask-plain",
            botId: "plan-test-bot",
            roomId: nil,
            chat: key,
            executionChat: key,
            hostID: nil,
            boundGrant: .vault,
            tool: "提问",
            toolName: "ask_user",
            reason: "先确认范围",
            detail: nil,
            at: Now.ms,
            answerable: true,
            forced: false,
            planReadOnlySafe: true
        )
        XCTAssertEqual(team.pendingDecision(for: plainAskApproval), .wait)

        let secretAskApproval = Approval(
            id: "appr-ask-secret",
            botId: "plan-test-bot",
            roomId: nil,
            chat: key,
            executionChat: key,
            hostID: nil,
            boundGrant: .vault,
            tool: "填密匣",
            toolName: "ask_user",
            reason: "输入密码",
            detail: nil,
            at: Now.ms,
            answerable: true,
            forced: false,
            planReadOnlySafe: false
        )
        XCTAssertEqual(team.pendingDecision(for: secretAskApproval), .reject)

        // Casual track ignores Plan mode toggle.
        let casualKey = "casual-plan-test-bot"
        team.setPlanMode(true, in: casualKey)
        XCTAssertFalse(team.isPlanModeActive(for: casualKey))

        // Disabling Plan mode restores memory write eligibility immediately.
        team.setPlanMode(false, in: key)
        XCTAssertFalse(team.isPlanModeActive(for: key))
        XCTAssertTrue(team.canWriteMemories(beforeCompressing: key))
    }

    func testPlanRecordRevisionAndTurnIDGuardUnlockPlanAndExecute() {
        let team = TeamModel()
        team.phase = .ready
        let bot = BotInfo(id: "plan-bot-\(UUID().uuidString.lowercased())", name: "规划助手")
        team.bots = [bot]
        let key = TeamModel.key(bot: bot.id)
        defer {
            team.stop(key)
            ChatDisk.finishWrites()
            Disk.remove(Disk.chatFile(key))
            Disk.remove(TeamModel.optionsFile(key))
        }

        team.setPlanMode(true, in: key)
        team.setPlan(key, [TeamModel.PlanStep(text: "第一步：调研结构", state: "todo")], turnID: "turn-1")
        let firstRecord = team.planRecords[key]
        XCTAssertNotNil(firstRecord)
        XCTAssertEqual(firstRecord?.turnID, "turn-1")

        // Updating plan bumps revision monotonically.
        team.setPlan(key, [
            TeamModel.PlanStep(text: "第一步：调研结构", state: "done"),
            TeamModel.PlanStep(text: "第二步：实施改动", state: "todo"),
        ], turnID: "turn-2")
        let secondRecord = team.planRecords[key]
        XCTAssertNotNil(secondRecord)
        XCTAssertGreaterThan(secondRecord?.revision ?? 0, firstRecord?.revision ?? 0)
        XCTAssertEqual(secondRecord?.turnID, "turn-2")

        // Stale revision or wrong turnID MUST NOT unlock Plan mode.
        XCTAssertFalse(team.unlockPlanAndExecute(chat: key, revision: firstRecord?.revision ?? 0, turnID: "turn-1"))
        XCTAssertTrue(team.isPlanModeActive(for: key))
        XCTAssertFalse(team.unlockPlanAndExecute(chat: key, revision: secondRecord?.revision ?? 0, turnID: "turn-wrong"))
        XCTAssertTrue(team.isPlanModeActive(for: key))

        // Inherited read-only sub-companion MUST NOT self-unlock.
        team.livePlanModeLedger.setInheritedReadOnly(true, for: key)
        XCTAssertFalse(team.unlockPlanAndExecute(chat: key, revision: secondRecord?.revision ?? 0, turnID: "turn-2"))
        XCTAssertTrue(team.isPlanModeActive(for: key))
        team.livePlanModeLedger.setInheritedReadOnly(false, for: key)

        // Advancing to a newer turn without updating the plan invalidates the older turn's plan card.
        team.activePlanTurnIDs[key] = "turn-3"
        XCTAssertFalse(team.unlockPlanAndExecute(chat: key, revision: secondRecord?.revision ?? 0, turnID: "turn-2"))
        XCTAssertTrue(team.isPlanModeActive(for: key))
        team.activePlanTurnIDs[key] = "turn-2"

        // Exact revision + active turnID + current plan session unlocks Plan mode cleanly.
        XCTAssertTrue(team.unlockPlanAndExecute(chat: key, revision: secondRecord?.revision ?? 0, turnID: "turn-2"))
        XCTAssertFalse(team.isPlanModeActive(for: key))
        team.stop(key)
    }

    func testRecallToolUsesZeroWriteRecallReadOnlyInPlanMode() async throws {
        let team = TeamModel()
        team.phase = .demo
        Grant.memory.policy = .allow
        let bot = BotInfo(id: "recall-bot-\(UUID().uuidString.lowercased())", name: "回忆助手")
        team.bots = [bot]
        let key = TeamModel.key(bot: bot.id)
        team.memories = [
            Memory(id: "m-deep", text: "用户偏好深色纸墨主题", at: 1000, deep: true, used: 1000),
        ]

        team.setPlanMode(true, in: key)
        let builtTools = team.tools(for: bot, key: key, canSee: false, workplace: .desk)
        let recallTool = try XCTUnwrap(builtTools.first { $0.spec.name == "recall" })

        let output = try await recallTool.run(.object(["query": .string("纸墨")]))
        XCTAssertFalse(output.isError)
        // Must remain deep with unchanged `used` timestamp (zero-write guarantee).
        let stored = try XCTUnwrap(team.memories.first { $0.id == "m-deep" })
        XCTAssertEqual(stored.deep, true)
        XCTAssertEqual(stored.used, 1000)
    }
}
