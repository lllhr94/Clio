import AgentKit
@testable import Clio
import Craft
import CryptoKit
import Foundation
import XCTest

final class ClioAppPR1ATests: XCTestCase {
    func testBackupStripsMountsAndUnionsTombstonesIntoMemoryAndExperiences() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clio-app-backup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let stagedTeam = dir.appendingPathComponent("Team", isDirectory: true)
        let revisionsDir = stagedTeam.appendingPathComponent("memory-revisions", isDirectory: true)
        try FileManager.default.createDirectory(at: revisionsDir, withIntermediateDirectories: true)

        try Data("[]".utf8).write(to: stagedTeam.appendingPathComponent("mounts.json"))
        try Data("{}".utf8).write(to: stagedTeam.appendingPathComponent("trash-index.json"))
        try Data("journal".utf8).write(to: revisionsDir.appendingPathComponent("commit.journal"))
        try Data("{}".utf8).write(to: revisionsDir.appendingPathComponent("rev-100.json"))

        let forgottenMemoryText = "需要忘掉的旧住址"
        let keptMemoryText = "保留的工作习惯"
        let stagedMemBook = CanonicalMemoryBook(
            memories: [
                CanonicalMemoryItem(id: "m1", text: forgottenMemoryText, at: 100),
                CanonicalMemoryItem(id: "m2", text: keptMemoryText, at: 200),
            ]
        )
        try JSONEncoder().encode(stagedMemBook).write(to: stagedTeam.appendingPathComponent("memory.json"))

        let forgottenExp = ExperienceRecord(id: "e1", title: "过期经验", content: "不应该恢复的步骤", source: .mainChat)
        let keptExp = ExperienceRecord(id: "e2", title: "有效经验", content: "应当保留的操作流程", source: .user)
        let stagedExpBook = CanonicalExperienceBook(records: [forgottenExp, keptExp])
        try JSONEncoder().encode(stagedExpBook).write(to: stagedTeam.appendingPathComponent("experiences.json"))

