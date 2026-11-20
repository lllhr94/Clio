import SwiftUI

// The figures a portrait can be: 卷卷 (a little scroll, Clio's own sign), 墨团 (a drop of ink), 天鹅 (a swan,
// Apollo's bird, who leads the Muses), and the whale from before. Each is drawn in two inks only, the figure's
// ink and a "hole" of the ground, so all of them read as silhouettes and can be recoloured freely.
// All coordinates are fractions of a square, the figure facing right.

/// Where a figure's eye, crown and neck are, for charms and the little marks of each pose.
struct FigureSpots {
    var eye: CGPoint
    var crown: CGPoint
    var neck: CGPoint
}

extension Persona.Kind {
    /// Drawn in code (not a picture the user brought).
    var drawn: Bool { self != .picture }

    var word: String {
        switch self {
        case .scroll: "卷卷"
        case .ink: "墨团"
        case .swan: "天鹅"
        case .whale: "鲸鱼"
        case .picture: "画像"
        }
    }

    static let figures: [Persona.Kind] = [.scroll, .ink, .swan, .whale]
}

// MARK: 卷卷

/// A hanging scroll standing on its lower rod: paper between two rods, a face on the paper.
/// `open` is how far it is unrolled (asleep it rolls up into a short tube).
struct ScrollFigure: View {
    var pose: WhalePose
    var time: Double
    var inner: CGFloat
    var ink: Color
    var hole: Color

    static let spots = FigureSpots(eye: CGPoint(x: 0.58, y: 0.48), crown: CGPoint(x: 0.5, y: 0.2), neck: CGPoint(x: 0.5, y: 0.62))

    var body: some View {
        let open: CGFloat = pose == .sleeping ? 0.22 : 1
        let sway: Double = switch pose {
        case .writing: sin(time * 5) * 2
        case .thinking: sin(time * 0.9) * 4
        case .cheering: sin(time * 10) * 6
        default: sin(time * 1.4) * 1.5
        }
        let bottom: CGFloat = 0.86
        let top = bottom - 0.62 * open
        let rodW: CGFloat = 0.58, paperW: CGFloat = 0.44
        ZStack {
            // Paper
            Rectangle()
                .fill(ink)
                .frame(width: inner * paperW, height: inner * (bottom - top))
                .position(x: inner * 0.5, y: inner * (top + bottom) / 2)
            if open > 0.5 {
                face
                lines
            } else {
                // Rolled up: closed eyes on the tube.
                HStack(spacing: inner * 0.09) {
                    Capsule().fill(hole).frame(width: inner * 0.07, height: inner * 0.016)
                    Capsule().fill(hole).frame(width: inner * 0.07, height: inner * 0.016)
                }
                .position(x: inner * 0.5, y: inner * (top + bottom) / 2)
            }
            // Rods, a little wider than the paper, with round knobs.
            rod(width: rodW).position(x: inner * 0.5, y: inner * top)
            rod(width: rodW).position(x: inner * 0.5, y: inner * bottom)
        }
        .rotationEffect(.degrees(sway), anchor: .bottom)
        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: pose)
    }

    private func rod(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            Circle().fill(ink).frame(width: inner * 0.08, height: inner * 0.08)
            Capsule().fill(ink).frame(width: inner * (width - 0.12), height: inner * 0.06)
            Circle().fill(ink).frame(width: inner * 0.08, height: inner * 0.08)
        }
    }

    private var face: some View {
        let blink = pose == .idle && sin(time * 0.8) > 0.985
        return HStack(spacing: inner * 0.11) {
            ForEach(0..<2, id: \.self) { _ in
                if blink {
                    Capsule().fill(hole).frame(width: inner * 0.06, height: inner * 0.014)
                } else {
                    Circle().fill(hole).frame(width: inner * 0.055, height: inner * 0.055)
                }
            }
        }
        .position(x: inner * 0.5 + (pose == .thinking ? inner * 0.03 : 0), y: inner * 0.46)
    }

    /// The writing on the paper; while it writes, the last line grows.
    private var lines: some View {
        let grow = pose == .writing ? CGFloat((sin(time * 2.5) + 1) / 2) : 1
        return VStack(alignment: .leading, spacing: inner * 0.045) {
            Capsule().fill(hole.opacity(0.75)).frame(width: inner * 0.28, height: max(1, inner * 0.022))
            Capsule().fill(hole.opacity(0.75)).frame(width: inner * 0.28 * grow, height: max(1, inner * 0.022))
        }
        .frame(width: inner * 0.28, alignment: .leading)
        .position(x: inner * 0.5, y: inner * 0.66)
    }
}

