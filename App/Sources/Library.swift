import AgentKit
import Craft
import Foundation
import Synchronization
import UIKit

/// A Bot as this phone keeps it.
struct BotInfo: Codable, Identifiable, Equatable, Sendable {
    struct Blocked: Codable, Equatable, Sendable { var code: String? }

    let id: String
    var name: String
    var role: String?
    var color: String?
    var main: Bool?
    /// Who it is and how it talks, in the user's words.
    var instructions: String?
    /// `endpointId/modelId`; nil: the default model.
    var model: String?
    var preview: String?
    /// Milliseconds.
    var lastAt: Double?
    var blocked: Blocked?
    var createdAt: Double?
    /// 性格 (`Temper`): warm / clear / lively / blank; nil is 温.
    var temper: String?
    /// 说话风格 (`SpeechStyle`); nil is 默认.
    var style: String?
    /// The character on its seal; nil is the first character of its name.
    var seal: String?
    /// Its face: nil follows the pet picked in 宠物设置; "pet:<pack id>" one particular pet; "photo" a picture
    /// from the album, kept on this phone (`Avatars`).
    var avatar: String?
}

struct RoomInfo: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    var preview: String?
    var members: [String]?
    var lastAt: Double?
}

/// One message of a chat, as kept on the phone. Photos live in their own files.
struct Entry: Codable, Identifiable, Equatable, Sendable {
    var id: String
    /// Milliseconds.
    var at: Double
    var message: Message
    /// In a group: the Bot that said it.
    var speaker: String?
    /// File names under `media/`.
    var photos: [String] = []
    /// What the user saw while the tool ran: 「搜索：重庆天气」.
    var label: String?
    /// Not for the model: a line for the user only.
    var note: Bool?
    /// On the last reply of a turn: how many tokens the model wrote in that turn.
    var tokens: Int?
    /// On a note about a failure: what to do next (`Explain.Next`).
    var next: String?
    /// On a reply: the companion's 心绪 before it spoke (see `Pulse`).
    var pulse: String?
    /// The line a compression leaves: what is above it the model now reads as the 前情提要; it all stays here to scroll back to.
    var fold: Bool?
    /// Original queued message IDs transferred into this user entry, used to deduplicate on restart if a crash
    /// occurred after the chat saved but before the queued store removed them.
    var queuedIds: [UUID]?
    /// True when this entry introduced or was produced after reading untrusted external content (web, mail, clipboard, MCP).
    var tainted: Bool? = nil
    /// True when this entry is a companion-to-companion delegation prompt rather than user speech.
    var delegated: Bool? = nil
    /// Provenance of the turn (`ExperienceWriteSource.rawValue`), persisted so paused/restarted turns cannot regain write privileges.
    var experienceSource: String? = nil
}

/// A message a Bot set for later; it shows in the chat once its time has come.
struct Later: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var chat: String
    var botId: String
    var text: String
    /// Seconds since 1970.
    var at: Double
}

/// A model service the user added: its address and which models it has. The key is in the Vault.
struct Endpoint: Codable, Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Hashable, Sendable, Codable {
        case openai
        case openaiResponses
        case openaiCodex
        case anthropic
        case unknown(String)

        var rawValue: String {
            switch self {
            case .openai: return "openai"
            case .openaiResponses: return "openai_responses"
            case .openaiCodex: return "openai_codex"
            case .anthropic: return "anthropic"
            case .unknown(let raw): return raw
            }
        }

