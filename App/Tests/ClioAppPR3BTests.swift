import AgentKit
import Craft
import Foundation
import XCTest
@testable import Clio

private struct AppPR3BMockTool: AgentTool {
    let name: String
    let isReadOnlySafe: Bool
    let hasSideEffects: Bool
    let runCount: AppPR3BCounter

    var spec: ToolSpec {
        ToolSpec(name: name, description: "mock \(name)", parameters: .object(["type": .string("object")]))
    }

    func label(for arguments: JSONValue) -> String { name }

    func run(_ arguments: JSONValue) async throws -> ToolOutput {
        runCount.inc()
        return ToolOutput("ok:\(name)")
    }
}

private final class AppPR3BCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
    func inc() {
        lock.lock(); storage += 1; lock.unlock()
    }
}

@MainActor
final class ClioAppPR3BTests: XCTestCase {
    private var savedPolicies: [Grant: Grant.Policy] = [:]

    override func setUp() async throws {
        try await super.setUp()
        for grant in [Grant.desk, .memory, .web] {
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

    private func makeTempStore() throws -> (URL, TaskStore) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clio-app-pr3b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = dir.appendingPathComponent("clio-tasks.db")
        return (dir, TaskStore(canonicalTeamDirectory: dir, projectionDatabaseURL: db))
    }

    func testSideEffectRecorderInsideGrantGateDoesNotRecordWhenPlanModeBlocksWrite() async throws {
        let (dir, store) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        Grant.desk.policy = .allow

        let (thread, attempt) = try store.createThread(
            stableParentChatID: "bot-parent",
            askerBotID: "parent",
            helperBotID: "helper",
            helperBotName: "助手",
            taskPrompt: "规划调研",
            inheritedPlanMode: true,
            taintedIn: false
        )

        let ledger = LivePlanModeLedger()
        ledger.setPlanMode(true, for: "bot-parent")
        ledger.setDelegationParent("bot-parent", for: thread.threadID)

        let writeCounter = AppPR3BCounter()
        let rawWrite = AppPR3BMockTool(name: "write_file", isReadOnlySafe: false, hasSideEffects: true, runCount: writeCounter)
        let recorded = SideEffectRecordingTool(inner: rawWrite, threadID: thread.threadID, attemptID: attempt.attemptID, store: store)

        let gated = Grant.gate(
            [recorded],
            workspace: ["write_file": .desk],
            executionChat: thread.threadID,
            hostID: "desk",
            hostKind: "desk",
            planModeActive: { ledger.isRestricted(thread.threadID) }
        )

        let out = try await XCTUnwrap(gated.first).run(.object(["path": .string("blocked.txt")]))
        XCTAssertTrue(out.isError)
        XCTAssertEqual(writeCounter.value, 0)

        // Because Plan mode blocked before `SideEffectRecordingTool.run`, the attempt stays proven side-effect-free!
        let reloaded = try XCTUnwrap(store.thread(id: thread.threadID))
        XCTAssertEqual(reloaded.latestAttempt?.provenSideEffectFree, true)
        XCTAssertTrue(reloaded.latestAttempt?.pendingSideEffects.isEmpty ?? false)
    }

    func testIdempotentDeliveryPropagatesBidirectionalTaintToParentEvenWhenArchived() throws {
        let (dir, store) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let manager = SubtaskManager(store: store)
        let team = TeamModel()
        team.phase = .demo
        let parentBot = BotInfo(id: "parent-b-\(UUID().uuidString.lowercased())", name: "主旅伴")
        let helperBot = BotInfo(id: "helper-b-\(UUID().uuidString.lowercased())", name: "副旅伴")
        team.bots = [parentBot, helperBot]
        let parentKey = TeamModel.key(bot: parentBot.id)
        team.archived.insert(parentKey)

        let (thread, attempt) = try store.createThread(
            stableParentChatID: parentKey,
            askerBotID: parentBot.id,
            helperBotID: helperBot.id,
            helperBotName: helperBot.name,
            taskPrompt: "查网页资料",
            inheritedPlanMode: false,
            taintedIn: false
        )
        let (finished, eventID) = try store.finishAttempt(
            threadID: thread.threadID,
            attemptID: attempt.attemptID,
            status: .succeeded,
            resultText: "已汇总网页结论",
            taintedOut: true
        )

        XCTAssertFalse(team.taint.isTainted(parentKey))
        let countBefore = team.entries[parentKey]?.count ?? 0

        // First delivery injects once and taints parent conversation.
        XCTAssertTrue(manager.deliverIdempotentlyToParent(thread: finished, attemptID: attempt.attemptID, eventID: eventID, team: team))
        XCTAssertTrue(team.taint.isTainted(parentKey))
        XCTAssertTrue(team.isTurnMemoryTainted(parentKey))
        XCTAssertEqual(team.entries[parentKey]?.count, countBefore + 1)
        XCTAssertEqual(team.entries[parentKey]?.last?.tainted, true)

        // Second delivery with same `eventID` is a strict no-op (zero duplicate message).
        XCTAssertFalse(manager.deliverIdempotentlyToParent(thread: finished, attemptID: attempt.attemptID, eventID: eventID, team: team))
        XCTAssertEqual(team.entries[parentKey]?.count, countBefore + 1)
    }

    func testStopScopeRespectsRemoteHillsPreferenceAndIsolatesSubtasks() throws {
        let (dir, store) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let manager = SubtaskManager(store: store)
        let team = TeamModel()
        team.phase = .demo
        let parentKey = TeamModel.key(bot: "main-bot-\(UUID().uuidString.lowercased())")

        let (localThread, _) = try store.createThread(
            stableParentChatID: parentKey,
            askerBotID: "main-bot",
            helperBotID: "h1",
            helperBotName: "本地助手",
            taskPrompt: "本地分析",
            inheritedPlanMode: false,
            taintedIn: false,
            hostCode: nil
        )
        let (remoteThread, _) = try store.createThread(
            stableParentChatID: parentKey,
            askerBotID: "main-bot",
            helperBotID: "h2",
            helperBotName: "远端助手",
            taskPrompt: "服务器检查",
            inheritedPlanMode: false,
            taintedIn: false,
            hostCode: "hill:prod-1"
        )
        manager.refresh()

        XCTAssertEqual(manager.activeThreads(for: parentKey).count, 2)
        XCTAssertTrue(manager.hasActiveRemoteHillsTask(for: parentKey))

        // Stopping main-only preserves independent async subtask approvals!
        let subtaskApproval = Approval(
            id: "appr-subtask-1",
            botId: "h2",
            roomId: nil,
            chat: parentKey,
            executionChat: remoteThread.latestAttempt?.attemptID,
            hostID: "hill:prod-1",
            boundGrant: .hills,
            tool: "远端命令",
            toolName: "ssh_run",
            reason: "检查状态",
            detail: nil,
            at: Now.ms,
            answerable: true,
            forced: false
        )
        team.approvals = [subtaskApproval]
        team.stop(parentKey)
        XCTAssertEqual(team.approvals.map(\.id), ["appr-subtask-1"])

        // Stopping local subtasks ONLY leaves the remote Hills task AND its approval untouched.
        manager.stopSubtasks(for: parentKey, includeRemoteHills: false, team: team)
        XCTAssertEqual(store.thread(id: localThread.threadID)?.status, .cancelled)
        XCTAssertEqual(store.thread(id: remoteThread.threadID)?.status, .running)
        XCTAssertEqual(team.approvals.map(\.id), ["appr-subtask-1"])

        // Explicitly stopping including remote Hills cancels the remaining remote task and clears its approval.
        manager.stopSubtasks(for: parentKey, includeRemoteHills: true, team: team)
        XCTAssertEqual(store.thread(id: remoteThread.threadID)?.status, .cancelled)
        XCTAssertTrue(manager.activeThreads(for: parentKey).isEmpty)
        XCTAssertTrue(team.approvals.isEmpty)
    }

    func testPendingQuestionTwoPhaseNotificationAnswerAndIdempotentResume() throws {
        let (dir, store) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let manager = SubtaskManager(store: store)
        let team = TeamModel()
        team.phase = .ready
        let bot = BotInfo(id: "q-bot-\(UUID().uuidString.lowercased())", name: "问答助手")
        team.bots = [bot]
        let key = TeamModel.key(bot: bot.id)
        defer {
            team.stop(key)
            ChatDisk.finishWrites()
            Disk.remove(Disk.chatFile(key))
            Disk.remove(TeamModel.optionsFile(key))
        }

        let saved = manager.persistQuestion(
            questionID: "q-app-1",
            formID: UUID(),
            chatKey: key,
            botName: bot.name,
            title: "输出方式",
            promptText: "需要哪种格式？",
            fieldKey: "format",
            options: ["摘要", "详版"],
            requiresForeground: false
        )
        XCTAssertNotNil(saved)
        XCTAssertEqual(store.pendingQuestion(id: "q-app-1")?.state, .pending)

        // Phase 1 commits `.answered` with deterministic `resumeAttemptID`.
        let ok = manager.recordNotificationAnswer(questionID: "q-app-1", answerText: "摘要", answerID: "ans-app-1", team: nil)
        XCTAssertTrue(ok)
        let answered = try XCTUnwrap(store.pendingQuestion(id: "q-app-1"))
        XCTAssertEqual(answered.state, .answered)
        XCTAssertEqual(answered.resumeAttemptID, PendingQuestion.deterministicResumeAttemptID(questionID: "q-app-1", answerID: "ans-app-1"))

        // Draining when unlocked marks `.consumed` and does not re-dispatch on second drain.
        if AppLock.isCurrentlyUnlocked {
            manager.drainPendingQuestionResumes(team: team)
            XCTAssertEqual(store.pendingQuestion(id: "q-app-1")?.state, .consumed)
            manager.drainPendingQuestionResumes(team: team)
            XCTAssertEqual(store.pendingQuestion(id: "q-app-1")?.state, .consumed)
        }
        team.stop(key)
    }
}
