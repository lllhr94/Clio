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
    // MARK: Top bar

    static func companionStatus(waiting: Approval?, doing: String?, streaming: Bool = false) -> String {
        if waiting != nil { return Words.t("候印") }
        if streaming { return Words.t("落笔") }
        guard let doing else { return Words.t("闲坐") }
        if doing == "正在回复" { return Words.t("落笔") }
        if doing == "正在想" || doing == "等你批准" || doing.contains("在想") || doing.contains("开口") || doing.contains("递出") {
            return Words.t("沉吟")
        }
        if doing.contains("压缩") || doing.contains("提要") {
            return L.t("chat.statusOrganizing")
        }
        let verb = doing.split(separator: "：", maxSplits: 1).first.map(String.init) ?? doing
        switch verb {
        case "搜索", "读网页", "浏览":
            return Words.t("寻访")
        case "读", "看", "查", "翻", "找":
            return L.t("chat.statusReading")
        case "写", "改", "存", "删", "新建":
            return L.t("chat.statusEditing")
        case "跑", "终端", "命令", "SSH":
            return L.t("chat.statusRunning")
        default:
            if doing.contains("寻访") || doing.contains("远游") { return Words.t("寻访") }
            if doing.contains("读") || doing.contains("看") || doing.contains("查") { return L.t("chat.statusReading") }
            if doing.contains("写") || doing.contains("改") { return L.t("chat.statusEditing") }
            if doing.contains("命令") || doing.contains("终端") || doing.contains("SSH") { return L.t("chat.statusRunning") }
            return L.t("chat.statusWorking")
        }
    }

    static func companionPetState(
        waiting: Approval?,
        hasStreaming: Bool,
        doing: String?,
        working: Bool,
        typing: Bool,
        listening: Bool,
        cheering: Bool,
        dozing: Bool
    ) -> String {
        if waiting != nil { return "notification" }
        if hasStreaming || doing == "正在回复" { return "working" }
        if working || typing || listening { return "thinking" }
        if cheering { return "attention" }
        if dozing { return "sleeping" }
        return "idle"
    }

    var header: some View {
        ChatTopBarView(
            chat: chat,
            team: team,
            bot: bot,
            side: side,
            dictationSlot: dictationSlot,
            idleMood: idleMood,
            followState: followState,
            notice: notice,
            chromeCoordinator: chromeCoordinator,
            viewportWidth: chatViewport.width,
            largeText: largeText,
            textScale: textScale,
            typing: $typing,
            headerHeight: $headerHeight,
            glancing: $glancing,
            detailOpen: $detailOpen,
            cardOpen: $cardOpen,
            roaming: $roaming,
            sharing: $sharing,
            exportFailed: $exportFailed,
            clearingChat: $clearingChat,
            terminalOpen: $terminalOpen,
            filesOpen: $filesOpen,
            chatSkillsOpen: $chatSkillsOpen,
            chatConnectorsOpen: $chatConnectorsOpen,
            outlinePairs: $outlinePairs,
            outlining: $outlining,
            leafing: $leafing,
            renameText: $renameText,
            renaming: $renaming,
            onLeave: leave,
            onStartFinding: startFinding,
            onReturnToLatest: returnToLatest,
            onLoadOutlinePairs: {
                await loadEverything()
                return outline
            }
        )
    }

    var headerBack: some View {
        ChatHeaderBackButton(onLeave: leave)
    }
}

