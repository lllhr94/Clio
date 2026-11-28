import Craft
import Foundation
import Network
import Security

/// Pure-Swift in-process local proxy hub (SOCKS5 + HTTP CONNECT) bound strictly to `127.0.0.1`.
/// Starts lazily ONLY when at least one active route targets an upstream proxy, and shuts down
/// completely when all routes are direct or the master routing switch is off.
final class ClioNetHub: @unchecked Sendable {
    struct EntryEndpoints: Equatable, Sendable {
        let socksPort: UInt16
        let httpPort: UInt16
        let password: String
    }

    struct DiagnosticItem: Identifiable, Equatable, Sendable {
        enum Status: String, Sendable { case ok, warn, fail, skip }
        let id = UUID()
        let name: String
        let status: Status
        let detail: String
        let elapsedMs: Int
    }

    private let queue = DispatchQueue(label: "clio.nethub.io", qos: .userInitiated, attributes: .concurrent)
    private let stateLock = NSLock()

    private var settings: NetworkRoutingSettings = .default
    private let passwordProvider: @Sendable (String) -> String?
    private let entryPassword: String

    private var socksListener: NWListener?
    private var httpListener: NWListener?
    private var activeSocksPort: UInt16 = 0
    private var activeHttpPort: UInt16 = 0
    private var connectionSeq: UInt64 = 0

    // Consecutive failure tracking per proxy ID (3 consecutive failures raises alert; first success clears).
    private var failureStreaks: [String: Int] = [:]
    private var alertedProxies: Set<String> = []
    private var onAlertChange: (@Sendable (String?) -> Void)?
    private var onLog: (@Sendable (String) -> Void)?

    init(
        passwordProvider: @escaping @Sendable (String) -> String? = { proxyID in
            Vault.load(String.self, key: "net.proxy.\(proxyID.uppercased())")
        },
        onAlertChange: (@Sendable (String?) -> Void)? = nil,
        onLog: (@Sendable (String) -> Void)? = nil
    ) {
        self.passwordProvider = passwordProvider
        self.entryPassword = Self.generateRandomPassword()
        self.onAlertChange = onAlertChange
        self.onLog = onLog
    }

    var currentEntryPassword: String { entryPassword }

    var activeEndpoints: EntryEndpoints? {
        stateLock.withLock {
            guard activeSocksPort > 0, activeHttpPort > 0 else { return nil }
            return EntryEndpoints(socksPort: activeSocksPort, httpPort: activeHttpPort, password: entryPassword)
        }
    }

    func apply(settings newSettings: NetworkRoutingSettings) async -> EntryEndpoints? {
        let shouldRun = newSettings.needsLocalEntry
        stateLock.withLock {
            self.settings = newSettings
            // Clear alerts for removed proxies.
            let validIDs = Set(newSettings.proxies.map { $0.id.uppercased() })
            self.failureStreaks = self.failureStreaks.filter { validIDs.contains($0.key) }
            self.alertedProxies = self.alertedProxies.intersection(validIDs)
        }
        publishAlertState()

        if !shouldRun {
            stop()
            emitLog("[Net] applied routing=\(newSettings.routingEnabled ? "on" : "OFF") entry=off default=\(newSettings.defaultRoute.rawValue) proxies=\(newSettings.proxies.count)")
            return nil
        }

        if let existing = activeEndpoints {
            emitLog("[Net] applied routing=on entry=socks:\(existing.socksPort),http:\(existing.httpPort) default=\(newSettings.defaultRoute.rawValue) proxies=\(newSettings.proxies.count)")
            return existing
        }

        do {
            let endpoints = try await startListeners()
            emitLog("[Net] applied routing=on entry=socks:\(endpoints.socksPort),http:\(endpoints.httpPort) default=\(newSettings.defaultRoute.rawValue) proxies=\(newSettings.proxies.count)")
            return endpoints
        } catch {
            emitLog("[Net][Entry] failed to start local entry: \(error.localizedDescription)")
            stop()
            return nil
        }
    }

    func stop() {
        let (s, h): (NWListener?, NWListener?) = stateLock.withLock {
            let oldS = socksListener
            let oldH = httpListener
            socksListener = nil
            httpListener = nil
            activeSocksPort = 0
            activeHttpPort = 0
            return (oldS, oldH)
        }
        s?.cancel()
        h?.cancel()
    }

    // MARK: Listener Startup

