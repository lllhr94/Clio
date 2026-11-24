import Foundation

// Only the platform inputs and side effects are simulated. The runner fills in
// the app's function bodies so the assertions cannot pass against a copy of the rules.
// RULE: STREAM_BLOCKS
// RULE: DRAFT_INPUT

private enum ScrollPhase { case idle, interacting, decelerating, animating }

private struct ScrollGeometry {
    let contentSize: ContentSize
    let contentInsets: Insets
    let visibleRect: VisibleRect

    struct ContentSize { let height: CGFloat }
    struct Insets { let bottom: CGFloat }
    struct VisibleRect { let maxY: CGFloat }
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
    private var observer: (count: Int, continuation: CheckedContinuation<Void, Never>)?

    func sleep(for duration: Duration) async throws {
        let nanoseconds = UInt64(duration.components.attoseconds / 1_000_000_000)
        try Task.checkCancellation()
        await withCheckedContinuation { continuation in
            sleepers.append((nanoseconds, continuation))
            if let waiting = observer, sleepers.count >= waiting.count {
                observer = nil
                waiting.continuation.resume()
            }
        }
        try Task.checkCancellation()
    }

    func waitForSleepers(_ count: Int) async {
        guard sleepers.count < count else { return }
        await withCheckedContinuation { observer = (count, $0) }
    }

    func advance(_ duration: UInt64) throws {
        try check(sleepers.first?.0, duration, "Pending scroll delay")
        sleepers.removeFirst().1.resume()
    }
}

/// Stands in for the app's draft store; the fixture only checks the composer empties.
private enum DraftAttachments {
    static func clear(_ chat: String) {}
}

@MainActor
private final class FlowFixture {
    var pasteTask: Task<Void, Never>?
    var draft = "你好"
    var photos = ["photo"]
    var files = ["file"]
    var draftAttachmentQueuedIds: [UUID] = [UUID()]
    var following = true
    var scrolling = false
    var touchScrolling = false
    let chat = HistoryPause()

    final class HistoryPause {
        let key = "chat"
        private(set) var browsing = false
        func setBrowsingHistory(_ active: Bool) { browsing = active }
    }
    var jumpedTo: String?
    var hideJumps: Task<Void, Never>?
    var jumpVisible = false
    var selecting: Set<UUID> = []
    var historyPage: [String]?

    func lingerJumpButtons() {}
    func invalidatePhotoSelection() {}
    private(set) var scrolls: [Bool] = []
    private var followPending: Task<Void, Never>?
    private var settleEnd: Task<Void, Never>?
    let clock = Clock()

