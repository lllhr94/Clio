import AVFoundation
import AgentKit
import CoreLocation
import Craft
import PhotosUI
import Prose
import Observation
import SwiftUI
import UniformTypeIdentifiers
import VisionKit

/// 絮语: a conversation with one companion, set as a page.
struct ChatPage: View {
    let team: TeamModel
    @State var chat: ChatModel
    @State var dictationSlot = ChatDictationSlot()
    let asker = Asker.shared
    @State var petPerch = PetPerch()
    @State var chatViewport = CGSize.zero
    @Environment(\.accessibilityReduceMotion) var calmPetMotion
    @Environment(\.scenePhase) var scenePhase
    /// Opens the sidebar. An object that stays the same, not a closure made anew: a new closure on every redraw of the
    /// desk made SwiftUI think the whole page had changed, and redraw all of it for every frame the sidebar slid.
    let side: SideControl
    var back: () -> Void { side.open }

    @State var draftState = ChatDraft()
    var draft: String { get { draftState.text } nonmutating set { draftState.text = newValue } }
    @State var dictationMerger = DictationDraftMerger()
    @State var speakingText: String?
    @State var headerHeight: CGFloat = 0
    @State var photos: [Data] = []
    @State var draftAttachmentQueuedIds: [UUID] = []
    @State var picks: [PhotosPickerItem] = []
    @State var attachmentRevision = UUID()
    @State var pasteTask: Task<Void, Never>?
    @State var takingPhoto = false
    @State var approving: Approval?
    @State var viewing: String?
    @State var presentedViewing: Viewing?
    @Namespace private var photoZoom
    /// The message being changed and sent again.
    @State var editing: String?
    @State var scroller: ChatScroller?
    @State var listProxy = ChatListControllerProxy()
    @AppStorage("look.uikitChatList") var useUIKitChatList = true
    /// Whether the page keeps to the newest line as things arrive: off once the reader scrolls up to read,
    /// on again when they come back to the bottom, send something, or tap 回到最新.
    @State var following = true
    /// 聊天里显示头像: off unless turned on (设置 › 对话 › 对话显示与反馈).
    @AppStorage("chat.faces") var faces = false
    /// The stop button asks first (as Open Minis does): a long task lost to a thumb that slipped is worse than one more tap.
    @AppStorage("chat.confirmStop") var confirmStop = true
    @State var askingStop = false
    /// 在对话里找: what is looked for, and which of the places found is in view.
    @State var finding = false
    @State var findText = ""
    @State var findAt = 0
    @State var hits: [String] = []
    @State var findLoadTask: Task<Void, Never>?
    @State var findQueryTask: Task<Void, Never>?
    @State var findScrollTask: Task<Void, Never>?
    /// How many lines were on the page before finding or the outline opened everything; restored after.
    @State var lookupRows: [ChatLine] = []
    @State var historyPage: [ChatLine]?
    var displayedRows: [ChatLine] { historyPage ?? chat.lines }
    @State var outlinePairs: [OutlineSheet.Pair] = []
    @FocusState var findFocus: Bool
    /// A reply opened to pick any words from it.
    @State var picking: ChatLine?
    /// The message of yours 「回到我上一句」 went to last; the next tap goes one further up.
    @State var jumpedTo: String?
    @State var hideJumps: Task<Void, Never>?
    @State var chrome = ChatChrome()
    @State var viewport = ChatViewport()
    @State var selecting: Set<UUID> = []
    @State var sharing: ShareFile?
    @State var terminalOpen = false
    @State var chatSkillsOpen = false
    @State var chatConnectorsOpen = false
    @State var clearingChat = false
    /// The reader's own finger is moving the page (dragging, or the glide after it) — not a scroll the app made.
    var touchScrolling: Bool {
        get { viewport.touchScrolling }
        nonmutating set { viewport.touchScrolling = newValue }
    }
    /// How full the next request will be; worked out when the page opens and after each turn, not on every word.
    @State var contextMetrics = ChatContextMetrics()
    @State var usageOpen = false
    @State var idleMood = ChatIdleMood()
    @State var notice = ChatComposerNotice()
    @State var followState = ChatFollowState()
    @State var workTimer = ChatWorkTimer()
    @State var bridge = ChatRowBridge()
    /// How many of the newest lines are drawn; 「更早的」 adds more.
    @State var shownCount = 60
    /// What happened in the other conversations while the user was away from this one.
    @State var awayState = ChatAwayState()
    @Environment(\.dynamicTypeSize) var typeSize
    @ScaledMetric(relativeTo: .body) var textScale: CGFloat = 1
    var largeText: Bool { typeSize.isAccessibilitySize }

    @FocusState var typing: Bool
    @State var voice = AVSpeechSynthesizer()

    init(team: TeamModel, bot: BotInfo, side: SideControl) {
        self.team = team
        self.side = side
        _chat = State(initialValue: ChatModel(bot: bot, team: team))
    }

    init(team: TeamModel, room: RoomInfo, side: SideControl) {
        self.team = team
        self.side = side
        _chat = State(initialValue: ChatModel(room: room, team: team))
    }

    var isRoom: Bool { chat.roomId != nil }

    var bot: BotInfo { isRoom ? chat.bot : (team.bots.first { $0.id == chat.bot.id } ?? chat.bot) }
    var doing: String? { team.workDetail(for: chat.key).words }
    var working: Bool { doing != nil || chat.hasStreaming }
    var waiting: Approval? { team.approvals.first { $0.chat == chat.key } }

    /// What the pet acts out for this conversation.
    var petMood: PetMood {
        if waiting != nil || (asker.current != nil && working) { return .waiting }
        if let doing, doing.contains("压缩") || doing.contains("提要") { return .sweeping }
        if chat.hasStreaming { return .writing }
        if working {
            if let doing, doing.contains("沉吟") || doing.contains("思考") { return .thinking }
            return .working(max(1, team.doing.count))
        }
        return .idle
    }

    /// Which of the pet's states the portrait in the header and the empty page show.
    var petState: String {
        Self.companionPetState(
            waiting: waiting,
            hasStreaming: chat.hasStreaming,
            doing: doing,
            working: working,
            typing: typing,
            listening: dictationSlot.instance?.listening == true,
            cheering: idleMood.cheering,
            dozing: idleMood.dozing
        )
    }

