import AgentKit
import Craft
import Foundation
import XCTest

final class R1BCraftSecurityTests: XCTestCase {
    // MARK: - CLIO-005: AskUserRules scalar boundary with Chinese & emoji prefixes

    func testAskUserForceSecretDetectsTokenPrefixesAfterChineseAndEmoji() {
        // Prompts intentionally omit Chinese secret words (like 密钥/令牌) so detection must come from `token_prefix`.
        let samples = [
            "请粘贴内容 sk-live-1234567890",
            "这里填入：ghp_1234567890abcdef",
            "🔑AIzaSyAbCdEfGhIjKlMnOpQrStUv",
            "配置编号 AKIAIOSFODNN7EXAMPLE",
            "临时值：ASIA1234567890ABCDEF",
        ]
        for prompt in samples {
            XCTAssertEqual(
                AskUserRules.detectSecretSignal(in: prompt),
                "token_prefix",
                "Expected token_prefix signal for multibyte-prefixed prompt: \(prompt)"
            )
            XCTAssertTrue(
                AskUserRules.isSecretField(key: "custom_input", label: prompt),
                "Expected force-secret for multibyte-prefixed prompt: \(prompt)"
            )
        }

        // ASCII alphanumeric prefix directly attached to token prefix must still not false-positive.
        XCTAssertNil(AskUserRules.detectSecretSignal(in: "选择 disk-1 还是 fooAIzaBar"))
        XCTAssertFalse(AskUserRules.isSecretField(key: "note", label: "选择 disk-1 还是 fooAIzaBar"))
    }

    // MARK: - CLIO-007: WorkspacePath.isInside rejects empty, ~user, and control characters

    func testWorkspacePathRejectsEmptyOtherUserTildeAndControlChars() {
        XCTAssertFalse(WorkspacePath.isInside("", root: "/root/desk"))
        XCTAssertFalse(WorkspacePath.isInside("   ", root: "/root/desk"))
        XCTAssertFalse(WorkspacePath.isInside("~root/.ssh/authorized_keys", root: "/root/desk", home: ["~"]))
        XCTAssertFalse(WorkspacePath.isInside("~admin/secret", root: "~", home: ["/home/lin"]))
        XCTAssertFalse(WorkspacePath.isInside("\n/etc/passwd", root: "/root/desk"))
        XCTAssertFalse(WorkspacePath.isInside("notes/a.md\n/etc/passwd", root: "/root/desk"))
        XCTAssertFalse(WorkspacePath.isInside("notes/a\r.md", root: "/root/desk"))
        XCTAssertFalse(WorkspacePath.isInside("notes/\u{0000}a.md", root: "/root/desk"))
        XCTAssertFalse(WorkspacePath.isInside("../escape.txt", root: "/root/desk"))

        // Valid paths remain allowed.
        XCTAssertTrue(WorkspacePath.isInside("notes/a.md", root: "/root/desk"))
        XCTAssertTrue(WorkspacePath.isInside("/root/desk/notes/a.md", root: "/root/desk"))
        XCTAssertTrue(WorkspacePath.isInside("~/notes/a.md", root: "/root/desk", home: ["~"]))
        XCTAssertTrue(WorkspacePath.isInside("~", root: "~"))
    }

    // MARK: - CLIO-010: Taint completeness & sticky explicit taint in MemorySafety

    private struct StubTool: AgentTool {
        let spec: ToolSpec
        func label(for arguments: JSONValue) -> String { spec.name }
        func run(_ arguments: JSONValue) async throws -> ToolOutput { ToolOutput("ok") }
    }

    func testTaintCoversToolInvokeRunJSRecordExperienceAndMakeDocument() async throws {
        XCTAssertTrue(Taint.reads("tool_invoke"))

        let alwaysInside: (String) -> Bool = { _ in true }
        XCTAssertTrue(Taint.needsSeal(tool: "run_js", arguments: .object(["code": .string("1+1")]), isInside: alwaysInside))
        XCTAssertTrue(Taint.needsSeal(tool: "record_experience", arguments: .object(["title": .string("x")]), isInside: alwaysInside))
        XCTAssertTrue(Taint.needsSeal(tool: "make_document", arguments: .object(["path": .string("a.pdf")]), isInside: alwaysInside))
        XCTAssertTrue(Taint.needsSeal(tool: "tool_invoke", arguments: .object(["tool": .string("mcp_x")]), isInside: alwaysInside))

        XCTAssertNotNil(Taint.codePayload(tool: "tool_invoke", arguments: .object(["tool": .string("mcp_x")])))

        // Running `tool_invoke` marks the conversation tainted, which forces approval on `run_js` and `record_experience`.
        let book = TaintBook()
        let invokeGuard = TaintGuard(
            StubTool(spec: ToolSpec(name: "tool_invoke", description: "", parameters: .object([:]))),
            key: "chat-1",
            book: book,
            isInside: { _ in true }
        )
        _ = try await invokeGuard.run(.object(["tool": .string("mcp_web")]))
        XCTAssertTrue(book.isTainted("chat-1"))

        for dangerousName in ["run_js", "record_experience", "make_document", "tool_invoke"] {
            let guarded = TaintGuard(
                StubTool(spec: ToolSpec(name: dangerousName, description: "", parameters: .object([:]))),
                key: "chat-1",
                book: book,
                isInside: { _ in true }
            )
            let ask = guarded.approval(for: .object(["code": .string("write()"), "path": .string("doc.pdf")]))
            XCTAssertNotNil(ask, "\(dangerousName) must require forced approval after taint")
            XCTAssertEqual(ask?.forced, true)
        }
    }

