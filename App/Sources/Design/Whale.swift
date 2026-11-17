import SwiftUI

/// Clio's own whale: a round silhouette drawn here, in three candidate outlines.
struct WhaleLook: Equatable {
    /// Where the body begins at the tail end, 0...1 across.
    var start: CGFloat
    /// The body's middle line, 0...1 down.
    var mid: CGFloat
    /// How high the back rises (smaller is higher).
    var back: CGFloat
    /// How deep the belly hangs.
    var belly: CGFloat
    /// Where the flukes part.
    var root: CGPoint
    /// The length of each fluke.
    var fluke: CGFloat
    /// The direction of each fluke, in degrees.
    var lobes: [Double]
    var fin: CGPoint
    var eye: CGPoint

    static let looks: [WhaleLook] = [
        WhaleLook(start: 0.26, mid: 0.57, back: 0.16, belly: 0.96, root: CGPoint(x: 0.17, y: 0.33), fluke: 0.17, lobes: [-150, -55], fin: CGPoint(x: 0.60, y: 0.845), eye: CGPoint(x: 0.80, y: 0.53)),
        WhaleLook(start: 0.20, mid: 0.58, back: 0.28, belly: 0.88, root: CGPoint(x: 0.13, y: 0.34), fluke: 0.20, lobes: [-160, -60], fin: CGPoint(x: 0.58, y: 0.80), eye: CGPoint(x: 0.80, y: 0.55)),
        WhaleLook(start: 0.27, mid: 0.60, back: 0.16, belly: 0.86, root: CGPoint(x: 0.19, y: 0.36), fluke: 0.14, lobes: [-145, -50], fin: CGPoint(x: 0.62, y: 0.80), eye: CGPoint(x: 0.79, y: 0.55)),
    ]

    static let names = ["团子", "长调", "墩墩"]
}

/// The body: one fat curve over the back, round the head and under the belly, with a small fin.
struct WhaleBody: Shape {
    var look: WhaleLook

    func path(in rect: CGRect) -> Path {
        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        var path = Path()
        let start = look.start, mid = look.mid
        path.move(to: at(start, mid))
        path.addCurve(to: at(0.96, mid), control1: at(start + 0.02, look.back), control2: at(0.93, look.back - 0.02))
        path.addCurve(to: at(start, mid), control1: at(0.98, look.belly), control2: at(start + 0.06, look.belly))
        path.closeSubpath()
        let turn: CGFloat = 0.45
        var fin = Path()
        for step in 0..<48 {
            let angle = 2 * CGFloat.pi * CGFloat(step) / 48
            let x = 0.09 * cos(angle), y = 0.04 * sin(angle)
            let point = at(look.fin.x + x * cos(turn) - y * sin(turn), look.fin.y + x * sin(turn) + y * cos(turn))
            if step == 0 { fin.move(to: point) } else { fin.addLine(to: point) }
        }
        fin.closeSubpath()
        path.addPath(fin)
        return path
    }
}

/// The tail: a stem and two leaf-shaped flukes. Kept apart from the body so it can wag.
struct WhaleTail: Shape {
    var look: WhaleLook

    func path(in rect: CGRect) -> Path {
        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        let root = look.root, start = look.start, mid = look.mid
        var path = Path()
        path.move(to: at(root.x - 0.035, root.y + 0.02))
        path.addQuadCurve(to: at(start + 0.12, mid + 0.10), control: at(root.x - 0.03, mid + 0.02))
        path.addLine(to: at(start + 0.16, mid - 0.14))
        path.addQuadCurve(to: at(root.x + 0.035, root.y + 0.01), control: at(root.x + 0.06, root.y + 0.12))
        path.closeSubpath()
        for degrees in look.lobes {
            let turn = CGFloat(degrees) * .pi / 180
            var lobe = Path()
            for step in 0..<60 {
                let angle = 2 * CGFloat.pi * CGFloat(step) / 60
                let x = look.fluke / 2 + look.fluke / 2 * cos(angle)
                // Pinched at the root, so each fluke reads as a leaf.
                let along = min(1, max(0, x / look.fluke))
                let y = look.fluke * 0.25 * sin(angle) * (0.35 + 0.65 * pow(sin(.pi * along), 0.6))
                let point = at(root.x + x * cos(turn) - y * sin(turn), root.y + x * sin(turn) + y * cos(turn))
                if step == 0 { lobe.move(to: point) } else { lobe.addLine(to: point) }
            }
            lobe.closeSubpath()
            path.addPath(lobe)
        }
        return path
    }
}

