import Foundation
import SQLite3
import XCTest
@testable import Craft

final class SQLiteEngineTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clio-sqlite-engine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testOpenAppliesWALBusyTimeoutForeignKeysAndMigrations() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("test.db")

        let conn = try SQLiteConnection.open(
            at: dbURL,
            options: SQLiteOpenOptions(busyTimeoutMs: 4_500, enableWAL: true, enableForeignKeys: true, excludeFromBackup: true)
        )
        defer { conn.close() }

        XCTAssertEqual(try conn.pragmaString("journal_mode").lowercased(), "wal")
        XCTAssertEqual(try conn.pragmaInt32("busy_timeout"), 4_500)
        XCTAssertEqual(try conn.pragmaInt32("foreign_keys"), 1)
        XCTAssertEqual(try conn.userVersion(), 0)

        var appliedVersions: [Int32] = []
        try conn.migrate(steps: [
            (version: 1, apply: { c in
                appliedVersions.append(1)
                try c.execute("CREATE TABLE items (id TEXT PRIMARY KEY, name TEXT NOT NULL);")
            }),
            (version: 2, apply: { c in
                appliedVersions.append(2)
                try c.execute("ALTER TABLE items ADD COLUMN note TEXT;")
            }),
        ])
        XCTAssertEqual(appliedVersions, [1, 2])
        XCTAssertEqual(try conn.userVersion(), 2)

        // Re-running migrate is a no-op
        try conn.migrate(steps: [
            (version: 1, apply: { _ in appliedVersions.append(99) }),
            (version: 2, apply: { _ in appliedVersions.append(100) }),
        ])
        XCTAssertEqual(appliedVersions, [1, 2])
    }

    func testTransactionRollsBackCleanlyOnError() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("rollback.db")

        let conn = try SQLiteConnection.open(at: dbURL)
        defer { conn.close() }
        try conn.execute("CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT NOT NULL);")

        struct Boom: Error {}
        XCTAssertThrowsError(try conn.withTransaction { c in
            let ins = try c.prepare("INSERT INTO notes (id, body) VALUES (?, ?);")
            try ins.bind(Int64(1), at: 1)
            try ins.bind("should-rollback", at: 2)
            try ins.step()
            throw Boom()
        })

        let countStmt = try conn.prepare("SELECT COUNT(*) FROM notes;")
        XCTAssertTrue(try countStmt.step())
        XCTAssertEqual(countStmt.int64(at: 0), 0)
    }

    func testErrorClassificationAndCorruptionQuarantine() throws {
        XCTAssertTrue(SQLiteEngineError.isTransientLockCode(SQLITE_BUSY))
        XCTAssertTrue(SQLiteEngineError.isTransientLockCode(SQLITE_LOCKED))
        XCTAssertFalse(SQLiteEngineError.isCorruptionCode(SQLITE_BUSY))
        XCTAssertTrue(SQLiteEngineError.isCorruptionCode(SQLITE_CORRUPT))
        XCTAssertTrue(SQLiteEngineError.isCorruptionCode(SQLITE_NOTADB))

        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let corruptURL = dir.appendingPathComponent("broken.db")
        try Data("not-a-valid-sqlite-database-header-at-all".utf8).write(to: corruptURL)

        XCTAssertThrowsError(try SQLiteConnection.open(at: corruptURL)) { err in
            XCTAssertEqual((err as? SQLiteEngineError)?.isCorruption, true)
        }

        let moved = SQLiteConnection.quarantineCorruptDatabase(at: corruptURL)
        XCTAssertNotNil(moved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: corruptURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved!.path))

        // Fresh DB now opens cleanly at the original path
        let fresh = try SQLiteConnection.open(at: corruptURL)
        defer { fresh.close() }
        XCTAssertEqual(try fresh.pragmaString("journal_mode").lowercased(), "wal")
    }
}
