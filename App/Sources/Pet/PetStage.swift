import SwiftUI

/// What the conversation on screen is doing, as far as the pet is concerned.
enum PetMood: Equatable {
    case idle, thinking, writing, waiting, sweeping
    /// Working, with this many conversations running at once.
    case working(Int)

    var state: String {
        switch self {
        case .idle: "idle"
        case .thinking: "thinking"
        case .writing, .working: "working"
        case .waiting: "notification"
        case .sweeping: "sweeping"
        }
    }
}

/// The pet, standing on the top edge of the composer (or the bar above it): it acts out what is happening,
/// naps when nothing does, wanders a little, answers a poke, and speaks up in a bubble when another conversation
/// finishes or waits for you. Only its body takes touches; everything around it passes through.
struct PetStage: View {
    var mood: PetMood
    /// Opens 宠物设置.
    var openSettings: () -> Void

    @State private var library = PetLibrary.shared
    @State private var news = PetNews.shared
    @AppStorage("pet.x") private var restX = 0.22
    @Environment(\.accessibilityReduceMotion) private var calm

    @State private var drag: CGFloat = 0
    @State private var dragging = false
    @State private var wander: CGFloat = 0
    @State private var facingRight = false
    /// A one-off: a reaction, a moment of joy, a stumble. Plays over the state until `until`.
    @State private var oneOff: (anim: String, pose: WhalePose?, until: Date)?
    @State private var since = Date()
    @State private var shownAnim = ""
    @State private var lastTouch = Date()
    @State private var now = Date()
    @State private var nextIdle = Date().addingTimeInterval(.random(in: 45...150))
    @State private var taps: [Date] = []
    @State private var bounce = false
    @State private var tilt = 0.0

    private var bodyHeight: CGFloat { CGFloat(30 * library.factor) * UIScale.factor }
    private var whaleSize: CGFloat { CGFloat(44 * library.factor) * UIScale.factor }
    private var figureWidth: CGFloat {
        guard let pack = library.pack else { return whaleSize * 1.15 }
        return bodyHeight * CGFloat(pack.canvasW / pack.content.h)
    }
    /// From the feet to the top of the drawing.
    private var standHeight: CGFloat {
        guard let pack = library.pack else { return whaleSize }
        return bodyHeight * CGFloat(pack.baseline / pack.content.h)
    }

