import Foundation

/// An endpoint's authorization names a specific origin and route, so never resend its body on a redirect.
/// All fixed-route requests still run through `HTTP.SessionPool` (passing `rejectDelegate` per task) so
/// network/proxy changes rotate sessions cleanly instead of pinning stale connections.
enum FixedModelRoute {
    final class RejectRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    static let rejectDelegate: URLSessionTaskDelegate = RejectRedirect()
}
