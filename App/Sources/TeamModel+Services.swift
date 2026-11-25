import AgentKit
import Craft
import SwiftUI
import UserNotifications
import UIKit

extension TeamModel {
    // MARK: Model services

    private nonisolated static func writeAndVerifyData(_ slot: String, _ data: Data) -> Bool {
        Vault.save(data, as: slot)
        return Vault.load(Data.self, key: slot) == data
    }

    private nonisolated static func writeAndVerifyBool(_ slot: String, _ value: Bool) -> Bool {
        Vault.save(value, as: slot)
        return Vault.load(Bool.self, key: slot) == value
    }

    private nonisolated static func writeAndVerifyString(_ slot: String, _ value: String) -> Bool {
        Vault.save(value, as: slot)
        return Vault.load(String.self, key: slot) == value
    }

    nonisolated static func resolveEndpointKey(for endpoint: Endpoint) -> String? {
        EndpointKeyCoordinator.resolveBoundKey(
            endpointID: endpoint.credentialID,
            requestURL: endpoint.baseURL,
            readBoundRecord: { Vault.load(Data.self, key: $0) },
            hasBoundMarker: { Vault.load(Bool.self, key: $0) == true },
            readLegacyKey: { Vault.load(String.self, key: $0) }
        )
    }

    nonisolated static func exportBackupKeys(endpoints: [Endpoint], allowedIDs: [String]) -> [String: String] {
        let snapshots = endpoints.map { Self.credentialSnapshot($0) }
        return EndpointKeyCoordinator.exportBackupKeys(
            endpoints: snapshots,
            allowedIDs: Set(allowedIDs),
            readBoundRecord: { Vault.load(Data.self, key: $0) },
            hasBoundMarker: { Vault.load(Bool.self, key: $0) == true },
            readLegacyKey: { Vault.load(String.self, key: $0) }
        )
    }

    private nonisolated static func credentialSnapshot(_ endpoint: Endpoint) -> EndpointKeyCoordinator.EndpointSnapshot {
        .init(id: endpoint.id, baseURL: endpoint.baseURL, credentialSlot: endpoint.credentialSlot)
    }

    nonisolated static func prepareBackupServices(previous: [Endpoint], restored: [Endpoint], keys: [String: String]?) throws -> [Endpoint] {
        let prepared = try EndpointKeyCoordinator.prepareBackupRestore(
            previousEndpoints: previous.map(Self.credentialSnapshot),
            restoredEndpoints: restored.map(Self.credentialSnapshot),
            restoredKeys: keys,
            stage: { snapshot, key in
                if let key, let origin = EndpointAddressPolicy.rawOrigin(snapshot.baseURL) {
                    return EndpointKeyCoordinator.saveBoundCredential(
                        endpointID: snapshot.credentialID,
                        origin: origin,
                        key: key,
                        writeBoundRecord: Self.writeAndVerifyData,
                        writeBoundMarker: { Self.writeAndVerifyBool($0, true) },
                        writeLegacyKey: Self.writeAndVerifyString,
                        removeKey: { Vault.remove($0) }
                    )
                }
                return Self.writeAndVerifyBool(EndpointKeyCoordinator.boundMarkerSlot(for: snapshot.credentialID), true)
            },
            discard: Self.discardCredential
        )
        return zip(restored, prepared).map { endpoint, snapshot in
            var updated = endpoint
            updated.credentialSlot = snapshot.credentialSlot
            return updated
        }
    }

    private nonisolated static func discardCredential(_ snapshot: EndpointKeyCoordinator.EndpointSnapshot) {
        EndpointKeyCoordinator.cleanupCredentials(
            endpointID: snapshot.credentialID,
            origin: EndpointAddressPolicy.rawOrigin(snapshot.baseURL),
            readLegacyKey: { Vault.load(String.self, key: $0) },
            removeKey: { Vault.remove($0) }
        )
    }

    nonisolated static func discardCredentials(from discarded: [Endpoint], keeping active: [Endpoint]) {
        let activeSlots = Set(active.map(\.credentialID))
        for endpoint in discarded where !activeSlots.contains(endpoint.credentialID) {
            discardCredential(credentialSnapshot(endpoint))
        }
    }

