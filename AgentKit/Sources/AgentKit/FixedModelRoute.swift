import Foundation

/// An endpoint's authorization names a specific origin and route, so never resend its body on a redirect.
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

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 900
        return URLSession(configuration: configuration, delegate: rejectDelegate, delegateQueue: nil)
    }()
}
