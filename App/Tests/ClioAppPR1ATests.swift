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
        Backup.applyTombstoneUnionToStagedTeam(stagedTeam: stagedTeam, localRetractedHashes: localTombstones, nowMs: 5_000)

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

    func testIsolatedMemoryStoreBridgeRecoveryAndBackupBarrier() throws {
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

        let barrierValue = bridge.withBackupBarrier {
            bridge.tombstoneHashesSnapshot().count
        }
        XCTAssertGreaterThanOrEqual(barrierValue, 0)
    }

    @MainActor
    func testTeamModelRecallReadOnlyDoesNotMutateLayerOrUsedTimestamp() async {
        let team = TeamModel()
        team.keeping = false
        let deepItem = Memory(id: "d-readonly", text: "去年冬天去北海道滑雪的计划", at: 500, by: nil, deep: true, used: nil)
        let surfaceItem = Memory(id: "s-readonly", text: "平时冬天喜欢喝热可可", at: 900, by: nil, deep: nil, used: nil)
        team.memories = [deepItem, surfaceItem]

        let hits = await team.recallReadOnly("冬天")
        XCTAssertTrue(hits.contains(deepItem.text))
        XCTAssertTrue(hits.contains(surfaceItem.text))
        XCTAssertEqual(team.memories.first(where: { $0.id == "d-readonly" })?.deep, true)
        XCTAssertNil(team.memories.first(where: { $0.id == "d-readonly" })?.used)
        XCTAssertNil(team.memories.first(where: { $0.id == "s-readonly" })?.used)
    }
}
