import Foundation

/// Provenance gate for persisting reusable procedural experiences.
/// Only interactive main conversation, explicit user edits, or user-initiated imports may write.
public enum ExperienceWriteSource: String, Codable, Hashable, Sendable {
    case mainChat = "main_chat"
    case user = "user"
    case importAction = "import"
    case subtask = "subtask"
    case casualTrack = "casual_track"
    case routine = "routine"

    public var isAllowedToPersist: Bool {
        switch self {
        case .mainChat, .user, .importAction: return true
        case .subtask, .casualTrack, .routine: return false
        }
    }
}

public enum ExperienceStoreError: Error, LocalizedError, Equatable, Sendable {
    case writeNotAllowed(ExperienceWriteSource)
    case emptyContent
    case suppressedByTombstone
    case canonicalReadOnly(String)

    public var errorDescription: String? {
        switch self {
        case .writeNotAllowed(let source):
            return "当前来源（\(source.rawValue)）不允许写入经验库。"
        case .emptyContent:
            return "经验内容不能为空或仅包含敏感密钥。"
        case .suppressedByTombstone:
            return "该条经验已列入撤回名单，已阻止再次写入。"
        case .canonicalReadOnly(let detail):
            return "经验档案暂不可写：\(detail)"
        }
    }
}

public struct ExperienceRecord: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var content: String
    public var tags: [String]
    public var contentSHA256: String
    public var createdAtMs: Double
    public var updatedAtMs: Double
    public var usedAtMs: Double?
    public var useCount: Int
    public var deletedAtMs: Double?
    public var source: ExperienceWriteSource

    public init(
        id: String = UUID().uuidString.lowercased(), title: String, content: String,
        tags: [String] = [], contentSHA256: String? = nil,
        createdAtMs: Double = Date().timeIntervalSince1970 * 1000, updatedAtMs: Double? = nil,
        usedAtMs: Double? = nil, useCount: Int = 0, deletedAtMs: Double? = nil,
        source: ExperienceWriteSource = .mainChat
    ) {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = trimmedID.isEmpty ? UUID().uuidString.lowercased() : trimmedID
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = cleanTitle
        self.content = cleanContent
        self.tags = tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let suppliedHash = contentSHA256?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.contentSHA256 = suppliedHash.flatMap { $0.isEmpty ? nil : $0.lowercased() }
            ?? Self.fullHash(title: cleanTitle, content: cleanContent)
        self.createdAtMs = createdAtMs
        self.updatedAtMs = updatedAtMs ?? createdAtMs
        self.usedAtMs = usedAtMs
        self.useCount = max(0, min(Int(Int32.max), useCount))
        self.deletedAtMs = deletedAtMs
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, content, tags, contentSHA256, createdAtMs, updatedAtMs, usedAtMs, useCount, deletedAtMs, source
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawUseCount = try c.decodeIfPresent(Int64.self, forKey: .useCount) ?? 0
        try self.init(
            id: c.decode(String.self, forKey: .id),
            title: c.decodeIfPresent(String.self, forKey: .title) ?? "",
            content: c.decode(String.self, forKey: .content),
            tags: c.decodeIfPresent([String].self, forKey: .tags) ?? [],
            contentSHA256: c.decodeIfPresent(String.self, forKey: .contentSHA256),
            createdAtMs: c.decodeIfPresent(Double.self, forKey: .createdAtMs) ?? 0,
            updatedAtMs: c.decodeIfPresent(Double.self, forKey: .updatedAtMs),
            usedAtMs: c.decodeIfPresent(Double.self, forKey: .usedAtMs),
            useCount: Int(clamping: rawUseCount),
            deletedAtMs: c.decodeIfPresent(Double.self, forKey: .deletedAtMs),
            source: c.decodeIfPresent(ExperienceWriteSource.self, forKey: .source) ?? .mainChat
        )
    }

    private static func fullHash(title: String, content: String) -> String {
        MemorySafety.retractionHash(title.isEmpty ? content : "\(title)\n\(content)")
    }

    fileprivate func redacted(secrets: [String]) -> ExperienceRecord {
        func redact(_ value: String) -> String {
            MemorySafety.redactSecrets(value, secrets: secrets).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var copy = self
        copy.title = redact(title)
        copy.content = redact(content)
        copy.tags = tags.map(redact).filter { !Self.withoutRedactions($0).isEmpty }
        copy.contentSHA256 = Self.fullHash(title: copy.title, content: copy.content)
        return copy
    }

    fileprivate func visible(secrets: [String], suppressedBy hashes: Set<String>) -> ExperienceRecord? {
        let safe = redacted(secrets: secrets)
        guard Self.hasContent(safe.content),
              hashes.isEmpty || hashes.isDisjoint(with: self.hashes(redacted: safe)) else { return nil }
        return safe
    }

    fileprivate static func hasContent(_ value: String) -> Bool {
        !MemorySafety.normalizedFactKey(withoutRedactions(value)).isEmpty
    }

    fileprivate static func withoutRedactions(_ value: String) -> String {
        value.replacingOccurrences(of: "〔隐去〕", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    fileprivate func hashes(redacted: ExperienceRecord) -> Set<String> {
        [contentSHA256.lowercased(), redacted.contentSHA256, MemorySafety.retractionHash(redacted.content)]
    }

    static func clampedIncrement(_ value: Int) -> Int {
        value >= Int(Int32.max) ? Int(Int32.max) : max(0, value) + 1
    }
}

public struct CanonicalExperienceBook: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var updatedAtMs: Double
    public var records: [ExperienceRecord]
    public var retractedHashes: [String]

    public init(
        schemaVersion: Int = CanonicalExperienceBook.currentSchemaVersion,
        updatedAtMs: Double = 0,
        records: [ExperienceRecord] = [],
        retractedHashes: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAtMs = updatedAtMs
        self.records = records
        self.retractedHashes = Self.normalizedHashes(retractedHashes).sorted()
    }

    fileprivate static func normalizedHashes(_ hashes: some Sequence<String>) -> Set<String> {
        Set(hashes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })
    }

    fileprivate func suppressionSet(including external: Set<String>) -> Set<String> {
        Self.normalizedHashes(retractedHashes).union(Self.normalizedHashes(external))
    }

    /// Merges external retraction hashes into this book and tombstones matching experience entries.
    public mutating func mergeRetractionsAndPrune(hashes externalHashes: Set<String>, nowMs: Double) {
        mergeRetractionsAndPrune(hashes: externalHashes, nowMs: nowMs, secrets: [])
    }

    fileprivate mutating func mergeRetractionsAndPrune(
        hashes externalHashes: Set<String>, nowMs: Double, secrets: [String]
    ) {
        guard !externalHashes.isEmpty else { return }
        let combined = suppressionSet(including: externalHashes)
        retractedHashes = combined.sorted()

        for index in records.indices where records[index].deletedAtMs == nil {
            let record = records[index]
            let rawBodyHash = MemorySafety.retractionHash(record.content)
            if combined.contains(rawBodyHash) || !combined.isDisjoint(with: record.hashes(redacted: record.redacted(secrets: secrets))) {
                records[index].deletedAtMs = nowMs
                records[index].updatedAtMs = max(records[index].updatedAtMs, nowMs)
            }
        }
        updatedAtMs = max(updatedAtMs, nowMs)
    }
}

