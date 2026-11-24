import AgentKit
import Craft
import SwiftUI
import UserNotifications
import UIKit

extension TeamModel {
    // MARK: This conversation's own settings

    /// What the user set for one conversation only: abilities switched off, and a model of its own.
    struct ChatOptions: Codable, Equatable {
        /// `Grant` names turned off in this conversation.
        var off: [String] = []
        /// `endpointId/modelId`; nil follows the companion.
        var model: String?
        /// Where the work happens (`WorkPlace.code`); nil is 书案.
        var place: String?
        /// The current conversation's title, written by the model after the first exchange (12 characters at most).
        var title: String?
        /// Tokens this conversation has used, as the services reported them (counted from 0.27 on).
        var spend: Spend?
        /// How hard the model thinks here; nil: the model's own default.
        var thinking: Thinking?

        var web: Bool { !off.contains(Grant.web.rawValue) && !off.contains(Grant.browser.rawValue) }
    }

    static func optionsFile(_ key: String) -> String { "chats/\(key)~options.json" }

    func options(_ key: String) -> ChatOptions {
        if let kept = optionBook[key] { return kept }
        let loaded = keeping ? (Disk.load(ChatOptions.self, Self.optionsFile(key)) ?? ChatOptions()) : ChatOptions()
        optionBook[key] = loaded
        return loaded
    }

    /// What every conversation has used, biggest first: 「团子 · 1.2M 输入 · 80K 输出」.
    func allSpend() -> [(name: String, spend: Spend)] {
        let keys = bots.map { Self.key(bot: $0.id) } + rooms.map { Self.key(room: $0.id) }
        return keys.compactMap { key in
            guard let spend = options(key).spend, spend.input + spend.output > 0 else { return nil }
            return (chatName(key), spend)
        }
        .sorted { $0.spend.input + $0.spend.output > $1.spend.input + $1.spend.output }
    }

    func setOptions(_ key: String, _ value: ChatOptions) {
        let oldHostID = WorkPlace(code: (optionBook[key] ?? options(key)).place).hostID
        objectWillChange.send()
        optionBook[key] = value
        let newHostID = WorkPlace(code: value.place).hostID
        hostBindings.set(newHostID, for: key)
        if keeping { Disk.save(value, Self.optionsFile(key)) }
        if oldHostID != newHostID {
            cancelStaleWorkplaceApprovals(executionChat: key, oldHostID: oldHostID)
        }
    }

    /// Switches one ability on or off for this conversation.
    func setAbility(_ grant: Grant, on: Bool, in key: String) {
        var value = options(key)
        value.off.removeAll { $0 == grant.rawValue }
        if !on { value.off.append(grant.rawValue) }
        setOptions(key, value)
    }

    /// 联网: searching, reading pages and 远游 together.
    func setWeb(_ on: Bool, in key: String) {
        var value = options(key)
        value.off.removeAll { $0 == Grant.web.rawValue || $0 == Grant.browser.rawValue }
        if !on { value.off += [Grant.web.rawValue, Grant.browser.rawValue] }
        setOptions(key, value)
    }

    func setModel(_ ref: String?, in key: String) {
        var value = options(key)
        value.model = ref
        setOptions(key, value)
    }

    func setPlace(_ place: WorkPlace, in key: String) {
        var value = options(key)
        value.place = place.code
        setOptions(key, value)
    }

    func place(of key: String) -> WorkPlace { WorkPlace(code: options(key).place) }

    /// The model this conversation will use.
    func model(for key: String, bot: BotInfo) -> String? { options(key).model ?? bot.model ?? settings.defaultModel }

    func setThinking(_ level: Thinking?, in key: String) {
        var value = options(key)
        value.thinking = level == .auto ? nil : level
        setOptions(key, value)
    }

    /// The service and model a chat would use now, with what the model can do.
    func current(_ key: String, bot: BotInfo) -> (endpoint: Endpoint, model: String, traits: ModelTraits)? {
        guard let found = resolveActive(options(key).model)
            ?? resolveActive(bot.model)
            ?? resolveActive(settings.defaultModel)
            ?? resolve(model(for: key, bot: bot))
            ?? resolve(settings.defaultModel) else { return nil }
        return (found.endpoint, found.model, found.endpoint.traits(found.model))
    }

    func offBlock(_ key: String) -> String {
        let off = options(key).off.compactMap(Grant.init(rawValue:))
        guard !off.isEmpty else { return "" }
        return "\n\n在这段絮语里，用户关掉了这些本事：" + off.map(\.title).joined(separator: "、") + "。需要用到时，告诉用户可以在输入框下的「本事」里打开，不要假装做了。"
    }
}