        init(rawValue: String) {
            switch rawValue {
            case "openai": self = .openai
            case "openai_responses": self = .openaiResponses
            case "openai_codex": self = .openaiCodex
            case "anthropic": self = .anthropic
            default: self = .unknown(rawValue)
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            self = Kind(rawValue: raw)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }

        /// Whether this protocol kind is supported by this Clio build. Unknown kinds decode safely in disabled state.
        var isSupportedProtocol: Bool {
            switch self {
            case .openai, .openaiResponses, .openaiCodex, .anthropic: return true
            case .unknown: return false
            }
        }

        var isAnthropic: Bool {
            switch self {
            case .anthropic: return true
            case .openai, .openaiResponses, .openaiCodex, .unknown: return false
            }
        }

        var isOpenAIFamily: Bool {
            switch self {
            case .openai, .openaiResponses, .openaiCodex: return true
            case .anthropic, .unknown: return false
            }
        }

        var usesResponsesAPI: Bool {
            switch self {
            case .openaiResponses, .openaiCodex: return true
            case .openai, .anthropic, .unknown: return false
            }
        }

        var supportsThinkingStyleSelection: Bool {
            switch self {
            case .openai: return true
            case .openaiResponses, .openaiCodex, .anthropic, .unknown: return false
            }
        }

        var supportsPromptCache: Bool {
            switch self {
            case .anthropic: return true
            case .openai, .openaiResponses, .openaiCodex, .unknown: return false
            }
        }

        var supportsImages: Bool {
            switch self {
            case .openai, .openaiResponses, .openaiCodex: return true
            case .anthropic, .unknown: return false
            }
        }

        var supportsStandardImagesAPI: Bool {
            switch self {
            case .openai, .openaiResponses: return true
            case .openaiCodex, .anthropic, .unknown: return false
            }
        }

        var defaultRoutePath: String {
            switch self {
            case .openai: return "/chat/completions"
            case .openaiResponses, .openaiCodex: return "/responses"
            case .anthropic: return "/v1/messages"
            case .unknown: return ""
            }
        }

        var addressHint: String {
            switch self {
            case .openai: return "一般以 /v1 结尾，比如 https://api.example.com/v1"
            case .openaiResponses: return "一般以 /v1 结尾，将请求 /responses"
            case .openaiCodex: return "Codex Responses 端点地址"
            case .anthropic: return "填到 /v1 前面为止，比如 https://api.example.com"
            case .unknown(let raw): return "未识别的协议类型（\(raw)），已暂停外发"
            }
        }

        var displayTitle: String {
            switch self {
            case .openai: return L.t("servicePage.apiOpenAI")
            case .openaiResponses: return "OpenAI Responses"
            case .openaiCodex: return "OpenAI Codex"
            case .anthropic: return L.t("servicePage.apiAnthropic")
            case .unknown(let raw): return "未知协议（\(raw)）"
            }
        }
    }

    var id: String
    var name: String
    var kind: Kind {
        didSet { if kind != oldValue { bumpIdentityRevision() } }
    }
    var baseURL: String {
        didSet { if baseURL != oldValue { bumpIdentityRevision() } }
    }
    private var storedIdentityRevision: UInt64?
    var identityRevision: UInt64 { storedIdentityRevision ?? 0 }

    private mutating func bumpIdentityRevision() {
        storedIdentityRevision = identityRevision &+ 1
    }
    /// The models in use: the ones offered when picking a model.
    var models: [String]
    /// Everything the service listed last time, in use or not.
    var listed: [String]?
    /// The original service catalog for the image picker, separate from the filtered chat list.
    var imageModels: [String]?
    /// What the user set right about a model; the rest is guessed from its name.
    var overrides: [String: ModelTraits]?
    /// Context windows the service reported in its model list (tokens), by model.
    var windows: [String: Int]?
    /// How to ask it for thinking; nil: as its service does.
    var style: ThinkingStyle? {
        didSet {
            if style != nil { unknownStyleRaw = nil }
        }
    }
    /// Preserves an unrecognized future `ThinkingStyle` raw value from disk/backup so decoding never fails
    /// and the endpoint stays safely disabled until changed.
    var unknownStyleRaw: String?
    /// The listed service it came from (`Service.id`).
    var service: String?
    /// Local Vault slot selected together with the service settings during restore.
    var credentialSlot: UUID?
    /// Whether Anthropic endpoints send `cache_control` breakpoints; nil defaults to on.
    var promptCache: Bool?
    /// Optional user-defined display names for models (`[modelID: customName]`).
    var modelNames: [String: String]?
    /// Optional user-confirmed manual thinking rules keyed by model ID, bound to `(origin, protocol, route, model)`.
    var manualThinkingRules: [String: ManualThinkingRule]?
    var credentialID: String { EndpointKeyCoordinator.credentialID(for: id, slot: credentialSlot) }

