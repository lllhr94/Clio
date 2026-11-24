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
    // MARK: Dock: the cards above the composer

    /// The cards that can sit above the composer, the most pressing first.
    enum DockCard: Hashable { case waiting, roam, working, away }

    var dockCards: [DockCard] {
        var cards: [DockCard] = []
        if waiting != nil { cards.append(.waiting) }
        // Only the conversation that asked for the takeover shows it.
        if team.browser.handoff != nil, team.browser.handoffChat == nil || team.browser.handoffChat == chat.key { cards.append(.roam) }
        if working, waiting == nil, liveWords != nil { cards.append(.working) }
        if !away.isEmpty, waiting == nil { cards.append(.away) }
        return cards
    }

    /// Two cards or more stack into one, like notifications: the first in front, the edges of the next ones
    /// showing behind it. A tap on the edges spreads them out.
    @ViewBuilder
    var dock: some View {
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
    func dockCard(_ card: DockCard) -> some View {
        switch card {
        case .waiting:
            if let waiting {
                if !InlineApprovalPolicy.canAnswer(answerable: waiting.answerable != false,
                                                   forced: waiting.forced == true,
                                                   tool: waiting.toolName,
                                                   hasCode: waiting.detail?.code?.isEmpty == false) {
                    Button {
                        Haptics.grab()
                        presentApproval(waiting)
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
                        presentApproval(waiting)
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

    var draftField: some View {
        let placeholder: String
        if dictation.listening {
            placeholder = "正在听，说完点右边"
        } else if dictation.transcribing {
            placeholder = "正在转写语音…"
        } else if working {
            placeholder = "在做 · 可以直接插话"
        } else {
            placeholder = "同\(bot.name)说点什么…"
        }
        return TextField(placeholder, text: Binding(get: { draft }, set: { draft = $0 }), axis: .vertical)
            .font(largeText ? .body : Ink.label)
            .foregroundStyle(Ink.ink)
            .lineLimit(1...(largeText ? 3 : 6))
            .focused($typing)
            .onChange(of: draft) { old, new in keepLongPaste(old, new) }
            .padding(.vertical, 6)
            .frame(minHeight: 34)
    }

    var composer: some View {
        ChatSection { composerContents }
    }

    var composerContents: some View {
        VStack(spacing: Ink.Space.s) {
            // The plan sits right on the composer, as one block with it, not as a second bar floating above.
            VStack(spacing: Ink.Space.xs) {
                if let plan = team.plans[chat.key] {
                    PlanCard(steps: plan, maxHeight: chatViewport.height > 0 ? max(160, chatViewport.height * 0.38) : nil) { team.clearPlan(chat.key) }
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
                ChatSection { composerSuggestions }
                if largeText { ChatSection { draftField } }
                // One row at rest, like any messaging app: add, write, speak or send.
                HStack(alignment: .bottom, spacing: Ink.Space.s) {
                    Button {
                        Haptics.light()
                        typing = false
                        attaching = true
                    } label: {
                        let lit = !photos.isEmpty || !files.isEmpty
                        Image(systemName: "plus")
                            .font(.system(size: Ink.Size.sub, weight: .medium))
                            .foregroundStyle(lit ? Ink.accent : Ink.inkSoft)
                            .frame(width: 34, height: 34)
                            .background(lit ? Ink.accentWash : Color.clear, in: .circle)
                            .contentShape(.circle)
                    }
                    .buttonStyle(PressStyle(haptic: false))
                    .accessibilityLabel(Words.t("加照片、文件，或改这段絮语的设置"))
                    .photosPicker(isPresented: $pickerShown, selection: $picks, maxSelectionCount: 4, matching: .images)
                    .fileImporter(isPresented: $importingFile, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                        if case .success(let urls) = result { withAnimation(Ink.Motion.settle) { receive(urls) } }
                    }
                    if !largeText { ChatSection { draftField } }
                    if composing, team.place(of: chat.key) != .desk {
                        placeChip
                            .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    }
                    Button {
                        Haptics.light()
                        typing = false
                        usageOpen = true
                    } label: {
                        let share = context?.share ?? 0
                        ContextRing(share: share, showsNumber: !composing && share >= 0.5)
                    }
                    .buttonStyle(TapStyle())
                    .accessibilityLabel("用量：下次请求约占上下文的 \(UsageSheet.percent(context?.share ?? 0))")
                    action
                }
            }
            .animation(Ink.Motion.settle, value: composing)
            .padding(.horizontal, Ink.Space.s)
            .padding(.vertical, 6 * UIScale.factor)
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
        .overlay(alignment: .top) {
            ChatFloatingJumpOverlay(
                chrome: chrome,
                petPerch: petPerch,
                inHistory: historyPage != nil,
                following: following,
                onPrevious: { stepQuestion(earlier: true) },
                onNext: { stepQuestion(earlier: false) },
                onLatest: returnToLatest
            )
        }
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
            onStepQuestion: { earlier in stepQuestion(earlier: earlier) }
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

    private func presentApproval(_ approval: Approval) {
        DiagTrail.record("开审批详情")
        followPending?.cancel()
        settleEnd?.cancel()
        settleJump?.cancel()
        viewport.advanceNavigation()
        typing = false
        approving = approval
    }

    func approvalInsetChanged() {
        followPending?.cancel()
        settleEnd?.cancel()
        approvalInsetTask?.cancel()
        approvalInsetTask = Task { @MainActor in
            // The system anchor follows the animated dock. Recheck only after it settles.
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            approvalInsetTask = nil
            followToEnd(settle: false)
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
        typing || draftState.hasText || !photos.isEmpty || !files.isEmpty || editing != nil || quote != nil || dictation.listening || dictation.transcribing
    }

    var sendingBlocked: Bool {
        team.phase != .demo && !team.canAcceptInput(for: chat.key)
    }

    var canSend: Bool {
        draftState.hasSendableText || !photos.isEmpty || !files.isEmpty
    }

    var action: some View {
        let mode: Int
        let symbol: String
        let fill: Color
        let label: String
        if dictation.listening {
            mode = 0; symbol = "waveform"; fill = Ink.stop; label = "说完了"
        } else if dictation.transcribing {
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
                dictation.stop()
            case 4:
                Haptics.light()
                dictation.cancel()
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
                    accepted = redo(from: editing, text: draft)
                    if accepted { self.editing = nil }
                } else if let quote {
                    let quoted = quote.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
                    accepted = chat.send(quoted + "\n\n" + draft + fileNote, photos: photos)
                    if accepted { self.quote = nil }
                } else if working {
                    // While it works, a plain tap is 插话: heard after the step in progress.
                    accepted = chat.interject(outgoing, photos: photos)
                } else {
                    accepted = chat.send(outgoing, photos: photos)
                }
                if accepted { clearComposer() }
            default:
                listen()
            }
        } label: {
            ZStack {
                if mode == 0 {
                    Circle().fill(Ink.stop.opacity(0.25)).scaleEffect(1 + dictation.level * 0.6)
                }
                if mode == 4 {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Ink.accent)
                        .frame(width: 34, height: 34)
                        .background(fill, in: .circle)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: Ink.Size.sub, weight: mode == 3 ? .medium : .bold))
                        .foregroundStyle(mode == 3 ? Ink.inkSoft : Ink.paper)
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.variableColor.iterative, isActive: mode == 0)
                        .frame(width: 34, height: 34)
                        .background(fill, in: .circle)
                }
            }
            .frame(width: 34, height: 34)
            .opacity(mode == 2 && sendingBlocked ? 0.45 : 1)
        }
        .disabled(mode == 2 && sendingBlocked)
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
        .accessibilityLabel(label)
        .contextMenu {
            if working && canSend && !sendingBlocked && editing == nil && quote == nil {
                Button("插话：这一步做完就递给它", systemImage: "text.bubble") {
                    if chat.interject(outgoing, photos: photos) { clearComposer() }
                }
                Button("中断并发送", systemImage: "bolt") {
                    Haptics.thud()
                    if chat.sendNow(outgoing, photos: photos) { clearComposer() }
                }
                Button("排队：这轮做完再发", systemImage: "tray") {
                    if chat.send(outgoing, photos: photos) { clearComposer() }
                }
            }
        }
    }
}
