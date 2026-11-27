import AgentKit
import Craft
import CryptoKit
import Foundation
import UIKit

/// 谷歌: the person's Gmail and Google Drive, reached with their own sign-in.
/// Clio has no Google client of its own: the person makes an iOS OAuth client in their Google Cloud project and
/// pastes its Client ID, the same way they bring their own model key. Tokens stay in the Vault.
@MainActor
final class Google: NSObject, ObservableObject {
    static let shared = Google()

    @Published private(set) var account: String? = UserDefaults.standard.string(forKey: "google.account")
    @Published private(set) var expired: Bool = UserDefaults.standard.bool(forKey: "google.expired")
    @Published private(set) var busy = false
    @Published var problem: String?
    private var activeSession: OAuthWebSession?

    fileprivate func setExpired(_ value: Bool) {
        expired = value
        if value {
            UserDefaults.standard.set(true, forKey: "google.expired")
        } else {
            UserDefaults.standard.removeObject(forKey: "google.expired")
        }
    }

    /// What the sign-in asks for: enough for Clio's own Gmail and Drive tools and for Google's official
    /// MCP services (Gmail, Drive, Calendar, Docs, Sheets, Slides).
    static let scopes = [
        "email",
        "https://www.googleapis.com/auth/gmail.readonly",
        "https://www.googleapis.com/auth/gmail.compose",
        "https://www.googleapis.com/auth/drive.readonly",
        "https://www.googleapis.com/auth/drive.file",
        "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
        "https://www.googleapis.com/auth/calendar.events",
        "https://www.googleapis.com/auth/documents",
        "https://www.googleapis.com/auth/spreadsheets",
        "https://www.googleapis.com/auth/presentations",
    ]
    /// Bumped when `scopes` grows: an older sign-in has to be done again to grant the new ones.
    static let scopesVersion = 2

    /// Signed in, but before the scopes grew.
    var needsMoreScopes: Bool { connected && UserDefaults.standard.integer(forKey: "google.scopes") < Self.scopesVersion }

