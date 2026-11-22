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
    let perch: PetPerch

    @State private var library = PetLibrary.shared
    @State private var news = PetNews.shared
    @AppStorage("pet.x") private var restX = 0.22
    @AppStorage("pet.lift") private var legacyLift = 0.0
    /// Left over from when the pet could be pinned anywhere up the screen. It now always stands on the composer
    /// (主人定的，像 DSH Go): an old pin is cleared on first show.
    @AppStorage("pet.pinnedY") private var pinnedY = -1.0
    /// How far it may be held up while dragged, before it drops back on the composer.
    private static let liftLimit: CGFloat = 28
    @Environment(\.accessibilityReduceMotion) private var calm
    @Environment(\.displayScale) private var displayScale

    @State private var drag: CGFloat = 0
    @State private var dragUp: CGFloat = 0
    @State private var dragStart: CGFloat?
    private var dragging: Bool { dragStart != nil }
    @State private var wander: CGFloat = 0
    @State private var facingRight = false
    /// A one-off: a reaction, a moment of joy, a stumble. Plays over the state until `until`.
    @State private var oneOff: (anim: String, until: Date)?
    @State private var landingAnim: String?
    @State private var landingCount = 0
    @State private var handledLanding = 0
    @State private var since = Date()
    @State private var lastTouch = Date()
    @State private var sleeping = false
    @State private var nextIdle = Date().addingTimeInterval(.random(in: 45...150))
    @State private var taps: [Date] = []

    private var mood: PetMood { perch.mood }

    private var asleep: Bool { sleeping && mood == .idle && oneOff == nil && !dragging }

    private var pack: PetPack? { library.pack(for: perch.face) }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            if library.shown, !perch.suppressed, let pack, width > 0, height > 0 {
                let unit = PetSize.unit(for: pack, factor: library.factor, displayScale: displayScale,
                                        maxWidth: max(1, width - Ink.Space.page * 2), maxHeight: height / 3)
                let figureWidth = CGFloat(pack.canvasW) * unit
                let stand = CGFloat(pack.baseline) * unit
                let margin = min(width / 2, figureWidth / 2 + Ink.Space.page)
                // It never stands under the jump buttons while they show (they would be hidden and untappable).
                let right = max(margin, width - margin - perch.keepOutRight)
                let foot = foot(in: height, stand: stand)
                let buttons = perch.replyActions
                let overlaps = !buttons.isNull && buttons.minY < foot && buttons.maxY > foot - stand
                let left = overlaps && !dragging
                    ? min(right, max(margin, buttons.maxX - perch.chatOffset + figureWidth / 2 + Ink.Space.xs))
                    : margin
                let x = min(max(margin + (width - margin * 2) * restX + wander + drag, left), right)
                ZStack(alignment: .topLeading) {
                    pet(pack, unit: unit, width: figureWidth, stand: stand)
                        .simultaneousGesture(dragGesture(width: width, height: height, margin: margin, foot: foot, stand: stand))
                        .position(x: aligned(x + perch.chatOffset, offset: figureWidth / 2), y: aligned(foot, offset: stand) - stand / 2)
                        .transition(.opacity)
                    if let bubble = news.bubble {
                        PetBubble(bubble: bubble)
                            .frame(maxWidth: max(1, width - Ink.Space.page * 2))
                            .fixedSize()
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { perch.bubbleHit = $0 }
                            .onDisappear { perch.bubbleHit = .null }
                            .position(x: min(max(x, min(120, width / 2)), max(width - 120, width / 2)) + perch.chatOffset,
                                      y: foot - stand - 26)
                            .transition(.opacity)
                    }
                }
                .frame(width: width, height: height)
                .onAppear {
                    if pinnedY >= 0 { pinnedY = -1 }
                    if legacyLift > 0 { legacyLift = 0 }
                }
            }
        }
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

    /// Always the composer's top edge; while dragged, held up a little above it.
    private func foot(in height: CGFloat, stand: CGFloat) -> CGFloat {
        if dragging { return min(max(perch.foot - min(max(dragUp, 6), Self.liftLimit), stand), height) }
        return perch.foot
    }

    private func aligned(_ point: CGFloat, offset: CGFloat) -> CGFloat {
        ((point - offset) * displayScale).rounded() / displayScale + offset
    }

    // MARK: What is drawn

    private func pet(_ pack: PetPack, unit: CGFloat, width: CGFloat, stand: CGFloat) -> some View {
        let anim = currentAnim(pack)
        return SpritePet(pack: pack, anim: anim, since: since, unit: unit, mirrored: mirrored(pack))
            .keyframeAnimator(initialValue: CGFloat(1), trigger: landingCount) { pet, height in
                pet.scaleEffect(x: 2 - height, y: height, anchor: .bottom)
            } keyframes: { _ in
                KeyframeTrack(\.self) {
                    LinearKeyframe(0.92, duration: 0.045)
                    CubicKeyframe(1.035, duration: 0.09)
                    CubicKeyframe(1, duration: 0.1)
                }
            }
            .frame(width: width, height: stand, alignment: .bottom)
            .contentShape(Rectangle())
            .gesture(tapGesture(width: width))
            .contextMenu { menu }
            .accessibilityLabel(L.t("nav.pet") + "，点一下逗它，左右拖动换位置，长按有菜单")
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { perch.bodyHit = $0 }
            .onDisappear { perch.bodyHit = .null }
            .onChange(of: anim) { since = Date() }
            .task(id: perch.landing) {
                guard perch.landing != handledLanding else { return }
                handledLanding = perch.landing
                guard !calm, pinnedY < 0, !dragging else { return }
                landingCount += 1
                landingAnim = pack.motionAnimation(["land", "landing", "jump-land", "jump_land", "jump"])
                    ?? pack.anim(for: "idle")
                since = Date()
                try? await Task.sleep(for: .milliseconds(pack.animations[landingAnim ?? ""]?.total ?? 230))
                if !Task.isCancelled { landingAnim = nil }
            }
    }

    private func currentAnim(_ pack: PetPack) -> String {
        if dragging, let drag = pack.reaction("drag") { return drag }
        if !calm, pinnedY < 0 {
            if perch.rising, let jump = pack.motionAnimation(["jump", "jump-up", "jump_up"]) { return jump }
            if let landingAnim, pack.animations[landingAnim] != nil { return landingAnim }
        }
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

    /// A drag moves it left or right along the composer. Pulling up only lifts it a little while held; let go and it
    /// drops back onto the composer at the new spot.
    private func dragGesture(width: CGFloat, height: CGFloat, margin: CGFloat, foot: CGFloat, stand: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
                var still = Transaction()
                still.disablesAnimations = true
                withTransaction(still) {
                    if dragStart == nil {
                        dragStart = foot
                        touch()
                        Haptics.tick(0.4)
                    }
                    drag = value.translation.width
                    dragUp = max(0, -value.translation.height) * 0.4
                }
            }
            .onEnded { value in
                let span = max(width - margin * 2, 1)
                let landed = margin + span * restX + wander + value.translation.width
                var still = Transaction()
                still.disablesAnimations = true
                withTransaction(still) {
                    restX = min(max((landed - margin) / span, 0), 1)
                    wander = 0
                    wanderTarget = 0
                    drag = 0
                    dragUp = 0
                    dragStart = nil
                }
                // A small bump as it lands back on the composer.
                if !calm { landingCount += 1 }
                Haptics.tick(0.6)
            }
    }

    @ViewBuilder
    private var menu: some View {
        if library.packs.count > 1 {
            Button(L.t("pet.change"), systemImage: "arrow.triangle.2.circlepath") { library.next() }
        }
        Button(L.t("pet.hideHour"), systemImage: "eye.slash") {
            withAnimation(Ink.Motion.settle) { library.hideForAnHour() }
        }
        Button(L.t("pet.settings"), systemImage: "gearshape") { perch.openSettings() }
    }

    // MARK: Moving

    private func touch() {
        lastTouch = Date()
        if sleeping { sleeping = false }
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
        let now = Date()
        let after = Double(pack?.sleepAfter ?? 60_000) / 1000
        let shouldSleep = now.timeIntervalSince(lastTouch) > after
        if sleeping != shouldSleep { sleeping = shouldSleep }
        if let one = oneOff, one.until < now { oneOff = nil }
        guard !calm, library.shown, pinnedY < 0, mood == .idle, !dragging, oneOff == nil, !asleep, news.bubble == nil, now > nextIdle else { return }
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