    /// True when this endpoint carries an unrecognized `Kind` or `ThinkingStyle` and must remain disabled.
    var isDisabledByUnknownProtocol: Bool {
        !kind.isSupportedProtocol || unknownStyleRaw != nil
    }

    var isActiveProtocol: Bool {
        !isDisabledByUnknownProtocol
    }

    var disabledProtocolReason: String? {
        if case .unknown(let raw) = kind {
            return "「\(name)」使用了当前版本不识别的协议（\(raw)），已禁用并停止发送凭据。"
        }
        if let rawStyle = unknownStyleRaw {
            return "「\(name)」使用了当前版本不识别的思考格式（\(rawStyle)），已禁用并停止发送凭据。"
        }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, baseURL, storedIdentityRevision, models, listed, imageModels
        case overrides, windows, style, service, credentialSlot, promptCache, modelNames
        case manualThinkingRules
    }

    init(
        id: String,
        name: String,
        kind: Kind,
        baseURL: String,
        models: [String],
        service: String? = nil,
        promptCache: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.models = models
        self.service = service
        self.promptCache = promptCache
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(Kind.self, forKey: .kind)
        baseURL = try c.decode(String.self, forKey: .baseURL)
        storedIdentityRevision = try c.decodeIfPresent(UInt64.self, forKey: .storedIdentityRevision)
        models = try c.decode([String].self, forKey: .models)
        listed = try c.decodeIfPresent([String].self, forKey: .listed)
        imageModels = try c.decodeIfPresent([String].self, forKey: .imageModels)
        overrides = try c.decodeIfPresent([String: ModelTraits].self, forKey: .overrides)
        windows = try c.decodeIfPresent([String: Int].self, forKey: .windows)
        if let rawStyle = try c.decodeIfPresent(String.self, forKey: .style) {
            if let known = ThinkingStyle(rawValue: rawStyle) {
                style = known
                unknownStyleRaw = nil
            } else {
                style = nil
                unknownStyleRaw = rawStyle
            }
        } else {
            style = nil
            unknownStyleRaw = nil
        }
        service = try c.decodeIfPresent(String.self, forKey: .service)
        credentialSlot = try c.decodeIfPresent(UUID.self, forKey: .credentialSlot)
        promptCache = try c.decodeIfPresent(Bool.self, forKey: .promptCache)
        modelNames = try c.decodeIfPresent([String: String].self, forKey: .modelNames)
        manualThinkingRules = try c.decodeIfPresent([String: ManualThinkingRule].self, forKey: .manualThinkingRules)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(kind, forKey: .kind)
        try c.encode(baseURL, forKey: .baseURL)
        try c.encodeIfPresent(storedIdentityRevision, forKey: .storedIdentityRevision)
        try c.encode(models, forKey: .models)
        try c.encodeIfPresent(listed, forKey: .listed)
        try c.encodeIfPresent(imageModels, forKey: .imageModels)
        try c.encodeIfPresent(overrides, forKey: .overrides)
        try c.encodeIfPresent(windows, forKey: .windows)
        if let style {
            try c.encode(style.rawValue, forKey: .style)
        } else if let unknownStyleRaw {
            try c.encode(unknownStyleRaw, forKey: .style)
        }
        try c.encodeIfPresent(service, forKey: .service)
        try c.encodeIfPresent(credentialSlot, forKey: .credentialSlot)
        try c.encodeIfPresent(promptCache, forKey: .promptCache)
        try c.encodeIfPresent(modelNames, forKey: .modelNames)
        try c.encodeIfPresent(manualThinkingRules, forKey: .manualThinkingRules)
    }

