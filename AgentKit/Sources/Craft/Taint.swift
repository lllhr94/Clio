import AgentKit
import Foundation

/// Text from the web can carry instructions aimed at the model, hidden in a page.
/// Clio respects the user's explicit permission settings and standing approvals for everyday tools
/// (shell, SSH, MCP, workspace files); only the three irreversible or secret-bearing exits are always forced.
public enum Taint {
    /// Tools whose results bring text from outside into the turn.
    public static func reads(_ tool: String) -> Bool {
        // Web pages (and their titles), mail and shared documents, the clipboard, and any connector service.
        ["browser_read", "browser_text", "browser_open", "browser_click", "browser_back", "browser_tabs", "browser_screenshot",
         "web_read", "web_search", "gmail_read", "gmail_search", "drive_read", "drive_search", "clipboard_read"].contains(tool)
            || tool.hasPrefix("mcp_")
    }

    /// The three core exits that always require a fresh user seal:
    /// filling a kept secret into a webpage, sending email, and creating a recurring routine.
    public static let hardExits: Set<String> = ["browser_fill_secret", "gmail_send", "schedule_task"]

    /// Whether this step always requires a forced seal regardless of standing permissions.
    public static func needsSeal(tool: String, arguments: JSONValue, isInside: (String) -> Bool) -> Bool {
        _ = arguments
        _ = isInside
        return hardExits.contains(tool)
    }

    public static func codePayload(tool name: String, arguments: JSONValue) -> String? {
        if name == "shell" || name == "ssh_run" || name == "ssh_job_start" {
            if let command = arguments["command"]?.string, !command.isEmpty { return command }
        }
        if name == "run_js", let script = arguments["code"]?.string, !script.isEmpty {
            return script
        }
        if name.hasPrefix("mcp_") {
            let compact = arguments.compact
            if !compact.isEmpty, compact != "{}" { return compact }
        }
        return nil
    }

    public static let reason = "这一轮读过外部网页。网页里可能藏着冲着模型写的指令，所以这一步不管之前怎么放行，都要你亲自点头。"
}

/// Which chats have read the web in the turn running now.
public final class TaintBook: @unchecked Sendable {
    private let lock = NSLock()
    private var tainted: Set<String> = []

    public init() {}

    public func mark(_ key: String) {
        lock.lock(); tainted.insert(key); lock.unlock()
    }

    public func clear(_ key: String) {
        lock.lock(); tainted.remove(key); lock.unlock()
    }

    public func isTainted(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return tainted.contains(key)
    }
}

/// Wraps a tool: tracks whether the turn read outside content and ensures hard exits always ask with `forced` set
/// (with an extra web-reading banner when the current turn read outside text).
public struct TaintGuard: AgentTool {
    public let inner: AgentTool
    let key: String
    let book: TaintBook
    let isInside: @Sendable (String) -> Bool

    public init(_ inner: AgentTool, key: String, book: TaintBook, isInside: @escaping @Sendable (String) -> Bool) {
        self.inner = inner
        self.key = key
        self.book = book
        self.isInside = isInside
    }

    public var spec: ToolSpec { inner.spec }
    public func label(for arguments: JSONValue) -> String { inner.label(for: arguments) }

    public func approval(for arguments: JSONValue) -> ApprovalAsk? {
        let own = inner.approval(for: arguments)
        let mustSeal = own?.forced == true || Taint.needsSeal(tool: spec.name, arguments: arguments, isInside: isInside)
        guard mustSeal else { return own }
        var ask = own ?? ApprovalAsk(title: "这一步要你点头", reason: inner.label(for: arguments))
        if ask.code == nil {
            ask.code = Taint.codePayload(tool: spec.name, arguments: arguments)
        }
        ask.forced = true
        if book.isTainted(key), !(ask.detail?.hasPrefix(Taint.reason) == true) {
            ask.detail = Taint.reason + (ask.detail.map { "\n\n" + $0 } ?? "")
        }
        return ask
    }

    public func run(_ arguments: JSONValue) async throws -> ToolOutput {
        if Taint.reads(spec.name) { book.mark(key) }
        return try await inner.run(arguments)
    }
}
