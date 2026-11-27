import AgentKit
import Craft
import Foundation
import XCTest

private struct PlanMockTool: AgentTool {
    let name: String
    let requiresApproval: Bool
    let onRun: @Sendable (JSONValue) -> Void

    init(_ name: String, requiresApproval: Bool = false, onRun: @escaping @Sendable (JSONValue) -> Void = { _ in }) {
        self.name = name
        self.requiresApproval = requiresApproval
        self.onRun = onRun
    }

    var spec: ToolSpec {
        ToolSpec(name: name, description: "mock \(name)", parameters: .object(["type": .string("object")]))
    }

    func label(for arguments: JSONValue) -> String { name }

    func approval(for arguments: JSONValue) -> ApprovalAsk? {
        requiresApproval ? ApprovalAsk(title: "Approve \(name)", reason: "mock", forced: false) : nil
    }

    func run(_ arguments: JSONValue) async throws -> ToolOutput {
        onRun(arguments)
        return ToolOutput("ok:\(name)")
    }
}

private final class AtomicIntBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
    func increment() {
        lock.lock(); storage += 1; lock.unlock()
    }
}

final class PlanModeGateTests: XCTestCase {
    func testPolicyAllowsReadOnlyDeskToolsAndBlocksMutationsAndNonDeskHosts() {
        // Desk read-only tools allowed.
        for name in ["read_file", "list_dir", "glob", "grep"] {
            XCTAssertTrue(
                PlanModeReadOnlyPolicy.evaluate(toolName: name, hostKind: "desk", arguments: .object([:])).isAllowed,
                "\(name) should be allowed on desk"
            )
            XCTAssertFalse(
                PlanModeReadOnlyPolicy.evaluate(toolName: name, hostKind: "den", arguments: .object([:])).isAllowed,
                "\(name) must be blocked on den"
            )
            XCTAssertFalse(
                PlanModeReadOnlyPolicy.evaluate(toolName: name, hostKind: "hill:prod", arguments: .object([:])).isAllowed,
                "\(name) must be blocked on hills"
            )
        }

        // Read-only info & planning tools allowed.
        for name in [
            "photo_text", "read_pdf", "search_docs",
            "web_search", "web_read", "weather",
            "recall", "search_history", "recall_experience",
            "calendar_events", "reminders", "device_status", "current_status",
            "use_skill", "update_plan", "ask_companion",
        ] {
            XCTAssertTrue(
                PlanModeReadOnlyPolicy.evaluate(toolName: name, hostKind: "desk", arguments: .object([:])).isAllowed,
                "\(name) should be allowed in Plan mode"
            )
        }

        // `view_image`: desk path & local `ref` allowed; non-desk `path` blocked.
        XCTAssertTrue(
            PlanModeReadOnlyPolicy.evaluate(toolName: "view_image", hostKind: "desk", arguments: .object(["path": .string("a.png")])).isAllowed
        )
        XCTAssertFalse(
            PlanModeReadOnlyPolicy.evaluate(toolName: "view_image", hostKind: "den", arguments: .object(["path": .string("a.png")])).isAllowed
        )
        XCTAssertFalse(
            PlanModeReadOnlyPolicy.evaluate(toolName: "view_image", hostKind: "hill:prod", arguments: .object(["path": .string("a.png")])).isAllowed
        )
        XCTAssertTrue(
            PlanModeReadOnlyPolicy.evaluate(toolName: "view_image", hostKind: "den", arguments: .object(["ref": .string("img-1")])).isAllowed
        )

        // Mutating, execution, vault, browser, memory-write, and ALL MCP / deferred MCP tools hard-blocked.
        for name in [
            "write_file", "edit_file", "desk_delete", "make_document", "generate_image",
            "shell", "run_js", "ssh_run", "ssh_add_host",
            "remember", "forget", "record_experience",
            "calendar_add", "reminder_add", "contacts_add", "photos_save",
            "message_later", "schedule_task", "cancel_task",
            "browser_open", "browser_click", "browser_type", "browser_fill_secret",
            "gmail_draft", "gmail_send", "clipboard_write", "open_link", "vault_list",
            "mcp_github_list_issues", "mcp_notion_read", "tool_search", "tool_help", "tool_invoke",
            "unknown_custom_tool",
        ] {
            XCTAssertFalse(
                PlanModeReadOnlyPolicy.evaluate(toolName: name, hostKind: "desk", arguments: .object([:])).isAllowed,
                "\(name) must be hard-blocked in Plan mode"
            )
        }
    }