public struct ExperienceHit: Equatable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var content: String
    public var tags: [String]
    public var contentSHA256: String
    public var score: Double
    public var useCount: Int
    public var updatedAtMs: Double
    public var usedAtMs: Double?

    public init(
        id: String, title: String, content: String, tags: [String], contentSHA256: String,
        score: Double, useCount: Int, updatedAtMs: Double, usedAtMs: Double?
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.tags = tags
        self.contentSHA256 = contentSHA256
        self.score = score
        self.useCount = useCount
        self.updatedAtMs = updatedAtMs
        self.usedAtMs = usedAtMs
    }
}

/// Canonical JSON storage with lexical search over a redacted snapshot.
public final class ExperienceStore: @unchecked Sendable {
    public let canonicalFileURL: URL?
    private let lock = NSRecursiveLock()
    private var inMemoryBook = CanonicalExperienceBook()

    public init(canonicalFileURL: URL?) {
        self.canonicalFileURL = canonicalFileURL
    }

    public static func inMemory() -> ExperienceStore { ExperienceStore(canonicalFileURL: nil) }

    public func readBook() throws -> CanonicalExperienceBook {
        try lock.withLock { try readLocked() }
    }

    public func loadAll(
        includeDeleted: Bool = false, suppressedHashes: Set<String> = [], secrets: [String] = []
    ) throws -> [ExperienceRecord] {
        try lock.withLock {
            let book = try readLocked()
            let suppressed = book.suppressionSet(including: suppressedHashes)
            return book.records.lazy.filter { includeDeleted || $0.deletedAtMs == nil }
                .compactMap { $0.visible(secrets: secrets, suppressedBy: suppressed) }
                .sorted { $0.updatedAtMs != $1.updatedAtMs ? $0.updatedAtMs > $1.updatedAtMs : $0.id < $1.id }
        }
    }

