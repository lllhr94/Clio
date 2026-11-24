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
    // MARK: Rows

    var empty: some View {
        VStack(spacing: Ink.Space.l) {
            PetStill(size: 96, state: petState, bot: isRoom ? nil : bot)
            if isRoom {
                Text(L.t("empty.groupChat"))
                    .font(Ink.reading)
                    .foregroundStyle(Ink.inkSoft)
            } else {
                Inscription(text: L.t("empty.inscription"))
            }
            VStack(spacing: Ink.Space.s) {
                ForEach(starters, id: \.0) { item in
                    Button {
                        Haptics.light()
                        draft = item.1
                        typing = true
                    } label: {
                        HStack(spacing: Ink.Space.m) {
                            Image(systemName: item.2).font(.system(size: Ink.Size.sub)).foregroundStyle(Ink.accent).frame(width: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.0).font(.system(size: Ink.Size.sub, weight: .medium)).foregroundStyle(Ink.ink)
                                Text(item.1).font(Ink.footnote).foregroundStyle(Ink.inkSoft).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, Ink.Space.l)
                        .padding(.vertical, Ink.Space.m)
                        .paperCard()
                    }
                    .buttonStyle(PressStyle())
                }
            }
            .padding(.top, Ink.Space.m)
            Text(Words.t(reach))
                .font(Ink.footnote)
                .foregroundStyle(Ink.inkFaint)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 72)
    }

    /// The pages the steps right before this reply read or found, for a row of sources under it.
    /// A reply without the 「来源：」 (or 参考 / Sources) list of links some models write at the very end.
    @MainActor static var trimmedCache: [String: String] = [:]

    @MainActor static func withoutSourceList(_ text: String) -> String {
        if let known = trimmedCache[text] { return known }
        let trimmed = trimSourceList(text)
        if trimmedCache.count > 400 { trimmedCache.removeAll() }
        trimmedCache[text] = trimmed
        return trimmed
    }

    static func trimSourceList(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        // One line at the end, 「来源：[甲](…)、[乙](…)」: only links after the colon.
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        if let last = lines.last?.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "*", with: ""),
           let colon = last.firstIndex(where: { $0 == "：" || $0 == ":" }),
           ["来源", "参考来源", "参考资料", "参考", "资料来源", "信息来源", "Sources", "References"].contains(String(last[..<colon]).trimmingCharacters(in: .whitespaces)) {
            let rest = last[last.index(after: colon)...]
            let bare = rest.replacingOccurrences(of: #"\[[^\]]*\]\([^)]*\)|https?://\S+"#, with: "", options: .regularExpression)
            if rest.contains("http"), bare.trimmingCharacters(in: CharacterSet(charactersIn: " 、，,;；。.")).isEmpty {
                return lines.dropLast().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        let heads = ["来源", "参考来源", "参考资料", "参考", "资料来源", "信息来源", "Sources", "References"]
        guard let start = lines.lastIndex(where: { raw in
            let bare = raw.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "*#：: "))
            return heads.contains(bare)
        }) else { return text }
        // Only if everything after it is links (or blank): otherwise it is part of the answer.
        let rest = lines[(start + 1)...]
        let onlyLinks = rest.allSatisfy { row in
            let bare = row.trimmingCharacters(in: .whitespaces)
            return bare.isEmpty || bare.contains("http") || bare.contains("](")
        }
        guard onlyLinks, rest.contains(where: { $0.contains("http") || $0.contains("](") }) else { return text }
        return lines[..<start].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Worked out once per reply: the steps before a reply do not change after it, and every reply asked on every
    /// redraw (twice), walking back through the chat each time.
    final class SourcesMemo {
        var found: [String: [URL]] = [:]
    }

    func sources(for line: ChatLine) -> [URL] {
        let memoKey = line.id + "|\(line.text.count)"
        if let known = sourcesMemo.found[memoKey] { return known }
        let found = findSources(for: line)
        if sourcesMemo.found.count > 600 { sourcesMemo.found.removeAll() }
        sourcesMemo.found[memoKey] = found
        return found
    }

    func findSources(for line: ChatLine) -> [URL] {
        guard let index = displayedRows.firstIndex(where: { $0.id == line.id }) else { return [] }
        // The pages the answer itself names come first: they are what it rests on.
        var urls: [URL] = SourcesRow.cited(in: line.text).map(\.url)
        var cursor = index - 1
        while cursor >= 0, displayedRows[cursor].kind == .steps {
            let step = displayedRows[cursor]
            for (position, label) in step.tools.enumerated() {
                let isSearch = label.hasPrefix("搜索") || label.hasPrefix("寻访")
                let isRead = label.hasPrefix("读网页") || Trace.canonicalKind(of: label) == "远游"
                guard isSearch || isRead, position < step.details.count else { continue }
                // Pages it read count first; then what a search brought back.
                let text = isSearch ? step.details[position].output : step.details[position].input
                for match in text.matches(of: #/https?://[^\s"'<>()\[\]，。]+/#) {
                    if let url = URL(string: String(match.output)), url.host != nil, !SourcesRow.isSearchPage(url), !urls.contains(url) { urls.append(url) }
                }
            }
            cursor -= 1
        }
        return Array(urls.prefix(8))
    }

    /// What this conversation can reach, in one line: 「在书案干活 · 能联网 · 远山 jp-1」.
    var reach: String {
        let off = Set(options.off)
        func on(_ grant: Grant) -> Bool { grant.policy != .off && !off.contains(grant.rawValue) }
        var parts = ["在\(team.place(of: chat.key).title)干活"]
        if on(.web) { parts.append("能联网") }
        if on(.browser) { parts.append(Words.t("能用远游")) }
        if !Hills.shared.hosts.isEmpty, on(.hills) { parts.append(Words.t("连得上 \(Hills.shared.hosts.count) 台远山")) }
        if on(.memory) { parts.append("记得你说过的事") }
        return parts.joined(separator: " · ")
    }

    /// Ways to begin, only for abilities this conversation has.
    var starters: [(String, String, String)] {
        let off = Set(options.off)
        var out: [(String, String, String)] = []
        func on(_ grant: Grant) -> Bool { grant.policy != .off && !off.contains(grant.rawValue) }
        if on(.calendar) { out.append(("看看日程", "我今天和明天有什么安排？", "calendar")) }
        if on(.web) { out.append(("查点东西", "帮我查一下最近附近有什么值得去的展览", "magnifyingglass")) }
        if on(.location) { out.append(("看看附近", "我现在在哪？附近有什么好吃的", "location")) }
        if on(.den) { out.append((Words.t("在斗室算一算"), "在斗室里用 Python 算一下：每月存 2000，年化 3%，十年后有多少", "terminal")) }
        if on(.desk) { out.append((Words.t("记到书案"), "帮我在书案里建一份本周待办清单", "books.vertical")) }
        out.append(("问问它会什么", "你能帮我做哪些事？挑几样有意思的说说", "sparkles"))
        return Array(out.prefix(5))
    }

    @ViewBuilder
    func row(_ line: ChatLine) -> some View {
        switch line.kind {
        case .user:
            VStack(alignment: .trailing, spacing: Ink.Space.s) {
                if !line.refs.isEmpty {
                    HStack(spacing: Ink.Space.s) {
                        ForEach(line.refs, id: \.self) { ref in
                            Button { viewing = ref } label: {
                                RemotePhoto(chat: chat, attachmentId: ref)
                                    .frame(width: 72, height: 72)
                                    .clipShape(.rect(cornerRadius: Ink.Radius.small, style: .continuous))
                            }
                            .buttonStyle(PressStyle())
                        }
                    }
                }
                if !line.text.isEmpty {
                    Text(line.text)
                        .font(.system(size: Ink.Size.body))
                        .foregroundStyle(Ink.ink)
                        .lineSpacing(4)
                        .padding(.horizontal, Ink.Space.l)
                        .padding(.vertical, 10 * UIScale.factor)
                        // Real Liquid Glass, as Open Minis does: your bubbles scroll over replies, code and pictures,
                        // so the glass has something to catch. Tinted a little with the paper, so it stays Clio's.
                        .glassEffect(.regular.tint(bubbleTint(editing: editing == line.id)),
                                     in: .rect(cornerRadius: Ink.Radius.card, style: .continuous))
                        .contentShape(.contextMenuPreview, .rect(cornerRadius: Ink.Radius.card, style: .continuous))
                        .contextMenu {
                            Button("复制", systemImage: "doc.on.doc") { UIPasteboard.general.string = line.text }
                            // Your own words too can be picked from and quoted, as replies can.
                            Button("选字引用", systemImage: "text.quote") { quoting = Noting(id: line.id, text: line.text) }
                            Button("改了重发", systemImage: "pencil") {
                                withAnimation(Ink.Motion.settle) {
                                    editing = line.id
                                    draft = line.text
                                }
                                typing = true
                            }
                        }
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, Ink.Space.huge)
        case .bot:
            VStack(alignment: .leading, spacing: Ink.Space.m) {
                if let reasoning = line.reasoning, Pref.showThinking {
                    ThinkingBox(text: reasoning)
                }
                if let felt = line.pulse {
                    PulseBox(text: felt, temper: Temper.of(line.speaker.flatMap { id in team.bots.first { $0.id == id } } ?? (isRoom ? nil : bot)))
                }
                let writing = chat.fresh?.id == line.id ? chat.fresh?.shown : nil
                let found = writing == nil ? sources(for: line) : []
                if let shown = writing {
                    StreamingProse(text: String(line.text.prefix(shown)))
                } else {
                    // Long-press selects words (across paragraphs); what the old long-press menu had is behind ⋯ under the reply.
                    // When the sources row is under it, a 「来源：」 list the model wrote at the end is not shown twice.
                    let shown = found.isEmpty ? line.text : Self.withoutSourceList(line.text)
                    let looked = Self.lookback(shown)
                    // 「回望：…」 the companion wrote after its steps: a quiet line of its own, like 心绪, not body text.
                    if let note = looked.note { LookbackLine(text: note) }
                    SelectableProse(text: looked.rest)
                        .equatable()
                }
                if !found.isEmpty {
                    SourcesRow(urls: found, titles: SourcesRow.titles(in: line.text)) { url in
                        typing = false
                        Task { await team.browser.open(url) }
                        roaming = true
                    }
                }
                // The same row under every reply: copy, ⋯; the newest also 重来 and its numbers.
                let newest = line.id == chat.lines.last(where: { $0.kind == .bot })?.id
                if writing == nil, hitStepLimit(line) {
                    continueStepLimitButton
                }
                // Only under the last words of a turn: a short 「先造钥匙。」 before the steps gets no row of its own.
                if writing == nil, newest ? !working : endsTurn(line) {
                    footer(line, newest: newest)
                        .transition(.opacity)
                }
            }
        case .steps:
            Trace(line: line, visit: { url in
                typing = false
                Task { await team.browser.open(url) }
                roaming = true
            }, openFile: { url, mount in
                reading = ReadingFile(url: url, mount: mount)
            }, unremember: { id, fact in
                team.unremember(id, fact: fact)
            })
        case .note:
            if line.fold {
                foldLine(line)
            } else if let next = line.next {
                trouble(line, next: next)
            } else {
                Text(line.text)
                    .font(Ink.footnote)
                    .foregroundStyle(Ink.inkFaint)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    private static let stepLimitNotice = "（这件事步骤太多，我先停在这里。要我接着做就说一声。）"

    private func hitStepLimit(_ line: ChatLine) -> Bool {
        guard historyPage == nil, !working, !sendingBlocked, chat.lines.last?.id == line.id else { return false }
        return line.text.trimmingCharacters(in: .whitespacesAndNewlines) == Self.stepLimitNotice
    }

    private var continueStepLimitButton: some View {
        Button {
            Haptics.light()
            following = true
            _ = chat.send(L.t("chat.continuePrompt"), photos: [])
        } label: {
            HStack(spacing: Ink.Space.xs) {
                Image(systemName: "play.fill")
                    .font(.system(size: Ink.Size.micro, weight: .semibold))
                Text(L.t("chat.continueTask"))
                    .font(.system(size: Ink.Size.sub, weight: .semibold))
            }
            .foregroundStyle(Ink.accent)
            .padding(.horizontal, Ink.Space.l)
            .frame(height: 34)
            .background(Ink.accentWash, in: .capsule)
        }
        .buttonStyle(PressStyle(haptic: false))
    }
}
