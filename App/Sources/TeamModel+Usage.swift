import AgentKit
import Craft
import SwiftUI
import UserNotifications
import UIKit

/// Estimation runs off the UI actor. A recent projection reuses token counts for entries whose
/// content, media disposition, and protocol rules are identical.
actor ContextEstimateCache {
    struct MediaState: Equatable, Sendable {
        var inlineCount: Int
        var pendingFiles: [String]
        var references: [String]
        var described: Bool
    }

    struct EntryKey: Equatable, Sendable {
        var id: String
        var contentRevision: UInt64
        var mediaState: MediaState
        var protocolRule: String
    }

    struct Projection: Sendable {
        var messages: [Message]
        var entryIDs: [String]
        var mediaFiles: [Int: [String]]
        var permittedImageCategories: Set<OutboundDataCategory>
        var describedImageCategories: Set<OutboundDataCategory>
        var recipient: RecipientIdentity?
        var visionRecipient: RecipientIdentity?
        var visionModel: String?
        var consentGeneration: UInt64
        var echoes: Bool
        var includesSignatures = false
        var toolsEnabled: Bool
        var tools: [ToolSpec]
        var prompt: String
        var base: TeamModel.ContextEstimate
    }

    private struct CachedEntry {
        var key: EntryKey
        var content: Message
        var tokens: Int
    }

    private struct RequestKey: Equatable {
        var entries: [EntryKey]
        var boundary: String?
        var recipient: RecipientIdentity?
        var visionRecipient: RecipientIdentity?
        var visionModel: String?
        var consentGeneration: UInt64
        var toolsEnabled: Bool
        var tools: [ToolSpec]
        var prompt: String
        var base: TeamModel.ContextEstimate
    }

    private struct ChatCache {
        var entries: [String: CachedEntry] = [:]
        var request: RequestKey?
        var estimate: TeamModel.ContextEstimate?
    }

    private var chats: [String: ChatCache] = [:]
    private(set) var entryHits = 0
    private(set) var requestHits = 0

    func estimate(_ projection: Projection, chat: String) -> TeamModel.ContextEstimate {
        var cache = chats[chat] ?? ChatCache()
        var entries: [String: CachedEntry] = [:]
        var keys: [EntryKey] = []
        var messageTokens = 0
        let protocolName = projection.recipient?.protocolKind ?? ""
        let rule = protocolName + (projection.includesSignatures ? ":signed" : projection.echoes ? ":echo" : ":plain")
        for unit in ProtocolAtomicUnit.group(projection.messages) {
            for (offset, pair) in zip(unit.messages, unit.sourceIndices).enumerated() {
                var message = pair.0
                let source = pair.1
                let id = source.flatMap { projection.entryIDs.indices.contains($0) ? projection.entryIDs[$0] : nil }
                    .map { "entry/" + $0 }
                    ?? "missing/\(message.toolCallId ?? "")/\(unit.sourceRange.lowerBound)/\(offset)"
                let files = source.flatMap { projection.mediaFiles[$0] } ?? []
                let category = OutboundDataCategory.image(in: message)
                let allowed = projection.permittedImageCategories.contains(category)
                let hasMedia = !message.images.isEmpty || !files.isEmpty
                let described = hasMedia && projection.describedImageCategories.contains(category)
                if hasMedia, !allowed, !described {
                    message = TeamModel.withholdingImages(message)
                }
                let media = MediaState(inlineCount: allowed ? message.images.count : 0,
                                       pendingFiles: allowed || described ? files : [],
                                       references: message.mediaReferences ?? [], described: described)
                message.images = []
                message.detail = nil
                let old = cache.entries[id]
                let revision: UInt64
                if let old, old.content != message { revision = old.key.contentRevision &+ 1 }
                else { revision = old?.key.contentRevision ?? 0 }
                let key = EntryKey(id: id, contentRevision: revision, mediaState: media, protocolRule: rule)
                let cached: CachedEntry
                if let old, old.key == key {
                    cached = old
                    entryHits += 1
                } else {
                    var reasoning = projection.echoes ? Tokens.estimate(message.reasoning ?? "") : 0
                    if projection.includesSignatures, let signature = message.reasoningSignature, !signature.isEmpty {
                        reasoning = Tokens.estimate(message.reasoning ?? "") + Tokens.estimate(signature)
                    }
                    let tools = message.toolCalls.reduce(0) { $0 + Tokens.estimate($1.name + $1.arguments) }
                    let images = described ? TeamModel.auxiliaryVisionOutputLimit
                        : (media.inlineCount + media.pendingFiles.count) * Tokens.perImage
                    cached = CachedEntry(key: key, content: message,
                                         tokens: Tokens.estimate(message.text) + reasoning + tools + images)
                }
                entries[id] = cached
                keys.append(key)
                messageTokens += cached.tokens
            }
        }
        let request = RequestKey(entries: keys, boundary: projection.entryIDs.first, recipient: projection.recipient,
                                 visionRecipient: projection.visionRecipient, visionModel: projection.visionModel,
                                 consentGeneration: projection.consentGeneration, toolsEnabled: projection.toolsEnabled,
                                 tools: projection.tools, prompt: projection.prompt, base: projection.base)
        if let estimate = cache.estimate, cache.request == request {
            requestHits += 1
            return estimate
        }
        var estimate = projection.base
        estimate.system = Tokens.estimate(projection.prompt)
        estimate.tools = projection.tools.reduce(0) { total, spec in
            let schema = (try? JSONEncoder().encode(spec.parameters)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            return total + Tokens.estimate(spec.name + spec.description + schema)
        }
        estimate.messages = messageTokens
        cache.entries = entries
        cache.request = request
        cache.estimate = estimate
        if chats[chat] == nil, chats.count >= 8, let oldest = chats.keys.first { chats[oldest] = nil }
        chats[chat] = cache
        return estimate
    }
}

extension TeamModel {
    // MARK: 用量

    /// About how big the next request will be, by part, and how much of the model's window that is.
    struct ContextEstimate: Equatable, Sendable {
        var system = 0
        var tools = 0
        var messages = 0
        var window = Tokens.window(for: "")
        var model = ""

        var total: Int { system + tools + messages }
        var share: Double { window > 0 ? Double(total) / Double(window) : 0 }
    }

    /// Who answers in a chat and with which model: the companion, or a gathering's first member.
    func speaker(of key: String) -> (bot: BotInfo, room: RoomInfo?, found: (endpoint: Endpoint, model: String)?)? {
        let room = rooms.first { Self.key(room: $0.id) == key }
        let bot = room.flatMap { room in bots.first { $0.id == room.members?.first } } ?? bots.first { Self.key(bot: $0.id) == key }
        guard let bot else { return nil }
        let picked = options(key).model ?? bot.model ?? settings.defaultModel
        return (bot, room, resolve(picked) ?? resolve(settings.defaultModel))
    }

    /// Minimal snapshot for the black status window, using the real turn start and speaker.
    func alwaysOnTurn(_ key: String) -> (started: Date?, bot: BotInfo?) {
        let run = runs[key]
        let current = run?.companion.flatMap { id in bots.first { $0.id == id } }
        return (run?.started, current ?? speaker(of: key)?.bot)
    }

    /// The model service a chat talks to.
    func chatEndpoint(_ key: String) -> Endpoint? { speaker(of: key)?.found?.endpoint }

    func contextEstimate(_ key: String) async -> ContextEstimate {
        _ = await loadHistory(key)
        guard !Task.isCancelled else { return ContextEstimate() }
        await Task.detached(priority: .utility) { _ = SkillShelf.enabled }.value
        var estimate = ContextEstimate()
        guard !Task.isCancelled, let who = speaker(of: key) else { return estimate }
        let (bot, room, found) = (who.bot, who.room, who.found)
        let traits = found.map { $0.endpoint.traits($0.model) }
        let directVision = traits?.sees ?? false
        let vision = directVision || (found.map { canUseAuxiliaryVision(for: $0.endpoint, model: $0.model) } ?? false)
        let chatOptions = options(key)
        let echoes = found?.endpoint.thinkingStyle.echoesReasoning ?? false
        let selection = chatOptions.effectiveThinkingSelection
        let signedReasoning = found?.endpoint.kind.isAnthropic == true && !selection.isDefault && !selection.isExplicitOff
        estimate.model = found?.model ?? ""
        estimate.window = traits?.window ?? Tokens.window(for: estimate.model)
        let workplace = place(of: key)
        let prompt = assembledSystemPrompt(
            for: bot,
            in: key,
            room: room,
            workplace: workplace,
            memory: !chatOptions.off.contains(Grant.memory.rawValue)
        ).full
        let specs = traits?.tools == false ? [] : tools(for: bot, key: key, canSee: vision, workplace: workplace).map(\.spec)
        let context = context(for: key, bot: bot, room: room, vision: vision)
        let recipient = found?.endpoint.recipientIdentity
        let auxiliary = directVision ? nil : visionModelSelection
        let auxiliaryRecipient = auxiliary?.endpoint.recipientIdentity
        let permitted = permittedImageCategories(for: directVision ? recipient : nil)
        return await contextEstimateCache.estimate(
            .init(messages: context.messages, entryIDs: context.entryIDs, mediaFiles: context.photos,
                  permittedImageCategories: permitted, describedImageCategories: permittedImageCategories(for: auxiliaryRecipient),
                  recipient: recipient, visionRecipient: auxiliaryRecipient, visionModel: auxiliary?.model,
                  consentGeneration: settings.outboundConsentGeneration, echoes: echoes, includesSignatures: signedReasoning,
                  toolsEnabled: traits?.tools != false, tools: specs, prompt: prompt, base: estimate),
            chat: key
        )
    }

    /// What is left on the account of `endpoint`, for the services that tell (DeepSeek, Moonshot, SiliconFlow, OpenRouter).
    func balance(_ endpoint: Endpoint) async throws -> Balance.Reading {
        guard let source = Balance.source(baseURL: endpoint.baseURL) else { throw TeamError(message: "\(endpoint.name) 不提供余额查询。") }
        guard let secret = await readAPIKey(for: endpoint.id), !secret.isEmpty else { throw TeamError(message: "\(endpoint.name) 的密钥找不到了。") }
        var request = URLRequest(url: source.url, timeoutInterval: 15)
        request.setValue(source.authorizationValue(for: secret), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let reading = Balance.parse(String(decoding: data, as: UTF8.self), baseURL: endpoint.baseURL) else {
            throw TeamError(message: status == 401 ? "密钥不对，查不了余额。" : "没查到余额（\(status)）。")
        }
        return reading
    }

    /// The reminder line for a service's balance; 0 is off.
    static func balanceFloor(_ endpointId: String) -> Double { UserDefaults.standard.double(forKey: "balance.alert.\(endpointId)") }
    static func setBalanceFloor(_ endpointId: String, _ value: Double) { UserDefaults.standard.set(value, forKey: "balance.alert.\(endpointId)") }


    /// After a turn: at most every half hour, look at the balance of a service with a reminder line set, and say so once it is under.
    func watchBalance(_ key: String) {
        guard let endpoint = chatEndpoint(key), Balance.source(baseURL: endpoint.baseURL) != nil else { return }
        let floor = Self.balanceFloor(endpoint.id)
        guard floor > 0 else { return }
        if let last = balanceCheckedAt[endpoint.id], Date().timeIntervalSince(last) < 1800 { return }
        balanceCheckedAt[endpoint.id] = Date()
        Task { [weak self] in
            guard let self, let reading = try? await self.balance(endpoint), reading.amount < floor else { return }
            let warned = "balance.warned.\(endpoint.id)"
            let now = Date().timeIntervalSince1970
            guard now - UserDefaults.standard.double(forKey: warned) > 12 * 3600 else { return }
            UserDefaults.standard.set(now, forKey: warned)
            Notify.now("\(endpoint.name) 余额只剩 \(reading.shown)", "低于你设的提醒线 \(reading.symbol)\(Int(floor))，记得去充值。", chat: key)
            Diag.note("\(endpoint.name) 余额 \(reading.shown)，低于提醒线")
        }
    }
}
