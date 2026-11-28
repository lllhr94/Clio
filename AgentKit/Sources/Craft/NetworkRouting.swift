import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Logical traffic scope used by Clio's in-app network router.
public enum NetworkScope: Hashable, Sendable {
    case `default`
    case shell
    case browser
    case mcp
    case backup
    case service(String)

    public var tag: String {
        switch self {
        case .default: return "default"
        case .shell: return "shell"
        case .browser: return "browser"
        case .mcp: return "mcp"
        case .backup: return "backup"
        case .service(let id): return "service:\(id)"
        }
    }

    public init?(tag: String) {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed {
        case "default": self = .default
        case "shell": self = .shell
        case "browser": self = .browser
        case "mcp": self = .mcp
        case "backup": self = .backup
        default:
            if trimmed.hasPrefix("service:") {
                let id = String(trimmed.dropFirst("service:".count))
                guard !id.isEmpty else { return nil }
                self = .service(id)
            } else {
                return nil
            }
        }
    }

    /// Standard non-service scopes exposed in Settings.
    public static let standardScopes: [NetworkScope] = [.shell, .browser, .mcp, .backup]
}

public enum ProxyKind: String, Codable, CaseIterable, Sendable {
    case socks5
    case http
    case https

    public var displayName: String {
        switch self {
        case .socks5: return "SOCKS5"
        case .http: return "HTTP"
        case .https: return "HTTPS"
        }
    }
}

/// Non-secret upstream proxy metadata. Passwords live exclusively in Keychain (`Vault`) under `vaultKey`.
public struct ProxyProfile: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var kind: ProxyKind
    public var host: String
    public var port: Int
    public var username: String
    public var bypass: [String]

    public init(
        id: String = UUID().uuidString.uppercased(),
        name: String = "",
        kind: ProxyKind = .socks5,
        host: String,
        port: Int,
        username: String = "",
        bypass: [String] = []
    ) {
        self.id = id.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.kind = kind
        self.host = Self.cleanHost(host)
        self.port = port
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        self.bypass = NetworkBypassMatcher.normalizeRules(bypass)
    }

    public var displayName: String {
        name.isEmpty ? "\(host):\(port)" : name
    }

    public var vaultKey: String {
        "net.proxy.\(id)"
    }

    public static func cleanHost(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("["), value.hasSuffix("]"), value.count > 2 {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }

    public func validationError() -> String? {
        guard !host.isEmpty else { return "请填写代理服务器地址。" }
        guard !host.contains("://"), !host.contains("/"), !host.contains("@"),
              !host.contains("?"), !host.contains("#"),
              host.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7E }) else {
            return "代理服务器地址格式不正确（只填主机名或 IP，不要带协议前缀或空格）。"
        }
        guard (1...65535).contains(port) else {
            return "端口必须在 1 到 65535 之间。"
        }
        if username.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            return "用户名包含无效控制字符。"
        }
        if name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            return "名称包含无效控制字符。"
        }
        return nil
    }
}

/// Route target for default, scope, or per-service policy.
public enum NetworkRoute: Equatable, Hashable, Sendable {
    case followDefault
    case direct
    case proxy(String)

    public var rawValue: String {
        switch self {
        case .followDefault: return "default"
        case .direct: return "direct"
        case .proxy(let id): return "proxy:\(id)"
        }
    }

    public init(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "direct" {
            self = .direct
        } else if trimmed.hasPrefix("proxy:") {
            let id = String(trimmed.dropFirst("proxy:".count)).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            self = id.isEmpty ? .direct : .proxy(id)
        } else {
            self = .followDefault
        }
    }
}

