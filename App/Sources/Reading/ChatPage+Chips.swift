import AVFoundation
import AgentKit
import CoreLocation
import Craft
import PhotosUI
import Observation
import SwiftUI
import UniformTypeIdentifiers
import VisionKit

extension ChatPage {
    // MARK: Composer chips

    var options: TeamModel.ChatOptions { team.options(chat.key) }

    /// A chip in the row under the text field. Lit when what it stands for is on.
    func chip(_ icon: String, _ name: String?, lit: Bool = false) -> some View {
        ChatChipLabel(icon: icon, name: name, lit: lit)
    }

    /// One line under the composer saying what just changed; it goes away by itself.
    func say(_ text: String) {
        Self.postComposerNotice(text, to: notice)
    }

    static func postComposerNotice(_ text: String, to notice: ChatComposerNotice, symbol: String? = nil, tint: Color = Ink.ink) {
        notice.text = nil
        ToastCenter.shared.show(text, symbol: symbol, tint: tint)
    }

    var modelSpeaker: BotInfo { Self.speakerForModel(in: chat, team: team, fallback: bot) }

    static func speakerForModel(in chat: ChatModel, team: TeamModel, fallback: BotInfo) -> BotInfo {
        chat.roomId != nil ? (team.alwaysOnTurn(chat.key).bot ?? fallback) : fallback
    }

    /// Strips routing prefixes, date stamps, and noisy suffixes into compact readable model badges.
    static func shortModelName(_ raw: String) -> String {
        Endpoint.shortName(raw)
    }

    var modelPillMaxWidth: CGFloat {
        Self.modelPillMaxWidth(viewportWidth: chatViewport.width, team: team)
    }

    static func modelPillMaxWidth(viewportWidth: CGFloat, team: TeamModel) -> CGFloat {
        let width = viewportWidth > 0 ? viewportWidth : 390
        let browser = team.browser.acting ? Ink.Bar.height + Ink.Space.xs : 0
        return max(84, min(174, (width - browser) * 0.42))
    }

    var modelMenu: some View {
        modelMenu(compact: false)
    }

    @ViewBuilder
    func modelMenu(compact: Bool) -> some View {
        ChatModelMenuView(
            chat: chat,
            team: team,
            bot: bot,
            notice: notice,
            viewportWidth: chatViewport.width,
            compact: compact
        )
    }

    func selectModel(_ reference: String?) {
        Self.selectModel(reference, in: chat, team: team, bot: bot, notice: notice)
    }

    static func selectModel(_ reference: String?, in chat: ChatModel, team: TeamModel, bot: BotInfo, notice: ChatComposerNotice) {
        Haptics.selection()
        team.setModel(reference, in: chat.key)
        // Preserve the user's saved `ThinkingSelection` across model switches (never destructively wipe to `.auto`).
        let speaker = speakerForModel(in: chat, team: team, fallback: bot)
        if let current = team.current(chat.key, bot: speaker) {
            let displayName = current.endpoint.distinguishableDisplayName(for: current.model)
            postComposerNotice(L.format("chatHub.modelSwitched", displayName), to: notice, symbol: "sparkles")
        }
    }

    var offeredThinkingSelections: [ThinkingSelection] {
        Self.offeredThinkingSelections(in: chat, team: team, fallback: bot)
    }

    static func offeredThinkingSelections(in chat: ChatModel, team: TeamModel, fallback: BotInfo) -> [ThinkingSelection] {
        team.offeredThinkingSelections(in: chat.key, roomId: chat.roomId, fallback: fallback)
    }

    var offeredThinking: [Thinking] {
        Self.offeredThinkingLevels(in: chat, team: team, fallback: bot)
    }

    static func offeredThinkingLevels(in chat: ChatModel, team: TeamModel, fallback: BotInfo) -> [Thinking] {
        let selections = offeredThinkingSelections(in: chat, team: team, fallback: fallback)
        var levels: [Thinking] = [.auto]
        for selection in selections {
            if let legacy = selection.legacyMirror, !levels.contains(legacy) {
                levels.append(legacy)
            }
        }
        return levels
    }

    var thinkingChoices: some View {
        ChatThinkingChoicesSection(chat: chat, team: team, bot: bot, notice: notice)
    }

    /// Where this conversation works: 书案, 斗室 or a 远山 host.
    var placeChip: some View {
        ChatPlaceChipView(chatKey: chat.key, team: team, notice: notice)
    }
}

struct ChatChipLabel: View {
    let icon: String
    let name: String?
    var lit: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: Ink.Size.small, weight: .medium))
            if let name { Text(name).font(.system(size: Ink.Size.small, weight: .medium)).lineLimit(1) }
        }
        .foregroundStyle(lit ? Ink.accent : Ink.inkSoft)
        .padding(.horizontal, name == nil ? 0 : Ink.Space.m)
        .frame(minWidth: 32, minHeight: 32)
        .background(lit ? Ink.accentWash : Color.clear, in: .capsule)
        .overlay(Capsule().strokeBorder(lit ? Color.clear : Ink.rule, lineWidth: 1))
        .contentShape(.capsule)
    }
}

struct ChatThinkingChoicesSection: View {
    let chat: ChatModel
    @ObservedObject var team: TeamModel
    let bot: BotInfo
    let notice: ChatComposerNotice

