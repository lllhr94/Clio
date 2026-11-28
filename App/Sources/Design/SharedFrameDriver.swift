// SPDX-License-Identifier: GPL-3.0-or-later
// SharedFrameDriver.swift
// Unified idle-zero ProMotion display clock + RuntimeBudgetGovernor for Clio (iOS 26.0+).
//
// Upstream Provenance (GPL-2.0-or-later -> GPL-3.0 compatible; record in UPSTREAM.md on integration):
// - Repository: https://github.com/TelegramMessenger/Telegram-iOS
// - Pinned Commit: 24638bc69bd083981b178dd1e7f921eebbf7fc46
// - Adapted from: submodules/Display/Source/DisplayLinkAnimator.swift (`SharedDisplayLinkDriver`)
//
// Key Clio Enhancements:
// - Consolidates Clio's 4 separate CADisplayLinks (FrameMeter, ChatRevealDisplayDriver,
//   ChatListViewController.insetDisplayLink, and PetPerch) into a single idle-zero clock.
// - Eliminates FrameClock's 120Hz `ObservableObject` broadcast hazard.
// - Adds Telegram Issue #2477 visibility predicate guard (`isActive`) so hidden/detached views
//   can never keep a high-refresh CADisplayLink spinning in background or off-screen.
// - Exposes `lastTargetTimestamp` & `frameDuration` for Telegram-style next-frame coordinate projection.
// - Pairs with `RuntimeBudgetGovernor` (ThermalState + Low Power + Memory Warning + Reduce Motion / Visual Effects)
//   so frame rates, blur/snippets, tile caches, and pet animations degrade coherently under load.

import CoreGraphics
import Foundation
import Observation
#if canImport(QuartzCore)
import QuartzCore
#endif
#if canImport(UIKit)
import UIKit
#endif

// MARK: - 1. Pure Runtime Budget Policy (Testable without UIKit)

public enum RuntimeBudgetTier: Int, Equatable, Comparable, Sendable, Codable {
    case full = 0
    case conserve = 1
    case critical = 2

