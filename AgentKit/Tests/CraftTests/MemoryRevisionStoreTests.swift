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

    func testColdStartCrashRecoveryFinalizesRollsBackVerifySHADiscardsStaleAndFirstCommitEmpty() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rev-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let memURL = dir.appendingPathComponent("memory.json")
        let retractedURL = dir.appendingPathComponent("memory-retracted.json")
        let revDir = dir.appendingPathComponent("memory-revisions", isDirectory: true)
        let store = MemoryRevisionStore(memoryFileURL: memURL, retractedFileURL: retractedURL, revisionsDirectoryURL: revDir)
        let encoder = JSONEncoder()

        // First commit crash when pre-commit file did NOT exist (`preCommitExisted == false`) -> roll back to empty!
        try FileManager.default.createDirectory(at: revDir, withIntermediateDirectories: true)
        let partialUncommitted = try encoder.encode(makeBook(texts: ["不该保留的未提交草稿"], generation: 1))
        try partialUncommitted.write(to: memURL)
        let firstCrashJournal = MemoryPendingJournal(
            id: "j-first-crash",
            phase: .prepared,
            targetCanonicalGeneration: 1,
            preCommitSHA256: "",
            postCommitSHA256: String(repeating: "0", count: 64),
            preCommitSnapshotID: nil,
            preCommitExisted: false
        )
        try encoder.encode(firstCrashJournal).write(to: store.journalFileURL)
        let firstOutcome = try store.recoverPendingJournalIfNeeded(nowMs: 500)
        XCTAssertEqual(firstOutcome, .rolledBackToSnapshot(journalID: "j-first-crash", snapshotID: "empty"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: memURL.path))
        XCTAssertTrue(store.hasPendingProjectionRebuild)
        store.clearPendingProjectionRebuild()

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
        try encoder.encode(matchingJournal).write(to: store.journalFileURL)
        let outcome1 = try store.recoverPendingJournalIfNeeded(nowMs: 3_000)
        XCTAssertEqual(outcome1, .finalizedCommittedJournal(journalID: "j-match"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.journalFileURL.path))

        // Case 2: Crash before replacing memory.json -> rolls back via verified preCommitSHA256 snapshot + tombstone union
        let forgottenHash = MemorySafety.retractionHash("喜欢抹茶")
        try encoder.encode([forgottenHash]).write(to: retractedURL)
        let rollbackJournal = MemoryPendingJournal(
            id: "j-rollback",
            phase: .prepared,
            targetCanonicalGeneration: 3,
            preCommitSHA256: diskSHA2,
            postCommitSHA256: String(repeating: "f", count: 64),
            preCommitSnapshotID: c2.snapshot?.id
        )
        // Re-commit generation 2 with a snapshot so `c2Snap` carries `preCommitSHA256 == diskSHA2`
        let c2Snap = try store.saveManualSnapshot(c2.book, reason: "manual", nowMs: 2_500)
        var verifiedRollbackJournal = rollbackJournal
        verifiedRollbackJournal.preCommitSHA256 = c2Snap.canonicalSHA256
        verifiedRollbackJournal.preCommitSnapshotID = c2Snap.id
        try encoder.encode(verifiedRollbackJournal).write(to: store.journalFileURL)

        let outcome2 = try store.recoverPendingJournalIfNeeded(extraRetractedHashes: [forgottenHash], nowMs: 4_000)
        XCTAssertEqual(outcome2, .rolledBackToSnapshot(journalID: "j-rollback", snapshotID: c2Snap.id))
        XCTAssertTrue(store.hasPendingProjectionRebuild)
        store.clearPendingProjectionRebuild()
        let rolledBackBook = try JSONDecoder().decode(CanonicalMemoryBook.self, from: Data(contentsOf: memURL))
        XCTAssertFalse(rolledBackBook.memories.contains(where: { $0.text == "喜欢抹茶" }))
        XCTAssertTrue(rolledBackBook.memories.contains(where: { $0.text == "住在北京" }))

        // Case 3: Mismatched preCommitSHA256 throws .rollbackUnavailable safely rather than restoring wrong file
        let badSHAJournal = MemoryPendingJournal(
            id: "j-bad-sha",
            phase: .prepared,
            targetCanonicalGeneration: 3,
            preCommitSHA256: String(repeating: "e", count: 64),
            postCommitSHA256: String(repeating: "f", count: 64),
            preCommitSnapshotID: c2Snap.id
        )
        try encoder.encode(badSHAJournal).write(to: store.journalFileURL)
        XCTAssertThrowsError(try store.recoverPendingJournalIfNeeded(nowMs: 4_500))
        try? FileManager.default.removeItem(at: store.journalFileURL)

        // Case 4: Stale journal where disk generation > targetCanonicalGeneration -> discard without overwriting disk
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
        let outcome4 = try store.recoverPendingJournalIfNeeded(nowMs: 8_000)
        XCTAssertEqual(outcome4, .discardedStaleJournal(journalID: "j-stale"))
        let latestDiskBook = try JSONDecoder().decode(CanonicalMemoryBook.self, from: Data(contentsOf: memURL))
        XCTAssertTrue(latestDiskBook.memories.contains(where: { $0.text == "最新写入不能丢失" }))
    }

    func testRollingCapEvictsCorruptFilesReversibleRestoreAndHealthCounter() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rev-cap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let memURL = dir.appendingPathComponent("memory.json")
        let revDir = dir.appendingPathComponent("memory-revisions", isDirectory: true)
        let store = MemoryRevisionStore(memoryFileURL: memURL, revisionsDirectoryURL: revDir, maxSnapshots: 10)
        try FileManager.default.createDirectory(at: revDir, withIntermediateDirectories: true)

        // Drop a corrupt `rev-*.json` file: pruning MUST evict it rather than letting it bypass the 10-file cap.
        let corruptSnapURL = revDir.appendingPathComponent("rev-999999999999999-corrupt.json")
        try Data("{corrupt json".utf8).write(to: corruptSnapURL)

        for idx in 1...12 {
            let book = makeBook(texts: ["事实-\(idx)"])
            _ = try store.commitWithJournal(book, snapshotReason: "nightly", nowMs: Double(idx * 1_000))
        }
        let snaps = store.listSnapshots()
        XCTAssertEqual(snaps.count, 10)
        XCTAssertFalse(FileManager.default.fileExists(atPath: corruptSnapURL.path))

        // Restore with live tombstone -> creates `pre_restore`, marks rebuild marker, and filters out deleted fact.
        let targetSnap = snaps.last!
        let forgottenHash = MemorySafety.retractionHash("事实-2")
        let restored = try store.restoreSnapshot(
            id: targetSnap.id,
            extraRetractedHashes: [forgottenHash],
            nowMs: 20_000
        )
        XCTAssertEqual(restored.preRestoreSnapshot?.reason, "pre_restore")
        XCTAssertTrue(store.hasPendingProjectionRebuild)
        store.clearPendingProjectionRebuild()
        XCTAssertFalse(restored.book.memories.contains(where: { $0.text == "事实-2" }))

        _ = store.recordReviewFailure(message: "timeout")
        _ = store.recordReviewFailure(message: "429 rate limit")
        XCTAssertEqual(store.readHealth().consecutiveFailures, 2)
        XCTAssertEqual(store.readHealth().lastFailureMessage, "429 rate limit")
        _ = store.recordReviewSuccess()
        XCTAssertEqual(store.readHealth().consecutiveFailures, 0)
        XCTAssertNil(store.readHealth().lastFailureMessage)
    }

    func testTamperedSnapshotPayloadCorruptHealthAndDirectoryUnreadableCanonical() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rev-tamper-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let memURL = dir.appendingPathComponent("memory.json")
        let revDir = dir.appendingPathComponent("memory-revisions", isDirectory: true)
        let store = MemoryRevisionStore(memoryFileURL: memURL, revisionsDirectoryURL: revDir)

        let c1 = try store.commitWithJournal(makeBook(texts: ["原始记忆"]), snapshotReason: "manual", nowMs: 1_000)
        let snapID = try XCTUnwrap(c1.snapshot?.id)
        let revFiles = try FileManager.default.contentsOfDirectory(at: revDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("rev-") && $0.lastPathComponent.hasSuffix(".json") }
        let snapFile = try XCTUnwrap(revFiles.first)

        // Tamper snapshot `book` without changing `canonicalSHA256` or `bookSHA256` -> restore AND rollback must reject it.
        var tamperedSnap = try JSONDecoder().decode(MemoryRevisionSnapshot.self, from: Data(contentsOf: snapFile))
        tamperedSnap.book.memories[0].text = "被篡改的内容"
        try JSONEncoder().encode(tamperedSnap).write(to: snapFile)

        XCTAssertThrowsError(try store.restoreSnapshot(id: snapID, nowMs: 2_000)) { error in
            XCTAssertEqual(
                error as? MemoryRevisionStoreError,
                .corruptSnapshot("快照 \(snapID) 载荷摘要校验未通过")
            )
        }

        let journal = MemoryPendingJournal(
            id: "j-tamper",
            phase: .prepared,
            targetCanonicalGeneration: 2,
            preCommitSHA256: tamperedSnap.canonicalSHA256,
            postCommitSHA256: String(repeating: "b", count: 64),
            preCommitSnapshotID: snapID
        )
        try JSONEncoder().encode(journal).write(to: store.journalFileURL)
        try? FileManager.default.removeItem(at: store.rollbackBackupURL)
        XCTAssertThrowsError(try store.recoverPendingJournalIfNeeded(nowMs: 3_000))
        try? FileManager.default.removeItem(at: store.journalFileURL)

        // Corrupt health file must throw on throwing APIs and not overwrite disk on readHealth().
        let corruptHealth = Data("{broken".utf8)
        try corruptHealth.write(to: store.healthFileURL)
        XCTAssertThrowsError(try store.readHealthThrowing())
        XCTAssertThrowsError(try store.recordReviewFailureThrowing(message: "err"))
        XCTAssertEqual(store.readHealth().lastRecoveryReason, "health_unreadable")
        XCTAssertEqual(try Data(contentsOf: store.healthFileURL), corruptHealth)

        // Unreadable existing `memory.json` (simulated via directory at memURL) must throw, not treat as missing.
        let badDir = FileManager.default.temporaryDirectory.appendingPathComponent("rev-baddir-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: badDir) }
        let dirMemURL = badDir.appendingPathComponent("memory.json", isDirectory: true)
        try FileManager.default.createDirectory(at: dirMemURL, withIntermediateDirectories: true)
        let badStore = MemoryRevisionStore(memoryFileURL: dirMemURL, revisionsDirectoryURL: badDir.appendingPathComponent("revisions"))
        XCTAssertThrowsError(try badStore.commitWithJournal(makeBook(texts: ["不可覆写"]), nowMs: 4_000))
    }

    func testMultiIDProcessedDeterminismCorruptJournalPreservedAndBlankDigestsRejected() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rev-det-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let memURL = dir.appendingPathComponent("memory.json")
        let revDir = dir.appendingPathComponent("memory-revisions", isDirectory: true)
        let store = MemoryRevisionStore(memoryFileURL: memURL, revisionsDirectoryURL: revDir)

        var book1 = makeBook(texts: ["多条已处理去重记录"])
        book1.processed = [
            "2026-11-26": Set(["e1", "e2", "e3", "e4", "e5"]),
            "2026-11-27": Set(["e6", "e7", "e8"]),
        ]
        let c1 = try store.commitWithJournal(book1, snapshotReason: "manual", nowMs: 1_000)
        let snap1 = try XCTUnwrap(c1.snapshot)
        let snapBookSHA = try XCTUnwrap(snap1.bookSHA256)
        XCTAssertFalse(snapBookSHA.isEmpty)

        // Repeated restore from snapshot with multi-ID `Set<String>` `processed` must succeed deterministically.
        var book2 = makeBook(texts: ["多条已处理去重记录", "第二版增量"], generation: c1.book.generation)
        book2.processed = book1.processed
        _ = try store.commitWithJournal(book2, nowMs: 2_000)
        let restored = try store.restoreSnapshot(id: snap1.id, nowMs: 3_000)
        XCTAssertEqual(restored.book.processed["2026-11-26"], Set(["e1", "e2", "e3", "e4", "e5"]))
        XCTAssertEqual(restored.book.processed["2026-11-27"], Set(["e6", "e7", "e8"]))
        store.clearPendingProjectionRebuild()

        // Rollback via journal carrying `preCommitBookSHA256` against multi-ID `Set<String>` snapshot succeeds cleanly.
        let diskData = try Data(contentsOf: memURL)
        let diskSHA = MemoryRevisionStore.sha256Hex(diskData)
        let snapAfterRestore = try store.saveManualSnapshot(restored.book, reason: "manual", nowMs: 3_500)
        let validRollbackJournal = MemoryPendingJournal(
            id: "j-multi-det",
            phase: .prepared,
            targetCanonicalGeneration: restored.book.generation + 1,
            preCommitSHA256: diskSHA,
            postCommitSHA256: String(repeating: "c", count: 64),
            preCommitSnapshotID: snapAfterRestore.id,
            preCommitBookSHA256: snapAfterRestore.bookSHA256
        )
        try JSONEncoder().encode(validRollbackJournal).write(to: store.journalFileURL)
        let rbOutcome = try store.recoverPendingJournalIfNeeded(nowMs: 4_000)
        XCTAssertEqual(rbOutcome, .rolledBackToSnapshot(journalID: "j-multi-det", snapshotID: snapAfterRestore.id))
        store.clearPendingProjectionRebuild()

        // Corrupt `commit.journal` MUST throw `.rollbackUnavailable` AND preserve exact bytes of `commit.journal` + `commit-prev.bak.journal`.
        let corruptJournal = Data("{corrupt-journal".utf8)
        let bakData = Data("backup-evidence".utf8)
        try corruptJournal.write(to: store.journalFileURL)
        try bakData.write(to: store.rollbackBackupURL)
        XCTAssertThrowsError(try store.recoverPendingJournalIfNeeded(nowMs: 5_000)) { error in
            guard case MemoryRevisionStoreError.rollbackUnavailable = error else {
                XCTFail("Expected .rollbackUnavailable, got \(error)")
                return
            }
        }
        XCTAssertEqual(try Data(contentsOf: store.journalFileURL), corruptJournal)
        XCTAssertEqual(try Data(contentsOf: store.rollbackBackupURL), bakData)
        try? FileManager.default.removeItem(at: store.journalFileURL)
        try? FileManager.default.removeItem(at: store.rollbackBackupURL)

        // Unreadable `commit.journal` (e.g., directory) MUST map to `.rollbackUnavailable`.
        try FileManager.default.createDirectory(at: store.journalFileURL, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.recoverPendingJournalIfNeeded(nowMs: 5_200)) { error in
            guard case MemoryRevisionStoreError.rollbackUnavailable = error else {
                XCTFail("Expected .rollbackUnavailable for unreadable journal, got \(error)")
                return
            }
        }
        try? FileManager.default.removeItem(at: store.journalFileURL)

        // Preferred `commit-prev.bak.journal` with valid `preCommitSHA256` MUST still reject blank/wrong `preCommitBookSHA256`.
        try diskData.write(to: store.rollbackBackupURL)
        let bakBadBookJournal = MemoryPendingJournal(
            id: "j-bak-bad-book",
            phase: .prepared,
            targetCanonicalGeneration: restored.book.generation + 1,
            preCommitSHA256: diskSHA,
            postCommitSHA256: String(repeating: "e", count: 64),
            preCommitSnapshotID: nil,
            preCommitBookSHA256: String(repeating: "9", count: 64)
        )
        try JSONEncoder().encode(bakBadBookJournal).write(to: store.journalFileURL)
        XCTAssertThrowsError(try store.recoverPendingJournalIfNeeded(nowMs: 5_500)) { error in
            guard case MemoryRevisionStoreError.rollbackUnavailable = error else {
                XCTFail("Expected .rollbackUnavailable for mismatched bak bookSHA256, got \(error)")
                return
            }
        }
        let bakBlankBookJournal = MemoryPendingJournal(
            id: "j-bak-blank-book",
            phase: .prepared,
            targetCanonicalGeneration: restored.book.generation + 1,
            preCommitSHA256: diskSHA,
            postCommitSHA256: String(repeating: "e", count: 64),
            preCommitSnapshotID: nil,
            preCommitBookSHA256: ""
        )
        try JSONEncoder().encode(bakBlankBookJournal).write(to: store.journalFileURL)
        XCTAssertThrowsError(try store.recoverPendingJournalIfNeeded(nowMs: 5_600)) { error in
            guard case MemoryRevisionStoreError.rollbackUnavailable = error else {
                XCTFail("Expected .rollbackUnavailable for blank bak bookSHA256, got \(error)")
                return
            }
        }
        try? FileManager.default.removeItem(at: store.journalFileURL)
        try? FileManager.default.removeItem(at: store.rollbackBackupURL)

        // Blank `bookSHA256: ""` on snapshot must be rejected by restoreSnapshot.
        let snapFiles = try FileManager.default.contentsOfDirectory(at: revDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("rev-") && $0.lastPathComponent.hasSuffix(".json") }
        let snapFile = try XCTUnwrap(snapFiles.first(where: { $0.lastPathComponent.contains(snap1.id) }))
        var blankSnap = try JSONDecoder().decode(MemoryRevisionSnapshot.self, from: Data(contentsOf: snapFile))
        blankSnap.bookSHA256 = ""
        try JSONEncoder().encode(blankSnap).write(to: snapFile)
        XCTAssertThrowsError(try store.restoreSnapshot(id: snap1.id, nowMs: 6_000)) { error in
            XCTAssertEqual(error as? MemoryRevisionStoreError, .corruptSnapshot("快照 \(snap1.id) 载荷摘要校验未通过"))
        }

        // Mismatched `preCommitBookSHA256` on journal must be rejected even if canonical SHA matches.
        let mismatchJournal = MemoryPendingJournal(
            id: "j-book-mismatch",
            phase: .prepared,
            targetCanonicalGeneration: restored.book.generation + 2,
            preCommitSHA256: snapAfterRestore.canonicalSHA256,
            postCommitSHA256: String(repeating: "d", count: 64),
            preCommitSnapshotID: snapAfterRestore.id,
            preCommitBookSHA256: String(repeating: "f", count: 64)
        )
        try JSONEncoder().encode(mismatchJournal).write(to: store.journalFileURL)
        XCTAssertThrowsError(try store.recoverPendingJournalIfNeeded(nowMs: 7_000)) { error in
            guard case MemoryRevisionStoreError.rollbackUnavailable = error else {
                XCTFail("Expected .rollbackUnavailable, got \(error)")
                return
            }
        }
        try? FileManager.default.removeItem(at: store.journalFileURL)

        // Zero-byte `health.json` must throw from `readHealthThrowing()`.
        try Data().write(to: store.healthFileURL)
        XCTAssertThrowsError(try store.readHealthThrowing())

        // #2: `!preCommitExisted` rollback failure removing `memory.json` must throw `.rollbackUnavailable`
        // AND keep `memory.json` + `commit.journal` intact on disk.
        let unremParent = dir.appendingPathComponent("unremovable-parent", isDirectory: true)
        try FileManager.default.createDirectory(at: unremParent, withIntermediateDirectories: true)
        let unremMem = unremParent.appendingPathComponent("memory.json")
        let unremRev = dir.appendingPathComponent("unrem-revisions", isDirectory: true)
        let unremStore = MemoryRevisionStore(memoryFileURL: unremMem, revisionsDirectoryURL: unremRev)
        try FileManager.default.createDirectory(at: unremRev, withIntermediateDirectories: true)
        try Data("{\"memories\":[],\"generation\":1}\n".utf8).write(to: unremMem)
        let firstFailJournal = MemoryPendingJournal(
            id: "j-first-unrem",
            phase: .prepared,
            targetCanonicalGeneration: 1,
            preCommitSHA256: "",
            postCommitSHA256: String(repeating: "0", count: 64),
            preCommitSnapshotID: nil,
            preCommitExisted: false
        )
        try JSONEncoder().encode(firstFailJournal).write(to: unremStore.journalFileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: unremParent.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unremParent.path) }
        XCTAssertThrowsError(try unremStore.recoverPendingJournalIfNeeded(nowMs: 8_000)) { error in
            guard case MemoryRevisionStoreError.rollbackUnavailable = error else {
                XCTFail("Expected .rollbackUnavailable when memory.json removal fails, got \(error)")
                return
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: unremMem.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unremStore.journalFileURL.path))
    }
}
