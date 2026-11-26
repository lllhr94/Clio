import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Five orthogonal network access domains separating public web, Fake-IP proxy traffic,
/// explicitly authorized private LAN endpoints, overlay meshes, and SSH hosts.
public enum NetworkAccessDomain: String, Codable, Equatable, Sendable {
    case publicWeb
    case fakeIPProxy
    case authorizedPrivate
    case privateMesh
    case sshWorkplace
}

/// Six actionable diagnostic categories surfaced instead of generic connection refusals.
public enum NetworkDiagnosticCategory: String, Equatable, Sendable {
    case fakeIPPlaceholder
    case unauthorizedPrivate
    case scopeEscalationBlocked
    case unreachableOrLocalNet
    case tlsCertificateMismatch
    case mixedDNSAnomaly

    public var userMessage: String {
        switch self {
        case .fakeIPPlaceholder:
            return "该域名解析到了代理占位网段（198.18.0.0/15，常见于 Clash/Mihomo/Surge Fake-IP）。如确认在使用此类代理，可前往「设置 › 权限与隐私安全」开启「Fake-IP 代理兼容」或检查代理 HTTPS 证书设置。"
        case .unauthorizedPrivate:
            return "该地址属于本机、局域网或私有组网端点，默认禁止模型访问。如需访问家庭 NAS 或内网服务，请前往「设置 › 权限与隐私安全」添加该主机的持久化授权。"
        case .scopeEscalationBlocked:
            return "该操作超出了此私人网络端点的已授权权限范围（或当前对话含外网非可信内容触发安全护栏），已被策略阻止。"
        case .unreachableOrLocalNet:
            return "目标地址暂时无法连接。如访问局域网或 Tailscale 设备，请检查 iOS「系统设置 › 隐私与安全性 › 本地网络」权限或 VPN 私网路由是否包含目标网段。"
        case .tlsCertificateMismatch:
            return "HTTPS 证书与目标域名不匹配或不受信任，已拒绝连接（可能是代理未正确配置证书或存在中间人拦截）。"
        case .mixedDNSAnomaly:
            return "域名解析同时返回了公网/占位地址与内网私有地址（混合 DNS 异常），为防止内网探测与分流绕过，已强制拦截。"
        }
    }
}

/// Action privilege ladder for explicitly authorized private network endpoints.
public enum PrivateNetworkAction: String, Codable, CaseIterable, Equatable, Comparable, Sendable {
    case reach
    case read
    case write
    case credential
    case crossNetworkExfil

    private var rank: Int {
        switch self {
        case .reach: 0
        case .read: 1
        case .write: 2
        case .credential: 3
        case .crossNetworkExfil: 4
        }
    }

    public static func < (lhs: PrivateNetworkAction, rhs: PrivateNetworkAction) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// Explicit, host- and scope-bound authorization entry for a user-controlled LAN or mesh endpoint.
public struct PrivateNetworkGrant: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var hostPattern: String
    public var port: Int?
    public var allowPlainHTTP: Bool
    public var maxAction: PrivateNetworkAction
    public var createdAt: Double

    public init(
        id: String = UUID().uuidString,
        label: String,
        hostPattern: String,
        port: Int? = nil,
        allowPlainHTTP: Bool = false,
        maxAction: PrivateNetworkAction = .read,
        createdAt: Double = Date().timeIntervalSince1970
    ) {
        self.id = id
        self.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        self.hostPattern = Self.normalizePattern(hostPattern)
        self.port = port
        self.allowPlainHTTP = allowPlainHTTP
        self.maxAction = maxAction
        self.createdAt = createdAt
    }

    public static func normalizePattern(_ raw: String) -> String {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if cleaned.hasPrefix("["), cleaned.hasSuffix("]"), cleaned.count > 2 {
            cleaned = String(cleaned.dropFirst().dropLast())
        }
        while cleaned.hasSuffix(".") {
            cleaned.removeLast()
        }
        return cleaned
    }

