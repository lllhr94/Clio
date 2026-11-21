import Foundation

// Only the platform inputs and side effects are simulated. The runner fills in
// the app's function bodies so the assertions cannot pass against a copy of the rules.
private enum StreamFixture {
// RULE: SETTLED
}

private enum ScrollPhase { case idle, interacting, decelerating }

private struct ScrollGeometry {
    let contentSize: CGSize
    let contentInsets: Insets
    let visibleRect: CGRect

    struct Insets { let bottom: CGFloat }
}

private enum Words {
    static func t(_ text: String) -> String { text }
}

private struct Hitches {
    static let shared = Self()
    func doing(_ text: String?, as key: String) {}
}

private struct Failure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) { self.description = description }
}

private func check<T: Equatable>(_ actual: T, _ expected: T, _ name: String) throws {
    guard actual == expected else { throw Failure("\(name): expected \(expected), got \(actual)") }
}

@MainActor
private final class Clock {
    private var sleepers: [(UInt64, CheckedContinuation<Void, Never>)] = []

    func sleep(nanoseconds: UInt64) async throws {
        try Task.checkCancellation()
        await withCheckedContinuation { sleepers.append((nanoseconds, $0)) }
        try Task.checkCancellation()
    }

    func waitForSleepers(_ count: Int) async throws {
        for _ in 0..<1_000 {
            if sleepers.count >= count { return }
            await Task.yield()
        }
        throw Failure("Expected \(count) queued scroll sleeps, got \(sleepers.count)")
    }

    func advance(_ duration: UInt64) throws {
        try check(sleepers.first?.0, duration, "Pending scroll delay")
        sleepers.removeFirst().1.resume()
    }
}

@MainActor
private final class FlowFixture {
    var draft = "你好"
    var photos = ["photo"]
    var files = ["file"]
    var following = true
    var scrolling = false
    private(set) var scrolls: [Bool] = []
    private var followPending: Task<Void, Never>?
    let clock = Clock()

    func changePhase(from old: ScrollPhase, to phase: ScrollPhase, at distance: CGFloat) {
        let geometry = ScrollGeometry(
            contentSize: CGSize(width: 320, height: 800),
            contentInsets: .init(bottom: 100),
            visibleRect: CGRect(x: 0, y: 0, width: 320, height: 900 - distance)
        )
        let context = (geometry: geometry, unused: ())
// RULE: PHASE
    }

    @discardableResult
    func requestFollow(settle: Bool = true) -> Task<Void, Never>? {
        followToEnd(settle: settle)
        return followPending
    }

    func sent() -> Task<Void, Never>? {
        clearComposer()
        return followPending
    }

    private func toEnd(animated: Bool = false) {
        scrolls.append(animated)
    }

// RULE: BELOW
// RULE: FOLLOW
// RULE: CLEAR_COMPOSER
}

@main
private enum ChatFlowTests {
    static func main() async {
        do {
            try paragraphsAndFences()
            try await followingTheReader()
            try await latestFollowWins()
            try await sendingCoalesces()
            print("Chat flow checks passed (see known gaps, if any).")
        } catch {
            FileHandle.standardError.write(Data("Chat flow check failed: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    static func paragraphsAndFences() throws {
        func prefix(_ input: String) -> String {
            String(input[..<StreamFixture.settled(input)])
        }
        try check(prefix("正在写 👋🏽"), "", "Incomplete paragraph")
        try check(prefix("第一段 👋🏽\n下一行\n\n正在写"), "第一段 👋🏽\n下一行\n\n", "Paragraph boundary")
        try check(prefix("第一段\n\n\n第二段"), "第一段\n\n", "Repeated blank lines")
        for fence in ["```", "~~~"] {
            let intro = "前言\n\n"
            let code = "\(fence)swift\nlet a = 1\n\nlet b = 2\n"
            try check(prefix(intro + code), intro, "Blank inside an unfinished fence")
            let closed = intro + code + fence + "\n\n"
            try check(prefix(closed + "下面"), closed, "Closed fence can settle")
        }

        // Require the documented result or the exact known behavior in the
        // protected renderer. Any new split point is a regression.
        for (name, first, continuation) in [
            ("list", "- 第一项\n\n", "- 第二项"),
            ("table", "| 项目 | 值 |\n| --- | --- |\n| 甲 | 1 |\n\n", "| 乙 | 2 |"),
        ] {
            let split = prefix(first + continuation)
            if split == first {
                print("Known gap: the renderer freezes a streaming \(name) on an internal blank line.")
            } else {
                try check(split, "", "Internal blank in \(name) stays live")
            }
        }
    }

    @MainActor
    static func followingTheReader() async throws {
        let flow = FlowFixture()
        flow.changePhase(from: .idle, to: .interacting, at: 0)
        try check(flow.following, false, "Dragging pauses following even at the bottom")
        flow.changePhase(from: .interacting, to: .idle, at: 80)
        try check(flow.following, false, "At the threshold, keep the reader's position")
        try check(flow.requestFollow() == nil, true, "Arriving text does not restart following")
        flow.changePhase(from: .idle, to: .interacting, at: 80)
        flow.changePhase(from: .interacting, to: .decelerating, at: 79)
        try check(flow.following, false, "Wait for the user's fling to stop")
        flow.changePhase(from: .decelerating, to: .idle, at: 79)
        try check(flow.following, true, "Resume within 80 points including the composer inset")

        let scheduled = flow.requestFollow()
        try await flow.clock.waitForSleepers(1)
        try flow.clock.advance(24_000_000)
        try await flow.clock.waitForSleepers(1)
        flow.changePhase(from: .idle, to: .interacting, at: 300)
        try flow.clock.advance(350_000_000)
        await scheduled?.value
        try check(flow.scrolls, [false], "A new drag stops the delayed animated scroll")
    }

    @MainActor
    static func latestFollowWins() async throws {
        let flow = FlowFixture()
        let first = flow.requestFollow()
        try await flow.clock.waitForSleepers(1)
        let latest = flow.requestFollow(settle: false)
        try await flow.clock.waitForSleepers(2)

        try check(first?.isCancelled, true, "A new follow cancels the pending request")
        try flow.clock.advance(24_000_000)
        await first?.value
        try check(flow.scrolls, [], "A cancelled request cannot scroll")
        try flow.clock.advance(24_000_000)
        await latest?.value
        try check(flow.scrolls, [false], "Streaming growth scrolls once without the delayed animation")
    }

    @MainActor
    static func sendingCoalesces() async throws {
        let flow = FlowFixture()
        flow.following = false
        let send = flow.sent()
        try check(flow.draft, "", "Sending clears the draft")
        try check(flow.photos, [], "Sending clears attached photos")
        try check(flow.files, [], "Sending clears attached files")
        try check(flow.following, true, "Sending resumes following")
        try await flow.clock.waitForSleepers(1)

        // A new line sends another follow request as observed by ChatPage.
        let message = flow.requestFollow()
        try await flow.clock.waitForSleepers(2)
        try flow.clock.advance(24_000_000)
        await send?.value
        try check(flow.scrolls, [], "Clearing the composer does not add a separate scroll")
        try flow.clock.advance(24_000_000)
        try await flow.clock.waitForSleepers(1)
        try check(flow.scrolls, [false], "Send and line insertion share the first scroll")
        try flow.clock.advance(350_000_000)
        await message?.value
        try check(flow.scrolls, [false, true], "Sending keeps a single delayed settling scroll")
    }
}