extension NetworkRoute: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self.init(rawValue: raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Per-device network routing configuration. Never synced or backed up to other devices.
public struct NetworkRoutingSettings: Codable, Equatable, Sendable {
    public var routingEnabled: Bool
    public var defaultRoute: NetworkRoute
    public var scopeRoutes: [String: NetworkRoute]
    public var serviceRoutes: [String: NetworkRoute]
    public var proxies: [ProxyProfile]

    public static let `default` = NetworkRoutingSettings()

    public init(
        routingEnabled: Bool = true,
        defaultRoute: NetworkRoute = .direct,
        scopeRoutes: [String: NetworkRoute] = [:],
        serviceRoutes: [String: NetworkRoute] = [:],
        proxies: [ProxyProfile] = []
    ) {
        self.routingEnabled = routingEnabled
        self.defaultRoute = defaultRoute == .followDefault ? .direct : defaultRoute
        self.scopeRoutes = scopeRoutes
        self.serviceRoutes = serviceRoutes
        self.proxies = proxies
    }

    enum CodingKeys: String, CodingKey {
        case routingEnabled, defaultRoute, scopeRoutes, serviceRoutes, proxies
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let enabled = try c.decodeIfPresent(Bool.self, forKey: .routingEnabled) ?? true
        let defRoute = try c.decodeIfPresent(NetworkRoute.self, forKey: .defaultRoute) ?? .direct
        let scopes = try c.decodeIfPresent([String: NetworkRoute].self, forKey: .scopeRoutes) ?? [:]
        let services = try c.decodeIfPresent([String: NetworkRoute].self, forKey: .serviceRoutes) ?? [:]
        let list = try c.decodeIfPresent([ProxyProfile].self, forKey: .proxies) ?? []
        self.init(
            routingEnabled: enabled,
            defaultRoute: defRoute,
            scopeRoutes: scopes,
            serviceRoutes: services,
            proxies: list
        )
    }

    public func proxy(id: String) -> ProxyProfile? {
        let target = id.uppercased()
        return proxies.first { $0.id.uppercased() == target }
    }

    public func configuredRoute(for scope: NetworkScope) -> NetworkRoute {
        switch scope {
        case .default:
            return defaultRoute == .followDefault ? .direct : defaultRoute
        case .shell, .browser, .mcp, .backup:
            return scopeRoutes[scope.tag] ?? .followDefault
        case .service(let id):
            return serviceRoutes[id] ?? .followDefault
        }
    }

    /// Resolves `.followDefault` into `.direct` or `.proxy(id)` (or `.direct` if master switch is off or proxy is missing).
    public func effectiveRoute(for scope: NetworkScope) -> NetworkRoute {
        guard routingEnabled else { return .direct }
        let raw = configuredRoute(for: scope)
        let resolved = (raw == .followDefault) ? defaultRoute : raw
        switch resolved {
        case .proxy(let id):
            return proxy(id: id) != nil ? .proxy(id) : .direct
        case .direct, .followDefault:
            return .direct
        }
    }

    /// True only when the local proxy entry actually needs to listen.
    public var needsLocalEntry: Bool {
        guard routingEnabled, !proxies.isEmpty else { return false }
        let validIDs = Set(proxies.map { $0.id.uppercased() })
        if case .proxy(let id) = defaultRoute, validIDs.contains(id.uppercased()) { return true }
        for route in scopeRoutes.values {
            if case .proxy(let id) = route, validIDs.contains(id.uppercased()) { return true }
        }
        for route in serviceRoutes.values {
            if case .proxy(let id) = route, validIDs.contains(id.uppercased()) { return true }
        }
        return false
    }

    public func settingRoute(_ route: NetworkRoute, for scope: NetworkScope) -> NetworkRoutingSettings {
        var copy = self
        switch scope {
        case .default:
            copy.defaultRoute = route == .followDefault ? .direct : route
        case .shell, .browser, .mcp, .backup:
            if route == .followDefault {
                copy.scopeRoutes.removeValue(forKey: scope.tag)
            } else {
                copy.scopeRoutes[scope.tag] = route
            }
        case .service(let id):
            if route == .followDefault {
                copy.serviceRoutes.removeValue(forKey: id)
            } else {
                copy.serviceRoutes[id] = route
            }
        }
        return copy
    }

    public func removingProxy(id: String) -> NetworkRoutingSettings {
        let target = id.uppercased()
        var copy = self
        copy.proxies.removeAll { $0.id.uppercased() == target }
        if case .proxy(let cur) = copy.defaultRoute, cur.uppercased() == target {
            copy.defaultRoute = .direct
        }
        for (k, v) in copy.scopeRoutes {
            if case .proxy(let cur) = v, cur.uppercased() == target {
                copy.scopeRoutes[k] = .direct
            }
        }
        for (k, v) in copy.serviceRoutes {
            if case .proxy(let cur) = v, cur.uppercased() == target {
                copy.serviceRoutes[k] = .direct
            }
        }
        return copy
    }
}

/// Host, domain suffix, IP, and CIDR bypass matcher with unconditional loopback protection.
public enum NetworkBypassMatcher {
    public static func normalizeHost(_ raw: String) -> String {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasPrefix("["), host.hasSuffix("]"), host.count > 2 {
            host = String(host.dropFirst().dropLast())
        }
        if let zone = host.firstIndex(of: "%") {
            host = String(host[..<zone])
        }
        while host.hasSuffix(".") {
            host.removeLast()
        }
        return host
    }

    public static func parseBypassText(_ text: String) -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;"))
        let rawTokens = text.components(separatedBy: separators)
        return normalizeRules(rawTokens)
    }

    public static func normalizeRules(_ rules: [String]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for raw in rules {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !trimmed.isEmpty,
                  trimmed.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7E }),
                  !trimmed.contains("://") else { continue }
            if seen.insert(trimmed).inserted {
                out.append(trimmed)
            }
        }
        return out
    }

    public static func isLoopback(_ rawHost: String) -> Bool {
        let host = normalizeHost(rawHost)
        if host.isEmpty { return false }
        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        if let v4 = parseIPv4(host) {
            return (v4 >> 24) == 127 || v4 == 0
        }
        if let v6 = parseIPv6(host) {
            let isV6Loopback = v6[0..<15].allSatisfy({ $0 == 0 }) && v6[15] == 1
            let isV6Unspec = v6.allSatisfy({ $0 == 0 })
            if isV6Loopback || isV6Unspec { return true }
            // IPv4-mapped ::ffff:127.0.0.0/104
            if v6[0..<10].allSatisfy({ $0 == 0 }) && v6[10] == 0xFF && v6[11] == 0xFF {
                return v6[12] == 127
            }
        }
        return false
    }

    public static func matches(host rawHost: String, rule rawRule: String) -> Bool {
        let host = normalizeHost(rawHost)
        let rule = rawRule.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty, !rule.isEmpty else { return false }

        if rule.contains("/") {
            return matchesCIDR(host: host, cidr: rule)
        }
        if rule.hasPrefix("*.") {
            let suffix = String(rule.dropFirst(2))
            guard !suffix.isEmpty else { return false }
            return host == suffix || host.hasSuffix(".\(suffix)")
        }
        if rule.hasPrefix(".") {
            let suffix = String(rule.dropFirst())
            guard !suffix.isEmpty else { return false }
            return host == suffix || host.hasSuffix(".\(suffix)")
        }
        if let h4 = parseIPv4(host), let r4 = parseIPv4(rule) {
            return h4 == r4
        }
        if let h6 = parseIPv6(host), let r6 = parseIPv6(rule) {
            return h6 == r6
        }
        return host == normalizeHost(rule)
    }

    public static func matchesAny(host: String, rules: [String]) -> Bool {
        rules.contains { matches(host: host, rule: $0) }
    }

    private static func matchesCIDR(host: String, cidr: String) -> Bool {
        let parts = cidr.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let prefix = Int(parts[1]) else { return false }
        let netStr = String(parts[0])

        if let net4 = parseIPv4(netStr), let host4 = parseIPv4(host), (0...32).contains(prefix) {
            if prefix == 0 { return true }
            let mask: UInt32 = ~UInt32(0) << UInt32(32 - prefix)
            return (host4 & mask) == (net4 & mask)
        }
        if let net6 = parseIPv6(netStr), let host6 = parseIPv6(host), (0...128).contains(prefix) {
            let fullBytes = prefix / 8
            let remBits = prefix % 8
            for i in 0..<fullBytes {
                if host6[i] != net6[i] { return false }
            }
            if remBits > 0 {
                let mask: UInt8 = ~UInt8(0) << UInt8(8 - remBits)
                if (host6[fullBytes] & mask) != (net6[fullBytes] & mask) { return false }
            }
            return true
        }
        return false
    }

    private static func parseIPv4(_ s: String) -> UInt32? {
        var addr = in_addr()
        guard inet_pton(AF_INET, s, &addr) == 1 else { return nil }
        return UInt32(bigEndian: addr.s_addr)
    }

    private static func parseIPv6(_ s: String) -> [UInt8]? {
        var addr = in6_addr()
        guard inet_pton(AF_INET6, s, &addr) == 1 else { return nil }
        return withUnsafeBytes(of: &addr) { Array($0) }
    }
}