    /// Official `models.dev` provider key when `baseURL` belongs to a verified official host; nil for custom relays.
    var officialCatalogProviderKey: String? {
        ThinkingRuleResolver.officialProviderKey(forOrigin: baseURL)
    }

    func contractKey(for model: String) -> EndpointContractKey? {
        guard isActiveProtocol, let identity = recipientIdentity else { return nil }
        return EndpointContractKey(
            origin: identity.canonicalOrigin,
            protocolKind: identity.protocolKind,
            route: identity.route,
            modelID: model
        )
    }

    func validatedManualThinkingRule(for model: String) -> ManualThinkingRule? {
        guard let key = contractKey(for: model),
              let rule = manualThinkingRules?[model],
              rule.isValid(for: key) else { return nil }
        return rule
    }

    /// Drops any manual thinking rules whose bound `(origin, protocol, route, model)` no longer matches this endpoint.
    @discardableResult
    mutating func revalidateManualThinkingRules() -> Int {
        guard let existing = manualThinkingRules, !existing.isEmpty else { return 0 }
        var kept: [String: ManualThinkingRule] = [:]
        var removed = 0
        for (model, rule) in existing {
            if let key = contractKey(for: model), rule.isValid(for: key) {
                kept[model] = rule
            } else {
                removed += 1
            }
        }
        manualThinkingRules = kept.isEmpty ? nil : kept
        return removed
    }

    func thinkingContract(for model: String, snapshot: ModelsDevCatalogSnapshot? = nil) -> ThinkingRuleResolver.ConfirmedContract {
        let activeSnapshot = snapshot ?? ModelsDev.currentSnapshot()
        guard let key = contractKey(for: model) else {
            let fallbackKey = EndpointContractKey(
                origin: baseURL,
                protocolKind: kind.rawValue,
                route: kind.defaultRoutePath,
                modelID: model
            )
            return ThinkingRuleResolver.ConfirmedContract(
                contractKey: fallbackKey,
                catalogProviderKey: nil,
                isConfirmedOfficialOrigin: false,
                isKnownContract: false,
                supportsThinking: false,
                canExplicitlyDisable: false,
                offeredSelections: [.inheritDefault],
                effortAliases: [:],
                mutualExclusionPolicy: nil,
                echoesReasoning: false,
                interleavedField: nil,
                ruleGeneration: activeSnapshot.generation,
                matchResult: .init(entry: nil, confidence: .ambiguousUnknown, matchedStage: 0, explanation: disabledProtocolReason ?? "端点未启用")
            )
        }
        let effectiveStyle: ThinkingStyle? = kind.supportsThinkingStyleSelection ? style : nil
        return ThinkingRuleResolver.contract(
            for: key,
            style: effectiveStyle,
            manualRule: validatedManualThinkingRule(for: model),
            snapshot: activeSnapshot
        )
    }

    /// Resolves `model` capabilities against the validated catalog/contract baseline and reports
    /// whether a legacy unattributed override conflicts with a confirmed contract.
    func traitsResolution(
        _ model: String,
        snapshot: ModelsDevCatalogSnapshot? = nil
    ) -> (traits: ModelTraits, baseline: ModelTraits, hasLegacyConflict: Bool) {
        let activeSnapshot = snapshot ?? ModelsDev.currentSnapshot()
        var baseline = ModelTraits.known(model, providerKey: officialCatalogProviderKey, snapshot: activeSnapshot)
        if let reported = windows?[model] { baseline.window = reported }
        let contract = thinkingContract(for: model, snapshot: activeSnapshot)
        let hasConfirmedContract = contract.isKnownContract
            && (contract.matchResult.confidence == .authoritative || contract.supportsThinking)
        if contract.isKnownContract && contract.matchResult.confidence == .authoritative {
            baseline.thinks = contract.supportsThinking
            baseline.thinksSource = .catalog
        }
        if let corrected = overrides?[model] {
            let resolved = corrected.resolvedAgainstCatalog(baseline, hasConfirmedContract: hasConfirmedContract)
            return (resolved.traits, baseline, resolved.hasLegacyConflict)
        }
        return (baseline, baseline, false)
    }

