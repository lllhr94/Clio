import AgentKit
import Craft
import Foundation
import XCTest

private struct TaskMockTool: AgentTool {
    let name: String
    let isReadOnlySafe: Bool
    let hasSideEffects: Bool
    let onRun: @Sendable (JSONValue) throws -> ToolOutput

    var spec: ToolSpec {
        ToolSpec(name: name, description: "mock \(name)", parameters: .object(["type": .string("object")]))
    }

    func label(for arguments: JSONValue) -> String { "\(name):\(arguments["path"]?.string ?? "op")" }

    func run(_ arguments: JSONValue) async throws -> ToolOutput {
        try onRun(arguments)
    }
}

final class TaskStoreCanonicalTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clio-taskstore-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testColdStartDistinguishesCleanInterruptedVsPendingSideEffectReconcile() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("clio-tasks.db")
        let store = TaskStore(canonicalTeamDirectory: root, projectionDatabaseURL: dbURL)

        // Thread A: strictly read-only, crashes mid-run -> `.interrupted` (safe one-tap retry).
        let (cleanThread, cleanAttempt) = try store.createThread(
            stableParentChatID: "bot-main",
            askerBotID: "main",
            helperBotID: "researcher",
            helperBotName: "研究员",
            taskPrompt: "查天气",
            inheritedPlanMode: true,
            taintedIn: false
        )
        XCTAssertTrue(cleanThread.threadID.hasPrefix("subtask-"))
        XCTAssertNotEqual(cleanThread.threadID, "bot-researcher")
        let readTool = SideEffectRecordingTool(
            inner: TaskMockTool(name: "read_file", isReadOnlySafe: true, hasSideEffects: false) { _ in ToolOutput("ok") },
            threadID: cleanThread.threadID,
            attemptID: cleanAttempt.attemptID,
            store: store
        )
        _ = try await readTool.run(.object(["path": .string("notes.md")]))

        // Thread B: invokes side-effecting tool that throws/crashes mid-execution -> unclosed `pending_side_effect`.
        let (dirtyThread, dirtyAttempt) = try store.createThread(
            stableParentChatID: "bot-main",
            askerBotID: "main",
            helperBotID: "builder",
            helperBotName: "工匠",
            taskPrompt: "修改文件",
            inheritedPlanMode: false,
            taintedIn: true
        )
        struct SimulatedCrash: Error {}
        let writeTool = SideEffectRecordingTool(
            inner: TaskMockTool(name: "write_file", isReadOnlySafe: false, hasSideEffects: true) { _ in throw SimulatedCrash() },
            threadID: dirtyThread.threadID,
            attemptID: dirtyAttempt.attemptID,
            store: store
        )
        do {
            _ = try await writeTool.run(.object(["path": .string("app.swift")]))
            XCTFail("Expected simulated crash")
        } catch is SimulatedCrash {}

        // Delete SQLite projection to prove Canonical JSON is sole source of truth and DB rebuilds automatically.
        try? FileManager.default.removeItem(at: dbURL)
        let restarted = TaskStore(canonicalTeamDirectory: root, projectionDatabaseURL: dbURL)
        let report = restarted.reconcileOnColdStart()

        XCTAssertEqual(report.interruptedThreads.map(\.threadID), [cleanThread.threadID])
        XCTAssertEqual(report.reconcileRequiredThreads.map(\.threadID), [dirtyThread.threadID])
        XCTAssertEqual(restarted.projectedThreadCount(), 2)

        let reloadedDirty = try XCTUnwrap(restarted.thread(id: dirtyThread.threadID))
        XCTAssertEqual(reloadedDirty.status, .interruptedNeedsReconcile)
        XCTAssertEqual(reloadedDirty.latestAttempt?.hasUnclosedSideEffect, true)

        // Blind one-tap retry on `interrupted_needs_reconcile` MUST be rejected.
        XCTAssertThrowsError(try restarted.retryInterruptedThread(threadID: dirtyThread.threadID, explicitUserReconciled: false)) { err in
            XCTAssertEqual(err as? TaskStoreError, .reconcileRequiredBeforeRetry)
        }
        // Explicit user reconciliation allows creating a fresh retry attempt while preserving taint.
        let (_, retriedDirty) = try restarted.retryInterruptedThread(threadID: dirtyThread.threadID, explicitUserReconciled: true)
        XCTAssertEqual(retriedDirty.status, .running)
        XCTAssertTrue(retriedDirty.taintedIn)

        // Clean `.interrupted` thread allows direct one-tap retry, and active thread rejects duplicate retry.
        let (_, retriedClean) = try restarted.retryInterruptedThread(threadID: cleanThread.threadID, explicitUserReconciled: false)
        XCTAssertEqual(retriedClean.status, .running)
        XCTAssertNotEqual(retriedClean.attemptID, cleanAttempt.attemptID)
        XCTAssertThrowsError(try restarted.retryInterruptedThread(threadID: cleanThread.threadID, explicitUserReconciled: true)) { err in
            XCTAssertEqual(err as? TaskStoreError, .threadAlreadyActive(cleanThread.threadID))
        }
    }

    func testIdempotentParentDeliveryAndBidirectionalTaint() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TaskStore(canonicalTeamDirectory: root)

        let (thread, attempt) = try store.createThread(
            stableParentChatID: "bot-parent",
            askerBotID: "parent",
            helperBotID: "helper",
            helperBotName: "助手",
            taskPrompt: "查网页",
            inheritedPlanMode: false,
            taintedIn: false
        )
        _ = try store.markAttemptTaintedOut(threadID: thread.threadID, attemptID: attempt.attemptID)
        let (finished, eventID) = try store.finishAttempt(
            threadID: thread.threadID,
            attemptID: attempt.attemptID,
            status: .succeeded,
            resultText: "摘要完成",
            taintedOut: true
        )
        XCTAssertEqual(finished.latestAttempt?.isTaintedForParent, true)

        // First delivery succeeds; duplicate replay of same eventID is rejected idempotently.
        XCTAssertTrue(try store.recordParentDelivery(threadID: thread.threadID, attemptID: attempt.attemptID, eventID: eventID))
        XCTAssertFalse(try store.recordParentDelivery(threadID: thread.threadID, attemptID: attempt.attemptID, eventID: eventID))
    }

    func testPendingQuestionTwoPhaseCrashSafeCommitAndForegroundGate() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TaskStore(canonicalTeamDirectory: root)

        // 1. Foreground-required (vault/secret) question rejects background notification answer.
        let secretQ = PendingQuestion(
            questionID: "q-secret",
            chatKey: "bot-main",
            botName: "小克",
            title: "填密匣",
            promptText: "请输入密码",
            requiresForeground: true
        )
        try store.savePendingQuestion(secretQ)
        XCTAssertThrowsError(try store.recordQuestionAnswer(
            questionID: "q-secret",
            answerText: "1234",
            fromBackgroundNotification: true
        )) { err in
            XCTAssertEqual(err as? TaskStoreError, .foregroundRequired)
        }
        XCTAssertEqual(store.pendingQuestion(id: "q-secret")?.state, .pending)

        // 2. Plain question: if Phase 1 disk write fails (e.g. Data Protection locked), stays `.pending`.
        let plainQ = PendingQuestion(
            questionID: "q-plain",
            chatKey: "bot-main",
            botName: "小克",
            title: "选格式",
            promptText: "导出为 Markdown 还是 PDF？",
            options: ["Markdown", "PDF"],
            requiresForeground: false
        )
        try store.savePendingQuestion(plainQ)
        struct LockedDiskError: Error {}
        store.simulateQuestionWriteFailure = { _ in LockedDiskError() }
        XCTAssertThrowsError(try store.recordQuestionAnswer(
            questionID: "q-plain",
            answerText: "PDF",
            answerID: "ans-1",
            fromBackgroundNotification: true
        ))
        store.simulateQuestionWriteFailure = nil
        XCTAssertEqual(store.pendingQuestion(id: "q-plain")?.state, .pending)

        // 3. Phase 1 succeeds: persists `.answered` with deterministic `resumeAttemptID`.
        let answered = try store.recordQuestionAnswer(
            questionID: "q-plain",
            answerText: "PDF",
            answerID: "ans-1",
            fromBackgroundNotification: true
        )
        XCTAssertEqual(answered.state, .answered)
        let expectedResumeID = PendingQuestion.deterministicResumeAttemptID(questionID: "q-plain", answerID: "ans-1")
        XCTAssertEqual(answered.resumeAttemptID, expectedResumeID)

        // 4. Simulate crash between Phase 2a (manifest committed) and Phase 2b (marking consumed):
        let firstClaim = try store.claimQuestionResume(questionID: "q-plain")
        XCTAssertTrue(firstClaim.shouldDispatch)
        XCTAssertEqual(firstClaim.resumeAttemptID, expectedResumeID)

        // Cold restart before `markQuestionConsumed` ran:
        let restarted = TaskStore(canonicalTeamDirectory: root)
        let coldReport = restarted.reconcileOnColdStart()
        XCTAssertEqual(coldReport.unconsumedAnsweredQuestions.map(\.questionID), ["q-plain"])

        // Claiming again yields the EXACT same `resumeAttemptID` with `shouldDispatch == false` (zero duplicate resume!).
        let replayClaim = try restarted.claimQuestionResume(questionID: "q-plain")
        XCTAssertFalse(replayClaim.shouldDispatch)
        XCTAssertEqual(replayClaim.resumeAttemptID, expectedResumeID)

        let consumed = try restarted.markQuestionConsumed(questionID: "q-plain")
        XCTAssertEqual(consumed.state, .consumed)
        XCTAssertThrowsError(try restarted.recordQuestionAnswer(
            questionID: "q-plain",
            answerText: "Markdown",
            answerID: "ans-2",
            fromBackgroundNotification: false
        ))
    }
}