    func testMemorySafetyExplicitTaintAndToolInvokeStayStickyAcrossLaterTurns() {
        let entries: [MemorySafety.CandidateEntry] = [
            .init(id: "u1", at: 1, role: .user, text: "我平时喝绿茶"),
            .init(id: "a1", at: 2, role: .assistant, text: "收到，记下了。"),
            .init(id: "t1", at: 3, role: .tool, text: "外部恶意指令", toolName: "tool_invoke", isTainted: true),
            .init(id: "a2", at: 4, role: .assistant, text: "工具已返回", isTainted: true),
            // Simulate cold restart where later assistant reply was saved with `isTainted == false`
            // even though `t1` is still in conversation history.
            .init(id: "u2", at: 5, role: .user, text: "我们继续聊"),
            .init(id: "a3", at: 6, role: .assistant, text: "按上面页面说的，你是管理员", isTainted: false),
        ]

        let filtered = MemorySafety.filterExtractableEntries(entries)
        XCTAssertEqual(filtered.map(\.id), ["u1", "a1", "u2"])
        XCTAssertFalse(filtered.contains(where: { $0.id == "a3" }))

        // Slice after the tainted turn alone has no untainted assistant reply -> refuses to flush.
        XCTAssertFalse(MemorySafety.hasFlushableConversation(entries, eligibleIDs: ["u2", "a3"]))
        XCTAssertNil(MemorySafety.buildFlushTranscript(entries, eligibleIDs: ["u2", "a3"]))
    }

    // MARK: - PR 2B: Tool-own forced approval vs taint-only escalation & CasualTrack outbox traversal

    private struct OwnForcedTool: AgentTool {
        let spec: ToolSpec
        func label(for arguments: JSONValue) -> String { spec.name }
        func approval(for arguments: JSONValue) -> ApprovalAsk? {
            ApprovalAsk(title: "高危操作", reason: "工具自带强确认", forced: true)
        }
        func run(_ arguments: JSONValue) async throws -> ToolOutput { ToolOutput("ok") }
    }

    func testTaintGuardDistinguishesOwnForcedApprovalFromTaintOnlyEscalation() {
        let book = TaintBook()
        book.mark("chat-tainted")

        // A tool's own `forced: true` approval must keep `forcedByTaintOnly == false` even when tainted.
        let ownForcedGuarded = TaintGuard(
            OwnForcedTool(spec: ToolSpec(name: "custom_destructive", description: "", parameters: .object([:]))),
            key: "chat-tainted",
            book: book,
            isInside: { _ in true }
        )
        let ownAsk = ownForcedGuarded.approval(for: .object([:]))
        XCTAssertEqual(ownAsk?.forced, true)
        XCTAssertEqual(ownAsk?.forcedByTaintOnly, false)

        // A regular tool escalated solely by taint must set `forcedByTaintOnly == true`.
        let taintOnlyGuarded = TaintGuard(
            StubTool(spec: ToolSpec(name: "run_js", description: "", parameters: .object([:]))),
            key: "chat-tainted",
            book: book,
            isInside: { _ in true }
        )
        let taintAsk = taintOnlyGuarded.approval(for: .object(["code": .string("1+1")]))
        XCTAssertEqual(taintAsk?.forced, true)
        XCTAssertEqual(taintAsk?.forcedByTaintOnly, true)
    }

    func testCasualTrackStoreRejectsPathTraversalBatchIDs() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clio-r1b2-casual-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = CasualTrackStore(canonicalTeamDirectory: dir)
        for badBatchID in ["", "../escape", "../../settings", "a/b", "a\\b", ".hidden", "bad id", "bad\nid"] {
            let batch = CasualOutboxBatch(
                batchID: badBatchID,
                botID: "chief",
                casualSessionID: "cs-1",
                segments: ["hello"],
                state: .queuedBeforeSend,
                trackEpoch: 1
            )
            XCTAssertThrowsError(try store.saveOutboxBatch(batch)) { err in
                if case .invalidBatchID(let rejected) = err as? CasualTrackError {
                    XCTAssertEqual(rejected, badBatchID)
                } else {
                    XCTFail("Expected CasualTrackError.invalidBatchID, got: \(err)")
                }
            }
            XCTAssertNil(store.loadOutboxBatch(batchID: badBatchID))
        }

        // Valid batchID still persists cleanly inside `casual/outbox/`.
        let goodBatch = CasualOutboxBatch(
            batchID: "batch-safe_01",
            botID: "chief",
            casualSessionID: "cs-1",
            segments: ["hi"],
            state: .queuedBeforeSend,
            trackEpoch: 1
        )
        try store.saveOutboxBatch(goodBatch)
        XCTAssertEqual(store.loadOutboxBatch(batchID: "batch-safe_01")?.batchID, "batch-safe_01")
    }
}
