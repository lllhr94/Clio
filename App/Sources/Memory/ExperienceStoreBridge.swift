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
    private let recoveryCheckLock = NSLock()
    private var customRecoveryBlockedCheck: (@Sendable () -> Bool)?
    private var customTombstoneHashesProvider: (@Sendable () -> Set<String>)?
    #if DEBUG
    var beforeRecordEnqueueForTesting: (@Sendable () async -> Void)?
    #endif

    init(
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

    func setCoordinatorHooks(
        recoveryBlockedCheck: @escaping @Sendable () -> Bool,
        tombstoneHashesProvider: @escaping @Sendable () -> Set<String>
    ) {
        recoveryCheckLock.withLock {
            customRecoveryBlockedCheck = recoveryBlockedCheck
            customTombstoneHashesProvider = tombstoneHashesProvider
        }
    }

    private var isSharedSQLiteRecoveryBlocked: Bool {
        if Disk.frozen { return true }
        let check = recoveryCheckLock.withLock { customRecoveryBlockedCheck }
        if let check {
            return check()
        }
        if self === ExperienceStoreBridge.shared {
            return MemoryStoreBridge.shared.isSQLiteRecoveryBlockedForCoordinator
        }
        return false
    }

    private func coordinatorTombstoneHashes() -> Set<String> {
        let provider = recoveryCheckLock.withLock { customTombstoneHashesProvider }
        if let provider {
            return provider()
        }
        if self === ExperienceStoreBridge.shared {
            return MemoryStoreBridge.shared.tombstoneHashesSnapshot()
        }
        return []
    }

    func loadAllOffMain() async -> [ExperienceRecord] {
        await withCheckedContinuation { continuation in
            queue.async { [self, store] in
                guard !Disk.frozen, !self.isSharedSQLiteRecoveryBlocked else {
                    continuation.resume(returning: [])
                    return
                }
                let suppressed = self.coordinatorTombstoneHashes()
                let secrets = Vault.allStrings().filter { !$0.isEmpty }.sorted { $0.count > $1.count }
                let loaded = (try? store.loadAll(includeDeleted: false, suppressedHashes: suppressed, secrets: secrets)) ?? []
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
        #if DEBUG
        if let beforeRecordEnqueueForTesting {
            await beforeRecordEnqueueForTesting()
        }
        #endif
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self, store] in
                do {
                    guard !Disk.frozen else {
                        throw ExperienceStoreError.canonicalReadOnly("刚恢复了备份，请先重新打开 Clio")
                    }
                    guard !self.isSharedSQLiteRecoveryBlocked else {
                        throw ExperienceStoreError.canonicalReadOnly("记忆库正在等待修复或重投，暂不可写入经验库")
                    }
                    var effectiveSuppressed = suppressedHashes
                    effectiveSuppressed.formUnion(self.coordinatorTombstoneHashes())
                    let secrets = Vault.allStrings().filter { !$0.isEmpty }.sorted { $0.count > $1.count }
                    let saved = try store.record(
                        id: id,
                        title: title,
                        content: content,
                        tags: tags,
                        source: source,
                        nowMs: Now.ms,
                        secrets: secrets,
                        suppressedHashes: effectiveSuppressed
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
            queue.async { [self, store] in
                do {
                    guard !Disk.frozen else {
                        throw ExperienceStoreError.canonicalReadOnly("刚恢复了备份，请先重新打开 Clio")
                    }
                    guard !self.isSharedSQLiteRecoveryBlocked else {
                        throw ExperienceStoreError.canonicalReadOnly("记忆库正在等待修复或重投，暂不可修改经验库")
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

    func closeForResetSync() {
        queue.sync {
            store.close()
        }
    }

    func performWithoutReopeningSync(_ body: () throws -> Void) rethrows {
        try queue.sync {
            store.close()
            try body()
        }
    }

    func performDatabaseResetSync<T>(_ body: () throws -> T) throws -> T {
        try queue.sync {
            store.close()
            let result = try body()
            if !Disk.frozen {
                let secrets = Vault.allStrings().filter { !$0.isEmpty }.sorted { $0.count > $1.count }
                try store.rebuildFromCanonical(secrets: secrets)
            }
            return result
        }
    }

    func rebuildFromCanonicalThrowingSync() throws {
        try queue.sync {
            try rebuildFromCanonicalLocked(allowWhenSQLiteRecoveryBlocked: true)
        }
    }

    func rebuildFromCanonicalOffMain() async {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                do {
                    try self?.rebuildFromCanonicalLocked(allowWhenSQLiteRecoveryBlocked: false)
                } catch {
                    let message = error.localizedDescription
                    Diag.note("经验索引重建失败：\(message)")
                }
                continuation.resume()
            }
        }
    }

    func rebuildFromCanonicalSync() {
        queue.sync {
            do {
                try rebuildFromCanonicalLocked(allowWhenSQLiteRecoveryBlocked: false)
            } catch {
                Diag.note("经验索引重建失败：\(error.localizedDescription)")
            }
        }
    }

    private func rebuildFromCanonicalLocked(allowWhenSQLiteRecoveryBlocked: Bool = false) throws {
        guard !Disk.frozen else { return }
        if !allowWhenSQLiteRecoveryBlocked, isSharedSQLiteRecoveryBlocked {
            return
        }
        let secrets = Vault.allStrings().filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        try store.rebuildFromCanonical(secrets: secrets)
    }

    func mergeRetractedHashesSync(_ hashes: Set<String>) {
        queue.sync {
            guard !hashes.isEmpty, !Disk.frozen, !isSharedSQLiteRecoveryBlocked else { return }
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
        guard !isSharedSQLiteRecoveryBlocked else {
            return ToolOutput("记忆库正在等待修复或重投，暂不可写入经验库。", isError: true)
        }
        do {
            let saved = try await recordOffMain(
                title: title,
                content: content,
                tags: tags,
                source: source,
                suppressedHashes: []
            )
            return ToolOutput("已记下经验「\(saved.title)」。", detail: saved.id)
        } catch {
            return ToolOutput(error.localizedDescription, isError: true)
        }
    }

    func searchTool(query: String, limit: Int) async -> [ExperienceHit] {
        guard Grant.memory.policy != .off else { return [] }
        return await withCheckedContinuation { continuation in
            queue.async { [self, store] in
                guard !Disk.frozen, !self.isSharedSQLiteRecoveryBlocked else {
                    continuation.resume(returning: [])
                    return
                }
                let suppressed = self.coordinatorTombstoneHashes()
                let secrets = Vault.allStrings().filter { !$0.isEmpty }.sorted { $0.count > $1.count }
                let hits = (try? store.search(
                    query: query,
                    limit: limit,
                    suppressedHashes: suppressed,
                    secrets: secrets,
                    markUsedNowMs: nil
                )) ?? []
                continuation.resume(returning: hits)
            }
        }
    }
}