    func apiKey(for endpoint: Endpoint) -> String? {
        Self.resolveEndpointKey(for: endpoint)
    }

    func apiKey(for endpointID: String) -> String? {
        guard let found = settings.endpoints.first(where: { $0.id == endpointID }) else {
            return nil
        }
        return apiKey(for: found)
    }

    func readAPIKey(for endpoint: Endpoint) async -> String? {
        await Task.detached(priority: .userInitiated) {
            Self.resolveEndpointKey(for: endpoint)
        }.value
    }

    func readAPIKey(for endpointID: String) async -> String? {
        guard let found = settings.endpoints.first(where: { $0.id == endpointID }) else { return nil }
        return await readAPIKey(for: found)
    }

    private nonisolated static let endpointEditQueue = DispatchQueue(label: "clio.endpoint-edit", qos: .userInitiated)

    private nonisolated static func saveCredential(for endpoint: Endpoint, key: String) {
        if let origin = EndpointAddressPolicy.rawOrigin(endpoint.baseURL) {
            _ = EndpointKeyCoordinator.saveBoundCredential(
                endpointID: endpoint.credentialID,
                origin: origin,
                key: key,
                writeBoundRecord: Self.writeAndVerifyData,
                writeBoundMarker: { Self.writeAndVerifyBool($0, true) },
                writeLegacyKey: Self.writeAndVerifyString,
                removeKey: { Vault.remove($0) }
            )
        } else {
            Vault.save(key, as: EndpointKeyCoordinator.legacyKeySlot(for: endpoint.credentialID))
        }
    }

    func addEndpoint(_ endpoint: Endpoint, key: String) {
        Self.saveCredential(for: endpoint, key: key)
        applyAddedEndpoint(endpoint)
    }

