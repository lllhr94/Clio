import Foundation
import SQLite3

/// Configuration for opening a Clio SQLite database via `SQLiteConnection`.
public struct SQLiteOpenOptions: Sendable {
    public var busyTimeoutMs: Int32
    public var enableWAL: Bool
    public var enableForeignKeys: Bool
    public var synchronousNormal: Bool
    public var applyFileProtection: Bool
    public var excludeFromBackup: Bool

    public init(
        busyTimeoutMs: Int32 = 5_000,
        enableWAL: Bool = true,
        enableForeignKeys: Bool = true,
        synchronousNormal: Bool = true,
        applyFileProtection: Bool = true,
        excludeFromBackup: Bool = false
    ) {
        self.busyTimeoutMs = busyTimeoutMs
        self.enableWAL = enableWAL
        self.enableForeignKeys = enableForeignKeys
        self.synchronousNormal = synchronousNormal
        self.applyFileProtection = applyFileProtection
        self.excludeFromBackup = excludeFromBackup
    }
}

/// Typed SQLite engine errors distinguishing transient lock contention from structural corruption.
public enum SQLiteEngineError: Error, LocalizedError, Equatable, Sendable {
    case openFailed(code: Int32, message: String)
    case execFailed(code: Int32, sql: String, message: String)
    case prepareFailed(code: Int32, sql: String, message: String)
    case bindFailed(code: Int32, index: Int32, message: String)
    case stepFailed(code: Int32, message: String)
    case busy(code: Int32, message: String)
    case corrupted(code: Int32, message: String)

    /// Returns `true` for transient lock contention (`SQLITE_BUSY` / `SQLITE_LOCKED`).
    /// Callers MUST retry with backoff and MUST NEVER delete or quarantine the database on transient lock errors.
    public static func isTransientLockCode(_ code: Int32) -> Bool {
        let primary = code & 0xFF
        return primary == SQLITE_BUSY || primary == SQLITE_LOCKED
    }

    /// Returns `true` ONLY for confirmed structural corruption (`SQLITE_CORRUPT` / `SQLITE_NOTADB`).
    public static func isCorruptionCode(_ code: Int32) -> Bool {
        let primary = code & 0xFF
        return primary == SQLITE_CORRUPT || primary == SQLITE_NOTADB
    }

    public var isTransientLock: Bool {
        if case .busy = self { return true }
        return false
    }

    public var isCorruption: Bool {
        if case .corrupted = self { return true }
        return false
    }

    public var errorDescription: String? {
        switch self {
        case .openFailed(let code, let message):
            return "SQLite open failed (\(code)): \(message)"
        case .execFailed(let code, _, let message):
            return "SQLite exec failed (\(code)): \(message)"
        case .prepareFailed(let code, _, let message):
            return "SQLite prepare failed (\(code)): \(message)"
        case .bindFailed(let code, let index, let message):
            return "SQLite bind failed at \(index) (\(code)): \(message)"
        case .stepFailed(let code, let message):
            return "SQLite step failed (\(code)): \(message)"
        case .busy(let code, let message):
            return "SQLite busy (\(code)): \(message)"
        case .corrupted(let code, let message):
            return "SQLite corrupted (\(code)): \(message)"
        }
    }
}

/// RAII wrapper around a compiled `sqlite3_stmt` with typed parameter binding and column readers.
public final class SQLiteStatement {
    private static let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private var handle: OpaquePointer?
    private let db: OpaquePointer

    fileprivate init(handle: OpaquePointer, db: OpaquePointer) {
        self.handle = handle
        self.db = db
    }

    deinit {
        finalize()
    }

    public func finalize() {
        if let h = handle {
            sqlite3_finalize(h)
            handle = nil
        }
    }

    public func reset() throws {
        guard let h = handle else { throw SQLiteEngineError.stepFailed(code: SQLITE_MISUSE, message: "Statement finalized") }
        let rc = sqlite3_reset(h)
        if rc != SQLITE_OK {
            throw classify(code: rc, fallback: .stepFailed(code: rc, message: lastErrorMessage()))
        }
        sqlite3_clear_bindings(h)
    }

    public func bind(_ value: String, at index: Int32) throws {
        guard let h = handle else { throw SQLiteEngineError.bindFailed(code: SQLITE_MISUSE, index: index, message: "Statement finalized") }
        let rc = sqlite3_bind_text(h, index, value, -1, Self.transientDestructor)
        if rc != SQLITE_OK {
            throw SQLiteEngineError.bindFailed(code: rc, index: index, message: lastErrorMessage())
        }
    }

    public func bind(_ value: String?, at index: Int32) throws {
        if let value {
            try bind(value, at: index)
        } else {
            try bindNull(at: index)
        }
    }

    public func bind(_ value: Int32, at index: Int32) throws {
        guard let h = handle else { throw SQLiteEngineError.bindFailed(code: SQLITE_MISUSE, index: index, message: "Statement finalized") }
        let rc = sqlite3_bind_int(h, index, value)
        if rc != SQLITE_OK {
            throw SQLiteEngineError.bindFailed(code: rc, index: index, message: lastErrorMessage())
        }
    }

