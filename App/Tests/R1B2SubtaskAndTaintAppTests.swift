import AgentKit
@testable import Clio
import Craft
import Foundation
import XCTest

@MainActor
final class R1B2SubtaskAndTaintAppTests: XCTestCase {
    // MARK: - CLIO-002 & CLIO-003: Subtask inherits parent disabled grants, no-memory gate, and drops remember/forget

    func testSubtaskToolsInheritParentDisablesAndOmitRememberForget() {
        let team = TeamModel()
        let parentChat = "bot-parent-\(UUID().uuidString)"
        let executionKey = "attempt-\(UUID().uuidString)"
        let helper = team.bots.first ?? BotInfo(id: "helper", name: "阿墨", role: "助手")

        // Disable web, shell (den), and memory on parent chat.
        var opts = team.options(parentChat)
        opts.off = [Grant.web.rawValue, Grant.den.rawValue, Grant.memory.rawValue]
        team.setOptions(parentChat, opts)

        let subtaskTools = team.tools(
            for: helper,
            key: executionKey,
            canSee: false,
            helping: true,
            displayChat: parentChat,
            workplace: .desk,
            experienceSource: .subtask
        )
        let toolNames = Set(subtaskTools.map(\.spec.name))

        // CLIO-002: parent chat disables must apply to subtask tools.
        XCTAssertFalse(toolNames.contains("web_search"), "Subtask must inherit parent's web disable")
        XCTAssertFalse(toolNames.contains("web_read"), "Subtask must inherit parent's web disable")
        XCTAssertFalse(toolNames.contains("recall"), "Subtask must inherit parent's memory disable")

        // CLIO-003: delegated/subtask helpers must NEVER receive global memory write tools (`remember`/`forget`).
        XCTAssertFalse(toolNames.contains("remember"), "Subtask must never expose remember tool")
        XCTAssertFalse(toolNames.contains("forget"), "Subtask must never expose forget tool")

        // Even when parent chat DOES enable memory, `helping == true` still omits `remember`/`forget` while keeping `recall`.
        opts.off = []
        team.setOptions(parentChat, opts)
        let enabledTools = Set(
            team.tools(
                for: helper,
                key: executionKey,
                canSee: false,
                helping: true,
                displayChat: parentChat,
                workplace: .desk,
                experienceSource: .subtask
            ).map(\.spec.name)
        )
        XCTAssertFalse(enabledTools.contains("remember"))
        XCTAssertFalse(enabledTools.contains("forget"))
        XCTAssertTrue(enabledTools.contains("recall"))
    }

    func testHelperPromptRefresherRespectsParentChatNoMemoryFlag() {
        let team = TeamModel()
        let parentChat = "bot-nomem-\(UUID().uuidString)"
        let helper = team.bots.first ?? BotInfo(id: "helper", name: "阿墨", role: "助手")

        team.memories = [
            Memory(id: "m-secret-1", text: "用户绝密暗号是青花瓷九号", at: Now.ms, by: nil, deep: nil, used: Now.ms)
        ]

        // Turn memory OFF on parent chat.
        var opts = team.options(parentChat)
        opts.off = [Grant.memory.rawValue]
        team.setOptions(parentChat, opts)
        let parentUsesMemory = !team.options(parentChat).off.contains(Grant.memory.rawValue) && Grant.memory.policy != .off
        XCTAssertFalse(parentUsesMemory)

        let (refresher, token) = team.registerLivePromptRefresher(
            for: helper,
            in: parentChat,
            room: nil,
            workplace: .desk,
            memory: parentUsesMemory
        )
        defer { team.unregisterLivePromptRefresher(token) }

        let prompt = refresher.currentPrompt().full
        XCTAssertFalse(prompt.contains("青花瓷九号"), "Helper prompt must omit long-term memories when parent chat disables memory")
    }

    // MARK: - CLIO-010 tail: Cold-start taint restoration from persisted history & summary