    /// What `model` can do: validated user correction (never silently suppressed by legacy probe or unattributed
    /// overrides against confirmed contracts), else what the service reported and the models.dev catalog say,
    /// else the guess from the name.
    func traits(_ model: String, ignoringCorrection: Bool = false) -> ModelTraits {
        let resolution = traitsResolution(model)
        return ignoringCorrection ? resolution.baseline : resolution.traits
    }

    /// The user changed what this model can do (true), or it is still the guess.
    func corrected(_ model: String) -> Bool { overrides?[model] != nil }

    var thinkingStyle: ThinkingStyle {
        if let style { return style }
        switch kind {
        case .anthropic, .unknown:
            return .none
        case .openai, .openaiResponses, .openaiCodex:
            return Service.of(self)?.style ?? ThinkingStyle.guess(baseURL: baseURL)
        }
    }

    /// Every model it knows of: in use first, then the rest of the list.
    var allModels: [String] {
        guard let listed, !listed.isEmpty else { return models }
        let active = Set(models)
        return models + listed.filter { !active.contains($0) }
    }

    static func looksLikeImageModel(_ model: String) -> Bool {
        let name = model.lowercased()
        return ["image", "dall-e", "flux", "seedream", "imagen"].contains { name.contains($0) }
    }

    /// Strips routing prefixes, date stamps, and noisy suffixes into compact readable model badges.
    static func shortName(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return model }
        var name = trimmed
        if let slash = name.lastIndex(of: "/") {
            let tail = String(name[name.index(after: slash)...])
            if !tail.isEmpty { name = tail }
        }
        for tag in [":free", ":thinking", ":exacto", ":extended"] {
            if name.lowercased().hasSuffix(tag), name.count > tag.count {
                name = String(name.dropLast(tag.count))
            }
        }
        if name.count > 9 {
            let suffix = name.suffix(9)
            if suffix.first == "-", suffix.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber }) {
                let base = String(name.dropLast(9))
                if !base.isEmpty { name = base }
            }
        }
        for suffix in ["-latest", "-preview"] {
            if name.lowercased().hasSuffix(suffix), name.count > suffix.count {
                name = String(name.dropLast(suffix.count))
            }
        }

        let lower = name.lowercased()
        if lower == "deepseek-reasoner" || lower == "deepseek-r1" { return "DeepSeek R1" }
        if lower == "deepseek-chat" || lower == "deepseek-v3" { return "DeepSeek V3" }

        let parts = name.split(separator: "-").map(String.init)
        if parts.first?.lowercased() == "claude", parts.count >= 2 {
            let rest = parts.dropFirst()
            if let familyIdx = rest.firstIndex(where: { ["sonnet", "opus", "haiku"].contains($0.lowercased()) }) {
                let family = rest[familyIdx].capitalized
                let versionParts = rest.indices
                    .filter { $0 != familyIdx }
                    .map { rest[$0] }
                    .filter { $0.allSatisfy { $0.isASCII && $0.isNumber } }
                if !versionParts.isEmpty {
                    return "\(family) \(versionParts.joined(separator: "."))"
                }
                return family
            }
        }
        if parts.first?.lowercased() == "gpt", parts.count >= 2 {
            return "GPT-" + parts.dropFirst().joined(separator: "-")
        }
        if parts.first?.lowercased() == "gemini", parts.count >= 2 {
            return "Gemini " + parts.dropFirst().joined(separator: " ")
        }
        return name
    }

    /// Returns the user's trimmed custom display name for `model`, if one is set.
    func customName(for model: String) -> String? {
        guard let raw = modelNames?[model]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return raw
    }

    /// Returns the user-visible display name for `model`: custom name if set, otherwise shortened ID.
    func displayName(for model: String) -> String {
        customName(for: model) ?? Self.shortName(model)
    }

    /// Returns a display name disambiguated against `peers` (defaulting to `models`) via global fixed-point
    /// settlement so `:free` variants, custom-name swaps, and cascading raw-ID collisions never duplicate labels.
    func distinguishableDisplayName(for model: String, among peers: [String]? = nil) -> String {
        let pool = peers ?? models
        var uniquePeers: [String] = []
        var seen: Set<String> = []
        for peer in pool where seen.insert(peer).inserted {
            uniquePeers.append(peer)
        }
        if seen.insert(model).inserted {
            uniquePeers.append(model)
        }

        let baseByPeer = Dictionary(uniqueKeysWithValues: uniquePeers.map { ($0, displayName(for: $0)) })
        var labels = baseByPeer

        for _ in 0..<(uniquePeers.count * 2 + 2) {
            var counts: [String: Int] = [:]
            for peer in uniquePeers {
                counts[labels[peer] ?? peer, default: 0] += 1
            }
            var changed = false
            for peer in uniquePeers {
                let current = labels[peer] ?? peer
                guard (counts[current] ?? 0) > 1 else { continue }
                let base = baseByPeer[peer] ?? peer
                let tagged = base != peer ? "\(base) (\(peer))" : peer
                let next = current != peer ? peer : tagged
                if next != current {
                    labels[peer] = next
                    changed = true
                }
            }
            if !changed { break }
        }

        return labels[model] ?? displayName(for: model)
    }

    var usesPromptCache: Bool { promptCache ?? AnthropicProvider.caches(baseURL) }

    func provider(key: String, stableSystemPrefix: String? = nil) -> ModelProvider {
        if let disabledReason = disabledProtocolReason {
            return DisabledProtocolProvider(reason: disabledReason)
        }
        switch kind {
        case .openai, .openaiResponses, .openaiCodex:
            return OpenAIProvider(baseURL: baseURL, apiKey: key, style: thinkingStyle, fixedRoute: true)
        case .anthropic:
            return AnthropicProvider(
                baseURL: baseURL,
                apiKey: key,
                promptCache: usesPromptCache,
                stableSystemPrefix: stableSystemPrefix,
                fixedRoute: true
            )
        case .unknown(let raw):
            return DisabledProtocolProvider(reason: "「\(name)」使用了当前版本不识别的协议（\(raw)），已禁用并停止发送凭据。")
        }
    }
}

