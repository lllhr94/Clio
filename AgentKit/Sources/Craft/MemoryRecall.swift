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

private let memoryRecallSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Lightweight Channel-1 recall frequency & recency statistics keyed by `memoryID`.
public struct MemoryRecallUsageStat: Codable, Equatable, Sendable {
    public var lastRecalledAtMs: Double
    public var recallCount: Int

    public init(lastRecalledAtMs: Double, recallCount: Int) {
        self.lastRecalledAtMs = lastRecalledAtMs
        self.recallCount = max(0, recallCount)
    }
}

/// Channel-1 zero-cost FTS5 memory recall for `.deep` memories, volatile-tail formatting,
/// live prompt cache-prefix preservation, and deterministic nightly promotion/archival rules.
public enum MemoryRecall: Sendable {
    public struct Hit: Equatable, Sendable, Identifiable {
        public var id: String
        public var text: String
        public var textSHA256: String
        public var topic: String
        public var kind: String
        public var createdAtMs: Double
        public var usedAtMs: Double?
        public var confidence: Double
        public var score: Double

        public init(
            id: String,
            text: String,
            textSHA256: String,
            topic: String = "",
            kind: String = "fact",
            createdAtMs: Double = 0,
            usedAtMs: Double? = nil,
            confidence: Double = 1.0,
            score: Double = 0
        ) {
            self.id = id
            self.text = text
            self.textSHA256 = textSHA256
            self.topic = topic
            self.kind = kind
            self.createdAtMs = createdAtMs
            self.usedAtMs = usedAtMs
            self.confidence = confidence
            self.score = score
        }
    }

    public struct Config: Equatable, Sendable {
        public var limit: Int
        public var maxBytes: Int
        public var maxItemBytes: Int

        public init(limit: Int = 5, maxBytes: Int = 1_200, maxItemBytes: Int = 240) {
            self.limit = max(1, limit)
            self.maxBytes = max(120, maxBytes)
            self.maxItemBytes = max(64, maxItemBytes)
        }
    }

    public static let tailHeader = "与当前话题相关的过往记忆（自动联想，按需参考）："

    private static let stopBigrams: Set<String> = [
        "的是", "了一", "我的", "你的", "他的", "她的", "我们", "你们", "他们",
        "一个", "这个", "那个", "哪些", "什么", "怎么", "没有", "已经", "可以",
        "就是", "还是", "因为", "所以", "但是", "如果", "的话", "时候", "是不是",
        "一下", "知道", "觉得", "帮我", "请问", "谢谢", "有没有",
    ]

    fileprivate struct QueryAnalysis {
        let normalizedQuery: String
        let words: [String]
        let cjkRuns: [String]
        let cjkBigrams: [String]
        let singleCJKChars: [String]
        let nonStopCount: Int

        var isEmpty: Bool {
            words.isEmpty && cjkBigrams.isEmpty && singleCJKChars.isEmpty
        }
    }

    fileprivate static func analyzeQuery(_ query: String) -> QueryAnalysis {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let bounded = String(trimmed.unicodeScalars.prefix(512))
        let normalized = MemoryIndexTokenizer.normalize(bounded)
        var words: [String] = []
        var cjkRuns: [String] = []
        var seenWords = Set<String>()
        var seenRuns = Set<String>()
        var wordBuffer = ""
        var cjkBuffer: [Character] = []

        func flushWord() {
            if !wordBuffer.isEmpty {
                if words.count < 48, seenWords.insert(wordBuffer).inserted {
                    words.append(wordBuffer)
                }
                wordBuffer.removeAll(keepingCapacity: true)
            }
        }

        func flushCJK() {
            if !cjkBuffer.isEmpty {
                let run = String(cjkBuffer)
                if cjkRuns.count < 48, seenRuns.insert(run).inserted {
                    cjkRuns.append(run)
                }
                cjkBuffer.removeAll(keepingCapacity: true)
            }
        }

        for scalar in normalized.unicodeScalars {
            if scalar.properties.generalCategory == .nonspacingMark {
                continue
            }
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
            if words.count >= 48 && cjkRuns.count >= 48 && wordBuffer.isEmpty && cjkBuffer.isEmpty {
                break
            }
        }
        flushWord()
        flushCJK()

        var bigrams: [String] = []
        var singleChars: [String] = []
        var seenBigrams = Set<String>()
        var seenSingles = Set<String>()
        for run in cjkRuns {
            let chars = Array(run)
            if chars.count == 1 {
                if singleChars.count < 32 {
                    let ch = String(chars[0])
                    if seenSingles.insert(ch).inserted {
                        singleChars.append(ch)
                    }
                }
            } else if bigrams.count < 64 {
                for index in 0..<(chars.count - 1) {
                    if bigrams.count >= 64 { break }
                    let pair = String(chars[index...index + 1])
                    if seenBigrams.insert(pair).inserted {
                        bigrams.append(pair)
                    }
                }
            }
            if bigrams.count >= 64 && singleChars.count >= 32 {
                break
            }
        }

        let nonStopWords = words.filter { $0.count >= 2 }.count
        let nonStopBigrams = bigrams.filter { !stopBigrams.contains($0) }.count
        let nonStopSingles = words.isEmpty && bigrams.isEmpty ? singleChars.count : 0

        return QueryAnalysis(
            normalizedQuery: normalized,
            words: words,
            cjkRuns: cjkRuns,
            cjkBigrams: bigrams,
            singleCJKChars: singleChars,
            nonStopCount: nonStopWords + nonStopBigrams + nonStopSingles
        )
    }

    /// Builds an OR-composed FTS5 `MATCH` expression so conversational prompts can recall relevant `.deep` items.
    public static func buildFTS5OrMatchExpression(for query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let bounded = String(trimmed.unicodeScalars.prefix(512))
        let analysis = analyzeQuery(bounded)
        guard !analysis.isEmpty else { return nil }

        var clauses: [String] = []
        var seen = Set<String>()

        for word in analysis.words.prefix(16) {
            let safe = quotedFTS5Literal(word)
            guard !safe.isEmpty else { continue }
            let clause = word.count >= 2 ? "body_tokens : \(safe)*" : "body_tokens : \(safe)"
            if seen.insert(clause).inserted {
                clauses.append(clause)
            }
        }

        let prioritizedBigrams: [String]
        let nonStop = analysis.cjkBigrams.filter { !stopBigrams.contains($0) }
        if !nonStop.isEmpty {
            prioritizedBigrams = nonStop + analysis.cjkBigrams.filter { stopBigrams.contains($0) }
        } else {
            prioritizedBigrams = analysis.cjkBigrams
        }

        for bigram in prioritizedBigrams.prefix(24) {
            let safe = quotedFTS5Literal(bigram)
            guard !safe.isEmpty else { continue }
            let clause = "body_tokens : \(safe)"
            if seen.insert(clause).inserted {
                clauses.append(clause)
            }
        }

        if clauses.isEmpty || (analysis.words.isEmpty && analysis.cjkBigrams.isEmpty) {
            for single in analysis.singleCJKChars.prefix(8) {
                let safe = quotedFTS5Literal(single)
                guard !safe.isEmpty else { continue }
                let clause = "cjk_unigrams : \(safe)"
                if seen.insert(clause).inserted {
                    clauses.append(clause)
                }
            }
        }

        guard !clauses.isEmpty else { return nil }
        return clauses.joined(separator: " OR ")
    }

    static func fallbackTerms(for query: String) -> [String] {
        let analysis = analyzeQuery(query)
        var terms: [String] = []
        var seen = Set<String>()
        for word in analysis.words where seen.insert(word).inserted {
            terms.append(word)
        }
        let nonStop = analysis.cjkBigrams.filter { !stopBigrams.contains($0) }
        let chosenBigrams = nonStop.isEmpty ? analysis.cjkBigrams : nonStop
        for bg in chosenBigrams where seen.insert(bg).inserted {
            terms.append(bg)
        }
        if terms.isEmpty {
            for ch in analysis.singleCJKChars where seen.insert(ch).inserted {
                terms.append(ch)
            }
        }
        return Array(terms.prefix(24))
    }

    private static func quotedFTS5Literal(_ token: String) -> String {
        let sanitized = token.replacingOccurrences(of: "\"", with: "")
        guard !sanitized.isEmpty else { return "" }
        return "\"\(sanitized)\""
    }