/// What the whale is doing.
enum WhalePose: String, CaseIterable {
    /// 闲坐
    case idle
    /// 沉吟
    case thinking
    /// 落笔
    case writing
    /// 候印
    case waiting

    var word: String {
        switch self {
        case .idle: "闲坐"
        case .thinking: "沉吟"
        case .writing: "落笔"
        case .waiting: "候印"
        }
    }
}

/// The parts a portrait is put together from. Every part can be swapped; nothing about the look is fixed.
struct Persona: Codable, Equatable {
    enum Frame: String, Codable, CaseIterable {
        case circle, squircle, bare

        var word: String {
            switch self {
            case .circle: "圆"
            case .squircle: "方"
            case .bare: "无框"
            }
        }
    }

    enum Charm: String, Codable, CaseIterable {
        case none, beret, scarf, glasses, flower, star

        var word: String {
            switch self {
            case .none: "无"
            case .beret: "贝雷帽"
            case .scarf: "围巾"
            case .glasses: "眼镜"
            case .flower: "簪花"
            case .star: "星子"
            }
        }
    }

    var outline = 0
    var tone = 0
    var wash = 0
    var frame = Frame.circle
    var charm = Charm.none

    /// The ink the silhouette is drawn in.
    static let tones: [(name: String, color: Color)] = [
        ("黛蓝", Ink.accent),
        ("墨", Color(hex: 0x3A3632)),
        ("赭石", Color(hex: 0x9A6A44)),
        ("松绿", Color(hex: 0x4F6E5A)),
        ("绛紫", Color(hex: 0x7E4A5C)),
    ]

    /// What the silhouette sits on.
    static let washNames = ["蓝晕", "藕荷", "竹青", "缃色"]

    var toneColor: Color { Self.tones[min(max(tone, 0), Self.tones.count - 1)].color }
    var washColor: Color { Ink.washes[min(max(wash, 0), Ink.washes.count - 1)] }

    /// The portrait the user put together, kept between launches.
    static var stored: Persona {
        guard let data = UserDefaults.standard.data(forKey: "persona"),
              let persona = try? JSONDecoder().decode(Persona.self, from: data) else { return Persona() }
        return persona
    }

    static func store(_ persona: Persona) {
        if let data = try? JSONEncoder().encode(persona) { UserDefaults.standard.set(data, forKey: "persona") }
    }
}

/// A companion's portrait: the whale, framed and dressed as its persona says.
struct Whale: View {
    var size: CGFloat = 44
    var pose: WhalePose = .idle
    /// Nil follows the portrait the user put together.
    var persona: Persona?
    /// Overrides for places with their own palette, such as a note.
    var wash: Color?
    var tone: Color?
    /// Portraits in lists hold still.
    var still = false

    @AppStorage("persona") private var storedData = Data()
    @Environment(\.accessibilityReduceMotion) private var calm

    private var parts: Persona {
        if let persona { return persona }
        return (try? JSONDecoder().decode(Persona.self, from: storedData)) ?? Persona()
    }

