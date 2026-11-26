@testable import Craft
import Foundation
import XCTest

final class MemoryRevisionStoreTests: XCTestCase {
    private func makeBook(texts: [String], generation: UInt64 = 0, suppressed: [String] = []) -> CanonicalMemoryBook {
        let items = texts.enumerated().map { idx, text in
            CanonicalMemoryItem(id: "m-\(idx + 1)", text: text, at: Double(1_000 + idx))
        }
        return CanonicalMemoryBook(
            memories: items,
            suppressedFlushHashes: suppressed,
            generation: generation
        )
    }

    func testColdStartCrashRecoveryFinalizesRollsBackAndDiscardsStaleJournal() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rev-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let memURL = dir.appendingPathComponent("memory.json")
        let retractedURL = dir.appendingPathComponent("memory-retracted.json")
        let revDir = dir.appendingPathComponent("memory-revisions", isDirectory: true)
        let store = MemoryRevisionStore(memoryFileURL: memURL, retractedFileURL: retractedURL, revisionsDirectoryURL: revDir)

        // Commit generation 1 & generation 2 cleanly.
        let c1 = try store.commitWithJournal(makeBook(texts: ["喜欢抹茶", "住在北京"]), snapshotReason: "manual", nowMs: 1_000)
        let c2 = try store.commitWithJournal(makeBook(texts: ["喜欢抹茶", "住在北京", "养了一只橘猫"]), nowMs: 2_000)
        XCTAssertEqual(c2.book.generation, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.journalFileURL.path))

        // Case 1: Crash after writing memory.json (diskSHA == postCommitSHA256) -> .finalizedCommittedJournal
        let diskData2 = try Data(contentsOf: memURL)
        let diskSHA2 = MemoryRevisionStore.sha256Hex(diskData2)
        let matchingJournal = MemoryPendingJournal(
            id: "j-match",
            phase: .prepared,
            targetCanonicalGeneration: 2,
            preCommitSHA256: c1.digest,
            postCommitSHA256: diskSHA2,
            preCommitSnapshotID: c1.snapshot?.id
        )
        let encoder = JSONEncoder()
        try encoder.encode(matchingJournal).write(to: store.journalFileURL)
        let outcome1 = try store.recoverPendingJournalIfNeeded(nowMs: 3_000)
        XCTAssertEqual(outcome1, .finalizedCommittedJournal(journalID: "j-match"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.journalFileURL.path))

        // Case 2: Crash before replacing memory.json (diskSHA != postCommitSHA256, diskGen <= targetGen)
        // Must roll back to snapshot AND preserve tombstones in memory-retracted.json so forgotten facts never resurrect!
        let forgottenHash = MemorySafety.retractionHash("喜欢抹茶")
        try encoder.encode([forgottenHash]).write(to: retractedURL)
        let rollbackJournal = MemoryPendingJournal(
            id: "j-rollback",
            phase: .prepared,
            targetCanonicalGeneration: 3,
            preCommitSHA256: diskSHA2,
            postCommitSHA256: String(repeating: "f", count: 64),
            preCommitSnapshotID: c1.snapshot?.id
        )
        try encoder.encode(rollbackJournal).write(to: store.journalFileURL)
        let outcome2 = try store.recoverPendingJournalIfNeeded(extraRetractedHashes: [forgottenHash], nowMs: 4_000)
        XCTAssertEqual(outcome2, .rolledBackToSnapshot(journalID: "j-rollback", snapshotID: c1.snapshot?.id ?? ""))
        let rolledBackBook = try JSONDecoder().decode(CanonicalMemoryBook.self, from: Data(contentsOf: memURL))
        XCTAssertFalse(rolledBackBook.memories.contains(where: { $0.text == "喜欢抹茶" }))
        XCTAssertTrue(rolledBackBook.memories.contains(where: { $0.text == "住在北京" }))

        // Case 3: Stale journal where disk generation (now >= 5) > targetCanonicalGeneration (3) -> discard without overwriting disk!
        _ = try store.commitWithJournal(makeBook(texts: ["最新写入不能丢失"]), nowMs: 5_000)
        _ = try store.commitWithJournal(makeBook(texts: ["最新写入不能丢失", "第二条"]), nowMs: 6_000)
        _ = try store.commitWithJournal(makeBook(texts: ["最新写入不能丢失", "第二条", "第三条"]), nowMs: 7_000)
        let staleJournal = MemoryPendingJournal(
            id: "j-stale",
            phase: .prepared,
            targetCanonicalGeneration: 3,
            preCommitSHA256: "old",
            postCommitSHA256: "old-post",
            preCommitSnapshotID: c1.snapshot?.id
        )
        try encoder.encode(staleJournal).write(to: store.journalFileURL)
        let outcome3 = try store.recoverPendingJournalIfNeeded(nowMs: 8_000)
        XCTAssertEqual(outcome3, .discardedStaleJournal(journalID: "j-stale"))
        let latestDiskBook = try JSONDecoder().decode(CanonicalMemoryBook.self, from: Data(contentsOf: memURL))
        XCTAssertTrue(latestDiskBook.memories.contains(where: { $0.text == "最新写入不能丢失" }))
    }

    func testRollingCapOf10SnapshotsReversibleRestoreAndHealthCounter() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rev-cap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let memURL = dir.appendingPathComponent("memory.json")
        let revDir = dir.appendingPathComponent("memory-revisions", isDirectory: true)
        let store = MemoryRevisionStore(memoryFileURL: memURL, revisionsDirectoryURL: revDir, maxSnapshots: 10)

        var firstSnapID = ""
        for idx in 1...12 {
            let book = makeBook(texts: ["事实-\(idx)"])
            let result = try store.commitWithJournal(book, snapshotReason: "nightly", nowMs: Double(idx * 1_000))
            if idx == 3, let id = result.snapshot?.id {
                firstSnapID = id
            }
        }
        let snaps = store.listSnapshots()
        XCTAssertEqual(snaps.count, 10)
        XCTAssertFalse(firstSnapID.isEmpty)

        // Restore with live tombstone -> creates `pre_restore` and filters out deleted fact.
        let targetSnap = snaps.last!
        let forgottenHash = MemorySafety.retractionHash("事实-2")
        let restored = try store.restoreSnapshot(
            id: targetSnap.id,
            extraRetractedHashes: [forgottenHash],
            nowMs: 20_000
        )
        XCTAssertEqual(restored.preRestoreSnapshot?.reason, "pre_restore")
        XCTAssertFalse(restored.book.memories.contains(where: { $0.text == "事实-2" }))

        _ = store.recordReviewFailure(message: "timeout")
        _ = store.recordReviewFailure(message: "429 rate limit")
        XCTAssertEqual(store.readHealth().consecutiveFailures, 2)
        XCTAssertEqual(store.readHealth().lastFailureMessage, "429 rate limit")
        _ = store.recordReviewSuccess()
        XCTAssertEqual(store.readHealth().consecutiveFailures, 0)
        XCTAssertNil(store.readHealth().lastFailureMessage)
    }
}