    func addEndpointAsync(_ endpoint: Endpoint, key: String) async {
        await EndpointMutationGate.run(on: self) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                Self.endpointEditQueue.async {
                    Self.saveCredential(for: endpoint, key: key)
                    continuation.resume()
                }
            }
            self.applyAddedEndpoint(endpoint)
        }
    }

    private func applyAddedEndpoint(_ endpoint: Endpoint) {
        settings.endpoints.removeAll { $0.id == endpoint.id }
        settings.endpoints.append(endpoint)
        if resolveActive(settings.defaultModel) == nil, let pick = Self.preferred(endpoint) {
            settings.defaultModel = "\(endpoint.id)/\(pick)"
        }
        saveSettings()
        if phase == .setup { phase = .ready }
        ensureMainBot()
    }

    func removeEndpoint(_ id: String) {
        let removed = settings.endpoints.filter { $0.id == id }
        let remaining = settings.endpoints.filter { $0.id != id }
        Self.discardCredentials(from: removed, keeping: remaining)
        applyRemovedEndpoint(id)
    }

    @discardableResult
    func removeEndpointAsync(_ id: String) async -> Bool {
        await EndpointMutationGate.run(on: self) {
            guard let index = self.settings.endpoints.firstIndex(where: { $0.id == id }) else { return true }
            let removed = [self.settings.endpoints[index]]
            let snapshot = self.settings
            var candidate = snapshot
            candidate.endpoints.remove(at: index)
            let prefix = id + "/"
            if candidate.backupModel?.hasPrefix(prefix) == true { candidate.backupModel = nil }
            if candidate.imageModel?.hasPrefix(prefix) == true { candidate.imageModel = nil }
            if candidate.memoryModel?.hasPrefix(prefix) == true { candidate.memoryModel = nil }
            if Self.resolveActive(candidate.defaultModel, in: candidate.endpoints) == nil {
                candidate.defaultModel = Self.firstPreferredModel(in: candidate.endpoints)
            }

            if self.keeping {
                let wrote: Bool = await withCheckedContinuation { continuation in
                    Self.endpointEditQueue.async {
                        do {
                            try ChatDisk.writeValueAndWait(candidate, file: "settings.json")
                            continuation.resume(returning: true)
                        } catch {
                            let reason = error.localizedDescription
                            DispatchQueue.main.async {
                                Diag.note("没存进手机：settings.json（\(reason)）")
                            }
                            continuation.resume(returning: false)
                        }
                    }
                }
                guard wrote else { return false }
            }

            if self.settings == snapshot {
                self.settings = candidate
                self.pruneUnavailableModelRefs { $0.hasPrefix(prefix) }
            } else {
                self.applyRemovedEndpoint(id)
            }
            let remaining = self.settings.endpoints
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                Self.endpointEditQueue.async {
                    Self.discardCredentials(from: removed, keeping: remaining)
                    continuation.resume()
                }
            }
            return true
        }
    }

    private func applyRemovedEndpoint(_ id: String) {
        let prefix = id + "/"
        settings.endpoints.removeAll { $0.id == id }
        if settings.backupModel?.hasPrefix(prefix) == true { settings.backupModel = nil }
        if settings.imageModel?.hasPrefix(prefix) == true { settings.imageModel = nil }
        if settings.memoryModel?.hasPrefix(prefix) == true { settings.memoryModel = nil }
        pruneUnavailableModelRefs { $0.hasPrefix(prefix) }
        if resolveActive(settings.defaultModel) == nil {
            settings.defaultModel = Self.firstPreferredModel(in: settings.endpoints)
        }
        saveSettings()
    }

    /// Asks a service for its models again. Returns how many it listed. Models in use stay in use.
    @discardableResult
    func refreshModels(_ id: String) async throws -> Int {
        guard let index = settings.endpoints.firstIndex(where: { $0.id == id }) else { return 0 }
        let endpoint = settings.endpoints[index]
        guard let key = await readAPIKey(for: endpoint), !key.isEmpty else { throw TeamError(message: "\(endpoint.name) 还没有密钥。") }
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
              let key = await readAPIKey(for: endpoint), !key.isEmpty else {
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
        let oldModels = Set(settings.endpoints[index].models)
        let removed = oldModels.subtracting(models)
        settings.endpoints[index].models = models
        if !removed.isEmpty {
            let prefix = id + "/"
            let activeRefs = Set(models.map { prefix + $0 })
            let removedFromService: @Sendable (String) -> Bool = { ref in
                ref.hasPrefix(prefix) && !activeRefs.contains(ref)
            }
            if let backup = settings.backupModel, removedFromService(backup) { settings.backupModel = nil }
            if let memory = settings.memoryModel, removedFromService(memory) { settings.memoryModel = nil }
            pruneUnavailableModelRefs(removedFromService)
        }
        if resolveActive(settings.defaultModel) == nil {
            if let pick = Self.preferred(settings.endpoints[index]) {
                settings.defaultModel = "\(id)/\(pick)"
            } else {
                settings.defaultModel = Self.firstPreferredModel(in: settings.endpoints)
            }
        }
        saveSettings()
    }

    private nonisolated static func optionsFilePath(_ key: String) -> String {
        "chats/\(key)~options.json"
    }

    private struct OptionsModelProbe: Decodable {
        let model: String?
    }

    private nonisolated static func scanOptionsMatching(
        skipKeys: Set<String>,
        matching: (String) -> Bool
    ) -> [(chatKey: String, model: String)] {
        let chatsDir = Disk.url("chats")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: chatsDir.path) else { return [] }
        let suffix = "~options.json"
        var matches: [(chatKey: String, model: String)] = []
        for file in files where file.hasSuffix(suffix) {
            let chatKey = String(file.dropLast(suffix.count))
            if skipKeys.contains(chatKey) { continue }
            let rel = "chats/\(file)"
            guard let data = try? Data(contentsOf: Disk.url(rel)),
                  let probe = try? JSONDecoder().decode(OptionsModelProbe.self, from: data),
                  let ref = probe.model, matching(ref) else { continue }
            matches.append((chatKey, ref))
        }
        return matches
    }

    private func pruneUnavailableModelRefs(_ shouldClear: @escaping @Sendable (String) -> Bool) {
        var botsChanged = false
        for idx in bots.indices {
            if let ref = bots[idx].model, shouldClear(ref) {
                bots[idx].model = nil
                botsChanged = true
            }
        }
        if botsChanged { saveBots() }

        for (key, var opts) in optionBook {
            if let ref = opts.model, shouldClear(ref) {
                opts.model = nil
                optionBook[key] = opts
                if keeping { ChatDisk.saveValue(opts, file: Self.optionsFile(key)) }
            }
        }
        guard keeping else { return }
        let loadedKeys = Set(optionBook.keys)
        OptionRefSync.enqueue(for: self) { team in
            guard team.keeping else { return }
            let found = await Task.detached(priority: .utility) {
                Self.scanOptionsMatching(skipKeys: loadedKeys, matching: shouldClear)
            }.value
            guard team.keeping, !found.isEmpty else { return }
            for item in found {
                guard shouldClear(item.model), team.resolveActive(item.model) == nil else { continue }
                let file = Self.optionsFile(item.chatKey)
                if var live = team.optionBook[item.chatKey] {
                    guard live.model == item.model else { continue }
                    live.model = nil
                    team.optionBook[item.chatKey] = live
                    ChatDisk.saveValue(live, file: file)
                } else {
                    let expected = item.model
                    ChatDisk.modifyValue(ChatOptions.self, file: file) { stored in
                        guard stored.model == expected else { return false }
                        stored.model = nil
                        return true
                    }
                }
            }
        }
    }

    /// Sets right what a model can do; nil goes back to the guess.
    func setTraits(_ id: String, model: String, _ traits: ModelTraits?) {
        guard let index = settings.endpoints.firstIndex(where: { $0.id == id }) else { return }
        var book = settings.endpoints[index].overrides ?? [:]
        book[model] = traits
        settings.endpoints[index].overrides = book.isEmpty ? nil : book
        saveSettings()
    }

    /// Enables or disables Anthropic prompt caching (`cache_control`) for one endpoint.
    func setPromptCache(_ id: String, enabled: Bool) {
        guard let index = settings.endpoints.firstIndex(where: { $0.id == id }) else { return }
        settings.endpoints[index].promptCache = enabled
        saveSettings()
    }

    static func normalizedEndpointAddress(_ raw: String) -> String? {
        EndpointAddressPolicy.normalize(raw)
    }

    private nonisolated static func makeEditedSettings(
        base: TeamSettings,
        id: String,
        originalCredentialID: String,
        givenName: String,
        targetCredentialID: String,
        nextURL: String,
        style: ThinkingStyle?
    ) -> (settings: TeamSettings, targetID: String)? {
        guard let idx = base.endpoints.firstIndex(where: { $0.id == id }) else { return nil }
        var candidate = base
        let migrated = targetCredentialID != originalCredentialID
        let targetID = migrated ? targetCredentialID : id
        candidate.endpoints[idx].id = targetID
        if migrated { candidate.endpoints[idx].credentialSlot = nil }
        if !givenName.isEmpty { candidate.endpoints[idx].name = givenName }
        let oldURL = candidate.endpoints[idx].baseURL
        let oldStyle = candidate.endpoints[idx].style
        candidate.endpoints[idx].baseURL = nextURL
        candidate.endpoints[idx].style = style
        if candidate.endpoints[idx].baseURL != oldURL || candidate.endpoints[idx].style != oldStyle,
           var overrides = candidate.endpoints[idx].overrides {
            for (model, var custom) in overrides where custom.levels != nil {
                custom.levels = nil
                let baseline = candidate.endpoints[idx].traits(model, ignoringCorrection: true)
                overrides[model] = (custom == baseline) ? nil : custom
            }
            candidate.endpoints[idx].overrides = overrides.isEmpty ? nil : overrides
        }
        if targetID != id {
            let oldPrefix = id + "/"
            let newPrefix = targetID + "/"
            func rewrite(_ ref: String?) -> String? {
                guard let ref, ref.hasPrefix(oldPrefix) else { return ref }
                return newPrefix + String(ref.dropFirst(oldPrefix.count))
            }
            candidate.defaultModel = rewrite(candidate.defaultModel)
            candidate.backupModel = rewrite(candidate.backupModel)
            candidate.memoryModel = rewrite(candidate.memoryModel)
            candidate.imageModel = rewrite(candidate.imageModel)
        }
        return (candidate, targetID)
    }

    /// Changes a service's name, address, thinking style, and optionally its API key.
    /// Same-origin path adjustments keep the endpoint ID and existing key; cross-host changes
    /// require a new key, write independent credentials under a new endpoint ID first, commit
    /// settings atomically, and defer cleanup of old slots.
    @discardableResult
    func editEndpoint(_ id: String, name: String, baseURL: String, style: ThinkingStyle?, key: String? = nil) -> EndpointKeyEditOutcome {
        guard let index = settings.endpoints.firstIndex(where: { $0.id == id }) else { return .invalidAddress }
        let original = settings.endpoints[index]
        let given = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowKeyless = Service.of(original)?.keyless == true

        let store = EndpointKeyCoordinator.Store(
            readBoundRecord: { Vault.load(Data.self, key: $0) },
            writeBoundRecord: Self.writeAndVerifyData,
            hasBoundMarker: { Vault.load(Bool.self, key: $0) == true },
            writeBoundMarker: { Self.writeAndVerifyBool($0, true) },
            readLegacyKey: { Vault.load(String.self, key: $0) },
            writeLegacyKey: Self.writeAndVerifyString,
            removeKey: { Vault.remove($0) },
            makeEndpointID: { UUID().uuidString },
            commitSettings: { targetCredentialID, nextURL in
                MainActor.assumeIsolated {
                    guard let built = Self.makeEditedSettings(
                        base: self.settings,
                        id: id,
                        originalCredentialID: original.credentialID,
                        givenName: given,
                        targetCredentialID: targetCredentialID,
                        nextURL: nextURL,
                        style: style
                    ) else { return false }
                    if self.keeping {
                        do {
                            try ChatDisk.writeValueAndWait(built.settings, file: "settings.json")
                        } catch {
                            return false
                        }
                    }
                    self.settings = built.settings
                    if built.targetID != id {
                        self.rewriteMigratedEndpointRefs(from: id, to: built.targetID)
                    }
                    return true
                }
            }
        )

        let outcome = EndpointKeyCoordinator.applyEdit(
            endpointID: original.credentialID,
            currentBaseURL: original.baseURL,
            newBaseURL: baseURL,
            replacementKey: key,
            allowKeylessLocalReuse: allowKeyless,
            store: store
        )
        if case .saved(let credentialID, let normalizedURL, let keyUpdated) = outcome {
            if keyUpdated { objectWillChange.send() }
            let endpointID = credentialID == original.credentialID ? id : credentialID
            return .saved(endpointID: endpointID, normalizedURL: normalizedURL, keyUpdated: keyUpdated)
        }
        return outcome
    }

    @discardableResult
    func editEndpointAsync(
        _ id: String,
        name: String,
        baseURL: String,
        style: ThinkingStyle?,
        key: String? = nil
    ) async -> EndpointKeyEditOutcome {
        await EndpointMutationGate.run(on: self) {
            guard let index = self.settings.endpoints.firstIndex(where: { $0.id == id }) else { return .invalidAddress }
            let original = self.settings.endpoints[index]
            let given = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let allowKeyless = Service.of(original)?.keyless == true

            let outcome: EndpointKeyEditOutcome = await withCheckedContinuation { continuation in
                Self.endpointEditQueue.async {
                    let store = EndpointKeyCoordinator.Store(
                        readBoundRecord: { Vault.load(Data.self, key: $0) },
                        writeBoundRecord: Self.writeAndVerifyData,
                        hasBoundMarker: { Vault.load(Bool.self, key: $0) == true },
                        writeBoundMarker: { Self.writeAndVerifyBool($0, true) },
                        readLegacyKey: { Vault.load(String.self, key: $0) },
                        writeLegacyKey: Self.writeAndVerifyString,
                        removeKey: { Vault.remove($0) },
                        makeEndpointID: { UUID().uuidString },
                        commitSettings: { targetCredentialID, nextURL in
                            let snapshot: (settings: TeamSettings, keeping: Bool)? = DispatchQueue.main.sync {
                                MainActor.assumeIsolated {
                                    guard self.settings.endpoints.contains(where: { $0.id == id }) else { return nil }
                                    return (self.settings, self.keeping)
                                }
                            }
                            guard let snapshot,
                                  let built = Self.makeEditedSettings(
                                      base: snapshot.settings,
                                      id: id,
                                      originalCredentialID: original.credentialID,
                                      givenName: given,
                                      targetCredentialID: targetCredentialID,
                                      nextURL: nextURL,
                                      style: style
                                  ) else {
                                return false
                            }
                            if snapshot.keeping {
                                do {
                                    try ChatDisk.writeValueAndWait(built.settings, file: "settings.json")
                                } catch {
                                    return false
                                }
                            }
                            let published: Bool = DispatchQueue.main.sync {
                                MainActor.assumeIsolated {
                                    if self.settings == snapshot.settings {
                                        self.settings = built.settings
                                    } else if let merged = Self.makeEditedSettings(
                                        base: self.settings,
                                        id: id,
                                        originalCredentialID: original.credentialID,
                                        givenName: given,
                                        targetCredentialID: targetCredentialID,
                                        nextURL: nextURL,
                                        style: style
                                    ) {
                                        self.settings = merged.settings
                                        self.saveSettings()
                                    } else {
                                        return false
                                    }
                                    if built.targetID != id {
                                        self.rewriteMigratedEndpointRefs(from: id, to: built.targetID)
                                    }
                                    return true
                                }
                            }
                            return published
                        }
                    )
                    let applied = EndpointKeyCoordinator.applyEdit(
                        endpointID: original.credentialID,
                        currentBaseURL: original.baseURL,
                        newBaseURL: baseURL,
                        replacementKey: key,
                        allowKeylessLocalReuse: allowKeyless,
                        store: store
                    )
                    continuation.resume(returning: applied)
                }
            }

            if case .saved(let credentialID, let normalizedURL, let keyUpdated) = outcome {
                if keyUpdated { self.objectWillChange.send() }
                let endpointID = credentialID == original.credentialID ? id : credentialID
                return .saved(endpointID: endpointID, normalizedURL: normalizedURL, keyUpdated: keyUpdated)
            }
            return outcome
        }
    }

    private func rewriteMigratedEndpointRefs(from oldID: String, to newID: String) {
        let oldPrefix = oldID + "/"
        let newPrefix = newID + "/"
        let rewrite: @Sendable (String?) -> String? = { ref in
            guard let ref, ref.hasPrefix(oldPrefix) else { return ref }
            return newPrefix + String(ref.dropFirst(oldPrefix.count))
        }

        var botsChanged = false
        for idx in bots.indices {
            if let next = rewrite(bots[idx].model), next != bots[idx].model {
                bots[idx].model = next
                botsChanged = true
            }
        }
        if botsChanged { saveBots() }

        for (key, var opts) in optionBook {
            if let next = rewrite(opts.model), next != opts.model {
                opts.model = next
                optionBook[key] = opts
                if keeping { ChatDisk.saveValue(opts, file: Self.optionsFile(key)) }
            }
        }
        guard keeping else { return }
        let loadedKeys = Set(optionBook.keys)
        OptionRefSync.enqueue(for: self) { team in
            guard team.keeping else { return }
            let found = await Task.detached(priority: .utility) {
                Self.scanOptionsMatching(skipKeys: loadedKeys) { $0.hasPrefix(oldPrefix) }
            }.value
            guard team.keeping, !found.isEmpty else { return }
            let targetActive = team.settings.endpoints.contains { $0.id == newID }
            for item in found {
                let targetModel = targetActive ? rewrite(item.model) : nil
                let file = Self.optionsFile(item.chatKey)
                if var live = team.optionBook[item.chatKey] {
                    guard live.model == item.model else { continue }
                    live.model = targetModel
                    team.optionBook[item.chatKey] = live
                    ChatDisk.saveValue(live, file: file)
                } else {
                    let expected = item.model
                    ChatDisk.modifyValue(ChatOptions.self, file: file) { stored in
                        guard stored.model == expected else { return false }
                        stored.model = targetModel
                        return true
                    }
                }
            }
        }
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
        guard let endpoint = settings.endpoints.first(where: { $0.id == id }) else { return }
        if let origin = EndpointAddressPolicy.rawOrigin(endpoint.baseURL) {
            _ = EndpointKeyCoordinator.saveBoundCredential(
                endpointID: endpoint.credentialID,
                origin: origin,
                key: key,
                writeBoundRecord: Self.writeAndVerifyData,
                writeBoundMarker: { Self.writeAndVerifyBool($0, true) },
                writeLegacyKey: Self.writeAndVerifyString,
                removeKey: { Vault.remove($0) }
            )
        } else {
            Vault.save(key, as: EndpointKeyCoordinator.legacyKeySlot(for: endpoint.credentialID))
        }
        objectWillChange.send()
    }

    func editMemory(_ id: String, _ text: String) {
        guard canMutateMemoryState else { return }
        guard let index = memories.firstIndex(where: { $0.id == id }) else { return }
        let orderedSecrets = Vault.allStrings().filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        let safeWords = MemorySafety.redactSecrets(text, secrets: orderedSecrets)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if safeWords.isEmpty {
            deleteMemory(id)
            return
        }
        var nextMemories = memories
        nextMemories[index].text = safeWords
        nextMemories[index].editedByUser = true
        if !keeping {
            memories = nextMemories
            memoryBook.memories = nextMemories
            memoryPromptState.clearRetraction(id: id, text: safeWords)
            syncLivePromptsFromMemories()
            return
        }
        var nextBook = memoryBook
        nextBook.memories = nextMemories
        _ = try? commitMemoryBook(
            nextBook,
            mutation: .edit(id: id, text: safeWords, editedByUser: true, nowMs: Now.ms)
        )
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

    static func firstPreferredModel(in endpoints: [Endpoint]) -> String? {
        for endpoint in endpoints {
            if let pick = preferred(endpoint) { return "\(endpoint.id)/\(pick)" }
        }
        return nil
    }

    nonisolated static func resolve(_ ref: String?, in endpoints: [Endpoint]) -> (endpoint: Endpoint, model: String)? {
        guard let ref, let slash = ref.firstIndex(of: "/") else { return nil }
        let id = String(ref[..<slash])
        let model = String(ref[ref.index(after: slash)...])
        guard let endpoint = endpoints.first(where: { $0.id == id }), !model.isEmpty else { return nil }
        return (endpoint, model)
    }

    nonisolated static func resolveActive(_ ref: String?, in endpoints: [Endpoint]) -> (endpoint: Endpoint, model: String)? {
        guard let found = resolve(ref, in: endpoints), found.endpoint.models.contains(found.model) else { return nil }
        return found
    }

    /// The service and model a ref names; nil when it names none that is set up.
    func resolve(_ ref: String?) -> (endpoint: Endpoint, model: String)? {
        Self.resolve(ref, in: settings.endpoints)
    }

    /// Resolves a model ref only when the model is currently enabled in that service's `models` list.
    func resolveActive(_ ref: String?) -> (endpoint: Endpoint, model: String)? {
        Self.resolveActive(ref, in: settings.endpoints)
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

@MainActor
private enum EndpointMutationGate {
    private static var tails: [ObjectIdentifier: (id: UUID, task: Task<Void, Never>)] = [:]

    static func run<Result: Sendable>(
        on team: TeamModel,
        _ work: @escaping @MainActor () async -> Result
    ) async -> Result {
        let key = ObjectIdentifier(team)
        let previous = tails[key]?.task
        let token = UUID()
        let task = Task<Result, Never> {
            _ = await previous?.value
            return await work()
        }
        let waiter = Task<Void, Never> {
            _ = await task.value
            if tails[key]?.id == token {
                tails.removeValue(forKey: key)
            }
        }
        tails[key] = (token, waiter)
        return await task.value
    }
}

@MainActor
private enum OptionRefSync {
    private static var tails: [ObjectIdentifier: Task<Void, Never>] = [:]

    static func enqueue(for team: TeamModel, _ work: @escaping @MainActor (TeamModel) async -> Void) {
        let key = ObjectIdentifier(team)
        let previous = tails[key]
        let task = Task { [weak team] in
            await previous?.value
            guard let team, !Task.isCancelled else { return }
            await work(team)
        }
        tails[key] = task
    }
}
