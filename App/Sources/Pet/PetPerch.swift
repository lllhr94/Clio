import Observation
import SwiftUI
import UIKit

/// The only copy of the pet lives above the chat and its bottom sheets. The clear part of
/// this window passes touches through, and the window never takes keyboard focus.
@MainActor @Observable
final class PetPerch {
    var mood: PetMood = .idle
    var face: String?
    var foot: CGFloat = 0
    var landing = 0
    var rising = false
    var suppressed = false
    @ObservationIgnored var openSettings: () -> Void = {}
    @ObservationIgnored var bodyHit = CGRect.null
    @ObservationIgnored var bubbleHit = CGRect.null
}

struct PetPerchAnchor: UIViewRepresentable {
    let perch: PetPerch
    let mood: PetMood
    let face: String?
    let showingSheet: Bool
    let covered: Bool
    let quiet: Bool
    let enabled: Bool
    var openSettings: () -> Void

    func makeCoordinator() -> Tracker { Tracker(perch) }

    func makeUIView(context: Context) -> Marker {
        let marker = Marker()
        marker.changed = { [weak tracker = context.coordinator, weak marker] in
            guard let marker else { return }
            tracker?.attach(marker, layoutChanged: true)
        }
        return marker
    }

    func updateUIView(_ marker: Marker, context: Context) {
        let changed = context.coordinator.update(self)
        context.coordinator.attach(marker, layoutChanged: changed)
    }

    static func dismantleUIView(_ marker: Marker, coordinator: Tracker) {
        marker.changed = nil
        coordinator.detach()
    }

    final class Marker: UIView {
        var changed: (() -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            changed?()
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            changed?()
        }
        override var frame: CGRect {
            didSet { if frame != oldValue { changed?() } }
        }
    }

    @MainActor
    final class Tracker: NSObject {
        private let perch: PetPerch
        private weak var marker: Marker?
        private var window: Surface?
        private var link: CADisplayLink?
        private var awakeUntil: CFTimeInterval = 0
        private var showingSheet = false
        private var covered = false
        private var quiet = false
        private var enabled = false
        private var previousTop: CGFloat?
        private var travelStart: CGFloat?
        private var lastMove: CFTimeInterval = 0
        private var catchUp: (from: CGFloat, to: CGFloat, start: CFTimeInterval)?
        private var keyboardDuration: CFTimeInterval = 0.24
        private var keyboardUntil: CFTimeInterval = 0

        init(_ perch: PetPerch) {
            self.perch = perch
            super.init()
            NotificationCenter.default.addObserver(self, selector: #selector(keyboard),
                                                   name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
            for event in [UIWindow.didBecomeKeyNotification, UIWindow.didResignKeyNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(windowChanged), name: event, object: nil)
            }
        }

        func update(_ anchor: PetPerchAnchor) -> Bool {
            let changed = anchor.showingSheet != showingSheet || anchor.covered != covered || anchor.quiet != quiet
                || anchor.enabled != enabled || anchor.mood != pending.0 || anchor.face != pending.1
            showingSheet = anchor.showingSheet
            covered = anchor.covered
            quiet = anchor.quiet
            enabled = anchor.enabled
            perch.openSettings = anchor.openSettings
            // UIViewRepresentable can update in the middle of a SwiftUI body pass.
            // Publish to the other hosting controller on the display clock instead.
            pending = (anchor.mood, anchor.face)
            return changed
        }

        private var pending: (PetMood, String?) = (.idle, nil)

        func attach(_ marker: Marker, layoutChanged: Bool) {
            self.marker = marker
            guard enabled, let source = marker.window, let scene = source.windowScene else {
                detach()
                return
            }
            if window?.windowScene !== scene {
                detach()
                let surface = Surface(windowScene: scene)
                surface.perch = perch
                surface.frame = source.frame
                surface.windowLevel = .normal + 1
                surface.backgroundColor = .clear
                let host = UIHostingController(rootView: PetStage(perch: perch).ignoresSafeArea())
                host.view.backgroundColor = .clear
                surface.rootViewController = host
                window = surface
            }
            if link == nil {
                let clock = CADisplayLink(target: Clock(self), selector: #selector(Clock.beat(_:)))
                clock.preferredFramesPerSecond = 60
                clock.add(to: .main, forMode: .common)
                link = clock
                wake()
            } else if layoutChanged {
                wake()
            }
        }

        func detach() {
            link?.invalidate()
            link = nil
            window?.isHidden = true
            window = nil
            previousTop = nil
            travelStart = nil
            catchUp = nil
        }

        private func wake() {
            awakeUntil = CACurrentMediaTime() + 0.8
            link?.isPaused = false
        }

        @objc private func keyboard(_ note: Notification) {
            keyboardDuration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.24)
            keyboardUntil = CACurrentMediaTime() + keyboardDuration + 0.15
            wake()
        }

        @MainActor
        private final class Clock: NSObject {
            weak var tracker: Tracker?

            init(_ tracker: Tracker) { self.tracker = tracker }

            @objc func beat(_ link: CADisplayLink) {
                guard let tracker else { link.invalidate(); return }
                tracker.tick(link)
            }
        }

        @objc private func windowChanged() { wake() }

