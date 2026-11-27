import Foundation

public enum OAuthRefreshErrorKind: Equatable, Sendable {
    case reauthRequired(code: String?)
    case transient
    case other
}

public enum OAuthRefreshErrorClassifier {
    private static let revoked: Set<String> = [
        "invalid_grant", "invalid_client", "unauthorized_client",
        "invalid_token", "expired_token", "access_denied",
    ]

    public static func classify(
        statusCode: Int?, body: Data?, error: Error?, wwwAuthenticate: String? = nil
    ) -> OAuthRefreshErrorKind {
        if error is URLError { return .transient }
        guard let statusCode else { return .other }
        if statusCode == 429 || (500..<600).contains(statusCode) { return .transient }
        guard [400, 401, 403].contains(statusCode) else { return .other }
        let object = body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        if let code = object?["error"] as? String, revoked.contains(code) {
            return .reauthRequired(code: code)
        }
        if statusCode == 401, let wwwAuthenticate {
            for challenge in MCPDiscoveryPolicy.challenges(wwwAuthenticate) where challenge.scheme == "bearer" {
                if let code = challenge.parameters["error"], code == "invalid_token" || code == "invalid_grant" {
                    return .reauthRequired(code: code)
                }
            }
        }
        return statusCode == 400 && object?["error"] as? String == nil ? .transient : .other
    }
}
