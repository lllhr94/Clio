import AgentKit
import Craft
import Foundation

/// App-layer resource loader and single-flight refresher for the `models.dev` catalog (MIT).
///
/// Architectural boundary:
/// - `AgentKit` never reads the App Bundle directly.
/// - App loads the offline bundled trimmed snapshot (`App/Resources/models-dev-catalog.json`)
///   or a validated on-disk cache (`Caches/models-dev-v2.json`) and injects an immutable
///   `ModelsDevCatalogSnapshot` into `ThinkingRuleResolver`.
/// - Network refreshes coalesce through a single-flight actor and pass through
///   `ModelsDevCatalogSnapshot.parseAndValidate` (size cap, schema version, provider/model bounds,
///   required field completeness, and anti-degradation guard against dropped `reasoning_options`/`interleaved`).
enum ModelsDev {
    struct Entry: Codable, Equatable, Sendable {
        var sees: Bool
        var tools: Bool
        var thinks: Bool
        var window: Int
        var outputLimit: Int = 0
        var catalogProviderKey: String? = nil
        var confidence: CatalogMatchConfidence = .ambiguousUnknown
        var supportedEfforts: [String] = []
        var canToggleOff: Bool = false
        var interleavedField: String? = nil
    }

    private static let source = URL(string: "https://models.dev/api.json")!
    private static var cacheFile: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("models-dev-v2.json")
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedSnapshot: ModelsDevCatalogSnapshot? = nil
    nonisolated(unsafe) private static var generationCounter: UInt64 = 0

    private actor RefreshCoordinator {
        private var inFlight: Task<Bool, Never>?

        func run(_ operation: @escaping @Sendable () async -> Bool) async -> Bool {
            if let existing = inFlight {
                return await existing.value
            }
            let task = Task { await operation() }
            inFlight = task
            let result = await task.value
            inFlight = nil
            return result
        }
    }

    private static let refreshCoordinator = RefreshCoordinator()

    /// Returns the currently active immutable catalog snapshot (loading cache or bundled offline
    /// snapshot lazily once if needed and installing it into `ThinkingRuleResolver`).
    static func currentSnapshot() -> ModelsDevCatalogSnapshot {
        lock.lock()
        if let existing = cachedSnapshot {
            lock.unlock()
            return existing
        }
        lock.unlock()

        let loaded = loadFromDiskOrBundle()
        lock.lock()
        if let existing = cachedSnapshot {
            lock.unlock()
            return existing
        }
        cachedSnapshot = loaded
        generationCounter = max(generationCounter, loaded.generation)
        lock.unlock()
        ThinkingRuleResolver.install(snapshot: loaded)
        return loaded
    }

    /// Looks up `model` in the active snapshot (using verified `providerKey` when available).
    static func lookup(
        _ model: String,
        providerKey: String? = nil,
        snapshot: ModelsDevCatalogSnapshot? = nil
    ) -> Entry? {
        let active = snapshot ?? currentSnapshot()
        let result = ThinkingRuleResolver.matchCatalog(
            modelID: model,
            officialProviderKey: providerKey,
            in: active
        )
        guard let entry = result.entry else { return nil }
        return Entry(
            sees: entry.sees,
            tools: entry.tools,
            thinks: entry.thinks,
            window: entry.contextWindow,
            outputLimit: entry.outputLimit,
            catalogProviderKey: entry.catalogProviderKey,
            confidence: result.confidence,
            supportedEfforts: entry.supportedEfforts,
            canToggleOff: entry.canToggleOff,
            interleavedField: entry.interleavedField
        )
    }

    /// Segment-boundary normalized alias candidates for `model`.
    static func candidates(_ model: String) -> [String] {
        ModelsDevCatalogSnapshot.normalizedAliases(for: model)
    }

    /// Locates the bundled offline snapshot in `Clio.app` (works in both app runtime and `ClioAppTests`).
    static func bundledSnapshotURL() -> URL? {
        let bundles = [Bundle.main] + Bundle.allBundles.filter { $0 !== Bundle.main }
        for bundle in bundles {
            if let url = bundle.url(forResource: "models-dev-catalog", withExtension: "json") {
                return url
            }
            if let url = bundle.url(forResource: "models-dev-catalog", withExtension: "json", subdirectory: "Resources") {
                return url
            }
        }
        return nil
    }

    static func bundledSnapshotData() -> Data? {
        guard let url = bundledSnapshotURL() else { return nil }
        return try? Data(contentsOf: url)
    }

