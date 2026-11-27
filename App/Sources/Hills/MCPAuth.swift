import AgentKit
import AuthenticationServices
import Craft
import CryptoKit
import Foundation
import Network
import SafariServices
import Security
import UIKit

struct MCPLoginOptions: Codable, Equatable, Sendable {
    var clientID = ""
    var scope = ""
    var redirectURI = ""

    var normalized: Self {
        Self(clientID: Self.optional(clientID) ?? "",
             scope: MCPDiscoveryPolicy.scope(challenge: nil, minimal: scope) ?? "",
             redirectURI: Self.optional(redirectURI) ?? "")
    }

    static func optional(_ value: String) -> String? {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    private static func key(_ id: String, _ url: String) -> String {
        let resource = URL(string: url).flatMap(MCPDiscoveryPolicy.canonicalResource) ?? url
        return "mcp.oauth.options.\(id).\(resource)"
    }

    static func load(server id: String, url: String) -> Self {
        guard let data = UserDefaults.standard.data(forKey: key(id, url)),
              let options = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return options
    }

    func save(server id: String, url: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key(id, url))
    }
}

@MainActor
enum OAuthPresentation {
    private static var owner: UUID?

    static func acquire() throws -> UUID {
        guard owner == nil else { throw ProviderError("已有一个登录窗口，请先完成或取消。") }
        guard window != nil else { throw ProviderError("请回到应用前台再登录。") }
        let ticket = UUID()
        owner = ticket
        return ticket
    }

    static func release(_ ticket: UUID) {
        if owner == ticket { owner = nil }
    }

    static var window: UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        return scenes.compactMap(\.keyWindow).first ?? scenes.flatMap(\.windows).first(where: { !$0.isHidden })
    }

    static var presenter: UIViewController? {
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        guard top?.isBeingDismissed == false else { return nil }
        return top
    }
}

@MainActor
final class OAuthWebSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var activeSession: ASWebAuthenticationSession?
    private var completion: CheckedContinuation<URL, Error>?

    func open(_ url: URL, scheme: String) async throws -> URL {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                completion = continuation
                let session = ASWebAuthenticationSession(url: url, callback: .customScheme(scheme)) { url, error in
                    Task { @MainActor in
                        if let url { self.finish(.success(url)) }
                        else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                            self.finish(.failure(CancellationError()))
                        } else {
                            self.finish(.failure(ProviderError("登录窗口未能完成，请重试。")))
                        }
                    }
                }
                activeSession = session
                session.presentationContextProvider = self
                if !session.start() { finish(.failure(ProviderError("打不开登录页。"))) }
            }
        } onCancel: {
            Task { @MainActor in self.cancel() }
        }
    }

    func cancel() {
        let session = activeSession
        finish(.failure(CancellationError()))
        session?.cancel()
    }

    private func finish(_ result: Result<URL, Error>) {
        let continuation = completion
        completion = nil
        activeSession = nil
        continuation?.resume(with: result)
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { OAuthPresentation.window ?? ASPresentationAnchor() }
    }
}

struct OAuthHTTPError: LocalizedError {
    let status: Int
    let kind: OAuthRefreshErrorKind

    init(response: HTTPURLResponse, data: Data) {
        status = response.statusCode
        kind = OAuthRefreshErrorClassifier.classify(
            statusCode: status, body: data, error: nil,
            wwwAuthenticate: response.value(forHTTPHeaderField: "WWW-Authenticate")
        )
    }

    var errorDescription: String? { "登录服务返回 HTTP \(status)。" }
}

final class OAuthRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

@MainActor
final class MCPAuth {
    static let shared = MCPAuth()

    struct Saved: Codable, Equatable, Sendable {
        var clientId: String
        var clientSecret: String?
        var tokenEndpoint: String
        var issuer: String?
        var resource: String
        var access: String
        var refresh: String?
        var until: Date?
        var registrationKey: String?
        var options: MCPLoginOptions?
    }

    private struct Client: Codable, Sendable {
        let id: String
        let clientSecret: String?
    }

    private struct ResourceMetadata: Decodable {
        let resource: URL
        let authorization_servers: [URL]
    }

    private struct Discovery {
        let server: MCPDiscoveryPolicy.ServerMetadata
        let resource: String
        let scope: String?
    }

