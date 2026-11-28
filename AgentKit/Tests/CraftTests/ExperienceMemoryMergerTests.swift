import Craft
import XCTest

final class ExperienceMemoryMergerTests: XCTestCase {
    func testMigratesValidExperiencesToDeepLayerWithEmptyTopicAndRetractionHash() {
        let exp = ExperienceRecord(
            id: "exp-1",
            title: "打包约定",
            content: "发布前先跑本地 test-build",
            createdAtMs: 1_000,
            updatedAtMs: 1_500,
            usedAtMs: 1_400,
            source: .mainChat
        )
        let book = CanonicalExperienceBook(records: [exp])

        let report = ExperienceMemoryMerger.merge(
            experiences: book,
            into: [],
            nowMs: 9_000
        )

        XCTAssertEqual(report.addedCount, 1)
        XCTAssertEqual(report.memories.count, 1)
        let migrated = report.memories[0]
        XCTAssertEqual(migrated.layer, .deep)
        XCTAssertEqual(migrated.topic, "")
        XCTAssertEqual(migrated.text, "打包约定\n发布前先跑本地 test-build")
        XCTAssertEqual(migrated.textSHA256, MemorySafety.retractionHash(migrated.text))
        XCTAssertEqual(migrated.createdAtMs, 1_000)
        XCTAssertEqual(migrated.updatedAtMs, 1_500)
        XCTAssertEqual(migrated.usedAtMs, 1_400)
        XCTAssertTrue(migrated.automatic)
        XCTAssertFalse(migrated.editedByUser)
    }

    func testSkipsDeletedAndDisallowedSourcesAndPropagatesSoftDeletedHashes() {
        let deleted = ExperienceRecord(
            id: "exp-del",
            title: "废弃流程",
            content: "旧版手动脚本",
            createdAtMs: 100,
            deletedAtMs: 200,
            source: .user
        )
        let resurrectedDuplicate = ExperienceRecord(
            id: "exp-dup",
            title: "废弃流程",
            content: "旧版手动脚本",
            createdAtMs: 300,
            source: .user
        )
        let subtaskExp = ExperienceRecord(id: "exp-sub", title: "子任务", content: "不能落盘", source: .subtask)
        let casualExp = ExperienceRecord(id: "exp-cas", title: "闲聊", content: "不能落盘", source: .casualTrack)
        let routineExp = ExperienceRecord(id: "exp-rou", title: "定时", content: "不能落盘", source: .routine)

        let report = ExperienceMemoryMerger.merge(
            experiences: CanonicalExperienceBook(records: [deleted, resurrectedDuplicate, subtaskExp, casualExp, routineExp]),
            into: [],
            nowMs: 5_000
        )

        XCTAssertTrue(report.memories.isEmpty)
        XCTAssertEqual(report.skippedDeletedCount, 1)
        XCTAssertEqual(report.skippedRetractedCount, 1)
        XCTAssertEqual(report.skippedDisallowedSourceCount, 3)
        XCTAssertTrue(report.retractedHashes.contains(MemorySafety.retractionHash("废弃流程\n旧版手动脚本")))
        XCTAssertTrue(report.retractedHashes.contains(MemorySafety.retractionHash("旧版手动脚本")))
    }

    func testRejectsVaultRedactedAndCommonRawSecretPrefixes() {
        let vaultSecret = "my-super-vault-token-987654321"
        let samples = [
            ExperienceRecord(id: "s1", title: "Vault", content: "使用 \(vaultSecret) 登录", source: .user),
            ExperienceRecord(id: "s2", title: "Anthropic", content: "key is sk-ant-api03-abcdef123456", source: .user),
            ExperienceRecord(id: "s3", title: "OpenAI", content: "key is sk-proj-abcdef123456", source: .user),
            ExperienceRecord(id: "s4", title: "GitHub1", content: "token ghp_1234567890abcdef", source: .user),
            ExperienceRecord(id: "s5", title: "GitHub2", content: "token github_pat_11ABCDEF", source: .user),
            ExperienceRecord(id: "s6", title: "PEM", content: "-----BEGIN PRIVATE KEY-----\nMIIE...", source: .user),
            ExperienceRecord(id: "s7", title: "AlreadyRedacted", content: "密钥是 〔隐去〕", source: .user),
        ]

        let report = ExperienceMemoryMerger.merge(
            experiences: CanonicalExperienceBook(records: samples),
            into: [],
            secrets: [vaultSecret],
            nowMs: 5_000
        )

        XCTAssertTrue(report.memories.isEmpty)
        XCTAssertEqual(report.skippedSecretOrEmptyCount, samples.count)
    }

    func testDeduplicatesWithRetractionHashPreservingRealCreatedAtUsedAtAndFlags() {
        let existing = MemoryRecord(
            id: "mem-1",
            text: "偏好简洁中文回复",
            layer: .surface,
            topic: "风格",
            createdAtMs: 2_000,
            updatedAtMs: 2_500,
            usedAtMs: 2_400,
            automatic: true,
            editedByUser: false
        )
        let incomingZeroCreated = ExperienceRecord(
            id: "exp-same",
            title: "",
            content: "偏好简洁中文回复",
            createdAtMs: 0,
            updatedAtMs: 3_000,
            usedAtMs: 2_900,
            source: .user
        )

        let report = ExperienceMemoryMerger.merge(
            experiences: CanonicalExperienceBook(records: [incomingZeroCreated]),
            into: [existing],
            nowMs: 9_000
        )

        XCTAssertEqual(report.addedCount, 0)
        XCTAssertEqual(report.mergedDuplicateCount, 1)
        XCTAssertEqual(report.memories.count, 1)
        let merged = report.memories[0]
        XCTAssertEqual(merged.createdAtMs, 2_000)
        XCTAssertEqual(merged.updatedAtMs, 3_000)
        XCTAssertEqual(merged.usedAtMs, 2_900)
        XCTAssertTrue(merged.automatic)
        XCTAssertTrue(merged.editedByUser)
        XCTAssertEqual(merged.layer, .surface)
        XCTAssertEqual(merged.topic, "风格")

        // Retracted hash blocks migration even when normalized whitespace differs.
        let blockedHash = MemorySafety.retractionHash("需要撤回的经验")
        let blockedExp = ExperienceRecord(id: "exp-ret", title: "", content: "  需要撤回的经验  ", source: .user)
        let blockedReport = ExperienceMemoryMerger.merge(
            experiences: CanonicalExperienceBook(records: [blockedExp]),
            into: [],
            existingRetractedHashes: [blockedHash],
            nowMs: 9_000
        )
        XCTAssertTrue(blockedReport.memories.isEmpty)
        XCTAssertEqual(blockedReport.skippedRetractedCount, 1)
    }
}