    public static func isValidPattern(_ raw: String) -> Bool {
        let pattern = normalizePattern(raw)
        guard !pattern.isEmpty,
              !pattern.contains("://"),
              !pattern.contains("/"),
              !pattern.contains("?"),
              !pattern.contains("#"),
              !pattern.contains("@"),
              !pattern.contains(":"),
              !pattern.contains(where: \.isWhitespace) else {
            // Allow valid IPv6 private ULA literals containing ':' when explicitly bracketless/clean.
            if pattern.contains(":"),
               !pattern.contains("*"),
               !pattern.contains("/"),
               !pattern.contains("://"),
               !pattern.contains("?"),
               !pattern.contains("#"),
               !pattern.contains("@"),
               !pattern.contains(where: \.isWhitespace) {
                var a6 = in6_addr()
                if inet_pton(AF_INET6, pattern, &a6) == 1 {
                    let bytes = withUnsafeBytes(of: &a6) { Array($0) }
                    return LocalAddress.classifyV6Bytes(bytes) == .privateLAN
                }
            }
            return false
        }

        guard pattern != "*", pattern != "*.*", !pattern.hasSuffix(".*") else {
            return false
        }

        if pattern.hasPrefix("*.") {
            let suffix = String(pattern.dropFirst(2))
            guard !suffix.isEmpty, !suffix.contains("*"), !LocalAddress.isLiteralIP(suffix) else {
                return false
            }
            let privateSuffixes = [".local", ".lan", ".internal", ".home.arpa", ".ts.net"]
            let exactPrivateTLDs = ["local", "lan", "internal", "home.arpa", "ts.net"]
            guard exactPrivateTLDs.contains(suffix) || privateSuffixes.contains(where: { suffix.hasSuffix($0) }) else {
                return false
            }
            if suffix == "localhost" || suffix.hasSuffix(".localhost") { return false }
            let probe = "probe.\(suffix)"
            guard let url = URL(string: "https://\(probe)/") else { return false }
            let kind = LocalAddress.classifyLiteral(url)
            return kind == .privateLAN || kind == .cgnatMesh
        }

        guard !pattern.contains("*") else { return false }
        if pattern == "localhost" || pattern.hasSuffix(".localhost") { return false }
        guard let url = URL(string: "https://\(pattern)/") else { return false }
        let kind = LocalAddress.classifyLiteral(url)
        return kind == .privateLAN || kind == .cgnatMesh
    }

    public func matchesHost(_ rawHost: String, port targetPort: Int?, scheme: String) -> Bool {
        let host = Self.normalizePattern(rawHost)
        guard !host.isEmpty else { return false }
        let schemeLower = scheme.lowercased()
        guard schemeLower == "https" || (allowPlainHTTP && schemeLower == "http") else {
            return false
        }
        if let port, targetPort != port {
            return false
        }
        let pattern = Self.normalizePattern(hostPattern)
        if pattern.hasPrefix("*.") {
            let suffix = String(pattern.dropFirst(2))
            return host == suffix || host.hasSuffix(".\(suffix)")
        }
        return host == pattern
    }
}

extension LocalAddress {
    public enum AddressKind: String, Equatable, Sendable {
        case publicAddress
        case fakeIPRange
        case privateLAN
        case cgnatMesh
        case loopbackOrMetadata
    }

    public static func isLiteralIP(_ rawHost: String) -> Bool {
        var host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if let zone = host.firstIndex(of: "%") { host = String(host[..<zone]) }
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return false }
        if host.contains(":") {
            var a6 = in6_addr()
            return inet_pton(AF_INET6, host, &a6) == 1
        }
        var a4 = in_addr()
        if inet_aton(host, &a4) != 0 { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy { part in
            guard !part.isEmpty else { return false }
            if part.hasPrefix("0x") {
                let hex = part.dropFirst(2)
                return !hex.isEmpty && hex.allSatisfy(\.isHexDigit)
            }
            return part.allSatisfy(\.isNumber)
        }
    }

    public static func classifyV4(_ b: [UInt8]) -> AddressKind {
        guard b.count == 4 else { return .loopbackOrMetadata }
        if b[0] >= 224 { return .loopbackOrMetadata }
        switch (b[0], b[1]) {
        case (0, _), (127, _), (169, 254):
            return .loopbackOrMetadata
        case (10, _), (192, 168), (172, 16...31):
            return .privateLAN
        case (100, 64...127):
            return .cgnatMesh
        case (198, 18...19):
            return .fakeIPRange
        default:
            return .publicAddress
        }
    }