    /// 「更早的」: draws forty more of the older lines, keeping the line you were looking at in place.
    var earlier: some View {
        Button {
            Haptics.light()
            loadEarlier()
        } label: {
            Label(L.t("chat.earlier"), systemImage: "arrow.up")
                .font(.system(size: Ink.Size.small, weight: .medium))
                .foregroundStyle(Ink.inkSoft)
                .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(TapStyle())
    }

    /// Draws forty more older lines and keeps the one at the top of the screen where it was. Called by the button,
    /// and by itself when the reader scrolls near the top, so long conversations read on without stopping.
    var canLoadEarlier: Bool {
        historyPage == nil && (chat.lines.count > shownCount || chat.hasEarlier)
    }

    func loadEarlier() {
        guard canLoadEarlier, earlierTask == nil, selecting.isEmpty else { return }
        let previous = chat.lines.suffix(shownCount)
        let visible = Set(viewport.ids)
        let anchor = previous.first { visible.contains($0.id) }?.id
        let first = previous.first?.id
        let oldCount = previous.count
        earlierTask = Task { @MainActor in
            defer { earlierTask = nil }
            if chat.lines.count <= shownCount {
                await chat.loadEarlier()
            }
            guard !Task.isCancelled, historyPage == nil, selecting.isEmpty else { return }
            let retained = first.flatMap { id in chat.lines.firstIndex { $0.id == id } }
                .map { chat.lines.count - $0 } ?? oldCount
            let previewNextShown = min(chat.lines.count, retained + 40)
            let startIndex = max(0, chat.lines.count - previewNextShown)
            let endIndex = max(startIndex, chat.lines.count - retained)
            if startIndex < endIndex {
                let targetSlice = Array(chat.lines[startIndex..<endIndex])
                let botTexts = targetSlice.compactMap { line -> String? in
                    guard line.kind == .bot, !line.text.isEmpty else { return nil }
                    return line.text
                }
                if !botTexts.isEmpty {
                    let uiKitMode = useUIKitChatList
                    let styleKey: ProseStyleKey? = uiKitMode ? nil : ProseStyleKey.current()
                    let worker = Task.detached(priority: .userInitiated) {
                        if uiKitMode {
                            for raw in botTexts {
                                if Task.isCancelled { return }
                                let rawRest = ProseTextTransforms.lookback(raw).rest
                                ChatPage.prewarmProseText(rawRest)
                                let trimmed = ProseTextTransforms.trimSourceList(raw)
                                if trimmed != raw {
                                    let trimmedRest = ProseTextTransforms.lookback(trimmed).rest
                                    if trimmedRest != rawRest {
                                        ChatPage.prewarmProseText(trimmedRest)
                                    }
                                }
                            }
                        } else if let styleKey {
                            ProsePrewarm.prewarm(lines: targetSlice[...], styleKey: styleKey)
                        }
                    }
                    await withTaskCancellationHandler {
                        await worker.value
                    } onCancel: {
                        worker.cancel()
                    }
                }
            }
            guard !Task.isCancelled, historyPage == nil, selecting.isEmpty else { return }
            let finalRetained = first.flatMap { id in chat.lines.firstIndex { $0.id == id } }
                .map { chat.lines.count - $0 } ?? oldCount
            shownCount = min(chat.lines.count, finalRetained + 40)
            guard let anchor else { return }
            settleJump?.cancel()
            viewport.advanceNavigation()
            await Task.yield()
            guard !Task.isCancelled, historyPage == nil, selecting.isEmpty, !following else { return }
            viewport.recordJump("载入更早的消息")
            if !useUIKitChatList {
                scroller?.scrollTo(anchor, anchor: .top)
            }
        }
    }

    nonisolated private static func prewarmProseText(_ rawText: String) {
        guard !rawText.isEmpty else { return }
        let blocks = ParsedCache.blocks(rawText)
        prewarmCodeAndTables(in: blocks)
    }

    nonisolated private static func prewarmCodeAndTables(in blocks: [Prose.Block]) {
        for block in blocks {
            if Task.isCancelled { return }
            switch block {
            case .code(let language, let rawCode, _):
                let trimmed = CodeTokenizer.trimmedLines(rawCode)
                let body = trimmed.isEmpty ? " " : trimmed
                let count = CodeTokenizer.lineCount(body)
                let isOutput = CodeTokenizer.isOutputBlock(language: language, text: body)
                _ = CodeTokenizer.prepare(body, language: language, isOutput: isOutput)
                if count > 20 {
                    let folded = body.split(separator: "\n", omittingEmptySubsequences: false).prefix(12).joined(separator: "\n")
                    _ = CodeTokenizer.prepare(folded, language: language, isOutput: isOutput)
                }
            case .table(let table):
                _ = TablePreparer.prepare(table)
            case .quote(let inner):
                prewarmCodeAndTables(in: inner)
            default:
                break
            }
        }
    }

    @State var earlierTask: Task<Void, Never>?

    /// A failure in the conversation: what went wrong, and a way to try again right there.
    func failureCard(_ error: String) -> some View {
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
                    following = true
                    chat.retry()
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
    }

    /// A failure already explained in the conversation (the card with 再试一次) is not repeated in red under it.
    func saidInNote(_ error: String) -> Bool {
        guard let last = chat.lines.last, last.kind == .note else { return false }
        return error.split(separator: "\n").first.map { last.text.contains($0) } ?? false
    }

    /// Something happened: the pet wakes, and the doze clock starts over without triggering a full-page redraw.
    func stir() {
        if idleMood.dozing { idleMood.dozing = false }
        viewport.lastStirAt = ProcessInfo.processInfo.systemUptime
    }

    /// Whether the line under the conversation says what is going on: whenever the companion works and nothing else shows it.
    var showsLive: Bool {
        guard doing != nil || waiting != nil else { return false }
        if let last = chat.lines.last, last.kind == .steps, last.live { return false }
        return !chat.hasStreaming || waiting != nil
    }

    /// What it is doing, in plain words, for the line under the conversation.
    var liveWords: String? {
        Live.words(doing, name: bot.name, waiting: waiting != nil)
    }

    var liveIcon: String {
        if waiting != nil { return "seal" }
        guard let doing else { return "ellipsis" }
        let name = doing.split(separator: "：", maxSplits: 1).first.map(String.init) ?? doing
        if doing.contains("：") { return Trace.icon(for: name) }
        return doing == "正在回复" ? "pencil.line" : "sparkles"
    }

    /// Under the name: what it is doing while it works; otherwise this conversation's title, once one is written.
    var headerLine: String {
        if working || waiting != nil { return status }
        return team.title(of: chat.key) ?? status
    }

    /// The companion's state in the glossary's words.
    var status: String {
        Self.companionStatus(waiting: waiting, doing: doing)
    }

    /// The lines of the conversation, what is arriving, and what waits to be sent.
    var conversationContent: some View {
        // Only the rows are lazy. Lazy stacks nested in lazy stacks only guess each other's height: scrolling to the
        // foot (tapping 「最新」, or a reply starting) then landed on a spot with nothing drawn yet — the blank page.
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Ink.Space.m) {
                ChatEmptyStatusView(chat: chat) {
                    ChatEmptyContentView(
                        chat: chat,
                        team: team,
                        bot: bot,
                        dictationSlot: dictationSlot,
                        idleMood: idleMood,
                        starters: starters,
                        reach: reach,
                        typing: $typing,
                        onPickStarter: { text in
                            draft = text
                            typing = true
                        }
                    )
                }
                ChatEarlierButtonView(
                    chat: chat,
                    historyInView: historyPage != nil,
                    shownCount: shownCount,
                    onLoadEarlier: loadEarlier
                )
                let rows = historyPage == nil ? Array(chat.lines.suffix(shownCount)) : displayedRows
                let heads = openers
                let lit = finding ? currentHit : nil
                let animateRow = historyPage == nil
                let firstRowId = displayedRows.first?.id
                let recentSecondLastId = chat.lines.count >= 2 ? chat.lines[chat.lines.count - 2].id : nil
                let recentLastId = chat.lines.last?.id
                let latestBot = latestBotId
                let latestNote = chat.lines.last(where: { $0.kind == .note })?.id
                let showThinking = Pref.showThinking
                let showStats = Pref.stats
                let editingId = editing
                let defaultBot = bot
                let defaultBotName = defaultBot.name
                // Keep distant replies unmounted when the keyboard, stream or window size changes.
                LazyVStack(alignment: .leading, spacing: Ink.Space.m) {
                    ForEach(rows) { line in
                        settledRow(
                            line: line,
                            heads: heads,
                            lit: lit,
                            animateRow: animateRow,
                            firstRowId: firstRowId,
                            recentSecondLastId: recentSecondLastId,
                            recentLastId: recentLastId,
                            latestBot: latestBot,
                            latestNote: latestNote,
                            showThinking: showThinking,
                            showStats: showStats,
                            editingId: editingId,
                            defaultBot: defaultBot,
                            defaultBotName: defaultBotName
                        )
                    }
                }
                .scrollTargetLayout()
                if historyPage == nil {
                    ChatLiveTailView(
                        chat: chat,
                        team: team,
                        isRoom: isRoom,
                        bot: defaultBot,
                        bridge: bridge
                    )
                }
            }
            // The foot of the page, under the breathing room at the bottom: scrolling to it shows everything,
            // and it is exactly the end of the content, so "at the bottom" and "scrolled to the foot" agree.
            Color.clear.frame(height: Ink.Space.xxl + Ink.Space.l)
            Color.clear.frame(height: 1).id(Self.end)
        }
        .padding(.horizontal, Ink.Space.page)
        .padding(.top, Ink.Space.s)
    }

    private func settledRow(
        line: ChatLine,
        heads: Set<String>,
        lit: String?,
        animateRow: Bool,
        firstRowId: String?,
        recentSecondLastId: String?,
        recentLastId: String?,
        latestBot: String?,
        latestNote: String?,
        showThinking: Bool,
        showStats: Bool,
        editingId: String?,
        defaultBot: BotInfo,
        defaultBotName: String
    ) -> some View {
        let isFirst = line.id == firstRowId
        let opens = heads.contains(line.id)
        let isFreshWriting = chat.freshWritingID == line.id
        let isBot = line.kind == .bot
        let meta: SourcesMemo.LineMeta? = (isBot && !isFreshWriting) ? lineMeta(for: line) : nil
        let lookback: (note: String?, rest: String) = (isBot && !isFreshWriting)
            ? Self.lookback(meta?.trimmedText ?? line.text)
            : (nil, "")
        let speakerBot = line.speaker.flatMap { id in team.bots.first { $0.id == id } } ?? (isRoom ? nil : defaultBot)
        let isRecent = animateRow && (line.id == recentLastId || line.id == recentSecondLastId) && chat.freshID != line.id
        return ChatSettledRowView(
            line: line,
            opens: opens,
            lit: lit == line.id,
            isFirst: isFirst,
            isFreshWriting: isFreshWriting,
            isLatestBot: line.id == latestBot,
            isLatestNote: line.id == latestNote && line.id == recentLastId,
            isLastLine: line.id == recentLastId,
            endsTurn: isBot ? endsTurn(line) : false,
            timeGap: (faces && opens) ? timeGap(before: line) : nil,
            isEditing: editingId == line.id,
            faces: faces,
            isRoom: isRoom,
            historyInView: historyPage != nil,
            speakerBot: speakerBot,
            botName: defaultBotName,
            bubbleTint: bubbleTint(editing: editingId == line.id),
            lineMeta: meta,
            lookbackNote: lookback.note,
            lookbackRest: lookback.rest,
            showThinking: showThinking,
            showStats: showStats,
            chat: chat,
            team: team,
            petPerch: petPerch,
            followState: followState,
            bridge: bridge
        )
        .equatable()
        .id(line.id)
        .transition(isRecent
                    ? .opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)).combined(with: .offset(y: 8))
                    : .identity)
    }

    /// The conversation itself: the lines, what is arriving, and the header it scrolls under.
    /// Kept apart from `body` so the compiler checks each piece on its own.
    @ViewBuilder
    var conversation: some View {
        if useUIKitChatList {
            uikitConversation
                .environment(\.photoZoomNamespace, photoZoom)
        } else {
            swiftUIConversation
                .environment(\.photoZoomNamespace, photoZoom)
        }
    }

    private var swiftUIConversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                conversationContent
            }
            .observeProseStyle()
            .environment(\.chatSelectionChanged, selectionChanged)
            .environment(\.chatQuoteSelection) { picked in
                Haptics.tick(0.5)
                withAnimation(Ink.Motion.settle) { quote = picked }
                typing = true
            }
            .environment(\.chatSpeakSelection) { picked in
                Haptics.light()
                speak(picked)
            }
            .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.15) { viewport.ids = $0 }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(Self.resizeAnchor(following: following, inHistory: historyPage != nil,
                                                   hasSelection: !selecting.isEmpty), for: .sizeChanges)
            // Size changes already use the bottom anchor while following. Only schedule a correction
            // when the viewport actually leaves the bottom, rather than scrolling again on every reflow.
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                Self.endAlignment(geometry)
            } action: { _, alignment in
                endAlignmentChanged(alignment)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                Self.below(geometry) >= 80
            } action: { _, far in
                if chrome.farFromEnd != far {
                    withAnimation(Ink.Motion.settle) { chrome.farFromEnd = far }
                }
            }
            // Near the top while the reader scrolls up: the older lines come in by themselves.
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top < 240
            } action: { _, nearTop in
                // Only when the reader scrolls up by hand: a scroll the app makes (keeping to the foot while a
                // reply arrives) must never pull in older lines above and shift the page.
                if nearTop, touchScrolling, !following, selecting.isEmpty { loadEarlier() }
            }
            // Record large unexpected upward jumps, height collapses, and the preceding UI actions without redrawing.
            .onScrollGeometryChange(for: ChatScrollSample.self) { geometry in
                ChatScrollSample(offset: geometry.contentOffset.y, contentHeight: geometry.contentSize.height,
                                 viewportHeight: geometry.containerSize.height)
            } action: { old, now in
                guard old.offset.isFinite, now.offset.isFinite,
                      old.contentHeight.isFinite, now.contentHeight.isFinite,
                      old.viewportHeight.isFinite, now.viewportHeight.isFinite else { return }
                let heightDelta = now.contentHeight - old.contentHeight
                let viewportDelta = now.viewportHeight - old.viewportHeight
                if abs(viewportDelta) >= 8 {
                    DiagTrail.record("视口高(\(Int(old.viewportHeight))→\(Int(now.viewportHeight)))")
                }
                if abs(heightDelta) >= 600, !chat.hasStreaming {
                    DiagTrail.record("正文高(\(Int(old.contentHeight))→\(Int(now.contentHeight)))")
                }
                let distance = old.offset - now.offset
                guard !touchScrolling, historyPage == nil, distance > 900 else { return }
                let recentJump = viewport.recentJump
                let collapsed = heightDelta < -400
                let blankLanding = viewport.ids.isEmpty
                // Intentional user navigation (minimap, prev/next question, search hit, back to latest)
                // that lands on visible rows without a height collapse is normal, not an error.
                if let recentJump, !collapsed, !blankLanding,
                   Self.isIntentionalJump(recentJump) {
                    return
                }
                let origin = recentJump.map { "最近跳转：\($0)" } ?? "无近期跳转请求"
                let trail = DiagTrail.recentContext(within: 4, limit: 6).joined(separator: " | ")
                let trailPart = trail.isEmpty ? "" : "，前4秒：[\(trail)]"
                Diag.note("对话页往上跳 \(Int(distance)) 点（\(origin)，阶段=\(viewport.scrollPhaseLabel)，following=\(following)，可见 \(viewport.ids.count) 条，已加载 \(min(shownCount, chat.lines.count)) 条，偏移 \(Int(old.offset))→\(Int(now.offset))，正文高 \(Int(old.contentHeight))→\(Int(now.contentHeight))，视口高 \(Int(old.viewportHeight))→\(Int(now.viewportHeight))，在写=\(chat.hasStreaming)\(trailPart)）")
            }
            .onScrollPhaseChange { old, phase, context in
                viewport.scrollPhaseLabel = Self.phaseLabel(phase)
                let moving = phase != .idle
                viewport.isTouching = phase == .tracking || phase == .interacting || phase == .decelerating
                touchScrolling = phase == .interacting || phase == .decelerating
                chat.setBrowsingHistory(phase == .interacting || phase == .decelerating)
                if moving != chrome.scrolling {
                    chrome.scrolling = moving
                    stir()
                    Hitches.shared.doing(moving ? Words.t("滚动絮语") : nil, as: "scroll")
                }
                if phase == .tracking || phase == .interacting {
                    settleJump?.cancel()
                    viewport.advanceNavigation()
                }
                // Only the reader's own scrolling decides whether the page keeps to the newest line; arriving text never does.
                if phase == .interacting {
                    following = false
                    followPending?.cancel()
                    settleEnd?.cancel()
                    jumpedTo = nil
                    hideJumps?.cancel()
                    if !chrome.jumpVisible {
                        DiagTrail.record("开始滑")
                        chrome.jumpVisible = true
                    }
                }
                if phase == .idle, old == .interacting || old == .decelerating {
                    let below = Self.below(context.geometry)
                    following = historyPage == nil && selecting.isEmpty && below < 80
                    viewport.needsEndCorrection = Self.endAlignment(context.geometry) != 0
                    DiagTrail.record("停滑(距底\(Int(max(0, below).rounded())),跟随=\(following ? 1 : 0))")
                    if following, viewport.needsEndCorrection { followToEnd(settle: false) }
                    lingerJumpButtons()
                }
            }
            .scrollIndicators(.hidden)
            .overlay(alignment: .trailing) { minimap }
            .scrollDismissesKeyboard(.interactively)
            // The header is a bar the conversation scrolls under: iOS blurs and fades the text beneath it, so nothing
            // reads through between the buttons, and the glass no longer picks up colours from the page.
            .scrollEdgeEffectStyle(.soft, for: .top)
            .safeAreaBar(edge: .top) { header }
            .onAppear { scroller = ChatScroller(proxy: proxy) }
            .task { await playShot() }
        }
    }

    static func phaseLabel(_ phase: ScrollPhase) -> String {
        switch phase {
        case .idle: return "静止"
        case .tracking: return "按住"
        case .interacting: return "拖动"
        case .decelerating: return "惯性"
        case .animating: return "动画"
        }
    }

    static func isIntentionalJump(_ source: String) -> Bool {
        source.hasPrefix("小地图")
            || source.hasPrefix("点了上一句")
            || source.hasPrefix("点了下一句")
            || source == "点了搜索结果"
            || source == "点了提纲"
            || source == "回到最新"
    }

    /// Screenshot scenes that act: send a message and catch the reply arriving; or go up, then back to the latest.
    func playShot() async {
        guard let shot = Shots.name else { return }
        try? await Task.sleep(for: .seconds(1))
        switch shot {
        case "chat-stream":
            if let stage = Shots.streamStage {
                following = false
                chat.stageReplyShot(stage)
                do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
                scroller?.scrollTo(ChatModel.shotQuestionID, anchor: .top)
            } else {
                chat.send("再帮我列个要带的东西", photos: [])
            }
        case "newchat":
            side.fresh(bot.id)
        case "chat-latest":
            following = false
            if let first = chat.lines.suffix(shownCount).first?.id { scroller?.scrollTo(first, anchor: .top) }
            try? await Task.sleep(for: .seconds(1))
            returnToLatest()
        default:
            break
        }
    }

    /// Puts a queued or interjected turn back into the composer atomically once persisted on disk.
    func withdrawQueued(_ item: TeamModel.Queued) {
        Self.performWithdrawQueued(
            item,
            chat: chat,
            team: team,
            draftState: draftState,
            photos: $photos,
            files: $files,
            draftAttachmentQueuedIds: $draftAttachmentQueuedIds,
            typing: $typing
        )
    }

    static func performWithdrawQueued(
        _ item: TeamModel.Queued,
        chat: ChatModel,
        team: TeamModel,
        draftState: ChatDraft,
        photos: Binding<[Data]>,
        files: Binding<[String]>,
        draftAttachmentQueuedIds: Binding<[UUID]>,
        typing: FocusState<Bool>.Binding
    ) {
        guard let back = team.unqueue(chat.key, item.id, deferRemoval: true) else { return }
        let chatKey = chat.key
        draftState.load(chatKey)
        let textSnapshot: StoredTextDraft?
        if !back.text.isEmpty {
            draftState.text = draftState.text.isEmpty ? back.text : draftState.text + "\n" + back.text
            draftState.recordQueuedId(back.id)
            textSnapshot = draftState.prepareAtomicSave()
        } else {
            textSnapshot = nil
        }
        if !back.photos.isEmpty {
            let previousCount = photos.wrappedValue.count
            photos.wrappedValue.append(contentsOf: back.photos)
            if !draftAttachmentQueuedIds.wrappedValue.contains(back.id) {
                draftAttachmentQueuedIds.wrappedValue.append(back.id)
            }
            let snapshotPhotos = photos.wrappedValue
            let snapshotFiles = files.wrappedValue
            let snapshotIds = draftAttachmentQueuedIds.wrappedValue
            Task {
                let textOk: Bool
                if let textSnapshot {
                    textOk = await DraftTextStore.saveResult(textSnapshot, for: chatKey)
                } else {
                    textOk = true
                }
                let photosOk: Bool
                if textOk {
                    photosOk = await DraftAttachments.saveResult(
                        photos: snapshotPhotos,
                        files: snapshotFiles,
                        chat: chatKey,
                        queuedIds: snapshotIds
                    )
                } else {
                    photosOk = false
                }
                if textOk && photosOk {
                    team.confirmQueuedRemoved([back.id], for: chatKey)
                } else {
                    draftAttachmentQueuedIds.wrappedValue.removeAll { $0 == back.id }
                    draftState.removeQueuedId(back.id)
                    if !back.text.isEmpty {
                        if draftState.text == back.text {
                            draftState.text = ""
                        } else if draftState.text.hasSuffix("\n" + back.text) {
                            draftState.text = String(draftState.text.dropLast(back.text.count + 1))
                        }
                    }
                    draftState.flush()
                    if photos.wrappedValue.count >= previousCount + back.photos.count,
                       Array(photos.wrappedValue[previousCount..<(previousCount + back.photos.count)]) == back.photos {
                        photos.wrappedValue.removeSubrange(previousCount..<(previousCount + back.photos.count))
                    }
                    team.restoreInFlightQueued([back.id], to: chatKey)
                    Diag.note("撤回的草稿没存进手机，原消息已留在排队里。")
                }
            }
        } else if let textSnapshot {
            Task {
                let ok = await DraftTextStore.saveResult(textSnapshot, for: chatKey)
                if ok {
                    team.confirmQueuedRemoved([back.id], for: chatKey)
                } else {
                    draftState.removeQueuedId(back.id)
                    if draftState.text == back.text {
                        draftState.text = ""
                    } else if draftState.text.hasSuffix("\n" + back.text) {
                        draftState.text = String(draftState.text.dropLast(back.text.count + 1))
                    }
                    draftState.flush()
                    team.restoreInFlightQueued([back.id], to: chatKey)
                    Diag.note("撤回的草稿文字没存进手机，原消息已留在排队里。")
                }
            }
        } else {
            team.confirmQueuedRemoved([back.id], for: chatKey)
        }
        typing.wrappedValue = true
    }

    /// Starts dictation; what is heard is added after what was already written.
    func listen() {
        if let existing = dictationSlot.instance, existing.busy { return }
        let active = dictationSlot.ensure()
        if voice.isSpeaking {
            _ = voice.stopSpeaking(at: .immediate)
            speakingText = nil
        }
        Haptics.grab()
        typing = false
        dictationMerger.start(initialDraft: draft)
        active.onText = { heard in
            draft = dictationMerger.merge(currentDraft: draft, heard: heard)
        }
        Task { await active.start() }
    }

    /// Siri or a shortcut sent us here: put the words in, listen, or just wait at the composer. Nothing is sent.
    func takeShortcut() {
        guard let ask = ShortcutDoor.take(for: chat.key) else { return }
        switch ask {
        case .ask(let words):
            let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                draft = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? trimmed : draft + "\n\n" + trimmed
            }
            typing = true
        case .dictate:
            listen()
        case .fresh:
            typing = true
        case .importedFiles(let paths, let failed):
            if !paths.isEmpty {
                withAnimation(Ink.Motion.settle) {
                    for rel in paths where !files.contains(rel) {
                        files.append(rel)
                    }
                }
                Haptics.tick(0.6)
            }
            if let firstError = failed.first {
                say(firstError)
            }
            typing = true
        }
    }

    var composerBar: some View {
        bottomStack
    }

    var bottomStack: some View {
        ChatBottomStackView(
            chat: chat,
            team: team,
            bot: bot,
            chrome: chrome,
            petPerch: petPerch,
            asker: asker,
            dictationSlot: dictationSlot,
            draftState: draftState,
            followState: followState,
            idleMood: idleMood,
            notice: notice,
            awayState: awayState,
            contextMetrics: contextMetrics,
            workTimer: workTimer,
            finding: finding,
            historyInView: historyPage != nil,
            largeText: largeText,
            confirmStop: confirmStop,
            calmPetMotion: calmPetMotion,
            chatViewport: chatViewport,
            coveredByPage: side.choosingFresh || petSettingsOpen || roaming || approving != nil || tuningOpen || scanning || takingPhoto,
            baseSheetOpen: attaching || usageOpen || abilities || outlining || quoting != nil || savingNote != nil,
            typing: $typing,
            usageOpen: $usageOpen,
            pickerShown: $pickerShown,
            importingFile: $importingFile,
            picks: $picks,
            attaching: $attaching,
            dockOpen: $dockOpen,
            askingStop: $askingStop,
            detailOpen: $detailOpen,
            roaming: $roaming,
            petSettingsOpen: $petSettingsOpen,
            editing: $editing,
            quote: $quote,
            photos: $photos,
            files: $files,
            following: $following,
            onPresentApproval: { approval in presentApproval(approval) },
            onToEnd: { toEnd() },
            onPreviousQuestion: { stepQuestion(earlier: true) },
            onNextQuestion: { stepQuestion(earlier: false) },
            onReturnToLatest: returnToLatest,
            onClearComposer: clearComposer,
            onListen: listen,
            onRedoFrom: { entry, text in redo(from: entry, text: text) },
            onPasteChange: { old, new in keepLongPaste(old, new) },
            onReceiveURLs: { urls in receive(urls) },
            fileNote: { fileNote },
            outgoingText: { outgoing },
            findBar: { findBar }
        )
    }

    var petDockMotion: Animation {
        calmPetMotion ? .easeInOut(duration: 0.22) : Ink.Motion.unfold
    }

    private var observers: some View {
        ChatConversationObservers(
            chat: chat,
            team: team,
            viewport: viewport,
            idleMood: idleMood,
            awayState: awayState,
            contextMetrics: contextMetrics,
            followState: followState,
            workTimer: workTimer,
            following: following,
            usageOpen: usageOpen,
            typing: $typing,
            onStir: stir,
            onClearedLines: {
                historyPage = nil
                lookupRows = []
            },
            onFollowToEnd: { followToEnd() },
            onApprovalInsetChanged: { approvalInsetChanged() },
            onTakeShortcut: takeShortcut
        )
    }

    func syncBridge() {
        let chatRef = chat
        let teamRef = team
        let draftRef = draftState
        let noticeRef = notice
        let dictationRef = dictationSlot
        let voiceRef = voice

        let viewingBinding = $viewing
        let quotingBinding = $quoting
        let editingBinding = $editing
        let typingBinding = $typing
        let roamingBinding = $roaming
        let readingBinding = $reading
        let leafingBinding = $leafing
        let savingNoteBinding = $savingNote
        let notingBinding = $noting
        let followingBinding = $following
        let undoAskBinding = $undoAsk
        let tuningOpenBinding = $tuningOpen
        let careOpenBinding = $careOpen
        let speakingTextBinding = $speakingText
        let photosBinding = $photos
        let filesBinding = $files
        let queuedIdsBinding = $draftAttachmentQueuedIds

        let bridgeRef = bridge
        bridge.onViewPhoto = { [weak bridgeRef] ref in
            bridgeRef?.activeViewingPhotoID = ref
            viewingBinding.wrappedValue = ref
        }
        bridge.onQuote = { id, text in quotingBinding.wrappedValue = Noting(id: id, text: text) }
        bridge.onEdit = { [weak draftRef] id, text in
            withAnimation(Ink.Motion.settle) {
                editingBinding.wrappedValue = id
                draftRef?.text = text
            }
            typingBinding.wrappedValue = true
        }
        bridge.onOpenURL = { [weak teamRef] url in
            typingBinding.wrappedValue = false
            if let teamRef { Task { await teamRef.browser.open(url) } }
            roamingBinding.wrappedValue = true
        }
        bridge.onOpenFile = { url, mount in readingBinding.wrappedValue = ReadingFile(url: url, mount: mount) }
        bridge.onOpenLeaves = { leafingBinding.wrappedValue = true }
        bridge.onAct = { [weak chatRef, weak teamRef, weak noticeRef] next in
            guard let chatRef, let teamRef, let noticeRef else { return }
            Self.performAct(
                next,
                chat: chatRef,
                team: teamRef,
                notice: noticeRef,
                following: followingBinding,
                undoAsk: undoAskBinding,
                tuningOpen: tuningOpenBinding,
                careOpen: careOpenBinding
            )
        }
        bridge.onSpeak = { [weak dictationRef, weak voiceRef] text in
            guard let dictationRef, let voiceRef else { return }
            Self.performSpeak(text, dictationSlot: dictationRef, voice: voiceRef, speakingText: speakingTextBinding)
        }
        bridge.onSaveNote = { id, text in savingNoteBinding.wrappedValue = Noting(id: id, text: text) }
        bridge.onLongNote = { id, text in notingBinding.wrappedValue = Noting(id: id, text: text) }
        bridge.onFork = { [weak chatRef, weak teamRef] line in
            guard let chatRef, let teamRef else { return }
            Haptics.thud()
            teamRef.fork(chatRef.key, at: line.id)
        }
        bridge.onRedo = { [weak chatRef, weak teamRef] in
            guard let chatRef, let teamRef else { return }
            Self.performRedo(chat: chatRef, team: teamRef, following: followingBinding, undoAsk: undoAskBinding)
        }
        bridge.onContinueStepLimit = { [weak chatRef] in
            guard let chatRef else { return }
            followingBinding.wrappedValue = true
            _ = chatRef.send(L.t("chat.continuePrompt"), photos: [])
        }
        bridge.onSay = { [weak noticeRef] text in
            guard let noticeRef else { return }
            Self.postComposerNotice(text, to: noticeRef)
        }
        bridge.onRetry = { [weak chatRef] in
            guard let chatRef else { return }
            followingBinding.wrappedValue = true
            chatRef.retry()
        }
        bridge.onWithdrawQueued = { [weak chatRef, weak teamRef, weak draftRef] item in
            guard let chatRef, let teamRef, let draftRef else { return }
            Self.performWithdrawQueued(
                item,
                chat: chatRef,
                team: teamRef,
                draftState: draftRef,
                photos: photosBinding,
                files: filesBinding,
                draftAttachmentQueuedIds: queuedIdsBinding,
                typing: typingBinding
            )
        }
        bridge.onSendQueuedNow = { [weak chatRef, weak teamRef] in
            guard let chatRef, let teamRef else { return }
            Haptics.thud()
            followingBinding.wrappedValue = true
            teamRef.sendQueueNow(chatRef.key)
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Ink.paper.ignoresSafeArea()
            conversation
            if !roaming {
                HStack {
                    Spacer()
                    ChatRoamThumbOverlay(browser: team.browser, chrome: chrome) {
                        typing = false
                        roaming = true
                    }
                }
                .padding(.top, (headerHeight > 0 ? headerHeight : Ink.Bar.height + Ink.Space.s) + Ink.Space.s)
                .padding(.trailing, Ink.Bar.edge)
                .zIndex(3)
            }
        }
        .background { observers }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { chatViewport = $0 }
        .safeAreaInset(edge: .bottom) { bottomStack }
        .sheet(isPresented: $petSettingsOpen) { PetPage() }
        .sheet(isPresented: $usageOpen) {
            UsageSheet(team: team, key: chat.key)
                .presentationDetents([.medium, .large])
        }
        .onAppear {
            syncBridge()
            DiagTrail.record("开对话(\(chat.lines.count)条)")
            chat.open()
            PetNews.shared.focused = chat.key
            draftState.load(chat.key)
            if photos.isEmpty, files.isEmpty {
                let kept = DraftAttachments.load(chat.key)
                photos = kept.photos
                files = kept.files
                draftAttachmentQueuedIds = kept.queuedIds
            }
        }
        .onChange(of: scenePhase) { _, next in
            if next == .background {
                DiagTrail.record("退后台")
                dictationSlot.cancelIfActive()
                _ = voice.stopSpeaking(at: .immediate)
                speakingText = nil
            } else if next == .active {
                DiagTrail.record("回前台")
            }
            if next != .active {
                draftState.flush()
                DraftAttachments.save(photos: photos, files: files, chat: chat.key, queuedIds: draftAttachmentQueuedIds)
            }
        }
        .hitchPage(isRoom ? "雅集" : "絮语")
        .onDisappear {
            DiagTrail.record("关对话")
            if PetNews.shared.focused == chat.key { PetNews.shared.focused = nil }
            followPending?.cancel()
            settleEnd?.cancel()
            settleJump?.cancel()
            approvalInsetTask?.cancel()
            approvalInsetTask = nil
            draftState.flush()
            DraftAttachments.save(photos: photos, files: files, chat: chat.key, queuedIds: draftAttachmentQueuedIds)
            chat.close()
            team.markSeen(chat.key)
            hideJumps?.cancel()
            earlierTask?.cancel()
            cancelFindTasks()
            pasteTask?.cancel()
            selecting.removeAll()
            dictationSlot.cancelIfActive()
            _ = voice.stopSpeaking(at: .immediate)
            speakingText = nil
            bridge.unbind()
        }
        .sheet(item: $noting) { note in
            NoteSheet(text: note.text, from: isRoom ? Words.t("雅集 · \(bot.name)") : bot.name, question: askedBefore(note.id),
                      bot: isRoom ? nil : bot)
        }
        .sheet(item: $savingNote) { note in
            SaveNoteSheet(
                text: note.text,
                question: askedBefore(note.id),
                sender: isRoom ? Words.t("雅集 · \(bot.name)") : bot.name
            ) { savedPath in
                say(Words.t("已存成笔记：书案/\(savedPath)"))
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $quoting) { item in
            QuoteSheet(text: item.text) { picked in
                quoting = nil
                guard let picked else { return }
                withAnimation(Ink.Motion.settle) { quote = picked }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { typing = true }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $cardOpen) { NameCardSheet(team: team, bot: bot) }
        .alert(L.t("errors.exportChat"), isPresented: $exportFailed) {
            Button(L.t("actions.done"), role: .cancel) {}
        }
        .alert("重命名对话", isPresented: $renaming) {
            TextField("对话标题", text: $renameText)
            Button(L.t("actions.cancel"), role: .cancel) {}
            Button(L.t("actions.save")) { team.rename(chat.key, to: renameText) }
        }
        .fullScreenCover(isPresented: $tuningOpen) { SettingsView(team: team) }
        .sheet(isPresented: $careOpen) { CarePage(team: team) }
        .sheet(isPresented: $filesOpen) { StudyPage() }
        .sheet(item: $sharing) { file in ChatShareSheet(url: file.url) }
        .fullScreenCover(isPresented: $terminalOpen) { InkstonePage() }
        .sheet(isPresented: $chatSkillsOpen) { SkillsPage() }
        .sheet(isPresented: $chatConnectorsOpen) { ConnectorsPage() }
        .confirmationDialog(L.t("chat.clearConfirm"), isPresented: $clearingChat, titleVisibility: .visible) {
            Button(L.t("actions.clear"), role: .destructive) {
                team.clearChat(chat.key)
                jumpedTo = nil
            }
            Button(L.t("actions.cancel"), role: .cancel) {}
        } message: {
            Text(L.t("errors.cannotUndo"))
        }
        .sheet(isPresented: $detailOpen, onDismiss: {
            // Open what was asked for from the detail page once it is out of the way.
            if afterDetail == "card" { cardOpen = true }
            if afterDetail == "leaves" { leafing = true }
            afterDetail = nil
        }) {
            ChatDetail(team: team, chat: chat, title: team.title(of: chat.key) ?? bot.name,
                       bot: isRoom ? nil : bot,
                       openCard: isRoom ? nil : { afterDetail = "card" },
                       openLeaves: { afterDetail = "leaves" })
        }
        .sheet(isPresented: $attaching, onDismiss: {
            // The sheet is out of the way; now open what was picked.
            if let kind = attachPicked {
                attachPicked = nil
                bring(kind)
            }
        }) {
            let revision = attachmentRevision
            PlusSheet(team: team, key: chat.key, name: bot.name, isRoom: isRoom, addPhoto: { data in
                await addPhoto(data, revision: revision)
            }, removePhoto: { data in
                if let index = photos.firstIndex(of: data) { _ = withAnimation(Ink.Motion.settle) { photos.remove(at: index) } }
            }, pick: { attachPicked = $0 })
            // Half open: photos, camera and files at hand; pull up for the rest.
            .presentationDetents([.medium, .large])
            .presentationBackgroundInteraction(.disabled)
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $deskPicking) {
            DeskPicker { picked in
                deskPicking = false
                if !picked.isEmpty {
                    withAnimation(Ink.Motion.settle) { files += picked.filter { !files.contains($0) } }
                    say(Words.t("带上了书案里的 \(picked.count) 个文件。"))
                }
            }
        }
        .fullScreenCover(isPresented: $scanning) {
            ScannerView { pages in
                scanning = false
                guard !pages.isEmpty else { return }
                say(L.t("loading.recognizingScan"))
                Task {
                    if let kept = await Scan.keep(pages) {
                        withAnimation(Ink.Motion.settle) { files.append(kept.text) }
                        say(Words.t("扫了 \(pages.count) 页，认出 \(kept.count) 个字，图和文字都放进了书案。"))
                    }
                }
            }
            .ignoresSafeArea()
        }
        .alert(Words.t("请旅伴读一个网页"), isPresented: $linkAsking) {
            TextField("https://…", text: $linkDraft)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
            Button("带上") {
                let link = linkDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                if !link.isEmpty { draft += (draft.isEmpty ? "" : "\n") + "请读一下这个网页：\(link)" }
                linkDraft = ""
                typing = true
            }
            Button("算了", role: .cancel) { linkDraft = "" }
        } message: {
            Text(Words.t("旅伴会去读，读不出来时会用远游打开。"))
        }
        .sheet(isPresented: $abilities) {
            AbilitiesSheet(team: team, key: chat.key, name: bot.name)
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $reading) { file in
            NavigationStack { StudyFile(url: file.url, mount: file.mount, showsDone: true) }
        }
        .sheet(isPresented: $outlining, onDismiss: { lookupRows = [] }) {
            OutlineSheet(pairs: outlinePairs) { id in
                outlining = false
                settleJump?.cancel()
                viewport.advanceNavigation()
                let generation = viewport.navigationGeneration
                reveal(id)
                following = false
                Task { @MainActor in
                    do { try await Task.sleep(nanoseconds: 350_000_000) } catch { return }
                    guard !Task.isCancelled,
                          generation == viewport.navigationGeneration,
                          !viewport.isTouching, !touchScrolling else { return }
                    viewport.recordJump("点了提纲")
                    withAnimation(Ink.Motion.settle) { scroller?.scrollTo(id, anchor: .top) }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $picking) { line in
            PickWords(text: line.text)
        }
        .sheet(isPresented: $leafing) {
            LeavesSheet(team: team, key: chat.key, name: bot.name)
                .presentationDetents([.medium, .large])
        }
        .confirmationDialog(
            undoAsk.map { "这一轮改过 \($0.files.count) 个文件" } ?? "",
            isPresented: Binding(get: { undoAsk != nil }, set: { if !$0 { undoAsk = nil } }),
            titleVisibility: .visible,
            presenting: undoAsk
        ) { ask in
            Button("文件也还原，再来") { finishRedo(ask, restoring: true) }
            Button("只重来，文件留着") { finishRedo(ask, restoring: false) }
            Button("算了", role: .cancel) {}
        } message: { ask in
            Text(ask.files.prefix(6).joined(separator: "\n") + (ask.files.count > 6 ? "\n……" : "") + "\n\n还原就是放回这一轮动手之前的样子；新建的文件会删掉。")
        }
        .fullScreenCover(isPresented: $roaming) {
            RoamPage(browser: team.browser)
        }
        .sheet(item: $approving, onDismiss: { followToEnd() }) { approval in
            ApproveView(approval: approval, team: team)
                .presentationDetents([.large])
        }
        .fullScreenCover(isPresented: $takingPhoto) {
            let revision = attachmentRevision
            CameraPicker { image in
                guard let image else { return }
                Task {
                    let photo = await Task.detached(priority: .userInitiated) {
                        image.jpegData(compressionQuality: 0.9)
                    }.value
                    if let photo { _ = await addPhoto(photo, revision: revision) }
                }
            }
            .ignoresSafeArea()
        }
        .onChange(of: viewing) { _, next in
            if let next {
                bridge.activeViewingPhotoID = next
                if presentedViewing?.id != next {
                    presentedViewing = Viewing(id: next, canZoom: !calmPetMotion && canZoomPhoto(next))
                }
            } else {
                presentedViewing = nil
            }
        }
        .fullScreenCover(item: $presentedViewing, onDismiss: {
            let dismissedID = bridge.activeViewingPhotoID
            bridge.activeViewingPhotoID = nil
            viewing = nil
            if let dismissedID {
                bridge.onDismissPhotoHero?(dismissedID)
            }
        }) { item in
            PhotoViewer(chat: chat, attachmentId: item.id)
                .presentationBackground(.clear)
                .modifier(PhotoZoomDestinationModifier(
                    id: item.id,
                    namespace: photoZoom,
                    enabled: item.canZoom
                ))
        }
        .onChange(of: finding) { _, now in
            DiagTrail.record(now ? "开查找" : "关查找")
        }
        .task(id: picks) {
            let items = picks
            let revision = attachmentRevision
            guard !items.isEmpty else { return }
            for item in items {
                guard !Task.isCancelled, revision == attachmentRevision, picks == items, photos.count < 4 else { return }
                if let data = try? await item.loadTransferable(type: Data.self) {
                    _ = await addPhoto(data, revision: revision, selection: items)
                }
            }
            if !Task.isCancelled, revision == attachmentRevision, picks == items { picks = [] }
        }
    }

    @State var exportFailed = false
    struct ShareFile: Identifiable { let url: URL; var id: URL { url } }

    struct Viewing: Identifiable { let id: String; let canZoom: Bool }
    struct Noting: Identifiable { let id: String; let text: String }

    private func canZoomPhoto(_ id: String) -> Bool {
        useUIKitChatList ? (bridge.matchedHeroID == id) : true
    }

    /// What you asked just before a reply, for the picture of the exchange.
    func askedBefore(_ id: String) -> String? {
        guard let index = displayedRows.firstIndex(where: { $0.id == id }) else { return nil }
        return displayedRows[..<index].last(where: { $0.kind == .user && !$0.text.isEmpty })?.text
    }
    @State var noting: Noting?
    @State var savingNote: Noting?
    @State var quoting: Noting?
    /// Words from a reply the next message asks about.
    @State var quote: String?
    @State var roaming = false
    /// A retry or an edit waiting to hear whether the files it changed should go back too.
    @State var undoAsk: UndoAsk?
    @State var leafing = false
    struct ReadingFile: Identifiable {
        let url: URL
        var mount: MountedFolder? = nil
        var id: String { (mount?.id ?? "desk") + "|" + url.path }
    }
    @State var reading: ReadingFile?

    func leave() {
        typing = false
        dictationSlot.cancelIfActive()
        _ = voice.stopSpeaking(at: .immediate)
        speakingText = nil
        Haptics.light()
        back()
    }

    @State var sourcesMemo = SourcesMemo()
    @State var followPending: Task<Void, Never>?
    @State var approvalInsetTask: Task<Void, Never>?
    @State var settleEnd: Task<Void, Never>?
    @State var settleJump: Task<Void, Never>?
    @State var pickerShown = false
    @State var importingFile = false
    @State var files: [String] = []
    @State var abilities = false
    @State var attaching = false
    @State var filesOpen = false
    @State var dockOpen = false
    @State var detailOpen = false
    @State var afterDetail: String?
    @State var attachPicked: AttachKind?
    @State var deskPicking = false
    @State var scanning = false
    @State var linkAsking = false
    @State var linkDraft = ""
    @State var cardOpen = false
    @State var glancing = false
    @State var outlining = false
    @State var renaming = false
    @State var renameText = ""
    @State var tuningOpen = false
    @State var careOpen = false
    @State var petSettingsOpen = false
}

@MainActor @Observable
final class ChatIdleMood {
    var cheering = false
    var dozing = false
}

@MainActor @Observable
final class ChatComposerNotice {
    var text: String?
}

@MainActor @Observable
final class ChatAwayState {
    var items: [Happening] = []
}

@MainActor @Observable
final class ChatContextMetrics {
    var estimate: TeamModel.ContextEstimate?
}

@MainActor @Observable
final class ChatFollowState {
    var following = true
}

@MainActor @Observable
final class ChatWorkTimer {
    var since: Date?
}

@MainActor @Observable
final class ChatDictationSlot {
    private(set) var instance: Dictation?

    func ensure() -> Dictation {
        if let instance { return instance }
        let created = Dictation()
        instance = created
        return created
    }

    func cancelIfActive() {
        instance?.cancel()
    }
}

@MainActor
final class ChatRowBridge {
    var matchedHeroID: String?
    var activeViewingPhotoID: String?
    var onDismissPhotoHero: ((String) -> Void)?
    var onViewPhoto: (String) -> Void = { _ in }
    var onQuote: (String, String) -> Void = { _, _ in }
    var onEdit: (String, String) -> Void = { _, _ in }
    var onOpenURL: (URL) -> Void = { _ in }
    var onOpenFile: (URL, MountedFolder?) -> Void = { _, _ in }
    var onOpenLeaves: () -> Void = {}
    var onAct: (Explain.Next) -> Void = { _ in }
    var onSpeak: (String) -> Void = { _ in }
    var onSaveNote: (String, String) -> Void = { _, _ in }
    var onLongNote: (String, String) -> Void = { _, _ in }
    var onFork: (ChatLine) -> Void = { _ in }
    var onRedo: () -> Void = {}
    var onContinueStepLimit: () -> Void = {}
    var onSay: (String) -> Void = { _ in }
    var onRetry: () -> Void = {}
    var onWithdrawQueued: (TeamModel.Queued) -> Void = { _ in }
    var onSendQueuedNow: () -> Void = {}

    func unbind() {
        matchedHeroID = nil
        activeViewingPhotoID = nil
        onDismissPhotoHero = nil
        onViewPhoto = { _ in }
        onQuote = { _, _ in }
        onEdit = { _, _ in }
        onOpenURL = { _ in }
        onOpenFile = { _, _ in }
        onOpenLeaves = {}
        onAct = { _ in }
        onSpeak = { _ in }
        onSaveNote = { _, _ in }
        onLongNote = { _, _ in }
        onFork = { _ in }
        onRedo = {}
        onContinueStepLimit = {}
        onSay = { _ in }
        onRetry = {}
        onWithdrawQueued = { _ in }
        onSendQueuedNow = {}
    }
}

struct ChatEarlierButtonView: View {
    let chat: ChatModel
    let historyInView: Bool
    let shownCount: Int
    let onLoadEarlier: () -> Void

    private var canLoadEarlier: Bool {
        !historyInView && (chat.lines.count > shownCount || chat.hasEarlier)
    }

    var body: some View {
        if canLoadEarlier {
            Button {
                Haptics.light()
                onLoadEarlier()
            } label: {
                Label(L.t("chat.earlier"), systemImage: "arrow.up")
                    .font(.system(size: Ink.Size.small, weight: .medium))
                    .foregroundStyle(Ink.inkSoft)
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(TapStyle())
        }
    }
}

struct ChatEmptyContentView: View {
    let chat: ChatModel
    @ObservedObject var team: TeamModel
    let bot: BotInfo
    let dictationSlot: ChatDictationSlot
    let idleMood: ChatIdleMood
    let starters: [(String, String, String)]
    let reach: String
    let typing: FocusState<Bool>.Binding
    let onPickStarter: (String) -> Void

    private var isRoom: Bool { chat.roomId != nil }
    private var doing: String? { team.workDetail(for: chat.key).words }
    private var working: Bool { doing != nil || chat.hasStreaming }
    private var waiting: Approval? { team.approvals.first { $0.chat == chat.key } }

    var body: some View {
        VStack(spacing: Ink.Space.l) {
            ChatEmptyPetFace(
                dictationSlot: dictationSlot,
                waiting: waiting,
                hasStreaming: chat.hasStreaming,
                doing: doing,
                working: working,
                typing: typing.wrappedValue,
                cheering: idleMood.cheering,
                dozing: idleMood.dozing,
                isRoom: isRoom,
                bot: bot
            )
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
                        onPickStarter(item.1)
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
}

private struct ChatEmptyPetFace: View {
    let dictationSlot: ChatDictationSlot
    let waiting: Approval?
    let hasStreaming: Bool
    let doing: String?
    let working: Bool
    let typing: Bool
    let cheering: Bool
    let dozing: Bool
    let isRoom: Bool
    let bot: BotInfo

    var body: some View {
        if let dictation = dictationSlot.instance {
            ChatActiveEmptyPetFace(
                dictation: dictation,
                waiting: waiting,
                hasStreaming: hasStreaming,
                doing: doing,
                working: working,
                typing: typing,
                cheering: cheering,
                dozing: dozing,
                isRoom: isRoom,
                bot: bot
            )
        } else {
            let state = ChatPage.companionPetState(
                waiting: waiting,
                hasStreaming: hasStreaming,
                doing: doing,
                working: working,
                typing: typing,
                listening: false,
                cheering: cheering,
                dozing: dozing
            )
            PetStill(size: 96, state: state, bot: isRoom ? nil : bot)
        }
    }
}

private struct ChatActiveEmptyPetFace: View {
    @ObservedObject var dictation: Dictation
    let waiting: Approval?
    let hasStreaming: Bool
    let doing: String?
    let working: Bool
    let typing: Bool
    let cheering: Bool
    let dozing: Bool
    let isRoom: Bool
    let bot: BotInfo

    var body: some View {
        let state = ChatPage.companionPetState(
            waiting: waiting,
            hasStreaming: hasStreaming,
            doing: doing,
            working: working,
            typing: typing,
            listening: dictation.listening,
            cheering: cheering,
            dozing: dozing
        )
        PetStill(size: 96, state: state, bot: isRoom ? nil : bot)
    }
}

/// Hosts stream, status, mood, and context observers outside `ChatPage.body` so high-frequency updates
/// never force settled message rows or the composer container to re-evaluate.
struct ChatConversationObservers: View {
    let chat: ChatModel
    @ObservedObject var team: TeamModel
    let viewport: ChatViewport
    let idleMood: ChatIdleMood
    let awayState: ChatAwayState
    let contextMetrics: ChatContextMetrics
    let followState: ChatFollowState
    let workTimer: ChatWorkTimer

    let following: Bool
    let usageOpen: Bool
    let typing: FocusState<Bool>.Binding

    let onStir: () -> Void
    let onClearedLines: () -> Void
    let onFollowToEnd: () -> Void
    let onApprovalInsetChanged: () -> Void
    let onTakeShortcut: () -> Void

    private var doing: String? { team.workDetail(for: chat.key).words }
    private var working: Bool { doing != nil || chat.hasStreaming }
    private var waiting: Approval? { team.approvals.first { $0.chat == chat.key } }

    private var showsLive: Bool {
        guard doing != nil || waiting != nil else { return false }
        if let last = chat.lines.last, last.kind == .steps, last.live { return false }
        return !chat.hasStreaming || waiting != nil
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: following, initial: true) { _, now in
                if followState.following != now { followState.following = now }
            }
            .onChange(of: working, initial: true) { _, now in
                workTimer.since = now ? (workTimer.since ?? Date()) : nil
            }
            .onChange(of: working) { _, now in
                onStir()
                guard !now, chat.error == nil, chat.lines.last?.kind == .bot else { return }
                idleMood.cheering = true
                Task {
                    try? await Task.sleep(nanoseconds: 2_400_000_000)
                    idleMood.cheering = false
                }
            }
            .onChange(of: chat.hasStreaming) { _, now in
                DiagTrail.record(now ? "开始流式" : "结束流式")
            }
            .onChange(of: showsLive) { onFollowToEnd() }
            .onChange(of: waiting?.id) { _, next in
                DiagTrail.record(next == nil ? "收起审批" : "弹出审批")
                onApprovalInsetChanged()
            }
            .background {
                ChatSecondaryObservers(
                    chat: chat,
                    team: team,
                    viewport: viewport,
                    idleMood: idleMood,
                    awayState: awayState,
                    contextMetrics: contextMetrics,
                    working: working,
                    usageOpen: usageOpen,
                    typing: typing,
                    onStir: onStir,
                    onClearedLines: onClearedLines,
                    onFollowToEnd: onFollowToEnd,
                    onTakeShortcut: onTakeShortcut
                )
            }
    }
}

private struct ChatSecondaryObservers: View {
    let chat: ChatModel
    @ObservedObject var team: TeamModel
    let viewport: ChatViewport
    let idleMood: ChatIdleMood
    let awayState: ChatAwayState
    let contextMetrics: ChatContextMetrics
    let working: Bool
    let usageOpen: Bool
    let typing: FocusState<Bool>.Binding

    let onStir: () -> Void
    let onClearedLines: () -> Void
    let onFollowToEnd: () -> Void
    let onTakeShortcut: () -> Void

    private var estimateTrigger: String {
        let folding = team.compressing.contains(chat.key)
        let lastFold = chat.lines.last(where: { $0.fold })?.id ?? ""
        let summaryLen = team.cachedSummaryLength(chat.key)
        return "\(chat.loaded)|\(working)|\(folding)|\(lastFold)|\(summaryLen)|\(chat.lines.count)|\(chat.lines.last?.id ?? "")|\(team.options(chat.key).model ?? "")|\(Pref.contextShare)|\(usageOpen)"
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: typing.wrappedValue) { _, now in
                DiagTrail.record(now ? "开键盘" : "收键盘")
                Hitches.shared.doing(now ? "打字" : nil, as: "typing")
                onStir()
            }
            .onChange(of: chat.lines.last?.id) { _, _ in
                if chat.lines.isEmpty { onClearedLines() }
                if chat.lines.last?.kind == .bot { Haptics.tick(0.45) }
                onFollowToEnd()
            }
            .onChange(of: chat.lines.count) { onFollowToEnd() }
            .onChange(of: chat.error) { onFollowToEnd() }
            .onChange(of: team.queued[chat.key]?.count ?? 0) { onFollowToEnd() }
            .task {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    let idle = ProcessInfo.processInfo.systemUptime - viewport.lastStirAt
                    if idle >= 180, !idleMood.dozing { idleMood.dozing = true }
                }
            }
            .task { awayState.items = team.whileAway(from: chat.key) }
            .task {
                try? await Task.sleep(nanoseconds: 400_000_000)
                onTakeShortcut()
            }
            .onReceive(NotificationCenter.default.publisher(for: .clioShortcutReady)) { _ in onTakeShortcut() }
            .task(id: estimateTrigger) {
                guard chat.loaded, !working else { return }
                do { try await Task.sleep(for: .milliseconds(90)) } catch { return }
                let estimate = await team.contextEstimate(chat.key)
                if !Task.isCancelled { contextMetrics.estimate = estimate }
            }
    }
}

struct ChatSection<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View { content() }
}

@MainActor @Observable
final class ChatDraft {
    private(set) var hasText = false
    private(set) var hasSendableText = false

    var text = "" {
        didSet {
            guard oldValue != text else { return }
            let hasText = !text.isEmpty
            let hasSendableText = text.unicodeScalars.contains { !CharacterSet.whitespacesAndNewlines.contains($0) }
            if self.hasText != hasText { self.hasText = hasText }
            if self.hasSendableText != hasSendableText { self.hasSendableText = hasSendableText }
            guard key != nil else { return }
            if text.isEmpty {
                flush()
                return
            }
            save?.cancel()
            save = Task {
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                flush()
            }
        }
    }

    var skills: [SkillShelf.Item] = []
    var files: [String] = []
    @ObservationIgnored private var key: String?
    @ObservationIgnored private var chatKey: String?
    @ObservationIgnored private var queuedIds: [UUID] = []
    @ObservationIgnored private var save: Task<Void, Never>?

    func load(_ chat: String) {
        guard key == nil else { return }
        chatKey = chat
        let loaded = DraftTextStore.load(for: chat)
        text = loaded.text
        queuedIds = loaded.queuedIds
        key = "draft." + chat
    }

    func recordQueuedId(_ id: UUID) {
        if !queuedIds.contains(id) { queuedIds.append(id) }
    }

    func removeQueuedId(_ id: UUID) {
        queuedIds.removeAll { $0 == id }
    }

    /// Cancels any debounced save and captures a snapshot for atomic write-then-confirm unqueue flows.
    func prepareAtomicSave() -> StoredTextDraft {
        save?.cancel()
        save = nil
        return StoredTextDraft(text: text, queuedIds: queuedIds)
    }

    func flush() {
        save?.cancel()
        save = nil
        guard let chatKey else { return }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queuedIds.removeAll()
            DraftTextStore.save(StoredTextDraft(text: "", queuedIds: []), for: chatKey)
        } else {
            DraftTextStore.save(StoredTextDraft(text: text, queuedIds: queuedIds), for: chatKey)
        }
    }
}

/// Atomically stores per-chat text drafts and unqueued IDs on disk (under Application Support/ClioDrafts),
/// replacing non-durable `UserDefaults` so pure-text unqueues only delete the source queue after disk confirmation.
enum DraftTextStore {
    private static let queue = DispatchQueue(label: "clio.draft-text", qos: .utility)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pendingCount = 0

    private static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClioDrafts", isDirectory: true)
    }

    static func save(
        _ draft: StoredTextDraft,
        for chat: String,
        onSaved: (@Sendable (Bool) -> Void)? = nil
    ) {
        guard !Disk.frozen else {
            onSaved?(false)
            return
        }
        let base = root
        lock.withLock { pendingCount += 1 }
        queue.async {
            defer { lock.withLock { pendingCount = max(0, pendingCount - 1) } }
            guard !Disk.frozen else {
                onSaved?(false)
                return
            }
            do {
                try QueuedMessageStore.saveTextDraft(draft, for: chat, under: base)
                UserDefaults.standard.removeObject(forKey: "draft." + chat)
                UserDefaults.standard.removeObject(forKey: "draft.queuedIds." + chat)
                onSaved?(true)
            } catch {
                onSaved?(false)
            }
        }
    }

    static func saveResult(_ draft: StoredTextDraft, for chat: String) async -> Bool {
        await withCheckedContinuation { continuation in
            save(draft, for: chat) { ok in
                continuation.resume(returning: ok)
            }
        }
    }

    static func load(for chat: String) -> StoredTextDraft {
        queue.sync {}
        if let saved = QueuedMessageStore.loadTextDraft(for: chat, under: root) {
            return saved
        }
        // Migrate any legacy draft previously stored in UserDefaults.
        let legacyText = UserDefaults.standard.string(forKey: "draft." + chat) ?? ""
        guard !legacyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return StoredTextDraft(text: "", queuedIds: [])
        }
        return StoredTextDraft(text: legacyText, queuedIds: [])
    }

    /// Queued message IDs confirmed in the atomic on-disk text draft file for `chat`.
    static func storedQueuedIds(for chat: String) -> Set<UUID> {
        queue.sync {}
        guard let saved = QueuedMessageStore.loadTextDraft(for: chat, under: root) else {
            return []
        }
        return Set(saved.queuedIds)
    }

    @MainActor
    static func finishBeforeSuspension() {
        guard lock.withLock({ pendingCount > 0 }) else { return }
        let app = UIApplication.shared
        var token = UIBackgroundTaskIdentifier.invalid
        func end() {
            guard token != .invalid else { return }
            app.endBackgroundTask(token)
            token = .invalid
        }
        token = app.beginBackgroundTask(withName: "clio-draft-text") { end() }
        queue.async {
            DispatchQueue.main.async { end() }
        }
    }
}

