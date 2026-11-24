import AgentKit
import Craft
import Observation
import SwiftUI
import UIKit

/// Unified scroll bridge allowing `ChatPage`, `ChatPage+Dock`, and `ChatPage+Finding`
/// to target either `ChatListUIKit` or the SwiftUI fallback `ScrollViewProxy`.
@MainActor
final class ChatScroller {
    private let swiftUIProxy: ScrollViewProxy?
    private weak var listProxy: ChatListControllerProxy?

    init(proxy: ScrollViewProxy) {
        self.swiftUIProxy = proxy
        self.listProxy = nil
    }

    init(listProxy: ChatListControllerProxy) {
        self.swiftUIProxy = nil
        self.listProxy = listProxy
    }

    func scrollTo(_ id: String, anchor: UnitPoint) {
        if let swiftUIProxy {
            swiftUIProxy.scrollTo(id, anchor: anchor)
        } else if let listProxy {
            let shouldAnimate: Bool
            if id == ChatPage.end {
                shouldAnimate = !listProxy.isNearBottom
            } else {
                shouldAnimate = anchor == .center
            }
            listProxy.scrollTo(id: id, anchor: anchor, animated: shouldAnimate)
        }
    }
}

/// Top-level observable model for hosted `Trace` cells (top-level avoids Xcode 26.3 nested `@Observable` traps).
@MainActor @Observable
final class TraceRowModel {
    var row: ChatListRowItem
    let actions: ChatListActions

    init(row: ChatListRowItem, actions: ChatListActions) {
        self.row = row
        self.actions = actions
    }
}

/// SwiftUI accessory view hosted inside `ChatTraceHostingCell` for expandable tool steps.
private struct ChatTraceHostView: View {
    let model: TraceRowModel
    let onHeightChanged: (CGFloat) -> Void

    private var row: ChatListRowItem { model.row }
    private var actions: ChatListActions { model.actions }

    var body: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            if row.faces, row.opens, let timeGap = row.timeGap {
                Text(timeGap)
                    .font(Ink.footnote)
                    .foregroundStyle(Ink.inkFaint)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, Ink.Space.xs)
            }
            if row.opens, row.faces || row.isRoom {
                HStack(spacing: Ink.Space.s) {
                    PetStill(
                        size: row.faces ? ChatPage.face : Ink.Size.body,
                        wash: row.speakerBot.map { Ink.wash(for: $0) },
                        avatar: true,
                        bot: row.speakerBot
                    )
                    Text(row.speakerTitle)
                        .font(.system(size: Ink.Size.small, weight: .semibold))
                        .foregroundStyle(Ink.inkSoft)
                }
                .accessibilityElement(children: .combine)
            }
            Trace(
                line: row.line,
                visit: { url in
                    actions.bridge.onOpenURL(url)
                },
                openFile: { url, mount in
                    actions.bridge.onOpenFile(url, mount)
                },
                unremember: { id, fact in
                    actions.team.unremember(id, fact: fact)
                }
            )
        }
        .padding(.horizontal, Ink.Space.page)
        .padding(.bottom, Ink.Space.m)
        .background {
            if row.lit {
                RoundedRectangle(cornerRadius: Ink.Radius.small, style: .continuous)
                    .fill(Ink.accentWash)
                    .padding(.horizontal, Ink.Space.page - Ink.Space.s)
                    .padding(.bottom, Ink.Space.xs)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            onHeightChanged(height)
        }
    }
}

/// Self-sizing `UICollectionViewCell` wrapping SwiftUI's interactive `Trace` drawer while keeping `@State` across live updates.
@MainActor
final class ChatTraceHostingCell: UICollectionViewCell {
    static let reuseID = "ChatTraceHostingCell"

    private var model: TraceRowModel?
    private var configuredLineID: String?
    private var onHeightChanged: ((CGFloat) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        row: ChatListRowItem,
        actions: ChatListActions,
        onHeightChanged: @escaping (CGFloat) -> Void
    ) {
        self.onHeightChanged = onHeightChanged
        if configuredLineID == row.line.id, let model {
            model.row = row
            return
        }
        configuredLineID = row.line.id
        let nextModel = TraceRowModel(row: row, actions: actions)
        model = nextModel
        contentConfiguration = UIHostingConfiguration {
            ChatTraceHostView(model: nextModel) { [weak self] height in
                self?.onHeightChanged?(height)
            }
        }
        .margins(.all, 0)
        .background(.clear)
    }

    func updateLineInPlace(_ row: ChatListRowItem) {
        model?.row = row
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onHeightChanged = nil
    }
}

