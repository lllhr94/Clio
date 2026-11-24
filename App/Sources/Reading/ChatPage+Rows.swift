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

    func emptyStateView(isWorking: Bool, isListening: Bool) -> some View {
        let state: String
        if waiting != nil { state = "notification" }
        else if chat.hasStreaming || doing == "正在回复" { state = "working" }
        else if isWorking || typing || isListening { state = "thinking" }
        else if idleMood.cheering { state = "attention" }
        else if idleMood.dozing { state = "sleeping" }
        else { state = "idle" }
        return VStack(spacing: Ink.Space.l) {
            PetStill(size: 96, state: state, bot: isRoom ? nil : bot)
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

    var empty: some View {
        emptyStateView(isWorking: working, isListening: dictationSlot.instance?.listening == true)
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

    nonisolated static func trimSourceList(_ text: String) -> String {
        ProseTextTransforms.trimSourceList(text)
    }

    /// Worked out once per reply and once per row-array snapshot: avoids O(N²) scans and full-string hashing on redraw.
    final class SourcesMemo {
        struct LineMeta: Equatable {
            let urls: [URL]
            let titles: [URL: String]
            let trimmedText: String
        }

        var meta: [String: LineMeta] = [:]

        private var cachedRows: [ChatLine] = []
        private var cachedBotId: String = ""
        private(set) var indexById: [String: Int] = [:]
        private(set) var openers: Set<String> = []
        private(set) var turnEnds: Set<String> = []
        private(set) var newestBotId: String?

        func sync(rows: [ChatLine], defaultBotId: String) {
            let same = cachedBotId == defaultBotId
                && rows.count == cachedRows.count
                && rows.withUnsafeBufferPointer { current in
                    cachedRows.withUnsafeBufferPointer { kept in
                        current.baseAddress == kept.baseAddress
                    }
                }
            if same { return }
            cachedRows = rows
            cachedBotId = defaultBotId
            indexById.removeAll(keepingCapacity: true)
            openers.removeAll(keepingCapacity: true)
            turnEnds.removeAll(keepingCapacity: true)
            newestBotId = nil

            var lastVoice: String?
            for index in rows.indices {
                let line = rows[index]
                indexById[line.id] = index
                let voice: String?
                switch line.kind {
                case .user: voice = "me"
                case .bot, .steps: voice = "bot:" + (line.speaker ?? defaultBotId)
                case .note: voice = nil
                }
                if let voice {
                    if voice != lastVoice { openers.insert(line.id) }
                    lastVoice = voice
                }
                if line.kind == .bot { newestBotId = line.id }
            }

            var nextSpeaker: String?
            var seenUserAfter = true
            for index in rows.indices.reversed() {
                let line = rows[index]
                switch line.kind {
                case .user:
                    seenUserAfter = true
                    nextSpeaker = nil
                case .bot:
                    if seenUserAfter || nextSpeaker != line.speaker {
                        turnEnds.insert(line.id)
                    }
                    seenUserAfter = false
                    nextSpeaker = line.speaker
                case .steps, .note:
                    break
                }
            }
        }
    }

    func lineMeta(for line: ChatLine) -> SourcesMemo.LineMeta {
        let memoKey = line.id + "|\(line.text.utf8.count)"
        if let known = sourcesMemo.meta[memoKey] { return known }
        let rows = displayedRows
        sourcesMemo.sync(rows: rows, defaultBotId: bot.id)
        let cited = SourcesRow.cited(in: line.text)
        var urls = cited.map(\.url)
        if let index = sourcesMemo.indexById[line.id] {
            var cursor = index - 1
            while cursor >= 0, rows[cursor].kind == .steps {
                let step = rows[cursor]
                for (position, label) in step.tools.enumerated() {
                    let isSearch = label.hasPrefix("搜索") || label.hasPrefix("寻访")
                    let isRead = label.hasPrefix("读网页") || Trace.canonicalKind(of: label) == "远游"
                    guard isSearch || isRead, position < step.details.count else { continue }
                    // Pages it read count first; then what a search brought back.
                    let text = isSearch ? step.details[position].output : step.details[position].input
                    guard text.contains("http") else { continue }
                    for match in text.matches(of: #/https?://[^\s"'<>()\[\]，。]+/#) {
                        if let url = URL(string: String(match.output)), url.host != nil, !SourcesRow.isSearchPage(url), !urls.contains(url) { urls.append(url) }
                    }
                }
                cursor -= 1
            }
        }
        let found = Array(urls.prefix(8))
        let titles = Dictionary(cited.map { ($0.url, $0.title) }, uniquingKeysWith: { first, _ in first })
        let trimmed = found.isEmpty ? line.text : Self.trimSourceList(line.text)
        let computed = SourcesMemo.LineMeta(urls: found, titles: titles, trimmedText: trimmed)
        if sourcesMemo.meta.count > 600 { sourcesMemo.meta.removeAll() }
        sourcesMemo.meta[memoKey] = computed
        return computed
    }

    func sources(for line: ChatLine) -> [URL] {
        lineMeta(for: line).urls
    }

    var latestBotId: String? {
        if historyPage == nil {
            sourcesMemo.sync(rows: displayedRows, defaultBotId: bot.id)
            return sourcesMemo.newestBotId
        }
        return chat.lines.last(where: { $0.kind == .bot })?.id
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
                    let isEditing = editing == line.id
                    Text(line.text)
                        .font(.system(size: Ink.Size.body))
                        .foregroundStyle(Ink.ink)
                        .lineSpacing(4)
                        .padding(.horizontal, Ink.Space.l)
                        .padding(.vertical, 10 * UIScale.factor)
                        .glassBubble(in: RoundedRectangle(cornerRadius: Ink.Radius.card, style: .continuous),
                                     tint: bubbleTint(editing: isEditing))
                        .overlay {
                            if isEditing {
                                RoundedRectangle(cornerRadius: Ink.Radius.card, style: .continuous)
                                    .strokeBorder(Ink.accent, lineWidth: 1.5)
                            }
                        }
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
                let meta = writing == nil ? lineMeta(for: line) : nil
                let found = meta?.urls ?? []
                if let shown = writing {
                    StreamingProse(text: String(line.text.prefix(shown)))
                } else {
                    // Long-press selects words (across paragraphs); what the old long-press menu had is behind ⋯ under the reply.
                    // When the sources row is under it, a 「来源：」 list the model wrote at the end is not shown twice.
                    let shown = meta?.trimmedText ?? line.text
                    let looked = Self.lookback(shown)
                    // 「回望：…」 the companion wrote after its steps: a quiet line of its own, like 心绪, not body text.
                    if let note = looked.note { LookbackLine(text: note) }
                    SelectableProse(text: looked.rest)
                        .equatable()
                }
                if let meta, !found.isEmpty {
                    SourcesRow(urls: found, titles: meta.titles) { url in
                        typing = false
                        Task { await team.browser.open(url) }
                        roaming = true
                    }
                }
                // The same row under every reply: copy, ⋯; the newest also 重来 and its numbers.
                let newest = line.id == latestBotId
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

/// Isolated empty/loading header so `conversationContent` does not subscribe to `chat.hasStreaming` or `idleMood`.
struct ChatEmptyStatusView<EmptyContent: View>: View {
    let chat: ChatModel
    @ViewBuilder let emptyContent: () -> EmptyContent

    var body: some View {
        if !chat.loaded {
            ProgressView().frame(maxWidth: .infinity)
        } else if chat.lines.isEmpty && !chat.hasStreaming {
            emptyContent()
        }
    }
}

/// Isolated 15Hz handoff prose view so only the single freshly committed row subscribes to `stream.fresh`.
private struct ChatFreshProseView: View {
    let fullText: String
    let stream: ChatLiveStreamState

    var body: some View {
        let shown = stream.fresh?.shown ?? fullText.count
        StreamingProse(text: String(fullText.prefix(shown)))
    }
}

/// Isolated footer + continue-step-limit controls for the newest bot row only, so older settled rows
/// never invalidate when `WorkDetail.words`, `hasStreaming`, or `following` changes.
private struct ChatNewestBotFooterView: View {
    let line: ChatLine
    let isLastLine: Bool
    let historyInView: Bool
    let showStats: Bool
    let chat: ChatModel
    let team: TeamModel
    let petPerch: PetPerch
    let followState: ChatFollowState
    let bridge: ChatRowBridge

    private var isWorking: Bool {
        team.workDetail(for: chat.key).words != nil || chat.hasStreaming
    }

    private var sendingBlocked: Bool {
        team.phase != .demo && !team.canAcceptInput(for: chat.key)
    }

    private var hitStepLimit: Bool {
        guard !historyInView, !isWorking, !sendingBlocked, isLastLine else { return false }
        return line.text.trimmingCharacters(in: .whitespacesAndNewlines) == "（这件事步骤太多，我先停在这里。要我接着做就说一声。）"
    }

    var body: some View {
        Group {
            if hitStepLimit {
                Button {
                    Haptics.light()
                    bridge.onContinueStepLimit()
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
            if !isWorking {
                ChatBotFooterRow(
                    line: line,
                    newest: true,
                    isRoom: chat.roomId != nil,
                    showStats: showStats,
                    petPerch: petPerch,
                    followState: followState,
                    bridge: bridge
                )
                .transition(.opacity)
            }
        }
    }
}

struct ChatBotFooterRow: View {
    let line: ChatLine
    let newest: Bool
    let isRoom: Bool
    let showStats: Bool
    let petPerch: PetPerch
    let followState: ChatFollowState?
    let bridge: ChatRowBridge

    var body: some View {
        HStack(spacing: Ink.Space.xs) {
            HStack(spacing: Ink.Space.xs) {
                iconButton("doc.on.doc", "复制") {
                    UIPasteboard.general.string = line.text
                    Haptics.tick(0.5)
                    bridge.onSay("复制好了。")
                }
                if newest {
                    iconButton("arrow.clockwise", "重来一次") {
                        Haptics.light()
                        bridge.onRedo()
                    }
                }
                Menu {
                    Button("朗读", systemImage: "speaker.wave.2") { bridge.onSpeak(line.text) }
                    Button("引用追问", systemImage: "text.quote") { bridge.onQuote(line.id, line.text) }
                    Button(L.t("saveNote.title"), systemImage: "square.and.arrow.down.on.square") { bridge.onSaveNote(line.id, line.text) }
                    Button(Words.t("做成长图"), systemImage: "photo.on.rectangle") { bridge.onLongNote(line.id, line.text) }
                    ShareLink(item: line.text) { Label("分享", systemImage: "square.and.arrow.up") }
                    if !isRoom {
                        Button(Words.t("从这里另起一叶"), systemImage: "arrow.triangle.branch") { bridge.onFork(line) }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: Ink.Size.small, weight: .medium))
                        .foregroundStyle(Ink.inkFaint)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("更多")
            }
            .overlay {
                if newest, let followState {
                    ChatReplyClearanceMarker(lineID: line.id, petPerch: petPerch, followState: followState)
                }
            }
            Spacer(minLength: Ink.Space.s)
            if newest, showStats {
                Text(ChatPage.numbers(line))
                    .font(.system(size: Ink.Size.micro).monospacedDigit())
                    .foregroundStyle(Ink.inkFaint.opacity(0.85))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .layoutPriority(1)
            }
        }
        .padding(.leading, -5)
    }

    private func iconButton(_ name: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: Ink.Size.small, weight: .regular))
                .foregroundStyle(Ink.inkFaint)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(label)
    }
}

private struct ChatReplyClearanceMarker: View {
    let lineID: String
    let petPerch: PetPerch
    let followState: ChatFollowState

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rect in
                petPerch.replyActionsOwner = lineID
                petPerch.replyActions = rect
            }
            .onChange(of: followState.following, initial: true) { _, resting in
                petPerch.avoidsReplies = resting
            }
            .onDisappear {
                if petPerch.replyActionsOwner == lineID {
                    petPerch.replyActionsOwner = nil
                    petPerch.replyActions = .null
                }
            }
    }
}

/// Equatable settled row view: isolated from streaming tokens, composer typing, and global status changes.
struct ChatSettledRowView: View, Equatable {
    let line: ChatLine
    let opens: Bool
    let lit: Bool
    let isFirst: Bool
    let isFreshWriting: Bool
    let isLatestBot: Bool
    let isLatestNote: Bool
    let isLastLine: Bool
    let endsTurn: Bool
    let timeGap: String?
    let isEditing: Bool
    let faces: Bool
    let isRoom: Bool
    let historyInView: Bool
    let speakerBot: BotInfo?
    let botName: String
    let bubbleTint: Color
    let lineMeta: ChatPage.SourcesMemo.LineMeta?
    let lookbackNote: String?
    let lookbackRest: String
    let showThinking: Bool
    let showStats: Bool

    let chat: ChatModel
    let team: TeamModel
    let petPerch: PetPerch
    let followState: ChatFollowState
    let bridge: ChatRowBridge

    static func == (lhs: ChatSettledRowView, rhs: ChatSettledRowView) -> Bool {
        lhs.line == rhs.line
            && lhs.opens == rhs.opens
            && lhs.lit == rhs.lit
            && lhs.isFirst == rhs.isFirst
            && lhs.isFreshWriting == rhs.isFreshWriting
            && lhs.isLatestBot == rhs.isLatestBot
            && lhs.isLatestNote == rhs.isLatestNote
            && lhs.isLastLine == rhs.isLastLine
            && lhs.endsTurn == rhs.endsTurn
            && lhs.timeGap == rhs.timeGap
            && lhs.isEditing == rhs.isEditing
            && lhs.faces == rhs.faces
            && lhs.isRoom == rhs.isRoom
            && lhs.historyInView == rhs.historyInView
            && lhs.speakerBot == rhs.speakerBot
            && lhs.botName == rhs.botName
            && lhs.bubbleTint == rhs.bubbleTint
            && lhs.lineMeta == rhs.lineMeta
            && lhs.lookbackNote == rhs.lookbackNote
            && lhs.lookbackRest == rhs.lookbackRest
            && lhs.showThinking == rhs.showThinking
            && lhs.showStats == rhs.showStats
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            if faces, opens, let timeGap {
                Text(timeGap)
                    .font(Ink.footnote)
                    .foregroundStyle(Ink.inkFaint)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, Ink.Space.xs)
            }
            switch line.kind {
            case .user:
                userContainer
            case .bot, .steps:
                if opens, faces || isRoom { speakerHeadView }
                rowBody
            case .note:
                rowBody
            }
        }
        .background {
            if lit {
                RoundedRectangle(cornerRadius: Ink.Radius.small, style: .continuous)
                    .fill(Ink.accentWash)
                    .padding(-Ink.Space.s)
            }
        }
        .animation(Ink.Motion.settle, value: lit)
        .padding(.top, line.kind == .user && !isFirst ? Ink.Space.l : 0)
    }

    @ViewBuilder
    private var userContainer: some View {
        if faces {
            HStack(alignment: .top, spacing: Ink.Space.s) {
                userRowBody
                if opens {
                    MeAvatar(size: ChatPage.face)
                } else {
                    Color.clear.frame(width: ChatPage.face, height: 1)
                }
            }
        } else {
            userRowBody
        }
    }

    private var speakerHeadView: some View {
        HStack(spacing: Ink.Space.s) {
            PetStill(size: faces ? ChatPage.face : 22, wash: speakerBot.map { Ink.wash(for: $0) }, avatar: true, bot: speakerBot)
            Text(speakerBot?.name ?? line.speakerName ?? botName)
                .font(.system(size: Ink.Size.small, weight: .semibold))
                .foregroundStyle(Ink.inkSoft)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var rowBody: some View {
        switch line.kind {
        case .user:
            userRowBody
        case .bot:
            botRowBody
        case .steps:
            Trace(line: line, visit: { url in
                bridge.onOpenURL(url)
            }, openFile: { url, mount in
                bridge.onOpenFile(url, mount)
            }, unremember: { id, fact in
                team.unremember(id, fact: fact)
            })
        case .note:
            noteRowBody
        }
    }

    private var userRowBody: some View {
        VStack(alignment: .trailing, spacing: Ink.Space.s) {
            if !line.refs.isEmpty {
                HStack(spacing: Ink.Space.s) {
                    ForEach(line.refs, id: \.self) { ref in
                        Button { bridge.onViewPhoto(ref) } label: {
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
                    .glassBubble(in: RoundedRectangle(cornerRadius: Ink.Radius.card, style: .continuous), tint: bubbleTint)
                    .overlay {
                        if isEditing {
                            RoundedRectangle(cornerRadius: Ink.Radius.card, style: .continuous)
                                .strokeBorder(Ink.accent, lineWidth: 1.5)
                        }
                    }
                    .contentShape(.contextMenuPreview, .rect(cornerRadius: Ink.Radius.card, style: .continuous))
                    .contextMenu {
                        Button("复制", systemImage: "doc.on.doc") { UIPasteboard.general.string = line.text }
                        Button("选字引用", systemImage: "text.quote") { bridge.onQuote(line.id, line.text) }
                        Button("改了重发", systemImage: "pencil") { bridge.onEdit(line.id, line.text) }
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, Ink.Space.huge)
    }

    private var botRowBody: some View {
        VStack(alignment: .leading, spacing: Ink.Space.m) {
            if let reasoning = line.reasoning, showThinking {
                ThinkingBox(text: reasoning)
            }
            if let felt = line.pulse {
                PulseBox(text: felt, temper: Temper.of(speakerBot))
            }
            if isFreshWriting {
                ChatFreshProseView(fullText: line.text, stream: chat.stream)
            } else {
                if let lookbackNote { LookbackLine(text: lookbackNote) }
                SelectableProse(text: lookbackRest, entryID: line.id)
                    .equatable()
            }
            if !isFreshWriting, let meta = lineMeta, !meta.urls.isEmpty {
                SourcesRow(urls: meta.urls, titles: meta.titles) { url in
                    bridge.onOpenURL(url)
                }
            }
            if !isFreshWriting {
                if isLatestBot {
                    ChatNewestBotFooterView(
                        line: line,
                        isLastLine: isLastLine,
                        historyInView: historyInView,
                        showStats: showStats,
                        chat: chat,
                        team: team,
                        petPerch: petPerch,
                        followState: followState,
                        bridge: bridge
                    )
                } else if endsTurn {
                    ChatBotFooterRow(
                        line: line,
                        newest: false,
                        isRoom: isRoom,
                        showStats: showStats,
                        petPerch: petPerch,
                        followState: nil,
                        bridge: bridge
                    )
                    .transition(.opacity)
                }
            }
        }
    }

    @ViewBuilder
    private var noteRowBody: some View {
        if line.fold {
            Button {
                Haptics.light()
                bridge.onOpenLeaves()
            } label: {
                HStack(spacing: Ink.Space.s) {
                    Rectangle().fill(Ink.rule).frame(height: 1)
                    Label(line.text, systemImage: "text.append")
                        .font(Ink.footnote)
                        .foregroundStyle(Ink.inkFaint)
                        .lineLimit(1)
                        .fixedSize()
                    Rectangle().fill(Ink.rule).frame(height: 1)
                }
                .padding(.vertical, Ink.Space.s)
                .contentShape(Rectangle())
            }
            .buttonStyle(TapStyle())
            .accessibilityLabel(line.text + "，点开看前情提要")
        } else if let next = line.next {
            let parts = line.text.split(separator: "\n", maxSplits: 1).map(String.init)
            let advice = Explain.Advice(title: parts.first ?? line.text, detail: parts.count > 1 ? parts[1] : "", next: next)
            VStack(alignment: .leading, spacing: Ink.Space.s) {
                Label(advice.displayTitle, systemImage: next == .resume ? "pause.circle" : "exclamationmark.triangle")
                    .font(.system(size: Ink.Size.sub, weight: .semibold))
                    .foregroundStyle(next == .resume ? Ink.ink : Ink.stop)
                if !advice.detail.isEmpty {
                    Text(advice.detail).font(Ink.secondary).foregroundStyle(Ink.inkSoft)
                }
                if isLatestNote, let button = advice.button {
                    Button {
                        Haptics.light()
                        bridge.onAct(next)
                    } label: {
                        Text(button)
                            .font(.system(size: Ink.Size.sub, weight: .semibold))
                            .foregroundStyle(Ink.accent)
                            .padding(.horizontal, Ink.Space.l)
                            .frame(height: 34)
                            .background(Ink.accentWash, in: .capsule)
                    }
                    .buttonStyle(PressStyle(haptic: false))
                    .padding(.top, Ink.Space.xs)
                }
            }
            .padding(Ink.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(next == .resume ? Ink.paperRaised.opacity(0.7) : Ink.stop.opacity(0.07), in: .rect(cornerRadius: Ink.Radius.card, style: .continuous))
        } else {
            Text(line.text)
                .font(Ink.footnote)
                .foregroundStyle(Ink.inkFaint)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

/// Live tail below the settled `LazyVStack`: each slot observes only its own slice of streaming state.
struct ChatLiveTailView: View {
    let chat: ChatModel
    @ObservedObject var team: TeamModel
    let isRoom: Bool
    let bot: BotInfo
    let bridge: ChatRowBridge

    var body: some View {
        Group {
            if team.compressing.contains(chat.key) {
                Label("正在后台整理较早的聊天，不耽误你接着聊", systemImage: "text.append")
                    .font(Ink.footnote)
                    .foregroundStyle(Ink.inkFaint)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .id("folding")
                    .transition(.opacity)
            }
            ChatLivePulseSlot(stream: chat.stream, chat: chat, team: team, isRoom: isRoom, bot: bot)
            ChatLiveThinkingSlot(stream: chat.stream, chat: chat)
            ChatLiveProseSlot(stream: chat.stream, chat: chat)
            ChatLiveToolTailSlot(team: team, chatKey: chat.key)
            ChatFailureCardSlot(chat: chat, team: team, bridge: bridge)
            ForEach(team.queued[chat.key] ?? []) { item in
                ChatQueuedRowSlot(item: item, chat: chat, team: team, bridge: bridge)
                    .transition(.opacity.combined(with: .offset(y: 8)))
            }
        }
    }
}

private struct ChatLivePulseSlot: View {
    let stream: ChatLiveStreamState
    let chat: ChatModel
    let team: TeamModel
    let isRoom: Bool
    let bot: BotInfo

    var body: some View {
        if !stream.pulse.isEmpty {
            let speaker = stream.pulseSpeaker.flatMap { id in team.bots.first { $0.id == id } }
            PulseBox(text: stream.pulse, live: !chat.hasStreaming, temper: Temper.of(speaker ?? (isRoom ? nil : bot)))
                .id("pulse")
                .transition(.opacity)
        }
    }
}

private struct ChatLiveThinkingSlot: View {
    let stream: ChatLiveStreamState
    let chat: ChatModel

    var body: some View {
        if !stream.reasoning.isEmpty && !chat.hasStreaming {
            ThinkingBox(text: stream.reasoning, live: true)
                .id("thinking")
                .transition(.opacity)
        }
    }
}

private struct ChatLiveProseSlot: View {
    let stream: ChatLiveStreamState
    let chat: ChatModel

    var body: some View {
        if chat.hasStreaming {
            StreamingProse(text: stream.text)
                .id(stream.generation)
                .id("streaming")
        }
    }
}

private struct ChatLiveToolTailSlot: View {
    let team: TeamModel
    let chatKey: String

    var body: some View {
        if let doing = team.workDetail(for: chatKey).words,
           doing.contains("："),
           let kind = Trace.canonicalKind(of: doing),
           kind == "斗室" || kind == "远山" {
            ToolTailView(tail: team.toolTail(for: chatKey))
                .id("live")
                .transition(.opacity.combined(with: .offset(y: 8)))
        }
    }
}

private struct ChatFailureCardSlot: View {
    let chat: ChatModel
    let team: TeamModel
    let bridge: ChatRowBridge

    private var working: Bool {
        team.workDetail(for: chat.key).words != nil || chat.hasStreaming
    }

    private func saidInNote(_ error: String) -> Bool {
        guard let last = chat.lines.last, last.kind == .note else { return false }
        return error.split(separator: "\n").first.map { last.text.contains($0) } ?? false
    }

    var body: some View {
        if let error = chat.error, !saidInNote(error) {
            HStack(alignment: .center, spacing: Ink.Space.m) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: Ink.Size.sub, weight: .semibold))
                    .foregroundStyle(Ink.stop)
                Text(error)
                    .font(.system(size: Ink.Size.sub))
                    .foregroundStyle(Ink.stop)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !working {
                    Button {
                        Haptics.light()
                        bridge.onRetry()
                    } label: {
                        Label(L.t("actions.retry"), systemImage: "arrow.clockwise")
                            .font(.system(size: Ink.Size.small, weight: .semibold))
                            .foregroundStyle(Ink.ink)
                            .padding(.horizontal, Ink.Space.m)
                            .frame(height: 32)
                            .background(Ink.paper, in: .capsule)
                    }
                    .buttonStyle(PressStyle(haptic: false))
                }
            }
            .padding(.horizontal, Ink.Space.l)
            .padding(.vertical, Ink.Space.m)
            .background(Ink.stopWash, in: .rect(cornerRadius: Ink.Radius.small, style: .continuous))
            .transition(.opacity.combined(with: .offset(y: 6)))
        }
    }
}

private struct ChatQueuedRowSlot: View {
    let item: TeamModel.Queued
    let chat: ChatModel
    let team: TeamModel
    let bridge: ChatRowBridge

    private var working: Bool {
        team.workDetail(for: chat.key).words != nil || chat.hasStreaming
    }

    private var sendingBlocked: Bool {
        team.phase != .demo && !team.canAcceptInput(for: chat.key)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: Ink.Space.xs) {
            VStack(alignment: .trailing, spacing: 4) {
                if !item.photos.isEmpty {
                    Label("\(item.photos.count) 张照片", systemImage: "photo").font(Ink.footnote).foregroundStyle(Ink.inkSoft)
                }
                if !item.text.isEmpty {
                    Text(item.text).font(Ink.label).foregroundStyle(Ink.ink).lineLimit(4).lineSpacing(4)
                }
            }
            .padding(.horizontal, Ink.Space.l)
            .padding(.vertical, Ink.Space.m)
            .background(Ink.mine.opacity(0.55), in: .rect(cornerRadius: Ink.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Ink.Radius.card, style: .continuous).strokeBorder(Ink.rule, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            HStack(spacing: Ink.Space.m) {
                Text(item.interject ? (working ? "插话 · 这一步做完就递给它" : "还没发出") : (working ? "排队中，这轮做完就发" : "还没发出")).font(Ink.footnote).foregroundStyle(Ink.inkFaint)
                Button("撤回", systemImage: "arrow.uturn.backward") {
                    bridge.onWithdrawQueued(item)
                }
                Button("立即发送", systemImage: "paperplane.fill") {
                    bridge.onSendQueuedNow()
                }
                .fontWeight(.semibold)
                .disabled(sendingBlocked)
            }
            .font(.system(size: Ink.Size.small))
            .foregroundStyle(Ink.accent)
            .buttonStyle(TapStyle())
            .opacity(sendingBlocked ? 0.45 : 1)
            .disabled(sendingBlocked)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, Ink.Space.huge)
    }
}
