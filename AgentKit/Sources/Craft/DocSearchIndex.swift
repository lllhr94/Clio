import Foundation
import SQLite3
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private let docSearchSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum DocSearchIndexRecoveryReason: String, Sendable, Equatable {
    case none
    case missing
    case externalDeletion
    case corrupt
    case schemaMismatch
    case incompleteBuild
}

public enum DocSearchIndexError: Error, Equatable, Sendable {
    case openFailed(code: Int32, message: String)
    case sqlite(code: Int32, message: String)
}

public struct DocSearchDocumentDescriptor: Equatable, Sendable {
    public var path: String
    public var byteCount: Int
    public var mtimeMs: Int64
    public var contentFingerprint: String?

    public init(
        path: String,
        byteCount: Int,
        mtimeMs: Int64,
        contentFingerprint: String? = nil
    ) {
        self.path = path
        self.byteCount = byteCount
        self.mtimeMs = mtimeMs
        self.contentFingerprint = contentFingerprint
    }
}

public struct DocSearchDocumentInput: Equatable, Sendable {
    public var path: String
    public var text: String
    public var byteCount: Int
    public var mtimeMs: Int64
    public var contentFingerprint: String

    public init(
        path: String,
        text: String,
        byteCount: Int? = nil,
        mtimeMs: Int64 = 0,
        contentFingerprint: String? = nil
    ) {
        self.path = path
        self.text = text
        self.byteCount = byteCount ?? text.utf8.count
        self.mtimeMs = mtimeMs
        self.contentFingerprint = contentFingerprint ?? DocSearchIndex.contentFingerprint(for: text)
    }
}

public struct DocSearchSyncPlan: Equatable, Sendable {
    public var staleOrNewPaths: Set<String>
    public var removedPaths: [String]
    public var totalTrackedInScope: Int

    public init(
        staleOrNewPaths: Set<String> = [],
        removedPaths: [String] = [],
        totalTrackedInScope: Int = 0
    ) {
        self.staleOrNewPaths = staleOrNewPaths
        self.removedPaths = removedPaths
        self.totalTrackedInScope = totalTrackedInScope
    }
}

/// Persistent, incremental, self-healing SQLite3 + FTS5 passage index for 书案 & mounted documents.
/// Derived cache only (`Library/Caches/ClioIndex/clio-docs-fts.db`); excluded from `Team/` and backups.
public final class DocSearchIndex: @unchecked Sendable {
    public static let schemaVersion: Int32 = 1

    public static var isFTS5Supported: Bool {
        sqlite3_compileoption_used("ENABLE_FTS5") != 0
    }