    private func startListeners() async throws -> EntryEndpoints {
        let socks = try makeLoopbackListener()
        let http = try makeLoopbackListener()

        socks.newConnectionHandler = { [weak self] conn in
            self?.handleSocksConnection(conn)
        }
        http.newConnectionHandler = { [weak self] conn in
            self?.handleHTTPConnection(conn)
        }

        async let socksPort = waitReady(socks)
        async let httpPort = waitReady(http)
        let (sp, hp) = try await (socksPort, httpPort)

        let previous: (NWListener?, NWListener?) = stateLock.withLock {
            let prev = (socksListener, httpListener)
            socksListener = socks
            httpListener = http
            activeSocksPort = sp
            activeHttpPort = hp
            return prev
        }
        previous.0?.cancel()
        previous.1?.cancel()
        return EntryEndpoints(socksPort: sp, httpPort: hp, password: entryPassword)
    }

    private func makeLoopbackListener() throws -> NWListener {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        return try NWListener(using: params)
    }

    private func waitReady(_ listener: NWListener) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            let done = OnceFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue, port > 0 {
                        if done.claim() { continuation.resume(returning: port) }
                    } else if done.claim() {
                        continuation.resume(throwing: NetHubError.listenerFailed("本地监听端口未分配"))
                    }
                case .failed(let err):
                    if done.claim() { continuation.resume(throwing: err) }
                case .cancelled:
                    if done.claim() { continuation.resume(throwing: NetHubError.listenerFailed("本地监听已取消")) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    // MARK: SOCKS5 Entry (RFC 1928 + RFC 1929)

    private func handleSocksConnection(_ client: NWConnection) {
        let connID = nextConnectionID()
        client.start(queue: queue)
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { client.cancel(); return }
            await self.serveSocks(client: client, connID: connID)
        }
    }

