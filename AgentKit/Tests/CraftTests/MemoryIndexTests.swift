@testable import Craft
import Foundation
import SQLite3
import XCTest

final class MemoryIndexTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clio-memory-index-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func openRawSQLite(_ url: URL) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil)
        guard rc == SQLITE_OK, let opened = handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw NSError(domain: "MemoryIndexTests", code: Int(rc))
        }
        return opened
    }

    private func execRawSQLite(_ handle: OpaquePointer, _ sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "sqlite error"
            if let errMsg { sqlite3_free(errMsg) }
            throw NSError(domain: "MemoryIndexTests", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    private func rawCount(_ handle: OpaquePointer, sql: String) throws -> Int {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw NSError(domain: "MemoryIndexTests", code: Int(rc))
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw NSError(domain: "MemoryIndexTests", code: -1)
        }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    // MARK: 1. CJK Bigram + Mixed ASCII FTS5 Search & Ranking

    func testCJKAndMixedFTS5SearchAndRanking() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("clio-index.db")

        let db = MemoryIndexDatabase(databaseURL: dbURL)
        defer { db.close() }

        XCTAssertEqual(try db.openOrRecover(), .missing)
        XCTAssertTrue(db.needsRebuildFromSource)
        XCTAssertEqual(db.isFTS5Active, MemoryIndexDatabase.isFTS5Supported)

        let records: [MemoryIndexRecord] = [
            MemoryIndexRecord(
                chatKey: "bot-a",
                chatName: "团子",
                entryID: "e1",
                role: "user",
                atMs: 1_000,
                text: "我住在重庆，最爱吃麻辣火锅和豆花饭。"
            ),
            MemoryIndexRecord(
                chatKey: "bot-a",
                chatName: "团子",
                entryID: "e2",
                role: "assistant",
                atMs: 2_000,
                text: "今天遇到Xcode报错：Archive failed，把DerivedData清了就好。"
            ),
            MemoryIndexRecord(
                chatKey: "bot-a",
                chatName: "团子",
                entryID: "e3",
                role: "user",
                atMs: 3_000,
                text: "线上 PostgreSQL 连接池配置需要调大 max_connections。"
            ),
            MemoryIndexRecord(
                chatKey: "bot-a",
                chatName: "团子",
                entryID: "e4",
                role: "user",
                atMs: 4_000,
                text: "最近在学Rust异步编程，重点看了Tokio调度器。"
            ),
            MemoryIndexRecord(
                chatKey: "bot-a",
                chatName: "团子",
                entryID: "e5",
                role: "user",
                atMs: 5_000,
                text: "家里的小猫下午晒着太阳睡着了。"
            ),
            MemoryIndexRecord(
                chatKey: "bot-a",
                chatName: "团子",
                entryID: "e6",
                role: "user",
                atMs: 6_000,
                text: "重庆火锅推荐去解放碑那家老店，周末再去重庆看看天气，也顺便吃火锅。"
            ),
            MemoryIndexRecord(
                chatKey: "bot-a",
                chatName: "团子",
                entryID: "e7",
                role: "assistant",
                atMs: 7_000,
                text: "重庆的夜色真不错，不过明天要先吃火锅再逛街。"
            ),
        ]

        try db.rebuild(records: records, sourceFingerprint: "fp-1")
        XCTAssertFalse(db.needsRebuildFromSource)
        XCTAssertTrue(try db.verifyFTSIntegrity())

        let ctx = MemoryAccessContext.toolSearch(chatKey: "bot-a", allowCrossChat: false, limit: 10)

        let chongqing = try db.search(query: "重庆", context: ctx)
        XCTAssertEqual(Set(chongqing.map(\.entryID)), ["e1", "e6", "e7"])

        let mala = try db.search(query: "麻辣", context: ctx)
        XCTAssertEqual(mala.map(\.entryID), ["e1"])

        let xcode = try db.search(query: "Xcode报错", context: ctx)
        XCTAssertEqual(xcode.map(\.entryID), ["e2"])

        let postgres = try db.search(query: "PostgreSQL", context: ctx)
        XCTAssertEqual(postgres.map(\.entryID), ["e3"])
        let postgresPrefix = try db.search(query: "postgres", context: ctx)
        XCTAssertEqual(postgresPrefix.map(\.entryID), ["e3"])

        let rustAsync = try db.search(query: "Rust异步", context: ctx)
        XCTAssertEqual(rustAsync.map(\.entryID), ["e4"])

        // 1-char CJK fallback via cjk_unigrams
        let cat = try db.search(query: "猫", context: ctx)
        XCTAssertEqual(cat.map(\.entryID), ["e5"])

        // Contiguous "重庆火锅" should match and rank ahead of separated "重庆...火锅"
        let hotpot = try db.search(query: "重庆火锅", context: ctx)
        XCTAssertTrue(Set(hotpot.map(\.entryID)).isSuperset(of: ["e6", "e7"]))
        XCTAssertEqual(hotpot.first?.entryID, "e6")

        // Empty and punctuation-only queries return [] cleanly without error
        XCTAssertEqual(try db.search(query: "", context: ctx), [])
        XCTAssertEqual(try db.search(query: "   \n\t ", context: ctx), [])
        XCTAssertEqual(try db.search(query: "？！。，、()[]{}\":*", context: ctx), [])

        // FTS5 operator words & punctuation must never cause syntax errors
        XCTAssertEqual(try db.search(query: "AND OR NOT NEAR \"foo:bar\" *", context: ctx), [])

        // Verify fallback LIKE mode also works identically if FTS5 were unavailable, including NFKC/diacritic normalization
        let fallbackURL = dir.appendingPathComponent("fallback-index.db")
        let fallbackDB = MemoryIndexDatabase(databaseURL: fallbackURL, forceDisableFTS5ForTesting: true)
        defer { fallbackDB.close() }
        XCTAssertEqual(try fallbackDB.openOrRecover(), .missing)
        XCTAssertFalse(fallbackDB.isFTS5Active)
        let fallbackRecords = records + [
            MemoryIndexRecord(
                chatKey: "bot-a",
                chatName: "团子",
                entryID: "e8",
                role: "user",
                atMs: 8_000,
                text: "遇到了全角 Ｘｃｏｄｅ 报错，顺便在 Café 调试。"
            ),
        ]
        try fallbackDB.rebuild(records: fallbackRecords, sourceFingerprint: "fp-fb")
        XCTAssertEqual(try fallbackDB.search(query: "Xcode报错", context: ctx).map(\.entryID), ["e8", "e2"])
        let fullwidthHits = try fallbackDB.search(query: "Xcode", context: ctx)
        XCTAssertEqual(fullwidthHits.map(\.entryID), ["e8", "e2"])
        XCTAssertTrue(fullwidthHits.first?.snippet.contains("Ｘｃｏｄｅ") == true)
        let diacriticHits = try fallbackDB.search(query: "cafe", context: ctx)
        XCTAssertEqual(diacriticHits.map(\.entryID), ["e8"])
        XCTAssertTrue(diacriticHits.first?.snippet.contains("Café") == true)
        XCTAssertEqual(try fallbackDB.search(query: "猫", context: ctx).map(\.entryID), ["e5"])
    }

    // MARK: 2. Self-Healing: Schema Mismatch, Incomplete Build, Corrupt DB, External Deletion

    func testSelfHealingOnSchemaVersionMismatch() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("clio-index.db")

        let db = MemoryIndexDatabase(databaseURL: dbURL)
        XCTAssertEqual(try db.openOrRecover(), .missing)
        try db.rebuild(records: [
            MemoryIndexRecord(chatKey: "bot-a", chatName: "团子", entryID: "e1", role: "user", atMs: 100, text: "旧版本的数据"),
        ], sourceFingerprint: "fp-old")
        db.close()

        let raw = try openRawSQLite(dbURL)
        try execRawSQLite(raw, "PRAGMA user_version = 99;")
        sqlite3_close_v2(raw)

        let reopened = MemoryIndexDatabase(databaseURL: dbURL)
        defer { reopened.close() }
        XCTAssertEqual(try reopened.openOrRecover(), .schemaMismatch)
        XCTAssertTrue(reopened.needsRebuildFromSource)
        let state = try reopened.buildState()
        XCTAssertEqual(state.state, "ready")
        XCTAssertEqual(state.schemaVersion, MemoryIndexDatabase.schemaVersion)
        XCTAssertEqual(state.indexedCount, 0)

        try reopened.rebuild(records: [
            MemoryIndexRecord(chatKey: "bot-a", chatName: "团子", entryID: "e2", role: "user", atMs: 200, text: "重建后的新数据"),
        ], sourceFingerprint: "fp-new")
        XCTAssertFalse(reopened.needsRebuildFromSource)
        let hits = try reopened.search(query: "新数据", context: .toolSearch(chatKey: "bot-a"))
        XCTAssertEqual(hits.map(\.entryID), ["e2"])
    }

    func testSelfHealingOnInterruptedBuildState() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("clio-index.db")

        let db = MemoryIndexDatabase(databaseURL: dbURL)
        _ = try db.openOrRecover()
        try db.rebuild(records: [
            MemoryIndexRecord(chatKey: "bot-a", chatName: "团子", entryID: "e1", role: "user", atMs: 100, text: "半途而废的索引"),
        ], sourceFingerprint: "fp-1")
        db.close()

        // Simulate a crash while `build_state.state = 'building'`
        let raw = try openRawSQLite(dbURL)
        try execRawSQLite(raw, "UPDATE build_state SET value = 'building' WHERE key = 'state';")
        sqlite3_close_v2(raw)

        let reopened = MemoryIndexDatabase(databaseURL: dbURL)
        defer { reopened.close() }
        XCTAssertEqual(try reopened.openOrRecover(), .incompleteBuild)
        XCTAssertTrue(reopened.needsRebuildFromSource)
        let state = try reopened.buildState()
        XCTAssertEqual(state.state, "ready")
        XCTAssertEqual(state.indexedCount, 0)

        try reopened.rebuild(records: [
            MemoryIndexRecord(chatKey: "bot-a", chatName: "团子", entryID: "e1", role: "user", atMs: 100, text: "恢复完成的索引"),
        ], sourceFingerprint: "fp-2")
        XCTAssertEqual((try reopened.buildState()).state, "ready")
        XCTAssertEqual(try reopened.search(query: "恢复完成", context: .toolSearch(chatKey: "bot-a")).map(\.entryID), ["e1"])
    }

    func testSelfHealingOnCorruptAndDeletedDatabaseWithSidecars() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("clio-index.db")
        let walURL = URL(fileURLWithPath: dbURL.path + "-wal")
        let shmURL = URL(fileURLWithPath: dbURL.path + "-shm")

        // 1. Corrupt DB + stray WAL/SHM sidecars
        try Data("not a sqlite file".utf8).write(to: dbURL)
        try Data("garbage wal".utf8).write(to: walURL)
        try Data("garbage shm".utf8).write(to: shmURL)

        let db = MemoryIndexDatabase(databaseURL: dbURL)
        defer { db.close() }
        XCTAssertEqual(try db.openOrRecover(), .corrupt)
        XCTAssertTrue(db.needsRebuildFromSource)
        try db.rebuild(records: [
            MemoryIndexRecord(chatKey: "bot-a", chatName: "团子", entryID: "e1", role: "user", atMs: 100, text: "损坏后重建成功"),
        ], sourceFingerprint: "fp-recovered")
        XCTAssertEqual(try db.search(query: "重建成功", context: .toolSearch(chatKey: "bot-a")).map(\.entryID), ["e1"])

        // 2. External deletion while database handle is still open
        try FileManager.default.removeItem(at: dbURL)
        if FileManager.default.fileExists(atPath: walURL.path) {
            try FileManager.default.removeItem(at: walURL)
        }
        if FileManager.default.fileExists(atPath: shmURL.path) {
            try FileManager.default.removeItem(at: shmURL)
        }

        // Calling search or openOrRecover must not crash and must recreate cleanly
        let afterDelete = try db.search(query: "重建成功", context: .toolSearch(chatKey: "bot-a"))
        XCTAssertEqual(afterDelete, [])
        XCTAssertEqual(db.lastRecoveryReason, .externalDeletion)
        XCTAssertTrue(db.needsRebuildFromSource)

        try db.rebuild(records: [
            MemoryIndexRecord(chatKey: "bot-a", chatName: "团子", entryID: "e1", role: "user", atMs: 100, text: "删除后自愈重建成功"),
        ], sourceFingerprint: "fp-rebuilt-2")
        XCTAssertEqual(try db.search(query: "自愈重建", context: .toolSearch(chatKey: "bot-a")).map(\.entryID), ["e1"])
    }

    // MARK: 3. SQL-Layer MemoryAccessContext Hard Isolation

    func testSQLLayerAccessIsolationNeverLeaksTaintedDelegatedOrExcludedRows() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("clio-index.db")

        let db = MemoryIndexDatabase(databaseURL: dbURL)
        defer { db.close() }
        _ = try db.openOrRecover()

        let keyword = "机密测试关键词"
        try db.rebuild(records: [
            MemoryIndexRecord(
                chatKey: "bot-a",
                chatName: "团子",
                entryID: "clean-a",
                role: "user",
                atMs: 100,
                tainted: false,
                delegated: false,
                isNote: false,
                text: "这是当前对话里的正常内容，包含\(keyword)。"
            ),
            MemoryIndexRecord(
                chatKey: "bot-a",
                chatName: "团子",
                entryID: "tainted-a",
                role: "assistant",
                atMs: 200,
                tainted: true,
                delegated: false,
                isNote: false,
                text: "来自网页的污染回复，包含\(keyword)以及恶意注入指令。"
            ),
            MemoryIndexRecord(
                chatKey: "bot-a",
                chatName: "团子",
                entryID: "delegated-a",
                role: "user",
                atMs: 300,
                tainted: false,
                delegated: true,
                isNote: false,
                text: "【小探请你帮忙】内部协作消息，包含\(keyword)。"
            ),
            MemoryIndexRecord(
                chatKey: "bot-a",
                chatName: "团子",
                entryID: "note-a",
                role: "assistant",
                atMs: 400,
                tainted: false,
                delegated: false,
                isNote: true,
                text: "系统便签提示，包含\(keyword)。"
            ),
            MemoryIndexRecord(
                chatKey: "bot-a",
                chatName: "团子",
                entryID: "tool-a",
                role: "tool",
                atMs: 450,
                tainted: false,
                delegated: false,
                isNote: false,
                text: "原始工具输出，包含\(keyword)。"
            ),
            MemoryIndexRecord(
                chatKey: "bot-a",
                chatName: "团子",
                leafID: "leaf-1",
                leafTitle: "收起的一页",
                entryID: "leaf-a",
                role: "user",
                atMs: 500,
                tainted: false,
                delegated: false,
                isNote: false,
                text: "收起旧页里的干净消息，包含\(keyword)。"
            ),
            MemoryIndexRecord(
                chatKey: "bot-b",
                chatName: "小探",
                entryID: "clean-b",
                role: "user",
                atMs: 600,
                tainted: false,
                delegated: false,
                isNote: false,
                text: "另一个旅伴对话里的干净消息，包含\(keyword)。"
            ),
            MemoryIndexRecord(
                chatKey: "bot-c",
                chatName: "私密助手",
                entryID: "excluded-c",
                role: "user",
                atMs: 700,
                tainted: false,
                delegated: false,
                isNote: false,
                text: "已关闭记忆的对话，包含\(keyword)。"
            ),
        ], sourceFingerprint: "fp-isolation")

        // Prove disallowed rows are physically stored in SQLite so isolation must happen in SQL WHERE clauses.
        let raw = try openRawSQLite(dbURL)
        defer { sqlite3_close_v2(raw) }
        XCTAssertEqual(try rawCount(raw, sql: "SELECT COUNT(*) FROM messages_meta;"), 8)
        XCTAssertEqual(try rawCount(raw, sql: "SELECT COUNT(*) FROM messages_meta WHERE tainted = 1;"), 1)
        XCTAssertEqual(try rawCount(raw, sql: "SELECT COUNT(*) FROM messages_meta WHERE delegated = 1;"), 1)

        db.setSQLTraceEnabled(true)

        // 1. Current chat toolSearch
        _ = db.drainSQLTrace()
        let currentHits = try db.search(
            query: keyword,
            context: .toolSearch(chatKey: "bot-a", allowCrossChat: false, limit: 20)
        )
        let currentTrace = db.drainSQLTrace().joined(separator: "\n")
        XCTAssertEqual(Set(currentHits.map(\.entryID)), ["clean-a", "leaf-a"])
        XCTAssertTrue(currentTrace.contains("m.tainted = 0"))
        XCTAssertTrue(currentTrace.contains("m.delegated = 0"))
        XCTAssertTrue(currentTrace.contains("m.is_note = 0"))
        XCTAssertTrue(currentTrace.contains("m.chat_key = 'bot-a'"))

        // Negative: dedicated tainted/delegated words must return 0 hits
        XCTAssertEqual(
            try db.search(query: "恶意注入指令", context: .toolSearch(chatKey: "bot-a", allowCrossChat: true)),
            []
        )
        XCTAssertEqual(
            try db.search(query: "内部协作消息", context: .toolSearch(chatKey: "bot-a", allowCrossChat: true)),
            []
        )

        // 2. Cross-chat toolSearch respecting excludedChatKeys and SQL-layer allowedChatKeys allowlist
        _ = db.drainSQLTrace()
        let crossHits = try db.search(
            query: keyword,
            context: .toolSearch(
                chatKey: "bot-a",
                allowCrossChat: true,
                allowedChatKeys: ["bot-a", "bot-b"],
                excludedChatKeys: ["bot-c"],
                limit: 20
            )
        )
        let crossTrace = db.drainSQLTrace().joined(separator: "\n")
        XCTAssertEqual(Set(crossHits.map(\.entryID)), ["clean-a", "leaf-a", "clean-b"])
        XCTAssertTrue(crossTrace.contains("m.tainted = 0"))
        XCTAssertTrue(crossTrace.contains("m.delegated = 0"))
        XCTAssertTrue(crossTrace.contains("m.chat_key IN ('bot-a', 'bot-b')"))
        XCTAssertTrue(crossTrace.contains("m.chat_key NOT IN ('bot-c')"))

        // Allowed list omitting deleted/revoked chat excludes it at SQL level even without excludedChatKeys
        _ = db.drainSQLTrace()
        let allowOnlyB = try db.search(
            query: keyword,
            context: .toolSearch(
                chatKey: "bot-a",
                allowCrossChat: true,
                allowedChatKeys: ["bot-b"],
                limit: 20
            )
        )
        let allowOnlyBTrace = db.drainSQLTrace().joined(separator: "\n")
        XCTAssertEqual(allowOnlyB.map(\.entryID), ["clean-b"])
        XCTAssertTrue(allowOnlyBTrace.contains("m.chat_key IN ('bot-b')"))

        // Empty allowlist enforces 1 = 0 in SQLite WHERE clause
        _ = db.drainSQLTrace()
        let allowEmpty = try db.search(
            query: keyword,
            context: .toolSearch(
                chatKey: "bot-a",
                allowCrossChat: true,
                allowedChatKeys: [],
                limit: 20
            )
        )
        let allowEmptyTrace = db.drainSQLTrace().joined(separator: "\n")
        XCTAssertEqual(allowEmpty, [])
        XCTAssertTrue(allowEmptyTrace.contains("1 = 0"))

        // 3. Delegated helper toolSearch: current live chat only, no cross-chat, no leaves
        _ = db.drainSQLTrace()
        let delegatedHits = try db.search(
            query: keyword,
            context: .delegatedToolSearch(chatKey: "bot-a", limit: 20)
        )
        let delegatedTrace = db.drainSQLTrace().joined(separator: "\n")
        XCTAssertEqual(delegatedHits.map(\.entryID), ["clean-a"])
        XCTAssertTrue(delegatedTrace.contains("m.leaf_id = ''"))
        XCTAssertTrue(delegatedTrace.contains("m.chat_key = 'bot-a'"))

        // 4. Internal diagnostic strict preset
        let diagHits = try db.search(
            query: keyword,
            context: .internalDiagnostic(limit: 20)
        )
        XCTAssertEqual(Set(diagHits.map(\.entryID)), ["clean-a", "leaf-a", "clean-b", "excluded-c"])
    }

    // MARK: 4. Vault Secret Redaction & Incremental Updates / Deletions

    func testSecretRedactionAndIncrementalMutationConsistency() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("clio-index.db")

        let db = MemoryIndexDatabase(databaseURL: dbURL)
        defer { db.close() }
        _ = try db.openOrRecover()

        let secret = "sk-clio-super-secret-998877"
        try db.rebuild(
            records: [
                MemoryIndexRecord(
                    chatKey: "bot-a",
                    chatName: "团子",
                    entryID: "e1",
                    role: "user",
                    atMs: 100,
                    text: "请帮我配置服务器，密钥是 \(secret)，端口 22。"
                ),
            ],
            sourceFingerprint: "fp-1",
            secrets: [secret]
        )

        // Secret must NEVER appear anywhere in SQLite snippet_text or FTS tokens
        XCTAssertEqual(
            try db.search(query: secret, context: .toolSearch(chatKey: "bot-a")),
            []
        )
        let portHits = try db.search(query: "端口", context: .toolSearch(chatKey: "bot-a"))
        XCTAssertEqual(portHits.count, 1)
        XCTAssertFalse(portHits[0].snippet.contains(secret))
        XCTAssertTrue(portHits[0].snippet.contains("〔隐去〕"))

        // Incremental slot replacement removes stale tokens immediately and preserves catalog fingerprint
        try db.replaceSlot(
            chatKey: "bot-a",
            leafID: "",
            records: [
                MemoryIndexRecord(
                    chatKey: "bot-a",
                    chatName: "团子",
                    entryID: "e2",
                    role: "user",
                    atMs: 200,
                    text: "已改用杭州机房节点部署。"
                ),
            ],
            slotDigest: "digest-2",
            secrets: [secret]
        )
        XCTAssertEqual((try db.buildState()).sourceFingerprint, "fp-1")
        XCTAssertEqual(try db.readSlotVersions()[MemoryIndexSlotKey(chatKey: "bot-a", leafID: "")], "digest-2")
        XCTAssertEqual(try db.search(query: "服务器", context: .toolSearch(chatKey: "bot-a")), [])
        XCTAssertEqual(try db.search(query: "杭州机房", context: .toolSearch(chatKey: "bot-a")).map(\.entryID), ["e2"])

        // Add leaf, update leaf title with secret redaction, then delete leaf and verify FTS consistency
        try db.replaceSlot(
            chatKey: "bot-a",
            leafID: "leaf-9",
            records: [
                MemoryIndexRecord(
                    chatKey: "bot-a",
                    chatName: "团子",
                    leafID: "leaf-9",
                    leafTitle: "原标题",
                    entryID: "e3",
                    role: "user",
                    atMs: 150,
                    text: "旧页里的成都美食攻略。"
                ),
            ],
            slotDigest: "leaf-digest-1"
        )
        try db.updateLeafTitle(
            chatKey: "bot-a",
            leafID: "leaf-9",
            leafTitle: "成都攻略 \(secret)",
            slotDigest: "leaf-digest-2",
            secrets: [secret]
        )
        let leafHits = try db.search(query: "成都美食", context: .toolSearch(chatKey: "bot-a"))
        XCTAssertEqual(leafHits.first?.leafTitle, "成都攻略 〔隐去〕")
        XCTAssertEqual(try db.readSlotVersions()[MemoryIndexSlotKey(chatKey: "bot-a", leafID: "leaf-9")], "leaf-digest-2")

        // Verify directly in raw SQLite that the secret never landed in messages_meta.leaf_title
        let raw = try openRawSQLite(dbURL)
        defer { sqlite3_close_v2(raw) }
        XCTAssertEqual(
            try rawCount(raw, sql: "SELECT COUNT(*) FROM messages_meta WHERE leaf_title LIKE '%\(secret)%';"),
            0
        )
        XCTAssertEqual((try db.buildState()).sourceFingerprint, "fp-1")

        try db.deleteChat(chatKey: "bot-a", includingLeaves: false, leafID: "leaf-9")
        XCTAssertNil(try db.readSlotVersions()[MemoryIndexSlotKey(chatKey: "bot-a", leafID: "leaf-9")])
        XCTAssertEqual((try db.buildState()).sourceFingerprint, "fp-1")
        XCTAssertEqual(try db.search(query: "成都美食", context: .toolSearch(chatKey: "bot-a")), [])
        XCTAssertEqual(try db.search(query: "杭州机房", context: .toolSearch(chatKey: "bot-a")).map(\.entryID), ["e2"])

        try db.deleteChat(chatKey: "bot-a", includingLeaves: true)
        XCTAssertTrue(try db.readSlotVersions().isEmpty)
        XCTAssertEqual(try db.search(query: "杭州机房", context: .toolSearch(chatKey: "bot-a")), [])
        XCTAssertEqual((try db.buildState()).indexedCount, 0)
        XCTAssertTrue(try db.verifyFTSIntegrity())
    }
}