    public func bind(_ value: Int64, at index: Int32) throws {
        guard let h = handle else { throw SQLiteEngineError.bindFailed(code: SQLITE_MISUSE, index: index, message: "Statement finalized") }
        let rc = sqlite3_bind_int64(h, index, value)
        if rc != SQLITE_OK {
            throw SQLiteEngineError.bindFailed(code: rc, index: index, message: lastErrorMessage())
        }
    }

    public func bind(_ value: Bool, at index: Int32) throws {
        try bind(Int32(value ? 1 : 0), at: index)
    }

    public func bindNull(at index: Int32) throws {
        guard let h = handle else { throw SQLiteEngineError.bindFailed(code: SQLITE_MISUSE, index: index, message: "Statement finalized") }
        let rc = sqlite3_bind_null(h, index)
        if rc != SQLITE_OK {
            throw SQLiteEngineError.bindFailed(code: rc, index: index, message: lastErrorMessage())
        }
    }

    /// Advances the statement by one row. Returns `true` if a row is ready (`SQLITE_ROW`),
    /// or `false` when finished (`SQLITE_DONE`).
    @discardableResult
    public func step() throws -> Bool {
        guard let h = handle else { throw SQLiteEngineError.stepFailed(code: SQLITE_MISUSE, message: "Statement finalized") }
        let rc = sqlite3_step(h)
        if rc == SQLITE_ROW { return true }
        if rc == SQLITE_DONE { return false }
        throw classify(code: rc, fallback: .stepFailed(code: rc, message: lastErrorMessage()))
    }

    public func string(at column: Int32) -> String? {
        guard let h = handle, let raw = sqlite3_column_text(h, column) else { return nil }
        return String(cString: raw)
    }

    public func int32(at column: Int32) -> Int32 {
        guard let h = handle else { return 0 }
        return sqlite3_column_int(h, column)
    }

    public func int64(at column: Int32) -> Int64 {
        guard let h = handle else { return 0 }
        return sqlite3_column_int64(h, column)
    }

    private func lastErrorMessage() -> String {
        sqlite3_errmsg(db).map { String(cString: $0) } ?? "unknown sqlite error"
    }

    private func classify(code: Int32, fallback: SQLiteEngineError) -> SQLiteEngineError {
        let msg = lastErrorMessage()
        if SQLiteEngineError.isCorruptionCode(code) { return .corrupted(code: code, message: msg) }
        if SQLiteEngineError.isTransientLockCode(code) { return .busy(code: code, message: msg) }
        return fallback
    }
}

/// Shared zero-dependency SQLite connection wrapper enforcing FULLMUTEX, WAL, busy_timeout,
/// file protection, transactional rollback, schema versioning, and safe corruption quarantine.
public final class SQLiteConnection {
    public let url: URL
    private var handle: OpaquePointer?

    private init(url: URL, handle: OpaquePointer) {
        self.url = url
        self.handle = handle
    }

    deinit {
        close()
    }

    public func close() {
        if let h = handle {
            sqlite3_close_v2(h)
            handle = nil
        }
    }

    /// Opens or creates a SQLite database with Clio's standard safety pragmas and file attributes.
    public static func open(at url: URL, options: SQLiteOpenOptions = .init()) throws -> SQLiteConnection {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var raw: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let openRC = sqlite3_open_v2(url.path, &raw, flags, nil)
        guard openRC == SQLITE_OK, let db = raw else {
            let msg = raw.flatMap { sqlite3_errmsg($0).map { String(cString: $0) } } ?? "open failed"
            if let raw { sqlite3_close_v2(raw) }
            if SQLiteEngineError.isCorruptionCode(openRC) {
                throw SQLiteEngineError.corrupted(code: openRC, message: msg)
            }
            if SQLiteEngineError.isTransientLockCode(openRC) {
                throw SQLiteEngineError.busy(code: openRC, message: msg)
            }
            throw SQLiteEngineError.openFailed(code: openRC, message: msg)
        }

        let conn = SQLiteConnection(url: url, handle: db)
        sqlite3_busy_timeout(db, options.busyTimeoutMs)
        if options.enableWAL {
            try conn.execute("PRAGMA journal_mode = WAL;")
        }
        if options.synchronousNormal {
            try conn.execute("PRAGMA synchronous = NORMAL;")
        }
        if options.enableForeignKeys {
            try conn.execute("PRAGMA foreign_keys = ON;")
        }
        Self.applyFileAttributes(at: url, options: options)
        return conn
    }

