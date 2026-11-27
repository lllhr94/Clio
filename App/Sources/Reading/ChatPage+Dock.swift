import AVFoundation
import AgentKit
import CoreLocation
import Craft
import ImageIO
import PhotosUI
import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import VisionKit

extension ChatPage {
    // MARK: Dock: the cards above the composer

    /// The cards that can sit above the composer, the most pressing first.
    enum DockCard: Hashable { case waiting, roam, working, away }

    var dockCards: [DockCard] {
        Self.dockCards(
            team: team,
            chatKey: chat.key,
            waiting: waiting,
            working: working,
            liveWords: liveWords,
            awayItems: awayState.items,
            hasStreaming: chat.hasStreaming,
            following: followState.following
        )
    }

    static func dockCards(
        team: TeamModel,
        chatKey: String,
        waiting: Approval?,
        working: Bool,
        liveWords: String?,
        awayItems: [Happening],
        hasStreaming: Bool = false,
        following: Bool = true
    ) -> [DockCard] {
        var cards: [DockCard] = []
        if waiting != nil { cards.append(.waiting) }
        // Only the conversation that asked for the takeover shows it.
        if team.browser.handoff != nil, team.browser.handoffChat == nil || team.browser.handoffChat == chatKey { cards.append(.roam) }
        let hideStreamingBar = hasStreaming && following && waiting == nil
        if working, waiting == nil, liveWords != nil, !hideStreamingBar { cards.append(.working) }
        if !awayItems.isEmpty, waiting == nil { cards.append(.away) }
        return cards
    }

    var dock: some View {
        ChatDockAreaView(
            chat: chat,
            team: team,
            bot: bot,
            awayState: awayState,
            workTimer: workTimer,
            calmPetMotion: calmPetMotion,
            dockOpen: $dockOpen,
            typing: $typing,
            roaming: $roaming,
            followState: followState,
            onPresentApproval: { approval in presentApproval(approval) },
            onToEnd: { toEnd() }
        )
    }

    var draftField: some View {
        ChatDraftFieldView(
            draftState: draftState,
            chat: chat,
            team: team,
            dictationSlot: dictationSlot,
            botName: bot.name,
            largeText: largeText,
            typing: $typing,
            onPasteChange: { old, new in keepLongPaste(old, new) }
        )
    }

    var composer: some View {
        ChatSection { composerContents }
    }

    var composerContents: some View {
        ChatComposerBarView(
            chat: chat,
            team: team,
            bot: bot,
            chrome: chrome,
            petPerch: petPerch,
            dictationSlot: dictationSlot,
            draftState: draftState,
            followState: followState,
            notice: notice,
            awayState: awayState,
            contextMetrics: contextMetrics,
            workTimer: workTimer,
            historyInView: historyPage != nil,
            largeText: largeText,
            confirmStop: confirmStop,
            calmPetMotion: calmPetMotion,
            viewportMetrics: viewportMetrics,
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
            editing: $editing,
            quote: $quote,
            photos: $photos,
            files: $files,
            onPresentApproval: { approval in presentApproval(approval) },
            onToEnd: { toEnd() },
            onReturnToLatest: returnToLatest,
            onClearComposer: clearComposer,
            onListen: listen,
            onRedoFrom: { entry, text in redo(from: entry, text: text) },
            onPasteChange: { old, new in keepLongPaste(old, new) },
            onReceiveURLs: { urls in receive(urls) },
            fileNote: { fileNote },
            outgoingText: { outgoing }
        )
    }

    var minimap: some View {
        ChatMinimapOverlay(
            chrome: chrome,
            viewport: viewport,
            chat: chat,
            historyPage: historyPage,
            shownCount: shownCount,
            onCancelHide: { hideJumps?.cancel() },
            onJump: { id, animated, label in jump(to: id, animated: animated, source: label) },
            onStepQuestion: { earlier in stepQuestion(earlier: earlier) },
            onPrewarm: { id in scroller?.prewarm(id) }
        )
    }

    func scheduleJumpSettle(to id: String, source: String, delayMs: Int) {
        let generation = viewport.navigationGeneration
        settleJump?.cancel()
        settleJump = Task { @MainActor in
            defer { if !Task.isCancelled { settleJump = nil } }
            do { try await Task.sleep(for: .milliseconds(delayMs)) } catch { return }
            guard !Task.isCancelled,
                  generation == viewport.navigationGeneration,
                  !touchScrolling, !viewport.isTouching, !following, historyPage == nil,
                  selecting.isEmpty, !viewport.ids.contains(id) else { return }
            viewport.recordJump("\(source)落位")
            scroller?.scrollTo(id, anchor: .top)
        }
    }

    func jump(to id: String, animated: Bool = true, source: String = "小地图") {
        Haptics.tick(0.4)
        chromeCoordinator.markProgrammaticScroll()
        following = false
        jumpedTo = id
        lingerJumpButtons()
        viewport.recordJump(source)
        // From the 小地图 the page goes straight there: a long animated scroll through a lazy list lags behind.
        if animated {
            withAnimation(Ink.Motion.settle) { scroller?.scrollTo(id, anchor: .top) }
        } else {
            scroller?.scrollTo(id, anchor: .top)
        }
        scheduleJumpSettle(to: id, source: source, delayMs: animated ? 380 : 120)
    }

    func lingerJumpButtons() {
        hideJumps?.cancel()
        hideJumps = Task {
            do { try await Task.sleep(for: .milliseconds(1400)) } catch { return }
            if chrome.jumpVisible {
                DiagTrail.record("隐藏跳转钮")
                chrome.jumpVisible = false
            }
        }
    }

    func stepQuestion(earlier: Bool) {
        guard let target = question(earlier: earlier) else { return }
        let label = earlier ? "点了上一句" : "点了下一句"
        Haptics.light()
        chromeCoordinator.markProgrammaticScroll()
        following = false
        jumpedTo = target
        lingerJumpButtons()
        viewport.recordJump(label)
        withAnimation(Ink.Motion.settle) { scroller?.scrollTo(target, anchor: .top) }
        scheduleJumpSettle(to: target, source: label, delayMs: 380)
    }

    func question(earlier: Bool) -> String? {
        let rows = historyPage.map { $0[...] } ?? chat.lines.suffix(shownCount)
        let visible = Set(viewport.ids)
        let center = jumpedTo.flatMap { id in rows.firstIndex { $0.id == id } }
            ?? rows.firstIndex { visible.contains($0.id) }
        guard let center else { return earlier ? rows.last(where: { $0.kind == .user })?.id : nil }
        if earlier { return rows[..<center].last(where: { $0.kind == .user })?.id }
        let after = rows.index(after: center)
        return rows[after...].first(where: { $0.kind == .user })?.id
    }

    func returnToLatest() {
        Haptics.light()
        chromeCoordinator.restore()
        chromeCoordinator.markProgrammaticScroll(duration: 0.35)
        settleJump?.cancel()
        viewport.recordJump("回到最新")
        following = true
        jumpedTo = nil
        if historyPage == nil {
            toEnd(animated: true)
        } else {
            historyPage = nil
            followToEnd()
        }
    }

    static let end = "foot-of-page"

    static func resizeAnchor(following: Bool, inHistory: Bool, hasSelection: Bool) -> UnitPoint? {
        following && !inHistory && !hasSelection ? .bottom : nil
    }

    /// Distance to the resting bottom offset. A short page rests at its top inset.
    static func below(_ geometry: ScrollGeometry) -> CGFloat {
        let bottom = max(-geometry.contentInsets.top,
                         geometry.contentSize.height + geometry.contentInsets.bottom - geometry.containerSize.height)
        return bottom - geometry.contentOffset.y
    }

    /// Observe further drift without scheduling scrolls for every point of movement.
    static func endAlignment(_ geometry: ScrollGeometry) -> CGFloat {
        let distance = below(geometry)
        return abs(distance) <= 2 ? 0 : (distance / 16).rounded(.awayFromZero)
    }

    func endAlignmentChanged(_ alignment: CGFloat) {
        viewport.needsEndCorrection = alignment != 0
        if viewport.needsEndCorrection, followPending?.isCancelled != false { followToEnd(settle: false) }
    }

    func presentApproval(_ approval: Approval) {
        DiagTrail.record("开审批详情")
        followPending?.cancel()
        settleEnd?.cancel()
        settleJump?.cancel()
        viewport.advanceNavigation()
        setComposerFocused(false)
        approving = approval
    }

