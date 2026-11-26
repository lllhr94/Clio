import Observation
import SwiftUI
import UIKit

/// Scroll-driven overlay state isolated from `ChatPage`'s stored `@State` so showing/hiding
/// jump controls, scrubbing the minimap, or starting/stopping scroll never redraws chat rows.
@MainActor @Observable
final class ChatChrome {
    var jumpVisible = false
    var farFromEnd = false
    var unreadCount = 0
    var minimapScrub: Int?
    var activeTurnID: String?
    var scrolling = false
}

final class ChatViewport {
    var ids: [String] = []
    var needsEndCorrection = false
    var touchScrolling = false
    var isTouching = false
    var jumpedTo: String?
    var navigationGeneration: UInt64 = 0
    var lastStirAt: TimeInterval = ProcessInfo.processInfo.systemUptime
    var scrollPhaseLabel = "静止"
    private var jump: (source: String, at: TimeInterval)?

    func advanceNavigation() {
        navigationGeneration &+= 1
    }

    func recordJump(_ source: String) {
        navigationGeneration &+= 1
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

struct ChatUnreadBadge: View {
    let count: Int

    var body: some View {
        let label = count > 99 ? "99+" : "\(count)"
        Text(label)
            .font(.system(size: ChatBarMetrics.microFontSize, weight: .bold).monospacedDigit())
            .foregroundStyle(Ink.onAccent)
            .padding(.horizontal, 5 * ChatBarMetrics.scale)
            .frame(minWidth: 18 * ChatBarMetrics.scale)
            .frame(height: 18 * ChatBarMetrics.scale)
            .background(Ink.accent, in: Capsule(style: .continuous))
            .offset(x: 4 * ChatBarMetrics.scale, y: -4 * ChatBarMetrics.scale)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct ChatFloatingJumpOverlay: View {
    let chrome: ChatChrome
    let petPerch: PetPerch
    let inHistory: Bool
    let following: Bool
    var suppressed: Bool = false
    let onLatest: () -> Void

    private var latestIsFloating: Bool {
        inHistory || (chrome.farFromEnd && !following)
    }

    private func updateKeepOut() {
        let width = ChatChromeCoordinator.jumpKeepOutWidth(
            latestVisible: !suppressed && latestIsFloating
        )
        withAnimation(Ink.Motion.settle) { petPerch.keepOutRight = width }
    }

    var body: some View {
        let showLatest = !suppressed && latestIsFloating
        HStack {
            Spacer(minLength: 0)
            if showLatest {
                latestButton
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .offset(y: -(ChatBarMetrics.jumpSize + Ink.Space.s))
        .onChange(of: latestIsFloating, initial: true) { _, _ in updateKeepOut() }
        .onChange(of: suppressed, initial: true) { _, _ in updateKeepOut() }
        .onChange(of: UIScale.factor) { _, _ in updateKeepOut() }
        .animation(Ink.Motion.settle, value: showLatest)
    }

    private var latestButton: some View {
        let latestSize = ChatBarMetrics.jumpSize
        return Button(action: onLatest) {
            Image(systemName: "chevron.down")
                .font(.system(size: ChatBarMetrics.titleFontSize, weight: .semibold))
                .foregroundStyle(Ink.ink)
                .frame(width: latestSize, height: latestSize)
                .frostedChatChrome(in: Circle())
                .contentShape(Circle())
                .overlay(alignment: .topTrailing) {
                    if chrome.unreadCount > 0 {
                        ChatUnreadBadge(count: chrome.unreadCount)
                    }
                }
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(
            chrome.unreadCount > 0
                ? "\(L.t("chat.latest"))，\(chrome.unreadCount)"
                : L.t("chat.latest")
        )
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
    var onPrewarm: (String) -> Void = { _ in }

    var body: some View {
        let rows = historyPage.map { $0[...] } ?? chat.lines.suffix(shownCount)
        let asked = rows.indices.filter { rows[$0].kind == .user }
        if rows.count >= 30, asked.count >= 4 {
            strip(rows: rows, asked: asked)
                .opacity(chrome.jumpVisible ? 1 : 0)
                .allowsHitTesting(chrome.jumpVisible)
                .accessibilityHidden(!chrome.jumpVisible)
                .animation(Ink.Motion.settle, value: chrome.jumpVisible)
        }
    }

    private func strip(rows: ArraySlice<ChatLine>, asked: [Int]) -> some View {
        let first = rows.startIndex
        let span = max(1, rows.count - 1)
        var askedIndexByID: [String: Int] = [:]
        askedIndexByID.reserveCapacity(asked.count)
        for idx in asked {
            askedIndexByID[rows[idx].id] = idx
        }
        return GeometryReader { box in
            let height = box.size.height
            let place = { (index: Int) in height * CGFloat(index - first) / CGFloat(span) }
            let nearest = { (y: CGFloat) in asked.min(by: { abs(place($0) - y) < abs(place($1) - y) }) }
            ZStack(alignment: .top) {
                Canvas { context, size in
                    let trackRect = CGRect(x: (size.width - 1) * 0.5, y: 0, width: 1, height: size.height)
                    context.fill(Path(roundedRect: trackRect, cornerRadius: 0.5), with: .color(Ink.rule.opacity(0.28)))
                    let tickColor = Ink.inkFaint.opacity(0.45)
                    let tickX = (size.width - 4) * 0.5
                    for index in asked {
                        let y = size.height * CGFloat(index - first) / CGFloat(span) - 1
                        let rect = CGRect(x: tickX, y: y, width: 4, height: 2)
                        context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(tickColor))
                    }
                }
                .frame(width: 16, height: height)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

                ChatMinimapCursorOverlay(
                    chrome: chrome,
                    viewport: viewport,
                    rows: rows,
                    asked: asked,
                    askedIndexByID: askedIndexByID,
                    height: height,
                    onStepQuestion: onStepQuestion
                )
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
                        if rows.indices.contains(index) {
                            onPrewarm(rows[index].id)
                        }
                    }
                    .onEnded { drag in
                        let index = nearest(drag.location.y) ?? chrome.minimapScrub
                        chrome.minimapScrub = nil
                        guard let index, rows.indices.contains(index) else { return }
                        let rank = (asked.firstIndex(of: index) ?? 0) + 1
                        onJump(rows[index].id, false, "小地图(\(rank)/\(asked.count))")
                    }
            )
        }
        .frame(width: 16)
        .padding(.vertical, Ink.Space.m)
        .padding(.trailing, 2)
        .transition(.opacity)
    }
}

private struct ChatMinimapCursorOverlay: View {
    let chrome: ChatChrome
    let viewport: ChatViewport
    let rows: ArraySlice<ChatLine>
    let asked: [Int]
    let askedIndexByID: [String: Int]
    let height: CGFloat
    let onStepQuestion: (Bool) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var activeIndex: Int? {
        if let scrub = chrome.minimapScrub, rows.indices.contains(scrub) {
            return scrub
        }
        if let turnID = chrome.activeTurnID, let idx = askedIndexByID[turnID] {
            return idx
        }
        let visible = Set(viewport.ids)
        if let firstVisible = rows.indices.first(where: { visible.contains(rows[$0].id) }) {
            return asked.last(where: { $0 <= firstVisible }) ?? asked.first
        }
        return nil
    }

    private var cursorAnimation: Animation? {
        if chrome.minimapScrub == nil && !reduceMotion {
            return .interactiveSpring(response: 0.14, dampingFraction: 0.90)
        }
        return nil
    }

    var body: some View {
        let first = rows.startIndex
        let span = max(1, rows.count - 1)
        let currentActive = activeIndex

        ZStack(alignment: .top) {
            if let idx = currentActive {
                let y = height * CGFloat(idx - first) / CGFloat(span) - 1.25
                Capsule()
                    .fill(Ink.accent)
                    .frame(width: 10, height: 2.5)
                    .offset(y: y)
                    .animation(cursorAnimation, value: currentActive)
            }
        }
        .frame(width: 16, height: height, alignment: .top)
        .allowsHitTesting(false)
        .overlay(alignment: .topTrailing) {
            if let index = chrome.minimapScrub, rows.indices.contains(index) {
                let previewY = height * CGFloat(index - first) / CGFloat(span)
                Text(rows[index].text.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: Ink.Size.small))
                    .foregroundStyle(Ink.ink)
                    .lineLimit(2)
                    .frame(width: 200, alignment: .trailing)
                    .padding(.horizontal, Ink.Space.m)
                    .padding(.vertical, Ink.Space.s)
                    .glassFace(in: RoundedRectangle(cornerRadius: Ink.Radius.small, style: .continuous))
                    .offset(x: -24, y: min(max(0, previewY - 18), max(0, height - 44)))
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(L.t("chat.questionMap"))
        .accessibilityValue(accessibilityRank(for: currentActive))
        .accessibilityAdjustableAction { direction in
            onStepQuestion(direction == .decrement)
        }
    }

    private func accessibilityRank(for index: Int?) -> String {
        guard let index, let pos = asked.firstIndex(of: index) else { return "\(asked.count)" }
        return "\(pos + 1) / \(asked.count)"
    }
}

struct ChatBrowserIndicator: View {
    @ObservedObject var browser: BrowserSession
    let open: () -> Void
    var body: some View {
        if browser.acting {
            Button(action: open) {
                Image(systemName: "globe")
                    .font(.system(size: ChatBarMetrics.iconFontSize, weight: .medium))
                    .symbolEffect(.pulse)
                    .frame(width: ChatBarMetrics.height, height: ChatBarMetrics.height)
                    .frostedChatChrome(in: Circle())
                    .contentShape(Circle())
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
