import Foundation

/// A provider that can report both model IDs and service-reported context windows without
/// forcing callers to downcast to a concrete provider type.
public protocol CatalogReportingProvider: ModelProvider {
    func catalog() async throws -> (ids: [String], windows: [String: Int])
}

extension OpenAIProvider: CatalogReportingProvider {}

/// A safe placeholder provider for endpoints disabled due to an unknown protocol `Kind`
/// or unrecognized `ThinkingStyle`. Fails locally without performing network I/O or sending credentials.
public struct DisabledProtocolProvider: ModelProvider, Sendable {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }

    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        let message = reason
        return AsyncThrowingStream { continuation in
            continuation.finish(throwing: ProviderError(status: nil, message))
        }
    }

    public func models() async throws -> [String] {
        throw ProviderError(status: nil, reason)
    }
}

/// High-level intent behind a model invocation so internal low-latency calls do not share
/// user-facing `explicitOff` failure semantics.
public enum ThinkingCallIntent: String, Codable, Equatable, Hashable, Sendable {
    /// Interactive chat turn driven by the user's explicit selection.
    case userChat
    /// Internal probes, short utility prompts, and nightly organizers.
    case preferLowLatency
    /// Real conversation compression (inherits default contract separately).
    case conversationCompression
}

/// Versioned high-fidelity thinking selection (v2).
/// Preserves exact effort tokens (`minimal`, `low`, `medium`, `high`, `xhigh`, `max`),
/// explicit on/off intent, optional token budget, and tolerates unknown future payloads.
public enum ThinkingSelection: Equatable, Hashable, Sendable {
    /// Follow the endpoint/model default without emitting unsolicited thinking overrides.
    case inheritDefault
    /// User explicitly requested thinking OFF (requires a verified off-encoding before sending).
    case explicitOff
    /// User explicitly requested thinking ON (toggle-only or budget-only models).
    case explicitOn(budget: Int? = nil)
    /// Explicit named effort level (e.g. `minimal`, `low`, `medium`, `high`, `xhigh`, `max`).
    case effort(String, budget: Int? = nil)
    /// Forward-compatible placeholder for unrecognized future selection encodings.
    case unknown(kind: String, value: String?, budget: Int?)

    public static let currentVersion = 2

    /// Canonical effort order from lightest to deepest.
    public static let effortOrder = ["minimal", "low", "medium", "high", "xhigh", "max"]

    /// Stable persistence identifier completely decoupled from localized UI tone copy.
    public var stableID: String {
        switch self {
        case .inheritDefault: return "inherit_default"
        case .explicitOff: return "explicit_off"
        case .explicitOn(let budget):
            return budget.map { "explicit_on:budget=\($0)" } ?? "explicit_on"
        case .effort(let raw, let budget):
            let key = raw.lowercased()
            return budget.map { "effort:\(key):budget=\($0)" } ?? "effort:\(key)"
        case .unknown(let kind, let value, let budget):
            return "unknown:\(kind):\(value ?? ""):\(budget.map(String.init) ?? "")"
        }
    }

    public var isDefault: Bool {
        if case .inheritDefault = self { return true }
        return false
    }

    public var isExplicitOff: Bool {
        if case .explicitOff = self { return true }
        return false
    }

    public var effortName: String? {
        if case .effort(let value, _) = self { return value.lowercased() }
        return nil
    }

    public var budgetTokens: Int? {
        switch self {
        case .explicitOn(let budget), .effort(_, let budget), .unknown(_, _, let budget):
            return budget
        case .inheritDefault, .explicitOff:
            return nil
        }
    }

    /// Maps a legacy 6-stop `Thinking` value into the versioned selection model.
    public static func fromLegacy(_ legacy: Thinking?) -> ThinkingSelection {
        guard let legacy else { return .inheritDefault }
        switch legacy {
        case .auto: return .inheritDefault
        case .off: return .explicitOff
        case .low: return .effort("low")
        case .medium: return .effort("medium")
        case .high: return .effort("high")
        case .max: return .effort("max")
        }
    }

    /// Returns a legacy `Thinking` mirror ONLY when the selection can be faithfully represented
    /// without lossy coercion (e.g. `minimal`, `xhigh`, `explicitOn`, budgeted, and `unknown` return `nil`).
    public var legacyMirror: Thinking? {
        switch self {
        case .inheritDefault: return nil
        case .explicitOff: return .off
        case .effort(let value, let budget) where budget == nil:
            switch value.lowercased() {
            case "low": return .low
            case "medium": return .medium
            case "high": return .high
            case "max": return .max
            default: return nil
            }
        case .explicitOn, .effort, .unknown:
            return nil
        }
    }

    /// Best-effort legacy `Thinking` approximation for legacy provider APIs (never used to overwrite storage).
    public var approximateLegacyThinking: Thinking {
        switch self {
        case .inheritDefault, .unknown: return .auto
        case .explicitOff: return .off
        case .explicitOn: return .medium
        case .effort(let value, _):
            switch value.lowercased() {
            case "none": return .off
            case "minimal", "low": return .low
            case "medium": return .medium
            case "high", "xhigh": return .high
            case "max": return .max
            default: return .auto
            }
        }
    }

    /// Locked read order: v2 `ThinkingSelection` takes precedence; legacy `Thinking` is consulted
    /// ONLY when v2 is absent.
    public static func readEffective(v2: ThinkingSelection?, legacy: Thinking?) -> ThinkingSelection {
        if let v2 { return v2 }
        return fromLegacy(legacy)
    }

    /// Locked write pair: stores v2 as the authoritative field and writes the legacy mirror ONLY
    /// when it is faithfully expressible without corrupting the user's intent.
    public static func writePair(_ selection: ThinkingSelection) -> (v2: ThinkingSelection?, legacy: Thinking?) {
        if case .inheritDefault = selection {
            return (nil, nil)
        }
        return (selection, selection.legacyMirror)
    }

    public var title: String {
        switch self {
        case .inheritDefault: return Thinking.auto.title
        case .explicitOff: return Thinking.off.title
        case .explicitOn: return "开启"
        case .effort(let value, _):
            switch value.lowercased() {
            case "minimal": return "极浅"
            case "low": return Thinking.low.title
            case "medium": return Thinking.medium.title
            case "high": return Thinking.high.title
            case "xhigh": return "极深"
            case "max": return Thinking.max.title
            default: return value
            }
        case .unknown(let kind, let value, _):
            return value ?? kind
        }
    }

    public var line: String {
        switch self {
        case .inheritDefault: return Thinking.auto.line
        case .explicitOff: return Thinking.off.line
        case .explicitOn: return "开启思考，由模型自定深度"
        case .effort(let value, _):
            switch value.lowercased() {
            case "minimal": return "极少思考，更快"
            case "low": return Thinking.low.line
            case "medium": return Thinking.medium.line
            case "high": return Thinking.high.line
            case "xhigh": return "深度推理，适合高难任务"
            case "max": return Thinking.max.line
            default: return "思考强度：\(value)"
            }
        case .unknown:
            return "来自较新版本的思考设定"
        }
    }

    public var symbol: String {
        switch self {
        case .inheritDefault: return Thinking.auto.symbol
        case .explicitOff: return Thinking.off.symbol
        case .explicitOn: return "brain"
        case .effort(let value, _):
            switch value.lowercased() {
            case "minimal", "low": return Thinking.low.symbol
            case "medium": return Thinking.medium.symbol
            case "high": return Thinking.high.symbol
            case "xhigh", "max": return Thinking.max.symbol
            default: return "brain"
            }
        case .unknown:
            return "brain"
        }
    }
}

extension ThinkingSelection: Codable {
    private enum CodingKeys: String, CodingKey {
        case version
        case kind
        case effort
        case value
        case budget
    }

