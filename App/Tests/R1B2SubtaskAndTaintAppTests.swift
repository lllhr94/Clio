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
        let writer = TeamModel()
        let chatKey = "bot-cold-taint-\(UUID().uuidString)"
        let chatKey2 = "bot-cold-flag-\(UUID().uuidString)"
        let summaryOnlyChat = "bot-cold-summary-\(UUID().uuidString)"
        let cleanChat = "bot-cold-clean-\(UUID().uuidString)"
        defer {
            for k in [chatKey, chatKey2, summaryOnlyChat, cleanChat] {
                ChatDisk.removeAndWait(k)
                Disk.remove(TeamModel.summaryFile(k))
                Disk.remove(TeamModel.optionsFile(k))
            }
        }

        // 1. Persist history containing a `tool_invoke` entry, flush to disk, and test on a brand-new cold TeamModel.
        writer.append(Entry(id: "u1", at: 1, message: .user("看看外部工具")), to: chatKey)
        writer.append(Entry(id: "t1", at: 2, message: .toolResult("外网文本", for: ToolCall(id: "c1", name: "tool_invoke", arguments: "{}"))), to: chatKey)
        // 2. Persist explicitly tainted entry.
        var taintedEntry = Entry(id: "a1", at: 3, message: .assistant("网页总结"))
        taintedEntry.tainted = true
        writer.append(taintedEntry, to: chatKey2)
        // 3. Persist summary-only taint (zero live entries).
        writer.setSummary(summaryOnlyChat, "包含外网抓取内容的折叠摘要", tainted: true)
        // 4. Persist clean history.
        writer.append(Entry(id: "u-clean", at: 4, message: .user("你好")), to: cleanChat)
        writer.append(Entry(id: "a-clean", at: 5, message: .assistant("你好！")), to: cleanChat)
        ChatDisk.finishWrites()

        // Cold-start instance has empty in-memory entries, summaryBook, and TaintBook: must load from disk.
        let coldTeam = TeamModel()
        XCTAssertFalse(coldTeam.taint.isTainted(chatKey))
        XCTAssertTrue(coldTeam.restoreTaintFromPersistedHistoryIfNeeded(for: chatKey))
        XCTAssertTrue(coldTeam.taint.isTainted(chatKey), "Cold start must restore TaintBook from persisted tool_invoke history")
        XCTAssertTrue(coldTeam.isTurnMemoryTainted(chatKey))

        XCTAssertTrue(coldTeam.restoreTaintFromPersistedHistoryIfNeeded(for: chatKey2))
        XCTAssertTrue(coldTeam.taint.isTainted(chatKey2))

        XCTAssertTrue(coldTeam.restoreTaintFromPersistedHistoryIfNeeded(for: summaryOnlyChat))
        XCTAssertTrue(coldTeam.taint.isTainted(summaryOnlyChat))
        XCTAssertTrue(coldTeam.isTurnMemoryTainted(summaryOnlyChat))

        XCTAssertFalse(coldTeam.restoreTaintFromPersistedHistoryIfNeeded(for: cleanChat))
        XCTAssertFalse(coldTeam.taint.isTainted(cleanChat))
    }

    func testMidTurnParentGrantDisableAndShelveIsolationEnforceLiveBoundaries() async throws {
        let team = TeamModel()
        team.phase = .ready
        let parentChat = "bot-live-gate-\(UUID().uuidString)"
        let executionKey = "attempt-\(UUID().uuidString)"
        let helper = team.bots.first ?? BotInfo(id: "helper", name: "阿墨", role: "助手")
        defer {
            ChatDisk.removeAndWait(parentChat)
            for leaf in team.leaves(parentChat) {
                Disk.remove(TeamModel.leafFile(parentChat, leaf.id))
                Disk.remove(TeamModel.leafSummary(parentChat, leaf.id))
            }
            Disk.remove(TeamModel.leafList(parentChat))
            Disk.remove(TeamModel.summaryFile(parentChat))
            Disk.remove(TeamModel.optionsFile(parentChat))
        }
        team.memories = [
            Memory(id: "m-live-1", text: "秘密口令是翡翠七号", at: Now.ms, by: nil, deep: nil, used: Now.ms)
        ]

        // Assemble tools while parent chat allows memory, and bind expectedConversationID.
        let initialConvID = team.activeConversationID(for: parentChat)
        var opts = team.options(parentChat)
        opts.off = []
        team.setOptions(parentChat, opts)

        let assembled = team.tools(
            for: helper,
            key: executionKey,
            canSee: false,
            helping: true,
            displayChat: parentChat,
            workplace: .desk,
            experienceSource: .subtask,
            expectedConversationID: initialConvID,
            threadCreatedAtMs: Now.ms
        )
        let recallTool = try XCTUnwrap(assembled.first { $0.spec.name == "recall" })
        let historyTool = try XCTUnwrap(assembled.first { $0.spec.name == "search_history" })

        // Now turn memory OFF mid-turn on parent chat: both recallReadOnly and assembled LiveGatedTool must block live!
        opts.off = [Grant.memory.rawValue]
        team.setOptions(parentChat, opts)
        let readOnlyHits = await team.recallReadOnly("翡翠七号", chat: parentChat)
        XCTAssertTrue(readOnlyHits.isEmpty, "recallReadOnly must respect parent chat's live memory disable")
        let recallOut = try await recallTool.run(.object(["query": .string("翡翠七号")]))
        XCTAssertTrue(recallOut.isError, "Assembled recall tool must refuse immediately when parent chat disables memory mid-turn")

        // Re-enable memory, shelve the conversation via turnLeaf (rotating conversationID), and verify old subtask cannot search new slot!
        opts.off = []
        team.setOptions(parentChat, opts)
        team.append(Entry(id: "old-1", at: 1, message: .user("旧对话内容")), to: parentChat)
        ChatDisk.finishWrites()
        XCTAssertTrue(team.turnLeaf(parentChat))
        team.setSummary(parentChat, "新对话绝密摘要", tainted: false)

        let historyOut = try await historyTool.run(.object(["query": .string("新对话")]))
        XCTAssertTrue(historyOut.text.contains("原对话已收起"), "Shelved subtask must refuse searching the new conversation slot")

        let (noSummaryRefresher, token) = team.registerLivePromptRefresher(
            for: helper,
            in: parentChat,
            room: nil,
            workplace: .desk,
            memory: false,
            includeSummary: false
        )
        defer { team.unregisterLivePromptRefresher(token) }
        XCTAssertFalse(noSummaryRefresher.currentPrompt().full.contains("新对话绝密摘要"))
    }

    func testWorkspaceImagesReplyAbortsBeforeDiskWriteWhenPlanModeTriggers() async {
        // Minimal 1x1 PNG bytes embedded; `beforeWrite` throws policy block before touching disk.
        let onePixelPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        do {
            _ = try await WorkspaceImages.reply([.embedded(ImagePart(mediaType: "image/png", data: onePixelPNG))]) {
                throw WorkspaceImages.Failure.blockedByPolicy("规划模式阻止写盘")
            }
            XCTFail("Expected WorkspaceImages.reply to propagate blockedByPolicy without writing")
        } catch let error as WorkspaceImages.Failure {
            if case .blockedByPolicy(let reason) = error {
                XCTAssertEqual(reason, "规划模式阻止写盘")
            } else {
                XCTFail("Unexpected WorkspaceImages.Failure: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
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
