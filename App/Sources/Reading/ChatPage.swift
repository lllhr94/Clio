import AVFoundation
import PhotosUI
import SwiftUI

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
    @State private var position = ScrollPosition(edge: .bottom)
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
        return .idle
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

    var body: some View {
        ZStack(alignment: .top) {
            Ink.paper.ignoresSafeArea()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Ink.Space.xl) {
                    if chat.lines.isEmpty && chat.streaming.isEmpty { empty }
                    ForEach(chat.lines) { line in
                        row(line)
                            .transition(.opacity.combined(with: .offset(y: 12)))
                    }
                    if !chat.streaming.isEmpty {
                        ProseView(text: chat.streaming, streaming: true)
                            .id("streaming")
                    }
                    if let error = chat.error {
                        Text(error)
                            .font(Ink.secondary)
                            .foregroundStyle(Ink.stop)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .padding(.horizontal, Ink.Space.page)
                .padding(.top, 76)
                .padding(.bottom, Ink.Space.xxl)
                .animation(Ink.Motion.unfold, value: chat.lines.count)
            }
            .scrollPosition($position)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.visibleRect.maxY > 320
            } action: { _, far in
                withAnimation(Ink.Motion.settle) { farFromEnd = far }
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            // Text scrolling up fades under the header instead of running into it.
            LinearGradient(colors: [Ink.paper, Ink.paper.opacity(0.92), Ink.paper.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: 72)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
                .zIndex(1)
            header
                .zIndex(2)
        }
        .safeAreaInset(edge: .bottom) { composer }
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
        .onDisappear {
            chat.close()
            if dictation.listening { dictation.stop() }
        }
        .sheet(item: $noting) { note in
            NoteSheet(text: note.text, from: isRoom ? "雅集 · \(bot.name)" : bot.name)
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
    @State private var roaming = false

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
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Ink.ink)
                    .frame(width: 38, height: 38)
                    .glassEffect(.regular, in: .circle)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .padding(-4)
            .accessibilityLabel("回到案头")
            HStack(spacing: Ink.Space.s) {
                Whale(size: 26, pose: pose)
                    .onTapGesture {
                        // Brings the whale back after it was put away.
                        Haptics.tick(0.5)
                        withAnimation(Ink.Motion.settle) { mascotShown.toggle() }
                    }
                VStack(alignment: .leading, spacing: 0) {
                    Text(bot.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.ink)
                    HStack(spacing: 4) {
                        Circle().fill(working ? Ink.accent : Ink.ok).frame(width: 6, height: 6)
                        Text(status)
                            .font(Ink.footnote)
                            .foregroundStyle(Ink.inkSoft)
                            .lineLimit(1)
                            .contentTransition(.opacity)
                    }
                    .animation(Ink.Motion.settle, value: status)
                }
            }
            .padding(.leading, -Ink.Space.xs)
            .glassChip()
            Spacer(minLength: 0)
            RoamButton(browser: team.browser) { open in
                typing = false
                roaming = open
            }
            if !isRoom { modelMenu }
        }
        .padding(.horizontal, Ink.Space.l)
        .padding(.top, Ink.Space.s)
    }

    private var modelMenu: some View {
        Menu {
            ForEach(team.models) { item in
                Button {
                    Haptics.tick(0.5)
                    Task { try? await team.saveBot(id: bot.id, name: bot.name, role: bot.role ?? "", color: bot.color ?? "blue", model: item.ref) }
                } label: {
                    if (bot.model ?? team.settings.defaultModel) == item.ref {
                        Label("\(item.name ?? item.ref) · \(item.providerName ?? "")", systemImage: "checkmark")
                    } else {
                        Text("\(item.name ?? item.ref) · \(item.providerName ?? "")")
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "sparkle").font(.system(size: 12, weight: .semibold))
                Text(team.resolve(bot.model ?? team.settings.defaultModel)?.model ?? "选模型")
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(Ink.ink)
            .frame(maxWidth: 150)
            .glassChip()
        }
    }

    // MARK: Rows

    private var empty: some View {
        VStack(spacing: Ink.Space.l) {
            Whale(size: 96, pose: pose)
            Text("同\(bot.name)说点什么吧")
                .font(Ink.reading)
                .foregroundStyle(Ink.inkSoft)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
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
            Trace(line: line)
        case .note:
            Text(line.text)
                .font(Ink.footnote)
                .foregroundStyle(Ink.inkFaint)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func footer(_ line: ChatLine) -> some View {
        HStack(spacing: Ink.Space.xl) {
            icon("doc.on.doc", "复制") {
                UIPasteboard.general.string = line.text
                Haptics.tick(0.5)
            }
            icon("arrow.clockwise", "重来一次") {
                Haptics.light()
                chat.retry()
            }
            icon(voice.isSpeaking ? "speaker.slash" : "speaker.wave.2", "朗读") { speak(line.text) }
            icon("scroll", "做成笺") {
                Haptics.light()
                noting = Noting(id: line.id, text: line.text)
            }
            Spacer()
            Text(Self.numbers(line))
                .font(Ink.footnote.monospacedDigit())
                .foregroundStyle(Ink.inkFaint)
        }
    }

    /// 「23 秒 · 3.4 千字」: how long the turn took and how much was written.
    static func numbers(_ line: ChatLine) -> String {
        var parts: [String] = []
        if let seconds = line.seconds { parts.append(seconds >= 60 ? "\(seconds / 60) 分 \(seconds % 60) 秒" : "\(seconds) 秒") }
        if let tokens = line.tokens {
            parts.append(tokens >= 1000 ? String(format: "%.1f 千 tokens", Double(tokens) / 1000) : "\(tokens) tokens")
        } else {
            let count = line.text.count
            parts.append(count >= 1000 ? String(format: "%.1f 千字", Double(count) / 1000) : "\(count) 字")
        }
        return parts.joined(separator: " · ")
    }

    private func icon(_ name: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 14, weight: .medium))
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

    private var composer: some View {
        VStack(spacing: Ink.Space.s) {
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
            if farFromEnd {
                Button {
                    Haptics.light()
                    withAnimation(Ink.Motion.unfold) { position.scrollTo(edge: .bottom) }
                } label: {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Ink.ink)
                        .frame(width: 36, height: 36)
                        .glassEffect(.regular, in: .circle)
                }
                .buttonStyle(PressStyle())
                .transition(.scale(scale: 0.6).combined(with: .opacity))
                .accessibilityLabel("回到最新")
            }
            if let problem = dictation.problem {
                Text(problem).font(Ink.footnote).foregroundStyle(Ink.stop)
                    .onTapGesture { dictation.problem = nil }
            }
            VStack(alignment: .leading, spacing: Ink.Space.s) {
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
                TextField(dictation.listening ? "正在听，说完点右边" : "同\(bot.name)说点什么…", text: $draft, axis: .vertical)
                    .font(Ink.label)
                    .foregroundStyle(Ink.ink)
                    .lineLimit(1...6)
                    .focused($typing)
                    .padding(.top, Ink.Space.xs)
                HStack(spacing: Ink.Space.s) {
                    Menu {
                        Button("照片", systemImage: "photo.on.rectangle") { pickerShown = true }
                        Button("拍照", systemImage: "camera") { takingPhoto = true }
                    } label: {
                        chipLabel("plus", nil)
                    }
                    .photosPicker(isPresented: $pickerShown, selection: $picks, maxSelectionCount: 4, matching: .images)
                    chipLabel("globe", "联网")
                    Spacer()
                    action
                }
            }
            .padding(.horizontal, Ink.Space.l)
            .padding(.vertical, Ink.Space.m)
            .glassEffect(.regular, in: .rect(cornerRadius: Ink.Radius.sheet))
        }
        .padding(.horizontal, Ink.Space.m)
        .padding(.bottom, Ink.Space.s)
        .animation(Ink.Motion.unfold, value: waiting?.id)
    }

    @State private var pickerShown = false

    private func chipLabel(_ icon: String, _ name: String?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 13, weight: .medium))
            if let name { Text(name).font(.system(size: 13, weight: .medium)) }
        }
        .foregroundStyle(Ink.inkSoft)
        .padding(.horizontal, name == nil ? 0 : Ink.Space.m)
        .frame(minWidth: 32, minHeight: 32)
        .overlay(Capsule().strokeBorder(Ink.rule, lineWidth: 1))
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !photos.isEmpty
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
                    chat.resend(editing, text: draft)
                    self.editing = nil
                } else {
                    chat.send(draft, photos: photos)
                }
                draft = ""
                photos = []
                position.scrollTo(edge: .bottom)
            default:
                Haptics.grab()
                typing = false
                spokenBase = draft
                dictation.onText = { heard in draft = spokenBase + heard }
                Task { await dictation.start() }
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
    @State private var open = false

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
                        step(tool, last: index == line.tools.count - 1)
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
    }

    private func step(_ tool: String, last: Bool) -> some View {
        let parts = tool.split(separator: "：", maxSplits: 1).map(String.init)
        let name = parts.first ?? tool
        let detail = parts.count > 1 ? parts[1] : nil
        let failed = tool.hasSuffix("（没成功）")
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
                Text(Self.word(for: name)).font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.ink)
                if let detail { Text(detail).font(Ink.secondary).foregroundStyle(Ink.inkSoft).lineLimit(2) }
            }
            .padding(.bottom, last ? 0 : Ink.Space.l)
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
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
        case "记住", "忘掉": "bookmark"
        case "看日历", "新建日程": "calendar"
        case "看提醒事项", "加提醒": "checklist"
        default: label.hasPrefix("约好") ? "envelope" : "sparkle"
        }
    }
}
