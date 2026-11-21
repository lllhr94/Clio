import AVFoundation
import AgentKit
import CoreLocation
import Craft
import PhotosUI
import Observation
import SwiftUI
import UniformTypeIdentifiers
import VisionKit

/// 絮语: a conversation with one companion, set as a page.
struct ChatPage: View {
    @ObservedObject var team: TeamModel
    @State private var chat: ChatModel
    @StateObject private var dictation = Dictation()
    @ObservedObject private var asker = Asker.shared
    @State private var petPerch = PetPerch()
    @Environment(\.accessibilityReduceMotion) private var calmPetMotion
    @Environment(\.scenePhase) private var scenePhase
    /// Opens the sidebar. An object that stays the same, not a closure made anew: a new closure on every redraw of the
    /// desk made SwiftUI think the whole page had changed, and redraw all of it for every frame the sidebar slid.
    let side: SideControl
    private var back: () -> Void { side.open }

    @State private var draftState = ChatDraft()
    private var draft: String { get { draftState.text } nonmutating set { draftState.text = newValue } }
    @State private var spokenBase = ""
    @State private var photos: [Data] = []
    @State private var picks: [PhotosPickerItem] = []
    @State private var takingPhoto = false
    @State private var approving: Approval?
    @State private var viewing: String?
    /// The message being changed and sent again.
    @State private var editing: String?
    @State private var scroller: ScrollViewProxy?
    /// Whether the page keeps to the newest line as things arrive: off once the reader scrolls up to read,
    /// on again when they come back to the bottom, send something, or tap 回到最新.
    @State private var following = true
    /// 聊天里显示头像: off unless turned on (设置 › 对话 › 对话显示与反馈).
    @AppStorage("chat.faces") private var faces = false
    /// The stop button asks first (as Open Minis does): a long task lost to a thumb that slipped is worse than one more tap.
    @AppStorage("chat.confirmStop") private var confirmStop = true
    @State private var askingStop = false
    /// 在对话里找: what is looked for, and which of the places found is in view.
    @State private var finding = false
    @State private var findText = ""
    @State private var findAt = 0
    @State private var hits: [String] = []
    /// How many lines were on the page before finding or the outline opened everything; restored after.
    @State private var lookupRows: [ChatLine] = []
    @State private var historyPage: [ChatLine]?
    private var displayedRows: [ChatLine] { historyPage ?? chat.lines }
    @State private var outlinePairs: [OutlineSheet.Pair] = []
    @FocusState private var findFocus: Bool
    /// A reply opened to pick any words from it.
    @State private var picking: ChatLine?
    /// The message of yours 「回到我上一句」 went to last; the next tap goes one further up.
    @State private var jumpedTo: String?
    @State private var jumpVisible = false
    @State private var hideJumps: Task<Void, Never>?
    @State private var viewport = ChatViewport()
    @State private var selecting: Set<UUID> = []
    @State private var sharing: ShareFile?
    @State private var terminalOpen = false
    @State private var chatSkillsOpen = false
    @State private var chatConnectorsOpen = false
    @State private var clearingChat = false
    /// The conversation is moving under the reader's finger or settling after it.
    @State private var scrolling = false
    /// How full the next request will be; worked out when the page opens and after each turn, not on every word.
    @State private var context: TeamModel.ContextEstimate?
    @State private var usageOpen = false
    /// A turn has just finished well: the pet is glad.
    @State private var cheering = false
    /// Nothing has happened for a few minutes: the pet dozes.
    @State private var dozing = false
    @State private var stirs = 0
    /// How many of the newest lines are drawn; 「更早的」 adds more.
    @State private var shownCount = 60
    /// What happened in the other conversations while the user was away from this one.
    @State private var away: [Happening] = []
    @State private var farFromEnd = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var textScale: CGFloat = 1
    private var largeText: Bool { typeSize.isAccessibilitySize }

    @FocusState private var typing: Bool
    @State private var voice = AVSpeechSynthesizer()

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

    private var isRoom: Bool { chat.roomId != nil }

    private var bot: BotInfo { isRoom ? chat.bot : (team.bots.first { $0.id == chat.bot.id } ?? chat.bot) }
    private var doing: String? { team.doing[chat.key] }
    private var working: Bool { doing != nil || chat.hasStreaming }
    private var waiting: Approval? { team.approvals.first { $0.chat == chat.key } }