    private static func loadFromDiskOrBundle() -> ModelsDevCatalogSnapshot {
        // 1. Prefer previously validated on-disk cache if readable and structurally healthy.
        if let cacheData = try? Data(contentsOf: cacheFile),
           let decoded = try? JSONDecoder().decode(ModelsDevCatalogSnapshot.self, from: cacheData),
           decoded.schemaVersion == ModelsDevCatalogSnapshot.currentSchemaVersion,
           decoded.totalProviders >= ModelsDevCatalogSnapshot.ValidationPolicy.default.minProviders,
           decoded.totalModels >= ModelsDevCatalogSnapshot.ValidationPolicy.default.minModels,
           decoded.modelsWithReasoningOptions >= ModelsDevCatalogSnapshot.ValidationPolicy.default.minReasoningOptionsModels,
           decoded.modelsWithInterleaved >= ModelsDevCatalogSnapshot.ValidationPolicy.default.minInterleavedModels {
            return decoded
        }

        // 2. Fall back to the offline bundled trimmed snapshot.
        if let bundleData = bundledSnapshotData(),
           let parsed = try? ModelsDevCatalogSnapshot.parseAndValidate(data: bundleData, generation: 1) {
            return parsed
        }

        return .empty
    }

    /// Pre-warms the offline/cached snapshot off the main actor, then refreshes from `models.dev`
    /// at most once per 24 hours through a single-flight coordinator.
    static func refreshIfStale() async {
        await Task.detached(priority: .utility) { _ = currentSnapshot() }.value
        let age = (try? cacheFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            .map { Date().timeIntervalSince($0) }
        if let age, age < 24 * 3600 { return }
        _ = await refresh()
    }

    /// Single-flight catalog refresh with strict structural & anti-degradation validation.
    @discardableResult
    static func refresh() async -> Bool {
        await refreshCoordinator.run {
            do {
                var request = URLRequest(url: source)
                request.timeoutInterval = 30
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
                _ = try applyValidatedRefreshData(data, writeCache: true)
                return true
            } catch {
                Diag.note("模型资料库没更新：\(error.localizedDescription)")
                return false
            }
        }
    }

    /// Strict validation boundary for raw catalog payloads; atomically publishes on success and
    /// preserves the last valid snapshot on rejection.
    @discardableResult
    static func applyValidatedRefreshData(
        _ data: Data,
        writeCache: Bool = true,
        policy: ModelsDevCatalogSnapshot.ValidationPolicy = .default
    ) throws -> ModelsDevCatalogSnapshot {
        let nextGen = nextGeneration()
        let validated = try ModelsDevCatalogSnapshot.parseAndValidate(
            data: data,
            generation: nextGen,
            policy: policy
        )
        if writeCache {
            let encoded = try JSONEncoder().encode(validated)
            try encoded.write(to: cacheFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        installInMemory(validated)
        return validated
    }

    /// Installs an already-validated snapshot in memory and pushes it to `ThinkingRuleResolver`.
    static func installInMemory(_ snapshot: ModelsDevCatalogSnapshot) {
        lock.lock()
        cachedSnapshot = snapshot
        generationCounter = max(generationCounter, snapshot.generation)
        lock.unlock()
        ThinkingRuleResolver.install(snapshot: snapshot)
    }

    /// Resets in-memory state (for unit tests verifying cold-start loading and fallback).
    static func resetForTesting() {
        lock.lock()
        cachedSnapshot = nil
        generationCounter = 0
        lock.unlock()
        ThinkingRuleResolver.install(snapshot: .empty)
    }

    private static func nextGeneration() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        generationCounter = max(generationCounter, cachedSnapshot?.generation ?? 0) &+ 1
        return generationCounter
    }

    /// Parses and validates raw catalog JSON without flat `services.values` OR-merging.
    static func parse(_ data: Data) throws -> ModelsDevCatalogSnapshot {
        try ModelsDevCatalogSnapshot.parseAndValidate(data: data, generation: nextGeneration())
    }
}

extension ModelTraits {
    /// What a model can do, best source first: the validated catalog (preserving provider provenance),
    /// else the guess from the name.
    static func known(
        _ model: String,
        providerKey: String? = nil,
        snapshot: ModelsDevCatalogSnapshot? = nil
    ) -> ModelTraits {
        var traits = ModelTraits.guess(model)
        if let entry = ModelsDev.lookup(model, providerKey: providerKey, snapshot: snapshot) {
            traits.sees = entry.sees
            traits.tools = entry.tools
            traits.thinks = entry.thinks
            traits.thinksSource = .catalog
            traits.levelsSource = .catalog
            if entry.window > 0 { traits.window = entry.window }
        }
        return traits
    }
}