    enum LoginError: LocalizedError {
        case reauthRequired
        case accessRejected
        case sessionChanged

        var errorDescription: String? {
            switch self {
            case .reauthRequired: return "登录已过期，请重新登录。"
            case .accessRejected: return "服务拒绝了访问，请在连接器中重新连接。"
            case .sessionChanged: return "连接凭据已更改，请重新发起请求。"
            }
        }
    }

    private var activeServer: String?
    private var activeEpoch: UInt64?
    private var activeSession: OAuthWebSession?
    private var activeLoopback: MCPLoopbackSession?

    private func cancel(server id: String, before epoch: UInt64) {
        guard activeServer == id, let activeEpoch, activeEpoch < epoch else { return }
        activeSession?.cancel()
        activeLoopback?.cancel()
    }

    func login(server id: String, url: String, options: MCPLoginOptions, challenge: MCPDiscoveryPolicy.Challenge) async throws {
        let configured = try Self.configuredRedirect(MCPLoginOptions.optional(options.redirectURI))
        let ticket = try OAuthPresentation.acquire()
        activeServer = id
        defer {
            activeSession = nil
            activeLoopback?.cancel()
            activeLoopback = nil
            activeServer = nil
            activeEpoch = nil
            OAuthPresentation.release(ticket)
        }
        let gate = Self.gate(id)
        let attempt = gate.beginSignIn()
        activeEpoch = attempt.baseEpoch
        let discovery = try await Self.discover(url, challenge: challenge, minimumScope: options.scope)
        let metadata = discovery.server
        let issuer = MCPDiscoveryPolicy.normalizedIssuer(metadata.issuer) ?? metadata.issuer.absoluteString
        let registration = metadata.registrationEndpoint
        let verifier = try Self.random(48)
        let state = try Self.random(24)
        let redirect: URL
        if let configured, MCPCallbackTransport.route(configured) == .legacyCustomScheme {
            redirect = configured
        } else {
            let portKey = "mcp.oauth.port." + Self.digest(Data("\(issuer)\n\(discovery.resource)".utf8))
            let preferred = UInt16(exactly: UserDefaults.standard.integer(forKey: portKey)).flatMap { $0 == 0 ? nil : $0 }
            let fixed = configured?.port.flatMap { UInt16(exactly: $0) }
            do {
                redirect = try await listen(port: fixed ?? preferred, state: state)
            } catch {
                guard fixed == nil, preferred != nil, !(error is CancellationError), !Task.isCancelled else { throw error }
                redirect = try await listen(port: nil, state: state)
            }
            if configured == nil, let port = redirect.port { UserDefaults.standard.set(port, forKey: portKey) }
        }
        guard gate.isSignInActive(attempt) else { throw LoginError.sessionChanged }

        let client: Client
        let registrationKey: String?
        if let clientID = MCPLoginOptions.optional(options.clientID) {
            client = Client(id: clientID, clientSecret: nil)
            registrationKey = nil
        } else if let registration {
            let key = MCPDCRCacheKey(issuer: issuer, registrationEndpoint: registration.absoluteString,
                                     redirectURI: redirect.absoluteString, manualStaticClientID: nil)
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let slot = "mcp.oauth.client." + Self.digest(try encoder.encode(key))
            registrationKey = slot
            if let cached = Self.registrationCacheLock.withLock({ Vault.load(Client.self, key: slot) }) {
                client = cached
            } else {
                client = try await Self.register(at: registration, redirect: redirect)
                try gate.withCurrentEpoch(attempt.baseEpoch) { _ in
                    try Self.registrationCacheLock.withLock { try Vault.saveResult(client, as: slot).get() }
                }
            }
        } else {
            throw ProviderError("此服务需要预先登记客户端，请填写客户端 ID。")
        }

        let page = try Self.authorizationURL(
            endpoint: metadata.authorizationEndpoint, client: client.id, redirect: redirect,
            resource: discovery.resource, scope: discovery.scope, state: state, verifier: verifier
        )
        guard gate.isSignInActive(attempt) else { throw LoginError.sessionChanged }
        let callback: URL
        if let activeLoopback {
            callback = try await activeLoopback.open(page)
        } else {
            let session = OAuthWebSession()
            activeSession = session
            callback = try await session.open(page, scheme: "clio")
        }
        let code = try Self.callbackCode(callback, redirect: redirect, state: state)
        guard gate.isSignInActive(attempt) else { throw LoginError.sessionChanged }
        var form = [
            "grant_type": "authorization_code", "code": code, "redirect_uri": redirect.absoluteString,
            "client_id": client.id, "code_verifier": verifier,
        ]
        if let secret = client.clientSecret { form["client_secret"] = secret }
        let tokens: JSONValue
        do {
            tokens = try await Self.post(metadata.tokenEndpoint, form: form, resource: discovery.resource)
        } catch let failure as OAuthHTTPError where failure.kind == .reauthRequired(code: "invalid_client") {
            try gate.withCurrentEpoch(attempt.baseEpoch) { _ in
                Self.clearRegistration(registrationKey, ifClientIs: client.id)
            }
            throw ProviderError("登录服务器拒绝了客户端，请检查客户端 ID 后重试。")
        }
        guard let access = tokens["access_token"]?.string, !access.isEmpty else {
            throw ProviderError("登录服务器未返回访问令牌。")
        }
        let saved = Saved(clientId: client.id, clientSecret: client.clientSecret,
                          tokenEndpoint: metadata.tokenEndpoint.absoluteString, issuer: issuer, resource: discovery.resource,
                          access: access, refresh: tokens["refresh_token"]?.string, until: Self.expiry(tokens),
                          registrationKey: registrationKey, options: options.normalized)
        try Task.checkCancellation()
        guard try gate.commitSignIn(attempt, persist: { try Self.store(id).replace(saved) }) != nil else {
            throw LoginError.sessionChanged
        }
    }

