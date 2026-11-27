@testable import Craft
import Foundation
import SQLite3
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

    func testZeroWriteReadOnlySearchSkipsCreatingDatabaseAndClampsSQLiteInt64() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("exp-ro-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Team"), withIntermediateDirectories: true)

        let canonURL = dir.appendingPathComponent("Team/experiences.json")
        let roDBURL = dir.appendingPathComponent("ClioMemory/readonly-never-created.db")
        let book = CanonicalExperienceBook(
            updatedAtMs: 1_000,
            records: [
                ExperienceRecord(
                    id: "exp-ro-1",
                    title: "零写经验检索",
                    content: "冷启动调用只读搜索时不得创建 SQLite 数据库或目录。",
                    tags: ["readonly", "sqlite"],
                    createdAtMs: 1_000,
                    updatedAtMs: 1_000,
                    useCount: 0,
                    source: .mainChat
                ),
            ]
        )
        let encoded = try JSONEncoder().encode(book)
        try encoded.write(to: canonURL)

        let readOnlyStore = ExperienceStore(canonicalFileURL: canonURL, databaseURL: roDBURL)
        let roHits = try readOnlyStore.search(query: "零写经验", markUsedNowMs: nil)
        XCTAssertEqual(roHits.map(\.id), ["exp-ro-1"])
        XCTAssertEqual(roHits.first?.useCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: roDBURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: roDBURL.deletingLastPathComponent().path))

        // Direct SQLite >Int32.max row must clamp safely when read via SQLite Int64 columns.
        let rwDBURL = dir.appendingPathComponent("ClioMemory/int64-clamp.db")
        let writerStore = ExperienceStore(canonicalFileURL: nil, databaseURL: rwDBURL)
        _ = try writerStore.record(
            id: "exp-int64",
            title: "数据库大整数校验",
            content: "确保 sqlite3_column_int64 限幅不溢出。",
            tags: ["int64"],
            source: .mainChat,
            nowMs: 1_000
        )
        writerStore.close()

        var rawDB: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(rwDBURL.path, &rawDB, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(rawDB, "UPDATE experiences SET use_count = 9999999999;", nil, nil, nil), SQLITE_OK)
        sqlite3_close(rawDB)

        // Fresh unopened reader must execute SQLITE_OPEN_READONLY search cleanly BEFORE any loadAll() opens a RW DB handle.
        let roColdReader = ExperienceStore(canonicalFileURL: nil, databaseURL: rwDBURL)
        let coldSearchHits = try roColdReader.search(query: "大整数校验", markUsedNowMs: nil)
        XCTAssertEqual(coldSearchHits.first?.useCount, Int(Int32.max))

        let readerStore = ExperienceStore(canonicalFileURL: nil, databaseURL: rwDBURL)
        let loaded = try readerStore.loadAll()
        XCTAssertEqual(loaded.first?.useCount, Int(Int32.max))
        let searchHits = try readerStore.search(query: "大整数校验", markUsedNowMs: nil)
        XCTAssertEqual(searchHits.first?.useCount, Int(Int32.max))

        // Failed SQLite `markUsedNowMs` transaction must clear `lastSyncedCanonicalKey` so next `record` forces full SQLite resync.
        let failSyncCanon = dir.appendingPathComponent("Team/fail-sync-experiences.json")
        let failSyncDB = dir.appendingPathComponent("ClioMemory/fail-sync.db")
        let syncStore = ExperienceStore(canonicalFileURL: failSyncCanon, databaseURL: failSyncDB)
        _ = try syncStore.record(
            id: "e-sync-1",
            title: "触发器失败同步",
            content: "验证 SQLite UPDATE 失败后下次 record 全量重同步 use_count。",
            tags: ["sync"],
            source: .mainChat,
            nowMs: 1_000
        )
        syncStore.close()

        var trigDB: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(failSyncDB.path, &trigDB, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(
                trigDB,
                "CREATE TRIGGER block_exp_update BEFORE UPDATE ON experiences BEGIN SELECT RAISE(ABORT, 'simulated failure'); END;",
                nil, nil, nil
            ),
            SQLITE_OK
        )
        sqlite3_close(trigDB)

        XCTAssertThrowsError(try syncStore.search(query: "触发器失败", markUsedNowMs: 2_000))

        var dropDB: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(failSyncDB.path, &dropDB, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(dropDB, "DROP TRIGGER block_exp_update;", nil, nil, nil), SQLITE_OK)
        sqlite3_close(dropDB)

        // Direct SQLite reader before resync still sees pre-failure useCount == 0 while canonical JSON has useCount == 1.
        let sqliteOnlyBefore = try ExperienceStore(canonicalFileURL: nil, databaseURL: failSyncDB).loadAll()
        XCTAssertEqual(sqliteOnlyBefore.first(where: { $0.id == "e-sync-1" })?.useCount, 0)

        _ = try syncStore.record(
            id: "e-sync-2",
            title: "触发全量重同步的记录",
            content: "写入第二条经验触发全量重同步。",
            tags: ["sync"],
            source: .mainChat,
            nowMs: 3_000
        )
        let sqliteOnlyAfter = try ExperienceStore(canonicalFileURL: nil, databaseURL: failSyncDB).loadAll()
        XCTAssertEqual(sqliteOnlyAfter.first(where: { $0.id == "e-sync-1" })?.useCount, 1)
        XCTAssertEqual(sqliteOnlyAfter.first(where: { $0.id == "e-sync-2" })?.id, "e-sync-2")

        // Hot-connection Vault secret change and external canonical update must NOT use stale `skipSyncIfAlreadyOpen`.
        let hotCanon = dir.appendingPathComponent("Team/hot-sync-experiences.json")
        let hotDB = dir.appendingPathComponent("ClioMemory/hot-sync.db")
        let hotStore = ExperienceStore(canonicalFileURL: hotCanon, databaseURL: hotDB)
        _ = try hotStore.record(
            id: "e-hot-sec",
            title: "热连接秘密经验",
            content: "旧密码 sk-hot-secret-1111 应该在密钥更新后重同步抹除。",
            tags: ["secret"],
            source: .mainChat,
            nowMs: 1_000,
            secrets: []
        )
        _ = try hotStore.record(
            id: "e-hot-next",
            title: "新秘密触发全量重同步",
            content: "第二条记录携带新增 Vault 密钥。",
            tags: ["sync"],
            source: .mainChat,
            nowMs: 2_000,
            secrets: ["sk-hot-secret-1111"]
        )
        let sqliteAfterSecret = try ExperienceStore(canonicalFileURL: nil, databaseURL: hotDB).loadAll()
        let scrubbedRow = try XCTUnwrap(sqliteAfterSecret.first(where: { $0.id == "e-hot-sec" }))
        XCTAssertFalse(scrubbedRow.content.contains("sk-hot-secret-1111"))
        XCTAssertTrue(scrubbedRow.content.contains("〔隐去〕"))

        var externalBook = try JSONDecoder().decode(CanonicalExperienceBook.self, from: Data(contentsOf: hotCanon))
        externalBook.records.append(ExperienceRecord(
            id: "e-hot-external",
            title: "外部写入的经验",
            content: "绕开当前热连接写入 canonical 后下次 record 必须补全到 SQLite。",
            tags: ["external"],
            createdAtMs: 2_500,
            updatedAtMs: 2_500,
            source: .mainChat
        ))
        try JSONEncoder().encode(externalBook).write(to: hotCanon)
        _ = try hotStore.record(
            id: "e-hot-third",
            title: "感知外部变更的记录",
            content: "第三次写入校验 preWriteDigest。",
            tags: ["sync"],
            source: .mainChat,
            nowMs: 3_000,
            secrets: ["sk-hot-secret-1111"]
        )
        let sqliteAfterExternal = try ExperienceStore(canonicalFileURL: nil, databaseURL: hotDB).loadAll()
        XCTAssertTrue(sqliteAfterExternal.contains(where: { $0.id == "e-hot-external" }))
        XCTAssertTrue(sqliteAfterExternal.contains(where: { $0.id == "e-hot-third" }))

        // Hot-connection `delete` must also detect Vault secret change and external canonical update.
        _ = try hotStore.record(
            id: "e-hot-del-keep",
            title: "删除链路密钥刷新",
            content: "旧秘密 sk-del-secret-2222 等删除动作触发全量重同步。",
            tags: ["sync"],
            source: .mainChat,
            nowMs: 3_500,
            secrets: ["sk-hot-secret-1111"]
        )
        _ = try hotStore.record(
            id: "e-hot-del-target",
            title: "待删除经验",
            content: "将被删掉。",
            tags: ["del"],
            source: .mainChat,
            nowMs: 3_600,
            secrets: ["sk-hot-secret-1111"]
        )
        try hotStore.delete(id: "e-hot-del-target", nowMs: 3_700, secrets: ["sk-hot-secret-1111", "sk-del-secret-2222"])
        let sqliteAfterDelSecret = try ExperienceStore(canonicalFileURL: nil, databaseURL: hotDB).loadAll()
        XCTAssertNil(sqliteAfterDelSecret.first(where: { $0.id == "e-hot-del-target" }))
        let scrubbedAfterDel = try XCTUnwrap(sqliteAfterDelSecret.first(where: { $0.id == "e-hot-del-keep" }))
        XCTAssertFalse(scrubbedAfterDel.content.contains("sk-del-secret-2222"))
        XCTAssertTrue(scrubbedAfterDel.content.contains("〔隐去〕"))

        var externalDelBook = try JSONDecoder().decode(CanonicalExperienceBook.self, from: Data(contentsOf: hotCanon))
        externalDelBook.records.append(ExperienceRecord(
            id: "e-ext-via-del",
            title: "删除链路感知外部写入",
            content: "通过 delete 触发从外部 canonical 补全进 SQLite。",
            tags: ["ext-del"],
            createdAtMs: 3_800,
            updatedAtMs: 3_800,
            source: .mainChat
        ))
        try JSONEncoder().encode(externalDelBook).write(to: hotCanon)
        try hotStore.delete(id: "e-hot-del-keep", nowMs: 3_900, secrets: ["sk-hot-secret-1111", "sk-del-secret-2222"])
        let sqliteAfterExtDel = try ExperienceStore(canonicalFileURL: nil, databaseURL: hotDB).loadAll()
        XCTAssertNil(sqliteAfterExtDel.first(where: { $0.id == "e-hot-del-keep" }))
        XCTAssertTrue(sqliteAfterExtDel.contains(where: { $0.id == "e-ext-via-del" }))
        hotStore.close()

        // Raw stored `contentSHA256` retraction regression: when a Vault secret changes how text redacts
        // (so recomputed redacted hash != original raw stored hash), `loadAll(suppressedHashes:secrets:)` must still
        // filter the retracted entry by its raw stored `contentSHA256` on BOTH canonical-backed and SQLite-only stores.
        let rawHashCanon = dir.appendingPathComponent("Team/raw-hash-experiences.json")
        let rawHashDB = dir.appendingPathComponent("ClioMemory/raw-hash.db")
        let rawSecret = "sk-raw-retract-7788"
        let rawBody = "含旧密钥的流程：\(rawSecret) 步骤"
        let rawStoredHash = MemorySafety.retractionHash("含旧密钥\n\(rawBody)")
        let rawRetractedCanon = CanonicalExperienceBook(records: [
            ExperienceRecord(
                id: "e-raw-secret",
                title: "含旧密钥",
                content: rawBody,
                tags: ["raw"],
                contentSHA256: rawStoredHash,
                createdAtMs: 1_000,
                updatedAtMs: 1_000,
                source: .mainChat
            ),
            ExperienceRecord(
                id: "e-raw-keep",
                title: "合法流程",
                content: "不含撤回哈希的保留步骤。",
                tags: ["keep"],
                createdAtMs: 1_100,
                updatedAtMs: 1_100,
                source: .mainChat
            ),
        ])
        try FileManager.default.createDirectory(at: rawHashCanon.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(rawRetractedCanon).write(to: rawHashCanon)
        let canonLoadFiltered = try ExperienceStore(canonicalFileURL: rawHashCanon, databaseURL: rawHashDB).loadAll(
            includeDeleted: false,
            suppressedHashes: [rawStoredHash],
            secrets: [rawSecret]
        )
        XCTAssertEqual(canonLoadFiltered.map(\.id), ["e-raw-keep"])

        // Sync raw stored hash into SQLite while rebuilding projection WITH `rawSecret` active (so redacted text goes to SQLite),
        // then query SQLite-only `loadAll` proving both rows exist (redacted) before raw-hash suppression filters `e-raw-secret`.
        let sqliteRawSeed = ExperienceStore(canonicalFileURL: rawHashCanon, databaseURL: rawHashDB)
        try sqliteRawSeed.rebuildFromCanonical(secrets: [rawSecret])
        sqliteRawSeed.close()
        let sqliteOnlyProbe = ExperienceStore(canonicalFileURL: nil, databaseURL: rawHashDB)
        let sqliteUnfiltered = try sqliteOnlyProbe.loadAll(
            includeDeleted: false,
            suppressedHashes: [],
            secrets: [rawSecret]
        )
        XCTAssertEqual(Set(sqliteUnfiltered.map(\.id)), Set(["e-raw-keep", "e-raw-secret"]))
        let scrubbedSQLiteRow = try XCTUnwrap(sqliteUnfiltered.first(where: { $0.id == "e-raw-secret" }))
        XCTAssertFalse(scrubbedSQLiteRow.content.contains(rawSecret))
        XCTAssertTrue(scrubbedSQLiteRow.content.contains("〔隐去〕"))

        let sqliteOnlyFiltered = try sqliteOnlyProbe.loadAll(
            includeDeleted: false,
            suppressedHashes: [rawStoredHash],
            secrets: [rawSecret]
        )
        XCTAssertEqual(sqliteOnlyFiltered.map(\.id), ["e-raw-keep"])
        sqliteOnlyProbe.close()

        // Zero-sidecar cold SQLITE_OPEN_READONLY search vs active WAL uncheckpointed frame visibility.
        let walDBURL = dir.appendingPathComponent("ClioMemory/ro-sidecar.db")
        let walWriter = ExperienceStore(canonicalFileURL: nil, databaseURL: walDBURL)
        _ = try walWriter.record(
            id: "e-wal-1",
            title: "已检查点经验",
            content: "关闭清理 sidecar 后只读查询不应新建 -wal 或 -shm。",
            tags: ["wal"],
            source: .mainChat,
            nowMs: 1_000
        )
        walWriter.close()
        let walMem = MemoryStore(databaseURL: walDBURL)
        try walMem.checkpoint()
        walMem.close()
        try? FileManager.default.removeItem(atPath: walDBURL.path + "-wal")
        try? FileManager.default.removeItem(atPath: walDBURL.path + "-shm")

        let noSidecarHits = try ExperienceStore(canonicalFileURL: nil, databaseURL: walDBURL)
            .search(query: "已检查点", markUsedNowMs: nil)
        XCTAssertEqual(noSidecarHits.map(\.id), ["e-wal-1"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: walDBURL.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: walDBURL.path + "-shm"))

        // Uncheckpointed WAL visibility: disable autocheckpoint, insert raw frame into WAL, verify WAL file > 0 bytes, then RO search.
        var walRawDB: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(walDBURL.path, &walRawDB, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(walRawDB, "PRAGMA wal_autocheckpoint = 0;", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(walRawDB, "PRAGMA journal_mode = WAL;", nil, nil, nil), SQLITE_OK)
        let rawInsertSQL = """
        INSERT INTO experiences (
            id, title, content, tags_json, tags_text, content_sha256, source, use_count,
            created_at_ms, updated_at_ms, used_at_ms, deleted_at_ms, normalized_text, body_tokens, cjk_unigrams
        ) VALUES (
            'e-wal-raw', '未检查点热帧', '仍处于 WAL 日志里的 walrawframe 经验。', '["wal"]', 'wal',
            'abc123', 'main_chat', 0, 2000, 2000, NULL, NULL,
            '未检查点热帧 walrawframe', '未检查点热帧 walrawframe', '未 检 查 点 热 帧'
        );
        """
        XCTAssertEqual(sqlite3_exec(walRawDB, rawInsertSQL, nil, nil, nil), SQLITE_OK)
        let walPath = walDBURL.path + "-wal"
        XCTAssertTrue(FileManager.default.fileExists(atPath: walPath))
        let walAttrs = try FileManager.default.attributesOfItem(atPath: walPath)
        XCTAssertGreaterThan((walAttrs[.size] as? NSNumber)?.intValue ?? 0, 0)

        let uncheckpointedHits = try ExperienceStore(canonicalFileURL: nil, databaseURL: walDBURL)
            .search(query: "walrawframe", markUsedNowMs: nil)
        XCTAssertEqual(uncheckpointedHits.map(\.id), ["e-wal-raw"])
        if let walRawDB { sqlite3_close(walRawDB) }

        // Cross-connection auto-replacement & concurrent last-reference `deinit`: `MemoryStore.openOrRecover()` replaces corrupt DB
        // while surviving `ExperienceStore` handle refreshes cleanly and dropping handles interleaves safely under pathLock.
        let sharedCanon = dir.appendingPathComponent("Team/shared-replace-experiences.json")
        let sharedDB = dir.appendingPathComponent("ClioMemory/shared-replace.db")
        final class StrongDropBox: @unchecked Sendable {
            var store: ExperienceStore?
            init(_ store: ExperienceStore) { self.store = store }
        }
        final class WeakStoreRef: @unchecked Sendable {
            weak var store: ExperienceStore?
            init(_ store: ExperienceStore) { self.store = store }
        }
        final class LockedValueBox<Value>: @unchecked Sendable {
            private let lock = NSLock()
            private var value: Value
            init(_ value: Value) { self.value = value }
            func get() -> Value { lock.withLock { value } }
            func set(_ newValue: Value) { lock.withLock { value = newValue } }
        }
        final class TimeoutRetainBox: @unchecked Sendable {
            private let lock = NSLock()
            private var refs: [Unmanaged<StrongDropBox>] = []

            func retainAll(_ boxes: [StrongDropBox]) {
                lock.withLock {
                    refs.append(contentsOf: boxes.map { Unmanaged.passRetained($0) })
                }
            }

            func releaseAll() {
                let drained: [Unmanaged<StrongDropBox>] = lock.withLock {
                    let current = refs
                    refs.removeAll()
                    return current
                }
                for ref in drained {
                    ref.release()
                }
            }
        }
        func waitOrRetainBoxesOnTimeout(
            group: DispatchGroup,
            timeoutSeconds: Double,
            boxes: [StrongDropBox],
            retainStore: TimeoutRetainBox? = nil
        ) -> Bool {
            guard group.wait(timeout: .now() + timeoutSeconds) == .success else {
                if let retainStore {
                    retainStore.retainAll(boxes)
                } else {
                    for box in boxes {
                        _ = Unmanaged.passRetained(box)
                    }
                }
                return false
            }
            return true
        }
        func makeSurvivor() throws -> StrongDropBox {
            let store = ExperienceStore(canonicalFileURL: sharedCanon, databaseURL: sharedDB)
            _ = try store.record(
                id: "e-shared-1",
                title: "跨连接自动换库",
                content: "坏库被替换后仍能通过 canonical 重建恢复。",
                tags: ["replace"],
                source: .mainChat,
                nowMs: 1_000
            )
            return StrongDropBox(store)
        }
        func makeEphemeral(round: Int) throws -> (StrongDropBox, WeakStoreRef) {
            let store = ExperienceStore(canonicalFileURL: sharedCanon, databaseURL: sharedDB)
            let hits = try store.search(query: "跨连接", markUsedNowMs: 3_000 + Double(round))
            XCTAssertTrue(hits.contains(where: { $0.id == "e-shared-1" }))
            return (StrongDropBox(store), WeakStoreRef(store))
        }

        let survivorBox = try makeSurvivor()
        do {
            let handle = try FileHandle(forUpdating: sharedDB)
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: Data("corrupt-header!!".utf8))
            try handle.close()

            let sharedMem = MemoryStore(databaseURL: sharedDB)
            let recoveryReason = try sharedMem.openOrRecover()
            XCTAssertEqual(recoveryReason, .corrupt)
            sharedMem.close()
        }
        _ = try XCTUnwrap(survivorBox.store).record(
            id: "e-shared-2",
            title: "换库后继续写入",
            content: "旧记录也应完整同步进新库。",
            tags: ["replace"],
            source: .mainChat,
            nowMs: 2_000
        )
        do {
            let probe = ExperienceStore(canonicalFileURL: nil, databaseURL: sharedDB)
            let rebuiltShared = try probe.loadAll()
            probe.close()
            XCTAssertEqual(Set(rebuiltShared.map(\.id)), Set(["e-shared-1", "e-shared-2"]))
        }

        for round in 0..<6 {
            let (dropBox, weakRef) = try makeEphemeral(round: round)
            XCTAssertNotNil(weakRef.store)
            let corruptHandle = try FileHandle(forUpdating: sharedDB)
            try corruptHandle.seek(toOffset: 0)
            try corruptHandle.write(contentsOf: Data("corrupt-header!!".utf8))
            try corruptHandle.close()

            let dropQueue = DispatchQueue(label: "exp.deinit.drop.\(round)")
            let recoverQueue = DispatchQueue(label: "exp.deinit.recover.\(round)")
            let readyDrop = DispatchSemaphore(value: 0)
            let readyRecover = DispatchSemaphore(value: 0)
            let startGate = DispatchSemaphore(value: 0)
            let group = DispatchGroup()
            let recoveryResult = LockedValueBox<MemoryStoreRecoveryReason?>(nil)
            let recoveryError = LockedValueBox<String?>(nil)

            dropQueue.async(group: group) {
                readyDrop.signal()
                _ = startGate.wait(timeout: .now() + 5)
                dropBox.store = nil
            }
            recoverQueue.async(group: group) {
                readyRecover.signal()
                _ = startGate.wait(timeout: .now() + 5)
                let fixer = MemoryStore(databaseURL: sharedDB)
                do {
                    recoveryResult.set(try fixer.openOrRecover())
                } catch {
                    recoveryError.set("\(error)")
                }
                fixer.close()
            }
            XCTAssertEqual(readyDrop.wait(timeout: .now() + 5), .success)
            XCTAssertEqual(readyRecover.wait(timeout: .now() + 5), .success)
            startGate.signal()
            startGate.signal()
            guard waitOrRetainBoxesOnTimeout(
                group: group,
                timeoutSeconds: 10,
                boxes: [survivorBox, dropBox]
            ) else {
                XCTFail("Timed out waiting for concurrent deinit/openOrRecover round \(round)")
                return
            }

            XCTAssertNil(weakRef.store)
            XCTAssertNil(recoveryError.get())
            XCTAssertEqual(recoveryResult.get(), .corrupt)

            let activeSurvivor = try XCTUnwrap(survivorBox.store)
            let survivorHits = try activeSurvivor.search(query: "跨连接", markUsedNowMs: 4_000 + Double(round))
            XCTAssertTrue(survivorHits.contains(where: { $0.id == "e-shared-1" }))
            let survivorAll = try activeSurvivor.loadAll()
            XCTAssertEqual(Set(survivorAll.map(\.id)), Set(["e-shared-1", "e-shared-2"]))
        }
        _ = try XCTUnwrap(survivorBox.store).record(
            id: "e-shared-after-deinit",
            title: "析构竞态后可写",
            content: "并发释放与换库后完整可用。",
            tags: ["replace"],
            source: .mainChat,
            nowMs: 9_000
        )
        survivorBox.store?.close()
        survivorBox.store = nil
        do {
            let postDeinitProbe = ExperienceStore(canonicalFileURL: nil, databaseURL: sharedDB)
            let postDeinitRows = try postDeinitProbe.loadAll()
            postDeinitProbe.close()
            XCTAssertEqual(Set(postDeinitRows.map(\.id)), Set(["e-shared-1", "e-shared-2", "e-shared-after-deinit"]))
        }

        #if DEBUG
        // Deterministic timeout-exit check sharing `waitOrRetainBoxesOnTimeout`:
        // wait for explicit `#if DEBUG` contention callback inside `ClioMemoryDatabaseCoordinator.withDatabaseLock`
        // (proving `deinit` attempted `dbLock.try()` and blocked on `dbLock.lock()`), then unwind helper without blocking.
        let lockTestDB = dir.appendingPathComponent("ClioMemory/lock-timeout.db")
        let lockTestKey = ClioMemoryDatabaseCoordinator.key(for: lockTestDB)
        let lockHolderQueue = DispatchQueue(label: "exp.timeout.holder")
        let lockAcquired = DispatchSemaphore(value: 0)
        let contentionObserved = DispatchSemaphore(value: 0)
        let allowUnlock = DispatchSemaphore(value: 0)
        let lockReleased = DispatchSemaphore(value: 0)
        let holderGroup = DispatchGroup()
        let timeoutRetainBox = TimeoutRetainBox()
        let dropGroup = DispatchGroup()
        func makeLockContenderBox() -> (StrongDropBox, WeakStoreRef) {
            let store = ExperienceStore(canonicalFileURL: nil, databaseURL: lockTestDB)
            return (StrongDropBox(store), WeakStoreRef(store))
        }

        ClioMemoryDatabaseCoordinator.setDatabaseLockContentionHookForTesting { path in
            if path == lockTestKey {
                contentionObserved.signal()
            }
        }
        defer {
            ClioMemoryDatabaseCoordinator.setDatabaseLockContentionHookForTesting(nil)
            allowUnlock.signal()
            _ = holderGroup.wait(timeout: .now() + 5)
            _ = dropGroup.wait(timeout: .now() + 5)
            timeoutRetainBox.releaseAll()
        }

        lockHolderQueue.async(group: holderGroup) {
            ClioMemoryDatabaseCoordinator.withDatabaseLock(for: lockTestDB) {
                lockAcquired.signal()
                _ = allowUnlock.wait(timeout: .now() + 30)
            }
            lockReleased.signal()
        }
        guard lockAcquired.wait(timeout: .now() + 5) == .success else {
            XCTFail("Timed out waiting for lock holder to acquire path lock")
            return
        }

        let (returnedFromWait, contentionHit, weakSurvivor, weakContender): (Bool, Bool, WeakStoreRef, WeakStoreRef) = {
            let (localSurvivorBox, weakS) = makeLockContenderBox()
            let (localContenderBox, weakC) = makeLockContenderBox()
            DispatchQueue(label: "exp.timeout.drop").async(group: dropGroup) {
                localContenderBox.store = nil
            }
            guard contentionObserved.wait(timeout: .now() + 5) == .success else {
                timeoutRetainBox.retainAll([localSurvivorBox, localContenderBox])
                return (true, false, weakS, weakC)
            }
            let ok = waitOrRetainBoxesOnTimeout(
                group: dropGroup,
                timeoutSeconds: 0.05,
                boxes: [localSurvivorBox, localContenderBox],
                retainStore: timeoutRetainBox
            )
            return (ok, true, weakS, weakC)
        }()
        guard contentionHit else {
            XCTFail("Timed out waiting for ExperienceStore.deinit path-lock contention")
            return
        }
        XCTAssertFalse(returnedFromWait)
        XCTAssertEqual(lockReleased.wait(timeout: .now()), .timedOut)
        XCTAssertEqual(dropGroup.wait(timeout: .now()), .timedOut)
        XCTAssertNotNil(weakSurvivor.store)

        allowUnlock.signal()
        guard holderGroup.wait(timeout: .now() + 5) == .success,
              lockReleased.wait(timeout: .now() + 5) == .success,
              dropGroup.wait(timeout: .now() + 5) == .success else {
            XCTFail("Timed out waiting for lock release and contender deinit after unlock")
            return
        }
        XCTAssertNil(weakContender.store)
        timeoutRetainBox.releaseAll()
        XCTAssertNil(weakSurvivor.store)
        #endif
    }
}