        private func tick(_ clock: CADisplayLink) {
            guard let marker, let source = marker.window, let window else {
                detach()
                return
            }
            let now = clock.timestamp
            if window.frame != source.frame { window.frame = source.frame }
            if perch.mood != pending.0 { perch.mood = pending.0 }
            if perch.face != pending.1 { perch.face = pending.1 }
            if window.overrideUserInterfaceStyle != source.traitCollection.userInterfaceStyle {
                window.overrideUserInterfaceStyle = source.traitCollection.userInterfaceStyle
            }

            let presented = presentation(above: source.rootViewController)
            let sheet = presented?.sheetPresentationController
            let host = (sheet?.presentedView).flatMap { $0.window === source ? $0 : nil }
            let isBottomSheet = showingSheet || sheet?.detents.contains(where: { $0.identifier == .medium }) == true
            let blocked = covered || (presented != nil && !isBottomSheet)
            if perch.suppressed != (quiet || blocked) { perch.suppressed = quiet || blocked }

            let composer = top(of: marker, in: source)
            let top = min(composer, isBottomSheet ? host.map { self.top(of: $0, in: source) } ?? composer : composer)
            if source.isKeyWindow, composer > 0, !blocked {
                move(to: max(0, top), at: now, calm: UIAccessibility.isReduceMotionEnabled)
                if window.isHidden { window.isHidden = false }
            } else {
                window.isHidden = true
                previousTop = nil
                travelStart = nil
                catchUp = nil
                if perch.rising { perch.rising = false }
            }
            // An interactive sheet can be grabbed again at any time. Away from a sheet, only
            // sample while layout or the keyboard is moving.
            if now > awakeUntil, !showingSheet, host == nil, catchUp == nil, travelStart == nil {
                clock.isPaused = true
            }
        }

        private func presentation(above controller: UIViewController?) -> UIViewController? {
            guard let controller else { return nil }
            if let presented = controller.presentedViewController {
                return presentation(above: presented) ?? presented
            }
            for child in controller.children.reversed() {
                if let presented = presentation(above: child) { return presented }
            }
            return nil
        }

        private func top(of view: UIView, in source: UIWindow) -> CGFloat {
            if let shown = view.layer.presentation(), let screen = source.layer.presentation() {
                return shown.convert(.zero, to: screen).y
            }
            return view.convert(.zero, to: source).y
        }

        private func move(to top: CGFloat, at now: CFTimeInterval, calm: Bool) {
            guard let prior = previousTop else {
                previousTop = top
                perch.foot = top
                return
            }
            let delta = abs(top - prior)
            if delta > 0.25 {
                if travelStart == nil { travelStart = perch.foot }
                if delta > 36, now - lastMove > 0.08 {
                    // Some SwiftUI changes supply a final layout in one step. Keep the pet
                    // continuous even there. Native, interactive movement is sampled directly.
                    catchUp = (perch.foot, top, now)
                } else if let catchUp, abs(catchUp.to - top) > 0.25 {
                    self.catchUp = nil
                }
                lastMove = now
            }
            previousTop = top
            let next: CGFloat
            if let catchUp {
                let duration = now < keyboardUntil ? max(0.12, keyboardDuration) : 0.24
                let t = min(1, max(0, (now - catchUp.start) / duration))
                next = catchUp.from + (catchUp.to - catchUp.from) * CGFloat(t * t * (3 - 2 * t))
                if t == 1 { self.catchUp = nil }
            } else {
                next = top
            }
            let rising = !calm && travelStart != nil && next < perch.foot - 0.25
            if perch.rising != rising, rising || travelStart == nil || next > perch.foot + 0.25 {
                perch.rising = rising
            }
            if perch.foot != next { perch.foot = next }
            if let travelStart, catchUp == nil, now - lastMove > 0.065 {
                perch.rising = false
                if !calm, !quiet, abs(next - travelStart) > 12 { perch.landing += 1 }
                self.travelStart = nil
            }
        }
    }

    private final class Surface: UIWindow {
        weak var perch: PetPerch?

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            guard let perch else { return nil }
            if rootViewController?.presentedViewController != nil { return super.hitTest(point, with: event) }
            guard !perch.suppressed, perch.bodyHit.contains(point) || perch.bubbleHit.contains(point) else { return nil }
            return super.hitTest(point, with: event)
        }
    }
}

/// Keeps chat text out from behind the docked pet.
struct PetPerchSpace: View {
    let face: String?
    @Environment(\.displayScale) private var displayScale
    @AppStorage("pet.pinnedY") private var pinnedY = -1.0
    @State private var now = Date()

    var body: some View {
        let library = PetLibrary.shared
        let hidden = library.hiddenUntil.map { $0 > now } ?? false
        Group {
            if library.visible, !hidden, pinnedY < 0, let pack = library.pack(for: face) {
                let screen = UIScreen.main.bounds
                let unit = PetSize.unit(for: pack, factor: library.factor, displayScale: displayScale,
                                        maxWidth: screen.width - Ink.Space.page * 2, maxHeight: screen.height / 3)
                Color.clear.frame(height: CGFloat(pack.baseline) * unit)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .task(id: library.hiddenUntil) {
            now = Date()
            if let until = library.hiddenUntil, until > now {
                try? await Task.sleep(for: .seconds(until.timeIntervalSince(now)))
                if !Task.isCancelled { now = Date() }
            }
        }
    }
}

/// A short form sits on the composer. Keep its fields in one scroll view so focusing
/// the keyboard or changing the available height cannot replace the form mid-edit.
struct PetDockSlip<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var calm
    @State private var measured: CGFloat = 100
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            content
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    withAnimation(calm ? .easeInOut(duration: 0.22) : Ink.Motion.unfold) { measured = height }
                }
        }
        .frame(height: min(measured, UIScreen.main.bounds.height * 0.28))
        .scrollBounceBehavior(.basedOnSize)
    }
}