    public static func < (lhs: RuntimeBudgetTier, rhs: RuntimeBudgetTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct RuntimeBudgetSnapshot: Equatable, Sendable {
    public let tier: RuntimeBudgetTier
    public let maxPreferredFPS: Int
    public let allowsRevealSnippets: Bool
    public let allowsContinuousGlassEffects: Bool
    public let petIdleFPS: Int
    public let prefetchWindowScale: Double

    public init(
        tier: RuntimeBudgetTier,
        maxPreferredFPS: Int,
        allowsRevealSnippets: Bool,
        allowsContinuousGlassEffects: Bool,
        petIdleFPS: Int,
        prefetchWindowScale: Double
    ) {
        self.tier = tier
        self.maxPreferredFPS = maxPreferredFPS
        self.allowsRevealSnippets = allowsRevealSnippets
        self.allowsContinuousGlassEffects = allowsContinuousGlassEffects
        self.petIdleFPS = petIdleFPS
        self.prefetchWindowScale = prefetchWindowScale
    }
}

public enum RuntimeBudgetPolicy {
    /// Evaluates Clio's unified performance/power budget tier.
    /// Keeps 120Hz ProMotion in `.nominal` and `.fair` (matching `MotionPolicyCore`);
    /// steps down gracefully under Low Power Mode, `.serious`/`.critical` thermal pressure, or accessibility overrides.
    public static func evaluate(
        thermalState: ProcessInfo.ThermalState,
        isLowPowerMode: Bool,
        reduceMotion: Bool,
        reduceVisualEffects: Bool
    ) -> RuntimeBudgetSnapshot {
        if thermalState == .critical || reduceMotion || reduceVisualEffects {
            return RuntimeBudgetSnapshot(
                tier: .critical,
                maxPreferredFPS: thermalState == .critical ? 30 : 60,
                allowsRevealSnippets: false,
                allowsContinuousGlassEffects: false,
                petIdleFPS: 4,
                prefetchWindowScale: 0.5
            )
        }
        if isLowPowerMode || thermalState == .serious {
            return RuntimeBudgetSnapshot(
                tier: .conserve,
                maxPreferredFPS: 60,
                allowsRevealSnippets: false,
                allowsContinuousGlassEffects: false,
                petIdleFPS: 4,
                prefetchWindowScale: 0.65
            )
        }
        return RuntimeBudgetSnapshot(
            tier: .full,
            maxPreferredFPS: 120,
            allowsRevealSnippets: true,
            allowsContinuousGlassEffects: true,
            petIdleFPS: 12,
            prefetchWindowScale: 1.0
        )
    }
}

// MARK: - 2. Frame Tick Context & FPS Arbitration

public struct SharedFrameTick: Equatable, Sendable {
    /// Current display timestamp (`CADisplayLink.timestamp`).
    public let timestamp: CFTimeInterval
    /// Next vsync presentation timestamp (`CADisplayLink.targetTimestamp`) for 0-frame lookahead projection.
    public let targetTimestamp: CFTimeInterval
    /// Monotonic clamped delta seconds since this client's last delivered tick.
    public let dt: CFTimeInterval
    /// Current hardware frame interval (`targetTimestamp - timestamp`).
    public let frameDuration: CFTimeInterval
}

public enum SharedFrameRate: Equatable, Sendable {
    case fps(Int)
    case max

    public var numericFPS: Int {
        switch self {
        case .fps(let value): return min(120, Swift.max(1, value))
        case .max: return 120
        }
    }
}

// MARK: - Runtime budget and display clock

#if canImport(UIKit) && canImport(QuartzCore)
@MainActor @Observable
public final class RuntimeBudgetGovernor {
    public static let shared = RuntimeBudgetGovernor()

    public private(set) var snapshot: RuntimeBudgetSnapshot
    @ObservationIgnored private var budgetObservers: [UUID: (RuntimeBudgetSnapshot) -> Void] = [:]
    @ObservationIgnored private var memoryPressureObservers: [UUID: () -> Void] = [:]
    @ObservationIgnored private var notifications: [NSObjectProtocol] = []

    private init() {
        snapshot = Self.readSnapshot()
        observeTheme()
        let center = NotificationCenter.default
        for name in [ProcessInfo.thermalStateDidChangeNotification, .NSProcessInfoPowerStateDidChange,
                     UIAccessibility.reduceMotionStatusDidChangeNotification] {
            notifications.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.recompute() }
            })
        }
        notifications.append(center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for handler in Array(self.memoryPressureObservers.values) { handler() }
            }
        })
    }

    @discardableResult
    public func observeBudget(_ handler: @escaping (RuntimeBudgetSnapshot) -> Void) -> UUID {
        let id = UUID()
        budgetObservers[id] = handler
        handler(snapshot)
        return id
    }

    public func removeBudgetObserver(_ id: UUID) {
        budgetObservers.removeValue(forKey: id)
    }

    @discardableResult
    public func observeMemoryWarning(_ handler: @escaping () -> Void) -> UUID {
        let id = UUID()
        memoryPressureObservers[id] = handler
        return id
    }

    public func removeMemoryWarningObserver(_ id: UUID) {
        memoryPressureObservers.removeValue(forKey: id)
    }

    private func observeTheme() {
        withObservationTracking {
            _ = Theme.shared.reduceVisualEffects
        } onChange: { [weak self] in
            // Observation sends willSet. Read the new preference after the setter returns.
            Task { @MainActor in
                self?.observeTheme()
                self?.recompute()
            }
        }
    }

    private static func readSnapshot() -> RuntimeBudgetSnapshot {
        let process = ProcessInfo.processInfo
        return RuntimeBudgetPolicy.evaluate(
            thermalState: process.thermalState,
            isLowPowerMode: process.isLowPowerModeEnabled,
            reduceMotion: UIAccessibility.isReduceMotionEnabled,
            reduceVisualEffects: Theme.shared.reduceVisualEffects
        )
    }

    private func recompute() {
        let next = Self.readSnapshot()
        guard next != snapshot else { return }
        snapshot = next
        for handler in Array(budgetObservers.values) { handler(next) }
        SharedFrameDriver.shared.requestArbitrationUpdate()
    }
}