    func approvalInsetChanged() {
        followPending?.cancel()
        settleEnd?.cancel()
        approvalInsetTask?.cancel()
        let capturedEpoch = listProxy.currentInteractionEpoch
        approvalInsetTask = Task { @MainActor in
            // The system anchor follows the animated dock. Recheck only after it settles.
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            approvalInsetTask = nil
            if useUIKitChatList {
                listProxy.requestApprovalCardSettle(capturedEpoch: capturedEpoch)
            } else {
                followToEnd(settle: false)
            }
        }
    }

    func selectionChanged(_ id: UUID, _ started: Bool) {
        if started {
            if selecting.isEmpty { DiagTrail.record("开始选字") }
            selecting.insert(id)
            followPending?.cancel()
            settleJump?.cancel()
            viewport.advanceNavigation()
        } else if selecting.remove(id) != nil, selecting.isEmpty {
            DiagTrail.record("结束选字")
            if viewport.needsEndCorrection {
                followToEnd(settle: false)
            }
        }
    }

    /// Coalesce layout changes from the composer and a newly inserted row before moving the viewport.
    func followToEnd(settle: Bool = true) {
        guard historyPage == nil, following, !touchScrolling, selecting.isEmpty,
              approving == nil, approvalInsetTask == nil else { return }
        followPending?.cancel()
        followPending = Task { @MainActor in
            defer { if !Task.isCancelled { followPending = nil } }
            do { try await Task.sleep(for: .milliseconds(settle ? 32 : 16)) } catch { return }
            guard following, !touchScrolling, historyPage == nil, selecting.isEmpty,
                  approving == nil, approvalInsetTask == nil, viewport.needsEndCorrection else { return }
            toEnd()
        }
    }


    func toEnd(animated: Bool = false) {
        guard historyPage == nil, selecting.isEmpty, let scroller else { return }
        chromeCoordinator.markProgrammaticScroll(duration: animated ? 0.45 : 0.16)
        settleJump?.cancel()
        viewport.advanceNavigation()
        if animated {
            withAnimation(Ink.Motion.settle) { scroller.scrollTo(Self.end, anchor: .bottom) }
        } else {
            scroller.scrollTo(Self.end, anchor: .bottom)
        }
        // The first jump goes by guessed heights of rows not drawn yet; once they are drawn the foot may sit elsewhere.
        // Correct once if the real foot still differs after those rows have been drawn.
        settleEnd?.cancel()
        settleEnd = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(animated ? 420 : 120)) } catch { return }
            guard following, !touchScrolling, historyPage == nil, selecting.isEmpty,
                  approving == nil, approvalInsetTask == nil, viewport.needsEndCorrection else { return }
            scroller.scrollTo(Self.end, anchor: .bottom)
        }
    }



    /// Writing something: the row of chips shows under the text field.
    var composing: Bool {
        let listening = dictationSlot.instance?.listening == true
        let transcribing = dictationSlot.instance?.transcribing == true
        return isComposerFocused || draftState.hasText || !photos.isEmpty || !files.isEmpty || editing != nil || quote != nil || listening || transcribing
    }

    var sendingBlocked: Bool {
        team.phase != .demo && !team.canAcceptInput(for: chat.key)
    }

    var canSend: Bool {
        draftState.hasSendableText || !photos.isEmpty || !files.isEmpty
    }

    var action: some View {
        ChatActionButtonView(
            chat: chat,
            team: team,
            dictationSlot: dictationSlot,
            draftState: draftState,
            confirmStop: confirmStop,
            askingStop: $askingStop,
            editing: $editing,
            quote: $quote,
            photos: photos,
            files: files,
            fileNote: { fileNote },
            outgoingText: { outgoing },
            onListen: listen,
            onClearComposer: clearComposer,
            onRedoFrom: { entry, text in redo(from: entry, text: text) }
        )
    }
}

/// Bottom safe-area container hosting the floating pet perch, optional inline form, and either the find bar or composer.
struct ChatBottomStackView<FindBar: View>: View {
    let chat: ChatModel
    let team: TeamModel
    let bot: BotInfo
    let chrome: ChatChrome
    let chromeCoordinator: ChatChromeCoordinator
    let petPerch: PetPerch
    let asker: Asker
    let dictationSlot: ChatDictationSlot
    let draftState: ChatDraft
    let followState: ChatFollowState
    let idleMood: ChatIdleMood
    let notice: ChatComposerNotice
    let awayState: ChatAwayState
    let contextMetrics: ChatContextMetrics
    let workTimer: ChatWorkTimer

    let finding: Bool
    let historyInView: Bool
    let largeText: Bool
    let confirmStop: Bool
    let calmPetMotion: Bool
    let viewportMetrics: ChatViewportMetrics
    var effectiveBottomOcclusion: CGFloat = 0
    var hostViewportHeight: CGFloat = 0
    var topBarHeight: CGFloat = 0
    let coveredByPage: Bool
    let baseSheetOpen: Bool
    let typing: FocusState<Bool>.Binding

    @Binding var usageOpen: Bool
    @Binding var pickerShown: Bool
    @Binding var importingFile: Bool
    @Binding var picks: [PhotosPickerItem]
    @Binding var attaching: Bool
    @Binding var dockOpen: Bool
    @Binding var askingStop: Bool
    @Binding var detailOpen: Bool
    @Binding var roaming: Bool
    @Binding var petSettingsOpen: Bool
    @Binding var editing: String?
    @Binding var quote: String?
    @Binding var photos: [Data]
    @Binding var files: [String]

    let onPresentApproval: (Approval) -> Void
    var onResignFocusForSheet: (() -> Void)? = nil
    let onToEnd: () -> Void
    let onReturnToLatest: () -> Void
    let onClearComposer: () -> Void
    let onListen: () -> Void
    let onRedoFrom: (String, String) -> Bool
    let onPasteChange: (String, String) -> Void
    let onReceiveURLs: ([URL]) -> Void
    let fileNote: () -> String
    let outgoingText: () -> String
    @ViewBuilder let findBar: () -> FindBar

    private var isRoom: Bool { chat.roomId != nil }
    private var petDockMotion: Animation {
        calmPetMotion ? .easeInOut(duration: 0.22) : Ink.Motion.unfold
    }

    private var estimatedComposerHeight: CGFloat {
        var h = ChatBarMetrics.height + 16 * UIScale.factor
        if !photos.isEmpty { h += 64 }
        if !files.isEmpty { h += 38 }
        if quote != nil || editing != nil { h += 34 }
        return h
    }

    private var sharedCardBudget: ChatDockCardBudget.Allocation {
        let viewportH = hostViewportHeight > 0 ? hostViewportHeight : viewportMetrics.size.height
        let waiting = team.approvals.first { $0.chat == chat.key }
        let canInlineApproval = waiting.map {
            InlineApprovalPolicy.canAnswer(
                answerable: $0.answerable != false,
                forced: $0.forced == true,
                tool: $0.toolName,
                hasCode: $0.detail?.code?.isEmpty == false
            )
        } ?? false
        let hasInlineAsk: Bool = {
            guard let current = asker.current, current.inline,
                  current.chat == nil || current.chat == chat.key else { return false }
            return team.isWorking(chat.key)
        }()
        let hasPlan = team.plans[chat.key] != nil
        return ChatDockCardBudget.allocate(ChatDockCardBudget.Input(
            viewportHeight: viewportH,
            effectiveBottomOcclusion: effectiveBottomOcclusion,
            topBarHeight: max(topBarHeight, ChatBarMetrics.height),
            composerHeight: estimatedComposerHeight,
            minProseReadableHeight: 120,
            hasPendingApproval: waiting != nil,
            canInlineApproval: canInlineApproval,
            hasInlineAsk: hasInlineAsk,
            hasPlanCard: hasPlan
        ))
    }

