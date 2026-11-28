import Craft
import Foundation
import SwiftUI
import UIKit

/// RFC 8628 transport for a Kimi-issued client registration. Tokens stay in memory
/// until the client has a provider-approved storage and refresh contract.
enum KimiDeviceOAuth {
    struct Registration: Sendable {
        let clientID: String
        let deviceAuthorizationEndpoint: URL
        let tokenEndpoint: URL
        var scope: String? = nil

        fileprivate var isValid: Bool {
            guard !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let host = deviceAuthorizationEndpoint.host?.lowercased(),
                  ["auth.kimi.com", "auth.kimi.ai"].contains(host),
                  tokenEndpoint.host?.lowercased() == host else { return false }
            return [deviceAuthorizationEndpoint, tokenEndpoint].allSatisfy {
                KimiDeviceOAuth.isPublicHTTPS($0) && $0.query == nil
            }
        }
    }

    struct Authorization: Decodable, Equatable, Sendable {
        let deviceCode: String
        let userCode: String
        let verificationURI: URL
        let verificationURIComplete: URL?
        let expiresIn: Int
        let interval: Int?

        enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code"
            case userCode = "user_code"
            case verificationURI = "verification_uri"
            case verificationURIComplete = "verification_uri_complete"
            case expiresIn = "expires_in"
            case interval
        }

        var pollingInterval: Int { interval ?? 5 }
        var browserURL: URL { verificationURIComplete ?? verificationURI }
    }

    struct Token: Decodable, Equatable, Sendable {
        let accessToken: String
        let tokenType: String
        let expiresIn: Int?
        let refreshToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case tokenType = "token_type"
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
        }
    }

    enum Poll: Equatable, Sendable {
        case pending, slowDown, expired, denied, success(Token)
    }

    enum Failure: Error { case invalidEndpoint, invalidResponse, expired, denied }

    private static func isPublicHTTPS(_ url: URL) -> Bool {
        URLAccessPurpose.oauthEndpoint.acceptsURL(url) && url.fragment == nil && (url.port == nil || url.port == 443)
    }

    private static func isVerificationURL(_ url: URL) -> Bool {
        guard isPublicHTTPS(url), let host = url.host?.lowercased() else { return false }
        return ["kimi.com", "www.kimi.com", "auth.kimi.com", "kimi.ai", "www.kimi.ai", "auth.kimi.ai"].contains(host)
    }

    static func parseAuthorization(_ data: Data) throws -> Authorization {
        guard let grant = try? JSONDecoder().decode(Authorization.self, from: data),
              !grant.deviceCode.isEmpty, !grant.userCode.isEmpty,
              (1...86400).contains(grant.expiresIn), (1...86400).contains(grant.pollingInterval),
              isVerificationURL(grant.verificationURI), isVerificationURL(grant.browserURL),
              grant.browserURL.host?.lowercased() == grant.verificationURI.host?.lowercased() else {
            throw Failure.invalidResponse
        }
        return grant
    }

    static func parsePoll(_ data: Data, status: Int) throws -> Poll {
        struct ErrorReply: Decodable { let error: String }
        if (400..<500).contains(status), let reply = try? JSONDecoder().decode(ErrorReply.self, from: data) {
            switch reply.error {
            case "authorization_pending": return .pending
            case "slow_down": return .slowDown
            case "expired_token": return .expired
            case "access_denied": return .denied
            default: throw Failure.invalidResponse
            }
        }
        guard (200..<300).contains(status),
              let token = try? JSONDecoder().decode(Token.self, from: data),
              token.tokenType.lowercased() == "bearer",
              !token.accessToken.isEmpty,
              !token.accessToken.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains),
              token.expiresIn.map({ $0 > 0 }) ?? true else { throw Failure.invalidResponse }
        return .success(token)
    }

    static func authorize(
        _ registration: Registration,
        showCode: @MainActor (Authorization) -> Void
    ) async throws -> Token {
        guard registration.isValid else { throw Failure.invalidEndpoint }
        var parameters = ["client_id": registration.clientID]
        if let scope = registration.scope, !scope.isEmpty { parameters["scope"] = scope }
        let (data, status) = try await post(parameters, to: registration.deviceAuthorizationEndpoint)
        guard (200..<300).contains(status) else { throw Failure.invalidResponse }
        let grant = try parseAuthorization(data)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(grant.expiresIn))
        let verificationAllowed = await URLAccessPurpose.oauthEndpoint.allows(grant.verificationURI)
        let browserAllowed = grant.browserURL == grant.verificationURI
            ? verificationAllowed : await URLAccessPurpose.oauthEndpoint.allows(grant.browserURL)
        try Task.checkCancellation()
        guard verificationAllowed, browserAllowed else { throw Failure.invalidEndpoint }
        await showCode(grant)
        var interval = grant.pollingInterval
        let fields = [
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            "device_code": grant.deviceCode, "client_id": registration.clientID,
        ]
        while clock.now < deadline {
            let next = clock.now.advanced(by: .seconds(interval))
            guard next < deadline else {
                try await clock.sleep(until: deadline)
                break
            }
            try await clock.sleep(until: next)
            let response: (Data, Int)
            let remaining = clock.now.duration(to: deadline).components
            let timeout = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
            guard timeout > 0 else { throw Failure.expired }
            do {
                response = try await post(fields, to: registration.tokenEndpoint, timeout: min(15, timeout))
            } catch let error as URLError where error.code == .timedOut {
                interval = min(86400, interval * 2)
                continue
            }
            try Task.checkCancellation()
            guard clock.now < deadline else { break }
            switch try parsePoll(response.0, status: response.1) {
            case .pending: continue
            case .slowDown: interval += 5
            case .expired: throw Failure.expired
            case .denied: throw Failure.denied
            case .success(let token): return token
            }
        }
        try Task.checkCancellation()
        throw Failure.expired
    }

    private static var session: URLSession { NetworkRuntime.shared.session(for: .default, ephemeral: true) }

    private static func post(_ fields: [String: String], to url: URL, timeout: TimeInterval = 15) async throws -> (Data, Int) {
        try Task.checkCancellation()
        guard isPublicHTTPS(url) else { throw Failure.invalidEndpoint }
        let allowed = await URLAccessPurpose.oauthEndpoint.allows(url)
        try Task.checkCancellation()
        guard allowed else { throw Failure.invalidEndpoint }
        let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let body = fields.sorted { $0.key < $1.key }.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")"
        }.joined(separator: "&")
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        do {
            let (data, response) = try await session.data(for: request, delegate: OAuthRedirectGuard())
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { throw Failure.invalidResponse }
            return (data, response.statusCode)
        } catch {
            try Task.checkCancellation()
            throw error
        }
    }
}

struct KimiDeviceCodeCard: View {
    let authorization: KimiDeviceOAuth.Authorization
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: Ink.Space.m) {
            Text(authorization.userCode).font(Ink.mono(Ink.Size.title)).textSelection(.enabled)
            Text(authorization.verificationURI.absoluteString)
                .font(Ink.footnote)
                .foregroundStyle(Ink.inkSoft)
                .textSelection(.enabled)
            Button(L.t("services.oauthCopyOpen")) {
                UIPasteboard.general.setItems(
                    [["public.utf8-plain-text": authorization.userCode]],
                    options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(TimeInterval(authorization.expiresIn))]
                )
                openURL(authorization.browserURL)
            }
            .buttonStyle(WideButtonStyle())
        }
        .padding(Ink.Space.l)
        .paperCard()
    }
}
