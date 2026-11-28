import Foundation

/// Summary produced when merging legacy `CanonicalExperienceBook` entries into unified `MemoryRecord` storage.
public struct ExperienceMemoryMergeReport: Equatable, Sendable {
    public var memories: [MemoryRecord]
    public var retractedHashes: Set<String>
    public var addedCount: Int
    public var mergedDuplicateCount: Int
    public var skippedDeletedCount: Int
    public var skippedDisallowedSourceCount: Int
    public var skippedRetractedCount: Int
    public var skippedSecretOrEmptyCount: Int

    public init(
        memories: [MemoryRecord],
        retractedHashes: Set<String>,
        addedCount: Int = 0,
        mergedDuplicateCount: Int = 0,
        skippedDeletedCount: Int = 0,
        skippedDisallowedSourceCount: Int = 0,
        skippedRetractedCount: Int = 0,
        skippedSecretOrEmptyCount: Int = 0
    ) {
        self.memories = memories
        self.retractedHashes = retractedHashes
        self.addedCount = addedCount
        self.mergedDuplicateCount = mergedDuplicateCount
        self.skippedDeletedCount = skippedDeletedCount
        self.skippedDisallowedSourceCount = skippedDisallowedSourceCount
        self.skippedRetractedCount = skippedRetractedCount
        self.skippedSecretOrEmptyCount = skippedSecretOrEmptyCount
    }
}

/// Pure, deterministic merger consolidating legacy `ExperienceRecord` entries into unified `MemoryRecord` items.
///
/// Safety invariants:
/// - Deduplication and retraction suppression strictly use `MemorySafety.retractionHash`.
/// - Newly migrated records default to `MemoryLayer.deep` with an empty `topic` (`""`).
/// - Soft-deleted (`deletedAtMs != nil`) and disallowed sources (`!source.isAllowedToPersist`) are never imported;
///   soft-deleted experience hashes are propagated into `retractedHashes` so they cannot resurface.
/// - Applies Vault secret redaction and rejects any record containing `"〔隐去〕"` or common raw secret prefixes.
/// - Timestamp merges never let `0` overwrite a real `createdAtMs`, and preserve `usedAtMs`, `automatic`, and `editedByUser`.
public enum ExperienceMemoryMerger {
    private static let redactionMarker = "〔隐去〕"
    private static let rawSecretMarkers: [String] = [
        "sk-ant-",
        "sk-proj-",
        "ghp_",
        "github_pat_",
        "PRIVATE KEY",
    ]

