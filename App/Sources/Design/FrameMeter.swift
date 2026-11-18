import QuartzCore
import SwiftUI
import UIKit

/// Counts frames with the screen's own clock and reports twice a second.
@MainActor
final class FrameClock: ObservableObject {
    @Published private(set) var fps = 0
    @Published private(set) var worst = 0.0
    private var link: CADisplayLink?
    private var frames = 0
    private var since = CACurrentMediaTime()
    private var last = CACurrentMediaTime()
    private var longest = 0.0

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: Ticker(self), selector: #selector(Ticker.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        since = CACurrentMediaTime()
        last = since
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    fileprivate func tick(_ time: CFTimeInterval) {
        frames += 1
        longest = max(longest, time - last)
        last = time
        let span = time - since
        if span >= 0.5 {
            fps = Int((Double(frames) / span).rounded())
            worst = longest * 1000
            frames = 0
            longest = 0
            since = time
        }
    }

    /// CADisplayLink holds its target strongly; this keeps the clock itself free to go.
    private final class Ticker: NSObject {
        weak var clock: FrameClock?
        init(_ clock: FrameClock) { self.clock = clock }
        @objc func tick(_ link: CADisplayLink) {
            let time = link.timestamp
            MainActor.assumeIsolated { clock?.tick(time) }
        }
    }
}

/// A small tag in the corner: frames per second, and the longest frame in the last half second.
struct FrameMeter: View {
    @StateObject private var clock = FrameClock()

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text("\(clock.fps) fps")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
            Text(String(format: "最长 %.0f ms", clock.worst))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 6))
        .allowsHitTesting(false)
        .onAppear { clock.start() }
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

    static func set(_ on: Bool) {
        if !on {
            window?.isHidden = true
            window = nil
            return
        }
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }) ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let window = PassThroughWindow(windowScene: scene)
        window.windowLevel = .statusBar + 1
        window.backgroundColor = .clear
        let host = UIHostingController(rootView: FrameMeter().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(.trailing, 8).padding(.top, 50))
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
