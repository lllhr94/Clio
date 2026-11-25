import AgentKit
import Craft
import SwiftUI
import UserNotifications
import UIKit

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
        let vision = traits?.sees ?? false
        let echoes = found?.endpoint.thinkingStyle.echoesReasoning ?? false
        estimate.model = found?.model ?? ""
        estimate.window = traits?.window ?? Tokens.window(for: estimate.model)
        let workplace = place(of: key)
        let prompt = assembledSystemPrompt(
            for: bot,
            in: key,
            room: room,
            workplace: workplace,
            memory: !options(key).off.contains(Grant.memory.rawValue)
        ).full
        let specs = traits?.tools == false ? [] : tools(for: bot, key: key, canSee: vision, workplace: workplace).map(\.spec)
        let context = context(for: key, bot: bot, room: room, vision: vision)
        let base = estimate
        return await Task.detached(priority: .utility) {
            var estimate = base
            estimate.system = Tokens.estimate(prompt)
            estimate.tools = specs.reduce(0) { total, spec in
                let schema = (try? JSONEncoder().encode(spec.parameters)).map { String(decoding: $0, as: UTF8.self) } ?? ""
                return total + Tokens.estimate(spec.name + spec.description + schema)
            }
            estimate.messages = context.estimatedTokens(echoes: echoes)
            return estimate
        }.value
    }

    /// What is left on the account of `endpoint`, for the services that tell (DeepSeek, Moonshot, SiliconFlow, OpenRouter).
    func balance(_ endpoint: Endpoint) async throws -> Balance.Reading {
        guard let source = Balance.source(baseURL: endpoint.baseURL) else { throw TeamError(message: "\(endpoint.name) 不提供余额查询。") }
        guard let secret = await readAPIKey(for: endpoint.id), !secret.isEmpty else { throw TeamError(message: "\(endpoint.name) 的密钥找不到了。") }
        var request = URLRequest(url: source.url, timeoutInterval: 15)
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
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
