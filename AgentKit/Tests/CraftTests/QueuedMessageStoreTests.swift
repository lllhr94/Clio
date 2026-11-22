import Craft
import Foundation
import XCTest

final class QueuedMessageStoreTests: XCTestCase {
    private func makeTempRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clio-queued-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testRoundTripSavesAndRestoresTextPhotosAndFlags() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = StoredQueuedMessage(
            text: "发完上一句后帮我查一下日志",
            photos: [Data([0xFF, 0xD8, 0xFF, 0xE0]), Data([0x89, 0x50, 0x4E, 0x47])],
            interject: false,
            userInitiated: true
        )
        let second = StoredQueuedMessage(
            text: "顺便看看端口",
            photos: [],
            interject: true,
            userInitiated: true
        )
        let roomItem = StoredQueuedMessage(
            text: "大家一起看看",
            photos: [],
            interject: false,
            userInitiated: false
        )

        try QueuedMessageStore.save([first, second], for: "bot-alpha", under: root)
        try QueuedMessageStore.save([roomItem], for: "room-beta", under: root)

        let loaded = QueuedMessageStore.loadAll(from: root)
        XCTAssertEqual(loaded["bot-alpha"], [first, second])
        XCTAssertEqual(loaded["room-beta"], [roomItem])
    }

    func testEmptySaveRemovesFolderAndReplacesOldPhotosCleanly() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let original = StoredQueuedMessage(text: "第一条", photos: [Data(repeating: 0x01, count: 64)])
        try QueuedMessageStore.save([original], for: "bot-alpha", under: root)

        let updated = StoredQueuedMessage(text: "更新后", photos: [Data(repeating: 0x02, count: 32)])
        try QueuedMessageStore.save([updated], for: "bot-alpha", under: root)

        let afterUpdate = QueuedMessageStore.loadAll(from: root)
        XCTAssertEqual(afterUpdate["bot-alpha"], [updated])

        // Old photo file must not linger after atomic replacement.
        let folder = root.appendingPathComponent("bot-alpha", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertFalse(files.contains("\(original.id.uuidString)-0.img"))

        // Empty save removes the folder completely.
        try QueuedMessageStore.save([], for: "bot-alpha", under: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(QueuedMessageStore.loadAll(from: root).isEmpty)
    }

    func testLoadAllIgnoresAndCleansStaleStagingFolders() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let stale = root.appendingPathComponent(".new-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: stale.appendingPathComponent("queue.json"))

        let valid = StoredQueuedMessage(text: "保留这条")
        try QueuedMessageStore.save([valid], for: "bot-keep", under: root)

        let loaded = QueuedMessageStore.loadAll(from: root)
        XCTAssertEqual(loaded["bot-keep"], [valid])
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }

    func testDeduplicatedDropsConfirmedTransfersAndProtectsUnwrittenPhotos() {
        let sentFirst = StoredQueuedMessage(text: "已写入聊天 1")
        let sentSecond = StoredQueuedMessage(text: "已写入聊天 2", photos: [Data([0xFF, 0xD8])])
        let textUnqueued = StoredQueuedMessage(text: "纯文字已撤回草稿")
        let photoUnqueuedTextOnly = StoredQueuedMessage(text: "带图撤回但图未落盘", photos: [Data([0x89, 0x50])])
        let photoUnqueuedSaved = StoredQueuedMessage(text: "带图撤回且图已落盘", photos: [Data([0x89, 0x50, 0x4E])])
        let stillPending = StoredQueuedMessage(text: "新排队的")

        let all = [sentFirst, sentSecond, textUnqueued, photoUnqueuedTextOnly, photoUnqueuedSaved, stillPending]
        let remaining = QueuedMessageStore.deduplicated(
            all,
            persistedInChat: [sentFirst.id, sentSecond.id],
            persistedInDraftText: [textUnqueued.id, photoUnqueuedTextOnly.id, photoUnqueuedSaved.id],
            persistedInDraftAttachments: [photoUnqueuedSaved.id]
        )

        XCTAssertEqual(remaining, [photoUnqueuedTextOnly, stillPending])
    }

    func testEvaluateSlotPreservesLeafQueueWhenIndexUnreadableOrLeafFileStillExists() {
        let anchor = ConversationAnchor.from(entryIds: ["e1", "e2"])

        // 1. Index unreadable (e.g. failed write/corrupt JSON) -> fail closed, keep slot on disk.
        XCTAssertEqual(
            QueuedMessageStore.evaluateSlot(
                existsInIndex: false,
                indexReadable: false,
                chatFileExists: false,
                anchor: anchor,
                chatEntryIds: nil
            ),
            .preserveUnreadable
        )

        // 2. Index readable but leaf file still exists on disk (e.g. crash before index updated) -> fail closed.
        XCTAssertEqual(
            QueuedMessageStore.evaluateSlot(
                existsInIndex: false,
                indexReadable: true,
                chatFileExists: true,
                anchor: anchor,
                chatEntryIds: ["e1", "e2"]
            ),
            .preserveUnreadable
        )

        // 3. Index readable AND chat/leaf file confirmed absent -> safe to delete orphan.
        XCTAssertEqual(
            QueuedMessageStore.evaluateSlot(
                existsInIndex: false,
                indexReadable: true,
                chatFileExists: false,
                anchor: anchor,
                chatEntryIds: nil
            ),
            .deleteOrphan
        )
    }

    func testAtomicTextDraftWriteThenImmediateTerminationDeduplicatesWithoutLoss() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let queuedRoot = root.appendingPathComponent("ClioQueued", isDirectory: true)
        let draftsRoot = root.appendingPathComponent("ClioDrafts", isDirectory: true)
        let item = StoredQueuedMessage(text: "撤回的纯文字消息")
        try QueuedMessageStore.save([item], for: "bot-a", under: queuedRoot)

        // Crash BEFORE atomic draft file lands: draft is absent, queue item stays intact.
        XCTAssertNil(QueuedMessageStore.loadTextDraft(for: "bot-a", under: draftsRoot))
        let beforeWrite = QueuedMessageStore.deduplicated(
            QueuedMessageStore.loadAll(from: queuedRoot)["bot-a"] ?? [],
            persistedInChat: [],
            persistedInDraftText: Set(QueuedMessageStore.loadTextDraft(for: "bot-a", under: draftsRoot)?.queuedIds ?? [])
        )
        XCTAssertEqual(beforeWrite, [item])

        // Crash RIGHT AFTER atomic draft file writes, BEFORE queue item is removed:
        // restart reads both text and queuedIds from the atomic draft file and deduplicates the queue cleanly.
        try QueuedMessageStore.saveTextDraft(StoredTextDraft(text: item.text, queuedIds: [item.id]), for: "bot-a", under: draftsRoot)
        let loadedDraft = try XCTUnwrap(QueuedMessageStore.loadTextDraft(for: "bot-a", under: draftsRoot))
        XCTAssertEqual(loadedDraft.text, "撤回的纯文字消息")
        XCTAssertEqual(loadedDraft.queuedIds, [item.id])

        let afterWrite = QueuedMessageStore.deduplicated(
            QueuedMessageStore.loadAll(from: queuedRoot)["bot-a"] ?? [],
            persistedInChat: [],
            persistedInDraftText: Set(loadedDraft.queuedIds)
        )
        XCTAssertTrue(afterWrite.isEmpty)
    }

    func testRestoreOldBackupOfSameCompanionIsolatesMismatchedQueueAndExportsReadableCopy() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let queuedRoot = root.appendingPathComponent("ClioQueued", isDirectory: true)
        let quarantineRoot = root.appendingPathComponent("ClioQueuedIsolated", isDirectory: true)
        let exportRoot = root.appendingPathComponent("Export", isDirectory: true)

        // Conversation B on bot-alpha queues a message with photo, bound to B's entry IDs.
        let photo = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02])
        let itemFromB = StoredQueuedMessage(text: "发给 B 对话的敏感内容", photos: [photo])
        let anchorB = ConversationAnchor.from(entryIds: ["b1", "b2"])
        try QueuedMessageStore.save([itemFromB], for: "bot-alpha", anchor: anchorB, under: queuedRoot)

        // Same conversation continuing normally (b3 appended) still matches anchor B.
        let loaded = try XCTUnwrap(QueuedMessageStore.loadAllSlots(from: queuedRoot)["bot-alpha"])
        XCTAssertEqual(
            QueuedMessageStore.evaluateSlot(
                existsInIndex: true,
                indexReadable: true,
                chatFileExists: true,
                anchor: loaded.anchor,
                chatEntryIds: ["b1", "b2", "b3"]
            ),
            .restore
        )

        // Restoring an older backup of the same companion replaces chat with conversation A ([a1, a2]) -> mismatch!
        XCTAssertEqual(
            QueuedMessageStore.evaluateSlot(
                existsInIndex: true,
                indexReadable: true,
                chatFileExists: true,
                anchor: loaded.anchor,
                chatEntryIds: ["a1", "a2"]
            ),
            .isolateMismatched
        )

        // Restoring an older snapshot of the same conversation ([b1], before b2 existed) also mismatches!
        XCTAssertEqual(
            QueuedMessageStore.evaluateSlot(
                existsInIndex: true,
                indexReadable: true,
                chatFileExists: true,
                anchor: loaded.anchor,
                chatEntryIds: ["b1"]
            ),
            .isolateMismatched
        )

        // Isolating moves B's queue out of active ClioQueued so it cannot auto-send in A, and exports a readable copy.
        let report = QueuedMessageStore.isolateSlot(
            "bot-alpha",
            from: queuedRoot,
            to: quarantineRoot,
            readableExportRoot: exportRoot
        )
        XCTAssertEqual(report.isolatedMessages, 1)
        XCTAssertEqual(report.failedMessages, 0)
        XCTAssertTrue(report.failedSlots.isEmpty)
        XCTAssertTrue(report.readableExportSucceeded)
        XCTAssertTrue(QueuedMessageStore.loadAll(from: queuedRoot).isEmpty)

        // Verify quarantine copy and readable export both exist with text + photo preserved.
        let exportFolders = try FileManager.default.contentsOfDirectory(at: exportRoot, includingPropertiesForKeys: nil)
        XCTAssertEqual(exportFolders.count, 1)
        let exportedMarkdown = try String(contentsOf: exportFolders[0].appendingPathComponent("bot-alpha.md"), encoding: .utf8)
        XCTAssertTrue(exportedMarkdown.contains("发给 B 对话的敏感内容"))
        let exportedPhoto = try Data(contentsOf: exportFolders[0].appendingPathComponent("bot-alpha-1-1.jpg"))
        XCTAssertEqual(exportedPhoto, photo)
    }

    func testQueueDispatchGateBlocksDuringAndAfterRestoreAndResumesOnFailure() {
        // Normal operation: allowed.
        XCTAssertTrue(QueuedMessageStore.canDispatchQueue(isFrozen: false, isRestoring: false))
        // While restore is running: blocked even before Disk.frozen flips.
        XCTAssertFalse(QueuedMessageStore.canDispatchQueue(isFrozen: false, isRestoring: true))
        // After restore succeeds (Disk.frozen == true), before relaunch: permanently blocked even if old turn finishes.
        XCTAssertFalse(QueuedMessageStore.canDispatchQueue(isFrozen: true, isRestoring: true))
        XCTAssertFalse(QueuedMessageStore.canDispatchQueue(isFrozen: true, isRestoring: false))
    }

    func testIsolationFailureReportsFailedSlotBlocksRestartEvenWithoutAnchorAndRetriesCleanly() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let queuedRoot = root.appendingPathComponent("ClioQueued", isDirectory: true)
        let blockedQuarantine = root.appendingPathComponent("ClioQueuedIsolated-blocker")
        let exportRoot = root.appendingPathComponent("Export", isDirectory: true)

        // Create a legacy queue without anchor (nil), where anchor mismatch alone would NOT catch it.
        let legacyItem = StoredQueuedMessage(text: "旧格式纯文字排队消息")
        try QueuedMessageStore.save([legacyItem], for: "bot-legacy", anchor: nil, under: queuedRoot)

        // Place a regular file at quarantineRoot so creating the quarantine directory fails.
        try Data("blocker".utf8).write(to: blockedQuarantine)

        let failed = QueuedMessageStore.isolateAll(
            from: queuedRoot,
            to: blockedQuarantine,
            readableExportRoot: exportRoot
        )
        XCTAssertEqual(failed.isolatedMessages, 0)
        XCTAssertEqual(failed.failedMessages, 1)
        XCTAssertEqual(failed.failedSlots, ["bot-legacy"])
        XCTAssertTrue(failed.readableExportSucceeded)
        // Source slot is still present, and blocked marker was persisted.
        XCTAssertEqual(QueuedMessageStore.loadAll(from: queuedRoot)["bot-legacy"], [legacyItem])
        let blocked = QueuedMessageStore.loadBlockedSlots(from: queuedRoot)
        XCTAssertTrue(blocked.contains("bot-legacy"))

        // On restart, even with nil anchor (or matching anchor), blocked slot MUST return .retryIsolation, NEVER .restore.
        XCTAssertEqual(
            QueuedMessageStore.evaluateSlot(
                existsInIndex: true,
                indexReadable: true,
                chatFileExists: true,
                anchor: nil,
                chatEntryIds: ["a1", "a2"],
                isBlockedByRestore: blocked.contains("bot-legacy")
            ),
            .retryIsolation
        )

        // Once the quarantine path is writable again, retrying isolation succeeds and clears the blocked marker.
        try FileManager.default.removeItem(at: blockedQuarantine)
        let retried = QueuedMessageStore.isolateSlot(
            "bot-legacy",
            from: queuedRoot,
            to: blockedQuarantine,
            readableExportRoot: exportRoot
        )
        XCTAssertEqual(retried.isolatedMessages, 1)
        XCTAssertEqual(retried.failedMessages, 0)
        XCTAssertTrue(QueuedMessageStore.loadAll(from: queuedRoot).isEmpty)
        XCTAssertFalse(QueuedMessageStore.loadBlockedSlots(from: queuedRoot).contains("bot-legacy"))
    }

    func testReadableExportFailureIsReportedSeparatelyFromSuccessfulIsolation() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let queuedRoot = root.appendingPathComponent("ClioQueued", isDirectory: true)
        let quarantineRoot = root.appendingPathComponent("ClioQueuedIsolated", isDirectory: true)
        let blockedExport = root.appendingPathComponent("ExportBlocker")
        try Data("not-a-dir".utf8).write(to: blockedExport)

        let item = StoredQueuedMessage(text: "隔离成功但导出失败的消息")
        try QueuedMessageStore.save([item], for: "bot-a", under: queuedRoot)

        let report = QueuedMessageStore.isolateAll(
            from: queuedRoot,
            to: quarantineRoot,
            readableExportRoot: blockedExport
        )
        XCTAssertEqual(report.isolatedMessages, 1)
        XCTAssertEqual(report.failedMessages, 0)
        XCTAssertFalse(report.readableExportSucceeded)
        XCTAssertTrue(QueuedMessageStore.loadAll(from: queuedRoot).isEmpty)
    }

    func testPendingLeafOpenReconcilesRollbackWhenIndexWriteFailedBeforeRestart() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let teamRoot = root.appendingPathComponent("Team", isDirectory: true)
        let chatsDir = teamRoot.appendingPathComponent("chats", isDirectory: true)
        let queuedRoot = root.appendingPathComponent("ClioQueued", isDirectory: true)
        try FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)

        let leafKey = "bot-a~leaf-1"
        let leafQueuedItem = StoredQueuedMessage(text: "旧对话里的排队消息")
        let priorActiveItem = StoredQueuedMessage(text: "空白当前页里原本的排队")
        let leafAnchor = ConversationAnchor.from(entryIds: ["e1", "e2"])

        // Existing leaf on disk + leaf still listed in ~leaves.json (3rd write failed!).
        try Data("[{\"id\":\"e1\"},{\"id\":\"e2\"}]".utf8).write(to: chatsDir.appendingPathComponent("\(leafKey).json"))
        try Data("[{\"id\":\"leaf-1\",\"title\":\"旧对话\",\"at\":1,\"count\":2}]".utf8)
            .write(to: chatsDir.appendingPathComponent("bot-a~leaves.json"))
        try QueuedMessageStore.save([leafQueuedItem], for: leafKey, anchor: leafAnchor, under: queuedRoot)

        // Simulate writes #1 and #2 succeeding (active chat + merged active queue written), then #3 failing / crashing!
        try QueuedMessageStore.savePendingLeafOpen(
            PendingLeafOpen(
                chatKey: "bot-a",
                leafId: "leaf-1",
                leafKey: leafKey,
                priorActiveQueuedIds: [priorActiveItem.id]
            ),
            under: queuedRoot
        )
        try Data("[{\"id\":\"e1\"},{\"id\":\"e2\"}]".utf8).write(to: chatsDir.appendingPathComponent("bot-a.json"))
        try QueuedMessageStore.save([priorActiveItem, leafQueuedItem], for: "bot-a", anchor: leafAnchor, under: queuedRoot)

        // Restart reconciles the uncommitted transaction: rolls back duplicate active chat & leaf queue copy.
        QueuedMessageStore.reconcilePendingLeafOpens(teamRoot: teamRoot, queuedRoot: queuedRoot)

        XCTAssertFalse(FileManager.default.fileExists(atPath: chatsDir.appendingPathComponent("bot-a.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: chatsDir.appendingPathComponent("\(leafKey).json").path))
        let slotsAfter = QueuedMessageStore.loadAllSlots(from: queuedRoot)
        XCTAssertEqual(slotsAfter[leafKey]?.items, [leafQueuedItem])
        XCTAssertEqual(slotsAfter["bot-a"]?.items, [priorActiveItem])
        XCTAssertTrue(QueuedMessageStore.loadPendingLeafOpens(from: queuedRoot).isEmpty)
    }

    func testPendingLeafOpenReconcilesForwardWhenIndexAlreadyCommittedBeforeCrash() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let teamRoot = root.appendingPathComponent("Team", isDirectory: true)
        let chatsDir = teamRoot.appendingPathComponent("chats", isDirectory: true)
        let queuedRoot = root.appendingPathComponent("ClioQueued", isDirectory: true)
        try FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)

        let leafKey = "bot-a~leaf-2"
        let leafQueuedItem = StoredQueuedMessage(text: "翻回后的排队消息")
        let leafAnchor = ConversationAnchor.from(entryIds: ["e1"])

        // Writes #1, #2, and #3 ALL succeeded (leaf-2 removed from ~leaves.json), then app crashed before deleting leaf files.
        try QueuedMessageStore.savePendingLeafOpen(
            PendingLeafOpen(chatKey: "bot-a", leafId: "leaf-2", leafKey: leafKey, priorActiveQueuedIds: []),
            under: queuedRoot
        )
        try Data("[{\"id\":\"e1\"}]".utf8).write(to: chatsDir.appendingPathComponent("bot-a.json"))
        try Data("[{\"id\":\"e1\"}]".utf8).write(to: chatsDir.appendingPathComponent("\(leafKey).json"))
        try Data("[]".utf8).write(to: chatsDir.appendingPathComponent("bot-a~leaves.json"))
        try QueuedMessageStore.save([leafQueuedItem], for: "bot-a", anchor: leafAnchor, under: queuedRoot)
        try QueuedMessageStore.save([leafQueuedItem], for: leafKey, anchor: leafAnchor, under: queuedRoot)

        QueuedMessageStore.reconcilePendingLeafOpens(teamRoot: teamRoot, queuedRoot: queuedRoot)

        XCTAssertTrue(FileManager.default.fileExists(atPath: chatsDir.appendingPathComponent("bot-a.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: chatsDir.appendingPathComponent("\(leafKey).json").path))
        let slotsAfter = QueuedMessageStore.loadAllSlots(from: queuedRoot)
        XCTAssertEqual(slotsAfter["bot-a"]?.items, [leafQueuedItem])
        XCTAssertNil(slotsAfter[leafKey])
        XCTAssertTrue(QueuedMessageStore.loadPendingLeafOpens(from: queuedRoot).isEmpty)
    }
}