    func testAskUserAllowsPlainClarificationAndBlocksSecretOrVaultFields() {
        let plainFields: JSONValue = .object([
            "fields": .array([
                .object([
                    "key": .string("scope"),
                    "label": .string("先做哪个模块？"),
                    "type": .string("text"),
                ]),
            ]),
        ])
        XCTAssertTrue(PlanModeReadOnlyPolicy.evaluate(toolName: "ask_user", hostKind: "desk", arguments: plainFields).isAllowed)

        let plainShorthand: JSONValue = .object([
            "question": .string("偏好哪种实现方案？"),
            "choices": .array([.string("方案 A"), .string("方案 B")]),
        ])
        XCTAssertTrue(PlanModeReadOnlyPolicy.evaluate(toolName: "ask_user", hostKind: "desk", arguments: plainShorthand).isAllowed)

        let secretTopLevel: JSONValue = .object([
            "question": .string("输入访问凭证"),
            "secret": .bool(true),
        ])
        XCTAssertFalse(PlanModeReadOnlyPolicy.evaluate(toolName: "ask_user", hostKind: "desk", arguments: secretTopLevel).isAllowed)

        let secretField: JSONValue = .object([
            "fields": .array([
                .object([
                    "key": .string("pwd"),
                    "label": .string("输入登录密码"),
                    "type": .string("text"),
                    "secret": .bool(true),
                ]),
            ]),
        ])
        XCTAssertFalse(PlanModeReadOnlyPolicy.evaluate(toolName: "ask_user", hostKind: "desk", arguments: secretField).isAllowed)

        let classifiedVaultPrompt: JSONValue = .object([
            "fields": .array([
                .object([
                    "key": .string("api_key"),
                    "label": .string("请输入 API Key"),
                    "type": .string("text"),
                ]),
            ]),
        ])
        XCTAssertFalse(PlanModeReadOnlyPolicy.evaluate(toolName: "ask_user", hostKind: "desk", arguments: classifiedVaultPrompt).isAllowed)
    }

    func testLiveGatedToolPreExecutionRecheckBlocksEvenWithPriorReceipt() async throws {
        let ledger = LivePlanModeLedger()
        let receipts = ApprovalReceiptBook()
        let executed = AtomicIntBox()
        let raw = PlanMockTool("write_file", requiresApproval: true) { _ in executed.increment() }
        let context = ToolExecutionContext(executionChat: "bot-a", hostID: "desk", grantID: "desk")

        let gated = LiveGatedTool(
            inner: raw,
            context: context,
            receipts: receipts,
            planRefusal: { args in
                guard ledger.isRestricted("bot-a") else { return nil }
                if case .deny(let reason) = PlanModeReadOnlyPolicy.evaluate(toolName: "write_file", hostKind: "desk", arguments: args) {
                    return reason
                }
                return nil
            },
            access: { .allow(bypassNonForced: true) }
        )

        // Simulate user approving the write before toggling Plan mode ON mid-turn.
        receipts.record(invocation: "inv-1", context: context, tool: "write_file")
        ledger.setPlanMode(true, for: "bot-a")

        let output = try await ToolInvocation.$currentID.withValue("inv-1") {
            try await gated.run(.object(["path": .string("a.txt"), "content": .string("x")]))
        }
        XCTAssertTrue(output.isError)
        XCTAssertEqual(executed.value, 0)
        XCTAssertTrue(output.text.contains("规划模式"))
    }

    func testLedgerCasualImmunityAndParentToChildDynamicPropagation() {
        let ledger = LivePlanModeLedger()

        // Casual tracks must never enter Plan mode.
        ledger.setPlanMode(true, for: "casual-bot-1")
        XCTAssertFalse(ledger.isPlanMode("casual-bot-1"))
        XCTAssertFalse(ledger.isRestricted("casual-bot-1"))

        // Active delegation dynamically inherits mid-flight parent Plan-mode activation.
        ledger.setDelegationParent("bot-parent", for: "bot-helper")
        XCTAssertFalse(ledger.isRestricted("bot-helper"))

        ledger.setPlanMode(true, for: "bot-parent")
        XCTAssertTrue(ledger.isRestricted("bot-parent"))
        XCTAssertTrue(ledger.isRestricted("bot-helper"))
        XCTAssertTrue(ledger.isInheritedReadOnly("bot-helper"))

        // Explicit inherited read-only ceiling stays active until released.
        ledger.setInheritedReadOnly(true, for: "bot-helper")
        ledger.setPlanMode(false, for: "bot-parent")
        XCTAssertTrue(ledger.isRestricted("bot-helper"))

        ledger.setInheritedReadOnly(false, for: "bot-helper")
        ledger.setDelegationParent(nil, for: "bot-helper")
        XCTAssertFalse(ledger.isRestricted("bot-helper"))
    }
}
