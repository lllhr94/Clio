import AgentKit
import Citadel
import Craft
import CryptoKit
import Foundation
import NIOCore
import NIOSSH
import Security

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
        /// SHA-256 of the server's own certificate, for a self-signed https server set up by Clio. Only that certificate is trusted.
        var pin: String?
    }

    /// What an MCP server said it can do, kept so tools can be listed without a network call.
    struct Borrowed: Codable, Sendable {
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

    /// Logs in to a host: by the phone's key, or by the password kept in the Vault.
    nonisolated static func connect(_ host: Host) async throws -> SSHClient {
        let method: SSHAuthenticationMethod
        if host.useKey {
            method = .ed25519(username: host.user, privateKey: key)
        } else {
            guard let password = Vault.load(String.self, key: "hill.\(host.id)") else { throw ProviderError("还没存 \(host.name) 的密码。") }
            method = .passwordBased(username: host.user, password: password)
        }
        return try await SSHClient.connect(host: host.address, port: host.port, authenticationMethod: method, hostKeyValidator: .custom(HostKeyKeeper(host: host.address, port: host.port)), reconnect: .never, connectTimeout: .seconds(15))
    }

    /// The channel could not be opened on a kept connection: it has probably gone stale.
    private struct Stale: Error {}

    /// Runs one command on a kept connection. A stale connection is dropped and the command tried once more on a fresh one;
    /// a command that already started is never sent twice.
    nonisolated static func run(_ command: String, on host: Host, timeout: Double = 60) async throws -> Outcome {
        do {
            return try await runOnce(command, on: host, timeout: timeout, fresh: false)
        } catch is Stale {
            await HillPool.shared.drop(host)
            do {
                return try await runOnce(command, on: host, timeout: timeout, fresh: true)
            } catch is Stale {
                throw ProviderError("连上了 \(host.name)，但开不了会话。")
            }
        }
    }

    private nonisolated static func runOnce(_ command: String, on host: Host, timeout: Double, fresh: Bool) async throws -> Outcome {
        try await withThrowingTaskGroup(of: Outcome.self) { group in
            group.addTask {
                let client = try await HillPool.shared.client(for: host, fresh: fresh)
                var output = ""
                var code = 0
                let stream: AsyncThrowingStream<ExecCommandOutput, Error>
                do {
                    stream = try await client.executeCommandStream(command)
                } catch let failed as SSHClient.CommandFailed {
                    return Outcome(code: failed.exitCode, output: "")
                } catch {
                    throw Stale()
                }
                do {
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
                await HillPool.shared.touch(host)
                return Outcome(code: code, output: output)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw ProviderError("超过 \(Int(timeout)) 秒没跑完。长任务可以用 ssh_job_start 放到后台。")
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    /// Words safe to put inside a shell command as one argument.
    nonisolated static func quote(_ text: String) -> String { Shell.quote(text) }

    // MARK: Jobs in the background

    /// Starts a command that keeps running after the connection closes. Its output goes to ~/.clio/jobs/<id>.log.
    nonisolated static func startJob(_ command: String, on host: Host) async throws -> String {
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        let script = "mkdir -p ~/.clio/jobs && cd ~ && printf '%s' \(quote(command)) > ~/.clio/jobs/\(id).cmd && nohup sh -c \(quote("( " + command + " ); echo $? > ~/.clio/jobs/\(id).exit")) > ~/.clio/jobs/\(id).log 2>&1 < /dev/null & echo $! > ~/.clio/jobs/\(id).pid; echo started"
        let result = try await run(script, on: host, timeout: 30)
        guard result.output.contains("started") else { throw ProviderError("没能在 \(host.name) 上开始：\(result.output)") }
        return id
    }

    struct JobState: Sendable {
        var running: Bool
        var exit: Int?
        var tail: String
    }

    nonisolated static func checkJob(_ id: String, on host: Host, lines: Int = 40) async throws -> JobState {
        let safe = id.filter { $0.isLetter || $0.isNumber }
        let script = "cd ~/.clio/jobs 2>/dev/null || { echo NOJOBS; exit 0; }; [ -f \(safe).pid ] || { echo NOJOB; exit 0; }; if kill -0 $(cat \(safe).pid) 2>/dev/null; then echo RUNNING; else echo DONE; fi; echo EXIT=$(cat \(safe).exit 2>/dev/null); echo ---; tail -n \(lines) \(safe).log"
        let result = try await run(script, on: host, timeout: 30)
        if result.output.hasPrefix("NOJOB") { throw ProviderError("\(host.name) 上没有这个后台任务：\(id)") }
        let parts = result.output.components(separatedBy: "\n---\n")
        let head = parts.first ?? ""
        let exit = head.components(separatedBy: "EXIT=").last.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return JobState(running: head.hasPrefix("RUNNING"), exit: exit, tail: parts.dropFirst().joined(separator: "\n---\n"))
    }

    nonisolated static func stopJob(_ id: String, on host: Host) async throws {
        let safe = id.filter { $0.isLetter || $0.isNumber }
        _ = try await run("cd ~/.clio/jobs && pkill -P $(cat \(safe).pid) 2>/dev/null; kill $(cat \(safe).pid) 2>/dev/null; echo 130 > \(safe).exit", on: host, timeout: 20)
    }

    // MARK: A browser on the far computer

    /// Port the token gate listens on (https, with a certificate of its own); Playwright's MCP stays on 127.0.0.1:8931 behind it.
    nonisolated static let browserPort = 8930

    /// Installs Playwright's MCP server and a small token gate on a Linux host, and starts both. Runs as a background job.
    /// The gate speaks https with a self-signed certificate; the app trusts only that certificate (see `PinnedSessions`).
    nonisolated static func browserInstallScript(token: String) -> String {
        let proxy = """
        const http = require('http');
        const https = require('https');
        const fs = require('fs');
        const token = fs.readFileSync(__dirname + '/token', 'utf8').trim();
        const tls = { key: fs.readFileSync(__dirname + '/key.pem'), cert: fs.readFileSync(__dirname + '/cert.pem') };
        https.createServer(tls, (req, res) => {
          if ((req.headers['authorization'] || '') !== 'Bearer ' + token) { res.writeHead(401); res.end('unauthorized'); return; }
          const headers = Object.assign({}, req.headers);
          delete headers['authorization'];
          headers.host = '127.0.0.1:8931';
          delete headers['origin'];
          const up = http.request({ host: '127.0.0.1', port: 8931, path: req.url, method: req.method, headers }, (r) => { res.writeHead(r.statusCode, r.headers); r.pipe(res); });
          up.on('error', (e) => { res.writeHead(502); res.end(String(e)); });
          req.pipe(up);
        }).listen(\(browserPort), '0.0.0.0');
        """
        let start = """
        cd ~/.clio/browser
        [ -f mcp.pid ] && kill $(cat mcp.pid) 2>/dev/null
        [ -f gate.pid ] && kill $(cat gate.pid) 2>/dev/null
        nohup ./node_modules/.bin/mcp-server-playwright --headless --isolated --port 8931 --host 127.0.0.1 > mcp.log 2>&1 < /dev/null &
        echo $! > mcp.pid
        nohup node proxy.js > gate.log 2>&1 < /dev/null &
        echo $! > gate.pid
        exit 0
        """
        return """
        set -e
        mkdir -p ~/.clio/browser && cd ~/.clio/browser
        SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo -n"
        need_node=1
        if command -v node >/dev/null 2>&1; then
          major=$(node -e 'console.log(process.versions.node.split(".")[0])')
          [ "$major" -ge 18 ] && need_node=0
        fi
        if [ $need_node = 1 ]; then
          echo "== 装 Node.js"
          if command -v apt-get >/dev/null 2>&1; then
            curl -fsSL https://deb.nodesource.com/setup_20.x | $SUDO bash - && $SUDO apt-get install -y nodejs
          elif command -v dnf >/dev/null 2>&1; then
            $SUDO dnf install -y nodejs npm
          elif command -v yum >/dev/null 2>&1; then
            curl -fsSL https://rpm.nodesource.com/setup_20.x | $SUDO bash - && $SUDO yum install -y nodejs
          elif command -v apk >/dev/null 2>&1; then
            $SUDO apk add nodejs npm
          else
            echo "不认识这台机器的包管理器，请先手动装 Node.js 18 以上。"; exit 2
          fi
        fi
        echo "== 装 Playwright MCP"
        [ -f package.json ] || npm init -y >/dev/null
        npm install --no-audit --no-fund @playwright/mcp@latest
        echo "== 装 Chromium（要几分钟）"
        npx -y playwright install --with-deps chromium || npx -y playwright install chromium
        printf '%s' \(quote(token)) > token
        chmod 600 token
        echo "== 做一张自己的证书（连接加密，手机只认这一张）"
        if ! command -v openssl >/dev/null 2>&1; then
          if command -v apt-get >/dev/null 2>&1; then $SUDO apt-get install -y openssl
          elif command -v dnf >/dev/null 2>&1; then $SUDO dnf install -y openssl
          elif command -v yum >/dev/null 2>&1; then $SUDO yum install -y openssl
          elif command -v apk >/dev/null 2>&1; then $SUDO apk add openssl
          fi
        fi
        [ -f cert.pem ] || openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -subj "/CN=clio-browser" >/dev/null 2>&1
        chmod 600 key.pem
        cat > proxy.js <<'CLIO_EOF'
        \(proxy)
        CLIO_EOF
        cat > start.sh <<'CLIO_EOF'
        \(start)
        CLIO_EOF
        sh start.sh
        if command -v crontab >/dev/null 2>&1; then
          (crontab -l 2>/dev/null | grep -v 'clio-browser'; echo "@reboot sh $HOME/.clio/browser/start.sh # clio-browser") | crontab - || true
        fi
        sleep 3
        echo "== 好了，令牌门在 \(browserPort) 端口（https）"
        openssl x509 -in cert.pem -noout -fingerprint -sha256
        """
    }

    /// The fingerprint of the browser gate's certificate, read over SSH.
    nonisolated static func browserPin(on host: Host) async throws -> String {
        let result = try await run("openssl x509 -in ~/.clio/browser/cert.pem -noout -fingerprint -sha256", on: host, timeout: 20)
        let pin = PinnedSessions.normalize(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        guard pin.count == 64 else { throw ProviderError("读不到证书指纹：\(result.output.prefix(200))") }
        return pin
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
            let client = MCPClient(url: server.url, token: Vault.load(String.self, key: "mcp.\(server.id)"), pin: server.pin)
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
                    let text = Shell.clip(result.output)
                    return ToolOutput((text.isEmpty ? "（没有输出）" : text) + (result.code == 0 ? "" : "\n（退出码 \(result.code)）"), isError: result.code != 0)
                } catch {
                    return ToolOutput("连 \(host.name) 出错：\(error.localizedDescription)", isError: true)
                }
            })
            let pick: @Sendable (JSONValue) -> Host? = { arguments in
                let wanted = (arguments["host"]?.string ?? "").lowercased()
                return snapshot.first(where: { $0.name.lowercased() == wanted || $0.address.lowercased() == wanted }) ?? (snapshot.count == 1 ? snapshot.first : nil)
            }
            tools.append(DeskTool(name: "ssh_job_start", description: "在远山主机上把一条要跑很久的命令放到后台（编译、下载、训练、装软件）。连接断了它也接着跑。返回一个任务编号，之后用 ssh_job_check 看进度。", parameters: ["type": "object", "properties": ["host": ["type": "string", "description": "主机名字"], "command": ["type": "string"]], "required": ["host", "command"]], label: { "远山：后台跑 \(($0["command"]?.string ?? "").prefix(30))" }) { arguments in
                guard let host = pick(arguments) else { return ToolOutput("没有这台主机。可用：\(names)", isError: true) }
                do {
                    let id = try await Hills.startJob(arguments["command"]?.string ?? "", on: host)
                    return ToolOutput("开始了，任务编号 \(id)。输出记在 \(host.name) 的 ~/.clio/jobs/\(id).log。过一会儿用 ssh_job_check 看。")
                } catch {
                    return ToolOutput("没能开始：\(error.localizedDescription)", isError: true)
                }
            })
            tools.append(DeskTool(name: "ssh_job_check", description: "看远山后台任务的进度：还在不在跑、退出码、最后几十行输出。", parameters: ["type": "object", "properties": ["host": ["type": "string"], "job": ["type": "string", "description": "ssh_job_start 给的编号"], "lines": ["type": "number", "description": "看最后几行，默认 40"]], "required": ["host", "job"]], label: { "远山：看后台任务 \($0["job"]?.string ?? "")" }) { arguments in
                guard let host = pick(arguments) else { return ToolOutput("没有这台主机。可用：\(names)", isError: true) }
                do {
                    let state = try await Hills.checkJob(arguments["job"]?.string ?? "", on: host, lines: min(400, max(5, Int(arguments["lines"]?.number ?? 40))))
                    let head = state.running ? "还在跑。" : "跑完了，退出码 \(state.exit.map(String.init) ?? "不明")。"
                    return ToolOutput(head + "\n最后的输出：\n" + (state.tail.isEmpty ? "（还没有输出）" : state.tail))
                } catch {
                    return ToolOutput(error.localizedDescription, isError: true)
                }
            })
            tools.append(DeskTool(name: "ssh_job_stop", description: "停掉远山上的一个后台任务。", parameters: ["type": "object", "properties": ["host": ["type": "string"], "job": ["type": "string"]], "required": ["host", "job"]], label: { "远山：停掉后台任务 \($0["job"]?.string ?? "")" }, approval: { arguments in
                ApprovalAsk(title: "停掉远山的后台任务", reason: "\(arguments["host"]?.string ?? "") · \(arguments["job"]?.string ?? "")")
            }) { arguments in
                guard let host = pick(arguments) else { return ToolOutput("没有这台主机。可用：\(names)", isError: true) }
                do {
                    try await Hills.stopJob(arguments["job"]?.string ?? "", on: host)
                    return ToolOutput("停掉了。")
                } catch {
                    return ToolOutput(error.localizedDescription, isError: true)
                }
            })
        }
        for server in servers where server.enabled {
            let token = Vault.load(String.self, key: "mcp.\(server.id)")
            // A name with no Latin letters or digits ("香港的浏览器") would slug to underscores only; the id keeps tools apart.
            let named = Self.slug(server.name)
            let slug = named.contains(where: { $0.isASCII && ($0.isLetter || $0.isNumber) }) ? named : "s" + String(server.id.prefix(6)).lowercased()
            for tool in borrowed where tool.server == server.id {
                let url = server.url
                let pin = server.pin
                let remote = tool.name
                let title = server.name
                tools.append(DeskTool(name: String("mcp_\(slug)__\(Self.slug(remote))".prefix(64)), description: "（来自远山 MCP「\(title)」）" + tool.description, parameters: tool.schema, label: { _ in "远山：\(title) · \(remote)" }) { arguments in
                    do {
                        return try await MCPClient(url: url, token: token, pin: pin).call(remote, arguments: arguments)
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
    var pin: String?

    private var session: URLSession { pin.map(PinnedSessions.session) ?? .shared }

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
        _ = try await session.data(for: try request(["jsonrpc": "2.0", "method": .string(method)]))
    }

    private func send(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        let id = Int.random(in: 1...999_999)
        let (bytes, response) = try await session.bytes(for: try request(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params]))
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


/// Remembers each server's key the first time, and refuses to go on if it ever changes.
final class HostKeyKeeper: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    let host: String
    let port: Int

    init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    static func slot(_ host: String, _ port: Int) -> String { "hostkey.\(host.lowercased()):\(port)" }

    /// What the user sees: SHA256 of the key, like `ssh-keygen -l` prints.
    static func fingerprint(_ openSSH: String) -> String {
        let parts = openSSH.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return openSSH }
        let digest = SHA256.hash(data: blob)
        return "SHA256:" + Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    static func known(_ host: String, _ port: Int) -> String? { UserDefaults.standard.string(forKey: slot(host, port)) }
    static func forget(_ host: String, _ port: Int) { UserDefaults.standard.removeObject(forKey: slot(host, port)) }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let seen = String(openSSHPublicKey: hostKey)
        let slot = Self.slot(host, port)
        if let known = UserDefaults.standard.string(forKey: slot) {
            if known == seen {
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(ProviderError("\(host) 的服务器指纹变了（以前 \(Self.fingerprint(known))，现在 \(Self.fingerprint(seen))）。可能是重装了系统，也可能有人在中间冒充。确认没问题后，到「远山」里点这台主机的「重新信任」。"))
            }
        } else {
            UserDefaults.standard.set(seen, forKey: slot)
            validationCompletePromise.succeed(())
        }
    }
}

/// SSH connections kept open for a while, so a run of commands logs in once.
actor HillPool {
    static let shared = HillPool()

    private var open: [String: (client: SSHClient, used: Date)] = [:]
    /// A connection left alone this long is closed and made again.
    private let idle: TimeInterval = 600

    func client(for host: Hills.Host, fresh: Bool) async throws -> SSHClient {
        if !fresh, let kept = open[host.id], kept.client.isConnected, Date().timeIntervalSince(kept.used) < idle {
            open[host.id] = (kept.client, Date())
            return kept.client
        }
        if let kept = open.removeValue(forKey: host.id) { try? await kept.client.close() }
        let client = try await Hills.connect(host)
        open[host.id] = (client, Date())
        return client
    }

    func touch(_ host: Hills.Host) {
        if let kept = open[host.id] { open[host.id] = (kept.client, Date()) }
    }

    func drop(_ host: Hills.Host) async {
        if let kept = open.removeValue(forKey: host.id) { try? await kept.client.close() }
    }

    func closeAll() async {
        for kept in open.values { try? await kept.client.close() }
        open = [:]
    }

    var count: Int { open.count }
}

/// Sessions that trust exactly one certificate, by its SHA-256: for the browser Clio set up on a 远山 computer with a certificate of its own.
/// The fingerprint was read over SSH, which already proved who the computer is.
enum PinnedSessions {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var made: [String: URLSession] = [:]

    static func session(_ pin: String) -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        if let kept = made[pin] { return kept }
        let session = URLSession(configuration: .ephemeral, delegate: Pinning(pin: pin), delegateQueue: nil)
        made[pin] = session
        return session
    }

    /// "AB:CD:…" or "abcd…" → "abcd…".
    static func normalize(_ fingerprint: String) -> String {
        let tail = fingerprint.split(separator: "=").last.map(String.init) ?? fingerprint
        return tail.lowercased().filter { $0.isHexDigit }
    }

    private final class Pinning: NSObject, URLSessionDelegate, @unchecked Sendable {
        let pin: String
        init(pin: String) { self.pin = PinnedSessions.normalize(pin) }

        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust,
                  let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                  let leaf = chain.first else {
                return (.performDefaultHandling, nil)
            }
            let digest = SHA256.hash(data: SecCertificateCopyData(leaf) as Data)
            let seen = digest.map { String(format: "%02x", $0) }.joined()
            return seen == pin ? (.useCredential, URLCredential(trust: trust)) : (.cancelAuthenticationChallenge, nil)
        }
    }
}