public struct NetworkRouteDecision: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case direct
        case proxy(ProxyProfile)
    }

    public enum Rule: String, Equatable, Sendable {
        case masterOff = "master-off"
        case route = "route"
        case loopback = "loopback"
        case bypass = "bypass"
        case missingProxy = "missing-proxy"
    }

    public let kind: Kind
    public let rule: Rule
    public let scopeTag: String

    public init(kind: Kind, rule: Rule, scopeTag: String) {
        self.kind = kind
        self.rule = rule
        self.scopeTag = scopeTag
    }

    public var exitLabel: String {
        switch kind {
        case .direct: return "direct"
        case .proxy(let p): return "proxy:\(p.displayName)"
        }
    }

    public static func decide(
        settings: NetworkRoutingSettings,
        scope: NetworkScope,
        host: String
    ) -> NetworkRouteDecision {
        if !settings.routingEnabled {
            return NetworkRouteDecision(kind: .direct, rule: .masterOff, scopeTag: scope.tag)
        }
        if NetworkBypassMatcher.isLoopback(host) {
            return NetworkRouteDecision(kind: .direct, rule: .loopback, scopeTag: scope.tag)
        }
        let configured = settings.configuredRoute(for: scope)
        let resolved = (configured == .followDefault) ? settings.defaultRoute : configured
        switch resolved {
        case .direct, .followDefault:
            return NetworkRouteDecision(kind: .direct, rule: .route, scopeTag: scope.tag)
        case .proxy(let id):
            guard let profile = settings.proxy(id: id) else {
                return NetworkRouteDecision(kind: .direct, rule: .missingProxy, scopeTag: scope.tag)
            }
            if NetworkBypassMatcher.matchesAny(host: host, rules: profile.bypass) {
                return NetworkRouteDecision(kind: .direct, rule: .bypass, scopeTag: scope.tag)
            }
            return NetworkRouteDecision(kind: .proxy(profile), rule: .route, scopeTag: scope.tag)
        }
    }
}

