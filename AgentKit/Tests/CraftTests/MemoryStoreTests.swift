@testable import Craft
import Foundation
import SQLite3
import XCTest

final class MemoryStoreTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clio-memory-store-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func openRawSQLite(_ url: URL) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil)
        guard rc == SQLITE_OK, let opened = handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw NSError(domain: "MemoryStoreTests", code: Int(rc))
        }
        return opened
    }

    private func rawString(_ handle: OpaquePointer, sql: String) throws -> String {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw NSError(domain: "MemoryStoreTests", code: Int(rc))
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let cStr = sqlite3_column_text(stmt, 0) else {
            throw NSError(domain: "MemoryStoreTests", code: -1)
        }
        return String(cString: cStr)
    }

    private func rawInt(_ handle: OpaquePointer, sql: String) throws -> Int {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw NSError(domain: "MemoryStoreTests", code: Int(rc))
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw NSError(domain: "MemoryStoreTests", code: -1)
        }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    // MARK: 1. Schema, WAL Pragmas, 4 Memory Layers, Pinning & Promotion/Demotion

    func testSchemaPragmasAndFourMemoryLayersLifecycle() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("clio-memory.db")

        let store = MemoryStore(databaseURL: dbURL)
        defer { store.close() }

        XCTAssertEqual(try store.openOrRecover(), .missing)
        XCTAssertTrue(store.needsBootstrapFromCanonical)

        let raw = try openRawSQLite(dbURL)
        defer { sqlite3_close_v2(raw) }
        XCTAssertEqual(try rawString(raw, sql: "PRAGMA journal_mode;").lowercased(), "wal")
        XCTAssertEqual(try rawInt(raw, sql: "PRAGMA user_version;"), 1)
        XCTAssertEqual(try rawInt(raw, sql: "PRAGMA foreign_keys;"), 1)

        _ = try store.upsert(
            MemoryRecord(
                id: "m-pin",
                text: "平时只喝无糖乌龙茶",
                layer: .pinned,
                pinned: true,
                kind: "preference",
                topic: "饮品",
                sourceChat: "bot-chief",
                sourceEntryID: "e1",
                confidence: 0.95,
                createdAtMs: 1_000,
                usedAtMs: 1_000,
                editedByUser: true
            )
        )
        _ = try store.upsert(
            MemoryRecord(
                id: "m-surf-old",
                text: "住在重庆南岸区",
                layer: .surface,
                kind: "fact",
                topic: "居住",
                createdAtMs: 2_000,
                usedAtMs: 2_000
            )
        )
        _ = try store.upsert(
            MemoryRecord(
                id: "m-surf-new",
                text: "主要用 Swift 开发 iOS 应用",
                layer: .surface,
                kind: "project",
                topic: "技术栈",
                createdAtMs: 3_000,
                usedAtMs: 3_000
            )
        )
        _ = try store.upsert(
            MemoryRecord(
                id: "m-deep",
                text: "2024 年秋天去过川西稻城亚丁",
                layer: .deep,
                kind: "experience",
                topic: "旅行",
                createdAtMs: 500,
                usedAtMs: 500
            )
        )
        _ = try store.upsert(
            MemoryRecord(
                id: "m-arch",
                text: "临时搬家纸箱已全部回收",
                layer: .archived,
                kind: "candidate",
                topic: "杂项",
                createdAtMs: 4_000,
                usedAtMs: 4_000
            )
        )

        XCTAssertEqual(try store.list(layer: .pinned).map(\.id), ["m-pin"])
        XCTAssertEqual(try store.list(layer: .surface).map(\.id), ["m-surf-old", "m-surf-new"])
        XCTAssertEqual(try store.list(layer: .deep).map(\.id), ["m-deep"])
        XCTAssertEqual(try store.list(layer: .archived).map(\.id), ["m-arch"])

        // activeFacts includes pinned + surface (isDeep: false) and deep (isDeep: true), excludes archived.
        let facts = try store.activeFacts()
        XCTAssertEqual(Set(facts.map(\.id)), ["m-pin", "m-surf-old", "m-surf-new", "m-deep"])
        XCTAssertFalse(facts.contains(where: { $0.id == "m-arch" }))
        XCTAssertEqual(facts.first(where: { $0.id == "m-pin" })?.isDeep, false)
        XCTAssertEqual(facts.first(where: { $0.id == "m-deep" })?.isDeep, true)

        // settleSurface with limit 2: pinned stays immune, oldest surface sinks to deep!
        let demoted = try store.settleSurface(limit: 2, nowMs: 5_000)
        XCTAssertEqual(demoted, ["m-surf-old"])
        XCTAssertEqual(try store.list(layer: .pinned).map(\.id), ["m-pin"])
        XCTAssertEqual(try store.list(layer: .surface).map(\.id), ["m-surf-new"])
        XCTAssertEqual(Set(try store.list(layer: .deep).map(\.id)), ["m-deep", "m-surf-old"])

        // Promote deep -> pinned, edit text, and unpin back to surface.
        let promoted = try store.pin(id: "m-deep", pinned: true, nowMs: 6_000)
        XCTAssertEqual(promoted?.layer, .pinned)
        XCTAssertEqual(promoted?.pinned, true)

        let edited = try store.editText(id: "m-surf-new", text: "主力使用 Swift 5 和 SwiftUI", nowMs: 7_000)
        XCTAssertEqual(edited?.text, "主力使用 Swift 5 和 SwiftUI")
        XCTAssertEqual(edited?.editedByUser, true)

        let unpinned = try store.pin(id: "m-deep", pinned: false, nowMs: 8_000)
        XCTAssertEqual(unpinned?.layer, .surface)
        XCTAssertEqual(unpinned?.pinned, false)

        // Move to archived layer explicitly.
        let archived = try store.setLayer(id: "m-surf-old", layer: .archived, nowMs: 9_000)
        XCTAssertEqual(archived?.layer, .archived)
        XCTAssertFalse(try store.activeFacts().contains(where: { $0.id == "m-surf-old" }))

        let hits = try store.search(query: "乌龙茶", layers: [.pinned])
        XCTAssertEqual(hits.map(\.id), ["m-pin"])
    }

    // MARK: 2. Tombstone Soft Delete, Anti-Resurrection, Restore & Purge

    func testTombstoneSoftDeletePreventsResurrectionAcrossSyncAndReopen() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("clio-memory.db")

        var store = MemoryStore(databaseURL: dbURL)
        _ = try store.upsert(
            MemoryRecord(
                id: "m-allergy",
                text: "对花生和坚果严重过敏",
                layer: .surface,
                createdAtMs: 1_000,
                updatedAtMs: 1_000,
                usedAtMs: 1_000,
                byBot: "chief"
            )
        )

        let tomb = try store.softDelete(id: "m-allergy", nowMs: 2_000, reason: "user_delete")
        XCTAssertNotNil(tomb)
        XCTAssertEqual(tomb?.deletedAtMs, 2_000)
        XCTAssertEqual(tomb?.textSHA256, MemorySafety.retractionHash("对花生和坚果严重过敏"))
        XCTAssertTrue(try store.list().isEmpty)
        XCTAssertTrue(try store.activeFacts().isEmpty)
        XCTAssertTrue(try store.isSuppressed(text: "对花生和坚果严重过敏！"))

        // Tombstone row is preserved in `memories` with non-null deleted_at_ms AND in `memory_tombstones`.
        let deletedRows = try store.list(includeDeleted: true)
        XCTAssertEqual(deletedRows.count, 1)
        XCTAssertEqual(deletedRows[0].deletedAtMs, 2_000)
        XCTAssertEqual(try store.tombstones().count, 1)

        // Older live book re-import (updatedAt <= deletedAt) MUST NOT resurrect.
        let staleBook = CanonicalMemoryBook(
            memories: [
                CanonicalMemoryItem(
                    id: "m-allergy",
                    text: "对花生和坚果严重过敏",
                    at: 1_000,
                    used: 1_500,
                    updatedAt: 2_000
                ),
                CanonicalMemoryItem(
                    id: "m-allergy-new-id",
                    text: "对花生和坚果严重过敏。",
                    at: 1_200,
                    used: 1_800
                ),
            ]
        )
        let afterStaleSync = try store.reconcile(book: staleBook, nowMs: 2_500)
        XCTAssertTrue(afterStaleSync.memories.isEmpty)
        XCTAssertEqual(afterStaleSync.tombstones.count, 1)

        // Automatic extraction (`explicitUserAction: false`, `automatic: true`) MUST NOT resurrect even later.
        let autoAttempt = try store.upsert(
            MemoryRecord(
                id: "m-auto-retry",
                text: "对花生和坚果严重过敏",
                createdAtMs: 3_000,
                updatedAtMs: 3_000,
                automatic: true
            ),
            explicitUserAction: false
        )
        XCTAssertNil(autoAttempt)

        // Automatic item in canonical book MUST NOT resurrect either.
        let autoBook = CanonicalMemoryBook(
            memories: [
                CanonicalMemoryItem(
                    id: "m-auto-book",
                    text: "对花生和坚果严重过敏",
                    at: 3_500,
                    used: 3_500,
                    automatic: true,
                    updatedAt: 3_500
                ),
            ]
        )
        let afterAutoSync = try store.reconcile(book: autoBook, nowMs: 3_600)
        XCTAssertTrue(afterAutoSync.memories.isEmpty)

        // Close and reopen DB: tombstone remains persistent.
        store.close()
        store = MemoryStore(databaseURL: dbURL)
        XCTAssertEqual(try store.openOrRecover(), .none)
        XCTAssertTrue(try store.isSuppressed(text: "对花生和坚果严重过敏"))
        XCTAssertTrue(try store.list().isEmpty)

        // Verify PromptState integration blocks automatic proposals using exported suppressedFlushHashes.
        let exported = try store.snapshotBook()
        let filtered = MemorySafety.filterSuppressedProposals(
            [MemorySafety.FilteredProposal(text: "对花生和坚果严重过敏")],
            existingTexts: [],
            suppressedHashes: Set(exported.suppressedFlushHashes)
        )
        XCTAssertTrue(filtered.isEmpty)

        // Explicit user re-addition clears suppression cleanly.
        let recreated = try store.upsert(
            MemoryRecord(
                id: "m-readded",
                text: "对花生和坚果严重过敏",
                layer: .surface,
                createdAtMs: 4_000,
                updatedAtMs: 4_000,
                editedByUser: true
            ),
            explicitUserAction: true
        )
        XCTAssertNotNil(recreated)
        XCTAssertFalse(try store.isSuppressed(text: "对花生和坚果严重过敏"))
        XCTAssertEqual(try store.list().map(\.text), ["对花生和坚果严重过敏"])

        // Delete again, then test explicit `restore(id:)` and `purgeTombstone(id:)`.
        _ = try store.softDelete(id: "m-readded", nowMs: 5_000)
        XCTAssertTrue(try store.list().isEmpty)
        let restored = try store.restore(id: "m-readded", layer: .pinned, nowMs: 6_000)
        XCTAssertEqual(restored?.layer, .pinned)
        XCTAssertFalse(try store.isSuppressed(text: "对花生和坚果严重过敏"))

        _ = try store.softDelete(id: "m-readded", nowMs: 7_000)
        XCTAssertTrue(try store.purgeTombstone(id: "m-readded"))
        XCTAssertFalse(try store.isSuppressed(text: "对花生和坚果严重过敏"))
        XCTAssertTrue(try store.list(includeDeleted: true).isEmpty)
        store.close()
    }

    // MARK: 3. Canonical `memory.json` Bidirectional Sync, Legacy Bootstrap & Conflict Resolution

    func testBidirectionalCanonicalSyncConflictResolutionAndLegacyBootstrap() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("clio-memory.db")

        // Legacy bare `[Memory]` array JSON (like older Clio installs).
        let legacyJSON = """
        [
          {"id":"m1","text":"早起喝黑咖啡","at":1000,"used":2000,"editedByUser":true},
          {"id":"m2","text":"养了一只橘猫叫年糕","at":1500,"deep":true,"used":1500}
        ]
        """
        let legacyBook = try CanonicalMemoryBook.decodeFlexible(from: Data(legacyJSON.utf8))
        XCTAssertEqual(legacyBook.memories.count, 2)
        XCTAssertEqual(legacyBook.memories[1].resolvedLayer, .deep)

        let store = MemoryStore(databaseURL: dbURL)
        defer { store.close() }

        // Bootstrap from legacy book + review/budget metadata.
        var initialBook = legacyBook
        let reviewID = UUID()
        initialBook.reviewFromDay = "2026-11-20"
        initialBook.budgetDay = "2026-11-24"
        initialBook.requests = 5
        initialBook.diaryRequests = 2
        initialBook.processed = ["2026-11-24": ["entry-1", "entry-2"]]
        initialBook.reviews = [
            CanonicalMemoryReviewLog(
                id: reviewID,
                at: Date(timeIntervalSince1970: 1_700_000_000),
                day: "2026-11-24",
                conversation: "小克",
                added: [.init(memoryID: "m1", text: "早起喝黑咖啡")],
                merged: []
            ),
        ]

        _ = try store.reconcile(book: initialBook, nowMs: 2_500)
        _ = try store.pin(id: "m1", pinned: true, nowMs: 3_000)
        _ = try store.upsert(
            MemoryRecord(
                id: "m3",
                text: "旧工位在 3 楼东侧",
                layer: .archived,
                createdAtMs: 3_100,
                updatedAtMs: 3_100
            )
        )

        // Export canonical snapshot and verify all metadata + layers + archived preserved.
        let exported = try store.snapshotBook()
        XCTAssertEqual(exported.budgetDay, "2026-11-24")
        XCTAssertEqual(exported.reviewFromDay, "2026-11-20")
        XCTAssertEqual(exported.requests, 5)
        XCTAssertEqual(exported.diaryRequests, 2)
        XCTAssertEqual(exported.processed["2026-11-24"], ["entry-1", "entry-2"])
        XCTAssertEqual(exported.reviews.map(\.id), [reviewID])
        XCTAssertEqual(exported.memories.first(where: { $0.id == "m1" })?.layer, .pinned)
        XCTAssertEqual(exported.archived.map(\.id), ["m3"])

        // Conflict resolution:
        // 1) Stale legacy book (used=2500 < db updatedAt 3000) must NOT unpin m1 or overwrite newer edit.
        // 2) Newer external edit on m2 (updatedAt=5000 > 1500) MUST win and promote m2 to surface.
        // 3) Newer explicit re-add after tombstone wins; older tombstone wins over older live entry.
        _ = try store.editText(id: "m1", text: "早起喝冰美式", nowMs: 4_000)

        let conflictingBook = CanonicalMemoryBook(
            memories: [
                CanonicalMemoryItem(
                    id: "m1",
                    text: "早起喝黑咖啡",
                    at: 1_000,
                    used: 2_500,
                    editedByUser: true
                ),
                CanonicalMemoryItem(
                    id: "m2",
                    text: "养了两只橘猫：年糕和团子",
                    at: 1_500,
                    deep: nil,
                    used: 5_000,
                    editedByUser: true,
                    layer: .surface,
                    updatedAt: 5_000
                ),
            ],
            processed: ["2026-11-25": ["entry-3"]],
            reviewFromDay: "2026-11-18",
            budgetDay: "2026-11-24",
            requests: 7,
            diaryRequests: 1
        )
        let merged = try store.reconcile(book: conflictingBook, nowMs: 5_100)
        let m1 = merged.memories.first { $0.id == "m1" }
        let m2 = merged.memories.first { $0.id == "m2" }
        XCTAssertEqual(m1?.text, "早起喝冰美式")
        XCTAssertEqual(m1?.layer, .pinned)
        XCTAssertEqual(m2?.text, "养了两只橘猫：年糕和团子")
        XCTAssertEqual(m2?.resolvedLayer, .surface)
        XCTAssertEqual(merged.archived.map(\.id), ["m3"])
        XCTAssertEqual(merged.reviewFromDay, "2026-11-18")
        XCTAssertEqual(merged.requests, 7)
        XCTAssertEqual(merged.diaryRequests, 2)
        XCTAssertEqual(merged.processed["2026-11-24"], ["entry-1", "entry-2"])
        XCTAssertEqual(merged.processed["2026-11-25"], ["entry-3"])
    }

    // MARK: 4. Vault Secret Redaction, Corrupt DB Self-Healing & Markdown Mirror

    func testSecretRedactionAndCorruptDBRecoveryFromCanonicalJSON() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("clio-memory.db")
        let secrets = ["vault-token-secret-998877", "bearer-vault-xyz"]

        var store = MemoryStore(databaseURL: dbURL)
        let saved = try store.upsert(
            MemoryRecord(
                id: "m-sec",
                text: "测试接口的密钥是 vault-token-secret-998877 请记住",
                layer: .pinned,
                pinned: true,
                topic: "token bearer-vault-xyz",
                createdAtMs: 1_000,
                updatedAtMs: 1_000
            ),
            secrets: secrets
        )
        XCTAssertNotNil(saved)
        XCTAssertFalse(saved!.text.contains("vault-token-secret-998877"))
        XCTAssertTrue(saved!.text.contains("〔隐去〕"))
        XCTAssertFalse(saved!.topic.contains("bearer-vault-xyz"))

        // Verify raw SQLite bytes never hold unredacted secret.
        let raw = try openRawSQLite(dbURL)
        let storedText = try rawString(raw, sql: "SELECT text FROM memories WHERE id = 'm-sec';")
        let storedTopic = try rawString(raw, sql: "SELECT topic FROM memories WHERE id = 'm-sec';")
        sqlite3_close_v2(raw)
        XCTAssertFalse(storedText.contains("vault-token-secret-998877"))
        XCTAssertFalse(storedTopic.contains("bearer-vault-xyz"))

        _ = try store.upsert(
            MemoryRecord(
                id: "m-del",
                text: "已删掉的旧习惯",
                layer: .surface,
                createdAtMs: 2_000,
                updatedAtMs: 2_000
            ),
            secrets: secrets
        )
        _ = try store.softDelete(id: "m-del", nowMs: 3_000)

        let canonicalSnapshot = try store.snapshotBook()
        let canonicalData = try JSONEncoder().encode(canonicalSnapshot)
        store.close()

        // Corrupt clio-memory.db on disk intentionally.
        try Data("NOT A VALID SQLITE DATABASE HEADER CORRUPTION TEST".utf8).write(to: dbURL, options: .atomic)

        store = MemoryStore(databaseURL: dbURL)
        let recoveryReason = try store.openOrRecover()
        XCTAssertEqual(recoveryReason, .corrupt)
        XCTAssertTrue(store.needsBootstrapFromCanonical)

        // Recover seamlessly from canonical JSON snapshot.
        let decodedBook = try CanonicalMemoryBook.decodeFlexible(from: canonicalData)
        let recoveredBook = try store.reconcile(book: decodedBook, secrets: secrets, nowMs: 4_000)
        XCTAssertEqual(recoveredBook.memories.map(\.id), ["m-sec"])
        XCTAssertEqual(recoveredBook.memories.first?.layer, .pinned)
        XCTAssertTrue(try store.isSuppressed(text: "已删掉的旧习惯"))
        store.close()
    }

    func testMarkdownMirrorRenderingRedactionZeroChurnAndUserEditPreservation() {
        let secrets = ["clio-secret-abc-123"]
        let records: [MemoryRecord] = [
            MemoryRecord(
                id: "1",
                text: "核心设定：喜欢无糖茶，密钥 clio-secret-abc-123",
                layer: .pinned,
                pinned: true,
                kind: "preference",
                topic: "饮品",
                createdAtMs: 1_700_000_000_000,
                updatedAtMs: 1_700_000_100_000
            ),
            MemoryRecord(
                id: "2",
                text: "最近在重构 Clio 记忆存储",
                layer: .surface,
                createdAtMs: 1_700_000_200_000,
                updatedAtMs: 1_700_000_200_000
            ),
            MemoryRecord(
                id: "3",
                text: "前年冬天去了哈尔滨",
                layer: .deep,
                createdAtMs: 1_690_000_000_000,
                updatedAtMs: 1_690_000_000_000
            ),
            MemoryRecord(
                id: "4",
                text: "已删除的隐私条目",
                layer: .surface,
                createdAtMs: 1_700_000_300_000,
                updatedAtMs: 1_700_000_300_000,
                deletedAtMs: 1_700_000_400_000
            ),
        ]
        let bots = [
            MemoryMirrorBot(name: "小克", role: "贴身助理", isMain: true),
            MemoryMirrorBot(name: "阿墨", role: "写稿 · clio-secret-abc-123", isMain: false),
        ]
        let tz = TimeZone(secondsFromGMT: 8 * 3600) ?? .current

        let zhenzhi = MemoryMarkdownRenderer.renderZhenzhi(records: records, secrets: secrets, timeZone: tz)
        XCTAssertTrue(zhenzhi.contains("# 镇纸"))
        XCTAssertTrue(zhenzhi.contains("喜欢无糖茶"))
        XCTAssertTrue(zhenzhi.contains("〔隐去〕"))
        XCTAssertFalse(zhenzhi.contains("clio-secret-abc-123"))
        XCTAssertFalse(zhenzhi.contains("重构 Clio"))
        XCTAssertFalse(zhenzhi.contains("已删除的隐私条目"))

        let dangan = MemoryMarkdownRenderer.renderDangan(records: records, bots: bots, secrets: secrets, timeZone: tz)
        XCTAssertTrue(dangan.contains("# 档案"))
        XCTAssertTrue(dangan.contains("镇纸 1 条 · 常记 1 条 · 旧事 1 条"))
        XCTAssertTrue(dangan.contains("小克（主 · 贴身助理）"))
        XCTAssertFalse(dangan.contains("clio-secret-abc-123"))
        XCTAssertFalse(dangan.contains("已删除的隐私条目"))

        // User-authored file without markers: preserved verbatim above managed section.
        let userFile = "# 我的手写备忘\n\n不要删掉这一行。"
        let firstMerge = MemoryMarkdownRenderer.mergeManagedSection(dangan, into: userFile)
        XCTAssertTrue(firstMerge.hasPrefix("# 我的手写备忘\n\n不要删掉这一行。"))
        XCTAssertTrue(firstMerge.contains(MemoryMarkdownRenderer.startMarker))
        XCTAssertTrue(MemoryMarkdownRenderer.shouldWrite(merged: firstMerge, existing: userFile))

        // Re-running with identical data produces zero churn.
        let secondMerge = MemoryMarkdownRenderer.mergeManagedSection(dangan, into: firstMerge)
        XCTAssertFalse(MemoryMarkdownRenderer.shouldWrite(merged: secondMerge, existing: firstMerge))
        XCTAssertEqual(secondMerge, firstMerge)
    }
}
