import SwiftUI
import UIKit

/// Foreground-only OLED status window. A caller supplies the conversation key used by TeamModel.
@MainActor
enum AlwaysOn {
    private static var window: TouchToCloseWindow?
    private static weak var previousWindow: UIWindow?
    private static var previousIdleTimer: Bool?
    private static var inactivityObserver: NSObjectProtocol?
    private static var conversation: String?

    static func show(chat: String) {
        let app = UIApplication.shared
        guard app.applicationState == .active,
              let scene = app.connectedScenes.compactMap({ $0 as? UIWindowScene })
                  .first(where: { $0.activationState == .foregroundActive }) else { return }
        if conversation == chat, window?.windowScene == scene { return }

        if window?.windowScene != scene { hide() }
        let content = AlwaysOnStatus(chat: chat, team: TeamModel.shared)
        let controller = BlackScreenHost(rootView: content)
        controller.view.backgroundColor = UIColor(Ink.Artwork.black)

        if let window {
            window.rootViewController = controller
        } else {
            let overlay = TouchToCloseWindow(windowScene: scene)
            overlay.windowLevel = .alert + 1
            overlay.backgroundColor = UIColor(Ink.Artwork.black)
            overlay.rootViewController = controller
            previousWindow = scene.windows.first(where: \.isKeyWindow)
            previousIdleTimer = app.isIdleTimerDisabled
            app.isIdleTimerDisabled = true
            window = overlay
            inactivityObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated { hide() }
            }
            overlay.makeKeyAndVisible()
        }
        conversation = chat
    }

    static func hide() {
        guard let overlay = window else { return }
        window = nil
        conversation = nil
        if let inactivityObserver { NotificationCenter.default.removeObserver(inactivityObserver) }
        inactivityObserver = nil

        // Restore exactly what the app held before the overlay, including a previously disabled timer.
        if let previousIdleTimer { UIApplication.shared.isIdleTimerDisabled = previousIdleTimer }
        previousIdleTimer = nil
        let wasKey = overlay.isKeyWindow
        overlay.isHidden = true
        overlay.rootViewController = nil
        if wasKey, let previousWindow, !previousWindow.isHidden { previousWindow.makeKey() }
        previousWindow = nil
    }

    private final class TouchToCloseWindow: UIWindow {
        override func sendEvent(_ event: UIEvent) {
            if event.type == .touches, event.allTouches?.contains(where: { $0.phase == .began }) == true {
                AlwaysOn.hide()
                return
            }
            super.sendEvent(event)
        }
    }

    private final class BlackScreenHost: UIHostingController<AlwaysOnStatus> {
        override var prefersStatusBarHidden: Bool { true }
        override var prefersHomeIndicatorAutoHidden: Bool { true }
    }
}

private struct AlwaysOnStatus: View {
    let chat: String
    @ObservedObject var team: TeamModel
    @State private var opened = Date()
    @State private var started: Date?
    @State private var finished: Date?

    private static let offsets = [
        CGSize.zero,
        CGSize(width: 1, height: -1),
        CGSize(width: -1, height: -1),
        CGSize(width: -1, height: 1),
        CGSize(width: 1, height: 1),
    ]

    var body: some View {
        let turn = team.alwaysOnTurn(chat)
        let waiting = team.approvals.contains { $0.chat == chat }
        let words = waiting ? L.t("alwaysOn.waiting") : Live.words(team.workDetail(for: chat).words, name: turn.bot?.name ?? team.chatName(chat))
            ?? L.t("alwaysOn.idle")

        TimelineView(.periodic(from: opened, by: 15)) { context in
            let index = Int(max(0, context.date.timeIntervalSince(opened)) / 15) % Self.offsets.count
            let offset = Self.offsets[index]
            VStack(spacing: Ink.Space.m) {
                PetStill(size: Ink.Space.huge, state: waiting ? "notification" : turn.started == nil ? "idle" : "working",
                         bot: turn.bot)
                Text(words)
                    .font(Ink.label)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                elapsed
                    .font(Ink.mono(Ink.Size.sub))
                    .monospacedDigit()
            }
            .foregroundStyle(Ink.Artwork.white.opacity(0.8))
            .padding(.horizontal, Ink.Space.xxl)
            .offset(x: offset.width * Ink.Space.m, y: offset.height * Ink.Space.m)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Ink.Artwork.black.ignoresSafeArea())
        .accessibilityElement(children: .combine)
        .accessibilityHint(L.t("alwaysOn.exitHint"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { AlwaysOn.hide() }
        .accessibilityAction(.escape) { AlwaysOn.hide() }
        .onChange(of: turn.started, initial: true) { _, current in
            if let current {
                started = current
                finished = nil
            } else if started != nil, finished == nil {
                finished = Date()
            }
        }
    }

    @ViewBuilder
    private var elapsed: some View {
        if let started, finished == nil {
            Text(started, style: .timer)
        } else {
            let seconds = Int(max(0, finished?.timeIntervalSince(started ?? opened) ?? 0))
            Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
        }
    }
}
