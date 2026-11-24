import Foundation

/// Clio's four-tier memory lifecycle layer.
public enum MemoryLayer: String, Codable, CaseIterable, Sendable {
    /// 镇纸：置顶常驻核心设定，始终注入对话且不随表面记忆上限下沉。
    case pinned
    /// 常记：当前对话直接注入，按最近使用时间受表面容量上限调控。
    case surface
    /// 旧事：按需通过 `recall` 召回，不占每轮对话前缀空间。
    case deep
    /// 归档/候选：暂不主动注入，留作归档或待晋升/待清理候选。
    case archived
}

/// Authoritative SQLite-backed memory record with layer, provenance, confidence, and tombstone timestamps.
public struct MemoryRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var text: String
    public var textSHA256: String
    public var layer: MemoryLayer
    public var pinned: Bool
    public var kind: String
    public var topic: String
    public var sourceChat: String?
    public var sourceEntryID: String?
    public var confidence: Double
    public var createdAtMs: Double
    public var updatedAtMs: Double
    public var usedAtMs: Double?
    public var byBot: String?
    public var automatic: Bool
    public var editedByUser: Bool
    public var deletedAtMs: Double?

    public init(
        id: String = UUID().uuidString,
        text: String,
        textSHA256: String? = nil,
        layer: MemoryLayer = .surface,
        pinned: Bool = false,
        kind: String = "fact",
        topic: String = "",
        sourceChat: String? = nil,
        sourceEntryID: String? = nil,
        confidence: Double = 1.0,
        createdAtMs: Double,
        updatedAtMs: Double? = nil,
        usedAtMs: Double? = nil,
        byBot: String? = nil,
        automatic: Bool = false,
        editedByUser: Bool = false,
        deletedAtMs: Double? = nil
    ) {
        let resolvedPinned = pinned || layer == .pinned
        let resolvedLayer: MemoryLayer = resolvedPinned ? .pinned : layer
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = id
        self.text = trimmed
        if let provided = textSHA256, !provided.isEmpty {
            self.textSHA256 = provided.lowercased()
        } else {
            self.textSHA256 = MemorySafety.retractionHash(trimmed)
        }
        self.layer = resolvedLayer
        self.pinned = resolvedPinned
        let cleanKind = kind.trimmingCharacters(in: .whitespacesAndNewlines)
        self.kind = cleanKind.isEmpty ? "fact" : cleanKind
        self.topic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sourceChat = sourceChat
        self.sourceEntryID = sourceEntryID
        self.confidence = min(1.0, max(0.0, confidence))
        self.createdAtMs = createdAtMs
        self.updatedAtMs = updatedAtMs ?? max(usedAtMs ?? createdAtMs, createdAtMs)
        self.usedAtMs = usedAtMs
        self.byBot = byBot
        self.automatic = automatic
        self.editedByUser = editedByUser
        self.deletedAtMs = deletedAtMs
    }

    /// Maps the record to `MemorySafety.Fact` for prompt assembly (`nil` when `.archived` or tombstoned).
    public var safetyFact: MemorySafety.Fact? {
        guard deletedAtMs == nil, layer != .archived else { return nil }
        return MemorySafety.Fact(
            id: id,
            text: text,
            at: createdAtMs,
            used: usedAtMs,
            isDeep: layer == .deep
        )
    }
}

/// Persistent soft-delete tombstone keyed by normalized SHA-256 hash so sync/review cannot resurrect deleted facts.
public struct MemoryTombstone: Codable, Equatable, Sendable, Identifiable {
    public var id: String { textSHA256 }
    public var textSHA256: String
    public var memoryID: String?
    public var deletedAtMs: Double
    public var reason: String

    public init(
        textSHA256: String,
        memoryID: String? = nil,
        deletedAtMs: Double,
        reason: String = "user_delete"
    ) {
        self.textSHA256 = textSHA256.lowercased()
        self.memoryID = memoryID
        self.deletedAtMs = deletedAtMs
        self.reason = reason
    }
}

