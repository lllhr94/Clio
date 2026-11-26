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

    private var sideDragGesture: some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .onChanged { value in
                let across = value.translation.width
                guard abs(value.translation.height) < max(60, abs(across)) else { return }
                if sideOpen {
                    pull = min(0, across)
                } else if value.startLocation.x < 32, across > 0 {
                    pull = min(across, sideWidth)
                }
            }
            .onEnded { value in
                guard pull != 0, sideWidth > 0 else { return }
                let fling = value.predictedEndTranslation.width
                let settleAnimation: Animation? = reduceMotion ? nil : Ink.Motion.settle
                let transitionAnimation: Animation? = reduceMotion ? nil : Ink.Motion.unfold
                if sideOpen {
                    if -pull > sideWidth * 0.3 || fling < -180 {
                        withAnimation(transitionAnimation) { pull = 0 }
                        closeSide()
                    } else {
                        withAnimation(settleAnimation) { pull = 0 }
                    }
                } else {
                    if pull > sideWidth * 0.35 || fling > sideWidth * 0.72 {
                        withAnimation(transitionAnimation) { pull = 0 }
                        openSide()
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
        .onChange(of: opened) { _, _ in
            if sideOpen || pull != 0 {
                sideOpen = false
                pull = 0
            }
        }
        .onChange(of: sideOpen) { _, _ in
            if pull != 0 {
                withAnimation(reduceMotion ? nil : Ink.Motion.unfold) {
                    pull = 0
                }
            }
        }
    }

    @ViewBuilder
    private func sidebarLayer(progress: CGFloat) -> some View {
        let parallaxX: CGFloat = reduceMotion ? 0 : -(1 - progress) * sideWidth * 0.14
        let sideScale: CGFloat = reduceMotion ? 1 : (0.96 + 0.04 * progress)
        let sideOpacity: Double = reduceMotion
            ? (sideOpen ? 1 : Double(progress))
            : min(1, Double(progress) * 1.3)
        sidebarContent()
            .frame(width: sideWidth)
            .scaleEffect(sideScale, anchor: .leading)
            .offset(x: parallaxX)
            .opacity(sideOpacity)
            .reducedMotionFade(enabled: reduceMotion, duration: 0.15, value: sideOpen)
            .frame(width: sideWidth)
            .clipped()
            .frame(maxWidth: .infinity, alignment: .leading)
            .allowsHitTesting(sideOpen)
            .accessibilityHidden(!sideOpen && progress <= 0.01)
    }

    @ViewBuilder
    private func sidebarDimVeil(progress: CGFloat) -> some View {
        if progress > 0 || sideOpen {
            Ink.Artwork.black
                .opacity(0.18 * Double(progress))
                .ignoresSafeArea()
                .reducedMotionFade(enabled: reduceMotion, duration: 0.15, value: sideOpen)
                .contentShape(Rectangle())
                .allowsHitTesting(sideOpen)
                .onTapGesture {
                    if sideOpen { closeSide() }
                }
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
            .simultaneousGesture(sideDragGesture)
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