    var body: some View {
        let p = chromeCoordinator.visualProgress
        let fabAlpha = max(0, min(1, (Double(p) - 0.45) / 0.55))
        let budget = sharedCardBudget
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                PetPerchSpace(face: nil, viewport: viewportMetrics.size)
                VStack(spacing: 0) {
                    ChatDockedFormSlot(
                        chatKey: chat.key,
                        viewportMetrics: viewportMetrics,
                        calmPetMotion: calmPetMotion,
                        askLayout: budget.inlineAsk,
                        onResignFocusForSheet: {
                            typing.wrappedValue = false
                            onResignFocusForSheet?()
                        },
                        team: team,
                        asker: asker
                    )
                    if finding {
                        findBar()
                    } else {
                        ChatComposerBarView(
                            chat: chat,
                            team: team,
                            bot: bot,
                            chrome: chrome,
                            petPerch: petPerch,
                            dictationSlot: dictationSlot,
                            draftState: draftState,
                            followState: followState,
                            notice: notice,
                            awayState: awayState,
                            contextMetrics: contextMetrics,
                            workTimer: workTimer,
                            historyInView: historyInView,
                            largeText: largeText,
                            confirmStop: confirmStop,
                            calmPetMotion: calmPetMotion,
                            viewportMetrics: viewportMetrics,
                            cardBudget: budget,
                            typing: typing,
                            usageOpen: $usageOpen,
                            pickerShown: $pickerShown,
                            importingFile: $importingFile,
                            picks: $picks,
                            attaching: $attaching,
                            dockOpen: $dockOpen,
                            askingStop: $askingStop,
                            detailOpen: $detailOpen,
                            roaming: $roaming,
                            editing: $editing,
                            quote: $quote,
                            photos: $photos,
                            files: $files,
                            onPresentApproval: onPresentApproval,
                            onToEnd: onToEnd,
                            onReturnToLatest: onReturnToLatest,
                            onClearComposer: onClearComposer,
                            onListen: onListen,
                            onRedoFrom: onRedoFrom,
                            onPasteChange: onPasteChange,
                            onReceiveURLs: onReceiveURLs,
                            fileNote: fileNote,
                            outgoingText: outgoingText
                        )
                    }
                }
                .overlay(alignment: .top) {
                    ChatDockedJumpOverlaySlot(
                        chatKey: chat.key,
                        team: team,
                        asker: asker,
                        chrome: chrome,
                        petPerch: petPerch,
                        inHistory: historyInView,
                        followState: followState,
                        onLatest: onReturnToLatest
                    )
                }
                .background(alignment: .top) {
                    ChatPetPerchAnchorView(
                        chat: chat,
                        team: team,
                        asker: asker,
                        dictationSlot: dictationSlot,
                        petPerch: petPerch,
                        face: nil,
                        baseSheetOpen: baseSheetOpen,
                        coveredByPage: coveredByPage,
                        quiet: p > 0.15,
                        onOpenSettings: { petSettingsOpen = true }
                    )
                }
            }
            .offset(y: calmPetMotion ? 0 : 96 * p)
            .opacity(max(0, 1 - Double(p) * 1.18))
            .allowsHitTesting(p < 0.5)
            .accessibilityHidden(p >= 0.5)

            ChatImmersiveBottomBar(
                chat: chat,
                team: team,
                chrome: chrome,
                confirmStop: confirmStop,
                askingStop: $askingStop,
                onRestore: { chromeCoordinator.restore() },
                onLatest: onReturnToLatest
            )
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, Ink.Space.page)
            .padding(.bottom, 8 * ChatBarMetrics.scale)
            .opacity(fabAlpha)
            .offset(y: calmPetMotion ? 0 : CGFloat(1 - fabAlpha) * 12)
            .scaleEffect(calmPetMotion ? 1 : CGFloat(0.88 + 0.12 * fabAlpha))
            .allowsHitTesting(p >= 0.5)
            .accessibilityHidden(p < 0.5)
        }
        .animation(petDockMotion, value: finding)
        .confirmationDialog(L.t("chat.stopAsk"), isPresented: $askingStop, titleVisibility: .visible) {
            Button(L.t("chat.stopNow"), role: .destructive) {
                Haptics.lock()
                if team.workDetail(for: chat.key).words != nil || chat.hasStreaming {
                    chat.stop()
                }
            }
            Button(L.t("actions.cancel"), role: .cancel) {}
        } message: {
            Text(L.t("chat.stopAskNote"))
        }
    }
}

private struct ChatDockedFormSlot: View {
    let chatKey: String
    let viewportMetrics: ChatViewportMetrics
    let calmPetMotion: Bool
    var askLayout: ChatDockCardBudget.InlineAskLayout = .none
    var onResignFocusForSheet: (() -> Void)? = nil
    @ObservedObject var team: TeamModel
    @ObservedObject var asker: Asker

    private var form: Asker.Form? {
        guard let current = asker.current, current.inline,
              current.chat == nil || current.chat == chatKey,
              team.isWorking(chatKey) else { return nil }
        return current
    }

    private var petDockMotion: Animation {
        calmPetMotion ? .easeInOut(duration: 0.22) : Ink.Motion.unfold
    }

    private func expandToDetailSheet(_ form: Asker.Form) {
        onResignFocusForSheet?()
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        Asker.shared.requestDetailSheet(form.id)
    }

    var body: some View {
        Group {
            if let form {
                switch askLayout {
                case .compactSummaryWithSheetFallback:
                    InlineAskCompactSummaryBar(form: form) {
                        expandToDetailSheet(form)
                    }
                    .id(form.id)
                    .padding(.horizontal, Ink.Bar.edge)
                    .padding(.bottom, Ink.Space.s)
                    .transition(.opacity)
                case .inline(let maxHeight):
                    PetDockSlip(availableHeight: viewportMetrics.size.height, explicitMaxHeight: maxHeight) {
                        InlineAsk(form: form) {
                            expandToDetailSheet(form)
                        }
                        .id(form.id)
                    }
                    .padding(.horizontal, Ink.Bar.edge)
                    .padding(.bottom, Ink.Space.s)
                    .transition(.opacity)
                case .none:
                    PetDockSlip(availableHeight: viewportMetrics.size.height) {
                        InlineAsk(form: form) {
                            expandToDetailSheet(form)
                        }
                        .id(form.id)
                    }
                    .padding(.horizontal, Ink.Bar.edge)
                    .padding(.bottom, Ink.Space.s)
                    .transition(.opacity)
                }
            }
        }
        .animation(petDockMotion, value: form?.id)
    }
}

private struct ChatPetPerchAnchorView: View {
    let chat: ChatModel
    @ObservedObject var team: TeamModel
    @ObservedObject var asker: Asker
    let dictationSlot: ChatDictationSlot
    let petPerch: PetPerch
    let face: String?
    let baseSheetOpen: Bool
    let coveredByPage: Bool
    let quiet: Bool
    let onOpenSettings: () -> Void

    private var doing: String? { team.workDetail(for: chat.key).words }
    private var working: Bool { doing != nil || chat.hasStreaming }
    private var waiting: Approval? { team.approvals.first { $0.chat == chat.key } }

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

