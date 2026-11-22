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
    case requiresHTTPS

    public var errorDescription: String? {
        switch self {
        case .empty:
            return "还没填语音转写接口地址，请去 设置 › 对话显示与反馈 › 语音输入与转写 配置。"
        case .invalidFormat:
            return "语音转写接口地址格式不对，请填写完整的 https:// 地址。"
        case .embeddedCredentials:
            return "接口地址不能包含用户名或密码，请把密钥填到下方的本机钥匙串栏里。"
        case .requiresHTTPS:
            return "公网或域名语音转写地址必须使用 https://；只有明确的本机或局域网 IP（如 127.0.0.1、192.168.x.x）允许 http://。"
        }
    }
}

/// Validates standalone speech-to-text URLs, enforces strict transport/same-origin redirect rules,
/// and computes normalized origin keys for per-service Keychain credential isolation.
public enum VoiceEndpoint {
    /// Returns true if the raw text looks like it carries embedded `user[:pass]@` authority credentials.
    public static func containsEmbeddedCredentials(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let candidate = trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://")
            ? trimmed
            : "https://" + trimmed
        if let components = URLComponents(string: candidate),
           (components.user != nil || components.password != nil) {
            return true
        }
        // Fallback string check before the first `/` in case of malformed URLs containing `@`.
        let withoutScheme: Substring
        if let range = candidate.range(of: "://") {
            withoutScheme = candidate[range.upperBound...]
        } else {
            withoutScheme = Substring(candidate)
        }
        let authority = withoutScheme.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return authority.contains("@")
    }

    /// Validates and resolves a base URL into `/audio/transcriptions`.
    /// Plaintext HTTP is allowed ONLY for explicit loopback or private IP literals (no domain/mDNS shortcuts).
    public static func validate(_ rawBase: String) -> Result<URL, VoiceEndpointError> {
        var trimmed = rawBase.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return .failure(.empty) }
        if containsEmbeddedCredentials(trimmed) {
            return .failure(.embeddedCredentials)
        }
        let lowerInitial = trimmed.lowercased()
        if !lowerInitial.hasPrefix("http://") && !lowerInitial.hasPrefix("https://") {
            trimmed = "https://" + trimmed
        }
        let lower = trimmed.lowercased()
        let full: String
        if lower.hasSuffix("/audio/transcriptions") {
            full = trimmed
        } else if lower.hasSuffix("/v1") || lower.hasSuffix("/openai/v1") {
            full = trimmed + "/audio/transcriptions"
        } else {
            full = trimmed + "/v1/audio/transcriptions"
        }
        guard let url = URL(string: full),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty else {
            return .failure(.invalidFormat)
        }
        if url.user != nil || url.password != nil {
            return .failure(.embeddedCredentials)
        }
        guard allowsTransport(url) else {
            return .failure(.requiresHTTPS)
        }
        return .success(url)
    }

    /// True when the URL satisfies transport security: HTTPS for any valid host, or HTTP strictly for explicit private/loopback IP literals.
    public static func allowsTransport(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else {
            return false
        }
        if scheme == "https" { return true }
        if scheme == "http" { return isExplicitPrivateOrLoopbackIP(host) }
        return false
    }

    /// Redirect policy for authenticated speech-to-text uploads: must stay on the EXACT same origin and valid transport.
    public static func allowsRedirect(from origin: URL, to next: URL) -> Bool {
        guard allowsTransport(origin), allowsTransport(next),
              let originKey = originKey(for: origin),
              let nextKey = originKey(for: next) else {
            return false
        }
        return originKey == nextKey
    }

    /// Normalized `(scheme, host, effectivePort)` key for isolating saved Keychain credentials per service origin.
    public static func originKey(for url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host?.lowercased(), !host.isEmpty else {
            return nil
        }
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