/// Backwards-compatible canonical item mirroring `App`'s `Memory` JSON structure plus optional enriched fields.
public struct CanonicalMemoryItem: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var text: String
    public var at: Double
    public var by: String?
    public var deep: Bool?
    public var used: Double?
    public var automatic: Bool?
    public var editedByUser: Bool?

    public var layer: MemoryLayer?
    public var pinned: Bool?
    public var kind: String?
    public var topic: String?
    public var sourceChat: String?
    public var sourceEntryID: String?
    public var confidence: Double?
    public var updatedAt: Double?

    public init(
        id: String,
        text: String,
        at: Double,
        by: String? = nil,
        deep: Bool? = nil,
        used: Double? = nil,
        automatic: Bool? = nil,
        editedByUser: Bool? = nil,
        layer: MemoryLayer? = nil,
        pinned: Bool? = nil,
        kind: String? = nil,
        topic: String? = nil,
        sourceChat: String? = nil,
        sourceEntryID: String? = nil,
        confidence: Double? = nil,
        updatedAt: Double? = nil
    ) {
        self.id = id
        self.text = text
        self.at = at
        self.by = by
        self.deep = deep
        self.used = used
        self.automatic = automatic
        self.editedByUser = editedByUser
        self.layer = layer
        self.pinned = pinned
        self.kind = kind
        self.topic = topic
        self.sourceChat = sourceChat
        self.sourceEntryID = sourceEntryID
        self.confidence = confidence
        self.updatedAt = updatedAt
    }

    public init(from record: MemoryRecord) {
        self.id = record.id
        self.text = record.text
        self.at = record.createdAtMs
        self.by = record.byBot
        self.deep = record.layer == .deep ? true : nil
        self.used = record.usedAtMs
        self.automatic = record.automatic ? true : nil
        self.editedByUser = record.editedByUser ? true : nil
        self.layer = record.layer
        self.pinned = record.pinned ? true : nil
        self.kind = record.kind == "fact" ? nil : record.kind
        self.topic = record.topic.isEmpty ? nil : record.topic
        self.sourceChat = record.sourceChat
        self.sourceEntryID = record.sourceEntryID
        self.confidence = record.confidence < 1.0 ? record.confidence : nil
        self.updatedAt = record.updatedAtMs
    }

    public var effectiveUpdatedAtMs: Double {
        updatedAt ?? max(used ?? at, at)
    }

    public var resolvedLayer: MemoryLayer {
        if let layer {
            if pinned == true { return .pinned }
            return layer
        }
        if pinned == true { return .pinned }
        if deep == true { return .deep }
        return .surface
    }
}

/// Wire-compatible canonical mirror of `App`'s `MemoryReviewLog`.
public struct CanonicalMemoryReviewLog: Codable, Identifiable, Equatable, Sendable {
    public struct Addition: Codable, Equatable, Sendable {
        public var memoryID: String
        public var text: String

        public init(memoryID: String, text: String) {
            self.memoryID = memoryID
            self.text = text
        }
    }

    public struct Change: Codable, Equatable, Sendable {
        public var memoryID: String
        public var before: String
        public var after: String

        public init(memoryID: String, before: String, after: String) {
            self.memoryID = memoryID
            self.before = before
            self.after = after
        }
    }

    public var id: UUID
    public var at: Date
    public var day: String
    public var conversation: String
    public var added: [Addition]
    public var merged: [Change]

    public init(
        id: UUID,
        at: Date,
        day: String,
        conversation: String,
        added: [Addition],
        merged: [Change]
    ) {
        self.id = id
        self.at = at
        self.day = day
        self.conversation = conversation
        self.added = added
        self.merged = merged
    }
}

/// Canonical JSON snapshot corresponding to `memory.json`, backwards-compatible with both legacy `[Memory]`
/// arrays and `MemoryBook` dictionaries while also carrying tombstones, archived entries, and retraction hashes.
public struct CanonicalMemoryBook: Codable, Equatable, Sendable {
    public var memories: [CanonicalMemoryItem]
    public var archived: [CanonicalMemoryItem]
    public var reviews: [CanonicalMemoryReviewLog]
    public var processed: [String: Set<String>]
    public var reviewFromDay: String?
    public var budgetDay: String?
    public var requests: Int
    public var diaryRequests: Int
    public var suppressedFlushHashes: [String]
    public var tombstones: [MemoryTombstone]