    private var asleep: Bool {
        guard mood == .idle, oneOff == nil, !dragging else { return false }
        let after = Double(library.pack?.sleepAfter ?? 60_000) / 1000
        return now.timeIntervalSince(lastTouch) > after
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let margin = standHeight * 0.6 + Ink.Space.page
            let x = min(max(margin + (width - margin * 2) * restX + wander + drag, margin), width - margin)
            ZStack(alignment: .bottomLeading) {
                Color.clear
                if library.shown {
                    figure
                        .frame(width: figureWidth, height: standHeight, alignment: .bottom)
                        .contentShape(Rectangle())
                        .gesture(tapGesture(width: figureWidth))
                        .simultaneousGesture(dragGesture(width: width, margin: margin))
                        .contextMenu { menu }
                        .accessibilityLabel(L.t("nav.pet") + "，点一下逗它，拖动换位置，长按有菜单")
                        .position(x: x, y: proxy.size.height - standHeight / 2)
                        .transition(.scale(scale: 0.5, anchor: .bottom).combined(with: .opacity))
                    if let bubble = news.bubble {
                        PetBubble(bubble: bubble)
                            .frame(maxWidth: width - Ink.Space.page * 2)
                            .fixedSize()
                            .position(x: min(max(x, 120), width - 120), y: proxy.size.height - standHeight - 26)
                            .transition(.opacity.combined(with: .offset(y: 6)))
                    }
                }
            }
        }
        .frame(height: library.shown ? standHeight : 0)
        .animation(Ink.Motion.settle, value: news.bubble)
        .animation(Ink.Motion.settle, value: library.shown)
        .task(id: "clock") {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                tick()
            }
        }
        .onChange(of: news.react?.at) { _, _ in
            guard let kind = news.react?.kind else { return }
            touch()
            switch kind {
            case .done: play(state: "attention", pose: .cheering, seconds: 3)
            case .failed: play(state: "error", pose: .thinking, seconds: 3)
            case .approval, .answer: break
            }
        }
        .onChange(of: mood) { _, _ in touch() }
    }

    // MARK: What is drawn

    @ViewBuilder
    private var figure: some View {
        if let pack = library.pack {
            let anim = currentAnim(pack)
            SpritePet(pack: pack, anim: anim, since: since, bodyHeight: bodyHeight, mirrored: mirrored(pack))
                .onChange(of: anim) { _, _ in since = Date() }
        } else {
            PetFigure(size: whaleSize, pose: whalePose, writing: isWriting)
            .scaleEffect(x: facingRight ? -1 : 1, y: 1)
            .scaleEffect(dragging ? 1.12 : (bounce ? 1.1 : 1), anchor: .bottom)
            .rotationEffect(.degrees(tilt), anchor: .bottom)
            .shadow(color: .black.opacity(dragging ? 0.16 : 0.06), radius: dragging ? 10 : 3, y: dragging ? 6 : 1)
        }
    }

    private var isWriting: Bool {
        switch mood {
        case .writing, .working: true
        default: false
        }
    }

    private var whalePose: WhalePose {
        if let pose = oneOff?.pose { return pose }
        if asleep { return .sleeping }
        switch mood {
        case .idle: return .idle
        case .thinking: return .thinking
        case .writing, .working, .sweeping: return .writing
        case .waiting: return .waiting
        }
    }

    private func currentAnim(_ pack: PetPack) -> String {
        if dragging, let drag = pack.reaction("drag") { return drag }
        if let one = oneOff, pack.animations[one.anim] != nil { return one.anim }
        if asleep { return pack.anim(for: "sleeping") ?? "" }
        if wander != 0, mood == .idle, let roam = pack.roamAnim, abs(wanderTarget - wander) > 1 { return roam }
        var busy = 1
        if case .working(let count) = mood { busy = count }
        return pack.anim(for: mood.state, busy: busy) ?? ""
    }

    private func mirrored(_ pack: PetPack) -> Bool {
        switch pack.faces {
        case "front": false
        case "right": !facingRight
        default: facingRight
        }
    }

    @State private var wanderTarget: CGFloat = 0

    // MARK: Touch

    private func tapGesture(width: CGFloat) -> some Gesture {
        SpatialTapGesture().onEnded { value in
            let wasAsleep = asleep
            touch()
            if wasAsleep {
                play(state: "waking", pose: .idle, seconds: Double(library.pack?.wakeMs ?? 1200) / 1000)
                return
            }
            // A bubble about another conversation: the pet takes you there.
            if let bubble = news.bubble {
                news.dismiss()
                NotificationCenter.default.post(name: .clioOpenChat, object: bubble.chat)
                return
            }
            let now = Date()
            taps = taps.filter { now.timeIntervalSince($0) < 1.1 } + [now]
            Haptics.tick(0.5)
            if taps.count >= 6 {
                taps = []
                react("annoyed", fallback: "tickle", whale: { shake() })
            } else if taps.count >= 3 {
                react("tickle", fallback: nil, whale: { wiggle() })
            } else {
                let left = value.location.x < width / 2
                react(left ? "tapLeft" : "tapRight", fallback: nil, whale: { hop(left: left) })
            }
        }
    }

    private func dragGesture(width: CGFloat, margin: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                if !dragging {
                    dragging = true
                    touch()
                    Haptics.tick(0.4)
                }
                drag = value.translation.width
            }
            .onEnded { value in
                let span = max(width - margin * 2, 1)
                let landed = margin + span * restX + wander + value.translation.width
                withAnimation(Ink.Motion.unfold) {
                    restX = min(max((landed - margin) / span, 0), 1)
                    wander = 0
                    wanderTarget = 0
                    drag = 0
                    dragging = false
                }
                Haptics.tick(0.6)
            }
    }

    @ViewBuilder
    private var menu: some View {
        if library.packs.count > 0 {
            Button(L.t("pet.change"), systemImage: "arrow.triangle.2.circlepath") { library.next() }
        }
        Button(L.t("pet.hideHour"), systemImage: "eye.slash") {
            withAnimation(Ink.Motion.settle) { library.hideForAnHour() }
        }
        Button(L.t("pet.settings"), systemImage: "gearshape") { openSettings() }
    }

    // MARK: Moving

    private func touch() {
        lastTouch = Date()
        now = lastTouch
    }

    private func react(_ name: String, fallback: String?, whale: () -> Void) {
        if let pack = library.pack {
            if let anim = pack.reaction(name) ?? fallback.flatMap({ pack.reaction($0) }) {
                let ms = pack.animations[anim]?.total ?? 1200
                oneOff = (anim, nil, Date().addingTimeInterval(Double(ms) / 1000))
                since = Date()
            }
        } else {
            whale()
        }
    }

    private func play(state: String, pose: WhalePose, seconds: Double) {
        if let pack = library.pack {
            guard let anim = pack.anim(for: state) else { return }
            let hold = Double(pack.minDisplay[state] ?? Int(seconds * 1000)) / 1000
            oneOff = (anim, nil, Date().addingTimeInterval(hold))
            since = Date()
        } else {
            oneOff = ("", pose, Date().addingTimeInterval(seconds))
            if pose == .cheering { hop(left: false) }
        }
    }

    private func hop(left: Bool) {
        guard !calm else { return }
        withAnimation(.spring(response: 0.22, dampingFraction: 0.45)) { bounce = true; tilt = left ? -8 : 8 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) { bounce = false; tilt = 0 }
        }
    }

    private func wiggle() {
        guard !calm else { return }
        for (step, angle) in [10.0, -10, 8, -8, 0].enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * 0.08) {
                withAnimation(.easeInOut(duration: 0.08)) { tilt = angle }
            }
        }
    }

    private func shake() {
        guard !calm else { return }
        Haptics.thud()
        for (step, angle) in [-4.0, 4, -4, 4, 0].enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * 0.05) {
                withAnimation(.linear(duration: 0.05)) { tilt = angle }
            }
        }
    }

    /// Once a second: one-offs run out, naps begin, and now and then a little wander or an idle flourish.
    private func tick() {
        now = Date()
        if let one = oneOff, one.until < now { oneOff = nil }
        guard !calm, library.shown, mood == .idle, !dragging, oneOff == nil, !asleep, news.bubble == nil, now > nextIdle else { return }
        let pack = library.pack
        let every: (mean: Int, min: Int, max: Int) = pack?.idleEvery ?? (mean: 120_000, min: 45_000, max: 300_000)
        nextIdle = now.addingTimeInterval(Double(Int.random(in: every.min...Swift.max(every.min, every.max))) / 1000 * 0.6)
        if Bool.random() || pack?.idlePool.isEmpty != false {
            // Wander a little way along the edge, turning to face where it goes.
            let step = CGFloat.random(in: 24...56) * (Bool.random() ? 1 : -1)
            facingRight = step > 0
            wanderTarget = step
            withAnimation(.easeInOut(duration: 1.6)) { wander = step }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) { wanderTarget = wander }
        } else if let pack, let pick = pack.idlePool.randomElement() {
            oneOff = (pick.anim, nil, now.addingTimeInterval(Double(pick.ms) / 1000))
            since = now
        }
    }
}