    func testColdStartTaintRestorationMarksTaintBookFromPersistedHistoryAndSummary() {
        let team = TeamModel()
        let chatKey = "bot-cold-taint-\(UUID().uuidString)"

        // 1. Persisted history contains a `tool_invoke` entry while in-memory TaintBook is empty (simulating cold launch).
        team.append(Entry(id: "u1", at: 1, message: .user("看看外部工具")), to: chatKey)
        team.append(Entry(id: "t1", at: 2, message: .toolResult("外网文本", for: ToolCall(id: "c1", name: "tool_invoke", arguments: "{}"))), to: chatKey)
        team.taint.clear(chatKey)
        team.resetTurnMemoryTaint(chatKey)

        XCTAssertFalse(team.taint.isTainted(chatKey))
        XCTAssertTrue(team.restoreTaintFromPersistedHistoryIfNeeded(for: chatKey))
        XCTAssertTrue(team.taint.isTainted(chatKey), "Cold start must restore TaintBook from persisted tool_invoke/web_read history")
        XCTAssertTrue(team.isTurnMemoryTainted(chatKey))

        // 2. Persisted explicitly tainted entry also restores TaintBook.
        let chatKey2 = "bot-cold-flag-\(UUID().uuidString)"
        var taintedEntry = Entry(id: "a1", at: 3, message: .assistant("网页总结"))
        taintedEntry.tainted = true
        team.append(taintedEntry, to: chatKey2)
        team.taint.clear(chatKey2)
        team.resetTurnMemoryTaint(chatKey2)

        XCTAssertTrue(team.restoreTaintFromPersistedHistoryIfNeeded(for: chatKey2))
        XCTAssertTrue(team.taint.isTainted(chatKey2))

        // 3. Clean history stays untainted.
        let cleanChat = "bot-cold-clean-\(UUID().uuidString)"
        team.append(Entry(id: "u-clean", at: 4, message: .user("你好")), to: cleanChat)
        team.append(Entry(id: "a-clean", at: 5, message: .assistant("你好！")), to: cleanChat)
        team.taint.clear(cleanChat)
        team.resetTurnMemoryTaint(cleanChat)

        XCTAssertFalse(team.restoreTaintFromPersistedHistoryIfNeeded(for: cleanChat))
        XCTAssertFalse(team.taint.isTainted(cleanChat))
    }

    // MARK: - Tool-own forced approval must never be auto-bypassed by web taint opt-in

    func testOwnForcedApprovalIsNeverBypassedByAllowThroughWeb() {
        let team = TeamModel()
        let chatKey = "bot-forced-own-\(UUID().uuidString)"
        team.taint.mark(chatKey)
        team.taint.allowThrough(chatKey)
        team.trust(chatKey, true)

        // Tool's own forced approval (`forced: true`, `forcedByTaintOnly: false`) with Taint.reason detail must still WAIT.
        let ownForced = Approval(
            id: "a-own",
            botId: "chief",
            roomId: nil,
            chat: chatKey,
            executionChat: nil,
            tool: "删除重要数据",
            toolName: "custom_destructive",
            reason: "不可撤销操作",
            detail: Approval.Detail(text: Taint.reason + "\n\n工具自身要求每次确认", code: nil),
            at: Now.ms,
            answerable: true,
            forced: true,
            forcedByTaintOnly: false
        )
        XCTAssertEqual(team.pendingDecision(for: ownForced), .wait)

        // Taint-only escalated non-hard-exit approval (`forced: true`, `forcedByTaintOnly: true`) respects opt-in allowThrough.
        let taintOnly = Approval(
            id: "a-taint",
            botId: "chief",
            roomId: nil,
            chat: chatKey,
            executionChat: nil,
            tool: "运行脚本",
            toolName: "run_js",
            reason: "执行脚本",
            detail: Approval.Detail(text: Taint.reason, code: "1+1"),
            at: Now.ms,
            answerable: true,
            forced: true,
            forcedByTaintOnly: true
        )
        XCTAssertEqual(team.pendingDecision(for: taintOnly), .allow)
    }
}