    public static func classifyV6Bytes(_ b: [UInt8]) -> AddressKind {
        guard b.count == 16 else { return .loopbackOrMetadata }
        // :: (unspecified) and ::1 (loopback)
        if b[0..<15].allSatisfy({ $0 == 0 }) && (b[15] == 0 || b[15] == 1) {
            return .loopbackOrMetadata
        }
        // ff00::/8 (multicast)
        if b[0] == 0xff {
            return .loopbackOrMetadata
        }
        // fd00:ec2::254 (AWS IPv6 IMDS)
        if b[0] == 0xfd && b[1] == 0x00 && b[2] == 0x0e && b[3] == 0xc2
            && b[4..<14].allSatisfy({ $0 == 0 }) && b[14] == 0x02 && b[15] == 0x54 {
            return .loopbackOrMetadata
        }
        // ::ffff:0:0/96 (IPv4-mapped IPv6) & 64:ff9b::/96 (NAT64)
        if (b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff)
            || (b[0] == 0x00 && b[1] == 0x64 && b[2] == 0xff && b[3] == 0x9b && b[4..<12].allSatisfy({ $0 == 0 })) {
            return classifyV4(Array(b[12..<16]))
        }
        // fe80::/10 (link-local)
        if b[0] == 0xfe && (b[1] & 0xc0) == 0x80 {
            return .loopbackOrMetadata
        }
        // fc00::/7 (unique local IPv6)
        if (b[0] & 0xfe) == 0xfc {
            return .privateLAN
        }
        return .publicAddress
    }

    public static func classifyLiteral(_ url: URL) -> AddressKind {
        if url.user != nil || url.password != nil {
            return .loopbackOrMetadata
        }
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           components.user != nil || components.password != nil
            || components.percentEncodedUser != nil || components.percentEncodedPassword != nil {
            return .loopbackOrMetadata
        }
        guard var host = url.host?.lowercased(), !host.isEmpty else {
            return .loopbackOrMetadata
        }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if let zone = host.firstIndex(of: "%") { host = String(host[..<zone]) }
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return .loopbackOrMetadata }

        if host == "localhost" || host.hasSuffix(".localhost") {
            return .loopbackOrMetadata
        }
        if host.hasSuffix(".ts.net") {
            return .cgnatMesh
        }
        if host.hasSuffix(".local") || host.hasSuffix(".lan") || host.hasSuffix(".internal")
            || host.hasSuffix(".home.arpa") || (!host.contains(".") && !host.contains(":")) {
            return .privateLAN
        }
        if host.contains(":") {
            var addr6 = in6_addr()
            guard inet_pton(AF_INET6, host, &addr6) == 1 else { return .loopbackOrMetadata }
            let bytes = withUnsafeBytes(of: &addr6) { Array($0) }
            return classifyV6Bytes(bytes)
        }
        var addr4 = in_addr()
        if inet_aton(host, &addr4) != 0 {
            let bytes = withUnsafeBytes(of: &addr4) { Array($0) }
            return classifyV4(bytes)
        }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let numeric = !parts.isEmpty && parts.allSatisfy { part in
            guard !part.isEmpty else { return false }
            if part.hasPrefix("0x") {
                let hex = part.dropFirst(2)
                return !hex.isEmpty && hex.allSatisfy(\.isHexDigit)
            }
            return part.allSatisfy(\.isNumber)
        }
        if numeric {
            return .loopbackOrMetadata
        }
        return .publicAddress
    }

    public static func resolveAddressKinds(_ rawHost: String) -> [AddressKind] {
        var host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if let zone = host.firstIndex(of: "%") { host = String(host[..<zone]) }
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return [] }

        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let head = result else {
            return []
        }
        defer { freeaddrinfo(head) }

        var kinds: [AddressKind] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = head
        while let current = cursor {
            let info = current.pointee
            if let sa = info.ai_addr {
                let kind: AddressKind?
                if info.ai_family == AF_INET {
                    var sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                    let bytes = withUnsafeBytes(of: &sin) { Array($0) }
                    kind = classifyV4(bytes)
                } else if info.ai_family == AF_INET6 {
                    var sin6 = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                    let bytes = withUnsafeBytes(of: &sin6) { Array($0) }
                    kind = classifyV6Bytes(bytes)
                } else {
                    kind = nil
                }
                if let kind, !kinds.contains(kind) {
                    kinds.append(kind)
                }
            }
            cursor = info.ai_next
        }
        return kinds
    }
}