    @discardableResult
    public func record(
        id: String? = nil, title: String, content: String, tags: [String] = [], source: ExperienceWriteSource,
        nowMs: Double = Date().timeIntervalSince1970 * 1000, secrets: [String] = [], suppressedHashes: Set<String> = []
    ) throws -> ExperienceRecord {
        guard source.isAllowedToPersist else { throw ExperienceStoreError.writeNotAllowed(source) }
        let input = ExperienceRecord(id: id ?? "", title: title, content: content, tags: tags, createdAtMs: nowMs, source: source)
        var saved = input.redacted(secrets: secrets)
        guard ExperienceRecord.hasContent(saved.content) else { throw ExperienceStoreError.emptyContent }

        return try lock.withLock {
            var book = try readLocked()
            let titleKey = MemorySafety.normalizedFactKey(saved.title)
            let contentKey = MemorySafety.normalizedFactKey(saved.content)
            func matchesContent(_ record: ExperienceRecord) -> Bool {
                let safe = record.redacted(secrets: secrets)
                return MemorySafety.normalizedFactKey(safe.title) == titleKey
                    && MemorySafety.normalizedFactKey(safe.content) == contentKey
            }
            let index = id.flatMap { _ in book.records.firstIndex { $0.id == saved.id } }
                ?? book.records.firstIndex { $0.deletedAtMs == nil && matchesContent($0) }
                ?? book.records.firstIndex(where: matchesContent)
            var hashes = input.hashes(redacted: saved)
            if let index {
                let previous = book.records[index]
                if source == .mainChat {
                    hashes.formUnion(previous.hashes(redacted: previous.redacted(secrets: secrets)))
                } else {
                    hashes.insert(previous.contentSHA256.lowercased())
                }
                saved.createdAtMs = previous.createdAtMs
                saved.updatedAtMs = max(previous.updatedAtMs, nowMs)
                saved.usedAtMs = previous.usedAtMs
                saved.useCount = previous.useCount
                saved.id = previous.id
            }
            if source == .user || source == .importAction {
                let local = CanonicalExperienceBook.normalizedHashes(book.retractedHashes)
                book.retractedHashes = local.subtracting(hashes).sorted()
            } else if !book.suppressionSet(including: suppressedHashes).isDisjoint(with: hashes) {
                throw ExperienceStoreError.suppressedByTombstone
            }
            if let index {
                book.records[index] = saved
            } else {
                book.records.append(saved)
            }
            book.updatedAtMs = max(book.updatedAtMs, nowMs)
            try writeLocked(book)
            return saved
        }
    }

    public func delete(id: String, nowMs: Double = Date().timeIntervalSince1970 * 1000, secrets: [String] = []) throws {
        try lock.withLock {
            var book = try readLocked()
            guard let index = book.records.firstIndex(where: { $0.id == id }) else { return }
            let target = book.records[index]
            book.records[index].deletedAtMs = nowMs
            book.records[index].updatedAtMs = max(target.updatedAtMs, nowMs)
            book.updatedAtMs = max(book.updatedAtMs, nowMs)
            var hashes = target.hashes(redacted: target.redacted(secrets: secrets))
            hashes.insert(MemorySafety.retractionHash(target.content))
            book.retractedHashes = book.suppressionSet(including: hashes).sorted()
            try writeLocked(book)
        }
    }