/// Caches mapped `ChatListRowItem`s so 15Hz live token updates never rebuild unchanged settled rows.
@MainActor
final class ChatRowsMemo {
    private struct CacheKey: Equatable {
        let chatKey: String
        let rows: [ChatLine]
        let heads: Set<String>
        let lit: String?
        let freshWritingID: String?
        let freshShown: Int?
        let editing: String?
        let faces: Bool
        let isRoom: Bool
        let historyInView: Bool
        let defaultBot: BotInfo
        let teamBots: [BotInfo]
        let showThinking: Bool
        let showStats: Bool
        let working: Bool
        let sendingBlocked: Bool
        let speakingText: String?
        let latestBot: String?
        let latestNote: String?
        let lastLineID: String?
    }

    private var lastKey: CacheKey?
    private var lastItems: [ChatListRowItem] = []

    func buildRows(
        chat: ChatModel,
        displayedRows: [ChatLine],
        visibleRows: [ChatLine],
        heads: Set<String>,
        lit: String?,
        editing: String?,
        faces: Bool,
        isRoom: Bool,
        historyInView: Bool,
        defaultBot: BotInfo,
        teamBots: [BotInfo],
        showThinking: Bool,
        showStats: Bool,
        working: Bool,
        sendingBlocked: Bool,
        speakingText: String?,
        sourcesMemo: ChatPage.SourcesMemo,
        lineMeta: (ChatLine) -> ChatPage.SourcesMemo.LineMeta,
        endsTurn: (ChatLine) -> Bool,
        timeGap: (ChatLine) -> String?
    ) -> [ChatListRowItem] {
        sourcesMemo.sync(rows: displayedRows, defaultBotId: defaultBot.id)

        let freshWritingID = chat.freshWritingID
        let freshShown = freshWritingID != nil ? chat.stream.fresh?.shown : nil
        let latestBot: String?
        if !historyInView {
            latestBot = sourcesMemo.newestBotId
        } else {
            latestBot = displayedRows.last(where: { $0.kind == .bot })?.id
        }
        let latestNote = displayedRows.last(where: { $0.kind == .note })?.id
        let lastLineID = displayedRows.last?.id

        let key = CacheKey(
            chatKey: chat.key,
            rows: visibleRows,
            heads: heads,
            lit: lit,
            freshWritingID: freshWritingID,
            freshShown: freshShown,
            editing: editing,
            faces: faces,
            isRoom: isRoom,
            historyInView: historyInView,
            defaultBot: defaultBot,
            teamBots: teamBots,
            showThinking: showThinking,
            showStats: showStats,
            working: working,
            sendingBlocked: sendingBlocked,
            speakingText: speakingText,
            latestBot: latestBot,
            latestNote: latestNote,
            lastLineID: lastLineID
        )

        if let lastKey, lastKey == key {
            return lastItems
        }

        let firstRowId = displayedRows.first?.id
        let defaultBotName = defaultBot.name
        let stepLimitNotice = "（这件事步骤太多，我先停在这里。要我接着做就说一声。）"

        var result: [ChatListRowItem] = []
        result.reserveCapacity(visibleRows.count)

        for line in visibleRows {
            let isFirst = line.id == firstRowId
            let opens = heads.contains(line.id)
            let isFreshWriting = freshWritingID == line.id
            let isBot = line.kind == .bot
            let meta: ChatPage.SourcesMemo.LineMeta? = (isBot && !isFreshWriting) ? lineMeta(line) : nil
            let lookback: (note: String?, rest: String) = (isBot && !isFreshWriting)
                ? ChatPage.lookback(meta?.trimmedText ?? line.text)
                : (nil, "")
            let speakerBot = line.speaker.flatMap { id in teamBots.first { $0.id == id } } ?? (isRoom ? nil : defaultBot)
            let hitStepLimit = isBot
                && !isFreshWriting
                && !historyInView
                && !working
                && !sendingBlocked
                && lastLineID == line.id
                && line.text.trimmingCharacters(in: .whitespacesAndNewlines) == stepLimitNotice

            result.append(ChatListRowItem(
                line: line,
                opens: opens,
                lit: lit == line.id,
                isFirst: isFirst,
                isFreshWriting: isFreshWriting,
                freshShown: isFreshWriting ? freshShown : nil,
                isLatestBot: line.id == latestBot,
                isLatestNote: line.id == latestNote && line.id == lastLineID,
                isLastLine: line.id == lastLineID,
                endsTurn: isBot ? endsTurn(line) : false,
                timeGap: (faces && opens) ? timeGap(line) : nil,
                isEditing: editing == line.id,
                faces: faces,
                isRoom: isRoom,
                historyInView: historyInView,
                speakerBot: speakerBot,
                defaultBotName: defaultBotName,
                lineMeta: meta,
                lookbackNote: lookback.note,
                lookbackRest: lookback.rest,
                showThinking: showThinking,
                showStats: showStats,
                hitStepLimit: hitStepLimit,
                working: working,
                speakingText: speakingText
            ))
        }

        lastKey = key
        lastItems = result
        return result
    }
}