    var clientId: String {
        get { UserDefaults.standard.string(forKey: "google.client") ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "google.client") }
    }

    var connected: Bool { account != nil }

    /// `123-abc.apps.googleusercontent.com` → `com.googleusercontent.apps.123-abc`: the address Google sends the
    /// sign-in back to for an iOS client.
    private var scheme: String? {
        let id = clientId
        let suffix = ".apps.googleusercontent.com"
        guard id.hasSuffix(suffix) else { return nil }
        let prefix = id.dropLast(suffix.count)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        guard !prefix.isEmpty, prefix.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return "com.googleusercontent.apps." + prefix
    }

    // MARK: Signing in

    func signIn() async {
        guard !busy else { return }
        guard let scheme else {
            problem = "Client ID 不对：应该以 .apps.googleusercontent.com 结尾，而且要是「iOS」类型的。"
            return
        }
        let ticket: UUID
        do { ticket = try OAuthPresentation.acquire() }
        catch { problem = error.localizedDescription; return }
        let attempt = GoogleTokenBox.shared.beginSignIn()
        let client = clientId
        busy = true
        problem = nil
        defer {
            busy = false
            activeSession = nil
            OAuthPresentation.release(ticket)
        }
        do {
            let verifier = try MCPAuth.random(48)
            let state = try MCPAuth.random(24)
            let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
            let redirect = scheme + ":/oauth2redirect"
            guard var parts = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth") else {
                problem = "谷歌登录地址不对。"
                return
            }
            parts.queryItems = [
                URLQueryItem(name: "client_id", value: client),
                URLQueryItem(name: "redirect_uri", value: redirect),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "scope", value: Self.scopes.joined(separator: " ")),
                URLQueryItem(name: "code_challenge", value: challenge),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "state", value: state),
                URLQueryItem(name: "prompt", value: "consent"),
            ]
            guard let authURL = parts.url, let redirectURL = URL(string: redirect) else {
                problem = "谷歌登录地址不对。"
                return
            }
            let session = OAuthWebSession()
            activeSession = session
            let back = try await session.open(authURL, scheme: scheme)
            guard GoogleTokenBox.shared.isSignInActive(attempt) else { return }
            let code = try MCPAuth.callbackCode(back, redirect: redirectURL, state: state)
            let tokens = try await Self.token([
                "code": code, "client_id": client, "redirect_uri": redirect,
                "grant_type": "authorization_code", "code_verifier": verifier,
            ])
            guard let refresh = tokens["refresh_token"]?.string, !refresh.isEmpty,
                  let access = tokens["access_token"]?.string, !access.isEmpty else {
                throw ProviderError("谷歌未返回完整的登录令牌，请重试。")
            }
            let until = Self.expiry(tokens)
            let credential = Credential(clientID: client, access: access, refresh: refresh, until: until)
            if Task.isCancelled {
                if !GoogleTokenBox.shared.isSignInActive(attempt) { Self.revokeToken(refresh) }
                return
            }
            guard let sessionEpoch = try GoogleTokenBox.shared.commitSignIn(attempt, persist: {
                try Self.rotation.replace(credential)
            }) else {
                Self.revokeToken(refresh)
                return
            }
            await GoogleTokenBox.shared.store(token: access, expiresAt: until, epoch: sessionEpoch)
            guard GoogleTokenBox.shared.currentEpoch() == sessionEpoch else { return }
            setExpired(false)
            let lease = SessionTokenGate.Lease(token: access, epoch: sessionEpoch)
            let userInfo = URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!
            let data = try? await Self.performCall(userInfo, method: "GET", body: nil, lease: lease, maxBytes: nil)
            guard GoogleTokenBox.shared.currentEpoch() == sessionEpoch else { return }
            let me = data.flatMap { JSONValue.parse(String(decoding: $0, as: UTF8.self)) }
            account = me?["email"]?.string ?? "已登录"
            UserDefaults.standard.set(Self.scopesVersion, forKey: "google.scopes")
            UserDefaults.standard.set(account, forKey: "google.account")
            Haptics.grab()
        } catch is CancellationError {
            return
        } catch {
            guard GoogleTokenBox.shared.isSignInActive(attempt) else { return }
            problem = error.localizedDescription
        }
    }

    func signOut() {
        activeSession?.cancel()
        var oldRefresh: String?
        GoogleTokenBox.shared.invalidateSession {
            oldRefresh = Self.rotation.latestPayload?.refresh ?? Vault.load(String.self, key: Self.rotation.credentialID)
            Self.rotation.remove()
        }
        setExpired(false)
        account = nil
        UserDefaults.standard.removeObject(forKey: "google.account")
        if let refresh = oldRefresh {
            Self.revokeToken(refresh)
        }
    }

    private nonisolated static func revokeToken(_ refresh: String) {
        guard let url = URL(string: "https://oauth2.googleapis.com/revoke") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = refresh.addingPercentEncoding(withAllowedCharacters: allowed) ?? refresh
        request.httpBody = Data("token=\(encoded)".utf8)
        Task { _ = try? await URLSession.shared.data(for: request, delegate: OAuthRedirectGuard()) }
    }

    private struct Credential: Codable, Equatable, Sendable {
        let clientID: String
        var access: String
        var refresh: String
        var until: Date
    }

    private nonisolated static var rotation: VaultRotationStore<Credential> {
        VaultRotationStore(credentialID: "google.refresh")
    }

    private nonisolated static func expiry(_ tokens: JSONValue) -> Date {
        Date().addingTimeInterval((tokens["expires_in"]?.number ?? 3000) - 60)
    }

    private nonisolated static func token(_ form: [String: String]) async throws -> JSONValue {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = MCPAuth.formBody(form)
        let (data, response) = try await URLSession.shared.data(for: request, delegate: OAuthRedirectGuard())
        guard let http = response as? HTTPURLResponse else { throw ProviderError("谷歌未返回 HTTP 响应。") }
        guard (200..<300).contains(http.statusCode) else { throw OAuthHTTPError(response: http, data: data) }
        return JSONValue.parse(String(decoding: data, as: UTF8.self)) ?? .null
    }

    private nonisolated static func refresh(epoch: UInt64, forced: Bool) async throws -> SessionTokenGate.RefreshOutput {
        let gate = GoogleTokenBox.shared
        let store = rotation
        let current = try gate.withCurrentEpoch(epoch) { _ in
            switch store.load(legacy: {
                guard let refresh = Vault.load(String.self, key: store.credentialID) else { return nil }
                let client = UserDefaults.standard.string(forKey: "google.client") ?? ""
                return Credential(clientID: client, access: "", refresh: refresh, until: .distantPast)
            }) {
            case .missing: throw ProviderError("请先登录谷歌。")
            case .reauthRequired: throw VaultRotationStore<Credential>.StorageError.reauthRequired
            case .current(let credential), .recovered(let credential): return credential
            }
        }
        var payload = current.payload
        if !forced, payload.until > Date(), !payload.access.isEmpty {
            return SessionTokenGate.RefreshOutput(token: payload.access, expiresAt: payload.until)
        }
        try gate.withCurrentEpoch(epoch) { _ in try store.begin(current) }
        let tokens: JSONValue
        do {
            tokens = try await token([
                "refresh_token": payload.refresh, "client_id": payload.clientID, "grant_type": "refresh_token",
            ])
        } catch {
            try gate.withCurrentEpoch(epoch) { _ in
                if let http = error as? OAuthHTTPError, case .reauthRequired = http.kind {
                    throw VaultRotationStore<Credential>.StorageError.reauthRequired
                }
                store.abandonRetryableRefresh()
            }
            throw error
        }
        guard let access = tokens["access_token"]?.string, !access.isEmpty else {
            throw VaultRotationStore<Credential>.StorageError.reauthRequired
        }
        payload.access = access
        if let next = tokens["refresh_token"]?.string, !next.isEmpty { payload.refresh = next }
        payload.until = expiry(tokens)
        try gate.withCurrentEpoch(epoch) { _ in try store.finish(payload, replacing: current) }
        return SessionTokenGate.RefreshOutput(token: payload.access, expiresAt: payload.until)
    }

    private nonisolated static let sessionChangedMessage = "谷歌账号已退出或切换，请重试。"

    /// A fresh access token, renewed with the long-lived one when it has run out.
    nonisolated static func access(stale: Bool = false) async throws -> String {
        try await accessLease(stale: stale).token
    }

    /// A fresh access token paired with the Google login epoch it belongs to.
    nonisolated static func accessLease(stale: Bool = false, expectedEpoch: UInt64? = nil) async throws -> SessionTokenGate.Lease {
        let gate = GoogleTokenBox.shared
        let epoch = expectedEpoch ?? gate.currentEpoch()
        do {
            return try await gate.access(
                forceRefresh: stale,
                expectedEpoch: epoch,
                refresh: { try await refresh(epoch: $0, forced: stale) },
                onCommitted: { epoch in
                    await MainActor.run {
                        if gate.currentEpoch() == epoch { Google.shared.setExpired(false) }
                    }
                }
            )
        } catch SessionTokenGate.GateError.sessionChanged {
            throw ProviderError(sessionChangedMessage)
        } catch VaultRotationStore<Credential>.StorageError.reauthRequired {
            await MainActor.run {
                if gate.currentEpoch() == epoch { Google.shared.setExpired(true) }
            }
            throw ProviderError("谷歌登录已过期，请重新登录。")
        }
    }

    nonisolated static func call(_ url: String, method: String = "GET", body: JSONValue? = nil, maxBytes: Int? = nil) async throws -> Data {
        guard let target = URL(string: url),
              SessionTokenGate.validateLeaseOrigin(target, allowedHTTPSOrigins: Self.apiOrigins) else {
            throw ProviderError("此地址不能使用谷歌登录令牌。")
        }
        let first = try await accessLease()
        do {
            return try await performCall(target, method: method, body: body, lease: first, maxBytes: maxBytes)
        } catch let retry as UnauthorizedRetry {
            do {
                let refreshed = try await accessLease(stale: true, expectedEpoch: retry.epoch)
                return try await performCall(target, method: method, body: body, lease: refreshed, maxBytes: maxBytes)
            } catch is UnauthorizedRetry {
                throw ProviderError("谷歌拒绝了访问，请在连接器里重新登录 Google。")
            }
        }
    }

    private struct UnauthorizedRetry: Error {
        let epoch: UInt64
    }

    private nonisolated static let apiOrigins: Set<String> = [
        "https://www.googleapis.com", "https://gmail.googleapis.com",
    ]

    nonisolated private static func performCall(_ target: URL, method: String, body: JSONValue?, lease: SessionTokenGate.Lease, maxBytes: Int?) async throws -> Data {
        guard SessionTokenGate.validateLeaseOrigin(target, allowedHTTPSOrigins: apiOrigins),
              GoogleTokenBox.shared.currentEpoch() == lease.epoch else {
            throw ProviderError(sessionChangedMessage)
        }
        var request = URLRequest(url: target, timeoutInterval: 60)
        request.httpMethod = method
        request.setValue("Bearer \(lease.token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(body.compact.utf8)
        }
        if let maxBytes {
            let (bytes, response) = try await URLSession.shared.bytes(for: request, delegate: OAuthRedirectGuard())
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if status == 401 {
                await GoogleTokenBox.shared.invalidateCached(token: lease.token, epoch: lease.epoch)
                throw UnauthorizedRetry(epoch: lease.epoch)
            }
            if !(200..<300).contains(status) {
                var errData = Data()
                for try await byte in bytes {
                    errData.append(byte)
                    if errData.count >= 4096 { break }
                }
                let said = JSONValue.parse(String(decoding: errData, as: UTF8.self))?["error"]?["message"]?.string ?? String(decoding: errData.prefix(200), as: UTF8.self)
                if status == 403, said.contains("has not been used") || said.contains("disabled") {
                    throw ProviderError("这个接口还没在你的 Google Cloud 项目里启用：\(said)")
                }
                throw ProviderError("谷歌回了 \(status)：\(said)")
            }
            if let expected = http?.expectedContentLength, expected > Int64(maxBytes) {
                throw ProviderError("文件有 \(Int(expected / 1_000_000)) MB，超过 \(maxBytes / 1_000_000) MB 上限，没有下载。")
            }
            var out = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                out.append(byte)
                if out.count > maxBytes {
                    throw ProviderError("文件内容超过 \(maxBytes / 1_000_000) MB 上限，已停止下载。")
                }
            }
            return out
        }
        let (data, response) = try await URLSession.shared.data(for: request, delegate: OAuthRedirectGuard())
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 {
            await GoogleTokenBox.shared.invalidateCached(token: lease.token, epoch: lease.epoch)
            throw UnauthorizedRetry(epoch: lease.epoch)
        }
        guard (200..<300).contains(status) else {
            let said = JSONValue.parse(String(decoding: data, as: UTF8.self))?["error"]?["message"]?.string ?? String(decoding: data.prefix(200), as: UTF8.self)
            if status == 403, said.contains("has not been used") || said.contains("disabled") {
                throw ProviderError("这个接口还没在你的 Google Cloud 项目里启用：\(said)")
            }
            throw ProviderError("谷歌回了 \(status)：\(said)")
        }
        return data
    }

    nonisolated static func get(_ url: String) async throws -> JSONValue {
        let data = try await call(url)
        return JSONValue.parse(String(decoding: data, as: UTF8.self)) ?? .null
    }
}

private enum GoogleTokenBox {
    static let shared = SessionTokenGate().scoped(
        account: "google", issuer: "https://accounts.google.com", resource: "https://www.googleapis.com"
    )
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL text: String) {
        var plain = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while plain.count % 4 != 0 { plain += "=" }
        self.init(base64Encoded: plain)
    }
}
