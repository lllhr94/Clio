import Foundation

/// The identity of the recipient of a model request, separate from the credentials used to reach it.
public struct RecipientIdentity: Codable, Hashable, Sendable {
    public let endpointID: String
    public let canonicalOrigin: String
    public let protocolKind: String
    public let route: String
    public let identityRevision: UInt64

    public init(endpointID: String, canonicalOrigin: String, protocolKind: String, route: String, identityRevision: UInt64) {
        self.endpointID = endpointID
        self.canonicalOrigin = canonicalOrigin
        self.protocolKind = protocolKind
        self.route = route
        self.identityRevision = identityRevision
    }
}

public enum OutboundDataCategory: String, Codable, CaseIterable, Hashable, Sendable {
    case userImage, toolScreenshot, mcpImage, memoryCompress
}

/// One instance per turn. The caller can consult it before considering a different model recipient.
public final class WholeTurnRetryArbiter: @unchecked Sendable {
    enum Decision: Equatable {
        case retryTransient
        case retryWithoutThinking
        case retryShorterContext
        case stop
    }

    private let lock = NSLock()
    private var hasOutput = false
    private var hasSideEffect = false
    private var hasUnknownOutcome = false
    private var rejectsExplicitOff = false
    private var retriedContext = false

    public init() {}

    public func allowsBackup(after error: Error) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !Self.cancelled(error) && !hasOutput && !hasSideEffect && !hasUnknownOutcome && !rejectsExplicitOff
    }

    func recordOutput() {
        lock.lock()
        defer { lock.unlock() }
        hasOutput = true
    }

    func recordSideEffect() {
        lock.lock()
        defer { lock.unlock() }
        hasSideEffect = true
    }

    func recordUnknownOutcome() {
        lock.lock()
        defer { lock.unlock() }
        hasUnknownOutcome = true
    }

    func decide(
        after error: Error,
        requestHasOutput: Bool,
        thinking: Thinking,
        canTrimContext: Bool,
        hasTransientRetry: Bool
    ) -> Decision {
        guard !Self.cancelled(error), !requestHasOutput else { return .stop }
        lock.lock()
        defer { lock.unlock() }

        if Self.contextExceeded(error) {
            // This retries the unsatisfied model request, with the active turn and tool outcomes still present.
            guard canTrimContext, !retriedContext else { return .stop }
            retriedContext = true
            return .retryShorterContext
        }
        guard !hasOutput, !hasSideEffect, !hasUnknownOutcome else { return .stop }
        if hasTransientRetry, Self.transient(error) { return .retryTransient }
        if let failure = error as? ProviderError, failure.status == 400 || failure.status == 422 {
            if thinking == .off { rejectsExplicitOff = true }
            if thinking != .off, thinking != .auto { return .retryWithoutThinking }
        }
        return .stop
    }

    static func cancelled(_ error: Error) -> Bool {
        Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    static func transient(_ error: Error) -> Bool {
        if let url = error as? URLError {
            let codes: [URLError.Code] = [.secureConnectionFailed, .networkConnectionLost, .timedOut, .cannotConnectToHost,
                                          .notConnectedToInternet, .dnsLookupFailed, .cannotFindHost, .badServerResponse]
            return codes.contains(url.code)
        }
        if let failure = error as? ProviderError, let status = failure.status {
            return status == 429 || (500...599).contains(status)
        }
        return false
    }

    static func contextExceeded(_ error: Error) -> Bool {
        guard let failure = error as? ProviderError,
              failure.status == nil || failure.status == 400 || failure.status == 413 || failure.status == 422
        else { return false }
        let words = failure.message.lowercased()
        return words.contains("context_length_exceeded") || words.contains("too many tokens")
            || (words.contains("context") && ["length", "too long", "maximum", "window", "exceed"].contains(where: words.contains))
    }
}