/// SwiftUI host embedding `ChatListViewController` edge-to-edge under `header` and `bottomStack`
/// while preserving safe-area alignment for `minimap` and automatic keyboard/dock inset tracking.
struct ChatUIKitContainer<Minimap: View>: View {
    let chat: ChatModel
    @ObservedObject var team: TeamModel
    let bot: BotInfo
    let isRoom: Bool
    let displayedRows: [ChatLine]
    let visibleRows: [ChatLine]
    let heads: Set<String>
    let historyPage: [ChatLine]?
    let shownCount: Int
    let lit: String?
    let editing: String?
    let speakingText: String?
    let headerHeight: CGFloat
    let starters: [(String, String, String)]
    let reach: String
    let petPerch: PetPerch
    let chrome: ChatChrome
    let viewport: ChatViewport
    let followState: ChatFollowState
    let dictationSlot: ChatDictationSlot
    let idleMood: ChatIdleMood
    let bridge: ChatRowBridge
    let sourcesMemo: ChatPage.SourcesMemo
    let listProxy: ChatListControllerProxy
    let typing: FocusState<Bool>.Binding
    @Binding var following: Bool
    @Binding var touchScrolling: Bool
    @Binding var quote: String?
    @Binding var jumpedTo: String?
    let onLoadEarlier: () -> Void
    let onSelectionChanged: (UUID, Bool) -> Void
    let onSpeak: (String) -> Void
    let onSaveNote: (String, String) -> Void
    let onPickStarter: (String) -> Void
    let onStir: () -> Void
    let onDragStarted: () -> Void
    let onScrollEnded: () -> Void
    let lineMeta: (ChatLine) -> ChatPage.SourcesMemo.LineMeta
    let endsTurn: (ChatLine) -> Bool
    let timeGap: (ChatLine) -> String?
    @ViewBuilder let minimap: () -> Minimap

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @AppStorage("chat.faces") private var faces = false
    @AppStorage("look.thinking") private var showThinking = true
    @AppStorage("look.stats") private var showStats = true

    @State private var fullFrame: CGRect = .zero
    @State private var safeFrame: CGRect = .zero
    @State private var rowsMemo = ChatRowsMemo()

    private var safeTopInset: CGFloat {
        guard fullFrame.height > 0, safeFrame.height > 0 else { return 0 }
        return max(0, safeFrame.minY - fullFrame.minY)
    }

    private var safeBottomInset: CGFloat {
        guard fullFrame.height > 0, safeFrame.height > 0 else { return 0 }
        return max(0, fullFrame.maxY - safeFrame.maxY)
    }

    private var styleSignal: String {
        let theme = Theme.shared
        let scale = UIScale.shared.value
        let fontGen = FontShelf.shared.generation
        let darkFlag = colorScheme == .dark ? 1 : 0
        let motionFlag = reduceMotion ? 1 : 0
        return "\(theme.key)|\(theme.face.rawValue)|\(theme.code.rawValue)|\(theme.size)|\(theme.lineHeight)|\(theme.white)|\(theme.oled)|\(theme.bubble)|\(theme.fontsArrived)|\(scale)|\(fontGen)|\(darkFlag)|\(motionFlag)|\(dynamicTypeSize)"
    }

    private var doing: String? {
        team.workDetail(for: chat.key).words
    }

    private var working: Bool {
        doing != nil || chat.hasStreaming
    }

    private var sendingBlocked: Bool {
        team.phase != .demo && !team.canAcceptInput(for: chat.key)
    }

    private var waiting: Approval? {
        team.approvals.first { $0.chat == chat.key }
    }

