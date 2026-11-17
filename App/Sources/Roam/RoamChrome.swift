import SwiftUI

/// The globe in a chat's top bar. It shows once the browser has a page, and pulses while a companion is on it.
struct RoamButton: View {
    @ObservedObject var browser: BrowserSession
    let open: (Bool) -> Void

    var body: some View {
        if browser.used || browser.url != nil {
            Button {
                Haptics.light()
                open(true)
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "safari")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Ink.ink)
                        .symbolEffect(.pulse, isActive: browser.loading)
                        .frame(width: 38, height: 38)
                        .glassEffect(.regular, in: .circle)
                    if browser.handoff != nil {
                        Circle().fill(Ink.warn).frame(width: 9, height: 9).offset(x: -2, y: 2)
                    }
                }
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("打开远游")
            .transition(.scale(scale: 0.6).combined(with: .opacity))
        }
    }
}

/// Above the composer when a companion is waiting for the user to do a step in the browser by hand.
struct RoamSlip: View {
    @ObservedObject var browser: BrowserSession
    let open: () -> Void

    var body: some View {
        if let reason = browser.handoff {
            Button {
                Haptics.grab()
                open()
            } label: {
                HStack(spacing: Ink.Space.m) {
                    Image(systemName: "hand.raised").foregroundStyle(Ink.warn)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("远游 · 请你接手").font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.ink)
                        Text(reason).font(Ink.footnote).foregroundStyle(Ink.inkSoft).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text("去看看").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.accent)
                }
                .padding(Ink.Space.m)
                .paperCard()
            }
            .buttonStyle(PressStyle())
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
