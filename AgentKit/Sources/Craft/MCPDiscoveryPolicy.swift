import AgentKit
import Foundation

public enum URLAccessPurpose: Equatable, Sendable {
    case oauthEndpoint, skillDownload, remoteImage

    public func acceptsURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), url.host?.isEmpty == false,
              url.user == nil, url.password == nil,
              LocalAddress.classifyLiteral(url) == .publicAddress else { return false }
        switch self {
        case .oauthEndpoint, .skillDownload: return scheme == "https"
        case .remoteImage: return scheme == "http" || scheme == "https"
        }
    }

    public func allows(_ url: URL, policy: PrivateNetworkPolicy = .shared) async -> Bool {
        guard acceptsURL(url) else { return false }
        return await policy.evaluateAsync(
            url: url, action: .read, allowAuthorizedPrivate: false, hasCredentials: self == .oauthEndpoint
        ).allowed
    }
}

public enum MCPCallbackTransport: Equatable, Sendable {
    case loopbackSafariVC
    case rejectedHTTPSUnsupported(reason: String)
    case legacyCustomScheme
    case unsupported(reason: String)

    public var isMCP20251125Subset: Bool { self == .loopbackSafariVC }

    public static func route(_ url: URL) -> Self {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else {
            return .unsupported(reason: "回调地址不能带账号、参数或片段。")
        }
        switch parts.scheme?.lowercased() {
        case "http" where parts.host == "127.0.0.1" && parts.percentEncodedPath == "/callback":
            if let port = url.port, (1...65535).contains(port) { return .loopbackSafariVC }
            return .unsupported(reason: "本机回调需要指定端口。")
        case "https":
            return .rejectedHTTPSUnsupported(reason: "此版本不支持 HTTPS 回调，请使用 http://127.0.0.1:<端口>/callback。")
        case "clio" where parts.host == "oauth" && parts.percentEncodedPath == "/mcp" && parts.port == nil:
            return .legacyCustomScheme
        default:
            return .unsupported(reason: "请使用 http://127.0.0.1:<端口>/callback。")
        }
    }
}

public struct MCPDCRCacheKey: Hashable, Codable, Sendable {
    public let issuer: String
    public let registrationEndpoint: String
    public let redirectURI: String
    public let manualStaticClientID: String?

    public init(issuer: String, registrationEndpoint: String, redirectURI: String, manualStaticClientID: String?) {
        self.issuer = issuer
        self.registrationEndpoint = registrationEndpoint
        self.redirectURI = redirectURI
        self.manualStaticClientID = manualStaticClientID
    }
}

public enum MCPDiscoveryPolicy {
    public static let protocolVersion = "2025-11-25"

    public struct Challenge: Equatable, Sendable {
        public let scheme: String
        public fileprivate(set) var parameters: [String: String]
    }