    public static var defaultRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClioIndex", isDirectory: true)
    }

    public static var defaultDatabaseURL: URL {
        defaultRoot.appendingPathComponent("clio-docs-fts.db")
    }

    public let databaseURL: URL
    private let sqlitePath: String
    private let isInMemory: Bool
    private let forceDisableFTS5ForTesting: Bool
    private let lock = NSLock()
    private var db: OpaquePointer?
    private var openedIdentity: FileIdentity?
    private var fts5Active: Bool
    private var _lastRecoveryReason: DocSearchIndexRecoveryReason = .none
    private var _needsRebuildFromSource: Bool = false
    private var _unredactedSecretDetected: Bool = false

    private struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    private struct StoredFileStamp: Equatable {
        let byteCount: Int
        let mtimeMs: Int64
        let contentFingerprint: String
    }

    private enum SQLBinding {
        case text(String)
        case int(Int32)
        case optionalInt(Int32?)
        case int64(Int64)
    }

    public convenience init(
        databaseURL: URL = DocSearchIndex.defaultDatabaseURL,
        forceDisableFTS5ForTesting: Bool = false
    ) {
        let inMem = databaseURL.path == ":memory:" || databaseURL.scheme == "sqlite"
        self.init(
            databaseURL: databaseURL,
            isInMemory: inMem,
            forceDisableFTS5ForTesting: forceDisableFTS5ForTesting
        )
    }

    public static func inMemory(forceDisableFTS5ForTesting: Bool = false) -> DocSearchIndex {
        DocSearchIndex(
            databaseURL: URL(string: "sqlite:memory")!,
            isInMemory: true,
            forceDisableFTS5ForTesting: forceDisableFTS5ForTesting
        )
    }

    private init(
        databaseURL: URL,
        isInMemory: Bool,
        forceDisableFTS5ForTesting: Bool
    ) {
        self.databaseURL = databaseURL
        self.isInMemory = isInMemory
        self.sqlitePath = isInMemory ? ":memory:" : databaseURL.path
        self.forceDisableFTS5ForTesting = forceDisableFTS5ForTesting
        self.fts5Active = !forceDisableFTS5ForTesting && Self.isFTS5Supported
    }

    public convenience init(
        cachesRoot: URL,
        forceDisableFTS5ForTesting: Bool = false
    ) {
        let url = cachesRoot
            .appendingPathComponent("ClioIndex", isDirectory: true)
            .appendingPathComponent("clio-docs-fts.db")
        self.init(databaseURL: url, forceDisableFTS5ForTesting: forceDisableFTS5ForTesting)
    }

    deinit {
        lock.lock()
        closeLocked()
        lock.unlock()
    }

    public var lastRecoveryReason: DocSearchIndexRecoveryReason {
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

    public static func contentFingerprint(for text: String) -> String {
        sha256Hex(Data(text.utf8))
    }

    @discardableResult
    public func openOrRecover() throws -> DocSearchIndexRecoveryReason {
        lock.lock()
        defer { lock.unlock() }
        return try openOrRecoverLocked()
    }

    public func close() {
        lock.lock()
        closeLocked()
        lock.unlock()
    }

    public func destroyFiles() {
        lock.lock()
        closeLocked()
        if !isInMemory {
            unlinkDatabaseFiles()
        }
        _needsRebuildFromSource = true
        lock.unlock()
    }

    public func verifyFTSIntegrity() throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        _ = try openOrRecoverLocked()
        guard fts5Active else { return true }
        try execLocked("INSERT INTO docs_fts(docs_fts) VALUES('integrity-check');")
        return true
    }

    public func consumeUnredactedSecretDetected() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let detected = _unredactedSecretDetected
        _unredactedSecretDetected = false
        return detected
    }

    /// Clears `secrets_digest` and marks the index for rebuild so recovery or secret rotation
    /// genuinely re-indexes affected documents rather than hitting a `planSync` no-op.
    public func resetForSecretRotation() throws {
        lock.lock()
        defer { lock.unlock() }
        _ = try openOrRecoverLocked()
        try runPreparedLocked("DELETE FROM build_state WHERE key = 'secrets_digest';")
        _needsRebuildFromSource = true
    }

    public func trackedDocumentCount(folderPrefix: String? = nil) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        _ = try openOrRecoverLocked()
        return try countLocked(table: "doc_files", pathColumn: "path", folderPrefix: folderPrefix)
    }

    public func trackedPassageCount(folderPrefix: String? = nil) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        _ = try openOrRecoverLocked()
        return try countLocked(table: "doc_passages", pathColumn: "doc_path", folderPrefix: folderPrefix)
    }

    /// Compares live file metadata against indexed `doc_files` inside `scopePrefix` to determine
    /// which paths need reading/re-indexing and which deleted paths should be pruned.
    /// When `secrets_digest` changes or rebuild is forced under a non-nil `scopePrefix`, out-of-scope
    /// paths are included in `removedPaths` so unredacted rows never remain stranded on disk.
    public func planSync(
        descriptors: [DocSearchDocumentDescriptor],
        scopePrefix: String? = nil,
        secrets: [String] = [],
        force: Bool = false
    ) throws -> DocSearchSyncPlan {
        let orderedSecrets = secrets.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        let secretsDigest = Self.secretsFingerprint(orderedSecrets)
        let cleanScope = Self.normalizedScope(scopePrefix)

        lock.lock()
        defer { lock.unlock() }
        _ = try openOrRecoverLocked()

        do {
            let stateMap = try readBuildStateMapLocked()
            let storedSecretsDigest = stateMap["secrets_digest"] ?? ""
            let secretsChanged = storedSecretsDigest != secretsDigest
            let forceAll = force || _needsRebuildFromSource || secretsChanged
            let storedFiles = try readStoredFileStampsLocked(scopePrefix: cleanScope)

            var incomingByPath: [String: DocSearchDocumentDescriptor] = [:]
            for desc in descriptors {
                incomingByPath[desc.path] = desc
            }

            var stale: Set<String> = []
            for desc in descriptors {
                if forceAll {
                    stale.insert(desc.path)
                    continue
                }
                guard let stored = storedFiles[desc.path] else {
                    stale.insert(desc.path)
                    continue
                }
                if stored.byteCount != desc.byteCount {
                    stale.insert(desc.path)
                } else if let fp = desc.contentFingerprint {
                    if stored.contentFingerprint != fp {
                        stale.insert(desc.path)
                    }
                } else if stored.mtimeMs != desc.mtimeMs {
                    stale.insert(desc.path)
                }
            }

            var removedSet = Set(storedFiles.keys.filter { incomingByPath[$0] == nil })
            if let cleanScope, forceAll {
                let outOfScope = try readOutOfScopePathsLocked(excludingScopePrefix: cleanScope)
                removedSet.formUnion(outOfScope)
            }
            let removed = removedSet.sorted()
            return DocSearchSyncPlan(
                staleOrNewPaths: stale,
                removedPaths: removed,
                totalTrackedInScope: storedFiles.count
            )
        } catch {
            if isCorruptionError(error) {
                try? recreateFreshDatabaseLocked(reason: .corrupt)
                return DocSearchSyncPlan(
                    staleOrNewPaths: Set(descriptors.map(\.path)),
                    removedPaths: [],
                    totalTrackedInScope: 0
                )
            }
            throw error
        }
    }

    /// Applies incremental upserts and deletions inside a single WAL transaction, redacting any Vault secrets.
    public func applyIncrementalSync(
        upserts: [DocSearchDocumentInput],
        removedPaths: [String],
        secrets: [String] = []
    ) throws {
        let orderedSecrets = secrets.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        let secretsDigest = Self.secretsFingerprint(orderedSecrets)

        lock.lock()
        defer { lock.unlock() }
        _ = try openOrRecoverLocked()

        do {
            let stateMap = try readBuildStateMapLocked()
            let secretsChanged = (stateMap["secrets_digest"] ?? "") != secretsDigest
            if upserts.isEmpty && removedPaths.isEmpty && !secretsChanged && !_needsRebuildFromSource {
                return
            }

            try execLocked("BEGIN IMMEDIATE;")
            do {
                for path in removedPaths {
                    try deleteDocumentLocked(path: path)
                }
                for doc in upserts {
                    try deleteDocumentLocked(path: doc.path)
                    let safeText = orderedSecrets.isEmpty
                        ? doc.text
                        : MemorySafety.redactSecrets(doc.text, secrets: orderedSecrets)
                    try insertDocumentLocked(doc, safeText: safeText)
                }
                if secretsChanged {
                    let updatedPaths = Set(upserts.map(\.path))
                    let remainingPaths = try readStoredFileStampsLocked(scopePrefix: nil).keys
                    for path in remainingPaths where !updatedPaths.contains(path) {
                        try deleteDocumentLocked(path: path)
                    }
                }
                try setBuildStateLocked("state", "ready")
                try setBuildStateLocked("schema_version", String(Self.schemaVersion))
                try setBuildStateLocked("last_built_at", Self.timestampString(Date()))
                try setBuildStateLocked("secrets_digest", secretsDigest)
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

    /// Incrementally synchronizes `(path, text)` documents using content SHA-256 + byte-length fingerprints.
    public func sync(
        documents: [(path: String, text: String)],
        scopePrefix: String? = nil,
        secrets: [String] = []
    ) throws {
        let inputs = documents.map { doc in
            DocSearchDocumentInput(path: doc.path, text: doc.text)
        }
        try sync(inputs: inputs, scopePrefix: scopePrefix, secrets: secrets)
    }

    /// Incrementally synchronizes pre-described `DocSearchDocumentInput` entries inside `scopePrefix`.
    public func sync(
        inputs: [DocSearchDocumentInput],
        scopePrefix: String? = nil,
        secrets: [String] = []
    ) throws {
        let descriptors = inputs.map {
            DocSearchDocumentDescriptor(
                path: $0.path,
                byteCount: $0.byteCount,
                mtimeMs: $0.mtimeMs,
                contentFingerprint: $0.contentFingerprint
            )
        }
        let plan = try planSync(descriptors: descriptors, scopePrefix: scopePrefix, secrets: secrets)
        let upserts = inputs.filter { plan.staleOrNewPaths.contains($0.path) }
        try applyIncrementalSync(upserts: upserts, removedPaths: plan.removedPaths, secrets: secrets)
    }

    /// Searches indexed passages via SQLite FTS5 (or LIKE fallback), supporting CJK bigrams, PDF page numbers,
    /// folder scoping, multi-term coverage, exact phrase boosts, and live Vault secret redaction.
    public func search(
        query: String,
        folderPrefix: String? = nil,
        limit: Int = 12,
        secrets: [String] = []
    ) throws -> [DocSearch.Hit] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return [] }
        let cleanQuery = String(trimmedQuery.prefix(512))
        let clampedLimit = max(1, limit)
        let cleanScope = Self.normalizedScope(folderPrefix)
        let orderedSecrets = secrets.filter { !$0.isEmpty }.sorted { $0.count > $1.count }

        lock.lock()
        defer { lock.unlock() }
        _ = try openOrRecoverLocked()

        var whereClauses: [String] = []
        var bindings: [SQLBinding] = []

        if fts5Active {
            guard let matchExpr = Self.buildFTS5OrMatchExpression(for: cleanQuery) else {
                return []
            }
            whereClauses.append("docs_fts MATCH ?")
            bindings.append(.text(matchExpr))
        } else {
            let terms = Self.fallbackTerms(for: cleanQuery)
            guard !terms.isEmpty else { return [] }
            let likes = terms.map { _ in "p.normalized_text LIKE ? ESCAPE '\\'" }
            whereClauses.append("(" + likes.joined(separator: " OR ") + ")")
            for term in terms {
                bindings.append(.text("%\(Self.escapeLike(term))%"))
            }
        }

        if let cleanScope {
            whereClauses.append("(p.doc_path = ? OR p.doc_path LIKE ? ESCAPE '\\')")
            bindings.append(.text(cleanScope))
            bindings.append(.text("\(Self.escapeLike(cleanScope))/%"))
        }

        let candidateCap = Int32(max(clampedLimit * 20, 200))
        bindings.append(.int(candidateCap))

        let whereSQL = whereClauses.joined(separator: " AND ")
        let sql: String
        if fts5Active {
            sql = """
            SELECT
                p.doc_path,
                p.passage_index,
                p.page,
                p.snippet_text,
                bm25(docs_fts) AS rank_score
            FROM docs_fts
            JOIN doc_passages p ON p.id = docs_fts.rowid
            WHERE \(whereSQL)
            ORDER BY rank_score ASC, p.doc_path ASC, p.passage_index ASC
            LIMIT ?;
            """
        } else {
            sql = """
            SELECT
                p.doc_path,
                p.passage_index,
                p.page,
                p.snippet_text,
                0.0 AS rank_score
            FROM doc_passages p
            WHERE \(whereSQL)
            ORDER BY p.doc_path ASC, p.passage_index ASC
            LIMIT ?;
            """
        }

        do {
            guard let db else { throw DocSearchIndexError.sqlite(code: SQLITE_MISUSE, message: "database closed") }
            var stmt: OpaquePointer?
            let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            guard rc == SQLITE_OK, let stmt else {
                throw sqliteErrorLocked(code: rc)
            }
            defer { sqlite3_finalize(stmt) }
            try bind(bindings, to: stmt)

            let normalizedQuery = MemoryIndexTokenizer.normalize(cleanQuery)
            let words = DocSearch.terms(normalizedQuery)
            let soft = words.flatMap(DocSearch.pairs)
            guard !words.isEmpty else { return [] }

            var scoredHits: [(hit: DocSearch.Hit, passageIndex: Int)] = []
            while true {
                let stepRC = sqlite3_step(stmt)
                if stepRC == SQLITE_ROW {
                    let rawPath = Self.columnText(stmt, 0)
                    let safePath = orderedSecrets.isEmpty
                        ? rawPath
                        : MemorySafety.redactSecrets(rawPath, secrets: orderedSecrets)
                    let passageIndex = Int(sqlite3_column_int(stmt, 1))
                    let page: Int? = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 2))
                    let rawText = Self.columnText(stmt, 3)
                    let bm25Rank = sqlite3_column_double(stmt, 4)

                    let safeText = orderedSecrets.isEmpty
                        ? rawText
                        : MemorySafety.redactSecrets(rawText, secrets: orderedSecrets)
                    if safeText != rawText {
                        _unredactedSecretDetected = true
                    }

                    let lower = MemoryIndexTokenizer.normalize(safeText)
                    var score = 0
                    var whole = 0
                    for word in words where lower.contains(word) {
                        whole += 1
                        score += 10 + min(5, lower.components(separatedBy: word).count - 1)
                    }
                    let softHits = soft.filter { lower.contains($0) }.count
                    if whole == 0 {
                        guard !soft.isEmpty, softHits * 2 >= soft.count else { continue }
                    }
                    score += softHits * 2
                    if whole == words.count, words.count > 1 {
                        score += 20
                    } else if words.count > 2, whole >= 2 {
                        score += whole * 3
                    }
                    if words.count > 1 {
                        let phrase = words.joined(separator: " ")
                        if lower.contains(phrase) {
                            score += 15
                        }
                    }
                    if fts5Active && bm25Rank.isFinite {
                        score += max(0, min(8, Int((-bm25Rank).rounded())))
                    }

                    let snippet = DocSearch.snippet(safeText, around: words + soft)
                    let hit = DocSearch.Hit(path: safePath, page: page, snippet: snippet, score: score)
                    scoredHits.append((hit: hit, passageIndex: passageIndex))
                } else if stepRC == SQLITE_DONE {
                    break
                } else {
                    throw sqliteErrorLocked(code: stepRC)
                }
            }

            scoredHits.sort { lhs, rhs in
                if lhs.hit.score != rhs.hit.score { return lhs.hit.score > rhs.hit.score }
                let lPage = lhs.hit.page ?? Int.max
                let rPage = rhs.hit.page ?? Int.max
                if lPage != rPage { return lPage < rPage }
                if lhs.hit.path != rhs.hit.path { return lhs.hit.path < rhs.hit.path }
                return lhs.passageIndex < rhs.passageIndex
            }

            return Array(scoredHits.prefix(clampedLimit).map(\.hit))
        } catch {
            if isCorruptionError(error) {
                try? recreateFreshDatabaseLocked(reason: .corrupt)
                return []
            }
            throw error
        }
    }

    // MARK: - Query Tokenization Helpers

    static func buildFTS5OrMatchExpression(for query: String) -> String? {
        let bounded = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(512))
        guard !bounded.isEmpty else { return nil }
        let normalized = MemoryIndexTokenizer.normalize(bounded)
        let runs = extractRuns(from: normalized)
        guard !runs.isEmpty else { return nil }

        var clauses: [String] = []
        var seen = Set<String>()
        var hasMultiCharClause = false

        for run in runs.prefix(16) {
            switch run {
            case .word(let word):
                let safe = quotedFTS5Literal(word)
                guard !safe.isEmpty else { continue }
                let clause = word.count >= 2 ? "body_tokens : \(safe)*" : "body_tokens : \(safe)"
                if seen.insert(clause).inserted {
                    clauses.append(clause)
                    hasMultiCharClause = true
                }
            case .cjk(let chars):
                if chars.count == 1 {
                    let safe = quotedFTS5Literal(String(chars[0]))
                    if !safe.isEmpty {
                        let clause = "cjk_unigrams : \(safe)"
                        if seen.insert(clause).inserted {
                            clauses.append(clause)
                        }
                    }
                } else {
                    hasMultiCharClause = true
                    for index in 0..<(chars.count - 1) {
                        let bigram = String(chars[index...index + 1])
                        let safe = quotedFTS5Literal(bigram)
                        guard !safe.isEmpty else { continue }
                        let clause = "body_tokens : \(safe)"
                        if seen.insert(clause).inserted && clauses.count < 36 {
                            clauses.append(clause)
                        }
                    }
                }
            }
        }

        if !hasMultiCharClause && clauses.isEmpty {
            return nil
        }
        return clauses.isEmpty ? nil : clauses.joined(separator: " OR ")
    }

    static func fallbackTerms(for query: String) -> [String] {
        let bounded = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(512))
        guard !bounded.isEmpty else { return [] }
        let normalized = MemoryIndexTokenizer.normalize(bounded)
        let runs = extractRuns(from: normalized)
        var terms: [String] = []
        var seen = Set<String>()
        for run in runs {
            switch run {
            case .word(let word):
                if seen.insert(word).inserted { terms.append(word) }
            case .cjk(let chars):
                if chars.count == 1 {
                    let s = String(chars[0])
                    if seen.insert(s).inserted { terms.append(s) }
                } else {
                    for i in 0..<(chars.count - 1) {
                        let bg = String(chars[i...i + 1])
                        if seen.insert(bg).inserted { terms.append(bg) }
                        if terms.count >= 24 { break }
                    }
                }
            }
            if terms.count >= 24 { break }
        }
        return Array(terms.prefix(24))
    }

    private enum ScriptRun {
        case word(String)
        case cjk([Character])
    }

    private static func extractRuns(from normalized: String) -> [ScriptRun] {
        var runs: [ScriptRun] = []
        var wordBuffer = ""
        var cjkBuffer: [Character] = []

        func flushWord() {
            if !wordBuffer.isEmpty {
                runs.append(.word(wordBuffer))
                wordBuffer.removeAll(keepingCapacity: true)
            }
        }
        func flushCJK() {
            if !cjkBuffer.isEmpty {
                runs.append(.cjk(cjkBuffer))
                cjkBuffer.removeAll(keepingCapacity: true)
            }
        }

        for scalar in normalized.unicodeScalars {
            if scalar.properties.generalCategory == .nonspacingMark { continue }
            if MemoryIndexTokenizer.isCJKScalar(scalar) {
                flushWord()
                cjkBuffer.append(Character(scalar))
            } else if CharacterSet.alphanumerics.contains(scalar) {
                flushCJK()
                wordBuffer.append(Character(scalar))
            } else {
                flushWord()
                flushCJK()
            }
        }
        flushWord()
        flushCJK()
        return runs
    }

    private static func quotedFTS5Literal(_ token: String) -> String {
        let sanitized = token.replacingOccurrences(of: "\"", with: "")
        guard !sanitized.isEmpty else { return "" }
        return "\"\(sanitized)\""
    }

    // MARK: - Private SQLite Lifecycle & Self-Healing

    private func openOrRecoverLocked() throws -> DocSearchIndexRecoveryReason {
        if db != nil {
            if isInMemory {
                return .none
            }
            if let currentIdentity = Self.fileIdentity(databaseURL), currentIdentity == openedIdentity {
                // Detect silent in-place truncation while handle remained open.
                if let size = Self.fileByteSize(databaseURL), size < 100 {
                    try recreateFreshDatabaseLocked(reason: .corrupt)
                    return .corrupt
                }
                return .none
            }
            closeLocked()
            unlinkDatabaseFiles()
            try createFreshDatabaseLocked(reason: .externalDeletion)
            return .externalDeletion
        }

        if isInMemory {
            try createFreshDatabaseLocked(reason: .missing)
            return .missing
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
            sqlitePath,
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

        let recovery = validateOpenedDatabaseLocked()
        if recovery == .none {
            do {
                try configureRuntimePragmasLocked()
                self.openedIdentity = Self.fileIdentity(databaseURL)
                markSidecarsExcludedFromBackup()
                _lastRecoveryReason = .none
                return .none
            } catch {
                let reason: DocSearchIndexRecoveryReason = isCorruptionError(error) ? .corrupt : .schemaMismatch
                try recreateFreshDatabaseLocked(reason: reason)
                return reason
            }
        } else {
            try recreateFreshDatabaseLocked(reason: recovery)
            return recovery
        }
    }

    private func validateOpenedDatabaseLocked() -> DocSearchIndexRecoveryReason {
        do {
            try execLocked("PRAGMA busy_timeout = 5000;")

            let check = try scalarStringLocked("PRAGMA quick_check(1);")
            guard check == "ok" else { return .corrupt }

            let userVer = try scalarInt32Locked("PRAGMA user_version;")
            guard userVer == Self.schemaVersion else { return .schemaMismatch }

            let expectedTables: Set<String> = fts5Active
                ? ["build_state", "doc_files", "doc_passages", "docs_fts"]
                : ["build_state", "doc_files", "doc_passages"]
            let foundTables = try existingTableNamesLocked()
            guard expectedTables.isSubset(of: foundTables) else { return .schemaMismatch }

            let stateMap = try readBuildStateMapLocked()
            guard stateMap["state"] == "ready" else { return .incompleteBuild }
            guard stateMap["schema_version"] == String(Self.schemaVersion) else { return .schemaMismatch }
            let expectedFTSFlag = fts5Active ? "1" : "0"
            guard stateMap["fts5_enabled"] == expectedFTSFlag else { return .schemaMismatch }

            if fts5Active {
                try execLocked("INSERT INTO docs_fts(docs_fts) VALUES('integrity-check');")
            }
            return .none
        } catch {
            return isCorruptionError(error) ? .corrupt : .schemaMismatch
        }
    }

    private func recreateFreshDatabaseLocked(reason: DocSearchIndexRecoveryReason) throws {
        closeLocked()
        if !isInMemory {
            unlinkDatabaseFiles()
        }
        try createFreshDatabaseLocked(reason: reason)
    }

    private func createFreshDatabaseLocked(reason: DocSearchIndexRecoveryReason) throws {
        if !isInMemory {
            let fm = FileManager.default
            let parentDir = databaseURL.deletingLastPathComponent()
            try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
            Self.excludeFromBackup(parentDir)
        }

        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(
            sqlitePath,
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard rc == SQLITE_OK, let opened = handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown open error"
            if let handle { sqlite3_close_v2(handle) }
            throw DocSearchIndexError.openFailed(code: rc, message: msg)
        }

        self.db = opened
        do {
            try configureRuntimePragmasLocked()
            try createSchemaLocked()
            if !isInMemory {
                self.openedIdentity = Self.fileIdentity(databaseURL)
                markSidecarsExcludedFromBackup()
            }
            _lastRecoveryReason = reason
            _needsRebuildFromSource = true
        } catch {
            closeLocked()
            if !isInMemory { unlinkDatabaseFiles() }
            throw error
        }
    }

    private func configureRuntimePragmasLocked() throws {
        try execLocked("PRAGMA busy_timeout = 5000;")
        if !isInMemory {
            try execLocked("PRAGMA journal_mode = WAL;")
        }
        try execLocked("PRAGMA synchronous = NORMAL;")
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
            CREATE TABLE doc_files (
                path TEXT PRIMARY KEY,
                byte_count INTEGER NOT NULL,
                mtime_ms INTEGER NOT NULL,
                content_fingerprint TEXT NOT NULL
            );
            """)
            try execLocked("""
            CREATE TABLE doc_passages (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                doc_path TEXT NOT NULL,
                passage_index INTEGER NOT NULL,
                page INTEGER,
                snippet_text TEXT NOT NULL,
                normalized_text TEXT NOT NULL DEFAULT '',
                body_tokens TEXT NOT NULL DEFAULT '',
                cjk_unigrams TEXT NOT NULL DEFAULT '',
                UNIQUE(doc_path, passage_index)
            );
            """)
            try execLocked("CREATE INDEX idx_doc_passages_path ON doc_passages(doc_path, passage_index);")

            if fts5Active {
                do {
                    try execLocked("""
                    CREATE VIRTUAL TABLE docs_fts USING fts5(
                        body_tokens,
                        cjk_unigrams,
                        content='doc_passages',
                        content_rowid='id',
                        tokenize='unicode61 remove_diacritics 2'
                    );
                    """)
                    try execLocked("""
                    CREATE TRIGGER doc_passages_ai AFTER INSERT ON doc_passages BEGIN
                        INSERT INTO docs_fts(rowid, body_tokens, cjk_unigrams)
                        VALUES (new.id, new.body_tokens, new.cjk_unigrams);
                    END;
                    """)
                    try execLocked("""
                    CREATE TRIGGER doc_passages_ad AFTER DELETE ON doc_passages BEGIN
                        INSERT INTO docs_fts(docs_fts, rowid, body_tokens, cjk_unigrams)
                        VALUES ('delete', old.id, old.body_tokens, old.cjk_unigrams);
                    END;
                    """)
                    try execLocked("""
                    CREATE TRIGGER doc_passages_au AFTER UPDATE ON doc_passages BEGIN
                        INSERT INTO docs_fts(docs_fts, rowid, body_tokens, cjk_unigrams)
                        VALUES ('delete', old.id, old.body_tokens, old.cjk_unigrams);
                        INSERT INTO docs_fts(rowid, body_tokens, cjk_unigrams)
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
            try setBuildStateLocked("secrets_digest", "")
            try setBuildStateLocked("fts5_enabled", fts5Active ? "1" : "0")
            try execLocked("PRAGMA user_version = \(Self.schemaVersion);")
            try execLocked("COMMIT;")
        } catch {
            try? execLocked("ROLLBACK;")
            throw error
        }
    }

    // MARK: - Private SQL Helpers

    private func deleteDocumentLocked(path: String) throws {
        try runPreparedLocked("DELETE FROM doc_passages WHERE doc_path = ?;", bindings: [.text(path)])
        try runPreparedLocked("DELETE FROM doc_files WHERE path = ?;", bindings: [.text(path)])
    }

    private func insertDocumentLocked(_ doc: DocSearchDocumentInput, safeText: String) throws {
        try runPreparedLocked(
            """
            INSERT INTO doc_files(path, byte_count, mtime_ms, content_fingerprint)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET
                byte_count = excluded.byte_count,
                mtime_ms = excluded.mtime_ms,
                content_fingerprint = excluded.content_fingerprint;
            """,
            bindings: [
                .text(doc.path),
                .int64(Int64(doc.byteCount)),
                .int64(doc.mtimeMs),
                .text(doc.contentFingerprint),
            ]
        )

        let passages = DocSearch.passages(safeText)
        guard !passages.isEmpty else { return }

        guard let db else { throw DocSearchIndexError.sqlite(code: SQLITE_MISUSE, message: "database closed") }
        let sql = """
        INSERT INTO doc_passages (
            doc_path, passage_index, page, snippet_text, normalized_text, body_tokens, cjk_unigrams
        ) VALUES (?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw sqliteErrorLocked(code: rc) }
        defer { sqlite3_finalize(stmt) }

        for (index, passage) in passages.enumerated() {
            let normalized = MemoryIndexTokenizer.normalize(passage.text)
            let tokens = MemoryIndexTokenizer.indexTokens(for: passage.text)
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            try bind(
                [
                    .text(doc.path),
                    .int(Int32(index)),
                    .optionalInt(passage.page.flatMap { Int32(exactly: $0) }),
                    .text(passage.text),
                    .text(normalized),
                    .text(tokens.bodyTokens),
                    .text(tokens.cjkUnigrams),
                ],
                to: stmt
            )
            let stepRC = sqlite3_step(stmt)
            guard stepRC == SQLITE_DONE else { throw sqliteErrorLocked(code: stepRC) }
        }
    }

    private func readStoredFileStampsLocked(scopePrefix: String?) throws -> [String: StoredFileStamp] {
        guard let db else { throw DocSearchIndexError.sqlite(code: SQLITE_MISUSE, message: "database closed") }
        let sql: String
        let bindings: [SQLBinding]
        if let scopePrefix {
            sql = """
            SELECT path, byte_count, mtime_ms, content_fingerprint
            FROM doc_files
            WHERE path = ? OR path LIKE ? ESCAPE '\\';
            """
            bindings = [.text(scopePrefix), .text("\(Self.escapeLike(scopePrefix))/%")]
        } else {
            sql = "SELECT path, byte_count, mtime_ms, content_fingerprint FROM doc_files;"
            bindings = []
        }

        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw sqliteErrorLocked(code: rc) }
        defer { sqlite3_finalize(stmt) }
        try bind(bindings, to: stmt)

        var map: [String: StoredFileStamp] = [:]
        while true {
            let stepRC = sqlite3_step(stmt)
            if stepRC == SQLITE_ROW {
                let path = Self.columnText(stmt, 0)
                let bytes = Int(sqlite3_column_int64(stmt, 1))
                let mtime = sqlite3_column_int64(stmt, 2)
                let fp = Self.columnText(stmt, 3)
                map[path] = StoredFileStamp(byteCount: bytes, mtimeMs: mtime, contentFingerprint: fp)
            } else if stepRC == SQLITE_DONE {
                break
            } else {
                throw sqliteErrorLocked(code: stepRC)
            }
        }
        return map
    }

    private func readOutOfScopePathsLocked(excludingScopePrefix scopePrefix: String) throws -> [String] {
        guard let db else { throw DocSearchIndexError.sqlite(code: SQLITE_MISUSE, message: "database closed") }
        let sql = """
        SELECT path FROM doc_files
        WHERE NOT (path = ? OR path LIKE ? ESCAPE '\\')
        ORDER BY path ASC;
        """
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw sqliteErrorLocked(code: rc) }
        defer { sqlite3_finalize(stmt) }
        try bind([.text(scopePrefix), .text("\(Self.escapeLike(scopePrefix))/%")], to: stmt)

        var paths: [String] = []
        while true {
            let stepRC = sqlite3_step(stmt)
            if stepRC == SQLITE_ROW {
                paths.append(Self.columnText(stmt, 0))
            } else if stepRC == SQLITE_DONE {
                break
            } else {
                throw sqliteErrorLocked(code: stepRC)
            }
        }
        return paths
    }

    private func countLocked(table: String, pathColumn: String, folderPrefix: String?) throws -> Int {
        guard let db else { throw DocSearchIndexError.sqlite(code: SQLITE_MISUSE, message: "database closed") }
        let cleanScope = Self.normalizedScope(folderPrefix)
        let sql: String
        let bindings: [SQLBinding]
        if let cleanScope {
            sql = "SELECT COUNT(*) FROM \(table) WHERE \(pathColumn) = ? OR \(pathColumn) LIKE ? ESCAPE '\\';"
            bindings = [.text(cleanScope), .text("\(Self.escapeLike(cleanScope))/%")]
        } else {
            sql = "SELECT COUNT(*) FROM \(table);"
            bindings = []
        }

        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw sqliteErrorLocked(code: rc) }
        defer { sqlite3_finalize(stmt) }
        try bind(bindings, to: stmt)

        let stepRC = sqlite3_step(stmt)
        guard stepRC == SQLITE_ROW else { throw sqliteErrorLocked(code: stepRC) }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func closeLocked() {
        guard let db else { return }
        sqlite3_close_v2(db)
        self.db = nil
        self.openedIdentity = nil
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

    private func setBuildStateLocked(_ key: String, _ value: String) throws {
        try runPreparedLocked(
            "INSERT OR REPLACE INTO build_state(key, value) VALUES (?, ?);",
            bindings: [.text(key), .text(value)]
        )
    }

    private func readBuildStateMapLocked() throws -> [String: String] {
        guard let db else { throw DocSearchIndexError.sqlite(code: SQLITE_MISUSE, message: "database closed") }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, "SELECT key, value FROM build_state;", -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw sqliteErrorLocked(code: rc) }
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
        guard let db else { throw DocSearchIndexError.sqlite(code: SQLITE_MISUSE, message: "database closed") }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type IN ('table', 'view');", -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw sqliteErrorLocked(code: rc) }
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

    private func runPreparedLocked(_ sql: String, bindings: [SQLBinding] = []) throws {
        guard let db else { throw DocSearchIndexError.sqlite(code: SQLITE_MISUSE, message: "database closed") }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw sqliteErrorLocked(code: rc) }
        defer { sqlite3_finalize(stmt) }
        try bind(bindings, to: stmt)
        let stepRC = sqlite3_step(stmt)
        guard stepRC == SQLITE_DONE else { throw sqliteErrorLocked(code: stepRC) }
    }

    private func bind(_ bindings: [SQLBinding], to stmt: OpaquePointer) throws {
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let rc: Int32
            switch value {
            case .text(let string):
                rc = string.withCString { cStr in
                    sqlite3_bind_text(stmt, index, cStr, -1, docSearchSQLiteTransient)
                }
            case .int(let intVal):
                rc = sqlite3_bind_int(stmt, index, intVal)
            case .optionalInt(let optional):
                if let intVal = optional {
                    rc = sqlite3_bind_int(stmt, index, intVal)
                } else {
                    rc = sqlite3_bind_null(stmt, index)
                }
            case .int64(let int64Val):
                rc = sqlite3_bind_int64(stmt, index, int64Val)
            }
            guard rc == SQLITE_OK else { throw sqliteErrorLocked(code: rc) }
        }
    }

    private func execLocked(_ sql: String) throws {
        guard let db else { throw DocSearchIndexError.sqlite(code: SQLITE_MISUSE, message: "database closed") }
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            if let errMsg { sqlite3_free(errMsg) }
            throw DocSearchIndexError.sqlite(code: rc, message: msg)
        }
    }

    private func scalarStringLocked(_ sql: String) throws -> String {
        guard let db else { throw DocSearchIndexError.sqlite(code: SQLITE_MISUSE, message: "database closed") }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw sqliteErrorLocked(code: rc) }
        defer { sqlite3_finalize(stmt) }
        let stepRC = sqlite3_step(stmt)
        guard stepRC == SQLITE_ROW else { throw sqliteErrorLocked(code: stepRC) }
        return Self.columnText(stmt, 0)
    }

    private func scalarInt32Locked(_ sql: String) throws -> Int32 {
        guard let db else { throw DocSearchIndexError.sqlite(code: SQLITE_MISUSE, message: "database closed") }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw sqliteErrorLocked(code: rc) }
        defer { sqlite3_finalize(stmt) }
        let stepRC = sqlite3_step(stmt)
        guard stepRC == SQLITE_ROW else { throw sqliteErrorLocked(code: stepRC) }
        return sqlite3_column_int(stmt, 0)
    }

    private func sqliteErrorLocked(code: Int32) -> DocSearchIndexError {
        let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite error \(code)"
        return .sqlite(code: code, message: msg)
    }

    private func isCorruptionError(_ error: Error) -> Bool {
        guard case .sqlite(let code, _) = error as? DocSearchIndexError else { return false }
        let primary = code & 0xFF
        return primary == SQLITE_CORRUPT || primary == SQLITE_NOTADB
    }

    private static func normalizedScope(_ scope: String?) -> String? {
        guard let scope else { return nil }
        let trimmed = scope.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return trimmed.isEmpty ? nil : trimmed
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

    private static func secretsFingerprint(_ orderedSecrets: [String]) -> String {
        guard !orderedSecrets.isEmpty else { return "" }
        return sha256Hex(Data(orderedSecrets.joined(separator: "\u{1F}").utf8))
    }

    private static func sha256Hex(_ data: Data) -> String {
        #if canImport(CryptoKit)
        let digest = CryptoKit.SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
        #else
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(format: "%016llx", hash)
        #endif
    }

    private static func fileIdentity(_ url: URL) -> FileIdentity? {
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        return FileIdentity(
            device: UInt64(truncatingIfNeeded: st.st_dev),
            inode: UInt64(truncatingIfNeeded: st.st_ino)
        )
    }

    private static func fileByteSize(_ url: URL) -> Int64? {
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        return Int64(st.st_size)
    }
}
