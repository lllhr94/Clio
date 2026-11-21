import LocalAuthentication
import SwiftUI

/// Face ID lock for the whole app: when on, the app covers itself after going to the background
/// and opens again only after Face ID (or the passcode).
struct AppLock: ViewModifier {
    @Environment(\.scenePhase) private var phase
    @AppStorage("lock.faceid") private var on = false
    @State private var locked = UserDefaults.standard.bool(forKey: "lock.faceid")
    @State private var asking = false
    /// Only coming back from the background asks by itself; dismissing the Face ID sheet does not ask again.
    @State private var wasAway = false

    private var covering: Bool { on && (locked || phase != .active) }

    func body(content: Content) -> some View {
        content
            // The cover is a window of its own above everything, sheets included: drawn as an overlay it sat under
            // any open sheet (信匣 with a password shown, say), which then showed in the app switcher and stayed usable.
            .onChange(of: "\(covering)|\(locked)|\(asking)", initial: true) {
                if covering { LockCurtain.shared.show(AnyView(cover)) } else { LockCurtain.shared.hide() }
            }
            .onChange(of: phase) { _, now in
                if now == .background, on { locked = true; wasAway = true }
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
        // No Face ID and no passcode on this phone: a lock could never open, so don't hold the door.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &problem) else {
            locked = false
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

/// The window the lock cover is drawn in, above alerts and sheets.
@MainActor
final class LockCurtain {
    static let shared = LockCurtain()
    private var window: UIWindow?

    func show(_ content: AnyView) {
        if let window, let host = window.rootViewController as? UIHostingController<AnyView> {
            host.rootView = content
            window.isHidden = false
            return
        }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState != .unattached }) else { return }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        let host = UIHostingController(rootView: content)
        host.view.backgroundColor = .clear
        window.rootViewController = host
        window.isHidden = false
        self.window = window
    }

    func hide() {
        window?.isHidden = true
        window = nil
    }
}