/// Shell proxy environment and managed OpenSSH `ProxyCommand` config renderer for Den.
public enum NetworkShellConfig {
    public static func environment(
        settings: NetworkRoutingSettings,
        socksPort: UInt16?,
        httpPort: UInt16?,
        entryPassword: String
    ) -> [String: String] {
        guard settings.routingEnabled,
              case .proxy(let proxyID) = settings.effectiveRoute(for: .shell),
              let profile = settings.proxy(id: proxyID),
              !entryPassword.isEmpty else {
            return [:]
        }

        var env: [String: String] = [:]
        var noProxyEntries = ["localhost", "127.0.0.1", "::1"]
        for item in profile.bypass where !noProxyEntries.contains(item) {
            noProxyEntries.append(item)
        }
        let noProxy = noProxyEntries.joined(separator: ",")
        env["NO_PROXY"] = noProxy
        env["no_proxy"] = noProxy

        if let httpPort, httpPort > 0 {
            let httpURL = "http://shell:\(entryPassword)@127.0.0.1:\(httpPort)"
            env["HTTP_PROXY"] = httpURL
            env["http_proxy"] = httpURL
            env["HTTPS_PROXY"] = httpURL
            env["https_proxy"] = httpURL
            env["CLIO_NET_PROXY_URL"] = httpURL
        }
        if let socksPort, socksPort > 0 {
            let socksURL = "socks5h://shell:\(entryPassword)@127.0.0.1:\(socksPort)"
            env["ALL_PROXY"] = socksURL
            env["all_proxy"] = socksURL
        }
        return env
    }

    /// Generates `/etc/clio-net/ssh_config`. Empty string when shell routing is direct so OpenSSH stays 100% stock.
    public static func renderSSHConfig(
        settings: NetworkRoutingSettings,
        proxyActive: Bool,
        helperPath: String = "/etc/clio-net/ssh-proxy"
    ) -> String {
        guard proxyActive,
              settings.routingEnabled,
              case .proxy(let proxyID) = settings.effectiveRoute(for: .shell),
              let profile = settings.proxy(id: proxyID) else {
            return "# Clio Den network routing: direct (no SSH proxy override)\n"
        }

        var excludes = ["127.0.0.1", "localhost", "::1"]
        for rule in profile.bypass {
            // OpenSSH Match host accepts exact host/IP and `*` wildcards (CIDR patterns are enforced by ClioNetHub itself).
            guard !rule.contains("/"),
                  rule.unicodeScalars.allSatisfy({ ch in
                      let v = ch.value
                      return (v >= 48 && v <= 57) || (v >= 65 && v <= 90) || (v >= 97 && v <= 122)
                          || ch == "." || ch == "-" || ch == "*" || ch == ":"
                  }) else { continue }
            let pattern = rule.hasPrefix(".") ? "*\(rule)" : rule
            if !excludes.contains(pattern) {
                excludes.append(pattern)
            }
        }
        let negated = excludes.map { "!\($0)" }.joined(separator: ",")
        return """
        # Managed by Clio Den network router — updated automatically when routing settings change.
        Match host \(negated),*
            ProxyCommand \(helperPath) %h %p
        """
    }