    var body: some View {
        let saved = team.options(chat.key).effectiveThinkingSelection
        let offered = ChatPage.offeredThinkingSelections(in: chat, team: team, fallback: bot)
        let unfulfilled = !saved.isDefault && !offered.contains(saved)
        Section(L.t("chat.thinking")) {
            if unfulfilled {
                Button {} label: {
                    Label("已保留：\(saved.title)（当前模型暂不支持）", systemImage: "exclamationmark.circle")
                    Text("切换回支持的模型会自动恢复，或下方另选一档。")
                }
                .disabled(true)
            }
            ForEach(offered, id: \.stableID) { option in
                Button {
                    Haptics.tick(0.5)
                    team.setThinkingSelection(option, in: chat.key)
                    ChatPage.postComposerNotice(
                        option.isDefault ? "思考强度交给模型自己定。" : "思考强度：\(option.title)。\(option.line)。",
                        to: notice
                    )
                } label: {
                    Label(option.title, systemImage: option == saved ? "checkmark" : option.symbol)
                    Text(option.line)
                }
            }
        }
    }
}

struct ChatModelMenuView: View {
    let chat: ChatModel
    @ObservedObject var team: TeamModel
    let bot: BotInfo
    let notice: ChatComposerNotice
    let viewportWidth: CGFloat
    let compact: Bool

    var body: some View {
        let isRoom = chat.roomId != nil
        let options = team.options(chat.key)
        let own = team.resolveActive(options.model) != nil ? options.model : nil
        let speaker = ChatPage.speakerForModel(in: chat, team: team, fallback: bot)
        let rawName = team.current(chat.key, bot: speaker)?.model ?? L.t("settings.models")
        let labelName = compact ? ChatPage.shortModelName(rawName) : rawName
        let offered = ChatPage.offeredThinkingSelections(in: chat, team: team, fallback: bot)
        let saved = options.effectiveThinkingSelection
        let isRealizable = offered.contains(saved)
        let maxPillWidth = ChatPage.modelPillMaxWidth(viewportWidth: viewportWidth, team: team)
        if isRoom && offered.count <= 1 && saved.isDefault {
            HStack(spacing: Ink.Space.xs) {
                Text(labelName)
                    .font(Ink.mono(Ink.Size.micro, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundStyle(Ink.inkSoft)
            .padding(.leading, compact ? Ink.Space.m : Ink.Space.s)
            .padding(.trailing, Ink.Space.s)
            .frame(minHeight: Ink.Bar.height)
            .frame(maxWidth: compact ? maxPillWidth : nil, alignment: .leading)
            .accessibilityLabel("\(L.t("settings.models"))：\(rawName)")
        } else {
            Menu {
                ChatThinkingChoicesSection(chat: chat, team: team, bot: bot, notice: notice)
                if !isRoom {
                    Section(L.t("settings.models")) {
                        Button {
                            ChatPage.selectModel(nil, in: chat, team: team, bot: bot, notice: notice)
                        } label: {
                            let label = "跟着\(bot.name)走"
                            if own == nil { Label(label, systemImage: "checkmark") } else { Text(label) }
                        }
                    }
                    ModelChoices(team: team, current: own) { ref in
                        ChatPage.selectModel(ref, in: chat, team: team, bot: bot, notice: notice)
                    }
                }
            } label: {
                HStack(spacing: Ink.Space.xs) {
                    Text(labelName)
                        .font(Ink.mono(Ink.Size.micro, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if !saved.isDefault {
                        Image(systemName: saved.symbol)
                            .font(.system(size: Ink.Size.micro, weight: .medium))
                            .foregroundStyle(isRealizable ? Ink.accent : Ink.warn)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: Ink.Size.micro, weight: .semibold))
                        .foregroundStyle(Ink.inkFaint)
                        .scaleEffect(0.82)
                }
                .foregroundStyle(Ink.inkSoft)
                .padding(.leading, compact ? Ink.Space.m : Ink.Space.s)
                .padding(.trailing, Ink.Space.s)
                .frame(minHeight: Ink.Bar.height)
                .frame(maxWidth: compact ? maxPillWidth : nil, alignment: .leading)
                .contentShape(Rectangle())
            }
            .menuOrder(.fixed)
            .accessibilityLabel("\(L.t("settings.models"))：\(rawName)")
            .accessibilityValue("\(L.t("chat.thinking"))：\(level.title)")
        }
    }
}

struct ChatPlaceChipView: View {
    let chatKey: String
    @ObservedObject var team: TeamModel
    let notice: ChatComposerNotice
    @ObservedObject private var hills = Hills.shared

    var body: some View {
        let current = team.place(of: chatKey)
        Menu {
            Section(Words.t("这段絮语在哪里干活")) {
                placeButton(.desk, current: current, line: "手机里的文件夹，读写文件、算数")
                placeButton(.den, current: current, line: "手机里的 Linux，能跑命令、装软件")
                ForEach(hills.hosts) { host in
                    placeButton(.hill(host.id), current: current, line: "\(host.user)@\(host.address)")
                }
            }
            if hills.hosts.isEmpty {
                Section { Text(Words.t("在设置 › 远山 添一台主机，这里就能选它。")) }
            }
        } label: {
            ChatChipLabel(icon: current.symbol, name: nil, lit: current != .desk)
        }
        .accessibilityLabel("工作地点：\(current.title)")
    }

    private func placeButton(_ place: WorkPlace, current: WorkPlace, line: String) -> some View {
        Button {
            Haptics.tick(0.5)
            team.setPlace(place, in: chatKey)
            switch place {
            case .desk: ChatPage.postComposerNotice(Words.t("回到书案：文件放在手机的书案里，不跑命令。"), to: notice)
            case .den: ChatPage.postComposerNotice(Words.t("在斗室干活：旅伴会在手机里的 Linux 跑命令，文件放在 /root/desk。"), to: notice)
            case .hill: ChatPage.postComposerNotice("在\(place.title)干活：命令和文件都在那台电脑上。", to: notice)
            }
        } label: {
            if current == place {
                Label(place.title, systemImage: "checkmark")
            } else {
                Text(place.title)
            }
            Text(line)
        }
    }
}
