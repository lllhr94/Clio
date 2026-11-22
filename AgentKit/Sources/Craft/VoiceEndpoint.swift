import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum VoiceEndpointError: LocalizedError, Equatable {
    case empty
    case invalidFormat
    case embeddedCredentials
    case queryOrFragmentNotAllowed
    case requiresHTTPS

    public var errorDescription: String? {
        switch self {
        case .empty:
            return "还没填语音转写接口地址，请去 设置 › 对话显示与反馈 › 语音输入与转写 配置。"
        case .invalidFormat:
            return "语音转写接口地址格式不对，请填写完整的 https:// 地址。"
        case .embeddedCredentials:
            return "接口地址不能包含用户名或密码，请把密钥填到下方的本机钥匙串栏里。"
        case .queryOrFragmentNotAllowed:
            return "接口地址不能包含查询参数（?）或片段（#），请只填写纯服务地址；密钥请填到下方的本机钥匙串栏里。"
        case .requiresHTTPS:
            return "公网或域名语音转写地址必须使用 https://；只有明确的本机或局域网 IP（如 127.0.0.1、192.168.x.x）允许 http://。"
        }
    }
}

/// Validates standalone speech-to-text URLs, enforces strict transport/same-origin redirect rules,
/// and computes normalized origin keys for per-service Keychain credential isolation.
public enum VoiceEndpoint {
    /// Fully parsed, sanitized endpoint data safe to persist (`baseURL` has no credentials, query, or fragment).
    public struct Parsed: Equatable, Sendable {
        public let baseURL: String
        public let endpoint: URL
        public let originKey: String
    }

    /// Returns true if the raw text looks like it carries embedded `user[:pass]@` authority credentials.
    public static func containsEmbeddedCredentials(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        if let components = URLComponents(string: candidate),
           (components.user != nil || components.password != nil
            || components.percentEncodedUser != nil || components.percentEncodedPassword != nil) {
            return true
        }
        // Fallback string check before the first `/`, `?`, or `#` in case of malformed URLs containing `@`.
        let withoutScheme: Substring
        if let range = candidate.range(of: "://") {
            withoutScheme = candidate[range.upperBound...]
        } else {
            withoutScheme = Substring(candidate)
        }
        let authority = withoutScheme.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        return authority.contains("@")
    }

    /// Parses and validates a base URL with `URLComponents`, forbidding embedded credentials, query strings,
    /// and fragments, and builds the normalized `/audio/transcriptions` endpoint URL.
    /// Plaintext HTTP is allowed ONLY for explicit loopback or private IP literals (no domain/mDNS shortcuts).
    public static func parse(_ rawBase: String) -> Result<Parsed, VoiceEndpointError> {
        let trimmed = rawBase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        if containsEmbeddedCredentials(trimmed) {
            return .failure(.embeddedCredentials)
        }
        if trimmed.contains("?") || trimmed.contains("#") {
            return .failure(.queryOrFragmentNotAllowed)
        }

        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard var baseComponents = URLComponents(string: candidate) else {
            return .failure(.invalidFormat)
        }
        if baseComponents.user != nil || baseComponents.password != nil
            || baseComponents.percentEncodedUser != nil || baseComponents.percentEncodedPassword != nil {
            return .failure(.embeddedCredentials)
        }
        if baseComponents.query != nil || baseComponents.percentEncodedQuery != nil
            || baseComponents.fragment != nil || baseComponents.percentEncodedFragment != nil {
            return .failure(.queryOrFragmentNotAllowed)
        }
        guard let scheme = baseComponents.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = baseComponents.host, !host.isEmpty else {
            return .failure(.invalidFormat)
        }
        baseComponents.scheme = scheme

        var cleanPath = baseComponents.path
        while cleanPath.hasSuffix("/") {
            cleanPath.removeLast()
        }
        baseComponents.path = cleanPath

        guard let canonicalBase = baseComponents.url else {
            return .failure(.invalidFormat)
        }

        var endpointComponents = baseComponents
        let lowerPath = cleanPath.lowercased()
        if lowerPath.hasSuffix("/audio/transcriptions") {
            endpointComponents.path = cleanPath
        } else if lowerPath.hasSuffix("/v1") || lowerPath.hasSuffix("/openai/v1") {
            endpointComponents.path = cleanPath + "/audio/transcriptions"
        } else {
            endpointComponents.path = cleanPath + "/v1/audio/transcriptions"
        }

        guard let endpoint = endpointComponents.url else {
            return .failure(.invalidFormat)
        }
        guard allowsTransport(endpoint) else {
            return .failure(.requiresHTTPS)
        }
        guard let key = Self.originKey(for: endpoint) else {
            return .failure(.invalidFormat)
        }
        return .success(Parsed(baseURL: canonicalBase.absoluteString, endpoint: endpoint, originKey: key))
    }

