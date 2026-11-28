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
        headerView(reportsHeight: true)
    }

    func headerView(reportsHeight: Bool) -> some View {
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
            historyInView: historyPage != nil,
            isTyping: isComposerFocused,
            reportsHeaderHeight: reportsHeight,
            onDismissTyping: { setComposerFocused(false) },
            onIntrinsicHeightChanged: reportsHeight ? nil : { height in
                listProxy.controller?.updateHostedTopBarHeight(height)
            },
            onHitRectChanged: reportsHeight ? nil : { slot, rect in
                listProxy.controller?.updateTopBarHitRect(slot, rect: rect)
            },
            headerHeight: $headerHeight,
            trackMode: $trackMode,
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

/// Reading-chrome physical metrics aligned with HanaAgent on modern iPhones (46pt bars, 38pt avatar, 44pt jump)
/// so compact/small list scaling never shrinks high-frequency chat touch targets.
enum ChatBarMetrics {
    static var scale: CGFloat { max(1, UIScale.factor) }
    static var height: CGFloat { 46 * scale }
    static var avatarSize: CGFloat { 38 * scale }
    static var concentricPadding: CGFloat { (height - avatarSize) / 2 }
    static var itemSpacing: CGFloat { 8 * scale }
    static var pillTrailing: CGFloat { 16 * scale }
    static var jumpSize: CGFloat { 44 * scale }
    static var controlHeight: CGFloat { 38 * scale }
    static var iconFontSize: CGFloat { 17 * scale }
    static var titleFontSize: CGFloat { 15 * scale }
    static var subTitleFontSize: CGFloat { 13 * scale }
    static var microFontSize: CGFloat { 11 * scale }
}

/// Measures left and right top-bar controls and centers the companion capsule cleanly within the free span
/// without shrinking short names or overlapping when right controls expand.
private struct ChatTopBarThreeSlotLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 3 else {
            return subviews.first?.sizeThatFits(proposal) ?? .zero
        }
        let leftSize = subviews[0].sizeThatFits(.unspecified)
        let rightSize = subviews[2].sizeThatFits(.unspecified)
        let proposedWidth = proposal.width ?? (leftSize.width + rightSize.width + spacing * 2)
        let availableCenter = max(0, proposedWidth - leftSize.width - rightSize.width - spacing * 2)
        let centerSize = subviews[1].sizeThatFits(ProposedViewSize(width: availableCenter, height: proposal.height))
        let width = proposal.width ?? (leftSize.width + centerSize.width + rightSize.width + spacing * 2)
        let height = max(leftSize.height, max(centerSize.height, rightSize.height))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let leftSize = subviews[0].sizeThatFits(.unspecified)
        let rightSize = subviews[2].sizeThatFits(.unspecified)
        let availableCenter = max(0, bounds.width - leftSize.width - rightSize.width - spacing * 2)
        let centerSize = subviews[1].sizeThatFits(ProposedViewSize(width: availableCenter, height: bounds.height))

        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: bounds.midY),
            anchor: .leading,
            proposal: ProposedViewSize(leftSize)
        )
        subviews[2].place(
            at: CGPoint(x: bounds.maxX, y: bounds.midY),
            anchor: .trailing,
            proposal: ProposedViewSize(rightSize)
        )

        let placedCenterWidth = min(availableCenter, centerSize.width)
        let minAllowedX = bounds.minX + leftSize.width + spacing
        let maxAllowedX = bounds.maxX - rightSize.width - spacing - placedCenterWidth
        let desiredMinX = bounds.midX - placedCenterWidth / 2
        let centerX: CGFloat
        if minAllowedX <= maxAllowedX {
            centerX = min(maxAllowedX, max(minAllowedX, desiredMinX))
        } else {
            centerX = minAllowedX
        }
        subviews[1].place(
            at: CGPoint(x: centerX, y: bounds.midY),
            anchor: .leading,
            proposal: ProposedViewSize(width: placedCenterWidth, height: centerSize.height)
        )
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
    let historyInView: Bool
    let isTyping: Bool
    let reportsHeaderHeight: Bool
    let onDismissTyping: () -> Void
    let onIntrinsicHeightChanged: ((CGFloat) -> Void)?
    let onHitRectChanged: ((Int, CGRect) -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Binding var headerHeight: CGFloat
    @Binding var trackMode: ChatTrackMode
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

    private var effectiveReduceMotion: Bool {
        Ink.Motion.prefersReduced(reduceMotion)
    }

    private var isImmersiveCollapsed: Bool {
        chromeCoordinator.mode == .immersive && chromeCoordinator.isEnabled
    }

    var body: some View {
        let p = chromeCoordinator.visualProgress
        ZStack {
            innerBar
                .offset(y: effectiveReduceMotion ? 0 : -60 * p)
                .scaleEffect(effectiveReduceMotion ? 1 : (1 - 0.03 * p), anchor: .top)
                .opacity(max(0, 1 - Double(p) * 1.18))
                .allowsHitTesting(p < 0.5)
                .accessibilityHidden(p >= 0.5)
        }
        .padding(.horizontal, Ink.Space.page)
        .padding(.top, 2)
        .padding(.bottom, 0)
        .coordinateSpace(name: "chatTopBar")
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { next in
            if reportsHeaderHeight {
                if abs(headerHeight - next) > 0.5 {
                    headerHeight = next
                }
            } else {
                onIntrinsicHeightChanged?(next)
            }
        }
    }

    @ViewBuilder
    private var innerBar: some View {
        if largeText {
            HStack(alignment: .center, spacing: Ink.Space.s) {
                leftSlotView
                    .layoutPriority(2)
                centerSlotView
                    .layoutPriority(0)
                Spacer(minLength: 0)
                controlsView
                    .layoutPriority(1)
            }
        } else {
            ChatTopBarThreeSlotLayout(spacing: ChatBarMetrics.itemSpacing) {
                leftSlotView
                centerSlotView
                controlsView
            }
        }
    }

    private var leftSlotView: some View {
        ChatHeaderBackButton(onLeave: onLeave)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("chatTopBar")) } action: { rect in
                onHitRectChanged?(0, rect)
            }
    }

    private var centerSlotView: some View {
        centeredIdentityPill
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("chatTopBar")) } action: { rect in
                onHitRectChanged?(1, rect)
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
            isTyping: isTyping,
            isImmersiveCollapsed: isImmersiveCollapsed,
            onDismissTyping: onDismissTyping,
            trackMode: $trackMode,
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
            historyInView: historyInView,
            onDismissTyping: onDismissTyping,
            onHitRectChanged: onHitRectChanged,
            trackMode: $trackMode,
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
                .font(.system(size: ChatBarMetrics.iconFontSize, weight: .medium))
                .foregroundStyle(Ink.ink)
                .frame(width: ChatBarMetrics.height, height: ChatBarMetrics.height)
                .frostedChatChrome(in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel("打开侧边栏")
    }
}