/// Wide velvety Hana-style top paper fade melting scrolling prose gently before the status bar.
struct ChatTopEdgeFadeOverlay: View {
    let chromeCoordinator: ChatChromeCoordinator
    let headerHeight: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let p = chromeCoordinator.visualProgress
        let baseHeader = headerHeight > 0 ? headerHeight : Ink.Bar.height + Ink.Space.xs * 2
        let fadeTail = max(14 * UIScale.factor, baseHeader * (1 - 0.72 * p) + Ink.Space.s * (1 - p))
        VStack(spacing: 0) {
            Ink.paper
                .frame(height: 1)
                .background {
                    Ink.paper.ignoresSafeArea(edges: .top)
                }
            LinearGradient(
                stops: [
                    .init(color: Ink.paper, location: 0),
                    .init(color: Ink.paper.opacity(0.92), location: 0.42),
                    .init(color: Ink.paper.opacity(0.55), location: 0.74),
                    .init(color: Ink.paper.opacity(0), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: fadeTail)
            Spacer(minLength: 0)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .animation(reduceMotion ? .easeOut(duration: 0.18) : nil, value: p)
    }
}

/// Top floating navigation chrome isolated from message streaming and composer typing.
struct ChatTopBarView: View {
    let chat: ChatModel
    let team: TeamModel
    let bot: BotInfo
    let side: SideControl
    let dictationSlot: ChatDictationSlot
    let idleMood: ChatIdleMood
    let followState: ChatFollowState
    let notice: ChatComposerNotice
    let chromeCoordinator: ChatChromeCoordinator
    let viewportWidth: CGFloat
    let largeText: Bool
    let textScale: CGFloat
    let typing: FocusState<Bool>.Binding
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Binding var headerHeight: CGFloat
    @Binding var glancing: Bool
    @Binding var detailOpen: Bool
    @Binding var cardOpen: Bool
    @Binding var roaming: Bool
    @Binding var sharing: ChatPage.ShareFile?
    @Binding var exportFailed: Bool
    @Binding var clearingChat: Bool
    @Binding var terminalOpen: Bool
    @Binding var filesOpen: Bool
    @Binding var chatSkillsOpen: Bool
    @Binding var chatConnectorsOpen: Bool
    @Binding var outlinePairs: [OutlineSheet.Pair]
    @Binding var outlining: Bool
    @Binding var leafing: Bool
    @Binding var renameText: String
    @Binding var renaming: Bool

    let onLeave: () -> Void
    let onStartFinding: () -> Void
    let onReturnToLatest: () -> Void
    let onLoadOutlinePairs: () async -> [OutlineSheet.Pair]

    var body: some View {
        let p = chromeCoordinator.visualProgress
        ZStack {
            innerBar
                .offset(y: reduceMotion ? 0 : -60 * p)
                .scaleEffect(reduceMotion ? 1 : (1 - 0.03 * p), anchor: .top)
                .opacity(max(0, 1 - Double(p) * 1.18))
                .allowsHitTesting(p < 0.5)
                .accessibilityHidden(p >= 0.5)
        }
        .padding(.horizontal, Ink.Space.page)
        .padding(.top, Ink.Space.xs)
        .padding(.bottom, Ink.Space.xs)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
    }

    @ViewBuilder
    private var innerBar: some View {
        if largeText {
            HStack(alignment: .center, spacing: Ink.Space.s) {
                ChatHeaderBackButton(onLeave: onLeave)
                    .layoutPriority(2)
                centeredIdentityPill
                    .layoutPriority(0)
                Spacer(minLength: 0)
                controlsView
                    .layoutPriority(1)
            }
        } else {
            ZStack {
                HStack(spacing: Ink.Space.xs) {
                    ChatHeaderBackButton(onLeave: onLeave)
                    Spacer(minLength: 0)
                    controlsView
                }
                centeredIdentityPill
                    .padding(.horizontal, Ink.Bar.height + Ink.Space.s)
            }
        }
    }

    private var centeredIdentityPill: some View {
        ChatCenteredIdentityPill(
            chat: chat,
            team: team,
            bot: bot,
            notice: notice,
            dictationSlot: dictationSlot,
            idleMood: idleMood,
            viewportWidth: viewportWidth,
            largeText: largeText,
            textScale: textScale,
            typing: typing,
            glancing: $glancing,
            detailOpen: $detailOpen,
            cardOpen: $cardOpen
        )
    }

    private var controlsView: some View {
        ChatTopBarControlsView(
            chat: chat,
            team: team,
            bot: bot,
            side: side,
            notice: notice,
            followState: followState,
            viewportWidth: viewportWidth,
            largeText: largeText,
            typing: typing,
            roaming: $roaming,
            sharing: $sharing,
            exportFailed: $exportFailed,
            clearingChat: $clearingChat,
            terminalOpen: $terminalOpen,
            filesOpen: $filesOpen,
            chatSkillsOpen: $chatSkillsOpen,
            chatConnectorsOpen: $chatConnectorsOpen,
            outlinePairs: $outlinePairs,
            outlining: $outlining,
            leafing: $leafing,
            renameText: $renameText,
            renaming: $renaming,
            cardOpen: $cardOpen,
            detailOpen: $detailOpen,
            onStartFinding: onStartFinding,
            onReturnToLatest: onReturnToLatest,
            onLoadOutlinePairs: onLoadOutlinePairs
        )
    }
}

private struct ChatHeaderBackButton: View {
    let onLeave: () -> Void

    var body: some View {
        Button(action: onLeave) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: Ink.Size.body, weight: .medium))
                .foregroundStyle(Ink.ink)
                .frame(width: Ink.Bar.height, height: Ink.Bar.height)
                .glassFace(in: Circle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel("打开侧边栏")
    }
}

/// Hana-style ultra-tight centered pill: avatar opens glance card, name opens model/thinking & chat details.
private struct ChatCenteredIdentityPill: View {
    let chat: ChatModel
    @ObservedObject var team: TeamModel
    let bot: BotInfo
    let notice: ChatComposerNotice
    let dictationSlot: ChatDictationSlot
    let idleMood: ChatIdleMood
    let viewportWidth: CGFloat
    let largeText: Bool
    let textScale: CGFloat
    let typing: FocusState<Bool>.Binding

