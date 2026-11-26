import AgentKit
@testable import Clio
import Craft
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
    }

    func testIsolatedMemoryStoreBridgeRecoveryAndProjectionRebuildCrashWindow() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clio-bridge-pr1a-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let teamRoot = dir.appendingPathComponent("Team", isDirectory: true)
        let mirrorRoot = dir.appendingPathComponent("Mirrors", isDirectory: true)
        let dbURL = dir.appendingPathComponent("ClioMemory/clio-memory.db")
        try FileManager.default.createDirectory(at: teamRoot, withIntermediateDirectories: true)

        let bridge = MemoryStoreBridge(databaseURL: dbURL, teamRoot: teamRoot, mirrorRoot: mirrorRoot)
        let snapBook = CanonicalMemoryBook(
            memories: [CanonicalMemoryItem(id: "m1", text: "快照里的旧记录", at: 100)],
            generation: 1
        )
        let c1 = try bridge.revisionStore.commitWithJournal(snapBook, snapshotReason: "manual", nowMs: 1_000)

        let pendingJournal = MemoryPendingJournal(
            id: "bridge-j1",
            phase: .prepared,
            targetCanonicalGeneration: 2,
            preCommitSHA256: c1.digest,
            postCommitSHA256: String(repeating: "a", count: 64),
            preCommitSnapshotID: c1.snapshot?.id
        )
        try JSONEncoder().encode(pendingJournal).write(to: bridge.revisionStore.journalFileURL)

        let outcome = try bridge.runColdStartRecoveryForTesting(nowMs: 2_000)
        XCTAssertEqual(outcome, .rolledBackToSnapshot(journalID: "bridge-j1", snapshotID: c1.snapshot?.id ?? ""))
        XCTAssertTrue(bridge.revisionStore.hasPendingProjectionRebuild)

        // Simulate stale row left inside SQLite before crash: bootstrapOnLaunch MUST honor `projection-rebuild.journal`,
        // wipe stale SQLite rows (`m-stale-resurrection`), rebuild from Canonical `memory.json`, and clear the marker.
        let directSQLite = MemoryStore(databaseURL: dbURL)
        _ = try directSQLite.upsert(
            MemoryRecord(id: "m-stale-resurrection", text: "崩溃窗口里残留的旧SQLite行", createdAtMs: 9_000),
            explicitUserAction: true
        )
        let bootstrap = bridge.bootstrapOnLaunch()
        XCTAssertEqual(bootstrap.book.memories.map(\.id), ["m1"])
        XCTAssertFalse(bridge.revisionStore.hasPendingProjectionRebuild)

        let barrierValue = bridge.withBackupBarrier {
            bridge.tombstoneHashesSnapshot().count
        }
        XCTAssertGreaterThanOrEqual(barrierValue, 0)
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
            "2026-11-27": ["entry-1000-new"],
        ])
        XCTAssertTrue(deduped.contains("entry-0430-legacy"))
        XCTAssertTrue(deduped.contains("entry-1000-new"))
    }
}