    public init(from decoder: Decoder) throws {
        // Also tolerate bare string values if an older/hand-edited file wrote a string.
        if let single = try? decoder.singleValueContainer(), let raw = try? single.decode(String.self) {
            if let legacy = Thinking(rawValue: raw) {
                self = .fromLegacy(legacy)
            } else {
                self = .unknown(kind: "raw", value: raw, budget: nil)
            }
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = (try? container.decode(String.self, forKey: .kind)) ?? ""
        let effort = (try? container.decodeIfPresent(String.self, forKey: .effort))
            ?? (try? container.decodeIfPresent(String.self, forKey: .value))
        let budget = try? container.decodeIfPresent(Int.self, forKey: .budget)

        switch kind {
        case "inherit_default", "auto":
            self = .inheritDefault
        case "explicit_off", "off":
            self = .explicitOff
        case "explicit_on", "on":
            self = .explicitOn(budget: budget)
        case "effort":
            if let effort, !effort.isEmpty {
                self = .effort(effort.lowercased(), budget: budget)
            } else {
                self = .unknown(kind: kind, value: effort, budget: budget)
            }
        default:
            self = .unknown(kind: kind.isEmpty ? "unspecified" : kind, value: effort, budget: budget)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentVersion, forKey: .version)
        switch self {
        case .inheritDefault:
            try container.encode("inherit_default", forKey: .kind)
        case .explicitOff:
            try container.encode("explicit_off", forKey: .kind)
        case .explicitOn(let budget):
            try container.encode("explicit_on", forKey: .kind)
            try container.encodeIfPresent(budget, forKey: .budget)
        case .effort(let value, let budget):
            try container.encode("effort", forKey: .kind)
            try container.encode(value.lowercased(), forKey: .effort)
            try container.encodeIfPresent(budget, forKey: .budget)
        case .unknown(let kind, let value, let budget):
            try container.encode(kind, forKey: .kind)
            try container.encodeIfPresent(value, forKey: .value)
            try container.encodeIfPresent(budget, forKey: .budget)
        }
    }
}

/// JSON-compatible wire value that stays `Equatable`, `Hashable`, and `Sendable`.
public enum ThinkingWireValue: Codable, Equatable, Hashable, Sendable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case object([String: ThinkingWireValue])

    public var foundationValue: Any {
        switch self {
        case .string(let v): return v
        case .bool(let v): return v
        case .int(let v): return v
        case .object(let dict): return dict.mapValues(\.foundationValue)
        }
    }
}

/// Reasoning capability shape preserved per `(catalogProviderKey, rawModelID)` without lossy OR-merging.
public enum CatalogReasoningMode: String, Codable, Equatable, Hashable, Sendable {
    /// Catalog omitted reasoning fields for this model.
    case unspecified
    /// Catalog explicitly marks `reasoning: false`.
    case disabled
    /// Supports on/off toggle without named effort values.
    case toggleOnly
    /// Always thinks (no toggle and no `"none"` effort value).
    case forced
    /// Explicit set of named effort values (may also allow toggle/none).
    case effortSet
    /// Explicit token budget without named effort values.
    case budgetOnly
    /// Supports both named effort values and token budget.
    case effortAndBudget
}

/// How a catalog entry was matched. Only `.authoritative` confirms an official provider + model pairing;
/// stages 2–4 are explainable hints and never alone dictate wire encoding on unknown relays.
public enum CatalogMatchConfidence: String, Codable, Equatable, Hashable, Sendable {
    case authoritative
    case bareHint
    case strippedHint
    case familyHint
    case ambiguousUnknown
}

/// Single model entry in a `ModelsDevCatalogSnapshot` preserving full source identity.
public struct CatalogModelEntry: Codable, Equatable, Hashable, Sendable {
    public var rawModelID: String
    public var catalogProviderKey: String
    public var canonicalModelID: String
    public var normalizedAliases: [String]
    public var sees: Bool
    public var tools: Bool
    /// Optional to distinguish missing `reasoning` field from explicit `false` or `true`.
    public var reasoning: Bool?
    public var reasoningMode: CatalogReasoningMode
    /// Whether the catalog explicitly documents a way to disable thinking (`toggle` or `"none"` effort).
    public var canToggleOff: Bool
    /// When disabling is expressed via an effort value such as `"none"`, preserves that exact token.
    public var explicitOffEffortToken: String?
    /// Non-off named effort values in catalog order (e.g. `["minimal", "low", "medium", "high"]` or `["low", "high", "max"]`).
    public var supportedEfforts: [String]
    public var budgetMin: Int?
    public var budgetMax: Int?
    /// Interleaved reasoning echo field name (e.g. `"reasoning_content"`), if declared.
    public var interleavedField: String?
    public var contextWindow: Int
    public var outputLimit: Int

    public init(
        rawModelID: String,
        catalogProviderKey: String,
        canonicalModelID: String,
        normalizedAliases: [String],
        sees: Bool,
        tools: Bool,
        reasoning: Bool?,
        reasoningMode: CatalogReasoningMode,
        canToggleOff: Bool,
        explicitOffEffortToken: String? = nil,
        supportedEfforts: [String] = [],
        budgetMin: Int? = nil,
        budgetMax: Int? = nil,
        interleavedField: String? = nil,
        contextWindow: Int = 0,
        outputLimit: Int = 0
    ) {
        self.rawModelID = rawModelID
        self.catalogProviderKey = catalogProviderKey
        self.canonicalModelID = canonicalModelID
        self.normalizedAliases = normalizedAliases
        self.sees = sees
        self.tools = tools
        self.reasoning = reasoning
        self.reasoningMode = reasoningMode
        self.canToggleOff = canToggleOff
        self.explicitOffEffortToken = explicitOffEffortToken
        self.supportedEfforts = supportedEfforts
        self.budgetMin = budgetMin
        self.budgetMax = budgetMax
        self.interleavedField = interleavedField
        self.contextWindow = contextWindow
        self.outputLimit = outputLimit
    }

    public var thinks: Bool {
        reasoning == true
    }
}

/// Errors raised by the strict validation boundary when loading or refreshing a `models.dev` snapshot.
public enum CatalogValidationError: Error, Equatable, Sendable {
    case oversize(bytes: Int, limit: Int)
    case invalidJSON
    case unsupportedSchemaVersion(Int)
    case providerCountOutOfBounds(Int)
    case modelCountOutOfBounds(Int)
    case missingRequiredFields(validRatio: Double, minimum: Double)
    case capabilityDegradation(reasoningOptionsCount: Int, interleavedCount: Int)
}

/// Immutable, validated snapshot of the `models.dev` catalog injected by the App layer into `AgentKit`.
/// `AgentKit` never reads the App Bundle directly.
public struct ModelsDevCatalogSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public struct ValidationPolicy: Equatable, Sendable {
        public var maxBytes: Int
        public var minProviders: Int
        public var maxProviders: Int
        public var minModels: Int
        public var maxModels: Int
        public var minReasoningOptionsModels: Int
        public var minInterleavedModels: Int
        public var minValidModelFieldRatio: Double

        public init(
            maxBytes: Int = 25 * 1024 * 1024,
            minProviders: Int = 10,
            maxProviders: Int = 2_000,
            minModels: Int = 100,
            maxModels: Int = 50_000,
            minReasoningOptionsModels: Int = 20,
            minInterleavedModels: Int = 10,
            minValidModelFieldRatio: Double = 0.70
        ) {
            self.maxBytes = maxBytes
            self.minProviders = minProviders
            self.maxProviders = maxProviders
            self.minModels = minModels
            self.maxModels = maxModels
            self.minReasoningOptionsModels = minReasoningOptionsModels
            self.minInterleavedModels = minInterleavedModels
            self.minValidModelFieldRatio = minValidModelFieldRatio
        }