    @Binding var glancing: Bool
    @Binding var detailOpen: Bool
    @Binding var cardOpen: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isRoom: Bool { chat.roomId != nil }
    private var doing: String? { team.workDetail(for: chat.key).words }
    private var working: Bool { doing != nil || chat.hasStreaming }
    private var waiting: Approval? { team.approvals.first { $0.chat == chat.key } }
    private var active: Bool { working || waiting != nil }

    private var headerLine: String {
        ChatPage.companionStatus(waiting: waiting, doing: doing, streaming: chat.hasStreaming)
    }

    var body: some View {
        let options = team.options(chat.key)
        let own = team.resolveActive(options.model) != nil ? options.model : nil
        let speaker = ChatPage.speakerForModel(in: chat, team: team, fallback: bot)
        let rawName = team.current(chat.key, bot: speaker)?.model ?? L.t("settings.models")
        let offered = ChatPage.offeredThinkingLevels(in: chat, team: team, fallback: bot)
        let level = offered.contains(options.thinking ?? .auto) ? (options.thinking ?? .auto) : .auto

        HStack(spacing: Ink.Space.s) {
            ChatTopBarPetFace(
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
            // Its face opens a glance at it: what it does, what it made, its schedule.
            .onTapGesture {
                guard !isRoom else { detailOpen = true; return }
                Haptics.light()
                glancing = true
            }
            .popover(isPresented: $glancing) {
                GlanceCard(
                    team: team,
                    bot: bot,
                    key: chat.key,
                    availableWidth: viewportWidth,
                    openCard: { glancing = false; cardOpen = true },
                    openDetail: { glancing = false; detailOpen = true }
                )
                .presentationCompactAdaptation(.popover)
            }

            Menu {
                Section(rawName) {
                    if isRoom {
                        Text("\(L.t("settings.models"))：\(rawName)")
                    } else {
                        Button {
                            ChatPage.selectModel(nil, in: chat, team: team, bot: bot, notice: notice)
                        } label: {
                            let label = "跟着\(bot.name)走"
                            if own == nil { Label(label, systemImage: "checkmark") } else { Text(label) }
                        }
                        ModelChoices(team: team, current: own) { ref in
                            ChatPage.selectModel(ref, in: chat, team: team, bot: bot, notice: notice)
                        }
                    }
                }
                ChatThinkingChoicesSection(chat: chat, team: team, bot: bot, notice: notice)
                Section {
                    Button(L.t("chat.details"), systemImage: "info.circle") {
                        typing.wrappedValue = false
                        detailOpen = true
                    }
                    if !isRoom {
                        Button(L.t("chat.openCard"), systemImage: "person.text.rectangle") {
                            typing.wrappedValue = false
                            cardOpen = true
                        }
                    }
                }
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    Text(bot.name)
                        .font(.system(
                            size: (active && !largeText ? Ink.Size.small : Ink.Size.sub) * (largeText ? textScale : 1),
                            weight: .semibold
                        ))
                        .foregroundStyle(Ink.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if active {
                        HStack(spacing: Ink.Space.xs) {
                            Circle()
                                .fill(waiting != nil ? Ink.warn : Ink.accent)
                                .frame(width: 5, height: 5)
                            Text(headerLine)
                                .font(largeText ? .footnote : .system(size: Ink.Size.micro, weight: .medium))
                                .foregroundStyle(Ink.inkSoft)
                                .lineLimit(largeText ? 2 : 1)
                                .truncationMode(.tail)
                                .fixedSize(horizontal: false, vertical: largeText)
                                .contentTransition(.opacity)
                        }
                        .transition(.opacity)
                    }
                }
                .animation(reduceMotion ? .easeOut(duration: 0.16) : Ink.Motion.quick, value: active)
                .animation(.easeInOut(duration: 0.35), value: headerLine)
                .contentShape(Rectangle())
            }
            .menuOrder(.fixed)
            .accessibilityLabel("\(bot.name)，\(headerLine)")
            .accessibilityValue("\(rawName)，\(level.title)")
            .accessibilityHint(L.t("chat.details"))
        }
        .padding(.leading, 6 * UIScale.factor)
        .padding(.trailing, Ink.Space.m)
        .padding(.vertical, largeText ? Ink.Space.xs : 0)
        .frame(height: largeText ? nil : Ink.Bar.height)
        .frame(minHeight: Ink.Bar.height, alignment: .leading)
        .glassBacking(in: Capsule())
    }
}

private struct ChatTopBarControlsView: View {
    let chat: ChatModel
    @ObservedObject var team: TeamModel
    let bot: BotInfo
    let side: SideControl
    let notice: ChatComposerNotice
    let followState: ChatFollowState
    let viewportWidth: CGFloat
    let largeText: Bool
    let typing: FocusState<Bool>.Binding