// MARK: 墨团

/// A drop of ink: round below, drawn up to a soft point that curls a little, eyes low on the belly.
struct InkDropShape: Shape {
    var squash: CGFloat

    var animatableData: CGFloat {
        get { squash }
        set { squash = newValue }
    }

    func path(in rect: CGRect) -> Path {
        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height) }
        let base: CGFloat = 0.9, radius = 0.3 * (1 + (1 - squash) * 0.25)
        let tip = at(0.56, base - 0.78 * squash)
        var path = Path()
        path.move(to: tip)
        path.addCurve(to: at(0.5 + radius, base - radius * squash), control1: at(0.6, 0.38), control2: at(0.5 + radius, base - radius * 1.5 * squash))
        path.addCurve(to: at(0.5, base), control1: at(0.5 + radius, base - radius * 0.3), control2: at(0.5 + radius * 0.6, base))
        path.addCurve(to: at(0.5 - radius, base - radius * squash), control1: at(0.5 - radius * 0.6, base), control2: at(0.5 - radius, base - radius * 0.3))
        path.addCurve(to: tip, control1: at(0.5 - radius, base - radius * 1.6 * squash), control2: at(0.48, 0.36))
        path.closeSubpath()
        return path
    }
}

struct InkFigure: View {
    var pose: WhalePose
    var time: Double
    var inner: CGFloat
    var ink: Color
    var hole: Color

    static let spots = FigureSpots(eye: CGPoint(x: 0.57, y: 0.66), crown: CGPoint(x: 0.56, y: 0.16), neck: CGPoint(x: 0.5, y: 0.78))

    var body: some View {
        let squash: CGFloat = switch pose {
        case .sleeping: 0.82
        case .cheering: 1 + CGFloat(abs(sin(time * 7))) * 0.06
        case .writing: 1 + CGFloat(sin(time * 6)) * 0.025
        default: 1 + CGFloat(sin(time * 1.4)) * 0.015
        }
        ZStack {
            InkDropShape(squash: squash).fill(ink)
            eyes(lowered: pose == .sleeping)
            if pose == .writing {
                // A little drip that falls and fades, as if it were writing with itself.
                let phase = CGFloat((time * 0.9).truncatingRemainder(dividingBy: 1))
                Circle().fill(ink.opacity(Double(1 - phase)))
                    .frame(width: inner * 0.05, height: inner * 0.05)
                    .position(x: inner * 0.82, y: inner * (0.62 + 0.3 * phase))
            }
        }
        .frame(width: inner, height: inner)
        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: pose)
    }

    @ViewBuilder
    private func eyes(lowered: Bool) -> some View {
        let y = lowered ? 0.72 : 0.66
        HStack(spacing: inner * 0.1) {
            ForEach(0..<2, id: \.self) { _ in
                if lowered {
                    Capsule().fill(hole).frame(width: inner * 0.065, height: inner * 0.015)
                } else {
                    Circle().fill(hole).frame(width: inner * 0.055, height: inner * 0.06)
                }
            }
        }
        .position(x: inner * 0.52, y: inner * y)
    }
}

// MARK: 天鹅