        public static let `default` = ValidationPolicy()
    }

    public var schemaVersion: Int
    public var upstream: String
    public var generatedAt: String
    public var generation: UInt64
    /// Provider key (lowercased) -> lowercased raw model ID -> `CatalogModelEntry`.
    public var entriesByProvider: [String: [String: CatalogModelEntry]]
    public var totalProviders: Int
    public var totalModels: Int
    public var modelsWithReasoningOptions: Int
    public var modelsWithInterleaved: Int

    public init(
        schemaVersion: Int = ModelsDevCatalogSnapshot.currentSchemaVersion,
        upstream: String = "https://models.dev/api.json",
        generatedAt: String = "",
        generation: UInt64 = 1,
        entriesByProvider: [String: [String: CatalogModelEntry]]
    ) {
        self.schemaVersion = schemaVersion
        self.upstream = upstream
        self.generatedAt = generatedAt
        self.generation = generation
        self.entriesByProvider = entriesByProvider
        self.totalProviders = entriesByProvider.count
        var models = 0
        var withOptions = 0
        var withInterleaved = 0
        for modelsMap in entriesByProvider.values {
            for entry in modelsMap.values {
                models += 1
                if !entry.supportedEfforts.isEmpty || entry.canToggleOff || entry.budgetMin != nil {
                    withOptions += 1
                }
                if entry.interleavedField != nil {
                    withInterleaved += 1
                }
            }
        }
        self.totalModels = models
        self.modelsWithReasoningOptions = withOptions
        self.modelsWithInterleaved = withInterleaved
    }

    public static let empty = ModelsDevCatalogSnapshot(generation: 0, entriesByProvider: [:])

    /// Parses and strictly validates either the bundled schema v2 trimmed snapshot or raw upstream
    /// `https://models.dev/api.json` payload. Rejects oversized, structurally degraded, or schema-incompatible payloads.
    public static func parseAndValidate(
        data: Data,
        generation: UInt64 = 1,
        policy: ValidationPolicy = .default
    ) throws -> ModelsDevCatalogSnapshot {
        if data.count > policy.maxBytes {
            throw CatalogValidationError.oversize(bytes: data.count, limit: policy.maxBytes)
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CatalogValidationError.invalidJSON
        }

        let servicesObject: [String: Any]
        let schemaVersion: Int
        let upstream: String
        let generatedAt: String

        if let rawVersion = root["schemaVersion"] {
            guard let versionInt = (rawVersion as? NSNumber)?.intValue, !(rawVersion is Bool) else {
                throw CatalogValidationError.invalidJSON
            }
            guard versionInt == currentSchemaVersion else {
                throw CatalogValidationError.unsupportedSchemaVersion(versionInt)
            }
            guard let wrappedServices = root["services"] as? [String: Any] else {
                throw CatalogValidationError.invalidJSON
            }
            schemaVersion = versionInt
            upstream = (root["upstream"] as? String) ?? "https://models.dev/api.json"
            generatedAt = (root["generatedAt"] as? String) ?? ""
            servicesObject = wrappedServices
        } else {
            schemaVersion = currentSchemaVersion
            upstream = "https://models.dev/api.json"
            generatedAt = ""
            servicesObject = root
        }

        var entriesByProvider: [String: [String: CatalogModelEntry]] = [:]
        var totalModels = 0
        var validRequiredFieldModels = 0
        var reasoningOptionsCount = 0
        var interleavedCount = 0

        for (rawProviderKey, rawService) in servicesObject {
            guard let serviceDict = rawService as? [String: Any],
                  let modelsDict = serviceDict["models"] as? [String: Any] else { continue }
            let providerKey = rawProviderKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !providerKey.isEmpty else { continue }

            var providerModels: [String: CatalogModelEntry] = [:]
            for (rawModelID, rawModelValue) in modelsDict {
                guard let modelDict = rawModelValue as? [String: Any] else { continue }
                let trimmedID = rawModelID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedID.isEmpty else { continue }
                totalModels += 1

                let hasModalities = modelDict["modalities"] is [String: Any]
                let hasLimit = modelDict["limit"] is [String: Any]
                let hasReasoningField = modelDict["reasoning"] is Bool
                let hasToolCallField = modelDict["tool_call"] is Bool
                if hasModalities || hasLimit || (hasReasoningField && hasToolCallField) {
                    validRequiredFieldModels += 1
                }

                let inputs = (modelDict["modalities"] as? [String: Any])?["input"] as? [String] ?? []
                let attachment = modelDict["attachment"] as? Bool ?? false
                let sees = inputs.contains("image") || (attachment && inputs.isEmpty)
                let tools = modelDict["tool_call"] as? Bool ?? true
                let reasoning = modelDict["reasoning"] as? Bool

                let limitDict = modelDict["limit"] as? [String: Any]
                let contextWindow = (limitDict?["context"] as? NSNumber)?.intValue ?? 0
                let outputLimit = (limitDict?["output"] as? NSNumber)?.intValue ?? 0

                var hasToggle = false
                var explicitOffEffortToken: String? = nil
                var efforts: [String] = []
                var budgetMin: Int? = nil
                var budgetMax: Int? = nil
                var hasReasoningOptions = false

                if let options = modelDict["reasoning_options"] as? [[String: Any]], !options.isEmpty {
                    hasReasoningOptions = true
                    for option in options {
                        guard let type = (option["type"] as? String)?.lowercased() else { continue }
                        switch type {
                        case "toggle":
                            hasToggle = true
                        case "effort":
                            if let values = option["values"] as? [String] {
                                for rawVal in values {
                                    let val = rawVal.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                                    guard !val.isEmpty else { continue }
                                    if val == "none" || val == "off" || val == "disabled" {
                                        hasToggle = true
                                        if explicitOffEffortToken == nil { explicitOffEffortToken = val }
                                    } else if !efforts.contains(val) {
                                        efforts.append(val)
                                    }
                                }
                            }
                        case "budget_tokens":
                            if let minVal = (option["min"] as? NSNumber)?.intValue {
                                budgetMin = minVal
                            }
                            if let maxVal = (option["max"] as? NSNumber)?.intValue {
                                budgetMax = maxVal
                            }
                        default:
                            break
                        }
                    }
                }
                if hasReasoningOptions {
                    reasoningOptionsCount += 1
                }

                let interleavedField: String?
                if let interleavedDict = modelDict["interleaved"] as? [String: Any],
                   let field = interleavedDict["field"] as? String, !field.isEmpty {
                    interleavedField = field
                    interleavedCount += 1
                } else if (modelDict["interleaved"] as? Bool) == true {
                    interleavedField = "reasoning_content"
                    interleavedCount += 1
                } else {
                    interleavedField = nil
                }

                let reasoningMode: CatalogReasoningMode
                if reasoning == nil && !hasReasoningOptions {
                    reasoningMode = .unspecified
                } else if reasoning == false {
                    reasoningMode = .disabled
                } else {
                    let hasEfforts = !efforts.isEmpty
                    let hasBudget = budgetMin != nil || budgetMax != nil
                    if hasEfforts && hasBudget {
                        reasoningMode = .effortAndBudget
                    } else if hasEfforts {
                        reasoningMode = .effortSet
                    } else if hasBudget {
                        reasoningMode = .budgetOnly
                    } else if hasToggle {
                        reasoningMode = .toggleOnly
                    } else {
                        reasoningMode = .forced
                    }
                }

                let canonical = Self.canonicalModelID(from: trimmedID)
                let aliases = Self.normalizedAliases(for: trimmedID)
                let entry = CatalogModelEntry(
                    rawModelID: trimmedID,
                    catalogProviderKey: providerKey,
                    canonicalModelID: canonical,
                    normalizedAliases: aliases,
                    sees: sees,
                    tools: tools,
                    reasoning: reasoning,
                    reasoningMode: reasoningMode,
                    canToggleOff: hasToggle,
                    explicitOffEffortToken: explicitOffEffortToken,
                    supportedEfforts: efforts,
                    budgetMin: budgetMin,
                    budgetMax: budgetMax,
                    interleavedField: interleavedField,
                    contextWindow: contextWindow,
                    outputLimit: outputLimit
                )
                providerModels[trimmedID.lowercased()] = entry
            }
            if !providerModels.isEmpty {
                entriesByProvider[providerKey] = providerModels
            }
        }

        let providerCount = entriesByProvider.count
        guard providerCount >= policy.minProviders && providerCount <= policy.maxProviders else {
            throw CatalogValidationError.providerCountOutOfBounds(providerCount)
        }
        guard totalModels >= policy.minModels && totalModels <= policy.maxModels else {
            throw CatalogValidationError.modelCountOutOfBounds(totalModels)
        }
        let validRatio = totalModels > 0 ? Double(validRequiredFieldModels) / Double(totalModels) : 0
        guard validRatio >= policy.minValidModelFieldRatio else {
            throw CatalogValidationError.missingRequiredFields(validRatio: validRatio, minimum: policy.minValidModelFieldRatio)
        }
        guard reasoningOptionsCount >= policy.minReasoningOptionsModels && interleavedCount >= policy.minInterleavedModels else {
            throw CatalogValidationError.capabilityDegradation(
                reasoningOptionsCount: reasoningOptionsCount,
                interleavedCount: interleavedCount
            )
        }

        return ModelsDevCatalogSnapshot(
            schemaVersion: schemaVersion,
            upstream: upstream,
            generatedAt: generatedAt,
            generation: generation,
            entriesByProvider: entriesByProvider
        )
    }

    /// Normalizes a model ID by stripping provider routing prefix (`provider/model`) without losing semantic identity.
    public static func canonicalModelID(from raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let slash = name.lastIndex(of: "/") {
            let tail = String(name[name.index(after: slash)...])
            if !tail.isEmpty { name = tail }
        }
        return name
    }

    /// Segment-boundary normalized candidates for stage 2/3 hint matching.
    public static func normalizedAliases(for raw: String) -> [String] {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return [] }
        var out: [String] = [lower]
        var bare = lower
        if let slash = bare.lastIndex(of: "/") {
            let tail = String(bare[bare.index(after: slash)...])
            if !tail.isEmpty { bare = tail; out.append(bare) }
        }
        // Strip known colon suffixes (`:free`, `:thinking`, `:exacto`, `:extended`, `:online`) or prefixes (`cn:`).
        if let colon = bare.lastIndex(of: ":") {
            let left = String(bare[..<colon])
            let right = String(bare[bare.index(after: colon)...])
            let knownSuffixes: Set<String> = ["free", "thinking", "exacto", "extended", "online", "beta"]
            if knownSuffixes.contains(right), !left.isEmpty {
                bare = left
                out.append(bare)
            } else if !right.isEmpty {
                bare = right
                out.append(bare)
            }
        }
        var segments = bare.split(separator: "-").map(String.init)
        let removableTags: Set<String> = ["latest", "preview", "exp", "beta", "free", "online"]
        while segments.count > 1 {
            guard let last = segments.last else { break }
            let isDate = (last.count == 8 || last.count == 4) && last.allSatisfy { $0.isASCII && $0.isNumber }
            if isDate || removableTags.contains(last) {
                segments.removeLast()
                out.append(segments.joined(separator: "-"))
            } else {
                break
            }
        }
        var seen: Set<String> = []
        return out.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// Immutable contract key identifying a concrete `(origin, protocolKind, route, modelID)` target.
