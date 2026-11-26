import Observation
import SwiftUI
import UIKit

/// A single transient toast pill item displayed by `ToastCenter`.
struct ToastItem: Identifiable, Equatable {
    let id: UUID
    let dedupeKey: String?
    let message: String
    let symbol: String?
    let tintColor: Color
    let actionTitle: String?
    let action: (() -> Void)?

    init(
        id: UUID = UUID(),
        dedupeKey: String? = nil,
        message: String,
        symbol: String? = nil,
        tintColor: Color = Ink.ink,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.id = id
        self.dedupeKey = dedupeKey
        self.message = message
        self.symbol = symbol
        self.tintColor = tintColor
        self.actionTitle = actionTitle
        self.action = action
    }

    static func == (lhs: ToastItem, rhs: ToastItem) -> Bool {
        lhs.id == rhs.id
            && lhs.dedupeKey == rhs.dedupeKey
            && lhs.message == rhs.message
            && lhs.symbol == rhs.symbol
            && lhs.actionTitle == rhs.actionTitle
    }
}

/// App-wide manager for floating bottom toast pills that never steal keyboard focus or block background taps.
@MainActor @Observable
final class ToastCenter {
    static let shared = ToastCenter()

    private(set) var items: [ToastItem] = []
    /// Bottom clearance set by active floating docks (e.g. chat composer + pet perch).
    var bottomClearance: CGFloat = 0

    @ObservationIgnored private var dismissTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored fileprivate var hitFrames: [UUID: CGRect] = [:]

    private init() {}

    func show(
        _ message: String,
        symbol: String? = nil,
        tint: Color = Ink.ink,
        actionTitle: String? = nil,
        dedupeKey: String? = nil,
        duration: TimeInterval = 2.6,
        action: (() -> Void)? = nil
    ) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, AppLock.isCurrentlyUnlocked else { return }

        if let dedupeKey,
           let idx = items.lastIndex(where: { $0.dedupeKey == dedupeKey }) {
            let existing = items[idx]
            items[idx] = ToastItem(
                id: existing.id,
                dedupeKey: dedupeKey,
                message: trimmed,
                symbol: symbol,
                tintColor: tint,
                actionTitle: actionTitle,
                action: action
            )
            scheduleDismiss(for: existing.id, duration: duration)
            return
        }

        // Only coalesce identical non-action informational toasts; never clobber an active undo action.
        if dedupeKey == nil,
           action == nil,
           let last = items.last,
           last.dedupeKey == nil,
           last.action == nil,
           last.message == trimmed {
            items[items.count - 1] = ToastItem(
                id: last.id,
                dedupeKey: nil,
                message: trimmed,
                symbol: symbol,
                tintColor: tint,
                actionTitle: actionTitle,
                action: nil
            )
            scheduleDismiss(for: last.id, duration: duration)
            return
        }

        let item = ToastItem(
            id: UUID(),
            dedupeKey: dedupeKey,
            message: trimmed,
            symbol: symbol,
            tintColor: tint,
            actionTitle: actionTitle,
            action: action
        )

        withAnimation(toastAnimation) {
            if items.count >= 3 {
                let oldest = items.removeFirst()
                dismissTasks[oldest.id]?.cancel()
                dismissTasks.removeValue(forKey: oldest.id)
                hitFrames.removeValue(forKey: oldest.id)
            }
            items.append(item)
        }

        UIAccessibility.post(notification: .announcement, argument: trimmed)
        scheduleDismiss(for: item.id, duration: duration)
    }

    func dismiss(_ id: UUID) {
        dismissTasks[id]?.cancel()
        dismissTasks.removeValue(forKey: id)
        hitFrames.removeValue(forKey: id)
        guard items.contains(where: { $0.id == id }) else { return }
        withAnimation(toastAnimation) {
            items.removeAll { $0.id == id }
        }
    }

    fileprivate func containsHitPoint(_ point: CGPoint) -> Bool {
        for item in items {
            if let rect = hitFrames[item.id], !rect.isNull, rect.contains(point) {
                return true
            }
        }
        return false
    }

    private func scheduleDismiss(for id: UUID, duration: TimeInterval) {
        dismissTasks[id]?.cancel()
        let delay = max(0.4, duration)
        dismissTasks[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.dismiss(id)
        }
    }

    private var toastAnimation: Animation {
        if Ink.Motion.prefersReduced(UIAccessibility.isReduceMotionEnabled) {
            return .easeOut(duration: 0.16)
        }
        return Ink.Motion.settle
    }
}

