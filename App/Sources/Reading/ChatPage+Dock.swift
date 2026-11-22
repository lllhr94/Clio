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
                ChatSection { composerSuggestions }
                if largeText { ChatSection { draftField } }
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
                    .opacity(latestIsFloating ? 1 : 0)
                    .allowsHitTesting(latestIsFloating)
                    .accessibilityHidden(!latestIsFloating)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .offset(y: -Ink.Bar.height)
            .onChange(of: jumpVisible || latestIsFloating, initial: true) { _, shown in
                withAnimation(Ink.Motion.settle) { petPerch.keepOutRight = shown ? Ink.Bar.height * 3 + Ink.Space.s * 3 : 0 }
            }
            .animation(Ink.Motion.settle, value: jumpVisible)
            .animation(Ink.Motion.settle, value: farFromEnd && !following)
        }
    }

    /// 长对话小地图 (after Kelivo): while scrolling a long conversation, a thin strip at the right edge with a tick
    /// for each thing you asked; the ones on screen are darker. A tap goes there. Hidden when not scrolling.
    @ViewBuilder
    var minimap: some View {
        let rows = historyPage.map { $0[...] } ?? chat.lines.suffix(shownCount)
        let asked = rows.indices.filter { rows[$0].kind == .user }
        if jumpVisible, rows.count >= 30, asked.count >= 4 {
            let visible = Set(viewport.ids)
            let first = rows.startIndex
            let span = max(1, rows.count - 1)
            GeometryReader { box in
                let height = box.size.height
                let place = { (index: Int) in height * CGFloat(index - first) / CGFloat(span) }
                let nearest = { (y: CGFloat) in asked.min(by: { abs(place($0) - y) < abs(place($1) - y) }) }
                ZStack(alignment: .top) {
                    Capsule().fill(Ink.rule.opacity(0.5)).frame(width: 3)
                    ForEach(asked, id: \.self) { index in
                        // While sliding, the finger's question is the one lit; otherwise the ones on screen.
                        let lit = minimapScrub.map { $0 == index } ?? visible.contains(rows[index].id)
                        Capsule()
                            .fill(lit ? Ink.accent : Ink.inkFaint)
                            .frame(width: lit ? 12 : 7, height: lit ? 4 : 3)
                            .offset(y: place(index) - 1.5)
                    }
                }
                .frame(width: 24, height: height, alignment: .top)
                .contentShape(Rectangle().inset(by: -Ink.Space.s))
                // Tap, or slide along it: the question under the finger lights at once (with a tick and its first
                // words beside the strip), and letting go goes there. One gesture for the whole strip (the review, #32).
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            hideJumps?.cancel()
                            guard let index = nearest(drag.location.y), index != minimapScrub else { return }
                            if minimapScrub != nil { Haptics.tick(0.3) }
                            minimapScrub = index
                        }
                        .onEnded { drag in
                            let index = nearest(drag.location.y) ?? minimapScrub
                            minimapScrub = nil
                            guard let index, rows.indices.contains(index) else { return }
                            jump(to: rows[index].id, animated: false)
                        }
                )
                .overlay(alignment: .topTrailing) {
                    if let index = minimapScrub, rows.indices.contains(index) {
                        Text(rows[index].text.replacingOccurrences(of: "\n", with: " "))
                            .font(.system(size: Ink.Size.small))
                            .foregroundStyle(Ink.ink)
                            .lineLimit(2)
                            .frame(width: 200, alignment: .trailing)
                            .padding(.horizontal, Ink.Space.m)
                            .padding(.vertical, Ink.Space.s)
                            .glassFace(in: RoundedRectangle(cornerRadius: Ink.Radius.small, style: .continuous))
                            .offset(x: -32, y: min(max(0, place(index) - 18), max(0, height - 44)))
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
            }
            .frame(width: 24)
            .padding(.vertical, Ink.Bar.height * 2)
            .padding(.trailing, 2)
            .transition(.opacity)
            // VoiceOver: one element that steps through the questions with a swipe up or down.
            .accessibilityElement()
            .accessibilityLabel(L.t("chat.questionMap"))
            .accessibilityValue(minimapPlace(rows: rows, asked: asked, visible: visible))
            .accessibilityAdjustableAction { direction in
                let earlier = direction == .decrement
                if let target = question(earlier: earlier) { jump(to: target) }
            }
        }
    }

    func minimapPlace(rows: ArraySlice<ChatLine>, asked: [Int], visible: Set<String>) -> String {
        guard let at = asked.firstIndex(where: { visible.contains(rows[$0].id) }) else { return "\(asked.count)" }
        return "\(at + 1) / \(asked.count)"
    }

    func jump(to id: String, animated: Bool = true) {
        Haptics.tick(0.4)
        following = false
        jumpedTo = id
        lingerJumpButtons()
        // From the 小地图 the page goes straight there: a long animated scroll through a lazy list lags behind.
        if animated {
            withAnimation(Ink.Motion.settle) { scroller?.scrollTo(id, anchor: .top) }
        } else {
            scroller?.scrollTo(id, anchor: .top)
        }
    }

    func lingerJumpButtons() {
        hideJumps?.cancel()
        hideJumps = Task {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            jumpVisible = false
        }
    }

    func jumpButton(_ symbol: String, title: String, earlier: Bool) -> some View {
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

    func floating(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: Ink.Size.sub, weight: .semibold))
            .foregroundStyle(Ink.ink)
            .frame(width: 36, height: 36)
            .background(Ink.paperRaised, in: .circle)
            .overlay(Circle().strokeBorder(Ink.rule, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
            .contentShape(.circle)
    }

    var latestIsFloating: Bool {
        jumpVisible && (historyPage != nil || farFromEnd && !following)
    }

    func returnToLatest() {
        Haptics.light()
        following = true
        jumpedTo = nil
        if historyPage == nil {
            toEnd(animated: true)
        } else {
            historyPage = nil
            followToEnd()
        }
    }

    var backToEnd: some View {
        Button(action: returnToLatest) {
            floating("arrow.down.to.line")
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(L.t("chat.latest"))
    }

    static let end = "foot-of-page"

    /// Points of the page still below the visible part, counting the composer's inset at the bottom.
    static func below(_ geometry: ScrollGeometry) -> CGFloat {
        geometry.contentSize.height + geometry.contentInsets.bottom - geometry.visibleRect.maxY
    }

    func selectionChanged(_ id: UUID, _ started: Bool) {
        if started {
            selecting.insert(id)
            followPending?.cancel()
        } else {
            selecting.remove(id)
        }
    }

    /// Coalesce layout changes from the composer and a newly inserted row before moving the viewport.
    func followToEnd(settle: Bool = true) {
        guard historyPage == nil, following, selecting.isEmpty else { return }
        followPending?.cancel()
        followPending = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(settle ? 32 : 16)) } catch { return }
            guard following else { return }
            toEnd()
        }
    }


    func toEnd(animated: Bool = false) {
        guard historyPage == nil, selecting.isEmpty, let scroller else { return }
        if animated {
            withAnimation(Ink.Motion.settle) { scroller.scrollTo(Self.end, anchor: .bottom) }
        } else {
            scroller.scrollTo(Self.end, anchor: .bottom)
        }
        // The first jump goes by guessed heights of rows not drawn yet; once they are drawn the foot may sit elsewhere.
        // One more look a moment later puts the page on the real foot instead of a blank stretch.
        settleEnd?.cancel()
        settleEnd = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(animated ? 420 : 120)) } catch { return }
            guard following, historyPage == nil, selecting.isEmpty else { return }
            scroller.scrollTo(Self.end, anchor: .bottom)
        }
    }



    /// Writing something: the row of chips shows under the text field.
    var composing: Bool {
        typing || draftState.hasText || !photos.isEmpty || !files.isEmpty || editing != nil || quote != nil || dictation.listening || dictation.transcribing
    }

    var canSend: Bool {
        draftState.hasSendableText || !photos.isEmpty || !files.isEmpty
    }

    var action: some View {
        let mode: Int
        if dictation.listening {
            mode = 0
        } else if dictation.transcribing {
            mode = 4
        } else if working && !canSend {
            mode = 1
        } else if canSend {
            mode = 2
        } else {
            mode = 3
        }
        let symbol = ["waveform", "stop.fill", "arrow.up", "mic", "ellipsis"][mode]
        let fill: Color = [Ink.stop, Ink.ink, Ink.accent, .clear, Ink.accentWash][mode]
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
                if mode == 4 {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Ink.accent)
                        .frame(width: 34, height: 34)
                        .background(fill, in: .circle)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: mode == 3 ? 16 : 15, weight: mode == 3 ? .medium : .bold))
                        .foregroundStyle(mode == 3 ? Ink.inkSoft : Ink.paper)
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.variableColor.iterative, isActive: mode == 0)
                        .frame(width: 34, height: 34)
                        .background(fill, in: .circle)
                }
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
}