public struct EndpointContractKey: Codable, Equatable, Hashable, Sendable {
    public var origin: String
    public var protocolKind: String
    public var route: String
    public var modelID: String

    public init(origin: String, protocolKind: String, route: String, modelID: String) {
        self.origin = Self.normalizeOrigin(origin)
        self.protocolKind = protocolKind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.route = Self.normalizeRoute(route)
        self.modelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public func matches(_ other: EndpointContractKey) -> Bool {
        origin == other.origin
            && protocolKind == other.protocolKind
            && route == other.route
            && modelID == other.modelID
    }

    public static func normalizeOrigin(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty else {
            return trimmed.lowercased()
        }
        if let port = components.port {
            let isDefault = (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
            return isDefault ? "\(scheme)://\(host)" : "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }

    public static func normalizeRoute(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.count > 1 && value.hasSuffix("/") { value.removeLast() }
        if !value.isEmpty && !value.hasPrefix("/") { value = "/" + value }
        return value.lowercased()
    }
}

/// User-confirmed manual thinking rule bound strictly to an `(origin, protocolKind, route, modelID)` contract.
/// On backup restore, rules MUST be revalidated against the restored endpoint contract before activation.
public struct ManualThinkingRule: Codable, Equatable, Hashable, Sendable {
    public var contract: EndpointContractKey
    public var canDisable: Bool
    public var supportedEfforts: [String]
    public var wireStyle: ThinkingStyle?
    public var ruleGeneration: UInt64

    public init(
        contract: EndpointContractKey,
        canDisable: Bool,
        supportedEfforts: [String],
        wireStyle: ThinkingStyle? = nil,
        ruleGeneration: UInt64 = 1
    ) {
        self.contract = contract
        self.canDisable = canDisable
        self.supportedEfforts = supportedEfforts.map { $0.lowercased() }
        self.wireStyle = wireStyle
        self.ruleGeneration = ruleGeneration
    }

    public func isValid(for target: EndpointContractKey) -> Bool {
        contract.matches(target)
    }
}

/// Pure, data-driven thinking resolution engine injected with an immutable `ModelsDevCatalogSnapshot`.
public enum ThinkingRuleResolver {
    public struct CatalogMatchResult: Equatable, Sendable {
        public var entry: CatalogModelEntry?
        public var confidence: CatalogMatchConfidence
        public var matchedStage: Int
        public var explanation: String

        public init(entry: CatalogModelEntry?, confidence: CatalogMatchConfidence, matchedStage: Int, explanation: String) {
            self.entry = entry
            self.confidence = confidence
            self.matchedStage = matchedStage
            self.explanation = explanation
        }
    }

    public struct ConfirmedContract: Equatable, Sendable {
        public var contractKey: EndpointContractKey
        public var catalogProviderKey: String?
        public var isConfirmedOfficialOrigin: Bool
        public var isKnownContract: Bool
        public var supportsThinking: Bool
        public var canExplicitlyDisable: Bool
        public var offeredSelections: [ThinkingSelection]
        public var effortAliases: [String: String]
        public var mutualExclusionPolicy: String?
        public var echoesReasoning: Bool
        public var interleavedField: String?
        public var ruleGeneration: UInt64
        public var matchResult: CatalogMatchResult
    }

    public enum SelectionFulfillment: Equatable, Sendable {
        case fulfilled(effective: ThinkingSelection, migratedFrom: ThinkingSelection?, note: String?)
        /// `explicitOff` requested against a model or unconfirmed relay with no verified off-encoding.
        /// Callers MUST halt locally with 0 network requests and preserve the user's saved selection.
        case unfulfilledExplicitOff(reason: String)
        /// Saved selection cannot be fulfilled on the current model; preserve saved selection and show reason.
        case unfulfilledSelection(requested: ThinkingSelection, reason: String)
    }

    public struct Resolution: Equatable, Sendable {
        public var contract: ConfirmedContract
        public var requested: ThinkingSelection
        public var intent: ThinkingCallIntent
        public var fulfillment: SelectionFulfillment
        public var bodyFields: [String: ThinkingWireValue]

        public var foundationBodyFields: [String: Any] {
            bodyFields.mapValues(\.foundationValue)
        }
    }

    // MARK: Immutable Snapshot Injection

    private final class SnapshotBox: @unchecked Sendable {
        private let lock = NSLock()
        private var snapshot: ModelsDevCatalogSnapshot = .empty

        func current() -> ModelsDevCatalogSnapshot {
            lock.lock()
            defer { lock.unlock() }
            return snapshot
        }

        func install(_ next: ModelsDevCatalogSnapshot) {
            lock.lock()
            snapshot = next
            lock.unlock()
        }
    }

    private static let store = SnapshotBox()

    /// Atomically installs a validated immutable catalog snapshot from the App layer.
    public static func install(snapshot: ModelsDevCatalogSnapshot) {
        store.install(snapshot)
    }

    /// Captures the currently installed immutable snapshot (freeze once per turn).
    public static func currentSnapshot() -> ModelsDevCatalogSnapshot {
        store.current()
    }

    // MARK: Verified Official Origin Mapping

    /// Maps ONLY verified official API hosts to their authoritative `models.dev` provider key.
    /// Custom relays and unrecognized hosts ALWAYS return `nil`.
    public static func officialProviderKey(forOrigin rawOrigin: String) -> String? {
        guard let host = hostName(from: rawOrigin) else { return nil }
        switch host {
        case "api.deepseek.com":
            return "deepseek"
        case "api.openai.com":
            return "openai"
        case "api.anthropic.com":
            return "anthropic"
        case "openrouter.ai", "api.openrouter.ai":
            return "openrouter"
        case "dashscope.aliyuncs.com":
            return "alibaba-cn"
        case "dashscope-intl.aliyuncs.com":
            return "alibaba"
        case "api.moonshot.cn":
            return "moonshotai-cn"
        case "api.moonshot.ai", "api.kimi.com":
            return "moonshotai"
        case "open.bigmodel.cn":
            return "zhipuai"
        case "api.z.ai":
            return "zai"
        case "api.minimaxi.com":
            return "minimax-cn"
        case "api.minimax.io":
            return "minimax"
        case "generativelanguage.googleapis.com":
            return "google"
        case "api.x.ai":
            return "xai"
        case "api.siliconflow.cn":
            return "siliconflow-cn"
        case "api.siliconflow.com":
            return "siliconflow"
        case "api.stepfun.com":
            return "stepfun"
        case "aihubmix.com", "api.aihubmix.com":
            return "aihubmix"
        case "api-inference.modelscope.cn":
            return "modelscope"
        default:
            if host.hasPrefix("ark.") && host.hasSuffix(".volces.com") {
                return "volcengine"
            }
            return nil
        }
    }

    public static func hostName(from rawURL: String) -> String? {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        return host
    }

    // MARK: 4-Stage Catalog Matching (Authoritative vs Hints)

    /// Matches `modelID` against `snapshot` across 4 ordered stages:
    /// 1. Exact `(officialProviderKey, modelID)` -> `.authoritative`
    /// 2. Normalized bare model ID majority across providers -> `.bareHint`
    /// 3. Segment-boundary suffix-stripped ID -> `.strippedHint`
    /// 4. Family prefix aggregate -> `.familyHint` (or `.ambiguousUnknown` on conflict)
    public static func matchCatalog(
        modelID: String,
        officialProviderKey: String?,
        in snapshot: ModelsDevCatalogSnapshot
    ) -> CatalogMatchResult {
        let lowerRaw = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowerRaw.isEmpty, !snapshot.entriesByProvider.isEmpty else {
            return CatalogMatchResult(entry: nil, confidence: .ambiguousUnknown, matchedStage: 0, explanation: "目录为空或模型名为空")
        }

        // Stage 1: Exact official provider key + exact model ID (or stripped suffix inside same official provider).
        if let providerKey = officialProviderKey?.lowercased(),
           let providerEntries = snapshot.entriesByProvider[providerKey] {
            if let exact = providerEntries[lowerRaw] {
                return CatalogMatchResult(
                    entry: exact,
                    confidence: .authoritative,
                    matchedStage: 1,
                    explanation: "权威命中官方目录 \(providerKey)/\(exact.rawModelID)"
                )
            }
            // Check canonical bare ID inside the exact official provider (e.g. `deepseek/deepseek-flash`).
            let bare = ModelsDevCatalogSnapshot.canonicalModelID(from: lowerRaw)
            if let bareExact = providerEntries[bare] {
                return CatalogMatchResult(
                    entry: bareExact,
                    confidence: .authoritative,
                    matchedStage: 1,
                    explanation: "权威命中官方目录 \(providerKey)/\(bareExact.rawModelID)"
                )
            }
            // Check segment-stripped aliases within the same official provider.
            for alias in ModelsDevCatalogSnapshot.normalizedAliases(for: lowerRaw) where alias != lowerRaw && alias != bare {
                if let stripped = providerEntries[alias] {
                    return CatalogMatchResult(
                        entry: stripped,
                        confidence: .strippedHint,
                        matchedStage: 3,
                        explanation: "同官方服务去后缀线索命中 \(providerKey)/\(stripped.rawModelID)"
                    )
                }
            }
        }

        // Stage 2: Exact normalized bare model ID across providers (hint only!).
        let bare = ModelsDevCatalogSnapshot.canonicalModelID(from: lowerRaw)
        var bareMatches: [CatalogModelEntry] = []
        for providerEntries in snapshot.entriesByProvider.values {
            if let entry = providerEntries[lowerRaw] {
                bareMatches.append(entry)
            } else if let entry = providerEntries[bare] {
                bareMatches.append(entry)
            } else {
                for entry in providerEntries.values where entry.canonicalModelID == bare {
                    bareMatches.append(entry)
                }
            }
        }
        if !bareMatches.isEmpty {
            if let picked = selectConsensusHint(from: bareMatches) {
                return CatalogMatchResult(
                    entry: picked,
                    confidence: .bareHint,
                    matchedStage: 2,
                    explanation: "跨服务裸名线索命中 \(picked.catalogProviderKey)/\(picked.rawModelID)（仅供参考）"
                )
            }
            return CatalogMatchResult(
                entry: nil,
                confidence: .ambiguousUnknown,
                matchedStage: 2,
                explanation: "多服务对 \(bare) 能力描述冲突，保持未知"
            )
        }

        // Stage 3: Segment-boundary suffix stripping across providers (hint only!).
        let aliases = ModelsDevCatalogSnapshot.normalizedAliases(for: lowerRaw).filter { $0 != lowerRaw && $0 != bare }
        for alias in aliases {
            var aliasMatches: [CatalogModelEntry] = []
            for providerEntries in snapshot.entriesByProvider.values {
                if let entry = providerEntries[alias] {
                    aliasMatches.append(entry)
                } else {
                    for entry in providerEntries.values where entry.canonicalModelID == alias {
                        aliasMatches.append(entry)
                    }
                }
            }
            if !aliasMatches.isEmpty {
                if let picked = selectConsensusHint(from: aliasMatches) {
                    return CatalogMatchResult(
                        entry: picked,
                        confidence: .strippedHint,
                        matchedStage: 3,
                        explanation: "段边界去后缀线索命中 \(picked.catalogProviderKey)/\(picked.rawModelID)（仅供参考）"
                    )
                }
                return CatalogMatchResult(
                    entry: nil,
                    confidence: .ambiguousUnknown,
                    matchedStage: 3,
                    explanation: "去后缀候选 \(alias) 存在歧义，保持未知"
                )
            }
        }

        // Stage 4: Family prefix aggregate (requires >= 2 segments match and unanimous reasoning capability).
        let bareParts = bare.split(separator: "-").map(String.init)
        if bareParts.count >= 2 {
            let familyPrefix = bareParts.prefix(2).joined(separator: "-")
            var familyMatches: [CatalogModelEntry] = []
            for providerEntries in snapshot.entriesByProvider.values {
                for entry in providerEntries.values {
                    if entry.canonicalModelID == familyPrefix || entry.canonicalModelID.hasPrefix(familyPrefix + "-") {
                        familyMatches.append(entry)
                    }
                }
            }
            if !familyMatches.isEmpty {
                let reasoningStates = Set(familyMatches.compactMap(\.reasoning))
                if reasoningStates.count == 1, let picked = selectConsensusHint(from: familyMatches) {
                    return CatalogMatchResult(
                        entry: picked,
                        confidence: .familyHint,
                        matchedStage: 4,
                        explanation: "家族 \(familyPrefix) 聚合线索（仅供参考）"
                    )
                }
                return CatalogMatchResult(
                    entry: nil,
                    confidence: .ambiguousUnknown,
                    matchedStage: 4,
                    explanation: "家族 \(familyPrefix) 存在不同思考能力分支，保持未知"
                )
            }
        }

        return CatalogMatchResult(entry: nil, confidence: .ambiguousUnknown, matchedStage: 0, explanation: "目录未收录该模型")
    }

    private static func selectConsensusHint(from matches: [CatalogModelEntry]) -> CatalogModelEntry? {
        guard !matches.isEmpty else { return nil }
        // Majority vote on `reasoning`; ties are ambiguous and return nil!
        let trueCount = matches.filter { $0.reasoning == true }.count
        let falseCount = matches.filter { $0.reasoning == false }.count
        if trueCount > 0 && falseCount > 0 && trueCount == falseCount {
            return nil
        }
        let targetReasoning: Bool? = trueCount > falseCount ? true : (falseCount > trueCount ? false : nil)
        let pool = matches.filter { $0.reasoning == targetReasoning }
        let sorted = (pool.isEmpty ? matches : pool).sorted { lhs, rhs in
            // Prefer entries with richer metadata and official-looking provider keys.
            let lhsRich = (!lhs.supportedEfforts.isEmpty ? 2 : 0) + (lhs.interleavedField != nil ? 1 : 0)
            let rhsRich = (!rhs.supportedEfforts.isEmpty ? 2 : 0) + (rhs.interleavedField != nil ? 1 : 0)
            if lhsRich != rhsRich { return lhsRich > rhsRich }
            if lhs.contextWindow != rhs.contextWindow { return lhs.contextWindow > rhs.contextWindow }
            return lhs.catalogProviderKey < rhs.catalogProviderKey
        }
        return sorted.first
    }

    // MARK: Confirmed Contract Resolution

    /// Resolves the confirmed endpoint contract for `(origin, protocolKind, route, modelID)`.
    /// Only confirmed official origins or a validated matching `ManualThinkingRule` produce an authoritative contract.
    public static func contract(
        for key: EndpointContractKey,
        style: ThinkingStyle?,
        manualRule: ManualThinkingRule? = nil,
        snapshot: ModelsDevCatalogSnapshot? = nil
    ) -> ConfirmedContract {
        let activeSnapshot = snapshot ?? currentSnapshot()
        let officialKey = officialProviderKey(forOrigin: key.origin)
        let match = matchCatalog(modelID: key.modelID, officialProviderKey: officialKey, in: activeSnapshot)
        let lowerModel = key.modelID.lowercased()
        let bareModel = ModelsDevCatalogSnapshot.canonicalModelID(from: lowerModel)

        // 1. Validated manual rule bound strictly to `(origin, protocolKind, route, modelID)` takes explicit precedence.
        if let manualRule, manualRule.isValid(for: key) {
            var offered: [ThinkingSelection] = [.inheritDefault]
            if manualRule.canDisable { offered.append(.explicitOff) }
            if manualRule.supportedEfforts.isEmpty && !manualRule.canDisable {
                // Manual rule specifies no efforts and cannot disable -> default only.
            } else {
                for effort in canonicalSortEfforts(manualRule.supportedEfforts) {
                    offered.append(.effort(effort))
                }
            }
            let effectiveStyle = manualRule.wireStyle ?? style ?? .effort
            return ConfirmedContract(
                contractKey: key,
                catalogProviderKey: officialKey,
                isConfirmedOfficialOrigin: officialKey != nil,
                isKnownContract: true,
                supportsThinking: manualRule.canDisable || !manualRule.supportedEfforts.isEmpty,
                canExplicitlyDisable: manualRule.canDisable,
                offeredSelections: offered,
                effortAliases: [:],
                mutualExclusionPolicy: nil,
                echoesReasoning: effectiveStyle.echoesReasoning,
                interleavedField: match.entry?.interleavedField,
                ruleGeneration: max(activeSnapshot.generation, manualRule.ruleGeneration),
                matchResult: match
            )
        }

        // 2. Confirmed official origins.
        if let officialKey {
            // 2a. DeepSeek Official Chat Contract (`deepseek-flash`, `deepseek-v4-pro`, retired `deepseek-reasoner` compat).
            if officialKey == "deepseek" && (key.protocolKind == "openai" || key.protocolKind == "openai_responses") {
                let isKnownDeepSeekThinkingModel = (match.entry?.thinks == true)
                    || bareModel == "deepseek-flash"
                    || bareModel == "deepseek-v4-flash"
                    || bareModel == "deepseek-v4-flash-vision-exp"
                    || bareModel == "deepseek-v4-pro"
                    || bareModel == "deepseek-chat"
                    || bareModel == "deepseek-reasoner"
                if isKnownDeepSeekThinkingModel {
                    let efforts = (match.entry?.supportedEfforts.isEmpty == false)
                        ? canonicalSortEfforts(match.entry!.supportedEfforts)
                        : ["low", "high", "max"]
                    let offered: [ThinkingSelection] = [.inheritDefault, .explicitOff] + efforts.map { .effort($0) }
                    return ConfirmedContract(
                        contractKey: key,
                        catalogProviderKey: officialKey,
                        isConfirmedOfficialOrigin: true,
                        isKnownContract: true,
                        supportsThinking: true,
                        canExplicitlyDisable: true,
                        offeredSelections: offered,
                        effortAliases: ["medium": "high", "xhigh": "high"],
                        mutualExclusionPolicy: nil,
                        echoesReasoning: true,
                        interleavedField: match.entry?.interleavedField ?? "reasoning_content",
                        ruleGeneration: activeSnapshot.generation,
                        matchResult: match
                    )
                }
            }

            // 2b. Alibaba Bailian Official Contract (strictly prevents conflicting `reasoning_effort` + `thinking_budget`).
            if officialKey == "alibaba-cn" || officialKey == "alibaba" {
                let entry = match.confidence == .authoritative ? match.entry : nil
                let thinks = entry?.thinks ?? false
                var offered: [ThinkingSelection] = [.inheritDefault]
                let canDisable = entry?.canToggleOff ?? thinks
                if thinks {
                    if canDisable { offered.append(.explicitOff) }
                    if let entry, !entry.supportedEfforts.isEmpty {
                        offered += canonicalSortEfforts(entry.supportedEfforts).map { .effort($0) }
                    } else {
                        offered += [.effort("low"), .effort("medium"), .effort("high")]
                    }
                }
                return ConfirmedContract(
                    contractKey: key,
                    catalogProviderKey: officialKey,
                    isConfirmedOfficialOrigin: true,
                    isKnownContract: true,
                    supportsThinking: thinks,
                    canExplicitlyDisable: thinks && canDisable,
                    offeredSelections: offered,
                    effortAliases: [:],
                    mutualExclusionPolicy: "bailian_no_effort_with_budget",
                    echoesReasoning: true,
                    interleavedField: entry?.interleavedField ?? (thinks ? "reasoning_content" : nil),
                    ruleGeneration: activeSnapshot.generation,
                    matchResult: match
                )
            }

            // 2c. OpenRouter Official Contract (per-model `supported_efforts`).
            if officialKey == "openrouter" {
                if let entry = match.entry, match.confidence == .authoritative {
                    let thinks = entry.thinks
                    var offered: [ThinkingSelection] = [.inheritDefault]
                    let canDisable = thinks && entry.canToggleOff
                    if thinks {
                        if canDisable { offered.append(.explicitOff) }
                        if !entry.supportedEfforts.isEmpty {
                            offered += canonicalSortEfforts(entry.supportedEfforts).map { .effort($0) }
                        } else if entry.reasoningMode == .toggleOnly {
                            offered.append(.explicitOn())
                        }
                    }
                    return ConfirmedContract(
                        contractKey: key,
                        catalogProviderKey: officialKey,
                        isConfirmedOfficialOrigin: true,
                        isKnownContract: true,
                        supportsThinking: thinks,
                        canExplicitlyDisable: canDisable,
                        offeredSelections: offered,
                        effortAliases: [:],
                        mutualExclusionPolicy: nil,
                        echoesReasoning: entry.interleavedField != nil,
                        interleavedField: entry.interleavedField,
                        ruleGeneration: activeSnapshot.generation,
                        matchResult: match
                    )
                }
            }

            // 2d. Anthropic Official Contract.
            if officialKey == "anthropic" || key.protocolKind == "anthropic" {
                if let entry = match.entry, match.confidence == .authoritative {
                    let thinks = entry.thinks
                    var offered: [ThinkingSelection] = [.inheritDefault]
                    let canDisable = thinks && entry.canToggleOff
                    if thinks {
                        if canDisable { offered.append(.explicitOff) }
                        if !entry.supportedEfforts.isEmpty {
                            offered += canonicalSortEfforts(entry.supportedEfforts).map { .effort($0) }
                        } else if entry.budgetMin != nil {
                            offered += [.effort("low"), .effort("medium"), .effort("high"), .effort("max")]
                        } else if entry.canToggleOff {
                            offered.append(.explicitOn())
                        }
                    }
                    return ConfirmedContract(
                        contractKey: key,
                        catalogProviderKey: officialKey,
                        isConfirmedOfficialOrigin: true,
                        isKnownContract: true,
                        supportsThinking: thinks,
                        canExplicitlyDisable: canDisable,
                        offeredSelections: offered,
                        effortAliases: [:],
                        mutualExclusionPolicy: nil,
                        echoesReasoning: true,
                        interleavedField: entry.interleavedField,
                        ruleGeneration: activeSnapshot.generation,
                        matchResult: match
                    )
                }
            }

            // 2e. Other Confirmed Official Providers with Authoritative Catalog Entry (OpenAI, Moonshot, Zhipu, MiniMax, Google, xAI, etc.).
            if let entry = match.entry, match.confidence == .authoritative {
                let thinks = entry.thinks
                var offered: [ThinkingSelection] = [.inheritDefault]
                let styleGuess = style ?? ThinkingStyle.guess(baseURL: key.origin)
                let canDisable: Bool
                if !thinks {
                    canDisable = false
                } else if entry.canToggleOff {
                    canDisable = true
                } else if !entry.supportedEfforts.isEmpty {
                    // Explicit effort list without `toggle` and without `"none"` (e.g. `gpt-5` minimal..high, `gpt-5-pro` high).
                    canDisable = false
                } else {
                    canDisable = styleGuess.canStop && entry.reasoningMode != .forced
                }

                if thinks {
                    if canDisable { offered.append(.explicitOff) }
                    if !entry.supportedEfforts.isEmpty {
                        offered += canonicalSortEfforts(entry.supportedEfforts).map { .effort($0) }
                    } else if entry.reasoningMode == .toggleOnly {
                        offered.append(.explicitOn())
                    } else if entry.reasoningMode != .forced {
                        let legacyLevels = styleGuess.levels(thinks: true).filter { $0 != .auto && $0 != .off }
                        offered += legacyLevels.map { ThinkingSelection.fromLegacy($0) }
                    }
                }
                return ConfirmedContract(
                    contractKey: key,
                    catalogProviderKey: officialKey,
                    isConfirmedOfficialOrigin: true,
                    isKnownContract: true,
                    supportsThinking: thinks,
                    canExplicitlyDisable: canDisable,
                    offeredSelections: offered,
                    effortAliases: [:],
                    mutualExclusionPolicy: nil,
                    echoesReasoning: entry.interleavedField != nil || styleGuess.echoesReasoning,
                    interleavedField: entry.interleavedField,
                    ruleGeneration: activeSnapshot.generation,
                    matchResult: match
                )
            }

            // 2f. Official provider host, but model not yet in snapshot -> fall back to verified official ThinkingStyle contract.
            let officialStyle = style ?? ThinkingStyle.guess(baseURL: key.origin)
            let legacyOffered = officialStyle.levels(thinks: true).map { ThinkingSelection.fromLegacy($0) }
            let canDisable = officialStyle != .none && officialStyle.canStop
            return ConfirmedContract(
                contractKey: key,
                catalogProviderKey: officialKey,
                isConfirmedOfficialOrigin: true,
                isKnownContract: true,
                supportsThinking: legacyOffered.count > 1,
                canExplicitlyDisable: canDisable,
                offeredSelections: legacyOffered,
                effortAliases: officialStyle == .deepseek ? ["medium": "high", "xhigh": "high"] : [:],
                mutualExclusionPolicy: nil,
                echoesReasoning: officialStyle.echoesReasoning,
                interleavedField: match.entry?.interleavedField,
                ruleGeneration: activeSnapshot.generation,
                matchResult: match
            )
        }

        // 3. Unknown / third-party custom relay without a validated manual rule.
        // Catalog match is strictly a hint; we MUST NOT claim verified `canExplicitlyDisable`!
        let hintThinks = match.entry?.thinks ?? false
        let relayStyle = style ?? .effort
        var hintOffered: [ThinkingSelection] = [.inheritDefault]
        if let explicitStyle = style, explicitStyle != .none {
            // User explicitly picked a ThinkingStyle on this relay, still not a verified off-contract unless manual rule exists.
            let efforts = explicitStyle.levels(thinks: true).filter { $0 != .auto && $0 != .off }
            hintOffered += efforts.map { ThinkingSelection.fromLegacy($0) }
        }
        return ConfirmedContract(
            contractKey: key,
            catalogProviderKey: nil,
            isConfirmedOfficialOrigin: false,
            isKnownContract: false,
            supportsThinking: hintThinks || hintOffered.count > 1,
            canExplicitlyDisable: false,
            offeredSelections: hintOffered,
            effortAliases: [:],
            mutualExclusionPolicy: nil,
            echoesReasoning: match.entry?.interleavedField != nil || relayStyle.echoesReasoning,
            interleavedField: match.entry?.interleavedField,
            ruleGeneration: activeSnapshot.generation,
            matchResult: match
        )
    }

    // MARK: Selection Resolution & Wire Compilation

    /// Resolves a user (or internal) `ThinkingSelection` against a frozen `ConfirmedContract`.
    public static func resolve(
        selection: ThinkingSelection,
        contract: ConfirmedContract,
        style: ThinkingStyle? = nil,
        intent: ThinkingCallIntent = .userChat
    ) -> Resolution {
        // Internal low-latency calls (probes, short utilities, nightly organizers):
        // omit questionable thinking fields on forced-thinking or unconfirmed contracts instead of failing.
        if intent == .preferLowLatency {
            if contract.isKnownContract && contract.canExplicitlyDisable {
                let fields = wireFields(for: .explicitOff, contract: contract, style: style)
                return Resolution(
                    contract: contract,
                    requested: selection,
                    intent: intent,
                    fulfillment: .fulfilled(effective: .explicitOff, migratedFrom: nil, note: nil),
                    bodyFields: fields
                )
            }
            let fields = wireFields(for: .inheritDefault, contract: contract, style: style)
            return Resolution(
                contract: contract,
                requested: selection,
                intent: intent,
                fulfillment: .fulfilled(effective: .inheritDefault, migratedFrom: nil, note: nil),
                bodyFields: fields
            )
        }

        // User chat / compression intent.
        switch selection {
        case .inheritDefault:
            return Resolution(
                contract: contract,
                requested: selection,
                intent: intent,
                fulfillment: .fulfilled(effective: .inheritDefault, migratedFrom: nil, note: nil),
                bodyFields: wireFields(for: .inheritDefault, contract: contract, style: style)
            )

        case .explicitOff:
            // Pre-flight zero-request gate: NEVER smuggle `explicitOff` by omitting fields!
            guard contract.isKnownContract && contract.canExplicitlyDisable else {
                let reason = contract.isKnownContract
                    ? "当前模型不支持关闭思考，无法按「不想」发送；已保留你的设定，未发起请求。"
                    : "当前中转站或自定义端点缺少经确认的关闭思考契约，无法保证「不想」生效；已保留你的设定，未发起请求。"
                return Resolution(
                    contract: contract,
                    requested: selection,
                    intent: intent,
                    fulfillment: .unfulfilledExplicitOff(reason: reason),
                    bodyFields: [:]
                )
            }
            return Resolution(
                contract: contract,
                requested: selection,
                intent: intent,
                fulfillment: .fulfilled(effective: .explicitOff, migratedFrom: nil, note: nil),
                bodyFields: wireFields(for: .explicitOff, contract: contract, style: style)
            )

        case .explicitOn:
            if contract.offeredSelections.contains(where: {
                if case .explicitOn = $0 { return true }
                return false
            }) {
                return Resolution(
                    contract: contract,
                    requested: selection,
                    intent: intent,
                    fulfillment: .fulfilled(effective: selection, migratedFrom: nil, note: nil),
                    bodyFields: wireFields(for: selection, contract: contract, style: style)
                )
            }
            return Resolution(
                contract: contract,
                requested: selection,
                intent: intent,
                fulfillment: .unfulfilledSelection(
                    requested: selection,
                    reason: "当前模型不提供纯开关式思考设定，已保留你的原设定，本次按模型默认处理。"
                ),
                bodyFields: wireFields(for: .inheritDefault, contract: contract, style: style)
            )

        case .effort(let rawEffort, let budget):
            let key = rawEffort.lowercased()
            // Exact match on confirmed contract.
            if contract.offeredSelections.contains(where: { $0.effortName == key }) {
                let effective = ThinkingSelection.effort(key, budget: budget)
                return Resolution(
                    contract: contract,
                    requested: selection,
                    intent: intent,
                    fulfillment: .fulfilled(effective: effective, migratedFrom: nil, note: nil),
                    bodyFields: wireFields(for: effective, contract: contract, style: style)
                )
            }
            // Confirmed alias migration (e.g. DeepSeek legacy `.medium` -> `"high"` or `"xhigh"` -> `"high"`).
            if contract.isKnownContract,
               let mapped = contract.effortAliases[key],
               contract.offeredSelections.contains(where: { $0.effortName == mapped }) {
                let effective = ThinkingSelection.effort(mapped, budget: budget)
                return Resolution(
                    contract: contract,
                    requested: selection,
                    intent: intent,
                    fulfillment: .fulfilled(
                        effective: effective,
                        migratedFrom: selection,
                        note: "已按端点契约将「\(selection.title)」映射为「\(effective.title)」。"
                    ),
                    bodyFields: wireFields(for: effective, contract: contract, style: style)
                )
            }
            // Insufficient evidence to coerce: preserve user's saved selection, explain why, and omit suspect fields safely.
            return Resolution(
                contract: contract,
                requested: selection,
                intent: intent,
                fulfillment: .unfulfilledSelection(
                    requested: selection,
                    reason: "当前模型不支持「\(selection.title)」思考档位，已保留你的原设定，本次按模型默认处理。"
                ),
                bodyFields: wireFields(for: .inheritDefault, contract: contract, style: style)
            )

        case .unknown:
            return Resolution(
                contract: contract,
                requested: selection,
                intent: intent,
                fulfillment: .unfulfilledSelection(
                    requested: selection,
                    reason: "已保留来自较新版本的思考设定，当前版本按模型默认处理。"
                ),
                bodyFields: wireFields(for: .inheritDefault, contract: contract, style: style)
            )
        }
    }

    /// Computes the ordered intersection of realizable selections across multiple gathering speakers
    /// (used ONLY when `ChatOptions.model == nil`; conversation-level model override resolves directly).
    public static func intersectOfferings(_ contracts: [ConfirmedContract]) -> [ThinkingSelection] {
        guard let first = contracts.first else { return [.inheritDefault] }
        let rest = contracts.dropFirst()
        var common: [ThinkingSelection] = []
        for candidate in first.offeredSelections {
            let realizableByAll = rest.allSatisfy { contract in
                if case .inheritDefault = candidate { return true }
                if case .explicitOff = candidate {
                    return contract.isKnownContract && contract.canExplicitlyDisable
                }
                if contract.offeredSelections.contains(candidate) { return true }
                if let name = candidate.effortName,
                   contract.isKnownContract,
                   let mapped = contract.effortAliases[name],
                   contract.offeredSelections.contains(where: { $0.effortName == mapped }) {
                    return true
                }
                return false
            }
            if realizableByAll && !common.contains(candidate) {
                common.append(candidate)
            }
        }
        return common.isEmpty ? [.inheritDefault] : common
    }

    // MARK: Wire Field Compilation

    private static func wireFields(
        for selection: ThinkingSelection,
        contract: ConfirmedContract,
        style: ThinkingStyle?
    ) -> [String: ThinkingWireValue] {
        var fields: [String: ThinkingWireValue] = [:]
        let effectiveStyle = style ?? ThinkingStyle.guess(baseURL: contract.contractKey.origin)

        if effectiveStyle == .minimax {
            fields["reasoning_split"] = .bool(true)
        }
        if case .inheritDefault = selection {
            return fields
        }

        // Unknown relay without confirmed contract: never send speculative thinking parameters.
        if !contract.isKnownContract {
            return fields
        }

        // DeepSeek official contract.
        if contract.catalogProviderKey == "deepseek" || effectiveStyle == .deepseek {
            switch selection {
            case .explicitOff:
                fields["thinking"] = .object(["type": .string("disabled")])
            case .explicitOn:
                fields["thinking"] = .object(["type": .string("enabled")])
            case .effort(let value, _):
                fields["thinking"] = .object(["type": .string("enabled")])
                fields["reasoning_effort"] = .string(value)
            default:
                break
            }
            return fields
        }

        // Alibaba Bailian official contract: NEVER send both `reasoning_effort` and `thinking_budget`.
        if contract.mutualExclusionPolicy == "bailian_no_effort_with_budget" {
            switch selection {
            case .explicitOff:
                fields["enable_thinking"] = .bool(false)
            case .explicitOn(let budget):
                fields["enable_thinking"] = .bool(true)
                if let budget { fields["thinking_budget"] = .int(budget) }
            case .effort(let value, let budget):
                fields["enable_thinking"] = .bool(true)
                if let budget {
                    fields["thinking_budget"] = .int(budget)
                } else if let entry = contract.matchResult.entry, !entry.supportedEfforts.isEmpty {
                    // Model explicitly supports effort on Bailian -> send `reasoning_effort` ONLY (no `thinking_budget`).
                    fields["reasoning_effort"] = .string(value)
                } else {
                    let mappedBudget: Int? = switch value {
                    case "minimal", "low": 1024
                    case "medium": 4096
                    case "high", "xhigh": 16384
                    default: nil
                    }
                    if let mappedBudget { fields["thinking_budget"] = .int(mappedBudget) }
                }
            default:
                break
            }
            return fields
        }

        // OpenRouter official contract.
        if contract.catalogProviderKey == "openrouter" || effectiveStyle == .openrouter {
            switch selection {
            case .explicitOff:
                fields["reasoning"] = .object(["enabled": .bool(false)])
            case .explicitOn:
                fields["reasoning"] = .object(["enabled": .bool(true)])
            case .effort(let value, _):
                fields["reasoning"] = .object(["effort": .string(value)])
            default:
                break
            }
            return fields
        }

        // OpenAI / standard effort contract.
        if contract.catalogProviderKey == "openai" || effectiveStyle == .effort || effectiveStyle == .gemini || effectiveStyle == .kimi || effectiveStyle == .grok {
            switch selection {
            case .explicitOff:
                let offToken = contract.matchResult.entry?.explicitOffEffortToken ?? "none"
                fields["reasoning_effort"] = .string(offToken)
            case .effort(let value, _):
                fields["reasoning_effort"] = .string(value)
            default:
                break
            }
            return fields
        }

        // GLM / Doubao / Qwen fallback styles.
        switch effectiveStyle {
        case .glm, .doubao:
            switch selection {
            case .explicitOff:
                fields["thinking"] = .object(["type": .string("disabled")])
            case .explicitOn:
                fields["thinking"] = .object(["type": .string("enabled")])
            case .effort(let value, _):
                fields["thinking"] = .object(["type": .string("enabled")])
                fields["reasoning_effort"] = .string(value)
            default:
                break
            }
        case .qwen:
            switch selection {
            case .explicitOff:
                fields["enable_thinking"] = .bool(false)
            case .explicitOn(let budget):
                fields["enable_thinking"] = .bool(true)
                if let budget { fields["thinking_budget"] = .int(budget) }
            case .effort(let value, let budget):
                fields["enable_thinking"] = .bool(true)
                if let budget {
                    fields["thinking_budget"] = .int(budget)
                } else {
                    let mappedBudget: Int? = switch value {
                    case "minimal", "low": 1024
                    case "medium": 4096
                    case "high", "xhigh": 16384
                    default: nil
                    }
                    if let mappedBudget { fields["thinking_budget"] = .int(mappedBudget) }
                }
            default:
                break
            }
        default:
            break
        }
        return fields
    }

    private static func canonicalSortEfforts(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        let unique = values.map { $0.lowercased() }.filter { !$0.isEmpty && seen.insert($0).inserted }
        return unique.sorted { lhs, rhs in
            let li = ThinkingSelection.effortOrder.firstIndex(of: lhs) ?? Int.max
            let ri = ThinkingSelection.effortOrder.firstIndex(of: rhs) ?? Int.max
            if li != ri { return li < ri }
            return lhs < rhs
        }
    }
}
