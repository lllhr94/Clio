import Craft
import CryptoKit
import Foundation
import Network
import SafariServices
import Security

enum OAuthLoopbackAddress {
    static func callback(port: Int) -> URL? {
        guard (1...65535).contains(port) else { return nil }
        return URL(string: "http://127.0.0.1:\(port)/callback")
    }
}

enum OpenRouterKeyOAuth {
    enum Failure: Error { case invalidKey, unreachable, timedOut }

    private static var session: URLSession { NetworkRuntime.shared.session(for: .default, ephemeral: true) }

    struct Attempt: Sendable {
        let verifier: String
        let state: String

        static func new() throws -> Attempt {
            Attempt(verifier: try randomString(), state: try randomString())
        }

        private static func randomString() throws -> String {
            var bytes = [UInt8](repeating: 0, count: 32)
            let result = bytes.withUnsafeMutableBytes {
                SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
            }
            guard result == errSecSuccess else { throw Failure.unreachable }
            return OpenRouterKeyOAuth.base64URL(Data(bytes))
        }
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func authorizationURL(port: UInt16, attempt: Attempt) -> URL? {
        guard let callback = OAuthLoopbackAddress.callback(port: Int(port)) else { return nil }
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = "openrouter.ai"
        parts.path = "/auth"
        parts.queryItems = [
            URLQueryItem(name: "callback_url", value: callback.absoluteString),
            URLQueryItem(name: "state", value: attempt.state),
            URLQueryItem(name: "key_label", value: "Clio"),
            URLQueryItem(name: "code_challenge", value: base64URL(Data(SHA256.hash(data: Data(attempt.verifier.utf8))))),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return parts.url
    }

    static func callbackCode(_ url: URL, port: UInt16, state: String) -> String? {
        guard let expected = OAuthLoopbackAddress.callback(port: Int(port)),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == expected.scheme, parts.host == expected.host, parts.port == expected.port,
              parts.percentEncodedPath == "/callback", parts.user == nil, parts.password == nil, parts.fragment == nil,
              let fields = parts.queryItems, fields.filter({ $0.name == "state" }).map(\.value) == [state],
              !fields.contains(where: { $0.name == "error" }) else { return nil }
        let codes = fields.filter { $0.name == "code" }
        guard codes.count == 1, let code = codes[0].value, !code.isEmpty else { return nil }
        return code
    }

    static func parseKey(_ data: Data) throws -> String {
        struct Reply: Decodable { let key: String }
        guard let key = try? JSONDecoder().decode(Reply.self, from: data).key,
              !key.isEmpty, !key.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains) else {
            throw Failure.invalidKey
        }
        return key
    }

    @MainActor
    static func authorize() async throws -> String {
        let ticket = try OAuthPresentation.acquire()
        defer { OAuthPresentation.release(ticket) }
        let attempt = try Attempt.new()
        let code = try await OpenRouterLoopback(attempt: attempt).open()
        try Task.checkCancellation()
        let endpoint = URL(string: "https://openrouter.ai/api/v1/auth/keys")!
        guard await URLAccessPurpose.oauthEndpoint.allows(endpoint) else { throw Failure.unreachable }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode([
            "code": code, "code_verifier": attempt.verifier, "code_challenge_method": "S256",
        ])
        let (data, response) = try await session.data(for: request, delegate: OAuthRedirectGuard())
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw Failure.invalidKey
        }
        return try parseKey(data)
    }
}

@MainActor
private final class OpenRouterLoopback: NSObject, SFSafariViewControllerDelegate {
    private let listener: NWListener
    private let attempt: OpenRouterKeyOAuth.Attempt
    private var continuation: CheckedContinuation<String, Error>?
    private var port: UInt16?
    private var safari: SFSafariViewController?
    private var timer: Task<Void, Never>?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    init(attempt: OpenRouterKeyOAuth.Attempt) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        self.attempt = attempt
    }

    func open() async throws -> String {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                listener.stateUpdateHandler = { [weak self] state in
                    MainActor.assumeIsolated { self?.listenerChanged(state) }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    MainActor.assumeIsolated {
                        if let self { self.accept(connection) } else { connection.cancel() }
                    }
                }
                timer = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(180)) } catch { return }
                    self?.finish(.failure(OpenRouterKeyOAuth.Failure.timedOut))
                }
                listener.start(queue: .main)
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    private func listenerChanged(_ state: NWListener.State) {
        guard continuation != nil else { return }
        switch state {
        case .ready:
            guard safari == nil, let port = listener.port?.rawValue,
                  let page = OpenRouterKeyOAuth.authorizationURL(port: port, attempt: attempt),
                  let presenter = OAuthPresentation.presenter else {
                finish(.failure(OpenRouterKeyOAuth.Failure.unreachable))
                return
            }
            self.port = port
            let browser = SFSafariViewController(url: page)
            browser.delegate = self
            safari = browser
            presenter.present(browser, animated: true)
        case .failed, .waiting, .cancelled:
            finish(.failure(OpenRouterKeyOAuth.Failure.unreachable))
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard continuation != nil, port != nil, connections.count < 8 else { connection.cancel(); return }
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
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        let limit = 8192
        connection.receive(minimumIncompleteLength: 1, maximumLength: limit - buffer.count) { [weak self] data, _, ended, error in
            MainActor.assumeIsolated {
                guard let self, self.continuation != nil, error == nil else { connection.cancel(); return }
                var bytes = buffer
                if let data { bytes.append(data) }
                if let range = bytes.range(of: Data("\r\n\r\n".utf8)) {
                    self.respond(connection, headers: bytes[..<range.lowerBound])
                } else if ended || bytes.count >= limit {
                    connection.cancel()
                } else {
                    self.receive(connection, buffer: bytes)
                }
            }
        }
    }

    private func respond(_ connection: NWConnection, headers: Data) {
        guard let port else { connection.cancel(); return }
        let authority = "127.0.0.1:\(port)"
        let lines = String(decoding: headers, as: UTF8.self).components(separatedBy: "\r\n")
        let request = lines.first?.split(separator: " ") ?? []
        let hosts = lines.dropFirst().filter { $0.lowercased().hasPrefix("host:") }
        var code: String?
        if request.count == 3, request[0] == "GET", request[1].hasPrefix("/callback?"),
           hosts.count == 1, hosts[0].dropFirst(5).trimmingCharacters(in: .whitespaces) == authority,
           let url = URL(string: "http://\(authority)\(request[1])") {
            code = OpenRouterKeyOAuth.callbackCode(url, port: port, state: attempt.state)
        }
        let status = code == nil ? "400 Bad Request" : "200 OK"
        let body = L.t(code == nil ? "services.oauthInvalidCallback" : "services.oauthReturnToApp")
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        let received = code
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            MainActor.assumeIsolated {
                connection.cancel()
                if let received { self?.finish(.success(received)) }
            }
        })
    }

    func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<String, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timer?.cancel()
        listener.cancel()
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        safari?.dismiss(animated: true)
        safari = nil
        continuation.resume(with: result)
    }
}
