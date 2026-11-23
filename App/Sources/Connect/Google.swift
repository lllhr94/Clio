import AgentKit
import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

/// 谷歌: the person's Gmail and Google Drive, reached with their own sign-in.
/// Clio has no Google client of its own: the person makes an iOS OAuth client in their Google Cloud project and
/// pastes its Client ID, the same way they bring their own model key. Tokens stay in the Vault.
@MainActor
final class Google: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = Google()

    @Published private(set) var account: String? = UserDefaults.standard.string(forKey: "google.account")
    @Published private(set) var expired: Bool = UserDefaults.standard.bool(forKey: "google.expired")
    @Published private(set) var busy = false
    @Published var problem: String?

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
        guard id.hasSuffix(".apps.googleusercontent.com") else { return nil }
        return "com.googleusercontent.apps." + id.dropLast(".apps.googleusercontent.com".count)
    }

    // MARK: Signing in

    func signIn() async {
        guard let scheme else {
            problem = "Client ID 不对：应该以 .apps.googleusercontent.com 结尾，而且要是「iOS」类型的。"
            return
        }
        busy = true
        problem = nil
        defer { busy = false }
        let verifier = Self.random(48)
        let state = Self.random(16)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let redirect = scheme + ":/oauth2redirect"
        guard var parts = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth") else {
            problem = "谷歌登录地址不对。"
            return
        }
        parts.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        guard let authURL = parts.url else {
            problem = "谷歌登录地址不对。"
            return
        }
        do {
            let back = try await authenticate(authURL, scheme: scheme)
            let items = URLComponents(url: back, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if let said = items.first(where: { $0.name == "error" })?.value {
                problem = said == "access_denied" ? "你在谷歌那边没同意。" : "谷歌没给登录码（\(said)）。"
                return
            }
            guard items.first(where: { $0.name == "state" })?.value == state,
                  let code = items.first(where: { $0.name == "code" })?.value else {
                problem = "登录回来的信息对不上，再试一次。"
                return
            }
            let tokens = try await Self.token([
                "code": code, "client_id": clientId, "redirect_uri": redirect,
                "grant_type": "authorization_code", "code_verifier": verifier,
            ])
            guard let refresh = tokens["refresh_token"]?.string else { problem = "谷歌没给长期令牌，重新登录一次试试。"; return }
            Vault.save(refresh, as: "google.refresh")
            if let access = tokens["access_token"]?.string {
                let until = Date().addingTimeInterval((tokens["expires_in"]?.number ?? 3000) - 60)
                await GoogleTokenBox.shared.store(token: access, until: until)
            }
            setExpired(false)
            let me = try? await Self.get("https://www.googleapis.com/oauth2/v3/userinfo")
            account = me?["email"]?.string ?? "已登录"
            UserDefaults.standard.set(Self.scopesVersion, forKey: "google.scopes")
            UserDefaults.standard.set(account, forKey: "google.account")
            Haptics.grab()
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return
        } catch {
            problem = error.localizedDescription
        }
    }

    func signOut() {
        if let refresh = Vault.load(String.self, key: "google.refresh"),
           let url = URL(string: "https://oauth2.googleapis.com/revoke") {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            let encoded = refresh.addingPercentEncoding(withAllowedCharacters: allowed) ?? refresh
            request.httpBody = Data("token=\(encoded)".utf8)
            Task { _ = try? await URLSession.shared.data(for: request) }
        }
        Vault.remove("google.refresh")
        Task { await GoogleTokenBox.shared.invalidate() }
        setExpired(false)
        account = nil
        UserDefaults.standard.removeObject(forKey: "google.account")
    }

    private func authenticate(_ url: URL, scheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme(scheme)) { url, error in
                if let url { continuation.resume(returning: url) } else { continuation.resume(throwing: error ?? ProviderError("登录没完成。")) }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            if !session.start() { continuation.resume(throwing: ProviderError("打不开谷歌登录页。")) }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        }
    }

    // MARK: Talking to Google

    private static func random(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes).base64URL
    }

    nonisolated fileprivate static func token(_ form: [String: String]) async throws -> JSONValue {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+/:?")
        request.httpBody = Data(form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }.joined(separator: "&").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let body = JSONValue.parse(String(decoding: data, as: UTF8.self)) ?? .null
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let said = body["error_description"]?.string ?? body["error"]?.string ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
            if body["error"]?.string == "invalid_grant" {
                await MainActor.run { Google.shared.setExpired(true) }
                throw ProviderError("谷歌的登录过期了（测试模式的应用 7 天就过期），去「连接器 → 谷歌」重新登录。")
            }
            throw ProviderError("谷歌登录出错：\(said)")
        }
        return body
    }

    /// A fresh access token, renewed with the long-lived one when it has run out.
    nonisolated static func access(stale: Bool = false) async throws -> String {
        try await GoogleTokenBox.shared.access(forceRefresh: stale)
    }

    nonisolated static func call(_ url: String, method: String = "GET", body: JSONValue? = nil, maxBytes: Int? = nil) async throws -> Data {
        guard let target = URL(string: url) else { throw ProviderError("地址不对。") }
        do {
            return try await performCall(target, method: method, body: body, bearer: try await access(), maxBytes: maxBytes)
        } catch let retry as UnauthorizedRetry {
            _ = retry
            do {
                return try await performCall(target, method: method, body: body, bearer: try await access(stale: true), maxBytes: maxBytes)
            } catch is UnauthorizedRetry {
                throw ProviderError("谷歌拒绝了访问，请在连接器里重新登录 Google。")
            }
        }
    }

    private struct UnauthorizedRetry: Error {}

    nonisolated private static func performCall(_ target: URL, method: String, body: JSONValue?, bearer: String, maxBytes: Int?) async throws -> Data {
        var request = URLRequest(url: target, timeoutInterval: 60)
        request.httpMethod = method
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(body.compact.utf8)
        }
        if let maxBytes {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if status == 401 {
                await GoogleTokenBox.shared.invalidate()
                throw UnauthorizedRetry()
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
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 {
            await GoogleTokenBox.shared.invalidate()
            throw UnauthorizedRetry()
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

private actor GoogleTokenBox {
    static let shared = GoogleTokenBox()
    private var cached: (token: String, until: Date)?
    private var refreshing: Task<String, Error>?

    func store(token: String, until: Date) {
        cached = (token, until)
    }

    func invalidate() {
        cached = nil
    }

    func access(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let cached, cached.until > Date() {
            return cached.token
        }
        if forceRefresh {
            cached = nil
        }
        if let inFlight = refreshing {
            return try await inFlight.value
        }
        let task = Task<String, Error> {
            guard let refresh = Vault.load(String.self, key: "google.refresh") else {
                throw ProviderError(Words.t("还没登录谷歌：在「调弦 → 连接器」里登录。"))
            }
            let client = UserDefaults.standard.string(forKey: "google.client") ?? ""
            let body = try await Google.token(["refresh_token": refresh, "client_id": client, "grant_type": "refresh_token"])
            guard let access = body["access_token"]?.string else {
                throw ProviderError("谷歌没给访问令牌。")
            }
            let until = Date().addingTimeInterval((body["expires_in"]?.number ?? 3000) - 60)
            await self.store(token: access, until: until)
            await MainActor.run { Google.shared.setExpired(false) }
            return access
        }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }
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
