import Foundation
import SQLite3
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Identifies a single conversation storage slot (`leafID == ""` for live chat).
public struct MemoryIndexSlotKey: Hashable, Sendable, Equatable {
    public var chatKey: String
    public var leafID: String

    public init(chatKey: String, leafID: String = "") {
        self.chatKey = chatKey
        self.leafID = leafID
    }
}

/// SQL-layer access scope & isolation policy enforced directly inside SQLite `WHERE` predicates.
public struct MemoryAccessContext: Sendable, Equatable {
    public var callerChatKey: String
    public var allowTainted: Bool
    public var allowDelegated: Bool
    public var allowNotes: Bool
    public var allowedRoles: Set<String>
    public var allowedChatKeys: Set<String>?
    public var excludedChatKeys: Set<String>
    public var excludedThreadKeys: Set<String>
    public var includeOtherChats: Bool
    public var includeLeaves: Bool
    public var limit: Int

    public init(
        callerChatKey: String,
        allowTainted: Bool = false,
        allowDelegated: Bool = false,
        allowNotes: Bool = false,
        allowedRoles: Set<String> = ["user", "assistant"],
        allowedChatKeys: Set<String>? = nil,
        excludedChatKeys: Set<String> = [],
        excludedThreadKeys: Set<String> = [],
        includeOtherChats: Bool = false,
        includeLeaves: Bool = true,
        limit: Int = 8
    ) {
        self.callerChatKey = callerChatKey
        self.allowTainted = allowTainted
        self.allowDelegated = allowDelegated
        self.allowNotes = allowNotes
        self.allowedRoles = allowedRoles
        self.allowedChatKeys = allowedChatKeys
        self.excludedChatKeys = excludedChatKeys
        self.excludedThreadKeys = excludedThreadKeys
        self.includeOtherChats = includeOtherChats
        self.includeLeaves = includeLeaves
        self.limit = max(1, min(100, limit))
    }

    /// Standard agent tool query scope: strictly excludes tainted, delegated, and note entries at SQL level.
    public static func toolSearch(
        chatKey: String,
        allowCrossChat: Bool = false,
        allowedChatKeys: Set<String>? = nil,
        excludedChatKeys: Set<String> = [],
        excludedThreadKeys: Set<String> = [],
        includeLeaves: Bool = true,
        limit: Int = 8
    ) -> MemoryAccessContext {
        MemoryAccessContext(
            callerChatKey: chatKey,
            allowTainted: false,
            allowDelegated: false,
            allowNotes: false,
            allowedRoles: ["user", "assistant"],
            allowedChatKeys: allowedChatKeys,
            excludedChatKeys: excludedChatKeys,
            excludedThreadKeys: excludedThreadKeys,
            includeOtherChats: allowCrossChat,
            includeLeaves: includeLeaves,
            limit: max(1, min(20, limit))
        )
    }

    /// Strict scope for a delegated helper companion: current chat only, no cross-chat access, no tainted/delegated rows.
    public static func delegatedToolSearch(
        chatKey: String,
        allowedChatKeys: Set<String>? = nil,
        excludedChatKeys: Set<String> = [],
        limit: Int = 8
    ) -> MemoryAccessContext {
        MemoryAccessContext(
            callerChatKey: chatKey,
            allowTainted: false,
            allowDelegated: false,
            allowNotes: false,
            allowedRoles: ["user", "assistant"],
            allowedChatKeys: allowedChatKeys,
            excludedChatKeys: excludedChatKeys,
            excludedThreadKeys: [],
            includeOtherChats: false,
            includeLeaves: false,
            limit: max(1, min(20, limit))
        )
    }

    /// Diagnostic / maintenance query preset with strict defaults unless explicitly broadened by caller.
    public static func internalDiagnostic(
        chatKey: String? = nil,
        allowTainted: Bool = false,
        allowDelegated: Bool = false,
        allowNotes: Bool = false,
        allowedChatKeys: Set<String>? = nil,
        limit: Int = 20
    ) -> MemoryAccessContext {
        MemoryAccessContext(
            callerChatKey: chatKey ?? "",
            allowTainted: allowTainted,
            allowDelegated: allowDelegated,
            allowNotes: allowNotes,
            allowedRoles: ["user", "assistant"],
            allowedChatKeys: allowedChatKeys,
            excludedChatKeys: [],
            excludedThreadKeys: [],
            includeOtherChats: chatKey == nil,
            includeLeaves: true,
            limit: max(1, min(50, limit))
        )
    }
}

/// Canonical conversation entry payload passed into the derived SQLite index.
public struct MemoryIndexRecord: Sendable, Equatable {
    public var chatKey: String
    public var chatName: String
    public var leafID: String
    public var leafTitle: String
    public var entryID: String
    public var role: String
    public var atMs: Double
    public var tainted: Bool
    public var delegated: Bool
    public var isNote: Bool
    public var text: String

    public init(
        chatKey: String,
        chatName: String,
        leafID: String = "",
        leafTitle: String = "",
        entryID: String,
        role: String,
        atMs: Double,
        tainted: Bool = false,
        delegated: Bool = false,
        isNote: Bool = false,
        text: String
    ) {
        self.chatKey = chatKey
        self.chatName = chatName
        self.leafID = leafID
        self.leafTitle = leafTitle
        self.entryID = entryID
        self.role = role
        self.atMs = atMs
        self.tainted = tainted
        self.delegated = delegated
        self.isNote = isNote
        self.text = text
    }
}

/// Matched conversation excerpt returned directly from a SQL-isolated index query.
public struct MemoryIndexHit: Sendable, Equatable, Identifiable {
    public var id: String { "\(chatKey)|\(leafID)|\(entryID)" }
    public var chatKey: String
    public var chatName: String
    public var leafID: String
    public var leafTitle: String
    public var entryID: String
    public var role: String
    public var atMs: Double
    public var tainted: Bool
    public var delegated: Bool
    public var isNote: Bool
    public var snippet: String
    public var score: Double

