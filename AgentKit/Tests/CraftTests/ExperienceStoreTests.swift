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

    func testCoexistsInSharedClioMemoryDatabaseAndHandlesDestroyFilesEpochReopen() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("exp-shared-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let canonicalURL = dir.appendingPathComponent("Team/experiences.json")
        let sharedDBURL = dir.appendingPathComponent("ClioMemory/clio-memory.db")

        // 1. Open ExperienceStore BEFORE MemoryStore ever touches `clio-memory.db`.
        let expStore = ExperienceStore(canonicalFileURL: canonicalURL, databaseURL: sharedDBURL)
        let savedExp = try expStore.record(
            title: "ffmpeg 无损压视频",
            content: "使用 ffmpeg -c:v libx264 -crf 23 压缩大体积屏幕录像。",
            tags: ["ffmpeg", "视频"],
            source: .user,
            nowMs: 2_000
        )

        // 2. Open MemoryStore on the SAME `clio-memory.db` and assert zero schema-mismatch recreation.
        let memStore = MemoryStore(databaseURL: sharedDBURL)
        let recoveryReason = try memStore.openOrRecover()
        XCTAssertEqual(recoveryReason, .none)

        _ = try memStore.upsert(MemoryRecord(id: "m1", text: "用户剪辑视频常用 Final Cut", createdAtMs: 2_100))
        let expHits = try expStore.search(query: "ffmpeg 压缩录像")
        XCTAssertEqual(expHits.map(\.id), [savedExp.id])
        XCTAssertEqual(try memStore.list(layer: nil).map(\.id), ["m1"])

        // 3. Destroy DB while ExperienceStore already holds an open handle -> ExperienceStore detects epoch/inode
        // change, cleanly reopens, and rebuilds SQLite projection from Canonical `experiences.json`.
        memStore.destroyFiles()
        _ = try memStore.openOrRecover()
        _ = try memStore.upsert(MemoryRecord(id: "m2", text: "重建后的新记忆", createdAtMs: 3_000))
        let hitsAfterDestroy = try expStore.search(query: "ffmpeg")
        XCTAssertEqual(hitsAfterDestroy.map(\.id), [savedExp.id])
        XCTAssertEqual(try memStore.list(layer: nil).map(\.id), ["m2"])
    }

    func testHybridSearchSecretRedactionUsageSemanticsAndInt32Clamping() throws {
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

            // Read-only search (`markUsedNowMs: nil`) leaves persisted `useCount == 0`.
            let readOnlyHits = try store.search(query: "CSV 批处理", markUsedNowMs: nil)
            XCTAssertEqual(readOnlyHits.map(\.id), [e1.id])
            XCTAssertEqual(readOnlyHits.first?.useCount, 0)
            XCTAssertEqual(try store.loadAll().first?.useCount, 0)

            // Search with `markUsedNowMs` returns incremented `useCount == 1` AND persists it.
            let hits = try store.search(query: "CSV 批处理", markUsedNowMs: 2_000)
            XCTAssertEqual(hits.map(\.id), [e1.id])
            XCTAssertEqual(hits.first?.useCount, 1)
            XCTAssertEqual(try store.loadAll().first?.useCount, 1)

            // Tombstone delete keeps deleted experience suppressed across subsequent search & rebuild.
            try store.delete(id: e1.id, nowMs: 3_000)
            XCTAssertTrue(try store.search(query: "CSV").isEmpty)
            try store.rebuildFromCanonical()
            XCTAssertTrue(try store.search(query: "CSV").isEmpty)
        }

        // Restored/crafted `experiences.json` with out-of-range `useCount = 2147483648` must clamp safely without crashing.
        let overflowDir = FileManager.default.temporaryDirectory.appendingPathComponent("exp-overflow-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: overflowDir) }
        try FileManager.default.createDirectory(at: overflowDir.appendingPathComponent("Team"), withIntermediateDirectories: true)
        let overflowURL = overflowDir.appendingPathComponent("Team/experiences.json")
        let overflowJSON = """
        {
          "schemaVersion": 1,
          "updatedAtMs": 1000,
          "retractedHashes": [],
          "records": [
            {
              "id": "e-big",
              "title": "大计数恢复校验",
              "content": "恢复超大 useCount 时不崩溃。",
              "tags": ["safe"],
              "createdAtMs": 1000,
              "updatedAtMs": 1000,
              "useCount": 2147483648,
              "source": "user"
            }
          ]
        }
        """
        try Data(overflowJSON.utf8).write(to: overflowURL)
        let overflowStore = ExperienceStore(
            canonicalFileURL: overflowURL,
            databaseURL: overflowDir.appendingPathComponent("ClioMemory/clio-memory.db")
        )
        let saturatedHits = try overflowStore.search(query: "恢复校验", markUsedNowMs: 2_000)
        XCTAssertEqual(saturatedHits.map(\.id), ["e-big"])
        XCTAssertEqual(saturatedHits.first?.useCount, Int(Int32.max))
    }
}