    /// What the pet acts out for this conversation.
    private var petMood: PetMood {
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
    private var petState: String {
        if waiting != nil { return "notification" }
        if chat.hasStreaming || doing == "正在回复" { return "working" }
        if working || typing || dictation.listening { return "thinking" }
        if cheering { return "attention" }
        if dozing { return "sleeping" }
        return "idle"
    }

    /// 「更早的」: draws forty more of the older lines, keeping the line you were looking at in place.
    private var earlier: some View {
        Button {
            Haptics.light()
            loadEarlier()
        } label: {
            Label("更早的 \(chat.lines.count - shownCount) 条", systemImage: "arrow.up")
                .font(.system(size: Ink.Size.small, weight: .medium))
                .foregroundStyle(Ink.inkSoft)
                .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(TapStyle())
    }

    /// Draws forty more older lines and keeps the one at the top of the screen where it was. Called by the button,
    /// and by itself when the reader scrolls near the top, so long conversations read on without stopping.
    private func loadEarlier() {
        guard chat.lines.count > shownCount, !loadingEarlier else { return }
        loadingEarlier = true
        let anchor = chat.lines.suffix(shownCount).first?.id
        shownCount += 40
        Task { @MainActor in
            await Task.yield()
            if let anchor { scroller?.scrollTo(anchor, anchor: .top) }
            try? await Task.sleep(nanoseconds: 300_000_000)
            loadingEarlier = false
        }
    }

    @State private var loadingEarlier = false

    /// A failure in the conversation: what went wrong, and a way to try again right there.
    private func failureCard(_ error: String) -> some View {
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
    private func saidInNote(_ error: String) -> Bool {
        guard let last = chat.lines.last, last.kind == .note else { return false }
        return error.split(separator: "\n").first.map { last.text.contains($0) } ?? false
    }

    /// Something happened: the pet wakes, and the doze clock starts over.
    private func stir() {
        if dozing { dozing = false }
        stirs += 1
    }

    /// Whether the line under the conversation says what is going on: whenever the companion works and nothing else shows it.
    private var showsLive: Bool {
        guard doing != nil || waiting != nil else { return false }
        if let last = chat.lines.last, last.kind == .steps, last.live { return false }
        return !chat.hasStreaming || waiting != nil
    }

    /// What it is doing, in plain words, for the line under the conversation.
    private var liveWords: String? {
        Live.words(doing, name: bot.name, waiting: waiting != nil)
    }

    private var liveIcon: String {
        if waiting != nil { return "seal" }
        guard let doing else { return "ellipsis" }
        let name = doing.split(separator: "：", maxSplits: 1).first.map(String.init) ?? doing
        if doing.contains("：") { return Trace.icon(for: name) }
        return doing == "正在回复" ? "pencil.line" : "sparkles"
    }

    /// Under the name: what it is doing while it works; otherwise this conversation's title, once one is written.
    private var headerLine: String {
        if working || waiting != nil { return status }
        return team.title(of: chat.key) ?? status
    }

    /// The companion's state in the glossary's words.
    private var status: String {
        if waiting != nil { return Words.t("候印") }
        guard let doing else { return Words.t("闲坐") }
        switch doing {
        case "正在回复": return Words.t("落笔")
        case "正在想", "等你批准": return Words.t("沉吟")
        default: return Words.t(doing)
        }
    }

    /// The lines of the conversation, what is arriving, and what waits to be sent.
    private var conversationContent: some View {
        LazyVStack(spacing: 0) {
            // Keep distant replies unmounted when the keyboard, stream or window size changes.
            LazyVStack(alignment: .leading, spacing: Ink.Space.m) {
                if chat.lines.isEmpty && !chat.hasStreaming { empty }
                if historyPage == nil, chat.lines.count > shownCount { earlier }
                let heads = openers
                let lit = finding ? currentHit : nil
                LazyVStack(alignment: .leading, spacing: Ink.Space.m) {
                    ForEach(historyPage == nil ? Array(chat.lines.suffix(shownCount)) : displayedRows) { line in
                        turnRow(line, opens: heads.contains(line.id), lit: lit == line.id)
                            // A turn starts with what you said: more room above it than between the parts of a reply.
                            .padding(.top, line.kind == .user && line.id != displayedRows.first?.id ? Ink.Space.l : 0)
                            .id(line.id)
                            // Only what just arrived rises into place; history loaded above stays still.
                            .transition(historyPage == nil && chat.lines.suffix(2).contains(where: { $0.id == line.id })
                                        ? .opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)).combined(with: .offset(y: 8))
                                        : .identity)
                    }
                }
                .scrollTargetLayout()
                if historyPage == nil {
                if team.compressing.contains(chat.key) {
                    // Said once, quietly: it is happening behind, and you can go on talking.
                    Label("正在后台整理较早的聊天，不耽误你接着聊", systemImage: "text.append")
                        .font(Ink.footnote)
                        .foregroundStyle(Ink.inkFaint)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .id("folding")
                        .transition(.opacity)
                }
                ChatSection { liveReply }
                // What it is doing now sits in the bar above the composer; here only a running command's output.
                if let doing = team.doing[chat.key], doing.hasPrefix("斗室：") || doing.hasPrefix("远山 · ") {
                    ToolTailView()
                        .id("live")
                        .transition(.opacity.combined(with: .offset(y: 8)))
                }
                if let error = chat.error, !saidInNote(error) {
                    failureCard(error)
                        .transition(.opacity.combined(with: .offset(y: 6)))
                }
                ForEach(team.queued[chat.key] ?? []) { item in
                    queuedRow(item)
                        .transition(.opacity.combined(with: .offset(y: 8)))
                }
                }
            }
            // The foot of the page, under the breathing room at the bottom: scrolling to it shows everything,
            // and it is exactly the end of the content, so "at the bottom" and "scrolled to the foot" agree.
            Color.clear.frame(height: Ink.Space.xxl)
            Color.clear.frame(height: 1).id(Self.end)
        }
        .padding(.horizontal, Ink.Space.page)
        .padding(.top, Ink.Space.m)
    }

    @ViewBuilder
    private var liveReply: some View {
        if !chat.pulse.isEmpty {
            let speaker = chat.pulseSpeaker.flatMap { id in team.bots.first { $0.id == id } }
            PulseBox(text: chat.pulse, live: !chat.hasStreaming, temper: Temper.of(speaker ?? (isRoom ? nil : bot)))
                .id("pulse")
                .transition(.opacity)
        }
        if !chat.thinking.isEmpty && !chat.hasStreaming {
            ThinkingBox(text: chat.thinking, live: true)
                .id("thinking")
                .transition(.opacity)
        }
        if chat.hasStreaming {
            StreamingProse(text: chat.streaming)
                .id("streaming")
        }
    }

    /// The conversation itself: the lines, what is arriving, and the header it scrolls under.
    /// Kept apart from `body` so the compiler checks each piece on its own.
    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                conversationContent
            }
            .environment(\.chatSelectionChanged, selectionChanged)
            .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.15) { viewport.ids = $0 }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(following ? .bottom : .top, for: .sizeChanges)
            // Whenever something new pushes the bottom out of sight while the page follows, go back down at once.
            // Nothing moves while the reader is up reading older lines.
            // How far the last line is from sitting just above the composer. The composer (and the bar over it
            // while the companion works) is an inset: without counting it, the page kept stopping one composer short.
            .onScrollGeometryChange(for: Bool.self) { geometry in
                Self.below(geometry) > 2
            } action: { _, behind in
                if behind, following { followToEnd(settle: false) }
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentSize.height
            } action: { _, _ in
                // Every time what is on the page grows, keep to the bottom right away, not every 80 characters.
                if following { followToEnd(settle: false) }
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                Self.below(geometry) >= 80
            } action: { _, far in
                withAnimation(Ink.Motion.settle) { farFromEnd = far }
            }
            // Near the top while the reader scrolls up: the older lines come in by themselves.
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top < 240
            } action: { _, nearTop in
                if nearTop, scrolling, selecting.isEmpty { loadEarlier() }
            }
            .onScrollPhaseChange { old, phase, context in
                let moving = phase != .idle
                chat.setBrowsingHistory(phase == .interacting || phase == .decelerating)
                if moving != scrolling {
                    scrolling = moving
                    Hitches.shared.doing(moving ? Words.t("滚动絮语") : nil, as: "scroll")
                }
                // Only the reader's own scrolling decides whether the page keeps to the newest line; arriving text never does.
                if phase == .interacting {
                    following = false
                    jumpedTo = nil
                    hideJumps?.cancel()
                    jumpVisible = true
                }
                if phase == .idle, old != .idle {
                    following = historyPage == nil && selecting.isEmpty && Self.below(context.geometry) < 80
                    if old == .interacting || old == .decelerating { lingerJumpButtons() }
                }
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            // The header is a bar the conversation scrolls under: iOS blurs and fades the text beneath it, so nothing
            // reads through between the buttons, and the glass no longer picks up colours from the page.
            .scrollEdgeEffectStyle(.soft, for: .top)
            .safeAreaBar(edge: .top) { header }
            .onChange(of: working, initial: true) { _, now in
                workingSince = now ? (workingSince ?? Date()) : nil
            }
            .onChange(of: chat.lines.last?.id) {
                if chat.lines.isEmpty { historyPage = nil; lookupRows = [] }
                followToEnd()
            }
            .onChange(of: chat.lines.count) { followToEnd() }
            .onChange(of: showsLive) { followToEnd() }
            .onChange(of: chat.error) { followToEnd() }
            .animation(Ink.Motion.settle, value: showsLive)
            .onAppear { scroller = proxy }
        }
    }

    /// A message written while the companion works: it waits for the turn to finish, or goes now, or comes back to the composer.
    private func queuedRow(_ item: TeamModel.Queued) -> some View {
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
                    if let back = team.unqueue(chat.key, item.id) {
                        draft = draft.isEmpty ? back.text : draft + "\n" + back.text
                        typing = true
                    }
                }
                Button("立即发送", systemImage: "paperplane.fill") {
                    Haptics.thud()
                    following = true
                    team.sendQueueNow(chat.key)
                }
                .fontWeight(.semibold)
            }
            .font(.system(size: Ink.Size.small))
            .foregroundStyle(Ink.accent)
            .buttonStyle(TapStyle())
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, Ink.Space.huge)
    }

    /// Starts dictation; what is heard is added after what was already written.
    private func listen() {
        Haptics.grab()
        typing = false
        spokenBase = draft
        dictation.onText = { heard in draft = spokenBase + heard }
        Task { await dictation.start() }
    }

    /// Siri or a shortcut sent us here: put the words in, listen, or just wait at the composer. Nothing is sent.
    private func takeShortcut() {
        guard let ask = ShortcutDoor.take(for: chat.key) else { return }
        switch ask {
        case .ask(let words):
            if !words.isEmpty { draft = words }
            typing = true
        case .dictate:
            listen()
        case .fresh:
            typing = true
        case .files(let urls):
            withAnimation(Ink.Motion.settle) { receive(urls) }
            typing = true
        }
    }

    /// The composer, with what keeps the 用量 ring up to date and opens its sheet. In two layers, so the compiler
    /// checks each one on its own instead of giving up on one long chain.
    private var composerBar: some View {
        composerWatched
        .onChange(of: team.options(chat.key).model) { context = team.contextEstimate(chat.key) }
        .sheet(isPresented: $usageOpen, onDismiss: { context = team.contextEstimate(chat.key) }) {
            UsageSheet(team: team, key: chat.key)
                .presentationDetents([.medium, .large])
        }
        .onChange(of: typing) { _, now in
            Hitches.shared.doing(now ? "打字" : nil, as: "typing")
            stir()
        }
        .onChange(of: working) { _, now in
            stir()
            guard !now, chat.error == nil, chat.lines.last?.kind == .bot else { return }
            cheering = true
            Task {
                try? await Task.sleep(nanoseconds: 2_400_000_000)
                cheering = false
            }
        }
        .onChange(of: scrolling) { stir() }
        .task(id: stirs) {
            try? await Task.sleep(nanoseconds: 180_000_000_000)
            if !Task.isCancelled { dozing = true }
        }
        .task { away = team.whileAway(from: chat.key) }
    }

    private var composerWatched: some View {
        composer
        .task {
            // Let the page settle in before the keyboard or the microphone comes up.
            try? await Task.sleep(nanoseconds: 400_000_000)
            takeShortcut()
        }
        .onReceive(NotificationCenter.default.publisher(for: .clioShortcutReady)) { _ in takeShortcut() }
        .onChange(of: team.queued[chat.key]?.count ?? 0) { followToEnd() }
        .task { context = team.contextEstimate(chat.key) }
        .onChange(of: working) { _, now in if !now { context = team.contextEstimate(chat.key) } }
        .onChange(of: chat.lines.count) { if !working { context = team.contextEstimate(chat.key) } }
    }

    private var dockedForm: Asker.Form? {
        guard let form = asker.current, form.inline, team.isWorking(chat.key) else { return nil }
        return form
    }

    /// The floating pet follows the top of this stack, including the keyboard safe area.
    private var bottomStack: some View {
        VStack(spacing: 0) {
            PetPerchSpace(face: isRoom ? nil : bot.avatar)
            VStack(spacing: 0) {
                if let form = dockedForm {
                    PetDockSlip { InlineAsk(form: form).id(form.id) }
                        .padding(.horizontal, Ink.Bar.edge)
                        .padding(.bottom, Ink.Space.s)
                        .transition(.opacity)
                }
                if finding { findBar } else { composerBar }
            }
            .background(alignment: .top) {
                PetPerchAnchor(
                    perch: petPerch, mood: petMood, face: isRoom ? nil : bot.avatar,
                    showingSheet: attaching || usageOpen || abilities || outlining || quoting != nil
                        || (asker.current.map { !$0.inline } ?? false),
                    covered: petSettingsOpen || roaming || approving != nil || tuningOpen || scanning || takingPhoto,
                    quiet: dictation.listening, enabled: PetLibrary.shared.visible
                ) { petSettingsOpen = true }
                .frame(height: 1)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { _ in petPerch.layoutChanged() }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            // Paper behind the composer and the plan card, fading up into the page.
            .background(alignment: .bottom) {
                LinearGradient(stops: [
                    .init(color: Ink.paper.opacity(0), location: 0),
                    .init(color: Ink.paper.opacity(0.92), location: 0.35),
                    .init(color: Ink.paper, location: 1),
                ], startPoint: .top, endPoint: .bottom)
                .padding(.top, -Ink.Space.xl)
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
            }
        }
        .animation(petDockMotion, value: dockedForm?.id)
        .animation(petDockMotion, value: finding)
    }

    private var petDockMotion: Animation {
        calmPetMotion ? .easeInOut(duration: 0.22) : Ink.Motion.unfold
    }

    var body: some View {
        ZStack(alignment: .top) {
            Ink.paper.ignoresSafeArea()
            conversation
            if !roaming {
                HStack {
                    Spacer()
                    RoamThumb(browser: team.browser, frozen: scrolling) {
                        typing = false
                        roaming = true
                    }
                }
                .padding(.top, Ink.Bar.height + Ink.Space.s * 2)
                .padding(.trailing, Ink.Bar.edge)
                .zIndex(3)
            }
        }
        .safeAreaInset(edge: .bottom) { bottomStack }
        .sheet(isPresented: $petSettingsOpen) { PetPage() }
        .onAppear {
            chat.open()
            PetNews.shared.focused = chat.key
            draftState.load(chat.key)
        }
        .onChange(of: scenePhase) { if scenePhase != .active { draftState.flush() } }
        .hitchPage(isRoom ? "雅集" : "絮语")
        .onDisappear {
            if PetNews.shared.focused == chat.key { PetNews.shared.focused = nil }
            draftState.flush()
            chat.close()
            team.markSeen(chat.key)
            hideJumps?.cancel()
            selecting.removeAll()
            if dictation.listening { dictation.stop() }
        }
        .sheet(item: $noting) { note in
            NoteSheet(text: note.text, from: isRoom ? Words.t("雅集 · \(bot.name)") : bot.name, question: askedBefore(note.id),
                      bot: isRoom ? nil : bot)
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
            PlusSheet(team: team, key: chat.key, name: bot.name, isRoom: isRoom, addPhoto: { data in
                guard photos.count < 4 else { say("最多带四张图。"); return nil }
                guard let small = Self.shrink(data) else { return nil }
                withAnimation(Ink.Motion.settle) { photos.append(small) }
                return small
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
            NavigationStack { StudyFile(url: file.url) }
        }
        .sheet(isPresented: $outlining, onDismiss: { lookupRows = [] }) {
            OutlineSheet(pairs: outlinePairs) { id in
                outlining = false
                reveal(id)
                following = false
                Task {
                    try? await Task.sleep(nanoseconds: 350_000_000)
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
        .fullScreenCover(item: $approving) { approval in
            ApproveView(approval: approval, team: team)
        }
        .fullScreenCover(isPresented: $takingPhoto) {
            CameraPicker { data in
                if let data, let small = Self.shrink(data), photos.count < 4 { photos.append(small) }
            }
            .ignoresSafeArea()
        }
        .sheet(item: Binding(get: { viewing.map(Viewing.init) }, set: { viewing = $0?.id })) { item in
            PhotoViewer(chat: chat, attachmentId: item.id)
        }
        .onChange(of: picks) { _, items in
            guard !items.isEmpty else { return }
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self), let small = Self.shrink(data), photos.count < 4 {
                        withAnimation(Ink.Motion.settle) { photos.append(small) }
                    }
                }
                picks = []
            }
        }
        .onChange(of: chat.lines.last?.id) { _, _ in
            if chat.lines.last?.kind == .bot { Haptics.tick(0.45) }
        }
    }

    private struct ShareFile: Identifiable { let url: URL; var id: URL { url } }

    private struct Viewing: Identifiable { let id: String }
    private struct Noting: Identifiable { let id: String; let text: String }

    /// What you asked just before a reply, for the picture of the exchange.
    private func askedBefore(_ id: String) -> String? {
        guard let index = displayedRows.firstIndex(where: { $0.id == id }) else { return nil }
        return displayedRows[..<index].last(where: { $0.kind == .user && !$0.text.isEmpty })?.text
    }
    @State private var noting: Noting?
    @State private var quoting: Noting?
    /// Words from a reply the next message asks about.
    @State private var quote: String?
    @State private var roaming = false
    /// A retry or an edit waiting to hear whether the files it changed should go back too.
    @State private var undoAsk: UndoAsk?
    @State private var leafing = false
    private struct ReadingFile: Identifiable { let url: URL; var id: URL { url } }
    @State private var reading: ReadingFile?


    private func leave() {
        typing = false
        if dictation.listening { dictation.stop() }
        Haptics.light()
        back()
    }

    // MARK: Top bar

    private var header: some View {
        let layout = largeText ? AnyLayout(VStackLayout(alignment: .leading, spacing: Ink.Space.s)) :
            AnyLayout(HStackLayout(spacing: Ink.Space.s))
        return layout {
            HStack(alignment: largeText ? .top : .center, spacing: Ink.Space.s) {
                headerBack
                headerIdentity
            }
            if !largeText { Spacer(minLength: 0) }
            headerControls
        }
        .padding(.horizontal, Ink.Bar.edge)
        .padding(.top, Ink.Space.s)
        .padding(.bottom, Ink.Space.s)
        // Paper behind the buttons that fades out downwards, the same as under the composer: no hard band with
        // a line under it, and text scrolling up melts away instead of showing between the buttons.
        .background(alignment: .top) {
            LinearGradient(stops: [
                .init(color: Ink.paper, location: 0),
                .init(color: Ink.paper.opacity(0.92), location: 0.6),
                .init(color: Ink.paper.opacity(0), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            .padding(.bottom, -Ink.Space.l)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
        }
    }

    private var headerBack: some View {
        Button(action: leave) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: Ink.Size.body, weight: .semibold))
                .foregroundStyle(Ink.ink)
                .frame(width: Ink.Bar.height, height: Ink.Bar.height)
                .glassFace(in: Circle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel("打开侧边栏")
    }

    private var headerIdentity: some View {
        HStack(spacing: Ink.Space.s) {
            PetStill(size: 30, state: petState, avatar: true, bot: isRoom ? nil : bot)
                .breathing(working, tint: Ink.accent)
                // Its face opens a glance at it: what it does, what it made, its schedule.
                .onTapGesture {
                    guard !isRoom else { detailOpen = true; return }
                    Haptics.light()
                    glancing = true
                }
                .popover(isPresented: $glancing) {
                    GlanceCard(team: team, bot: bot, key: chat.key,
                               openCard: { glancing = false; cardOpen = true },
                               openDetail: { glancing = false; detailOpen = true })
                        .presentationCompactAdaptation(.popover)
                }
            VStack(alignment: .leading, spacing: 0) {
                Text(bot.name).font(.system(size: Ink.Size.sub * (largeText ? textScale : 1), weight: .semibold)).foregroundStyle(Ink.ink)
                HStack(spacing: 4) {
                    Circle().fill(working ? Ink.accent : Ink.ok).frame(width: 6, height: 6)
                    Text(headerLine)
                        .font(largeText ? .footnote : Ink.footnote)
                        .foregroundStyle(Ink.inkSoft)
                        .lineLimit(largeText ? nil : 1)
                        .fixedSize(horizontal: false, vertical: largeText)
                        .contentTransition(.opacity)
                }
                .animation(.easeInOut(duration: 0.5), value: headerLine)
            }
        }
        .padding(.leading, -Ink.Space.xs)
        .padding(.horizontal, Ink.Space.m)
        .padding(.vertical, largeText ? Ink.Space.s : 0)
        .frame(minHeight: Ink.Bar.height)
        .glassFace(in: Capsule())
        .contentShape(.capsule)
        .onTapGesture {
            Haptics.light()
            typing = false
            detailOpen = true
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("点一下看对话详情")
    }

    private var headerControls: some View {
        HStack(spacing: Ink.Space.xs) {
            ChatBrowserIndicator(browser: team.browser) {
                typing = false
                roaming = true
            }
            Menu {
                Section {
                    chatMenuButton("chat.newConversation", icon: "square.and.pencil") { team.turnLeaf(chat.key) }
                    chatMenuButton("actions.share", icon: "square.and.arrow.up") {
                        let title = team.title(of: chat.key) ?? bot.name
                        sharing = ShareFile(url: team.exportChat(chat.key, title: title))
                    }
                    chatMenuButton("chat.find", icon: "magnifyingglass") { startFinding() }
                }
                Section {
                    chatMenuButton("chat.compactContext", icon: "rectangle.compress.vertical") {
                        Task { _ = try? await team.compress(chat.key) }
                    }
                    Button(L.t("actions.clear"), systemImage: "trash", role: .destructive) {
                        typing = false
                        clearingChat = true
                    }
                }
                Section {
                    chatMenuButton("nav.terminal", icon: "terminal") { terminalOpen = true }
                    chatMenuButton("nav.browser", icon: "safari") { roaming = true }
                    chatMenuButton("chat.files", icon: "folder") { filesOpen = true }
                }
                Section {
                    chatMenuButton("agent.skills", icon: "books.vertical") { chatSkillsOpen = true }
                    chatMenuButton("chat.mcp", icon: "point.3.connected.trianglepath.dotted") { chatConnectorsOpen = true }
                }
                Section {
                    chatMenuButton("chat.outline", icon: "list.bullet.indent") {
                        Task {
                            await loadEverything()
                            outlinePairs = outline
                            outlining = true
                        }
                    }
                    chatMenuButton("chat.conversationHistory", icon: "book.pages") { leafing = true }
                    chatMenuButton("chat.rename", icon: "pencil") {
                        renameText = team.title(of: chat.key) ?? ""
                        renaming = true
                    }
                    if !isRoom { chatMenuButton("chat.openCard", icon: "person.text.rectangle") { cardOpen = true } }
                    if working { chatMenuButton("alwaysOn.open", icon: "moon.stars") { AlwaysOn.show(chat: chat.key) } }
                    if PetLibrary.shared.shown {
                        chatMenuButton("pet.hideHour", icon: "eye.slash") {
                            withAnimation(Ink.Motion.settle) { PetLibrary.shared.hideForAnHour() }
                        }
                    } else {
                        chatMenuButton("pet.showNow", icon: "eye") {
                            withAnimation(Ink.Motion.settle) {
                                PetLibrary.shared.hiddenUntil = nil
                                PetLibrary.shared.visible = true
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: Ink.Size.body, weight: .semibold))
                    .foregroundStyle(Ink.ink)
                    .frame(width: Ink.Bar.height, height: Ink.Bar.height)
                    .glassFace(in: Circle())
            }
            .accessibilityLabel(L.t("chat.menu"))
        }
    }

    private func chatMenuButton(_ key: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(L.t(key), systemImage: icon) {
            typing = false
            action()
        }
    }

    // MARK: Composer chips

    private var options: TeamModel.ChatOptions { team.options(chat.key) }

    /// A chip in the row under the text field. Lit when what it stands for is on.
    private func chip(_ icon: String, _ name: String?, lit: Bool = false) -> some View {
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
    private func say(_ text: String) {
        withAnimation(Ink.Motion.settle) { hint = text }
        let said = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
            if hint == said { withAnimation(Ink.Motion.settle) { hint = nil } }
        }
    }



    private func shortName(_ ref: String?) -> String {
        guard let found = team.resolve(ref) else { return "选模型" }
        let name = found.model
        return name.count > 16 ? String(name.prefix(15)) + "…" : name
    }

    private var modelChip: some View {
        let own = options.model
        let level = options.thinking ?? .auto
        let current = team.model(for: chat.key, bot: bot)
        return Menu {
            Section(Words.t("这段絮语用哪个模型")) {
                Button {
                    Haptics.tick(0.5)
                    team.setModel(nil, in: chat.key)
                    say("跟着\(bot.name)走：用 \(shortName(bot.model ?? team.settings.defaultModel))。")
                } label: {
                    if own == nil { Label("跟着\(bot.name)走", systemImage: "checkmark") } else { Text("跟着\(bot.name)走") }
                }
            }
            Menu {
                thinkingChoices
            } label: {
                Label("思考：\(level.title)", systemImage: level.symbol)
                Text(level.line)
            }
            ModelChoices(team: team, current: own) { ref in
                Haptics.tick(0.5)
                team.setModel(ref, in: chat.key)
                let found = team.resolve(ref)
                let sight = (found.map { $0.endpoint.traits($0.model).sees } ?? false) ? "能看图" : "不能看图，发的照片会改用 photo_text 读字"
                say(Words.t("这段絮语改用 \(found?.model ?? ref)（\(sight)），\(bot.name)别处的絮语不变。"))
            }
        } label: {
            // Just the service's icon; the name is in the menu. A dot when this conversation has its own model or depth.
            let found = team.resolve(current)
            ZStack(alignment: .topTrailing) {
                ModelIcon(model: found?.model, service: found.flatMap { Service.of($0.endpoint) }, size: 22, name: found?.endpoint.name)
                    .frame(width: 32, height: 32)
                if own != nil || level != .auto {
                    Circle().fill(Ink.accent).frame(width: 7, height: 7).offset(x: -3, y: 4)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityLabel("模型：\(shortName(current))，经由\(team.resolve(current)?.endpoint.name ?? "")\(level == .auto ? "" : "，思考\(level.title)")")
    }

    /// How hard the model thinks in this conversation: on its own in a gathering, inside the model menu otherwise.
    private var thinkChip: some View {
        let level = options.thinking ?? .auto
        return Menu {
            thinkingChoices
        } label: {
            chip(level == .auto ? "brain" : level.symbol, nil, lit: level != .auto)
        }
        .accessibilityLabel("思考强度：\(level.title)")
    }

    @ViewBuilder
    private var thinkingChoices: some View {
        let level = options.thinking ?? .auto
        let now = isRoom ? nil : team.current(chat.key, bot: bot)
        // Only the levels this model's service really tells apart (the one chosen stays visible).
        let offered: [Thinking] = {
            guard let now, now.endpoint.kind == .openai else { return Thinking.allCases }
            let levels = now.endpoint.thinkingStyle.levels(thinks: now.traits.thinks)
            return Thinking.allCases.filter { levels.contains($0) || $0 == level }
        }()
        Section(Words.t("这段絮语想多深")) {
            ForEach(offered, id: \.self) { option in
                Button {
                    Haptics.tick(0.5)
                    team.setThinking(option, in: chat.key)
                    say(option == .auto ? "思考强度交给模型自己定。" : "思考强度：\(option.title)。\(option.line)。")
                } label: {
                    if option == level { Label(option.title, systemImage: "checkmark") } else { Label(option.title, systemImage: option.symbol) }
                    Text(option.line)
                }
            }
        }
        if let now {
            Section {
                if !now.traits.thinks {
                    Text("\(now.model) 好像不会思考，选了也许没变化。")
                } else if now.endpoint.kind == .openai, !now.endpoint.thinkingStyle.canStop {
                    Text("\(now.endpoint.name) 的模型总要想一想，「不想」会按「浅想」来。")
                } else {
                    Text("模型不接受某一档时，会自动改回默认，并在对话里说一声。")
                }
            }
        }
    }

    /// Where this conversation works: 书案, 斗室 or a 远山 host.
    private var placeChip: some View {
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

    private func placeButton(_ place: WorkPlace, line: String) -> some View {
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

    // MARK: Attachments

    private func bring(_ kind: AttachKind) {
        switch kind {
        case .photos: pickerShown = true
        case .camera: takingPhoto = true
        case .files: importingFile = true
        case .desk: deskPicking = true
        case .scan: scanning = true
        }
    }


    /// More than 2500 characters arriving at once (a paste) would make the box crawl: they go into 书案/收件 as a file,
    /// shown as an attachment under the box, and the box keeps what was there before.
    private func keepLongPaste(_ old: String, _ new: String) {
        guard new.count - old.count > 2500 else { return }
        let start = zip(old, new).prefix { $0 == $1 }.count
        let tail = zip(old.reversed(), new.reversed()).prefix { $0 == $1 }.count
        let end = max(start, min(new.count - tail, new.count))
        let pasted = String(new.dropFirst(start).prefix(end - start))
        guard pasted.count > 2500 else { return }
        let inbox = Workspace.root.appendingPathComponent("收件", isDirectory: true)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let file = inbox.appendingPathComponent("粘贴片段-\(formatter.string(from: Date())).txt")
        guard (try? Data(pasted.utf8).write(to: file)) != nil else { return }
        draft = old
        withAnimation(Ink.Motion.settle) { files.append(Workspace.relative(file)) }
        say(Words.t("粘进来的字太长（\(pasted.count) 字），存成文件带上了：书案/\(Workspace.relative(file))"))
    }


    /// Files picked from the Files app land in 书案/收件, and the companion is told where.
    private func receive(_ urls: [URL]) {
        let inbox = Workspace.root.appendingPathComponent("收件", isDirectory: true)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var target = inbox.appendingPathComponent(url.lastPathComponent)
            var number = 2
            while FileManager.default.fileExists(atPath: target.path) {
                let base = url.deletingPathExtension().lastPathComponent
                let ext = url.pathExtension
                target = inbox.appendingPathComponent(ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
                number += 1
            }
            do {
                try FileManager.default.copyItem(at: url, to: target)
                if target.pathExtension.lowercased() == "pdf", let text = PDFText.extract(target), !text.isEmpty {
                    try? Data(text.utf8).write(to: target.appendingPathExtension("txt"))
                }
                files.append(Workspace.relative(target))
            } catch {
                say("没拿到「\(url.lastPathComponent)」：\(error.localizedDescription)")
            }
        }
        if !urls.isEmpty { Haptics.tick(0.6) }
    }

    /// What goes after the message so the companion knows about the files.
    private var fileNote: String {
        guard !files.isEmpty else { return "" }
        let lines = files.map { path -> String in
            let pdf = path.lowercased().hasSuffix(".pdf") && FileManager.default.fileExists(atPath: (Workspace.resolve(path + ".txt")?.path ?? ""))
            return "- 书案/\(path)" + (pdf ? "（PDF：用 read_pdf 按页读；文字也抽出到了 \(path).txt）" : "")
        }
        return "\n\n［我放进书案的文件（书案路径；斗室里是 /root/desk 下同名路径），可以用 read_file 读、read_pdf 读 PDF、view_image 看图，或用 shell 处理：\n" + lines.joined(separator: "\n") + "］"
    }

    // MARK: Rows

    private var empty: some View {
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
    @MainActor private static var trimmedCache: [String: String] = [:]

    @MainActor static func withoutSourceList(_ text: String) -> String {
        if let known = trimmedCache[text] { return known }
        let trimmed = trimSourceList(text)
        if trimmedCache.count > 400 { trimmedCache.removeAll() }
        trimmedCache[text] = trimmed
        return trimmed
    }

    private static func trimSourceList(_ text: String) -> String {
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
    private final class SourcesMemo {
        var found: [String: [URL]] = [:]
    }
    @State private var sourcesMemo = SourcesMemo()

    private func sources(for line: ChatLine) -> [URL] {
        let memoKey = line.id + "|\(line.text.count)"
        if let known = sourcesMemo.found[memoKey] { return known }
        let found = findSources(for: line)
        if sourcesMemo.found.count > 600 { sourcesMemo.found.removeAll() }
        sourcesMemo.found[memoKey] = found
        return found
    }

    private func findSources(for line: ChatLine) -> [URL] {
        guard let index = displayedRows.firstIndex(where: { $0.id == line.id }) else { return [] }
        // The pages the answer itself names come first: they are what it rests on.
        var urls: [URL] = SourcesRow.cited(in: line.text).map(\.url)
        var cursor = index - 1
        while cursor >= 0, displayedRows[cursor].kind == .steps {
            let step = displayedRows[cursor]
            for (position, label) in step.tools.enumerated() where label.hasPrefix("读网页") || label.hasPrefix("搜索") || label.hasPrefix("远游") {
                guard position < step.details.count else { continue }
                // Pages it read count first; then what a search brought back.
                let text = label.hasPrefix("搜索") ? step.details[position].output : step.details[position].input
                for match in text.matches(of: #/https?://[^\s"'<>()\[\]，。]+/#) {
                    if let url = URL(string: String(match.output)), url.host != nil, !SourcesRow.isSearchPage(url), !urls.contains(url) { urls.append(url) }
                }
            }
            cursor -= 1
        }
        return Array(urls.prefix(8))
    }

    /// What this conversation can reach, in one line: 「在书案干活 · 能联网 · 远山 jp-1」.
    private var reach: String {
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
    private var starters: [(String, String, String)] {
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
    private func row(_ line: ChatLine) -> some View {
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
                        .padding(.vertical, Ink.Space.m)
                        // Real Liquid Glass, as Open Minis does: your bubbles scroll over replies, code and pictures,
                        // so the glass has something to catch. Tinted a little with the paper, so it stays Clio's.
                        .glassEffect(.regular.tint((editing == line.id ? Ink.accentWash : Ink.mine).opacity(0.45)),
                                     in: .rect(cornerRadius: Ink.Radius.card, style: .continuous))
                        .contentShape(.contextMenuPreview, .rect(cornerRadius: Ink.Radius.card, style: .continuous))
                        .contextMenu {
                            Button("复制", systemImage: "doc.on.doc") { UIPasteboard.general.string = line.text }
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
                if let fresh = chat.fresh, fresh.id == line.id, let shown = fresh.shown {
                    StreamingProse(text: String(line.text.prefix(shown)))
                } else {
                    // Long-press selects words (across paragraphs); what the old long-press menu had is behind ⋯ under the reply.
                    // When the sources row is under it, a 「来源：」 list the model wrote at the end is not shown twice.
                    let shown = sources(for: line).isEmpty ? line.text : Self.withoutSourceList(line.text)
                    let looked = Self.lookback(shown)
                    // 「回望：…」 the companion wrote after its steps: a quiet line of its own, like 心绪, not body text.
                    if let note = looked.note { LookbackLine(text: note) }
                    SelectableProse(text: looked.rest)
                        .equatable()
                }
                let found = sources(for: line)
                if !found.isEmpty, !(chat.fresh?.id == line.id) {
                    SourcesRow(urls: found, titles: SourcesRow.titles(in: line.text)) { url in
                        typing = false
                        Task { await team.browser.open(url) }
                        roaming = true
                    }
                }
                // The same row under every reply: copy, ⋯; the newest also 重来 and its numbers.
                let newest = line.id == chat.lines.last(where: { $0.kind == .bot })?.id
                // Only under the last words of a turn: a short 「先造钥匙。」 before the steps gets no row of its own.
                if newest ? !working : (!(chat.fresh?.id == line.id) && endsTurn(line)) {
                    footer(line, newest: newest)
                        .transition(.opacity)
                }
            }
        case .steps:
            Trace(line: line, visit: { url in
                typing = false
                Task { await team.browser.open(url) }
                roaming = true
            }, openFile: { url in
                reading = ReadingFile(url: url)
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

    // MARK: Outline

    /// 问答目录: each thing you said, with how the answer began.
    private var outline: [OutlineSheet.Pair] {
        var pairs: [OutlineSheet.Pair] = []
        let lines = lookupRows
        for (index, line) in lines.enumerated() where line.kind == .user && !line.text.isEmpty {
            let answer = lines[(index + 1)...].prefix { $0.kind != .user }.first { $0.kind == .bot && !$0.text.isEmpty }?.text
            pairs.append(.init(id: line.id, question: line.text, answer: answer.map { String(Pulse.split($0).rest.prefix(80)) }, at: line.at))
        }
        return pairs
    }

    // MARK: Finding

    /// The lines with what you look for, oldest first.
    /// Worked out once per change of the words, not for every row.
    private func findHits() -> [String] {
        let wanted = findText.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return [] }
        return lookupRows.filter { ($0.kind == .user || $0.kind == .bot) && $0.text.localizedCaseInsensitiveContains(wanted) }.map(\.id)
    }

    private var currentHit: String? {
        let found = hits
        guard !found.isEmpty else { return nil }
        return found[min(max(findAt, 0), found.count - 1)]
    }

    /// Everything said is looked through, not only what is on screen.
    private func startFinding() {
        Haptics.light()
        withAnimation(Ink.Motion.settle) { finding = true }
        findFocus = true
        Task {
            await loadEverything()
            guard finding else { lookupRows = []; return }
            if !findText.isEmpty { updateFindHits() }
        }
    }

    /// The whole conversation, built once, for finding and the outline. Rows are only put on the page when going there.
    private func loadEverything() async {
        lookupRows = await chat.lookupRows()
    }

    private func stopFinding() {
        withAnimation(Ink.Motion.settle) { finding = false }
        findText = ""
        findAt = 0
        hits = []
        lookupRows = []
    }

    /// Keep a bounded window around the result, without altering the live conversation's paging.
    private func reveal(_ id: String) {
        if chat.lines.suffix(shownCount).contains(where: { $0.id == id }) {
            historyPage = nil
            return
        }
        guard let index = lookupRows.firstIndex(where: { $0.id == id }) else { return }
        let bounds = max(0, index - 30)..<min(lookupRows.count, index + 31)
        historyPage = Array(lookupRows[bounds])
    }

    private func updateFindHits() {
        hits = findHits()
        findAt = max(hits.count - 1, 0)
        if !hits.isEmpty { showHit(0) }
    }

    /// Goes to the place found, newest first; the arrows step older or newer.
    private func showHit(_ step: Int) {
        let found = hits
        guard !found.isEmpty else { return }
        findAt = (findAt + step + found.count) % found.count
        let target = found[findAt]
        reveal(target)
        following = false
        Haptics.tick(0.4)
        Task { @MainActor in
            await Task.yield()
            withAnimation(Ink.Motion.settle) { scroller?.scrollTo(target, anchor: .center) }
        }
    }

    /// Where the composer was, while looking: the words, how many places, older / newer, and 完成.
    private var findBar: some View {
        let found = hits.count
        return HStack(spacing: Ink.Space.s) {
            Image(systemName: "magnifyingglass").foregroundStyle(Ink.inkFaint)
            TextField("在这段对话里找", text: $findText)
                .font(.system(size: Ink.Size.body))
                .focused($findFocus)
                .submitLabel(.search)
                .onSubmit { showHit(-1) }
                .onChange(of: findText) { updateFindHits() }
            if !findText.isEmpty {
                Text(found == 0 ? "没找到" : "\(min(findAt + 1, found))/\(found)")
                    .font(Ink.footnote.monospacedDigit())
                    .foregroundStyle(Ink.inkSoft)
                    .fixedSize()
            }
            Button { showHit(-1) } label: { Image(systemName: "chevron.up") }
                .disabled(found == 0)
                .accessibilityLabel("更早的一处")
            Button { showHit(1) } label: { Image(systemName: "chevron.down") }
                .disabled(found == 0)
                .accessibilityLabel("更新的一处")
            Button(L.t("actions.done")) { stopFinding() }
                .font(.system(size: Ink.Size.sub, weight: .semibold))
        }
        .font(.system(size: Ink.Size.sub, weight: .semibold))
        .foregroundStyle(Ink.accent)
        .padding(.horizontal, Ink.Space.l)
        .frame(minHeight: 48)
        .glassFace(in: Capsule())
        .padding(.horizontal, Ink.Bar.edge)
        .padding(.bottom, Ink.Space.s)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    // MARK: Faces

    private static let face: CGFloat = 32

    /// Who said a line, for faces: you, or the companion (in a group, the one who spoke). Steps belong to the reply.
    private func voice(_ line: ChatLine) -> String? {
        switch line.kind {
        case .user: return "me"
        case .bot, .steps: return "bot:" + (line.speaker ?? bot.id)
        case .note: return nil
        }
    }

    /// The lines that open a run by one speaker: only they carry a face, so a reply in several parts shows it once.
    private var openers: Set<String> {
        var heads: Set<String> = []
        var last: String?
        for line in displayedRows {
            guard let who = voice(line) else { continue }
            if who != last { heads.insert(line.id) }
            last = who
        }
        return heads
    }

    /// A line with its face: the companion's above its reply, yours beside your bubble, and the time when a while has passed.
    @ViewBuilder
    private func turnRow(_ line: ChatLine, opens: Bool, lit: Bool) -> some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            if faces, opens, let gap = timeGap(before: line) {
                Text(gap)
                    .font(Ink.footnote)
                    .foregroundStyle(Ink.inkFaint)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, Ink.Space.xs)
            }
            switch line.kind {
            case .user:
                if faces {
                    HStack(alignment: .top, spacing: Ink.Space.s) {
                        row(line)
                        if opens {
                            MeAvatar(size: Self.face)
                        } else {
                            Color.clear.frame(width: Self.face, height: 1)
                        }
                    }
                } else {
                    row(line)
                }
            case .bot, .steps:
                // Without faces, a group still says who is speaking, small.
                if opens, faces || isRoom { speakerHead(line) }
                row(line)
            case .note:
                row(line)
            }
        }
        // The place found: a soft ground behind it, so the eye lands there.
        .background {
            if lit {
                RoundedRectangle(cornerRadius: Ink.Radius.small, style: .continuous)
                    .fill(Ink.accentWash)
                    .padding(-Ink.Space.s)
            }
        }
        .animation(Ink.Motion.settle, value: lit)
    }

    /// The companion's face and name, over what it says.
    private func speakerHead(_ line: ChatLine) -> some View {
        let speaker = line.speaker.flatMap { id in team.bots.first { $0.id == id } } ?? (isRoom ? nil : bot)
        return HStack(spacing: Ink.Space.s) {
            PetStill(size: faces ? Self.face : 22, wash: speaker.map { Ink.wash(for: $0) }, avatar: true, bot: speaker)
            Text(speaker?.name ?? line.speakerName ?? bot.name)
                .font(.system(size: Ink.Size.small, weight: .semibold))
                .foregroundStyle(Ink.inkSoft)
        }
        .accessibilityElement(children: .combine)
    }

    /// 「昨天 23:10」 over a line said more than half an hour after the one before it.
    private func timeGap(before line: ChatLine) -> String? {
        guard let at = line.at,
              let index = displayedRows.firstIndex(where: { $0.id == line.id }), index > 0,
              let before = displayedRows[..<index].last(where: { $0.at != nil })?.at,
              at - before > 30 * 60 * 1000 else { return nil }
        let date = Date(timeIntervalSince1970: at / 1000)
        let calendar = Calendar.current
        let clock = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        if calendar.isDateInToday(date) { return clock }
        if calendar.isDateInYesterday(date) { return "昨天 " + clock }
        if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            return date.formatted(.dateTime.month(.defaultDigits).day()) + " " + clock
        }
        return date.formatted(.dateTime.year().month(.defaultDigits).day()) + " " + clock
    }

    /// Where a compression happened: a quiet divider. Above it everything is still here; tap to read the 前情提要.
    private func foldLine(_ line: ChatLine) -> some View {
        Button {
            Haptics.light()
            leafing = true
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
    }

    /// A failure, said plainly, with the one thing to do about it. Only the latest one keeps its button.
    private func trouble(_ line: ChatLine, next: Explain.Next) -> some View {
        let parts = line.text.split(separator: "\n", maxSplits: 1).map(String.init)
        let latest = chat.lines.last(where: { $0.kind == .note })?.id == line.id && chat.lines.last?.id == line.id
        let advice = Explain.Advice(title: parts.first ?? line.text, detail: parts.count > 1 ? parts[1] : "", next: next)
        return VStack(alignment: .leading, spacing: Ink.Space.s) {
            // A pause is not a failure: said in ink, not in red.
            Label(advice.displayTitle, systemImage: next == .resume ? "pause.circle" : "exclamationmark.triangle")
                .font(.system(size: Ink.Size.sub, weight: .semibold))
                .foregroundStyle(next == .resume ? Ink.ink : Ink.stop)
            if !advice.detail.isEmpty {
                Text(advice.detail).font(Ink.secondary).foregroundStyle(Ink.inkSoft)
            }
            if latest, let button = advice.button {
                Button {
                    Haptics.light()
                    act(next)
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
    }

    struct UndoAsk: Identifiable {
        let id = UUID()
        /// Nil: a retry of the last answer. Otherwise the edited message.
        var entry: String?
        var text: String?
        var files: [String]
    }

    /// 重来一次, or 改了重发: when that turn changed files, first ask whether they go back too.
    private func redo(from entry: String? = nil, text: String? = nil) {
        following = true
        let changed = team.changedFiles(chat.key, from: entry)
        guard !changed.isEmpty else {
            if let entry, let text { chat.resend(entry, text: text) } else { chat.retry() }
            return
        }
        undoAsk = UndoAsk(entry: entry, text: text, files: changed.map { WorkPlace(code: $0.place).title + "：" + $0.path })
    }

    private func finishRedo(_ ask: UndoAsk, restoring: Bool) {
        following = true
        if let entry = ask.entry, let text = ask.text { chat.resend(entry, text: text, restoring: restoring) } else { chat.retry(restoring: restoring) }
    }

    private func act(_ next: Explain.Next) {
        switch next {
        case .retry: redo()
        case .resume:
            following = true
            team.resume(chat.key)
        case .tuning: tuningOpen = true
        case .care: careOpen = true
        case .compress:
            say(L.t("loading.compactingContext"))
            Task {
                do {
                    let folded = try await team.compress(chat.key)
                    say("压好了：较早的 \(folded) 条写成了提要。再发一次试试。")
                } catch {
                    say(error.localizedDescription)
                }
            }
        }
    }

    /// A first line 「回望：…」 taken off the reply, and the rest.
    static func lookback(_ text: String) -> (note: String?, rest: String) {
        let trimmed = text.drop { $0 == "\n" || $0 == " " }
        guard let first = trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first else { return (nil, text) }
        let line = first.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespaces)
        for head in ["回望：", "回望:"] where line.hasPrefix(head) {
            let note = String(line.dropFirst(head.count)).trimmingCharacters(in: .whitespaces)
            let rest = trimmed.dropFirst(first.count).trimmingCharacters(in: .whitespacesAndNewlines)
            return (note.isEmpty ? nil : note, rest)
        }
        return (nil, text)
    }

    /// No more of the companion's words follow before the user speaks again.
    private func endsTurn(_ line: ChatLine) -> Bool {
        guard let index = displayedRows.firstIndex(where: { $0.id == line.id }) else { return true }
        for later in displayedRows[(index + 1)...] {
            // In a group, another companion speaking ends this one's turn.
            if later.kind == .bot { return later.speaker != line.speaker }
            if later.kind == .user { return true }
        }
        return true
    }

    private func fork(at line: ChatLine) {
        Haptics.thud()
        team.fork(chat.key, at: line.id)
    }

    /// The same actions on every reply, by a long press: the footer only sits under the last one.
    @ViewBuilder
    /// What ⋯ under a reply holds. Copying the whole reply is the icon beside it, so it is not here again.
    private func replyMenu(_ line: ChatLine) -> some View {
        Button("朗读", systemImage: "speaker.wave.2") { speak(line.text) }
        Button("引用追问", systemImage: "text.quote") { quoting = Noting(id: line.id, text: line.text) }
        Button(Words.t("做成长图"), systemImage: "photo.on.rectangle") { noting = Noting(id: line.id, text: line.text) }
        ShareLink(item: line.text) { Label("分享", systemImage: "square.and.arrow.up") }
        if !isRoom {
            Button(Words.t("从这里另起一叶"), systemImage: "arrow.triangle.branch") { fork(at: line) }
        }
    }

    private func footer(_ line: ChatLine, newest: Bool = true) -> some View {
        HStack(spacing: 2) {
            icon("doc.on.doc", "复制") {
                UIPasteboard.general.string = line.text
                Haptics.tick(0.5)
                say("复制好了。")
            }
            if newest {
                icon("arrow.clockwise", "重来一次") {
                    Haptics.light()
                    redo()
                }
            }
            // The rest waits behind ⋯, so the row stays short like other apps'.
            Menu {
                replyMenu(line)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: Ink.Size.small, weight: .medium))
                    .foregroundStyle(Ink.inkSoft)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("更多")
            Spacer(minLength: Ink.Space.s)
            if newest, Pref.stats {
                Text(Self.numbers(line))
                    .font(Ink.footnote.monospacedDigit())
                    .foregroundStyle(Ink.inkFaint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .layoutPriority(1)
            }
        }
        .padding(.leading, -6)
    }

    /// 「2分31秒 · 6.4k tokens」: how long the turn took and how much was written, short enough for one line.
    static func numbers(_ line: ChatLine) -> String {
        var parts: [String] = []
        if let seconds = line.seconds { parts.append(Clock.said(seconds)) }
        if let tokens = line.tokens {
            parts.append(tokens >= 1000 ? String(format: "%.1fk tokens", Double(tokens) / 1000) : "\(tokens) tokens")
        } else {
            let count = line.text.count
            parts.append(count >= 1000 ? String(format: "%.1f千字", Double(count) / 1000) : "\(count)字")
        }
        return parts.joined(separator: " · ")
    }

    private func icon(_ name: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: Ink.Size.small, weight: .regular))
                .foregroundStyle(Ink.inkSoft)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(label)
    }

    private func speak(_ text: String) {
        if voice.isSpeaking {
            voice.stopSpeaking(at: .immediate)
            return
        }
        let plain = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))).map { String($0.characters) } ?? text
        let utterance = AVSpeechUtterance(string: plain)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        voice.speak(utterance)
    }

    // MARK: Composer

    /// 你不在时: the other conversations that finished, failed or are waiting for you, one line each. Costs nothing.
    private var awayCard: some View {
        VStack(alignment: .leading, spacing: Ink.Space.xs) {
            HStack {
                Text("你不在时").font(Ink.serif(14, bold: true)).foregroundStyle(Ink.inkSoft)
                Spacer()
                Button {
                    withAnimation(Ink.Motion.settle) { away = [] }
                } label: {
                    Image(systemName: "xmark").font(.system(size: Ink.Size.small, weight: .semibold)).foregroundStyle(Ink.inkFaint).frame(width: 28, height: 28)
                }
                .buttonStyle(TapStyle(grow: 8))
                .accessibilityLabel("知道了")
            }
            ForEach(away) { item in
                Button {
                    Haptics.tick(0.6)
                    withAnimation(Ink.Motion.settle) { away = [] }
                    NotificationCenter.default.post(name: .clioOpenChat, object: item.chat)
                } label: {
                    HStack(spacing: Ink.Space.s) {
                        Image(systemName: Self.awayIcon(item.kind)).foregroundStyle(item.kind == .failed ? Ink.stop : (item.kind == .waiting ? Ink.warn : Ink.accent)).frame(width: 18)
                        Text("\(team.chatName(item.chat))：\(Self.awayWords(item.kind))").font(.system(size: Ink.Size.sub)).foregroundStyle(Ink.ink).lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.system(size: Ink.Size.micro, weight: .semibold)).foregroundStyle(Ink.inkFaint)
                    }
                    .frame(minHeight: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
            }
        }
        .padding(.horizontal, Ink.Space.m)
        .padding(.vertical, Ink.Space.s)
        .glassBacking(in: RoundedRectangle(cornerRadius: Ink.Radius.card, style: .continuous))
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    static func awayIcon(_ kind: Happening.Kind) -> String {
        switch kind {
        case .done: "checkmark.circle"
        case .failed: "exclamationmark.circle"
        case .waiting: "seal"
        }
    }

    static func awayWords(_ kind: Happening.Kind) -> String {
        switch kind {
        case .done: "那边的活做完了，回复在等你看"
        case .failed: "那边出了点问题"
        case .waiting: "在等你批准"
        }
    }

    // MARK: Dock: the cards above the composer

    /// The cards that can sit above the composer, the most pressing first.
    private enum DockCard: Hashable { case waiting, roam, working, away }

    private var dockCards: [DockCard] {
        var cards: [DockCard] = []
        if waiting != nil { cards.append(.waiting) }
        if team.browser.handoff != nil { cards.append(.roam) }
        if working, waiting == nil, liveWords != nil { cards.append(.working) }
        if !away.isEmpty, waiting == nil { cards.append(.away) }
        return cards
    }

    /// Two cards or more stack into one, like notifications: the first in front, the edges of the next ones
    /// showing behind it. A tap on the edges spreads them out.
    @ViewBuilder
    private var dock: some View {
        let cards = dockCards
        if cards.count <= 1 || dockOpen {
            VStack(spacing: Ink.Space.s) {
                if cards.count > 1 {
                    HStack {
                        Spacer()
                        Button {
                            Haptics.light()
                            withAnimation(Ink.Motion.settle) { dockOpen = false }
                        } label: {
                            Label("收起", systemImage: "chevron.down").font(.system(size: Ink.Size.small, weight: .medium)).foregroundStyle(Ink.inkSoft)
                        }
                        .buttonStyle(TapStyle(grow: 8))
                    }
                }
                ForEach(cards, id: \.self) { card in dockCard(card) }
            }
            .transition(.opacity)
        } else {
            ZStack(alignment: .top) {
                ForEach(Array(cards.dropFirst().prefix(2).enumerated()), id: \.offset) { index, _ in
                    RoundedRectangle(cornerRadius: Ink.Radius.card, style: .continuous)
                        .fill(Ink.paperRaised)
                        .overlay(RoundedRectangle(cornerRadius: Ink.Radius.card, style: .continuous).strokeBorder(Ink.rule))
                        .frame(height: 40)
                        .scaleEffect(x: 1 - 0.05 * CGFloat(index + 1), y: 1, anchor: .top)
                        .opacity(1 - 0.25 * Double(index + 1))
                        .offset(y: -6 * CGFloat(index + 1))
                }
                dockCard(cards[0])
            }
            .padding(.top, 12)
            .overlay(alignment: .top) {
                // The showing edges open the stack.
                Color.clear
                    .frame(height: 16)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        Haptics.light()
                        withAnimation(Ink.Motion.settle) { dockOpen = true }
                    }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("展开另外 \(cards.count - 1) 条")
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private func dockCard(_ card: DockCard) -> some View {
        switch card {
        case .waiting:
            if let waiting {
                // A plain ask is answered right here; a forced one (after reading the web) gets the full slip.
                if waiting.forced == true || waiting.answerable == false {
                    Button {
                        Haptics.grab()
                        typing = false
                        approving = waiting
                    } label: {
                        HStack(spacing: Ink.Space.m) {
                            Image(systemName: "seal").foregroundStyle(Ink.warn)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Words.t("候印 · \(waiting.tool ?? "要你同意")")).font(.system(size: Ink.Size.sub, weight: .semibold)).foregroundStyle(Ink.ink)
                                if let reason = waiting.reason {
                                    Text(reason).font(Ink.footnote).foregroundStyle(Ink.inkSoft).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                            Text(Words.t("去落印")).font(.system(size: Ink.Size.small, weight: .semibold)).foregroundStyle(Ink.accent)
                        }
                        .padding(Ink.Space.m)
                        .paperCard()
                    }
                    .buttonStyle(PressStyle())
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    InlineApproval(approval: waiting, team: team, name: team.bots.first { $0.id == waiting.botId }?.name ?? bot.name) {
                        typing = false
                        approving = waiting
                    }
                    .id(waiting.id)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        case .roam:
            RoamSlip(browser: team.browser) {
                typing = false
                roaming = true
            }
        case .working:
            if let words = liveWords {
                WorkingBar(words: words, icon: liveIcon, tools: team.toolCount[chat.key] ?? 0, since: workingSince ?? Date(), free: Grant.Preset.current == .free) {
                    following = true
                    toEnd()
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        case .away:
            awayCard
        }
    }

    private var draftField: some View {
        TextField(dictation.listening ? "正在听，说完点右边" : (working ? "在做 · 可以直接插话" : "同\(bot.name)说点什么…"), text: Binding(get: { draft }, set: { draft = $0 }), axis: .vertical)
            .font(largeText ? .body : Ink.label)
            .foregroundStyle(Ink.ink)
            .lineLimit(1...(largeText ? 3 : 6))
            .focused($typing)
            .onChange(of: draft) { old, new in keepLongPaste(old, new) }
            .padding(.vertical, 6)
            .frame(minHeight: 34)
    }

    private var composer: some View {
        ChatSection { composerContents }
    }

    private var composerContents: some View {
        VStack(spacing: Ink.Space.s) {
            // The plan sits right on the composer, as one block with it, not as a second bar floating above.
            VStack(spacing: Ink.Space.xs) {
                if let plan = team.plans[chat.key] {
                    PlanCard(steps: plan) { team.clearPlan(chat.key) }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                dock
            }
            if let problem = dictation.problem {
                Text(problem).font(Ink.footnote).foregroundStyle(Ink.stop)
                    .onTapGesture { dictation.problem = nil }
            }
            VStack(alignment: .leading, spacing: Ink.Space.s) {
                if let quote {
                    HStack(alignment: .top, spacing: Ink.Space.s) {
                        Rectangle().fill(Ink.accent).frame(width: 2)
                        Text(quote).font(Ink.footnote).foregroundStyle(Ink.inkSoft).lineLimit(3)
                        Spacer(minLength: 0)
                        Button {
                            withAnimation(Ink.Motion.settle) { self.quote = nil }
                        } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: Ink.Size.sub)).foregroundStyle(Ink.inkFaint)
                        }
                        .buttonStyle(TapStyle(grow: 8))
                        .accessibilityLabel("不引用了")
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Ink.Space.xs)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                if editing != nil {
                    HStack(spacing: Ink.Space.s) {
                        Image(systemName: "pencil").font(.system(size: Ink.Size.small, weight: .semibold))
                        Text("改了重发：之后的对话会重新来过").font(Ink.footnote)
                        Spacer()
                        Button(L.t("actions.cancel")) {
                            withAnimation(Ink.Motion.settle) {
                                editing = nil
                                draft = ""
                            }
                        }
                        .font(Ink.footnote.weight(.semibold))
                    }
                    .foregroundStyle(Ink.accent)
                    .padding(.top, Ink.Space.xs)
                }
                if !photos.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: Ink.Space.s) {
                            ForEach(Array(photos.enumerated()), id: \.offset) { index, data in
                                ZStack(alignment: .topTrailing) {
                                    if let image = UIImage(data: data) {
                                        Image(uiImage: image).resizable().scaledToFill()
                                            .frame(width: 56, height: 56)
                                            .clipShape(.rect(cornerRadius: Ink.Radius.small, style: .continuous))
                                    }
                                    Button {
                                        withAnimation(Ink.Motion.settle) { _ = photos.remove(at: index) }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: Ink.Size.body))
                                            .foregroundStyle(Ink.paper, Ink.ink.opacity(0.6))
                                    }
                                    .accessibilityLabel("移除第 \(index + 1) 张照片")
                                    .offset(x: 5, y: -5)
                                }
                            }
                        }
                        .padding(.top, 6)
                    }
                    .scrollIndicators(.hidden)
                }
                if !files.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: Ink.Space.s) {
                            ForEach(files, id: \.self) { path in
                                HStack(spacing: 4) {
                                    Image(systemName: "doc").font(.system(size: Ink.Size.small))
                                    Text((path as NSString).lastPathComponent).font(.system(size: Ink.Size.small, weight: .medium)).lineLimit(1)
                                    Button {
                                        withAnimation(Ink.Motion.settle) { files.removeAll { $0 == path } }
                                    } label: {
                                        Image(systemName: "xmark").font(.system(size: Ink.Size.micro, weight: .bold))
                                    }
                                    .buttonStyle(TapStyle(grow: 8))
                                    .accessibilityLabel("移除文件：\((path as NSString).lastPathComponent)")
                                }
                                .foregroundStyle(Ink.ink)
                                .padding(.horizontal, Ink.Space.m)
                                .frame(height: 30)
                                .background(Ink.mine, in: .capsule)
                            }
                        }
                        .padding(.top, 6)
                    }
                    .scrollIndicators(.hidden)
                }
                let suggestions = hints
                if !suggestions.isEmpty { hintStrip(suggestions) }
                if largeText { draftField }
                // One row at rest, like any messaging app: add, write, speak or send.
                HStack(alignment: .bottom, spacing: Ink.Space.s) {
                    Button {
                        Haptics.light()
                        typing = false
                        attaching = true
                    } label: {
                        chip("plus", nil, lit: !photos.isEmpty || !files.isEmpty)
                    }
                    .buttonStyle(PressStyle(haptic: false))
                    .accessibilityLabel(Words.t("加照片、文件，或改这段絮语的设置"))
                    .photosPicker(isPresented: $pickerShown, selection: $picks, maxSelectionCount: 4, matching: .images)
                    .fileImporter(isPresented: $importingFile, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                        if case .success(let urls) = result { withAnimation(Ink.Motion.settle) { receive(urls) } }
                    }
                    if !largeText { draftField }
                    // While writing: what it goes out with, as small icons in the same row, not a row of their own.
                    if composing {
                        HStack(spacing: 2) {
                            if isRoom { thinkChip } else { modelChip }
                            if team.place(of: chat.key) != .desk { placeChip }
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    }
                    Button {
                        Haptics.light()
                        typing = false
                        usageOpen = true
                    } label: {
                        ContextRing(share: context?.share ?? 0, showsNumber: !composing)
                    }
                    .buttonStyle(TapStyle())
                    .accessibilityLabel("用量：下次请求约占上下文的 \(UsageSheet.percent(context?.share ?? 0))")
                    action
                }
            }
            .animation(Ink.Motion.settle, value: composing)
            .padding(.horizontal, Ink.Space.s)
            .padding(.vertical, Ink.Space.s)
            .glassBacking(in: RoundedRectangle(cornerRadius: Ink.Radius.sheet, style: .continuous))
            if let hint {
                Text(hint)
                    .font(Ink.footnote)
                    .foregroundStyle(Ink.inkSoft)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .onTapGesture { withAnimation(Ink.Motion.settle) { self.hint = nil } }
            }
        }
        .padding(.horizontal, Ink.Bar.edge)
        .padding(.bottom, Ink.Space.s)
        .animation(petDockMotion, value: waiting?.id)
        .task(id: suggestionSource) { await loadSuggestions(suggestionSource) }
        .overlay(alignment: .top) {
            HStack(spacing: Ink.Space.s) {
                jumpButton("arrow.up", title: "chat.previousQuestion", earlier: true)
                    .opacity(jumpVisible ? 1 : 0)
                    .allowsHitTesting(jumpVisible)
                    .accessibilityHidden(!jumpVisible)
                jumpButton("arrow.down", title: "chat.nextQuestion", earlier: false)
                    .opacity(jumpVisible ? 1 : 0)
                    .allowsHitTesting(jumpVisible)
                    .accessibilityHidden(!jumpVisible)
                backToEnd
                    .opacity(historyPage != nil || farFromEnd && !following ? 1 : 0)
                    .allowsHitTesting(historyPage != nil || farFromEnd && !following)
                    .accessibilityHidden(historyPage == nil && (!farFromEnd || following))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .offset(y: -Ink.Bar.height)
            .animation(Ink.Motion.settle, value: jumpVisible)
            .animation(Ink.Motion.settle, value: farFromEnd && !following)
        }
    }

    private func lingerJumpButtons() {
        hideJumps?.cancel()
        hideJumps = Task {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            jumpVisible = false
        }
    }

    private func jumpButton(_ symbol: String, title: String, earlier: Bool) -> some View {
        Button {
            guard let target = question(earlier: earlier) else { return }
            Haptics.light()
            following = false
            jumpedTo = target
            lingerJumpButtons()
            withAnimation(Ink.Motion.settle) { scroller?.scrollTo(target, anchor: .top) }
        } label: {
            floating(symbol)
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(L.t(title))
    }

    private func question(earlier: Bool) -> String? {
        let rows = historyPage.map { $0[...] } ?? chat.lines.suffix(shownCount)
        let visible = Set(viewport.ids)
        let center = jumpedTo.flatMap { id in rows.firstIndex { $0.id == id } }
            ?? rows.firstIndex { visible.contains($0.id) }
        guard let center else { return earlier ? rows.last(where: { $0.kind == .user })?.id : nil }
        if earlier { return rows[..<center].last(where: { $0.kind == .user })?.id }
        let after = rows.index(after: center)
        return rows[after...].first(where: { $0.kind == .user })?.id
    }

    private func floating(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: Ink.Size.sub, weight: .semibold))
            .foregroundStyle(Ink.ink)
            .frame(width: 36, height: 36)
            .background(Ink.paperRaised, in: .circle)
            .overlay(Circle().strokeBorder(Ink.rule, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
            .contentShape(.circle)
    }

    private var backToEnd: some View {
                Button {
                    Haptics.light()
                    following = true
                    jumpedTo = nil
                    if historyPage == nil {
                        toEnd(animated: true)
                    } else {
                        historyPage = nil
                        followToEnd()
                    }
                } label: {
                    floating("arrow.down")
                }
                .buttonStyle(PressStyle())
                .transition(.scale(scale: 0.6).combined(with: .opacity))
                .accessibilityLabel(L.t("chat.latest"))
    }

    private static let end = "foot-of-page"

    /// Points of the page still below the visible part, counting the composer's inset at the bottom.
    private static func below(_ geometry: ScrollGeometry) -> CGFloat {
        geometry.contentSize.height + geometry.contentInsets.bottom - geometry.visibleRect.maxY
    }

    private func selectionChanged(_ id: UUID, _ started: Bool) {
        if started {
            selecting.insert(id)
            followPending?.cancel()
        } else {
            selecting.remove(id)
        }
    }

    /// Coalesce layout changes from the composer and a newly inserted row before moving the viewport.
    private func followToEnd(settle: Bool = true) {
        guard historyPage == nil, following, selecting.isEmpty else { return }
        followPending?.cancel()
        followPending = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(settle ? 32 : 16)) } catch { return }
            guard following else { return }
            toEnd()
        }
    }

    @State private var followPending: Task<Void, Never>?

    private func toEnd(animated: Bool = false) {
        guard historyPage == nil, selecting.isEmpty, let scroller else { return }
        if animated {
            withAnimation(Ink.Motion.settle) { scroller.scrollTo(Self.end, anchor: .bottom) }
        } else {
            scroller.scrollTo(Self.end, anchor: .bottom)
        }
    }

    @State private var pickerShown = false
    @State private var importingFile = false
    @State private var files: [String] = []
    @State private var hint: String?
    @State private var abilities = false
    @State private var attaching = false
    @State private var filesOpen = false
    @State private var dockOpen = false
    @State private var detailOpen = false
    @State private var afterDetail: String?
    @State private var attachPicked: AttachKind?
    @State private var deskPicking = false
    @State private var scanning = false
    @State private var linkAsking = false
    @State private var linkDraft = ""
    /// When the companion started on the current turn, for the seconds under the conversation.
    @State private var workingSince: Date?
    @State private var cardOpen = false
    @State private var glancing = false
    @State private var outlining = false
    @State private var renaming = false
    @State private var renameText = ""
    @State private var tuningOpen = false
    @State private var careOpen = false
    @State private var petSettingsOpen = false

    /// Writing something: the row of chips shows under the text field.
    private var composing: Bool {
        typing || !draft.isEmpty || !photos.isEmpty || !files.isEmpty || editing != nil || quote != nil || dictation.listening
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !photos.isEmpty || !files.isEmpty
    }

    private var action: some View {
        let mode: Int = dictation.listening ? 0 : (working && !canSend ? 1 : (canSend ? 2 : 3))
        let symbol = ["waveform", "stop.fill", "arrow.up", "mic"][mode]
        let fill: Color = [Ink.stop, Ink.ink, Ink.accent, .clear][mode]
        return Button {
            switch mode {
            case 0:
                Haptics.light()
                dictation.stop()
            case 1:
                if confirmStop {
                    Haptics.light()
                    askingStop = true
                } else {
                    Haptics.lock()
                    chat.stop()
                }
            case 2:
                Haptics.grab()
                if let editing {
                    redo(from: editing, text: draft)
                    self.editing = nil
                } else if let quote {
                    let quoted = quote.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
                    chat.send(quoted + "\n\n" + draft + fileNote, photos: photos)
                    self.quote = nil
                } else if working {
                    // While it works, a plain tap is 插话: heard after the step in progress.
                    chat.interject(outgoing, photos: photos)
                } else {
                    chat.send(outgoing, photos: photos)
                }
                clearComposer()
            default:
                listen()
            }
        } label: {
            ZStack {
                if mode == 0 {
                    Circle().fill(Ink.stop.opacity(0.25)).scaleEffect(1 + dictation.level * 0.6)
                }
                Image(systemName: symbol)
                    .font(.system(size: mode == 3 ? 16 : 15, weight: mode == 3 ? .medium : .bold))
                    .foregroundStyle(mode == 3 ? Ink.inkSoft : Ink.paper)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.variableColor.iterative, isActive: mode == 0)
                    .frame(width: 34, height: 34)
                    .background(fill, in: .circle)
            }
            .frame(width: 34, height: 34)
        }
        .buttonStyle(PressStyle(haptic: false))
        .confirmationDialog(L.t("chat.stopAsk"), isPresented: $askingStop, titleVisibility: .visible) {
            Button(L.t("chat.stopNow"), role: .destructive) {
                Haptics.lock()
                if working { chat.stop() }
            }
            Button(L.t("actions.cancel"), role: .cancel) {}
        } message: {
            Text(L.t("chat.stopAskNote"))
        }
        .animation(Ink.Motion.press, value: mode)
        .accessibilityLabel(["说完了", "让它停下", working ? "插话" : "发送", "说话"][mode])
        .contextMenu {
            if working && canSend && editing == nil && quote == nil {
                Button("插话：这一步做完就递给它", systemImage: "text.bubble") {
                    chat.interject(outgoing, photos: photos)
                    clearComposer()
                }
                Button("中断并发送", systemImage: "bolt") {
                    Haptics.thud()
                    chat.sendNow(outgoing, photos: photos)
                    clearComposer()
                }
                Button("排队：这轮做完再发", systemImage: "tray") {
                    chat.send(outgoing, photos: photos)
                    clearComposer()
                }
            }
        }
    }

    // MARK: / and @

    /// One suggestion over the composer: a command after 「/」, a file after 「@」.
    struct Hint: Identifiable {
        let id: String
        let icon: String
        let title: String
        let note: String
        let run: () -> Void
    }

    /// The word being typed after 「@」, if the draft ends in one.
    private var mention: String? {
        guard let at = draft.lastIndex(of: "@") else { return nil }
        let word = draft[draft.index(after: at)...]
        guard !word.contains(where: { $0 == " " || $0 == "\n" }) else { return nil }
        if at > draft.startIndex, let before = draft[..<at].last, !before.isWhitespace { return nil }
        return String(word)
    }

    private enum SuggestionSource: Equatable { case files, skills }

    private var suggestionSource: SuggestionSource? {
        let text = draft.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("/"), !text.contains("\n") { return .skills }
        return mention == nil ? nil : .files
    }

    private func loadSuggestions(_ source: SuggestionSource?) async {
        switch source {
        case .skills:
            let skills = await Task.detached(priority: .userInitiated) { SkillShelf.enabled }.value
            if !Task.isCancelled { draftState.skills = skills }
        case .files:
            let paths = await Task.detached(priority: .userInitiated) {
                Workspace.files(under: Workspace.root, cap: 800)
                    .filter { !$0.path.hasPrefix("技能/") && !$0.path.hasSuffix(".pdf.txt") }
                    .sorted { $0.date > $1.date }
                    .map(\.path)
            }.value
            if !Task.isCancelled { draftState.files = paths }
        case nil:
            draftState.files = []
            draftState.skills = []
        }
    }

    private var hints: [Hint] {
        let text = draft.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("/"), !text.contains("\n") {
            let typed = String(text.dropFirst()).lowercased()
            var list: [Hint] = [
                Hint(id: "leaf", icon: "square.and.pencil", title: "/新对话", note: Words.t("另起一叶，眼下的收起来")) {
                    draft = ""
                    team.turnLeaf(chat.key)
                },
                Hint(id: "redo", icon: "arrow.clockwise", title: "/重来", note: "最后一句重新回答") {
                    draft = ""
                    chat.retry()
                },
                Hint(id: "squeeze", icon: "rectangle.compress.vertical", title: "/压缩", note: "把较早的话写成提要，省上下文") {
                    draft = ""
                    Task { _ = try? await team.compress(chat.key) }
                },
                Hint(id: "detail", icon: "square.and.arrow.up", title: "/导出", note: "看这段对话的详情，可导出成 Markdown") {
                    draft = ""
                    detailOpen = true
                },
            ]
            for item in draftState.skills where item.on {
                list.append(Hint(id: "skill-" + item.id, icon: "wand.and.stars", title: "/" + item.skill.name, note: item.skill.description) {
                    draft = "用技能「\(item.skill.name)」："
                })
            }
            return typed.isEmpty ? list : list.filter { $0.title.lowercased().contains(typed) || $0.note.lowercased().contains(typed) }
        }
        if let word = mention?.lowercased() {
            let all = draftState.files.lazy.filter { word.isEmpty || $0.lowercased().contains(word) }.prefix(6)
            return all.map { file in
                Hint(id: "file-" + file, icon: "doc", title: (file as NSString).lastPathComponent, note: Words.t("书案/") + file) {
                    if let at = draft.lastIndex(of: "@") { draft = String(draft[..<at]) }
                    if !files.contains(file) { withAnimation(Ink.Motion.settle) { files.append(file) } }
                }
            }
        }
        return []
    }

    private func hintStrip(_ hints: [Hint]) -> some View {
        VStack(spacing: 0) {
            ForEach(hints.prefix(6)) { hint in
                Button {
                    Haptics.tick(0.4)
                    hint.run()
                } label: {
                    HStack(spacing: Ink.Space.m) {
                        Image(systemName: hint.icon).font(.system(size: Ink.Size.sub)).foregroundStyle(Ink.accent).frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(hint.title).font(.system(size: Ink.Size.sub, weight: .semibold)).foregroundStyle(Ink.ink).lineLimit(1)
                            Text(hint.note).font(Ink.footnote).foregroundStyle(Ink.inkSoft).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Ink.Space.m)
                    .padding(.vertical, Ink.Space.s)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, Ink.Space.xs)
        .paperCard()
        .padding(.bottom, Ink.Space.s)
        .transition(.opacity.combined(with: .offset(y: 6)))
    }

    /// What the send button sends: the draft and the files picked for it.
    private var outgoing: String {
        let words = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return (words.isEmpty && !files.isEmpty ? "看看这些文件。" : draft) + fileNote
    }

    private func clearComposer() {
        historyPage = nil
        draft = ""
        photos = []
        files = []
        following = true
        followToEnd()
    }

    /// Smaller and as JPEG: quick to send and enough for a model to read.
    static func shrink(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let scale = min(1, 1568 / max(1, max(image.size.width, image.size.height)))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            .jpegData(compressionQuality: 0.8)
    }
}

/// 行迹: one line when closed, a timeline when open. A running trace shows its newest step.
private struct Trace: View {
    let line: ChatLine
    var visit: (URL) -> Void = { _ in }
    var openFile: (URL) -> Void = { _ in }
    /// Takes back something the companion wrote into 拾遗 in these steps. False: it was not there any more.
    var unremember: ((String, String) -> Bool)?
    @State private var undone: Set<String> = []

    private func forget(_ memory: Remembered, with unremember: (String, String) -> Bool) {
        Haptics.light()
        // Shown as taken back only if it was: an entry you wrote or edited stays, and so does this line.
        guard let id = memory.memoryID else { return }
        if unremember(id, memory.fact) {
            withAnimation(Ink.Motion.settle) { _ = undone.insert(id) }
        } else {
            Haptics.lock()
        }
    }

    /// What these steps wrote into 拾遗, as the model wrote it.
    private struct Remembered: Identifiable {
        let id: Int
        let memoryID: String?
        let fact: String
    }

    private var remembered: [Remembered] {
        line.tools.enumerated().compactMap { index, tool in
            guard tool.hasPrefix("记住："), !tool.hasSuffix("（没成功）"), index < line.details.count,
                  line.details[index].output.hasPrefix("记下了"),
                  let fact = JSONValue.parse(line.details[index].input)?["fact"]?.string else { return nil }
            let id = line.details[index].full.flatMap { UUID(uuidString: $0) == nil ? nil : $0 }
            return Remembered(id: index, memoryID: id, fact: fact.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// What the steps left behind worth a card: a date set, a reminder, a file written, a command run.
    private struct Keepsake: Identifiable {
        enum Kind { case event, reminder, file, remoteFile, command, health }
        let id: Int
        let kind: Kind
        let title: String
        let detail: String
        var url: URL?
        /// A changed file's whole comparison.
        var diff: String?
    }

    /// A file change opened to its whole comparison.
    private struct DiffShow: Identifiable {
        let id = UUID()
        let title: String
        let place: String
        let diff: String
        let url: URL?
    }
    @State private var diffing: DiffShow?

    /// A file to read rather than code to review — a report, a page, a picture: a tap opens it to read, as other
    /// agents do, instead of a comparison of lines.
    private static func isDocument(_ item: Keepsake) -> Bool {
        guard let url = item.url else { return false }
        let kinds: Set<String> = ["md", "markdown", "txt", "pdf", "doc", "docx", "rtf", "pages", "xls", "xlsx", "csv", "numbers",
                                  "ppt", "pptx", "key", "png", "jpg", "jpeg", "gif", "heic", "webp", "svg", "html", "htm",
                                  "mp3", "m4a", "wav", "mp4", "mov"]
        return kinds.contains(url.pathExtension.lowercased())
    }

    /// The files these steps wrote or changed.
    private var changedFiles: [Keepsake] { keepsakes.filter { $0.kind == .file || $0.kind == .remoteFile } }

    /// Lines added and taken out, read off a comparison.
    private static func tally(_ diff: String?) -> (added: Int, removed: Int) {
        guard let diff else { return (0, 0) }
        var added = 0, removed = 0
        for row in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if row.hasPrefix("+"), !row.hasPrefix("+++") { added += 1 }
            if row.hasPrefix("-"), !row.hasPrefix("---") { removed += 1 }
        }
        return (added, removed)
    }

    /// Several files changed in one go: one card, 「改动了 3 个文件 +120 −40」, a row for each, opened to its comparison.
    private var changesCard: some View {
        let files = changedFiles
        let counts = files.map { Self.tally($0.diff) }
        let added = counts.reduce(0) { $0 + $1.added }
        let removed = counts.reduce(0) { $0 + $1.removed }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Ink.Space.s) {
                Image(systemName: "arrow.triangle.pull").font(.system(size: Ink.Size.sub)).foregroundStyle(Ink.inkSoft)
                Text("改动了 \(files.count) 个文件").font(.system(size: Ink.Size.sub, weight: .semibold)).foregroundStyle(Ink.ink)
                Spacer()
                tallyText(added, removed)
            }
            .padding(Ink.Space.l)
            ForEach(Array(files.enumerated()), id: \.element.id) { index, item in
                Kit.rule(inset: Ink.Space.l)
                Button {
                    Haptics.light()
                    if !Self.isDocument(item), let diff = item.diff, !diff.isEmpty {
                        diffing = DiffShow(title: item.title, place: item.detail, diff: diff, url: item.url)
                    } else if let url = item.url {
                        openFile(url)
                    }
                } label: {
                    HStack(spacing: Ink.Space.m) {
                        let fresh = counts[index].removed == 0 && counts[index].added > 0
                        Image(systemName: fresh ? "doc.badge.plus" : "doc.text")
                            .font(.system(size: Ink.Size.body)).foregroundStyle(fresh ? Ink.ok : Ink.inkSoft).frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(item.title).font(.system(size: Ink.Size.sub, weight: .medium)).foregroundStyle(Ink.ink).lineLimit(1)
                                if fresh { Text("新建").font(.system(size: Ink.Size.micro, weight: .medium)).foregroundStyle(Ink.ok) }
                            }
                            Text(item.detail).font(.system(size: Ink.Size.micro)).foregroundStyle(Ink.inkFaint).lineLimit(1)
                        }
                        Spacer(minLength: Ink.Space.s)
                        tallyText(counts[index].added, counts[index].removed)
                    }
                    .padding(.horizontal, Ink.Space.l)
                    .padding(.vertical, Ink.Space.m)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
            }
        }
        .paperCard()
        .padding(.top, Ink.Space.s)
    }

    private func tallyText(_ added: Int, _ removed: Int) -> some View {
        HStack(spacing: 6) {
            if added > 0 { Text("+\(added)").foregroundStyle(Ink.ok) }
            if removed > 0 { Text("−\(removed)").foregroundStyle(Ink.stop) }
        }
        .font(Ink.mono(Ink.Size.small))
    }

    private var keepsakes: [Keepsake] {
        var out: [Keepsake] = []
        for (index, tool) in line.tools.enumerated() where !tool.hasSuffix("（没成功）") {
            let output = index < line.details.count ? line.details[index].output : ""
            let full = index < line.details.count ? line.details[index].full : nil
            if tool.hasPrefix("新建日程：") {
                out.append(Keepsake(id: index, kind: .event, title: String(tool.dropFirst(5)), detail: "已加进日历", url: URL(string: "calshow://")))
            } else if tool.hasPrefix("加提醒：") {
                out.append(Keepsake(id: index, kind: .reminder, title: String(tool.dropFirst(4)), detail: "已加进提醒事项", url: URL(string: "x-apple-reminderkit://")))
            } else if tool.hasPrefix("健康："), !output.isEmpty {
                out.append(Keepsake(id: index, kind: .health, title: String(tool.dropFirst(3)), detail: output, url: URL(string: "x-apple-health://"), diff: full))
            } else if tool.hasPrefix("书案：写 ") || tool.hasPrefix("书案：改 ") {
                let path = String(tool.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if let file = Workspace.resolve(path), FileManager.default.fileExists(atPath: file.path) {
                    let change = Diff.counts(in: output).map { " · −\($0.removed) +\($0.added) 行" } ?? ""
                    if let kept = out.firstIndex(where: { $0.url == file }) {
                        out[kept] = Keepsake(id: out[kept].id, kind: .file, title: file.lastPathComponent, detail: Words.t("书案/") + Workspace.relative(file) + " · 改了几次，这是最后一次", url: file, diff: full ?? out[kept].diff)
                    } else {
                        out.append(Keepsake(id: index, kind: .file, title: file.lastPathComponent, detail: Words.t("书案/") + Workspace.relative(file) + change, url: file, diff: full))
                    }
                }
            } else if tool.hasPrefix("斗室：") || tool.hasPrefix("远山 · ") {
                let rest = tool.split(separator: "：", maxSplits: 1).last.map(String.init) ?? tool
                if ["读 ", "找 ", "搜 ", "翻看 ", "看图 ", "看后台任务", "看看后台任务", "停掉后台任务", "后台跑"].contains(where: { rest.hasPrefix($0) }) { continue }
                if rest.hasPrefix("写 ") || rest.hasPrefix("改 ") {
                    let where_ = tool.split(separator: "：", maxSplits: 1).first.map(String.init) ?? ""
                    let change = Diff.counts(in: output).map { " · −\($0.removed) +\($0.added) 行" } ?? ""
                    out.append(Keepsake(id: index, kind: .remoteFile, title: (String(rest.dropFirst(2)) as NSString).lastPathComponent, detail: where_ + " · " + String(rest.dropFirst(2)) + change, diff: full))
                    continue
                }
                guard tool.hasPrefix("斗室：") else { continue }
                let tail = output.split(separator: "\n").suffix(3).joined(separator: "\n")
                out.append(Keepsake(id: index, kind: .command, title: rest, detail: tail.isEmpty ? "（没有输出）" : tail))
            }
        }
        return out
    }
    @State private var open = Pref.traceOpen

    /// While it works: 「第 3 步：搜索 重庆天气」.
    private var liveLine: String {
        guard let current = line.tools.last else { return "沉吟" }
        return "第 \(line.tools.count) 步：" + current
    }

    /// Done: 「6 步 · 搜索、读网页、写文件 · 12 秒」.
    private var summary: String {
        var kinds: [String] = []
        for tool in line.tools {
            let kind = String(tool.split(whereSeparator: { $0 == "：" || $0 == "·" }).first ?? Substring(tool)).trimmingCharacters(in: .whitespaces)
            if !kind.isEmpty, !kinds.contains(kind) { kinds.append(kind) }
        }
        var out = "\(line.tools.count) 步"
        if !kinds.isEmpty { out += " · " + kinds.prefix(3).joined(separator: "、") + (kinds.count > 3 ? " 等" : "") }
        if let seconds = line.seconds { out += " · " + Clock.said(seconds) }
        return out
    }
    @State private var peeking: Set<Int> = []

    /// Pages a companion opened in 远游 during these steps, newest last, each once.
    private var pages: [URL] {
        var seen: [URL] = []
        for tool in line.tools where tool.hasPrefix("远游：http") && !tool.hasSuffix("（没成功）") {
            if let url = URL(string: String(tool.dropFirst(3)).trimmingCharacters(in: .whitespaces)), !seen.contains(url) { seen.append(url) }
        }
        return seen
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Ink.Motion.unfold) { open.toggle() }
            } label: {
                HStack(spacing: Ink.Space.s) {
                    if line.live {
                        ProgressView().controlSize(.mini).tint(Ink.accent)
                    } else {
                        Image(systemName: "checkmark.circle").font(.system(size: Ink.Size.sub, weight: .medium)).foregroundStyle(Ink.ok)
                    }
                    Text(Words.t(line.live ? liveLine : summary))
                        .font(Ink.secondary)
                        .foregroundStyle(Ink.inkSoft)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: Ink.Size.micro, weight: .bold))
                        .foregroundStyle(Ink.inkFaint)
                        .rotationEffect(.degrees(open ? -180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            // One line whether it works or is done (「第 3 步：搜索 重庆天气」); every step when you open it.
            if open {
                let hidden = 0
                VStack(alignment: .leading, spacing: 0) {
                    if hidden > 0 {
                        Button {
                            withAnimation(Ink.Motion.unfold) { open = true }
                        } label: {
                            Text("前面还有 \(hidden) 步")
                                .font(Ink.footnote).foregroundStyle(Ink.inkFaint)
                                .padding(.leading, 30).padding(.bottom, Ink.Space.s)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(Array(line.tools.enumerated()).filter { $0.offset >= hidden }, id: \.offset) { index, tool in
                        step(tool, index: index, last: index == line.tools.count - 1)
                    }
                }
                .padding(.top, Ink.Space.m)
                .transition(.asymmetric(
                    insertion: .opacity.animation(Ink.Motion.settle.delay(0.08)),
                    removal: .opacity.animation(.easeOut(duration: 0.12))
                ))
            }
        }
        .clipped()
        .animation(Ink.Motion.settle, value: line.tools.count)
        // Done: everything folds into the one line again.
        .onChange(of: line.live) { _, live in
            if !live { withAnimation(Ink.Motion.unfold) { open = Pref.traceOpen } }
        }
        if !line.live, changedFiles.count >= 2 {
            changesCard
        }
        if !line.live {
            ForEach(changedFiles.count >= 2 ? keepsakes.filter { $0.kind != .file && $0.kind != .remoteFile } : keepsakes) { item in
                Button {
                    Haptics.light()
                    switch item.kind {
                    case .file, .remoteFile:
                        if !Self.isDocument(item), let diff = item.diff, !diff.isEmpty {
                            diffing = DiffShow(title: item.title, place: item.detail, diff: diff, url: item.url)
                        } else if let url = item.url {
                            openFile(url)
                        }
                    case .event, .reminder, .health: if let url = item.url { UIApplication.shared.open(url) }
                    case .command: break
                    }
                } label: {
                    if item.kind == .health {
                        HealthCard(text: item.detail, format: item.diff)
                    } else {
                    HStack(alignment: .top, spacing: Ink.Space.m) {
                        Image(systemName: Self.keepsakeIcon(item.kind)).font(.system(size: Ink.Size.body)).foregroundStyle(Ink.accent).frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.kind == .command ? "# " + item.title : item.title)
                                .font(item.kind == .command ? Ink.mono(Ink.Size.small, weight: .medium) : .system(size: Ink.Size.sub, weight: .medium))
                                .foregroundStyle(Ink.ink).lineLimit(2)
                            Text(item.detail)
                                .font(item.kind == .command ? Ink.mono(Ink.Size.micro) : Ink.footnote)
                                .foregroundStyle(Ink.inkSoft).lineLimit(3)
                            if !Self.isDocument(item), let diff = item.diff, !diff.isEmpty {
                                // The first few changed lines, so the card shows what changed at a glance.
                                DiffText(hunk: DiffText.glance(diff), limit: 5)
                                    .padding(.top, 4)
                                    .allowsHitTesting(false)
                            }
                        }
                        Spacer(minLength: 0)
                        if item.kind != .command, item.kind != .remoteFile || item.diff != nil {
                            Image(systemName: "chevron.right").font(.system(size: Ink.Size.micro, weight: .semibold)).foregroundStyle(Ink.inkFaint)
                        }
                    }
                    .padding(Ink.Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .paperCard()
                    }
                }
                .buttonStyle(PressStyle())
                .padding(.top, Ink.Space.s)
            }
        }
        if !line.live, let unremember {
            // 「记下了」: one quiet line per thing remembered, as Cindy's learning footer; 撤回 right there, or long-press.
            ForEach(remembered) { memory in
                let fact = memory.fact
                let gone = memory.memoryID.map(undone.contains) ?? false
                HStack(alignment: .firstTextBaseline, spacing: Ink.Space.xs) {
                    Image(systemName: gone ? "bookmark.slash" : "bookmark")
                        .font(.system(size: Ink.Size.micro))
                    Text(gone ? "撤回了：\(fact)" : "记下了：\(fact)")
                        .font(Ink.footnote)
                        .strikethrough(gone)
                        .lineLimit(2)
                    Spacer(minLength: Ink.Space.s)
                    if !gone, memory.memoryID != nil {
                        Button("撤回") { forget(memory, with: unremember) }
                            .font(.system(size: Ink.Size.small, weight: .medium))
                            .foregroundStyle(Ink.accent)
                            .buttonStyle(.plain)
                    }
                }
                .foregroundStyle(Ink.inkFaint)
                .padding(.top, Ink.Space.xs)
                .contentShape(Rectangle())
                .contextMenu {
                    if !gone, memory.memoryID != nil {
                        Button("撤回这条", systemImage: "bookmark.slash") { forget(memory, with: unremember) }
                    }
                    Button("复制", systemImage: "doc.on.doc") { UIPasteboard.general.string = fact }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(gone ? "撤回了：\(fact)" : "记下了：\(fact)")
            }
        }
        Color.clear.frame(height: 0)
            .sheet(item: $diffing) { show in
                DiffSheet(title: show.title, place: show.place, diff: show.diff, url: show.url) { url in
                    diffing = nil
                    openFile(url)
                }
            }
        if !pages.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: Ink.Space.s) {
                    ForEach(pages, id: \.self) { url in
                        Button {
                            Haptics.light()
                            visit(url)
                        } label: {
                            HStack(spacing: Ink.Space.s) {
                                Image(systemName: "safari").font(.system(size: Ink.Size.sub)).foregroundStyle(Ink.accent)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(url.host() ?? url.absoluteString).font(.system(size: Ink.Size.small, weight: .medium)).foregroundStyle(Ink.ink).lineLimit(1)
                                    Text(url.path().isEmpty || url.path() == "/" ? "首页" : url.path()).font(.system(size: Ink.Size.micro)).foregroundStyle(Ink.inkFaint).lineLimit(1)
                                }
                            }
                            .padding(.horizontal, Ink.Space.m)
                            .padding(.vertical, Ink.Space.s)
                            .frame(maxWidth: 220, alignment: .leading)
                            .paperCard()
                        }
                        .buttonStyle(PressStyle())
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
            .padding(.top, Ink.Space.s)
        }
    }

    private func step(_ tool: String, index: Int, last: Bool) -> some View {
        let parts = tool.split(separator: "：", maxSplits: 1).map(String.init)
        let name = parts.first ?? tool
        let detail = parts.count > 1 ? parts[1] : nil
        let failed = tool.hasSuffix("（没成功）")
        let more = index < line.details.count ? line.details[index] : nil
        let shown = peeking.contains(index)
        return HStack(alignment: .top, spacing: Ink.Space.m) {
            VStack(spacing: 0) {
                Image(systemName: failed ? "exclamationmark" : Self.icon(for: name))
                    .font(.system(size: Ink.Size.small, weight: .medium))
                    .foregroundStyle(failed ? Ink.stop : Ink.inkSoft)
                    .frame(width: 22, height: 22)
                if !last { Rectangle().fill(Ink.rule).frame(width: 1).frame(maxHeight: .infinity).padding(.vertical, 2) }
            }
            VStack(alignment: .leading, spacing: 2) {
                // One line per step: what kind of thing, then what exactly. Time only when it was worth waiting for.
                HStack(alignment: .firstTextBaseline, spacing: Ink.Space.s) {
                    (Text(Words.t(Self.word(for: name))).foregroundStyle(Ink.ink).fontWeight(.medium)
                        + Text(detail.map { "  " + $0 } ?? "").foregroundStyle(Ink.inkSoft))
                        .font(.system(size: Ink.Size.sub))
                        .lineLimit(shown ? nil : 1)
                    Spacer(minLength: 0)
                    if let seconds = more?.seconds, seconds >= 2 {
                        Text(Clock.said(seconds)).font(.system(size: Ink.Size.small).monospacedDigit()).foregroundStyle(Ink.inkFaint)
                    }
                    if shown {
                        Image(systemName: "chevron.up").font(.system(size: Ink.Size.micro, weight: .semibold)).foregroundStyle(Ink.inkFaint)
                    }
                }
                .frame(minHeight: 22)
                if shown, let more {
                    VStack(alignment: .leading, spacing: Ink.Space.xs) {
                        if !more.input.isEmpty, more.input != "{}" {
                            Text("交给它的").font(Ink.footnote).foregroundStyle(Ink.inkFaint)
                            Text(Self.tidy(more.input)).font(Ink.mono(Ink.Size.small)).foregroundStyle(Ink.inkSoft).lineLimit(12)
                        }
                        if let name = more.photo, let data = Disk.photo(name), let image = UIImage(data: data) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 260)
                                .clipShape(.rect(cornerRadius: Ink.Radius.small, style: .continuous))
                                .padding(.top, 2)
                        }
                        Text("它回来的").font(Ink.footnote).foregroundStyle(Ink.inkFaint).padding(.top, 2)
                        if let hunk = Diff.hunk(in: more.output) {
                            Text(more.output.components(separatedBy: "\n").first ?? "").font(Ink.mono(Ink.Size.small)).foregroundStyle(Ink.inkSoft)
                            DiffText(hunk: hunk)
                        } else {
                            Text(more.output.isEmpty ? "（空）" : String(more.output.prefix(1500))).font(Ink.mono(Ink.Size.small)).foregroundStyle(Ink.inkSoft).lineLimit(24)
                        }
                    }
                    .textSelection(.enabled)
                    .padding(Ink.Space.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Ink.mine.opacity(0.6), in: .rect(cornerRadius: Ink.Radius.small, style: .continuous))
                    .padding(.top, Ink.Space.xs)
                    .transition(.opacity)
                }
            }
            .padding(.bottom, last ? 0 : Ink.Space.s + 2)
            .contentShape(Rectangle())
            .onTapGesture {
                guard more != nil else { return }
                withAnimation(Ink.Motion.settle) {
                    if shown { peeking.remove(index) } else { peeking.insert(index) }
                }
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private static func keepsakeIcon(_ kind: Keepsake.Kind) -> String {
        switch kind {
        case .event: "calendar.badge.checkmark"
        case .reminder: "checklist"
        case .file: "doc.text"
        case .remoteFile: "doc.badge.gearshape"
        case .command: "terminal"
        case .health: "heart.text.square"
        }
    }

    /// Tool arguments as short lines: `key: value`.
    static func tidy(_ json: String) -> String {
        guard let value = JSONValue.parse(json), case .object(let map) = value else { return json }
        return map.keys.sorted().map { key in
            let item = map[key]!
            return "\(key): \(item.string ?? item.compact)"
        }.joined(separator: "\n")
    }

    /// The glossary's names for what a tool does.
    static func word(for label: String) -> String {
        switch label {
        case "搜索": "寻访"
        case "读网页": Words.t("远游")
        case "记住": Words.t("拾遗")
        case "忘掉": Words.t("删去拾遗")
        case "看日历", "看提醒事项": "翻看"
        case "新建日程", "加提醒": Words.t("落印 · \(label)")
        default: label.hasPrefix("约好") ? "来信" : label
        }
    }

    static func icon(for label: String) -> String {
        switch label {
        case "搜索": return "magnifyingglass"
        case "读网页": return "globe"
        case "清单", "计划": return "list.bullet"
        case "写文件", "改文件": return "doc.text"
        case "读文件": return "doc"
        case "命令", "终端": return "terminal"
        default: break
        }
        return poeticIcon(label)
    }

    private static func poeticIcon(_ label: String) -> String {
        switch Words.poetic(label) {
        case "搜索": "magnifyingglass"
        case "读网页": "globe"
        case "远游": "safari"
        case "书案": "books.vertical"
        case "斗室": "terminal"
        case "所在": "location"
        case "远山": "mountain.2"
        case "递笺": "square.and.pencil"
        case "信匣": "lock.rectangle.stack"
        case "通讯录": "person.crop.circle"
        case "相册": "photo.on.rectangle"
        case "步数": "figure.walk"
        case "剪贴板": "doc.on.clipboard"
        case "打开": "arrow.up.forward.app"
        case "手机": "iphone"
        case "记住", "忘掉": "bookmark"
        case "看日历", "新建日程": "calendar"
        case "看提醒事项", "加提醒": "checklist"
        default: label.hasPrefix("约好") ? "envelope" : "wrench.and.screwdriver"
        }
    }
}


/// The line under the conversation while the companion works: what it is doing, and for how long.
/// Above the composer while the companion works, after DSH Go: what it is doing, how many tools so far, how long.
/// A tap goes to the bottom of the conversation.
private struct WorkingBar: View {
    let words: String
    let icon: String
    let tools: Int
    let since: Date
    /// Everything set to 放手: said on the bar, so it is never forgotten.
    var free = false
    let tap: () -> Void

    /// A word that grows with the work. The same few minutes always get the same word, so it does not flicker.
    private func mood(at now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(since) / 60)
        let hour = Calendar.current.component(.hour, from: now)
        let pools: [String]
        switch (tools, minutes, hour) {
        case (_, _, 0..<5): pools = ["夜深了，还在做", "陪你熬一会儿", "轻手轻脚地做"]
        case (0, 1..., _): pools = ["想得有点久", "在琢磨", "这题不简单"]
        case (0, _, _): return ""
        case (1...2, _, _): pools = ["上手了", "开个头"]
        case (3...6, _, _): pools = ["手感来了", "顺着往下做"]
        case (7...14, _, _): pools = ["越做越顺", "快理清了"]
        default: pools = ["大活，慢慢来", "一步步啃"]
        }
        // A new word only every two minutes or with the next stage.
        let slot = minutes / 2 + tools / 3
        return pools[slot % pools.count]
    }

    var body: some View {
        Button(action: tap) {
            HStack(spacing: Ink.Space.s) {
                Image(systemName: icon)
                    .font(.system(size: Ink.Size.small, weight: .semibold))
                    .foregroundStyle(Ink.accent)
                    .symbolEffect(.pulse)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 18)
                Text(Words.t(words))
                    .font(.system(size: Ink.Size.sub, weight: .semibold))
                    .foregroundStyle(Ink.ink)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                TimelineView(.periodic(from: since, by: 30)) { context in
                    let word = mood(at: context.date)
                    let parts = [tools > 0 ? "工具 ×\(tools)" : "", word].filter { !$0.isEmpty }
                    if !parts.isEmpty {
                        Text(parts.joined(separator: "，"))
                            .font(.system(size: Ink.Size.small))
                            .foregroundStyle(Ink.inkSoft)
                            .lineLimit(1)
                    }
                }
                .layoutPriority(-1)
                Spacer(minLength: Ink.Space.s)
                if free {
                    Text("放手").font(.system(size: Ink.Size.micro, weight: .semibold)).foregroundStyle(Ink.warn)
                        .padding(.horizontal, 6).frame(height: 18)
                        .background(Ink.warn.opacity(0.14), in: .capsule)
                }
                TimelineView(.periodic(from: since, by: 1)) { context in
                    let seconds = max(0, Int(context.date.timeIntervalSince(since)))
                    Text(Clock.running(seconds))
                        .font(.system(size: Ink.Size.small).monospacedDigit())
                        .foregroundStyle(Ink.inkSoft)
                        .contentTransition(.numericText())
                }
            }
            .padding(.horizontal, Ink.Space.l)
            .frame(height: 40)
            .glassFace(in: Capsule())
            .animation(Ink.Motion.settle, value: words)
        }
        .buttonStyle(PressStyle(haptic: false))
        .accessibilityElement(children: .combine)
        .accessibilityHint("回到对话最底下")
    }
}


/// Three dots that rise in turn.
private struct Dots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Ink.inkSoft)
                        .frame(width: 3.5, height: 3.5)
                        .offset(y: -2.5 * max(0, sin((time * 5) - Double(index) * 0.8)))
                }
            }
            .padding(.leading, 2)
        }
        .frame(height: 10)
    }
}


/// 出处: the pages behind an answer, as small cards with the site's name; a tap opens the page in 远游.
struct SourcesRow: View {
    let urls: [URL]
    /// What the answer called each page, where it linked one: 「中国天气网」 rather than 「weather.com.cn」.
    var titles: [URL: String] = [:]
    let open: (URL) -> Void
    @State private var listing = false

    /// One per site, in the order they were read.
    private var sites: [URL] {
        var seen: Set<String> = []
        return urls.filter { seen.insert(Self.site($0)).inserted }
    }

    var body: some View {
        // Folded like other agents do it: the sites' icons overlapping, and how many; the list opens on a tap.
        Button {
            Haptics.light()
            listing = true
        } label: {
            HStack(spacing: Ink.Space.s) {
                HStack(spacing: -7) {
                    ForEach(Array(sites.prefix(4).enumerated()), id: \.offset) { index, url in
                        BrandIcon(domain: Self.site(url), mark: String(Self.site(url).first ?? "?").uppercased(), tint: Ink.inkSoft, size: 20)
                            .clipShape(Circle())
                            .overlay(Circle().strokeBorder(Ink.paper, lineWidth: 1.5))
                            .zIndex(Double(10 - index))
                    }
                }
                Text("\(urls.count) 个来源")
                    .font(.system(size: Ink.Size.small, weight: .medium))
                    .foregroundStyle(Ink.inkSoft)
            }
            .padding(.leading, 6)
            .padding(.trailing, 12)
            .frame(height: 32)
            .background(Ink.mine, in: .capsule)
        }
        .buttonStyle(PressStyle(haptic: false))
        .accessibilityLabel("\(urls.count) 个来源，点开看")
        .sheet(isPresented: $listing) {
            SourcesSheet(urls: urls, titles: titles) { url in
                listing = false
                open(url)
            }
            .presentationDetents([.medium, .large])
        }
    }

    /// The links written in an answer, 「[名字](网址)」, in order.
    /// Worked out once per reply text: the chat redraws often, and every reply asks on each redraw.
    @MainActor private static var citedCache: [String: [(title: String, url: URL)]] = [:]

    @MainActor static func cited(in text: String) -> [(title: String, url: URL)] {
        if let known = citedCache[text] { return known }
        let found = findCited(in: text)
        if citedCache.count > 400 { citedCache.removeAll() }
        citedCache[text] = found
        return found
    }

    private static func findCited(in text: String) -> [(title: String, url: URL)] {
        var found: [(title: String, url: URL)] = []
        for match in text.matches(of: #/\[([^\]\n]+)\]\((https?://[^)\s]+)\)/#) {
            guard let url = URL(string: String(match.output.2)), url.host != nil, !isSearchPage(url),
                  !found.contains(where: { $0.url == url }) else { continue }
            found.append((String(match.output.1).trimmingCharacters(in: .whitespaces), url))
        }
        return found
    }

    @MainActor static func titles(in text: String) -> [URL: String] {
        Dictionary(cited(in: text).map { ($0.url, $0.title) }, uniquingKeysWith: { first, _ in first })
    }

    /// A search engine's list of results is how the pages were found, not a source.
    static func isSearchPage(_ url: URL) -> Bool {
        let host = site(url), path = url.path()
        let engines = ["bing.com", "cn.bing.com", "google.com", "baidu.com", "sogou.com", "so.com", "duckduckgo.com", "search.yahoo.com"]
        return engines.contains(host) && (path.hasPrefix("/search") || path == "/s" || path == "/web" || path == "/" || path.isEmpty)
    }

    /// 「zhihu.com」 from 「https://www.zhihu.com/question/…」.
    static func site(_ url: URL) -> String {
        var host = url.host() ?? url.absoluteString
        if host.hasPrefix("www.") { host.removeFirst(4) }
        if host.hasPrefix("m.") { host.removeFirst(2) }
        return host
    }
}


/// The sources of a reply, one per row: the site's icon, the page's address, and where it leads.
private struct SourcesSheet: View {
    let urls: [URL]
    var titles: [URL: String] = [:]
    let open: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
                        if index > 0 { Rectangle().fill(Ink.rule).frame(height: 0.5).padding(.leading, 60) }
                        Button {
                            Haptics.light()
                            open(url)
                        } label: {
                            HStack(spacing: Ink.Space.m) {
                                BrandIcon(domain: SourcesRow.site(url), mark: String(SourcesRow.site(url).first ?? "?").uppercased(), tint: Ink.inkSoft, size: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    // The name the answer gave it, when it gave one; then the site.
                                    Text(titles[url] ?? SourcesRow.site(url)).font(.system(size: Ink.Size.sub, weight: .medium)).foregroundStyle(Ink.ink).lineLimit(1)
                                    Text(titles[url] == nil ? Self.path(url) : SourcesRow.site(url)).font(.system(size: Ink.Size.small)).foregroundStyle(Ink.inkFaint).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.up.right").font(.system(size: Ink.Size.small, weight: .semibold)).foregroundStyle(Ink.inkFaint)
                            }
                            .padding(.horizontal, Ink.Space.l)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressStyle(haptic: false))
                        .contextMenu {
                            Button("复制链接", systemImage: "doc.on.doc") { UIPasteboard.general.string = url.absoluteString }
                            ShareLink(item: url) { Label("分享", systemImage: "square.and.arrow.up") }
                        }
                    }
                }
                .paperCard()
                .padding(Ink.Space.page)
            }
            .background(Ink.paper.ignoresSafeArea())
            .navigationTitle("\(urls.count) 个" + L.t("chat.source"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L.t("actions.done")) { dismiss() } } }
        }
    }

    /// What comes after the site, readable: 「/question/12345」 → 「question/12345」.
    static func path(_ url: URL) -> String {
        let rest = url.path().removingPercentEncoding ?? url.path()
        let trimmed = rest.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.isEmpty ? url.absoluteString : trimmed
    }
}


/// 选择文字: the reply as plain selectable text, to pick any words from it and copy them.
private struct PickWords: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Selectable(text: text)
                .padding(.horizontal, Ink.Space.page)
                .background(Ink.paper.ignoresSafeArea())
                .navigationTitle("选择文字")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { Button(L.t("actions.done")) { dismiss() } }
                }
        }
        .presentationDetents([.medium, .large])
    }
}