    public static func merge(
        experiences: CanonicalExperienceBook,
        into existingMemories: [MemoryRecord],
        existingRetractedHashes: Set<String> = [],
        secrets: [String] = [],
        nowMs: Double
    ) -> ExperienceMemoryMergeReport {
        var retracted = normalizedHashes(existingRetractedHashes)
        retracted.formUnion(normalizedHashes(experiences.retractedHashes))

        for record in existingMemories where record.deletedAtMs != nil {
            retracted.insert(record.textSHA256.lowercased())
            retracted.insert(MemorySafety.retractionHash(record.text))
        }

        // First pass: collect every soft-deleted experience's hashes into the retraction set
        // before considering any surviving experience record.
        var skippedDeletedCount = 0
        for exp in experiences.records where exp.deletedAtMs != nil {
            skippedDeletedCount += 1
            retracted.formUnion(allRetractionHashes(for: exp, secrets: secrets))
        }

        var merged = existingMemories
        var indexByHash: [String: Int] = [:]
        var usedIDs = Set<String>()
        for (idx, record) in merged.enumerated() {
            usedIDs.insert(record.id)
            guard record.deletedAtMs == nil else { continue }
            let hash = MemorySafety.retractionHash(record.text)
            if indexByHash[hash] == nil {
                indexByHash[hash] = idx
            }
            let stored = record.textSHA256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !stored.isEmpty, indexByHash[stored] == nil {
                indexByHash[stored] = idx
            }
        }

        var addedCount = 0
        var mergedDuplicateCount = 0
        var skippedDisallowedSourceCount = 0
        var skippedRetractedCount = 0
        var skippedSecretOrEmptyCount = 0

        for exp in experiences.records {
            if exp.deletedAtMs != nil {
                continue
            }
            guard exp.source.isAllowedToPersist else {
                skippedDisallowedSourceCount += 1
                continue
            }

            let rawTitle = exp.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let rawContent = exp.content.trimmingCharacters(in: .whitespacesAndNewlines)
            let redactedTitle = MemorySafety.redactSecrets(rawTitle, secrets: secrets)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let redactedContent = MemorySafety.redactSecrets(rawContent, secrets: secrets)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if containsForbiddenSecret(rawTitle) || containsForbiddenSecret(rawContent)
                || containsForbiddenSecret(redactedTitle) || containsForbiddenSecret(redactedContent) {
                skippedSecretOrEmptyCount += 1
                continue
            }

            let formattedText = formatMemoryText(title: redactedTitle, content: redactedContent)
            guard !formattedText.isEmpty,
                  !MemorySafety.normalizedFactKey(formattedText).isEmpty,
                  !containsForbiddenSecret(formattedText) else {
                skippedSecretOrEmptyCount += 1
                continue
            }

            let candidateHashes = allRetractionHashes(for: exp, redactedTitle: redactedTitle, redactedContent: redactedContent, formattedText: formattedText)
            guard retracted.isDisjoint(with: candidateHashes) else {
                skippedRetractedCount += 1
                continue
            }

            let canonicalHash = MemorySafety.retractionHash(formattedText)
            let bodyHash = MemorySafety.retractionHash(redactedContent)
            let existingIdx = indexByHash[canonicalHash]
                ?? (bodyHash != canonicalHash ? indexByHash[bodyHash] : nil)

            if let idx = existingIdx {
                mergedDuplicateCount += 1
                merged[idx] = mergeTimestampsAndFlags(existing: merged[idx], incoming: exp)
                indexByHash[canonicalHash] = idx
                indexByHash[bodyHash] = idx
                continue
            }

            let resolvedCreatedAt = firstPositive(exp.createdAtMs, exp.updatedAtMs, fallback: nowMs)
            let resolvedUpdatedAt = max(resolvedCreatedAt, exp.updatedAtMs > 0 ? exp.updatedAtMs : resolvedCreatedAt)
            let resolvedUsedAt = positiveOptional(exp.usedAtMs)
            let id = resolveUniqueID(preferred: exp.id, usedIDs: &usedIDs)

            let migrated = MemoryRecord(
                id: id,
                text: formattedText,
                textSHA256: canonicalHash,
                layer: .deep,
                pinned: false,
                kind: "fact",
                topic: "",
                sourceChat: nil,
                sourceEntryID: nil,
                confidence: 1.0,
                createdAtMs: resolvedCreatedAt,
                updatedAtMs: resolvedUpdatedAt,
                usedAtMs: resolvedUsedAt,
                byBot: nil,
                automatic: exp.source == .mainChat,
                editedByUser: exp.source == .user,
                deletedAtMs: nil
            )
            let newIndex = merged.count
            merged.append(migrated)
            indexByHash[canonicalHash] = newIndex
            if indexByHash[bodyHash] == nil {
                indexByHash[bodyHash] = newIndex
            }
            addedCount += 1
        }

        return ExperienceMemoryMergeReport(
            memories: merged,
            retractedHashes: retracted,
            addedCount: addedCount,
            mergedDuplicateCount: mergedDuplicateCount,
            skippedDeletedCount: skippedDeletedCount,
            skippedDisallowedSourceCount: skippedDisallowedSourceCount,
            skippedRetractedCount: skippedRetractedCount,
            skippedSecretOrEmptyCount: skippedSecretOrEmptyCount
        )
    }

    // MARK: - Helpers

    private static func formatMemoryText(title: String, content: String) -> String {
        guard !content.isEmpty else { return "" }
        guard !title.isEmpty else { return content }
        if MemorySafety.normalizedFactKey(content) == MemorySafety.normalizedFactKey(title) {
            return content
        }
        return "\(title)\n\(content)"
    }

