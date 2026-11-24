import Craft
import SwiftUI

/// One approval slip at a time: slide to stamp it approved, or turn it down.
struct ApproveView: View {
    @ObservedObject var team: TeamModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var textScale: CGFloat = 1
    private var largeText: Bool { typeSize.isAccessibilitySize }
    private var accessibilityScale: CGFloat { largeText ? textScale : 1 }

    private enum Verdict { case allowed, rejected }

    /// Kept here: the computer drops the approval the moment it is answered, the slip stays to be stamped.
    @State private var current: Approval
    @State private var verdict: Verdict?
    @State private var stampedAt = Date()
    @State private var busy = false
    @State private var always = false
    @State private var trustChat = false
    @State private var handled: Set<String> = []
    @State private var note: String?
    /// 0...1: how far the stamp is pressing the slip down.
    @State private var press: CGFloat = 0
    @State private var slide: CGFloat = 0
    @State private var lastTick = 0
    @State private var shown = false
    @State private var viewport = CGSize.zero

    private var shortWindow: Bool { viewport.height > 0 && viewport.height < viewport.width * 1.25 }
    private var slipWidth: CGFloat? {
        guard viewport.width > 0 else { return nil }
        let gutter = (largeText ? Ink.Space.l : Ink.Space.page) * 2
        return min(max(1, viewport.width - gutter), viewport.width * (largeText ? 0.92 : 0.80),
                   Ink.Size.body * (largeText ? 33 : 24))
    }
    private var paperSide: CGFloat { min((slipWidth ?? 0) * 0.93, viewport.height * 0.53) }
    private var stampSide: CGFloat { (slipWidth ?? 0) * 0.36 }

    init(approval: Approval, team: TeamModel) {
        self.team = team
        _current = State(initialValue: approval)
    }

    private var bot: BotInfo? { team.bots.first { $0.id == current.botId } }
    private var name: String { bot?.name ?? Words.t("旅伴") }
    private var answerable: Bool { current.answerable != false }
    private var waiting: Int { team.approvals.filter { $0.id != current.id && !handled.contains($0.id) }.count }