/// Evaluates network requests against the 5-domain model, opt-in Fake-IP proxy compatibility,
/// and user-scoped persistent private network grants without weakening baseline SSRF checks.
public final class PrivateNetworkPolicy: @unchecked Sendable {
    public static let shared = PrivateNetworkPolicy()

    public static let fakeIPCompatKey = "net.fakeIPCompat"
    public static let grantsKey = "net.privateGrants"

    public struct Evaluation: Equatable, Sendable {
        public let allowed: Bool
        public let domain: NetworkAccessDomain
        public let diagnostic: NetworkDiagnosticCategory?
        public let matchedGrant: PrivateNetworkGrant?
        public let reason: String?
    }

    private let lock = NSLock()
    private let defaults: UserDefaults
    private var storedFakeIPCompat: Bool
    private var storedGrants: [PrivateNetworkGrant]
    private var storedRevision: UInt64 = 0

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.storedFakeIPCompat = defaults.bool(forKey: Self.fakeIPCompatKey)
        if let data = defaults.data(forKey: Self.grantsKey),
           let decoded = try? JSONDecoder().decode([PrivateNetworkGrant].self, from: data) {
            self.storedGrants = decoded.filter { PrivateNetworkGrant.isValidPattern($0.hostPattern) }
        } else {
            self.storedGrants = []
        }
    }

    public var fakeIPCompatEnabled: Bool {
        get { lock.withLock { storedFakeIPCompat } }
        set {
            lock.withLock {
                storedFakeIPCompat = newValue
                defaults.set(newValue, forKey: Self.fakeIPCompatKey)
                storedRevision &+= 1
            }
        }
    }

    public var grants: [PrivateNetworkGrant] {
        lock.withLock { storedGrants }
    }

    public var revision: UInt64 {
        lock.withLock { storedRevision }
    }

    @discardableResult
    public func addGrant(_ grant: PrivateNetworkGrant) -> Bool {
        guard PrivateNetworkGrant.isValidPattern(grant.hostPattern) else { return false }
        let normalized = PrivateNetworkGrant(
            id: grant.id,
            label: grant.label.isEmpty ? grant.hostPattern : grant.label,
            hostPattern: grant.hostPattern,
            port: grant.port,
            allowPlainHTTP: grant.allowPlainHTTP,
            maxAction: grant.maxAction,
            createdAt: grant.createdAt
        )
        lock.withLock {
            storedGrants.removeAll { $0.id == normalized.id }
            storedGrants.append(normalized)
            persistGrantsLocked()
            storedRevision &+= 1
        }
        return true
    }

    public func revokeGrant(id: String) {
        lock.withLock {
            let before = storedGrants.count
            storedGrants.removeAll { $0.id == id }
            if storedGrants.count != before {
                persistGrantsLocked()
                storedRevision &+= 1
            }
        }
    }

    public func revokeAll() {
        lock.withLock {
            guard !storedGrants.isEmpty else { return }
            storedGrants.removeAll()
            persistGrantsLocked()
            storedRevision &+= 1
        }
    }

    private func persistGrantsLocked() {
        if let data = try? JSONEncoder().encode(storedGrants) {
            defaults.set(data, forKey: Self.grantsKey)
        }
    }

    public func evaluate(
        url: URL,
        action: PrivateNetworkAction = .read,
        allowAuthorizedPrivate: Bool = false,
        hasCredentials: Bool = false,
        resolvedKinds: [LocalAddress.AddressKind]? = nil
    ) -> Evaluation {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else {
            return Evaluation(
                allowed: false,
                domain: .authorizedPrivate,
                diagnostic: .unauthorizedPrivate,
                matchedGrant: nil,
                reason: NetworkDiagnosticCategory.unauthorizedPrivate.userMessage
            )
        }

        let effectivePort = url.port ?? (scheme == "https" ? 443 : 80)
        let literalKind = LocalAddress.classifyLiteral(url)
        let (fakeIPOn, activeGrants) = lock.withLock { (storedFakeIPCompat, storedGrants) }

        switch literalKind {
        case .loopbackOrMetadata:
            return Evaluation(
                allowed: false,
                domain: .authorizedPrivate,
                diagnostic: .unauthorizedPrivate,
                matchedGrant: nil,
                reason: NetworkDiagnosticCategory.unauthorizedPrivate.userMessage
            )

        case .fakeIPRange:
            return Evaluation(
                allowed: false,
                domain: .fakeIPProxy,
                diagnostic: .fakeIPPlaceholder,
                matchedGrant: nil,
                reason: NetworkDiagnosticCategory.fakeIPPlaceholder.userMessage
            )

        case .privateLAN, .cgnatMesh:
            let domain: NetworkAccessDomain = literalKind == .cgnatMesh ? .privateMesh : .authorizedPrivate
            guard allowAuthorizedPrivate else {
                return Evaluation(
                    allowed: false,
                    domain: domain,
                    diagnostic: .unauthorizedPrivate,
                    matchedGrant: nil,
                    reason: NetworkDiagnosticCategory.unauthorizedPrivate.userMessage
                )
            }
            return matchPrivateGrant(
                grants: activeGrants,
                host: host,
                port: effectivePort,
                scheme: scheme,
                domain: domain,
                action: action,
                hasCredentials: hasCredentials
            )

        case .publicAddress:
            let kinds: [LocalAddress.AddressKind]
            if let resolvedKinds {
                kinds = resolvedKinds
            } else if LocalAddress.isLiteralIP(host) {
                kinds = []
            } else {
                kinds = LocalAddress.resolveAddressKinds(host)
            }

            if kinds.isEmpty || kinds.allSatisfy({ $0 == .publicAddress }) {
                return Evaluation(allowed: true, domain: .publicWeb, diagnostic: nil, matchedGrant: nil, reason: nil)
            }

            if kinds.contains(.loopbackOrMetadata) {
                let diag: NetworkDiagnosticCategory = kinds.count > 1 ? .mixedDNSAnomaly : .unauthorizedPrivate
                return Evaluation(allowed: false, domain: .authorizedPrivate, diagnostic: diag, matchedGrant: nil, reason: diag.userMessage)
            }

            if kinds.contains(.fakeIPRange) {
                if kinds.contains(.privateLAN) || kinds.contains(.cgnatMesh) {
                    return Evaluation(
                        allowed: false,
                        domain: .fakeIPProxy,
                        diagnostic: .mixedDNSAnomaly,
                        matchedGrant: nil,
                        reason: NetworkDiagnosticCategory.mixedDNSAnomaly.userMessage
                    )
                }
                if fakeIPOn && !LocalAddress.isLiteralIP(host) {
                    if scheme == "https" || (!hasCredentials && action == .read) {
                        return Evaluation(allowed: true, domain: .fakeIPProxy, diagnostic: nil, matchedGrant: nil, reason: nil)
                    }
                    return Evaluation(
                        allowed: false,
                        domain: .fakeIPProxy,
                        diagnostic: .scopeEscalationBlocked,
                        matchedGrant: nil,
                        reason: NetworkDiagnosticCategory.scopeEscalationBlocked.userMessage
                    )
                }
                return Evaluation(
                    allowed: false,
                    domain: .fakeIPProxy,
                    diagnostic: .fakeIPPlaceholder,
                    matchedGrant: nil,
                    reason: NetworkDiagnosticCategory.fakeIPPlaceholder.userMessage
                )
            }

            // DNS resolved a domain name to privateLAN or cgnatMesh addresses.
            if kinds.contains(.publicAddress) {
                return Evaluation(
                    allowed: false,
                    domain: .authorizedPrivate,
                    diagnostic: .mixedDNSAnomaly,
                    matchedGrant: nil,
                    reason: NetworkDiagnosticCategory.mixedDNSAnomaly.userMessage
                )
            }

            let resolvedDomain: NetworkAccessDomain = kinds.contains(.cgnatMesh) && !kinds.contains(.privateLAN)
                ? .privateMesh
                : .authorizedPrivate
            guard allowAuthorizedPrivate else {
                return Evaluation(
                    allowed: false,
                    domain: resolvedDomain,
                    diagnostic: .unauthorizedPrivate,
                    matchedGrant: nil,
                    reason: NetworkDiagnosticCategory.unauthorizedPrivate.userMessage
                )
            }
            return matchPrivateGrant(
                grants: activeGrants,
                host: host,
                port: effectivePort,
                scheme: scheme,
                domain: resolvedDomain,
                action: action,
                hasCredentials: hasCredentials
            )
        }
    }

    public func evaluateAsync(
        url: URL,
        action: PrivateNetworkAction = .read,
        allowAuthorizedPrivate: Bool = false,
        hasCredentials: Bool = false
    ) async -> Evaluation {
        guard let host = url.host, !host.isEmpty else {
            return evaluate(url: url, action: action, allowAuthorizedPrivate: allowAuthorizedPrivate, hasCredentials: hasCredentials, resolvedKinds: [])
        }
        let literal = LocalAddress.classifyLiteral(url)
        if literal != .publicAddress || LocalAddress.isLiteralIP(host) {
            return evaluate(url: url, action: action, allowAuthorizedPrivate: allowAuthorizedPrivate, hasCredentials: hasCredentials, resolvedKinds: [])
        }
        let cleanHost = Self.cleanHostForLookup(host)
        let kinds = await Task.detached(priority: .utility) {
            LocalAddress.resolveAddressKinds(cleanHost)
        }.value
        return evaluate(
            url: url,
            action: action,
            allowAuthorizedPrivate: allowAuthorizedPrivate,
            hasCredentials: hasCredentials,
            resolvedKinds: kinds
        )
    }

    private func matchPrivateGrant(
        grants: [PrivateNetworkGrant],
        host: String,
        port: Int,
        scheme: String,
        domain: NetworkAccessDomain,
        action: PrivateNetworkAction,
        hasCredentials: Bool
    ) -> Evaluation {
        let matching = grants.filter { $0.matchesHost(host, port: port, scheme: scheme) }
        guard !matching.isEmpty else {
            return Evaluation(
                allowed: false,
                domain: domain,
                diagnostic: .unauthorizedPrivate,
                matchedGrant: nil,
                reason: NetworkDiagnosticCategory.unauthorizedPrivate.userMessage
            )
        }
        if scheme != "https" && (hasCredentials || action >= .credential) {
            return Evaluation(
                allowed: false,
                domain: domain,
                diagnostic: .scopeEscalationBlocked,
                matchedGrant: matching.first,
                reason: NetworkDiagnosticCategory.scopeEscalationBlocked.userMessage
            )
        }
        if let sufficient = matching.first(where: { action <= $0.maxAction }) {
            return Evaluation(allowed: true, domain: domain, diagnostic: nil, matchedGrant: sufficient, reason: nil)
        }
        return Evaluation(
            allowed: false,
            domain: domain,
            diagnostic: .scopeEscalationBlocked,
            matchedGrant: matching.first,
            reason: NetworkDiagnosticCategory.scopeEscalationBlocked.userMessage
        )
    }

    private static func cleanHostForLookup(_ rawHost: String) -> String {
        var host = rawHost.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if let zone = host.firstIndex(of: "%") { host = String(host[..<zone]) }
        if host.hasSuffix(".") { host.removeLast() }
        return host
    }

    public static func diagnoseTransportError(_ error: Error, url: URL) -> NetworkDiagnosticCategory? {
        let urlError: URLError?
        if let direct = error as? URLError {
            urlError = direct
        } else {
            let ns = error as NSError
            urlError = ns.domain == NSURLErrorDomain ? URLError(_nsError: ns) : nil
        }
        guard let urlError else { return nil }
        switch urlError.code {
        case .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
             .secureConnectionFailed:
            return .tlsCertificateMismatch
        case .cannotConnectToHost, .timedOut, .networkConnectionLost,
             .notConnectedToInternet, .cannotFindHost, .dnsLookupFailed:
            let literal = LocalAddress.classifyLiteral(url)
            if literal == .privateLAN || literal == .cgnatMesh {
                return .unreachableOrLocalNet
            }
            return nil
        default:
            return nil
        }
    }
}
