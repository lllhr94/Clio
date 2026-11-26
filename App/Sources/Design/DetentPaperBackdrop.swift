import SwiftUI

/// Sheet backdrop that transitions from frosted paper at `.medium` to solid `Ink.paper` at `.large`.
struct DetentPaperSurface: View {
    let isFull: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let solid = reduceTransparency || Theme.shared.reduceVisualEffects
        let calm = Ink.Motion.prefersReduced(reduceMotion)
        if solid {
            Ink.paper.ignoresSafeArea()
        } else {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Ink.paper.opacity(isFull ? 1.0 : 0.78)
            }
            .ignoresSafeArea()
            .animation(calm ? .easeOut(duration: 0.16) : Ink.Motion.standard, value: isFull)
        }
    }
}

private struct DetentPaperBackdropModifier: ViewModifier {
    let externalDetent: Binding<PresentationDetent>?
    let detents: Set<PresentationDetent>
    @State private var internalDetent: PresentationDetent

    init(detent: Binding<PresentationDetent>?, initial: PresentationDetent, detents: Set<PresentationDetent>) {
        self.externalDetent = detent
        let resolvedDetents: Set<PresentationDetent> = detents.isEmpty ? [.medium, .large] : detents
        self.detents = resolvedDetents
        let resolvedInitial = resolvedDetents.contains(initial) ? initial : (resolvedDetents.first ?? .medium)
        self._internalDetent = State(initialValue: resolvedInitial)
    }

    private var resolvedDetent: Binding<PresentationDetent> {
        let source = externalDetent ?? $internalDetent
        let allowed = detents
        let fallback = allowed.contains(.medium) ? .medium : (allowed.first ?? .large)
        return Binding(
            get: {
                let current = source.wrappedValue
                return allowed.contains(current) ? current : fallback
            },
            set: { next in
                source.wrappedValue = allowed.contains(next) ? next : fallback
            }
        )
    }

    func body(content: Content) -> some View {
        let selection = resolvedDetent
        content
            .presentationDetents(detents, selection: selection)
            .presentationDragIndicator(.visible)
            .presentationBackground {
                DetentPaperSurface(isFull: selection.wrappedValue == .large)
            }
    }
}

extension View {
    /// Presents a sheet with a drag indicator and a paper backdrop synced to an external `PresentationDetent` binding.
    func detentPaperBackdrop(
        detent: Binding<PresentationDetent>,
        detents: Set<PresentationDetent> = [.medium, .large]
    ) -> some View {
        modifier(DetentPaperBackdropModifier(detent: detent, initial: detent.wrappedValue, detents: detents))
    }

    /// Presents a sheet with a drag indicator and a paper backdrop starting at `initial` detent.
    func detentPaperBackdrop(
        initial: PresentationDetent = .medium,
        detents: Set<PresentationDetent> = [.medium, .large]
    ) -> some View {
        modifier(DetentPaperBackdropModifier(detent: nil, initial: initial, detents: detents))
    }
}
