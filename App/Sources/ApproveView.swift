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
                        Text("后面还有 \(waiting) 张")
                            .font(.system(size: Ink.Size.sub, weight: .semibold))
                            .foregroundStyle(Ink.ink)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 34)
                            .glassEffect(.regular, in: .capsule)
                            .transition(.opacity)
                    }
                    Spacer()
                    Button {
                        Haptics.light()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: Ink.Size.body, weight: .semibold))
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .accessibilityLabel("关闭")
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

                Spacer(minLength: 12)

                ZStack {
                    if waiting > 0 && !largeText {
                        SlipShape()
                            .fill(Ink.paperRaised)
                            .frame(width: 300, height: 300)
                            .rotationEffect(.degrees(5))
                            .offset(x: 14, y: 12)
                            .blur(radius: 1.5)
                            .opacity(0.8)
                            .shadow(color: Ink.ink.opacity(0.10), radius: 14, y: 14)
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
                            removal: .offset(x: 300, y: -520).combined(with: .opacity)
                        ))
                }
                .scaleEffect(shown ? 1 : 0.9)
                .opacity(shown ? 1 : 0)
                .blur(radius: shown ? 0 : 10)

                Spacer(minLength: 12)

                VStack(spacing: 10) {
                    Text(title)
                        .font(Ink.serif(28, bold: true, relativeTo: .title))
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
                        .padding(.top, 18)
                        .frame(minHeight: largeText ? nil : 164, alignment: .top)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            }
            .modifier(ApprovalViewport(scrolls: largeText))
        }
        .fontDesign(.rounded)
        .onAppear {
            Haptics.prepare()
            withAnimation(.spring(response: 0.6, dampingFraction: 0.72).delay(0.1)) { shown = true }
        }
        .onChange(of: team.approvals) {
            // Answered somewhere else while this slip was open.
            guard verdict == nil, !busy, !team.approvals.contains(where: { $0.id == current.id }) else { return }
            handled.insert(current.id)
            withAnimation(.smooth) { note = "这张单子已经在别处处理了。" }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { advance() }
        }
    }

    private var title: String {
        switch verdict {
        case .allowed: return "盖章，放行"
        case .rejected: return "已拒绝"
        case nil: return "\(name)在等你点头"
        }
    }

    private var subtitle: String {
        switch verdict {
        case .allowed: return "\(name)已经继续干活。"
        case .rejected: return "\(name)不会做这件事。"
        case nil: return answerable ? "向右滑到底，就算批准。" : "这张单子现在答不了。"
        }
    }

    @ViewBuilder
    private var controls: some View {
        if verdict == nil && answerable {
            VStack(spacing: 6) {
                SlideTrack(progress: $slide, onTick: tick) { answer(allow: true) }
                    .disabled(busy)
                if current.forced == true {
                    // Standing permission would not cover this step anyway: say why instead of offering it.
                    Label("这一轮读过网页，这一步每次都要你点头", systemImage: "exclamationmark.shield")
                        .font(Ink.footnote)
                        .foregroundStyle(Ink.warn)
                } else {
                    let choices = largeText ? AnyLayout(VStackLayout(alignment: .leading, spacing: Ink.Space.s)) :
                        AnyLayout(HStackLayout(spacing: Ink.Space.s))
                    choices {
                        choice("以后都允许", on: $always)
                        choice(Words.t("这段絮语都放行"), on: $trustChat)
                    }
                }
                Button {
                    Haptics.light()
                    answer(allow: false)
                } label: {
                    Text("不批准")
                        .font(.system(size: Ink.Size.body * accessibilityScale, weight: .semibold))
                        .foregroundStyle(Ink.inkSoft)
                        .frame(minHeight: 46)
                        .padding(.horizontal, 24)
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
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("落 印 笺")
                    .font(.system(size: Ink.Size.small, weight: .bold))
                    .tracking(2)
                Spacer()
                Text(Self.clock(current.at.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date(), "HH:mm"))
                    .font(Ink.mono(Ink.Size.small))
            }
            .foregroundStyle(Ink.inkSoft)

            HStack(spacing: 12) {
                PetStill(size: 46, state: verdict == nil ? "notification" : "idle",
                         wash: bot.map(Ink.wash(for:)) ?? Ink.accentWash, avatar: true)
                    .padding(.top, 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text("来自").font(.system(size: Ink.Size.small)).foregroundStyle(Ink.inkSoft)
                    Text(name).font(Ink.mark(20, bold: true, relativeTo: .title3)).lineLimit(largeText ? nil : 1)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("想做的事").font(.system(size: Ink.Size.small)).foregroundStyle(Ink.inkSoft)
                if let tool = current.tool, !tool.isEmpty {
                    Text(tool).font(.system(size: Ink.Size.body * accessibilityScale, weight: .semibold)).lineLimit(largeText ? nil : 2)
                }
                if let text = current.detail?.text, !text.isEmpty {
                    Text(text).font(.system(size: Ink.Size.sub * accessibilityScale)).lineLimit(largeText ? nil : 4)
                }
                if let reason = current.reason, !reason.isEmpty {
                    Text(reason).font(.system(size: Ink.Size.sub * accessibilityScale)).foregroundStyle(Ink.inkSoft).lineLimit(largeText ? nil : 4)
                }
                if let code = current.detail?.code, !code.isEmpty {
                    // The whole command, scrolled, never cut off: what is approved must be seen in full.
                    ScrollView {
                        Text(code)
                            .font(Ink.mono(Ink.Size.small))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 88)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Ink.mine, in: RoundedRectangle(cornerRadius: Ink.Radius.small, style: .continuous))
                }
            }

            DashLine()
                .stroke(Ink.rule, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .frame(height: 1.5)

            VStack(alignment: .leading, spacing: 2) {
                Text(Words.t("落印")).font(.system(size: Ink.Size.small)).foregroundStyle(Ink.inkSoft)
                Text("你").font(.system(size: Ink.Size.body, weight: .semibold))
            }
            .frame(height: 62, alignment: .bottomLeading)
        }
        .foregroundStyle(Ink.ink)
        .padding(.init(top: 26, leading: 20, bottom: 22, trailing: 20))
        .frame(width: largeText ? nil : 300)
        .frame(maxWidth: largeText ? .infinity : nil, alignment: .leading)
        .background(SlipShape().fill(Ink.paperRaised))
        .overlay(alignment: .bottomTrailing) {
            Group {
                if verdict == .rejected {
                    Stamp(word: "已拒绝", date: Self.clock(stampedAt, "MM-dd HH:mm"), ink: Ink.inkSoft)
                        .rotationEffect(.degrees(-14))
                } else {
                    // Approved: Clio's own seal, pressed beside your name, with when.
                    VStack(spacing: Ink.Space.xs) {
                        ClioSeal(size: 66, tilt: -8)
                        Text(Self.clock(stampedAt, "MM-dd HH:mm"))
                            .font(Ink.mono(Ink.Size.micro, weight: .semibold))
                            .foregroundStyle(Ink.seal)
                    }
                }
            }
            .scaleEffect(verdict != nil ? 1 : 2.8)
            .opacity(verdict != nil ? 1 : 0)
            .padding(.trailing, 18)
            .padding(.bottom, 16)
        }
        .shadow(color: Ink.ink.opacity(0.18 - 0.06 * Double(press)), radius: 24 - 10 * press, y: 24 - 12 * press)
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
            HStack(spacing: 4) {
                Image(systemName: on.wrappedValue ? "checkmark.circle.fill" : "circle").font(.system(size: Ink.Size.small))
                Text(title).font(.system(size: Ink.Size.small * accessibilityScale, weight: .medium))
            }
            .foregroundStyle(on.wrappedValue ? Ink.accent : Ink.inkSoft)
            .padding(.horizontal, 10)
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

    var body: some View {
        ZStack {
            Circle().strokeBorder(ink, lineWidth: 4)
            Circle().strokeBorder(ink, lineWidth: 1.5).padding(7)
            VStack(spacing: 2) {
                Text(word)
                    .font(.system(size: 24, weight: .black))
                    .tracking(2)
                Text(date)
                    .font(Ink.mono(Ink.Size.micro, weight: .bold))
            }
            .foregroundStyle(ink)
        }
        .frame(width: 108, height: 108)
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
                Text(Words.t("滑过去，落印"))
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
                    .shadow(color: Ink.ink.opacity(0.18), radius: 6, y: 4)
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
                    .accessibilityLabel("滑动批准")
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
