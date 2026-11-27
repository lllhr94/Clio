import Craft
import Foundation
import XCTest

final class R1ADataIntegrityTests: XCTestCase {
    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clio-r1a-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private final class FreezeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        func set(_ value: Bool) { lock.withLock { flag = value } }
        func get() -> Bool { lock.withLock { flag } }
    }

    private struct SimulatedDiskError: Error {}

    // MARK: - CX-03: TaskStore Write Freeze Barrier & parentConversationID

    func testTaskStoreFreezeBarrierBlocksWritesAndPersistsParentConversationID() throws {
        let dir = try makeTempDir("taskstore-freeze")
        defer { try? FileManager.default.removeItem(at: dir) }

        let frozen = FreezeBox()
        let store = TaskStore(
            canonicalTeamDirectory: dir,
            projectionDatabaseURL: dir.appendingPathComponent("tasks.db"),
            isWriteFrozen: { frozen.get() }
        )

        let (thread, _) = try store.createThread(
            stableParentChatID: "bot-main",
            parentConversationID: "conv-1234",
            askerBotID: "main",
            helperBotID: "helper",
            helperBotName: "助手",
            taskPrompt: "检查日志",
            inheritedPlanMode: false,
            taintedIn: false
        )
        XCTAssertEqual(store.thread(id: thread.threadID)?.parentConversationID, "conv-1234")

        // Once backup restore freezes writes, TaskStore rejects all canonical mutations.
        frozen.set(true)
        var barrierRan = false
        store.withWriteBarrier { barrierRan = true }
        XCTAssertTrue(barrierRan)

        XCTAssertThrowsError(try store.createThread(
            stableParentChatID: "bot-main",
            parentConversationID: "conv-5678",
            askerBotID: "main",
            helperBotID: "helper",
            helperBotName: "助手",
            taskPrompt: "被冻结拦截",
            inheritedPlanMode: false,
            taintedIn: false
        )) { error in
            guard case TaskStoreError.writesFrozen = error else {
                return XCTFail("Expected TaskStoreError.writesFrozen, got \(error)")
            }
        }

        let question = PendingQuestion(
            questionID: "q-frozen",
            chatKey: "bot-main",
            botName: "助手",
            title: "确认",
            promptText: "继续吗？",
            fieldKey: "ans"
        )
        XCTAssertThrowsError(try store.savePendingQuestion(question)) { error in
            guard case TaskStoreError.writesFrozen = error else {
                return XCTFail("Expected TaskStoreError.writesFrozen, got \(error)")
            }
        }

        // Unfreezing allows writes again and tests resume claim release on rejected dispatch.
        frozen.set(false)
        _ = try store.savePendingQuestion(question)
        _ = try store.recordQuestionAnswer(
            questionID: "q-frozen",
            answerText: "好的",
            answerID: "ans-1",
            fromBackgroundNotification: true
        )
        let firstClaim = try store.claimQuestionResume(questionID: "q-frozen")
        XCTAssertTrue(firstClaim.shouldDispatch)
        XCTAssertTrue(store.isResumeDispatched(resumeAttemptID: firstClaim.resumeAttemptID))

        store.releaseQuestionResumeClaim(resumeAttemptID: firstClaim.resumeAttemptID)
        XCTAssertFalse(store.isResumeDispatched(resumeAttemptID: firstClaim.resumeAttemptID))
        let secondClaim = try store.claimQuestionResume(questionID: "q-frozen")
        XCTAssertTrue(secondClaim.shouldDispatch)
    }

    // MARK: - CX-11: HostBindingBook Removal

    func testHostBindingBookRemovesEphemeralAttemptBindings() {
        let book = HostBindingBook()
        for i in 0..<25 {
            let key = "attempt-\(i)"
            book.set("desk", for: key)
            XCTAssertEqual(book.current(for: key), "desk")
            book.remove(for: key)
            XCTAssertNil(book.current(for: key))
        }
        XCTAssertEqual(book.count, 0)
    }

    // MARK: - CX-07 & Backup Safety: CasualTrackStore Atomic Reply Write, Freeze & Demotion

    func testCasualAppendEntriesAndCompleteOutboxLeavesBatchOpenOnEntryWriteFailure() throws {
        let dir = try makeTempDir("casual-atomic-reply")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = CasualTrackStore(
            canonicalTeamDirectory: dir,
            projectionDatabaseURL: dir.appendingPathComponent("casual.db")
        )
        let step1 = try store.commitStep1QueuedBeforeSend(
            botID: "bot-a",
            casualSessionID: "sess-a",
            segments: ["晚安"],
            trackEpoch: 0,
            batchID: "batch-reply-1",
            isEpochCurrent: { true }
        )
        _ = try store.commitStep2MarkInFlight(batchID: step1.batchID)

        // Inject entry write failure: outbox MUST remain `.inFlight` (never marked `.completed`).
        store.simulateEntryWriteFailure = { _ in SimulatedDiskError() }
        let reply1 = CasualEntry(id: "a-batch-reply-1-0", botID: "bot-a", role: .assistant, text: "晚安呀", batchID: step1.batchID)
        let reply2 = CasualEntry(id: "a-batch-reply-1-1", botID: "bot-a", role: .assistant, text: "早点睡", batchID: step1.batchID)
        XCTAssertThrowsError(try store.appendEntriesAndCompleteOutbox(entries: [reply1, reply2], batchID: step1.batchID))
        XCTAssertEqual(store.loadOutboxBatch(batchID: step1.batchID)?.state, .inFlight)
        XCTAssertTrue(store.entries(for: "bot-a").isEmpty)

        // Once disk recovers, atomic write persists all segments and closes batch; replay deduplicates by ID.
        store.simulateEntryWriteFailure = nil
        let completed = try store.appendEntriesAndCompleteOutbox(entries: [reply1, reply2], batchID: step1.batchID)
        XCTAssertEqual(completed.state, .completed)
        XCTAssertEqual(store.entries(for: "bot-a").map(\.id), ["a-batch-reply-1-0", "a-batch-reply-1-1"])

        _ = try store.appendEntriesAndCompleteOutbox(entries: [reply1, reply2], batchID: step1.batchID)
        XCTAssertEqual(store.entries(for: "bot-a").count, 2)
    }

    func testCasualDemoteRestoredOutboxBatchesPreventsAutoDispatchAfterBackupRestore() throws {
        let dir = try makeTempDir("casual-restore-demote")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = CasualTrackStore(
            canonicalTeamDirectory: dir,
            projectionDatabaseURL: dir.appendingPathComponent("casual.db")
        )
        let queued = try store.commitStep1QueuedBeforeSend(
            botID: "bot-a",
            casualSessionID: "sess-a",
            segments: ["备份前排队的闲聊"],
            trackEpoch: 0,
            batchID: "batch-queued",
            isEpochCurrent: { true }
        )
        let inFlightStep1 = try store.commitStep1QueuedBeforeSend(
            botID: "bot-a",
            casualSessionID: "sess-a",
            segments: ["备份前在途的闲聊"],
            trackEpoch: 0,
            batchID: "batch-inflight",
            isEpochCurrent: { true }
        )
        _ = try store.commitStep2MarkInFlight(batchID: inFlightStep1.batchID)
        let doneStep1 = try store.commitStep1QueuedBeforeSend(
            botID: "bot-a",
            casualSessionID: "sess-a",
            segments: ["已完成的闲聊"],
            trackEpoch: 0,
            batchID: "batch-done",
            isEpochCurrent: { true }
        )
        _ = try store.markOutboxCompleted(batchID: doneStep1.batchID)

        let demotedCount = try CasualTrackStore.demoteRestoredOutboxBatches(in: dir)
        XCTAssertEqual(demotedCount, 2)
        XCTAssertEqual(store.loadOutboxBatch(batchID: queued.batchID)?.state, .needsReconcile)
        XCTAssertEqual(store.loadOutboxBatch(batchID: inFlightStep1.batchID)?.state, .needsReconcile)
        XCTAssertEqual(store.loadOutboxBatch(batchID: doneStep1.batchID)?.state, .completed)

        let recovery = store.reconcileOnColdStart()
        XCTAssertTrue(recovery.batchesReadyForInitialSend.isEmpty)
        XCTAssertEqual(Set(recovery.batchesNeedingReconcile.map(\.batchID)), Set([queued.batchID, inFlightStep1.batchID]))
    }

    func testCasualTrackStoreFreezeBarrierBlocksWrites() throws {
        let dir = try makeTempDir("casual-freeze")
        defer { try? FileManager.default.removeItem(at: dir) }

        let frozen = FreezeBox()
        frozen.set(true)
        let store = CasualTrackStore(
            canonicalTeamDirectory: dir,
            projectionDatabaseURL: dir.appendingPathComponent("casual.db"),
            isWriteFrozen: { frozen.get() }
        )
        XCTAssertThrowsError(try store.appendEntry(CasualEntry(botID: "bot-a", role: .user, text: "hi"))) { error in
            guard case CasualTrackError.writesFrozen = error else {
                return XCTFail("Expected CasualTrackError.writesFrozen, got \(error)")
            }
        }
        XCTAssertThrowsError(try store.saveDraft(CasualDraft(botID: "bot-a", casualSessionID: "s", segments: ["hi"])))
    }

    func testCasualSendQueueFlushNowPreservesConcurrentlyEnqueuedSegment() async throws {
        let dir = try makeTempDir("casual-flush-concurrent")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = CasualTrackStore(
            canonicalTeamDirectory: dir,
            projectionDatabaseURL: dir.appendingPathComponent("casual.db")
        )
        let queue = CasualSendQueue(botID: "bot-a", casualSessionID: "sess-1", store: store, mergeWindowSeconds: 5.0)
        try queue.enqueue("第一句") { _ in }

        let injectedConcurrent = FreezeBox()
        // Intercept Step 1 write to simulate a concurrent user message arriving while Step 1 is committing on disk.
        store.simulateOutboxWriteFailure = { [weak queue] batch in
            if batch.state == .queuedBeforeSend && !injectedConcurrent.get() {
                injectedConcurrent.set(true)
                try? queue?.enqueue("并发补发第二句") { _ in }
            }
            return nil
        }

        let dispatched = await queue.flushNow { _ in }
        XCTAssertEqual(dispatched?.segments, ["第一句"])
        XCTAssertEqual(queue.bufferedSegments, ["并发补发第二句"], "Concurrent segment enqueued during Step 1 MUST NOT be dropped")
        XCTAssertEqual(store.loadDraft(botID: "bot-a")?.segments, ["并发补发第二句"])
    }
}
