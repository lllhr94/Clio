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
            contextMetrics: contextMetrics,
            chromeCoordinator: chromeCoordinator,
            viewportWidth: chatViewport.width,
            largeText: largeText,
            textScale: textScale,
            typing: $typing,
            headerHeight: $headerHeight,
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

/// Pure optical progressive blur locked strictly above `safeAreaTop + 4pt` (status bar bottom edge) with zero fog below.
struct ChatStatusBarBlurVeil: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var fullTopY: CGFloat = 0
    @State private var safeTopY: CGFloat = 0

    private var safeAreaTop: CGFloat {
        max(0, safeTopY - fullTopY)
    }

    private var veilHeight: CGFloat {
        safeAreaTop > 0 ? safeAreaTop + 4 : 0
    }

    private var usesReducedBlur: Bool {
        reduceTransparency || Theme.shared.reduceVisualEffects
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
                .ignoresSafeArea(edges: .top)
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { fullTopY = $0 }
            Color.clear
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { safeTopY = $0 }

            if veilHeight > 0 {
                VStack(spacing: 0) {
                    blurSurface
                        .frame(height: veilHeight)
                    Spacer(minLength: 0)
                }
                .ignoresSafeArea(edges: .top)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var blurSurface: some View {
        if usesReducedBlur {
            LinearGradient(
                stops: [
                    .init(color: Ink.paper.opacity(0.95), location: 0),
                    .init(color: Ink.paper.opacity(0.70), location: 0.60),
                    .init(color: Ink.paper.opacity(0.24), location: 0.86),
                    .init(color: Ink.paper.opacity(0), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        } else {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Rectangle().fill(Ink.paper.opacity(0.06))
            }
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .white, location: 0),
                        .init(color: .white.opacity(0.86), location: 0.56),
                        .init(color: .white.opacity(0.30), location: 0.84),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
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
    let contextMetrics: ChatContextMetrics
    let chromeCoordinator: ChatChromeCoordinator
    let viewportWidth: CGFloat
    let largeText: Bool
    let textScale: CGFloat
    let typing: FocusState<Bool>.Binding
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Binding var headerHeight: CGFloat
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
            contextMetrics: contextMetrics,
            dictationSlot: dictationSlot,
            idleMood: idleMood,
            viewportWidth: viewportWidth,
            largeText: largeText,
            textScale: textScale,
            typing: typing,
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

/// Unified companion identity pill (`44 * UIScale.factor` tall): `36pt` circular avatar + name/status, anchored to `ChatCompanionHubPopover`.
private struct ChatCenteredIdentityPill: View {
    let chat: ChatModel
    @ObservedObject var team: TeamModel
    let bot: BotInfo
    let notice: ChatComposerNotice
    let contextMetrics: ChatContextMetrics
    let dictationSlot: ChatDictationSlot
    let idleMood: ChatIdleMood
    let viewportWidth: CGFloat
    let largeText: Bool
    let textScale: CGFloat
    let typing: FocusState<Bool>.Binding

    @Binding var detailOpen: Bool
    @Binding var cardOpen: Bool
    @State private var showCompanionHub = false
    @State private var lastHubToggleAt: TimeInterval = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isRoom: Bool { chat.roomId != nil }
    private var doing: String? { team.workDetail(for: chat.key).words }
    private var working: Bool { doing != nil || chat.hasStreaming }
    private var waiting: Approval? { team.approvals.first { $0.chat == chat.key } }
    private var active: Bool { working || waiting != nil }

    private var headerLine: String {
        ChatPage.companionStatus(waiting: waiting, doing: doing, streaming: chat.hasStreaming)
    }

    private var avatarRingSize: CGFloat {
        36 * UIScale.factor
    }

    private var concentricPadding: CGFloat {
        4 * UIScale.factor
    }

    private var pillHeight: CGFloat? {
        largeText ? nil : Ink.Bar.height
    }

    var body: some View {
        let speaker = ChatPage.speakerForModel(in: chat, team: team, fallback: bot)
        let displayName = team.current(chat.key, bot: speaker).map {
            $0.endpoint.distinguishableDisplayName(for: $0.model)
        } ?? L.t("settings.models")
        let options = team.options(chat.key)
        let offered = ChatPage.offeredThinkingLevels(in: chat, team: team, fallback: bot)
        let level = offered.contains(options.thinking ?? .auto) ? (options.thinking ?? .auto) : .auto

        Button(action: toggleCompanionHub) {
            pillContent
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel("\(bot.name)，\(headerLine)")
        .accessibilityValue("\(displayName)，\(level.title)")
        .accessibilityHint(L.t("chatHub.details"))
        .popover(isPresented: $showCompanionHub, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
            ChatCompanionHubPopover(
                chat: chat,
                team: team,
                bot: bot,
                notice: notice,
                contextMetrics: contextMetrics,
                dictationSlot: dictationSlot,
                idleMood: idleMood,
                typing: typing,
                isPresented: $showCompanionHub,
                detailOpen: $detailOpen,
                cardOpen: $cardOpen
            )
            .presentationCompactAdaptation(.popover)
            .presentationBackground(Ink.paperRaised)
        }
    }

    private var pillContent: some View {
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
                bot: bot,
                size: avatarRingSize
            )
            .frame(width: avatarRingSize, height: avatarRingSize)
            .clipShape(Circle())
            .overlay {
                Circle()
                    .strokeBorder(Ink.rule, lineWidth: 0.5)
                    .allowsHitTesting(false)
            }

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

            Image(systemName: "chevron.down")
                .font(.system(size: Ink.Size.micro, weight: .semibold))
                .foregroundStyle(Ink.inkFaint)
                .rotationEffect(.degrees(showCompanionHub ? 180 : 0))
                .animation(reduceMotion ? .easeOut(duration: 0.14) : Ink.Motion.quick, value: showCompanionHub)
        }
        .padding(.leading, concentricPadding)
        .padding(.vertical, largeText ? concentricPadding : 0)
        .padding(.trailing, Ink.Space.m)
        .frame(height: pillHeight)
        .frame(minHeight: Ink.Bar.height, alignment: .leading)
        .glassBacking(in: Capsule())
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Ink.rule.opacity(0.55), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .contentShape(Capsule(style: .continuous))
    }

    private func toggleCompanionHub() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastHubToggleAt >= 0.18 else { return }
        lastHubToggleAt = now
        typing.wrappedValue = false
        Haptics.light()
        showCompanionHub.toggle()
    }
}

/// Anchored compact companion hub popover: header, model switcher (2-level provider -> model), thinking control, context bar.
private struct ChatCompanionHubPopover: View {
    enum Route: Equatable {
        case root
        case providers
        case models(endpointID: String)

        var idKey: String {
            switch self {
            case .root: return "root"
            case .providers: return "providers"
            case .models(let id): return "models:\(id)"
            }
        }
    }

    let chat: ChatModel
    @ObservedObject var team: TeamModel
    let bot: BotInfo
    let notice: ChatComposerNotice
    let contextMetrics: ChatContextMetrics
    let dictationSlot: ChatDictationSlot
    let idleMood: ChatIdleMood
    let typing: FocusState<Bool>.Binding

    @Binding var isPresented: Bool
    @Binding var detailOpen: Bool
    @Binding var cardOpen: Bool

    @State private var route: Route = .root
    @State private var navigatingForward = true
    @State private var compressing = false
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isRoom: Bool { chat.roomId != nil }
    private var doing: String? { team.workDetail(for: chat.key).words }
    private var working: Bool { doing != nil || chat.hasStreaming }
    private var waiting: Approval? { team.approvals.first { $0.chat == chat.key } }
    private var active: Bool { working || waiting != nil }
    private var endpoints: [Endpoint] { team.settings.endpoints }

    private var speaker: BotInfo {
        ChatPage.speakerForModel(in: chat, team: team, fallback: bot)
    }

    private var currentResolved: (endpoint: Endpoint, model: String)? {
        guard let current = team.current(chat.key, bot: speaker) else { return nil }
        return (current.endpoint, current.model)
    }

    private var currentModelRef: String? {
        let options = team.options(chat.key)
        return options.model ?? bot.model ?? team.settings.defaultModel
    }

    private var currentDisplayName: String {
        if let currentResolved {
            return currentResolved.endpoint.distinguishableDisplayName(for: currentResolved.model)
        }
        return team.modelShort(currentModelRef)
    }

    private var currentSubtitle: String {
        if let currentResolved {
            return "\(currentResolved.endpoint.name) · \(currentResolved.model)"
        }
        return L.t("chatHub.noProviders")
    }

    private var statusLine: String {
        if active {
            return ChatPage.companionStatus(waiting: waiting, doing: doing, streaming: chat.hasStreaming)
        }
        if currentResolved != nil {
            return currentDisplayName
        }
        return ChatPage.companionStatus(waiting: nil, doing: nil, streaming: false)
    }

    private var offeredThinking: [Thinking] {
        ChatPage.offeredThinkingLevels(in: chat, team: team, fallback: bot)
    }

    private var selectedThinking: Thinking {
        let current = team.options(chat.key).thinking ?? .auto
        return offeredThinking.contains(current) ? current : .auto
    }

    private var thinkingBinding: Binding<Thinking> {
        Binding(
            get: { selectedThinking },
            set: { next in
                team.setThinking(next, in: chat.key)
            }
        )
    }

    private var hubAnimation: Animation {
        Ink.Motion.prefersReduced(reduceMotion) ? .easeOut(duration: 0.16) : Ink.Motion.quick
    }

    private var routeTransition: AnyTransition {
        if Ink.Motion.prefersReduced(reduceMotion) {
            return .opacity
        }
        if navigatingForward {
            return .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            )
        } else {
            return .asymmetric(
                insertion: .move(edge: .leading).combined(with: .opacity),
                removal: .move(edge: .trailing).combined(with: .opacity)
            )
        }
    }

    var body: some View {
        ZStack {
            routeBody
                .id(route.idKey)
                .transition(routeTransition)
        }
        .frame(width: 298 * UIScale.factor)
        .clipped()
        .animation(hubAnimation, value: route)
        .task(id: chat.key) {
            if contextMetrics.estimate == nil {
                contextMetrics.estimate = await team.contextEstimate(chat.key)
            }
        }
    }

    @ViewBuilder
    private var routeBody: some View {
        switch route {
        case .root:
            rootView
        case .providers:
            providersView
        case .models(let endpointID):
            modelsView(endpointID: endpointID)
        }
    }

    private var rootView: some View {
        VStack(spacing: 0) {
            rootHeaderSection
            hairlineDivider
            rootModelRowSection
            if offeredThinking.count > 1 {
                hairlineDivider
                rootThinkingSection
            }
            hairlineDivider
            rootContextSection
        }
    }

    private var rootHeaderSection: some View {
        HStack(spacing: Ink.Space.m) {
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
                bot: bot,
                size: 38 * UIScale.factor
            )
            .frame(width: 38 * UIScale.factor, height: 38 * UIScale.factor)
            .clipShape(Circle())
            .overlay {
                Circle()
                    .strokeBorder(Ink.rule, lineWidth: 0.5)
                    .allowsHitTesting(false)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Ink.Space.xs) {
                    Text(bot.name)
                        .font(.system(size: Ink.Size.body, weight: .semibold))
                        .foregroundStyle(Ink.ink)
                        .lineLimit(1)
                    ClioSeal(
                        size: 18 * UIScale.factor,
                        character: isRoom ? "克" : ClioSeal.character(for: bot)
                    )
                }
                Text(statusLine)
                    .font(.system(size: Ink.Size.micro))
                    .foregroundStyle(Ink.inkSoft)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)

            HStack(spacing: Ink.Space.xs) {
                if !isRoom {
                    hubActionIcon(title: L.t("chatHub.nameCard"), symbol: "person.text.rectangle") {
                        isPresented = false
                        typing.wrappedValue = false
                        cardOpen = true
                    }
                }
                hubActionIcon(title: L.t("chatHub.details"), symbol: "info.circle") {
                    isPresented = false
                    typing.wrappedValue = false
                    detailOpen = true
                }
            }
        }
        .padding(.horizontal, Ink.Space.m)
        .padding(.vertical, Ink.Space.m)
    }

    private func hubActionIcon(title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: Ink.Size.small, weight: .medium))
                .foregroundStyle(Ink.inkSoft)
                .frame(width: 28 * UIScale.factor, height: 28 * UIScale.factor)
                .background(Ink.surfaceSubtle, in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(Ink.rule.opacity(0.65), lineWidth: 0.5)
                        .allowsHitTesting(false)
                }
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(title)
        .help(title)
    }

    private var rootModelRowSection: some View {
        Button(action: openModelPicker) {
            HStack(spacing: Ink.Space.s) {
                if let currentResolved {
                    ServiceIcon(
                        service: Service.of(currentResolved.endpoint),
                        size: 24 * UIScale.factor,
                        name: currentResolved.endpoint.name
                    )
                } else {
                    Image(systemName: "cpu")
                        .font(.system(size: Ink.Size.small, weight: .medium))
                        .foregroundStyle(Ink.inkSoft)
                        .frame(width: 24 * UIScale.factor, height: 24 * UIScale.factor)
                        .background(Ink.surfaceSubtle, in: RoundedRectangle(cornerRadius: Kit.iconCorner(24 * UIScale.factor), style: .continuous))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(currentDisplayName)
                        .font(.system(size: Ink.Size.small, weight: .medium))
                        .foregroundStyle(Ink.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(currentSubtitle)
                        .font(Ink.mono(Ink.Size.micro))
                        .foregroundStyle(Ink.inkFaint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)

                if !isRoom {
                    Image(systemName: "chevron.right")
                        .font(.system(size: Ink.Size.micro, weight: .semibold))
                        .foregroundStyle(Ink.inkFaint)
                }
            }
            .padding(.horizontal, Ink.Space.m)
            .padding(.vertical, Ink.Space.m)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .disabled(isRoom)
    }

    private var rootThinkingSection: some View {
        VStack(alignment: .leading, spacing: Ink.Space.xs) {
            HStack {
                Text(L.t("chatHub.thinking"))
                    .font(.system(size: Ink.Size.micro, weight: .medium))
                    .foregroundStyle(Ink.inkFaint)
                Spacer(minLength: 0)
                Text(selectedThinking.title)
                    .font(.system(size: Ink.Size.micro, weight: .medium))
                    .foregroundStyle(Ink.inkSoft)
            }
            SlidingCapsuleControl(
                selection: thinkingBinding,
                options: offeredThinking,
                compact: true
            ) { option in
                option.title
            }
        }
        .padding(.horizontal, Ink.Space.m)
        .padding(.vertical, Ink.Space.m)
    }

    private var rootContextSection: some View {
        let estimate = contextMetrics.estimate
        let share = estimate?.share ?? 0
        let barColor = share >= 0.7 ? Ink.warn : Ink.accent

        return VStack(alignment: .leading, spacing: Ink.Space.s) {
            HStack(spacing: Ink.Space.xs) {
                Text(L.t("chatHub.context"))
                    .font(.system(size: Ink.Size.micro, weight: .medium))
                    .foregroundStyle(Ink.inkFaint)
                Spacer(minLength: 0)
                if let estimate {
                    Text("\(Tokens.short(estimate.total)) / \(Tokens.short(estimate.window)) · \(UsageSheet.percent(estimate.share))")
                        .font(Ink.mono(Ink.Size.micro, weight: .medium).monospacedDigit())
                        .foregroundStyle(Ink.inkSoft)
                        .contentTransition(.numericText(value: Double(estimate.total)))
                        .animation(Ink.Motion.quick, value: estimate.total)
                } else {
                    Text("--")
                        .font(Ink.mono(Ink.Size.micro, weight: .medium))
                        .foregroundStyle(Ink.inkFaint)
                }
            }

            GeometryReader { proxy in
                let fraction = (estimate?.total ?? 0) > 0 ? min(1, max(0.03, share)) : 0
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Ink.surfaceSubtle)
                    if fraction > 0 {
                        Capsule(style: .continuous)
                            .fill(barColor)
                            .frame(width: max(4, proxy.size.width * fraction))
                    }
                }
            }
            .frame(height: 5 * UIScale.factor)

            HStack {
                Spacer(minLength: 0)
                Button(action: compressContext) {
                    HStack(spacing: Ink.Space.xs) {
                        Image(systemName: "rectangle.compress.vertical")
                            .font(.system(size: Ink.Size.micro, weight: .medium))
                        Text(compressing ? L.t("loading.compactingContext") : L.t("chatHub.compressNow"))
                            .font(.system(size: Ink.Size.micro, weight: .medium))
                    }
                    .foregroundStyle(compressing ? Ink.inkFaint : Ink.accent)
                    .padding(.horizontal, Ink.Space.s)
                    .padding(.vertical, Ink.Space.xs)
                    .background(Ink.surfaceSubtle, in: Capsule(style: .continuous))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(Ink.rule.opacity(0.65), lineWidth: 0.5)
                            .allowsHitTesting(false)
                    }
                }
                .buttonStyle(PressStyle())
                .disabled(compressing)
            }
        }
        .padding(.horizontal, Ink.Space.m)
        .padding(.vertical, Ink.Space.m)
    }

    private var providersView: some View {
        VStack(spacing: 0) {
            pickerHeader(backTitle: L.t("chatHub.back"), title: L.t("chatHub.providers")) {
                navigatingForward = false
                Haptics.light()
                route = .root
            }
            hairlineDivider
            if endpoints.isEmpty {
                emptyProvidersState
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        defaultModelResetRowIfNeeded
                        ForEach(endpoints) { endpoint in
                            providerRow(endpoint)
                            if endpoint.id != endpoints.last?.id {
                                hairlineDivider
                            }
                        }
                    }
                }
                .frame(maxHeight: 250 * UIScale.factor)
                .scrollBounceBehavior(.basedOnSize)
            }
            hairlineDivider
            manageProvidersFooter
        }
    }

    private var emptyProvidersState: some View {
        VStack(spacing: Ink.Space.s) {
            Image(systemName: "cpu")
                .font(.system(size: Ink.Size.title, weight: .light))
                .foregroundStyle(Ink.inkFaint)
            Text(L.t("chatHub.noProviders"))
                .font(.system(size: Ink.Size.small))
                .foregroundStyle(Ink.inkSoft)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Ink.Space.xl)
    }

    private func providerRow(_ endpoint: Endpoint) -> some View {
        let isActive = currentResolved?.endpoint.id == endpoint.id
        return Button {
            navigatingForward = true
            Haptics.light()
            route = .models(endpointID: endpoint.id)
        } label: {
            HStack(spacing: Ink.Space.s) {
                ServiceIcon(service: Service.of(endpoint), size: 26 * UIScale.factor, name: endpoint.name)
                VStack(alignment: .leading, spacing: 1) {
                    Text(endpoint.name)
                        .font(.system(size: Ink.Size.small, weight: .medium))
                        .foregroundStyle(Ink.ink)
                        .lineLimit(1)
                    Text("\(endpoint.models.count) \(L.t("chatHub.models"))")
                        .font(.system(size: Ink.Size.micro))
                        .foregroundStyle(Ink.inkFaint)
                }
                Spacer(minLength: 0)
                if isActive {
                    Circle()
                        .fill(Ink.accent)
                        .frame(width: 6, height: 6)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: Ink.Size.micro, weight: .semibold))
                    .foregroundStyle(Ink.inkFaint)
            }
            .padding(.horizontal, Ink.Space.m)
            .padding(.vertical, Ink.Space.s)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }

    private func modelsView(endpointID: String) -> some View {
        let endpoint = endpoints.first(where: { $0.id == endpointID })
        let backLabel = endpoints.count >= 2 ? L.t("chatHub.providers") : L.t("chatHub.back")
        let backTarget: Route = endpoints.count >= 2 ? .providers : .root

        return VStack(spacing: 0) {
            pickerHeader(backTitle: backLabel, title: endpoint?.name ?? L.t("chatHub.models")) {
                navigatingForward = false
                Haptics.light()
                route = backTarget
            }
            hairlineDivider
            if let endpoint {
                if endpoint.models.isEmpty {
                    emptyProvidersState
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            if endpoints.count == 1 {
                                defaultModelResetRowIfNeeded
                            }
                            ForEach(endpoint.models, id: \.self) { model in
                                modelOptionRow(endpoint: endpoint, model: model)
                                if model != endpoint.models.last {
                                    hairlineDivider
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 260 * UIScale.factor)
                    .scrollBounceBehavior(.basedOnSize)
                }
            } else {
                emptyProvidersState
            }
            hairlineDivider
            manageProvidersFooter
        }
    }

    @ViewBuilder
    private var defaultModelResetRowIfNeeded: some View {
        let rawOwn = team.options(chat.key).model
        let own = team.resolveActive(rawOwn) != nil ? rawOwn : nil
        if own != nil && !isRoom {
            Button {
                ChatPage.selectModel(nil, in: chat, team: team, bot: bot, notice: notice)
                navigatingForward = false
                route = .root
                isPresented = false
            } label: {
                HStack(spacing: Ink.Space.s) {
                    Text("跟着\(bot.name)走")
                        .font(.system(size: Ink.Size.small, weight: .medium))
                        .foregroundStyle(Ink.ink)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Ink.Space.m)
                .padding(.vertical, Ink.Space.s)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            hairlineDivider
        }
    }

    private func modelOptionRow(endpoint: Endpoint, model: String) -> some View {
        let primaryTitle = endpoint.distinguishableDisplayName(for: model)
        let showRawSubtitle = endpoint.customName(for: model) != nil || primaryTitle != model
        let traits = endpoint.traits(model)
        let isSelected = currentResolved?.endpoint.id == endpoint.id && currentResolved?.model == model

        return Button {
            ChatPage.selectModel("\(endpoint.id)/\(model)", in: chat, team: team, bot: bot, notice: notice)
            navigatingForward = false
            route = .root
            isPresented = false
        } label: {
            HStack(spacing: Ink.Space.s) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(primaryTitle)
                        .font(.system(size: Ink.Size.small, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(Ink.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if showRawSubtitle || traits.thinks || traits.sees || traits.tools || traits.window > 0 {
                        modelMetaLine(rawModel: model, showRawSubtitle: showRawSubtitle, traits: traits)
                    }
                }
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: Ink.Size.small, weight: .semibold))
                        .foregroundStyle(Ink.accent)
                }
            }
            .padding(.horizontal, Ink.Space.m)
            .padding(.vertical, Ink.Space.s)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }

    private func modelMetaLine(rawModel: String, showRawSubtitle: Bool, traits: ModelTraits) -> some View {
        HStack(spacing: Ink.Space.xs) {
            if showRawSubtitle {
                Text(rawModel)
                    .font(Ink.mono(Ink.Size.micro))
                    .foregroundStyle(Ink.inkFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if traits.thinks {
                Image(systemName: "sparkles")
                    .font(.system(size: Ink.Size.micro))
                    .foregroundStyle(Ink.inkFaint)
            }
            if traits.sees {
                Image(systemName: "eye")
                    .font(.system(size: Ink.Size.micro))
                    .foregroundStyle(Ink.inkFaint)
            }
            if traits.tools {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: Ink.Size.micro))
                    .foregroundStyle(Ink.inkFaint)
            }
            if traits.window > 0 {
                Text(Tokens.short(traits.window))
                    .font(Ink.mono(Ink.Size.micro))
                    .foregroundStyle(Ink.inkFaint)
            }
        }
    }

    private func pickerHeader(backTitle: String, title: String, onBack: @escaping () -> Void) -> some View {
        HStack(spacing: Ink.Space.s) {
            Button(action: onBack) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: Ink.Size.micro, weight: .semibold))
                    Text(backTitle)
                        .font(.system(size: Ink.Size.small, weight: .medium))
                }
                .foregroundStyle(Ink.accent)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())

            Spacer(minLength: 0)

            Text(title)
                .font(.system(size: Ink.Size.small, weight: .semibold))
                .foregroundStyle(Ink.ink)
                .lineLimit(1)
        }
        .padding(.horizontal, Ink.Space.m)
        .padding(.vertical, Ink.Space.s)
    }

    private var manageProvidersFooter: some View {
        Button(action: openProvidersSettings) {
            HStack(spacing: Ink.Space.xs) {
                Image(systemName: "plus")
                    .font(.system(size: Ink.Size.small, weight: .medium))
                Text(L.t("chatHub.manageProviders"))
                    .font(.system(size: Ink.Size.small, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Ink.accent)
            .padding(.horizontal, Ink.Space.m)
            .padding(.vertical, Ink.Space.s)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }

    private var hairlineDivider: some View {
        Ink.rule.opacity(0.65)
            .frame(height: 0.5)
    }

    private func openModelPicker() {
        guard !isRoom else { return }
        Haptics.light()
        navigatingForward = true
        if endpoints.count == 1, let only = endpoints.first {
            route = .models(endpointID: only.id)
        } else {
            route = .providers
        }
    }

    private func openProvidersSettings() {
        Haptics.light()
        isPresented = false
        typing.wrappedValue = false
        if let url = URL(string: "clio://settings/services") {
            openURL(url)
        }
    }

    private func compressContext() {
        guard !compressing else { return }
        compressing = true
        Task {
            do {
                let count = try await team.compress(chat.key)
                Haptics.thud()
                contextMetrics.estimate = await team.contextEstimate(chat.key)
                ToastCenter.shared.show(
                    count > 0 ? "已压缩 \(count) 条较早消息" : "前文暂不需要压缩",
                    symbol: "rectangle.compress.vertical"
                )
            } catch {
                ToastCenter.shared.show(
                    error.localizedDescription,
                    symbol: "exclamationmark.triangle",
                    tint: Ink.warn
                )
            }
            compressing = false
        }
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
                menuButton("chat.find", icon: "magnifyingglass") { onStartFinding() }
                menuButton("chat.outline", icon: "list.bullet.indent") {
                    Task {
                        outlinePairs = await onLoadOutlinePairs()
                        outlining = true
                    }
                }
            }
            Menu(L.t("chatMenu.workbench"), systemImage: "wrench.and.screwdriver") {
                menuButton("chat.files", icon: "folder") { filesOpen = true }
                menuButton("nav.terminal", icon: "terminal") { terminalOpen = true }
                menuButton("nav.browser", icon: "safari") { roaming = true }
                menuButton("agent.skills", icon: "books.vertical") { chatSkillsOpen = true }
                menuButton("chat.mcp", icon: "point.3.connected.trianglepath.dotted") { chatConnectorsOpen = true }
                if working {
                    menuButton("alwaysOn.open", icon: "moon.stars") { AlwaysOn.show(chat: chat.key) }
                }
            }
            Menu(L.t("chatMenu.manageExport"), systemImage: "tray.full") {
                menuButton("chat.compactContext", icon: "rectangle.compress.vertical") {
                    Task {
                        do {
                            let count = try await team.compress(chat.key)
                            Haptics.thud()
                            ToastCenter.shared.show(
                                count > 0 ? "已压缩 \(count) 条较早消息" : "前文暂不需要压缩",
                                symbol: "rectangle.compress.vertical"
                            )
                        } catch {
                            ToastCenter.shared.show(
                                error.localizedDescription,
                                symbol: "exclamationmark.triangle",
                                tint: Ink.warn
                            )
                        }
                    }
                }
                menuButton("chat.rename", icon: "pencil") {
                    renameText = team.title(of: chat.key) ?? ""
                    renaming = true
                }
                menuButton("actions.share", icon: "square.and.arrow.up") {
                    let title = team.title(of: chat.key) ?? bot.name
                    Task {
                        if let url = await team.exportChat(chat.key, title: title) {
                            sharing = ChatPage.ShareFile(url: url)
                            ToastCenter.shared.show("已准备好导出文件", symbol: "square.and.arrow.up")
                        } else {
                            exportFailed = true
                            ToastCenter.shared.show(
                                L.t("errors.exportChat"),
                                symbol: "exclamationmark.triangle",
                                tint: Ink.warn
                            )
                        }
                    }
                }
                menuButton("chat.conversationHistory", icon: "book.pages") { leafing = true }
                menuButton("chat.details", icon: "info.circle") { detailOpen = true }
            }
            Section {
                Button(L.t("actions.clear"), systemImage: "trash", role: .destructive) {
                    typing.wrappedValue = false
                    clearingChat = true
                }
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
    var size: CGFloat = 36 * UIScale.factor

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
                bot: bot,
                size: size
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
            PetStill(size: size, state: state, avatar: true, bot: isRoom ? nil : bot)
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
    var size: CGFloat = 36 * UIScale.factor

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
        PetStill(size: size, state: state, avatar: true, bot: isRoom ? nil : bot)
            .breathing(working, tint: Ink.accent)
    }
}
