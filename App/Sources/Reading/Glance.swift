import SwiftUI
import Craft

/// A ring around a companion's face that breathes while it works (in its own colour), and fades when it is done.
/// Still at a steady brightness when Reduce Motion is on. After Cindy's presence ring (Apache-2.0).
struct BreathingRing: ViewModifier {
    let on: Bool
    var tint: Color
    var gap: CGFloat = 2
    @Environment(\.accessibilityReduceMotion) private var still
    @State private var bright = false

    func body(content: Content) -> some View {
        content.overlay {
            if on {
                Circle()
                    .strokeBorder(tint, lineWidth: 2)
                    .padding(-gap - 2)
                    .opacity(still ? 0.8 : (bright ? 1 : 0.3))
                    .onAppear {
                        guard !still else { return }
                        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { bright = true }
                    }
                    .onDisappear { bright = false }
                    .transition(.opacity.animation(.easeOut(duration: 0.15)))
                    .accessibilityHidden(true)
            }
        }
    }
}

extension View {
    func breathing(_ on: Bool, tint: Color) -> some View { modifier(BreathingRing(on: on, tint: tint)) }
}