/// Hosts floating toasts in a dedicated pass-through `UIWindow` above sheets and the pet perch.
struct FloatingToastHost: ViewModifier {
    func body(content: Content) -> some View {
        content.background {
            FloatingToastAnchorObserver()
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

extension View {
    func floatingToastHost() -> some View {
        modifier(FloatingToastHost())
    }
}

private struct FloatingToastAnchorObserver: View {
    var body: some View {
        FloatingToastAnchor(
            hasItems: !ToastCenter.shared.items.isEmpty,
            scheme: Theme.shared.scheme
        )
    }
}

@MainActor @Observable
private final class ToastWindowState {
    var keyboardClearance: CGFloat = 0
}

private struct FloatingToastAnchor: UIViewRepresentable {
    let hasItems: Bool
    let scheme: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> Marker {
        let marker = Marker()
        marker.backgroundColor = .clear
        marker.isUserInteractionEnabled = false
        marker.changed = { [weak coordinator = context.coordinator, weak marker] in
            guard let marker else { return }
            coordinator?.sync(marker: marker)
        }
        return marker
    }

    func updateUIView(_ marker: Marker, context: Context) {
        context.coordinator.sync(marker: marker)
    }

    static func dismantleUIView(_ marker: Marker, coordinator: Coordinator) {
        marker.changed = nil
        coordinator.detach()
    }

    final class Marker: UIView {
        var changed: (() -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            changed?()
        }

        override var frame: CGRect {
            didSet {
                if frame != oldValue { changed?() }
            }
        }
    }

    @MainActor
    final class Coordinator {
        private let token = UUID()
        private var attached = false

        func sync(marker: Marker) {
            guard let source = marker.window, source.windowScene != nil else {
                detach()
                return
            }
            attached = true
            FloatingToastWindowController.shared.attach(source: source, token: token)
        }

        func detach() {
            guard attached else { return }
            attached = false
            FloatingToastWindowController.shared.detach(token: token)
        }
    }
}

@MainActor
private final class FloatingToastWindowController: NSObject {
    static let shared = FloatingToastWindowController()

    private var window: FloatingToastWindow?
    private weak var sourceWindow: UIWindow?
    private var tokens: Set<UUID> = []
    private let state = ToastWindowState()
    private var hideTask: Task<Void, Never>?
    private var systemAlertWindowByClass: [ObjectIdentifier: Bool] = [:]

    private override init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(keyboardWillChange(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
        for event in [
            UIWindow.didBecomeVisibleNotification,
            UIWindow.didBecomeHiddenNotification,
            UIWindow.didBecomeKeyNotification,
        ] {
            center.addObserver(self, selector: #selector(windowDidChange), name: event, object: nil)
        }
    }

    func attach(source: UIWindow, token: UUID) {
        tokens.insert(token)
        sourceWindow = source
        guard let scene = source.windowScene else { return }
        if window?.windowScene !== scene {
            tearDownWindow()
            let toastWindow = FloatingToastWindow(windowScene: scene)
            toastWindow.toastCenter = ToastCenter.shared
            toastWindow.frame = source.frame
            toastWindow.windowLevel = .normal + 12
            toastWindow.backgroundColor = .clear
            let host = UIHostingController(rootView: FloatingToastStage(center: ToastCenter.shared, state: state))
            host.view.backgroundColor = .clear
            toastWindow.rootViewController = host
            toastWindow.isHidden = true
            window = toastWindow
        }
        sync()
    }

    func detach(token: UUID) {
        tokens.remove(token)
        if tokens.isEmpty {
            tearDownWindow()
            sourceWindow = nil
        }
    }

    private var alertPollTask: Task<Void, Never>?

    private func tearDownWindow() {
        hideTask?.cancel()
        hideTask = nil
        alertPollTask?.cancel()
        alertPollTask = nil
        window?.isHidden = true
        window = nil
    }

    @objc private func windowDidChange() {
        sync()
    }

    @objc private func keyboardWillChange(_ note: Notification) {
        guard let source = sourceWindow,
              let endFrame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let localEnd = source.convert(endFrame, from: nil)
        let overlap = max(0, source.bounds.maxY - source.safeAreaInsets.bottom - localEnd.minY)
        let resolved: CGFloat = overlap > 10 ? overlap + Ink.Space.m : 0
        guard abs(state.keyboardClearance - resolved) > 0.5 else { return }
        let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        withAnimation(.easeOut(duration: max(0.16, duration))) {
            state.keyboardClearance = resolved
        }
    }

    private func isSystemAlertWindow(_ other: UIWindow) -> Bool {
        let typeID = ObjectIdentifier(type(of: other))
        if let cached = systemAlertWindowByClass[typeID] { return cached }
        let name = NSStringFromClass(type(of: other))
        let isSystem = name.contains("Keyboard") || name.contains("TextEffects")
        systemAlertWindowByClass[typeID] = isSystem
        return isSystem
    }

    private func hasBlockingAlertController(in root: UIViewController?) -> Bool {
        var current = root
        while let vc = current {
            if vc is UIAlertController, !vc.isBeingDismissed {
                return true
            }
            if let nav = vc as? UINavigationController,
               let visible = nav.visibleViewController,
               visible is UIAlertController,
               !visible.isBeingDismissed {
                return true
            }
            current = vc.presentedViewController
        }
        return false
    }

    private func ensureAlertPollRunning(_ active: Bool) {
        if active {
            guard alertPollTask == nil else { return }
            alertPollTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled, let self else { return }
                    if ToastCenter.shared.items.isEmpty && (self.window?.isHidden ?? true) {
                        self.alertPollTask = nil
                        return
                    }
                    self.sync()
                }
            }
        } else {
            alertPollTask?.cancel()
            alertPollTask = nil
        }
    }

    private func sync() {
        guard let window, let source = sourceWindow, let scene = source.windowScene else { return }
        if window.frame != source.frame {
            window.frame = source.frame
        }
        if window.overrideUserInterfaceStyle != source.overrideUserInterfaceStyle {
            window.overrideUserInterfaceStyle = source.overrideUserInterfaceStyle
        }

        let alertCovering = !AppLock.isCurrentlyUnlocked
            || hasBlockingAlertController(in: source.rootViewController)
            || scene.windows.contains { other in
                guard other !== window, !other.isHidden, other.alpha > 0.01, other.windowLevel >= .alert else {
                    return false
                }
                return !isSystemAlertWindow(other)
            }

        let hasItems = !ToastCenter.shared.items.isEmpty
        if alertCovering {
            hideTask?.cancel()
            hideTask = nil
            if !window.isHidden { window.isHidden = true }
            ensureAlertPollRunning(hasItems)
        } else if hasItems {
            hideTask?.cancel()
            hideTask = nil
            if window.isHidden { window.isHidden = false }
            ensureAlertPollRunning(true)
        } else if !window.isHidden, hideTask == nil {
            ensureAlertPollRunning(false)
            hideTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(0.38))
                guard !Task.isCancelled, let self else { return }
                self.hideTask = nil
                if ToastCenter.shared.items.isEmpty {
                    self.window?.isHidden = true
                }
            }
        } else if window.isHidden {
            ensureAlertPollRunning(false)
        }
    }
}

private final class FloatingToastWindow: UIWindow {
    weak var toastCenter: ToastCenter?

