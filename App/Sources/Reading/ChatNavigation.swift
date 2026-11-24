import Observation
import SwiftUI
import UIKit

/// Scroll-driven overlay state isolated from `ChatPage`'s stored `@State` so showing/hiding
/// jump controls, scrubbing the minimap, or starting/stopping scroll never redraws chat rows.
@MainActor @Observable
final class ChatChrome {
    var jumpVisible = false
    var farFromEnd = false
    var minimapScrub: Int?
    var scrolling = false
}

final class ChatViewport {
    var ids: [String] = []
    var needsEndCorrection = false
    var touchScrolling = false
    var lastStirAt: TimeInterval = ProcessInfo.processInfo.systemUptime
    var scrollPhaseLabel = "静止"
    private var jump: (source: String, at: TimeInterval)?

    func recordJump(_ source: String) {
        jump = (source, ProcessInfo.processInfo.systemUptime)
        DiagTrail.record(source)
    }

    var recentJump: String? {
        guard let jump, ProcessInfo.processInfo.systemUptime - jump.at < 1.2 else { return nil }
        return jump.source
    }
}

struct ChatScrollSample: Equatable {
    let offsetBucket: Int
    let contentHeightBucket: Int
    let viewportHeightBucket: Int
    let offset: CGFloat
    let contentHeight: CGFloat
    let viewportHeight: CGFloat

    init(offset: CGFloat, contentHeight: CGFloat, viewportHeight: CGFloat) {
        self.offset = offset
        self.contentHeight = contentHeight
        self.viewportHeight = viewportHeight
        self.offsetBucket = offset.isFinite ? Int((offset / 16).rounded()) : 0
        self.contentHeightBucket = contentHeight.isFinite ? Int((contentHeight / 4).rounded()) : 0
        self.viewportHeightBucket = viewportHeight.isFinite ? Int((viewportHeight / 4).rounded()) : 0
    }

    static func == (lhs: ChatScrollSample, rhs: ChatScrollSample) -> Bool {
        lhs.offsetBucket == rhs.offsetBucket
            && lhs.contentHeightBucket == rhs.contentHeightBucket
            && lhs.viewportHeightBucket == rhs.viewportHeightBucket
    }
}

struct ChatRoamThumbOverlay: View {
    let browser: BrowserSession
    let chrome: ChatChrome
    let open: () -> Void

    var body: some View {
        RoamThumb(browser: browser, frozen: chrome.scrolling, open: open)
    }
}

struct ChatFloatingJumpOverlay: View {
    let chrome: ChatChrome
    let petPerch: PetPerch
    let inHistory: Bool
    let following: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onLatest: () -> Void

    private var latestIsFloating: Bool {
        chrome.jumpVisible && (inHistory || (chrome.farFromEnd && !following))
    }

    private func updateKeepOut() {
        let width: CGFloat
        if chrome.jumpVisible && latestIsFloating {
            width = 104 * UIScale.factor + Ink.Space.xs + Ink.Space.s
        } else if chrome.jumpVisible {
            width = 70 * UIScale.factor + Ink.Space.s
        } else if latestIsFloating {
            width = 32 * UIScale.factor + Ink.Space.s
        } else {
            width = 0
        }
        withAnimation(Ink.Motion.settle) { petPerch.keepOutRight = width }
    }

    var body: some View {
        let controlHeight = 32 * UIScale.factor
        HStack(spacing: Ink.Space.xs) {
            HStack(spacing: 0) {
                jumpButton("arrow.up", title: "chat.previousQuestion", action: onPrevious)
                Rectangle()
                    .fill(Ink.rule.opacity(0.7))
                    .frame(width: 0.5, height: 14 * UIScale.factor)
                jumpButton("arrow.down", title: "chat.nextQuestion", action: onNext)
            }
            .frame(height: controlHeight)
            .glassBacking(in: Capsule())
            .opacity(chrome.jumpVisible ? 1 : 0)
            .allowsHitTesting(chrome.jumpVisible)
            .accessibilityHidden(!chrome.jumpVisible)

            if latestIsFloating {
                Button(action: onLatest) {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: Ink.Size.small, weight: .semibold))
                        .foregroundStyle(Ink.ink)
                        .frame(width: 32 * UIScale.factor, height: 32 * UIScale.factor)
                        .glassFace(in: Circle())
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel(L.t("chat.latest"))
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .offset(y: -(controlHeight + Ink.Space.s))
        .onChange(of: chrome.jumpVisible, initial: true) { _, _ in updateKeepOut() }
        .onChange(of: latestIsFloating, initial: true) { _, _ in updateKeepOut() }
        .animation(Ink.Motion.settle, value: chrome.jumpVisible)
        .animation(Ink.Motion.settle, value: latestIsFloating)
    }

    private func jumpButton(_ symbol: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: Ink.Size.small, weight: .semibold))
                .foregroundStyle(Ink.inkSoft)
                .frame(width: 34 * UIScale.factor, height: 32 * UIScale.factor)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(L.t(title))
    }
}