    private static func extractNormalizedWords(
        from normalized: String,
        maxWords: Int = 256
    ) -> (ordered: [String], set: Set<String>) {
        var ordered: [String] = []
        var seen = Set<String>()
        var wordBuffer = ""

        func flushWord() {
            if !wordBuffer.isEmpty {
                if ordered.count < maxWords, seen.insert(wordBuffer).inserted {
                    ordered.append(wordBuffer)
                }
                wordBuffer.removeAll(keepingCapacity: true)
            }
        }

        for scalar in normalized.unicodeScalars {
            if scalar.properties.generalCategory == .nonspacingMark {
                continue
            }
            if MemoryIndexTokenizer.isCJKScalar(scalar) {
                flushWord()
            } else if CharacterSet.alphanumerics.contains(scalar) {
                wordBuffer.append(Character(scalar))
            } else {
                flushWord()
            }
            if ordered.count >= maxWords && wordBuffer.isEmpty {
                break
            }
        }
        flushWord()
        return (ordered, seen)
    }

    /// Relevance score (`<= 0` means no credible match).
    public static func scoreText(
        query: String,
        text: String,
        topic: String = "",
        bm25Rank: Double? = nil
    ) -> Double {
        scoreText(
            analysis: analyzeQuery(query),
            text: text,
            topic: topic,
            bm25Rank: bm25Rank
        )
    }

    fileprivate static func scoreText(
        analysis: QueryAnalysis,
        text: String,
        topic: String = "",
        bm25Rank: Double? = nil
    ) -> Double {
        guard !analysis.isEmpty else { return 0 }

        let combinedRaw = topic.isEmpty ? text : "\(text) \(topic)"
        let boundedCombined = String(combinedRaw.unicodeScalars.prefix(4096))
        let haystack = MemoryIndexTokenizer.normalize(boundedCombined)
        guard !haystack.isEmpty else { return 0 }

        let haystackWords = extractNormalizedWords(from: haystack)
        let haystackWordSet = haystackWords.set

        var score: Double = 0
        var matchedWordCount = 0
        var matchedNonStopSignals = 0

        for word in analysis.words {
            if haystackWordSet.contains(word) {
                score += 18
                matchedWordCount += 1
                if word.count >= 2 { matchedNonStopSignals += 1 }
            } else if word.count >= 3,
                      haystackWords.ordered.contains(where: { $0.hasPrefix(word) || word.hasPrefix($0) }) {
                score += 11
                matchedWordCount += 1
                matchedNonStopSignals += 1
            } else if word.count >= 2, haystack.contains(word) {
                score += 9
                matchedWordCount += 1
                matchedNonStopSignals += 1
            }
        }

        var matchedWholeCJKRuns = 0
        for run in analysis.cjkRuns where run.count >= 2 {
            if haystack.contains(run) {
                score += 14 + Double(min(run.count, 8)) * 2.5
                matchedWholeCJKRuns += 1
                if run.count >= 3 || !stopBigrams.contains(run) {
                    matchedNonStopSignals += 1
                }
            }
        }

        var nonStopBigramMatches = 0
        for bg in analysis.cjkBigrams where haystack.contains(bg) {
            if stopBigrams.contains(bg) {
                score += 1.0
            } else {
                score += 6.0
                nonStopBigramMatches += 1
                matchedNonStopSignals += 1
            }
        }

        // Contiguous CJK bigram bonus (e.g. two overlapping bigrams in sequence).
        if analysis.cjkBigrams.count >= 2 {
            for idx in 0..<(analysis.cjkBigrams.count - 1) {
                let first = analysis.cjkBigrams[idx]
                let second = analysis.cjkBigrams[idx + 1]
                if haystack.contains(first) && haystack.contains(second) {
                    score += 4.0
                }
            }
        }

        // Single-character CJK query fallback (only when query has standalone 1-char CJK and no larger match yet).
        if analysis.words.isEmpty && analysis.cjkBigrams.isEmpty {
            for single in analysis.singleCJKChars where haystack.contains(single) {
                score += 10.0
                matchedNonStopSignals += 1
            }
        }

        // Guard against filler-only accidental matches when the query actually carries content terms.
        if analysis.nonStopCount > 0 && matchedNonStopSignals == 0 {
            return 0
        }

        let distinctHitGroups = matchedWordCount + matchedWholeCJKRuns + (nonStopBigramMatches > 0 ? 1 : 0)
        if distinctHitGroups >= 2 {
            score += Double(min(distinctHitGroups, 5)) * 4.0
        }

        if let bm25Rank, bm25Rank.isFinite {
            // SQLite FTS5 bm25() returns negative scores where more negative = stronger match.
            let bm25Boost = min(8.0, max(0.0, -bm25Rank * 0.5))
            score += bm25Boost
        }

        return score >= 4.0 ? score : 0
    }

    /// Pure in-memory `.deep` recall with full layer, tombstone, suppression, and secret-redaction enforcement.
    public static func searchDeep(
        query: String,
        records: [MemoryRecord],
        excludedIDs: Set<String> = [],
        suppressedHashes: Set<String> = [],
        existingSurfaceTexts: [String] = [],
        secrets: [String] = [],
        config: Config = Config()
    ) -> [Hit] {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuery.isEmpty else { return [] }
        let queryAnalysis = analyzeQuery(cleanQuery)
        guard !queryAnalysis.isEmpty else { return [] }

        let orderedSecrets = secrets.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        let normalizedSuppressed = Set(suppressedHashes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        var seenSurfaceKeys = Set(existingSurfaceTexts.map(MemorySafety.normalizedFactKey).filter { !$0.isEmpty })
        for record in records where record.deletedAtMs == nil && (record.layer == .pinned || record.layer == .surface || record.pinned) {
            let safeSurface = MemorySafety.redactSecrets(record.text, secrets: orderedSecrets)
            let key = MemorySafety.normalizedFactKey(safeSurface)
            if !key.isEmpty { seenSurfaceKeys.insert(key) }
        }

        var scored: [(hit: Hit, recency: Double, updatedAt: Double)] = []
        for record in records {
            guard record.layer == .deep, !record.pinned, record.deletedAtMs == nil else { continue }
            guard !excludedIDs.contains(record.id) else { continue }

            let safeText = MemorySafety.redactSecrets(record.text, secrets: orderedSecrets)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let remainingWithoutMask = safeText.replacingOccurrences(of: "〔隐去〕", with: "")
            guard !MemorySafety.normalizedFactKey(remainingWithoutMask).isEmpty else { continue }

            let safeTopic = MemorySafety.redactSecrets(record.topic, secrets: orderedSecrets)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let safeHash = MemorySafety.retractionHash(safeText)
            let rawHash = record.textSHA256.lowercased()
            guard !normalizedSuppressed.contains(rawHash),
                  !normalizedSuppressed.contains(safeHash),
                  !normalizedSuppressed.contains(MemorySafety.retractionHash(record.text)) else {
                continue
            }

            let key = MemorySafety.normalizedFactKey(safeText)
            guard !key.isEmpty, !seenSurfaceKeys.contains(key) else { continue }

            let matchScore = scoreText(analysis: queryAnalysis, text: safeText, topic: safeTopic, bm25Rank: nil)
            guard matchScore > 0 else { continue }

            let confidenceBoost = min(1.0, max(0.0, record.confidence)) * 0.5
            let hit = Hit(
                id: record.id,
                text: safeText,
                textSHA256: safeHash,
                topic: safeTopic,
                kind: record.kind,
                createdAtMs: record.createdAtMs,
                usedAtMs: record.usedAtMs,
                confidence: record.confidence,
                score: matchScore + confidenceBoost
            )
            let recency = record.usedAtMs ?? record.createdAtMs
            scored.append((hit: hit, recency: recency, updatedAt: record.updatedAtMs))
        }

        scored.sort { lhs, rhs in
            if lhs.hit.score != rhs.hit.score { return lhs.hit.score > rhs.hit.score }
            if lhs.recency != rhs.recency { return lhs.recency > rhs.recency }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.hit.id < rhs.hit.id
        }

        return boundedSelection(scored.map(\.hit), config: config)
    }

    /// Queries `.deep` memories from a `MemoryStore` using SQLite FTS5 indexing (`MemoryRecallIndex`)
    /// while respecting tombstones, suppressions, surface exclusion, and secret redaction.
    public static func recallFromStore(
        query: String,
        store: MemoryStore,
        index: MemoryRecallIndex? = nil,
        suppressedHashes: Set<String> = [],
        excludedIDs: Set<String> = [],
        secrets: [String] = [],
        config: Config = Config(),
        markUsedNowMs: Double? = nil
    ) throws -> [Hit] {
        let activeRecords = try store.list(layer: nil, includeDeleted: false, secrets: secrets)
        let storeSuppressed = try store.suppressedHashes()
        let combinedSuppressed = suppressedHashes.union(storeSuppressed)

        let surfaceTexts = activeRecords
            .filter { $0.layer == .pinned || $0.layer == .surface || $0.pinned }
            .map(\.text)

        let effectiveIndex = index ?? MemoryRecallIndex.inMemory()
        try effectiveIndex.sync(records: activeRecords, secrets: secrets)
        let hits = try effectiveIndex.searchDeep(
            query: query,
            surfaceTexts: surfaceTexts,
            excludedIDs: excludedIDs,
            suppressedHashes: combinedSuppressed,
            secrets: secrets,
            config: config
        )

        if let markUsedNowMs, !hits.isEmpty {
            let hitIDs = hits.map(\.id)
            try effectiveIndex.recordUsage(ids: hitIDs, nowMs: markUsedNowMs)
            for id in hitIDs {
                if var record = try store.record(id: id, includeDeleted: false),
                   record.layer == .deep,
                   !record.pinned {
                    record.usedAtMs = max(record.usedAtMs ?? 0, markUsedNowMs)
                    record.updatedAtMs = max(record.updatedAtMs, markUsedNowMs)
                    _ = try store.upsert(record, explicitUserAction: false, secrets: secrets)
                }
            }
        }

        return hits
    }

    static func boundedSelection(_ sortedHits: [Hit], config: Config) -> [Hit] {
        var result: [Hit] = []
        var seenKeys = Set<String>()
        var usedBytes = tailHeader.utf8.count
        for hit in sortedHits {
            guard result.count < config.limit else { break }
            let key = MemorySafety.normalizedFactKey(hit.text)
            guard !key.isEmpty, seenKeys.insert(key).inserted else { continue }
            let clipped = MemorySafety.clipUTF8(hit.text, bytes: config.maxItemBytes)
            let lineBytes = 3 + clipped.utf8.count // "\n- " + clipped
            if !result.isEmpty && usedBytes + lineBytes > config.maxBytes {
                break
            }
            var adjusted = hit
            adjusted.text = clipped
            result.append(adjusted)
            usedBytes += lineBytes
        }
        return result
    }

    /// Formats recalled `.deep` hints strictly for the volatile prompt tail.
    public static func formatTailBlock(
        _ hits: [Hit],
        secrets: [String] = [],
        maxBytes: Int = 1_200,
        maxItemBytes: Int = 240
    ) -> String {
        guard !hits.isEmpty else { return "" }
        let orderedSecrets = secrets.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        var lines: [String] = []
        var usedBytes = tailHeader.utf8.count
        var seenKeys = Set<String>()

        for hit in hits {
            let safe = MemorySafety.redactSecrets(hit.text, secrets: orderedSecrets)
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let withoutMask = safe.replacingOccurrences(of: "〔隐去〕", with: "")
            let key = MemorySafety.normalizedFactKey(withoutMask)
            guard !key.isEmpty, seenKeys.insert(key).inserted else { continue }

            let clipped = MemorySafety.clipUTF8(safe, bytes: maxItemBytes)
            guard !clipped.isEmpty else { continue }
            let line = "- \(clipped)"
            let lineBytes = 1 + line.utf8.count
            if !lines.isEmpty && usedBytes + lineBytes > maxBytes {
                break
            }
            lines.append(line)
            usedBytes += lineBytes
        }

        guard !lines.isEmpty else { return "" }
        return tailHeader + "\n" + lines.joined(separator: "\n")
    }
}

public enum MemoryRecallIndexRecoveryReason: String, Sendable, Equatable {
    case none
    case missing
    case externalDeletion
    case corrupt
    case schemaMismatch
    case incompleteBuild
}

public enum MemoryRecallIndexError: Error, Equatable, Sendable {
    case openFailed(code: Int32, message: String)
    case sqlite(code: Int32, message: String)
}

/// Self-healing SQLite3 + FTS5 index for Channel-1 `.deep` memory recall and lightweight recall usage stats.
/// Derived cache only (`Library/Caches/ClioIndex/clio-memory-recall-fts.db`); safe to delete/rebuild anytime.
public final class MemoryRecallIndex: @unchecked Sendable {
    public static let schemaVersion: Int32 = 1