    /// Commas separate parameters and challenges, except inside quoted strings.
    public static func challenges(_ header: String) -> [Challenge] {
        var fields: [String] = []
        var field = ""
        var quoted = false
        var escaped = false
        for character in header {
            if escaped {
                escaped = false
            } else if quoted && character == "\\" {
                escaped = true
            } else if character == "\"" {
                quoted.toggle()
            } else if character == "," && !quoted {
                fields.append(field)
                field = ""
                continue
            }
            field.append(character)
        }
        if !quoted { fields.append(field) }

        var result: [Challenge] = []
        for raw in fields {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let head = trimmed.prefix { !$0.isWhitespace && $0 != "=" }
            guard !head.isEmpty else { continue }
            let rest = trimmed.dropFirst(head.count).trimmingCharacters(in: .whitespaces)
            var parameter = trimmed
            if !rest.hasPrefix("=") {
                result.append(Challenge(scheme: head.lowercased(), parameters: [:]))
                parameter = rest
            }
            guard !result.isEmpty, let equals = parameter.firstIndex(of: "=") else { continue }
            let name = parameter[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            var value = parameter[parameter.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            if value.hasPrefix("\"") {
                guard value.count >= 2, value.hasSuffix("\"") else { continue }
                var unquoted = ""
                var escape = false
                for character in value.dropFirst().dropLast() {
                    if !escape && character == "\\" { escape = true; continue }
                    unquoted.append(character)
                    escape = false
                }
                value = unquoted
            }
            let index = result.count - 1
            if result[index].parameters[name] == nil { result[index].parameters[name] = value }
        }
        return result
    }

    public static func scope(challenge: String?, minimal: String?) -> String? {
        for candidate in [challenge, minimal] {
            if let clean = candidate?.split(whereSeparator: { $0.isWhitespace }).joined(separator: " "), !clean.isEmpty {
                return clean
            }
        }
        return nil
    }

    public static func canonicalResource(_ url: URL) -> String? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil else { return nil }
        parts.scheme = scheme
        parts.host = host
        if (scheme == "https" && parts.port == 443) || (scheme == "http" && parts.port == 80) {
            parts.port = nil
        }
        parts.query = nil
        parts.fragment = nil
        return parts.string
    }

    public static func normalizedIssuer(_ url: URL) -> String? {
        guard url.query == nil, url.fragment == nil, let canonical = canonicalResource(url) else { return nil }
        return canonical.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
    }

    private static func wellKnown(_ url: URL, _ name: String) -> (path: URL, root: URL)? {
        guard let canonical = canonicalResource(url), var parts = URLComponents(string: canonical) else { return nil }
        let path = parts.percentEncodedPath == "/" ? "" : parts.percentEncodedPath
        parts.percentEncodedPath = "/.well-known/" + name + path
        guard let specific = parts.url else { return nil }
        parts.percentEncodedPath = "/.well-known/" + name
        guard let root = parts.url else { return nil }
        return (specific, root)
    }

    public static func resourceMetadataCandidates(resource: URL, pointer: URL?) -> [URL] {
        var candidates = pointer.map { [$0] } ?? []
        if let wellKnown = wellKnown(resource, "oauth-protected-resource") {
            candidates += [wellKnown.path, wellKnown.root]
        }
        var seen = Set<URL>()
        return candidates.filter { seen.insert($0).inserted }
    }

    public static func authorizationMetadataCandidates(issuer: URL) -> [URL] {
        guard let normalized = normalizedIssuer(issuer), let issuer = URL(string: normalized),
              let oauth = wellKnown(issuer, "oauth-authorization-server"),
              let oidc = wellKnown(issuer, "openid-configuration") else { return [] }
        var candidates = [oauth.path, oidc.path]
        if oidc.path != oidc.root { candidates.append(issuer.appendingPathComponent(".well-known/openid-configuration")) }
        return candidates
    }

    public struct ServerMetadata: Decodable, Equatable, Sendable {
        public let issuer: URL
        public let authorizationEndpoint: URL
        public let tokenEndpoint: URL
        public let registrationEndpoint: URL?
        public let codeChallengeMethodsSupported: [String]?

        private enum CodingKeys: String, CodingKey {
            case issuer
            case authorizationEndpoint = "authorization_endpoint"
            case tokenEndpoint = "token_endpoint"
            case registrationEndpoint = "registration_endpoint"
            case codeChallengeMethodsSupported = "code_challenge_methods_supported"
        }
    }

    public enum DiscoveryError: Error, Equatable, LocalizedError {
        case unsupportedServer(reason: String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedServer(let reason): return reason
            }
        }
    }

    public static func validate(_ metadata: ServerMetadata, expectedIssuer: URL) throws {
        guard URLAccessPurpose.oauthEndpoint.acceptsURL(metadata.issuer),
              let expected = normalizedIssuer(expectedIssuer), normalizedIssuer(metadata.issuer) == expected else {
            throw DiscoveryError.unsupportedServer(reason: "登录服务器身份与发现信息不符。")
        }
        guard metadata.codeChallengeMethodsSupported?.contains("S256") == true else {
            throw DiscoveryError.unsupportedServer(reason: "登录服务器未声明支持 PKCE S256。")
        }
        let endpoints = [metadata.authorizationEndpoint, metadata.tokenEndpoint] + (metadata.registrationEndpoint.map { [$0] } ?? [])
        guard endpoints.allSatisfy({ URLAccessPurpose.oauthEndpoint.acceptsURL($0) && $0.fragment == nil }) else {
            throw DiscoveryError.unsupportedServer(reason: "登录服务必须使用 HTTPS 公网端点。")
        }
    }
}
