@testable import Craft
import Foundation
import SQLite3
import XCTest

final class DocSearchIndexTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clio-doc-search-index-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func openRawSQLite(_ url: URL) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil)
        guard rc == SQLITE_OK, let opened = handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw NSError(domain: "DocSearchIndexTests", code: Int(rc))
        }
        return opened
    }

    private func execRawSQLite(_ handle: OpaquePointer, _ sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "sqlite error"
            if let errMsg { sqlite3_free(errMsg) }
            throw NSError(domain: "DocSearchIndexTests", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    // MARK: 1. Passage Indexing, PDF Pages, CJK Bigram Matching & Multi-Term Ranking

    func testPassagesPDFPagesCJKBigramAndMultiTermCoverage() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let index = DocSearchIndex(cachesRoot: dir)
        defer { index.close() }

        XCTAssertEqual(try index.openOrRecover(), .missing)
        XCTAssertTrue(index.needsRebuildFromSource)
        XCTAssertEqual(index.isFTS5Active, DocSearchIndex.isFTS5Supported)

        let manual = "[第 1 页]\n公司简介\n\n[第 2 页]\n报销的流程：先填单，再找主管签字，最后交财务。\n\n[第 3 页]\n请假要提前三天说。"
        let notes = "周末去重庆吃火锅。\n\n报销记得留发票。"
        let singleTopic = "去重庆出差安排。"
        let techDoc = "全角 Ｘｃｏｄｅ 打包指南与 Café 笔记，支持 Swift 并发。"

        try index.sync(documents: [
            ("手册.pdf", manual),
            ("notes/笔记.md", notes),
            ("notes/行程.md", singleTopic),
            ("notes/dev.txt", techDoc),
        ])
        XCTAssertFalse(index.needsRebuildFromSource)
        XCTAssertTrue(try index.verifyFTSIntegrity())
        XCTAssertEqual(try index.trackedDocumentCount(), 4)

        // CJK partial/bigram guarantee: "报销流程" finds "报销的流程" with preserved PDF page 2.
        let reimbursementHits = try index.search(query: "报销流程")
        XCTAssertEqual(reimbursementHits.first?.path, "手册.pdf")
        XCTAssertEqual(reimbursementHits.first?.page, 2)
        XCTAssertTrue(reimbursementHits.first?.snippet.contains("主管签字") == true)

        // Multi-term coverage bonus: doc matching both "火锅" and "重庆" ranks first.
        let chongqingHits = try index.search(query: "火锅 重庆")
        XCTAssertEqual(chongqingHits.first?.path, "notes/笔记.md")
        XCTAssertTrue(chongqingHits.first?.snippet.contains("火锅") == true)

        // Case/fullwidth/diacritic folding.
        XCTAssertEqual(try index.search(query: "Xcode").map(\.path), ["notes/dev.txt"])
        XCTAssertEqual(try index.search(query: "cafe").map(\.path), ["notes/dev.txt"])
        XCTAssertEqual(try index.search(query: "Swift 并发").map(\.path), ["notes/dev.txt"])

        // Missing term & FTS5 syntax punctuation never fail.
        XCTAssertTrue(try index.search(query: "天气").isEmpty)
        XCTAssertTrue(try index.search(query: "AND OR NOT NEAR \"foo:bar\" *").isEmpty)
        XCTAssertTrue(try index.search(query: "   \n\t ").isEmpty)
    }

    // MARK: 2. Folder Scoping & Incremental Sync + Pruning

    func testFolderScopingIncrementalSyncAndRemovedDocPruning() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let index = DocSearchIndex(cachesRoot: dir)
        defer { index.close() }

        let docA = DocSearchDocumentInput(path: "notes/a.md", text: "第一版报销规定", byteCount: 21, mtimeMs: 1_000)
        let docB = DocSearchDocumentInput(path: "notes/sub/b.md", text: "差旅住宿报销标准", byteCount: 24, mtimeMs: 2_000)
        let docOtherPrefix = DocSearchDocumentInput(path: "notes2/other.md", text: "无关的报销草稿", byteCount: 21, mtimeMs: 2_500)
        let mountedA = DocSearchDocumentInput(path: "挂载/Obsidian/工作.md", text: "Obsidian 里的报销总结", byteCount: 30, mtimeMs: 3_000)
        let mountedB = DocSearchDocumentInput(path: "挂载/Obsidian2/其他.md", text: "另一个挂载报销", byteCount: 21, mtimeMs: 3_500)

        try index.sync(inputs: [docA, docB, docOtherPrefix, mountedA, mountedB])
        XCTAssertEqual(try index.trackedDocumentCount(), 5)

        // Folder prefix scoping must match exact subtree without prefix collision ("notes" != "notes2").
        let notesHits = try index.search(query: "报销", folderPrefix: "notes")
        XCTAssertEqual(Set(notesHits.map(\.path)), ["notes/a.md", "notes/sub/b.md"])

        let mountHits = try index.search(query: "报销", folderPrefix: "挂载/Obsidian")
        XCTAssertEqual(mountHits.map(\.path), ["挂载/Obsidian/工作.md"])

        // Incremental planSync: unchanged docs are NOT marked stale; modified/new/removed docs ARE detected.
        let nextDescriptors = [
            DocSearchDocumentDescriptor(path: "notes/a.md", byteCount: 21, mtimeMs: 1_000), // unchanged
            DocSearchDocumentDescriptor(path: "notes/sub/b.md", byteCount: 27, mtimeMs: 4_000), // modified
            DocSearchDocumentDescriptor(path: "notes/new.md", byteCount: 18, mtimeMs: 5_000), // new
            // notes2/other.md, mountedA, mountedB omitted only if scope is global, so test scoped planSync!
        ]
        let scopedPlan = try index.planSync(descriptors: nextDescriptors, scopePrefix: "notes")
        XCTAssertEqual(scopedPlan.staleOrNewPaths, ["notes/sub/b.md", "notes/new.md"])
        XCTAssertEqual(scopedPlan.removedPaths, [])

        // Now remove notes/a.md inside "notes" scope -> only notes/a.md is pruned, mounted & notes2 stay intact!
        let prunePlan = try index.planSync(
            descriptors: [
                DocSearchDocumentDescriptor(path: "notes/sub/b.md", byteCount: 27, mtimeMs: 4_000),
                DocSearchDocumentDescriptor(path: "notes/new.md", byteCount: 18, mtimeMs: 5_000),
            ],
            scopePrefix: "notes"
        )
        XCTAssertEqual(prunePlan.removedPaths, ["notes/a.md"])
        try index.applyIncrementalSync(
            upserts: [
                DocSearchDocumentInput(path: "notes/sub/b.md", text: "新版差旅住宿标准说明", byteCount: 27, mtimeMs: 4_000),
                DocSearchDocumentInput(path: "notes/new.md", text: "新增报销附件要求", byteCount: 18, mtimeMs: 5_000),
            ],
            removedPaths: prunePlan.removedPaths
        )

        XCTAssertEqual(try index.trackedDocumentCount(), 5) // notes/a.md replaced by notes/new.md; others untouched
        XCTAssertEqual(try index.trackedDocumentCount(folderPrefix: "挂载/Obsidian"), 1)
        XCTAssertEqual(try index.search(query: "第一版报销规定"), [])
        XCTAssertEqual(try index.search(query: "报销附件", folderPrefix: "notes").map(\.path), ["notes/new.md"])
        XCTAssertEqual(try index.search(query: "Obsidian", folderPrefix: "挂载/Obsidian").map(\.path), ["挂载/Obsidian/工作.md"])
    }

    // MARK: 3. Vault Secret Redaction

    func testNeverIndexesOrReturnsVaultSecrets() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let index = DocSearchIndex(cachesRoot: dir)
        defer { index.close() }

        let secret = "sk-doc-secret-777"
        try index.sync(
            documents: [
                ("配置说明.md", "后端模型配置说明，密钥是 sk-doc-secret-777，注意保密。"),
            ],
            secrets: [secret]
        )

        let configHits = try index.search(query: "后端模型配置", secrets: [secret])
        XCTAssertEqual(configHits.map(\.path), ["配置说明.md"])
        XCTAssertFalse(configHits[0].snippet.contains(secret))
        XCTAssertTrue(configHits[0].snippet.contains("〔隐去〕"))

        // Querying the secret itself must return zero hits.
        let secretProbe = try index.search(query: secret, secrets: [secret])
        XCTAssertTrue(secretProbe.isEmpty)

        // Adding a new secret later invalidates stored docs via `secrets_digest` so they get re-redacted.
        let plan = try index.planSync(
            descriptors: [DocSearchDocumentDescriptor(path: "配置说明.md", byteCount: 0, mtimeMs: 0, contentFingerprint: DocSearchIndex.contentFingerprint(for: "后端模型配置说明，密钥是 sk-doc-secret-777，注意保密。"))],
            secrets: [secret, "new-secret-888"]
        )
        XCTAssertEqual(plan.staleOrNewPaths, ["配置说明.md"])
    }

    func testScopedSyncOnSecretChangePurgesOutOfScopeUnredactedRowsAndSupportsForcedRotation() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let index = DocSearchIndex(cachesRoot: dir)
        defer { index.close() }

        let docNotes = DocSearchDocumentInput(path: "notes/a.md", text: "普通日常工作笔记。")
        let docOther = DocSearchDocumentInput(path: "other/secret.md", text: "内部网关口令 secret-token-xyz 请妥善保管。")

        // Initially indexed with no Vault secrets configured.
        try index.sync(inputs: [docNotes, docOther], secrets: [])
        XCTAssertEqual(try index.trackedDocumentCount(), 2)

        // Now `"secret-token-xyz"` is added to Vault, and ONLY `"notes"` folder is scoped-synced.
        // Out-of-scope `"other/secret.md"` must be purged instead of having a new `secrets_digest` stamped over raw rows.
        let rotatedSecrets = ["secret-token-xyz"]
        let scopedDescriptor = DocSearchDocumentDescriptor(
            path: docNotes.path,
            byteCount: docNotes.byteCount,
            mtimeMs: docNotes.mtimeMs,
            contentFingerprint: docNotes.contentFingerprint
        )
        let scopedPlan = try index.planSync(descriptors: [scopedDescriptor], scopePrefix: "notes", secrets: rotatedSecrets)
        XCTAssertTrue(scopedPlan.staleOrNewPaths.contains("notes/a.md"))
        XCTAssertTrue(scopedPlan.removedPaths.contains("other/secret.md"))

        try index.applyIncrementalSync(upserts: [docNotes], removedPaths: scopedPlan.removedPaths, secrets: rotatedSecrets)
        XCTAssertEqual(try index.trackedDocumentCount(folderPrefix: "notes"), 1)
        XCTAssertEqual(try index.trackedDocumentCount(folderPrefix: "other"), 0)

        // Verify zero unredacted secret bytes remain anywhere in `doc_passages`.
        index.close()
        let raw = try openRawSQLite(index.databaseURL)
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(raw, "SELECT snippet_text FROM doc_passages;", -1, &stmt, nil)
        XCTAssertEqual(rc, SQLITE_OK)
        var rawTexts: [String] = []
        if let stmt {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cStr = sqlite3_column_text(stmt, 0) {
                    rawTexts.append(String(cString: cStr))
                }
            }
            sqlite3_finalize(stmt)
        }
        sqlite3_close_v2(raw)
        XCTAssertFalse(rawTexts.joined(separator: "\n").contains("secret-token-xyz"))

        // Searching `"other"` triggers fresh sync of `"other/secret.md"` with secret redacted and heals cleanly.
        try index.sync(inputs: [docOther], scopePrefix: "other", secrets: rotatedSecrets)
        XCTAssertEqual(try index.trackedDocumentCount(folderPrefix: "other"), 1)
        let otherHits = try index.search(query: "内部网关口令", folderPrefix: "other", secrets: rotatedSecrets)
        XCTAssertEqual(otherHits.map(\.path), ["other/secret.md"])
        XCTAssertFalse(otherHits[0].snippet.contains("secret-token-xyz"))
        XCTAssertTrue(otherHits[0].snippet.contains("〔隐去〕"))
        XCTAssertTrue(try index.search(query: "secret-token-xyz", folderPrefix: "other", secrets: rotatedSecrets).isEmpty)

        // Forced secret rotation helper clears digest so recovery re-indexes even if metadata is unchanged.
        try index.resetForSecretRotation()
        XCTAssertTrue(index.needsRebuildFromSource)
        let forcedPlan = try index.planSync(
            descriptors: [DocSearchDocumentDescriptor(
                path: docOther.path,
                byteCount: docOther.byteCount,
                mtimeMs: docOther.mtimeMs,
                contentFingerprint: docOther.contentFingerprint
            )],
            scopePrefix: "other",
            secrets: rotatedSecrets,
            force: true
        )
        XCTAssertTrue(forcedPlan.staleOrNewPaths.contains("other/secret.md"))
    }

    // MARK: 4. Self-Healing: Corruption, Truncation, Mid-Run Deletion, Schema Mismatch

    func testSelfHealsAcrossCorruptionSidecarsTruncationAndMidRunDeletion() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let index = DocSearchIndex(cachesRoot: dir)
        defer { index.close() }
        let dbURL = index.databaseURL
        let walURL = URL(fileURLWithPath: dbURL.path + "-wal")
        let shmURL = URL(fileURLWithPath: dbURL.path + "-shm")

        let docs: [(path: String, text: String)] = [
            ("手册.pdf", "[第 4 页]\n关于设备维护和故障排查的完整流程。"),
        ]
        try index.sync(documents: docs)
        XCTAssertEqual(try index.search(query: "故障排查").first?.page, 4)

        // 1. Corrupt DB bytes on disk + stray WAL/SHM sidecars after closing.
        index.close()
        try Data("NOT A VALID SQLITE DATABASE".utf8).write(to: dbURL)
        try Data("garbage wal".utf8).write(to: walURL)
        try Data("garbage shm".utf8).write(to: shmURL)

        XCTAssertEqual(try index.openOrRecover(), .corrupt)
        XCTAssertTrue(index.needsRebuildFromSource)
        try index.sync(documents: docs)
        XCTAssertFalse(index.needsRebuildFromSource)
        let afterCorrupt = try index.search(query: "故障排查")
        XCTAssertEqual(afterCorrupt.map(\.path), ["手册.pdf"])
        XCTAssertEqual(afterCorrupt.first?.page, 4)

        // 2. Truncate file in-place while handle is still open.
        try Data("tiny".utf8).write(to: dbURL)
        XCTAssertEqual(try index.openOrRecover(), .corrupt)
        XCTAssertTrue(index.needsRebuildFromSource)
        try index.sync(documents: docs)
        XCTAssertEqual(try index.search(query: "设备维护").map(\.path), ["手册.pdf"])

        // 3. External mid-run deletion of DB and sidecars while handle is open.
        try? FileManager.default.removeItem(at: dbURL)
        try? FileManager.default.removeItem(at: walURL)
        try? FileManager.default.removeItem(at: shmURL)

        let afterDelete = try index.search(query: "故障排查")
        XCTAssertEqual(afterDelete, [])
        XCTAssertEqual(index.lastRecoveryReason, .externalDeletion)
        XCTAssertTrue(index.needsRebuildFromSource)

        try index.sync(documents: docs)
        XCTAssertEqual(try index.search(query: "故障排查").map(\.path), ["手册.pdf"])

        // 4. Schema mismatch recovery.
        index.close()
        let raw = try openRawSQLite(dbURL)
        try execRawSQLite(raw, "PRAGMA user_version = 99;")
        sqlite3_close_v2(raw)

        XCTAssertEqual(try index.openOrRecover(), .schemaMismatch)
        XCTAssertTrue(index.needsRebuildFromSource)
        try index.sync(documents: docs)
        XCTAssertEqual(try index.search(query: "故障排查").map(\.path), ["手册.pdf"])
    }

    // MARK: 5. Backup Exclusion Path Guarantee

    func testDefaultPathLivesInCachesClioIndexOutsideTeamAndExcludesFromBackup() throws {
        let defaultURL = DocSearchIndex.defaultDatabaseURL
        XCTAssertEqual(defaultURL.lastPathComponent, "clio-docs-fts.db")
        XCTAssertEqual(defaultURL.deletingLastPathComponent().lastPathComponent, "ClioIndex")
        XCTAssertTrue(defaultURL.path.contains("/Caches/ClioIndex/"))
        XCTAssertFalse(defaultURL.path.contains("/Application Support/Team/"))
        XCTAssertTrue(BackupArchivePolicy.isSQLiteOrCacheArtifact(defaultURL.lastPathComponent))
        XCTAssertTrue(BackupArchivePolicy.isExcludedArchivePath("Team/ClioIndex/clio-docs-fts.db"))

        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = DocSearchIndex(cachesRoot: dir)
        defer { index.close() }
        _ = try index.openOrRecover()

        #if canImport(Darwin)
        let values = try index.databaseURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
        #endif
    }

    func testFallbackLikeModeMatchesCJKAndPagesWhenFTS5Disabled() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fallback = DocSearchIndex(cachesRoot: dir, forceDisableFTS5ForTesting: true)
        defer { fallback.close() }

        XCTAssertEqual(try fallback.openOrRecover(), .missing)
        XCTAssertFalse(fallback.isFTS5Active)

        let manual = "[第 1 页]\n目录\n\n[第 2 页]\n报销的流程需要主管审批，附上 Ｘｃｏｄｅ 采购发票。"
        try fallback.sync(documents: [("报销指南.pdf", manual)])

        let hits = try fallback.search(query: "报销流程")
        XCTAssertEqual(hits.first?.path, "报销指南.pdf")
        XCTAssertEqual(hits.first?.page, 2)

        XCTAssertEqual(try fallback.search(query: "Xcode").map(\.path), ["报销指南.pdf"])
    }

    // MARK: 6. Security & Bounds Regression Guards

    func testRedactsSecretsInDocumentPaths() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let index = DocSearchIndex(cachesRoot: dir)
        defer { index.close() }

        let secret = "sk-live-secret-9999"
        try index.sync(
            documents: [
                ("secret/\(secret).md", "内部部署文档与灰度发布步骤。"),
            ],
            secrets: [secret]
        )

        let hits = try index.search(query: "灰度发布", secrets: [secret])
        XCTAssertEqual(hits.map(\.path), ["secret/〔隐去〕.md"])
        XCTAssertFalse(hits[0].path.contains(secret))
        XCTAssertFalse(index.consumeUnredactedSecretDetected())
    }

    func testOverflowPDFPageNumberDoesNotCrashAndIndexesWithNilPage() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let overflowDoc = "[第 999999999999999 页]\n超大数据页码测试正文，包含报销单据归档要求。"
        let passages = DocSearch.passages(overflowDoc)
        XCTAssertEqual(passages.count, 1)
        XCTAssertNil(passages[0].page)
        XCTAssertTrue(passages[0].text.contains("超大数据页码测试正文"))

        let index = DocSearchIndex(cachesRoot: dir)
        defer { index.close() }

        try index.sync(documents: [("overflow.pdf", overflowDoc)])
        let hits = try index.search(query: "报销单据归档")
        XCTAssertEqual(hits.map(\.path), ["overflow.pdf"])
        XCTAssertNil(hits[0].page)
    }

    func testHugeMultiTokenQueryBoundsCleanly() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let padding = (0..<2500).map { "token\($0)" }.joined(separator: " ")
        let hugeQuery = "报销 发票 " + padding
        XCTAssertGreaterThan(hugeQuery.utf8.count, 20_000)

        let terms = DocSearch.terms(hugeQuery)
        XCTAssertLessThanOrEqual(terms.count, 24)
        XCTAssertTrue(terms.contains("报销"))
        XCTAssertTrue(terms.contains("发票"))
        XCTAssertNotNil(DocSearchIndex.buildFTS5OrMatchExpression(for: hugeQuery))

        let docs: [(path: String, text: String)] = [
            ("finance/reimburse.md", "公司差旅报销与发票规范说明。"),
            ("notes/other.md", "普通日常会议纪要。"),
        ]
        XCTAssertEqual(DocSearch.find(hugeQuery, in: docs).map(\.path), ["finance/reimburse.md"])

        let index = DocSearchIndex(cachesRoot: dir)
        defer { index.close() }
        try index.sync(documents: docs)
        let hits = try index.search(query: hugeQuery)
        XCTAssertEqual(hits.map(\.path), ["finance/reimburse.md"])
    }
}