    public init(
        chatKey: String,
        chatName: String,
        leafID: String,
        leafTitle: String,
        entryID: String,
        role: String,
        atMs: Double,
        tainted: Bool,
        delegated: Bool,
        isNote: Bool,
        snippet: String,
        score: Double
    ) {
        self.chatKey = chatKey
        self.chatName = chatName
        self.leafID = leafID
        self.leafTitle = leafTitle
        self.entryID = entryID
        self.role = role
        self.atMs = atMs
        self.tainted = tainted
        self.delegated = delegated
        self.isNote = isNote
        self.snippet = snippet
        self.score = score
    }
}

public struct MemoryIndexBuildState: Sendable, Equatable {
    public var state: String
    public var schemaVersion: Int32
    public var lastBuiltAt: String
    public var sourceFingerprint: String
    public var indexedCount: Int
    public var fts5Active: Bool

    public init(
        state: String,
        schemaVersion: Int32,
        lastBuiltAt: String,
        sourceFingerprint: String,
        indexedCount: Int,
        fts5Active: Bool
    ) {
        self.state = state
        self.schemaVersion = schemaVersion
        self.lastBuiltAt = lastBuiltAt
        self.sourceFingerprint = sourceFingerprint
        self.indexedCount = indexedCount
        self.fts5Active = fts5Active
    }
}

public enum MemoryIndexRecoveryReason: String, Sendable, Equatable {
    case none
    case missing
    case externalDeletion
    case corrupt
    case schemaMismatch
    case incompleteBuild
}

public enum MemoryIndexError: Error, Equatable, Sendable {
    case openFailed(code: Int32, message: String)
    case sqlite(code: Int32, message: String)
    case missingColumn(String)
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private final class SQLTraceSink: @unchecked Sendable {
    private let lock = NSLock()
    var enabled = false
    var statements: [String] = []

    func isEnabled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled
    }

    func setEnabled(_ flag: Bool) {
        lock.lock()
        enabled = flag
        if !flag { statements.removeAll() }
        lock.unlock()
    }

    func record(_ sql: String) {
        lock.lock()
        if enabled {
            if statements.count >= 256 { statements.removeFirst() }
            statements.append(sql)
        }
        lock.unlock()
    }

    func drain() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let copy = statements
        statements.removeAll()
        return copy
    }
}

private func memoryIndexSQLiteTraceCallback(
    _ event: UInt32,
    _ context: UnsafeMutableRawPointer?,
    _ p: UnsafeMutableRawPointer?,
    _ x: UnsafeMutableRawPointer?
) -> Int32 {
    guard event == UInt32(SQLITE_TRACE_STMT), let context else { return 0 }
    let sink = Unmanaged<SQLTraceSink>.fromOpaque(context).takeUnretainedValue()
    guard sink.isEnabled() else { return 0 }
    if let p {
        let stmt = OpaquePointer(p)
        if let expanded = sqlite3_expanded_sql(stmt) {
            sink.record(String(cString: expanded))
            sqlite3_free(expanded)
            return 0
        }
        if let raw = sqlite3_sql(stmt) {
            sink.record(String(cString: raw))
            return 0
        }
    }
    if let x {
        sink.record(String(cString: x.assumingMemoryBound(to: CChar.self)))
    }
    return 0
}

/// Thread-safe, self-healing, read-only rebuildable SQLite3 + FTS5 derived search index for conversation history.
public final class MemoryIndexDatabase: @unchecked Sendable {
    public static let schemaVersion: Int32 = 2
    private static let maxStoredSnippetBytes = 16_384

    public static var isFTS5Supported: Bool {
        sqlite3_compileoption_used("ENABLE_FTS5") != 0
    }

    public let databaseURL: URL
    private let forceDisableFTS5ForTesting: Bool
    private let lock = NSLock()
    private let traceSink = SQLTraceSink()

    private var db: OpaquePointer?
    private var openedIdentity: FileIdentity?
    private var fts5Active: Bool
    private var _lastRecoveryReason: MemoryIndexRecoveryReason = .none
    private var _needsRebuildFromSource: Bool = false

    private struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    private enum SQLBinding {
        case text(String)
        case int(Int32)
        case int64(Int64)
        case double(Double)
    }

    public init(databaseURL: URL, forceDisableFTS5ForTesting: Bool = false) {
        self.databaseURL = databaseURL
        self.forceDisableFTS5ForTesting = forceDisableFTS5ForTesting
        self.fts5Active = !forceDisableFTS5ForTesting && Self.isFTS5Supported
    }

    deinit {
        lock.lock()
        closeLocked()
        lock.unlock()
    }

    public var lastRecoveryReason: MemoryIndexRecoveryReason {
        lock.lock()
        defer { lock.unlock() }
        return _lastRecoveryReason
    }