    private func listen(port: UInt16?, state: String) async throws -> URL {
        let session = try MCPLoopbackSession(port: port, state: state)
        activeLoopback = session
        return try await session.start()
    }

    nonisolated static func configuredRedirect(_ raw: String?) throws -> URL? {
        guard let raw else { return nil }
        guard let url = URL(string: raw) else { throw ProviderError("登录回调地址无效。") }
        switch MCPCallbackTransport.route(url) {
        case .loopbackSafariVC, .legacyCustomScheme: return url
        case .rejectedHTTPSUnsupported(let reason), .unsupported(let reason): throw ProviderError(reason)
        }
    }

    nonisolated static func authorizationURL(
        endpoint: URL, client: String, redirect: URL, resource: String, scope: String?, state: String, verifier: String
    ) throws -> URL {
        var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        var items = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: client),
            URLQueryItem(name: "redirect_uri", value: redirect.absoluteString),
            URLQueryItem(name: "code_challenge", value: Data(SHA256.hash(data: Data(verifier.utf8))).base64URL),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "resource", value: resource),
        ]
        if let scope { items.append(URLQueryItem(name: "scope", value: scope)) }
        let reserved = Set(items.map(\.name) + ["scope"])
        let extra = parts?.queryItems?.filter { !reserved.contains($0.name) } ?? []
        parts?.queryItems = extra + items
        guard let url = parts?.url else { throw ProviderError("登录地址无效。") }
        return url
    }

    nonisolated static func callbackCode(_ callback: URL, redirect: URL, state: String) throws -> String {
        guard let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == redirect.scheme?.lowercased(),
              parts.host?.lowercased() == redirect.host?.lowercased(),
              parts.port == redirect.port,
              parts.percentEncodedPath == URLComponents(url: redirect, resolvingAgainstBaseURL: false)?.percentEncodedPath,
              parts.user == nil, parts.password == nil, parts.fragment == nil else {
            throw ProviderError("登录回调地址不匹配。")
        }
        let fields = parts.queryItems ?? []
        let states = fields.filter { $0.name == "state" }
        guard states.count == 1, states.first?.value == state else {
            throw ProviderError("登录回来的信息对不上，请重试。")
        }
        if fields.contains(where: { $0.name == "error" }) { throw ProviderError("登录未获授权，请重试。") }
        let codes = fields.filter { $0.name == "code" }
        guard codes.count == 1, let code = codes.first?.value, !code.isEmpty else {
            throw ProviderError("登录服务器未返回授权码。")
        }
        return code
    }
