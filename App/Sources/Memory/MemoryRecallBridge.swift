import Craft
import Foundation

/// Off-MainActor coordinator for Channel-1 zero-cost FTS5 `.deep` memory recall (`clio-memory-recall-fts.db`)
/// and lightweight recall frequency/recency bookkeeping.
final class MemoryRecallBridge: @unchecked Sendable {
    static let shared = MemoryRecallBridge()

    private let index: MemoryRecallIndex
    private let queue = DispatchQueue(label: "clio.memory-recall", qos: .utility)
    private let statsLock = NSLock()
    private var statsCache: [String: MemoryRecallUsageStat] = [:]
    private var statsLoaded = false

    init(databaseURL: URL = MemoryRecallIndex.defaultDatabaseURL) {
        self.index = MemoryRecallIndex(databaseURL: databaseURL)
    }

    func warmup() {
        guard !Disk.frozen else { return }
        queue.async { [weak self] in
            self?.warmupLocked()
        }
    }

    func scheduleSync() {
        guard !Disk.frozen else { return }
        queue.async { [weak self] in
            guard let self, !Disk.frozen else { return }
            let records = MemoryStoreBridge.shared.recordsSnapshot()
            let secrets = Self.orderedSecrets(Vault.allStrings())
            try? self.index.sync(records: records, secrets: secrets)
        }
    }

    func resetForRestore() {
        statsLock.lock()
        statsCache.removeAll()
        statsLoaded = false
        statsLock.unlock()

        queue.async { [weak self] in
            self?.index.destroyFiles()
        }
    }

    func usageStatsSnapshot() -> [String: MemoryRecallUsageStat] {
        statsLock.lock()
        let alreadyLoaded = statsLoaded
        statsLock.unlock()

        if !alreadyLoaded && !Disk.frozen {
            queue.sync {
                self.loadStatsLockedIfNeeded()
            }
        }

        statsLock.lock()
        defer { statsLock.unlock() }
        return statsCache
    }

    func recordUsageAsync(ids: [String], nowMs: Double = Now.ms) {
        let uniqueIDs = Array(Set(ids.filter { !$0.isEmpty })).sorted()
        guard !uniqueIDs.isEmpty, !Disk.frozen else { return }

        mergeUsageIntoCache(ids: uniqueIDs, nowMs: nowMs)
        queue.async { [weak self] in
            guard let self, !Disk.frozen else { return }
            try? self.index.recordUsage(ids: uniqueIDs, nowMs: nowMs)
        }
    }

    private enum RecallScope {
        case deepOnly
        case allActive
    }

    func recallForTurn(
        query: String?,
        usesMemory: Bool,
        grantAllowed: Bool,
        diskFrozen: Bool,
        keeping: Bool,
        fallbackRecords: [MemoryRecord] = [],
        fallbackSurfaceTexts: [String] = [],
        retractedIDs: Set<String>,
        suppressedHashes: Set<String>,
        recordUsage: Bool = true,
        config: MemoryRecall.Config = MemoryRecall.Config()
    ) async -> [MemoryRecall.Hit] {
        await recallScoped(
            scope: .deepOnly,
            query: query,
            usesMemory: usesMemory,
            grantAllowed: grantAllowed,
            diskFrozen: diskFrozen,
            keeping: keeping,
            fallbackRecords: fallbackRecords,
            fallbackSurfaceTexts: fallbackSurfaceTexts,
            retractedIDs: retractedIDs,
            suppressedHashes: suppressedHashes,
            recordUsage: recordUsage,
            config: config
        )
    }

    /// Full-scope recall across `.pinned`, `.surface`, and `.deep` (excluding `.archived`).
    func recallAll(
        query: String?,
        usesMemory: Bool,
        grantAllowed: Bool,
        diskFrozen: Bool,
        keeping: Bool,
        fallbackRecords: [MemoryRecord] = [],
        retractedIDs: Set<String>,
        suppressedHashes: Set<String>,
        recordUsage: Bool = false,
        config: MemoryRecall.Config = MemoryRecall.Config()
    ) async -> [MemoryRecall.Hit] {
        await recallScoped(
            scope: .allActive,
            query: query,
            usesMemory: usesMemory,
            grantAllowed: grantAllowed,
            diskFrozen: diskFrozen,
            keeping: keeping,
            fallbackRecords: fallbackRecords,
            fallbackSurfaceTexts: [],
            retractedIDs: retractedIDs,
            suppressedHashes: suppressedHashes,
            recordUsage: recordUsage,
            config: config
        )
    }

    private func recallScoped(
        scope: RecallScope,
        query: String?,
        usesMemory: Bool,
        grantAllowed: Bool,
        diskFrozen: Bool,
        keeping: Bool,
        fallbackRecords: [MemoryRecord],
        fallbackSurfaceTexts: [String],
        retractedIDs: Set<String>,
        suppressedHashes: Set<String>,
        recordUsage: Bool,
        config: MemoryRecall.Config
    ) async -> [MemoryRecall.Hit] {
        guard usesMemory, grantAllowed else { return [] }
        if scope == .deepOnly, diskFrozen { return [] }
        if diskFrozen && recordUsage { return [] }
        guard let rawQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines), !rawQuery.isEmpty else {
            return []
        }

