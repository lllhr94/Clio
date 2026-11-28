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

/// One instance per turn. Centralizes all automatic recovery decisions (transient retry, 400/422 thinking
/// downgrade, context trim, 413 image reduction, reasoning-block tool-call regeneration, and multi-level
/// backup handoff) while giving `explicitOff` terminal priority over every downgrade/fallback path.
public final class WholeTurnRetryArbiter: @unchecked Sendable {
    public enum Decision: Equatable, Sendable {
        case retryTransient
        case retryWithoutThinking
        case retryShorterContext
        case retryWithoutImages
        case retryRegenerateToolCall
        case stop
    }

    private let lock = NSLock()
    private var hasOutput = false
    private var hasSideEffect = false
    private var hasUnknownOutcome = false
    private var rejectsExplicitOff = false
    private var retriedContext = false
    private var retriedWithoutImages = false
    private var retriedReasoningToolCall = false

    public init() {}

    public var isExplicitOffTerminal: Bool {
        lock.lock()
        defer { lock.unlock() }
        return rejectsExplicitOff
    }

    public func recordExplicitOffRejected() {
        lock.lock()
        defer { lock.unlock() }
        rejectsExplicitOff = true
    }

    public func allowsBackup(after error: Error) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !Self.cancelled(error) && !hasOutput && !hasSideEffect && !hasUnknownOutcome && !rejectsExplicitOff
    }

    public func recordOutput() {
        lock.lock()
        defer { lock.unlock() }
        hasOutput = true
    }

    public func recordSideEffect() {
        lock.lock()
        defer { lock.unlock() }
        hasSideEffect = true
    }

    public func recordUnknownOutcome() {
        lock.lock()
        defer { lock.unlock() }
        hasUnknownOutcome = true
    }

    /// Evaluates whether a reasoning-only reply containing suspected raw tool-call JSON/markup may regenerate once.
    public func allowsReasoningToolRegeneration(hasDeliveredTextOrTools: Bool, isExplicitOff: Bool = false) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !rejectsExplicitOff, !isExplicitOff, !hasDeliveredTextOrTools,
              !hasSideEffect, !hasUnknownOutcome, !retriedReasoningToolCall else { return false }
        retriedReasoningToolCall = true
        return true
    }

    public func decide(
        after error: Error,
        requestHasOutput: Bool,
        thinking: Thinking,
        canTrimContext: Bool,
        hasTransientRetry: Bool,
        hasImages: Bool = false,
        isExplicitOff: Bool = false
    ) -> Decision {
        guard !Self.cancelled(error), !requestHasOutput else { return .stop }
        lock.lock()
        defer { lock.unlock() }

        let explicitOffRequested = isExplicitOff || thinking == .off
        if rejectsExplicitOff {
            return .stop
        }

        // Explicit-off thinking parameter rejection is a terminal state: blocks downgrades, trims, regens, and backups.
        // Non-thinking 400/422 errors (e.g. image payload too large, quota, bad image) are NOT thinking rejections.
        if explicitOffRequested, let failure = error as? ProviderError, failure.status == 400 || failure.status == 422 {
            if Self.isThinkingParameterRejection(failure) {
                rejectsExplicitOff = true
                return .stop
            }
        }

        // 413 payload-too-large with inline images: strip images once (preserving missing-image placeholders) if side-effect free.
        if Self.payloadTooLargeForImages(error), hasImages, !retriedWithoutImages,
           !hasOutput, !hasSideEffect, !hasUnknownOutcome {
            retriedWithoutImages = true
            return .retryWithoutImages
        }

        if Self.contextExceeded(error) {
            // This retries the unsatisfied model request, with the active turn and tool outcomes still present.
            guard canTrimContext, !retriedContext else { return .stop }
            retriedContext = true
            return .retryShorterContext
        }
        guard !hasOutput, !hasSideEffect, !hasUnknownOutcome else { return .stop }
        if hasTransientRetry, Self.transient(error) { return .retryTransient }
        if let failure = error as? ProviderError, failure.status == 400 || failure.status == 422 {
            if !explicitOffRequested, thinking != .auto, Self.isThinkingParameterRejection(failure) {
                return .retryWithoutThinking
            }
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

    static func payloadTooLargeForImages(_ error: Error) -> Bool {
        guard let failure = error as? ProviderError else { return false }
        if failure.status == 413 { return true }
        let words = failure.message.lowercased()
        return (failure.status == 400 || failure.status == 422)
            && (words.contains("request entity too large") || words.contains("payload too large") || words.contains("image_too_large"))
    }

    /// Confirms a 400/422 error actually rejected thinking/reasoning parameters rather than signatures,
    /// tool call pairing, image inputs, auth, or max_tokens budget violations.
    public static func isThinkingParameterRejection(_ failure: ProviderError) -> Bool {
        guard failure.status == 400 || failure.status == 422 else { return false }
        let words = failure.message.lowercased()
        let nonThinkingRejections = [
            "signature", "tool_use", "tool_result", "tool_call_id", "invalid_image", "image_url",
            "media_type", "cache_control", "invalid_api_key", "permission", "credit", "quota",
        ]
        if nonThinkingRejections.contains(where: { words.contains($0) }) {
            return false
        }
        let thinkingKeywords = [
            "reasoning_effort", "enable_thinking", "thinking_budget", "budget_tokens", "reasoning_split",
            "output_config", "thinking", "reasoning", "effort",
        ]
        return thinkingKeywords.contains(where: { words.contains($0) })
    }

    /// Detects reasoning-only output containing suspected raw tool-call JSON/tags that failed to emit structured tool calls.
    public static func looksLikeSuspectedReasoningToolCall(reasoning: String, text: String, toolCallCount: Int) -> Bool {
        guard toolCallCount == 0, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let lower = reasoning.lowercased()
        return lower.contains("<tool_call>")
            || lower.contains("\"tool_calls\"")
            || lower.contains("\"function_call\"")
            || (lower.contains("\"name\"") && lower.contains("\"arguments\""))
    }
}
