import Craft
import Foundation
import XCTest

final class CasualTrackTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clio-casual-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testAppendOnlyEntriesAndPermanentDeletionTombstonesNeverResurrect() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CasualTrackStore(canonicalTeamDirectory: root)

        let e1 = CasualEntry(id: "e1", botID: "bot1", role: .user, text: "早安", createdAtMs: 100)
        let e2 = CasualEntry(id: "e2", botID: "bot1", role: .assistant, text: "早呀", createdAtMs: 200)
        XCTAssertTrue(try store.appendEntry(e1))
        XCTAssertTrue(try store.appendEntry(e2))
        XCTAssertEqual(store.entries(for: "bot1").map(\.id), ["e1", "e2"])
        XCTAssertEqual(store.projectedEntryCount(for: "bot1"), 2)

        // Permanently delete e1 via Canonical tombstone.
        try store.permanentlyDelete(entryID: "e1", botID: "bot1", nowMs: 300)
        XCTAssertEqual(store.entries(for: "bot1").map(\.id), ["e2"])
        XCTAssertEqual(store.projectedEntryCount(for: "bot1"), 1)

        // Re-appending a tombstoned entry is blocked.
        XCTAssertFalse(try store.appendEntry(e1))

        // Restoring an older archive containing e1 + a new archive tombstone for e2 keeps e1 deleted AND suppresses e2.
        let e3 = CasualEntry(id: "e3", botID: "bot1", role: .user, text: "午好", createdAtMs: 400)
        let merged = try store.mergeRestoredArchive(
            botID: "bot1",
            archiveEntries: [e1, e2, e3],
            archiveTombstones: [CasualTombstone(entryID: "e2", deletedAtMs: 350)]
        )
        XCTAssertEqual(merged.map(\.id), ["e3"])
        XCTAssertEqual(store.projectedEntryCount(for: "bot1"), 1)
    }

    func testCasualSendQueueSwitchTrackCancelsCountdownAndRetainsQuietDraft() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CasualTrackStore(canonicalTeamDirectory: root)
        let queue = CasualSendQueue(botID: "bot1", casualSessionID: "sess-1", store: store, mergeWindowSeconds: 2.5)

        let dispatched = AtomicFlag()
        try queue.enqueue("第一句") { _ in dispatched.set() }
        try queue.enqueue("第二句") { _ in dispatched.set() }

        // Switching to formal chat bumps trackEpoch, cancels timer, and preserves text in Canonical draft.
        let epochBefore = queue.currentTrackEpoch
        let keptDraft = queue.cancelForTrackSwitch()
        XCTAssertGreaterThan(queue.currentTrackEpoch, epochBefore)
        XCTAssertEqual(keptDraft?.segments, ["第一句", "第二句"])
        XCTAssertEqual(store.loadDraft(botID: "bot1")?.combinedText, "第一句\n第二句")

        // Stale flush with pre-switch epoch is a strict no-op (never leaks into formal chat or fires network).
        let staleResult = await queue.flushNow(expectedEpoch: epochBefore) { _ in dispatched.set() }
        XCTAssertNil(staleResult)
        XCTAssertFalse(dispatched.isSet)
    }

    func testTwoStepPreWriteCrashWindowsDeterministicRecovery() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CasualTrackStore(canonicalTeamDirectory: root)

        // Window 1: Crash before Step 1 (still in debounce) -> text stays in Canonical draft, zero auto-send.
        try store.saveDraft(CasualDraft(botID: "bot-w1", casualSessionID: "s1", segments: ["未发完的话"]))

        // Window 2: Crash after Step 1 (`queued_before_send`), before Step 2 (`in_flight`).
        struct SimulatedStep2Failure: Error {}
        store.simulateOutboxWriteFailure = { batch in
            batch.state == .inFlight ? SimulatedStep2Failure() : nil
        }
        let queueW2 = CasualSendQueue(botID: "bot-w2", casualSessionID: "s2", store: store, mergeWindowSeconds: 0.05)
        let networkCalledW2 = AtomicFlag()
        try queueW2.enqueue("只落了第一步") { _ in networkCalledW2.set() }
        let failedStep2 = await queueW2.flushNow { _ in networkCalledW2.set() }
        XCTAssertNil(failedStep2)
        XCTAssertFalse(networkCalledW2.isSet, "Network dispatch MUST NOT start if Step 2 in_flight commit fails")
        store.simulateOutboxWriteFailure = nil

        // Window 3: Crash after Step 2 (`in_flight` committed on disk, whether network sent or not).
        let step1W3 = try store.commitStep1QueuedBeforeSend(
            botID: "bot-w3",
            casualSessionID: "s3",
            segments: ["已落第二步"],
            trackEpoch: 0,
            batchID: "batch-w3",
            isEpochCurrent: { true }
        )
        _ = try store.commitStep2MarkInFlight(batchID: step1W3.batchID)

        // Cold restart: verify ALL 3 crash windows classify deterministically!
        let restarted = CasualTrackStore(canonicalTeamDirectory: root)
        let recovery = restarted.reconcileOnColdStart()

        XCTAssertEqual(recovery.restoredDrafts.map(\.botID), ["bot-w1"])
        XCTAssertEqual(recovery.batchesReadyForInitialSend.map(\.botID), ["bot-w2"])
        XCTAssertEqual(recovery.batchesReadyForInitialSend.first?.state, .queuedBeforeSend)
        XCTAssertEqual(recovery.batchesNeedingReconcile.map(\.batchID), ["batch-w3"])
        XCTAssertEqual(restarted.loadOutboxBatch(batchID: "batch-w3")?.state, .needsReconcile)

        // Window 2 batch can now safely advance via Step 2 with the exact same `batchID`.
        let w2BatchID = try XCTUnwrap(recovery.batchesReadyForInitialSend.first?.batchID)
        let advanced = try restarted.commitStep2MarkInFlight(batchID: w2BatchID)
        XCTAssertEqual(advanced.batchID, w2BatchID)
        XCTAssertEqual(advanced.state, .inFlight)

        // Window 3 `needs_reconcile` batch cannot silently jump back to `in_flight`.
        XCTAssertThrowsError(try restarted.commitStep2MarkInFlight(batchID: "batch-w3"))
    }

    func testCasualTrackMemorySkillAndStickerBoundaries() {
        XCTAssertFalse(CasualTrackPolicy.allowsAutomaticMemoryOrExperienceWrite(isCasualTrack: true))
        XCTAssertTrue(CasualTrackPolicy.allowsAutomaticMemoryOrExperienceWrite(isCasualTrack: false))
        XCTAssertTrue(CasualTrackPolicy.allowsExplicitUserPromotionToMemoryCandidate(userInitiated: true))
        XCTAssertFalse(CasualTrackPolicy.allowsExplicitUserPromotionToMemoryCandidate(userInitiated: false))

        let rawSkills = ["quiet-musing", "user-guide", "daily-helper", "writing-coach"]
        let filtered = CasualTrackPolicy.filterSkills(rawSkills, id: { $0 })
        XCTAssertEqual(filtered, ["daily-helper", "writing-coach"])

        XCTAssertTrue(CasualTrackPolicy.isToolAllowed("web_search"))
        XCTAssertFalse(CasualTrackPolicy.isToolAllowed("shell"))
        XCTAssertFalse(CasualTrackPolicy.isToolAllowed("write_file"))
        XCTAssertFalse(CasualTrackPolicy.isToolAllowed("remember"))
        XCTAssertFalse(CasualTrackPolicy.isToolAllowed("record_experience"))

        // Stickers strictly capped at 1 per turn and limited to Casual Track.
        XCTAssertTrue(CasualTrackPolicy.allowsSticker(usedInCurrentTurn: 0, isCasualTrack: true))
        XCTAssertFalse(CasualTrackPolicy.allowsSticker(usedInCurrentTurn: 1, isCasualTrack: true))
        XCTAssertFalse(CasualTrackPolicy.allowsSticker(usedInCurrentTurn: 0, isCasualTrack: false))
    }
}

private final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isSet: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}
