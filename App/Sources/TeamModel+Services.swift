import AgentKit
import Craft
import SwiftUI
import UserNotifications
import UIKit

extension TeamModel {
    // MARK: Model services

    func apiKey(for endpoint: String) -> String? { Vault.load(String.self, key: "key-\(endpoint)") }

    func addEndpoint(_ endpoint: Endpoint, key: String) {
        settings.endpoints.removeAll { $0.id == endpoint.id }
        settings.endpoints.append(endpoint)
        Vault.save(key, as: "key-\(endpoint.id)")
        if resolve(settings.defaultModel) == nil, let pick = Self.preferred(endpoint) {
            settings.defaultModel = "\(endpoint.id)/\(pick)"
        }
        saveSettings()
        if phase == .setup { phase = .ready }
        ensureMainBot()
    }

    func removeEndpoint(_ id: String) {
        settings.endpoints.removeAll { $0.id == id }
        Vault.remove("key-\(id)")
        if settings.backupModel?.hasPrefix(id + "/") == true { settings.backupModel = nil }
        if settings.imageModel?.hasPrefix(id + "/") == true { settings.imageModel = nil }
        if settings.memoryModel?.hasPrefix(id + "/") == true { settings.memoryModel = nil }
        if resolve(settings.defaultModel) == nil {
            settings.defaultModel = settings.endpoints.first.flatMap { endpoint in Self.preferred(endpoint).map { "\(endpoint.id)/\($0)" } }
        }
        saveSettings()
    }

    /// Asks a service for its models again. Returns how many it listed. Models in use stay in use.
    @discardableResult
    func refreshModels(_ id: String) async throws -> Int {
        guard let index = settings.endpoints.firstIndex(where: { $0.id == id }) else { return 0 }
        let endpoint = settings.endpoints[index]
        guard let key = await Vault.readString("key-\(id)"), !key.isEmpty else { throw TeamError(message: "\(endpoint.name) 还没有密钥。") }
        let provider = endpoint.provider(key: key)
        var reported: [String: Int] = [:]
        let raw: [String]
        if let openAI = provider as? OpenAIProvider {
            let catalog = try await openAI.catalog()
            raw = catalog.ids
            reported = catalog.windows
        } else {
            raw = try await provider.models()
        }
        let listed = Self.keep(raw, for: endpoint)
        storeImageModels(raw, for: endpoint)
        guard !listed.isEmpty else { throw TeamError(message: "\(endpoint.name) 没给出模型列表，原来的先留着。") }
        guard let again = settings.endpoints.firstIndex(where: { $0.id == id }) else { return listed.count }
        settings.endpoints[again].listed = listed
        settings.endpoints[again].windows = reported.isEmpty ? nil : reported
        if settings.endpoints[again].models.isEmpty { settings.endpoints[again].models = Self.firstPicks(listed, service: Service.of(endpoint)) }
        saveSettings()
        return listed.count
    }

    /// Refreshes a service's images candidates without changing its chat model selection.
    func refreshImageModels(_ id: String) async throws {
        guard let endpoint = settings.endpoints.first(where: { $0.id == id && $0.kind == .openai }),
              let key = await Vault.readString("key-\(id)"), !key.isEmpty else {
            throw TeamError(message: L.t("errors.invalidApiKey"))
        }
        let listed = try await endpoint.provider(key: key).models()
        try Task.checkCancellation()
        storeImageModels(listed, for: endpoint)
    }

    func storeImageModels(_ listed: [String], for endpoint: Endpoint) {
        guard endpoint.kind == .openai,
              let index = settings.endpoints.firstIndex(where: { $0.id == endpoint.id && $0.baseURL == endpoint.baseURL }) else { return }
        settings.endpoints[index].imageModels = listed
        saveSettings()
    }

    /// The chat models of what a service listed.
    static func keep(_ listed: [String], for endpoint: Endpoint) -> [String] {
        if let service = Service.of(endpoint) { return service.keep(listed) }
        var models = listed.filter(ModelTraits.isChat)
        if endpoint.kind == .anthropic { models = models.filter { $0.hasPrefix("claude") } }
        return models
    }

    /// Which models of a fresh list go into use: all of a short list; of a long one, the service's suggestions, or a few.
    static func firstPicks(_ listed: [String], service: Service?) -> [String] {
        if listed.count <= 12 { return listed }
        let suggested = (service?.suggested ?? []).filter(listed.contains)
        if !suggested.isEmpty { return suggested }
        return Array(listed.prefix(3))
    }