// A server ID is the stable account slot. One issuer/resource can own it per epoch.
    private nonisolated static let gates = SessionTokenGate()
    private nonisolated static let registrationCacheLock = NSLock()

    private nonisolated static func gate(_ id: String) -> SessionTokenGate {
        gates.scoped(account: id, issuer: "", resource: "")
    }

    private nonisolated static func store(_ id: String) -> VaultRotationStore<Saved> {
        VaultRotationStore(credentialID: "mcp.oauth.\(id)")
    }

    nonisolated static func hasSavedCredential(_ id: String) -> Bool {
        (try? gate(id).withCurrentEpoch { _ in store(id).hasCredential }) ?? false
    }

    nonisolated static func needsNewOptions(_ options: MCPLoginOptions, server id: String) -> Bool {
        (try? gate(id).withCurrentEpoch { _ in
            guard let saved = store(id).latestPayload else {
                return options.normalized != MCPLoginOptions() && store(id).hasCredential
            }
            return (saved.options ?? MCPLoginOptions()) != options.normalized
        }) ?? false
    }

    nonisolated static func forget(_ id: String) {
        let epoch = gate(id).invalidateSession { store(id).remove() }
        Task { @MainActor in shared.cancel(server: id, before: epoch) }
    }

    nonisolated static func bearer(_ id: String, stale: Bool = false) async throws -> String? {
        // Hills.withCredential's legacy retry carries no epoch or original bearer.
        guard !stale else { throw LoginError.accessRejected }
        return try await bearerLease(id)?.token
    }

    nonisolated static func bearerLease(_ id: String, retrying previous: SessionTokenGate.Lease? = nil) async throws -> SessionTokenGate.Lease? {
        let gate = gate(id)
        let slot = try gate.withCurrentEpoch(previous?.epoch) { epoch in (store(id).hasCredential, epoch) }
        guard slot.0 else { return nil }
        if let previous { await gate.invalidateCached(token: previous.token, epoch: previous.epoch) }
        return try await gate.access(expectedEpoch: slot.1) { epoch in
            try await refresh(id: id, gate: gate, epoch: epoch, rejected: previous?.token)
        }
    }

    private nonisolated static func refresh(
        id: String, gate: SessionTokenGate, epoch: UInt64, rejected: String?
    ) async throws -> SessionTokenGate.RefreshOutput {
        let store = store(id)
        let current = try gate.withCurrentEpoch(epoch) { _ in
            switch store.load(legacy: {
                Vault.load(Data.self, key: store.credentialID).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
            }) {
            case .missing: throw LoginError.sessionChanged
            case .reauthRequired: throw LoginError.reauthRequired
            case .current(let credential), .recovered(let credential): return credential
            }
        }
        var saved = current.payload
        if saved.access != rejected, saved.until.map({ $0 > Date() }) ?? true {
            return SessionTokenGate.RefreshOutput(token: saved.access, expiresAt: saved.until ?? .distantFuture)
        }
        guard let refreshToken = saved.refresh, let endpoint = URL(string: saved.tokenEndpoint),
              let resourceURL = URL(string: saved.resource), let resource = MCPDiscoveryPolicy.canonicalResource(resourceURL) else {
            throw LoginError.reauthRequired
        }
        try await requirePublicHTTPS(endpoint)
        try gate.withCurrentEpoch(epoch) { _ in try store.begin(current) }
        var form = ["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": saved.clientId]
        if let secret = saved.clientSecret { form["client_secret"] = secret }
        let tokens: JSONValue
        do {
            tokens = try await post(endpoint, form: form, resource: resource, prevalidated: true)
        } catch {
            try gate.withCurrentEpoch(epoch) { _ in
                if let http = error as? OAuthHTTPError, case .reauthRequired(let code) = http.kind {
                    if code == "invalid_client" { clearRegistration(saved.registrationKey, ifClientIs: saved.clientId) }
                    throw LoginError.reauthRequired
                }
                store.abandonRetryableRefresh()
            }
            throw error
        }
        guard let access = tokens["access_token"]?.string, !access.isEmpty else { throw LoginError.reauthRequired }
        saved.access = access
        if let next = tokens["refresh_token"]?.string, !next.isEmpty { saved.refresh = next }
        saved.resource = resource
        saved.until = expiry(tokens)
        do {
            try gate.withCurrentEpoch(epoch) { _ in try store.finish(saved, replacing: current) }
        } catch VaultRotationStore<Saved>.StorageError.reauthRequired {
            throw LoginError.reauthRequired
        }
        return SessionTokenGate.RefreshOutput(token: saved.access, expiresAt: saved.until ?? .distantFuture)
    }

    nonisolated static func challenge(at raw: String) async throws -> MCPDiscoveryPolicy.Challenge? {
        guard let url = URL(string: raw) else { throw ProviderError("服务地址无效。") }
        try await requirePublicHTTPS(url)
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(MCPDiscoveryPolicy.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        request.httpBody = Data("""
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"\(MCPDiscoveryPolicy.protocolVersion)","capabilities":{},"clientInfo":{"name":"Clio","version":"1.0"}}}
        """.utf8)
        // Only the status and header are needed. The server may keep its body open.
        let (_, response) = try await URLSession.shared.bytes(for: request, delegate: OAuthRedirectGuard())
        guard let http = response as? HTTPURLResponse else { throw ProviderError("服务未返回 HTTP 响应。") }
        if http.statusCode == 401 {
            let challenges = MCPDiscoveryPolicy.challenges(http.value(forHTTPHeaderField: "WWW-Authenticate") ?? "")
                .filter { $0.scheme == "bearer" }
            return challenges.first(where: { $0.parameters["resource_metadata"] != nil })
                ?? challenges.first ?? MCPDiscoveryPolicy.challenges("Bearer").first
        }
        guard (200..<300).contains(http.statusCode) else { throw OAuthHTTPError(response: http, data: Data()) }
        return nil
    }

    private nonisolated static func discover(
        _ raw: String, challenge: MCPDiscoveryPolicy.Challenge, minimumScope: String?
    ) async throws -> Discovery {
        guard let target = URL(string: raw), let canonical = MCPDiscoveryPolicy.canonicalResource(target) else {
            throw ProviderError("服务地址无效。")
        }
        let pointer = challenge.parameters["resource_metadata"].flatMap { URL(string: $0) }
        let resource: ResourceMetadata = try await metadata(
            from: MCPDiscoveryPolicy.resourceMetadataCandidates(resource: target, pointer: pointer)
        )
        guard MCPDiscoveryPolicy.canonicalResource(resource.resource) == canonical,
              resource.resource.query == nil, resource.resource.fragment == nil,
              let issuer = resource.authorization_servers.first else {
            throw ProviderError("登录发现信息与此服务不匹配。")
        }
        try await requirePublicHTTPS(issuer)
        return try await discoverIssuer(issuer, resource: canonical, challenge: challenge, minimumScope: minimumScope)
    }

    private nonisolated static func discoverIssuer(
        _ issuer: URL, resource: String, challenge: MCPDiscoveryPolicy.Challenge, minimumScope: String?
    ) async throws -> Discovery {
        let server: MCPDiscoveryPolicy.ServerMetadata = try await metadata(
            from: MCPDiscoveryPolicy.authorizationMetadataCandidates(issuer: issuer),
            validate: { try MCPDiscoveryPolicy.validate($0, expectedIssuer: issuer) }
        )
        try await requirePublicHTTPS(server.authorizationEndpoint)
        try await requirePublicHTTPS(server.tokenEndpoint)
        if let registration = server.registrationEndpoint { try await requirePublicHTTPS(registration) }
        return Discovery(server: server, resource: resource,
                         scope: MCPDiscoveryPolicy.scope(challenge: challenge.parameters["scope"], minimal: minimumScope))
    }

    private nonisolated static func metadata<T: Decodable>(
        from candidates: [URL], validate: (T) throws -> Void = { _ in }
    ) async throws -> T {
        var unavailable: Error = ProviderError("没有找到登录发现信息。")
        var unsupported: MCPDiscoveryPolicy.DiscoveryError?
        for url in candidates {
            try await requirePublicHTTPS(url)
            do {
                let data = try await request(URLRequest(url: url, timeoutInterval: 15))
                guard let decoded = try? JSONDecoder().decode(T.self, from: data) else {
                    unavailable = ProviderError("登录发现信息格式不正确。")
                    continue
                }
                try validate(decoded)
                return decoded
            } catch let http as OAuthHTTPError where [404, 405, 410].contains(http.status) {
                unavailable = http
            } catch let error as MCPDiscoveryPolicy.DiscoveryError {
                unsupported = error
            }
        }
        if let unsupported { throw unsupported }
        throw unavailable
    }

    private nonisolated static func register(at endpoint: URL, redirect: URL) async throws -> Client {
        try await requirePublicHTTPS(endpoint)
        var registration = URLRequest(url: endpoint, timeoutInterval: 30)
        registration.httpMethod = "POST"
        registration.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: JSONValue = [
            "client_name": "Clio", "redirect_uris": [.string(redirect.absoluteString)],
            "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        ]
        registration.httpBody = Data(body.compact.utf8)
        let data = try await request(registration)
        let reply = JSONValue.parse(String(decoding: data, as: UTF8.self))
        guard let id = reply?["client_id"]?.string, !id.isEmpty else {
            throw ProviderError("登记响应未返回客户端 ID。")
        }
        return Client(id: id, clientSecret: reply?["client_secret"]?.string)
    }

    private nonisolated static func post(
        _ endpoint: URL, form: [String: String], resource: String, prevalidated: Bool = false
    ) async throws -> JSONValue {
        if !prevalidated { try await requirePublicHTTPS(endpoint) }
        var token = URLRequest(url: endpoint, timeoutInterval: 30)
        token.httpMethod = "POST"
        token.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        token.httpBody = tokenForm(form, resource: resource)
        let data = try await request(token)
        return JSONValue.parse(String(decoding: data, as: UTF8.self)) ?? .null
    }

    nonisolated static func tokenForm(_ fields: [String: String], resource: String) -> Data {
        var form = fields
        form["resource"] = resource
        return formBody(form)
    }

    nonisolated static func formBody(_ form: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return Data(form.keys.sorted().map { key in
            let value = form[key] ?? ""
            return "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&").utf8)
    }

    private nonisolated static func request(_ input: URLRequest) async throws -> Data {
        var request = input
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(MCPDiscoveryPolicy.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        let (data, response) = try await URLSession.shared.data(for: request, delegate: OAuthRedirectGuard())
        guard let http = response as? HTTPURLResponse else { throw ProviderError("登录服务未返回 HTTP 响应。") }
        guard (200..<300).contains(http.statusCode) else { throw OAuthHTTPError(response: http, data: data) }
        return data
    }

    private nonisolated static func requirePublicHTTPS(_ url: URL) async throws {
        guard url.fragment == nil, await URLAccessPurpose.oauthEndpoint.allows(url) else {
            throw ProviderError("登录端点必须使用 HTTPS 公网地址。")
        }
    }

    private nonisolated static func expiry(_ tokens: JSONValue) -> Date? {
        tokens["expires_in"]?.number.map { Date().addingTimeInterval($0 - 60) }
    }

    private nonisolated static func clearRegistration(_ key: String?, ifClientIs id: String) {
        registrationCacheLock.withLock {
            guard let key, Vault.load(Client.self, key: key)?.id == id else { return }
            Vault.remove(key)
        }
    }

    private static func digest(_ data: Data) -> String { Data(SHA256.hash(data: data)).base64URL }

    static func random(_ count: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw ProviderError("无法生成安全的登录凭据，请重试。")
        }
        return Data(bytes).base64URL
    }
}
@MainActor
private final class MCPLoopbackSession: NSObject, SFSafariViewControllerDelegate {
    private let listener: NWListener
    private let state: String
    private var readiness: CheckedContinuation<URL, Error>?
    private var completion: CheckedContinuation<URL, Error>?
    private var timeout: Task<Void, Never>?
    private var redirect: URL?
    private var safari: SFSafariViewController?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var closed = false

    init(port: UInt16?, state: String) throws {
        let parameters = NWParameters.tcp
        let localPort = port.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: localPort)
        listener = try NWListener(using: parameters)
        self.state = state
    }

    func start() async throws -> URL {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                readiness = continuation
                listener.stateUpdateHandler = { [weak self] status in
                    MainActor.assumeIsolated { self?.changed(status) }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    MainActor.assumeIsolated {
                        if let self { self.accept(connection) } else { connection.cancel() }
                    }
                }
                listener.start(queue: .main)
                scheduleTimeout(seconds: 10, message: "本机登录回调启动超时，请重试。")
            }
        } onCancel: {
            Task { @MainActor in self.cancel() }
        }
    }

    private func changed(_ status: NWListener.State) {
        guard !closed else { return }
        switch status {
        case .ready:
            guard let readiness, let port = listener.port, port != .any,
                  let url = URL(string: "http://127.0.0.1:\(port.rawValue)/callback") else {
                if redirect == nil { finish(.failure(ProviderError("无法确定本机回调端口。"))) }
                return
            }
            self.readiness = nil
            redirect = url
            timeout?.cancel()
            readiness.resume(returning: url)
        case .failed, .waiting:
            finish(.failure(ProviderError("无法打开本机登录回调端口，请检查端口后重试。")))
        case .cancelled:
            finish(.failure(CancellationError()))
        default: break
        }
    }

    func open(_ page: URL) async throws -> URL {
        guard !closed, redirect != nil, let presenter = OAuthPresentation.presenter else {
            throw ProviderError("打不开登录页，请回到应用前台再试。")
        }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                completion = continuation
                let safari = SFSafariViewController(url: page)
                self.safari = safari
                safari.delegate = self
                backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "MCP OAuth") { [weak self] in
                    Task { @MainActor in
                        self?.finish(.failure(ProviderError("登录在后台超时，请重试。")))
                    }
                }
                scheduleTimeout(seconds: 180, message: "等待登录超时，请重试。")
                presenter.present(safari, animated: true)
            }
        } onCancel: {
            Task { @MainActor in self.cancel() }
        }
    }

    private func scheduleTimeout(seconds: UInt64, message: String) {
        timeout?.cancel()
        timeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) }
            catch { return }
            self?.finish(.failure(ProviderError(message)))
        }
    }

    private func accept(_ connection: NWConnection) {
        guard !closed, completion != nil, connections.count < 8 else { connection.cancel(); return }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed, .cancelled: self?.connections[id] = nil
                default: break
                }
            }
        }
        connection.start(queue: .main)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        let limit = 8192
        guard buffer.count < limit else { connection.cancel(); return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: limit - buffer.count) { [weak self] data, _, ended, error in
            MainActor.assumeIsolated {
                guard let self, !self.closed, error == nil else { connection.cancel(); return }
                var request = buffer
                if let data { request.append(data) }
                if let end = request.range(of: Data("\r\n\r\n".utf8))?.lowerBound {
                    self.respond(to: request[..<end], on: connection)
                } else if ended || request.count >= limit {
                    connection.cancel()
                } else {
                    self.read(connection, buffer: request)
                }
            }
        }
    }

    private func respond(to headers: Data, on connection: NWConnection) {
        let lines = String(decoding: headers, as: UTF8.self).components(separatedBy: "\r\n")
        let request = lines.first?.split(separator: " ") ?? []
        let hosts = lines.dropFirst().filter { $0.lowercased().hasPrefix("host:") }
        let callback: URL?
        if request.count == 3, request.first == "GET", let redirect, let port = redirect.port,
           request[1].hasPrefix("/callback?"), hosts.count == 1,
           hosts.first?.dropFirst(5).trimmingCharacters(in: .whitespaces) == "127.0.0.1:\(port)",
           let received = URL(string: "http://127.0.0.1:\(port)\(request[1])"),
           let fields = URLComponents(url: received, resolvingAgainstBaseURL: false)?.queryItems,
           fields.filter({ $0.name == "state" }).map(\.value) == [state] {
            callback = received
        } else {
            callback = nil
        }
        let message = callback == nil ? "回调无效。" : "请返回 Clio 继续。"
        let status = callback == nil ? "400 Bad Request" : "200 OK"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: \(message.utf8.count)\r\nConnection: close\r\n\r\n\(message)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            MainActor.assumeIsolated {
                connection.cancel()
                if let callback { self?.finish(.success(callback)) }
            }
        })
    }

    func safariViewControllerDidFinish(_ controller: SFSafariViewController) { cancel() }

    func cancel() { finish(.failure(CancellationError())) }

    private func finish(_ result: Result<URL, Error>) {
        guard !closed else { return }
        closed = true
        timeout?.cancel()
        listener.cancel()
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
        safari?.dismiss(animated: true)
        safari = nil
        readiness?.resume(with: result)
        readiness = nil
        completion?.resume(with: result)
        completion = nil
    }
}