/// Unified companion identity pill (`46pt` tall): `38pt` circular avatar + name (plus status while working),
/// matching HanaAgent minimalism and anchored to `ChatCompanionHubPopover`.
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
    let isTyping: Bool
    let isImmersiveCollapsed: Bool
    let onDismissTyping: () -> Void

    enum DeferredHubAction {
        case nameCard
        case details
        case manageProviders
    }

    @Binding var trackMode: ChatTrackMode
    @Binding var detailOpen: Bool
    @Binding var cardOpen: Bool
    @State private var showCompanionHub = false
    @State private var deferredHubAction: DeferredHubAction?
    @State private var lastHubToggleAt: TimeInterval = 0
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isRoom: Bool { chat.roomId != nil }
    private var doing: String? { team.workDetail(for: chat.key).words }
    private var working: Bool { doing != nil || chat.hasStreaming }
    private var waiting: Approval? { team.approvals.first { $0.chat == chat.key } }
    private var active: Bool { working || waiting != nil }
    private var effectiveReduceMotion: Bool { Ink.Motion.prefersReduced(reduceMotion) }

    private var headerLine: String {
        ChatPage.companionStatus(waiting: waiting, doing: doing, streaming: chat.hasStreaming)
    }

    private var avatarRingSize: CGFloat {
        ChatBarMetrics.avatarSize
    }

    private var concentricPadding: CGFloat {
        ChatBarMetrics.concentricPadding
    }

    private var pillHeight: CGFloat? {
        largeText ? nil : ChatBarMetrics.height
    }

    var body: some View {
        let speaker = ChatPage.speakerForModel(in: chat, team: team, fallback: bot)
        let displayName = team.current(chat.key, bot: speaker).map {
            $0.endpoint.distinguishableDisplayName(for: $0.model)
        } ?? L.t("settings.models")
        let options = team.options(chat.key)
        let savedSelection = options.effectiveThinkingSelection

        Button(action: toggleCompanionHub) {
            pillContent
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel("\(bot.name)，\(headerLine)")
        .accessibilityValue("\(displayName)，\(savedSelection.title)")
        .accessibilityHint(L.t("chatHub.details"))
        .onChange(of: isImmersiveCollapsed) { _, hidden in
            if hidden && showCompanionHub {
                showCompanionHub = false
            }
        }
        .onDisappear {
            if showCompanionHub {
                showCompanionHub = false
            }
        }
        .popover(isPresented: $showCompanionHub, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
            ChatCompanionHubPopover(
                chat: chat,
                team: team,
                bot: bot,
                notice: notice,
                contextMetrics: contextMetrics,
                dictationSlot: dictationSlot,
                idleMood: idleMood,
                viewportWidth: viewportWidth,
                isTyping: isTyping,
                onDismissTyping: onDismissTyping,
                onDeferAction: { action in
                    deferredHubAction = action
                    onDismissTyping()
                    showCompanionHub = false
                },
                isPresented: $showCompanionHub,
                trackMode: $trackMode
            )
            .presentationCompactAdaptation(.popover)
            .presentationBackground(Ink.paperRaised)
            .onDisappear {
                consumeDeferredHubActionIfNeeded()
            }
        }
    }

    private func consumeDeferredHubActionIfNeeded() {
        guard let action = deferredHubAction else { return }
        deferredHubAction = nil
        Task { @MainActor in
            // Wait for UIKit's popover dismissal transition to finish before presenting a sheet/cover.
            try? await Task.sleep(for: .milliseconds(160))
            guard !showCompanionHub else { return }
            switch action {
            case .nameCard:
                cardOpen = true
            case .details:
                detailOpen = true
            case .manageProviders:
                if let url = URL(string: "clio://settings/services") {
                    openURL(url)
                }
            }
        }
    }

    private var pillContent: some View {
        HStack(spacing: ChatBarMetrics.itemSpacing) {
            ChatTopBarPetFace(
                dictationSlot: dictationSlot,
                waiting: waiting,
                hasStreaming: chat.hasStreaming,
                doing: doing,
                working: working,
                typing: isTyping,
                cheering: idleMood.cheering,
                dozing: idleMood.dozing,
                isRoom: isRoom,
                bot: bot,
                size: avatarRingSize
            )
            .frame(width: avatarRingSize, height: avatarRingSize)
            .clipShape(Circle())
            .background {
                Circle()
                    .fill(Ink.paperRaised.opacity(0.65))
                    .shadow(color: Ink.Artwork.black.opacity(0.05), radius: 2, y: 1)
            }
            .overlay {
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [Ink.Artwork.white.opacity(0.75), Ink.rule.opacity(0.45)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.75
                    )
                    .allowsHitTesting(false)
            }

            VStack(alignment: .leading, spacing: 0) {
                Text(bot.name)
                    .font(.system(
                        size: (active && !largeText ? ChatBarMetrics.subTitleFontSize : ChatBarMetrics.titleFontSize) * (largeText ? textScale : 1),
                        weight: .semibold
                    ))
                    .foregroundStyle(Ink.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                    .fixedSize(horizontal: false, vertical: true)
                if active {
                    HStack(spacing: Ink.Space.xs) {
                        Circle()
                            .fill(waiting != nil ? Ink.warn : Ink.accent)
                            .frame(width: 5, height: 5)
                        Text(headerLine)
                            .font(largeText ? .footnote : .system(size: ChatBarMetrics.microFontSize, weight: .medium))
                            .foregroundStyle(Ink.inkSoft)
                            .lineLimit(largeText ? 2 : 1)
                            .truncationMode(.tail)
                            .layoutPriority(1)
                            .fixedSize(horizontal: false, vertical: true)
                            .contentTransition(.opacity)
                    }
                    .fixedSize(horizontal: !largeText, vertical: false)
                    .transition(.opacity)
                }
            }
            .animation(effectiveReduceMotion ? .easeOut(duration: 0.16) : Ink.Motion.quick, value: active)
            .animation(.easeInOut(duration: 0.35), value: headerLine)
        }
        .padding(.leading, concentricPadding)
        .padding(.vertical, largeText ? concentricPadding : 0)
        .padding(.trailing, ChatBarMetrics.pillTrailing)
        .frame(height: pillHeight)
        .frame(minHeight: ChatBarMetrics.height)
        .frostedChatChrome(in: Capsule(style: .continuous))
        .contentShape(Capsule(style: .continuous))
    }

    private func toggleCompanionHub() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastHubToggleAt >= 0.18 else { return }
        lastHubToggleAt = now
        onDismissTyping()
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
    let viewportWidth: CGFloat
    let isTyping: Bool
    let onDismissTyping: () -> Void
    let onDeferAction: (ChatCenteredIdentityPill.DeferredHubAction) -> Void

    @Binding var isPresented: Bool
    @Binding var trackMode: ChatTrackMode

    @State private var route: Route = .root
    @State private var navigatingForward = true
    @State private var compressing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isRoom: Bool { chat.roomId != nil }
    private var isCasualTrack: Bool { (!isRoom && trackMode == .casual) || chat.key.hasPrefix("casual-") }
    private var doing: String? { team.workDetail(for: chat.key).words }
    private var working: Bool { doing != nil || chat.hasStreaming }
    private var waiting: Approval? { team.approvals.first { $0.chat == chat.key } }
    private var active: Bool { working || waiting != nil }
    private var endpoints: [Endpoint] { team.settings.endpoints }

    private var speaker: BotInfo {
        ChatPage.speakerForModel(in: chat, team: team, fallback: bot)
    }

    private var currentResolved: (endpoint: Endpoint, model: String)? {
        if isCasualTrack {
            guard let found = team.resolveActive(bot.model ?? team.settings.defaultModel)
                    ?? team.resolveActive(team.settings.defaultModel)
                    ?? team.resolve(bot.model ?? team.settings.defaultModel)
                    ?? team.resolve(team.settings.defaultModel) else { return nil }
            return (found.endpoint, found.model)
        }
        guard let current = team.current(chat.key, bot: speaker) else { return nil }
        return (current.endpoint, current.model)
    }

    private var currentModelRef: String? {
        if isCasualTrack {
            return bot.model ?? team.settings.defaultModel
        }
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
            if currentDisplayName != currentResolved.model || currentResolved.endpoint.customName(for: currentResolved.model) != nil {
                return "\(currentResolved.endpoint.name) · \(currentResolved.model)"
            }
            return currentResolved.endpoint.name
        }
        return L.t("chatHub.noProviders")
    }

    private var statusLine: String {
        if active {
            return ChatPage.companionStatus(waiting: waiting, doing: doing, streaming: chat.hasStreaming)
        }
        if let title = team.title(of: chat.key), !title.isEmpty {
            return title
        }
        return ChatPage.companionStatus(waiting: nil, doing: nil, streaming: false)
    }

    private var offeredSelections: [ThinkingSelection] {
        ChatPage.offeredThinkingSelections(in: chat, team: team, fallback: bot)
    }

    private var savedSelection: ThinkingSelection {
        team.options(chat.key).effectiveThinkingSelection
    }

    private var displayedSelection: ThinkingSelection {
        offeredSelections.contains(savedSelection) ? savedSelection : .inheritDefault
    }

    private var thinkingSelectionBinding: Binding<ThinkingSelection> {
        Binding(
            get: { displayedSelection },
            set: { next in
                team.setThinkingSelection(next, in: chat.key)
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
        let maxPopoverWidth: CGFloat = viewportWidth > 0 ? max(240, viewportWidth - Ink.Space.page * 2) : 312 * ChatBarMetrics.scale
        ZStack {
            routeBody
                .id(route.idKey)
                .transition(routeTransition)
        }
        .frame(width: min(312 * ChatBarMetrics.scale, maxPopoverWidth))
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
            if !isRoom {
                SlidingCapsuleControl(
                    selection: $trackMode,
                    options: ChatTrackMode.allCases,
                    compact: true
                ) { option in
                    L.t(option.titleKey)
                }
                .padding(.horizontal, Ink.Space.m)
                .padding(.vertical, Ink.Space.s)
                .onChange(of: trackMode) { _, _ in
                    isPresented = false
                }
                hairlineDivider
            }
            rootHeaderSection
            hairlineDivider
            rootModelRowSection
            if !isCasualTrack {
                if offeredSelections.count > 1 || !savedSelection.isDefault {
                    hairlineDivider
                    rootThinkingSection
                }
                hairlineDivider
                rootPlanModeSection
                hairlineDivider
                rootContextSection
            }
        }
    }

    private var rootPlanModeSection: some View {
        let active = team.isPlanModeActive(for: chat.key)
        return Button {
            Haptics.light()
            team.setPlanMode(!active, in: chat.key)
        } label: {
            HStack(spacing: Ink.Space.s) {
                Image(systemName: active ? "map.fill" : "map")
                    .font(.system(size: Ink.Size.small, weight: .medium))
                    .foregroundStyle(active ? Ink.accent : Ink.inkSoft)
                    .frame(width: 24 * UIScale.factor, height: 24 * UIScale.factor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L.t("plan.modeTitle"))
                        .font(.system(size: Ink.Size.small, weight: .medium))
                        .foregroundStyle(Ink.ink)
                    Text(L.t(active ? "plan.statusCapsule" : "plan.modeSubtitle"))
                        .font(.system(size: Ink.Size.micro))
                        .foregroundStyle(active ? Ink.accent : Ink.inkFaint)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: active ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: Ink.Size.sub, weight: .medium))
                    .foregroundStyle(active ? Ink.accent : Ink.inkFaint)
            }
            .padding(.horizontal, Ink.Space.m)
            .padding(.vertical, Ink.Space.s)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }

    private var rootHeaderSection: some View {
        HStack(spacing: Ink.Space.m) {
            ChatTopBarPetFace(
                dictationSlot: dictationSlot,
                waiting: waiting,
                hasStreaming: chat.hasStreaming,
                doing: doing,
                working: working,
                typing: isTyping,
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
                        onDeferAction(.nameCard)
                    }
                }
                if !isCasualTrack {
                    hubActionIcon(title: L.t("chatHub.details"), symbol: "info.circle") {
                        onDeferAction(.details)
                    }
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

                if !isRoom && !isCasualTrack {
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
        .disabled(isRoom || isCasualTrack)
    }

    private var rootThinkingSection: some View {
        let unfulfilled = !savedSelection.isDefault && !offeredSelections.contains(savedSelection)
        return VStack(alignment: .leading, spacing: Ink.Space.xs) {
            HStack {
                Text(L.t("chatHub.thinking"))
                    .font(.system(size: Ink.Size.micro, weight: .medium))
                    .foregroundStyle(Ink.inkFaint)
                Spacer(minLength: 0)
                Text(savedSelection.title)
                    .font(.system(size: Ink.Size.micro, weight: .medium))
                    .foregroundStyle(unfulfilled ? Ink.warn : Ink.inkSoft)
            }
            if offeredSelections.count > 1 {
                SlidingCapsuleControl(
                    selection: thinkingSelectionBinding,
                    options: offeredSelections,
                    compact: true
                ) { option in
                    option.title
                }
            }
            if unfulfilled {
                VStack(alignment: .leading, spacing: Ink.Space.xs) {
                    Text("当前模型暂不支持已保存的「\(savedSelection.title)」，已保留原设定。")
                        .font(.system(size: Ink.Size.micro))
                        .foregroundStyle(Ink.warn)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        Haptics.light()
                        team.setThinkingSelection(.inheritDefault, in: chat.key)
                    } label: {
                        Text("切回默认")
                            .font(.system(size: Ink.Size.micro, weight: .semibold))
                            .foregroundStyle(Ink.accent)
                            .padding(.horizontal, Ink.Space.s)
                            .padding(.vertical, Ink.Space.xs)
                            .background(Ink.accentWash, in: Capsule(style: .continuous))
                    }
                    .buttonStyle(PressStyle())
                }
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
        let backLabel = L.t("chatHub.providers")
        let backTarget: Route = .providers

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
        .padding(.top, Ink.Space.m)
        .padding(.bottom, Ink.Space.s)
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
            .padding(.top, Ink.Space.s)
            .padding(.bottom, Ink.Space.m + Ink.Space.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }

    private var hairlineDivider: some View {
        Ink.rule.opacity(0.65)
            .frame(height: 0.5)
    }

    private func openModelPicker() {
        guard !isRoom && !isCasualTrack else { return }
        Haptics.light()
        navigatingForward = true
        route = .providers
    }

    private func openProvidersSettings() {
        Haptics.light()
        onDeferAction(.manageProviders)
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
    let historyInView: Bool
    let onDismissTyping: () -> Void
    let onHitRectChanged: ((Int, CGRect) -> Void)?

    @Binding var trackMode: ChatTrackMode
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
    private var isCasualTrack: Bool { (!isRoom && trackMode == .casual) || chat.key.hasPrefix("casual-") }
    private var working: Bool { team.workDetail(for: chat.key).words != nil || chat.hasStreaming }

    var body: some View {
        HStack(spacing: Ink.Space.xs) {
            ChatBrowserIndicator(browser: team.browser) {
                onDismissTyping()
                roaming = true
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("chatTopBar")) } action: { rect in
                onHitRectChanged?(3, rect)
            }
            headerMoreMenu
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("chatTopBar")) } action: { rect in
                    onHitRectChanged?(2, rect)
                }
        }
    }

    private var headerMoreMenu: some View {
        Menu {
            if isCasualTrack {
                Section {
                    Button {
                        onDismissTyping()
                        Haptics.light()
                        trackMode = .formal
                    } label: {
                        Label(L.t("casual.trackFormal"), systemImage: "bubble.left.and.text.bubble.right")
                    }
                    if !isRoom {
                        menuButton("chatHub.nameCard", icon: "person.text.rectangle") { cardOpen = true }
                    }
                }
            } else {
                Section {
                    if historyInView {
                        menuButton("chat.latest", icon: "arrow.down.to.line") {
                            onReturnToLatest()
                        }
                    }
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
                    let planOn = team.isPlanModeActive(for: chat.key)
                    Button {
                        Haptics.light()
                        team.setPlanMode(!planOn, in: chat.key)
                    } label: {
                        Label(
                            L.t(planOn ? "plan.exitMenu" : "plan.enterMenu"),
                            systemImage: planOn ? "map.fill" : "map"
                        )
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
                        onDismissTyping()
                        clearingChat = true
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: ChatBarMetrics.iconFontSize, weight: .medium))
                .foregroundStyle(Ink.ink)
                .frame(width: ChatBarMetrics.height, height: ChatBarMetrics.height)
                .frostedChatChrome(in: Circle())
                .contentShape(Circle())
        }
        .accessibilityLabel(L.t("chat.menu"))
    }

    private func menuButton(_ key: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(L.t(key), systemImage: icon) {
            onDismissTyping()
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
            CompanionAvatar(size: size, state: state, bot: isRoom ? nil : bot)
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
        CompanionAvatar(size: size, state: state, bot: isRoom ? nil : bot)
            .breathing(working, tint: Ink.accent)
    }
}