    public init(
        memories: [CanonicalMemoryItem] = [],
        archived: [CanonicalMemoryItem] = [],
        reviews: [CanonicalMemoryReviewLog] = [],
        processed: [String: Set<String>] = [:],
        reviewFromDay: String? = nil,
        budgetDay: String? = nil,
        requests: Int = 0,
        diaryRequests: Int = 0,
        suppressedFlushHashes: [String] = [],
        tombstones: [MemoryTombstone] = []
    ) {
        self.memories = memories
        self.archived = archived
        self.reviews = reviews
        self.processed = processed
        self.reviewFromDay = reviewFromDay
        self.budgetDay = budgetDay
        self.requests = requests
        self.diaryRequests = diaryRequests
        self.suppressedFlushHashes = suppressedFlushHashes
        self.tombstones = tombstones
    }

    private enum CodingKeys: String, CodingKey {
        case memories
        case archived
        case reviews
        case processed
        case reviewFromDay
        case budgetDay
        case requests
        case diaryRequests
        case suppressedFlushHashes
        case tombstones
    }

    public init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            self.memories = try container.decodeIfPresent([CanonicalMemoryItem].self, forKey: .memories) ?? []
            self.archived = try container.decodeIfPresent([CanonicalMemoryItem].self, forKey: .archived) ?? []
            self.reviews = try container.decodeIfPresent([CanonicalMemoryReviewLog].self, forKey: .reviews) ?? []
            self.processed = try container.decodeIfPresent([String: Set<String>].self, forKey: .processed) ?? [:]
            self.reviewFromDay = try container.decodeIfPresent(String.self, forKey: .reviewFromDay)
            self.budgetDay = try container.decodeIfPresent(String.self, forKey: .budgetDay)
            self.requests = try container.decodeIfPresent(Int.self, forKey: .requests) ?? 0
            self.diaryRequests = try container.decodeIfPresent(Int.self, forKey: .diaryRequests) ?? 0
            self.suppressedFlushHashes = try container.decodeIfPresent([String].self, forKey: .suppressedFlushHashes) ?? []
            self.tombstones = try container.decodeIfPresent([MemoryTombstone].self, forKey: .tombstones) ?? []
            return
        }
        let single = try decoder.singleValueContainer()
        let legacyItems = try single.decode([CanonicalMemoryItem].self)
        self.init(memories: legacyItems)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(memories, forKey: .memories)
        if !archived.isEmpty {
            try container.encode(archived, forKey: .archived)
        }
        try container.encode(reviews, forKey: .reviews)
        try container.encode(processed, forKey: .processed)
        try container.encodeIfPresent(reviewFromDay, forKey: .reviewFromDay)
        try container.encodeIfPresent(budgetDay, forKey: .budgetDay)
        try container.encode(requests, forKey: .requests)
        try container.encode(diaryRequests, forKey: .diaryRequests)
        if !suppressedFlushHashes.isEmpty {
            try container.encode(suppressedFlushHashes, forKey: .suppressedFlushHashes)
        }
        if !tombstones.isEmpty {
            try container.encode(tombstones, forKey: .tombstones)
        }
    }

    /// Decodes either a `CanonicalMemoryBook` JSON object or a legacy `[CanonicalMemoryItem]` array.
    public static func decodeFlexible(from data: Data) throws -> CanonicalMemoryBook {
        let decoder = JSONDecoder()
        return try decoder.decode(CanonicalMemoryBook.self, from: data)
    }
}

public struct MemoryStoreMeta: Equatable, Sendable {
    public var schemaVersion: Int32
    public var instanceID: String
    public var revision: Int64
    public var lastSyncedJSONSHA256: String

    public init(
        schemaVersion: Int32,
        instanceID: String,
        revision: Int64,
        lastSyncedJSONSHA256: String
    ) {
        self.schemaVersion = schemaVersion
        self.instanceID = instanceID
        self.revision = revision
        self.lastSyncedJSONSHA256 = lastSyncedJSONSHA256
    }
}

public enum MemoryStoreRecoveryReason: String, Sendable, Equatable {
    case none
    case missing
    case externalDeletion
    case corrupt
    case schemaMismatch
}

public enum MemoryStoreError: Error, Equatable, Sendable {
    case openFailed(code: Int32, message: String)
    case sqlite(code: Int32, message: String)
    case emptyText
}
