import AVFoundation
import AgentKit
import CoreLocation
import Craft
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import VisionKit

/// 絮语: a conversation with one companion, set as a page.
struct ChatPage: View {
    @ObservedObject var team: TeamModel
    @StateObject private var chat: ChatModel
    @StateObject private var dictation = Dictation()
    var back: () -> Void

    @State private var draft = ""
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
    /// The conversation is moving under the reader's finger or settling after it.
    @State private var scrolling = false
    /// How full the next request will be; worked out when the page opens and after each turn, not on every word.
    @State private var context: TeamModel.ContextEstimate?
    @State private var usageOpen = false
    /// A turn has just finished well: the whale flips.
    @State private var cheering = false
    /// Nothing has happened for a few minutes: the whale dozes.
    @State private var dozing = false
    @State private var stirs = 0
    /// How many of the newest lines are drawn; 「更早的」 adds more.
    @State private var shownCount = 60
    /// What happened in the other conversations while the user was away from this one.
    @State private var away: [Happening] = []
    @State private var farFromEnd = false
    @FocusState private var typing: Bool
    @State private var voice = AVSpeechSynthesizer()

    init(team: TeamModel, bot: BotInfo, back: @escaping () -> Void) {
        self.team = team
        self.back = back
        _chat = StateObject(wrappedValue: ChatModel(bot: bot, team: team))
    }

    init(team: TeamModel, room: RoomInfo, back: @escaping () -> Void) {
        self.team = team
        self.back = back
        _chat = StateObject(wrappedValue: ChatModel(room: room, team: team))
    }

    private var isRoom: Bool { chat.roomId != nil }

    private var bot: BotInfo { isRoom ? chat.bot : (team.bots.first { $0.id == chat.bot.id } ?? chat.bot) }
    private var doing: String? { team.doing[chat.key] }
    private var working: Bool { doing != nil || !chat.streaming.isEmpty }
    private var waiting: Approval? { team.approvals.first { $0.chat == chat.key } }

    private var pose: WhalePose {
        if waiting != nil { return .waiting }
        if !chat.streaming.isEmpty || doing == "正在回复" { return .writing }
        if working || typing || dictation.listening { return .thinking }
        if cheering { return .cheering }
        if dozing { return .sleeping }
        return .idle
    }

    /// 「更早的」: draws forty more of the older lines, keeping the line you were looking at in place.
    private var earlier: some View {
        Button {
            Haptics.light()
            let anchor = chat.lines.suffix(shownCount).first?.id
            shownCount += 40
            if let anchor {
                Task { @MainActor in
                    await Task.yield()
                    scroller?.scrollTo(anchor, anchor: .top)
                }
            }
        } label: {
            Label("更早的 \(chat.lines.count - shownCount) 条", systemImage: "arrow.up")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Ink.inkSoft)
                .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(TapStyle())
    }

    /// A failure already explained in the conversation (the card with 再试一次) is not repeated in red under it.
    private func saidInNote(_ error: String) -> Bool {
        guard let last = chat.lines.last, last.kind == .note else { return false }
        return error.split(separator: "\n").first.map { last.text.contains($0) } ?? false
    }

    /// Something happened: the whale wakes, and the doze clock starts over.
    private func stir() {
        if dozing { dozing = false }
        stirs += 1
    }

    /// Whether the line under the conversation says what is going on: whenever the companion works and nothing else shows it.
    private var showsLive: Bool {
        guard doing != nil || waiting != nil else { return false }
        if let last = chat.lines.last, last.kind == .steps, last.live { return false }
        return chat.streaming.isEmpty || waiting != nil
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
        if waiting != nil { return "候印" }
        guard let doing else { return "闲坐" }
        switch doing {
        case "正在回复": return "落笔"
        case "正在想", "等你批准": return "沉吟"
        default: return doing
        }
    }

