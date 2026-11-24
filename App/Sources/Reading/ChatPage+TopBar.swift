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

    static func companionStatus(waiting: Approval?, doing: String?) -> String {
        if waiting != nil { return Words.t("候印") }
        guard let doing else { return Words.t("闲坐") }
        switch doing {
        case "正在回复": return Words.t("落笔")
        case "正在想", "等你批准": return Words.t("沉吟")
        default: return Words.t(doing)
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
    let viewportWidth: CGFloat
    let largeText: Bool
    let textScale: CGFloat
    let typing: FocusState<Bool>.Binding

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
        VStack(alignment: .leading, spacing: Ink.Space.xs) {
            if largeText {
                HStack(alignment: .top, spacing: Ink.Space.s) {
                    ChatHeaderBackButton(onLeave: onLeave)
                    identityView
                    Spacer(minLength: 0)
                    controlsView
                }
                ChatModelMenuView(
                    chat: chat,
                    team: team,
                    bot: bot,
                    notice: notice,
                    viewportWidth: viewportWidth,
                    compact: false
                )
                .glassBacking(in: Capsule())
            } else {
                HStack(alignment: .center, spacing: Ink.Space.s) {
                    ChatHeaderBackButton(onLeave: onLeave)
                    identityView
                    Spacer(minLength: Ink.Space.xs)
                    controlsView
                        .layoutPriority(1)
                }
            }
        }
        .padding(.horizontal, Ink.Bar.edge)
        .padding(.top, Ink.Space.xs)
        .padding(.bottom, Ink.Space.xs)
        // Seamless paper fade beneath the slim floating bar so scrolling prose melts out softly.
        .background {
            Ink.paper.ignoresSafeArea(edges: .top)
        }
        .background(alignment: .bottom) {
            LinearGradient(colors: [Ink.paper, Ink.paper.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: Ink.Space.m)
                .offset(y: Ink.Space.m)
                .allowsHitTesting(false)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
    }

    private var identityView: some View {
        ChatTopBarIdentityView(
            chat: chat,
            team: team,
            bot: bot,
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

private struct ChatTopBarIdentityView: View {
    let chat: ChatModel
    @ObservedObject var team: TeamModel
    let bot: BotInfo
    let dictationSlot: ChatDictationSlot
    let idleMood: ChatIdleMood
    let viewportWidth: CGFloat
    let largeText: Bool
    let textScale: CGFloat
    let typing: FocusState<Bool>.Binding

    @Binding var glancing: Bool
    @Binding var detailOpen: Bool
    @Binding var cardOpen: Bool

    private var isRoom: Bool { chat.roomId != nil }
    private var doing: String? { team.workDetail(for: chat.key).words }
    private var working: Bool { doing != nil || chat.hasStreaming }
    private var waiting: Approval? { team.approvals.first { $0.chat == chat.key } }

    private var headerLine: String {
        let status = ChatPage.companionStatus(waiting: waiting, doing: doing)
        if working || waiting != nil { return status }
        return team.title(of: chat.key) ?? status
    }

    var body: some View {
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
            Button {
                Haptics.light()
                typing.wrappedValue = false
                detailOpen = true
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(bot.name)
                        .font(.system(size: Ink.Size.sub * (largeText ? textScale : 1), weight: .semibold))
                        .foregroundStyle(Ink.ink)
                        .lineLimit(1)
                    HStack(spacing: Ink.Space.xs) {
                        Circle()
                            .fill(working ? Ink.accent : Ink.ok)
                            .frame(width: 5.5, height: 5.5)
                        Text(headerLine)
                            .font(largeText ? .footnote : .system(size: Ink.Size.micro, weight: .medium))
                            .foregroundStyle(Ink.inkSoft)
                            .lineLimit(largeText ? nil : 1)
                            .fixedSize(horizontal: false, vertical: largeText)
                            .contentTransition(.opacity)
                    }
                    .animation(.easeInOut(duration: 0.5), value: headerLine)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(L.t("chat.details"))
        }
        .padding(.leading, Ink.Space.s)
        .padding(.trailing, Ink.Space.m)
        .padding(.vertical, largeText ? Ink.Space.s : 0)
        .frame(minHeight: Ink.Bar.height)
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
            if largeText {
                headerMoreMenu
                    .frame(width: Ink.Bar.height, height: Ink.Bar.height)
                    .glassBacking(in: Circle())
            } else {
                HStack(spacing: 0) {
                    ChatModelMenuView(
                        chat: chat,
                        team: team,
                        bot: bot,
                        notice: notice,
                        viewportWidth: viewportWidth,
                        compact: true
                    )
                    Rectangle()
                        .fill(Ink.rule.opacity(0.75))
                        .frame(width: 0.5, height: 18 * UIScale.factor)
                    headerMoreMenu
                        .frame(width: 40 * UIScale.factor, height: Ink.Bar.height)
                }
                .frame(height: Ink.Bar.height)
                .glassBacking(in: Capsule())
            }
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
