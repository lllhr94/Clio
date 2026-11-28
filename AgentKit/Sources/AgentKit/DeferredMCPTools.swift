import Foundation

/// Progressive disclosure for oversized third-party MCP tool sets (`> 25` tools in one conversation).
///
/// Hard invariants:
/// - Clio built-in core tools (`builtInTools`) are 100% resident and NEVER deferred/folded.
/// - Only third-party MCP tools exceeding `threshold` (25) are collapsed behind `tool_search`,
///   `tool_help`, and `tool_invoke`.
/// - Every schema inspection (`tool_help`) AND every actual invocation (`tool_invoke`) re-checks live
///   connector permission + generation validity so revoked/changed connectors immediately invalidate.
public enum DeferredMCPTools {
    public static let threshold = 25

    public struct Entry: Sendable {
        public let stableID: String
        public let serverID: String
        public let serverName: String
        public let tool: AgentTool

        public init(stableID: String, serverID: String, serverName: String, tool: AgentTool) {
            self.stableID = stableID
            self.serverID = serverID
            self.serverName = serverName
            self.tool = tool
        }
    }

    public struct Policy: Sendable {
        public let connectorGeneration: UInt64
        /// Atomic evaluation returning `nil` when permitted, or a user-facing denial reason if generation/permission changed.
        private let evaluateAccess: @Sendable (String, String) -> String?
        private let evaluateGeneration: @Sendable () -> Bool

        public init(
            connectorGeneration: UInt64,
            currentGeneration: @escaping @Sendable () -> UInt64,
            isPermitted: @escaping @Sendable (String, String) -> Bool
        ) {
            self.connectorGeneration = connectorGeneration
            self.evaluateGeneration = { currentGeneration() == connectorGeneration }
            self.evaluateAccess = { serverID, stableID in
                if currentGeneration() != connectorGeneration {
                    return "连接器配置已变更（代次已失效），请重新检索工具后再试。"
                }
                guard isPermitted(serverID, stableID) else {
                    return "连接器权限已关闭或当前工具未被授权。"
                }
                return nil
            }
        }

        public init(
            connectorGeneration: UInt64,
            isGenerationCurrent: @escaping @Sendable () -> Bool,
            atomicCheck: @escaping @Sendable (String, String) -> String?
        ) {
            self.connectorGeneration = connectorGeneration
            self.evaluateGeneration = isGenerationCurrent
            self.evaluateAccess = atomicCheck
        }

        func isGenerationValid() -> Bool {
            evaluateGeneration()
        }

        func checkAccess(serverID: String, stableID: String) -> String? {
            evaluateAccess(serverID, stableID)
        }
    }

    /// Assembles the active tool list for a turn:
    /// - Keeps 100% of `builtInTools` resident.
    /// - If `mcpEntries.count <= threshold`, includes all MCP tools directly.
    /// - If `mcpEntries.count > threshold`, exposes `tool_search`, `tool_help`, and `tool_invoke`.
    public static func assemble(
        builtInTools: [AgentTool],
        mcpEntries: [Entry],
        policy: Policy,
        threshold: Int = DeferredMCPTools.threshold
    ) -> [AgentTool] {
        guard mcpEntries.count > threshold else {
            return builtInTools + mcpEntries.map(\.tool)
        }
        // Safely deduplicate by stableID without ever trapping on duplicate keys.
        var indexed: [String: Entry] = [:]
        var uniqueEntries: [Entry] = []
        uniqueEntries.reserveCapacity(mcpEntries.count)
        for entry in mcpEntries {
            if indexed[entry.stableID] == nil {
                indexed[entry.stableID] = entry
                uniqueEntries.append(entry)
            }
        }
        let metaTools: [AgentTool] = [
            SearchTool(entries: uniqueEntries, policy: policy),
            HelpTool(indexed: indexed, policy: policy),
            InvokeTool(indexed: indexed, policy: policy),
        ]
        return builtInTools + metaTools
    }

    private struct SearchTool: AgentTool {
        let entries: [Entry]
        let policy: Policy

        var isReadOnlySafe: Bool { true }
        var hasSideEffects: Bool { false }

