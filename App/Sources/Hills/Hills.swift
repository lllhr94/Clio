import AgentKit
import Citadel
import CryptoKit
import Foundation
import NIOCore

/// 远山: computers far away. SSH hosts the companions can run commands on, and MCP servers whose tools they can borrow.
@MainActor
final class Hills: ObservableObject {
    static let shared = Hills()

    struct Host: Codable, Identifiable, Hashable, Sendable {
        var id = UUID().uuidString
        var name: String
        var address: String
        var port: Int = 22
        var user: String
        var useKey: Bool = false
    }

    struct Server: Codable, Identifiable, Hashable, Sendable {
        var id = UUID().uuidString
        var name: String
        var url: String
        var enabled = true
    }

    /// What an MCP server said it can do, kept so tools can be listed without a network call.
    struct Borrowed: Codable, Hashable, Sendable {
        var server: String
        var name: String
        var description: String
        var schema: JSONValue
    }

    @Published private(set) var hosts: [Host] = []
    @Published private(set) var servers: [Server] = []
    @Published private(set) var borrowed: [Borrowed] = []
    @Published var lastError: [String: String] = [:]

    init() {
        hosts = Disk.load([Host].self, "hills.json") ?? []
        servers = Disk.load([Server].self, "mcp.json") ?? []
        borrowed = Disk.load([Borrowed].self, "mcp-tools.json") ?? []
    }

    // MARK: Hosts

    func save(_ host: Host, password: String?) {
        if let index = hosts.firstIndex(where: { $0.id == host.id }) { hosts[index] = host } else { hosts.append(host) }
        if let password, !password.isEmpty { Vault.save(password, as: "hill.\(host.id)") }
        Disk.save(hosts, "hills.json")
    }

    func remove(_ host: Host) {
        hosts.removeAll { $0.id == host.id }
        Disk.save(hosts, "hills.json")
    }

    func host(named name: String) -> Host? {
        let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
        return hosts.first { $0.name.lowercased() == wanted } ?? hosts.first { $0.address.lowercased() == wanted } ?? (hosts.count == 1 && wanted.isEmpty ? hosts.first : nil)
    }