    /// Puts models into use or out of it.
    func setModels(_ id: String, _ models: [String]) {
        guard let index = settings.endpoints.firstIndex(where: { $0.id == id }) else { return }
        settings.endpoints[index].models = models
        if resolve(settings.defaultModel) == nil, let pick = Self.preferred(settings.endpoints[index]) {
            settings.defaultModel = "\(id)/\(pick)"
        }
        saveSettings()
    }

    /// Sets right what a model can do; nil goes back to the guess.
    func setTraits(_ id: String, model: String, _ traits: ModelTraits?) {
        guard let index = settings.endpoints.firstIndex(where: { $0.id == id }) else { return }
        var book = settings.endpoints[index].overrides ?? [:]
        book[model] = traits
        settings.endpoints[index].overrides = book.isEmpty ? nil : book
        saveSettings()
    }

    /// Changes a service's name, address or thinking style.
    func editEndpoint(_ id: String, name: String, baseURL: String, style: ThinkingStyle?) {
        guard let index = settings.endpoints.firstIndex(where: { $0.id == id }) else { return }
        let given = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !given.isEmpty { settings.endpoints[index].name = given }
        let address = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if address.hasPrefix("http") { settings.endpoints[index].baseURL = address }
        settings.endpoints[index].style = style
        saveSettings()
    }

    /// Brings settings kept by an older Clio up to date. True when something changed.
    static func settle(_ settings: inout TeamSettings) -> Bool {
        var changed = false
        for index in settings.endpoints.indices {
            var endpoint = settings.endpoints[index]
            if endpoint.service == nil, let service = Service.of(endpoint) {
                endpoint.service = service.id
                changed = true
            }
            // V4.1 Flash came out after DeepSeek was first set up here, and it is the one that sees.
            if endpoint.service == "deepseek", !endpoint.allModels.contains("deepseek-flash") {
                endpoint.models.insert("deepseek-flash", at: 0)
                changed = true
            }
            settings.endpoints[index] = endpoint
        }
        return changed
    }

    func replaceKey(_ id: String, _ key: String) {
        Vault.save(key, as: "key-\(id)")
        objectWillChange.send()
    }

    func editMemory(_ id: String, _ text: String) {
        guard let index = memories.firstIndex(where: { $0.id == id }) else { return }
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if words.isEmpty {
            deleteMemory(id)
            return
        } else {
            memories[index].text = words
            memories[index].editedByUser = true
        }
        saveMemory()
    }

    func setDefaultModel(_ ref: String) {
        settings.defaultModel = ref
        saveSettings()
    }

    func setBackupModel(_ ref: String?) {
        settings.backupModel = ref
        saveSettings()
    }

    func setMemoryModel(_ ref: String?) {
        settings.memoryModel = ref
        saveSettings()
    }

    var imageModelSelection: (endpoint: Endpoint, model: String)? {
        guard let selected = resolve(settings.imageModel), selected.endpoint.kind == .openai else { return nil }
        return selected
    }

    func setImageModel(_ ref: String?) {
        if let ref {
            guard let selected = resolve(ref), selected.endpoint.kind == .openai else { return }
        }
        settings.imageModel = ref
        saveSettings()
    }

    static func preferred(_ endpoint: Endpoint) -> String? {
        endpoint.models.first { $0 == "deepseek-flash" }
            ?? endpoint.models.first { $0 == "deepseek-v4-flash" }
            ?? endpoint.models.first { $0 == "deepseek-chat" }
            ?? endpoint.models.first { $0.contains("sonnet") }
            ?? endpoint.models.first
    }

    /// The service and model a ref names; nil when it names none that is set up.
    func resolve(_ ref: String?) -> (endpoint: Endpoint, model: String)? {
        guard let ref, let slash = ref.firstIndex(of: "/") else { return nil }
        let id = String(ref[..<slash])
        let model = String(ref[ref.index(after: slash)...])
        guard let endpoint = settings.endpoints.first(where: { $0.id == id }), !model.isEmpty else { return nil }
        return (endpoint, model)
    }

    func modelTitle(_ ref: String?) -> String {
        guard let found = resolve(ref) else { return "没有设置" }
        return "\(found.model) · \(found.endpoint.name)"
    }

    /// Just the model, without a relay's routing prefix ("auto/deepseek-v4.1-flash" reads as "deepseek-v4.1-flash"),
    /// for places too narrow for the whole name.
    func modelShort(_ ref: String?) -> String {
        guard let found = resolve(ref) else { return "没有设置" }
        return found.model.split(separator: "/").last.map(String.init) ?? found.model
    }
}