enum DraftInput {
    static let pasteLimit = 2500
    private static let queryLimit = 128

    enum Source: Equatable { case files, skills }

    struct Suggestion: Equatable {
        let source: Source
        let text: String
    }

    static func suggestion(in draft: String) -> Suggestion? {
        let start = draft.prefix(queryLimit + 1)
        if start.endIndex == draft.endIndex {
            let words = start.trimmingCharacters(in: .whitespaces)
            if words.hasPrefix("/"), !words.contains(where: \.isNewline) {
                return Suggestion(source: .skills, text: String(words.dropFirst()))
            }
        }
        let token = draft.suffix(queryLimit + 1).reversed().prefix { !$0.isWhitespace }.reversed()
        guard token.count <= queryLimit, token.first == "@" else { return nil }
        let word = token.dropFirst()
        guard !word.contains("@") else { return nil }
        return Suggestion(source: .files, text: String(word))
    }

    static func longInsertion(from old: String, to new: String) -> String? {
        guard new.count - old.count > pasteLimit else { return nil }
        let start = zip(old, new).prefix { $0 == $1 }.count
        let tail = zip(old.dropFirst(start).reversed(), new.dropFirst(start).reversed()).prefix { $0 == $1 }.count
        return String(new.dropFirst(start).dropLast(tail))
    }
}