struct TeamSettings: Codable, Equatable, Sendable {
    var endpoints: [Endpoint] = []
    /// `endpointId/modelId`.
    var defaultModel: String?
    /// Legacy single backup model ref (`endpointId/modelId`) kept for JSON compatibility.
    var backupModel: String?
    /// Ordered multi-level backup chain (`endpointId/modelId`).
    /// `nil` = not explicitly configured yet (falls back to `[backupModel]` if present);
    /// `[]` = explicitly cleared by user (never falls back to legacy `backupModel`).
    var backupModels: [String]?
    /// Optional OpenAI-compatible images model, using the existing endpoint/model reference.
    var imageModel: String?
    var memoryModel: String?
    var visionModel: String?
    private var outboundConsents: Set<OutboundConsent>?
    private var outboundRevision: UInt64?
    var mainBotId: String?

    var outboundConsentGeneration: UInt64 { outboundRevision ?? 0 }

    /// Effective ordered backup model references respecting the distinction between `nil` (fallback to legacy
    /// `backupModel`) and explicit empty `[]` (backups explicitly disabled).
    var effectiveBackupModels: [String] {
        if let backupModels {
            return backupModels.filter { !$0.isEmpty }
        }
        if let backupModel, !backupModel.isEmpty {
            return [backupModel]
        }
        return []
    }

    mutating func setBackupModelsList(_ refs: [String]?) {
        guard let refs else {
            backupModels = []
            backupModel = nil
            return
        }
        var seen: Set<String> = []
        let cleaned = refs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        backupModels = cleaned
        backupModel = cleaned.first
    }

