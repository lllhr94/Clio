import AgentKit
import Foundation

/// Text from the web can carry instructions aimed at the model, hidden in a page. Once a turn has read the web,
/// the steps that could do real harm are always put to the person, whatever standing permission says.
public enum Taint {
    /// Tools whose results bring text from outside into the turn.
    public static func reads(_ tool: String) -> Bool {
        ["browser_read", "browser_screenshot", "web_read", "web_search"].contains(tool) || tool.hasPrefix("mcp_")
    }

    /// Whether this step must be asked about after the turn read the web: commands, filling in a kept secret,
    /// anything on a far computer, and writing outside the workspace.
    public static func needsSeal(tool: String, arguments: JSONValue, isInside: (String) -> Bool) -> Bool {
        if tool == "shell" || tool == "browser_fill_secret" || tool.hasPrefix("ssh_") { return true }
        if WorkspaceTools.writers.contains(tool) {
            guard let path = arguments["path"]?.string else { return true }
            return !isInside(path)
        }
        return false
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

/// Wraps a tool: reading the web marks the turn; after that, a harmful step asks with `forced` set.
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
        guard book.isTainted(key), Taint.needsSeal(tool: spec.name, arguments: arguments, isInside: isInside) else { return own }
        var ask = own ?? ApprovalAsk(title: "这一步要你点头", reason: inner.label(for: arguments))
        ask.forced = true
        ask.detail = Taint.reason + (ask.detail.map { "\n\n" + $0 } ?? "")
        return ask
    }

    public func run(_ arguments: JSONValue) async throws -> ToolOutput {
        if Taint.reads(spec.name) { book.mark(key) }
        return try await inner.run(arguments)
    }
}
