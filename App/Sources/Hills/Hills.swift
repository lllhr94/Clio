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
        /// A 远山 host (its id) to reach the service through: `url` is then the address on that computer
        /// (http://127.0.0.1:8931/mcp), carried over an SSH tunnel, so nothing is open to the internet.
        var tunnelHost: String?
        /// Set up from the 连接器 page (`amap`, `github`…): shown by its own name, not as a 远山 service.
        var connector: String?
    }

    /// What an MCP server said it can do, kept so tools can be listed without a network call.
    struct Borrowed: Codable, Sendable {
        var server: String
        var name: String
        var description: String
        var schema: JSONValue
        /// The service says this tool only reads (MCP `readOnlyHint`).
        var readOnly: Bool?
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
        // Kept connections and tunnels were to the host as it was: close them, so the next command goes to the
        // address, account and password just saved (the review, #5).
        Self.forget(host)
    }

    func remove(_ host: Host) {
        Vault.remove("hill.\(host.id)")
        hosts.removeAll { $0.id == host.id }
        Disk.save(hosts, "hills.json")
        Self.forget(host)
    }

    private static func forget(_ host: Host) {
        Task {
            await HillPool.shared.drop(host)
            await Tunnels.shared.close(host: host.id)
        }
    }

    func host(named name: String) -> Host? {
        let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
        return hosts.first { $0.name.lowercased() == wanted } ?? hosts.first { $0.address.lowercased() == wanted } ?? (hosts.count == 1 && wanted.isEmpty ? hosts.first : nil)
    }

    /// The phone's own SSH key, made once. Its public half goes into a server's ~/.ssh/authorized_keys.
    private nonisolated static let keyCreation = NSLock()

    nonisolated static var key: Curve25519.Signing.PrivateKey {
        keyCreation.lock()
        defer { keyCreation.unlock() }
        if let raw = Vault.load(Data.self, key: "hill.key"), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) { return key }
        let key = Curve25519.Signing.PrivateKey()
        Vault.save(key.rawRepresentation, as: "hill.key")
        return key
    }

    /// Worked out once: it is drawn on every redraw of the 远山 page.
    nonisolated static let publicKey: String = {
        func field(_ bytes: Data) -> Data {
            var length = UInt32(bytes.count).bigEndian
            return Data(bytes: &length, count: 4) + bytes
        }
        let blob = field(Data("ssh-ed25519".utf8)) + field(key.publicKey.rawRepresentation)
        return "ssh-ed25519 " + blob.base64EncodedString() + " clio@iphone"
    }()

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

    /// A command ran past its time.
    struct TimedOut: LocalizedError {
        let seconds: Int
        /// What it printed before the time ran out: handed back, so the model knows how far it got (Open Minis).
        var output: String = ""
        var errorDescription: String? { "超过 \(seconds) 秒没跑完。长任务可以放到后台跑。" }
    }

    /// How much of a command's output is kept, in bytes.
    nonisolated static let keptOutput = 200_000

    /// Output gathered while a command runs, readable by the timer that may cut it short.
    private final class Gathered: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        private var size = 0
        private let limit: Int
        init(limit: Int) { self.limit = limit }
        func add(_ piece: String) { lock.withLock { if size < limit { text += piece; size += piece.utf8.count } } }
        var value: String { lock.withLock { text } }
    }

    /// Runs one command on a kept connection. A connection that has dropped is made again, up to twice;
    /// a command that already started is never sent a second time. `onOutput` hears the output as it arrives.
    nonisolated static func run(_ command: String, on host: Host, timeout: Double = 60, keep: Int = keptOutput, onOutput: (@Sendable (String) -> Void)? = nil) async throws -> Outcome {
        var attempt = 0
        while true {
            do {
                return try await runOnce(command, on: host, timeout: timeout, keep: keep, fresh: attempt > 0, onOutput: onOutput)
            } catch is Stale {
                attempt += 1
                await HillPool.shared.drop(host)
                if attempt > 2 { throw ProviderError("连上了 \(host.name)，但重连两次都开不了会话。") }
                Diag.note("远山 \(host.name) 掉线，第 \(attempt) 次重连")
            }
        }
    }

    private nonisolated static func runOnce(_ command: String, on host: Host, timeout: Double, keep: Int, fresh: Bool, onOutput: (@Sendable (String) -> Void)?) async throws -> Outcome {
        let gathered = Gathered(limit: keep)
        return try await withThrowingTaskGroup(of: Outcome.self) { group in
            group.addTask {
                // A failure to log in is a real answer (wrong password, host down), never retried; only a kept connection
                // that will not open a channel any more counts as stale.
                let client = try await HillPool.shared.client(for: host, fresh: fresh)
                var output = ""
                var size = 0
                var dropped = 0
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
                            let piece = String(buffer: buffer)
                            // Past the limit the output is no longer kept, but the stream is still read to its end,
                            // so the command's real exit status comes back (the review, #8).
                            if size < keep {
                                output += piece
                                gathered.add(piece)
                            } else {
                                dropped += piece.utf8.count
                            }
                            size += piece.utf8.count
                            if let onOutput {
                                for line in piece.split(separator: "\n", omittingEmptySubsequences: true) { onOutput(String(line)) }
                            }
                        }
                    }
                } catch let failed as SSHClient.CommandFailed {
                    code = failed.exitCode
                }
                await HillPool.shared.touch(host)
                if dropped > 0 {
                    output += "\n……（输出太长，后面约 \(ByteCountFormatter.string(fromByteCount: Int64(dropped), countStyle: .file)) 没有留下；命令已经跑完）"
                }
                return Outcome(code: code, output: output)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw TimedOut(seconds: Int(timeout), output: gathered.value)
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

    /// Where Playwright's MCP listens on the far computer: its own loopback only, reached through an SSH tunnel.
    nonisolated static let browserAddress = "http://127.0.0.1:8931/mcp"

    /// The command a person can paste on their server to start the same browser by hand.
    nonisolated static let browserCommand = "npx @playwright/mcp@latest --headless --host 127.0.0.1 --port 8931"

    /// Installs Playwright's MCP server on a Linux host and starts it on 127.0.0.1:8931, again after every reboot.
    /// Nothing listens on a public address. Runs as a background job.
    nonisolated static func browserInstallScript() -> String {
        let start = """
        cd ~/.clio/browser
        [ -f mcp.pid ] && kill $(cat mcp.pid) 2>/dev/null
        [ -f gate.pid ] && kill $(cat gate.pid) 2>/dev/null && rm -f gate.pid proxy.js token key.pem cert.pem
        nohup ./node_modules/.bin/mcp-server-playwright --headless --isolated --host 127.0.0.1 --port 8931 > mcp.log 2>&1 < /dev/null &
        echo $! > mcp.pid
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
        cat > start.sh <<'CLIO_EOF'
        \(start)
        CLIO_EOF
        sh start.sh
        if command -v crontab >/dev/null 2>&1; then
          (crontab -l 2>/dev/null | grep -v 'clio-browser'; echo "@reboot sh $HOME/.clio/browser/start.sh # clio-browser") | crontab - || true
        fi
        sleep 3
        echo "== 好了，浏览器在这台机器的 127.0.0.1:8931，只有经 SSH 才连得上"
        """
    }

    // MARK: MCP servers

    func save(_ server: Server, token: String?) {
        if let index = servers.firstIndex(where: { $0.id == server.id }) { servers[index] = server } else { servers.append(server) }
        if let token { Vault.save(token, as: "mcp.\(server.id)") }
        Disk.save(servers, "mcp.json")
    }

    func remove(_ server: Server) {
        MCPAuth.forget(server.id)
        Vault.remove("mcp.\(server.id)")
        servers.removeAll { $0.id == server.id }
        borrowed.removeAll { $0.server == server.id }
        Disk.save(servers, "mcp.json")
        Disk.save(borrowed, "mcp-tools.json")
    }

    /// Asks a server for its tools again. Returns how many it offered.
    @discardableResult
    func refresh(_ server: Server) async -> Int {
        do {
            let tunnelHost: Host?
            if let tunnelHostId = server.tunnelHost {
                guard let found = hosts.first(where: { $0.id == tunnelHostId }) else {
                    throw ProviderError(Words.t("找不到隧道依赖的远山主机，请重新选择。"))
                }
                tunnelHost = found
            } else {
                tunnelHost = nil
            }
            let address = try await Self.address(server.url, through: tunnelHost)
            let isTunneled = tunnelHost != nil
            let tools = try await Self.withCredential(server.id) { token in
                try await MCPClient(url: address, token: token, tunneled: isTunneled).listTools()
            }
            borrowed.removeAll { $0.server == server.id }
            borrowed += tools.map { Borrowed(server: server.id, name: $0.name, description: $0.description, schema: $0.schema, readOnly: $0.readOnly) }
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
        let snapshotHosts = hosts
        if !hosts.isEmpty {
            let names = hosts.map { "\($0.name)（\($0.user)@\($0.address)）" }.joined(separator: "、")
            let snapshot = hosts
            tools.append(DeskTool(name: "ssh_run", description: Words.t("在用户的远程主机（远山）上用 SSH 跑一条命令。可用的主机：\(names)。命令要能自己结束，不要开交互程序。"), parameters: ["type": "object", "properties": ["host": ["type": "string", "description": "主机名字"], "command": ["type": "string"], "timeout": ["type": "number", "description": "最多等几秒，默认 60，最多 600"]], "required": ["host", "command"]], label: { Words.t("远山：\($0["host"]?.string ?? "") · \(($0["command"]?.string ?? "").prefix(30))") }) { arguments in
                let wanted = (arguments["host"]?.string ?? "").lowercased()
                guard let host = snapshot.first(where: { $0.name.lowercased() == wanted || $0.address.lowercased() == wanted }) ?? (snapshot.count == 1 ? snapshot.first : nil) else {
                    return ToolOutput("没有叫「\(arguments["host"]?.string ?? "")」的主机。可用：\(names)", isError: true)
                }
                do {
                    let result = try await Hills.run(arguments["command"]?.string ?? "", on: host, timeout: min(600, max(5, arguments["timeout"]?.number ?? 60)))
                    let text = Shell.maskedClip(result.output, secrets: Vault.allStrings())
                    return ToolOutput((text.isEmpty ? "（没有输出）" : text) + (result.code == 0 ? "" : "\n（退出码 \(result.code)）"), isError: result.code != 0)
                } catch {
                    return ToolOutput("连 \(host.name) 出错：\(error.localizedDescription)", isError: true)
                }
            })
            let pick: @Sendable (JSONValue) -> Host? = { arguments in
                let wanted = (arguments["host"]?.string ?? "").lowercased()
                return snapshot.first(where: { $0.name.lowercased() == wanted || $0.address.lowercased() == wanted }) ?? (snapshot.count == 1 ? snapshot.first : nil)
            }
            tools.append(DeskTool(name: "ssh_job_start", description: Words.t("在远山主机上把一条要跑很久的命令放到后台（编译、下载、训练、装软件）。连接断了它也接着跑。返回一个任务编号，之后用 ssh_job_check 看进度。"), parameters: ["type": "object", "properties": ["host": ["type": "string", "description": "主机名字"], "command": ["type": "string"]], "required": ["host", "command"]], label: { Words.t("远山：后台跑 \(($0["command"]?.string ?? "").prefix(30))") }) { arguments in
                guard let host = pick(arguments) else { return ToolOutput("没有这台主机。可用：\(names)", isError: true) }
                do {
                    let id = try await Hills.startJob(arguments["command"]?.string ?? "", on: host)
                    return ToolOutput("开始了，任务编号 \(id)。输出记在 \(host.name) 的 ~/.clio/jobs/\(id).log。过一会儿用 ssh_job_check 看。")
                } catch {
                    return ToolOutput("没能开始：\(error.localizedDescription)", isError: true)
                }
            })
            tools.append(DeskTool(name: "ssh_job_check", description: Words.t("看远山后台任务的进度：还在不在跑、退出码、最后几十行输出。"), parameters: ["type": "object", "properties": ["host": ["type": "string"], "job": ["type": "string", "description": "ssh_job_start 给的编号"], "lines": ["type": "number", "description": "看最后几行，默认 40"]], "required": ["host", "job"]], label: { Words.t("远山：看后台任务 \($0["job"]?.string ?? "")") }) { arguments in
                guard let host = pick(arguments) else { return ToolOutput("没有这台主机。可用：\(names)", isError: true) }
                do {
                    let state = try await Hills.checkJob(arguments["job"]?.string ?? "", on: host, lines: min(400, max(5, (arguments["lines"]?.int ?? 40))))
                    let head = state.running ? "还在跑。" : "跑完了，退出码 \(state.exit.map(String.init) ?? "不明")。"
                    return ToolOutput(head + "\n最后的输出：\n" + (state.tail.isEmpty ? "（还没有输出）" : Shell.maskedClip(state.tail, secrets: Vault.allStrings())))
                } catch {
                    return ToolOutput(error.localizedDescription, isError: true)
                }
            })
            tools.append(DeskTool(name: "ssh_job_stop", description: Words.t("停掉远山上的一个后台任务。"), parameters: ["type": "object", "properties": ["host": ["type": "string"], "job": ["type": "string"]], "required": ["host", "job"]], label: { Words.t("远山：停掉后台任务 \($0["job"]?.string ?? "")") }, approval: { arguments in
                ApprovalAsk(title: Words.t("停掉远山的后台任务"), reason: "\(arguments["host"]?.string ?? "") · \(arguments["job"]?.string ?? "")")
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
            let serverId = server.id
            // A name with no Latin letters or digits ("香港的浏览器") would slug to underscores only; the id keeps tools apart.
            let named = Self.slug(server.name)
            let slug = named.contains(where: { $0.isASCII && ($0.isLetter || $0.isNumber) }) ? named : "s" + String(server.id.prefix(6)).lowercased()
            let tunnelHostId = server.tunnelHost
            for tool in borrowed where tool.server == server.id {
                let url = server.url
                let remote = tool.name
                let title = server.name
                let shown = server.connector == nil ? Words.t("远山：\(title) · \(remote)") : "\(title)：\(remote)"
                // Every MCP service (connector or remote) asks before running any tool not marked read-only.
                let asks = tool.readOnly != true
                let what = String(tool.description.prefix(80))
                let reason = what.isEmpty ? "可能会改动「\(title)」里的东西" : what
                let askTitle = "\(title)：\(remote)"
                var ask: (@Sendable (JSONValue) -> ApprovalAsk?)?
                if asks {
                    ask = { (arguments: JSONValue) -> ApprovalAsk? in
                        let compact = arguments.compact
                        return ApprovalAsk(title: askTitle, reason: reason, detail: nil, code: compact == "{}" || compact == "null" ? nil : compact)
                    }
                }
                let toolName = String("mcp_\(server.connector ?? slug)__\(Self.slug(remote))".prefix(64))
                let where_ = server.connector == nil ? Words.t("远山 MCP") : Words.t("连接器")
                tools.append(DeskTool(name: toolName, description: "（来自\(where_)「\(title)」）" + tool.description, parameters: tool.schema, label: { _ in shown }, approval: ask) { arguments in
                    do {
                        let tunnelHost: Host?
                        if let tunnelHostId {
                            guard let found = snapshotHosts.first(where: { $0.id == tunnelHostId }) else {
                                throw ProviderError(Words.t("找不到隧道依赖的远山主机，请重新选择。"))
                            }
                            tunnelHost = found
                        } else {
                            tunnelHost = nil
                        }
                        let address = try await Hills.address(url, through: tunnelHost)
                        let isTunneled = tunnelHost != nil
                        return try await Hills.withCredential(serverId) { token in
                            try await MCPClient(url: address, token: token, tunneled: isTunneled).call(remote, arguments: arguments)
                        }
                    } catch {
                        return ToolOutput("「\(title)」出错：\(error.localizedDescription)", isError: true)
                    }
                })
            }
        }
        return tools
    }

    /// Runs a request with the service's credential: the token from its sign-in (renewed and tried once more
    /// after a 401), or the key or token pasted for it.
    nonisolated static func withCredential<T: Sendable>(_ id: String, _ work: @Sendable (String?) async throws -> T) async throws -> T {
        if let bearer = try await MCPAuth.bearer(id) {
            do {
                return try await work(bearer)
            } catch MCPClient.MCPError.http(let code, _) where code == 401 {
                return try await work(try await MCPAuth.bearer(id, stale: true))
            }
        }
        let saved = Vault.load(String.self, key: "mcp.\(id)")
        // Google's own MCP services: the token from the Google sign-in in 连接器.
        if saved == Hills.googleToken {
            do {
                return try await work(try await Google.access())
            } catch MCPClient.MCPError.http(let code, _) where code == 401 {
                return try await work(try await Google.access(stale: true))
            }
        }
        return try await work(saved)
    }

    /// Stands in, in the Vault, for "use the Google sign-in" on Google's MCP services.
    nonisolated static let googleToken = "google:signin"

    /// Where to send a service's requests: its own address, or the phone's end of an SSH tunnel to it.
    nonisolated static func address(_ url: String, through host: Host?) async throws -> String {
        guard let host else { return url }
        return try await Tunnels.shared.url(for: url, through: host)
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
    var tunneled: Bool = false

    private var session: URLSession { .shared }

    struct Tool: Sendable {
        var name: String
        var description: String
        var schema: JSONValue
        var readOnly: Bool?
    }

    private static let sessions = SessionBook()
    /// The most one answer may be.
    static let most = 12_000_000

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
                tools.append(Tool(name: name, description: item["description"]?.string ?? "", schema: item["inputSchema"] ?? ["type": "object", "properties": [:]],
                                  readOnly: item["annotations"]?["readOnlyHint"]?.bool))
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

    private func request(_ body: JSONValue) async throws -> (URLRequest, URLSessionTaskDelegate) {
        // A token starting with 「?」 goes into the address (高德's `?key=…`), not into a header.
        var address = url
        if let token, token.hasPrefix("?") { address += (url.contains("?") ? "&" : "?") + token.dropFirst() }
        guard let target = URL(string: address) else { throw MCPError.rpc("地址不对：\(url)") }
        let hasCredentials = token != nil && !(token?.isEmpty ?? true)
        if tunneled {
            let scheme = target.scheme?.lowercased()
            let host = target.host?.lowercased()
            guard (scheme == "http" || scheme == "https"),
                  (host == "127.0.0.1" || host == "localhost"),
                  target.port != nil else {
                throw MCPError.rpc("隧道本地地址不合法：\(url)")
            }
        } else {
            guard target.scheme?.lowercased() == "https",
                  let host = target.host, !host.isEmpty else {
                throw MCPError.rpc(Words.t("未开启远山隧道时，MCP 服务必须使用 https 公网地址。"))
            }
            var isLocalTarget = LocalAddress.isLocal(target)
            if !isLocalTarget {
                isLocalTarget = await LocalAddress.resolvesToLocal(target)
            }
            if isLocalTarget {
                throw MCPError.rpc(Words.t("MCP 服务地址指向本机或局域网，已拒绝。若在远程机器内网，请开启远山 SSH 隧道。"))
            }
        }
        var request = URLRequest(url: target, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
        if let token, !token.isEmpty, !token.hasPrefix("?") { request.setValue(token.lowercased().hasPrefix("bearer ") ? token : "Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let session = Self.sessions.get(url) { request.setValue(session, forHTTPHeaderField: "Mcp-Session-Id") }
        request.httpBody = Data(body.compact.utf8)
        let delegate = MCPRedirectDelegate(origin: target, tunneled: tunneled, hasCredentials: hasCredentials)
        return (request, delegate)
    }

    private func notify(_ method: String) async throws {
        let (req, delegate) = try await request(["jsonrpc": "2.0", "method": .string(method)])
        _ = try await session.data(for: req, delegate: delegate)
    }

    private func send(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        let id = Int.random(in: 1...999_999)
        let (req, delegate) = try await request(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params])
        let (bytes, response) = try await session.bytes(for: req, delegate: delegate)
        let http = response as? HTTPURLResponse
        if let session = http?.value(forHTTPHeaderField: "Mcp-Session-Id") { Self.sessions.set(url, session) }
        let status = http?.statusCode ?? 0
        if status == 404, Self.sessions.get(url) != nil, method != "initialize" { throw MCPError.sessionGone }
        if (300..<400).contains(status) {
            throw MCPError.rpc("服务器试图跳转到不安全或其他地址，已拒绝。")
        }
        if !(200..<300).contains(status) {
            var body = ""
            for try await line in bytes.lines { body += line; if body.count > 400 { break } }
            throw MCPError.http(status, body)
        }
        let type = http?.value(forHTTPHeaderField: "Content-Type") ?? ""
        if type.contains("text/event-stream") {
            var data = ""
            var read = 0
            for try await line in bytes.lines {
                // A service that keeps sending without ever answering, or answers with far too much, is cut off.
                read += line.utf8.count
                if read > Self.most { throw MCPError.rpc("服务器回的东西太多了（超过 \(Self.most / 1_000_000) MB），没收完。") }
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
        for try await byte in bytes {
            raw.append(byte)
            if raw.count > Self.most { throw MCPError.rpc("服务器回的东西太多了（超过 \(Self.most / 1_000_000) MB），没收完。") }
        }
        guard let message = JSONValue.parse(String(decoding: raw, as: UTF8.self)) else { throw MCPError.rpc("看不懂服务器的回复。") }
        if let list = message.array, let match = list.first(where: { $0["id"]?.number == Double(id) }) { return try unwrap(match) }
        return try unwrap(message)
    }

    private func unwrap(_ message: JSONValue) throws -> JSONValue {
        if let error = message["error"] { throw MCPError.rpc(error["message"]?.string ?? error.compact) }
        return message["result"] ?? [:]
    }
}

private final class MCPRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let origin: URL
    let tunneled: Bool
    let hasCredentials: Bool

    init(origin: URL, tunneled: Bool, hasCredentials: Bool) {
        self.origin = origin
        self.tunneled = tunneled
        self.hasCredentials = hasCredentials
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let next = request.url, next.user == nil, next.password == nil else {
            return nil
        }
        if tunneled {
            let originScheme = origin.scheme?.lowercased() ?? "http"
            let nextScheme = next.scheme?.lowercased() ?? ""
            guard nextScheme == "http" || nextScheme == "https" else { return nil }
            if originScheme == "https" && nextScheme != "https" { return nil }
            let nextHost = next.host?.lowercased()
            guard (nextHost == "127.0.0.1" || nextHost == "localhost"),
                  next.port == origin.port else {
                return nil
            }
            return request
        }
        guard next.scheme?.lowercased() == "https",
              let nextHost = next.host?.lowercased(), !nextHost.isEmpty,
              !LocalAddress.isLocal(next) else {
            return nil
        }
        if hasCredentials {
            guard origin.host?.lowercased() == nextHost,
                  (origin.port ?? 443) == (next.port ?? 443) else {
                return nil
            }
        }
        if await LocalAddress.resolvesToLocal(next) {
            return nil
        }
        return request
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
                validationCompletePromise.fail(ProviderError(Words.t("\(host) 的服务器指纹变了（以前 \(Self.fingerprint(known))，现在 \(Self.fingerprint(seen))）。可能是重装了系统，也可能有人在中间冒充。确认没问题后，到「远山」里点这台主机的「重新信任」。")))
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

    /// Each kept connection with who it was made to; a host edited since gets a new one.
    private var open: [String: (client: SSHClient, used: Date, to: String)] = [:]
    private var connecting: [String: (to: String, gen: UInt64, task: Task<SSHClient, Error>)] = [:]
    private var generation: [String: UInt64] = [:]

    private static func identity(_ host: Hills.Host) -> String { "\(host.user)@\(host.address):\(host.port) key=\(host.useKey)" }
    /// A connection left alone this long is closed and made again.
    private let idle: TimeInterval = 600

    func client(for host: Hills.Host, fresh: Bool) async throws -> SSHClient {
        let to = Self.identity(host)
        let currentGen = generation[host.id, default: 0]
        if !fresh, let kept = open[host.id], kept.to == to, kept.client.isConnected, Date().timeIntervalSince(kept.used) < idle {
            open[host.id] = (kept.client, Date(), to)
            return kept.client
        }
        if !fresh, let inFlight = connecting[host.id], inFlight.to == to, inFlight.gen == currentGen {
            return try await inFlight.task.value
        }
        let nextGen = currentGen &+ 1
        generation[host.id] = nextGen
        if let oldTask = connecting.removeValue(forKey: host.id) {
            oldTask.task.cancel()
        }
        if let kept = open.removeValue(forKey: host.id) {
            let oldClient = kept.client
            Task { try? await oldClient.close() }
        }
        let hostId = host.id
        let task = Task<SSHClient, Error> {
            do {
                let connected = try await Hills.connect(host)
                return try await self.finishConnect(hostId: hostId, to: to, gen: nextGen, client: connected)
            } catch {
                await self.clearConnecting(hostId: hostId, gen: nextGen)
                throw error
            }
        }
        connecting[host.id] = (to, nextGen, task)
        return try await task.value
    }

    private func finishConnect(hostId: String, to: String, gen: UInt64, client: SSHClient) async throws -> SSHClient {
        if connecting[hostId]?.gen == gen {
            connecting.removeValue(forKey: hostId)
        }
        guard generation[hostId, default: 0] == gen else {
            try? await client.close()
            throw CancellationError()
        }
        if let replaced = open.removeValue(forKey: hostId), replaced.client !== client {
            let oldClient = replaced.client
            Task { try? await oldClient.close() }
        }
        open[hostId] = (client, Date(), to)
        return client
    }

    private func clearConnecting(hostId: String, gen: UInt64) {
        if connecting[hostId]?.gen == gen {
            connecting.removeValue(forKey: hostId)
        }
    }

    func touch(_ host: Hills.Host) {
        if let kept = open[host.id] { open[host.id] = (kept.client, Date(), kept.to) }
    }

    func drop(_ host: Hills.Host) async {
        generation[host.id] = generation[host.id, default: 0] &+ 1
        if let inFlight = connecting.removeValue(forKey: host.id) {
            inFlight.task.cancel()
        }
        if let kept = open.removeValue(forKey: host.id) {
            try? await kept.client.close()
        }
    }

    func closeAll() async {
        for key in Set(open.keys).union(connecting.keys) {
            generation[key] = generation[key, default: 0] &+ 1
        }
        for inFlight in connecting.values {
            inFlight.task.cancel()
        }
        connecting = [:]
        let clients = open.values.map(\.client)
        open = [:]
        for client in clients {
            try? await client.close()
        }
    }

    var count: Int { open.count }
}