    mutating func pruneBackupModels(removing shouldRemove: (String) -> Bool) {
        if let legacy = backupModel, shouldRemove(legacy) {
            backupModel = nil
        }
        if var list = backupModels {
            list.removeAll(where: shouldRemove)
            backupModels = list
            backupModel = list.first
        }
    }

    mutating func rewriteBackupModels(_ transform: (String) -> String) {
        if let legacy = backupModel {
            backupModel = transform(legacy)
        }
        if let list = backupModels {
            let rewritten = list.map(transform)
            backupModels = rewritten
            backupModel = rewritten.first
        }
    }

    func allowsOutbound(_ recipient: RecipientIdentity, _ category: OutboundDataCategory) -> Bool {
        guard endpoints.contains(where: { $0.recipientIdentity == recipient }) else { return false }
        return outboundConsents?.contains(OutboundConsent(recipient: recipient, category: category)) == true
    }

    mutating func setOutboundConsent(_ allowed: Bool, for recipient: RecipientIdentity, category: OutboundDataCategory) {
        guard endpoints.contains(where: { $0.recipientIdentity == recipient }) else { return }
        var records = outboundConsents ?? []
        let record = OutboundConsent(recipient: recipient, category: category)
        let changed = allowed ? records.insert(record).inserted : records.remove(record) != nil
        guard changed else { return }
        outboundConsents = records
        outboundRevision = outboundConsentGeneration &+ 1
    }

    mutating func pruneOutboundConsents() {
        guard let records = outboundConsents else { return }
        let active = Set(endpoints.compactMap(\.recipientIdentity))
        let kept = records.filter { active.contains($0.recipient) }
        guard kept != records else { return }
        outboundConsents = kept
        outboundRevision = outboundConsentGeneration &+ 1
    }

    mutating func clearOutboundConsents() {
        guard outboundConsents?.isEmpty == false else { return }
        outboundConsents = nil
        outboundRevision = outboundConsentGeneration &+ 1
    }
}

private struct OutboundConsent: Codable, Hashable, Sendable {
    let recipient: RecipientIdentity
    let category: OutboundDataCategory
}

