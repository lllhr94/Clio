import Observation
import QuartzCore
import SwiftUI
import UIKit

/// Samples the shared clock without publishing individual frame callbacks to SwiftUI.
@MainActor @Observable
final class FrameMeterReading {
    private(set) var fps = 0
    private(set) var worst = 0.0
    @ObservationIgnored private var link: SharedFrameLink?
    @ObservationIgnored private var frames = 0
    @ObservationIgnored private var since: CFTimeInterval?
    @ObservationIgnored private var last: CFTimeInterval?
    @ObservationIgnored private var longest = 0.0

    func start() {
        guard link == nil else { return }
        link = SharedFrameDriver.shared.add(rate: .max, isActive: { [weak self] in self != nil }) { [weak self] tick in
            self?.sample(tick.timestamp)
        }
    }

    func stop() {
        link?.invalidate()
        link = nil
        frames = 0
        since = nil
        last = nil
        longest = 0
    }

    private func sample(_ time: CFTimeInterval) {
        guard let start = since, let previous = last else {
            since = time
            last = time
            return
        }
        frames += 1
        longest = max(longest, time - previous)
        last = time
        let span = time - start
        if span >= 0.5 {
            fps = Int((Double(frames) / span).rounded())
            worst = longest * 1000
            frames = 0
            longest = 0
            since = time
        }
    }
}

/// A small tag in the corner: frames per second, and the longest frame in the last half second.
struct FrameMeter: View {
    let clock: FrameMeterReading
    @Environment(\.scenePhase) private var phase

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text("\(clock.fps) fps")
                .font(Ink.mono(Ink.Size.micro, weight: .semibold))
                .foregroundStyle(color)
            Text(String(format: "最长 %.0f ms", clock.worst))
                .font(Ink.mono(Ink.Size.micro))
                .foregroundStyle(Ink.inkSoft)
        }
        .padding(.horizontal, Ink.Space.s)
        .padding(.vertical, Ink.Space.xs)
        .background(Ink.paperRaised.opacity(0.94), in: Capsule())
        .allowsHitTesting(false)
        .onChange(of: phase, initial: true) { _, phase in
            if phase == .active { clock.start() } else { clock.stop() }
        }
        .onDisappear { clock.stop() }
        .accessibilityHidden(true)
    }

    private var color: Color {
        clock.fps >= 100 ? Ink.ok : clock.fps >= 55 ? Ink.accent : Ink.stop
    }
}

/// The meter floats in its own window above everything, sheets and full-screen pages included, and never takes a touch.
@MainActor
enum MeterWindow {
    private static var window: UIWindow?
    private static var clock: FrameMeterReading?

    static func set(_ on: Bool) {
        if !on {
            clock?.stop()
            clock = nil
            window?.isHidden = true
            window = nil
            return
        }
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }) ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let window = PassThroughWindow(windowScene: scene)
        window.windowLevel = .statusBar + 1
        window.backgroundColor = .clear
        let clock = FrameMeterReading()
        self.clock = clock
        let host = UIHostingController(rootView: FrameMeter(clock: clock).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(.trailing, Ink.Space.s).padding(.top, Ink.Space.huge))
        host.view.backgroundColor = .clear
        window.rootViewController = host
        window.isUserInteractionEnabled = false
        window.isHidden = false
        self.window = window
    }

    private final class PassThroughWindow: UIWindow {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
    }
}
