import AgentKit
import Craft
import SwiftUI
import UserNotifications
import UIKit

extension TeamModel {
    // MARK: This conversation's own settings

    /// What the user set for one conversation only: abilities switched off, and a model of its own.
    struct ChatOptions: Codable, Equatable, Sendable {
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
        /// Legacy 6-stop thinking field kept for backward compatibility (read only when `thinkingSelection` is absent).
        var thinking: Thinking?
        /// Versioned high-fidelity thinking selection (v2, authoritative when present).
        var thinkingSelection: ThinkingSelection?
        /// Conversation-scoped read-only Plan mode (default off; never mutates global `Grant`).
        var planMode: Bool?
        /// Non-reusable conversation identity that migrates into `Leaf.conversationID` on `shelveCurrent`
        /// so late async subtask deliveries and approvals never land in a new conversation reusing the same slot.
        var conversationID: String?

        var isPlanMode: Bool { planMode == true }

        var web: Bool { !off.contains(Grant.web.rawValue) && !off.contains(Grant.browser.rawValue) }

        /// Locked read order: v2 `thinkingSelection` first; legacy `thinking` only when v2 is absent.
        var effectiveThinkingSelection: ThinkingSelection {
            ThinkingSelection.readEffective(v2: thinkingSelection, legacy: thinking)
        }

        /// Locked write order: persists v2 primarily and writes legacy `thinking` ONLY when faithfully expressible.
        mutating func setThinkingSelection(_ selection: ThinkingSelection) {
            let pair = ThinkingSelection.writePair(selection)
            thinkingSelection = pair.v2
            thinking = pair.legacy
        }

        init(
            off: [String] = [],
            model: String? = nil,
            place: String? = nil,
            title: String? = nil,
            spend: Spend? = nil,
            thinking: Thinking? = nil,
            thinkingSelection: ThinkingSelection? = nil,
            planMode: Bool? = nil,
            conversationID: String? = nil
        ) {
            self.off = off
            self.model = model
            self.place = place
            self.title = title
            self.spend = spend
            self.thinking = thinking
            self.thinkingSelection = thinkingSelection
            self.planMode = planMode
            self.conversationID = conversationID
        }

        private enum CodingKeys: String, CodingKey {
            case off, model, place, title, spend, thinking, thinkingSelection, planMode, conversationID
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            off = (try? c.decodeIfPresent([String].self, forKey: .off)) ?? []
            model = try? c.decodeIfPresent(String.self, forKey: .model)
            place = try? c.decodeIfPresent(String.self, forKey: .place)
            title = try? c.decodeIfPresent(String.self, forKey: .title)
            spend = try? c.decodeIfPresent(Spend.self, forKey: .spend)
            thinking = try? c.decodeIfPresent(Thinking.self, forKey: .thinking)
            thinkingSelection = try? c.decodeIfPresent(ThinkingSelection.self, forKey: .thinkingSelection)
            planMode = try? c.decodeIfPresent(Bool.self, forKey: .planMode)
            conversationID = try? c.decodeIfPresent(String.self, forKey: .conversationID)
        }
    }

    static func optionsFile(_ key: String) -> String { "chats/\(key)~options.json" }

    func options(_ key: String) -> ChatOptions {
        if let kept = optionBook[key] { return kept }
        let loaded = keeping ? (Disk.load(ChatOptions.self, Self.optionsFile(key)) ?? ChatOptions()) : ChatOptions()
        optionBook[key] = loaded
        liveChatMemoryGate.setDisabledGrants(Set(loaded.off), for: key)
        livePlanModeLedger.setPlanMode(loaded.isPlanMode, for: key)
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
        let oldOptions = optionBook[key] ?? options(key)
        let oldHostID = WorkPlace(code: oldOptions.place).hostID
        let oldOff = oldOptions.off.contains(Grant.memory.rawValue)
        let newOff = value.off.contains(Grant.memory.rawValue)
        objectWillChange.send()
        optionBook[key] = value
        liveChatMemoryGate.setDisabledGrants(Set(value.off), for: key)
        livePlanModeLedger.setPlanMode(value.isPlanMode, for: key)
        let newHostID = WorkPlace(code: value.place).hostID
        hostBindings.set(newHostID, for: key)
        if keeping { ChatDisk.saveValue(value, file: Self.optionsFile(key)) }
        if oldHostID != newHostID {
            cancelStaleWorkplaceApprovals(executionChat: key, oldHostID: oldHostID)
        }
        if Set(oldOptions.off) != Set(value.off) {
            approvalQueue.bumpRevision()
            reconcilePendingApprovals()
        }
        if oldOff != newOff {
            invalidateMemoryPromptCache()
        }
        if oldOptions.isPlanMode != value.isPlanMode {
            bumpPlanSessionEpoch(for: key)
            approvalQueue.bumpRevision()
            reconcilePendingApprovals()
            invalidateMemoryPromptCache()
        }
    }