/// Everything the app keeps, as small JSON files in Application Support.
enum Disk {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Team", isDirectory: true)
        for folder in ["", "chats", "media", "diary"] {
            try? FileManager.default.createDirectory(at: base.appendingPathComponent(folder, isDirectory: true), withIntermediateDirectories: true)
        }
        return base
    }()

    static func url(_ name: String) -> URL { root.appendingPathComponent(name) }

    static func load<Value: Decodable>(_ type: Value.Type, _ name: String) -> Value? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save<Value: Encodable>(_ value: Value, _ name: String) {
        do { try write(value, name) } catch {
            // Settings, companions and memory are kept in memory and saved again on the next change; say it failed.
            if !frozen { Diag.note("没存进手机：\(name)（\(error.localizedDescription)）") }
        }
    }

    static func write<Value: Encodable>(_ value: Value, _ name: String) throws {
        guard !frozen else { throw TeamError(message: "刚恢复了备份，重新打开 Clio 后才能保存。") }
        let data = try JSONEncoder().encode(value)
        try data.write(to: url(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func remove(_ name: String) {
        guard !frozen else { return }
        try? FileManager.default.removeItem(at: url(name))
    }

    /// Set once a backup has been put back: what is in memory is the old state, and writing it out would undo the
    /// restore. Until Clio is opened again nothing is written.
    static var frozen: Bool {
        get { frozenFlag.withLock { $0 } }
        set { frozenFlag.withLock { $0 = newValue } }
    }
    private static let frozenFlag = Mutex(false)

    /// A conversation's messages. A file that cannot be read as a whole is never taken for an empty conversation:
    /// that would let the next message overwrite it. It is copied aside first (…broken-<time>.json, kept out of the
    /// way), and every message that can still be read is kept.
    static func loadChat(_ key: String) -> [Entry] {
        let name = chatFile(key)
        guard let data = try? Data(contentsOf: url(name)) else { return [] }
        if let entries = try? JSONDecoder().decode([Entry].self, from: data) { return entries }
        let aside = name.replacingOccurrences(of: ".json", with: ".broken-\(Int(Date().timeIntervalSince1970)).json")
        if !frozen { try? data.write(to: url(aside), options: .atomic) }
        let readable = ((try? JSONDecoder().decode([Lenient].self, from: data)) ?? []).compactMap(\.entry)
        DispatchQueue.main.async {
            Diag.note("对话文件 \(name) 有坏的地方：读出了 \(readable.count) 条，原文件另存为 \(aside)")
        }
        return readable
    }

    private struct Lenient: Decodable {
        let entry: Entry?
        init(from decoder: Decoder) throws { entry = try? Entry(from: decoder) }
    }

    static func chatFile(_ key: String) -> String {
        "chats/\(key.replacingOccurrences(of: "/", with: "_")).json"
    }

    /// Keeps a photo and returns its file name.
    static func keepPhoto(_ data: Data) -> String {
        let name = UUID().uuidString + ".jpg"
        try? data.write(to: url("media/\(name)"), options: .atomic)
        return name
    }

    /// Writes a photo atomically and throws on failure so callers transferring queued photos can abort before deleting the source.
    static func writePhoto(_ data: Data) throws -> String {
        guard !frozen else { throw TeamError(message: "刚恢复了备份，重新打开 Clio 后才能保存。") }
        let name = UUID().uuidString + ".jpg"
        try data.write(to: url("media/\(name)"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return name
    }

    static func photo(_ name: String) -> Data? {
        try? Data(contentsOf: url("media/\(name)"))
    }

    /// A picture as a service will take it: JPEG or PNG as stored, anything else (HEIC, WebP…) drawn again as JPEG,
    /// nil when it cannot be read at all. What was learned is remembered per picture, so a chat does not decode them
    /// on every send — but only a little (the review, #11): a JPEG or PNG is remembered as 「send as stored」 and read
    /// from disk again; only redrawn pictures are kept, up to a byte limit, oldest first out; failures are not kept.
    static func sendablePhoto(_ name: String) -> Data? {
        _ = memoryWatch
        switch photoCache.withLock({ $0.look(name) }) {
        case .asStored: return photo(name)
        case .redrawn(let data): return data
        case nil: break
        }
        let stored = photo(name)
        guard let result = makeSendable(stored) else { return nil }
        photoCache.withLock { $0.keep(name, result == stored ? .asStored : .redrawn(result)) }
        return result
    }

    /// Forgets what was learned about pictures (memory is short, a backup was restored).
    static func forgetPhotos() { photoCache.withLock { $0 = PhotoCache() } }

    private enum Ready { case asStored, redrawn(Data) }

    private struct PhotoCache {
        static let limit = 24 * 1024 * 1024
        var known: [String: Ready] = [:]
        var order: [String] = []
        var bytes = 0

        mutating func look(_ name: String) -> Ready? { known[name] }

        mutating func keep(_ name: String, _ value: Ready) {
            if known[name] != nil { return }
            known[name] = value
            order.append(name)
            if case .redrawn(let data) = value { bytes += data.count }
            while bytes > Self.limit || order.count > 2000, let oldest = order.first {
                order.removeFirst()
                if case .redrawn(let data)? = known.removeValue(forKey: oldest) { bytes -= data.count }
            }
        }
    }

    private static let photoCache = Mutex(PhotoCache())
    private static let memoryWatch: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil
    ) { _ in Disk.forgetPhotos() }

    private static func makeSendable(_ data: Data?) -> Data? {
        guard let data, data.count > 32 else { return nil }
        let head = [UInt8](data.prefix(8))
        let jpeg = head.starts(with: [0xFF, 0xD8, 0xFF])
        let png = head.starts(with: [0x89, 0x50, 0x4E, 0x47])
        guard let image = UIImage(data: data) else { return nil }
        if jpeg || png { return data }
        return image.jpegData(compressionQuality: 0.85)
    }
}

enum Now {
    static var ms: Double { Date().timeIntervalSince1970 * 1000 }
}