    func changePhase(from old: ScrollPhase, to phase: ScrollPhase, at distance: CGFloat) {
        let geometry = ScrollGeometry(
            contentSize: .init(height: 800),
            contentInsets: .init(bottom: 100),
            visibleRect: .init(maxY: 900 - distance)
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
            try draftInput()
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
            var blocks = StreamBlocks()
            for character in input { blocks.append(String(character)) }
            return blocks.finished.joined()
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

        var accumulator = StreamBlocks()
        accumulator.append("前言\r")
        accumulator.append("\n\r\n")
        accumulator.append("👋")
        accumulator.append("🏽")
        try check(accumulator.finished, ["前言\r\n\r\n"], "CRLF split across updates")
        try check(accumulator.tail, "👋🏽", "Combining scalars in the tail")

        // A blank line inside a list, a table or a quote keeps the block live while it carries on.
        for (name, first, continuation) in [
            ("list", "- 第一项\n\n", "- 第二项\n"),
            ("table", "| 项目 | 值 |\n| --- | --- |\n| 甲 | 1 |\n\n", "| 乙 | 2 |\n"),
            ("numbered list", "1. 第一项\n\n", "2. 第二项\n"),
            ("quote", "> 一句\n\n", "> 又一句\n"),
        ] {
            try check(prefix(first + continuation), "", "Internal blank in \(name) stays live")
        }
        // And it does end once something else is written.
        try check(prefix("- 第一项\n\n下一段\n"), "- 第一项\n\n", "A list ends at the next paragraph")
        try check(prefix("| 甲 | 1 |\n\n下一段\n\n"), "| 甲 | 1 |\n\n下一段\n\n", "A table ends at the next paragraph")
    }

    static func draftInput() throws {
        let prefix = String(repeating: "正文", count: 2000)
        try check(DraftInput.suggestion(in: prefix), nil, "A long draft without a command")
        try check(DraftInput.suggestion(in: prefix + " @文件")?.text, "文件", "Mention at the end of a long draft")
        try check(DraftInput.suggestion(in: "mail@file"), nil, "An email is not a mention")
        try check(DraftInput.suggestion(in: " /技能 ")?.source, .skills, "Slash command")
        let large = String(repeating: "👋🏽", count: 2501)
        try check(DraftInput.longInsertion(from: "首尾", to: "首" + large + "尾"), large, "A large Unicode paste inside a draft")
        try check(DraftInput.longInsertion(from: "首尾", to: "首👋🏽尾"), nil, "An ordinary edit is not a paste")
    }

    @MainActor
    static func followingTheReader() async throws {
        let flow = FlowFixture()
        flow.changePhase(from: .idle, to: .interacting, at: 0)
        try check(flow.following, false, "Dragging pauses following even at the bottom")
        try check(flow.chat.browsing, true, "Holding off row refresh during the drag")
        flow.changePhase(from: .interacting, to: .idle, at: 80)
        try check(flow.following, false, "At the threshold, keep the reader's position")
        flow.changePhase(from: .animating, to: .idle, at: 0)
        try check(flow.following, false, "A programmatic scroll cannot turn following back on")
        try check(flow.requestFollow() == nil, true, "Arriving text does not restart following")
        flow.changePhase(from: .idle, to: .interacting, at: 80)
        flow.changePhase(from: .interacting, to: .decelerating, at: 79)
        try check(flow.following, false, "Wait for the user's fling to stop")
        flow.changePhase(from: .decelerating, to: .idle, at: 79)
        try check(flow.following, true, "Resume within 80 points including the composer inset")
        flow.changePhase(from: .animating, to: .idle, at: 150)
        try check(flow.following, true, "A programmatic scroll cannot turn following off")
        try check(flow.chat.browsing, false, "Resume row refresh when scrolling stops")
        flow.selecting.insert(UUID())
        try check(flow.requestFollow() == nil, true, "A selection prevents auto-follow")
        flow.selecting = []

        let scheduled = flow.requestFollow()
        await flow.clock.waitForSleepers(1)
        flow.changePhase(from: .idle, to: .interacting, at: 300)
        try flow.clock.advance(32_000_000)
        await scheduled?.value
        try check(flow.scrolls, [], "A drag stops the scheduled follow")
    }

    @MainActor
    static func latestFollowWins() async throws {
        let flow = FlowFixture()
        let first = flow.requestFollow()
        await flow.clock.waitForSleepers(1)
        let latest = flow.requestFollow(settle: false)
        await flow.clock.waitForSleepers(2)

        try check(first?.isCancelled, true, "A new follow cancels the pending request")
        try flow.clock.advance(32_000_000)
        await first?.value
        try check(flow.scrolls, [], "A cancelled request cannot scroll")
        try flow.clock.advance(16_000_000)
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
        try check(flow.draftAttachmentQueuedIds, [], "Sending clears queued attachment markers")
        try check(flow.following, true, "Sending resumes following")
        await flow.clock.waitForSleepers(1)

        // A new line sends another follow request as observed by ChatPage.
        let message = flow.requestFollow()
        await flow.clock.waitForSleepers(2)
        try flow.clock.advance(32_000_000)
        await send?.value
        try check(flow.scrolls, [], "Clearing the composer does not add a separate scroll")
        try flow.clock.advance(32_000_000)
        await message?.value
        try check(flow.scrolls, [false], "Send and line insertion share one scroll")
    }
}