    public func search(
        query: String, limit: Int = 5, suppressedHashes: Set<String> = [], secrets: [String] = [],
        markUsedNowMs: Double? = nil
    ) throws -> [ExperienceHit] {
        try lock.withLock {
            var book = try readLocked()
            let cleanQuery = ExperienceRecord.withoutRedactions(MemorySafety.redactSecrets(query, secrets: secrets))
            guard limit > 0, !cleanQuery.isEmpty else { return [] }
            let analysis = MemoryRecall.analyzeQuery(cleanQuery)
            guard !analysis.isEmpty else { return [] }

            let suppressed = book.suppressionSet(including: suppressedHashes)
            let ranked = book.records.enumerated().compactMap { index, raw -> (index: Int, hit: ExperienceHit)? in
                guard raw.deletedAtMs == nil, let record = raw.visible(secrets: secrets, suppressedBy: suppressed) else { return nil }
                let relevance = MemoryRecall.scoreText(
                    analysis: analysis, text: "\(record.title) \(record.content)",
                    topic: record.tags.joined(separator: " "), bm25Rank: nil
                )
                guard relevance > 0 else { return nil }
                let usageBonus = min(3.0, Double(max(0, record.useCount)) * 0.25)
                return (index, ExperienceHit(
                    id: record.id, title: record.title, content: record.content, tags: record.tags,
                    contentSHA256: record.contentSHA256, score: relevance + usageBonus, useCount: record.useCount,
                    updatedAtMs: record.updatedAtMs, usedAtMs: record.usedAtMs
                ))
            }.sorted { left, right in
                let lhs = left.hit
                let rhs = right.hit
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                let lhsRecency = lhs.usedAtMs ?? lhs.updatedAtMs
                let rhsRecency = rhs.usedAtMs ?? rhs.updatedAtMs
                return lhsRecency != rhsRecency ? lhsRecency > rhsRecency : lhs.id < rhs.id
            }
            let selected = ranked.prefix(limit)
            guard let now = markUsedNowMs, !selected.isEmpty else { return selected.map(\.hit) }

            let hits = selected.map { index, hit in
                var hit = hit
                hit.useCount = ExperienceRecord.clampedIncrement(hit.useCount)
                hit.usedAtMs = max(hit.usedAtMs ?? now, now)
                hit.updatedAtMs = max(hit.updatedAtMs, now)
                book.records[index].useCount = hit.useCount
                book.records[index].usedAtMs = hit.usedAtMs
                book.records[index].updatedAtMs = hit.updatedAtMs
                return hit
            }
            book.updatedAtMs = max(book.updatedAtMs, now)
            try writeLocked(book)
            return hits
        }
    }

    public func mergeRetractedHashesAndPrune(_ hashes: Set<String>, nowMs: Double, secrets: [String] = []) throws {
        try lock.withLock {
            var book = try readLocked()
            let original = book
            book.mergeRetractionsAndPrune(hashes: hashes, nowMs: nowMs, secrets: secrets)
            if book != original { try writeLocked(book) }
        }
    }

    private func readLocked() throws -> CanonicalExperienceBook {
        guard let url = canonicalFileURL else { return inMemoryBook }
        do {
            return try JSONDecoder().decode(CanonicalExperienceBook.self, from: Data(contentsOf: url))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return CanonicalExperienceBook()
        }
    }

    private func writeLocked(_ book: CanonicalExperienceBook) throws {
        guard let url = canonicalFileURL else {
            inMemoryBook = book
            return
        }
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: url.path)
        guard !exists || fm.isWritableFile(atPath: url.path) else {
            throw ExperienceStoreError.canonicalReadOnly(url.lastPathComponent)
        }
        let directory = url.deletingLastPathComponent()
        let temp = directory.appendingPathComponent(".experiences-\(UUID()).tmp")
        defer { try? fm.removeItem(at: temp) }
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(book).write(to: temp, options: .atomic)
            if exists {
                _ = try fm.replaceItemAt(url, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: url)
            }
        } catch {
            throw ExperienceStoreError.canonicalReadOnly(error.localizedDescription)
        }
    }
}
