import Craft
import Foundation
import XCTest

final class OAuthRefreshErrorClassifierTests: XCTestCase {
    private func body(_ code: String) -> Data { Data("{\"error\":\"\(code)\"}".utf8) }

    func testOnlySpecifiedStructuredErrorsRequireReauthorization() {
        for status in [400, 401, 403] {
            for code in ["invalid_grant", "invalid_client", "unauthorized_client", "invalid_token", "expired_token", "access_denied"] {
                XCTAssertEqual(OAuthRefreshErrorClassifier.classify(statusCode: status, body: body(code), error: nil),
                               .reauthRequired(code: code))
            }
        }
        XCTAssertEqual(OAuthRefreshErrorClassifier.classify(statusCode: 400, body: body("invalid_scope"), error: nil), .other)
        XCTAssertEqual(OAuthRefreshErrorClassifier.classify(statusCode: 404, body: body("invalid_grant"), error: nil), .other)
    }

    func testGatewayAndTransportFailuresAreTransientEvenWithOAuthLookingBodies() {
        for status in [429, 500, 502, 503, 599] {
            XCTAssertEqual(OAuthRefreshErrorClassifier.classify(statusCode: status, body: body("invalid_grant"), error: nil), .transient)
        }
        let codes: [URLError.Code] = [.timedOut, .notConnectedToInternet, .networkConnectionLost, .dnsLookupFailed, .cannotFindHost]
        for code in codes {
            XCTAssertEqual(OAuthRefreshErrorClassifier.classify(statusCode: nil, body: nil, error: URLError(code)), .transient)
        }
        XCTAssertEqual(OAuthRefreshErrorClassifier.classify(statusCode: 400, body: Data("<html>invalid_grant</html>".utf8), error: nil), .transient)
        XCTAssertEqual(OAuthRefreshErrorClassifier.classify(statusCode: 400, body: Data(#"{"error":123}"#.utf8), error: nil), .transient)
        XCTAssertEqual(OAuthRefreshErrorClassifier.classify(statusCode: 401, body: Data("invalid_token".utf8), error: nil), .other)
    }

    func testOnly401UsesStructuredAuthenticateError() {
        let challenge = #"Basic realm="other", Bearer realm="X,Y", ERROR=invalid_token"#
        XCTAssertEqual(OAuthRefreshErrorClassifier.classify(statusCode: 401, body: nil, error: nil, wwwAuthenticate: challenge),
                       .reauthRequired(code: "invalid_token"))
        XCTAssertEqual(OAuthRefreshErrorClassifier.classify(statusCode: 403, body: nil, error: nil, wwwAuthenticate: challenge), .other)
        XCTAssertEqual(OAuthRefreshErrorClassifier.classify(statusCode: 401, body: nil, error: nil,
                                                           wwwAuthenticate: #"Bearer error_description="invalid_grant""#), .other)
    }
}