    var body: some View {
        let state = makeListState()
        ZStack {
            ChatListUIKitRepresentable(
                state: state,
                styleSignal: styleSignal,
                safeTopInset: safeTopInset,
                safeBottomInset: safeBottomInset,
                following: $following,
                touchScrolling: $touchScrolling,
                quote: $quote,
                jumpedTo: $jumpedTo,
                chrome: chrome,
                viewport: viewport,
                petPerch: petPerch,
                chat: chat,
                team: team,
                bridge: bridge,
                dictationSlot: dictationSlot,
                idleMood: idleMood,
                listProxy: listProxy,
                typing: typing,
                onLoadEarlier: onLoadEarlier,
                onSelectionChanged: onSelectionChanged,
                onSpeak: onSpeak,
                onSaveNote: onSaveNote,
                onPickStarter: onPickStarter,
                onStir: onStir,
                onDragStarted: onDragStarted,
                onScrollEnded: onScrollEnded,
                makeEmptyView: { makeEmptyStatusAnyView() }
            )
            .ignoresSafeArea()
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rect in
                fullFrame = rect
            }

            Color.clear
                .allowsHitTesting(false)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rect in
                    safeFrame = rect
                }
                .overlay(alignment: .trailing) { minimap() }
        }
        .onChange(of: followState.following, initial: true) { _, resting in
            petPerch.avoidsReplies = resting
        }
    }

    private func makeEmptyStatusAnyView() -> AnyView {
        AnyView(
            ChatEmptyStatusView(chat: chat) {
                ChatEmptyContentView(
                    chat: chat,
                    team: team,
                    bot: bot,
                    dictationSlot: dictationSlot,
                    idleMood: idleMood,
                    starters: starters,
                    reach: reach,
                    typing: typing,
                    onPickStarter: onPickStarter
                )
            }
        )
    }

    private func makeListState() -> ChatListState {
        let rows = rowsMemo.buildRows(
            chat: chat,
            displayedRows: displayedRows,
            visibleRows: visibleRows,
            heads: heads,
            lit: lit,
            editing: editing,
            faces: faces,
            isRoom: isRoom,
            historyInView: historyPage != nil,
            defaultBot: bot,
            teamBots: team.bots,
            showThinking: showThinking,
            showStats: showStats,
            working: working,
            sendingBlocked: sendingBlocked,
            speakingText: speakingText,
            sourcesMemo: sourcesMemo,
            lineMeta: lineMeta,
            endsTurn: endsTurn,
            timeGap: timeGap
        )

        let showToolTail: Bool = {
            guard let activeDoing = doing,
                  activeDoing.contains("："),
                  let kind = Trace.canonicalKind(of: activeDoing) else {
                return false
            }
            return kind == "斗室" || kind == "远山"
        }()

        let failureCardError: String? = {
            guard let error = chat.error else { return nil }
            if let last = chat.lines.last,
               last.kind == .note,
               let firstLine = error.split(separator: "\n").first,
               last.text.contains(firstLine) {
                return nil
            }
            return error
        }()

        let emptyPetState = ChatPage.companionPetState(
            waiting: waiting,
            hasStreaming: chat.hasStreaming,
            doing: doing,
            working: working,
            typing: typing.wrappedValue,
            listening: dictationSlot.instance?.listening == true,
            cheering: idleMood.cheering,
            dozing: idleMood.dozing
        )

        let pulseSpeaker = chat.stream.pulseSpeaker.flatMap { id in
            team.bots.first { $0.id == id }
        }

        let canLoadEarlier = historyPage == nil && (displayedRows.count > shownCount || chat.hasEarlier)

        return ChatListState(
            chatKey: chat.key,
            loaded: chat.loaded,
            canLoadEarlier: canLoadEarlier,
            historyInView: historyPage != nil,
            isRoom: isRoom,
            defaultBot: bot,
            teamBots: team.bots,
            working: working,
            sendingBlocked: sendingBlocked,
            faces: faces,
            rows: rows,
            isCompressing: team.compressing.contains(chat.key),
            streamPulse: chat.stream.pulse,
            streamPulseSpeaker: pulseSpeaker,
            streamReasoning: chat.stream.reasoning,
            streamText: chat.stream.text,
            streamGeneration: chat.stream.generation,
            hasStreaming: chat.hasStreaming,
            fresh: chat.stream.fresh,
            showToolTail: showToolTail,
            failureCardError: failureCardError,
            queuedItems: team.queued[chat.key] ?? [],
            emptyPetState: emptyPetState,
            starters: starters,
            reach: reach,
            headerHeight: headerHeight,
            reduceMotion: reduceMotion
        )
    }
}