/// Retain this token while ticks are needed. Invalidate it to stop immediately, or release it
/// and let the driver prune it when next active.
@MainActor
public final class SharedFrameLink {
    private weak var driver: SharedFrameDriver?
    public let requestedRate: SharedFrameRate
    fileprivate let isActive: () -> Bool
    fileprivate let handler: (SharedFrameTick) -> Void
    fileprivate var isValid = true
    fileprivate var elapsed: CFTimeInterval = 0
    fileprivate var nextDelivery: CFTimeInterval?

    public var isPaused = false {
        didSet {
            guard isPaused != oldValue else { return }
            resetCadence()
            driver?.requestArbitrationUpdate()
        }
    }

    fileprivate init(
        driver: SharedFrameDriver,
        requestedRate: SharedFrameRate,
        isActive: @escaping () -> Bool,
        handler: @escaping (SharedFrameTick) -> Void
    ) {
        self.driver = driver
        self.requestedRate = requestedRate
        self.isActive = isActive
        self.handler = handler
    }

    public func invalidate() {
        guard isValid else { return }
        isValid = false
        driver?.requestArbitrationUpdate()
    }

    fileprivate func resetCadence() {
        nextDelivery = nil
        elapsed = 0
    }
}

/// A single display clock for all active frame consumers.
@MainActor
public final class SharedFrameDriver: NSObject {
    public static let shared = SharedFrameDriver(isInForeground: UIApplication.shared.applicationState != .background) {
        RuntimeBudgetGovernor.shared.snapshot
    }

    public private(set) var lastTargetTimestamp: CFTimeInterval?
    public private(set) var frameDuration: CFTimeInterval = 1.0 / 120.0

    private final class WeakLinkBox {
        weak var link: SharedFrameLink?
        init(_ link: SharedFrameLink) { self.link = link }
    }

    @MainActor
    private final class Ticker: NSObject {
        weak var driver: SharedFrameDriver?
        init(_ driver: SharedFrameDriver) { self.driver = driver }

        @objc func frame(_ link: CADisplayLink) {
            guard let driver else { link.invalidate(); return }
            driver.tick(timestamp: link.timestamp, targetTimestamp: link.targetTimestamp)
        }
    }

    private var boxes: [WeakLinkBox] = []
    private var displayLink: CADisplayLink?
    private let budget: @MainActor () -> RuntimeBudgetSnapshot
    private var isInForeground: Bool
    private var isTicking = false
    private var needsReconcileAfterTick = false
    private var lastTickTimestamp: CFTimeInterval?
    private(set) var activeMaxFPS = 0