    /// True when conversation-scoped Plan mode OR an inherited read-only sub-companion ceiling is active.
    func isPlanModeActive(for key: String) -> Bool {
        guard !key.hasPrefix("casual-") else { return false }
        _ = options(key)
        return livePlanModeLedger.isRestricted(key)
    }

    /// Enables or disables conversation-scoped read-only Plan mode without modifying any global `Grant`.
    func setPlanMode(_ on: Bool, in key: String) {
        guard !key.hasPrefix("casual-") else { return }
        var value = options(key)
        let target: Bool? = on ? true : nil
        guard value.planMode != target else { return }
        value.planMode = target
        setOptions(key, value)
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

    func place(of key: String) -> WorkPlace {
        if let bound = ephemeralPlaces[key] { return bound }
        return WorkPlace(code: options(key).place)
    }

    /// The model this conversation will use.
    func model(for key: String, bot: BotInfo) -> String? { options(key).model ?? bot.model ?? settings.defaultModel }

    func setThinking(_ level: Thinking?, in key: String) {
        setThinkingSelection(ThinkingSelection.fromLegacy(level), in: key)
    }

    func setThinkingSelection(_ selection: ThinkingSelection, in key: String) {
        var value = options(key)
        value.setThinkingSelection(selection)
        setOptions(key, value)
    }

    /// Resolves the confirmed thinking contract for one `(endpoint, model)` pair using an optional frozen snapshot.
    func thinkingContract(
        for endpoint: Endpoint,
        model: String,
        snapshot: ModelsDevCatalogSnapshot? = nil
    ) -> ThinkingRuleResolver.ConfirmedContract {
        let activeSnapshot = snapshot ?? ModelsDev.currentSnapshot()
        let resolution = endpoint.traitsResolution(model, snapshot: activeSnapshot)
        var contract = endpoint.thinkingContract(for: model, snapshot: activeSnapshot)
        // Honor explicit user-manual override (`thinks == false` or `thinks == true`) while never letting
        // legacy probe suppress confirmed contracts.
        if resolution.traits.effectiveThinksSource == .userManual && !resolution.traits.thinks {
            contract.supportsThinking = false
            contract.canExplicitlyDisable = false
            contract.offeredSelections = [.inheritDefault]
        } else if endpoint.validatedManualThinkingRule(for: model) != nil {
            // Validated `ManualThinkingRule` already populated `contract` authoritatively above.
        } else if resolution.traits.effectiveLevelsSource == .userManual,
                  let customLevels = resolution.traits.levels {
            let parsed = customLevels.compactMap(Thinking.init(rawValue:)).filter { $0 != .auto }
            var offered: [ThinkingSelection] = [.inheritDefault]
            for level in parsed {
                let sel = ThinkingSelection.fromLegacy(level)
                if !offered.contains(sel) { offered.append(sel) }
            }
            contract.offeredSelections = offered
            contract.supportsThinking = offered.count > 1
            if parsed.contains(.off) {
                contract.canExplicitlyDisable = true
                contract.isKnownContract = true
            }
        } else if resolution.traits.effectiveThinksSource == .userManual && resolution.traits.thinks {
            contract.supportsThinking = true
            if contract.offeredSelections.count <= 1 {
                var seeded: [ThinkingSelection] = [.inheritDefault]
                if endpoint.kind == .anthropic {
                    seeded += [.effort("low"), .effort("medium"), .effort("high"), .effort("max")]
                } else if endpoint.thinkingStyle != .none {
                    let levels = endpoint.thinkingStyle.levels(thinks: true).filter { $0 != .auto && $0 != .off }
                    seeded += levels.map { ThinkingSelection.fromLegacy($0) }
                }
                contract.offeredSelections = seeded
            }
        } else if !resolution.traits.thinks && !contract.isKnownContract {
            contract.supportsThinking = false
            contract.offeredSelections = [.inheritDefault]
        } else if resolution.traits.thinks && !contract.isKnownContract && contract.offeredSelections.count <= 1 {
            // Name-guessed or catalog-hint thinking model on a custom relay without manual rule:
            // offer non-off effort levels matching endpoint style (still never claiming verified explicitOff).
            contract.supportsThinking = true
            var seeded: [ThinkingSelection] = [.inheritDefault]
            if endpoint.kind == .anthropic {
                seeded += [.effort("low"), .effort("medium"), .effort("high"), .effort("max")]
            } else if endpoint.thinkingStyle != .none {
                let levels = endpoint.thinkingStyle.levels(thinks: true).filter { $0 != .auto && $0 != .off }
                seeded += levels.map { ThinkingSelection.fromLegacy($0) }
            }
            contract.offeredSelections = seeded
        }
        return contract
    }

    /// Resolves the thinking options offered in a chat (1:1 or gathering) using one frozen catalog snapshot.
    /// Precedence: when a gathering has a conversation-level model override (`options.model != nil`),
    /// resolves directly against that override model; ONLY when `options.model == nil` does it intersect
    /// all room members' realizable intents.
    func offeredThinkingSelections(
        in key: String,
        roomId: String?,
        fallback bot: BotInfo,
        snapshot: ModelsDevCatalogSnapshot? = nil
    ) -> [ThinkingSelection] {
        let activeSnapshot = snapshot ?? ModelsDev.currentSnapshot()
        let chatOptions = options(key)
        let speakers: [BotInfo]
        if let roomID = roomId, chatOptions.model == nil,
           let members = rooms.first(where: { $0.id == roomID })?.members, !members.isEmpty {
            speakers = members.compactMap { id in bots.first { $0.id == id } }
        } else {
            let activeBot = roomId != nil ? (alwaysOnTurn(key).bot ?? bot) : bot
            speakers = [activeBot]
        }
        guard !speakers.isEmpty else { return [.inheritDefault] }
        let contracts: [ThinkingRuleResolver.ConfirmedContract] = speakers.compactMap { speaker in
            guard let found = current(key, bot: speaker) else { return nil }
            return thinkingContract(for: found.endpoint, model: found.model, snapshot: activeSnapshot)
        }
        guard contracts.count == speakers.count, !contracts.isEmpty else { return [.inheritDefault] }
        return ThinkingRuleResolver.intersectOfferings(contracts)
    }

    /// Shared frozen resolution of the saved `ThinkingSelection` for one concrete speaker/turn.
    func resolvedThinking(
        for key: String,
        endpoint: Endpoint,
        model: String,
        intent: ThinkingCallIntent = .userChat,
        snapshot: ModelsDevCatalogSnapshot? = nil
    ) -> ThinkingRuleResolver.Resolution {
        let activeSnapshot = snapshot ?? ModelsDev.currentSnapshot()
        let contract = thinkingContract(for: endpoint, model: model, snapshot: activeSnapshot)
        let selection = options(key).effectiveThinkingSelection
        let style: ThinkingStyle? = endpoint.kind.supportsThinkingStyleSelection ? endpoint.thinkingStyle : nil
        return ThinkingRuleResolver.resolve(
            selection: selection,
            contract: contract,
            style: style,
            intent: intent
        )
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
        var blocks: [String] = []
        if isPlanModeActive(for: key) {
            blocks.append("【规划模式 · 只看不动】当前对话处于只读规划模式：你只能阅读资料、搜索信息、向用户提普通澄清问题（不可采集机密或密码表单）并用 update_plan 维护步骤方案；禁止写/改/删文件、运行命令/脚本、修改记忆或调用第三方 MCP。请先给出清晰可执行的方案，等用户点击「按此方案执行」后再开始动手。")
        }
        let off = options(key).off.compactMap(Grant.init(rawValue:))
        if !off.isEmpty {
            blocks.append("在这段絮语里，用户关掉了这些本事：" + off.map(\.title).joined(separator: "、") + "。需要用到时，告诉用户可以在输入框下的「本事」里打开，不要假装做了。")
        }
        guard !blocks.isEmpty else { return "" }
        return "\n\n" + blocks.joined(separator: "\n\n")
    }
}