    private static func containsForbiddenSecret(_ value: String) -> Bool {
        if value.contains(redactionMarker) { return true }
        for marker in rawSecretMarkers {
            if value.contains(marker) { return true }
        }
        return false
    }

    private static func allRetractionHashes(for exp: ExperienceRecord, secrets: [String]) -> Set<String> {
        let rawTitle = exp.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawContent = exp.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let redactedTitle = MemorySafety.redactSecrets(rawTitle, secrets: secrets)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let redactedContent = MemorySafety.redactSecrets(rawContent, secrets: secrets)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let formatted = formatMemoryText(title: redactedTitle, content: redactedContent)
        return allRetractionHashes(
            for: exp,
            redactedTitle: redactedTitle,
            redactedContent: redactedContent,
            formattedText: formatted
        )
    }

    private static func allRetractionHashes(
        for exp: ExperienceRecord,
        redactedTitle: String,
        redactedContent: String,
        formattedText: String
    ) -> Set<String> {
        var hashes = Set<String>()
        let stored = exp.contentSHA256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !stored.isEmpty { hashes.insert(stored) }
        let rawText = formatMemoryText(
            title: exp.title.trimmingCharacters(in: .whitespacesAndNewlines),
            content: exp.content.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        if !rawText.isEmpty { hashes.insert(MemorySafety.retractionHash(rawText)) }
        if !exp.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            hashes.insert(MemorySafety.retractionHash(exp.content))
        }
        if !formattedText.isEmpty { hashes.insert(MemorySafety.retractionHash(formattedText)) }
        if !redactedContent.isEmpty { hashes.insert(MemorySafety.retractionHash(redactedContent)) }
        return hashes
    }

    private static func mergeTimestampsAndFlags(
        existing: MemoryRecord,
        incoming: ExperienceRecord
    ) -> MemoryRecord {
        var updated = existing
        updated.createdAtMs = earliestPositive(existing.createdAtMs, incoming.createdAtMs)
        updated.updatedAtMs = max(
            existing.updatedAtMs,
            incoming.updatedAtMs > 0 ? incoming.updatedAtMs : existing.updatedAtMs
        )
        updated.usedAtMs = latestPositiveOptional(existing.usedAtMs, incoming.usedAtMs)
        updated.automatic = existing.automatic
        updated.editedByUser = existing.editedByUser || (incoming.source == .user)
        return updated
    }

    private static func earliestPositive(_ lhs: Double, _ rhs: Double) -> Double {
        if lhs > 0 && rhs > 0 { return min(lhs, rhs) }
        if lhs > 0 { return lhs }
        if rhs > 0 { return rhs }
        return 0
    }

    private static func firstPositive(_ first: Double, _ second: Double, fallback: Double) -> Double {
        if first > 0 { return first }
        if second > 0 { return second }
        return fallback
    }

    private static func positiveOptional(_ value: Double?) -> Double? {
        guard let value, value > 0 else { return nil }
        return value
    }

    private static func latestPositiveOptional(_ lhs: Double?, _ rhs: Double?) -> Double? {
        switch (positiveOptional(lhs), positiveOptional(rhs)) {
        case (let a?, let b?): return max(a, b)
        case (let a?, nil): return a
        case (nil, let b?): return b
        case (nil, nil): return nil
        }
    }

    private static func resolveUniqueID(preferred: String, usedIDs: inout Set<String>) -> String {
        let trimmed = preferred.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, usedIDs.insert(trimmed).inserted {
            return trimmed
        }
        let prefixed = "exp-\(trimmed.isEmpty ? UUID().uuidString.lowercased() : trimmed)"
        if usedIDs.insert(prefixed).inserted {
            return prefixed
        }
        let fallback = "exp-\(UUID().uuidString.lowercased())"
        usedIDs.insert(fallback)
        return fallback
    }

    private static func normalizedHashes(_ hashes: some Sequence<String>) -> Set<String> {
        Set(
            hashes
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
    }
}