/// 长对话小地图 (after Kelivo): isolated in its own view so scrub/visibility changes never redraw chat rows.
struct ChatMinimapOverlay: View {
    let chrome: ChatChrome
    let viewport: ChatViewport
    let chat: ChatModel
    let historyPage: [ChatLine]?
    let shownCount: Int
    let onCancelHide: () -> Void
    let onJump: (String, Bool, String) -> Void
    let onStepQuestion: (Bool) -> Void

    var body: some View {
        if chrome.jumpVisible {
            let rows = historyPage.map { $0[...] } ?? chat.lines.suffix(shownCount)
            let asked = rows.indices.filter { rows[$0].kind == .user }
            if rows.count >= 30, asked.count >= 4 {
                strip(rows: rows, asked: asked)
            }
        }
    }

    private func strip(rows: ArraySlice<ChatLine>, asked: [Int]) -> some View {
        let visible = Set(viewport.ids)
        let first = rows.startIndex
        let span = max(1, rows.count - 1)
        return GeometryReader { box in
            let height = box.size.height
            let place = { (index: Int) in height * CGFloat(index - first) / CGFloat(span) }
            let nearest = { (y: CGFloat) in asked.min(by: { abs(place($0) - y) < abs(place($1) - y) }) }
            ZStack(alignment: .top) {
                Capsule().fill(Ink.rule.opacity(0.28)).frame(width: 1)
                ForEach(asked, id: \.self) { index in
                    // While sliding, the finger's question is the one lit; otherwise the ones on screen.
                    let lit = chrome.minimapScrub.map { $0 == index } ?? visible.contains(rows[index].id)
                    Capsule()
                        .fill(lit ? Ink.accent : Ink.inkFaint.opacity(0.45))
                        .frame(width: lit ? 10 : 4, height: lit ? 2.5 : 2)
                        .offset(y: place(index) - 1)
                }
            }
            .frame(width: 16, height: height, alignment: .top)
            .contentShape(Rectangle().inset(by: -Ink.Space.m))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        onCancelHide()
                        guard let index = nearest(drag.location.y), index != chrome.minimapScrub else { return }
                        if chrome.minimapScrub != nil { Haptics.tick(0.3) }
                        chrome.minimapScrub = index
                    }
                    .onEnded { drag in
                        let index = nearest(drag.location.y) ?? chrome.minimapScrub
                        chrome.minimapScrub = nil
                        guard let index, rows.indices.contains(index) else { return }
                        let rank = (asked.firstIndex(of: index) ?? 0) + 1
                        onJump(rows[index].id, false, "小地图(\(rank)/\(asked.count))")
                    }
            )
            .overlay(alignment: .topTrailing) {
                if let index = chrome.minimapScrub, rows.indices.contains(index) {
                    Text(rows[index].text.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: Ink.Size.small))
                        .foregroundStyle(Ink.ink)
                        .lineLimit(2)
                        .frame(width: 200, alignment: .trailing)
                        .padding(.horizontal, Ink.Space.m)
                        .padding(.vertical, Ink.Space.s)
                        .glassFace(in: RoundedRectangle(cornerRadius: Ink.Radius.small, style: .continuous))
                        .offset(x: -24, y: min(max(0, place(index) - 18), max(0, height - 44)))
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
        }
        .frame(width: 16)
        .padding(.vertical, Ink.Bar.height * 2)
        .padding(.trailing, 2)
        .transition(.opacity)
        .accessibilityElement()
        .accessibilityLabel(L.t("chat.questionMap"))
        .accessibilityValue(minimapPlace(rows: rows, asked: asked, visible: visible))
        .accessibilityAdjustableAction { direction in
            onStepQuestion(direction == .decrement)
        }
    }

    private func minimapPlace(rows: ArraySlice<ChatLine>, asked: [Int], visible: Set<String>) -> String {
        guard let at = asked.firstIndex(where: { visible.contains(rows[$0].id) }) else { return "\(asked.count)" }
        return "\(at + 1) / \(asked.count)"
    }
}

struct ChatBrowserIndicator: View {
    @ObservedObject var browser: BrowserSession
    let open: () -> Void
    var body: some View {
        if browser.acting {
            Button(action: open) {
                Image(systemName: "globe")
                    .font(.system(size: Ink.Size.body, weight: .medium))
                    .symbolEffect(.pulse)
                    .frame(width: Ink.Bar.height, height: Ink.Bar.height)
                    .glassFace(in: Circle())
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel(L.t("nav.browser"))
        }
    }
}

struct ChatShareSheet: UIViewControllerRepresentable {
    private let items: [Any]

    init(url: URL) { items = [url] }
    init(image: UIImage) { items = [image] }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
