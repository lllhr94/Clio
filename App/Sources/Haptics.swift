import CoreHaptics
import QuartzCore
import UIKit

enum Haptics {
    private static let lightGen = UIImpactFeedbackGenerator(style: .light)
    private static let mediumGen = UIImpactFeedbackGenerator(style: .medium)
    private static let heavyGen = UIImpactFeedbackGenerator(style: .heavy)
    private static let rigidGen = UIImpactFeedbackGenerator(style: .rigid)
    private static let selectionGen = UISelectionFeedbackGenerator()
    private static let notificationGen = UINotificationFeedbackGenerator()
    private static let stateLock = NSLock()
    private static let minTickInterval: CFTimeInterval = 0.035

    nonisolated(unsafe) private static var engine: CHHapticEngine?
    nonisolated(unsafe) private static var lastTickTime: CFTimeInterval = 0
    nonisolated(unsafe) private static var voiceCaptureMuted = false

    static func prepare() {
        lightGen.prepare()
        mediumGen.prepare()
        heavyGen.prepare()
        rigidGen.prepare()
        selectionGen.prepare()
        notificationGen.prepare()
        startEngine()
    }

    static func setVoiceCaptureMuted(_ muted: Bool) {
        stateLock.withLock {
            voiceCaptureMuted = muted
        }
    }

    private static var activeScale: CGFloat? {
        let muted = stateLock.withLock { voiceCaptureMuted }
        guard !muted, Pref.haptics else { return nil }
        let intensity = Pref.hapticIntensity
        guard intensity != .off else { return nil }
        return intensity.scale
    }

    private static func startEngine() {
        stateLock.lock()
        let hasEngine = engine != nil
        stateLock.unlock()
        guard !hasEngine, CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            let made = try CHHapticEngine()
            made.isAutoShutdownEnabled = true
            made.resetHandler = {
                stateLock.lock()
                let current = engine
                stateLock.unlock()
                try? current?.start()
            }
            try made.start()
            stateLock.lock()
            engine = made
            stateLock.unlock()
        } catch {
            stateLock.lock()
            engine = nil
            stateLock.unlock()
        }
    }

    private static func playPattern(_ events: [CHHapticEvent]) -> Bool {
        let currentEngine: CHHapticEngine? = stateLock.withLock { engine }
        guard let currentEngine else { return false }
        do {
            try currentEngine.start()
            let player = try currentEngine.makePlayer(with: CHHapticPattern(events: events, parameters: []))
            try player.start(atTime: CHHapticTimeImmediate)
            return true
        } catch {
            return false
        }
    }

    /// A light semantic tap (e.g. sending a message), never `.medium 0.8`.
    static func light() {
        guard let scale = activeScale else { return }
        lightGen.impactOccurred(intensity: min(1.0, max(0.3, 0.65 * scale)))
    }

    /// Discrete choice change (model or thinking level picker).
    static func selection() {
        guard activeScale != nil else { return }
        selectionGen.selectionChanged()
    }

    /// Taking hold of something.
    static func grab() {
        guard let scale = activeScale else { return }
        mediumGen.impactOccurred(intensity: min(1.0, max(0.4, scale)))
    }

    /// One notch of travel with >= 35ms continuous drag throttle; `strength` in 0...1.
    static func tick(_ strength: CGFloat = 0.7) {
        guard let scale = activeScale else { return }
        let now = CACurrentMediaTime()
        let allowed = stateLock.withLock { () -> Bool in
            guard now - lastTickTime >= minTickInterval else { return false }
            lastTickTime = now
            return true
        }
        guard allowed else { return }
        let resolved = min(1.0, max(0.25, strength * scale))
        rigidGen.impactOccurred(intensity: resolved)
    }

    /// Baseline detent snap on StopRuler default or sidebar drag threshold.
    static func detent() {
        guard let scale = activeScale else { return }
        let level = min(Float(1.0), Float(0.68 * scale))
        let events = [
            CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: level),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.78),
                ],
                relativeTime: 0
            ),
        ]
        if !playPattern(events) {
            rigidGen.impactOccurred(intensity: min(1.0, max(0.4, 0.68 * scale)))
        }
    }

    /// Something locking into place.
    static func lock() {
        guard let scale = activeScale else { return }
        heavyGen.impactOccurred(intensity: min(1.0, max(0.45, scale)))
    }

    /// High-value completion confirmation (backup, long foreground turn).
    static func success() {
        guard activeScale != nil else { return }
        notificationGen.notificationOccurred(.success)
    }

    static func warning() {
        guard activeScale != nil else { return }
        notificationGen.notificationOccurred(.warning)
    }

    static func error() {
        guard activeScale != nil else { return }
        notificationGen.notificationOccurred(.error)
    }

    /// Double gentle wake tap for interactive pixel companion (`clio-pet-wake` profile).
    static func petWake() {
        guard let scale = activeScale else { return }
        let first = min(Float(0.6), Float(0.42 * scale))
        let second = min(Float(0.65), Float(0.55 * scale))
        let events = [
            CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: first),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.30),
                ],
                relativeTime: 0
            ),
            CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: second),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.52),
                ],
                relativeTime: 0.075
            ),
        ]
        if !playPattern(events) {
            lightGen.impactOccurred(intensity: min(1.0, 0.5 * scale))
        }
    }

    /// The stamp landing (`clio-seal-stamp` profile): deep hit, felt damp, sharper lift.
    static func thud() {
        guard let scale = activeScale else { return }
        let s = Float(scale)
        func p(_ id: CHHapticEvent.ParameterID, _ value: Float) -> CHHapticEventParameter {
            CHHapticEventParameter(parameterID: id, value: value)
        }
        let events = [
            CHHapticEvent(eventType: .hapticTransient, parameters: [p(.hapticIntensity, min(1.0, 0.95 * s)), p(.hapticSharpness, 0.25)], relativeTime: 0),
            CHHapticEvent(eventType: .hapticContinuous, parameters: [p(.hapticIntensity, min(1.0, 0.80 * s)), p(.hapticSharpness, 0.12)], relativeTime: 0, duration: 0.14),
            CHHapticEvent(eventType: .hapticTransient, parameters: [p(.hapticIntensity, min(1.0, 0.72 * s)), p(.hapticSharpness, 0.65)], relativeTime: 0.125),
        ]
        if !playPattern(events) {
            fallbackThud(scale: scale)
        }
    }

    private static func fallbackThud(scale: CGFloat) {
        heavyGen.impactOccurred(intensity: min(1.0, max(0.5, scale)))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            rigidGen.impactOccurred(intensity: min(1.0, max(0.45, 0.8 * scale)))
        }
    }
}