    var body: some View {
        ZStack {
            Ink.paper.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    if waiting > 0 {
                        Text(L.format("approval.remaining", waiting))
                            .font(.system(size: Ink.Size.sub, weight: .semibold))
                            .foregroundStyle(Ink.ink)
                            .padding(.horizontal, Ink.Space.l)
                            .frame(minHeight: 34)
                            .glassEffect(.regular, in: .capsule)
                            .transition(.opacity)
                    }
                    Spacer()
                    Button(L.t("actions.done")) {
                        Haptics.light()
                        dismiss()
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                }
                .padding(.horizontal, Ink.Space.page)
                .padding(.top, Ink.Space.s)

                Spacer(minLength: 12)

                ZStack {
                    if waiting > 0 && !largeText {
                        SlipShape()
                            .fill(Ink.paperRaised)
                            .frame(width: paperSide, height: paperSide)
                            .rotationEffect(.degrees(5))
                            .offset(x: 14, y: 12)
                            .blur(radius: 1.5)
                            .opacity(0.8)
                            .shadow(color: Color.black.opacity(0.10), radius: 14, y: 14)
                            .transition(.opacity)
                    }
                    slip
                        .padding(.horizontal, largeText ? Ink.Space.l : 0)
                        .scaleEffect(1 - 0.035 * press)
                        .rotationEffect(.degrees(largeText ? 0 : Double(-4 - 2 * press)))
                        .offset(y: 12 * press)
                        .id(current.id)
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.86).combined(with: .opacity).combined(with: .offset(x: 10, y: 30)),
                            removal: .offset(x: viewport.width * 0.85, y: -viewport.height * 0.65).combined(with: .opacity)
                        ))
                }
                .scaleEffect(shown ? 1 : 0.9)
                .opacity(shown ? 1 : 0)
                .blur(radius: shown ? 0 : 10)

                Spacer(minLength: 12)

                VStack(spacing: Ink.Space.m) {
                    Text(title)
                        .font(Ink.mark(Ink.Size.title, bold: true, relativeTo: .title))
                        .foregroundStyle(Ink.ink)
                        .multilineTextAlignment(.center)
                        .lineLimit(largeText ? nil : 2)
                        .minimumScaleFactor(largeText ? 1 : 0.7)
                        .contentTransition(.opacity)
                    Text(note ?? subtitle)
                        .font(.system(size: Ink.Size.body * accessibilityScale))
                        .foregroundStyle(note == nil ? Ink.inkSoft : Ink.stop)
                        .multilineTextAlignment(.center)
                        .contentTransition(.opacity)
                    controls
                        .padding(.top, Ink.Space.l)
                        .frame(minHeight: largeText || shortWindow ? nil : Ink.Bar.height * 3.6, alignment: .top)
                }
                .padding(.horizontal, Ink.Space.xl)
                .padding(.bottom, Ink.Space.m)
            }
            .modifier(ApprovalViewport(scrolls: largeText || shortWindow))
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { viewport = $0 }
        .fontDesign(.rounded)
        .onAppear {
            Haptics.prepare()
            withAnimation(.spring(response: 0.6, dampingFraction: 0.72).delay(0.1)) { shown = true }
        }
        .onChange(of: team.approvals) {
            // Answered somewhere else while this slip was open.
            guard verdict == nil, !busy, !team.approvals.contains(where: { $0.id == current.id }) else { return }
            handled.insert(current.id)
            withAnimation(.smooth) { note = L.t("approval.handledElsewhere") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { advance() }
        }
    }

    private var title: String {
        switch verdict {
        case .allowed: return L.t("approval.approvedTitle")
        case .rejected: return L.t("approval.refusedTitle")
        case nil: return L.format("approval.waitingForUser", name)
        }
    }

    private var subtitle: String {
        switch verdict {
        case .allowed: return L.format("approval.allowedNote", name)
        case .rejected: return L.format("approval.refusedNote", name)
        case nil: return answerable ? L.t("approval.slideNote") : L.t("approval.notAnswerable")
        }
    }

    @ViewBuilder
    private var controls: some View {
        if verdict == nil && answerable {
            VStack(spacing: Ink.Space.s) {
                SlideTrack(progress: $slide, onTick: tick) { answer(allow: true) }
                    .disabled(busy)
                if current.forced == true {
                    // Standing permission would not cover this step anyway: say why instead of offering it.
                    // Forced because the turn read outside text, or because the step is one that always asks (a routine).
                    Label(L.t(current.detail?.text?.contains("外部网页") == true ? "approval.webRequiresApproval" : "approval.alwaysAsks"),
                          systemImage: "exclamationmark.shield")
                        .font(Ink.footnote)
                        .foregroundStyle(Ink.warn)
                } else {
                    HStack(spacing: Ink.Space.s) {
                        choice(L.t("actions.allowAlways"), on: $always)
                        choice(L.t("actions.allowConversation"), on: $trustChat)
                    }
                }
                Button {
                    Haptics.light()
                    answer(allow: false)
                } label: {
                    Text(L.t("actions.rejectApproval"))
                        .font(.system(size: Ink.Size.body, weight: .semibold))
                        .foregroundStyle(Ink.inkSoft)
                        .frame(minHeight: 46)
                        .padding(.horizontal, Ink.Space.xl)
                        .contentShape(Rectangle())
                }
                .buttonStyle(TapStyle())
                .disabled(busy)
                .opacity(busy ? 0.4 : 1)
            }
            .transition(.blurReplace)
        }
    }

    // MARK: The slip

    private var slip: some View {
        VStack(alignment: .leading, spacing: Ink.Space.l) {
            HStack {
                Text(L.t("approval.approvalSheet"))
                    .font(.system(size: Ink.Size.small, weight: .bold))
                    .tracking(2)
                Spacer()
                Text(Self.clock(current.at.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date(), "HH:mm"))
                    .font(Ink.mono(Ink.Size.small))
            }
            .foregroundStyle(Ink.inkSoft)

            HStack(spacing: Ink.Space.m) {
                PetStill(size: 46, state: verdict == nil ? "notification" : "idle",
                         wash: bot.map(Ink.wash(for:)) ?? Ink.accentWash, avatar: true, bot: bot)
                    .padding(.top, Ink.Space.s)
                VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
                    Text(L.t("approval.from")).font(.system(size: Ink.Size.small)).foregroundStyle(Ink.inkSoft)
                    Text(name).font(Ink.mark(Ink.Size.title, bold: true, relativeTo: .title3))
                }
            }

            VStack(alignment: .leading, spacing: Ink.Space.s) {
                Text(L.t("approval.requestedAction")).font(.system(size: Ink.Size.small)).foregroundStyle(Ink.inkSoft)
                if let tool = current.tool, !tool.isEmpty {
                    Text(tool)
                        .font(.system(size: Ink.Size.body * accessibilityScale, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                detailSection
                if let reason = current.reason, !reason.isEmpty {
                    boundedScroll(maxHeight: 96 * UIScale.factor) {
                        Text(reason)
                            .font(.system(size: Ink.Size.sub * accessibilityScale))
                            .foregroundStyle(Ink.inkSoft)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let code = current.detail?.code, !code.isEmpty {
                    // The whole command, scrolled, never cut off: what is approved must be seen in full.
                    boundedScroll(maxHeight: 140 * UIScale.factor) {
                        Text(code)
                            .font(Ink.mono(Ink.Size.small))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, Ink.Space.m)
                    .padding(.vertical, Ink.Space.s)
                    .background(Ink.mine, in: RoundedRectangle(cornerRadius: Ink.Radius.small, style: .continuous))
                }
            }

            DashLine()
                .stroke(Ink.rule, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .frame(height: 1.5)

            VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
                Text(L.t("approval.signer")).font(.system(size: Ink.Size.small)).foregroundStyle(Ink.inkSoft)
                Text(L.t("approval.you")).font(.system(size: Ink.Size.body, weight: .semibold))
            }
            .frame(height: 62, alignment: .bottomLeading)
        }
        .foregroundStyle(Ink.ink)
        .padding(.init(top: 26, leading: 20, bottom: 22, trailing: 20))
        .frame(width: slipWidth, alignment: .leading)
        .background(SlipShape().fill(Ink.paperRaised))
        .overlay(alignment: .bottomTrailing) {
            Group {
                if verdict == .rejected {
                    Stamp(word: L.t("approval.refusedTitle"), date: Self.clock(stampedAt, "MM-dd HH:mm"), ink: Ink.inkSoft, side: stampSide)
                        .rotationEffect(.degrees(-14))
                } else {
                    // Approved: Clio's own seal, pressed beside your name, with when.
                    VStack(spacing: Ink.Space.xs) {
                        ClioSeal(size: stampSide * 0.61, tilt: -8)
                        Text(Self.clock(stampedAt, "MM-dd HH:mm"))
                            .font(Ink.mono(Ink.Size.micro, weight: .semibold))
                            .foregroundStyle(Ink.seal)
                    }
                }
            }
            .scaleEffect(verdict != nil ? 1 : 2.8)
            .opacity(verdict != nil ? 1 : 0)
            .padding(.trailing, Ink.Space.l)
            .padding(.bottom, Ink.Space.l)
        }
        .shadow(color: Color.black.opacity(0.18 - 0.06 * Double(press)), radius: 24 - 10 * press, y: 24 - 12 * press)
    }

    @ViewBuilder
    private var detailSection: some View {
        if let text = current.detail?.text, !text.isEmpty {
            let taintPrefix = Taint.reason + "\n\n"
            if text == Taint.reason {
                taintBanner(Taint.reason)
            } else if text.hasPrefix(taintPrefix) {
                taintBanner(Taint.reason)
                let bodyText = String(text.dropFirst(taintPrefix.count))
                if !bodyText.isEmpty {
                    scrollableDetailText(bodyText)
                }
            } else {
                scrollableDetailText(text)
            }
        }
    }

    private func taintBanner(_ words: String) -> some View {
        HStack(alignment: .top, spacing: Ink.Space.xs) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: Ink.Size.small))
                .foregroundStyle(Ink.warn)
            Text(words)
                .font(.system(size: Ink.Size.small * accessibilityScale, weight: .medium))
                .foregroundStyle(Ink.warn)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Ink.Space.s)
        .padding(.vertical, Ink.Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.warn.opacity(0.12), in: RoundedRectangle(cornerRadius: Ink.Radius.small, style: .continuous))
    }

    private func scrollableDetailText(_ words: String) -> some View {
        boundedScroll(maxHeight: 140 * UIScale.factor) {
            Text(words)
                .font(.system(size: Ink.Size.sub * accessibilityScale))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func boundedScroll<Inner: View>(maxHeight: CGFloat, @ViewBuilder content: () -> Inner) -> some View {
        let inner = content()
        return ViewThatFits(in: .vertical) {
            inner
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                inner
            }
        }
        .frame(maxHeight: maxHeight)
    }

    private static func clock(_ date: Date, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    // MARK: Answering

    private func tick(_ step: Int) {
        if step != lastTick {
            lastTick = step
            Haptics.tick(0.45 + 0.07 * CGFloat(step))
        }
    }

    /// The stamp only falls once the computer has taken the answer.
    private func choice(_ title: String, on: Binding<Bool>) -> some View {
        Button {
            Haptics.tick(0.5)
            on.wrappedValue.toggle()
        } label: {
            HStack(spacing: Ink.Space.xs) {
                Image(systemName: on.wrappedValue ? "checkmark.circle.fill" : "circle").font(.system(size: Ink.Size.small))
                Text(title).font(.system(size: Ink.Size.small * accessibilityScale, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(on.wrappedValue ? Ink.accent : Ink.inkSoft)
            .padding(.horizontal, Ink.Space.m)
            .frame(minHeight: 30)
            .background(on.wrappedValue ? Ink.accentWash : Color.clear, in: .capsule)
            .overlay(Capsule().strokeBorder(on.wrappedValue ? Color.clear : Ink.rule))
        }
        .buttonStyle(TapStyle())
        .disabled(busy)
    }

    private func answer(allow: Bool) {
        guard !busy else { return }
        busy = true
        note = nil
        let asked = current
        Task {
            do {
                try await team.answer(asked, allow: allow, always: always, trustChat: trustChat)
                handled.insert(asked.id)
                stamp(allow ? .allowed : .rejected)
            } catch {
                Haptics.lock()
                lastTick = 0
                withAnimation(.spring(response: 0.42, dampingFraction: 0.6)) {
                    slide = 0
                    note = "这张单子已经不在了。"
                }
                handled.insert(asked.id)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { advance() }
            }
        }
    }

    /// The stamp falls, lands with a thud, and the slip gives under it.
    private func stamp(_ result: Verdict) {
        stampedAt = Date()
        withAnimation(.spring(response: 0.24, dampingFraction: 0.62)) { verdict = result }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.11) {
            if result == .allowed { Haptics.thud() } else { Haptics.lock() }
            withAnimation(.spring(response: 0.1, dampingFraction: 0.7)) { press = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
                withAnimation(.spring(response: 0.55, dampingFraction: 0.38)) { press = 0 }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { advance() }
    }

    /// On to the next slip, or back when there is none.
    private func advance() {
        guard let next = team.approvals.first(where: { !handled.contains($0.id) }) else {
            dismiss()
            return
        }
        lastTick = 0
        withAnimation(.spring(response: 0.55, dampingFraction: 0.8)) {
            current = next
            verdict = nil
            slide = 0
            note = nil
            busy = false
            always = false
            trustChat = false
        }
    }
}

/// The round seal.
private struct ApprovalViewport: ViewModifier {
    let scrolls: Bool

    func body(content: Content) -> some View {
        if scrolls {
            ScrollView { content }
        } else {
            content
        }
    }
}

private struct Stamp: View {
    let word: String
    let date: String
    let ink: Color
    let side: CGFloat

    var body: some View {
        ZStack {
            Circle().strokeBorder(ink, lineWidth: 4)
            Circle().strokeBorder(ink, lineWidth: 1.5).padding(Ink.Space.s)
            VStack(spacing: Ink.Space.xs / 2) {
                Text(word)
                    .font(.system(size: Ink.Size.title, weight: .black))
                    .tracking(2)
                Text(date)
                    .font(Ink.mono(Ink.Size.micro, weight: .bold))
            }
            .foregroundStyle(ink)
        }
        .frame(width: side, height: side)
        .opacity(0.92)
        .accessibilityHidden(true)
    }
}

/// Slide to approve: a glass track with a knob that springs back unless it reaches the end.
private struct SlideTrack: View {
    @Binding var progress: CGFloat
    let onTick: (Int) -> Void
    let onDone: () -> Void

    private let height: CGFloat = 62
    private let knob: CGFloat = 52

    var body: some View {
        GeometryReader { proxy in
            let travel = max(1, proxy.size.width - knob - 10)
            ZStack(alignment: .leading) {
                Text(L.t("actions.slideToApprove"))
                    .font(.system(size: Ink.Size.body, weight: .semibold))
                    .foregroundStyle(Ink.inkSoft)
                    .frame(maxWidth: .infinity)
                    .opacity(1 - Double(progress) * 1.6)
                Capsule()
                    .fill(Ink.accentWash)
                    .frame(width: knob + 10 + travel * progress, height: height)
                Circle()
                    .fill(Ink.accent)
                    .overlay {
                        Image(systemName: "chevron.right")
                            .font(.system(size: Ink.Size.title, weight: .bold))
                            .foregroundStyle(Ink.paper)
                    }
                    .frame(width: knob, height: knob)
                    .shadow(color: Color.black.opacity(0.18), radius: 6, y: 4)
                    .scaleEffect(1 + 0.06 * progress)
                    .offset(x: 5 + travel * progress)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let next = max(0, min(1, value.translation.width / travel))
                                progress = next
                                onTick(Int(next * 8))
                            }
                            .onEnded { _ in
                                if progress > 0.86 {
                                    Haptics.lock()
                                    withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) { progress = 1 }
                                    onDone()
                                } else {
                                    Haptics.tick(0.5)
                                    withAnimation(.spring(response: 0.42, dampingFraction: 0.6)) { progress = 0 }
                                }
                            }
                    )
                    .accessibilityLabel(L.t("actions.slideToApprove"))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { onDone() }
            }
            .frame(height: height)
            .glassBacking(in: Capsule())
        }
        .frame(height: height)
    }
}

private struct DashLine: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

/// A slip of paper with a perforated top edge.
struct SlipShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let count = max(1, Int(rect.width / 18))
        let step = rect.width / CGFloat(count)
        let bite = step * 0.3
        let corner: CGFloat = 18
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        for index in 0..<count {
            let cx = rect.minX + (CGFloat(index) + 0.5) * step
            p.addLine(to: CGPoint(x: cx - bite, y: rect.minY))
            p.addArc(center: CGPoint(x: cx, y: rect.minY), radius: bite, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: true)
        }
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - corner))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - corner, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + corner, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - corner), control: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
