import AgentKit
import Craft
import Foundation

/// Serializes access to the canonical experience book off the main actor.
final class ExperienceStoreBridge: @unchecked Sendable {
    static let shared = ExperienceStoreBridge()

    let canonicalFileURL: URL
    let queue = DispatchQueue(label: "Clio.ExperienceStoreBridge", qos: .userInitiated)
    private let store: ExperienceStore
    private let providerLock = NSLock()
    private var customTombstoneHashesProvider: (@Sendable () -> Set<String>)?

    init(teamRoot: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let resolvedTeam = teamRoot ?? support.appendingPathComponent("Team", isDirectory: true)
        let resolvedCanonical = resolvedTeam.appendingPathComponent("experiences.json")
        self.canonicalFileURL = resolvedCanonical
        self.store = ExperienceStore(canonicalFileURL: resolvedCanonical)
    }

    func setTombstoneHashesProvider(_ provider: @escaping @Sendable () -> Set<String>) {
        providerLock.withLock { customTombstoneHashesProvider = provider }
    }

    private func tombstoneHashes() -> Set<String> {
        if let provider = providerLock.withLock({ customTombstoneHashesProvider }) {
            return provider()
        }
        return self === Self.shared ? MemoryStoreBridge.shared.tombstoneHashesSnapshot() : []
    }

    private func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    private func checkWritable() throws {
        guard !Disk.frozen else {
            throw ExperienceStoreError.canonicalReadOnly("刚恢复了备份，请先重新打开 Clio")
        }
    }

    func loadAllOffMain() async -> [ExperienceRecord] {
        (try? await offMain { [self] in
            guard !Disk.frozen else { return [] }
            return try store.loadAll(suppressedHashes: tombstoneHashes(), secrets: Vault.allStrings())
        }) ?? []
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
        try await offMain { [self] in
            try checkWritable()
            return try store.record(
                id: id, title: title, content: content, tags: tags, source: source,
                nowMs: Now.ms, secrets: Vault.allStrings(),
                suppressedHashes: suppressedHashes.union(tombstoneHashes())
            )
        }
    }

    func deleteOffMain(id: String) async throws {
        try await offMain { [self] in
            try checkWritable()
            try store.delete(id: id, nowMs: Now.ms, secrets: Vault.allStrings())
        }
    }

    func mergeRetractedHashesSync(_ hashes: Set<String>) {
        queue.sync {
            guard !Disk.frozen else { return }
            let combined = hashes.union(tombstoneHashes())
            guard !combined.isEmpty else { return }
            try? store.mergeRetractedHashesAndPrune(combined, nowMs: Now.ms, secrets: Vault.allStrings())
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
        do {
            let saved = try await recordOffMain(
                title: title,
                content: content,
                tags: tags,
                source: source
            )
            return ToolOutput("已记下经验「\(saved.title)」。", detail: saved.id)
        } catch {
            return ToolOutput(error.localizedDescription, isError: true)
        }
    }

    func searchTool(query: String, limit: Int) async -> [ExperienceHit] {
        guard Grant.memory.policy != .off else { return [] }
        return (try? await offMain { [self] in
            guard !Disk.frozen else { return [] }
            return try store.search(
                query: query, limit: limit, suppressedHashes: tombstoneHashes(), secrets: Vault.allStrings()
            )
        }) ?? []
    }
}