    private func serveSocks(client: NWConnection, connID: String) async {
        let reader = BufferedConnection(connection: client)
        do {
            // 1. Greeting: VER(1) NMETHODS(1) METHODS(NMETHODS)
            let head = try await reader.readExact(2)
            guard head[0] == 0x05 else { client.cancel(); return }
            let nMethods = Int(head[1])
            let methods = try await reader.readExact(nMethods)
            guard methods.contains(0x02) else {
                try? await reader.write(Data([0x05, 0xFF]))
                emitLog("[Net][Entry] \(connID) socks rejected: no auth offered")
                client.cancel()
                return
            }
            try await reader.write(Data([0x05, 0x02]))

            // 2. RFC 1929 Username/Password Auth
            let authHead = try await reader.readExact(2)
            guard authHead[0] == 0x01 else {
                try? await reader.write(Data([0x01, 0x01]))
                client.cancel()
                return
            }
            let uLen = Int(authHead[1])
            let uBytes = try await reader.readExact(uLen)
            let pLenData = try await reader.readExact(1)
            let pBytes = try await reader.readExact(Int(pLenData[0]))
            let username = String(decoding: uBytes, as: UTF8.self)
            let password = String(decoding: pBytes, as: UTF8.self)

            guard Self.constantTimeEqual(password, entryPassword),
                  let scope = Self.parseTagScope(username) else {
                try? await reader.write(Data([0x01, 0x01]))
                emitLog("[Net][Entry] \(connID) socks rejected: wrong entry password or unknown tag")
                client.cancel()
                return
            }
            try await reader.write(Data([0x01, 0x00]))

            // 3. Request: VER(1) CMD(1) RSV(1) ATYP(1) DST.ADDR DST.PORT(2)
            let reqHead = try await reader.readExact(4)
            guard reqHead[0] == 0x05 else { client.cancel(); return }
            guard reqHead[1] == 0x01 else {
                try? await reader.write(Data([0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
                client.cancel()
                return
            }
            let targetHost: String
            switch reqHead[3] {
            case 0x01:
                let b = try await reader.readExact(4)
                targetHost = "\(b[0]).\(b[1]).\(b[2]).\(b[3])"
            case 0x03:
                let lenB = try await reader.readExact(1)
                let hostBytes = try await reader.readExact(Int(lenB[0]))
                targetHost = String(decoding: hostBytes, as: UTF8.self)
            case 0x04:
                let b = try await reader.readExact(16)
                targetHost = Self.formatIPv6(b)
            default:
                try? await reader.write(Data([0x05, 0x08, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
                client.cancel()
                return
            }
            let portBytes = try await reader.readExact(2)
            let targetPort = (UInt16(portBytes[0]) << 8) | UInt16(portBytes[1])
            guard targetPort > 0 else {
                try? await reader.write(Data([0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
                client.cancel()
                return
            }

            let decision = decide(scope: scope, host: targetHost)
            let started = ContinuousClock.now
            do {
                let (upstream, upstreamEarly) = try await dial(decision: decision, targetHost: targetHost, targetPort: targetPort)
                if case .proxy(let profile) = decision.kind {
                    recordSuccess(proxyID: profile.id, name: profile.displayName)
                }
                try await reader.write(Data([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
                if !upstreamEarly.isEmpty {
                    try await reader.write(upstreamEarly)
                }
                let clientEarly = reader.drainBuffer()
                if !clientEarly.isEmpty {
                    try await Self.sendData(clientEarly, on: upstream)
                }
                await relay(client: client, upstream: upstream)
            } catch {
                let elapsed = Self.elapsedMs(since: started)
                if case .proxy(let profile) = decision.kind {
                    recordFailure(proxyID: profile.id, name: profile.displayName, detail: error.localizedDescription)
                }
                emitLog("[Net][Dial] \(connID) FAIL via=\(decision.exitLabel) target=\(targetHost):\(targetPort) after \(elapsed)ms tag=\(scope.tag): \(error.localizedDescription)")
                try? await reader.write(Data([0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
                client.cancel()
            }
        } catch {
            client.cancel()
        }
    }

    // MARK: HTTP CONNECT / Plain-HTTP Entry

    private func handleHTTPConnection(_ client: NWConnection) {
        let connID = nextConnectionID()
        client.start(queue: queue)
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { client.cancel(); return }
            await self.serveHTTP(client: client, connID: connID)
        }
    }

    private func serveHTTP(client: NWConnection, connID: String) async {
        let reader = BufferedConnection(connection: client)
        do {
            let headData = try await reader.readUntilCRLFCRLF(maxBytes: 32_768)
            let headString = String(decoding: headData, as: UTF8.self)
            let lines = headString.components(separatedBy: "\r\n")
            guard let requestLine = lines.first else { client.cancel(); return }
            let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3 else { client.cancel(); return }
            let method = String(parts[0])
            let target = String(parts[1])
            let version = String(parts[2])

            // Authenticate via Proxy-Authorization: Basic <base64(tag:password)>
            var authHeader: String?
            for line in lines.dropFirst() where !line.isEmpty {
                if let colon = line.firstIndex(of: ":") {
                    let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                    if name == "proxy-authorization" {
                        authHeader = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                        break
                    }
                }
            }
            guard let scope = authenticateBasicHeader(authHeader) else {
                let deny = "HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"Clio\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                try? await reader.write(Data(deny.utf8))
                emitLog("[Net][Entry] \(connID) http rejected: missing or wrong Proxy-Authorization")
                client.cancel()
                return
            }

            if method.uppercased() == "CONNECT" {
                guard let (host, port) = Self.parseAuthority(target, defaultPort: 443) else {
                    try? await reader.write(Data("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
                    client.cancel()
                    return
                }
                let decision = decide(scope: scope, host: host)
                let started = ContinuousClock.now
                do {
                    let (upstream, upstreamEarly) = try await dial(decision: decision, targetHost: host, targetPort: port)
                    if case .proxy(let profile) = decision.kind {
                        recordSuccess(proxyID: profile.id, name: profile.displayName)
                    }
                    try await reader.write(Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))
                    if !upstreamEarly.isEmpty {
                        try await reader.write(upstreamEarly)
                    }
                    let clientEarly = reader.drainBuffer()
                    if !clientEarly.isEmpty {
                        try await Self.sendData(clientEarly, on: upstream)
                    }
                    await relay(client: client, upstream: upstream)
                } catch {
                    let elapsed = Self.elapsedMs(since: started)
                    if case .proxy(let profile) = decision.kind {
                        recordFailure(proxyID: profile.id, name: profile.displayName, detail: error.localizedDescription)
                    }
                    emitLog("[Net][Dial] \(connID) FAIL CONNECT via=\(decision.exitLabel) target=\(host):\(port) after \(elapsed)ms tag=\(scope.tag): \(error.localizedDescription)")
                    try? await reader.write(Data("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
                    client.cancel()
                }
                return
            }

            // Plain HTTP proxy request (e.g. BusyBox wget / apk / http:// URLs)
            guard let url = URL(string: target), let host = url.host, !host.isEmpty else {
                try? await reader.write(Data("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
                client.cancel()
                return
            }
            let port = UInt16(url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80))
            let decision = decide(scope: scope, host: host)
            let started = ContinuousClock.now
            do {
                let (upstream, upstreamEarly) = try await dial(decision: decision, targetHost: host, targetPort: port)
                if case .proxy(let profile) = decision.kind {
                    recordSuccess(proxyID: profile.id, name: profile.displayName)
                }
                var pathPart = url.path.isEmpty ? "/" : url.path
                if let q = url.query, !q.isEmpty { pathPart += "?\(q)" }
                var rebuilt = "\(method) \(pathPart) \(version)\r\n"
                var hasHost = false
                for line in lines.dropFirst() where !line.isEmpty {
                    let lower = line.lowercased()
                    if lower.hasPrefix("proxy-authorization:") || lower.hasPrefix("proxy-connection:") {
                        continue
                    }
                    if lower.hasPrefix("host:") { hasHost = true }
                    rebuilt += "\(line)\r\n"
                }
                if !hasHost {
                    let hostHeader = (port == 80) ? host : "\(host):\(port)"
                    rebuilt += "Host: \(hostHeader)\r\n"
                }
                rebuilt += "\r\n"

                var payload = Data(rebuilt.utf8)
                let bodyRest = reader.drainBuffer()
                if !bodyRest.isEmpty { payload.append(bodyRest) }
                try await Self.sendData(payload, on: upstream)
                if !upstreamEarly.isEmpty {
                    try await reader.write(upstreamEarly)
                }
                await relay(client: client, upstream: upstream)
            } catch {
                let elapsed = Self.elapsedMs(since: started)
                if case .proxy(let profile) = decision.kind {
                    recordFailure(proxyID: profile.id, name: profile.displayName, detail: error.localizedDescription)
                }
                emitLog("[Net][Dial] \(connID) FAIL HTTP via=\(decision.exitLabel) target=\(host):\(port) after \(elapsed)ms tag=\(scope.tag): \(error.localizedDescription)")
                try? await reader.write(Data("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
                client.cancel()
            }
        } catch {
            client.cancel()
        }
    }

    // MARK: Upstream Dialing

    private func decide(scope: NetworkScope, host: String) -> NetworkRouteDecision {
        let current = stateLock.withLock { settings }
        return NetworkRouteDecision.decide(settings: current, scope: scope, host: host)
    }

    private func dial(
        decision: NetworkRouteDecision,
        targetHost: String,
        targetPort: UInt16
    ) async throws -> (NWConnection, Data) {
        switch decision.kind {
        case .direct:
            let conn = try await connectTCP(host: targetHost, port: targetPort, useTLS: false, timeoutSeconds: 20)
            return (conn, Data())
        case .proxy(let profile):
            let password = passwordProvider(profile.id) ?? ""
            switch profile.kind {
            case .socks5:
                return try await dialUpstreamSocks5(profile: profile, password: password, targetHost: targetHost, targetPort: targetPort)
            case .http:
                return try await dialUpstreamHTTPConnect(profile: profile, password: password, useTLS: false, targetHost: targetHost, targetPort: targetPort)
            case .https:
                return try await dialUpstreamHTTPConnect(profile: profile, password: password, useTLS: true, targetHost: targetHost, targetPort: targetPort)
            }
        }
    }

    private func connectTCP(host: String, port: UInt16, useTLS: Bool, timeoutSeconds: Double) async throws -> NWConnection {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NetHubError.invalidTarget("无效端口 \(port)")
        }
        let params: NWParameters = useTLS ? .tls : .tcp
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let done = OnceFlag()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + timeoutSeconds)
            timer.setEventHandler {
                if done.claim() {
                    conn.cancel()
                    continuation.resume(throwing: NetHubError.timeout("连接 \(host):\(port) 超时"))
                }
            }
            timer.resume()

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    timer.cancel()
                    if done.claim() { continuation.resume() }
                case .failed(let err):
                    timer.cancel()
                    if done.claim() {
                        conn.cancel()
                        continuation.resume(throwing: err)
                    }
                case .waiting(let err):
                    // Keep waiting until timeout or ready, unless clearly unrecoverable.
                    _ = err
                case .cancelled:
                    timer.cancel()
                    if done.claim() { continuation.resume(throwing: NetHubError.cancelled) }
                default:
                    break
                }
            }
            conn.start(queue: queue)
        }
        conn.stateUpdateHandler = nil
        return conn
    }

    private func dialUpstreamSocks5(
        profile: ProxyProfile,
        password: String,
        targetHost: String,
        targetPort: UInt16
    ) async throws -> (NWConnection, Data) {
        let conn = try await connectTCP(host: profile.host, port: UInt16(profile.port), useTLS: false, timeoutSeconds: 20)
        let io = BufferedConnection(connection: conn)
        do {
            let hasAuth = !profile.username.isEmpty || !password.isEmpty
            let methods: [UInt8] = hasAuth ? [0x05, 0x02, 0x00, 0x02] : [0x05, 0x01, 0x00]
            try await io.write(Data(methods))
            let sel = try await io.readExact(2)
            guard sel[0] == 0x05 else { throw NetHubError.proxyHandshake("上游 SOCKS5 版本不匹配") }
            if sel[1] == 0x02 {
                guard hasAuth else { throw NetHubError.proxyAuth("上游 SOCKS5 代理需要用户名和密码") }
                let uBytes = Array(profile.username.utf8)
                let pBytes = Array(password.utf8)
                guard uBytes.count <= 255, pBytes.count <= 255 else {
                    throw NetHubError.proxyAuth("上游代理用户名或密码过长")
                }
                var authMsg = Data([0x01, UInt8(uBytes.count)])
                authMsg.append(contentsOf: uBytes)
                authMsg.append(UInt8(pBytes.count))
                authMsg.append(contentsOf: pBytes)
                try await io.write(authMsg)
                let authRep = try await io.readExact(2)
                guard authRep[1] == 0x00 else {
                    throw NetHubError.proxyAuth("proxy-auth: 上游 SOCKS5 代理用户名或密码被拒绝")
                }
            } else if sel[1] != 0x00 {
                throw NetHubError.proxyAuth("上游 SOCKS5 代理不支持当前认证方式")
            }

            // CONNECT request (always domain ATYP=0x03 for non-IP, or IPv4/IPv6 for literals)
            var req = Data([0x05, 0x01, 0x00])
            var v4 = in_addr()
            var v6 = in6_addr()
            if inet_pton(AF_INET, targetHost, &v4) == 1 {
                req.append(0x01)
                withUnsafeBytes(of: &v4) { req.append(contentsOf: $0) }
            } else if inet_pton(AF_INET6, targetHost, &v6) == 1 {
                req.append(0x04)
                withUnsafeBytes(of: &v6) { req.append(contentsOf: $0) }
            } else {
                let hostBytes = Array(targetHost.utf8)
                guard hostBytes.count <= 255 else { throw NetHubError.invalidTarget("目标主机名过长") }
                req.append(0x03)
                req.append(UInt8(hostBytes.count))
                req.append(contentsOf: hostBytes)
            }
            req.append(UInt8((targetPort >> 8) & 0xFF))
            req.append(UInt8(targetPort & 0xFF))
            try await io.write(req)

            let repHead = try await io.readExact(4)
            guard repHead[0] == 0x05 else { throw NetHubError.proxyHandshake("上游 SOCKS5 响应异常") }
            guard repHead[1] == 0x00 else {
                throw NetHubError.proxyRejected("上游 SOCKS5 拒绝连接到 \(targetHost):\(targetPort)（状态码 \(repHead[1])）")
            }
            switch repHead[3] {
            case 0x01: _ = try await io.readExact(6)
            case 0x03:
                let l = try await io.readExact(1)
                _ = try await io.readExact(Int(l[0]) + 2)
            case 0x04: _ = try await io.readExact(18)
            default: throw NetHubError.proxyHandshake("上游 SOCKS5 返回未知地址类型")
            }
            return (conn, io.drainBuffer())
        } catch {
            conn.cancel()
            throw error
        }
    }

    private func dialUpstreamHTTPConnect(
        profile: ProxyProfile,
        password: String,
        useTLS: Bool,
        targetHost: String,
        targetPort: UInt16
    ) async throws -> (NWConnection, Data) {
        let conn = try await connectTCP(host: profile.host, port: UInt16(profile.port), useTLS: useTLS, timeoutSeconds: 20)
        let io = BufferedConnection(connection: conn)
        do {
            let formattedTarget = targetHost.contains(":") ? "[\(targetHost)]:\(targetPort)" : "\(targetHost):\(targetPort)"
            var req = "CONNECT \(formattedTarget) HTTP/1.1\r\nHost: \(formattedTarget)\r\n"
            if !profile.username.isEmpty || !password.isEmpty {
                let token = Data("\(profile.username):\(password)".utf8).base64EncodedString()
                req += "Proxy-Authorization: Basic \(token)\r\n"
            }
            req += "\r\n"
            try await io.write(Data(req.utf8))

            let head = try await io.readUntilCRLFCRLF(maxBytes: 16_384)
            let headStr = String(decoding: head, as: UTF8.self)
            let statusLine = headStr.components(separatedBy: "\r\n").first ?? ""
            let parts = statusLine.split(separator: " ", omittingEmptySubsequences: true)
            let statusCode = parts.count >= 2 ? Int(parts[1]) ?? 0 : 0
            if statusCode == 407 {
                throw NetHubError.proxyAuth("407 Proxy Authentication Required")
            }
            guard (200..<300).contains(statusCode) else {
                throw NetHubError.proxyRejected("上游 HTTP 代理拒绝 CONNECT（\(statusLine)）")
            }
            // Preserve any bytes sent immediately after HTTP 200 (critical for server-first protocols like SSH).
            return (conn, io.drainBuffer())
        } catch {
            conn.cancel()
            throw error
        }
    }

    // MARK: Bidirectional Relay

    private func relay(client: NWConnection, upstream: NWConnection) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await Self.pump(from: client, to: upstream) }
            group.addTask { await Self.pump(from: upstream, to: client) }
            await group.next()
            client.cancel()
            upstream.cancel()
            group.cancelAll()
        }
    }

    private static func pump(from source: NWConnection, to destination: NWConnection) async {
        while !Task.isCancelled {
            let chunk: (data: Data?, eof: Bool, error: NWError?) = await withCheckedContinuation { cont in
                source.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { data, _, isComplete, error in
                    cont.resume(returning: (data, isComplete, error))
                }
            }
            if let data = chunk.data, !data.isEmpty {
                do {
                    try await sendData(data, on: destination)
                } catch {
                    break
                }
            }
            if chunk.eof || chunk.error != nil {
                break
            }
        }
    }

    private static func sendData(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            })
        }
    }

    // MARK: Alerts & Diagnostics

    private func recordFailure(proxyID: String, name: String, detail: String) {
        let key = proxyID.uppercased()
        let becameAlerted: Bool = stateLock.withLock {
            let count = (failureStreaks[key] ?? 0) + 1
            failureStreaks[key] = count
            if count >= 3 && !alertedProxies.contains(key) {
                alertedProxies.insert(key)
                return true
            }
            return false
        }
        if becameAlerted {
            emitLog("[Net][Alert] 代理「\(name)」连续 3 次连接失败：\(detail)")
            publishAlertState()
        }
    }

    private func recordSuccess(proxyID: String, name: String) {
        let key = proxyID.uppercased()
        let recovered: Bool = stateLock.withLock {
            failureStreaks[key] = 0
            return alertedProxies.remove(key) != nil
        }
        if recovered {
            emitLog("[Net][Recovered] 代理「\(name)」已恢复连通")
            publishAlertState()
        }
    }

    private func publishAlertState() {
        let message: String? = stateLock.withLock {
            guard !alertedProxies.isEmpty else { return nil }
            let names = alertedProxies.compactMap { id in
                settings.proxy(id: id)?.displayName
            }.sorted()
            if names.isEmpty { return nil }
            return "代理连续连接失败：\(names.joined(separator: "、"))，请检查代理地址、端口或密码。"
        }
        onAlertChange?(message)
    }

    private func emitLog(_ raw: String) {
        let secrets: [String] = stateLock.withLock {
            var list = [entryPassword]
            for proxy in settings.proxies {
                if let pw = passwordProvider(proxy.id), !pw.isEmpty {
                    list.append(pw)
                }
            }
            return list
        }
        let clean = NetworkRedaction.redact(raw, secrets: secrets)
        onLog?(clean)
    }

    func runDiagnostics(
        settings: NetworkRoutingSettings,
        systemProxySummary: String,
        denDNSServers: [String],
        kernelNetStatus: String
    ) async -> [DiagnosticItem] {
        var items: [DiagnosticItem] = []

        // 1. Settings summary
        let routeDesc = settings.routingEnabled
            ? Words.t("已开启 · 默认 \(settings.defaultRoute.rawValue) · 斗室 \(settings.effectiveRoute(for: .shell).rawValue) · 代理 \(settings.proxies.count) 个")
            : "总开关已关闭（全部直连）"
        items.append(DiagnosticItem(name: "路由配置", status: .ok, detail: routeDesc, elapsedMs: 0))

        // 2. System proxy snapshot
        items.append(DiagnosticItem(name: "系统代理快照", status: .ok, detail: systemProxySummary, elapsedMs: 0))

        // 3. Den kernel & DNS
        let dnsText = denDNSServers.isEmpty ? "尚未写入" : denDNSServers.joined(separator: ", ")
        items.append(DiagnosticItem(name: Words.t("斗室内核与 DNS"), status: denDNSServers.isEmpty ? .warn : .ok, detail: "\(kernelNetStatus) · DNS: \(dnsText)", elapsedMs: 0))

        // 4. Local entry self-test
        if let entry = activeEndpoints {
            let t0 = ContinuousClock.now
            let socksOK = await selfTestSocksAuth(port: entry.socksPort)
            items.append(DiagnosticItem(
                name: "本地 SOCKS5 入口",
                status: socksOK ? .ok : .fail,
                detail: socksOK ? "127.0.0.1:\(entry.socksPort) 鉴权正常（错误密码已拒收）" : "127.0.0.1:\(entry.socksPort) 自检失败",
                elapsedMs: Self.elapsedMs(since: t0)
            ))

            let t1 = ContinuousClock.now
            let httpOK = await selfTestHTTPAuth(port: entry.httpPort)
            items.append(DiagnosticItem(
                name: "本地 HTTP 入口",
                status: httpOK ? .ok : .fail,
                detail: httpOK ? "127.0.0.1:\(entry.httpPort) 407 鉴权正常" : "127.0.0.1:\(entry.httpPort) 自检失败",
                elapsedMs: Self.elapsedMs(since: t1)
            ))
        } else {
            items.append(DiagnosticItem(name: "本地代理入口", status: .skip, detail: "当前全部走直连，未占用本地端口", elapsedMs: 0))
        }

        // 5. Direct probe
        let tDirect = ContinuousClock.now
        do {
            let conn = try await connectTCP(host: "1.1.1.1", port: 443, useTLS: false, timeoutSeconds: 8)
            conn.cancel()
            items.append(DiagnosticItem(name: "直连探测 (1.1.1.1:443)", status: .ok, detail: "TCP 握手成功", elapsedMs: Self.elapsedMs(since: tDirect)))
        } catch {
            items.append(DiagnosticItem(name: "直连探测 (1.1.1.1:443)", status: .warn, detail: error.localizedDescription, elapsedMs: Self.elapsedMs(since: tDirect)))
        }

        // 6. Each configured upstream proxy
        for proxy in settings.proxies {
            let tProxy = ContinuousClock.now
            do {
                let decision = NetworkRouteDecision(kind: .proxy(proxy), rule: .route, scopeTag: "default")
                let (conn, _) = try await dial(decision: decision, targetHost: "1.1.1.1", targetPort: 443)
                conn.cancel()
                items.append(DiagnosticItem(
                    name: "代理「\(proxy.displayName)」",
                    status: .ok,
                    detail: "\(proxy.kind.displayName) \(proxy.host):\(proxy.port) 隧道连通正常",
                    elapsedMs: Self.elapsedMs(since: tProxy)
                ))
            } catch {
                items.append(DiagnosticItem(
                    name: "代理「\(proxy.displayName)」",
                    status: .fail,
                    detail: "\(proxy.kind.displayName) \(proxy.host):\(proxy.port) 失败：\(error.localizedDescription)",
                    elapsedMs: Self.elapsedMs(since: tProxy)
                ))
            }
        }

        return items
    }

    private func selfTestSocksAuth(port: UInt16) async -> Bool {
        do {
            let conn = try await connectTCP(host: "127.0.0.1", port: port, useTLS: false, timeoutSeconds: 3)
            defer { conn.cancel() }
            let io = BufferedConnection(connection: conn)
            try await io.write(Data([0x05, 0x01, 0x02]))
            let sel = try await io.readExact(2)
            guard sel == Data([0x05, 0x02]) else { return false }
            // Send wrong password and verify rejection (0x01 0x01).
            let u = Array("default".utf8)
            let p = Array("wrong-password".utf8)
            var bad = Data([0x01, UInt8(u.count)])
            bad.append(contentsOf: u)
            bad.append(UInt8(p.count))
            bad.append(contentsOf: p)
            try await io.write(bad)
            let rep = try await io.readExact(2)
            return rep == Data([0x01, 0x01])
        } catch {
            return false
        }
    }

    private func selfTestHTTPAuth(port: UInt16) async -> Bool {
        do {
            let conn = try await connectTCP(host: "127.0.0.1", port: port, useTLS: false, timeoutSeconds: 3)
            defer { conn.cancel() }
            let io = BufferedConnection(connection: conn)
            try await io.write(Data("CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n".utf8))
            let head = try await io.readUntilCRLFCRLF(maxBytes: 4096)
            let line = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
            return line.contains("407")
        } catch {
            return false
        }
    }

    // MARK: Helpers

    private func nextConnectionID() -> String {
        let n: UInt64 = stateLock.withLock {
            connectionSeq &+= 1
            return connectionSeq
        }
        return String(format: "c%04llu", n)
    }

    private func authenticateBasicHeader(_ header: String?) -> NetworkScope? {
        guard let header, header.lowercased().hasPrefix("basic ") else { return nil }
        let b64 = String(header.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        guard let decoded = Data(base64Encoded: b64) else { return nil }
        let str = String(decoding: decoded, as: UTF8.self)
        guard let colon = str.firstIndex(of: ":") else { return nil }
        let user = String(str[..<colon])
        let pass = String(str[str.index(after: colon)...])
        guard Self.constantTimeEqual(pass, entryPassword) else { return nil }
        return Self.parseTagScope(user)
    }

    private static func parseTagScope(_ rawUser: String) -> NetworkScope? {
        let base = rawUser.split(separator: "~", maxSplits: 1).first.map(String.init) ?? rawUser
        return NetworkScope(tag: base)
    }

    private static func parseAuthority(_ raw: String, defaultPort: UInt16) -> (String, UInt16)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("[") {
            guard let close = trimmed.firstIndex(of: "]") else { return nil }
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            let rest = trimmed[trimmed.index(after: close)...]
            if rest.hasPrefix(":"), let p = UInt16(rest.dropFirst()), p > 0 {
                return (host, p)
            }
            return (host, defaultPort)
        }
        if let colon = trimmed.lastIndex(of: ":"), let p = UInt16(trimmed[trimmed.index(after: colon)...]), p > 0 {
            let host = String(trimmed[..<colon])
            return host.isEmpty ? nil : (host, p)
        }
        return (trimmed, defaultPort)
    }

    private static func formatIPv6(_ bytes: Data) -> String {
        var addr = in6_addr()
        _ = bytes.withUnsafeBytes { raw in
            memcpy(&addr, raw.baseAddress!, min(16, raw.count))
        }
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if inet_ntop(AF_INET6, &addr, &buf, socklen_t(buf.count)) != nil {
            return String(cString: buf)
        }
        return "::"
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8)
        let bb = Array(b.utf8)
        guard ab.count == bb.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<ab.count { diff |= ab[i] ^ bb[i] }
        return diff == 0
    }

    private static func generateRandomPassword() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func elapsedMs(since start: ContinuousClock.Instant) -> Int {
        let d = start.duration(to: .now)
        return Int(d.components.seconds * 1000) + Int(d.components.attoseconds / 1_000_000_000_000_000)
    }
}

private enum NetHubError: Error, LocalizedError {
    case listenerFailed(String)
    case invalidTarget(String)
    case timeout(String)
    case cancelled
    case eof
    case headerTooLarge
    case proxyHandshake(String)
    case proxyAuth(String)
    case proxyRejected(String)

    var errorDescription: String? {
        switch self {
        case .listenerFailed(let m), .invalidTarget(let m), .timeout(let m),
             .proxyHandshake(let m), .proxyAuth(let m), .proxyRejected(let m):
            return m
        case .cancelled: return "连接已取消"
        case .eof: return "对端提前断开连接"
        case .headerTooLarge: return "HTTP 代理响应头过大"
        }
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.withLock {
            if claimed { return false }
            claimed = true
            return true
        }
    }
}

private final class BufferedConnection: @unchecked Sendable {
    let connection: NWConnection
    private var buffer = Data()

    init(connection: NWConnection) {
        self.connection = connection
    }

    func drainBuffer() -> Data {
        defer { buffer.removeAll(keepingCapacity: false) }
        return buffer
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    func readExact(_ count: Int) async throws -> Data {
        while buffer.count < count {
            try await fillOnce()
        }
        let slice = Data(buffer.prefix(count))
        buffer.removeFirst(count)
        return slice
    }

    func readUntilCRLFCRLF(maxBytes: Int) async throws -> Data {
        let marker = Data([0x0D, 0x0A, 0x0D, 0x0A])
        while true {
            if let range = buffer.range(of: marker) {
                let end = range.upperBound
                let slice = Data(buffer[..<end])
                buffer.removeSubrange(..<end)
                return slice
            }
            if buffer.count > maxBytes {
                throw NetHubError.headerTooLarge
            }
            try await fillOnce()
        }
    }

    private func fillOnce() async throws {
        let result: (Data?, Bool, NWError?) = await withCheckedContinuation { cont in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, isComplete, error in
                cont.resume(returning: (data, isComplete, error))
            }
        }
        if let err = result.2 { throw err }
        if let data = result.0, !data.isEmpty {
            buffer.append(data)
            return
        }
        if result.1 { throw NetHubError.eof }
        throw NetHubError.eof
    }
}