/// A read-only text view you can select in: drag the handles, then 拷贝.
private struct Selectable: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 16, left: 0, bottom: 32, right: 0)
        view.adjustsFontForContentSizeCategory = true
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 6
        view.attributedText = NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: CGFloat(Pref.size)),
            .foregroundColor: UIColor(Ink.ink),
            .paragraphStyle: style,
        ])
    }
}


/// 问答目录: the conversation as a list of what you asked and how each answer began; search it, tap to go there.
/// After Kelivo's mini map (only the idea).
struct OutlineSheet: View {
    struct Pair: Identifiable {
        let id: String
        let question: String
        let answer: String?
        let at: Double?
    }

    let pairs: [Pair]
    let go: (String) -> Void
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private var shown: [Pair] {
        let wanted = query.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return pairs }
        return pairs.filter { $0.question.localizedCaseInsensitiveContains(wanted) || ($0.answer?.localizedCaseInsensitiveContains(wanted) ?? false) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, pair in
                    Button {
                        Haptics.light()
                        go(pair.id)
                    } label: {
                        HStack(alignment: .top, spacing: Ink.Space.m) {
                            Text("\(index + 1)")
                                .font(Ink.footnote.monospacedDigit())
                                .foregroundStyle(Ink.inkFaint)
                                .frame(width: 24, alignment: .trailing)
                            VStack(alignment: .leading, spacing: Ink.Space.xs) {
                                Text(pair.question)
                                    .font(.system(size: Ink.Size.sub, weight: .medium))
                                    .foregroundStyle(Ink.ink)
                                    .lineLimit(2)
                                if let answer = pair.answer, !answer.isEmpty {
                                    Text(answer)
                                        .font(.system(size: Ink.Size.small))
                                        .foregroundStyle(Ink.inkSoft)
                                        .lineLimit(2)
                                }
                            }
                        }
                        .padding(.vertical, Ink.Space.xs)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Ink.paperRaised)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Ink.paper.ignoresSafeArea())
            .overlay {
                if shown.isEmpty {
                    Text(pairs.isEmpty ? "还没有问答" : "没找到")
                        .font(Ink.footnote)
                        .foregroundStyle(Ink.inkFaint)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "找问过的话")
            .navigationTitle(L.t("chat.outline"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button(L.t("actions.done")) { dismiss() } }
            }
        }
    }
}


