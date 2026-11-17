import SwiftUI

/// The whale that keeps you company on a page: drag it anywhere, it settles against the nearer side;
/// hold it to put it away. It stays where you left it.
struct Mascot: View {
    var pose: WhalePose
    /// Something tall is showing at the bottom (a 候印 slip): step out of its way.
    var raised: Bool
    /// The page it lives on.
    var bounds: CGSize

    @AppStorage("mascot.shown") private var shown = true
    /// Where it rests, as fractions of the page.
    @AppStorage("mascot.x") private var restX = 1.0
    @AppStorage("mascot.y") private var restY = 0.80
    @GestureState private var drag: CGSize = .zero
    @State private var hop = false

    private let size: CGFloat = 44

    private var rest: CGPoint {
        let margin = size / 2 + Ink.Space.m
        let x = margin + (bounds.width - margin * 2) * restX
        var y = Self.clamp(bounds.height * restY, 96, bounds.height - 120)
        if raised, y > bounds.height - 240 { y -= 84 }
        return CGPoint(x: x, y: y)
    }

    var body: some View {
        if shown, bounds.width > 0 {
            Whale(size: size, pose: pose)
                .shadow(color: .black.opacity(drag == .zero ? 0.06 : 0.16), radius: drag == .zero ? 4 : 12, y: drag == .zero ? 2 : 8)
                .scaleEffect(drag == .zero ? (hop ? 1.12 : 1) : 1.1)
                .position(x: rest.x + drag.width, y: rest.y + drag.height)
                .animation(Ink.Motion.unfold, value: rest)
                .animation(Ink.Motion.press, value: drag == .zero)
                .gesture(
                    DragGesture(minimumDistance: 3)
                        .updating($drag) { value, state, _ in state = value.translation }
                        .onEnded { value in
                            let x = rest.x + value.predictedEndTranslation.width * 0.4 + value.translation.width * 0.6
                            let y = rest.y + value.translation.height
                            withAnimation(Ink.Motion.unfold) {
                                // Settles against whichever side is nearer.
                                restX = x < bounds.width / 2 ? 0 : 1
                                restY = Self.clamp(y, 96, bounds.height - 120) / max(bounds.height, 1)
                            }
                            Haptics.tick(0.6)
                        }
                )
                .onTapGesture {
                    Haptics.tick(0.5)
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.45)) { hop = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { hop = false }
                    }
                }
                .contextMenu {
                    Button("收起鲸鱼", systemImage: "eye.slash") {
                        withAnimation(Ink.Motion.settle) { shown = false }
                    }
                }
                .transition(.scale(scale: 0.4).combined(with: .opacity))
                .accessibilityLabel("鲸鱼，拖动可以换位置，长按可以收起")
        }
    }

    private static func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        min(max(value, low), max(low, high))
    }
}
