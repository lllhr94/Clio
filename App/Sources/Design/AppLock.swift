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

    func body(content: Content) -> some View {
        content
            .overlay {
                if on && (locked || phase != .active) {
                    cover.transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.2), value: locked)
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
                    .font(.system(size: 34, weight: .medium))
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
