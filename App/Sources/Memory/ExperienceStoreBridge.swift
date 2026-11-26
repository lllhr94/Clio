import AgentKit
import Craft
import Foundation

/// Off-main bridge coordinating Clio's Canonical `Team/experiences.json` and SQLite `experiences` projection.
final class ExperienceStoreBridge: @unchecked Sendable {
    static let shared = ExperienceStoreBridge()

    let teamRoot: URL
    let canonicalFileURL: URL
    let databaseURL: URL
    let queue = DispatchQueue(label: "Clio.ExperienceStoreBridge", qos: .userInitiated)
    private let store: ExperienceStore

    private init(
        teamRoot: URL? = nil,
        databaseURL: URL? = nil
    ) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let resolvedTeam = teamRoot ?? support.appendingPathComponent("Team", isDirectory: true)
        let resolvedCanonical = resolvedTeam.appendingPathComponent("experiences.json")
        let resolvedDB = databaseURL ?? MemoryStoreBridge.defaultDatabaseURL
        self.teamRoot = resolvedTeam
        self.canonicalFileURL = resolvedCanonical
        self.databaseURL = resolvedDB
        self.store = ExperienceStore(canonicalFileURL: resolvedCanonical, databaseURL: resolvedDB)
    }

    func loadAllOffMain() async -> [ExperienceRecord] {
        await withCheckedContinuation { continuation in
            queue.async { [store] in
                let secrets = Vault.allStrings().filter { !$0.isEmpty }.sorted { $0.count > $1.count }
                let loaded = (try? store.loadAll(includeDeleted: false, secrets: secrets)) ?? []
                continuation.resume(returning: loaded)
            }
        }
    }

    @discardableResult
    func recordOffMain(
        id: String? = nil,
        title: String,
        content: String,
        tags: [String],
        source: ExperienceWriteSource,
        suppressedHashes: Set<String> = []
    ) async throws -> ExperienceRecord {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [store] in
                do {
                    guard !Disk.frozen else {
                        throw ExperienceStoreError.canonicalReadOnly("刚恢复了备份，请先重新打开 Clio")
                    }
                    let secrets = Vault.allStrings().filter { !$0.isEmpty }.sorted { $0.count > $1.count }
                    let saved = try store.record(
                        id: id,
                        title: title,
                        content: content,
                        tags: tags,
                        source: source,
                        nowMs: Now.ms,
                        secrets: secrets,
                        suppressedHashes: suppressedHashes
                    )
                    continuation.resume(returning: saved)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func deleteOffMain(id: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [store] in
                do {
                    guard !Disk.frozen else {
                        throw ExperienceStoreError.canonicalReadOnly("刚恢复了备份，请先重新打开 Clio")
                    }
                    let secrets = Vault.allStrings().filter { !$0.isEmpty }.sorted { $0.count > $1.count }
                    try store.delete(id: id, nowMs: Now.ms, secrets: secrets)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func rebuildFromCanonicalOffMain() async {
        await withCheckedContinuation { continuation in
            queue.async { [store] in
                guard !Disk.frozen else {
                    continuation.resume()
                    return
                }
                let secrets = Vault.allStrings().filter { !$0.isEmpty }.sorted { $0.count > $1.count }
                try? store.rebuildFromCanonical(secrets: secrets)
                continuation.resume()
            }
        }
    }

    func mergeRetractedHashesSync(_ hashes: Set<String>) {
        queue.sync {
            guard !hashes.isEmpty else { return }
            let secrets = Vault.allStrings().filter { !$0.isEmpty }.sorted { $0.count > $1.count }
            try? store.mergeRetractedHashesAndPrune(hashes, nowMs: Now.ms, secrets: secrets)
        }
    }

    func recordTool(
        title: String,
        content: String,
        tags: [String],
        source: ExperienceWriteSource
    ) async -> ToolOutput {
        guard Grant.memory.policy != .off else {
            return ToolOutput("「记性」权限未开启，未保存到经验库。", isError: true)
        }
        guard !Disk.frozen else {
            return ToolOutput("刚恢复了备份，重新打开 Clio 后才能保存新的经验。", isError: true)
        }
        let suppressed = MemoryStoreBridge.shared.tombstoneHashesSnapshot()
        do {
            let saved = try await recordOffMain(
                title: title,
                content: content,
                tags: tags,
                source: source,
                suppressedHashes: suppressed
            )
            return ToolOutput("已记下经验「\(saved.title)」。", detail: saved.id)
        } catch {
            return ToolOutput(error.localizedDescription, isError: true)
        }
    }

    func searchTool(query: String, limit: Int) async -> [ExperienceHit] {
        guard Grant.memory.policy != .off else { return [] }
        let suppressed = MemoryStoreBridge.shared.tombstoneHashesSnapshot()
        return await withCheckedContinuation { continuation in
            queue.async { [store] in
                let secrets = Vault.allStrings().filter { !$0.isEmpty }.sorted { $0.count > $1.count }
                let markUsed = Disk.frozen ? nil : Now.ms
                let hits = (try? store.search(
                    query: query,
                    limit: limit,
                    suppressedHashes: suppressed,
                    secrets: secrets,
                    markUsedNowMs: markUsed
                )) ?? []
                continuation.resume(returning: hits)
            }
        }
    }
}
