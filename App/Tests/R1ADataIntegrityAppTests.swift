import AgentKit
import Craft
import Foundation
import XCTest
@testable import Clio

@MainActor
final class R1ADataIntegrityAppTests: XCTestCase {
    private struct InjectedIOError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private final class OptionalBoolBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool?
        func set(_ newValue: Bool) { lock.withLock { value = newValue } }
        func get() -> Bool? { lock.withLock { value } }
    }

    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clio-app-r1a-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Builds a valid plaintext `CLIO-BACKUP-1\n` archive from `(relativePath, data)` entries.
    private func writePlainBackupArchive(entries: [(String, Data)], to url: URL) throws {
        var payload = Data("CLIO-BACKUP-1\n".utf8)
        for (path, body) in entries {
            let name = Data(path.utf8)
            var nameLen = UInt32(name.count).bigEndian
            var bodyLen = UInt64(body.count).bigEndian
            withUnsafeBytes(of: &nameLen) { payload.append(contentsOf: $0) }
            payload.append(name)
            withUnsafeBytes(of: &bodyLen) { payload.append(contentsOf: $0) }
            payload.append(body)
        }
        try payload.write(to: url, options: .atomic)
    }

    override func tearDown() async throws {
        Disk.readChatDataOverride = nil
        Disk.writeDataOverride = nil
        CasualColdStartCoordinator.shared.resetForTesting()
        try await super.tearDown()
    }

    // MARK: - CX-02: Backup Interrupted Swap Recovery, Rollback Honesty & Restored Casual Safety

    func testBackupMidSwapCrashAndRollbackFailureRecoverCompleteOldDataOnColdStart() throws {
        let root = try makeTempDir("backup-crash")
        defer { try? FileManager.default.removeItem(at: root) }

        let support = root.appendingPathComponent("Support", isDirectory: true)
        let workspace = root.appendingPathComponent("Workspace", isDirectory: true)
        let liveTeam = support.appendingPathComponent("Team", isDirectory: true)
        let livePortraits = support.appendingPathComponent("Portraits", isDirectory: true)
        try FileManager.default.createDirectory(at: liveTeam, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: livePortraits, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        try Data("OLD-TEAM".utf8).write(to: liveTeam.appendingPathComponent("marker.txt"))
        try Data("OLD-PORTRAIT".utf8).write(to: livePortraits.appendingPathComponent("p.txt"))

        let archiveURL = root.appendingPathComponent("test.clio-backup")
        try writePlainBackupArchive(
            entries: [
                ("Team/marker.txt", Data("NEW-TEAM".utf8)),
                ("Portraits/p.txt", Data("NEW-PORTRAIT".utf8)),
            ],
            to: archiveURL
        )

        // Inject BOTH:
        // 1) swap failure when moving staged Portraits into live (after Team has already been moved into `.restore-old`),
        // 2) rollback failure when trying to move `.restore-old/Team` back to live.
        let ops = Backup.RestoreFileOps(
            moveItem: { src, dst in
                if src.path.contains(".restore-staging") && dst.lastPathComponent == "Portraits" {
                    throw InjectedIOError(message: "simulated-swap-crash")
                }
                if src.path.contains(".restore-old") && dst.lastPathComponent == "Team" {
                    throw InjectedIOError(message: "simulated-rollback-failure")
                }
                try FileManager.default.moveItem(at: src, to: dst)
            },
            removeItem: { try FileManager.default.removeItem(at: $0) }
        )

        XCTAssertThrowsError(try Backup.restore(
            from: archiveURL,
            passphrase: nil,
            support: support,
            workspaceRoot: workspace,
            fileOps: ops,
            skipGlobalBridges: true
        )) { error in
            XCTAssertFalse(
                error.localizedDescription.contains("已经还原成原样"),
                "Rollback failure MUST NOT falsely tell the user data was restored cleanly: \(error.localizedDescription)"
            )
        }

        // Journal and `.restore-old/Team` MUST still be preserved on disk for cold-start recovery.
        XCTAssertTrue(FileManager.default.fileExists(atPath: support.appendingPathComponent(".restore-journal.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: support.appendingPathComponent(".restore-old/Team/marker.txt").path))

        // Cold launch reconciliation with live FileManager completes rollback to complete old dataset!
        let recovered = try Backup.reconcileInterruptedRestoreIfNeeded(
            support: support,
            workspaceRoot: workspace,
            fileOps: .live,
            discardCredentials: { _, _ in }
        )
        XCTAssertTrue(recovered)
        XCTAssertEqual(try String(contentsOf: liveTeam.appendingPathComponent("marker.txt"), encoding: .utf8), "OLD-TEAM")
        XCTAssertEqual(try String(contentsOf: livePortraits.appendingPathComponent("p.txt"), encoding: .utf8), "OLD-PORTRAIT")
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent(".restore-old").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent(".restore-journal.json").path))
    }

    func testBackupRestoreRecoversLegacySoleSurvivingRestoreOldBeforeStarting() throws {
        let root = try makeTempDir("backup-legacy-old")
        defer { try? FileManager.default.removeItem(at: root) }

        let support = root.appendingPathComponent("Support", isDirectory: true)
        let workspace = root.appendingPathComponent("Workspace", isDirectory: true)
        let oldTeam = support.appendingPathComponent(".restore-old/Team", isDirectory: true)
        try FileManager.default.createDirectory(at: oldTeam, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("SOLE-SURVIVING-OLD".utf8).write(to: oldTeam.appendingPathComponent("keep.txt"))

        // Live `Team/` is missing — `.restore-old/Team` is the ONLY surviving copy.
        let recovered = try Backup.reconcileInterruptedRestoreIfNeeded(
            support: support,
            workspaceRoot: workspace,
            fileOps: .live,
            discardCredentials: { _, _ in }
        )
        XCTAssertTrue(recovered)
        XCTAssertEqual(
            try String(contentsOf: support.appendingPathComponent("Team/keep.txt"), encoding: .utf8),
            "SOLE-SURVIVING-OLD"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent(".restore-old").path))
    }

    func testBackupRestoreDemotesRestoredCasualOutboxToNeedsReconcile() throws {
        let root = try makeTempDir("backup-casual-demote")
        defer { try? FileManager.default.removeItem(at: root) }

        let support = root.appendingPathComponent("Support", isDirectory: true)
        let workspace = root.appendingPathComponent("Workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: support.appendingPathComponent("Team", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let batch = CasualOutboxBatch(
            batchID: "restored-batch-1",
            botID: "bot-a",
            casualSessionID: "sess-a",
            segments: ["备份里的待发闲聊"],
            state: .queuedBeforeSend,
            trackEpoch: 0
        )
        let batchData = try JSONEncoder().encode(batch)
        let archiveURL = root.appendingPathComponent("casual.clio-backup")
        try writePlainBackupArchive(
            entries: [
                ("Team/casual/outbox/restored-batch-1.json", batchData),
            ],
            to: archiveURL
        )

        _ = try Backup.restore(
            from: archiveURL,
            passphrase: nil,
            support: support,
            workspaceRoot: workspace,
            fileOps: .live,
            skipGlobalBridges: true
        )

        let restoredTeam = support.appendingPathComponent("Team", isDirectory: true)
        let restoredStore = CasualTrackStore(
            canonicalTeamDirectory: restoredTeam,
            projectionDatabaseURL: root.appendingPathComponent("restored-casual.db")
        )
        XCTAssertEqual(restoredStore.loadOutboxBatch(batchID: "restored-batch-1")?.state, .needsReconcile)
    }

    // MARK: - CX-06: Disk.loadChat Unreadable Guard Prevents Overwriting Original History

    func testUnreadableChatDoesNotCacheEmptyOrOverwriteExistingHistoryOnAppend() throws {
        let key = "test-r1a-unreadable-\(UUID().uuidString.lowercased())"
        let original = [
            Entry(id: "e-orig-1", at: 100, message: .user("第一句历史")),
            Entry(id: "e-orig-2", at: 200, message: .assistant("第二句历史")),
        ]
        try Disk.write(original, Disk.chatFile(key))
        defer {
            Disk.readChatDataOverride = nil
            ChatDisk.removeAndWait(key)
        }

        let team = TeamModel()
        team.phase = .ready

        // Simulate transient EACCES / Data Protection unreadable error (non-ENOENT).
        let chatPath = Disk.url(Disk.chatFile(key)).path
        Disk.readChatDataOverride = { url in
            if url.path == chatPath {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
            }
            return try Data(contentsOf: url)
        }

        XCTAssertTrue(team.history(key).isEmpty)
        XCTAssertNil(team.entries[key], "Unreadable chat MUST NOT cache [] into entries")
        XCTAssertTrue(team.unreadableChats.contains(key))

        let savedResult = OptionalBoolBox()
        team.append(Entry(id: "e-new", at: 300, message: .user("新消息")), to: key) { ok in
            savedResult.set(ok)
        }
        ChatDisk.finishWrites()
        XCTAssertEqual(savedResult.get(), false, "Append on unreadable chat MUST refuse overwrite")

        // Restore readability: original 2 messages MUST still be intact on disk!
        Disk.readChatDataOverride = nil
        guard case .loaded(let stillIntact) = Disk.loadChatChecked(key) else {
            return XCTFail("Expected original chat history to remain readable and intact")
        }
        XCTAssertEqual(stillIntact.map(\.id), ["e-orig-1", "e-orig-2"])

        // Now appending recovers cleanly and preserves all 3 messages.
        let recoveredSave = OptionalBoolBox()
        team.append(Entry(id: "e-new", at: 300, message: .user("新消息")), to: key) { ok in
            recoveredSave.set(ok)
        }
        ChatDisk.finishWrites()
        XCTAssertEqual(recoveredSave.get(), true)
        XCTAssertFalse(team.unreadableChats.contains(key))
        guard case .loaded(let merged) = Disk.loadChatChecked(key) else {
            return XCTFail("Expected merged history on disk")
        }
        XCTAssertEqual(merged.map(\.id), ["e-orig-1", "e-orig-2", "e-new"])
    }

    // MARK: - CX-04: Subtask Delivery Confirms Disk Persistence via onSaved & Defeats Memory Masking

    func testSubtaskDeliveryWriteFailureDoesNotRecordDeliveredAndRetriesCleanlyDespiteMemory() throws {
        let dir = try makeTempDir("subtask-delivery")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = TaskStore(canonicalTeamDirectory: dir, projectionDatabaseURL: dir.appendingPathComponent("tasks.db"))
        let manager = SubtaskManager(store: store)
        let team = TeamModel()
        team.phase = .ready

        let botID = "r1a-parent-\(UUID().uuidString.lowercased())"
        let helperID = "r1a-helper-\(UUID().uuidString.lowercased())"
        let parentKey = TeamModel.key(bot: botID)
        team.bots = [BotInfo(id: botID, name: "主旅伴"), BotInfo(id: helperID, name: "副旅伴")]
        defer {
            Disk.writeDataOverride = nil
            ChatDisk.removeAndWait(parentKey)
            Disk.remove(TeamModel.optionsFile(parentKey))
        }

        let convID = team.activeConversationID(for: parentKey)
        let (thread, attempt) = try store.createThread(
            stableParentChatID: parentKey,
            parentConversationID: convID,
            askerBotID: botID,
            helperBotID: helperID,
            helperBotName: "副旅伴",
            taskPrompt: "后台整理",
            inheritedPlanMode: false,
            taintedIn: false
        )
        let (finished, eventID) = try store.finishAttempt(
            threadID: thread.threadID,
            attemptID: attempt.attemptID,
            status: .succeeded,
            resultText: "整理完毕",
            taintedOut: false
        )

        // Fail ONLY the parent chat JSON save on first attempt.
        let parentChatPath = Disk.url(Disk.chatFile(parentKey)).path
        Disk.writeDataOverride = { data, url in
            if url.path == parentChatPath {
                throw InjectedIOError(message: "simulated-disk-full")
            }
            try data.write(to: url, options: .atomic)
        }

        XCTAssertFalse(
            manager.deliverIdempotentlyToParent(thread: finished, attemptID: attempt.attemptID, eventID: eventID, team: team),
            "Delivery MUST return false when parent chat write fails"
        )
        XCTAssertFalse(store.thread(id: thread.threadID)?.deliveredEventIDs.contains(eventID) ?? true)
        XCTAssertFalse(team.entries[parentKey]?.contains(where: { $0.id == eventID }) ?? false)

        // Simulate stale in-memory entry trying to mask disk absence on retry.
        team.entries[parentKey] = [Entry(id: eventID, at: Now.ms, message: .assistant("stale-mem"), note: true)]
        Disk.writeDataOverride = nil

        XCTAssertTrue(
            manager.deliverIdempotentlyToParent(thread: finished, attemptID: attempt.attemptID, eventID: eventID, team: team)
        )
        XCTAssertTrue(store.thread(id: thread.threadID)?.deliveredEventIDs.contains(eventID) ?? false)

        guard case .loaded(let diskEntries) = Disk.loadChatChecked(parentKey) else {
            return XCTFail("Expected parent chat on disk after retry")
        }
        XCTAssertEqual(diskEntries.filter { $0.id == eventID }.count, 1)

        // Replaying delivery after disk confirmation is a strict no-op.
        XCTAssertFalse(
            manager.deliverIdempotentlyToParent(thread: finished, attemptID: attempt.attemptID, eventID: eventID, team: team)
        )
    }

    // MARK: - CX-05: Immutable Conversation Identity Across shelveCurrent

    func testSubtaskResultAndTaintRouteToShelvedLeafInsteadOfNewConversation() throws {
        let dir = try makeTempDir("subtask-shelve")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = TaskStore(canonicalTeamDirectory: dir, projectionDatabaseURL: dir.appendingPathComponent("tasks.db"))
        let manager = SubtaskManager(store: store)
        let team = TeamModel()
        team.phase = .ready

        let botID = "r1a-shelve-\(UUID().uuidString.lowercased())"
        let helperID = "r1a-shelve-h-\(UUID().uuidString.lowercased())"
        let parentKey = TeamModel.key(bot: botID)
        team.bots = [BotInfo(id: botID, name: "主旅伴"), BotInfo(id: helperID, name: "副旅伴")]

        var createdLeafIDs: [String] = []
        defer {
            ChatDisk.removeAndWait(parentKey)
            for lid in createdLeafIDs {
                Disk.remove(TeamModel.leafFile(parentKey, lid))
                Disk.remove(TeamModel.leafSummary(parentKey, lid))
            }
            Disk.remove(TeamModel.leafList(parentKey))
            Disk.remove(TeamModel.optionsFile(parentKey))
        }

        // Seed original conversation and bind subtask to its non-reusable conversationID.
        team.append(Entry(id: "u-old-1", at: 100, message: .user("旧话题第一句")), to: parentKey)
        ChatDisk.finishWrites()
        let oldConversationID = team.activeConversationID(for: parentKey)

        let (thread, attempt) = try store.createThread(
            stableParentChatID: parentKey,
            parentConversationID: oldConversationID,
            askerBotID: botID,
            helperBotID: helperID,
            helperBotName: "副旅伴",
            taskPrompt: "查旧话题网页",
            inheritedPlanMode: false,
            taintedIn: false
        )

        // User starts a brand-new conversation (shelving old conversation into a leaf and reusing slot `parentKey`).
        XCTAssertTrue(team.turnLeaf(parentKey))
        createdLeafIDs = team.leaves(parentKey).map(\.id)
        let shelvedLeaf = try XCTUnwrap(team.leaves(parentKey).first)
        XCTAssertEqual(shelvedLeaf.conversationID, oldConversationID)
        XCTAssertNotEqual(team.activeConversationID(for: parentKey), oldConversationID)

        // Subtask completes later with tainted external data.
        let (finished, eventID) = try store.finishAttempt(
            threadID: thread.threadID,
            attemptID: attempt.attemptID,
            status: .succeeded,
            resultText: "旧话题外部网页结论",
            taintedOut: true
        )

        XCTAssertTrue(
            manager.deliverIdempotentlyToParent(thread: finished, attemptID: attempt.attemptID, eventID: eventID, team: team)
        )

        // Brand-new active conversation MUST stay clean and untainted!
        XCTAssertTrue((team.entries[parentKey] ?? []).isEmpty)
        XCTAssertFalse(team.taint.isTainted(parentKey))
        XCTAssertFalse(team.isTurnMemoryTainted(parentKey))

        // Original shelved leaf MUST receive the delivered note!
        let leafEntries = team.entries(in: shelvedLeaf, of: parentKey)
        XCTAssertEqual(leafEntries.filter { $0.id == eventID }.count, 1)
        XCTAssertEqual(leafEntries.last?.tainted, true)
    }

    // MARK: - CX-07: Casual Controller Multi-Bot Isolation & Safe Resend/Reply Persistence

    func testCasualControllerOpeningBotBDoesNotTouchBotAInFlightAndGuardsFailures() throws {
        let dir = try makeTempDir("casual-multibot")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = CasualTrackStore(
            canonicalTeamDirectory: dir,
            projectionDatabaseURL: dir.appendingPathComponent("casual.db")
        )
        let botAStep1 = try store.commitStep1QueuedBeforeSend(
            botID: "bot-a",
            casualSessionID: "sess-a",
            segments: ["正在请求中"],
            trackEpoch: 0,
            batchID: "live-a-1",
            isEpochCurrent: { true }
        )
        _ = try store.commitStep2MarkInFlight(batchID: botAStep1.batchID)

        // Opening Bot B's controller MUST NOT flip Bot A's live `.inFlight` batch to `.needsReconcile`.
        _ = CasualTrackController(botID: "bot-b", store: store)
        XCTAssertEqual(store.loadOutboxBatch(batchID: "live-a-1")?.state, .inFlight)

        // Reply persistence failure leaves Bot A's batch open.
        let ctrlA = CasualTrackController(botID: "bot-a", store: store)
        store.simulateEntryWriteFailure = { _ in InjectedIOError(message: "reply-disk-full") }
        XCTAssertFalse(ctrlA.persistReplyAndComplete(batchID: "live-a-1", reply: "回复内容"))
        XCTAssertEqual(store.loadOutboxBatch(batchID: "live-a-1")?.state, .inFlight)
        store.simulateEntryWriteFailure = nil

        // Manual resend failure when persisting the replacement batch MUST NOT close the old reconciled batch.
        _ = store.reconcileOnColdStart()
        ctrlA.reload()
        let reconciled = try XCTUnwrap(ctrlA.reconcileBatches.first { $0.batchID == "live-a-1" })
        store.simulateOutboxWriteFailure = { batch in
            batch.state == .queuedBeforeSend ? InjectedIOError(message: "resend-save-failed") : nil
        }
        let team = TeamModel()
        let botA = BotInfo(id: "bot-a", name: "甲")
        XCTAssertFalse(ctrlA.explicitlyResendReconciledBatch(reconciled, team: team, bot: botA, dispatchNow: false))
        XCTAssertEqual(store.loadOutboxBatch(batchID: "live-a-1")?.state, .needsReconcile)
        XCTAssertEqual(ctrlA.reconcileBatches.count, 1)
    }

    // MARK: - CX-10: SubConversationStore Corrupt Single-File Tolerance

    func testSubConversationStoreSkipsCorruptJSONWithoutBreakingListing() async throws {
        let dir = try makeTempDir("subconv-corrupt")
        defer { try? FileManager.default.removeItem(at: dir) }

        let teamDir = dir.appendingPathComponent("Team", isDirectory: true)
        let indexDir = dir.appendingPathComponent("ClioIndex", isDirectory: true)
        let store = SubConversationStore(teamRoot: teamDir, indexRoot: indexDir)

        let valid = SubConversationRecord(
            origin: SubConversationOrigin(sourceChatKey: "bot-a", sourceEntryID: "e1", selectedQuote: "好句子"),
            inheritedPlanMode: false,
            inheritedTaint: false
        )
        try await store.save(valid)

        // Write a second truncated corrupt JSON file with a valid UUID filename.
        let corruptID = UUID()
        let corruptURL = teamDir
            .appendingPathComponent("subconversations", isDirectory: true)
            .appendingPathComponent("\(corruptID.uuidString).json")
        try Data("{broken json".utf8).write(to: corruptURL, options: .atomic)

        let listed = try await store.records()
        XCTAssertEqual(listed.map(\.id), [valid.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: corruptURL.path), "Corrupt file must be kept untouched on disk")
    }
}
