import SwiftUI
import UIKit

/// Region covered by `TopEdgeBlurVeil`.
enum TopEdgeBlurScope: Equatable {
    /// Covers only `0 ..< safeTop + 4pt`, keeping top floating controls and content crisp.
    case statusBar
    /// Covers status bar + inline navigation bar (and any search/segmented top chrome) up to `safeTop + 6pt`.
    case navigationBar
    /// Fixed height inside an already-inset scroll container (starts at `y = 0`).
    case fixed(CGFloat)
}

/// Unified progressive Gaussian blur + warm paper feathering veil for top bars and status areas.
struct TopEdgeBlurVeil: View {
    let scope: TopEdgeBlurScope
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var usesReducedBlur: Bool {
        reduceTransparency || Theme.shared.reduceVisualEffects
    }

    private static var activeWindowSafeTop: CGFloat {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            if let keyTop = windowScene.windows.first(where: \.isKeyWindow)?.safeAreaInsets.top, keyTop > 0 {
                return keyTop
            }
            if let anyTop = windowScene.windows.first?.safeAreaInsets.top, anyTop > 0 {
                return anyTop
            }
        }
        return 0
    }

    var body: some View {
        switch scope {
        case .fixed(let height):
            GeometryReader { proxy in
                let resolvedHeight = max(0, height)
                if resolvedHeight > 0, proxy.size.width > 0 {
                    veilSurface(isCompactFixed: true)
                        .frame(width: proxy.size.width, height: resolvedHeight)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        case .statusBar, .navigationBar:
            GeometryReader { proxy in
                let measuredTop = proxy.safeAreaInsets.top
                let globalMinY = proxy.frame(in: .global).minY
                let geometry = resolvedEdgeGeometry(measuredTop: measuredTop, globalMinY: globalMinY)
                if geometry.height > 0, proxy.size.width > 0 {
                    VStack(spacing: 0) {
                        veilSurface(isCompactFixed: geometry.isCompactFixed)
                            .frame(width: proxy.size.width, height: geometry.height)
                        Spacer(minLength: 0)
                    }
                }
            }
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func resolvedEdgeGeometry(
        measuredTop: CGFloat,
        globalMinY: CGFloat
    ) -> (height: CGFloat, isCompactFixed: Bool) {
        switch scope {
        case .statusBar:
            if measuredTop > 0 {
                return (measuredTop + 4, false)
            }
            let windowSafeTop = Self.activeWindowSafeTop
            guard windowSafeTop > 0 else { return (0, false) }
            let remaining = (windowSafeTop + 4) - max(0, globalMinY)
            return (max(0, remaining), false)
        case .navigationBar:
            if measuredTop > 0 {
                return (measuredTop + 6, false)
            }
            // Host container already constrained below the navigation bar: feather at viewport top without intruding over cards.
            return (16, true)
        case .fixed(let height):
            return (max(0, height), true)
        }
    }

    @ViewBuilder
    private func veilSurface(isCompactFixed: Bool) -> some View {
        if usesReducedBlur {
            LinearGradient(
                stops: [
                    .init(color: Ink.paper.opacity(0.96), location: 0),
                    .init(color: Ink.paper.opacity(0.78), location: 0.55),
                    .init(color: Ink.paper.opacity(0.30), location: 0.84),
                    .init(color: Ink.paper.opacity(0), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        } else {
            ZStack {
                ProgressiveOpticalBlurView()
                LinearGradient(
                    stops: isCompactFixed
                        ? [
                            .init(color: Ink.paper.opacity(0.42), location: 0),
                            .init(color: Ink.paper.opacity(0.18), location: 0.58),
                            .init(color: Ink.paper.opacity(0), location: 1),
                        ]
                        : [
                            .init(color: Ink.paper.opacity(0.58), location: 0),
                            .init(color: Ink.paper.opacity(0.38), location: 0.55),
                            .init(color: Ink.paper.opacity(0.14), location: 0.82),
                            .init(color: Ink.paper.opacity(0), location: 1),
                        ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
    }
}

extension View {
    /// Applies Clio's unified progressive top-edge optical blur veil without affecting bottom soft edges.
    func clioTopBlurVeil(_ scope: TopEdgeBlurScope = .navigationBar) -> some View {
        overlay(alignment: .top) {
            TopEdgeBlurVeil(scope: scope)
        }
    }
}

/// Mask-free UIKit variable optical blur built from stacked `UIVisualEffectView` slices driven by paused `UIViewPropertyAnimator`s.
private struct ProgressiveOpticalBlurView: UIViewRepresentable {
    func makeUIView(context: Context) -> ProgressiveOpticalBlurUIView {
        ProgressiveOpticalBlurUIView()
    }

    func updateUIView(_ uiView: ProgressiveOpticalBlurUIView, context: Context) {}

    static func dismantleUIView(_ uiView: ProgressiveOpticalBlurUIView, coordinator: ()) {
        uiView.tearDownAnimators()
    }
}

@MainActor
private final class ProgressiveOpticalBlurUIView: UIView {
    private static let fractions: [CGFloat] = [0.92, 0.84, 0.72, 0.58, 0.42, 0.28, 0.16, 0.06]

    private var slices: [UIVisualEffectView] = []
    private var animators: [UIViewPropertyAnimator] = []
    nonisolated(unsafe) private var foregroundObserver: NSObjectProtocol?
    private var traitRegistration: UITraitChangeRegistration?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        clipsToBounds = true

        slices = Self.fractions.map { _ in
            let view = UIVisualEffectView(effect: nil)
            view.isUserInteractionEnabled = false
            addSubview(view)
            return view
        }

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.window != nil else { return }
                self.rebuildAnimators()
            }
        }

        traitRegistration = registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: ProgressiveOpticalBlurUIView, _) in
            guard self.window != nil else { return }
            self.rebuildAnimators()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            tearDownAnimators()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            rebuildAnimators()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        let height = bounds.height
        guard width > 0, height > 0, !slices.isEmpty else { return }
        let sliceHeight = height / CGFloat(slices.count)
        for (index, slice) in slices.enumerated() {
            let y = CGFloat(index) * sliceHeight
            let h = index == slices.count - 1 ? max(0, height - y) : sliceHeight
            slice.frame = CGRect(x: 0, y: y, width: width, height: h)
        }
    }

    func tearDownAnimators() {
        for animator in animators {
            if animator.state != .stopped {
                animator.stopAnimation(true)
            }
        }
        animators.removeAll()
        for slice in slices {
            slice.effect = nil
        }
    }

    private func rebuildAnimators() {
        tearDownAnimators()
        for (slice, fraction) in zip(slices, Self.fractions) {
            let animator = UIViewPropertyAnimator(duration: 1.0, curve: .linear) { [weak slice] in
                slice?.effect = UIBlurEffect(style: .regular)
            }
            animator.pausesOnCompletion = true
            animator.fractionComplete = fraction
            animators.append(animator)
        }
    }
}