        if !keeping || diskFrozen || (scope == .allActive && !recordUsage) {
            let sourceRecords: [MemoryRecord]
            if keeping && scope == .allActive && !recordUsage {
                sourceRecords = MemoryStoreBridge.shared.recordsSnapshot()
            } else {
                sourceRecords = fallbackRecords
            }
            return await Task.detached(priority: .userInitiated) {
                let secrets = Self.orderedSecrets(Vault.allStrings())
                switch scope {
                case .deepOnly:
                    return MemoryRecall.searchDeep(
                        query: rawQuery,
                        records: sourceRecords,
                        excludedIDs: retractedIDs,
                        suppressedHashes: suppressedHashes,
                        existingSurfaceTexts: fallbackSurfaceTexts,
                        secrets: secrets,
                        config: config
                    )
                case .allActive:
                    return MemoryRecall.searchAll(
                        query: rawQuery,
                        records: sourceRecords,
                        excludedIDs: retractedIDs,
                        suppressedHashes: suppressedHashes,
                        secrets: secrets,
                        config: config
                    )
                }
            }.value
        }

        return await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: [])
                    return
                }
                if scope == .deepOnly && Disk.frozen {
                    continuation.resume(returning: [])
                    return
                }
                let hits = self.performTurnRecallLocked(
                    scope: scope,
                    query: rawQuery,
                    retractedIDs: retractedIDs,
                    suppressedHashes: suppressedHashes,
                    recordUsage: recordUsage && !Disk.frozen,
                    config: config
                )
                continuation.resume(returning: hits)
            }
        }
    }

    static func makeFallbackRecords(from memories: [Memory], pinnedIDs: Set<String>) -> [MemoryRecord] {
        memories.map { mem in
            let isPinned = pinnedIDs.contains(mem.id) && mem.deep != true
            let layer: MemoryLayer
            if isPinned {
                layer = .pinned
            } else if mem.deep == true {
                layer = .deep
            } else {
                layer = .surface
            }
            return MemoryRecord(
                id: mem.id,
                text: mem.text,
                layer: layer,
                pinned: isPinned,
                createdAtMs: mem.at,
                usedAtMs: mem.used,
                byBot: mem.by,
                automatic: mem.automatic == true,
                editedByUser: mem.editedByUser == true
            )
        }
    }

    // MARK: - Private Queue Helpers

    private func warmupLocked() {
        guard !Disk.frozen else { return }
        let records = MemoryStoreBridge.shared.recordsSnapshot()
        let secrets = Self.orderedSecrets(Vault.allStrings())
        try? index.sync(records: records, secrets: secrets)
        loadStatsLockedIfNeeded()
    }

    private func loadStatsLockedIfNeeded() {
        statsLock.lock()
        let needsLoad = !statsLoaded
        statsLock.unlock()
        guard needsLoad, !Disk.frozen else { return }

        if let loaded = try? index.usageStats() {
            statsLock.lock()
            for (id, stat) in loaded {
                if let existing = statsCache[id] {
                    statsCache[id] = MemoryRecallUsageStat(
                        lastRecalledAtMs: max(existing.lastRecalledAtMs, stat.lastRecalledAtMs),
                        recallCount: max(existing.recallCount, stat.recallCount)
                    )
                } else {
                    statsCache[id] = stat
                }
            }
            statsLoaded = true
            statsLock.unlock()
        }
    }

    private func performTurnRecallLocked(
        scope: RecallScope = .deepOnly,
        query: String,
        retractedIDs: Set<String>,
        suppressedHashes: Set<String>,
        recordUsage: Bool,
        config: MemoryRecall.Config
    ) -> [MemoryRecall.Hit] {
        loadStatsLockedIfNeeded()
        let records = MemoryStoreBridge.shared.recordsSnapshot()
        let secrets = Self.orderedSecrets(Vault.allStrings())
        let surfaceTexts = scope == .deepOnly
            ? records
                .filter { $0.deletedAtMs == nil && ($0.layer == .pinned || $0.layer == .surface || $0.pinned) }
                .map(\.text)
            : []

        let hits: [MemoryRecall.Hit]
        do {
            try index.sync(records: records, secrets: secrets)
            switch scope {
            case .deepOnly:
                hits = try index.searchDeep(
                    query: query,
                    surfaceTexts: surfaceTexts,
                    excludedIDs: retractedIDs,
                    suppressedHashes: suppressedHashes,
                    secrets: secrets,
                    config: config
                )
            case .allActive:
                hits = try index.searchAll(
                    query: query,
                    excludedIDs: retractedIDs,
                    suppressedHashes: suppressedHashes,
                    secrets: secrets,
                    config: config
                )
            }
        } catch {
            switch scope {
            case .deepOnly:
                hits = MemoryRecall.searchDeep(
                    query: query,
                    records: records,
                    excludedIDs: retractedIDs,
                    suppressedHashes: suppressedHashes,
                    existingSurfaceTexts: surfaceTexts,
                    secrets: secrets,
                    config: config
                )
            case .allActive:
                hits = MemoryRecall.searchAll(
                    query: query,
                    records: records,
                    excludedIDs: retractedIDs,
                    suppressedHashes: suppressedHashes,
                    secrets: secrets,
                    config: config
                )
            }
        }

        if recordUsage, !hits.isEmpty {
            let nowMs = Now.ms
            let hitIDs = hits.map(\.id)
            mergeUsageIntoCache(ids: hitIDs, nowMs: nowMs)
            try? index.recordUsage(ids: hitIDs, nowMs: nowMs)
        }

        return hits
    }

    private func mergeUsageIntoCache(ids: [String], nowMs: Double) {
        statsLock.lock()
        for id in ids {
            let prev = statsCache[id]
            let prevCount = prev?.recallCount ?? 0
            let prevAt = prev?.lastRecalledAtMs ?? 0
            statsCache[id] = MemoryRecallUsageStat(
                lastRecalledAtMs: max(prevAt, nowMs),
                recallCount: prevCount + 1
            )
        }
        statsLock.unlock()
    }

    private static func orderedSecrets(_ secrets: [String]) -> [String] {
        secrets.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
    }
}
