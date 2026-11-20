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
    /// The companion's own face ("pet:<id>"), when it has one: that pet stands here instead of the one picked in 宠物设置.
    var face: String? = nil
    /// Opens 宠物设置.
    var openSettings: () -> Void

    @State private var library = PetLibrary.shared
    @State private var news = PetNews.shared
    @AppStorage("pet.x") private var restX = 0.22
    /// How far above the composer it was left, in points: dragged up, it stays up there over the conversation.
    @AppStorage("pet.lift") private var lift = 0.0
    @Environment(\.accessibilityReduceMotion) private var calm

    @State private var drag: CGFloat = 0
    @State private var dragUp: CGFloat = 0
    @State private var dragging = false
    @State private var wander: CGFloat = 0
    @State private var facingRight = false
    /// A one-off: a reaction, a moment of joy, a stumble. Plays over the state until `until`.
    @State private var oneOff: (anim: String, until: Date)?
    @State private var since = Date()
    @State private var shownAnim = ""
    @State private var lastTouch = Date()
    @State private var now = Date()
    @State private var nextIdle = Date().addingTimeInterval(.random(in: 45...150))
    @State private var taps: [Date] = []

    private var bodyHeight: CGFloat { CGFloat(30 * library.factor) * UIScale.factor }
    private var figureWidth: CGFloat {
        guard let pack = pack else { return bodyHeight }
        return bodyHeight * CGFloat(pack.canvasW / pack.content.h)
    }
    /// From the feet to the top of the drawing.
    private var standHeight: CGFloat {
        guard let pack = pack else { return bodyHeight }
        return bodyHeight * CGFloat(pack.baseline / pack.content.h)
    }

    private var asleep: Bool {
        guard mood == .idle, oneOff == nil, !dragging else { return false }
        let after = Double(pack?.sleepAfter ?? 60_000) / 1000
        return now.timeIntervalSince(lastTouch) > after
    }

    private var pack: PetPack? {
        if let face, face.hasPrefix("pet:"),
           let own = library.packs.first(where: { $0.id == String(face.dropFirst(4)) }) { return own }
        return library.pack
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let margin = standHeight * 0.6 + Ink.Space.page
            let x = min(max(margin + (width - margin * 2) * restX + wander + drag, margin), width - margin)
            let height = min(max(CGFloat(lift) + dragUp, 0), maxLift)
            ZStack(alignment: .bottomLeading) {
                Color.clear
                if library.shown, pack != nil {
                    figure
                        .frame(width: figureWidth, height: standHeight, alignment: .bottom)
                        .contentShape(Rectangle())
                        .gesture(tapGesture(width: figureWidth))
                        .simultaneousGesture(dragGesture(width: width, margin: margin))
                        .contextMenu { menu }
                        .accessibilityLabel(L.t("nav.pet") + "，点一下逗它，拖动换位置，长按有菜单")
                        .position(x: x, y: proxy.size.height - standHeight / 2 - height)
                        .transition(.scale(scale: 0.5, anchor: .bottom).combined(with: .opacity))
                    if let bubble = news.bubble {
                        PetBubble(bubble: bubble)
                            .frame(maxWidth: width - Ink.Space.page * 2)
                            .fixedSize()
                            .position(x: min(max(x, 120), width - 120), y: proxy.size.height - standHeight - 26 - height)
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
            case .done: play(state: "attention", seconds: 3)
            case .failed: play(state: "error", seconds: 3)
            case .approval, .answer: break
            }
        }
        .onChange(of: mood) { _, _ in touch() }
    }

    // MARK: What is drawn

    @ViewBuilder
    private var figure: some View {
        if let pack = pack {
            let anim = currentAnim(pack)
            SpritePet(pack: pack, anim: anim, since: since, bodyHeight: bodyHeight, mirrored: mirrored(pack))
                .onChange(of: anim) { _, _ in since = Date() }
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
                play(state: "waking", seconds: Double(pack?.wakeMs ?? 1200) / 1000)
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
                react("annoyed", fallback: "tickle")
            } else if taps.count >= 3 {
                react("tickle", fallback: nil)
            } else {
                let left = value.location.x < width / 2
                react(left ? "tapLeft" : "tapRight", fallback: nil)
            }
        }
    }

    /// The highest it can be lifted: well up the conversation, below the top bar.
    private var maxLift: CGFloat { max(0, UIScreen.main.bounds.height * 0.62) }

    /// Any direction. While the finger is down it follows with no animation at all: an animation trailing each
    /// move is what left ghost copies behind it. Where it is let go, it stays.
    private func dragGesture(width: CGFloat, margin: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
                var still = Transaction()
                still.disablesAnimations = true
                withTransaction(still) {
                    if !dragging {
                        dragging = true
                        touch()
                        Haptics.tick(0.4)
                    }
                    drag = value.translation.width
                    dragUp = -value.translation.height
                }
            }
            .onEnded { value in
                let span = max(width - margin * 2, 1)
                let landed = margin + span * restX + wander + value.translation.width
                var still = Transaction()
                still.disablesAnimations = true
                withTransaction(still) {
                    restX = min(max((landed - margin) / span, 0), 1)
                    lift = Double(min(max(CGFloat(lift) - value.translation.height, 0), maxLift))
                    wander = 0
                    wanderTarget = 0
                    drag = 0
                    dragUp = 0
                    dragging = false
                }
                Haptics.tick(0.6)
            }
    }

    @ViewBuilder
    private var menu: some View {
        if packs.count > 1 {
            Button(L.t("pet.change"), systemImage: "arrow.triangle.2.circlepath") { library.next() }
        }
        Button(L.t("pet.hideHour"), systemImage: "eye.slash") {
            withAnimation(Ink.Motion.settle) { library.hideForAnHour() }
        }
        if lift > 0 {
            Button("回到输入框上", systemImage: "arrow.down.to.line") {
                withAnimation(Ink.Motion.unfold) { lift = 0 }
            }
        }
        Button(L.t("pet.settings"), systemImage: "gearshape") { openSettings() }
    }

    // MARK: Moving

    private func touch() {
        lastTouch = Date()
        now = lastTouch
    }

    private func react(_ name: String, fallback: String?) {
        guard let pack = pack,
              let anim = pack.reaction(name) ?? fallback.flatMap({ pack.reaction($0) }) else { return }
        let ms = pack.animations[anim]?.total ?? 1200
        oneOff = (anim, Date().addingTimeInterval(Double(ms) / 1000))
        since = Date()
    }

    private func play(state: String, seconds: Double) {
        guard let pack = pack, let anim = pack.anim(for: state) else { return }
        let hold = Double(pack.minDisplay[state] ?? Int(seconds * 1000)) / 1000
        oneOff = (anim, Date().addingTimeInterval(hold))
        since = Date()
    }

    /// Once a second: one-offs run out, naps begin, and now and then a little wander or an idle flourish.
    private func tick() {
        now = Date()
        if let one = oneOff, one.until < now { oneOff = nil }
        guard !calm, library.shown, mood == .idle, !dragging, oneOff == nil, !asleep, news.bubble == nil, now > nextIdle else { return }
        let pack = self.pack
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
            oneOff = (pick.anim, now.addingTimeInterval(Double(pick.ms) / 1000))
            since = now
        }
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
