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

    static func postComposerNotice(_ text: String, to notice: ChatComposerNotice) {
        withAnimation(Ink.Motion.settle) { notice.text = text }
        let said = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
            if notice.text == said { withAnimation(Ink.Motion.settle) { notice.text = nil } }
        }
    }

    var modelSpeaker: BotInfo { Self.speakerForModel(in: chat, team: team, fallback: bot) }

    static func speakerForModel(in chat: ChatModel, team: TeamModel, fallback: BotInfo) -> BotInfo {
        chat.roomId != nil ? (team.alwaysOnTurn(chat.key).bot ?? fallback) : fallback
    }

    /// Strips routing prefixes, date stamps, and noisy suffixes into compact readable model badges.
    static func shortModelName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return raw }
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

    var modelPillMaxWidth: CGFloat {
        Self.modelPillMaxWidth(viewportWidth: chatViewport.width, team: team)
    }

    static func modelPillMaxWidth(viewportWidth: CGFloat, team: TeamModel) -> CGFloat {
        let width = viewportWidth > 0 ? viewportWidth : 390
        let browser = team.browser.acting ? Ink.Bar.height + Ink.Space.xs : 0
        return max(68, min(138, (width - 176 - browser) * 0.46))
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
        Haptics.tick(0.5)
        team.setModel(reference, in: chat.key)
        let offered = offeredThinkingLevels(in: chat, team: team, fallback: bot)
        if let selection = team.options(chat.key).thinking, !offered.contains(selection) {
            team.setThinking(.auto, in: chat.key)
        }
        let speaker = speakerForModel(in: chat, team: team, fallback: bot)
        if let current = team.current(chat.key, bot: speaker) {
            let sight = current.traits.sees ? "能看图" : "不能看图，发的照片会改用 photo_text 读字"
            postComposerNotice(Words.t("这段絮语用 \(current.model)（\(sight)），别处的絮语不变。"), to: notice)
        }
    }

    func resetUnavailableThinking(in offered: [Thinking]) {
        if let selection = options.thinking, !offered.contains(selection) {
            team.setThinking(.auto, in: chat.key)
        }
    }

    var offeredThinking: [Thinking] {
        Self.offeredThinkingLevels(in: chat, team: team, fallback: bot)
    }

    static func offeredThinkingLevels(in chat: ChatModel, team: TeamModel, fallback: BotInfo) -> [Thinking] {
        let options = team.options(chat.key)
        let speakers: [BotInfo]
        if let roomID = chat.roomId, options.model == nil,
           let members = team.rooms.first(where: { $0.id == roomID })?.members, !members.isEmpty {
            speakers = members.compactMap { id in team.bots.first { $0.id == id } }
        } else {
            speakers = [speakerForModel(in: chat, team: team, fallback: fallback)]
        }
        guard !speakers.isEmpty else { return [.auto] }
        return speakers.reduce(Thinking.allCases) { offered, speaker in
            guard let current = team.current(chat.key, bot: speaker) else { return [.auto] }
            let levels: [Thinking]
            if !current.traits.thinks {
                levels = [.auto]
            } else if let tested = current.traits.levels {
                let parsed = tested.compactMap(Thinking.init(rawValue:)).filter { $0 != .auto }
                levels = [.auto] + parsed
            } else if current.endpoint.kind == .openai {
                levels = current.endpoint.thinkingStyle.levels(thinks: true)
            } else {
                levels = Thinking.allCases
            }
            return offered.filter { levels.contains($0) }
        }
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
        let level = team.options(chat.key).thinking ?? .auto
        let offered = ChatPage.offeredThinkingLevels(in: chat, team: team, fallback: bot)
        Section(L.t("chat.thinking")) {
            ForEach(offered, id: \.self) { option in
                Button {
                    Haptics.tick(0.5)
                    team.setThinking(option, in: chat.key)
                    ChatPage.postComposerNotice(
                        option == .auto ? "思考强度交给模型自己定。" : "思考强度：\(option.title)。\(option.line)。",
                        to: notice
                    )
                } label: {
                    Label(option.title, systemImage: option == level ? "checkmark" : option.symbol)
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
        let offered = ChatPage.offeredThinkingLevels(in: chat, team: team, fallback: bot)
        let level = offered.contains(options.thinking ?? .auto) ? (options.thinking ?? .auto) : .auto
        let maxPillWidth = ChatPage.modelPillMaxWidth(viewportWidth: viewportWidth, team: team)
        if isRoom && offered.count <= 1 {
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
                    if level != .auto {
                        Image(systemName: level.symbol)
                            .font(.system(size: Ink.Size.micro, weight: .medium))
                            .foregroundStyle(Ink.accent)
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
