import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// Only the platform inputs and side effects are simulated. The runner fills in
// the app's function bodies so the assertions cannot pass against a copy of the rules.
// RULE: STREAM_BLOCKS
// RULE: DRAFT_INPUT
// RULE: TURN_EVENT
// RULE: INLINE_APPROVAL

private enum ScrollPhase { case idle, interacting, decelerating, animating }

private struct ScrollGeometry {
    let contentSize: CGSize
    let containerSize: CGSize
    let contentInsets: Insets
    let contentOffset: CGPoint

    struct Insets { let top: CGFloat; let bottom: CGFloat }
}

private enum Words {
    static func t(_ text: String) -> String { text }
}

private enum Grant {
    case web, desk, device, den, hills, mcp
// RULE: SMART_QUERY
}

private struct Approval: Equatable {}
private enum UnitPoint: Equatable { case bottom }

private struct Hitches {
    static let shared = Self()
    func doing(_ text: String?, as key: String) {}
}

private final class UIEvent {}

private class UIView {
    weak var window: UIWindow?
    weak var parent: UIView?

    func isDescendant(of ancestor: UIView) -> Bool {
        self === ancestor || parent?.isDescendant(of: ancestor) == true
    }
}

private final class UIViewController {
    var presentedViewController: UIViewController?
    let view = UIView()
    var viewIfLoaded: UIView? { view }
}

private class UIWindow: UIView {
    var rootViewController: UIViewController?
    var subviews: [UIView] = []
    var hit: UIView?
    func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { hit }
}

private final class PetPerch {
    var suppressed = false
    var chatOffset: CGFloat = 0
    var replyActions = CGRect.null
    var bodyHit = CGRect(x: 30, y: 720, width: 48, height: 48)
    var bubbleHit = CGRect(x: 100, y: 675, width: 120, height: 25)
}

private enum PetSurfaceFixture {
// RULE: PET_SURFACE

    static func checkPassThrough() throws {
        let window = Surface()
        let pet = PetPerch()
        let host = UIViewController()
        let wrapper = UIView()
        window.perch = pet
        window.rootViewController = host
        window.subviews = [host.view, wrapper]
        window.hit = wrapper

        let chatContent = CGPoint(x: 175, y: 400)
        let composer = CGPoint(x: 175, y: 805)
        try check(window.hasContextMenu, false, "A sibling wrapper is not a presented menu")
        try check(window.hitTest(chatContent, with: nil) == nil, true, "Scrolling passes through the pet window")
        try check(window.hitTest(composer, with: nil) == nil, true, "Taps on the composer pass through")

        let petPoint = CGPoint(x: 40, y: 740)
        let bubblePoint = CGPoint(x: 110, y: 680)
        window.hit = host.view
        try check(window.hitTest(petPoint, with: nil) === host.view, true, "The pet can still be tapped or dragged")
        try check(window.hitTest(bubblePoint, with: nil) === host.view, true, "The pet bubble remains interactive")
        pet.replyActions = pet.bodyHit
        try check(window.hitTest(petPoint, with: nil) == nil, true, "Reply actions take priority over the pet")

        let menu = UIViewController()
        let item = UIView()
        item.parent = menu.view
        menu.view.window = window
        host.presentedViewController = menu
        window.hit = item
        try check(window.hasContextMenu, true, "The menu is presented in the pet window")
        try check(window.hitTest(chatContent, with: nil) === item, true, "A presented menu item can still be tapped")
        window.hit = wrapper
        try check(window.hitTest(composer, with: nil) == nil, true, "Even an open menu cannot capture the rest of chat")
    }
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
    var approving: Approval?
    var typing = false
    var approvalInsetTask: Task<Void, Never>?
    let viewport = Viewport()

    final class Viewport {
        var needsEndCorrection = true
    }

    func lingerJumpButtons() {}
    func invalidatePhotoSelection() {}
    private(set) var scrolls: [Bool] = []
    private(set) var followPending: Task<Void, Never>?
    private var settleEnd: Task<Void, Never>?
    let clock = Clock()
    private var alignment: CGFloat = 0