/// Pictures and files picked for a message not sent yet, kept across leaving the page or the app being closed.
/// Stored under Application Support/ClioDrafts so iOS cache purges cannot drop unqueued draft photos.
/// Saved off the main thread into a fresh folder that replaces the old one only once every picture is written, so a
/// failed or cut-short save leaves the last good copy (the review, #7). The file list lives in the same folder.
enum DraftAttachments {
    private static let queue = DispatchQueue(label: "clio.draft-attachments", qos: .utility)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pendingCount = 0

    private static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClioDrafts", isDirectory: true)
    }

    private static var legacyRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("drafts", isDirectory: true)
    }

    private static func folder(_ chat: String, under base: URL = root) -> URL {
        base.appendingPathComponent(chat.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
    }

    private struct Manifest: Codable {
        var photos: Int
        var files: [String]
        var queuedIds: [UUID]?
    }

    static func save(
        photos: [Data],
        files: [String],
        chat: String,
        queuedIds: [UUID] = [],
        onSaved: (@Sendable (Bool) -> Void)? = nil
    ) {
        guard !Disk.frozen else {
            onSaved?(false)
            return
        }
        let dir = folder(chat)
        let legacyDir = folder(chat, under: legacyRoot)
        lock.withLock { pendingCount += 1 }
        queue.async {
            defer { lock.withLock { pendingCount = max(0, pendingCount - 1) } }
            guard !Disk.frozen else {
                onSaved?(false)
                return
            }
            let manager = FileManager.default
            UserDefaults.standard.removeObject(forKey: "draftFiles." + chat)
            guard !photos.isEmpty || !files.isEmpty else {
                try? manager.removeItem(at: dir)
                try? manager.removeItem(at: legacyDir)
                onSaved?(true)
                return
            }
            let fresh = root.appendingPathComponent(".new-" + UUID().uuidString, isDirectory: true)
            do {
                try manager.createDirectory(at: fresh, withIntermediateDirectories: true)
                let writeOptions: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
                for (index, data) in photos.enumerated() {
                    try data.write(to: fresh.appendingPathComponent("\(index).img"), options: writeOptions)
                }
                let manifest = Manifest(photos: photos.count, files: files, queuedIds: queuedIds.isEmpty ? nil : queuedIds)
                try JSONEncoder().encode(manifest).write(to: fresh.appendingPathComponent("draft.json"), options: writeOptions)
                if manager.fileExists(atPath: dir.path) {
                    _ = try manager.replaceItemAt(dir, withItemAt: fresh)
                } else {
                    try manager.moveItem(at: fresh, to: dir)
                }
                try? manager.removeItem(at: legacyDir)
                onSaved?(true)
            } catch {
                try? manager.removeItem(at: fresh)
                onSaved?(false)
            }
        }
    }

    static func saveResult(photos: [Data], files: [String], chat: String, queuedIds: [UUID] = []) async -> Bool {
        await withCheckedContinuation { continuation in
            save(photos: photos, files: files, chat: chat, queuedIds: queuedIds) { ok in
                continuation.resume(returning: ok)
            }
        }
    }

    /// Forgets a chat's draft attachments, right when the message goes out.
    static func clear(_ chat: String) {
        save(photos: [], files: [], chat: chat)
    }

    static func load(_ chat: String) -> (photos: [Data], files: [String], queuedIds: [UUID]) {
        queue.sync {}
        let primary = folder(chat)
        if let loaded = loadFrom(dir: primary, chat: chat) {
            return loaded
        }
        let legacy = folder(chat, under: legacyRoot)
        if let loaded = loadFrom(dir: legacy, chat: chat) {
            return loaded
        }
        let files = UserDefaults.standard.stringArray(forKey: "draftFiles." + chat) ?? []
        return ([], files, [])
    }

    private static func loadFrom(dir: URL, chat: String) -> (photos: [Data], files: [String], queuedIds: [UUID])? {
        if let data = try? Data(contentsOf: dir.appendingPathComponent("draft.json")),
           let manifest = try? JSONDecoder().decode(Manifest.self, from: data) {
            let photos = (0..<manifest.photos).compactMap { try? Data(contentsOf: dir.appendingPathComponent("\($0).img")) }
            return (photos, manifest.files, manifest.queuedIds ?? [])
        }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".img") }
            .sorted { (Int($0.dropLast(4)) ?? 0) < (Int($1.dropLast(4)) ?? 0) }
        guard !names.isEmpty else { return nil }
        let photos = names.compactMap { try? Data(contentsOf: dir.appendingPathComponent($0)) }
        let files = UserDefaults.standard.stringArray(forKey: "draftFiles." + chat) ?? []
        return (photos, files, [])
    }

    /// Queued message IDs whose draft attachments are completely persisted on disk.
    static func storedQueuedIds(for chat: String) -> Set<UUID> {
        queue.sync {}
        let dir = folder(chat)
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("draft.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              let ids = manifest.queuedIds,
              !ids.isEmpty else {
            return []
        }
        for index in 0..<manifest.photos {
            guard let img = try? Data(contentsOf: dir.appendingPathComponent("\(index).img")), !img.isEmpty else {
                return []
            }
        }
        return Set(ids)
    }

    @MainActor
    static func finishBeforeSuspension() {
        guard lock.withLock({ pendingCount > 0 }) else { return }
        let app = UIApplication.shared
        var token = UIBackgroundTaskIdentifier.invalid
        func end() {
            guard token != .invalid else { return }
            app.endBackgroundTask(token)
            token = .invalid
        }
        token = app.beginBackgroundTask(withName: "clio-draft-attachments") { end() }
        queue.async {
            DispatchQueue.main.async { end() }
        }
    }
}

