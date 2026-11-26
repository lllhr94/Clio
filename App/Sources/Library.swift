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
    enum Kind: String, Codable, Sendable { case openai, anthropic }

    var id: String
    var name: String
    var kind: Kind
    var baseURL: String
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
    var style: ThinkingStyle?
    /// The listed service it came from (`Service.id`).
    var service: String?
    /// Local Vault slot selected together with the service settings during restore.
    var credentialSlot: UUID?
    /// Whether Anthropic endpoints send `cache_control` breakpoints; nil defaults to on.
    var promptCache: Bool?
    /// Optional user-defined display names for models (`[modelID: customName]`).
    var modelNames: [String: String]?
    var credentialID: String { EndpointKeyCoordinator.credentialID(for: id, slot: credentialSlot) }

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

    /// What a model can do: as the user set it, or else as its name suggests.
    /// What `model` can do: the user's correction, else what the service reported and the models.dev catalog
    /// say, else the guess from the name.
    func traits(_ model: String, ignoringCorrection: Bool = false) -> ModelTraits {
        if !ignoringCorrection, let corrected = overrides?[model] { return corrected }
        var guessed = ModelTraits.known(model)
        // What the service itself said about the window beats a guess from the name.
        if let reported = windows?[model] { guessed.window = reported }
        return guessed
    }

    /// The user changed what this model can do (true), or it is still the guess.
    func corrected(_ model: String) -> Bool { overrides?[model] != nil }

    var thinkingStyle: ThinkingStyle {
        if let style { return style }
        if kind == .anthropic { return .none }
        return Service.of(self)?.style ?? ThinkingStyle.guess(baseURL: baseURL)
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
        switch kind {
        case .openai: return OpenAIProvider(baseURL: baseURL, apiKey: key, style: thinkingStyle)
        case .anthropic:
            return AnthropicProvider(
                baseURL: baseURL,
                apiKey: key,
                promptCache: usesPromptCache,
                stableSystemPrefix: stableSystemPrefix
            )
        }
    }
}

struct TeamSettings: Codable, Equatable, Sendable {
    var endpoints: [Endpoint] = []
    /// `endpointId/modelId`.
    var defaultModel: String?
    /// Tried once when the chosen model fails before a turn is done. `endpointId/modelId`.
    var backupModel: String?
    /// Optional OpenAI-compatible images model, using the existing endpoint/model reference.
    var imageModel: String?
    var memoryModel: String?
    var mainBotId: String?
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