    static func geometry(content: CGFloat = 800, offset: CGFloat) -> ScrollGeometry {
        ScrollGeometry(contentSize: .init(width: 0, height: content),
                       containerSize: .init(width: 0, height: 500),
                       contentInsets: .init(top: 20, bottom: 100),
                       contentOffset: .init(x: 0, y: offset))
    }

    func measure(content: CGFloat = 800, offset: CGFloat) -> Task<Void, Never>? {
        let next = Self.endAlignment(Self.geometry(content: content, offset: offset))
        if next != alignment {
            alignment = next
            endAlignmentChanged(next)
        }
        return followPending
    }

    func changePhase(from old: ScrollPhase, to phase: ScrollPhase, at distance: CGFloat) {
        let geometry = Self.geometry(offset: 400 - distance)
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

    func showApproval() { presentApproval(Approval()) }

    private func toEnd(animated: Bool = false) {
        scrolls.append(animated)
    }

// RULE: BELOW
// RULE: RESIZE_ANCHOR
// RULE: END_ALIGNMENT
// RULE: END_ALIGNMENT_CHANGED
// RULE: SELECTION_CHANGED
// RULE: PRESENT_APPROVAL
// RULE: APPROVAL_INSET
// RULE: FOLLOW
// RULE: CLEAR_COMPOSER
}

private struct ChatLine {
    enum Kind { case bot, note }
    let id: String
    let kind: Kind
    let text: String
}

private enum Haptics {
    static func tick(_ strength: Double) {}
}

private final class ReplyFixture {
    struct Fresh {
        let id: String
        var shown: Int?
    }

    var target = "abcdef"
    var streaming = "abc"
    var pulse = ""
    var thinking = ""
    var finalCount = 0
    var shown = 4
    var publishedShown = 3
    var fresh: Fresh?
    var heldRows: [ChatLine]?
    var lines: [ChatLine] = []