    var body: some View {
        if still || calm {
            figure(at: 0)
        } else {
            TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
                figure(at: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func figure(at time: Double) -> some View {
        let parts = self.parts
        let outline = WhaleLook.looks[min(max(parts.outline, 0), WhaleLook.looks.count - 1)]
        let ink = tone ?? parts.toneColor
        let ground = wash ?? parts.washColor
        let bob = pose == .writing ? sin(time * 5) * 0.012 : sin(time * 1.4) * 0.02
        let wag: Double = switch pose {
        case .writing: sin(time * 9) * 10
        case .waiting: sin(time * 3) * 6
        default: sin(time * 1.4) * 3
        }
        let inner = size * (parts.frame == .bare ? 0.96 : 0.78)
        let hole = parts.frame == .bare ? Ink.paper : ground
        return ZStack {
            switch parts.frame {
            case .circle: Circle().fill(ground)
            case .squircle: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).fill(ground)
            case .bare: Color.clear
            }
            ZStack {
                WhaleTail(look: outline)
                    .fill(ink)
                    .rotationEffect(.degrees(wag), anchor: UnitPoint(x: outline.start + 0.1, y: outline.mid))
                WhaleBody(look: outline).fill(ink)
                // The eye is a dot of the ground, so it stays a silhouette.
                Circle()
                    .fill(hole)
                    .frame(width: inner * 0.058, height: inner * 0.058)
                    .position(x: inner * outline.eye.x, y: inner * outline.eye.y)
                charm(parts.charm, outline, inner, ink, hole)
                if pose == .thinking { bubbles(time, inner, ink) }
                if pose == .waiting { spout(time, inner, ink) }
            }
            .frame(width: inner, height: inner)
            .offset(x: -size * 0.01, y: size * (0.04 + bob))
        }
        .frame(width: size, height: size)
        .clipShape(clip(parts.frame))
        .accessibilityHidden(true)
    }

    private func clip(_ frame: Persona.Frame) -> AnyShape {
        switch frame {
        case .circle: AnyShape(Circle())
        case .squircle: AnyShape(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
        case .bare: AnyShape(Rectangle())
        }
    }

    /// Small things the whale can wear; drawn in the same two inks, so it stays a silhouette.
    @ViewBuilder
    private func charm(_ charm: Persona.Charm, _ outline: WhaleLook, _ inner: CGFloat, _ ink: Color, _ hole: Color) -> some View {
        let eye = CGPoint(x: inner * outline.eye.x, y: inner * outline.eye.y)
        let crown = CGPoint(x: inner * 0.70, y: inner * (outline.back + 0.03))
        switch charm {
        case .none:
            EmptyView()
        case .beret:
            ZStack {
                Ellipse().fill(ink).frame(width: inner * 0.30, height: inner * 0.11)
                Capsule().fill(ink).frame(width: inner * 0.03, height: inner * 0.06).offset(y: -inner * 0.07)
            }
            .rotationEffect(.degrees(-12))
            .position(x: crown.x, y: crown.y - inner * 0.03)
        case .scarf:
            ZStack(alignment: .bottom) {
                Capsule().fill(hole).frame(width: inner * 0.07, height: inner * 0.52)
                Capsule().fill(hole).frame(width: inner * 0.06, height: inner * 0.20)
                    .rotationEffect(.degrees(24), anchor: .top)
                    .offset(x: -inner * 0.03, y: inner * 0.16)
            }
            .rotationEffect(.degrees(8))
            .position(x: inner * (outline.start + 0.24), y: inner * (outline.mid + 0.02))
        case .glasses:
            Circle()
                .stroke(hole, lineWidth: max(1, inner * 0.022))
                .frame(width: inner * 0.15, height: inner * 0.15)
                .position(eye)
        case .flower:
            ZStack {
                ForEach(0..<5, id: \.self) { petal in
                    Ellipse().fill(ink)
                        .frame(width: inner * 0.05, height: inner * 0.09)
                        .offset(y: -inner * 0.045)
                        .rotationEffect(.degrees(Double(petal) * 72))
                }
                Circle().fill(hole).frame(width: inner * 0.035, height: inner * 0.035)
            }
            .position(x: crown.x - inner * 0.06, y: crown.y - inner * 0.06)
        case .star:
            Image(systemName: "sparkle")
                .font(.system(size: inner * 0.16, weight: .bold))
                .foregroundStyle(ink)
                .position(x: crown.x + inner * 0.14, y: crown.y - inner * 0.04)
        }
    }

    private func bubbles(_ time: Double, _ inner: CGFloat, _ ink: Color) -> some View {
        ForEach(0..<3, id: \.self) { index in
            let phase = (time * 0.7 + Double(index) / 3).truncatingRemainder(dividingBy: 1)
            Circle()
                .fill(ink.opacity(0.75 * (1 - phase)))
                .frame(width: inner * (0.05 + 0.03 * CGFloat(index)), height: inner * (0.05 + 0.03 * CGFloat(index)))
                .position(x: inner * (0.74 + 0.07 * CGFloat(index)), y: inner * (0.24 - 0.2 * phase))
        }
    }

    private func spout(_ time: Double, _ inner: CGFloat, _ ink: Color) -> some View {
        let rise = (sin(time * 3) + 1) / 2
        return ForEach([-1.0, 1.0], id: \.self) { side in
            Capsule()
                .fill(ink)
                .frame(width: inner * 0.035, height: inner * (0.08 + 0.07 * rise))
                .rotationEffect(.degrees(side * 22))
                .position(x: inner * (0.66 + 0.035 * side), y: inner * (0.13 - 0.03 * rise))
        }
    }
}
