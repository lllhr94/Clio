import SwiftUI

/// The globe in a chat's top bar: always there, so the user can open 远游 without asking a companion; it pulses while one is on it.
struct RoamButton: View {
    @ObservedObject var browser: BrowserSession
    /// Inside a group of buttons that share one glass: no glass of its own.
    var bare = false
    let open: (Bool) -> Void

    var body: some View {
        Group {
            Button {
                Haptics.light()
                open(true)
            } label: {
                ZStack(alignment: .topTrailing) {
                    if bare {
                        Image(systemName: "safari")
                            .font(.system(size: Ink.Size.body, weight: .medium))
                            .foregroundStyle(Ink.ink)
                            .symbolEffect(.pulse, isActive: browser.loading)
                            .frame(width: Ink.Bar.height * 0.9, height: Ink.Bar.height)
                            .contentShape(Rectangle())
                    } else {
                        Image(systemName: "safari")
                            .font(.system(size: Ink.Size.body, weight: .medium))
                            .foregroundStyle(Ink.ink)
                            .symbolEffect(.pulse, isActive: browser.loading)
                            .frame(width: Ink.Bar.height, height: Ink.Bar.height)
                            .glassFace(in: Circle())
                    }
                    if browser.handoff != nil {
                        Circle().fill(Ink.warn).frame(width: 9, height: 9).offset(x: -2, y: 2)
                    }
                }
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel(Words.t("打开远游"))
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
                    VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
                        Text(Words.t("远游 · 请你接手")).font(.system(size: Ink.Size.sub, weight: .semibold)).foregroundStyle(Ink.ink)
                        Text(reason).font(Ink.footnote).foregroundStyle(Ink.inkSoft).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text("去看看").font(.system(size: Ink.Size.small, weight: .semibold)).foregroundStyle(Ink.accent)
                }
                .padding(Ink.Space.m)
                .paperCard()
            }
            .buttonStyle(PressStyle())
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}


/// 远游 as a small window on the chat page: the real page, shrunk, live. Tap to open it full; the cross puts it away.
struct RoamThumb: View {
    @ObservedObject var browser: BrowserSession
    /// The conversation under it is scrolling: show the still picture even while a tool works, so the page is not drawn twice per frame.
    var frozen = false
    let open: () -> Void
    private let scale: CGFloat = 0.3
    private let page = CGSize(width: 390, height: 640)

    var body: some View {
        if browser.used && !browser.thumbHidden && browser.url != nil {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Ink.Space.xs) {
                    if browser.loading { ProgressView().controlSize(.mini) } else { Image(systemName: "safari").font(.system(size: Ink.Size.micro, weight: .semibold)) }
                    Text(browser.url?.host() ?? Words.t("远游")).font(.system(size: Ink.Size.micro, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 0)
                    Button {
                        Haptics.light()
                        withAnimation(Ink.Motion.settle) { browser.thumbHidden = true }
                    } label: {
                        Image(systemName: "xmark").font(.system(size: Ink.Size.micro, weight: .bold)).frame(width: 18, height: 18)
                    }
                    .buttonStyle(TapStyle(grow: 8))
                    .accessibilityLabel("收起小窗")
                }
                .foregroundStyle(Ink.inkSoft)
                .padding(.horizontal, Ink.Space.s)
                .frame(height: 22)
                // Live only while a browser tool works; otherwise a still picture of the page, which costs nothing to draw.
                // Either way a tap anywhere on it opens 远游 full screen.
                ZStack(alignment: .topLeading) {
                    if browser.acting || browser.still == nil {
                        WebHost(view: browser.view, interactive: false, hidden: frozen && browser.still != nil)
                            .frame(width: page.width, height: page.height)
                            .scaleEffect(scale, anchor: .topLeading)
                            .frame(width: page.width * scale, height: page.height * scale, alignment: .topLeading)
                    }
                    if let still = browser.still, !browser.acting || frozen {
                        Image(uiImage: still)
                            .resizable()
                            .scaledToFill()
                            .frame(width: page.width * scale, height: page.height * scale, alignment: .top)
                    }
                }
                .frame(width: page.width * scale, height: page.height * scale, alignment: .topLeading)
                .clipped()
                .overlay(Ink.Artwork.white.opacity(0.001))
            }
            // As wide as the shrunk page: without this the title row's spacer stretched it across the chat.
            .frame(width: page.width * scale)
            .background(Ink.paperRaised)
            .clipShape(.rect(cornerRadius: Ink.Radius.small, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Ink.Radius.small, style: .continuous).strokeBorder(browser.handoff != nil ? Ink.warn : Ink.rule, lineWidth: browser.handoff != nil ? 2 : 1))
            .shadow(color: Ink.ink.opacity(0.12), radius: 10, y: 4)
            .contentShape(.rect)
            .onTapGesture {
                Haptics.light()
                open()
            }
            .accessibilityLabel(Words.t("远游小窗，点开看全屏"))
            .transition(.scale(scale: 0.7, anchor: .topTrailing).combined(with: .opacity))
        }
    }
}