    /// Convenience wrapper returning only the validated `/audio/transcriptions` endpoint URL.
    public static func validate(_ rawBase: String) -> Result<URL, VoiceEndpointError> {
        parse(rawBase).map(\.endpoint)
    }

    /// True when the URL satisfies transport security and carries no credentials, query, or fragment:
    /// HTTPS for any valid host, or HTTP strictly for explicit private/loopback IP literals.
    public static func allowsTransport(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.percentEncodedUser == nil, components.percentEncodedPassword == nil,
              components.query == nil, components.percentEncodedQuery == nil,
              components.fragment == nil, components.percentEncodedFragment == nil else {
            return false
        }
        if scheme == "https" { return true }
        if scheme == "http" { return isExplicitPrivateOrLoopbackIP(host) }
        return false
    }

    /// Redirect policy for authenticated speech-to-text uploads: must stay on the EXACT same origin and valid transport.
    public static func allowsRedirect(from origin: URL, to next: URL) -> Bool {
        guard allowsTransport(origin), allowsTransport(next),
              let sourceKey = Self.originKey(for: origin),
              let nextKey = Self.originKey(for: next) else {
            return false
        }
        return sourceKey == nextKey
    }

    /// Normalized `(scheme, host, effectivePort)` key for isolating saved Keychain credentials per service origin.
    public static func originKey(for url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let rawHost = url.host?.lowercased(), !rawHost.isEmpty else {
            return nil
        }
        let host = (rawHost.contains(":") && !rawHost.hasPrefix("[")) ? "[\(rawHost)]" : rawHost
        let defaultPort = scheme == "https" ? 443 : 80
        let port = url.port ?? defaultPort
        return "\(scheme)://\(host):\(port)"
    }

    /// True ONLY for explicit IPv4 or IPv6 loopback / RFC-1918 / ULA / link-local IP literals (strict `inet_pton`).
    /// Hostnames (including `localhost`, `.local`, or bare words) return false and therefore require HTTPS.
    public static func isExplicitPrivateOrLoopbackIP(_ rawHost: String) -> Bool {
        var host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        if let zone = host.firstIndex(of: "%") {
            host = String(host[..<zone])
        }
        guard !host.isEmpty else { return false }

        // Strict dotted-quad IPv4 check via inet_pton (rejects shorthand/octal/hex forms and hostnames).
        var addr4 = in_addr()
        if inet_pton(AF_INET, host, &addr4) == 1 {
            let bytes = withUnsafeBytes(of: &addr4) { Array($0) }
            return bytes.count == 4 && isPrivateOrLoopbackV4(bytes)
        }

        // Strict IPv6 literal check via inet_pton.
        var addr6 = in6_addr()
        if inet_pton(AF_INET6, host, &addr6) == 1 {
            let bytes = withUnsafeBytes(of: &addr6) { Array($0) }
            return bytes.count == 16 && isPrivateOrLoopbackV6(bytes)
        }

        return false
    }

    private static func isPrivateOrLoopbackV4(_ b: [UInt8]) -> Bool {
        b[0] == 127                                      // 127.0.0.0/8 loopback
            || b[0] == 10                                // 10.0.0.0/8 RFC 1918
            || (b[0] == 172 && (16...31).contains(b[1])) // 172.16.0.0/12 RFC 1918
            || (b[0] == 192 && b[1] == 168)              // 192.168.0.0/16 RFC 1918
            || (b[0] == 169 && b[1] == 254)              // 169.254.0.0/16 link-local
    }

    private static func isPrivateOrLoopbackV6(_ b: [UInt8]) -> Bool {
        let isLoopback = b[0..<15].allSatisfy { $0 == 0 } && b[15] == 1
        if isLoopback { return true }
        // IPv4-mapped ::ffff:a.b.c.d
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff {
            return isPrivateOrLoopbackV4(Array(b[12..<16]))
        }
        // Unique local fc00::/7 or link-local fe80::/10
        return (b[0] & 0xfe) == 0xfc || (b[0] == 0xfe && (b[1] & 0xc0) == 0x80)
    }
}