    var body: some View {
        let showingSheet = baseSheetOpen || (asker.current.map { !$0.inline } ?? false)
        if let dictation = dictationSlot.instance {
            ChatActivePetPerchAnchorView(
                dictation: dictation,
                perch: petPerch,
                mood: petMood,
                face: face,
                showingSheet: showingSheet,
                coveredByPage: coveredByPage,
                quiet: quiet,
                onOpenSettings: onOpenSettings
            )
        } else {
            PetPerchAnchor(
                perch: petPerch,
                mood: petMood,
                face: face,
                showingSheet: showingSheet,
                covered: coveredByPage,
                quiet: quiet,
                enabled: PetLibrary.shared.visible,
                openSettings: onOpenSettings
            )
            .frame(height: 1)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { _ in petPerch.layoutChanged() }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

private struct ChatActivePetPerchAnchorView: View {
    @ObservedObject var dictation: Dictation
    let perch: PetPerch
    let mood: PetMood
    let face: String?
    let showingSheet: Bool
    let coveredByPage: Bool
    let quiet: Bool
    let onOpenSettings: () -> Void

    var body: some View {
        PetPerchAnchor(
            perch: perch,
            mood: mood,
            face: face,
            showingSheet: showingSheet,
            covered: coveredByPage,
            quiet: quiet || dictation.listening,
            enabled: PetLibrary.shared.visible,
            openSettings: onOpenSettings
        )
        .frame(height: 1)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { _ in perch.layoutChanged() }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct ChatComposerBarView: View {
    let chat: ChatModel
    let team: TeamModel
    let bot: BotInfo
    let chrome: ChatChrome
    let petPerch: PetPerch
    let dictationSlot: ChatDictationSlot
    let draftState: ChatDraft
    let followState: ChatFollowState
    let notice: ChatComposerNotice
    let awayState: ChatAwayState
    let contextMetrics: ChatContextMetrics
    let workTimer: ChatWorkTimer

    let historyInView: Bool
    let largeText: Bool
    let confirmStop: Bool
    let calmPetMotion: Bool
    let viewportMetrics: ChatViewportMetrics
    var cardBudget: ChatDockCardBudget.Allocation? = nil
    let typing: FocusState<Bool>.Binding

    @Binding var usageOpen: Bool
    @Binding var pickerShown: Bool
    @Binding var importingFile: Bool
    @Binding var picks: [PhotosPickerItem]
    @Binding var attaching: Bool
    @Binding var dockOpen: Bool
    @Binding var askingStop: Bool
    @Binding var detailOpen: Bool
    @Binding var roaming: Bool
    @Binding var editing: String?
    @Binding var quote: String?
    @Binding var photos: [Data]
    @Binding var files: [String]

    let onPresentApproval: (Approval) -> Void
    let onToEnd: () -> Void
    let onReturnToLatest: () -> Void
    let onClearComposer: () -> Void
    let onListen: () -> Void
    let onRedoFrom: (String, String) -> Bool
    let onPasteChange: (String, String) -> Void
    let onReceiveURLs: ([URL]) -> Void
    let fileNote: () -> String
    let outgoingText: () -> String

    var body: some View {
        VStack(spacing: Ink.Space.s) {
            ChatDockAreaView(
                chat: chat,
                team: team,
                bot: bot,
                awayState: awayState,
                workTimer: workTimer,
                calmPetMotion: calmPetMotion,
                viewportMetrics: viewportMetrics,
                cardBudget: cardBudget,
                dockOpen: $dockOpen,
                typing: typing,
                roaming: $roaming,
                followState: followState,
                onPresentApproval: onPresentApproval,
                onToEnd: onToEnd
            )
            .padding(.horizontal, Ink.Space.page)
            ChatDictationProblemView(dictationSlot: dictationSlot)
                .padding(.horizontal, Ink.Space.page)
            ChatComposerMainCard(
                chat: chat,
                team: team,
                bot: bot,
                dictationSlot: dictationSlot,
                draftState: draftState,
                notice: notice,
                contextMetrics: contextMetrics,
                largeText: largeText,
                confirmStop: confirmStop,
                typing: typing,
                usageOpen: $usageOpen,
                pickerShown: $pickerShown,
                importingFile: $importingFile,
                picks: $picks,
                attaching: $attaching,
                askingStop: $askingStop,
                detailOpen: $detailOpen,
                editing: $editing,
                quote: $quote,
                photos: $photos,
                files: $files,
                onPasteChange: onPasteChange,
                onReceiveURLs: onReceiveURLs,
                onListen: onListen,
                onClearComposer: onClearComposer,
                onRedoFrom: onRedoFrom,
                fileNote: fileNote,
                outgoingText: outgoingText
            )
        }
        .padding(.bottom, 8 * UIScale.factor)
    }
}

private struct ChatDockAreaView: View {
    let chat: ChatModel
    @ObservedObject var team: TeamModel
    let bot: BotInfo
    let awayState: ChatAwayState
    let workTimer: ChatWorkTimer
    let calmPetMotion: Bool
    var viewportMetrics: ChatViewportMetrics? = nil
    var cardBudget: ChatDockCardBudget.Allocation? = nil

    @Binding var dockOpen: Bool
    let typing: FocusState<Bool>.Binding
    @Binding var roaming: Bool
    let followState: ChatFollowState

    let onPresentApproval: (Approval) -> Void
    let onToEnd: () -> Void

    private var chatViewportHeight: CGFloat {
        viewportMetrics?.size.height ?? 0
    }

    private var doing: String? { team.workDetail(for: chat.key).words }
    private var working: Bool { doing != nil || chat.hasStreaming }
    private var waiting: Approval? { team.approvals.first { $0.chat == chat.key } }
    private var liveWords: String? { Live.words(doing, name: bot.name, waiting: waiting != nil) }
    private var liveIcon: String {
        if waiting != nil { return "seal" }
        guard let doing else { return "ellipsis" }
        let name = doing.split(separator: "：", maxSplits: 1).first.map(String.init) ?? doing
        if doing.contains("：") { return Trace.icon(for: name) }
        return doing == "正在回复" ? "pencil.line" : "sparkles"
    }
    private var petDockMotion: Animation {
        calmPetMotion ? .easeInOut(duration: 0.22) : Ink.Motion.unfold
    }
    private var cards: [ChatPage.DockCard] {
        ChatPage.dockCards(
            team: team,
            chatKey: chat.key,
            waiting: waiting,
            working: working,
            liveWords: liveWords,
            awayItems: awayState.items,
            hasStreaming: chat.hasStreaming,
            following: followState.following
        )
    }

    var body: some View {
        VStack(spacing: Ink.Space.xs) {
            if team.isPlanModeActive(for: chat.key) {
                HStack(spacing: Ink.Space.xs) {
                    Image(systemName: "map")
                        .font(.system(size: Ink.Size.micro, weight: .semibold))
                        .foregroundStyle(Ink.accent)
                    Text(L.t("plan.statusCapsule"))
                        .font(.system(size: Ink.Size.micro, weight: .medium))
                        .foregroundStyle(Ink.inkSoft)
                    Spacer(minLength: 0)
                    if !team.livePlanModeLedger.isInheritedReadOnly(chat.key) {
                        Button {
                            Haptics.light()
                            team.setPlanMode(false, in: chat.key)
                        } label: {
                            Text(L.t("plan.exitAction"))
                                .font(.system(size: Ink.Size.micro, weight: .semibold))
                                .foregroundStyle(Ink.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Ink.Space.m)
                .padding(.vertical, Ink.Space.xs)
                .background(Ink.surfaceSubtle, in: Capsule(style: .continuous))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(Ink.accent.opacity(0.28), lineWidth: 0.5)
                        .allowsHitTesting(false)
                }
            }
            if let plan = team.plans[chat.key] {
                let record = team.planRecords[chat.key]
                let fallbackMax = chatViewportHeight > 0 ? max(160, chatViewportHeight * 0.38) : nil
                let (resolvedPlanMax, forcePlanCollapsed): (CGFloat?, Bool) = {
                    switch cardBudget?.planCard {
                    case .expandable(let cap):
                        return (cap, false)
                    case .forcedCollapsedCapsule:
                        return (nil, true)
                    default:
                        return (fallbackMax, false)
                    }
                }()
                let canExecute = record.map {
                    team.canExecutePlan(chat: chat.key, revision: $0.revision, turnID: $0.turnID)
                } ?? false
                PlanCard(
                    steps: plan,
                    maxHeight: resolvedPlanMax,
                    forceCollapsed: forcePlanCollapsed,
                    planMode: canExecute,
                    revision: record?.revision ?? 0,
                    turnID: record?.turnID ?? "",
                    onExecutePlan: canExecute ? { rev, tid in
                        _ = team.unlockPlanAndExecute(chat: chat.key, revision: rev, turnID: tid)
                    } : nil
                ) {
                    team.clearPlan(chat.key)
                }
                .transition(calmPetMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
            dockContent
        }
        .animation(petDockMotion, value: waiting?.id)
    }

    @ViewBuilder
    private var dockContent: some View {
        let items = cards
        if items.count <= 1 || dockOpen {
            VStack(spacing: Ink.Space.s) {
                if items.count > 1 {
                    HStack {
                        Spacer()
                        Button {
                            Haptics.light()
                            withAnimation(Ink.Motion.settle) { dockOpen = false }
                        } label: {
                            Label("收起", systemImage: "chevron.down")
                                .font(.system(size: Ink.Size.small, weight: .medium))
                                .foregroundStyle(Ink.inkSoft)
                        }
                        .buttonStyle(TapStyle(grow: 8))
                    }
                }
                ForEach(items, id: \.self) { card in
                    dockCardView(card)
                }
            }
            .transition(.opacity)
        } else {
            ZStack(alignment: .top) {
                ForEach(Array(items.dropFirst().prefix(2).enumerated()), id: \.offset) { index, _ in
                    RoundedRectangle(cornerRadius: Ink.Radius.card, style: .continuous)
                        .fill(Ink.paperRaised)
                        .overlay(RoundedRectangle(cornerRadius: Ink.Radius.card, style: .continuous).strokeBorder(Ink.rule))
                        .frame(height: 40)
                        .scaleEffect(x: 1 - 0.05 * CGFloat(index + 1), y: 1, anchor: .top)
                        .opacity(1 - 0.25 * Double(index + 1))
                        .offset(y: -6 * CGFloat(index + 1))
                }
                dockCardView(items[0])
            }
            .padding(.top, 12)
            .overlay(alignment: .top) {
                Color.clear
                    .frame(height: 16)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        Haptics.light()
                        withAnimation(Ink.Motion.settle) { dockOpen = true }
                    }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("展开另外 \(items.count - 1) 条")
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private func dockCardView(_ card: ChatPage.DockCard) -> some View {
        switch card {
        case .waiting:
            if let waiting {
                let canAnswerInline = InlineApprovalPolicy.canAnswer(
                    answerable: waiting.answerable != false,
                    forced: waiting.forced == true,
                    tool: waiting.toolName,
                    hasCode: waiting.detail?.code?.isEmpty == false
                )
                let forceSheetFallback = (cardBudget?.approval == .sheetFallbackOnly) || !canAnswerInline
                if forceSheetFallback {
                    Button {
                        Haptics.grab()
                        onPresentApproval(waiting)
                    } label: {
                        HStack(spacing: Ink.Space.m) {
                            Image(systemName: "seal").foregroundStyle(Ink.warn)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Words.t("候印 · \(waiting.tool ?? "要你同意")"))
                                    .font(.system(size: Ink.Size.sub, weight: .semibold))
                                    .foregroundStyle(Ink.ink)
                                if let reason = waiting.reason {
                                    Text(reason).font(Ink.footnote).foregroundStyle(Ink.inkSoft).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                            Text(Words.t("去落印"))
                                .font(.system(size: Ink.Size.small, weight: .semibold))
                                .foregroundStyle(Ink.accent)
                        }
                        .padding(Ink.Space.m)
                        .paperCard()
                    }
                    .buttonStyle(PressStyle())
                    .transition(calmPetMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                } else {
                    let approvalCap: CGFloat? = {
                        if case .inline(let maxH) = cardBudget?.approval { return maxH }
                        return nil
                    }()
                    InlineApproval(
                        approval: waiting,
                        team: team,
                        name: team.bots.first { $0.id == waiting.botId }?.name ?? bot.name
                    ) {
                        onPresentApproval(waiting)
                    }
                    .frame(maxHeight: approvalCap)
                    .id(waiting.id)
                    .transition(calmPetMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
            }
        case .roam:
            RoamSlip(browser: team.browser) {
                typing.wrappedValue = false
                roaming = true
            }
        case .working:
            if let words = liveWords {
                WorkingBar(
                    words: words,
                    icon: liveIcon,
                    tools: team.toolCount[chat.key] ?? 0,
                    since: workTimer.since ?? Date(),
                    free: Grant.Preset.current == .free
                ) {
                    followState.following = true
                    onToEnd()
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        case .away:
            ChatAwayCardView(team: team, awayState: awayState)
        }
    }
}

private struct ChatDictationProblemView: View {
    let dictationSlot: ChatDictationSlot

    var body: some View {
        if let dictation = dictationSlot.instance {
            ChatActiveDictationProblemView(dictation: dictation)
        }
    }
}

private struct ChatActiveDictationProblemView: View {
    @ObservedObject var dictation: Dictation

    var body: some View {
        if let problem = dictation.problem {
            Text(problem)
                .font(Ink.footnote)
                .foregroundStyle(Ink.stop)
                .onTapGesture { dictation.problem = nil }
        }
    }
}

private struct ChatComposerMainCard: View {
    let chat: ChatModel
    let team: TeamModel
    let bot: BotInfo
    let dictationSlot: ChatDictationSlot
    let draftState: ChatDraft
    let notice: ChatComposerNotice
    let contextMetrics: ChatContextMetrics
    let largeText: Bool
    let confirmStop: Bool
    let typing: FocusState<Bool>.Binding

    @Binding var usageOpen: Bool
    @Binding var pickerShown: Bool
    @Binding var importingFile: Bool
    @Binding var picks: [PhotosPickerItem]
    @Binding var attaching: Bool
    @Binding var askingStop: Bool
    @Binding var detailOpen: Bool
    @Binding var editing: String?
    @Binding var quote: String?
    @Binding var photos: [Data]
    @Binding var files: [String]

    let onPasteChange: (String, String) -> Void
    let onReceiveURLs: ([URL]) -> Void
    let onListen: () -> Void
    let onClearComposer: () -> Void
    let onRedoFrom: (String, String) -> Bool
    let fileNote: () -> String
    let outgoingText: () -> String

    private var baseComposing: Bool {
        typing.wrappedValue
            || draftState.hasText
            || !photos.isEmpty
            || !files.isEmpty
            || editing != nil
            || quote != nil
    }

    var body: some View {
        if let dictation = dictationSlot.instance {
            ChatActiveComposerMainCardContainer(dictation: dictation, baseComposing: baseComposing) { composing in
                cardBody(composing: composing)
            }
        } else {
            cardBody(composing: baseComposing)
        }
    }

    private func cardBody(composing: Bool) -> some View {
        let idleMargin = largeText ? Ink.Space.page : 34 * ChatBarMetrics.scale
        let sidePadding = composing ? Ink.Space.page : idleMargin
        return VStack(alignment: .leading, spacing: Ink.Space.s) {
            ChatComposerQuoteBanner(quote: $quote)
            ChatComposerEditingBanner(editing: $editing, draftState: draftState)
            ChatComposerPhotosRow(photos: $photos)
            ChatComposerFilesRow(files: $files)
            ChatComposerSuggestionsView(
                draftState: draftState,
                chat: chat,
                team: team,
                files: $files,
                detailOpen: $detailOpen
            )
            if largeText {
                ChatDraftFieldView(
                    draftState: draftState,
                    chat: chat,
                    team: team,
                    dictationSlot: dictationSlot,
                    botName: bot.name,
                    largeText: largeText,
                    typing: typing,
                    onPasteChange: onPasteChange
                )
            }
            ChatComposerAccessoryRow(
                chat: chat,
                team: team,
                bot: bot,
                dictationSlot: dictationSlot,
                draftState: draftState,
                notice: notice,
                contextMetrics: contextMetrics,
                largeText: largeText,
                confirmStop: confirmStop,
                typing: typing,
                usageOpen: $usageOpen,
                pickerShown: $pickerShown,
                importingFile: $importingFile,
                picks: $picks,
                attaching: $attaching,
                askingStop: $askingStop,
                editing: $editing,
                quote: $quote,
                photos: photos,
                files: files,
                onPasteChange: onPasteChange,
                onReceiveURLs: onReceiveURLs,
                onListen: onListen,
                onClearComposer: onClearComposer,
                onRedoFrom: onRedoFrom,
                fileNote: fileNote,
                outgoingText: outgoingText
            )
        }
        .padding(.horizontal, 8 * ChatBarMetrics.scale)
        .padding(.vertical, 7 * ChatBarMetrics.scale)
        .frostedChatChrome(in: RoundedRectangle(cornerRadius: max(26 * ChatBarMetrics.scale, Ink.Radius.card), style: .continuous))
        .padding(.horizontal, sidePadding)
        .animation(UIAccessibility.isReduceMotionEnabled ? .easeOut(duration: 0.16) : Ink.Motion.quick, value: composing)
    }
}

private struct ChatActiveComposerMainCardContainer<Content: View>: View {
    @ObservedObject var dictation: Dictation
    let baseComposing: Bool
    @ViewBuilder let content: (Bool) -> Content

    var body: some View {
        content(baseComposing || dictation.listening || dictation.transcribing)
    }
}

private struct ChatComposerQuoteBanner: View {
    @Binding var quote: String?

    var body: some View {
        if let quote {
            HStack(alignment: .top, spacing: Ink.Space.s) {
                Rectangle().fill(Ink.accent).frame(width: 2)
                Text(quote).font(Ink.footnote).foregroundStyle(Ink.inkSoft).lineLimit(3)
                Spacer(minLength: 0)
                Button {
                    withAnimation(Ink.Motion.settle) { self.quote = nil }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: Ink.Size.sub))
                        .foregroundStyle(Ink.inkFaint)
                }
                .buttonStyle(TapStyle(grow: 8))
                .accessibilityLabel("不引用了")
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, Ink.Space.xs)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }
}

private struct ChatComposerEditingBanner: View {
    @Binding var editing: String?
    let draftState: ChatDraft

    var body: some View {
        if editing != nil {
            HStack(spacing: Ink.Space.s) {
                Image(systemName: "pencil").font(.system(size: Ink.Size.small, weight: .semibold))
                Text("改了重发：之后的对话会重新来过").font(Ink.footnote)
                Spacer()
                Button(L.t("actions.cancel")) {
                    withAnimation(Ink.Motion.settle) {
                        editing = nil
                        draftState.text = ""
                    }
                }
                .font(Ink.footnote.weight(.semibold))
            }
            .foregroundStyle(Ink.accent)
            .padding(.top, Ink.Space.xs)
        }
    }
}

private struct ChatComposerPhotosRow: View {
    @Binding var photos: [Data]

    var body: some View {
        if !photos.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: Ink.Space.s) {
                    ForEach(Array(photos.enumerated()), id: \.offset) { index, data in
                        ZStack(alignment: .topTrailing) {
                            ChatComposerPhotoThumb(data: data)
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
    }
}

private struct ComposerPhotoThumbKey: Hashable, Sendable {
    let byteCount: Int
    let sampleHash: UInt64
    let pixelLimit: Int

    init(data: Data, pixelLimit: Int) {
        self.byteCount = data.count
        var hash: UInt64 = 14695981039346656037
        for byte in data.prefix(128) {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        for byte in data.suffix(128) {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        self.sampleHash = hash
        self.pixelLimit = pixelLimit
    }
}

private enum ComposerPhotoThumbCache {
    static let cache = BoundedLRUCache<ComposerPhotoThumbKey, UIImage>(countLimit: 32)
}

private struct ChatComposerPhotoThumb: View {
    let data: Data
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    private var pixelLimit: Int {
        max(1, Int((56 * max(1, displayScale)).rounded()))
    }

    private var cacheKey: ComposerPhotoThumbKey {
        ComposerPhotoThumbKey(data: data, pixelLimit: pixelLimit)
    }

    var body: some View {
        let shown = image ?? ComposerPhotoThumbCache.cache.get(cacheKey)
        Group {
            if let shown {
                Image(uiImage: shown).resizable().scaledToFill()
            } else {
                Ink.mine
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(.rect(cornerRadius: Ink.Radius.small, style: .continuous))
        .task(id: cacheKey) {
            let key = cacheKey
            if let hit = ComposerPhotoThumbCache.cache.get(key) {
                if image !== hit { image = hit }
                return
            }
            let payload = data
            let maxPixel = key.pixelLimit
            let decoded: UIImage? = await Task.detached(priority: .userInitiated) {
                guard !Task.isCancelled else { return nil }
                return Self.decodeThumbnail(from: payload, maxPixelSize: maxPixel)
            }.value
            guard !Task.isCancelled, let decoded else { return }
            ComposerPhotoThumbCache.cache.set(decoded, for: key)
            image = decoded
        }
    }

    nonisolated private static func decodeThumbnail(from data: Data, maxPixelSize: Int) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        if let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) {
            let thumbOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ]
            if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) {
                let raw = UIImage(cgImage: cgImage)
                return raw.preparingForDisplay() ?? raw
            }
        }
        guard let fallback = UIImage(data: data) else { return nil }
        return fallback.preparingForDisplay() ?? fallback
    }
}

private struct ChatComposerFilesRow: View {
    @Binding var files: [String]

    var body: some View {
        if !files.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: Ink.Space.s) {
                    ForEach(files, id: \.self) { path in
                        HStack(spacing: 4) {
                            Image(systemName: "doc")
                                .font(.system(size: Ink.Size.small))
                                .layoutPriority(1)
                            Text((path as NSString).lastPathComponent)
                                .font(.system(size: Ink.Size.small, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button {
                                withAnimation(Ink.Motion.settle) { files.removeAll { $0 == path } }
                            } label: {
                                Image(systemName: "xmark").font(.system(size: Ink.Size.micro, weight: .bold))
                            }
                            .buttonStyle(TapStyle(grow: 8))
                            .layoutPriority(1)
                            .accessibilityLabel("移除文件：\((path as NSString).lastPathComponent)")
                        }
                        .foregroundStyle(Ink.ink)
                        .padding(.horizontal, Ink.Space.m)
                        .frame(height: 30)
                        .frame(maxWidth: 180 * UIScale.factor)
                        .background(Ink.mine, in: .capsule)
                    }
                }
                .padding(.top, 6)
            }
            .scrollIndicators(.hidden)
        }
    }
}

private struct ChatComposerAccessoryRow: View {
    let chat: ChatModel
    @ObservedObject var team: TeamModel
    let bot: BotInfo
    let dictationSlot: ChatDictationSlot
    let draftState: ChatDraft
    let notice: ChatComposerNotice
    let contextMetrics: ChatContextMetrics
    let largeText: Bool
    let confirmStop: Bool
    let typing: FocusState<Bool>.Binding

    @Binding var usageOpen: Bool
    @Binding var pickerShown: Bool
    @Binding var importingFile: Bool
    @Binding var picks: [PhotosPickerItem]
    @Binding var attaching: Bool
    @Binding var askingStop: Bool
    @Binding var editing: String?
    @Binding var quote: String?
    let photos: [Data]
    let files: [String]

    let onPasteChange: (String, String) -> Void
    let onReceiveURLs: ([URL]) -> Void
    let onListen: () -> Void
    let onClearComposer: () -> Void
    let onRedoFrom: (String, String) -> Bool
    let fileNote: () -> String
    let outgoingText: () -> String

    var body: some View {
        if let dictation = dictationSlot.instance {
            ChatActiveComposerAccessoryRow(
                dictation: dictation,
                chat: chat,
                team: team,
                bot: bot,
                dictationSlot: dictationSlot,
                draftState: draftState,
                notice: notice,
                contextMetrics: contextMetrics,
                largeText: largeText,
                confirmStop: confirmStop,
                typing: typing,
                usageOpen: $usageOpen,
                pickerShown: $pickerShown,
                importingFile: $importingFile,
                picks: $picks,
                attaching: $attaching,
                askingStop: $askingStop,
                editing: $editing,
                quote: $quote,
                photos: photos,
                files: files,
                onPasteChange: onPasteChange,
                onReceiveURLs: onReceiveURLs,
                onListen: onListen,
                onClearComposer: onClearComposer,
                onRedoFrom: onRedoFrom,
                fileNote: fileNote,
                outgoingText: outgoingText
            )
        } else {
            ChatComposerAccessoryCore(
                chat: chat,
                team: team,
                bot: bot,
                dictationSlot: dictationSlot,
                draftState: draftState,
                notice: notice,
                contextMetrics: contextMetrics,
                largeText: largeText,
                confirmStop: confirmStop,
                isDictating: false,
                typing: typing,
                usageOpen: $usageOpen,
                pickerShown: $pickerShown,
                importingFile: $importingFile,
                picks: $picks,
                attaching: $attaching,
                askingStop: $askingStop,
                editing: $editing,
                quote: $quote,
                photos: photos,
                files: files,
                onPasteChange: onPasteChange,
                onReceiveURLs: onReceiveURLs,
                onListen: onListen,
                onClearComposer: onClearComposer,
                onRedoFrom: onRedoFrom,
                fileNote: fileNote,
                outgoingText: outgoingText
            )
        }
    }
}

private struct ChatActiveComposerAccessoryRow: View {
    @ObservedObject var dictation: Dictation
    let chat: ChatModel
    @ObservedObject var team: TeamModel
    let bot: BotInfo
    let dictationSlot: ChatDictationSlot
    let draftState: ChatDraft
    let notice: ChatComposerNotice
    let contextMetrics: ChatContextMetrics
    let largeText: Bool
    let confirmStop: Bool
    let typing: FocusState<Bool>.Binding

    @Binding var usageOpen: Bool
    @Binding var pickerShown: Bool
    @Binding var importingFile: Bool
    @Binding var picks: [PhotosPickerItem]
    @Binding var attaching: Bool
    @Binding var askingStop: Bool
    @Binding var editing: String?
    @Binding var quote: String?
    let photos: [Data]
    let files: [String]

    let onPasteChange: (String, String) -> Void
    let onReceiveURLs: ([URL]) -> Void
    let onListen: () -> Void
    let onClearComposer: () -> Void
    let onRedoFrom: (String, String) -> Bool
    let fileNote: () -> String
    let outgoingText: () -> String

    var body: some View {
        ChatComposerAccessoryCore(
            chat: chat,
            team: team,
            bot: bot,
            dictationSlot: dictationSlot,
            draftState: draftState,
            notice: notice,
            contextMetrics: contextMetrics,
            largeText: largeText,
            confirmStop: confirmStop,
            isDictating: dictation.listening || dictation.transcribing,
            typing: typing,
            usageOpen: $usageOpen,
            pickerShown: $pickerShown,
            importingFile: $importingFile,
            picks: $picks,
            attaching: $attaching,
            askingStop: $askingStop,
            editing: $editing,
            quote: $quote,
            photos: photos,
            files: files,
            onPasteChange: onPasteChange,
            onReceiveURLs: onReceiveURLs,
            onListen: onListen,
            onClearComposer: onClearComposer,
            onRedoFrom: onRedoFrom,
            fileNote: fileNote,
            outgoingText: outgoingText
        )
    }
}

private struct ChatComposerAccessoryCore: View {
    let chat: ChatModel
    @ObservedObject var team: TeamModel
    let bot: BotInfo
    let dictationSlot: ChatDictationSlot
    let draftState: ChatDraft
    let notice: ChatComposerNotice
    let contextMetrics: ChatContextMetrics
    let largeText: Bool
    let confirmStop: Bool
    let isDictating: Bool
    let typing: FocusState<Bool>.Binding

    @Binding var usageOpen: Bool
    @Binding var pickerShown: Bool
    @Binding var importingFile: Bool
    @Binding var picks: [PhotosPickerItem]
    @Binding var attaching: Bool
    @Binding var askingStop: Bool
    @Binding var editing: String?
    @Binding var quote: String?
    let photos: [Data]
    let files: [String]

    let onPasteChange: (String, String) -> Void
    let onReceiveURLs: ([URL]) -> Void
    let onListen: () -> Void
    let onClearComposer: () -> Void
    let onRedoFrom: (String, String) -> Bool
    let fileNote: () -> String
    let outgoingText: () -> String

    private var composing: Bool {
        typing.wrappedValue
            || draftState.hasText
            || !photos.isEmpty
            || !files.isEmpty
            || editing != nil
            || quote != nil
            || isDictating
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: Ink.Space.s) {
            Button {
                Haptics.light()
                typing.wrappedValue = false
                attaching = true
            } label: {
                let lit = !photos.isEmpty || !files.isEmpty
                Image(systemName: "plus")
                    .font(.system(size: ChatBarMetrics.iconFontSize, weight: .medium))
                    .foregroundStyle(lit ? Ink.accent : Ink.inkSoft)
                    .frame(width: ChatBarMetrics.controlHeight, height: ChatBarMetrics.controlHeight)
                    .background(lit ? Ink.accentWash : Color.clear, in: .circle)
            }
            .buttonStyle(PressStyle(haptic: false, grow: max(0, (44 - ChatBarMetrics.controlHeight) / 2)))
            .accessibilityLabel(Words.t("加照片、文件，或改这段絮语的设置"))
            .photosPicker(isPresented: $pickerShown, selection: $picks, maxSelectionCount: 4, matching: .images)
            .fileImporter(isPresented: $importingFile, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { withAnimation(Ink.Motion.settle) { onReceiveURLs(urls) } }
            }
            if !largeText {
                ChatDraftFieldView(
                    draftState: draftState,
                    chat: chat,
                    team: team,
                    dictationSlot: dictationSlot,
                    botName: bot.name,
                    largeText: largeText,
                    typing: typing,
                    onPasteChange: onPasteChange
                )
            }
            if composing, team.place(of: chat.key) != .desk {
                ChatPlaceChipView(chatKey: chat.key, team: team, notice: notice)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
            let ringShare = contextMetrics.estimate?.share ?? 0
            if composing || ringShare >= 0.5 {
                ChatContextRingButton(
                    contextMetrics: contextMetrics,
                    composing: composing
                ) {
                    Haptics.light()
                    typing.wrappedValue = false
                    usageOpen = true
                }
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
            ChatActionButtonView(
                chat: chat,
                team: team,
                dictationSlot: dictationSlot,
                draftState: draftState,
                confirmStop: confirmStop,
                askingStop: $askingStop,
                editing: $editing,
                quote: $quote,
                photos: photos,
                files: files,
                fileNote: fileNote,
                outgoingText: outgoingText,
                onListen: onListen,
                onClearComposer: onClearComposer,
                onRedoFrom: onRedoFrom
            )
        }
        .animation(Ink.Motion.settle, value: composing)
    }
}

private struct ChatDraftFieldView: View {
    let draftState: ChatDraft
    let chat: ChatModel
    let team: TeamModel
    let dictationSlot: ChatDictationSlot
    let botName: String
    let largeText: Bool
    let typing: FocusState<Bool>.Binding
    let onPasteChange: (String, String) -> Void

    var body: some View {
        if let dictation = dictationSlot.instance {
            ChatActiveDraftFieldView(
                dictation: dictation,
                draftState: draftState,
                chat: chat,
                team: team,
                botName: botName,
                largeText: largeText,
                typing: typing,
                onPasteChange: onPasteChange
            )
        } else {
            ChatDraftFieldCore(
                draftState: draftState,
                chat: chat,
                team: team,
                listening: false,
                transcribing: false,
                botName: botName,
                largeText: largeText,
                typing: typing,
                onPasteChange: onPasteChange
            )
        }
    }
}

private struct ChatActiveDraftFieldView: View {
    @ObservedObject var dictation: Dictation
    let draftState: ChatDraft
    let chat: ChatModel
    let team: TeamModel
    let botName: String
    let largeText: Bool
    let typing: FocusState<Bool>.Binding
    let onPasteChange: (String, String) -> Void

    var body: some View {
        ChatDraftFieldCore(
            draftState: draftState,
            chat: chat,
            team: team,
            listening: dictation.listening,
            transcribing: dictation.transcribing,
            botName: botName,
            largeText: largeText,
            typing: typing,
            onPasteChange: onPasteChange
        )
    }
}

private struct ChatDraftFieldCore: View {
    let draftState: ChatDraft
    let chat: ChatModel
    let team: TeamModel
    let listening: Bool
    let transcribing: Bool
    let botName: String
    let largeText: Bool
    let typing: FocusState<Bool>.Binding
    let onPasteChange: (String, String) -> Void

    private var working: Bool {
        team.workDetail(for: chat.key).words != nil || chat.hasStreaming
    }

    private var placeholder: String {
        if listening { return "正在听，说完点右边" }
        if transcribing { return "正在转写语音…" }
        if working { return "在做 · 可以直接插话" }
        return "同\(botName)说点什么…"
    }

    var body: some View {
        TextField(
            "消息",
            text: Binding(get: { draftState.text }, set: { draftState.text = $0 }),
            prompt: Text(placeholder).foregroundStyle(Ink.inkSoft),
            axis: .vertical
        )
        .id("chat-composer-text-field")
        .font(largeText ? .body : .system(size: ChatBarMetrics.iconFontSize))
        .foregroundStyle(Ink.ink)
        .lineLimit(1...(largeText ? 3 : 6))
        .focused(typing)
        .onChange(of: draftState.text) { old, new in onPasteChange(old, new) }
        .padding(.vertical, 7 * ChatBarMetrics.scale)
        .frame(minHeight: ChatBarMetrics.controlHeight)
    }
}

private struct ChatContextRingButton: View {
    let contextMetrics: ChatContextMetrics
    let composing: Bool
    let onOpen: () -> Void

    var body: some View {
        let share = contextMetrics.estimate?.share ?? 0
        Button(action: onOpen) {
            ContextRing(share: share, showsNumber: !composing && share >= 0.5)
        }
        .buttonStyle(TapStyle())
        .accessibilityLabel("用量：下次请求约占上下文的 \(UsageSheet.percent(share))")
    }
}

private struct ChatActionButtonView: View {
    let chat: ChatModel
    @ObservedObject var team: TeamModel
    let dictationSlot: ChatDictationSlot
    let draftState: ChatDraft
    let confirmStop: Bool
    @Binding var askingStop: Bool
    @Binding var editing: String?
    @Binding var quote: String?
    let photos: [Data]
    let files: [String]
    let fileNote: () -> String
    let outgoingText: () -> String
    let onListen: () -> Void
    let onClearComposer: () -> Void
    let onRedoFrom: (String, String) -> Bool

    var body: some View {
        if let dictation = dictationSlot.instance {
            ChatActiveActionButtonView(
                dictation: dictation,
                chat: chat,
                team: team,
                draftState: draftState,
                confirmStop: confirmStop,
                askingStop: $askingStop,
                editing: $editing,
                quote: $quote,
                photos: photos,
                files: files,
                fileNote: fileNote,
                outgoingText: outgoingText,
                onListen: onListen,
                onClearComposer: onClearComposer,
                onRedoFrom: onRedoFrom
            )
        } else {
            ChatActionButtonCore(
                chat: chat,
                team: team,
                draftState: draftState,
                confirmStop: confirmStop,
                listening: false,
                transcribing: false,
                level: 0,
                askingStop: $askingStop,
                editing: $editing,
                quote: $quote,
                photos: photos,
                files: files,
                fileNote: fileNote,
                outgoingText: outgoingText,
                onStopDictation: {},
                onCancelDictation: {},
                onListen: onListen,
                onClearComposer: onClearComposer,
                onRedoFrom: onRedoFrom
            )
        }
    }
}

private struct ChatActiveActionButtonView: View {
    @ObservedObject var dictation: Dictation
    let chat: ChatModel
    @ObservedObject var team: TeamModel
    let draftState: ChatDraft
    let confirmStop: Bool
    @Binding var askingStop: Bool
    @Binding var editing: String?
    @Binding var quote: String?
    let photos: [Data]
    let files: [String]
    let fileNote: () -> String
    let outgoingText: () -> String
    let onListen: () -> Void
    let onClearComposer: () -> Void
    let onRedoFrom: (String, String) -> Bool

    var body: some View {
        ChatActionButtonCore(
            chat: chat,
            team: team,
            draftState: draftState,
            confirmStop: confirmStop,
            listening: dictation.listening,
            transcribing: dictation.transcribing,
            level: dictation.level,
            askingStop: $askingStop,
            editing: $editing,
            quote: $quote,
            photos: photos,
            files: files,
            fileNote: fileNote,
            outgoingText: outgoingText,
            onStopDictation: { dictation.stop() },
            onCancelDictation: { dictation.cancel() },
            onListen: onListen,
            onClearComposer: onClearComposer,
            onRedoFrom: onRedoFrom
        )
    }
}

private struct ChatActionButtonCore: View {
    let chat: ChatModel
    @ObservedObject var team: TeamModel
    let draftState: ChatDraft
    let confirmStop: Bool
    let listening: Bool
    let transcribing: Bool
    let level: CGFloat
    @Binding var askingStop: Bool
    @Binding var editing: String?
    @Binding var quote: String?
    let photos: [Data]
    let files: [String]
    let fileNote: () -> String
    let outgoingText: () -> String
    let onStopDictation: () -> Void
    let onCancelDictation: () -> Void
    let onListen: () -> Void
    let onClearComposer: () -> Void
    let onRedoFrom: (String, String) -> Bool

    private var working: Bool {
        team.workDetail(for: chat.key).words != nil || chat.hasStreaming
    }

    private var sendingBlocked: Bool {
        team.phase != .demo && !team.canAcceptInput(for: chat.key)
    }

    private var canSend: Bool {
        draftState.hasSendableText || !photos.isEmpty || !files.isEmpty
    }

    var body: some View {
        let mode: Int
        let symbol: String
        let fill: Color
        let label: String
        if listening {
            mode = 0; symbol = "waveform"; fill = Ink.stop; label = "说完了"
        } else if transcribing {
            mode = 4; symbol = "ellipsis"; fill = Ink.accentWash; label = L.t("voiceSettings.cancelTranscribe")
        } else if working && !canSend {
            mode = 1; symbol = "stop.fill"; fill = Ink.ink; label = "让它停下"
        } else if canSend {
            mode = 2; symbol = "arrow.up"; fill = Ink.accent; label = working ? "插话" : "发送"
        } else {
            mode = 3; symbol = "mic"; fill = .clear; label = "说话"
        }
        return Button {
            switch mode {
            case 0:
                Haptics.light()
                onStopDictation()
            case 4:
                Haptics.light()
                onCancelDictation()
            case 1:
                if confirmStop {
                    Haptics.light()
                    askingStop = true
                } else {
                    Haptics.lock()
                    chat.stop()
                }
            case 2:
                guard !sendingBlocked else { return }
                Haptics.grab()
                let accepted: Bool
                if let editing {
                    accepted = onRedoFrom(editing, draftState.text)
                    if accepted { self.editing = nil }
                } else if let quote {
                    let quoted = quote.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
                    accepted = chat.send(quoted + "\n\n" + draftState.text + fileNote(), photos: photos)
                    if accepted { self.quote = nil }
                } else if working {
                    accepted = chat.interject(outgoingText(), photos: photos)
                } else {
                    accepted = chat.send(outgoingText(), photos: photos)
                }
                if accepted { onClearComposer() }
            default:
                onListen()
            }
        } label: {
            ZStack {
                if mode == 0 {
                    Circle().fill(Ink.stop.opacity(0.25)).scaleEffect(1 + level * 0.6)
                }
                if mode == 4 {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Ink.accent)
                        .frame(width: ChatBarMetrics.controlHeight, height: ChatBarMetrics.controlHeight)
                        .background(fill, in: .circle)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: ChatBarMetrics.titleFontSize, weight: mode == 3 ? .medium : .bold))
                        .foregroundStyle(mode == 3 ? Ink.inkSoft : Ink.paper)
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.variableColor.iterative, isActive: mode == 0)
                        .frame(width: ChatBarMetrics.controlHeight, height: ChatBarMetrics.controlHeight)
                        .background(fill, in: .circle)
                }
            }
            .frame(width: ChatBarMetrics.controlHeight, height: ChatBarMetrics.controlHeight)
            .opacity(mode == 2 && sendingBlocked ? 0.45 : 1)
        }
        .disabled(mode == 2 && sendingBlocked)
        .buttonStyle(PressStyle(haptic: false, grow: max(0, (44 - ChatBarMetrics.controlHeight) / 2)))
        .animation(Ink.Motion.press, value: mode)
        .accessibilityLabel(label)
        .contextMenu {
            if working && canSend && !sendingBlocked && editing == nil && quote == nil {
                Button("插话：这一步做完就递给它", systemImage: "text.bubble") {
                    if chat.interject(outgoingText(), photos: photos) { onClearComposer() }
                }
                Button("中断并发送", systemImage: "bolt") {
                    Haptics.thud()
                    if chat.sendNow(outgoingText(), photos: photos) { onClearComposer() }
                }
                Button("排队：这轮做完再发", systemImage: "tray") {
                    if chat.send(outgoingText(), photos: photos) { onClearComposer() }
                }
            }
        }
    }
}

private struct ChatDockedJumpOverlaySlot: View {
    let chatKey: String
    @ObservedObject var team: TeamModel
    @ObservedObject var asker: Asker
    let chrome: ChatChrome
    let petPerch: PetPerch
    let inHistory: Bool
    let followState: ChatFollowState
    let onLatest: () -> Void

    private var hasInlineAsk: Bool {
        guard let current = asker.current, current.inline,
              current.chat == nil || current.chat == chatKey else { return false }
        return team.isWorking(chatKey)
    }

    private var hasPendingApproval: Bool {
        team.approvals.contains { $0.chat == chatKey }
    }

    var body: some View {
        ChatFloatingJumpOverlay(
            chrome: chrome,
            petPerch: petPerch,
            inHistory: inHistory,
            following: followState.following,
            suppressed: hasInlineAsk || hasPendingApproval,
            onLatest: onLatest
        )
        .padding(.horizontal, Ink.Space.page)
    }
}

private struct ChatImmersiveBottomBar: View {
    let chat: ChatModel
    @ObservedObject var team: TeamModel
    let chrome: ChatChrome
    let confirmStop: Bool
    @Binding var askingStop: Bool
    let onRestore: () -> Void
    let onLatest: () -> Void

    private var working: Bool {
        team.workDetail(for: chat.key).words != nil || chat.hasStreaming
    }

    var body: some View {
        let fabSize = ChatBarMetrics.jumpSize
        HStack(spacing: Ink.Space.xs) {
            if working {
                Button {
                    if confirmStop {
                        Haptics.light()
                        askingStop = true
                    } else {
                        Haptics.lock()
                        chat.stop()
                    }
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: ChatBarMetrics.subTitleFontSize, weight: .semibold))
                        .foregroundStyle(Ink.stop)
                        .frame(width: fabSize, height: fabSize)
                        .frostedChatChrome(in: Circle())
                        .contentShape(Circle())
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle(haptic: false))
                .accessibilityLabel(L.t("chat.stopGenerating"))
            }

            Button {
                Haptics.light()
                onRestore()
                onLatest()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: ChatBarMetrics.titleFontSize, weight: .semibold))
                    .foregroundStyle(Ink.ink)
                    .frame(width: fabSize, height: fabSize)
                    .frostedChatChrome(in: Circle())
                    .contentShape(Circle())
                    .overlay(alignment: .topTrailing) {
                        if chrome.unreadCount > 0 {
                            ChatUnreadBadge(count: chrome.unreadCount)
                        }
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle(haptic: false))
            .accessibilityLabel(
                chrome.unreadCount > 0
                    ? "\(L.t("chat.latest"))，\(chrome.unreadCount)"
                    : L.t("chat.latest")
            )
            .accessibilityAction(named: L.t("chat.restoreControls")) {
                Haptics.selection()
                onRestore()
            }
        }
    }
}