    /// Applies iOS file protection and optional iCloud backup exclusion to the database and WAL/SHM sidecars.
    public static func applyFileAttributes(at url: URL, options: SQLiteOpenOptions) {
        let paths = [url, URL(fileURLWithPath: url.path + "-wal"), URL(fileURLWithPath: url.path + "-shm")]
        let fm = FileManager.default
        for item in paths where fm.fileExists(atPath: item.path) {
            #if os(iOS)
            if options.applyFileProtection {
                try? fm.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: item.path
                )
            }
            #endif
            if options.excludeFromBackup {
                var mutableURL = item
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? mutableURL.setResourceValues(values)
            }
        }
    }

    /// Moves a confirmed corrupt database and its WAL/SHM sidecars aside to `.corrupt-<timestamp>`
    /// so user forensics are preserved and a fresh database can be rebuilt cleanly.
    /// NEVER call this on transient lock (`SQLITE_BUSY` / `SQLITE_LOCKED`) errors.
    @discardableResult
    public static func quarantineCorruptDatabase(at url: URL, now: Date = Date()) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        let stamp = Int64(now.timeIntervalSince1970 * 1000)
        let quarantined = URL(fileURLWithPath: "\(url.path).corrupt-\(stamp)")
        do {
            try fm.moveItem(at: url, to: quarantined)
            for suffix in ["-wal", "-shm", "-journal"] {
                let sidecar = URL(fileURLWithPath: url.path + suffix)
                if fm.fileExists(atPath: sidecar.path) {
                    let target = URL(fileURLWithPath: quarantined.path + suffix)
                    try? fm.moveItem(at: sidecar, to: target)
                }
            }
            return quarantined
        } catch {
            return nil
        }
    }

    public func execute(_ sql: String, maxBusyRetries: Int = 3) throws {
        let db = try requireHandle()
        var attempt = 0
        while true {
            var errPtr: UnsafeMutablePointer<CChar>?
            let rc = sqlite3_exec(db, sql, nil, nil, &errPtr)
            if rc == SQLITE_OK { return }
            let msg = errPtr.map { String(cString: $0) } ?? lastErrorMessage(db)
            if let errPtr { sqlite3_free(errPtr) }
            if SQLiteEngineError.isTransientLockCode(rc) && attempt < maxBusyRetries {
                attempt += 1
                Thread.sleep(forTimeInterval: 0.02 * Double(attempt))
                continue
            }
            if SQLiteEngineError.isCorruptionCode(rc) {
                throw SQLiteEngineError.corrupted(code: rc, message: msg)
            }
            if SQLiteEngineError.isTransientLockCode(rc) {
                throw SQLiteEngineError.busy(code: rc, message: msg)
            }
            throw SQLiteEngineError.execFailed(code: rc, sql: sql, message: msg)
        }
    }

    public func prepare(_ sql: String) throws -> SQLiteStatement {
        let db = try requireHandle()
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            let msg = lastErrorMessage(db)
            if SQLiteEngineError.isCorruptionCode(rc) {
                throw SQLiteEngineError.corrupted(code: rc, message: msg)
            }
            if SQLiteEngineError.isTransientLockCode(rc) {
                throw SQLiteEngineError.busy(code: rc, message: msg)
            }
            throw SQLiteEngineError.prepareFailed(code: rc, sql: sql, message: msg)
        }
        return SQLiteStatement(handle: stmt, db: db)
    }

    public func withTransaction<T>(immediate: Bool = true, _ body: (SQLiteConnection) throws -> T) throws -> T {
        try execute(immediate ? "BEGIN IMMEDIATE;" : "BEGIN;")
        do {
            let result = try body(self)
            try execute("COMMIT;")
            return result
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    public func userVersion() throws -> Int32 {
        let stmt = try prepare("PRAGMA user_version;")
        defer { stmt.finalize() }
        guard try stmt.step() else { return 0 }
        return stmt.int32(at: 0)
    }

    public func setUserVersion(_ version: Int32) throws {
        try execute("PRAGMA user_version = \(version);")
    }

    /// Runs ordered `user_version` migrations atomically; skips steps already applied.
    public func migrate(steps: [(version: Int32, apply: (SQLiteConnection) throws -> Void)]) throws {
        let current = try userVersion()
        for step in steps.sorted(by: { $0.version < $1.version }) where step.version > current {
            try withTransaction(immediate: true) { conn in
                try step.apply(conn)
                try conn.setUserVersion(step.version)
            }
        }
    }

    public func pragmaString(_ name: String) throws -> String {
        let stmt = try prepare("PRAGMA \(name);")
        defer { stmt.finalize() }
        guard try stmt.step() else { return "" }
        return stmt.string(at: 0) ?? ""
    }

    public func pragmaInt32(_ name: String) throws -> Int32 {
        let stmt = try prepare("PRAGMA \(name);")
        defer { stmt.finalize() }
        guard try stmt.step() else { return 0 }
        return stmt.int32(at: 0)
    }

    private func requireHandle() throws -> OpaquePointer {
        guard let h = handle else {
            throw SQLiteEngineError.openFailed(code: SQLITE_MISUSE, message: "Connection is closed")
        }
        return h
    }

    private func lastErrorMessage(_ db: OpaquePointer) -> String {
        sqlite3_errmsg(db).map { String(cString: $0) } ?? "unknown sqlite error"
    }
}
