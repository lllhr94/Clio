@testable import Clio
import Craft
import XCTest

final class SkillInstallerValidationTests: XCTestCase {
    func testParseGitHubURLValidatesTreeAndAllowsDirectReleaseArchiveZip() throws {
        let tree = try XCTUnwrap(try SkillInstaller.parseGitHubURL("https://github.com/lllhr94/Clio/tree/main/skills/writer"))
        XCTAssertEqual(tree.owner, "lllhr94")
        XCTAssertEqual(tree.repo, "Clio")
        XCTAssertEqual(tree.ref, "main")
        XCTAssertEqual(tree.subpath, "skills/writer")

        XCTAssertNil(try SkillInstaller.parseGitHubURL("https://github.com/lllhr94/Clio/archive/refs/heads/main.zip"))
        XCTAssertNil(try SkillInstaller.parseGitHubURL("https://github.com/lllhr94/Clio/releases/download/v1.0/skill.zip"))
        XCTAssertNil(try SkillInstaller.parseGitHubURL("https://example.com/skill.zip"))
    }

    func testParseGitHubURLRejectsTraversalAndInjectionAttacksInsteadOfFallingThrough() {
        let attacks = [
            "https://github.com/owner/repo/tree/..%2F..%2Fvictim/skills",
            "https://github.com/owner/repo/tree/main/skills?ref=evil",
            "https://github.com/owner/repo/tree/main/skills#frag",
            "https://github.com/owner/repo/tree/main/.git/config",
            "https://github.com/owner/repo/archive/refs/heads/..%2Fevil.zip",
            "https://user@github.com/owner/repo",
        ]
        for url in attacks {
            XCTAssertThrowsError(try SkillInstaller.parseGitHubURL(url), "Expected \(url) to throw")
        }
    }

    func testMemoryStoreBridgeMergesLegacyExperiencesToDeepLayerAndPropagatesRetractions() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clio-exp-merge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let expBridge = ExperienceStoreBridge(teamRoot: dir)
        let dbURL = dir.appendingPathComponent("clio-memory.db")
        let mirrorRoot = dir.appendingPathComponent("Mirrors", isDirectory: true)
        let memBridge = MemoryStoreBridge(
            databaseURL: dbURL,
            teamRoot: dir,
            mirrorRoot: mirrorRoot,
            experienceBridge: expBridge
        )

        let secret = "vault-only-secret-token-xyz987"
        let validExp = ExperienceRecord(
            id: "exp-ok",
            title: "编译习惯",
            content: "推送前在本地跑 test-build",
            createdAtMs: 1_234,
            updatedAtMs: 1_500,
            usedAtMs: 1_450,
            source: .user
        )
        let deletedExp = ExperienceRecord(
            id: "exp-del",
            title: "过时步骤",
            content: "已经删掉的旧流程",
            createdAtMs: 500,
            deletedAtMs: 900,
            source: .user
        )
        let secretExp = ExperienceRecord(
            id: "exp-sec",
            title: "密钥",
            content: "使用 \(secret) 认证",
            source: .user
        )
        let book = CanonicalExperienceBook(records: [validExp, deletedExp, secretExp])
        try JSONEncoder().encode(book).write(to: expBridge.canonicalFileURL, options: .atomic)

        let report = try XCTUnwrap(memBridge.mergeLegacyExperiencesSync(secrets: [secret], nowMs: 5_000))
        XCTAssertEqual(report.addedCount, 1)
        XCTAssertEqual(report.skippedDeletedCount, 1)
        XCTAssertEqual(report.skippedSecretOrEmptyCount, 1)

        let stored = memBridge.recordsSnapshot(layer: .deep)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0].text, "编译习惯\n推送前在本地跑 test-build")
        XCTAssertEqual(stored[0].topic, "")
        XCTAssertEqual(stored[0].layer, .deep)
        XCTAssertEqual(stored[0].usedAtMs, 1_450)
        XCTAssertTrue(stored[0].editedByUser)
        XCTAssertTrue(memBridge.tombstoneHashesSnapshot().contains(MemorySafety.retractionHash("过时步骤\n已经删掉的旧流程")))

        // Second run is strictly idempotent.
        let second = try XCTUnwrap(memBridge.mergeLegacyExperiencesSync(secrets: [secret], nowMs: 6_000))
        XCTAssertEqual(second.addedCount, 0)
        XCTAssertEqual(second.mergedDuplicateCount, 1)
        XCTAssertEqual(memBridge.recordsSnapshot(layer: .deep).count, 1)
    }
}