/// A swan on the water: a round body, a long neck rising in an S to a small head and beak, a wing on its back.
/// Asleep it folds its head down onto its back.
struct SwanBody: Shape {
    func path(in rect: CGRect) -> Path {
        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height) }
        var path = Path()
        // Body, tail lifted at the left.
        path.move(to: at(0.12, 0.56))
        path.addCurve(to: at(0.66, 0.66), control1: at(0.26, 0.64), control2: at(0.5, 0.6))
        path.addCurve(to: at(0.82, 0.74), control1: at(0.74, 0.68), control2: at(0.82, 0.68))
        path.addCurve(to: at(0.5, 0.9), control1: at(0.82, 0.86), control2: at(0.66, 0.9))
        path.addCurve(to: at(0.12, 0.56), control1: at(0.28, 0.9), control2: at(0.16, 0.76))
        path.closeSubpath()
        return path
    }
}

struct SwanNeck: Shape {
    /// 0 upright, 1 folded down onto its back.
    var fold: CGFloat

    var animatableData: CGFloat {
        get { fold }
        set { fold = newValue }
    }

    func path(in rect: CGRect) -> Path {
        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height) }
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * fold }
        let head = CGPoint(x: mix(0.74, 0.5), y: mix(0.2, 0.6))
        var path = Path()
        path.move(to: at(0.64, 0.7))
        path.addCurve(to: at(head.x, head.y + 0.04), control1: at(mix(0.86, 0.7), mix(0.52, 0.66)), control2: at(mix(0.6, 0.62), mix(0.34, 0.62)))
        path.addLine(to: at(head.x + 0.04, head.y + 0.05))
        path.addCurve(to: at(0.74, 0.72), control1: at(mix(0.68, 0.66), mix(0.38, 0.64)), control2: at(mix(0.94, 0.78), mix(0.54, 0.68)))
        path.closeSubpath()
        // Head and beak.
        path.addEllipse(in: CGRect(x: rect.minX + (head.x - 0.055) * rect.width, y: rect.minY + (head.y - 0.04) * rect.height,
                                   width: 0.11 * rect.width, height: 0.09 * rect.height))
        let beakAt = CGPoint(x: head.x + 0.05, y: head.y + 0.005)
        path.move(to: at(beakAt.x - 0.01, beakAt.y - 0.02))
        path.addLine(to: at(beakAt.x + mix(0.09, 0.06), beakAt.y + mix(0.02, 0.04)))
        path.addLine(to: at(beakAt.x - 0.01, beakAt.y + 0.025))
        path.closeSubpath()
        return path
    }
}

struct SwanFigure: View {
    var pose: WhalePose
    var time: Double
    var inner: CGFloat
    var ink: Color
    var hole: Color

    static let spots = FigureSpots(eye: CGPoint(x: 0.75, y: 0.19), crown: CGPoint(x: 0.72, y: 0.12), neck: CGPoint(x: 0.7, y: 0.5))

    var body: some View {
        let fold: CGFloat = pose == .sleeping ? 1 : 0
        let lift: Double = switch pose {
        case .waiting: 28 + sin(time * 3) * 8
        case .cheering: 20 + sin(time * 12) * 18
        case .writing: sin(time * 6) * 6
        default: sin(time * 1.2) * 3
        }
        let bob = pose == .thinking ? sin(time * 0.9) * 0.01 : sin(time * 1.4) * 0.008
        ZStack {
            SwanBody().fill(ink)
            SwanNeck(fold: fold).fill(ink)
            // The wing, a leaf of the ground on the back, raised to wave.
            Ellipse()
                .fill(hole.opacity(0.55))
                .frame(width: inner * 0.34, height: inner * 0.1)
                .rotationEffect(.degrees(-12 - lift), anchor: .trailing)
                .position(x: inner * 0.4, y: inner * 0.68)
            if pose != .sleeping {
                Circle().fill(hole).frame(width: inner * 0.03, height: inner * 0.03)
                    .position(x: inner * 0.755, y: inner * 0.195)
            }
            // The water it sits on.
            Capsule().fill(ink.opacity(0.35)).frame(width: inner * 0.7, height: max(1, inner * 0.02))
                .position(x: inner * 0.47, y: inner * 0.93)
        }
        .frame(width: inner, height: inner)
        .offset(y: inner * CGFloat(bob))
        .animation(.spring(response: 0.6, dampingFraction: 0.75), value: pose)
    }
}