    override var canBecomeKey: Bool { false }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let toastCenter, !isHidden, toastCenter.containsHitPoint(point) else { return nil }
        return super.hitTest(point, with: event)
    }
}

private struct FloatingToastStage: View {
    let center: ToastCenter
    let state: ToastWindowState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let calm = Ink.Motion.prefersReduced(reduceMotion)
        let clearance = max(Ink.Space.l, max(center.bottomClearance, state.keyboardClearance))
        let total = center.items.count
        GeometryReader { proxy in
            let maxPadding = max(Ink.Space.l, proxy.size.height - Ink.Space.huge * 2)
            VStack(spacing: Ink.Space.s) {
                Spacer(minLength: 0)
                ForEach(Array(center.items.enumerated()), id: \.element.id) { index, item in
                    let depth = max(0, total - 1 - index)
                    let depthScale = calm ? 1.0 : max(0.92, 1.0 - CGFloat(depth) * 0.04)
                    let depthOpacity = max(0.72, 1.0 - Double(depth) * 0.14)
                    FloatingToastPill(item: item, center: center)
                        .scaleEffect(depthScale)
                        .opacity(depthOpacity)
                        .transition(pillTransition(calm: calm))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.horizontal, Ink.Space.page)
            .padding(.bottom, min(maxPadding, clearance))
            .animation(calm ? .easeOut(duration: 0.16) : Ink.Motion.settle, value: center.items)
        }
    }