    func update(_ next: [ChatLine], event: TurnEvent) { updateKeptRows(next, event: event) }
    func advance() -> Bool { step() }
    func apply(_ next: [ChatLine]) { lines = next }
    func type() {}
    func due() -> Bool { true }
    func clearThinking() { thinking = "" }
    func useBackupModel() {
// RULE: STREAM_RESET
    }
    func add(_ piece: String) {
// RULE: ADD_TEXT
    }
// RULE: KEPT_ROWS
// RULE: RESET_REPLY
// RULE: TYPING_STEP
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
            try await skipFollowOnceAligned()
            try await growingReplyKeepsFollowing()
            try await releasingSelectionResumesFollowing()
            try replyHandoff()
            try replyBoundaries()
            try PetSurfaceFixture.checkPassThrough()
            try await approvalPausesFollowing()
            try await inlineApprovalWaitsForLayout()
            try smartApprovalQueries()
            try passiveReadingHasNoResizeAnchor()
            try inlineApprovalRouting()
            print("Chat flow checks passed (see known gaps, if any).")
        } catch {
            FileHandle.standardError.write(Data("Chat flow check failed: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    static func inlineApprovalRouting() throws {
        try check(InlineApprovalPolicy.canAnswer(answerable: true, forced: false, tool: "shell", hasCode: true),
                  true, "Ordinary approval is available in chat")
        for tool in ["shell", "ssh_run", "ssh_job_start", "run_js"] {
            try check(InlineApprovalPolicy.canAnswer(answerable: true, forced: true, tool: tool, hasCode: false),
                      false, "An inline command approval must show the complete payload")
            try check(InlineApprovalPolicy.canAnswer(answerable: true, forced: true, tool: tool, hasCode: true),
                      true, "A forced command with the full payload can ask inline")
        }
        try check(InlineApprovalPolicy.canAnswer(answerable: false, forced: true, tool: "shell", hasCode: true),
                  false, "An old approval stays read-only")
    }

    @MainActor
    static func approvalPausesFollowing() async throws {
        let flow = FlowFixture()
        flow.typing = true
        let before = flow.requestFollow()
        await flow.clock.waitForSleepers(1)
        flow.showApproval()
        try check(flow.typing, false, "Opening the approval removes keyboard focus")
        try check(before?.isCancelled, true, "Opening the approval cancels an outdated jump")
        try flow.clock.advance(32_000_000)
        await before?.value
        try check(flow.requestFollow()?.isCancelled, true, "Open approval prevents a new automatic jump")
        try check(flow.scrolls, [], "No automatic scroll under the approval")

        flow.approving = nil
        let afterward = flow.requestFollow()
        await flow.clock.waitForSleepers(1)
        try flow.clock.advance(32_000_000)
        await afterward?.value
        try check(flow.scrolls, [false], "Dismissal recovers a reader who was following")

        flow.following = false
        flow.showApproval()
        flow.approving = nil
        try check(flow.requestFollow() == nil, true, "Reading history is preserved after approval")
    }

    static func smartApprovalQueries() throws {
        try check(Grant.allowsSmartQuery("read_file", grant: .desk), true, "Read local workspace")
        try check(Grant.allowsSmartQuery("read_pdf", grant: .desk), true, "Read a workspace PDF")
        try check(Grant.allowsSmartQuery("search_docs", grant: .desk), true, "Search workspace documents")
        try check(Grant.allowsSmartQuery("read_file", grant: .hills), false, "The same tool on a remote host still asks")
        try check(Grant.allowsSmartQuery("shell", grant: .den), false, "Commands still ask")
        try check(Grant.allowsSmartQuery("edit_file", grant: .desk), false, "Writes still ask")
        try check(Grant.allowsSmartQuery("mcp_read", grant: .mcp), false, "An external tool cannot self-authorize")
    }

    @MainActor
    static func passiveReadingHasNoResizeAnchor() throws {
        try check(FlowFixture.resizeAnchor(following: true, inHistory: false, hasSelection: false), .bottom,
                  "Readers following the latest reply stay anchored at the bottom")
        try check(FlowFixture.resizeAnchor(following: false, inHistory: false, hasSelection: false), nil,
                  "Layout changes while reading do not move the viewport to an edge")
        try check(FlowFixture.resizeAnchor(following: true, inHistory: true, hasSelection: false), nil,
                  "Looking at history does not anchor the viewport")
        try check(FlowFixture.resizeAnchor(following: true, inHistory: false, hasSelection: true), nil,
                  "Selecting text does not anchor the viewport")
    }

    @MainActor
    static func inlineApprovalWaitsForLayout() async throws {
        let flow = FlowFixture()
        flow.approvalInsetChanged()
        let resize = flow.approvalInsetTask
        await flow.clock.waitForSleepers(1)
        try check(flow.measure(offset: 350) == nil, true, "The changing inset cannot trigger early scrolling")
        try flow.clock.advance(400_000_000)
        await resize?.value
        let follow = flow.followPending
        try check(follow != nil, true, "Settling schedules a new geometry check")
        await flow.clock.waitForSleepers(1)
        try flow.clock.advance(16_000_000)
        await follow?.value
        try check(flow.scrolls, [false], "Follow only after the approval inset settles")
    }

    @MainActor
    static func skipFollowOnceAligned() async throws {
        let flow = FlowFixture()
        let request = flow.requestFollow()
        await flow.clock.waitForSleepers(1)
        flow.viewport.needsEndCorrection = false
        try flow.clock.advance(32_000_000)
        await request?.value
        try check(flow.scrolls, [], "The system anchor settled the scroll before the delayed request")
    }

    static func replyHandoff() throws {
        let flow = ReplyFixture()
        let note = ChatLine(id: "note", kind: .note, text: "Status")
        let scheduled = ChatLine(id: "scheduled", kind: .bot, text: "Scheduled delivery")
        let reply = ChatLine(id: "reply", kind: .bot, text: "abcde")
        flow.update([note, scheduled], event: .changed)
        try check(flow.lines.map(\.id), ["note", "scheduled"], "Independent history changes still appear")
        try check(flow.streaming, "abc", "A note and scheduled delivery leave the live reply in place")
        flow.update([note, scheduled], event: .replyCommitted(reply.id))
        try check(flow.streaming, "abc", "A missing saved row cannot replace the visible stream")
        flow.update([note, reply, scheduled], event: .replyCommitted(reply.id))
        try check(flow.fresh?.id, reply.id, "Only the committed row replaces the stream")
        try check(flow.fresh?.shown, 3, "The saved row starts at the last visible character")
        try check(flow.streaming, "", "The live row retires when its replacement is present")
        try check(flow.advance(), true, "The rest of the kept reply can still animate")
        try check(flow.fresh?.shown, 4, "The reply shows the next character")
        try check(flow.advance(), false, "The completed reply stops animating on the final character")
        try check(flow.fresh?.shown, nil, "The final character and settled row appear together")

        let fast = ReplyFixture()
        fast.publishedShown = 0
        fast.streaming = ""
        fast.update([reply], event: .replyCommitted(reply.id))
        try check(fast.fresh?.shown, nil, "An instant reply can display in full without an empty frame")
    }

    @MainActor
    static func growingReplyKeepsFollowing() async throws {
        let flow = FlowFixture()
        try check(FlowFixture.endAlignment(FlowFixture.geometry(content: 120, offset: -20)), 0,
                  "A short conversation rests against its top inset")
        try check(FlowFixture.endAlignment(FlowFixture.geometry(offset: 450)), -4,
                  "An offset past the end after content shrinks is still detected")
        flow.changePhase(from: .idle, to: .interacting, at: 40)
        try check(flow.measure(offset: 360) == nil, true, "Movement under the finger never schedules a correction")
        flow.changePhase(from: .interacting, to: .idle, at: 40)
        let resumed = flow.measure(offset: 360)
        try check(resumed != nil, true, "Releasing within 80 points schedules correction with no fresh geometry event")
        await flow.clock.waitForSleepers(1)
        let coalesced = flow.measure(offset: 340)
        try check(coalesced != nil && resumed?.isCancelled == false, true, "Further drift keeps the correction already scheduled")
        try flow.clock.advance(16_000_000)
        await resumed?.value

        let further = flow.measure(offset: 310)
        try check(further != nil, true, "Continued drift schedules again without ever passing through aligned")
        await flow.clock.waitForSleepers(1)
        try flow.clock.advance(16_000_000)
        await further?.value
        try check(flow.scrolls, [false, false], "Both drift corrections ran")
    }

    @MainActor
    static func releasingSelectionResumesFollowing() async throws {
        let flow = FlowFixture()
        let selection = UUID()
        flow.selectionChanged(selection, true)
        try check(flow.measure(offset: 350) == nil, true, "Geometry changes while selecting do not follow")
        flow.selectionChanged(selection, false)
        let resumed = flow.measure(offset: 350)
        try check(resumed != nil, true, "Ending selection corrects existing drift")
        await flow.clock.waitForSleepers(1)
        try flow.clock.advance(16_000_000)
        await resumed?.value
        try check(flow.scrolls, [false], "Ending selection restarts following")
    }

    static func replyBoundaries() throws {
        let flow = ReplyFixture()
        flow.pulse = "old pulse"
        flow.thinking = "old thought"
        flow.useBackupModel()
        try check(flow.streaming, "", "Switching models clears the previous visible stream")
        try check(flow.pulse, "", "Switching models clears the previous pulse")
        try check(flow.thinking, "", "Switching models clears the previous thought")
        flow.add("new reply")
        try check(flow.target, "new reply", "The backup model starts its own buffer")

        flow.target = "\n \n"
        flow.streaming = "\n \n"
        flow.update([], event: .changed)
        try check(flow.target, "\n \n", "An unrelated change does not discard whitespace in an active reply")
        flow.update([], event: .replyCommitted("tool"))
        try check(flow.target, "", "A whitespace-only tool preamble is retired when committed")
        try check(flow.streaming, "", "The tool preamble no longer covers later thinking")
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
        await flow.clock.waitForSleepers(1)
        let resumed = flow.measure(offset: 321)
        try flow.clock.advance(16_000_000)
        await resumed?.value
        try check(flow.scrolls, [false], "Resuming near the end corrects the resting position")
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
        try check(flow.scrolls, [false], "A drag stops the scheduled follow")
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
