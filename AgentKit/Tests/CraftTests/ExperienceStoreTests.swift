@testable import Craft
import Foundation
import XCTest

final class ExperienceStoreTests: XCTestCase {
    func testWriteSourceGateRejectsSubtaskCasualAndRoutine() throws {
        let store = ExperienceStore.inMemory()

        for blocked in [ExperienceWriteSource.subtask, .casualTrack, .routine] {
            XCTAssertThrowsError(
                try store.record(title: "测试", content: "不应该写入的内容", source: blocked)
            ) { error in
                XCTAssertEqual(error as? ExperienceStoreError, .writeNotAllowed(blocked))
            }
        }

        let allowed = try store.record(
            title: "Xcodebuild 静默测试参数",
            content: "跑 Simulator 单元测试时加 -only-testing:ClioAppTests 且关闭代码签名 CODE_SIGNING_ALLOWED=NO。",
            tags: ["xcodebuild", "ci"],
            source: .mainChat,
            nowMs: 1_000
        )
        XCTAssertEqual(allowed.source, .mainChat)
        let loaded = try store.loadAll()
        XCTAssertEqual(loaded.count, 1)
    }

    func testCoexistsInSharedClioMemoryDatabaseWithMemoryStoreInEitherOrder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("exp-shared-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let canonicalURL = dir.appendingPathComponent("Team/experiences.json")
        let sharedDBURL = dir.appendingPathComponent("ClioMemory/clio-memory.db")

        // Open ExperienceStore BEFORE MemoryStore ever touches `clio-memory.db`.
        let expStore = ExperienceStore(canonicalFileURL: canonicalURL, databaseURL: sharedDBURL)
        let savedExp = try expStore.record(
            title: "ffmpeg 无损压视频",
            content: "使用 ffmpeg -c:v libx264 -crf 23 压缩大体积屏幕录像。",
            tags: ["ffmpeg", "视频"],
            source: .user,
            nowMs: 2_000
        )

        // Now open MemoryStore on the SAME `clio-memory.db` and assert zero schema-mismatch recreation!
        let memStore = MemoryStore(databaseURL: sharedDBURL)
        let recoveryReason = try memStore.openOrRecover()
        XCTAssertEqual(recoveryReason, .none)

        _ = try memStore.upsert(MemoryRecord(id: "m1", text: "用户剪辑视频常用 Final Cut", createdAtMs: 2_100))
        let expHits = try expStore.search(query: "ffmpeg 压缩录像")
        XCTAssertEqual(expHits.map(\.id), [savedExp.id])
        XCTAssertEqual(try memStore.list(layer: nil).map(\.id), ["m1"])
    }

    func testHybridSearchSecretRedactionTombstonesAndFallbackLikeSearch() throws {
        for disableFTS5 in [false, true] {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("exp-search-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }

            let canonicalURL = dir.appendingPathComponent("Team/experiences.json")
            let dbURL = dir.appendingPathComponent("ClioMemory/clio-memory.db")
            let store = ExperienceStore(
                canonicalFileURL: canonicalURL,
                databaseURL: dbURL,
                forceDisableFTS5ForTesting: disableFTS5
            )

            let secret = "sk-exp-supersecret-9988"
            let e1 = try store.record(
                title: "处理大型 CSV 数据表格",
                content: "不要把整份 CSV 读进上下文，优先写 python 脚本用密码 \(secret) 的代理走批处理统计。",
                tags: ["python", "csv"],
                source: .mainChat,
                nowMs: 1_000,
                secrets: [secret]
            )
            XCTAssertFalse(e1.content.contains(secret))

            let hits = try store.search(query: "CSV 批处理", markUsedNowMs: 2_000)
            XCTAssertEqual(hits.map(\.id), [e1.id])
            XCTAssertEqual(hits.first?.useCount, 1)

            // Tombstone delete keeps deleted experience suppressed across subsequent search & rebuild.
            try store.delete(id: e1.id, nowMs: 3_000)
            XCTAssertTrue(try store.search(query: "CSV").isEmpty)
            try store.rebuildFromCanonical()
            XCTAssertTrue(try store.search(query: "CSV").isEmpty)
        }
    }
}
