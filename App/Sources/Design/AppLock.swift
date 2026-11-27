import LocalAuthentication
import SwiftUI
import UIKit

/// Face ID lock for the whole app: when on, the app covers itself after going to the background
/// and opens again only after Face ID (or the passcode).
struct AppLock: ViewModifier {
    @Environment(\.scenePhase) private var phase
    @AppStorage("lock.faceid") private var on = false
    @State private var locked = UserDefaults.standard.bool(forKey: "lock.faceid")
    @State private var asking = false
    /// Only coming back from the background asks by itself; dismissing the Face ID sheet does not ask again.
    @State private var wasAway = false

    @MainActor private static var unlockedInActiveSession = !UserDefaults.standard.bool(forKey: "lock.faceid")

    @MainActor static var isCurrentlyUnlocked: Bool {
        if !UserDefaults.standard.bool(forKey: "lock.faceid") { return true }
        return unlockedInActiveSession
            && !LockCurtain.shared.isShowing
            && UIApplication.shared.applicationState == .active
    }

    @MainActor static func verifyDeviceOwner(reason: String) async -> Bool {
        let context = LAContext()
        var problem: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &problem) else {
            return (problem as? LAError)?.code == .passcodeNotSet
        }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
                continuation.resume(returning: ok)
            }
        }
    }

    private var covering: Bool { on && (locked || phase != .active) }

    func body(content: Content) -> some View {
        content
            // The cover is a window of its own above everything, sheets included: drawn as an overlay it sat under
            // any open sheet (信匣 with a password shown, say), which then showed in the app switcher and stayed usable.
            .onChange(of: "\(covering)|\(locked)|\(asking)|\(on)", initial: true) {
                let wasUnlocked = Self.unlockedInActiveSession
                let nowUnlocked = !on || (!locked && phase == .active)
                Self.unlockedInActiveSession = nowUnlocked
                if covering { LockCurtain.shared.show(AnyView(cover)) } else { LockCurtain.shared.hide() }
                if !wasUnlocked && nowUnlocked {
                    NotificationCenter.default.post(name: .clioAppDidUnlock, object: nil)
                }
            }
            .onChange(of: phase) { _, now in
                if now == .background, on {
                    locked = true
                    wasAway = true
                    Self.unlockedInActiveSession = false
                }
                if now == .active, on, locked, wasAway {
                    wasAway = false
                    unlock()
                }
            }
            .task { if on, locked { unlock() } }
    }

    private var cover: some View {
        ZStack {
            Ink.paper.ignoresSafeArea()
            VStack(spacing: Ink.Space.l) {
                Image(systemName: "lock.fill")
                    .font(.system(size: Ink.Size.title, weight: .semibold))
                    .foregroundStyle(Ink.accent)
                Text("Clio 已上锁")
                    .font(.system(size: Ink.Size.body, weight: .semibold))
                    .foregroundStyle(Ink.ink)
                if locked {
                    Button("用面容解锁") { unlock() }
                        .buttonStyle(.borderedProminent)
                        .tint(Ink.accent)
                        .disabled(asking)
                }
            }
        }
    }

    private func unlock() {
        guard !asking else { return }
        let context = LAContext()
        var problem: NSError?
        // Only bypass when no passcode is configured on the device at all; never bypass on transient errors or lockout.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &problem) else {
            if (problem as? LAError)?.code == .passcodeNotSet {
                locked = false
            }
            return
        }
        asking = true
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "打开 Clio") { ok, _ in
            Task { @MainActor in
                asking = false
                if ok { locked = false }
            }
        }
    }
}

extension View {
    func appLock() -> some View { modifier(AppLock()) }
}

extension Notification.Name {
    static let clioAppDidUnlock = Notification.Name("clio.appDidUnlock")
}

/// The window the lock cover is drawn in, above alerts and sheets.
@MainActor
final class LockCurtain {
    static let shared = LockCurtain()
    private var window: UIWindow?

    var isShowing: Bool {
        guard let window else { return false }
        return !window.isHidden
    }

    func show(_ content: AnyView) {
        if let window, let host = window.rootViewController as? UIHostingController<AnyView> {
            window.windowScene?.windows.forEach { other in
                if other !== window { other.endEditing(true) }
            }
            host.rootView = content
            host.view.accessibilityViewIsModal = true
            window.makeKeyAndVisible()
            return
        }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState != .unattached }) else { return }
        scene.windows.forEach { $0.endEditing(true) }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        let host = UIHostingController(rootView: content)
        host.view.backgroundColor = .clear
        host.view.accessibilityViewIsModal = true
        window.rootViewController = host
        window.makeKeyAndVisible()
        self.window = window
        Theme.shared.applyScheme()
    }

    func hide() {
        let scene = window?.windowScene
        let current = window
        window?.isHidden = true
        window = nil
        if let main = scene?.windows.first(where: { $0 !== current && !$0.isHidden && $0.windowLevel == .normal }) {
            main.makeKey()
        }
    }
}
