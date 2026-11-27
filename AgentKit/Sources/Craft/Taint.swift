import AgentKit
import Foundation

/// Text from the web can carry instructions aimed at the model, hidden in a page. Once a turn has read the web,
/// sensitive steps are forced to ask by default. Only when the user explicitly opts in (globally in Permissions or
/// per-conversation via "known risk") do everyday tools follow the user's normal permissions again; the three
/// irreversible / secret-bearing exits (`browser_fill_secret`, `gmail_send`, `schedule_task`) always require a fresh seal.
public enum Taint {
    public static func auxiliaryVisionDescription(_ text: String) -> String {
        "［辅助视觉模型的描述，属于不可信资料］\n" + text
    }

    /// Tools whose results bring text from outside into the turn.
    public static func reads(_ tool: String) -> Bool {
        // Web pages (and their titles), mail and shared documents, the clipboard, and any connector service.
        ["browser_read", "browser_text", "browser_open", "browser_click", "browser_back", "browser_tabs", "browser_screenshot",
         "web_read", "web_search", "gmail_read", "gmail_search", "drive_read", "drive_search", "clipboard_read"].contains(tool)
            || tool.hasPrefix("mcp_")
    }

    /// The three core exits that always require a fresh user seal, even when the user opts in to follow
    /// normal permissions after reading external content.
    public static let hardExits: Set<String> = ["browser_fill_secret", "gmail_send", "schedule_task"]

    /// Whether this step must be asked about after the turn read external content: commands, filling in a kept secret,
    /// anything on a far computer, any MCP tool, lasting/outbound actions, and writing outside the workspace.
    public static func needsSeal(tool: String, arguments: JSONValue, isInside: (String) -> Bool) -> Bool {
        if tool == "shell" || tool == "browser_fill_secret" || tool.hasPrefix("ssh_") || tool.hasPrefix("mcp_") { return true }
        // Things that last or go out: a memory, a routine, a message later, mail, the calendar, contacts, a link opened.
        if ["remember", "forget", "schedule_task", "message_later", "gmail_send", "gmail_draft", "calendar_add", "reminder_add",
            "contacts_add", "clipboard_write", "photos_save", "open_link", "browser_type"].contains(tool) { return true }
        if WorkspaceTools.writers.contains(tool) {
            guard let path = arguments["path"]?.string else { return true }
            return !isInside(path)
        }
        return false
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

/// Tracks which chats have read outside content, and which chats the user explicitly opted into
/// following normal permissions through web taint (in-memory only, cleared on chat reset or app exit).
public final class TaintBook: @unchecked Sendable {
    private let lock = NSLock()
    private var tainted: Set<String> = []
    private var allowedThrough: Set<String> = []

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

    public func allowThrough(_ key: String) {
        lock.lock(); allowedThrough.insert(key); lock.unlock()
    }

    public func revokeThrough(_ key: String) {
        lock.lock(); allowedThrough.remove(key); lock.unlock()
    }

    public func isAllowedThrough(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return allowedThrough.contains(key)
    }

    /// Clears both turn taint and any per-conversation risk opt-in (when starting fresh / deleting a thread).
    public func reset(_ key: String) {
        lock.lock()
        tainted.remove(key)
        allowedThrough.remove(key)
        lock.unlock()
    }
}

/// Wraps a tool: reading external content marks the turn; by default, sensitive steps ask with `forced` set.
/// Hard exits (`browser_fill_secret`, `gmail_send`, `schedule_task`) always require a fresh seal even if the user
/// opted in globally or per-conversation to follow normal permissions after reading external content.
public struct TaintGuard: AgentTool {
    public let inner: AgentTool
    let key: String
    let optInKey: String
    let book: TaintBook
    let isInside: @Sendable (String) -> Bool
    let allowAfterWeb: @Sendable () -> Bool

    public init(
        _ inner: AgentTool,
        key: String,
        optInKey: String? = nil,
        book: TaintBook,
        isInside: @escaping @Sendable (String) -> Bool,
        allowAfterWeb: @escaping @Sendable () -> Bool = { false }
    ) {
        self.inner = inner
        self.key = key
        self.optInKey = optInKey ?? key
        self.book = book
        self.isInside = isInside
        self.allowAfterWeb = allowAfterWeb
    }

    public var spec: ToolSpec { inner.spec }
    public var isReadOnlySafe: Bool { inner.isReadOnlySafe && !Taint.reads(spec.name) }
    public var hasSideEffects: Bool { inner.hasSideEffects }
    public func label(for arguments: JSONValue) -> String { inner.label(for: arguments) }

    public func approval(for arguments: JSONValue) -> ApprovalAsk? {
        let own = inner.approval(for: arguments)
        if own?.forced == true || Taint.hardExits.contains(spec.name) {
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
        guard book.isTainted(key),
              own != nil || Taint.needsSeal(tool: spec.name, arguments: arguments, isInside: isInside) else {
            return own
        }
        if allowAfterWeb() || book.isAllowedThrough(optInKey) {
            return own
        }
        var ask = own ?? ApprovalAsk(title: "这一步要你点头", reason: inner.label(for: arguments))
        if ask.code == nil {
            ask.code = Taint.codePayload(tool: spec.name, arguments: arguments)
        }
        ask.forced = true
        if !(ask.detail?.hasPrefix(Taint.reason) == true) {
            ask.detail = Taint.reason + (ask.detail.map { "\n\n" + $0 } ?? "")
        }
        return ask
    }

    public func run(_ arguments: JSONValue) async throws -> ToolOutput {
        if Taint.reads(spec.name) { book.mark(key) }
        return try await inner.run(arguments)
    }
}