/// Clio's own pet: the figure from 形象 (卷卷, 墨团, 天鹅, the whale or your pictures). Figures other than 卷卷
/// hold a little scroll, as Clio holds hers; it opens while they write and rolls up again when they are done.
struct PetFigure: View {
    var size: CGFloat
    var pose: WhalePose
    var writing: Bool
    @AppStorage("persona") private var stored = Data()

    private var bare: Persona {
        var persona = (try? JSONDecoder().decode(Persona.self, from: stored)) ?? Persona()
        persona.frame = .bare
        return persona
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // Standing on the bar, not framed like a portrait: the whale without its disc.
            Whale(size: size, pose: pose, persona: bare)
            if bare.kind != .scroll {
                ScrollProp(open: writing, size: size * 0.5)
                    .offset(x: size * 0.1, y: -size * 0.02)
            }
        }
        .frame(width: size * 1.15, height: size, alignment: .bottom)
        .animation(Ink.Motion.settle, value: writing)
    }
}

/// A little scroll: rolled up into one tube while idle, opened out between its two rods while writing.
private struct ScrollProp: View {
    var open: Bool
    var size: CGFloat

    var body: some View {
        let rodW = size * 0.13, rodH = size * 0.5
        HStack(spacing: 0) {
            rod(rodW, rodH)
            ZStack {
                Rectangle().fill(Ink.paperRaised)
                VStack(spacing: size * 0.07) {
                    ForEach(0..<3, id: \.self) { _ in Capsule().fill(Ink.inkFaint.opacity(0.7)).frame(height: max(1, size * 0.035)) }
                }
                .padding(.horizontal, size * 0.08)
                .opacity(open ? 1 : 0)
            }
            .frame(width: open ? size * 0.72 : size * 0.42, height: open ? rodH * 0.84 : rodW * 1.25)
            .overlay(Rectangle().strokeBorder(Ink.inkSoft.opacity(0.5), lineWidth: 0.5))
            rod(rodW, rodH)
        }
        .rotationEffect(.degrees(open ? -8 : -24))
        .accessibilityHidden(true)
    }

    /// When rolled up, the rods are only the round ends of the tube.
    private func rod(_ width: CGFloat, _ height: CGFloat) -> some View {
        Capsule().fill(Ink.accent.opacity(0.85)).frame(width: width, height: open ? height : width * 1.5)
    }
}

/// One line about another conversation. Tap it to go there; swipe it up to put it away.
struct PetBubble: View {
    let bubble: PetNews.Bubble

    var body: some View {
        Text(bubble.text)
            .font(.system(size: Ink.Size.small, weight: .medium))
            .foregroundStyle(bubble.kind == .failed ? Ink.stop : Ink.ink)
            .lineLimit(1)
            .padding(.horizontal, Ink.Space.m)
            .padding(.vertical, Ink.Space.s)
            .background(Ink.paperRaised, in: .capsule)
            .overlay(Capsule().strokeBorder(Ink.rule, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
            .contentShape(.capsule)
            .onTapGesture {
                PetNews.shared.dismiss()
                NotificationCenter.default.post(name: .clioOpenChat, object: bubble.chat)
            }
            .gesture(DragGesture(minimumDistance: 10).onEnded { value in
                if value.translation.height < -10 { PetNews.shared.dismiss() }
            })
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("打开那段\(L.t("chat.conversation"))")
    }
}