    /// The phone's own SSH key, made once. Its public half goes into a server's ~/.ssh/authorized_keys.
    nonisolated static var key: Curve25519.Signing.PrivateKey {
        if let raw = Vault.load(Data.self, key: "hill.key"), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) { return key }
        let key = Curve25519.Signing.PrivateKey()
        Vault.save(key.rawRepresentation, as: "hill.key")
        return key
    }

    nonisolated static var publicKey: String {
        func field(_ bytes: Data) -> Data {
            var length = UInt32(bytes.count).bigEndian
            return Data(bytes: &length, count: 4) + bytes
        }
        let blob = field(Data("ssh-ed25519".utf8)) + field(key.publicKey.rawRepresentation)
        return "ssh-ed25519 " + blob.base64EncodedString() + " clio@iphone"
    }

    struct Outcome: Sendable {
        var code: Int
        var output: String
    }

    /// Connects, runs one command, and hangs up.
    nonisolated static func run(_ command: String, on host: Host, timeout: Double = 60) async throws -> Outcome {
        let method: SSHAuthenticationMethod
        if host.useKey {
            method = .ed25519(username: host.user, privateKey: key)
        } else {
            guard let password = Vault.load(String.self, key: "hill.\(host.id)") else { throw ProviderError("还没存 \(host.name) 的密码。") }
            method = .passwordBased(username: host.user, password: password)
        }
        return try await withThrowingTaskGroup(of: Outcome.self) { group in
            group.addTask {
                let client = try await SSHClient.connect(host: host.address, port: host.port, authenticationMethod: method, hostKeyValidator: .acceptAnything(), reconnect: .never, connectTimeout: .seconds(15))
                var output = ""
                var code = 0
                do {
                    let stream = try await client.executeCommandStream(command)
                    for try await chunk in stream {
                        switch chunk {
                        case .stdout(let buffer), .stderr(let buffer):
                            output += String(buffer: buffer)
                        }
                        if output.count > 200_000 { break }
                    }
                } catch let failed as SSHClient.CommandFailed {
                    code = failed.exitCode
                }
                try? await client.close()
                return Outcome(code: code, output: output)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw ProviderError("超过 \(Int(timeout)) 秒没跑完。")
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    // MARK: MCP servers

    func save(_ server: Server, token: String?) {
        if let index = servers.firstIndex(where: { $0.id == server.id }) { servers[index] = server } else { servers.append(server) }
        if let token { Vault.save(token, as: "mcp.\(server.id)") }
        Disk.save(servers, "mcp.json")
    }

    func remove(_ server: Server) {
        servers.removeAll { $0.id == server.id }
        borrowed.removeAll { $0.server == server.id }
        Disk.save(servers, "mcp.json")
        Disk.save(borrowed, "mcp-tools.json")
    }

    /// Asks a server for its tools again. Returns how many it offered.
    @discardableResult
    func refresh(_ server: Server) async -> Int {
        do {
            let client = MCPClient(url: server.url, token: Vault.load(String.self, key: "mcp.\(server.id)"))
            let tools = try await client.listTools()
            borrowed.removeAll { $0.server == server.id }
            borrowed += tools.map { Borrowed(server: server.id, name: $0.name, description: $0.description, schema: $0.schema) }
            Disk.save(borrowed, "mcp-tools.json")
            lastError[server.id] = nil
            return tools.count
        } catch {
            lastError[server.id] = error.localizedDescription
            return -1
        }
    }

    func tools(of server: Server) -> [Borrowed] { borrowed.filter { $0.server == server.id } }

    // MARK: Tools

    func tools() -> [AgentTool] {
        var tools: [AgentTool] = []
        if !hosts.isEmpty {
            let names = hosts.map { "\($0.name)（\($0.user)@\($0.address)）" }.joined(separator: "、")
            let snapshot = hosts
            tools.append(DeskTool(name: "ssh_run", description: "在用户的远程主机（远山）上用 SSH 跑一条命令。可用的主机：\(names)。命令要能自己结束，不要开交互程序。", parameters: ["type": "object", "properties": ["host": ["type": "string", "description": "主机名字"], "command": ["type": "string"], "timeout": ["type": "number", "description": "最多等几秒，默认 60，最多 600"]], "required": ["host", "command"]], label: { "远山：\($0["host"]?.string ?? "") · \(($0["command"]?.string ?? "").prefix(30))" }) { arguments in
                let wanted = (arguments["host"]?.string ?? "").lowercased()
                guard let host = snapshot.first(where: { $0.name.lowercased() == wanted || $0.address.lowercased() == wanted }) ?? (snapshot.count == 1 ? snapshot.first : nil) else {
                    return ToolOutput("没有叫「\(arguments["host"]?.string ?? "")」的主机。可用：\(names)", isError: true)
                }
                do {
                    let result = try await Hills.run(arguments["command"]?.string ?? "", on: host, timeout: min(600, max(5, arguments["timeout"]?.number ?? 60)))
                    var text = result.output
                    if text.count > 12000 { text = String(text.prefix(4000)) + "\n……（中间省略）……\n" + String(text.suffix(4000)) }
                    return ToolOutput((text.isEmpty ? "（没有输出）" : text) + (result.code == 0 ? "" : "\n（退出码 \(result.code)）"), isError: result.code != 0)
                } catch {
                    return ToolOutput("连 \(host.name) 出错：\(error.localizedDescription)", isError: true)
                }
            })
        }
        for server in servers where server.enabled {
            let token = Vault.load(String.self, key: "mcp.\(server.id)")
            let slug = Self.slug(server.name)
            for tool in borrowed where tool.server == server.id {
                let url = server.url
                let remote = tool.name
                let title = server.name
                tools.append(DeskTool(name: String("mcp_\(slug)__\(Self.slug(remote))".prefix(64)), description: "（来自远山 MCP「\(title)」）" + tool.description, parameters: tool.schema, label: { _ in "远山：\(title) · \(remote)" }) { arguments in
                    do {
                        return try await MCPClient(url: url, token: token).call(remote, arguments: arguments)
                    } catch {
                        return ToolOutput("「\(title)」出错：\(error.localizedDescription)", isError: true)
                    }
                })
            }
        }
        return tools
    }

    nonisolated static func slug(_ text: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        let cleaned = String(text.map { allowed.contains($0) ? $0 : "_" })
        return cleaned.isEmpty ? "s" : cleaned
    }
}

/// A small MCP client over Streamable HTTP: initialize, list tools, call a tool.
struct MCPClient: Sendable {
    let url: String
    let token: String?

    struct Tool: Sendable {
        var name: String
        var description: String
        var schema: JSONValue
    }

    private static let sessions = SessionBook()

    private final class SessionBook: @unchecked Sendable {
        private var ids: [String: String] = [:]
        private let lock = NSLock()
        func get(_ url: String) -> String? { lock.lock(); defer { lock.unlock() }; return ids[url] }
        func set(_ url: String, _ id: String?) { lock.lock(); ids[url] = id; lock.unlock() }
    }

    func listTools() async throws -> [Tool] {
        try await start()
        var tools: [Tool] = []
        var cursor: String?
        repeat {
            let params: JSONValue = cursor.map { JSONValue.object(["cursor": .string($0)]) } ?? .object([:])
            let result = try await send("tools/list", params)
            for item in result["tools"]?.array ?? [] {
                guard let name = item["name"]?.string else { continue }
                tools.append(Tool(name: name, description: item["description"]?.string ?? "", schema: item["inputSchema"] ?? ["type": "object", "properties": [:]]))
            }
            cursor = result["nextCursor"]?.string
        } while cursor != nil && tools.count < 300
        return tools
    }

    func call(_ name: String, arguments: JSONValue) async throws -> ToolOutput {
        if Self.sessions.get(url) == nil { try await start() }
        let result: JSONValue
        do {
            result = try await send("tools/call", ["name": .string(name), "arguments": arguments])
        } catch MCPError.sessionGone {
            try await start()
            result = try await send("tools/call", ["name": .string(name), "arguments": arguments])
        }
        var parts: [String] = []
        for item in result["content"]?.array ?? [] {
            switch item["type"]?.string {
            case "text": parts.append(item["text"]?.string ?? "")
            case "image": parts.append("［一张图片，\(item["mimeType"]?.string ?? "")］")
            case "resource": parts.append(item["resource"]?["text"]?.string ?? "［资源］")
            default: parts.append(item.compact)
            }
        }
        if parts.isEmpty, let structured = result["structuredContent"] { parts.append(structured.compact) }
        var text = parts.joined(separator: "\n")
        if text.count > 16000 { text = String(text.prefix(16000)) + "\n……（太长，截断了）" }
        return ToolOutput(text.isEmpty ? "（没有内容）" : text, isError: result["isError"]?.bool ?? false)
    }

    enum MCPError: LocalizedError {
        case http(Int, String)
        case rpc(String)
        case sessionGone
        var errorDescription: String? {
            switch self {
            case .http(let code, let body): "服务器回了 \(code)：\(body.prefix(200))"
            case .rpc(let message): message
            case .sessionGone: "会话过期了"
            }
        }
    }

    private func start() async throws {
        Self.sessions.set(url, nil)
        _ = try await send("initialize", [
            "protocolVersion": "2025-06-18",
            "capabilities": [:],
            "clientInfo": ["name": "Clio", "version": "1.0"],
        ])
        try? await notify("notifications/initialized")
    }

    private func request(_ body: JSONValue) throws -> URLRequest {
        guard let target = URL(string: url) else { throw MCPError.rpc("地址不对：\(url)") }
        var request = URLRequest(url: target, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
        if let token, !token.isEmpty { request.setValue(token.lowercased().hasPrefix("bearer ") ? token : "Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let session = Self.sessions.get(url) { request.setValue(session, forHTTPHeaderField: "Mcp-Session-Id") }
        request.httpBody = Data(body.compact.utf8)
        return request
    }

    private func notify(_ method: String) async throws {
        _ = try await URLSession.shared.data(for: try request(["jsonrpc": "2.0", "method": .string(method)]))
    }

    private func send(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        let id = Int.random(in: 1...999_999)
        let (bytes, response) = try await URLSession.shared.bytes(for: try request(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params]))
        let http = response as? HTTPURLResponse
        if let session = http?.value(forHTTPHeaderField: "Mcp-Session-Id") { Self.sessions.set(url, session) }
        let status = http?.statusCode ?? 0
        if status == 404, Self.sessions.get(url) != nil, method != "initialize" { throw MCPError.sessionGone }
        if !(200..<300).contains(status) {
            var body = ""
            for try await line in bytes.lines { body += line; if body.count > 400 { break } }
            throw MCPError.http(status, body)
        }
        let type = http?.value(forHTTPHeaderField: "Content-Type") ?? ""
        if type.contains("text/event-stream") {
            var data = ""
            for try await line in bytes.lines {
                if line.hasPrefix("data:") {
                    data += String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    if let message = JSONValue.parse(data) {
                        data = ""
                        if message["id"]?.number == Double(id) { return try unwrap(message) }
                    }
                } else if line.isEmpty {
                    data = ""
                }
            }
            throw MCPError.rpc("服务器没给回音就断开了。")
        }
        var raw = Data()
        for try await byte in bytes { raw.append(byte) }
        guard let message = JSONValue.parse(String(decoding: raw, as: UTF8.self)) else { throw MCPError.rpc("看不懂服务器的回复。") }
        if let list = message.array, let match = list.first(where: { $0["id"]?.number == Double(id) }) { return try unwrap(match) }
        return try unwrap(message)
    }

    private func unwrap(_ message: JSONValue) throws -> JSONValue {
        if let error = message["error"] { throw MCPError.rpc(error["message"]?.string ?? error.compact) }
        return message["result"] ?? [:]
    }
}