    @Binding var roaming: Bool
    @Binding var sharing: ChatPage.ShareFile?
    @Binding var exportFailed: Bool
    @Binding var clearingChat: Bool
    @Binding var terminalOpen: Bool
    @Binding var filesOpen: Bool
    @Binding var chatSkillsOpen: Bool
    @Binding var chatConnectorsOpen: Bool
    @Binding var outlinePairs: [OutlineSheet.Pair]
    @Binding var outlining: Bool
    @Binding var leafing: Bool
    @Binding var renameText: String
    @Binding var renaming: Bool
    @Binding var cardOpen: Bool
    @Binding var detailOpen: Bool

    let onStartFinding: () -> Void
    let onReturnToLatest: () -> Void
    let onLoadOutlinePairs: () async -> [OutlineSheet.Pair]

    private var isRoom: Bool { chat.roomId != nil }
    private var working: Bool { team.workDetail(for: chat.key).words != nil || chat.hasStreaming }
    private var offeredThinking: [Thinking] { ChatPage.offeredThinkingLevels(in: chat, team: team, fallback: bot) }

    var body: some View {
        HStack(spacing: Ink.Space.xs) {
            ChatBrowserIndicator(browser: team.browser) {
                typing.wrappedValue = false
                roaming = true
            }
            headerMoreMenu
                .frame(width: Ink.Bar.height, height: Ink.Bar.height)
                .glassFace(in: Circle())
        }
        .onChange(of: offeredThinking, initial: true) { _, offered in
            if let selection = team.options(chat.key).thinking, !offered.contains(selection) {
                team.setThinking(.auto, in: chat.key)
            }
        }
    }

    private var headerMoreMenu: some View {
        Menu {
            Section {
                menuButton("chat.newConversation", icon: "square.and.pencil") {
                    side.fresh(isRoom ? nil : bot.id)
                }
                menuButton("actions.share", icon: "square.and.arrow.up") {
                    let title = team.title(of: chat.key) ?? bot.name
                    Task {
                        if let url = await team.exportChat(chat.key, title: title) {
                            sharing = ChatPage.ShareFile(url: url)
                        } else {
                            exportFailed = true
                        }
                    }
                }
                menuButton("chat.find", icon: "magnifyingglass") { onStartFinding() }
                if !followState.following {
                    menuButton("chat.latest", icon: "arrow.down.to.line") { onReturnToLatest() }
                }
            }
            Section {
                menuButton("chat.compactContext", icon: "rectangle.compress.vertical") {
                    Task { _ = try? await team.compress(chat.key) }
                }
                Button(L.t("actions.clear"), systemImage: "trash", role: .destructive) {
                    typing.wrappedValue = false
                    clearingChat = true
                }
            }
            Section {
                menuButton("nav.terminal", icon: "terminal") { terminalOpen = true }
                menuButton("nav.browser", icon: "safari") { roaming = true }
                menuButton("chat.files", icon: "folder") { filesOpen = true }
            }
            Section {
                menuButton("agent.skills", icon: "books.vertical") { chatSkillsOpen = true }
                menuButton("chat.mcp", icon: "point.3.connected.trianglepath.dotted") { chatConnectorsOpen = true }
            }
            Section {
                menuButton("chat.outline", icon: "list.bullet.indent") {
                    Task {
                        outlinePairs = await onLoadOutlinePairs()
                        outlining = true
                    }
                }
                menuButton("chat.conversationHistory", icon: "book.pages") { leafing = true }
                menuButton("chat.rename", icon: "pencil") {
                    renameText = team.title(of: chat.key) ?? ""
                    renaming = true
                }
                if !isRoom { menuButton("chat.openCard", icon: "person.text.rectangle") { cardOpen = true } }
                if working { menuButton("alwaysOn.open", icon: "moon.stars") { AlwaysOn.show(chat: chat.key) } }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: Ink.Size.body, weight: .medium))
                .foregroundStyle(Ink.ink)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(L.t("chat.menu"))
    }

    private func menuButton(_ key: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(L.t(key), systemImage: icon) {
            typing.wrappedValue = false
            action()
        }
    }
}

private struct ChatTopBarPetFace: View {
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
            ChatActiveTopBarPetFace(
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
            PetStill(size: 28 * UIScale.factor, state: state, avatar: true, bot: isRoom ? nil : bot)
                .breathing(working, tint: Ink.accent)
        }
    }
}

private struct ChatActiveTopBarPetFace: View {
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
        PetStill(size: 28 * UIScale.factor, state: state, avatar: true, bot: isRoom ? nil : bot)
            .breathing(working, tint: Ink.accent)
    }
}