    public static var isFTS5Supported: Bool {
        sqlite3_compileoption_used("ENABLE_FTS5") != 0
    }

    public static var defaultDatabaseURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches
            .appendingPathComponent("ClioIndex", isDirectory: true)
            .appendingPathComponent("clio-memory-recall-fts.db")
    }

    public let databaseURL: URL
    private let sqlitePath: String
    private let isInMemory: Bool
    private let forceDisableFTS5ForTesting: Bool
    private let lock = NSLock()
    private var db: OpaquePointer?
    private var openedIdentity: FileIdentity?
    private var fts5Active: Bool
    private var _lastRecoveryReason: MemoryRecallIndexRecoveryReason = .none
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
        case optionalDouble(Double?)
    }

    public convenience init(
        databaseURL: URL = MemoryRecallIndex.defaultDatabaseURL,
        forceDisableFTS5ForTesting: Bool = false
    ) {
        let inMem = databaseURL.path == ":memory:" || databaseURL.scheme == "sqlite"
        self.init(
            databaseURL: databaseURL,
            isInMemory: inMem,
            forceDisableFTS5ForTesting: forceDisableFTS5ForTesting
        )
    }

    public static func inMemory(forceDisableFTS5ForTesting: Bool = false) -> MemoryRecallIndex {
        MemoryRecallIndex(
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

    deinit {
        lock.lock()
        closeLocked()
        lock.unlock()
    }

    public var lastRecoveryReason: MemoryRecallIndexRecoveryReason {
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

    @discardableResult
    public func openOrRecover() throws -> MemoryRecallIndexRecoveryReason {
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

    /// Incrementally synchronizes active `.deep` memory rows into FTS5 while redacting Vault secrets.
    public func sync(records: [MemoryRecord], secrets: [String] = []) throws {
        let orderedSecrets = secrets.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        let secretsDigest = Self.secretsFingerprint(orderedSecrets)

        lock.lock()
        defer { lock.unlock() }
        _ = try openOrRecoverLocked()

        do {
            let stateMap = try readBuildStateMapLocked()
            let storedSecretsDigest = stateMap["secrets_digest"] ?? ""
            let secretsChanged = storedSecretsDigest != secretsDigest
            let existingFingerprints = try readStoredFingerprintsLocked()

            var desiredDeep: [String: (record: MemoryRecord, safeText: String, safeTopic: String, fingerprint: String)] = [:]
            for record in records {
                guard record.layer == .deep, !record.pinned, record.deletedAtMs == nil else { continue }
                let safeText = MemorySafety.redactSecrets(record.text, secrets: orderedSecrets)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let withoutMask = safeText.replacingOccurrences(of: "〔隐去〕", with: "")
                guard !MemorySafety.normalizedFactKey(withoutMask).isEmpty else { continue }
                let safeTopic = MemorySafety.redactSecrets(record.topic, secrets: orderedSecrets)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let fp = "\(MemorySafety.retractionHash(safeText))|\(record.updatedAtMs)|\(record.usedAtMs ?? 0)|\(record.confidence)|\(safeTopic)|\(record.kind)"
                desiredDeep[record.id] = (record, safeText, safeTopic, fp)
            }

            let toDelete = existingFingerprints.keys.filter { desiredDeep[$0] == nil }
            let toUpsert = desiredDeep.values.filter { entry in
                secretsChanged || _needsRebuildFromSource || existingFingerprints[entry.record.id] != entry.fingerprint
            }

            if toDelete.isEmpty && toUpsert.isEmpty && !secretsChanged && !_needsRebuildFromSource {
                return
            }

            try execLocked("BEGIN IMMEDIATE;")
            do {
                if secretsChanged {
                    try execLocked("DELETE FROM recall_records;")
                    for entry in desiredDeep.values {
                        try upsertRecordLocked(
                            entry.record,
                            safeText: entry.safeText,
                            safeTopic: entry.safeTopic,
                            fingerprint: entry.fingerprint
                        )
                    }
                } else {
                    for id in toDelete {
                        try runPreparedLocked(
                            "DELETE FROM recall_records WHERE memory_id = ?;",
                            bindings: [.text(id)]
                        )
                    }
                    for entry in toUpsert {
                        try upsertRecordLocked(
                            entry.record,
                            safeText: entry.safeText,
                            safeTopic: entry.safeTopic,
                            fingerprint: entry.fingerprint
                        )
                    }
                }
                try setBuildStateLocked("state", "ready")
                try setBuildStateLocked("schema_version", String(Self.schemaVersion))
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

    public func searchDeep(
        query: String,
        surfaceTexts: [String] = [],
        excludedIDs: Set<String> = [],
        suppressedHashes: Set<String> = [],
        secrets: [String] = [],
        config: MemoryRecall.Config = MemoryRecall.Config()
    ) throws -> [MemoryRecall.Hit] {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuery.isEmpty else { return [] }
        let queryAnalysis = MemoryRecall.analyzeQuery(cleanQuery)
        guard !queryAnalysis.isEmpty else { return [] }

        let orderedSecrets = secrets.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        let normalizedSuppressed = Set(suppressedHashes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        let surfaceKeys = Set(surfaceTexts.map {
            MemorySafety.normalizedFactKey(MemorySafety.redactSecrets($0, secrets: orderedSecrets))
        }.filter { !$0.isEmpty })

        lock.lock()
        defer { lock.unlock() }
        _ = try openOrRecoverLocked()

        var whereClauses = [
            "r.layer = 'deep'",
            "r.pinned = 0",
            "r.deleted_at_ms IS NULL",
        ]
        var bindings: [SQLBinding] = []

        if fts5Active {
            guard let matchExpression = MemoryRecall.buildFTS5OrMatchExpression(for: cleanQuery) else {
                return []
            }
            whereClauses.append("recall_fts MATCH ?")
            bindings.append(.text(matchExpression))
        } else {
            let terms = MemoryRecall.fallbackTerms(for: cleanQuery)
            guard !terms.isEmpty else { return [] }
            let likeClauses = terms.map { _ in "r.normalized_text LIKE ? ESCAPE '\\'" }
            whereClauses.append("(" + likeClauses.joined(separator: " OR ") + ")")
            for term in terms {
                bindings.append(.text("%\(Self.escapeLike(term))%"))
            }
        }

        let candidateCap = Int32(max(config.limit * 16, 80))
        bindings.append(.int(candidateCap))

        let sql: String
        if fts5Active {
            sql = """
            SELECT
                r.memory_id,
                r.text,
                r.text_sha256,
                r.topic,
                r.kind,
                r.confidence,
                r.created_at_ms,
                r.updated_at_ms,
                COALESCE(s.last_recalled_at_ms, r.used_at_ms) AS effective_used_ms,
                bm25(recall_fts) AS rank_score
            FROM recall_fts
            JOIN recall_records r ON r.row_id = recall_fts.rowid
            LEFT JOIN recall_stats s ON s.memory_id = r.memory_id
            WHERE \(whereClauses.joined(separator: " AND "))
            ORDER BY rank_score ASC, effective_used_ms DESC, r.created_at_ms DESC
            LIMIT ?;
            """
        } else {
            sql = """
            SELECT
                r.memory_id,
                r.text,
                r.text_sha256,
                r.topic,
                r.kind,
                r.confidence,
                r.created_at_ms,
                r.updated_at_ms,
                COALESCE(s.last_recalled_at_ms, r.used_at_ms) AS effective_used_ms,
                0.0 AS rank_score
            FROM recall_records r
            LEFT JOIN recall_stats s ON s.memory_id = r.memory_id
            WHERE \(whereClauses.joined(separator: " AND "))
            ORDER BY effective_used_ms DESC, r.created_at_ms DESC
            LIMIT ?;
            """
        }

        do {
            guard let db else { throw MemoryRecallIndexError.sqlite(code: SQLITE_MISUSE, message: "database closed") }
            var stmt: OpaquePointer?
            let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            guard rc == SQLITE_OK, let stmt else {
                throw sqliteErrorLocked(code: rc)
            }
            defer { sqlite3_finalize(stmt) }
            try bind(bindings, to: stmt)

            var candidates: [(hit: MemoryRecall.Hit, recency: Double, updatedAt: Double)] = []
            while true {
                let stepRC = sqlite3_step(stmt)
                if stepRC == SQLITE_ROW {
                    let id = Self.columnText(stmt, 0)
                    guard !excludedIDs.contains(id) else { continue }
                    let rawText = Self.columnText(stmt, 1)
                    let storedHash = Self.columnText(stmt, 2).lowercased()
                    let rawTopic = Self.columnText(stmt, 3)
                    let kind = Self.columnText(stmt, 4)
                    let confidence = sqlite3_column_double(stmt, 5)
                    let createdAtMs = sqlite3_column_double(stmt, 6)
                    let updatedAtMs = sqlite3_column_double(stmt, 7)
                    let usedAtMs = Self.columnOptionalDouble(stmt, 8)
                    let bm25Rank = sqlite3_column_double(stmt, 9)

                    let safeText = MemorySafety.redactSecrets(rawText, secrets: orderedSecrets)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let withoutMask = safeText.replacingOccurrences(of: "〔隐去〕", with: "")
                    guard !MemorySafety.normalizedFactKey(withoutMask).isEmpty else { continue }

                    let safeTopic = MemorySafety.redactSecrets(rawTopic, secrets: orderedSecrets)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let safeHash = MemorySafety.retractionHash(safeText)
                    guard !normalizedSuppressed.contains(storedHash),
                          !normalizedSuppressed.contains(safeHash),
                          !normalizedSuppressed.contains(MemorySafety.retractionHash(rawText)) else {
                        continue
                    }

                    let key = MemorySafety.normalizedFactKey(safeText)
                    guard !key.isEmpty, !surfaceKeys.contains(key) else { continue }

                    let relevance = MemoryRecall.scoreText(
                        analysis: queryAnalysis,
                        text: safeText,
                        topic: safeTopic,
                        bm25Rank: fts5Active ? bm25Rank : nil
                    )
                    guard relevance > 0 else { continue }

                    let confidenceBoost = min(1.0, max(0.0, confidence)) * 0.5
                    let hit = MemoryRecall.Hit(
                        id: id,
                        text: safeText,
                        textSHA256: safeHash,
                        topic: safeTopic,
                        kind: kind,
                        createdAtMs: createdAtMs,
                        usedAtMs: usedAtMs,
                        confidence: confidence,
                        score: relevance + confidenceBoost
                    )
                    let recency = usedAtMs ?? createdAtMs
                    candidates.append((hit: hit, recency: recency, updatedAt: updatedAtMs))
                } else if stepRC == SQLITE_DONE {
                    break
                } else {
                    throw sqliteErrorLocked(code: stepRC)
                }
            }

            candidates.sort { lhs, rhs in
                if lhs.hit.score != rhs.hit.score { return lhs.hit.score > rhs.hit.score }
                if lhs.recency != rhs.recency { return lhs.recency > rhs.recency }
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.hit.id < rhs.hit.id
            }

            return MemoryRecall.boundedSelection(candidates.map(\.hit), config: config)
        } catch {
            if isCorruptionError(error) {
                try? recreateFreshDatabaseLocked(reason: .corrupt)
                return []
            }
            throw error
        }
    }

    public func recordUsage(ids: [String], nowMs: Double) throws {
        let uniqueIDs = Array(Set(ids.filter { !$0.isEmpty })).sorted()
        guard !uniqueIDs.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }
        _ = try openOrRecoverLocked()

        do {
            try execLocked("BEGIN IMMEDIATE;")
            do {
                for id in uniqueIDs {
                    try runPreparedLocked(
                        """
                        INSERT INTO recall_stats(memory_id, last_recalled_at_ms, recall_count)
                        VALUES (?, ?, 1)
                        ON CONFLICT(memory_id) DO UPDATE SET
                            last_recalled_at_ms = CASE
                                WHEN excluded.last_recalled_at_ms > recall_stats.last_recalled_at_ms
                                THEN excluded.last_recalled_at_ms
                                ELSE recall_stats.last_recalled_at_ms
                            END,
                            recall_count = recall_stats.recall_count + 1;
                        """,
                        bindings: [.text(id), .double(nowMs)]
                    )
                    try runPreparedLocked(
                        """
                        UPDATE recall_records
                        SET used_at_ms = CASE
                            WHEN used_at_ms IS NULL OR used_at_ms < ? THEN ?
                            ELSE used_at_ms
                        END
                        WHERE memory_id = ?;
                        """,
                        bindings: [.double(nowMs), .double(nowMs), .text(id)]
                    )
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

    public func usageStats() throws -> [String: MemoryRecallUsageStat] {
        lock.lock()
        defer { lock.unlock() }
        _ = try openOrRecoverLocked()
        guard let db else { throw MemoryRecallIndexError.sqlite(code: SQLITE_MISUSE, message: "database closed") }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(
            db,
            "SELECT memory_id, last_recalled_at_ms, recall_count FROM recall_stats;",
            -1,
            &stmt,
            nil
        )
        guard rc == SQLITE_OK, let stmt else { throw sqliteErrorLocked(code: rc) }
        defer { sqlite3_finalize(stmt) }
        var result: [String: MemoryRecallUsageStat] = [:]
        while true {
            let stepRC = sqlite3_step(stmt)
            if stepRC == SQLITE_ROW {
                let id = Self.columnText(stmt, 0)
                let lastAt = sqlite3_column_double(stmt, 1)
                let count = Int(sqlite3_column_int64(stmt, 2))
                result[id] = MemoryRecallUsageStat(lastRecalledAtMs: lastAt, recallCount: count)
            } else if stepRC == SQLITE_DONE {
                break
            } else {
                throw sqliteErrorLocked(code: stepRC)
            }
        }
        return result
    }

    // MARK: - Private SQLite Lifecycle & Self-Healing

    private func openOrRecoverLocked() throws -> MemoryRecallIndexRecoveryReason {
        if db != nil {
            if isInMemory {
                return .none
            }
            if let currentIdentity = Self.fileIdentity(databaseURL), currentIdentity == openedIdentity {
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
                let reason: MemoryRecallIndexRecoveryReason = isCorruptionError(error) ? .corrupt : .schemaMismatch
                try recreateFreshDatabaseLocked(reason: reason)
                return reason
            }
        } else {
            try recreateFreshDatabaseLocked(reason: recovery)
            return recovery
        }
    }

    private func validateOpenedDatabaseLocked() -> MemoryRecallIndexRecoveryReason {
        do {
            try execLocked("PRAGMA busy_timeout = 5000;")
            let check = try scalarStringLocked("PRAGMA quick_check(1);")
            guard check == "ok" else { return .corrupt }

            let userVer = try scalarInt32Locked("PRAGMA user_version;")
            guard userVer == Self.schemaVersion else { return .schemaMismatch }

            let expectedTables: Set<String> = fts5Active
                ? ["build_state", "recall_records", "recall_stats", "recall_fts"]
                : ["build_state", "recall_records", "recall_stats"]
            let foundTables = try existingTableNamesLocked()
            guard expectedTables.isSubset(of: foundTables) else { return .schemaMismatch }

            let stateMap = try readBuildStateMapLocked()
            guard stateMap["state"] == "ready" else { return .incompleteBuild }
            guard stateMap["schema_version"] == String(Self.schemaVersion) else { return .schemaMismatch }
            let expectedFTS = fts5Active ? "1" : "0"
            guard stateMap["fts5_enabled"] == expectedFTS else { return .schemaMismatch }
            return .none
        } catch {
            return isCorruptionError(error) ? .corrupt : .schemaMismatch
        }
    }

    private func recreateFreshDatabaseLocked(reason: MemoryRecallIndexRecoveryReason) throws {
        closeLocked()
        if !isInMemory {
            unlinkDatabaseFiles()
        }
        try createFreshDatabaseLocked(reason: reason)
    }

    private func createFreshDatabaseLocked(reason: MemoryRecallIndexRecoveryReason) throws {
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
            throw MemoryRecallIndexError.openFailed(code: rc, message: msg)
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
            CREATE TABLE recall_records (
                row_id INTEGER PRIMARY KEY AUTOINCREMENT,
                memory_id TEXT NOT NULL UNIQUE,
                text TEXT NOT NULL,
                text_sha256 TEXT NOT NULL,
                layer TEXT NOT NULL,
                pinned INTEGER NOT NULL DEFAULT 0,
                kind TEXT NOT NULL DEFAULT 'fact',
                topic TEXT NOT NULL DEFAULT '',
                confidence REAL NOT NULL DEFAULT 1.0,
                created_at_ms REAL NOT NULL,
                updated_at_ms REAL NOT NULL,
                used_at_ms REAL,
                deleted_at_ms REAL,
                normalized_text TEXT NOT NULL DEFAULT '',
                body_tokens TEXT NOT NULL DEFAULT '',
                cjk_unigrams TEXT NOT NULL DEFAULT '',
                sync_fingerprint TEXT NOT NULL DEFAULT ''
            );
            """)
            try execLocked("CREATE INDEX idx_recall_records_layer ON recall_records(layer, pinned, deleted_at_ms, used_at_ms DESC);")
            try execLocked("""
            CREATE TABLE recall_stats (
                memory_id TEXT PRIMARY KEY,
                last_recalled_at_ms REAL NOT NULL,
                recall_count INTEGER NOT NULL DEFAULT 0
            );
            """)

            if fts5Active {
                do {
                    try execLocked("""
                    CREATE VIRTUAL TABLE recall_fts USING fts5(
                        body_tokens,
                        cjk_unigrams,
                        content='recall_records',
                        content_rowid='row_id',
                        tokenize='unicode61 remove_diacritics 2'
                    );
                    """)
                    try execLocked("""
                    CREATE TRIGGER recall_records_ai AFTER INSERT ON recall_records BEGIN
                        INSERT INTO recall_fts(rowid, body_tokens, cjk_unigrams)
                        VALUES (new.row_id, new.body_tokens, new.cjk_unigrams);
                    END;
                    """)
                    try execLocked("""
                    CREATE TRIGGER recall_records_ad AFTER DELETE ON recall_records BEGIN
                        INSERT INTO recall_fts(recall_fts, rowid, body_tokens, cjk_unigrams)
                        VALUES ('delete', old.row_id, old.body_tokens, old.cjk_unigrams);
                    END;
                    """)
                    try execLocked("""
                    CREATE TRIGGER recall_records_au AFTER UPDATE ON recall_records BEGIN
                        INSERT INTO recall_fts(recall_fts, rowid, body_tokens, cjk_unigrams)
                        VALUES ('delete', old.row_id, old.body_tokens, old.cjk_unigrams);
                        INSERT INTO recall_fts(rowid, body_tokens, cjk_unigrams)
                        VALUES (new.row_id, new.body_tokens, new.cjk_unigrams);
                    END;
                    """)
                } catch {
                    fts5Active = false
                }
            }

            try setBuildStateLocked("state", "ready")
            try setBuildStateLocked("schema_version", String(Self.schemaVersion))
            try setBuildStateLocked("secrets_digest", "")
            try setBuildStateLocked("fts5_enabled", fts5Active ? "1" : "0")
            try execLocked("PRAGMA user_version = \(Self.schemaVersion);")
            try execLocked("COMMIT;")
        } catch {
            try? execLocked("ROLLBACK;")
            throw error
        }
    }

    private func upsertRecordLocked(
        _ record: MemoryRecord,
        safeText: String,
        safeTopic: String,
        fingerprint: String
    ) throws {
        let indexable = safeTopic.isEmpty ? safeText : "\(safeText) \(safeTopic)"
        let normalized = MemoryIndexTokenizer.normalize(indexable)
        let tokens = MemoryIndexTokenizer.indexTokens(for: indexable)
        let sql = """
        INSERT INTO recall_records (
            memory_id, text, text_sha256, layer, pinned, kind, topic, confidence,
            created_at_ms, updated_at_ms, used_at_ms, deleted_at_ms,
            normalized_text, body_tokens, cjk_unigrams, sync_fingerprint
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(memory_id) DO UPDATE SET
            text = excluded.text,
            text_sha256 = excluded.text_sha256,
            layer = excluded.layer,
            pinned = excluded.pinned,
            kind = excluded.kind,
            topic = excluded.topic,
            confidence = excluded.confidence,
            created_at_ms = excluded.created_at_ms,
            updated_at_ms = excluded.updated_at_ms,
            used_at_ms = excluded.used_at_ms,
            deleted_at_ms = excluded.deleted_at_ms,
            normalized_text = excluded.normalized_text,
            body_tokens = excluded.body_tokens,
            cjk_unigrams = excluded.cjk_unigrams,
            sync_fingerprint = excluded.sync_fingerprint;
        """
        try runPreparedLocked(sql, bindings: [
            .text(record.id),
            .text(safeText),
            .text(MemorySafety.retractionHash(safeText)),
            .text(record.layer.rawValue),
            .int(record.pinned ? 1 : 0),
            .text(record.kind),
            .text(safeTopic),
            .double(min(1.0, max(0.0, record.confidence))),
            .double(record.createdAtMs),
            .double(record.updatedAtMs),
            .optionalDouble(record.usedAtMs),
            .optionalDouble(record.deletedAtMs),
            .text(normalized),
            .text(tokens.bodyTokens),
            .text(tokens.cjkUnigrams),
            .text(fingerprint),
        ])
    }

    private func readStoredFingerprintsLocked() throws -> [String: String] {
        guard let db else { throw MemoryRecallIndexError.sqlite(code: SQLITE_MISUSE, message: "database closed") }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, "SELECT memory_id, sync_fingerprint FROM recall_records;", -1, &stmt, nil)
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
        guard let db else { throw MemoryRecallIndexError.sqlite(code: SQLITE_MISUSE, message: "database closed") }
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
        guard let db else { throw MemoryRecallIndexError.sqlite(code: SQLITE_MISUSE, message: "database closed") }
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
        guard let db else { throw MemoryRecallIndexError.sqlite(code: SQLITE_MISUSE, message: "database closed") }
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
                    sqlite3_bind_text(stmt, index, cStr, -1, memoryRecallSQLiteTransient)
                }
            case .int(let intVal):
                rc = sqlite3_bind_int(stmt, index, intVal)
            case .int64(let int64Val):
                rc = sqlite3_bind_int64(stmt, index, int64Val)
            case .double(let doubleVal):
                rc = sqlite3_bind_double(stmt, index, doubleVal)
            case .optionalDouble(let optional):
                if let doubleVal = optional {
                    rc = sqlite3_bind_double(stmt, index, doubleVal)
                } else {
                    rc = sqlite3_bind_null(stmt, index)
                }
            }
            guard rc == SQLITE_OK else { throw sqliteErrorLocked(code: rc) }
        }
    }

    private func execLocked(_ sql: String) throws {
        guard let db else { throw MemoryRecallIndexError.sqlite(code: SQLITE_MISUSE, message: "database closed") }
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            if let errMsg { sqlite3_free(errMsg) }
            throw MemoryRecallIndexError.sqlite(code: rc, message: msg)
        }
    }

    private func scalarStringLocked(_ sql: String) throws -> String {
        guard let db else { throw MemoryRecallIndexError.sqlite(code: SQLITE_MISUSE, message: "database closed") }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw sqliteErrorLocked(code: rc) }
        defer { sqlite3_finalize(stmt) }
        let stepRC = sqlite3_step(stmt)
        guard stepRC == SQLITE_ROW else { throw sqliteErrorLocked(code: stepRC) }
        return Self.columnText(stmt, 0)
    }

    private func scalarInt32Locked(_ sql: String) throws -> Int32 {
        guard let db else { throw MemoryRecallIndexError.sqlite(code: SQLITE_MISUSE, message: "database closed") }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw sqliteErrorLocked(code: rc) }
        defer { sqlite3_finalize(stmt) }
        let stepRC = sqlite3_step(stmt)
        guard stepRC == SQLITE_ROW else { throw sqliteErrorLocked(code: stepRC) }
        return sqlite3_column_int(stmt, 0)
    }

    private func sqliteErrorLocked(code: Int32) -> MemoryRecallIndexError {
        let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite error \(code)"
        return .sqlite(code: code, message: msg)
    }

    private func isCorruptionError(_ error: Error) -> Bool {
        guard case .sqlite(let code, _) = error as? MemoryRecallIndexError else { return false }
        let primary = code & 0xFF
        return primary == SQLITE_CORRUPT || primary == SQLITE_NOTADB
    }

    private static func columnText(_ stmt: OpaquePointer?, _ column: Int32) -> String {
        guard let cString = sqlite3_column_text(stmt, column) else { return "" }
        return String(cString: cString)
    }

    private static func columnOptionalDouble(_ stmt: OpaquePointer?, _ column: Int32) -> Double? {
        guard let stmt, sqlite3_column_type(stmt, column) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(stmt, column)
    }

    private static func escapeLike(_ term: String) -> String {
        term
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static func secretsFingerprint(_ orderedSecrets: [String]) -> String {
        guard !orderedSecrets.isEmpty else { return "" }
        let joined = orderedSecrets.joined(separator: "\u{1F}")
        return sha256Hex(Data(joined.utf8))
    }

    private static func sha256Hex(_ data: Data) -> String {
        #if canImport(CryptoKit)
        let digest = CryptoKit.SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
        #else
        return MemorySafety.retractionHash(String(decoding: data, as: UTF8.self))
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
}

/// Thread-safe live refresher wrapping `MemorySafety.SystemPromptInput` + `PromptState` + volatile Channel-1 `.deep` recall hits.
/// Invariant: recalled `.deep` hints are placed EXCLUSIVELY in `tail` (`extraTail`), keeping `prefix` (`systemCachePrefix`)
/// 100% byte-identical across all user queries while immediately removing any deleted/retracted/promoted memories mid-turn.
public final class MemoryRecallPromptRefresher: @unchecked Sendable {
    private let lock = NSLock()
    private var baseInput: MemorySafety.SystemPromptInput
    private let state: MemorySafety.PromptState
    private var recalledHits: [MemoryRecall.Hit]
    private var lastObservedGeneration: UInt64
    private var lastObservedMemoryEnabled: Bool
    private var lastObservedRecallAllowed: Bool
    private var lastObservedSecretsDigest: String
    private let isRecallAllowed: @Sendable () -> Bool
    private let isMemoryEnabled: @Sendable () -> Bool
    private let activeSecrets: @Sendable () -> [String]
    private var snapshot: MemorySafety.AssembledSystemPrompt

    public init(
        input: MemorySafety.SystemPromptInput,
        state: MemorySafety.PromptState,
        recalledHits: [MemoryRecall.Hit] = [],
        isRecallAllowed: @escaping @Sendable () -> Bool = { true },
        isMemoryEnabled: @escaping @Sendable () -> Bool = { true },
        activeSecrets: @escaping @Sendable () -> [String] = { [] }
    ) {
        let gen = state.currentGeneration
        let memoryEnabled = isMemoryEnabled()
        let allowed = isRecallAllowed()
        let orderedSecrets = Self.orderSecrets(activeSecrets())
        let secretsDigest = Self.secretsFingerprint(orderedSecrets)
        let retractedIDs = state.retractedIDsSnapshot()
        let suppressedHashes = state.suppressedFlushHashesSnapshot()
        let reconciled = Self.reconcileHits(
            recalledHits,
            against: input.memories,
            retractedIDs: retractedIDs,
            suppressedHashes: suppressedHashes,
            excludingIDs: input.excludingMemoryIDs,
            excludingTexts: input.excludingMemoryTexts,
            orderedSecrets: orderedSecrets
        )

        self.baseInput = input
        self.state = state
        self.recalledHits = reconciled
        self.lastObservedGeneration = gen
        self.lastObservedMemoryEnabled = memoryEnabled
        self.lastObservedRecallAllowed = allowed
        self.lastObservedSecretsDigest = secretsDigest
        self.isRecallAllowed = isRecallAllowed
        self.isMemoryEnabled = isMemoryEnabled
        self.activeSecrets = activeSecrets
        self.snapshot = Self.buildSnapshot(
            baseInput: input,
            state: state,
            recalledHits: reconciled,
            memoryEnabled: memoryEnabled,
            recallAllowed: allowed,
            orderedSecrets: orderedSecrets
        )
    }

    public func currentPrompt() -> MemorySafety.AssembledSystemPrompt {
        let gen = state.currentGeneration
        let memoryEnabled = isMemoryEnabled()
        let allowed = isRecallAllowed()
        let orderedSecrets = Self.orderSecrets(activeSecrets())
        let secretsDigest = Self.secretsFingerprint(orderedSecrets)
        lock.lock()
        defer { lock.unlock() }
        if gen != lastObservedGeneration
            || memoryEnabled != lastObservedMemoryEnabled
            || allowed != lastObservedRecallAllowed
            || secretsDigest != lastObservedSecretsDigest {
            let retractedIDs = state.retractedIDsSnapshot()
            let suppressedHashes = state.suppressedFlushHashesSnapshot()
            recalledHits = Self.reconcileHits(
                recalledHits,
                against: baseInput.memories,
                retractedIDs: retractedIDs,
                suppressedHashes: suppressedHashes,
                excludingIDs: baseInput.excludingMemoryIDs,
                excludingTexts: baseInput.excludingMemoryTexts,
                orderedSecrets: orderedSecrets
            )
            lastObservedGeneration = gen
            lastObservedMemoryEnabled = memoryEnabled
            lastObservedRecallAllowed = allowed
            lastObservedSecretsDigest = secretsDigest
            snapshot = Self.buildSnapshot(
                baseInput: baseInput,
                state: state,
                recalledHits: recalledHits,
                memoryEnabled: memoryEnabled,
                recallAllowed: allowed,
                orderedSecrets: orderedSecrets
            )
        }
        return snapshot
    }

    public func refresh(memories: [MemorySafety.Fact]) {
        let gen = state.currentGeneration
        let memoryEnabled = isMemoryEnabled()
        let allowed = isRecallAllowed()
        let retractedIDs = state.retractedIDsSnapshot()
        let suppressedHashes = state.suppressedFlushHashesSnapshot()
        let orderedSecrets = Self.orderSecrets(activeSecrets())
        let secretsDigest = Self.secretsFingerprint(orderedSecrets)

        lock.lock()
        baseInput.memories = memories
        recalledHits = Self.reconcileHits(
            recalledHits,
            against: memories,
            retractedIDs: retractedIDs,
            suppressedHashes: suppressedHashes,
            excludingIDs: baseInput.excludingMemoryIDs,
            excludingTexts: baseInput.excludingMemoryTexts,
            orderedSecrets: orderedSecrets
        )
        lastObservedGeneration = gen
        lastObservedMemoryEnabled = memoryEnabled
        lastObservedRecallAllowed = allowed
        lastObservedSecretsDigest = secretsDigest
        snapshot = Self.buildSnapshot(
            baseInput: baseInput,
            state: state,
            recalledHits: recalledHits,
            memoryEnabled: memoryEnabled,
            recallAllowed: allowed,
            orderedSecrets: orderedSecrets
        )
        lock.unlock()
    }

    public func updateRecalledHits(_ hits: [MemoryRecall.Hit]) {
        let gen = state.currentGeneration
        let memoryEnabled = isMemoryEnabled()
        let allowed = isRecallAllowed()
        let retractedIDs = state.retractedIDsSnapshot()
        let suppressedHashes = state.suppressedFlushHashesSnapshot()
        let orderedSecrets = Self.orderSecrets(activeSecrets())
        let secretsDigest = Self.secretsFingerprint(orderedSecrets)

        lock.lock()
        recalledHits = Self.reconcileHits(
            hits,
            against: baseInput.memories,
            retractedIDs: retractedIDs,
            suppressedHashes: suppressedHashes,
            excludingIDs: baseInput.excludingMemoryIDs,
            excludingTexts: baseInput.excludingMemoryTexts,
            orderedSecrets: orderedSecrets
        )
        lastObservedGeneration = gen
        lastObservedMemoryEnabled = memoryEnabled
        lastObservedRecallAllowed = allowed
        lastObservedSecretsDigest = secretsDigest
        snapshot = Self.buildSnapshot(
            baseInput: baseInput,
            state: state,
            recalledHits: recalledHits,
            memoryEnabled: memoryEnabled,
            recallAllowed: allowed,
            orderedSecrets: orderedSecrets
        )
        lock.unlock()
    }

    /// Reconciles recalled hits against live `baseInput.memories` so entries that were deleted,
    /// archived, promoted to `.surface`/`.pinned`, retracted, excluded, or updated mid-turn
    /// never leak stale or unredacted content into the volatile prompt tail.
    private static func reconcileHits(
        _ hits: [MemoryRecall.Hit],
        against memories: [MemorySafety.Fact],
        retractedIDs: Set<String>,
        suppressedHashes: Set<String>,
        excludingIDs: Set<String>,
        excludingTexts: Set<String>,
        orderedSecrets: [String]
    ) -> [MemoryRecall.Hit] {
        let factsByID = Dictionary(
            memories.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        let excludedNormalized = Set(excludingTexts.map(MemorySafety.normalizedFactKey).filter { !$0.isEmpty })
        var valid: [MemoryRecall.Hit] = []
        valid.reserveCapacity(hits.count)

        for var hit in hits {
            guard !retractedIDs.contains(hit.id), !excludingIDs.contains(hit.id) else {
                continue
            }
            if !hit.textSHA256.isEmpty && suppressedHashes.contains(hit.textSHA256.lowercased()) {
                continue
            }
            guard let liveFact = factsByID[hit.id], liveFact.isDeep else {
                continue
            }
            let rawKey = MemorySafety.normalizedFactKey(liveFact.text)
            let safeText = MemorySafety.redactSecrets(liveFact.text, secrets: orderedSecrets)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let normKey = MemorySafety.normalizedFactKey(safeText)
            guard !safeText.isEmpty,
                  !normKey.isEmpty,
                  !excludedNormalized.contains(normKey),
                  !excludedNormalized.contains(rawKey) else {
                continue
            }
            let rawHash = MemorySafety.retractionHash(liveFact.text)
            let computedHash = MemorySafety.retractionHash(safeText)
            if (!rawHash.isEmpty && suppressedHashes.contains(rawHash))
                || (!computedHash.isEmpty && suppressedHashes.contains(computedHash)) {
                continue
            }
            hit.text = safeText
            hit.textSHA256 = computedHash
            valid.append(hit)
        }
        return valid
    }

    private static func buildSnapshot(
        baseInput: MemorySafety.SystemPromptInput,
        state: MemorySafety.PromptState,
        recalledHits: [MemoryRecall.Hit],
        memoryEnabled: Bool,
        recallAllowed: Bool,
        orderedSecrets: [String]
    ) -> MemorySafety.AssembledSystemPrompt {
        let effectiveMemoryEnabled = baseInput.memoryEnabled && memoryEnabled
        let retractedIDs = state.retractedIDsSnapshot()
        let suppressedHashes = state.suppressedFlushHashesSnapshot()
        let effectiveHits: [MemoryRecall.Hit]
        if effectiveMemoryEnabled && recallAllowed {
            effectiveHits = reconcileHits(
                recalledHits,
                against: baseInput.memories,
                retractedIDs: retractedIDs,
                suppressedHashes: suppressedHashes,
                excludingIDs: baseInput.excludingMemoryIDs,
                excludingTexts: baseInput.excludingMemoryTexts,
                orderedSecrets: orderedSecrets
            )
        } else {
            effectiveHits = []
        }

        let recallBlock = MemoryRecall.formatTailBlock(effectiveHits, secrets: orderedSecrets)
        let baseExtra = baseInput.extraTail?.trimmingCharacters(in: .newlines) ?? ""
        let combinedTailParts = [baseExtra, recallBlock].filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        var effectiveInput = baseInput
        effectiveInput.memoryEnabled = effectiveMemoryEnabled
        effectiveInput.extraTail = combinedTailParts.isEmpty ? nil : combinedTailParts.joined(separator: "\n\n")
        return MemorySafety.assembleSystemPrompt(effectiveInput, state: state)
    }

    private static func orderSecrets(_ secrets: [String]) -> [String] {
        secrets.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
    }

    private static func secretsFingerprint(_ orderedSecrets: [String]) -> String {
        guard !orderedSecrets.isEmpty else { return "" }
        let joined = orderedSecrets.joined(separator: "\u{1F}")
        #if canImport(CryptoKit)
        let digest = CryptoKit.SHA256.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
        #else
        return MemorySafety.retractionHash(joined)
        #endif
    }
}

/// Deterministic nightly lifecycle policy evaluating `.pinned`, `.surface`, and `.deep` `MemoryRecord` entries.
public enum MemoryPromotionPolicy: Sendable {
    public struct Config: Equatable, Sendable {
        public var surfaceLimit: Int
        public var gracePeriodMs: Double
        public var promoteRecencyWindowMs: Double
        public var minRecallCountForPromotion: Int
        public var maxPromotionsPerRun: Int
        public var maxDemotionsPerRun: Int
        public var maxArchivalsPerRun: Int
        public var surfaceStaleAgeMs: Double
        public var deepAutoArchiveAgeMs: Double
        public var deepManualArchiveAgeMs: Double

        public static let `default` = Config()

        public init(
            surfaceLimit: Int = 40,
            gracePeriodMs: Double = 3 * 86_400_000,
            promoteRecencyWindowMs: Double = 7 * 86_400_000,
            minRecallCountForPromotion: Int = 2,
            maxPromotionsPerRun: Int = 5,
            maxDemotionsPerRun: Int = 8,
            maxArchivalsPerRun: Int = 12,
            surfaceStaleAgeMs: Double = 21 * 86_400_000,
            deepAutoArchiveAgeMs: Double = 45 * 86_400_000,
            deepManualArchiveAgeMs: Double = 120 * 86_400_000
        ) {
            self.surfaceLimit = max(0, surfaceLimit)
            self.gracePeriodMs = max(0, gracePeriodMs)
            self.promoteRecencyWindowMs = max(0, promoteRecencyWindowMs)
            self.minRecallCountForPromotion = max(1, minRecallCountForPromotion)
            self.maxPromotionsPerRun = max(0, maxPromotionsPerRun)
            self.maxDemotionsPerRun = max(0, maxDemotionsPerRun)
            self.maxArchivalsPerRun = max(0, maxArchivalsPerRun)
            self.surfaceStaleAgeMs = max(0, surfaceStaleAgeMs)
            self.deepAutoArchiveAgeMs = max(0, deepAutoArchiveAgeMs)
            self.deepManualArchiveAgeMs = max(0, deepManualArchiveAgeMs)
        }
    }

    public struct Plan: Equatable, Sendable {
        public var promoteToSurface: [String]
        public var demoteToDeep: [String]
        public var archiveIDs: [String]
        public var refreshedUsedAtMs: [String: Double]

        public init(
            promoteToSurface: [String] = [],
            demoteToDeep: [String] = [],
            archiveIDs: [String] = [],
            refreshedUsedAtMs: [String: Double] = [:]
        ) {
            self.promoteToSurface = promoteToSurface
            self.demoteToDeep = demoteToDeep
            self.archiveIDs = archiveIDs
            self.refreshedUsedAtMs = refreshedUsedAtMs
        }

        public var isEmpty: Bool {
            promoteToSurface.isEmpty && demoteToDeep.isEmpty && archiveIDs.isEmpty && refreshedUsedAtMs.isEmpty
        }
    }

    private struct EvaluatedRecord {
        let record: MemoryRecord
        let stat: MemoryRecallUsageStat?
        let effectiveUsedAtMs: Double?
        let lastActivityMs: Double
        let inGracePeriod: Bool
        let isPinned: Bool
    }

    public static func evaluate(
        records: [MemoryRecord],
        usageStats: [String: MemoryRecallUsageStat] = [:],
        suppressedHashes: Set<String> = [],
        nowMs: Double,
        config: Config = .default
    ) -> Plan {
        let normalizedSuppressed = Set(suppressedHashes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })

        // Filter out tombstones (`deletedAtMs != nil`), suppressed records, and already archived entries.
        let active: [EvaluatedRecord] = records.compactMap { record in
            guard record.deletedAtMs == nil, record.layer != .archived else { return nil }
            let rawHash = record.textSHA256.lowercased()
            let computedHash = MemorySafety.retractionHash(record.text)
            if !normalizedSuppressed.isEmpty,
               (normalizedSuppressed.contains(rawHash) || (!computedHash.isEmpty && normalizedSuppressed.contains(computedHash))) {
                return nil
            }

            let stat = usageStats[record.id]
            let statUsed = stat?.lastRecalledAtMs ?? 0
            let recordUsed = record.usedAtMs ?? 0
            let maxUsed = max(statUsed, recordUsed)
            let effectiveUsed: Double? = maxUsed > 0 ? maxUsed : nil

            let editedActivity = record.editedByUser ? record.updatedAtMs : 0
            let lastActivity = max(record.createdAtMs, max(maxUsed, editedActivity))
            let ageMs = nowMs - lastActivity
            let inGrace = ageMs < config.gracePeriodMs
            let isPinned = record.pinned || record.layer == .pinned

            return EvaluatedRecord(
                record: record,
                stat: stat,
                effectiveUsedAtMs: effectiveUsed,
                lastActivityMs: lastActivity,
                inGracePeriod: inGrace,
                isPinned: isPinned
            )
        }

        var refreshedUsedAtMs: [String: Double] = [:]
        for item in active {
            if let statUsed = item.stat?.lastRecalledAtMs,
               statUsed > (item.record.usedAtMs ?? 0) {
                refreshedUsedAtMs[item.record.id] = statUsed
            }
        }

        let pinnedCount = active.filter(\.isPinned).count
        let surfaceItems = active.filter { !$0.isPinned && $0.record.layer == .surface }
        let deepItems = active.filter { !$0.isPinned && $0.record.layer == .deep }

        // Phase A: Demote stale unpinned `.surface` -> `.deep` (protecting pinned & grace period).
        var demoteCandidates = surfaceItems.filter { item in
            guard !item.inGracePeriod else { return false }
            let age = nowMs - item.lastActivityMs
            return age >= config.surfaceStaleAgeMs
        }
        demoteCandidates.sort { lhs, rhs in
            let lAuto = lhs.record.automatic && !lhs.record.editedByUser
            let rAuto = rhs.record.automatic && !rhs.record.editedByUser
            if lAuto != rAuto { return lAuto && !rAuto }
            if lhs.lastActivityMs != rhs.lastActivityMs { return lhs.lastActivityMs < rhs.lastActivityMs }
            if lhs.record.createdAtMs != rhs.record.createdAtMs { return lhs.record.createdAtMs < rhs.record.createdAtMs }
            return lhs.record.id < rhs.record.id
        }
        var demotedIDs = Array(demoteCandidates.prefix(config.maxDemotionsPerRun).map(\.record.id))
        var demotedSet = Set(demotedIDs)

        // If surface + pinned STILL exceeds `surfaceLimit`, sink oldest unpinned non-grace-period surface entries.
        let remainingSurfaceAfterStale = surfaceItems.filter { !demotedSet.contains($0.record.id) }
        let overflowCount = (pinnedCount + remainingSurfaceAfterStale.count) - config.surfaceLimit
        if overflowCount > 0 {
            let overflowCandidates = remainingSurfaceAfterStale
                .filter { !$0.inGracePeriod }
                .sorted { lhs, rhs in
                    let lAuto = lhs.record.automatic && !lhs.record.editedByUser
                    let rAuto = rhs.record.automatic && !rhs.record.editedByUser
                    if lAuto != rAuto { return lAuto && !rAuto }
                    if lhs.lastActivityMs != rhs.lastActivityMs { return lhs.lastActivityMs < rhs.lastActivityMs }
                    return lhs.record.id < rhs.record.id
                }
            for item in overflowCandidates.prefix(overflowCount) {
                demotedIDs.append(item.record.id)
                demotedSet.insert(item.record.id)
            }
        }

        // Phase B: Archive very stale unpinned `.deep` -> `.archived` (preferring untouched automatic over editedByUser).
        var archiveCandidates = deepItems.filter { item in
            guard !item.inGracePeriod else { return false }
            let age = nowMs - item.lastActivityMs
            let isUntouchedAuto = item.record.automatic && !item.record.editedByUser
            let threshold = isUntouchedAuto ? config.deepAutoArchiveAgeMs : config.deepManualArchiveAgeMs
            return age >= threshold
        }
        archiveCandidates.sort { lhs, rhs in
            let lAuto = lhs.record.automatic && !lhs.record.editedByUser
            let rAuto = rhs.record.automatic && !rhs.record.editedByUser
            if lAuto != rAuto { return lAuto && !rAuto }
            if lhs.record.editedByUser != rhs.record.editedByUser {
                return !lhs.record.editedByUser && rhs.record.editedByUser
            }
            let lCount = lhs.stat?.recallCount ?? 0
            let rCount = rhs.stat?.recallCount ?? 0
            if lCount != rCount { return lCount < rCount }
            if lhs.record.confidence != rhs.record.confidence { return lhs.record.confidence < rhs.record.confidence }
            if lhs.lastActivityMs != rhs.lastActivityMs { return lhs.lastActivityMs < rhs.lastActivityMs }
            return lhs.record.id < rhs.record.id
        }
        let archiveIDs = Array(archiveCandidates.prefix(config.maxArchivalsPerRun).map(\.record.id))
        let archiveSet = Set(archiveIDs)

        // Phase C: Promote frequently / recently recalled `.deep` -> `.surface`, strictly bounded by `surfaceLimit`.
        // `.deep` entries without recorded Channel-1 recalls (`stat == nil`) or below `minRecallCountForPromotion`
        // must never auto-promote on night 1 (prevents fighting `setDeep(_:true)` or `settleMemory`).
        var promotionCandidates = deepItems.filter { item in
            guard !archiveSet.contains(item.record.id) else { return false }
            guard let stat = item.stat else { return false }
            guard stat.recallCount >= config.minRecallCountForPromotion else { return false }
            guard stat.lastRecalledAtMs > 0 else { return false }
            let recency = nowMs - stat.lastRecalledAtMs
            return recency >= 0 && recency <= config.promoteRecencyWindowMs
        }
        promotionCandidates.sort { lhs, rhs in
            let lCount = lhs.stat?.recallCount ?? 0
            let rCount = rhs.stat?.recallCount ?? 0
            if lCount != rCount { return lCount > rCount }
            let lUsed = lhs.effectiveUsedAtMs ?? 0
            let rUsed = rhs.effectiveUsedAtMs ?? 0
            if lUsed != rUsed { return lUsed > rUsed }
            if lhs.record.confidence != rhs.record.confidence { return lhs.record.confidence > rhs.record.confidence }
            if lhs.record.editedByUser != rhs.record.editedByUser {
                return lhs.record.editedByUser && !rhs.record.editedByUser
            }
            return lhs.record.id < rhs.record.id
        }

        let survivingSurface = surfaceItems.filter { !demotedSet.contains($0.record.id) }
        var availableSlots = max(0, config.surfaceLimit - (pinnedCount + survivingSurface.count))
        var swappableSurface = survivingSurface
            .filter { !$0.inGracePeriod }
            .sorted { lhs, rhs in
                let lAuto = lhs.record.automatic && !lhs.record.editedByUser
                let rAuto = rhs.record.automatic && !rhs.record.editedByUser
                if lAuto != rAuto { return lAuto && !rAuto }
                if lhs.lastActivityMs != rhs.lastActivityMs { return lhs.lastActivityMs < rhs.lastActivityMs }
                return lhs.record.id < rhs.record.id
            }

        var promotedIDs: [String] = []
        for candidate in promotionCandidates {
            guard promotedIDs.count < config.maxPromotionsPerRun else { break }
            if availableSlots > 0 {
                promotedIDs.append(candidate.record.id)
                availableSlots -= 1
            } else if let coldest = swappableSurface.first,
                      (candidate.effectiveUsedAtMs ?? 0) > coldest.lastActivityMs {
                swappableSurface.removeFirst()
                promotedIDs.append(candidate.record.id)
                demotedIDs.append(coldest.record.id)
                demotedSet.insert(coldest.record.id)
            } else {
                break
            }
        }

        return Plan(
            promoteToSurface: promotedIDs,
            demoteToDeep: demotedIDs,
            archiveIDs: archiveIDs,
            refreshedUsedAtMs: refreshedUsedAtMs
        )
    }
}
