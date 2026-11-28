import SwiftUI

/// Mounted only when a conversation is opened; isolates horizontal sidebar drag (`pull`) at 120Hz
/// so sliding never invalidates `DeskHomeView` or unrelated desktop state.
struct DeskSlideHost<Sidebar: View>: View {
    let team: TeamModel
    let opened: Opened
    let sideControl: SideControl
    let deskWidth: CGFloat
    @Binding var sideOpen: Bool
    let openSide: () -> Void
    let closeSide: () -> Void
    @ViewBuilder let sidebarContent: () -> Sidebar

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Interactive drag offset isolated inside the active slide host.
    @State private var pull: CGFloat = 0

    private var sideWidth: CGFloat {
        min(deskWidth * 0.82, Ink.Size.body * 21)
    }

    private var shift: CGFloat {
        max(0, (sideOpen ? sideWidth : 0) + pull)
    }

    private var sideProgress: CGFloat {
        min(1, max(0, shift / max(1, sideWidth)))
    }

    private var effectiveReduceMotion: Bool {
        Ink.Motion.prefersReduced(reduceMotion)
    }

    private var sideDragGesture: some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .onChanged { value in
                let across = value.translation.width
                guard abs(value.translation.height) < max(48, abs(across) * 0.85) else { return }
                if sideOpen {
                    pull = min(0, across)
                } else if value.startLocation.x < 32, across > 0 {
                    pull = min(across, sideWidth)
                }
            }
            .onEnded { value in
                guard pull != 0, sideWidth > 0 else { return }
                let velocityX = value.velocity.width
                let projectedPull = ClioTransition.projectLandingOffset(
                    currentOffset: pull,
                    velocityPtPerSec: velocityX,
                    decelerationRate: UIScrollView.DecelerationRate.fast.rawValue
                )
                let settleAnimation: Animation? = effectiveReduceMotion ? nil : ClioMotionPreset.snappyLayout.swiftUIAnimation
                let transitionAnimation: Animation? = effectiveReduceMotion ? nil : ClioMotionPreset.interactivePanel.swiftUIAnimation
                if sideOpen {
                    if -pull > sideWidth * 0.3 || projectedPull < -sideWidth * 0.42 {
                        Haptics.light()
                        withAnimation(transitionAnimation) {
                            pull = 0
                            sideOpen = false
                        }
                        DiagTrail.record("关侧边栏")
                    } else {
                        withAnimation(settleAnimation) { pull = 0 }
                    }
                } else {
                    if pull > sideWidth * 0.35 || projectedPull > sideWidth * 0.55 {
                        Haptics.light()
                        withAnimation(transitionAnimation) {
                            pull = 0
                            sideOpen = true
                        }
                        DiagTrail.record("开侧边栏")
                    } else {
                        withAnimation(settleAnimation) { pull = 0 }
                    }
                }
            }
    }

    var body: some View {
        let progress = sideProgress
        ZStack {
            sidebarLayer(progress: progress)
            openedConversationLayer(for: opened, progress: progress)
        }
        .simultaneousGesture(sideDragGesture)
        .onChange(of: opened) { _, _ in
            if sideOpen || pull != 0 {
                sideOpen = false
                pull = 0
            }
        }
        .onChange(of: sideOpen) { _, _ in
            if pull != 0 {
                withAnimation(effectiveReduceMotion ? nil : Ink.Motion.unfold) {
                    pull = 0
                }
            }
        }
    }

    @ViewBuilder
    private func sidebarLayer(progress: CGFloat) -> some View {
        let parallaxX: CGFloat = effectiveReduceMotion ? 0 : -(1 - progress) * sideWidth * 0.14
        let sideScale: CGFloat = effectiveReduceMotion ? 1 : (0.96 + 0.04 * progress)
        let sideOpacity: Double = effectiveReduceMotion
            ? (sideOpen ? 1 : Double(progress))
            : min(1, Double(progress) * 1.3)
        let revealedWidth = max(0, min(sideWidth, shift))
        sidebarContent()
            .frame(width: sideWidth)
            .scaleEffect(sideScale, anchor: .leading)
            .offset(x: parallaxX)
            .opacity(sideOpacity)
            .reducedMotionFade(enabled: effectiveReduceMotion, duration: 0.15, value: sideOpen)
            .frame(width: sideWidth)
            .frame(width: revealedWidth, alignment: .leading)
            .clipped()
            .frame(maxWidth: .infinity, alignment: .leading)
            .allowsHitTesting(sideOpen)
            .accessibilityHidden(!sideOpen && progress <= 0.01)
    }

    private func sidebarDimVeil(progress: CGFloat) -> some View {
        Ink.Artwork.black
            .opacity(0.18 * Double(progress))
            .ignoresSafeArea()
            .reducedMotionFade(enabled: effectiveReduceMotion, duration: 0.15, value: sideOpen)
            .contentShape(Rectangle())
            .allowsHitTesting(sideOpen)
            .accessibilityHidden(!sideOpen)
            .onTapGesture {
                if sideOpen { closeSide() }
            }
    }

    private func openedConversationLayer(for target: Opened, progress: CGFloat) -> some View {
        page(for: target)
            .overlay {
                sidebarDimVeil(progress: progress)
            }
            .background {
                Ink.paper
                    .shadow(color: Ink.Artwork.black.opacity(0.22 * Double(progress)), radius: 20, x: -4)
                    .ignoresSafeArea()
            }
            .offset(x: shift)
            .zIndex(1)
    }

    @ViewBuilder
    private func page(for target: Opened) -> some View {
        switch target {
        case .companion(let id):
            if let bot = team.bots.first(where: { $0.id == id }) {
                ChatPage(team: team, bot: bot, side: sideControl)
                    .id(target.id)
            }
        case .gathering(let id):
            if let room = team.rooms.first(where: { $0.id == id }) {
                ChatPage(team: team, room: room, side: sideControl)
                    .id(target.id)
            }
        }
    }
}

private extension View {
    @ViewBuilder
    func reducedMotionFade<V: Equatable>(enabled: Bool, duration: Double, value: V) -> some View {
        if enabled {
            self.animation(.easeOut(duration: duration), value: value)
        } else {
            self
        }
    }
}