    /// The lines of the conversation, what is arriving, and what waits to be sent.
    private var conversationContent: some View {
        VStack(spacing: 0) {
            // A plain stack, not a lazy one: every line is measured, so "the bottom" is always exactly where it is.
            // A lazy stack guesses the height of lines it has not drawn, and scrolling to the end could stop short.
            // To keep that cheap, only the newest lines are drawn; older ones come in on request.
            VStack(alignment: .leading, spacing: Ink.Space.xl) {
                if chat.lines.isEmpty && chat.streaming.isEmpty { empty }
                if chat.lines.count > shownCount { earlier }
                ForEach(chat.lines.suffix(shownCount)) { line in
                    row(line)
                        .id(line.id)
                        .transition(.opacity.combined(with: .offset(y: 12)))
                }
                if !chat.streaming.isEmpty {
                    ProseView(text: chat.streaming, streaming: true)
                        .id("streaming")
                }
                if let words = liveWords, showsLive {
                    VStack(alignment: .leading, spacing: Ink.Space.xs) {
                        LiveStatus(words: words, icon: liveIcon, since: workingSince ?? Date(), waiting: waiting != nil)
                        if let doing = team.doing[chat.key], doing.hasPrefix("斗室：") || doing.hasPrefix("远山 · ") { ToolTailView() }
                    }
                    .id("live")
                    .transition(.opacity.combined(with: .offset(y: 8)))
                }
                if let error = chat.error, !saidInNote(error) {
                    Text(error)
                        .font(Ink.secondary)
                        .foregroundStyle(Ink.stop)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                ForEach(team.queued[chat.key] ?? []) { item in
                    queuedRow(item)
                        .transition(.opacity.combined(with: .offset(y: 8)))
                }
            }
            // The foot of the page. Scrolling to it lands exactly; scrolling to the edge of a lazy stack can stop short.
            Color.clear.frame(height: 1).id(Self.end)
        }
        .padding(.horizontal, Ink.Space.page)
        .padding(.top, Ink.Space.m)
        .padding(.bottom, Ink.Space.xxl)
    }

    /// The conversation itself: the lines, what is arriving, and the header it scrolls under.
    /// Kept apart from `body` so the compiler checks each piece on its own.
    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                conversationContent
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            // Whenever something new pushes the bottom out of sight while the page follows, go back down at once.
            // Nothing moves while the reader is up reading older lines.
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.visibleRect.maxY > 2
            } action: { _, behind in
                if behind, following { toEnd() }
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.visibleRect.maxY > 320
            } action: { _, far in
                withAnimation(Ink.Motion.settle) { farFromEnd = far }
            }
            .onScrollPhaseChange { old, phase, context in
                let moving = phase != .idle
                if moving != scrolling {
                    scrolling = moving
                    Hitches.shared.doing(moving ? "滚动絮语" : nil, as: "scroll")
                }
                // Only the reader's own scrolling decides whether the page keeps to the newest line; arriving text never does.
                if phase == .interacting { following = false }
                if phase == .idle, old != .idle {
                    following = context.geometry.contentSize.height - context.geometry.visibleRect.maxY < 80
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
            .onChange(of: chat.lines.last?.id) { followToEnd() }
            .onChange(of: chat.lines.count) { followToEnd() }
            .onChange(of: showsLive) { followToEnd() }
            .onChange(of: chat.error) { followToEnd() }
            .onChange(of: chat.streaming.count / 80) { followToEnd(settle: false) }
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
            .background(Ink.mine.opacity(0.55), in: .rect(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Ink.rule, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            HStack(spacing: Ink.Space.m) {
                Text(working ? "排队中，这轮做完就发" : "还没发出").font(Ink.footnote).foregroundStyle(Ink.inkFaint)
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
            .font(.system(size: 13))
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
        .safeAreaInset(edge: .bottom) { composerBar }
        .overlay {
            GeometryReader { proxy in
                Mascot(pose: pose, raised: waiting != nil, bounds: proxy.size)
            }
        }
        .simultaneousGesture(
            // A swipe in from the left edge goes back, as it does everywhere else on iOS.
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    if value.startLocation.x < 28, value.translation.width > 80, abs(value.translation.height) < 60 { leave() }
                }
        )
        .onAppear { chat.open() }
        .hitchPage(isRoom ? "雅集" : "絮语")
        .onDisappear {
            chat.close()
            team.markSeen(chat.key)
            if dictation.listening { dictation.stop() }
        }
        .sheet(item: $noting) { note in
            NoteSheet(text: note.text, from: isRoom ? "雅集 · \(bot.name)" : bot.name)
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
        .sheet(isPresented: $cardOpen) { BotEditor(team: team, bot: bot) }
        .fullScreenCover(isPresented: $tuningOpen) { SettingsView(team: team) {} }
        .sheet(isPresented: $careOpen) { CarePage(team: team) }
        .sheet(isPresented: $deskPicking) {
            DeskPicker { picked in
                deskPicking = false
                if !picked.isEmpty {
                    withAnimation(Ink.Motion.settle) { files += picked.filter { !files.contains($0) } }
                    say("带上了书案里的 \(picked.count) 个文件。")
                }
            }
        }
        .fullScreenCover(isPresented: $scanning) {
            ScannerView { pages in
                scanning = false
                guard !pages.isEmpty else { return }
                say("正在识别扫描里的文字…")
                Task {
                    if let kept = await Scan.keep(pages) {
                        withAnimation(Ink.Motion.settle) { files.append(kept.text) }
                        say("扫了 \(pages.count) 页，认出 \(kept.count) 个字，图和文字都放进了书案。")
                    }
                }
            }
            .ignoresSafeArea()
        }
        .alert("请旅伴读一个网页", isPresented: $linkAsking) {
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
            Text("旅伴会去读，读不出来时会用远游打开。")
        }
        .sheet(isPresented: $abilities) {
            AbilitiesSheet(team: team, key: chat.key, name: bot.name)
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $reading) { file in
            NavigationStack { StudyFile(url: file.url) }
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

    private struct Viewing: Identifiable { let id: String }
    private struct Noting: Identifiable { let id: String; let text: String }
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

    @AppStorage("mascot.shown") private var mascotShown = true

    private func leave() {
        typing = false
        if dictation.listening { dictation.stop() }
        Haptics.light()
        back()
    }

    // MARK: Top bar

    private var header: some View {
        HStack(spacing: Ink.Space.s) {
            Button(action: leave) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Ink.ink)
                    .frame(width: Ink.Bar.height, height: Ink.Bar.height)
                    .glassFace(in: Circle())
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("回到案头")
            HStack(spacing: Ink.Space.s) {
                Whale(size: 30, pose: pose)
                VStack(alignment: .leading, spacing: 0) {
                    Text(bot.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.ink)
                    HStack(spacing: 4) {
                        Circle().fill(working ? Ink.accent : Ink.ok).frame(width: 6, height: 6)
                        Text(headerLine)
                            .font(Ink.footnote)
                            .foregroundStyle(Ink.inkSoft)
                            .lineLimit(1)
                            .contentTransition(.opacity)
                    }
                    .animation(.easeInOut(duration: 0.5), value: headerLine)
                }
            }
            .padding(.leading, -Ink.Space.xs)
            .glassChip()
            .contentShape(.capsule)
            .onTapGesture {
                guard !isRoom else { return }
                Haptics.light()
                typing = false
                cardOpen = true
            }
            .contextMenu {
                if !isRoom { Button("看名帖", systemImage: "person.text.rectangle") { cardOpen = true } }
                Button(mascotShown ? "收起浮着的鲸鱼" : "放出浮着的鲸鱼", systemImage: mascotShown ? "eye.slash" : "eye") {
                    withAnimation(Ink.Motion.settle) { mascotShown.toggle() }
                }
            }
            .accessibilityHint(isRoom ? "" : "点一下看名帖")
            Spacer(minLength: 0)
            RoamButton(browser: team.browser) { open in
                typing = false
                roaming = open
            }
            Button {
                Haptics.light()
                typing = false
                leafing = true
            } label: {
                Image(systemName: "book.pages")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Ink.ink)
                    .frame(width: Ink.Bar.height, height: Ink.Bar.height)
                    .glassFace(in: Circle())
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("絮语页")
        }
        .padding(.horizontal, Ink.Bar.edge)
        .padding(.top, Ink.Space.s)
    }

    // MARK: Composer chips

    private var options: TeamModel.ChatOptions { team.options(chat.key) }

    /// A chip in the row under the text field. Lit when what it stands for is on.
    private func chip(_ icon: String, _ name: String?, lit: Bool = false) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 13, weight: .medium))
            if let name { Text(name).font(.system(size: 13, weight: .medium)).lineLimit(1) }
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

    private var webChip: some View {
        let on = options.web
        return Button {
            Haptics.tick(0.6)
            team.setWeb(!on, in: chat.key)
            say(on ? "联网关了：这段絮语里，旅伴不会搜索、读网页，也不会用远游。" : "联网开了：旅伴需要时会去搜索、读网页，或用远游打开网站。")
        } label: {
            chip(on ? "globe" : "network.slash", "联网", lit: on)
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(on ? "联网：开着，点一下关掉" : "联网：关着，点一下打开")
    }

    private var abilitiesChip: some View {
        let off = options.off.count
        return Button {
            Haptics.light()
            typing = false
            abilities = true
        } label: {
            chip("wand.and.stars", off == 0 ? "本事" : "本事 · 关了 \(off)", lit: false)
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel("这段絮语里旅伴能用的本事")
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
            Section("这段絮语用哪个模型") {
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
                say("这段絮语改用 \(found?.model ?? ref)（\(sight)），\(bot.name)别处的絮语不变。")
            }
        } label: {
            chip("sparkle", shortName(current) + (level == .auto ? "" : " · \(level.title)"), lit: own != nil || level != .auto)
        }
        .accessibilityLabel("模型：\(shortName(current))")
    }

    /// How hard the model thinks in this conversation: on its own in a gathering, inside the model menu otherwise.
    private var thinkChip: some View {
        let level = options.thinking ?? .auto
        return Menu {
            thinkingChoices
        } label: {
            chip(level == .auto ? "brain" : level.symbol, level == .auto ? "思考" : level.title, lit: level != .auto)
        }
        .accessibilityLabel("思考强度：\(level.title)")
    }

    @ViewBuilder
    private var thinkingChoices: some View {
        let level = options.thinking ?? .auto
        let now = isRoom ? nil : team.current(chat.key, bot: bot)
        Section("这段絮语想多深") {
            ForEach(Thinking.allCases, id: \.self) { option in
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
            Section("这段絮语在哪里干活") {
                placeButton(.desk, line: "手机里的文件夹，读写文件、算数")
                placeButton(.den, line: "手机里的 Linux，能跑命令、装软件")
                ForEach(Hills.shared.hosts) { host in
                    placeButton(.hill(host.id), line: "\(host.user)@\(host.address)")
                }
            }
            if Hills.shared.hosts.isEmpty {
                Section { Text("在设置 › 远山 添一台主机，这里就能选它。") }
            }
        } label: {
            chip(current.symbol, current == .desk ? "书案" : current.title, lit: current != .desk)
        }
        .accessibilityLabel("工作地点：\(current.title)")
    }

    private func placeButton(_ place: WorkPlace, line: String) -> some View {
        let current = team.place(of: chat.key)
        return Button {
            Haptics.tick(0.5)
            team.setPlace(place, in: chat.key)
            switch place {
            case .desk: say("回到书案：文件放在手机的书案里，不跑命令。")
            case .den: say("在斗室干活：旅伴会在手机里的 Linux 跑命令，文件放在 /root/desk。")
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

    /// Whatever was copied last: a picture joins the photos, a link or short words join the draft, long words become a file.
    private func pasteClipboard() {
        let board = UIPasteboard.general
        if board.hasImages, let image = board.image, let data = image.jpegData(compressionQuality: 0.9), let small = Self.shrink(data) {
            guard photos.count < 4 else { return say("最多带四张图。") }
            withAnimation(Ink.Motion.settle) { photos.append(small) }
            say("带上了剪贴板里的图片。")
        } else if board.hasURLs, let url = board.url {
            draft += (draft.isEmpty ? "" : "\n") + url.absoluteString
            typing = true
        } else if let text = board.string, !text.isEmpty {
            if text.count > 400 {
                let inbox = Workspace.root.appendingPathComponent("收件", isDirectory: true)
                try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyyMMdd-HHmmss"
                let file = inbox.appendingPathComponent("剪贴板 \(formatter.string(from: Date())).txt")
                try? Data(text.utf8).write(to: file)
                withAnimation(Ink.Motion.settle) { files.append(Workspace.relative(file)) }
                say("剪贴板里的字有点长（\(text.count) 字），存成文件带上了。")
            } else {
                draft += (draft.isEmpty ? "" : "\n") + text
                typing = true
            }
        } else {
            say("剪贴板是空的。")
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
        say("粘进来的字太长（\(pasted.count) 字），存成文件带上了：书案/\(Workspace.relative(file))")
    }

    /// Where the user is, in words, added to the draft.
    private func attachPlace() {
        say("正在定位…")
        Task {
            do {
                let location = try await Spot.shared.locate()
                var words = String(format: "%.5f, %.5f", location.coordinate.latitude, location.coordinate.longitude)
                if let place = try? await CLGeocoder().reverseGeocodeLocation(location).first {
                    let parts = [place.administrativeArea, place.locality, place.subLocality, place.thoroughfare, place.name].compactMap { $0 }
                    var seen: [String] = []
                    for part in parts where !seen.contains(part) { seen.append(part) }
                    words = seen.joined(separator: " ") + "（\(words)）"
                }
                draft += (draft.isEmpty ? "" : "\n") + "［我现在在：\(words)］"
                typing = true
                say("位置带上了。")
            } catch {
                say("没定到位：\(error.localizedDescription)")
            }
        }
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
            Whale(size: 96, pose: pose)
            Text(isRoom ? "雅集里的旅伴会轮流说话" : "同\(bot.name)说点什么吧")
                .font(Ink.reading)
                .foregroundStyle(Ink.inkSoft)
            VStack(spacing: Ink.Space.s) {
                ForEach(starters, id: \.0) { item in
                    Button {
                        Haptics.light()
                        draft = item.1
                        typing = true
                    } label: {
                        HStack(spacing: Ink.Space.m) {
                            Image(systemName: item.2).font(.system(size: 15)).foregroundStyle(Ink.accent).frame(width: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.0).font(.system(size: 15, weight: .medium)).foregroundStyle(Ink.ink)
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
            Text("点一张填进输入框，改一改再发。")
                .font(Ink.footnote)
                .foregroundStyle(Ink.inkFaint)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 72)
    }

    /// Ways to begin, only for abilities this conversation has.
    private var starters: [(String, String, String)] {
        let off = Set(options.off)
        var out: [(String, String, String)] = []
        func on(_ grant: Grant) -> Bool { grant.policy != .off && !off.contains(grant.rawValue) }
        if on(.calendar) { out.append(("看看日程", "我今天和明天有什么安排？", "calendar")) }
        if on(.web) { out.append(("查点东西", "帮我查一下最近重庆有什么值得去的展览", "magnifyingglass")) }
        if on(.location) { out.append(("看看附近", "我现在在哪？附近有什么好吃的", "location")) }
        if on(.den) { out.append(("在斗室算一算", "在斗室里用 Python 算一下：每月存 2000，年化 3%，十年后有多少", "terminal")) }
        if on(.desk) { out.append(("记到书案", "帮我在书案里建一份本周待办清单", "books.vertical")) }
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
                                    .clipShape(.rect(cornerRadius: Ink.Radius.small))
                            }
                            .buttonStyle(PressStyle())
                        }
                    }
                }
                if !line.text.isEmpty {
                    Text(line.text)
                        .font(Ink.label)
                        .foregroundStyle(Ink.ink)
                        .lineSpacing(4)
                        .padding(.horizontal, Ink.Space.l)
                        .padding(.vertical, Ink.Space.m)
                        .background(editing == line.id ? Ink.accentWash : Ink.mine, in: .rect(cornerRadius: 18))
                        .contentShape(.contextMenuPreview, .rect(cornerRadius: 18))
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
                if isRoom, let speaker = team.bots.first(where: { $0.id == line.speaker }) {
                    HStack(spacing: Ink.Space.s) {
                        Whale(size: 22, wash: Ink.wash(for: speaker), still: true)
                        Text(speaker.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.inkSoft)
                    }
                }
                if let fresh = chat.fresh, fresh.id == line.id, let shown = fresh.shown {
                    ProseView(text: String(line.text.prefix(shown)), streaming: true)
                } else {
                    ProseView(text: line.text)
                }
                if line.id == chat.lines.last(where: { $0.kind == .bot })?.id, !working {
                    footer(line)
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
            })
        case .note:
            if let next = line.next {
                trouble(line, next: next)
            } else {
                Text(line.text)
                    .font(Ink.footnote)
                    .foregroundStyle(Ink.inkFaint)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    /// A failure, said plainly, with the one thing to do about it. Only the latest one keeps its button.
    private func trouble(_ line: ChatLine, next: Explain.Next) -> some View {
        let parts = line.text.split(separator: "\n", maxSplits: 1).map(String.init)
        let latest = chat.lines.last(where: { $0.kind == .note })?.id == line.id && chat.lines.last?.id == line.id
        let advice = Explain.Advice(title: parts.first ?? line.text, detail: parts.count > 1 ? parts[1] : "", next: next)
        return VStack(alignment: .leading, spacing: Ink.Space.s) {
            // A pause is not a failure: said in ink, not in red.
            Label(advice.title, systemImage: next == .resume ? "pause.circle" : "exclamationmark.triangle")
                .font(.system(size: 15, weight: .semibold))
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
                        .font(.system(size: 14, weight: .semibold))
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
        .background(next == .resume ? Ink.paperRaised.opacity(0.7) : Ink.stop.opacity(0.07), in: .rect(cornerRadius: Ink.Radius.card))
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
            say("正在把前文压成提要…")
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

    private func footer(_ line: ChatLine) -> some View {
        HStack(spacing: Ink.Space.s) {
            icon("doc.on.doc", "复制") {
                UIPasteboard.general.string = line.text
                Haptics.tick(0.5)
                say("复制好了。")
            }
            icon("arrow.clockwise", "重来一次") {
                Haptics.light()
                redo()
            }
            icon(voice.isSpeaking ? "speaker.slash" : "speaker.wave.2", "朗读") { speak(line.text) }
            icon("text.quote", "引用追问") {
                Haptics.light()
                quoting = Noting(id: line.id, text: line.text)
            }
            icon("scroll", "做成笺") {
                Haptics.light()
                noting = Noting(id: line.id, text: line.text)
            }
            Spacer(minLength: Ink.Space.s)
            if Pref.stats {
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
        if let seconds = line.seconds { parts.append(seconds >= 60 ? "\(seconds / 60)分\(seconds % 60)秒" : "\(seconds)秒") }
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
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Ink.inkSoft)
                .frame(width: 32, height: 32)
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
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.inkFaint).frame(width: 28, height: 28)
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
                        Text("\(team.chatName(item.chat))：\(Self.awayWords(item.kind))").font(.system(size: 14)).foregroundStyle(Ink.ink).lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Ink.inkFaint)
                    }
                    .frame(minHeight: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
            }
        }
        .padding(.horizontal, Ink.Space.m)
        .padding(.vertical, Ink.Space.s)
        .glassBacking(in: RoundedRectangle(cornerRadius: Ink.Radius.card))
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

    private var composer: some View {
        VStack(spacing: Ink.Space.s) {
            if !away.isEmpty, waiting == nil { awayCard }
            RoamSlip(browser: team.browser) {
                typing = false
                roaming = true
            }
            if let waiting {
                Button {
                    Haptics.grab()
                    typing = false
                    approving = waiting
                } label: {
                    HStack(spacing: Ink.Space.m) {
                        Image(systemName: "seal").foregroundStyle(Ink.warn)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("候印 · \(waiting.tool ?? "要你同意")").font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.ink)
                            if let reason = waiting.reason {
                                Text(reason).font(Ink.footnote).foregroundStyle(Ink.inkSoft).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        Text("去落印").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.accent)
                    }
                    .padding(Ink.Space.m)
                    .paperCard()
                }
                .buttonStyle(PressStyle())
                .transition(.move(edge: .bottom).combined(with: .opacity))
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
                            Image(systemName: "xmark.circle.fill").font(.system(size: 15)).foregroundStyle(Ink.inkFaint)
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
                        Image(systemName: "pencil").font(.system(size: 12, weight: .semibold))
                        Text("改了重发：之后的对话会重新来过").font(Ink.footnote)
                        Spacer()
                        Button("算了") {
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
                                            .clipShape(.rect(cornerRadius: Ink.Radius.small))
                                    }
                                    Button {
                                        withAnimation(Ink.Motion.settle) { _ = photos.remove(at: index) }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 16))
                                            .foregroundStyle(Ink.paper, Ink.ink.opacity(0.6))
                                    }
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
                                    Image(systemName: "doc").font(.system(size: 12))
                                    Text((path as NSString).lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    Button {
                                        withAnimation(Ink.Motion.settle) { files.removeAll { $0 == path } }
                                    } label: {
                                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                                    }
                                    .buttonStyle(TapStyle(grow: 8))
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
                // One row at rest, like any messaging app: add, write, speak or send.
                HStack(alignment: .bottom, spacing: Ink.Space.s) {
                    Menu {
                        ForEach([AttachKind.photos, .camera, .files]) { kind in
                            Button(kind.title, systemImage: kind.symbol) { bring(kind) }
                        }
                        Section {
                            Button(AttachKind.desk.title, systemImage: AttachKind.desk.symbol) { bring(.desk) }
                        }
                    } label: {
                        chip("plus", nil, lit: !photos.isEmpty || !files.isEmpty)
                    }
                    .simultaneousGesture(TapGesture().onEnded { typing = false })
                    .accessibilityLabel("加照片或文件")
                    .photosPicker(isPresented: $pickerShown, selection: $picks, maxSelectionCount: 4, matching: .images)
                    .fileImporter(isPresented: $importingFile, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                        if case .success(let urls) = result { withAnimation(Ink.Motion.settle) { receive(urls) } }
                    }
                    TextField(dictation.listening ? "正在听，说完点右边" : (working ? "接着写，这轮做完就发…" : "同\(bot.name)说点什么…"), text: $draft, axis: .vertical)
                        .font(Ink.label)
                        .foregroundStyle(Ink.ink)
                        .lineLimit(1...6)
                        .focused($typing)
                        .onChange(of: draft) { old, new in keepLongPaste(old, new) }
                        .padding(.vertical, 6)
                        .frame(minHeight: 34)
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
                // While writing: what this message goes out with. Web, where the work happens, abilities, model.
                if composing {
                    ScrollView(.horizontal) {
                        HStack(spacing: Ink.Space.s) {
                            abilitiesChip
                            if team.place(of: chat.key) != .desk { placeChip }
                            if isRoom { thinkChip } else { modelChip }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .animation(Ink.Motion.settle, value: composing)
            .padding(.horizontal, Ink.Space.s)
            .padding(.vertical, Ink.Space.s)
            .glassBacking(in: RoundedRectangle(cornerRadius: Ink.Radius.sheet))
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
        .animation(Ink.Motion.unfold, value: waiting?.id)
        .overlay(alignment: .top) {
            // Floats above the composer instead of standing in it: coming and going, it must not change the page's height.
            if farFromEnd && !following {
                Button {
                    Haptics.light()
                    following = true
                    toEnd(animated: true)
                } label: {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Ink.ink)
                        .frame(width: 36, height: 36)
                        .glassFace(in: Circle())
                }
                .buttonStyle(PressStyle())
                .offset(y: -46)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
                .accessibilityLabel("回到最新")
            }
        }
    }

    private static let end = "foot-of-page"

    /// Back to the newest line, if the page is following: once as soon as what arrived is laid out,
    /// and once more after the new row has settled in, since its height is only right by then.
    private func followToEnd(settle: Bool = true) {
        guard following else { return }
        Task { @MainActor in
            await Task.yield()
            if following { toEnd() }
            guard settle else { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
            if following { toEnd(animated: true) }
        }
    }

    private func toEnd(animated: Bool = false) {
        guard let scroller else { return }
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
    @State private var attachPicked: AttachKind?
    @State private var deskPicking = false
    @State private var scanning = false
    @State private var linkAsking = false
    @State private var linkDraft = ""
    /// When the companion started on the current turn, for the seconds under the conversation.
    @State private var workingSince: Date?
    @State private var cardOpen = false
    @State private var tuningOpen = false
    @State private var careOpen = false

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
                Haptics.lock()
                chat.stop()
            case 2:
                Haptics.grab()
                if let editing {
                    redo(from: editing, text: draft)
                    self.editing = nil
                } else if let quote {
                    let quoted = quote.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
                    chat.send(quoted + "\n\n" + draft + fileNote, photos: photos)
                    self.quote = nil
                } else {
                    let words = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    chat.send((words.isEmpty && !files.isEmpty ? "看看这些文件。" : draft) + fileNote, photos: photos)
                }
                draft = ""
                photos = []
                files = []
                following = true
                followToEnd()
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
        .animation(Ink.Motion.press, value: mode)
        .accessibilityLabel(["说完了", "让它停下", "发送", "说话"][mode])
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

    /// What the steps left behind worth a card: a date set, a reminder, a file written, a command run.
    private struct Keepsake: Identifiable {
        enum Kind { case event, reminder, file, remoteFile, command }
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

    private var keepsakes: [Keepsake] {
        var out: [Keepsake] = []
        for (index, tool) in line.tools.enumerated() where !tool.hasSuffix("（没成功）") {
            let output = index < line.details.count ? line.details[index].output : ""
            let full = index < line.details.count ? line.details[index].full : nil
            if tool.hasPrefix("新建日程：") {
                out.append(Keepsake(id: index, kind: .event, title: String(tool.dropFirst(5)), detail: "已加进日历", url: URL(string: "calshow://")))
            } else if tool.hasPrefix("加提醒：") {
                out.append(Keepsake(id: index, kind: .reminder, title: String(tool.dropFirst(4)), detail: "已加进提醒事项", url: URL(string: "x-apple-reminderkit://")))
            } else if tool.hasPrefix("书案：写 ") || tool.hasPrefix("书案：改 ") {
                let path = String(tool.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if let file = Workspace.resolve(path), FileManager.default.fileExists(atPath: file.path) {
                    let change = Diff.counts(in: output).map { " · −\($0.removed) +\($0.added) 行" } ?? ""
                    if let kept = out.firstIndex(where: { $0.url == file }) {
                        out[kept] = Keepsake(id: out[kept].id, kind: .file, title: file.lastPathComponent, detail: "书案/" + Workspace.relative(file) + " · 改了几次，这是最后一次", url: file, diff: full ?? out[kept].diff)
                    } else {
                        out.append(Keepsake(id: index, kind: .file, title: file.lastPathComponent, detail: "书案/" + Workspace.relative(file) + change, url: file, diff: full))
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
                        Image(systemName: "checkmark.circle").font(.system(size: 14, weight: .medium)).foregroundStyle(Ink.ok)
                    }
                    Text(line.live ? (line.tools.last ?? "沉吟") : "行迹 · \(line.tools.count) 步" + (line.seconds.map { " · \($0) 秒" } ?? ""))
                        .font(Ink.secondary)
                        .foregroundStyle(Ink.inkSoft)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Ink.inkFaint)
                        .rotationEffect(.degrees(open ? -180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            if open {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(line.tools.enumerated()), id: \.offset) { index, tool in
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
        if !line.live {
            ForEach(keepsakes) { item in
                Button {
                    Haptics.light()
                    switch item.kind {
                    case .file, .remoteFile:
                        if let diff = item.diff, !diff.isEmpty {
                            diffing = DiffShow(title: item.title, place: item.detail, diff: diff, url: item.url)
                        } else if let url = item.url {
                            openFile(url)
                        }
                    case .event, .reminder: if let url = item.url { UIApplication.shared.open(url) }
                    case .command: break
                    }
                } label: {
                    HStack(alignment: .top, spacing: Ink.Space.m) {
                        Image(systemName: Self.keepsakeIcon(item.kind)).font(.system(size: 16)).foregroundStyle(Ink.accent).frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.kind == .command ? "# " + item.title : item.title)
                                .font(item.kind == .command ? .system(size: 13, weight: .medium, design: .monospaced) : .system(size: 14, weight: .medium))
                                .foregroundStyle(Ink.ink).lineLimit(2)
                            Text(item.detail)
                                .font(item.kind == .command ? .system(size: 11, design: .monospaced) : Ink.footnote)
                                .foregroundStyle(Ink.inkSoft).lineLimit(3)
                            if let diff = item.diff, !diff.isEmpty {
                                // The first few changed lines, so the card shows what changed at a glance.
                                DiffText(hunk: DiffText.glance(diff), limit: 5)
                                    .padding(.top, 4)
                                    .allowsHitTesting(false)
                            }
                        }
                        Spacer(minLength: 0)
                        if item.kind != .command, item.kind != .remoteFile || item.diff != nil {
                            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Ink.inkFaint)
                        }
                    }
                    .padding(Ink.Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .paperCard()
                }
                .buttonStyle(PressStyle())
                .padding(.top, Ink.Space.s)
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
                                Image(systemName: "safari").font(.system(size: 15)).foregroundStyle(Ink.accent)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(url.host() ?? url.absoluteString).font(.system(size: 13, weight: .medium)).foregroundStyle(Ink.ink).lineLimit(1)
                                    Text(url.path().isEmpty || url.path() == "/" ? "首页" : url.path()).font(.system(size: 11)).foregroundStyle(Ink.inkFaint).lineLimit(1)
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
                Image(systemName: Self.icon(for: name))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(failed ? Ink.stop : Ink.accent)
                    .frame(width: 24, height: 24)
                    .background(failed ? Ink.stop.opacity(0.12) : Ink.accentWash, in: .circle)
                if !last { Rectangle().fill(Ink.rule).frame(width: 1).frame(maxHeight: .infinity) }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Ink.Space.s) {
                    Text(Self.word(for: name)).font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.ink)
                    if let seconds = more?.seconds { Text("\(max(seconds, 0)) 秒").font(Ink.footnote.monospacedDigit()).foregroundStyle(Ink.inkFaint) }
                    Spacer(minLength: 0)
                    if more != nil {
                        Image(systemName: shown ? "chevron.up" : "ellipsis").font(.system(size: 11, weight: .semibold)).foregroundStyle(Ink.inkFaint)
                    }
                }
                if let detail { Text(detail).font(Ink.secondary).foregroundStyle(Ink.inkSoft).lineLimit(shown ? nil : 2) }
                if shown, let more {
                    VStack(alignment: .leading, spacing: Ink.Space.xs) {
                        if !more.input.isEmpty, more.input != "{}" {
                            Text("交给它的").font(Ink.footnote).foregroundStyle(Ink.inkFaint)
                            Text(Self.tidy(more.input)).font(.system(size: 12, design: .monospaced)).foregroundStyle(Ink.inkSoft).lineLimit(12)
                        }
                        if let name = more.photo, let data = Disk.photo(name), let image = UIImage(data: data) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 260)
                                .clipShape(.rect(cornerRadius: Ink.Radius.small))
                                .padding(.top, 2)
                        }
                        Text("它回来的").font(Ink.footnote).foregroundStyle(Ink.inkFaint).padding(.top, 2)
                        if let hunk = Diff.hunk(in: more.output) {
                            Text(more.output.components(separatedBy: "\n").first ?? "").font(.system(size: 12, design: .monospaced)).foregroundStyle(Ink.inkSoft)
                            DiffText(hunk: hunk)
                        } else {
                            Text(more.output.isEmpty ? "（空）" : String(more.output.prefix(1500))).font(.system(size: 12, design: .monospaced)).foregroundStyle(Ink.inkSoft).lineLimit(24)
                        }
                    }
                    .textSelection(.enabled)
                    .padding(Ink.Space.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Ink.mine.opacity(0.6), in: .rect(cornerRadius: Ink.Radius.small))
                    .padding(.top, Ink.Space.xs)
                    .transition(.opacity)
                }
            }
            .padding(.bottom, last ? 0 : Ink.Space.l)
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
        case "读网页": "远游"
        case "记住": "拾遗"
        case "忘掉": "删去拾遗"
        case "看日历", "看提醒事项": "翻看"
        case "新建日程", "加提醒": "落印 · \(label)"
        default: label.hasPrefix("约好") ? "来信" : label
        }
    }

    static func icon(for label: String) -> String {
        switch label {
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
        default: label.hasPrefix("约好") ? "envelope" : "sparkle"
        }
    }
}


/// The line under the conversation while the companion works: what it is doing, and for how long.
private struct LiveStatus: View {
    let words: String
    let icon: String
    let since: Date
    var waiting = false
    @State private var breathe = false

    var body: some View {
        HStack(alignment: .center, spacing: Ink.Space.m) {
            ZStack {
                Circle()
                    .fill(waiting ? Ink.warn.opacity(0.16) : Ink.accentWash)
                    .scaleEffect(breathe ? 1.18 : 0.92)
                    .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: breathe)
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(waiting ? Ink.warn : Ink.accent)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 2) {
                    Text(words)
                        .font(Ink.secondary)
                        .foregroundStyle(Ink.ink)
                        .lineLimit(2)
                        .contentTransition(.opacity)
                    if !waiting { Dots() }
                }
                TimelineView(.periodic(from: since, by: 1)) { context in
                    let seconds = max(0, Int(context.date.timeIntervalSince(since)))
                    Text(seconds < 2 ? "刚刚收到" : "已经 \(seconds) 秒")
                        .font(Ink.footnote.monospacedDigit())
                        .foregroundStyle(Ink.inkFaint)
                        .contentTransition(.numericText())
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Ink.Space.m)
        .padding(.vertical, Ink.Space.s)
        .background(Ink.paperRaised.opacity(0.7), in: .rect(cornerRadius: Ink.Radius.card))
        .animation(Ink.Motion.settle, value: words)
        .onAppear { breathe = true }
        .accessibilityElement(children: .combine)
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