    init(isInForeground: Bool, budget: @escaping @MainActor () -> RuntimeBudgetSnapshot) {
        self.isInForeground = isInForeground
        self.budget = budget
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(handleEnterBackground),
                           name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.addObserver(self, selector: #selector(handleWillEnterForeground),
                           name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    /// If a predicate changes from false while the clock is idle, its owner must call
    /// `requestArbitrationUpdate()` from the corresponding visibility or lifecycle callback.
    public func add(
        rate: SharedFrameRate,
        isActive: @escaping () -> Bool = { true },
        handler: @escaping (SharedFrameTick) -> Void
    ) -> SharedFrameLink {
        let link = SharedFrameLink(driver: self, requestedRate: rate, isActive: isActive, handler: handler)
        boxes.append(WeakLinkBox(link))
        requestArbitrationUpdate()
        return link
    }

    public func requestArbitrationUpdate() {
        if isTicking {
            needsReconcileAfterTick = true
        } else {
            reconcileDisplayLink()
        }
    }

    public func predictedNextPresentationTime(now: CFTimeInterval = CACurrentMediaTime()) -> CFTimeInterval {
        if let lastTargetTimestamp, lastTargetTimestamp > now { return lastTargetTimestamp }
        return now + frameDuration
    }

    @objc private func handleEnterBackground() {
        isInForeground = false
        stopDisplayLink()
    }

    @objc private func handleWillEnterForeground() {
        isInForeground = true
        requestArbitrationUpdate()
    }

    private func reconcileDisplayLink() {
        boxes.removeAll { $0.link?.isValid != true }
        guard isInForeground, !boxes.isEmpty else { stopDisplayLink(); return }
        var highestRequested = 0
        for box in boxes {
            guard let client = box.link, !client.isPaused, client.isActive() else {
                box.link?.resetCadence()
                continue
            }
            highestRequested = max(highestRequested, client.requestedRate.numericFPS)
        }
        applyEffectiveFPS(min(highestRequested, budget().maxPreferredFPS))
    }

    private func applyEffectiveFPS(_ fps: Int) {
        guard isInForeground, fps > 0 else { stopDisplayLink(); return }
        guard activeMaxFPS != fps else { return }
        let link = displayLink ?? CADisplayLink(target: Ticker(self), selector: #selector(Ticker.frame(_:)))
        let preferred = Float(fps)
        let minimum = fps >= 50 ? Float(30) : preferred
        link.preferredFrameRateRange = CAFrameRateRange(minimum: minimum, maximum: preferred, preferred: preferred)
        if displayLink == nil {
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        activeMaxFPS = fps
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        activeMaxFPS = 0
        lastTickTimestamp = nil
        lastTargetTimestamp = nil
        for box in boxes { box.link?.resetCadence() }
    }

    func tick(timestamp: CFTimeInterval, targetTimestamp: CFTimeInterval) {
        guard isInForeground, activeMaxFPS > 0 else { return }
        let hardwareDuration = targetTimestamp > timestamp ? targetTimestamp - timestamp : frameDuration
        let elapsed = max(0, lastTickTimestamp.map { timestamp - $0 } ?? hardwareDuration)
        lastTickTimestamp = timestamp
        lastTargetTimestamp = targetTimestamp
        frameDuration = hardwareDuration

        let ceiling = budget().maxPreferredFPS
        var highestActiveFPS = 0
        var hasDeadLinks = false
        isTicking = true
        // Appending or removing subscriptions from a callback takes effect on the next frame.
        for box in boxes {
            guard let client = box.link, client.isValid else { hasDeadLinks = true; continue }
            guard !client.isPaused, client.isActive() else { client.resetCadence(); continue }
            let fps = min(client.requestedRate.numericFPS, ceiling)
            highestActiveFPS = max(highestActiveFPS, fps)
            client.elapsed += elapsed
            let interval = 1.0 / Double(fps)
            if fps < activeMaxFPS || hardwareDuration + 0.00001 < interval {
                let deadline = client.nextDelivery ?? timestamp
                guard timestamp + hardwareDuration / 4 >= deadline else { continue }
                // Keep the phase across frames so an uneven cadence, such as 12 Hz on 60 Hz,
                // does not drift or lose time when another client requests a different rate.
                client.nextDelivery = max(deadline + interval, timestamp + interval - hardwareDuration / 4)
            } else {
                client.nextDelivery = nil
            }
            let dt = min(client.elapsed, fps >= 30 ? 0.05 : 1.0 / Double(fps))
            client.elapsed = 0
            client.handler(SharedFrameTick(timestamp: timestamp, targetTimestamp: targetTimestamp,
                                           dt: dt, frameDuration: hardwareDuration))
        }
        isTicking = false
        if needsReconcileAfterTick || hasDeadLinks {
            needsReconcileAfterTick = false
            reconcileDisplayLink()
        } else {
            // Visibility can drop without the owner mutating or invalidating its token.
            applyEffectiveFPS(highestActiveFPS)
        }
    }
}
#endif