    private func pillTransition(calm: Bool) -> AnyTransition {
        if calm { return .opacity }
        return .move(edge: .bottom).combined(with: .opacity)
    }
}

private struct FloatingToastPill: View {
    let item: ToastItem
    let center: ToastCenter

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragOffset: CGFloat = 0

    private var strokeOpacity: Double {
        contrast == .increased ? 1 : 0.7
    }

    private var strokeWidth: CGFloat {
        contrast == .increased ? 1 : 0.5
    }

    private var hasAction: Bool {
        if let actionTitle = item.actionTitle {
            return !actionTitle.isEmpty
        }
        return false
    }

    private var trailingPadding: CGFloat {
        hasAction ? Ink.Space.m : Ink.Space.l
    }

    var body: some View {
        HStack(spacing: Ink.Space.s) {
            if let symbol = item.symbol, !symbol.isEmpty {
                Image(systemName: symbol)
                    .font(.system(size: Ink.Size.small, weight: .semibold))
                    .foregroundStyle(item.tintColor)
                    .accessibilityHidden(true)
            }
            Text(item.message)
                .font(.system(size: Ink.Size.small, weight: .medium))
                .foregroundStyle(Ink.ink)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if let actionTitle = item.actionTitle, !actionTitle.isEmpty {
                actionButton(title: actionTitle)
            }
        }
        .padding(.leading, Ink.Space.l)
        .padding(.trailing, trailingPadding)
        .padding(.vertical, Ink.Space.s)
        .background {
            ZStack {
                Capsule(style: .continuous)
                    .fill(Ink.paperRaised)
                    .shadow(color: Ink.bubbleShadow.opacity(0.95), radius: 10, y: 3)
                Capsule(style: .continuous)
                    .strokeBorder(Ink.rule.opacity(strokeOpacity), lineWidth: strokeWidth)
            }
        }
        .contentShape(Capsule(style: .continuous))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rect in
            center.hitFrames[item.id] = rect
        }
        .onDisappear {
            center.hitFrames.removeValue(forKey: item.id)
        }
        .offset(y: dragOffset)
        .onTapGesture {
            Haptics.light()
            center.dismiss(item.id)
        }
        .gesture(dismissDragGesture)
        .accessibilityElement(children: hasAction ? .contain : .combine)
    }

    private func actionButton(title: String) -> some View {
        Button {
            Haptics.light()
            item.action?()
            center.dismiss(item.id)
        } label: {
            Text(title)
                .font(.system(size: Ink.Size.small, weight: .semibold))
                .foregroundStyle(Ink.accent)
                .padding(.horizontal, Ink.Space.s)
                .padding(.vertical, Ink.Space.xs)
                .background(Ink.accentWash, in: Capsule(style: .continuous))
        }
        .buttonStyle(PressStyle())
    }

    private var dismissDragGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                let dy = value.translation.height
                dragOffset = dy < 0 ? dy * 0.45 : dy
            }
            .onEnded { value in
                let dy = value.translation.height
                let predicted = value.predictedEndTranslation.height
                if abs(dy) > 18 || abs(predicted) > 40 {
                    Haptics.light()
                    center.dismiss(item.id)
                } else {
                    let calm = Ink.Motion.prefersReduced(reduceMotion)
                    withAnimation(calm ? .easeOut(duration: 0.14) : Ink.Motion.quick) {
                        dragOffset = 0
                    }
                }
            }
    }
}