/// What 健康 said, as a small card: a row per day, each number with its name under it.
struct HealthCard: View {
    let text: String
    let format: String?

    private struct Day: Identifiable {
        let id: Int
        let date: String
        let values: [(name: String, value: String)]
    }

    private var days: [Day] {
        HealthCardRows.newest(text, format: format).enumerated().compactMap { index, row in
            let parts = row.split(separator: "：", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            let values = parts[1].split(separator: "；").compactMap { item -> (String, String)? in
                let piece = item.trimmingCharacters(in: .whitespaces)
                guard let space = piece.firstIndex(of: " ") else { return nil }
                return (String(piece[..<space]), String(piece[piece.index(after: space)...]))
            }
            return Day(id: index, date: parts[0], values: values)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Ink.Space.m) {
            Label("健康", systemImage: "heart.text.square")
                .font(.system(size: Ink.Size.small, weight: .semibold))
                .foregroundStyle(Ink.Tile.yan)
            ForEach(days) { day in
                VStack(alignment: .leading, spacing: Ink.Space.xs) {
                    Text(day.date).font(.system(size: Ink.Size.micro)).foregroundStyle(Ink.inkFaint)
                    if day.values.isEmpty {
                        Text("没有记录").font(Ink.footnote).foregroundStyle(Ink.inkSoft)
                    } else {
                        HStack(alignment: .top, spacing: Ink.Space.l) {
                            ForEach(Array(day.values.enumerated()), id: \.offset) { _, item in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.value).font(Ink.mono(Ink.Size.sub, weight: .medium)).foregroundStyle(Ink.ink).lineLimit(1).minimumScaleFactor(0.7)
                                    Text(item.name).font(.system(size: Ink.Size.micro)).foregroundStyle(Ink.inkSoft)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(Ink.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperCard()
        .accessibilityElement(children: .combine)
    }
}


/// 回望: what the steps changed in the companion's mind, in the 心绪 colour, one line, opened by a tap.
struct LookbackLine: View {
    let text: String
    @State private var open = false

    var body: some View {
        Button {
            Haptics.tick(0.4)
            withAnimation(Ink.Motion.settle) { open.toggle() }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Ink.Space.s) {
                Image(systemName: "arrow.uturn.backward").font(.system(size: Ink.Size.micro, weight: .semibold))
                Text("回望 · " + text)
                    .font(Ink.footnote)
                    .lineLimit(open ? nil : 1)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Ink.accent.opacity(0.85))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("回望：" + text)
    }
}


private struct ChatSection<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View { content() }
}

@MainActor @Observable
private final class ChatDraft {
    var text = "" {
        didSet {
            guard oldValue != text, key != nil else { return }
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
    @ObservationIgnored private var save: Task<Void, Never>?

    func load(_ chat: String) {
        guard key == nil else { return }
        text = UserDefaults.standard.string(forKey: "draft." + chat) ?? ""
        key = "draft." + chat
    }

    func flush() {
        save?.cancel()
        save = nil
        guard let key else { return }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(text, forKey: key)
        }
    }
}