        var spec: ToolSpec {
            ToolSpec(
                name: "tool_search",
                description: "检索已连接的第三方 MCP 工具（共 \(entries.count) 个）。输入关键词返回匹配工具名与简介，再用 tool_help 查看参数、tool_invoke 调用。",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object(["type": .string("string"), "description": .string("关键词，留空列出前 20 个工具")]),
                        "limit": .object(["type": .string("integer"), "description": .string("最多返回条数，默认 12，最大 25")]),
                    ]),
                ])
            )
        }

        func label(for arguments: JSONValue) -> String {
            let query = arguments["query"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return query.isEmpty ? "检索扩展工具" : "检索扩展工具：\(query)"
        }

        func run(_ arguments: JSONValue) async throws -> ToolOutput {
            if !policy.isGenerationValid() {
                return ToolOutput("连接器配置已变更（代次已失效），请刷新后重试。", isError: true)
            }
            let query = (arguments["query"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let limit = min(25, max(1, arguments["limit"]?.int ?? 12))
            let permitted = entries.filter { policy.checkAccess(serverID: $0.serverID, stableID: $0.stableID) == nil }
            let matched: [Entry]
            if query.isEmpty {
                matched = Array(permitted.prefix(limit))
            } else {
                let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
                matched = Array(permitted.filter { entry in
                    let haystack = "\(entry.stableID) \(entry.serverName) \(entry.tool.spec.description)".lowercased()
                    return terms.allSatisfy { haystack.contains($0) }
                }.prefix(limit))
            }
            guard !matched.isEmpty else {
                return ToolOutput("未找到匹配的已授权扩展工具。")
            }
            let lines = matched.map { entry in
                let desc = String(entry.tool.spec.description.prefix(120))
                return "- \(entry.stableID) [\(entry.serverName)]：\(desc)"
            }
            return ToolOutput("找到 \(matched.count) 个扩展工具（用 tool_help 查参数，tool_invoke 执行）：\n" + lines.joined(separator: "\n"))
        }
    }

    private struct HelpTool: AgentTool {
        let indexed: [String: Entry]
        let policy: Policy

        var isReadOnlySafe: Bool { true }
        var hasSideEffects: Bool { false }

        var spec: ToolSpec {
            ToolSpec(
                name: "tool_help",
                description: "查看单个第三方 MCP 扩展工具的完整参数 Schema（会复核当前连接器权限）。",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "tool": .object(["type": .string("string"), "description": .string("tool_search 返回的工具名")]),
                    ]),
                    "required": .array([.string("tool")]),
                ])
            )
        }

        func label(for arguments: JSONValue) -> String {
            let name = arguments["tool"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return "查看工具说明：\(name)"
        }

        func run(_ arguments: JSONValue) async throws -> ToolOutput {
            guard let name = arguments["tool"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let entry = indexed[name] else {
                return ToolOutput("未找到该扩展工具，请先用 tool_search 确认名称。", isError: true)
            }
            // Live permission + generation re-check at schema fetch!
            if let denial = policy.checkAccess(serverID: entry.serverID, stableID: entry.stableID) {
                return ToolOutput(denial, isError: true)
            }
            return ToolOutput(
                "工具：\(entry.stableID)（来自 \(entry.serverName)）\n说明：\(entry.tool.spec.description)\n参数 Schema：\(entry.tool.spec.parameters.compact)"
            )
        }
    }

    private struct InvokeTool: AgentTool {
        let indexed: [String: Entry]
        let policy: Policy

        var isReadOnlySafe: Bool { false }
        var hasSideEffects: Bool { true }

        var spec: ToolSpec {
            ToolSpec(
                name: "tool_invoke",
                description: "调用由 tool_search / tool_help 展开的第三方 MCP 扩展工具。",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "tool": .object(["type": .string("string"), "description": .string("要调用的扩展工具名")]),
                        "arguments": .object(["type": .string("object"), "description": .string("按 tool_help Schema 构造的参数对象")]),
                    ]),
                    "required": .array([.string("tool")]),
                ])
            )
        }

        private func resolveEntry(_ arguments: JSONValue) -> Entry? {
            guard let name = arguments["tool"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else {
                return nil
            }
            return indexed[name]
        }

        func label(for arguments: JSONValue) -> String {
            if let entry = resolveEntry(arguments) {
                return entry.tool.label(for: arguments["arguments"] ?? .object([:]))
            }
            let name = arguments["tool"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return "调用扩展工具：\(name)"
        }

        func approval(for arguments: JSONValue) -> ApprovalAsk? {
            guard let entry = resolveEntry(arguments) else { return nil }
            return entry.tool.approval(for: arguments["arguments"] ?? .object([:]))
        }

        func run(_ arguments: JSONValue) async throws -> ToolOutput {
            guard let entry = resolveEntry(arguments) else {
                return ToolOutput("未找到该扩展工具，请先用 tool_search 确认名称。", isError: true)
            }
            // Live permission + generation re-check at execution time!
            if let denial = policy.checkAccess(serverID: entry.serverID, stableID: entry.stableID) {
                return ToolOutput(denial, isError: true)
            }
            return try await entry.tool.run(arguments["arguments"] ?? .object([:]))
        }
    }
}