/// UIKit representable wrapping `ChatListViewController` with loop-free bidirectional state binding.
private struct ChatListUIKitRepresentable: UIViewControllerRepresentable {
    let state: ChatListState
    let styleSignal: String
    let safeTopInset: CGFloat
    let safeBottomInset: CGFloat
    @Binding var following: Bool
    @Binding var touchScrolling: Bool
    @Binding var quote: String?
    @Binding var jumpedTo: String?
    let chrome: ChatChrome
    let viewport: ChatViewport
    let petPerch: PetPerch
    let chat: ChatModel
    let team: TeamModel
    let bridge: ChatRowBridge
    let dictationSlot: ChatDictationSlot
    let idleMood: ChatIdleMood
    let listProxy: ChatListControllerProxy
    let typing: FocusState<Bool>.Binding
    let onLoadEarlier: () -> Void
    let onSelectionChanged: (UUID, Bool) -> Void
    let onSpeak: (String) -> Void
    let onSaveNote: (String, String) -> Void
    let onPickStarter: (String) -> Void
    let onStir: () -> Void
    let onDragStarted: () -> Void
    let onScrollEnded: () -> Void
    let makeEmptyView: () -> AnyView

    func makeCoordinator() -> Coordinator {
        Coordinator(lastStyleSignal: styleSignal, lastSyncedFollowing: following)
    }

    func makeUIViewController(context: Context) -> ChatListViewController {
        let actions = ChatListActions(
            chat: chat,
            team: team,
            bridge: bridge,
            dictationSlot: dictationSlot,
            idleMood: idleMood,
            petPerch: petPerch
        )
        wireActions(actions, coordinator: context.coordinator)

        let controller = ChatListViewController(actions: actions)
        controller.makeEmptyView = makeEmptyView
        listProxy.controller = controller
        context.coordinator.actions = actions
        controller.setHostSafeInsets(top: safeTopInset, bottom: safeBottomInset)
        controller.applyState(state)
        return controller
    }

    func updateUIViewController(_ uiViewController: ChatListViewController, context: Context) {
        let coordinator = context.coordinator
        if let actions = coordinator.actions {
            wireActions(actions, coordinator: coordinator)
        }
        uiViewController.makeEmptyView = makeEmptyView
        listProxy.controller = uiViewController

        if coordinator.lastStyleSignal != styleSignal {
            coordinator.lastStyleSignal = styleSignal
            uiViewController.refreshTypographyAndTheme()
        }

        uiViewController.setHostSafeInsets(top: safeTopInset, bottom: safeBottomInset)

        if coordinator.lastSyncedFollowing != following {
            coordinator.lastSyncedFollowing = following
            uiViewController.setFollowingFromHost(following)
        }

        uiViewController.applyState(state)
    }

    private func wireActions(_ actions: ChatListActions, coordinator: Coordinator) {
        actions.onLoadEarlier = onLoadEarlier

        actions.onQuoteExcerpt = { [typing] excerpt in
            Haptics.tick(0.5)
            withAnimation(Ink.Motion.settle) {
                quote = excerpt
            }
            typing.wrappedValue = true
        }

        actions.onSpeakExcerpt = { excerpt in
            Haptics.light()
            onSpeak(excerpt)
        }

        actions.onSaveNoteExcerpt = { lineID, excerpt in
            onSaveNote(lineID, excerpt)
        }

        actions.onSelectionChanged = onSelectionChanged

        actions.onFollowingChanged = { [weak coordinator] next in
            coordinator?.lastSyncedFollowing = next
            if following != next {
                following = next
            }
        }

        actions.onTouchScrollingChanged = { isTouching, isTouchScroll in
            if viewport.isTouching != isTouching {
                viewport.isTouching = isTouching
            }
            if touchScrolling != isTouchScroll {
                touchScrolling = isTouchScroll
            }
        }

        actions.onScrollingChanged = { moving in
            if moving != chrome.scrolling {
                chrome.scrolling = moving
                onStir()
                Hitches.shared.doing(moving ? Words.t("滚动絮语") : nil, as: "scroll")
            }
        }

        actions.onFarFromEndChanged = { far in
            if chrome.farFromEnd != far {
                withAnimation(Ink.Motion.settle) {
                    chrome.farFromEnd = far
                }
            }
        }

        actions.onVisibleIDsChanged = { ids in
            if viewport.ids != ids {
                viewport.ids = ids
            }
        }

        actions.onScrollPhaseChanged = { label in
            if viewport.scrollPhaseLabel != label {
                viewport.scrollPhaseLabel = label
            }
        }

        actions.onDragStarted = {
            onDragStarted()
        }

        actions.onScrollEnded = {
            onScrollEnded()
        }

        actions.onPickStarter = onPickStarter
    }

    @MainActor
    final class Coordinator {
        var lastStyleSignal: String
        var lastSyncedFollowing: Bool
        var actions: ChatListActions?

        init(lastStyleSignal: String, lastSyncedFollowing: Bool) {
            self.lastStyleSignal = lastStyleSignal
            self.lastSyncedFollowing = lastSyncedFollowing
        }
    }
}