    /// POSIX helper script bind-mounted at `/etc/clio-net/ssh-proxy`.
    /// Reads `$CLIO_NET_PROXY_URL` from the process environment (never writes credentials to disk).
    public static let sshProxyHelperScript: String = """
    #!/bin/sh
    # Managed by Clio Den network router. Connects SSH through the local authenticated HTTP CONNECT entry.
    set -eu
    HOST="${1:-}"
    PORT="${2:-22}"
    PROXY="${CLIO_NET_PROXY_URL:-${HTTPS_PROXY:-${HTTP_PROXY:-}}}"
    if [ -z "$HOST" ]; then
      echo "clio ssh-proxy: missing target host" >&2
      exit 2
    fi
    if [ -z "$PROXY" ]; then
      exec nc "$HOST" "$PORT"
    fi
    if command -v python3 >/dev/null 2>&1; then
      exec python3 - "$HOST" "$PORT" <<'PY'
    import base64, os, select, socket, sys, urllib.parse
    host, port = sys.argv[1], int(sys.argv[2])
    raw = os.environ.get("CLIO_NET_PROXY_URL") or os.environ.get("HTTPS_PROXY") or os.environ.get("HTTP_PROXY") or ""
    u = urllib.parse.urlparse(raw)
    phost = u.hostname or "127.0.0.1"
    pport = u.port or 8080
    s = socket.create_connection((phost, pport), timeout=20)
    s.settimeout(None)
    target = f"[{host}]:{port}" if ":" in host else f"{host}:{port}"
    req = f"CONNECT {target} HTTP/1.1\\r\\nHost: {target}\\r\\n"
    if u.username is not None:
      tok = base64.b64encode(f"{urllib.parse.unquote(u.username)}:{urllib.parse.unquote(u.password or '')}".encode()).decode()
      req += f"Proxy-Authorization: Basic {tok}\\r\\n"
    req += "\\r\\n"
    s.sendall(req.encode())
    buf = b""
    while b"\\r\\n\\r\\n" not in buf:
      chunk = s.recv(4096)
      if not chunk:
        sys.stderr.write("clio ssh-proxy: proxy closed during CONNECT\\n")
        sys.exit(1)
      buf += chunk
      if len(buf) > 16384:
        sys.stderr.write("clio ssh-proxy: proxy response header too large\\n")
        sys.exit(1)
    head, rest = buf.split(b"\\r\\n\\r\\n", 1)
    status_line = head.split(b"\\r\\n", 1)[0].decode("latin1", "replace")
    parts = status_line.split()
    if len(parts) < 2 or not parts[1].startswith("2"):
      sys.stderr.write(f"clio ssh-proxy: CONNECT failed ({status_line})\\n")
      sys.exit(1)
    out_fd = sys.stdout.fileno()
    in_fd = sys.stdin.fileno()
    if rest:
      os.write(out_fd, rest)
    fds = [in_fd, s]
    while s in fds:
      r, _, _ = select.select(fds, [], [])
      if in_fd in r:
        data = os.read(in_fd, 16384)
        if not data:
          fds.remove(in_fd)
          try: s.shutdown(socket.SHUT_WR)
          except OSError: pass
        else:
          s.sendall(data)
      if s in r:
        data = s.recv(16384)
        if not data:
          break
        os.write(out_fd, data)
    PY
    fi
    echo "clio ssh-proxy: 需要 python3 来通过代理转发 SSH（在斗室运行 apk add python3 或将目标加入直连例外）。" >&2
    exit 1
    """
}

/// Masks local entry passwords and proxy passwords before any text enters logs, UI, or chat history.
public enum NetworkRedaction {
    public static func redact(_ text: String, secrets: [String]) -> String {
        var result = text
        for secret in secrets where secret.count >= 4 {
            result = result.replacingOccurrences(of: secret, with: "<redacted>")
        }
        return result
    }
}

/// Actionable Chinese hints for common proxy/tarpit failure signatures.
public enum NetworkErrorDiagnostics {
    public static func hint(for output: String) -> String? {
        let lower = output.lowercased()
        if lower.contains("connection timed out during banner exchange") || lower.contains("kex_exchange_identification") {
            return "提示：TCP 已握手但对方没有返回 SSH 响应，常见于当前代理出口 IP 被目标服务器限流/假握手（tarpit）。可在「设置 › 能力与连接 › 网络与代理」中为斗室更换代理节点，或在系统代理里将目标 IP 设为直连。"
        }
        if lower.contains("proxy-auth") || lower.contains("407 proxy authentication") {
            return "提示：代理服务器认证失败（407），请检查「网络与代理」中的代理用户名与密码。"
        }
        return nil
    }
}