    public var needsRebuildFromSource: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _needsRebuildFromSource
    }

    public var isFTS5Active: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fts5Active
    }

    public func setSQLTraceEnabled(_ enabled: Bool) {
        traceSink.setEnabled(enabled)
    }

    public func drainSQLTrace() -> [String] {
        traceSink.drain()
    }

    /// Opens the index database if valid, or self-heals by unlinking DB + WAL/SHM sidecars and recreating fresh schema.
    @discardableResult
    public func openOrRecover() throws -> MemoryIndexRecoveryReason {
        lock.lock()
        defer { lock.unlock() }
        return try openOrRecoverLocked()
    }

    /// Returns the current `build_state` snapshot and row count.
    public func buildState() throws -> MemoryIndexBuildState {
        lock.lock()
        defer { lock.unlock() }
        _ = try openOrRecoverLocked()
        let values = try readBuildStateMapLocked()
        let count = try countRowsLocked(whereSQL: nil)
        let schemaVer = Int32(values["schema_version"] ?? "") ?? 0
        return MemoryIndexBuildState(
            state: values["state"] ?? "missing",
            schemaVersion: schemaVer,
            lastBuiltAt: values["last_built_at"] ?? "",
            sourceFingerprint: values["source_fingerprint"] ?? "",
            indexedCount: count,
            fts5Active: fts5Active
        )
    }

    /// Atomically replaces the entire derived index from canonical records, redacting any provided secrets first.
    public func rebuild(
        records: [MemoryIndexRecord],
        sourceFingerprint: String,
        slotDigests: [MemoryIndexSlotKey: String] = [:],
        secrets: [String] = []
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        _ = try openOrRecoverLocked()

        let orderedSecrets = secrets.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        let nowString = Self.timestampString(Date())

        do {
            // Commit `building` first so an interrupted crash mid-rebuild is detected and self-healed on next open.
            try execLocked("BEGIN IMMEDIATE;")
            do {
                try setBuildStateLocked("state", "building")
                try setBuildStateLocked("schema_version", String(Self.schemaVersion))
                try execLocked("COMMIT;")
            } catch {
                try? execLocked("ROLLBACK;")
                throw error
            }

            try execLocked("BEGIN IMMEDIATE;")
            do {
                try execLocked("DELETE FROM messages_meta;")
                try execLocked("DELETE FROM slot_versions;")
                try insertRecordsLocked(records, orderedSecrets: orderedSecrets)
                for (slotKey, digest) in slotDigests {
                    try setSlotVersionLocked(chatKey: slotKey.chatKey, leafID: slotKey.leafID, digest: digest)
                }
                try setBuildStateLocked("state", "ready")
                try setBuildStateLocked("schema_version", String(Self.schemaVersion))
                try setBuildStateLocked("last_built_at", nowString)
                try setBuildStateLocked("source_fingerprint", sourceFingerprint)
                try setBuildStateLocked("fts5_enabled", fts5Active ? "1" : "0")
                try execLocked("COMMIT;")
                _needsRebuildFromSource = false
            } catch {
                try? execLocked("ROLLBACK;")
                throw error
            }
        } catch {
            if isCorruptionError(error) {
                try? recreateFreshDatabaseLocked(reason: .corrupt)
            }
            throw error
        }
    }

    /// Replaces all rows for a single `(chatKey, leafID)` slot inside an atomic transaction without stamping full catalog fingerprint.
    public func replaceSlot(
        chatKey: String,
        leafID: String = "",
        records: [MemoryIndexRecord],
        slotDigest: String? = nil,
        secrets: [String] = []
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        _ = try openOrRecoverLocked()

        let orderedSecrets = secrets.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        do {
            try execLocked("BEGIN IMMEDIATE;")
            do {
                try deleteSlotLocked(chatKey: chatKey, leafID: leafID)
                try insertRecordsLocked(records, orderedSecrets: orderedSecrets)
                if let slotDigest {
                    try setSlotVersionLocked(chatKey: chatKey, leafID: leafID, digest: slotDigest)
                }
                try execLocked("COMMIT;")
            } catch {
                try? execLocked("ROLLBACK;")
                throw error
            }
        } catch {
            if isCorruptionError(error) {
                try? recreateFreshDatabaseLocked(reason: .corrupt)
            }
            throw error
        }
    }

    /// Updates `leaf_title` for an existing shelved leaf after redacting secrets, without stamping catalog fingerprint.
    public func updateLeafTitle(
        chatKey: String,
        leafID: String,
        leafTitle: String,
        slotDigest: String? = nil,
        secrets: [String] = []
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        _ = try openOrRecoverLocked()

        let orderedSecrets = secrets.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        let safeLeafTitle = orderedSecrets.isEmpty
            ? leafTitle
            : MemorySafety.redactSecrets(leafTitle, secrets: orderedSecrets)

        do {
            try execLocked("BEGIN IMMEDIATE;")
            do {
                try runPreparedLocked(
                    "UPDATE messages_meta SET leaf_title = ? WHERE chat_key = ? AND leaf_id = ?;",
                    bindings: [.text(safeLeafTitle), .text(chatKey), .text(leafID)]
                )
                if let slotDigest {
                    try setSlotVersionLocked(chatKey: chatKey, leafID: leafID, digest: slotDigest)
                }
                try execLocked("COMMIT;")
            } catch {
                try? execLocked("ROLLBACK;")
                throw error
            }
        } catch {
            if isCorruptionError(error) {
                try? recreateFreshDatabaseLocked(reason: .corrupt)
            }
            throw error
        }
    }

    /// Deletes indexed rows and slot digests for a live chat, a specific leaf, or an entire conversation and all its leaves.
    public func deleteChat(
        chatKey: String,
        includingLeaves: Bool = true,
        leafID: String? = nil
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        _ = try openOrRecoverLocked()

        do {
            try execLocked("BEGIN IMMEDIATE;")
            do {
                if let leafID {
                    try deleteSlotLocked(chatKey: chatKey, leafID: leafID)
                    try deleteSlotVersionLocked(chatKey: chatKey, leafID: leafID)
                } else if includingLeaves {
                    try runPreparedLocked(
                        "DELETE FROM messages_meta WHERE chat_key = ?;",
                        bindings: [.text(chatKey)]
                    )
                    try runPreparedLocked(
                        "DELETE FROM slot_versions WHERE chat_key = ?;",
                        bindings: [.text(chatKey)]
                    )
                } else {
                    try deleteSlotLocked(chatKey: chatKey, leafID: "")
                    try deleteSlotVersionLocked(chatKey: chatKey, leafID: "")
                }
                try execLocked("COMMIT;")
            } catch {
                try? execLocked("ROLLBACK;")
                throw error
            }
        } catch {
            if isCorruptionError(error) {
                try? recreateFreshDatabaseLocked(reason: .corrupt)
            }
            throw error
        }
    }

    /// Removes indexed rows and slot digests belonging to conversations no longer present in `validChatKeys`.
    public func pruneMissingChats(validChatKeys: Set<String>) throws {
        lock.lock()
        defer { lock.unlock() }
        _ = try openOrRecoverLocked()

        do {
            try execLocked("BEGIN IMMEDIATE;")
            do {
                if validChatKeys.isEmpty {
                    try execLocked("DELETE FROM messages_meta;")
                    try execLocked("DELETE FROM slot_versions;")
                } else {
                    let sorted = validChatKeys.sorted()
                    let placeholders = Array(repeating: "?", count: sorted.count).joined(separator: ", ")
                    let bindings = sorted.map { SQLBinding.text($0) }
                    try runPreparedLocked("DELETE FROM messages_meta WHERE chat_key NOT IN (\(placeholders));", bindings: bindings)
                    try runPreparedLocked("DELETE FROM slot_versions WHERE chat_key NOT IN (\(placeholders));", bindings: bindings)
                }
                try execLocked("COMMIT;")
            } catch {
                try? execLocked("ROLLBACK;")
                throw error
            }
        } catch {
            if isCorruptionError(error) {
                try? recreateFreshDatabaseLocked(reason: .corrupt)
            }
            throw error
        }
    }

    public func readSlotVersions() throws -> [MemoryIndexSlotKey: String] {
        lock.lock()
        defer { lock.unlock() }
        _ = try openOrRecoverLocked()
        return try readSlotVersionsLocked()
    }

    public func updateSourceFingerprint(_ fingerprint: String) throws {
        lock.lock()
        defer { lock.unlock() }
        _ = try openOrRecoverLocked()
        try execLocked("BEGIN IMMEDIATE;")
        do {
            try setBuildStateLocked("source_fingerprint", fingerprint)
            try execLocked("COMMIT;")
        } catch {
            try? execLocked("ROLLBACK;")
            throw error
        }
    }

    /// Searches conversation history enforcing all `MemoryAccessContext` rules inside the SQLite `WHERE` clause.
    public func search(query: String, context: MemoryAccessContext) throws -> [MemoryIndexHit] {
        lock.lock()
        defer { lock.unlock() }
        _ = try openOrRecoverLocked()

        var whereClauses: [String] = []
        var bindings: [SQLBinding] = []

        if fts5Active {
            guard let matchExpression = MemoryIndexTokenizer.fts5MatchExpression(for: query) else {
                return []
            }
            whereClauses.append("messages_fts MATCH ?")
            bindings.append(.text(matchExpression))
        } else {
            let terms = MemoryIndexTokenizer.fallbackLikeTerms(for: query)
            guard !terms.isEmpty else { return [] }
            for term in terms {
                whereClauses.append("m.normalized_text LIKE ? ESCAPE '\\'")
                bindings.append(.text("%\(Self.escapeLike(term))%"))
            }
        }

        if !context.allowTainted {
            whereClauses.append("m.tainted = 0")
        }
        if !context.allowDelegated {
            whereClauses.append("m.delegated = 0")
        }
        if !context.allowNotes {
            whereClauses.append("m.is_note = 0")
        }
        if context.allowedRoles.isEmpty {
            whereClauses.append("1 = 0")
        } else {
            let sortedRoles = context.allowedRoles.sorted()
            let placeholders = Array(repeating: "?", count: sortedRoles.count).joined(separator: ", ")
            whereClauses.append("m.role IN (\(placeholders))")
            for role in sortedRoles {
                bindings.append(.text(role))
            }
        }
        if let allowedChats = context.allowedChatKeys {
            if allowedChats.isEmpty {
                whereClauses.append("1 = 0")
            } else {
                let sortedAllowed = allowedChats.sorted()
                let placeholders = Array(repeating: "?", count: sortedAllowed.count).joined(separator: ", ")
                whereClauses.append("m.chat_key IN (\(placeholders))")
                for chatKey in sortedAllowed {
                    bindings.append(.text(chatKey))
                }
            }
        }
        if !context.includeLeaves {
            whereClauses.append("m.leaf_id = ''")
        }
        if !context.includeOtherChats {
            whereClauses.append("m.chat_key = ?")
            bindings.append(.text(context.callerChatKey))
        }
        if !context.excludedChatKeys.isEmpty {
            let sortedExcluded = context.excludedChatKeys.sorted()
            let placeholders = Array(repeating: "?", count: sortedExcluded.count).joined(separator: ", ")
            whereClauses.append("m.chat_key NOT IN (\(placeholders))")
            for excluded in sortedExcluded {
                bindings.append(.text(excluded))
            }
        }
        if !context.excludedThreadKeys.isEmpty {
            let sortedThreads = context.excludedThreadKeys.sorted()
            let placeholders = Array(repeating: "?", count: sortedThreads.count).joined(separator: ", ")
            whereClauses.append("(CASE WHEN m.leaf_id = '' THEN m.chat_key ELSE m.chat_key || '~' || m.leaf_id END) NOT IN (\(placeholders))")
            for thread in sortedThreads {
                bindings.append(.text(thread))
            }
        }

        let predicateSQL = whereClauses.joined(separator: " AND ")
        let sql: String
        if fts5Active {
            sql = """
            SELECT
                m.chat_key,
                m.chat_name,
                m.leaf_id,
                m.leaf_title,
                m.entry_id,
                m.role,
                m.at_ms,
                m.tainted,
                m.delegated,
                m.is_note,
                m.snippet_text,
                bm25(messages_fts) AS rank_score
            FROM messages_fts
            JOIN messages_meta m ON m.id = messages_fts.rowid
            WHERE \(predicateSQL)
            ORDER BY rank_score ASC, m.at_ms DESC
            LIMIT ?;
            """
        } else {
            sql = """
            SELECT
                m.chat_key,
                m.chat_name,
                m.leaf_id,
                m.leaf_title,
                m.entry_id,
                m.role,
                m.at_ms,
                m.tainted,
                m.delegated,
                m.is_note,
                m.snippet_text,
                0.0 AS rank_score
            FROM messages_meta m
            WHERE \(predicateSQL)
            ORDER BY m.at_ms DESC
            LIMIT ?;
            """
        }
        bindings.append(.int(Int32(max(1, min(100, context.limit)))))

        do {
            return try executeSearchLocked(sql: sql, bindings: bindings, query: query)
        } catch {
            if isCorruptionError(error) {
                try? recreateFreshDatabaseLocked(reason: .corrupt)
                return []
            }
            throw error
        }
    }

    public func countRows(whereSQL: String? = nil) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        _ = try openOrRecoverLocked()
        return try countRowsLocked(whereSQL: whereSQL)
    }

    /// Runs FTS5 `integrity-check` when FTS5 is active.
    public func verifyFTSIntegrity() throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        _ = try openOrRecoverLocked()
        guard fts5Active else { return true }
        try execLocked("INSERT INTO messages_fts(messages_fts) VALUES('integrity-check');")
        return true
    }

    /// Closes the SQLite handle cleanly without deleting files.
    public func close() {
        lock.lock()
        closeLocked()
        lock.unlock()
    }

    /// Closes the SQLite handle and deletes the database and its WAL/SHM/journal sidecar files.
    public func destroyFiles() {
        lock.lock()
        closeLocked()
        unlinkDatabaseFiles()
        _needsRebuildFromSource = true
        lock.unlock()
    }

    // MARK: - Private SQLite Lifecycle & Self-Healing

    private func openOrRecoverLocked() throws -> MemoryIndexRecoveryReason {
        if db != nil {
            if let currentIdentity = Self.fileIdentity(databaseURL), currentIdentity == openedIdentity {
                return .none
            }
            closeLocked()
            unlinkDatabaseFiles()
            try createFreshDatabaseLocked(reason: .externalDeletion)
            return .externalDeletion
        }

        let fm = FileManager.default
        let parentDir = databaseURL.deletingLastPathComponent()
        try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
        Self.excludeFromBackup(parentDir)

        guard fm.fileExists(atPath: databaseURL.path) else {
            unlinkDatabaseFiles()
            try createFreshDatabaseLocked(reason: .missing)
            return .missing
        }

        var candidate: OpaquePointer?
        let openRC = sqlite3_open_v2(
            databaseURL.path,
            &candidate,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openRC == SQLITE_OK, let validCandidate = candidate else {
            if let candidate { sqlite3_close_v2(candidate) }
            unlinkDatabaseFiles()
            try createFreshDatabaseLocked(reason: .corrupt)
            return .corrupt
        }

        self.db = validCandidate
        installTraceLocked()

        let recovery = validateOpenedDatabaseLocked()
        if recovery == .none {
            do {
                try configureRuntimePragmasLocked()
                self.openedIdentity = Self.fileIdentity(databaseURL)
                markSidecarsExcludedFromBackup()
                _lastRecoveryReason = .none
                return .none
            } catch {
                let reason: MemoryIndexRecoveryReason = isCorruptionError(error) ? .corrupt : .schemaMismatch
                try recreateFreshDatabaseLocked(reason: reason)
                return reason
            }
        } else {
            try recreateFreshDatabaseLocked(reason: recovery)
            return recovery
        }
    }

    private func validateOpenedDatabaseLocked() -> MemoryIndexRecoveryReason {
        do {
            try execLocked("PRAGMA busy_timeout = 5000;")

            let check = try scalarStringLocked("PRAGMA quick_check(1);")
            guard check == "ok" else {
                return .corrupt
            }

            let userVer = try scalarInt32Locked("PRAGMA user_version;")
            guard userVer == Self.schemaVersion else {
                return .schemaMismatch
            }

            let expectedTables: Set<String> = fts5Active
                ? ["build_state", "slot_versions", "messages_meta", "messages_fts"]
                : ["build_state", "slot_versions", "messages_meta"]
            let foundTables = try existingTableNamesLocked()
            guard expectedTables.isSubset(of: foundTables) else {
                return .schemaMismatch
            }

            let stateMap = try readBuildStateMapLocked()
            guard stateMap["state"] == "ready" else {
                return .incompleteBuild
            }
            guard stateMap["schema_version"] == String(Self.schemaVersion) else {
                return .schemaMismatch
            }
            let expectedFTSFlag = fts5Active ? "1" : "0"
            guard stateMap["fts5_enabled"] == expectedFTSFlag else {
                return .schemaMismatch
            }
            return .none
        } catch {
            return isCorruptionError(error) ? .corrupt : .schemaMismatch
        }
    }

    private func recreateFreshDatabaseLocked(reason: MemoryIndexRecoveryReason) throws {
        closeLocked()
        unlinkDatabaseFiles()
        try createFreshDatabaseLocked(reason: reason)
    }

    private func createFreshDatabaseLocked(reason: MemoryIndexRecoveryReason) throws {
        let fm = FileManager.default
        let parentDir = databaseURL.deletingLastPathComponent()
        try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
        Self.excludeFromBackup(parentDir)

        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(
            databaseURL.path,
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard rc == SQLITE_OK, let opened = handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown open error"
            if let handle { sqlite3_close_v2(handle) }
            throw MemoryIndexError.openFailed(code: rc, message: msg)
        }

        self.db = opened
        installTraceLocked()

        do {
            try configureRuntimePragmasLocked()
            try createSchemaLocked()
            self.openedIdentity = Self.fileIdentity(databaseURL)
            markSidecarsExcludedFromBackup()
            _lastRecoveryReason = reason
            _needsRebuildFromSource = true
        } catch {
            closeLocked()
            unlinkDatabaseFiles()
            throw error
        }
    }

    private func configureRuntimePragmasLocked() throws {
        try execLocked("PRAGMA busy_timeout = 5000;")
        try execLocked("PRAGMA journal_mode = WAL;")
        try execLocked("PRAGMA synchronous = NORMAL;")
        try execLocked("PRAGMA foreign_keys = ON;")
    }

    private func createSchemaLocked() throws {
        try execLocked("BEGIN IMMEDIATE;")
        do {
            try execLocked("""
            CREATE TABLE build_state (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            """)
            try execLocked("""
            CREATE TABLE slot_versions (
                chat_key TEXT NOT NULL,
                leaf_id TEXT NOT NULL DEFAULT '',
                slot_digest TEXT NOT NULL,
                PRIMARY KEY (chat_key, leaf_id)
            );
            """)
            try execLocked("""
            CREATE TABLE messages_meta (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                chat_key TEXT NOT NULL,
                chat_name TEXT NOT NULL,
                leaf_id TEXT NOT NULL DEFAULT '',
                leaf_title TEXT NOT NULL DEFAULT '',
                entry_id TEXT NOT NULL,
                role TEXT NOT NULL,
                at_ms REAL NOT NULL,
                tainted INTEGER NOT NULL DEFAULT 0 CHECK (tainted IN (0, 1)),
                delegated INTEGER NOT NULL DEFAULT 0 CHECK (delegated IN (0, 1)),
                is_note INTEGER NOT NULL DEFAULT 0 CHECK (is_note IN (0, 1)),
                snippet_text TEXT NOT NULL,
                normalized_text TEXT NOT NULL DEFAULT '',
                body_tokens TEXT NOT NULL DEFAULT '',
                cjk_unigrams TEXT NOT NULL DEFAULT '',
                UNIQUE(chat_key, leaf_id, entry_id)
            );
            """)
            try execLocked("CREATE INDEX idx_messages_meta_chat_at ON messages_meta(chat_key, leaf_id, at_ms DESC);")
            try execLocked("CREATE INDEX idx_messages_meta_scope ON messages_meta(tainted, delegated, is_note, chat_key, at_ms DESC);")

            if fts5Active {
                do {
                    try execLocked("""
                    CREATE VIRTUAL TABLE messages_fts USING fts5(
                        body_tokens,
                        cjk_unigrams,
                        content='messages_meta',
                        content_rowid='id',
                        tokenize='unicode61 remove_diacritics 2'
                    );
                    """)
                    try execLocked("""
                    CREATE TRIGGER messages_meta_ai AFTER INSERT ON messages_meta BEGIN
                        INSERT INTO messages_fts(rowid, body_tokens, cjk_unigrams)
                        VALUES (new.id, new.body_tokens, new.cjk_unigrams);
                    END;
                    """)
                    try execLocked("""
                    CREATE TRIGGER messages_meta_ad AFTER DELETE ON messages_meta BEGIN
                        INSERT INTO messages_fts(messages_fts, rowid, body_tokens, cjk_unigrams)
                        VALUES ('delete', old.id, old.body_tokens, old.cjk_unigrams);
                    END;
                    """)
                    try execLocked("""
                    CREATE TRIGGER messages_meta_au AFTER UPDATE ON messages_meta BEGIN
                        INSERT INTO messages_fts(messages_fts, rowid, body_tokens, cjk_unigrams)
                        VALUES ('delete', old.id, old.body_tokens, old.cjk_unigrams);
                        INSERT INTO messages_fts(rowid, body_tokens, cjk_unigrams)
                        VALUES (new.id, new.body_tokens, new.cjk_unigrams);
                    END;
                    """)
                } catch {
                    fts5Active = false
                }
            }

            try setBuildStateLocked("state", "ready")
            try setBuildStateLocked("schema_version", String(Self.schemaVersion))
            try setBuildStateLocked("last_built_at", Self.timestampString(Date()))
            try setBuildStateLocked("source_fingerprint", "")
            try setBuildStateLocked("fts5_enabled", fts5Active ? "1" : "0")
            try execLocked("PRAGMA user_version = \(Self.schemaVersion);")
            try execLocked("COMMIT;")
        } catch {
            try? execLocked("ROLLBACK;")
            throw error
        }
    }

    private func closeLocked() {
        guard let db else { return }
        sqlite3_trace_v2(db, 0, nil, nil)
        sqlite3_close_v2(db)
        self.db = nil
        self.openedIdentity = nil
    }

    private func installTraceLocked() {
        guard let db else { return }
        let contextPtr = Unmanaged.passUnretained(traceSink).toOpaque()
        sqlite3_trace_v2(db, UInt32(SQLITE_TRACE_STMT), memoryIndexSQLiteTraceCallback, contextPtr)
    }

    private func unlinkDatabaseFiles() {
        let fm = FileManager.default
        let paths = [
            databaseURL.path,
            databaseURL.path + "-wal",
            databaseURL.path + "-shm",
            databaseURL.path + "-journal",
        ]
        for path in paths {
            try? fm.removeItem(atPath: path)
        }
    }

    private func markSidecarsExcludedFromBackup() {
        Self.excludeFromBackup(databaseURL)
        Self.excludeFromBackup(URL(fileURLWithPath: databaseURL.path + "-wal"))
        Self.excludeFromBackup(URL(fileURLWithPath: databaseURL.path + "-shm"))
    }

    private static func excludeFromBackup(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var copy = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? copy.setResourceValues(values)
    }

    // MARK: - Private SQL Helpers

    private func insertRecordsLocked(_ records: [MemoryIndexRecord], orderedSecrets: [String]) throws {
        guard !records.isEmpty else { return }
        let sql = """
        INSERT INTO messages_meta (
            chat_key, chat_name, leaf_id, leaf_title, entry_id, role, at_ms,
            tainted, delegated, is_note, snippet_text, normalized_text, body_tokens, cjk_unigrams
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(chat_key, leaf_id, entry_id) DO UPDATE SET
            chat_name = excluded.chat_name,
            leaf_title = excluded.leaf_title,
            role = excluded.role,
            at_ms = excluded.at_ms,
            tainted = excluded.tainted,
            delegated = excluded.delegated,
            is_note = excluded.is_note,
            snippet_text = excluded.snippet_text,
            normalized_text = excluded.normalized_text,
            body_tokens = excluded.body_tokens,
            cjk_unigrams = excluded.cjk_unigrams;
        """
        guard let db else { throw MemoryIndexError.sqlite(code: SQLITE_MISUSE, message: "database closed") }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw sqliteErrorLocked(code: rc)
        }
        defer { sqlite3_finalize(stmt) }

        for record in records {
            let safeText = orderedSecrets.isEmpty
                ? record.text
                : MemorySafety.redactSecrets(record.text, secrets: orderedSecrets)
            let trimmed = safeText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let clipped = MemorySafety.clipUTF8(trimmed, bytes: Self.maxStoredSnippetBytes)
            let normalizedText = MemoryIndexTokenizer.normalize(clipped)
            let tokens = MemoryIndexTokenizer.indexTokens(for: clipped)

            let safeChatName = orderedSecrets.isEmpty
                ? record.chatName
                : MemorySafety.redactSecrets(record.chatName, secrets: orderedSecrets)
            let safeLeafTitle = orderedSecrets.isEmpty
                ? record.leafTitle
                : MemorySafety.redactSecrets(record.leafTitle, secrets: orderedSecrets)

            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)

            try bind(
                [
                    .text(record.chatKey),
                    .text(safeChatName),
                    .text(record.leafID),
                    .text(safeLeafTitle),
                    .text(record.entryID),
                    .text(record.role),
                    .double(record.atMs),
                    .int(record.tainted ? 1 : 0),
                    .int(record.delegated ? 1 : 0),
                    .int(record.isNote ? 1 : 0),
                    .text(clipped),
                    .text(normalizedText),
                    .text(tokens.bodyTokens),
                    .text(tokens.cjkUnigrams),
                ],
                to: stmt
            )

            let stepRC = sqlite3_step(stmt)
            guard stepRC == SQLITE_DONE else {
                throw sqliteErrorLocked(code: stepRC)
            }
        }
    }

    private func setSlotVersionLocked(chatKey: String, leafID: String, digest: String) throws {
        try runPreparedLocked(
            "INSERT OR REPLACE INTO slot_versions(chat_key, leaf_id, slot_digest) VALUES (?, ?, ?);",
            bindings: [.text(chatKey), .text(leafID), .text(digest)]
        )
    }

    private func deleteSlotVersionLocked(chatKey: String, leafID: String) throws {
        try runPreparedLocked(
            "DELETE FROM slot_versions WHERE chat_key = ? AND leaf_id = ?;",
            bindings: [.text(chatKey), .text(leafID)]
        )
    }

    private func readSlotVersionsLocked() throws -> [MemoryIndexSlotKey: String] {
        guard let db else { throw MemoryIndexError.sqlite(code: SQLITE_MISUSE, message: "database closed") }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, "SELECT chat_key, leaf_id, slot_digest FROM slot_versions;", -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw sqliteErrorLocked(code: rc)
        }
        defer { sqlite3_finalize(stmt) }

        var result: [MemoryIndexSlotKey: String] = [:]
        while true {
            let stepRC = sqlite3_step(stmt)
            if stepRC == SQLITE_ROW {
                let key = MemoryIndexSlotKey(chatKey: Self.columnText(stmt, 0), leafID: Self.columnText(stmt, 1))
                result[key] = Self.columnText(stmt, 2)
            } else if stepRC == SQLITE_DONE {
                break
            } else {
                throw sqliteErrorLocked(code: stepRC)
            }
        }
        return result
    }

    private func deleteSlotLocked(chatKey: String, leafID: String) throws {
        try runPreparedLocked(
            "DELETE FROM messages_meta WHERE chat_key = ? AND leaf_id = ?;",
            bindings: [.text(chatKey), .text(leafID)]
        )
    }

    private func executeSearchLocked(
        sql: String,
        bindings: [SQLBinding],
        query: String
    ) throws -> [MemoryIndexHit] {
        guard let db else { throw MemoryIndexError.sqlite(code: SQLITE_MISUSE, message: "database closed") }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw sqliteErrorLocked(code: rc)
        }
        defer { sqlite3_finalize(stmt) }

        try bind(bindings, to: stmt)

        var hits: [MemoryIndexHit] = []
        while true {
            let stepRC = sqlite3_step(stmt)
            if stepRC == SQLITE_ROW {
                let rawSnippet = Self.columnText(stmt, 10)
                let snippet = MemoryIndexTokenizer.extractSnippet(from: rawSnippet, query: query)
                hits.append(
                    MemoryIndexHit(
                        chatKey: Self.columnText(stmt, 0),
                        chatName: Self.columnText(stmt, 1),
                        leafID: Self.columnText(stmt, 2),
                        leafTitle: Self.columnText(stmt, 3),
                        entryID: Self.columnText(stmt, 4),
                        role: Self.columnText(stmt, 5),
                        atMs: sqlite3_column_double(stmt, 6),
                        tainted: sqlite3_column_int(stmt, 7) != 0,
                        delegated: sqlite3_column_int(stmt, 8) != 0,
                        isNote: sqlite3_column_int(stmt, 9) != 0,
                        snippet: snippet,
                        score: sqlite3_column_double(stmt, 11)
                    )
                )
            } else if stepRC == SQLITE_DONE {
                break
            } else {
                throw sqliteErrorLocked(code: stepRC)
            }
        }
        return hits
    }

    private func setBuildStateLocked(_ key: String, _ value: String) throws {
        try runPreparedLocked(
            "INSERT OR REPLACE INTO build_state(key, value) VALUES (?, ?);",
            bindings: [.text(key), .text(value)]
        )
    }

    private func readBuildStateMapLocked() throws -> [String: String] {
        guard let db else { throw MemoryIndexError.sqlite(code: SQLITE_MISUSE, message: "database closed") }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, "SELECT key, value FROM build_state;", -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw sqliteErrorLocked(code: rc)
        }
        defer { sqlite3_finalize(stmt) }

        var map: [String: String] = [:]
        while true {
            let stepRC = sqlite3_step(stmt)
            if stepRC == SQLITE_ROW {
                map[Self.columnText(stmt, 0)] = Self.columnText(stmt, 1)
            } else if stepRC == SQLITE_DONE {
                break
            } else {
                throw sqliteErrorLocked(code: stepRC)
            }
        }
        return map
    }

    private func existingTableNamesLocked() throws -> Set<String> {
        guard let db else { throw MemoryIndexError.sqlite(code: SQLITE_MISUSE, message: "database closed") }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(
            db,
            "SELECT name FROM sqlite_master WHERE type IN ('table', 'view');",
            -1,
            &stmt,
            nil
        )
        guard rc == SQLITE_OK, let stmt else {
            throw sqliteErrorLocked(code: rc)
        }
        defer { sqlite3_finalize(stmt) }

        var names: Set<String> = []
        while true {
            let stepRC = sqlite3_step(stmt)
            if stepRC == SQLITE_ROW {
                names.insert(Self.columnText(stmt, 0))
            } else if stepRC == SQLITE_DONE {
                break
            } else {
                throw sqliteErrorLocked(code: stepRC)
            }
        }
        return names
    }

    private func countRowsLocked(whereSQL: String?) throws -> Int {
        guard let db else { throw MemoryIndexError.sqlite(code: SQLITE_MISUSE, message: "database closed") }
        let sql: String
        if let whereSQL, !whereSQL.isEmpty {
            sql = "SELECT COUNT(*) FROM messages_meta WHERE \(whereSQL);"
        } else {
            sql = "SELECT COUNT(*) FROM messages_meta;"
        }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw sqliteErrorLocked(code: rc)
        }
        defer { sqlite3_finalize(stmt) }

        let stepRC = sqlite3_step(stmt)
        guard stepRC == SQLITE_ROW else {
            throw sqliteErrorLocked(code: stepRC)
        }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func runPreparedLocked(_ sql: String, bindings: [SQLBinding] = []) throws {
        guard let db else { throw MemoryIndexError.sqlite(code: SQLITE_MISUSE, message: "database closed") }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw sqliteErrorLocked(code: rc)
        }
        defer { sqlite3_finalize(stmt) }

        try bind(bindings, to: stmt)
        let stepRC = sqlite3_step(stmt)
        guard stepRC == SQLITE_DONE else {
            throw sqliteErrorLocked(code: stepRC)
        }
    }

    private func bind(_ bindings: [SQLBinding], to stmt: OpaquePointer) throws {
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let rc: Int32
            switch value {
            case .text(let string):
                rc = string.withCString { cStr in
                    sqlite3_bind_text(stmt, index, cStr, -1, sqliteTransient)
                }
            case .int(let intVal):
                rc = sqlite3_bind_int(stmt, index, intVal)
            case .int64(let int64Val):
                rc = sqlite3_bind_int64(stmt, index, int64Val)
            case .double(let doubleVal):
                rc = sqlite3_bind_double(stmt, index, doubleVal)
            }
            guard rc == SQLITE_OK else {
                throw sqliteErrorLocked(code: rc)
            }
        }
    }

    private func execLocked(_ sql: String) throws {
        guard let db else { throw MemoryIndexError.sqlite(code: SQLITE_MISUSE, message: "database closed") }
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            if let errMsg { sqlite3_free(errMsg) }
            throw MemoryIndexError.sqlite(code: rc, message: msg)
        }
    }

    private func scalarStringLocked(_ sql: String) throws -> String {
        guard let db else { throw MemoryIndexError.sqlite(code: SQLITE_MISUSE, message: "database closed") }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw sqliteErrorLocked(code: rc)
        }
        defer { sqlite3_finalize(stmt) }
        let stepRC = sqlite3_step(stmt)
        guard stepRC == SQLITE_ROW else {
            throw sqliteErrorLocked(code: stepRC)
        }
        return Self.columnText(stmt, 0)
    }

    private func scalarInt32Locked(_ sql: String) throws -> Int32 {
        guard let db else { throw MemoryIndexError.sqlite(code: SQLITE_MISUSE, message: "database closed") }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw sqliteErrorLocked(code: rc)
        }
        defer { sqlite3_finalize(stmt) }
        let stepRC = sqlite3_step(stmt)
        guard stepRC == SQLITE_ROW else {
            throw sqliteErrorLocked(code: stepRC)
        }
        return sqlite3_column_int(stmt, 0)
    }

    private func sqliteErrorLocked(code: Int32) -> MemoryIndexError {
        let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite error \(code)"
        return .sqlite(code: code, message: msg)
    }

    private func isCorruptionError(_ error: Error) -> Bool {
        guard case .sqlite(let code, _) = error as? MemoryIndexError else { return false }
        let primary = code & 0xFF
        return primary == SQLITE_CORRUPT || primary == SQLITE_NOTADB
    }

    private static func columnText(_ stmt: OpaquePointer?, _ column: Int32) -> String {
        guard let cString = sqlite3_column_text(stmt, column) else { return "" }
        return String(cString: cString)
    }

    private static func escapeLike(_ term: String) -> String {
        term
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static func timestampString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func fileIdentity(_ url: URL) -> FileIdentity? {
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }
        return FileIdentity(
            device: UInt64(truncatingIfNeeded: st.st_dev),
            inode: UInt64(truncatingIfNeeded: st.st_ino)
        )
    }
}
