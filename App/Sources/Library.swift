import AgentKit
import Craft
import Foundation

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

    init(id: String, name: String, kind: Kind, baseURL: String, models: [String], service: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.models = models
        self.service = service
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
    var allModels: [String] { models + (listed ?? []).filter { !models.contains($0) } }

    static func looksLikeImageModel(_ model: String) -> Bool {
        let name = model.lowercased()
        return ["image", "dall-e", "flux", "seedream", "imagen"].contains { name.contains($0) }
    }

    func provider(key: String) -> ModelProvider {
        switch kind {
        case .openai: return OpenAIProvider(baseURL: baseURL, apiKey: key, style: thinkingStyle)
        case .anthropic: return AnthropicProvider(baseURL: baseURL, apiKey: key)
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
        try? write(value, name)
    }

    static func write<Value: Encodable>(_ value: Value, _ name: String) throws {
        let data = try JSONEncoder().encode(value)
        try data.write(to: url(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func remove(_ name: String) {
        try? FileManager.default.removeItem(at: url(name))
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

    static func photo(_ name: String) -> Data? {
        try? Data(contentsOf: url("media/\(name)"))
    }
}

enum Now {
    static var ms: Double { Date().timeIntervalSince1970 * 1000 }
}
