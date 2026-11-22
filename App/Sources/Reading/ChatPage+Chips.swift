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

    /// One line under the composer saying what just changed; it goes away by itself.
    func say(_ text: String) {
        withAnimation(Ink.Motion.settle) { hint = text }
        let said = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
            if hint == said { withAnimation(Ink.Motion.settle) { hint = nil } }
        }
    }

    var modelSpeaker: BotInfo { isRoom ? team.alwaysOnTurn(chat.key).bot ?? bot : bot }

    var modelMenu: some View {
        let own = options.model
        let name = team.current(chat.key, bot: modelSpeaker)?.model ?? L.t("settings.models")
        let level = options.thinking ?? .auto
        return Menu {
            thinkingChoices
            if !isRoom {
                Section(L.t("settings.models")) {
                    Button {
                        selectModel(nil)
                    } label: {
                        let label = "跟着\(bot.name)走"
                        if own == nil { Label(label, systemImage: "checkmark") } else { Text(label) }
                    }
                }
                ModelChoices(team: team, current: own) { ref in selectModel(ref) }
            }
        } label: {
            HStack(spacing: Ink.Space.xs) {
                Text(name)
                    .font(Ink.mono(Ink.Size.micro))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if level != .auto {
                    Image(systemName: level.symbol)
                        .font(.system(size: Ink.Size.micro, weight: .medium))
                        .foregroundStyle(Ink.accent)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: Ink.Size.micro, weight: .medium))
            }
            .foregroundStyle(Ink.inkSoft)
            .padding(.horizontal, Ink.Space.s)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .menuOrder(.fixed)
        .accessibilityLabel("\(L.t("settings.models"))：\(name)")
        .accessibilityValue("\(L.t("chat.thinking"))：\(level.title)")
    }

    func selectModel(_ reference: String?) {
        Haptics.tick(0.5)
        team.setModel(reference, in: chat.key)
        resetUnavailableThinking(in: offeredThinking)
        if let current = team.current(chat.key, bot: modelSpeaker) {
            let sight = current.traits.sees ? "能看图" : "不能看图，发的照片会改用 photo_text 读字"
            say(Words.t("这段絮语用 \(current.model)（\(sight)），别处的絮语不变。"))
        }
    }

    func resetUnavailableThinking(in offered: [Thinking]) {
        if let selection = options.thinking, !offered.contains(selection) {
            team.setThinking(.auto, in: chat.key)
        }
    }

    var offeredThinking: [Thinking] {
        let speakers: [BotInfo]
        if let roomID = chat.roomId, options.model == nil,
           let members = team.rooms.first(where: { $0.id == roomID })?.members, !members.isEmpty {
            speakers = members.compactMap { id in team.bots.first { $0.id == id } }
        } else {
            speakers = [modelSpeaker]
        }
        guard !speakers.isEmpty else { return [.auto] }
        return speakers.reduce(Thinking.allCases) { offered, speaker in
            guard let current = team.current(chat.key, bot: speaker) else { return [.auto] }
            let levels: [Thinking]
            if let tested = current.traits.levels {
                levels = [.auto] + tested.compactMap(Thinking.init(rawValue:))
            } else if current.endpoint.kind == .openai {
                levels = current.endpoint.thinkingStyle.levels(thinks: current.traits.thinks)
            } else {
                levels = current.traits.thinks ? Thinking.allCases : [.auto]
            }
            return offered.filter { levels.contains($0) }
        }
    }

    var thinkingChoices: some View {
        let level = options.thinking ?? .auto
        return Section(L.t("chat.thinking")) {
            ForEach(offeredThinking, id: \.self) { option in
                Button {
                    Haptics.tick(0.5)
                    team.setThinking(option, in: chat.key)
                    say(option == .auto ? "思考强度交给模型自己定。" : "思考强度：\(option.title)。\(option.line)。")
                } label: {
                    Label(option.title, systemImage: option == level ? "checkmark" : option.symbol)
                    Text(option.line)
                }
            }
        }
    }

    /// Where this conversation works: 书案, 斗室 or a 远山 host.
    var placeChip: some View {
        let current = team.place(of: chat.key)
        return Menu {
            Section(Words.t("这段絮语在哪里干活")) {
                placeButton(.desk, line: "手机里的文件夹，读写文件、算数")
                placeButton(.den, line: "手机里的 Linux，能跑命令、装软件")
                ForEach(Hills.shared.hosts) { host in
                    placeButton(.hill(host.id), line: "\(host.user)@\(host.address)")
                }
            }
            if Hills.shared.hosts.isEmpty {
                Section { Text(Words.t("在设置 › 远山 添一台主机，这里就能选它。")) }
            }
        } label: {
            chip(current.symbol, nil, lit: current != .desk)
        }
        .accessibilityLabel("工作地点：\(current.title)")
    }

    func placeButton(_ place: WorkPlace, line: String) -> some View {
        let current = team.place(of: chat.key)
        return Button {
            Haptics.tick(0.5)
            team.setPlace(place, in: chat.key)
            switch place {
            case .desk: say(Words.t("回到书案：文件放在手机的书案里，不跑命令。"))
            case .den: say(Words.t("在斗室干活：旅伴会在手机里的 Linux 跑命令，文件放在 /root/desk。"))
            case .hill: say("在\(place.title)干活：命令和文件都在那台电脑上。")
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
