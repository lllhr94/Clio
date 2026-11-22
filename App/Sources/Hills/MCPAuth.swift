import AgentKit
import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

/// Signing in to an MCP service the standard way (MCP authorization, OAuth 2.1): find the service's sign-in
/// server, register Clio with it, open its sign-in page, and keep the tokens in the Vault. This is what lets
/// Notion, Linear, Atlassian and the like connect with a tap instead of a pasted key.
@MainActor
final class MCPAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = MCPAuth()
    static let redirect = "clio://oauth/mcp"

    /// What is kept for one service, in the Vault under `mcp.oauth.<server id>`.
    struct Saved: Codable, Sendable {
        var clientId: String
        var clientSecret: String?
        var tokenEndpoint: String
        var resource: String
        var access: String
        var refresh: String?
        var until: Date?
    }

    private struct Ends {
        var authorize: String
        var token: String
        var register: String?
        var scopes: [String]
    }

    // MARK: Signing in

    /// The whole sign-in for one service. Throws with a sentence the person can act on.
    func login(server id: String, url: String) async throws {
        let ends = try await Self.discover(url)
        guard let register = ends.register else {
            throw ProviderError("这家服务不支持自动登记客户端，暂时只能用令牌连接。")
        }
        let client = try await Self.register(at: register)
        let verifier = Self.random(48)
        let state = Self.random(16)
        var parts = URLComponents(string: ends.authorize)
        var items = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: client.id),
            URLQueryItem(name: "redirect_uri", value: Self.redirect),
            URLQueryItem(name: "code_challenge", value: Data(SHA256.hash(data: Data(verifier.utf8))).base64URL),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "resource", value: url),
        ]
        if !ends.scopes.isEmpty { items.append(URLQueryItem(name: "scope", value: ends.scopes.joined(separator: " "))) }
        let existing = parts?.queryItems ?? []
        parts?.queryItems = existing + items
        guard let page = parts?.url else { throw ProviderError("登录地址不对。") }
        let back = try await authenticate(page)
        let answer = URLComponents(url: back, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = answer.first(where: { $0.name == "error" })?.value {
            throw ProviderError(error == "access_denied" ? "你在那边没同意。" : "登录没成：\(error)")
        }
        guard answer.first(where: { $0.name == "state" })?.value == state,
              let code = answer.first(where: { $0.name == "code" })?.value else { throw ProviderError("登录回来的信息对不上，再试一次。") }
        var form = ["grant_type": "authorization_code", "code": code, "redirect_uri": Self.redirect,
                    "client_id": client.id, "code_verifier": verifier, "resource": url]
        if let secret = client.secret { form["client_secret"] = secret }
        let tokens = try await Self.post(ends.token, form: form)
        guard let access = tokens["access_token"]?.string else { throw ProviderError("那边没给访问令牌。") }
        let saved = Saved(clientId: client.id, clientSecret: client.secret, tokenEndpoint: ends.token, resource: url,
                          access: access, refresh: tokens["refresh_token"]?.string,
                          until: tokens["expires_in"]?.number.map { Date().addingTimeInterval($0 - 60) })
        Self.keep(saved, for: id)
    }

    private func authenticate(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme("clio")) { url, error in
                if let url { continuation.resume(returning: url) }
                else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: ProviderError("登录取消了。"))
                } else { continuation.resume(throwing: error ?? ProviderError("登录没完成。")) }
            }
            session.presentationContextProvider = self
            if !session.start() { continuation.resume(throwing: ProviderError("打不开登录页。")) }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        }
    }

    // MARK: Tokens

    nonisolated static func signedIn(_ id: String) -> Bool { Vault.load(Data.self, key: "mcp.oauth.\(id)") != nil }

    nonisolated static func forget(_ id: String) { Vault.remove("mcp.oauth.\(id)") }

    nonisolated private static func keep(_ saved: Saved, for id: String) {
        if let data = try? JSONEncoder().encode(saved) { Vault.save(data, as: "mcp.oauth.\(id)") }
    }

    /// The access token for a signed-in service, renewed when it ran out (or when `stale`, after a 401).
    nonisolated static func bearer(_ id: String, stale: Bool = false) async throws -> String? {
        guard let data = Vault.load(Data.self, key: "mcp.oauth.\(id)"), var saved = try? JSONDecoder().decode(Saved.self, from: data) else { return nil }
        if !stale, saved.until.map({ $0 > Date() }) ?? true { return saved.access }
        guard let refresh = saved.refresh else { throw ProviderError("登录过期了，去「连接器」里重新登录。") }
        var form = ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": saved.clientId, "resource": saved.resource]
        if let secret = saved.clientSecret { form["client_secret"] = secret }
        let tokens: JSONValue
        do { tokens = try await post(saved.tokenEndpoint, form: form) } catch {
            throw ProviderError("登录过期了，去「连接器」里重新登录。（\(error.localizedDescription)）")
        }
        guard let access = tokens["access_token"]?.string else { throw ProviderError("续不上登录，去「连接器」里重新登录。") }
        saved.access = access
        if let next = tokens["refresh_token"]?.string { saved.refresh = next }
        saved.until = tokens["expires_in"]?.number.map { Date().addingTimeInterval($0 - 60) }
        keep(saved, for: id)
        return access
    }

    // MARK: Finding the sign-in server

    nonisolated private static func requirePublicHTTPS(_ urlString: String, label: String = "地址") async throws -> URL {
        guard let target = URL(string: urlString),
              target.scheme?.lowercased() == "https",
              let host = target.host, !host.isEmpty else {
            throw ProviderError("\(label)必须是 https 公网地址。")
        }
        if LocalAddress.isLocal(target) || await LocalAddress.resolvesToLocal(target) {
            throw ProviderError("\(label)指向本机或局域网，已拒绝。")
        }
        return target
    }

    nonisolated private static func discover(_ url: String) async throws -> Ends {
        let target = try await requirePublicHTTPS(url, label: "服务地址")
        guard let host = target.host else { throw ProviderError("地址不对。") }
        let origin = "https://\(host)\(target.port.map { ":\($0)" } ?? "")"
        let path = target.path == "/" ? "" : target.path

        // 1. The service says where its sign-in server is: in the 401's header, or at its well-known address.
        var metadata: JSONValue?
        if let pointed = await resourcePointer(url) { metadata = await getJSON(pointed) }
        if metadata == nil { metadata = await getJSON(origin + "/.well-known/oauth-protected-resource" + path) }
        if metadata == nil, !path.isEmpty { metadata = await getJSON(origin + "/.well-known/oauth-protected-resource") }
        let issuer = metadata?["authorization_servers"]?.array?.first?.string ?? origin
        let scopes = metadata?["scopes_supported"]?.array?.compactMap(\.string) ?? []

        // 2. The sign-in server's own description.
        let issuerURL = try await requirePublicHTTPS(issuer, label: "登录服务器地址")
        guard let issuerHost = issuerURL.host else { throw ProviderError("登录服务器地址不对：\(issuer)") }
        let issuerOrigin = "https://\(issuerHost)\(issuerURL.port.map { ":\($0)" } ?? "")"
        let issuerPath = issuerURL.path == "/" ? "" : issuerURL.path
        var candidates = [issuerOrigin + "/.well-known/oauth-authorization-server" + issuerPath,
                          issuerOrigin + "/.well-known/openid-configuration" + issuerPath]
        if !issuerPath.isEmpty { candidates.append(issuer + "/.well-known/openid-configuration") }
        for candidate in candidates {
            if let found = await getJSON(candidate), let authorize = found["authorization_endpoint"]?.string, let token = found["token_endpoint"]?.string {
                _ = try await requirePublicHTTPS(authorize, label: "授权地址")
                _ = try await requirePublicHTTPS(token, label: "令牌地址")
                let register = found["registration_endpoint"]?.string
                if let register { _ = try await requirePublicHTTPS(register, label: "登记地址") }
                return Ends(authorize: authorize, token: token, register: register, scopes: scopes)
            }
        }
        // 3. Older services: the usual paths on the service itself.
        return Ends(authorize: origin + "/authorize", token: origin + "/token", register: origin + "/register", scopes: scopes)
    }

    /// `WWW-Authenticate: Bearer resource_metadata="…"` from an unsigned request.
    nonisolated private static func resourcePointer(_ url: String) async -> String? {
        guard let target = try? await requirePublicHTTPS(url) else { return nil }
        var request = URLRequest(url: target, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"Clio","version":"1.0"}}}"#.utf8)
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "WWW-Authenticate"),
              let range = header.range(of: #"resource_metadata="([^"]+)""#, options: .regularExpression) else { return nil }
        return String(header[range].dropFirst("resource_metadata=\"".count).dropLast())
    }

    private struct Client { var id: String; var secret: String? }

    /// Dynamic client registration: Clio introduces itself and gets a client id of its own.
    nonisolated private static func register(at endpoint: String) async throws -> Client {
        let target = try await requirePublicHTTPS(endpoint, label: "登记地址")
        var request = URLRequest(url: target, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: JSONValue = [
            "client_name": "Clio",
            "redirect_uris": [.string(redirect)],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        ]
        request.httpBody = Data(body.compact.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let answer = JSONValue.parse(String(decoding: data, as: UTF8.self))
        guard (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0), let id = answer?["client_id"]?.string else {
            let said = answer?["error_description"]?.string ?? answer?["error"]?.string ?? String(decoding: data.prefix(160), as: UTF8.self)
            throw ProviderError("那边不让 Clio 登记：\(said)")
        }
        return Client(id: id, secret: answer?["client_secret"]?.string)
    }

    nonisolated private static func getJSON(_ url: String) async -> JSONValue? {
        guard let target = try? await requirePublicHTTPS(url) else { return nil }
        var request = URLRequest(url: target, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let value = JSONValue.parse(String(decoding: data, as: UTF8.self))
        if case .object = value { return value }
        return nil
    }

    nonisolated private static func post(_ url: String, form: [String: String]) async throws -> JSONValue {
        let target = try await requirePublicHTTPS(url, label: "令牌地址")
        var request = URLRequest(url: target, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = Data(form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }.joined(separator: "&").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let answer = JSONValue.parse(String(decoding: data, as: UTF8.self)) ?? .null
        guard (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0) else {
            throw ProviderError(answer["error_description"]?.string ?? answer["error"]?.string ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return answer
    }

    private static func random(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes).base64URL
    }
}