        let strippedMounts = Backup.stripDisallowedStagedArtifacts(in: stagedTeam)
        XCTAssertTrue(strippedMounts)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedTeam.appendingPathComponent("mounts.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedTeam.appendingPathComponent("trash-index.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: revisionsDir.appendingPathComponent("commit.journal").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: revisionsDir.appendingPathComponent("rev-100.json").path))

        let localTombstones = Set([
            MemorySafety.retractionHash(forgottenMemoryText),
            forgottenExp.contentSHA256.lowercased(),
        ])
        try Backup.applyTombstoneUnionToStagedTeam(stagedTeam: stagedTeam, localRetractedHashes: localTombstones, nowMs: 5_000)

        let mergedRetracted = try JSONDecoder().decode(
            [String].self,
            from: Data(contentsOf: stagedTeam.appendingPathComponent("memory-retracted.json"))
        )
        XCTAssertTrue(mergedRetracted.contains(MemorySafety.retractionHash(forgottenMemoryText)))

        let mergedMem = try CanonicalMemoryBook.decodeFlexible(
            from: Data(contentsOf: stagedTeam.appendingPathComponent("memory.json"))
        )
        XCTAssertEqual(mergedMem.memories.map(\.text), [keptMemoryText])

        let mergedExp = try JSONDecoder().decode(
            CanonicalExperienceBook.self,
            from: Data(contentsOf: stagedTeam.appendingPathComponent("experiences.json"))
        )
        let activeExps = mergedExp.records.filter { $0.deletedAtMs == nil }
        XCTAssertEqual(activeExps.map(\.id), ["e2"])

        // P1-6 & #6: corrupt or 0-byte local/staged ledgers (all 6 ledger combinations) MUST throw while preserving
        // BOTH valid sibling ledgers byte-for-byte and leaving the 0-byte file at 0 bytes; legacy plaintext normalizes cleanly.
        let corruptLiveTeam = dir.appendingPathComponent("CorruptLiveTeam", isDirectory: true)
        try FileManager.default.createDirectory(at: corruptLiveTeam, withIntermediateDirectories: true)
        try Data("{corrupt json".utf8).write(to: corruptLiveTeam.appendingPathComponent("experiences.json"))
        XCTAssertThrowsError(try Backup.collectLocalRetractedHashes(in: corruptLiveTeam, memoryStoreTombstones: []))

        let validSibMemData = try JSONEncoder().encode(
            CanonicalMemoryBook(memories: [CanonicalMemoryItem(id: "m-sib", text: "兄弟账本必须原字节保留", at: 300)])
        )
        let validSibExpData = try JSONEncoder().encode(
            CanonicalExperienceBook(records: [ExperienceRecord(id: "e-sib", title: "合法兄弟经验", content: "不能被局部写坏", source: .user)])
        )
        let validSibRetractedData = try JSONEncoder().encode([MemorySafety.retractionHash("合法兄弟撤回")])
        let ledgerFixtures: [(name: String, bytes: Data)] = [
            ("memory.json", validSibMemData),
            ("experiences.json", validSibExpData),
            ("memory-retracted.json", validSibRetractedData),
        ]

        for target in ledgerFixtures {
            let zeroLive = dir.appendingPathComponent("ZeroLive-\(target.name)", isDirectory: true)
            try FileManager.default.createDirectory(at: zeroLive, withIntermediateDirectories: true)
            let zeroURL = zeroLive.appendingPathComponent(target.name)
            try Data().write(to: zeroURL)
            let siblings = ledgerFixtures.filter { $0.name != target.name }
            for sib in siblings {
                try sib.bytes.write(to: zeroLive.appendingPathComponent(sib.name))
            }
            XCTAssertThrowsError(
                try Backup.collectLocalRetractedHashes(in: zeroLive, memoryStoreTombstones: []),
                "Expected local 0-byte \(target.name) to throw"
            )
            XCTAssertEqual(try Data(contentsOf: zeroURL), Data())
            for sib in siblings {
                XCTAssertEqual(try Data(contentsOf: zeroLive.appendingPathComponent(sib.name)), sib.bytes)
            }
        }

        let legacyPlaintextTeam = dir.appendingPathComponent("LegacyPlaintextTeam", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyPlaintextTeam, withIntermediateDirectories: true)
        let legacyPlaintext = "旧版明文抹除记忆"
        try JSONEncoder().encode([legacyPlaintext]).write(to: legacyPlaintextTeam.appendingPathComponent("memory-retracted.json"))
        let normalizedFromLegacy = try Backup.collectLocalRetractedHashes(in: legacyPlaintextTeam, memoryStoreTombstones: [])
        XCTAssertEqual(normalizedFromLegacy, Set([MemorySafety.retractionHash(legacyPlaintext)]))

        let legacyStaged = dir.appendingPathComponent("LegacyStaged", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyStaged, withIntermediateDirectories: true)
        let legacyBook = CanonicalMemoryBook(memories: [
            CanonicalMemoryItem(id: "m-legacy", text: legacyPlaintext, at: 100),
            CanonicalMemoryItem(id: "m-stay", text: keptMemoryText, at: 200),
        ])
        try JSONEncoder().encode(legacyBook).write(to: legacyStaged.appendingPathComponent("memory.json"))
        try Backup.applyTombstoneUnionToStagedTeam(stagedTeam: legacyStaged, localRetractedHashes: normalizedFromLegacy, nowMs: 5_500)
        let prunedLegacy = try CanonicalMemoryBook.decodeFlexible(from: Data(contentsOf: legacyStaged.appendingPathComponent("memory.json")))
        XCTAssertEqual(prunedLegacy.memories.map(\.id), ["m-stay"])

        let corruptStage = dir.appendingPathComponent("CorruptStage", isDirectory: true)
        try FileManager.default.createDirectory(at: corruptStage, withIntermediateDirectories: true)
        try Data("{corrupt memory".utf8).write(to: corruptStage.appendingPathComponent("memory.json"))
        XCTAssertThrowsError(try Backup.applyTombstoneUnionToStagedTeam(stagedTeam: corruptStage, localRetractedHashes: [], nowMs: 6_000))

        for target in ledgerFixtures {
            let zeroStage = dir.appendingPathComponent("ZeroStage-\(target.name)", isDirectory: true)
            try FileManager.default.createDirectory(at: zeroStage, withIntermediateDirectories: true)
            let zeroURL = zeroStage.appendingPathComponent(target.name)
            try Data().write(to: zeroURL)
            let siblings = ledgerFixtures.filter { $0.name != target.name }
            for sib in siblings {
                try sib.bytes.write(to: zeroStage.appendingPathComponent(sib.name))
            }
            XCTAssertThrowsError(
                try Backup.applyTombstoneUnionToStagedTeam(
                    stagedTeam: zeroStage,
                    localRetractedHashes: Set([MemorySafety.retractionHash("触发修改检查")]),
                    nowMs: 6_500
                ),
                "Expected staged 0-byte \(target.name) to throw"
            )
            XCTAssertEqual(try Data(contentsOf: zeroURL), Data())
            for sib in siblings {
                XCTAssertEqual(try Data(contentsOf: zeroStage.appendingPathComponent(sib.name)), sib.bytes)
            }
        }
    }

    func testColdStartRollsBackJournalAndRebuildsMemoryProjection() async throws {
        let dir = try temporaryRoot()
        let teamRoot = dir.appendingPathComponent("Team", isDirectory: true)
        let dbURL = dir.appendingPathComponent("ClioMemory/clio-memory.db")
        let expBridge = ExperienceStoreBridge(teamRoot: teamRoot)
        let bridge = MemoryStoreBridge(
            databaseURL: dbURL,
            teamRoot: teamRoot,
            mirrorRoot: dir.appendingPathComponent("Mirrors"),
            experienceBridge: expBridge
        )
        _ = try await expBridge.recordOffMain(id: "experience", title: "Deploy", content: "Run the tests", tags: [], source: .user)
        let experienceBytes = try Data(contentsOf: expBridge.canonicalFileURL)
        let book = CanonicalMemoryBook(
            memories: [CanonicalMemoryItem(id: "m1", text: "快照里的旧记录", at: 100)], generation: 1
        )
        let commit = try bridge.revisionStore.commitWithJournal(book, snapshotReason: "manual", nowMs: 1_000)
        let snapshotID = try XCTUnwrap(commit.snapshot?.id)
        let journal = MemoryPendingJournal(
            id: "bridge-j1", phase: .prepared, targetCanonicalGeneration: 2,
            preCommitSHA256: commit.digest, postCommitSHA256: String(repeating: "a", count: 64),
            preCommitSnapshotID: snapshotID, preCommitBookSHA256: commit.snapshot?.bookSHA256
        )
        let journalBytes = try JSONEncoder().encode(journal)
        try journalBytes.write(to: bridge.revisionStore.journalFileURL)
        XCTAssertEqual(
            try bridge.runColdStartRecoveryForTesting(nowMs: 2_000),
            .rolledBackToSnapshot(journalID: journal.id, snapshotID: snapshotID)
        )
        XCTAssertTrue(bridge.revisionStore.hasPendingProjectionRebuild)

        let dirty = CanonicalMemoryBook(memories: [CanonicalMemoryItem(id: "dirty", text: "未提交", at: 200)])
        try JSONEncoder().encode(dirty).write(to: bridge.revisionStore.memoryFileURL)
        try journalBytes.write(to: bridge.revisionStore.journalFileURL)
        let staleStore = MemoryStore(databaseURL: dbURL)
        _ = try staleStore.upsert(MemoryRecord(id: "stale", text: "旧索引残留", createdAtMs: 2_000), explicitUserAction: true)
        staleStore.close()

        let bootstrap = bridge.bootstrapOnLaunch()
        XCTAssertEqual(bootstrap.book.memories.map(\.id), ["m1"])
        XCTAssertEqual(bridge.recordsSnapshot().map(\.id), ["m1"])
        XCTAssertFalse(bridge.revisionStore.hasPendingProjectionRebuild)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bridge.revisionStore.journalFileURL.path))
        XCTAssertEqual(try Data(contentsOf: expBridge.canonicalFileURL), experienceBytes)

        let corruptedJournal = Data("{corrupt-journal".utf8)
        try corruptedJournal.write(to: bridge.revisionStore.journalFileURL)
        try Data(#"{"pendingRebuild":true}"#.utf8).write(to: bridge.revisionStore.projectionRebuildMarkerURL)
        _ = bridge.bootstrapOnLaunch()
        XCTAssertTrue(bridge.revisionStore.hasPendingProjectionRebuild)
        XCTAssertEqual(try Data(contentsOf: bridge.revisionStore.journalFileURL), corruptedJournal)
    }

    func testDoubleCorruptMemoryKeepsProjectionAndMarker() throws {
        let dir = try temporaryRoot()
        let team = dir.appendingPathComponent("Team")
        let db = dir.appendingPathComponent("ClioMemory/clio-memory.db")
        let bridge = MemoryStoreBridge(databaseURL: db, teamRoot: team, mirrorRoot: dir.appendingPathComponent("Mirrors"))
        try FileManager.default.createDirectory(at: bridge.revisionStore.revisionsDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: db.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dbBytes = Data("corrupt SQLite header".utf8)
        let markerBytes = Data(#"{"pendingRebuild":true}"#.utf8)
        try dbBytes.write(to: db)
        try markerBytes.write(to: bridge.revisionStore.projectionRebuildMarkerURL)
        for canonicalBytes in [Data("{corrupt-memory".utf8), Data()] {
            try canonicalBytes.write(to: bridge.revisionStore.memoryFileURL)
            _ = bridge.bootstrapOnLaunch()
            bridge.checkpointForTestingSync()
            XCTAssertTrue(bridge.isCanonicalReadOnly)
            XCTAssertTrue(bridge.revisionStore.hasPendingProjectionRebuild)
            XCTAssertNil(bridge.restorableMemorySnapshot(id: "archived"))
            XCTAssertNil(bridge.archivedMemorySnapshot(id: "archived"))
            XCTAssertEqual(try Data(contentsOf: db), dbBytes)
            XCTAssertEqual(try Data(contentsOf: bridge.revisionStore.memoryFileURL), canonicalBytes)
            XCTAssertEqual(try Data(contentsOf: bridge.revisionStore.projectionRebuildMarkerURL), markerBytes)
        }
    }

    func testReadOnlyTeamDirectoryPreservesCanonicalAndRecoveryMarker() async throws {
        let dir = try temporaryRoot()
        let roTeam = dir.appendingPathComponent("Team", isDirectory: true)
        let roMirror = dir.appendingPathComponent("Mirrors", isDirectory: true)
        let roDB = dir.appendingPathComponent("ClioMemory/ro.db")
        try FileManager.default.createDirectory(at: roTeam, withIntermediateDirectories: true)
        let roBridge = MemoryStoreBridge(databaseURL: roDB, teamRoot: roTeam, mirrorRoot: roMirror)
        let commit = try roBridge.revisionStore.commitWithJournal(
            CanonicalMemoryBook(
                memories: [
                    CanonicalMemoryItem(id: "m-keep", text: "应当保留的控制记录", at: 100),
                    CanonicalMemoryItem(id: "m-prune", text: "需要撤回的旧条", at: 100),
                ],
                tombstones: [
                    MemoryTombstone(
                        textSHA256: MemorySafety.retractionHash("需要撤回的旧条"),
                        memoryID: "m-prune",
                        deletedAtMs: 5_000,
                        reason: "user_delete"
                    ),
                ]
            ),
            nowMs: 1_000
        )
        let beforeROMemBytes = try Data(contentsOf: roBridge.revisionStore.memoryFileURL)
        let beforeRODigest = SHA256.hash(data: beforeROMemBytes).map { String(format: "%02x", $0) }.joined()
        try Data("{\"pendingRebuild\":true}\n".utf8).write(to: roBridge.revisionStore.projectionRebuildMarkerURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: roTeam.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: roTeam.path) }
        _ = roBridge.bootstrapOnLaunch()
        XCTAssertTrue(roBridge.revisionStore.hasPendingProjectionRebuild)
        XCTAssertEqual(try Data(contentsOf: roBridge.revisionStore.memoryFileURL), beforeROMemBytes)
        let roCheckMem = MemoryStore(databaseURL: roDB)
        XCTAssertEqual(try roCheckMem.list().map(\.id), ["m-keep"])
        XCTAssertEqual(try roCheckMem.meta().lastSyncedJSONSHA256, beforeRODigest)
        roCheckMem.close()
        let snapshotID = try XCTUnwrap(commit.snapshot?.id)
        do {
            _ = try await roBridge.restoreRevisionSnapshotOffMain(id: snapshotID, bots: [], mainBotId: nil)
            XCTFail("Expected a read-only Team directory to prevent canonical restore")
        } catch {
            XCTAssertTrue(roBridge.revisionStore.hasPendingProjectionRebuild)
            XCTAssertEqual(try Data(contentsOf: roBridge.revisionStore.memoryFileURL), beforeROMemBytes)
        }
    }

    @MainActor
    func testSnapshotRestoreRejectsStaleEpochAndPreservesRecoveryAcrossRelaunch() async throws {
        let dir = try temporaryRoot()
        let restoreTeam = dir.appendingPathComponent("Team", isDirectory: true)
        let restoreMirror = dir.appendingPathComponent("Mirrors", isDirectory: true)
        let restoreDB = dir.appendingPathComponent("ClioMemory/restore.db")
        do {
            let restoreBridge = MemoryStoreBridge(databaseURL: restoreDB, teamRoot: restoreTeam, mirrorRoot: restoreMirror)
            let blockedExpHash = MemorySafety.retractionHash("已撤回的内容")
            let snap1 = try restoreBridge.revisionStore.commitWithJournal(
                CanonicalMemoryBook(
                    memories: [CanonicalMemoryItem(id: "m-snap1", text: "快照一保留记忆", at: 100)],
                    suppressedFlushHashes: [blockedExpHash],
                    tombstones: [
                        MemoryTombstone(
                            textSHA256: blockedExpHash,
                            memoryID: "m-ret",
                            deletedAtMs: 5_000,
                            reason: "user_delete"
                        ),
                    ],
                    generation: 1
                ),
                snapshotReason: "manual",
                nowMs: 1_000
            )
            let snap1ID = try XCTUnwrap(snap1.snapshot?.id)
            _ = try restoreBridge.revisionStore.commitWithJournal(
                CanonicalMemoryBook(
                    memories: [CanonicalMemoryItem(id: "m-snap2", text: "没有该撤回记录的状态", at: 2_000)],
                    generation: 2
                ),
                nowMs: 2_000
            )
            let preRestoreBoot = restoreBridge.bootstrapOnLaunch()
            XCTAssertFalse(restoreBridge.tombstoneHashesSnapshot().contains(blockedExpHash))
            XCTAssertNotNil(preRestoreBoot.book.storeEpoch)
            var staleMainActorBook = preRestoreBoot.book
            staleMainActorBook.memories.append(
                Memory(id: "m-post-restore-stale-book", text: "主线程未应用快照前的旧副本", at: 2_700, by: nil, deep: nil, used: nil)
            )

            let restored = try await restoreBridge.restoreRevisionSnapshotOffMain(id: snap1ID, bots: [], mainBotId: nil)
            XCTAssertEqual(restored.book.memories.map(\Memory.id), ["m-snap1"])
            XCTAssertNotEqual(restored.book.storeEpoch, staleMainActorBook.storeEpoch)
            XCTAssertTrue(restoreBridge.tombstoneHashesSnapshot().contains(blockedExpHash))
            XCTAssertFalse(restoreBridge.revisionStore.hasPendingProjectionRebuild)
            XCTAssertThrowsError(
                try restoreBridge.commitAppBook(staleMainActorBook, suppressedHashes: [], bots: [], mainBotId: nil, secrets: [])
            ) {
                XCTAssertTrue(($0 as? TeamError)?.message.contains("过期覆盖写入") == true)
            }
            do {
                _ = try await restoreBridge.commitAppBookAsync(
                    staleMainActorBook, suppressedHashes: [], bots: [], mainBotId: nil, secrets: []
                )
                XCTFail("Expected the async commit to reject an old store epoch")
            } catch {
                XCTAssertTrue((error as? TeamError)?.message.contains("过期覆盖写入") == true)
                XCTAssertEqual(try CanonicalMemoryBook.decodeFlexible(
                    from: Data(contentsOf: restoreBridge.revisionStore.memoryFileURL)
                ).memories.map(\.id), ["m-snap1"])
            }

            let retractedPath = restoreTeam.appendingPathComponent("memory-retracted.json")
            try FileManager.default.removeItem(at: retractedPath)
            try FileManager.default.createDirectory(at: retractedPath, withIntermediateDirectories: true)
            do {
                _ = try await restoreBridge.restoreRevisionSnapshotOffMain(id: snap1ID, bots: [], mainBotId: nil)
                XCTFail("Expected restore to fail when the retraction ledger is a directory")
            } catch {
                XCTAssertTrue(restoreBridge.revisionStore.hasPendingProjectionRebuild)
            }
            restoreBridge.flushSync()
        }

        let relaunch = MemoryStoreBridge(databaseURL: restoreDB, teamRoot: restoreTeam, mirrorRoot: restoreMirror)
        let relaunched = relaunch.bootstrapOnLaunch()
        XCTAssertTrue(relaunch.revisionStore.hasPendingProjectionRebuild)
        XCTAssertThrowsError(try relaunch.commitAppBook(
            relaunched.book, suppressedHashes: [], bots: [], mainBotId: nil, secrets: []
        ))
    }

    @MainActor
    func testRecallMergesWithSameEpochRemember() async throws {
        let dir = try temporaryRoot()
        let recallDir = dir.appendingPathComponent("recall-merge-\(UUID().uuidString)", isDirectory: true)
        let recallTeam = recallDir.appendingPathComponent("Team", isDirectory: true)
        let recallMirror = recallDir.appendingPathComponent("Mirrors", isDirectory: true)
        let recallDB = recallDir.appendingPathComponent("ClioMemory/recall.db")
        try FileManager.default.createDirectory(at: recallTeam, withIntermediateDirectories: true)
        let recallBridge = MemoryStoreBridge(databaseURL: recallDB, teamRoot: recallTeam, mirrorRoot: recallMirror)
        _ = try recallBridge.revisionStore.commitWithJournal(
            CanonicalMemoryBook(memories: [
                CanonicalMemoryItem(id: "m-deep-hit", text: "北海道冬天滑雪攻略", at: 1_000, deep: true),
            ]),
            nowMs: 1_000
        )
        let recallBoot = recallBridge.bootstrapOnLaunch()
        let staleRecallSnapshotBook = recallBoot.book

        let addedMem = Memory(id: "m-concurrent-added", text: "同版本新写入的重要记忆", at: 2_000, by: nil, deep: nil, used: nil)
        var concurrentRememberBook = recallBoot.book
        concurrentRememberBook.memories.append(addedMem)
        _ = try await recallBridge.commitAppBookAsync(
            concurrentRememberBook,
            mutation: .remember(memory: addedMem, explicitUserAction: true, nowMs: 2_000),
            suppressedHashes: [],
            bots: [],
            mainBotId: nil,
            secrets: []
        )

        var staleRecallUpdatedBook = staleRecallSnapshotBook
        staleRecallUpdatedBook.memories[0].deep = nil
        staleRecallUpdatedBook.memories[0].used = 9_000
        let (mergedAfterRecall, _) = try await recallBridge.commitAppBookAsync(
            staleRecallUpdatedBook,
            mutation: .recall(ids: ["m-deep-hit"], nowMs: 9_000),
            suppressedHashes: [],
            bots: [],
            mainBotId: nil,
            secrets: []
        )
        XCTAssertEqual(Set(mergedAfterRecall.memories.map(\.id)), Set(["m-deep-hit", "m-concurrent-added"]))
        let diskAfterRecall = try CanonicalMemoryBook.decodeFlexible(
            from: Data(contentsOf: recallBridge.revisionStore.memoryFileURL)
        )
        XCTAssertEqual(Set(diskAfterRecall.memories.map(\.id)), Set(["m-deep-hit", "m-concurrent-added"]))
        let surfacedHit = try XCTUnwrap(diskAfterRecall.memories.first(where: { $0.id == "m-deep-hit" }))
        XCTAssertNil(surfacedHit.deep)
        XCTAssertEqual(surfacedHit.used, 9_000)
    }

    @MainActor
    func testExperienceBridgeUsesLiveTombstonesAndHonorsPolicyAndFreeze() async throws {
        let dir = try temporaryRoot()
        let teamRoot = dir.appendingPathComponent("Team")
        try FileManager.default.createDirectory(at: teamRoot, withIntermediateDirectories: true)
        let experiences = ExperienceStoreBridge(teamRoot: teamRoot)
        let memory = MemoryStoreBridge(
            databaseURL: dir.appendingPathComponent("ClioMemory/clio-memory.db"),
            teamRoot: teamRoot, mirrorRoot: dir.appendingPathComponent("Mirrors"), experienceBridge: experiences
        )
        let previousPolicy = Grant.memory.policy
        let previousFrozen = Disk.frozen
        Grant.memory.policy = .allow
        Disk.frozen = false
        defer {
            Grant.memory.policy = previousPolicy
            Disk.frozen = previousFrozen
        }

        let vaultKey = "pr1a-test-\(UUID())"
        let secret = "temporary-test-secret-\(UUID())"
        Vault.save(secret, as: vaultKey)
        defer { Vault.remove(vaultKey) }
        XCTAssertTrue(Vault.allStrings().contains(secret))
        let redactedBody = "deploy using 〔隐去〕"
        let bodyHash = MemorySafety.retractionHash(redactedBody)
        let rawHash = MemorySafety.retractionHash("legacy identity")
        let book = CanonicalExperienceBook(records: [
            ExperienceRecord(id: "body", title: "Legacy", content: "deploy using \(secret)"),
            ExperienceRecord(id: "raw", title: "Legacy", content: "deploy using a pipeline", contentSHA256: rawHash),
            ExperienceRecord(id: "control", title: "Control", content: "deploy with tests"),
        ])
        try JSONEncoder().encode(book).write(to: experiences.canonicalFileURL)
        let initiallyVisible = await experiences.loadAllOffMain()
        XCTAssertEqual(Set(initiallyVisible.map(\.id)), ["body", "raw", "control"])
        XCTAssertEqual(initiallyVisible.first { $0.id == "body" }?.content, redactedBody)

        let retracted = teamRoot.appendingPathComponent("memory-retracted.json")
        try JSONEncoder().encode([bodyHash, rawHash]).write(to: retracted)
        XCTAssertEqual(memory.tombstoneHashesSnapshot(), [bodyHash, rawHash])
        let visible = await experiences.loadAllOffMain()
        XCTAssertEqual(visible.map(\.id), ["control"])
        let beforeSearch = try Data(contentsOf: experiences.canonicalFileURL)
        let hits = await experiences.searchTool(query: "deploy", limit: 5)
        XCTAssertEqual(hits.map(\.id), ["control"])
        XCTAssertEqual(try Data(contentsOf: experiences.canonicalFileURL), beforeSearch)
        for record in book.records where record.id != "control" {
            do {
                _ = try await experiences.recordOffMain(
                    id: record.id, title: record.title, content: record.content, tags: [], source: .mainChat
                )
                XCTFail("Expected the live tombstone to block \(record.id)")
            } catch {
                XCTAssertEqual(error as? ExperienceStoreError, .suppressedByTombstone)
            }
        }

        let blocked = await experiences.recordTool(
            title: "Tool", content: redactedBody, tags: [], source: .mainChat
        )
        XCTAssertTrue(blocked.isError)
        XCTAssertEqual(try Data(contentsOf: experiences.canonicalFileURL), beforeSearch)
        Grant.memory.policy = .off
        let denied = await experiences.recordTool(title: "Tool", content: "deploy with checks", tags: [], source: .mainChat)
        let deniedHits = await experiences.searchTool(query: "deploy", limit: 5)
        XCTAssertTrue(denied.isError)
        XCTAssertTrue(deniedHits.isEmpty)
        Grant.memory.policy = .allow
        let allowed = await experiences.recordTool(title: "Tool", content: "deploy with checks", tags: [], source: .mainChat)
        XCTAssertFalse(allowed.isError)

        Disk.frozen = true
        let frozenBytes = try Data(contentsOf: experiences.canonicalFileURL)
        let frozenLoad = await experiences.loadAllOffMain()
        let frozenHits = await experiences.searchTool(query: "deploy", limit: 5)
        let frozenTool = await experiences.recordTool(title: "Frozen", content: "deploy now", tags: [], source: .user)
        XCTAssertTrue(frozenLoad.isEmpty)
        XCTAssertTrue(frozenHits.isEmpty)
        XCTAssertTrue(frozenTool.isError)
        do {
            _ = try await experiences.recordOffMain(title: "Frozen", content: "deploy now", tags: [], source: .user)
            XCTFail("Expected a frozen store to reject recording")
        } catch ExperienceStoreError.canonicalReadOnly(_) { }
        do {
            try await experiences.deleteOffMain(id: "control")
            XCTFail("Expected a frozen store to reject deletion")
        } catch ExperienceStoreError.canonicalReadOnly(_) { }
        experiences.mergeRetractedHashesSync([MemorySafety.retractionHash("deploy with tests")])
        XCTAssertEqual(try Data(contentsOf: experiences.canonicalFileURL), frozenBytes)
    }

    func testBackupBarrierRunsOnExperienceQueueAndPropagatesErrors() throws {
        enum Expected: Error { case failure }
        let dir = try temporaryRoot()
        let experiences = ExperienceStoreBridge(teamRoot: dir)
        let bridge = MemoryStoreBridge(
            databaseURL: dir.appendingPathComponent("memory.db"), teamRoot: dir,
            mirrorRoot: dir.appendingPathComponent("Mirrors"), experienceBridge: experiences
        )
        let key = DispatchSpecificKey<Int>()
        experiences.queue.setSpecific(key: key, value: 1)
        let value = try bridge.withBackupBarrier {
            XCTAssertEqual(DispatchQueue.getSpecific(key: key), 1)
            return try ExperienceStore(canonicalFileURL: experiences.canonicalFileURL).readBook()
        }
        XCTAssertTrue(value.records.isEmpty)
        XCTAssertThrowsError(try bridge.withBackupBarrier { throw Expected.failure }) {
            XCTAssertEqual($0 as? Expected, .failure)
        }
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clio-pr1a-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    @MainActor
    func testTeamModelExperienceSourceGatingZeroWriteRecallReadOnlyAndProcessedDedupe() async throws {
        let previousMemoryPolicy = Grant.memory.policy
        Grant.memory.policy = .allow
        defer { Grant.memory.policy = previousMemoryPolicy }

        let team = TeamModel()
        team.phase = .demo
        let bot = BotInfo(id: "b-test", name: "小测", role: nil, instructions: nil, model: nil)

        // 1. Experience write-source propagation across routine / subtask / mainChat
        let routineTools = team.tools(for: bot, key: "bot-b-test", canSee: false, helping: false, workplace: .desk, experienceSource: .routine)
        if let recTool = routineTools.first(where: { $0.spec.name == "record_experience" }) {
            let out = try await recTool.run(.object(["title": .string("定时测试"), "content": .string("应被拦截")]))
            XCTAssertTrue(out.isError)
        } else {
            XCTFail("Expected record_experience tool")
        }

        let subtaskTools = team.tools(for: bot, key: "bot-b-test", canSee: false, helping: true, workplace: .desk, experienceSource: .mainChat)
        if let recTool = subtaskTools.first(where: { $0.spec.name == "record_experience" }) {
            let out = try await recTool.run(.object(["title": .string("子任务测试"), "content": .string("应被拦截")]))
            XCTAssertTrue(out.isError)
        } else {
            XCTFail("Expected record_experience tool in subtask")
        }

        // 2. Zero-write recallReadOnly across deep + surface + pinned (even under `keeping = true`, must never touch DB/timestamps)
        let deepItem = Memory(id: "d-readonly", text: "去年冬天去北海道滑雪的计划", at: 500, by: nil, deep: true, used: nil)
        let surfaceItem = Memory(id: "s-readonly", text: "平时冬天喜欢喝热可可", at: 900, by: nil, deep: nil, used: nil)
        team.memories = [deepItem, surfaceItem]

        let hits = await team.recallReadOnly("冬天")
        XCTAssertTrue(hits.contains(deepItem.text))
        XCTAssertTrue(hits.contains(surfaceItem.text))
        XCTAssertEqual(team.memories.first(where: { $0.id == "d-readonly" })?.deep, true)
        XCTAssertNil(team.memories.first(where: { $0.id == "d-readonly" })?.used)
        XCTAssertNil(team.memories.first(where: { $0.id == "s-readonly" })?.used)

        // 3. 05:00 -> 04:00 processed dedupe across legacy day buckets
        let deduped = TeamModel.processedEntryIDs(in: [
            "2026-11-26": ["entry-0430-legacy"],
            "2026-11-27": ["entry-0430-legacy", "entry-1000-new"],
        ])
        XCTAssertEqual(deduped, ["entry-0430-legacy", "entry-1000-new"])

        // 4. Pause / Resume preserves `.routine` provenance across natural Task exit
        let pauseKey = "bot-b-pause-pr1a-\(UUID())"
        defer {
            ChatDisk.finishWrites()
            Disk.remove(Disk.chatFile(pauseKey))
            Disk.remove(TeamModel.optionsFile(pauseKey))
        }
        team.start(pauseKey, userInitiated: false, experienceSource: .routine)
        team.pause(pauseKey)
        let pausedAway = try XCTUnwrap(team.pausedAway.removeValue(forKey: pauseKey))
        let pauseExited = await waitUntil { team.runs[pauseKey] == nil }
        XCTAssertTrue(pauseExited)
        team.pausedAway[pauseKey] = pausedAway
        team.resumePaused()
        XCTAssertEqual(team.activeTurnExperienceSource[pauseKey], .routine)
        XCTAssertEqual(team.history(pauseKey).last?.experienceSource, ExperienceWriteSource.routine.rawValue)
        team.stop(pauseKey)
        let pauseStopped = await waitUntil { team.runs[pauseKey] == nil }
        XCTAssertTrue(pauseStopped)

        // 5. Persisted `.routine` history reloaded into a fresh TeamModel keeps `.routine` on `retry`,
        // `resend` on legacy prefix/morning-letter/unknown source never escalates, stale `pausedAway` cannot
        // supersede a new `.mainChat` turn, and an interject during `.routine` keeps `.routine` across `retry`.
        let retryKey = "bot-pr1a-retry-\(UUID().uuidString)"
        let resendLegacyKey = "bot-pr1a-resend-legacy-\(UUID().uuidString)"
        let resendMorningKey = "bot-pr1a-resend-morning-\(UUID().uuidString)"
        let resendUnknownKey = "bot-pr1a-resend-unknown-\(UUID().uuidString)"
        let supKey = "bot-pr1a-sup-\(UUID().uuidString)"
        let intKey = "bot-pr1a-int-\(UUID().uuidString)"
        defer {
            ChatDisk.finishWrites()
            for key in [retryKey, resendLegacyKey, resendMorningKey, resendUnknownKey, supKey, intKey] {
                Disk.remove(Disk.chatFile(key))
                Disk.remove(TeamModel.optionsFile(key))
                QueuedStore.clear(key)
            }
        }
        let persistedRoutineHistory = [
            Entry(id: "u-routine-1", at: 1_000, message: .user("例行播报"), experienceSource: ExperienceWriteSource.routine.rawValue),
            Entry(id: "a-routine-1", at: 2_000, message: .assistant("旧回答"), speaker: "b-test"),
        ]
        try ChatDisk.saveAndWait(persistedRoutineHistory, chat: retryKey)
        let freshTeam = TeamModel()
        freshTeam.phase = .ready
        freshTeam.retry(retryKey)
        XCTAssertEqual(freshTeam.activeTurnExperienceSource[retryKey], .routine)
        XCTAssertNil(freshTeam.history(retryKey).first(where: { $0.id == "a-routine-1" }))
        freshTeam.phase = .demo
        freshTeam.stop(retryKey)
        let freshStopped = await waitUntil { freshTeam.runs[retryKey] == nil }
        XCTAssertTrue(freshStopped)

        team.phase = .ready
        team.entries[resendLegacyKey] = [
            Entry(id: "u-leg", at: 1_000, message: .user("【定时 · 晚报】自动例会总结")),
            Entry(id: "a-leg", at: 2_000, message: .assistant("晚报回复"), speaker: "b-test"),
        ]
        XCTAssertTrue(team.resend(resendLegacyKey, entry: "u-leg", text: "去掉了定时前缀的新提问"))
        XCTAssertEqual(team.activeTurnExperienceSource[resendLegacyKey], .routine)
        XCTAssertEqual(team.history(resendLegacyKey).last?.experienceSource, ExperienceWriteSource.routine.rawValue)
        team.stop(resendLegacyKey)
        let resendLegacyStopped = await waitUntil { team.runs[resendLegacyKey] == nil }
        XCTAssertTrue(resendLegacyStopped)

        team.entries[resendMorningKey] = [
            Entry(id: "u-morn", at: 1_000, message: .user("早。请给我一封今天的晨信：看看今天和明天的日程。")),
            Entry(id: "a-morn", at: 2_000, message: .assistant("晨信回复"), speaker: "b-test"),
        ]
        XCTAssertTrue(team.resend(resendMorningKey, entry: "u-morn", text: "重发晨信"))
        XCTAssertEqual(team.activeTurnExperienceSource[resendMorningKey], .routine)
        team.stop(resendMorningKey)
        let resendMorningStopped = await waitUntil { team.runs[resendMorningKey] == nil }
        XCTAssertTrue(resendMorningStopped)

        team.entries[resendUnknownKey] = [
            Entry(id: "u-unk", at: 1_000, message: .user("普通文案"), experienceSource: "future_restricted_tier"),
            Entry(id: "a-unk", at: 2_000, message: .assistant("旧回复"), speaker: "b-test"),
        ]
        XCTAssertTrue(team.resend(resendUnknownKey, entry: "u-unk", text: "重发普通文案"))
        XCTAssertEqual(team.activeTurnExperienceSource[resendUnknownKey], .routine)
        team.stop(resendUnknownKey)
        let resendUnknownStopped = await waitUntil { team.runs[resendUnknownKey] == nil }
        XCTAssertTrue(resendUnknownStopped)

        // New `.mainChat` turn replacing a paused `.routine` turn: `resumePaused()` & stale note must NOT resurrect `.routine`.
        team.append(Entry(id: "u-sup-1", at: 1_000, message: .user("【定时 · 早报】暂停旧轮"), experienceSource: ExperienceWriteSource.routine.rawValue), to: supKey)
        team.start(supKey, userInitiated: false, experienceSource: .routine)
        team.pause(supKey)
        team.append(Entry(id: "u-sup-2", at: 2_000, message: .user("新的主聊天问题"), experienceSource: ExperienceWriteSource.mainChat.rawValue), to: supKey)
        team.start(supKey, userInitiated: true, experienceSource: .mainChat)
        team.resumePaused()
        XCTAssertEqual(team.activeTurnExperienceSource[supKey], .mainChat)
        team.stop(supKey)
        let supStopped = await waitUntil { team.runs[supKey] == nil }
        XCTAssertTrue(supStopped)
        team.resumePaused()
        XCTAssertNil(team.runs[supKey])
        XCTAssertFalse(team.history(supKey).contains(where: { $0.next == Explain.Next.resume.rawValue }))

        // Interjected user line delivered while `.routine` is active inherits `.routine`, so `retry` stays `.routine`.
        team.start(intKey, userInitiated: false, experienceSource: .routine)
        XCTAssertTrue(team.interject("插话确认进度", to: intKey))
        XCTAssertEqual(team.takeInbox(intKey), ["插话确认进度"])
        await team.hear(.message(.user("插话确认进度")), chat: intKey, speaker: nil)
        XCTAssertEqual(team.history(intKey).last?.experienceSource, ExperienceWriteSource.routine.rawValue)
        team.stop(intKey)
        let intStopped = await waitUntil { team.runs[intKey] == nil }
        XCTAssertTrue(intStopped)
        team.retry(intKey)
        XCTAssertEqual(team.activeTurnExperienceSource[intKey], .routine)
        team.stop(intKey)
        let intRetryStopped = await waitUntil { team.runs[intKey] == nil }
        XCTAssertTrue(intRetryStopped)
        team.phase = .demo

        let flushBotID = "b-flush-\(UUID().uuidString.lowercased())"
        let flushKey = TeamModel.key(bot: flushBotID)
        let backupBotID = "b-backup-\(UUID().uuidString.lowercased())"
        let backupKey = TeamModel.key(bot: backupBotID)
        let recallDBURL = MemoryRecallIndex.defaultDatabaseURL
        let recallExistedBefore = FileManager.default.fileExists(atPath: recallDBURL.path)
        let recallMTimeBefore = (try? FileManager.default.attributesOfItem(atPath: recallDBURL.path)[.modificationDate] as? Date)
        let prevBots = team.bots
        let prevSettings = team.settings
        let prevOverride = team.turnProviderOverrideForTesting
        team.bots.append(BotInfo(id: flushBotID, name: "队列测试", role: nil, instructions: nil, model: nil))
        team.bots.append(BotInfo(id: backupBotID, name: "备用切换测试", role: nil, instructions: nil, model: nil))
        let testEndpoint = Endpoint(
            id: "ep-pr1a",
            name: "MockEP",
            kind: .openai,
            baseURL: "https://example.invalid/v1",
            models: ["gpt-mock", "gpt-4o-primary", "gpt-4o-backup"]
        )
        XCTAssertTrue(testEndpoint.traits("gpt-4o-backup").tools)
        team.settings.endpoints = [testEndpoint]
        team.settings.defaultModel = "ep-pr1a/gpt-mock"
        let providerTurns = LockedBox<[(source: String, userText: String)]>([])
        let backupCalls = LockedBox<[(model: String, source: String)]>([])
        let backupToolResult = LockedBox<String?>(nil)
        team.turnProviderOverrideForTesting = { _, model, source in
            if model == "gpt-4o-primary" {
                return CapturingMockModelProvider(customStream: { _ in
                    AsyncThrowingStream { continuation in
                        continuation.finish(throwing: ProviderError(status: 404, "primary unavailable"))
                    }
                })
            }
            if model == "gpt-4o-backup" {
                return CapturingMockModelProvider(customStream: { req in
                    backupCalls.mutate { $0.append((model: model, source: source.rawValue)) }
                    return AsyncThrowingStream { continuation in
                        if let toolReply = req.messages.last(where: { $0.role == .tool }) {
                            backupToolResult.set(toolReply.text)
                            continuation.yield(.text("备用完成"))
                            continuation.yield(.finish(reason: "stop"))
                            continuation.finish()
                        } else {
                            continuation.yield(.toolCallStart(index: 0, id: "call-backup-exp", name: "record_experience"))
                            continuation.yield(.toolCallArguments(
                                index: 0,
                                delta: #"{"title":"备用写库","content":"受限轮次切备用模型也不可写经验"}"#
                            ))
                            continuation.yield(.finish(reason: "tool_calls"))
                            continuation.finish()
                        }
                    }
                })
            }
            return CapturingMockModelProvider(replyText: "收到", onRequest: { req in
                let lastUser = req.messages.last(where: { $0.role == .user })?.text ?? ""
                providerTurns.mutate { $0.append((source: source.rawValue, userText: lastUser)) }
            })
        }
        team.phase = .ready
        defer {
            team.stop(flushKey)
            team.stop(backupKey)
            team.phase = .demo
            team.turnProviderOverrideForTesting = prevOverride
            team.bots = prevBots
            team.settings = prevSettings
            ChatDisk.finishWrites()
            for key in [flushKey, backupKey] {
                Disk.remove(Disk.chatFile(key))
                Disk.remove(TeamModel.optionsFile(key))
                QueuedStore.clear(key)
            }
        }

        // P1 #1: when primary model fails during a `.routine` turn, backup model recursion inherits `.routine`
        // and `record_experience` rejects persistence instead of escalating to `.mainChat`.
        team.settings.defaultModel = "ep-pr1a/gpt-4o-primary"
        team.settings.backupModel = "ep-pr1a/gpt-4o-backup"
        team.append(Entry(id: "u-backup-routine", at: 3_000, message: .user("【定时 · 巡检】测试备用模型权限"), experienceSource: ExperienceWriteSource.routine.rawValue), to: backupKey)
        team.start(backupKey, userInitiated: false, experienceSource: .routine)
        guard await waitUntil(timeoutSeconds: 8, { team.runs[backupKey] == nil }) else {
            XCTFail("Timed out waiting for backup-model routine turn to finish")
            return
        }
        XCTAssertEqual(backupCalls.get().map(\.model), ["gpt-4o-backup", "gpt-4o-backup"])
        XCTAssertEqual(backupCalls.get().map(\.source), [
            ExperienceWriteSource.routine.rawValue,
            ExperienceWriteSource.routine.rawValue,
        ])
        XCTAssertEqual(backupToolResult.get()?.contains("不允许改写经验库"), true)
        team.settings.defaultModel = "ep-pr1a/gpt-mock"
        team.settings.backupModel = nil
        providerTurns.set([])

        _ = await team.recallReadOnly("冬天")
        XCTAssertEqual(FileManager.default.fileExists(atPath: recallDBURL.path), recallExistedBefore)
        if recallExistedBefore {
            let recallMTimeAfter = (try? FileManager.default.attributesOfItem(atPath: recallDBURL.path)[.modificationDate] as? Date)
            XCTAssertEqual(recallMTimeAfter, recallMTimeBefore)
        }
        XCTAssertEqual(
            TeamModel.Queued.fromStored(StoredQueuedMessage(text: "旧版本队列兼容", photos: [], userInitiated: true, experienceSourceRaw: nil)).experienceSource,
            .mainChat
        )
        let storedTriplet = [
            StoredQueuedMessage(
                text: "【定时 · 早报】自动例会",
                photos: [],
                userInitiated: true,
                experienceSourceRaw: ExperienceWriteSource.routine.rawValue
            ),
            StoredQueuedMessage(
                text: "未知未来来源队列",
                photos: [],
                userInitiated: true,
                experienceSourceRaw: "future_restricted_v99"
            ),
            StoredQueuedMessage(
                text: "用户消息：记得喝水",
                photos: [],
                userInitiated: true,
                experienceSourceRaw: ExperienceWriteSource.mainChat.rawValue
            ),
        ]
        try QueuedStore.saveRawForTesting(storedTriplet, for: flushKey)
        let restoredSlot = try XCTUnwrap(QueuedStore.loadAllSlots()[flushKey])
        XCTAssertEqual(restoredSlot.items.count, 3)
        let restoredQueued = restoredSlot.items.map(TeamModel.Queued.fromStored)
        XCTAssertEqual(restoredQueued.map(\.experienceSource), [.routine, .routine, .mainChat])
        team.queued[flushKey] = restoredQueued
        team.flushQueue(flushKey)
        // Adjacent `.routine` items (`userInitiated: true`) coalesce into one batch, leaving only `.mainChat` in the queue.
        XCTAssertEqual(team.queued[flushKey]?.count, 1)
        XCTAssertEqual(team.queued[flushKey]?.first?.experienceSource, .mainChat)
        XCTAssertEqual(team.activeTurnExperienceSource[flushKey], .routine)
        XCTAssertEqual(team.history(flushKey).last?.experienceSource, ExperienceWriteSource.routine.rawValue)

        let drained = await waitUntil(timeoutSeconds: 8) {
            ChatDisk.finishWrites()
            return team.runs[flushKey] == nil
                && team.inFlightQueued[flushKey] == nil
                && team.queued[flushKey] == nil
                && QueuedStore.loadAllSlots()[flushKey] == nil
        }
        XCTAssertTrue(drained)
        XCTAssertNil(team.runs[flushKey])
        XCTAssertNil(team.queued[flushKey])
        XCTAssertNil(team.inFlightQueued[flushKey])
        XCTAssertNil(QueuedStore.loadAllSlots()[flushKey])
        let recordedProviderTurns = providerTurns.get()
        XCTAssertEqual(recordedProviderTurns.count, 2)
        XCTAssertEqual(recordedProviderTurns.map(\.source), [
            ExperienceWriteSource.routine.rawValue,
            ExperienceWriteSource.mainChat.rawValue,
        ])
        XCTAssertEqual(recordedProviderTurns.map(\.userText), [
            "【定时 · 早报】自动例会\n\n未知未来来源队列",
            "用户消息：记得喝水",
        ])
        let flushedUserEntries = team.history(flushKey).filter { $0.note != true && $0.message.role == .user }
        XCTAssertEqual(flushedUserEntries.map(\.experienceSource), [
            ExperienceWriteSource.routine.rawValue,
            ExperienceWriteSource.mainChat.rawValue,
        ])
    }

    func testLivePromptProviderRedactsSystemAndCachePrefixOnUpstreamRequest() async throws {
        let secretsBox = LockedBox<[String]>([])
        let capturedInputs = LockedBox<[ModelInput]>([])
        let secret = "sk-liveprovider-secret-4433"
        let splitLeft = "sk-livecross"
        let splitRight = "tail-7788"
        let crossBoundarySecret = "\(splitLeft)\n\n\(splitRight)"

        let refresher = MemoryRecallPromptRefresher(
            input: MemorySafety.SystemPromptInput(
                identity: "你是「小克」。",
                instructions: "系统指令含 \(secret)",
                skillsBlock: "可用技能含 \(secret)",
                memories: [MemorySafety.Fact(id: "m1", text: "记住：\(secret)", at: 100)],
                memoryEnabled: true,
                staticRules: "做事：\n- 静态边界前缀 \(splitLeft)",
                timestampLine: "\(splitRight) 时间线",
                diaryLine: "日记：\(secret)",
                summaryBlock: "摘要：\(secret)",
                extraTail: "附注：\(secret)"
            ),
            state: MemorySafety.PromptState(),
            isRecallAllowed: { true },
            isMemoryEnabled: { true },
            activeSecrets: { secretsBox.get() }
        )

        let upstream = CapturingMockModelProvider()
        let liveProvider = LivePromptProvider(upstream: upstream, refresher: refresher) { input in
            capturedInputs.mutate { $0.append(input) }
        }
        let baseRequest = ModelRequest(model: "gpt-test", system: "", messages: [.user("hi")])

        for try await _ in liveProvider.stream(baseRequest) {}
        let beforeReq = try XCTUnwrap(upstream.requestsSnapshot().last)
        let beforeInput = try XCTUnwrap(capturedInputs.get().last)
        XCTAssertTrue(beforeReq.system.contains(secret))
        XCTAssertEqual(beforeReq.systemCachePrefix?.contains(secret), true)
        XCTAssertTrue(beforeInput.skills.contains(secret))
        XCTAssertTrue(beforeInput.memory.contains(secret))

        secretsBox.set([secret, crossBoundarySecret])

        for try await _ in liveProvider.stream(baseRequest) {}
        let afterReq = try XCTUnwrap(upstream.requestsSnapshot().last)
        let afterCachePrefix = try XCTUnwrap(afterReq.systemCachePrefix)
        let afterInput = try XCTUnwrap(capturedInputs.get().last)
        XCTAssertFalse(afterReq.system.contains(secret))
        XCTAssertFalse(afterReq.system.contains(crossBoundarySecret))
        XCTAssertFalse(afterCachePrefix.contains(secret))
        XCTAssertTrue(afterCachePrefix.contains("〔隐去〕"))
        XCTAssertTrue(afterReq.system.contains("〔隐去〕"))
        XCTAssertTrue(afterReq.system.hasPrefix(afterCachePrefix))
        XCTAssertFalse(afterCachePrefix.hasSuffix(splitLeft))
        XCTAssertFalse(afterInput.skills.isEmpty)
        XCTAssertFalse(afterInput.skills.contains(secret))
        XCTAssertTrue(afterInput.skills.contains("〔隐去〕"))
        XCTAssertFalse(afterInput.memory.isEmpty)
        XCTAssertFalse(afterInput.memory.contains(secret))
        XCTAssertTrue(afterInput.memory.contains("〔隐去〕"))
        XCTAssertFalse(afterInput.system.contains(secret))
        XCTAssertFalse(afterInput.system.contains(crossBoundarySecret))
    }

    @MainActor
    private func waitUntil(timeoutSeconds: Double = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !condition() {
            if Date() >= deadline { return false }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return true
    }
}

private final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }

    func mutate(_ transform: (inout Value) -> Void) {
        lock.lock()
        transform(&value)
        lock.unlock()
    }
}

private final class CapturingMockModelProvider: ModelProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [ModelRequest] = []
    private let replyText: String?
    private let onRequest: (@Sendable (ModelRequest) -> Void)?
    private let customStream: (@Sendable (ModelRequest) -> AsyncThrowingStream<StreamEvent, Error>)?

    init(
        replyText: String? = nil,
        onRequest: (@Sendable (ModelRequest) -> Void)? = nil,
        customStream: (@Sendable (ModelRequest) -> AsyncThrowingStream<StreamEvent, Error>)? = nil
    ) {
        self.replyText = replyText
        self.onRequest = onRequest
        self.customStream = customStream
    }

    func requestsSnapshot() -> [ModelRequest] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        lock.lock()
        captured.append(request)
        lock.unlock()
        onRequest?(request)
        if let customStream {
            return customStream(request)
        }
        let text = replyText
        return AsyncThrowingStream { continuation in
            if let text {
                continuation.yield(.text(text))
            }
            continuation.yield(.finish(reason: "stop"))
            continuation.finish()
        }
    }

    func models() async throws -> [String] { [] }
}
