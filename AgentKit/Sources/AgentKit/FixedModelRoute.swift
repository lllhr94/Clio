import Foundation

/// An endpoint's authorization names a specific origin and route, so never resend its body on a redirect.
enum FixedModelRoute {
    private final class RejectRedirect: NSObject, URLSessionTaskDelegate {
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

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 900
        return URLSession(configuration: configuration, delegate: RejectRedirect(), delegateQueue: nil)
    }()
}
