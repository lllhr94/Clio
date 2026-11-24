import AgentKit
import Foundation

/// What the live permission setting currently allows for a tool call.
public enum LiveToolAccess: Equatable, Sendable {
    /// Disabled: skip approval and refuse execution.
    case off(String)
    /// Allowed without a policy prompt; `bypassNonForced` is true in 「放手」 mode.
    case allow(bypassNonForced: Bool)
    /// Ask the user before executing, using `title` if the tool has no own approval prompt.
    case ask(title: String)
}

/// What live permissions currently say about a waiting approval.
public enum PendingApprovalDecision: Equatable, Sendable {
    /// Keep waiting for an explicit user tap.
    case wait
    /// Live policy or standing trust now allows this call without prompting.
    case allow
    /// Live policy disabled this ability; stop this call.
    case reject
}

/// How a single suspended approval wait was woken.
public enum PendingApprovalResolution: Equatable, Sendable {
    case approvedByUser
    case rejectedByUser
    case allowedByPolicy(revision: UInt64)
    case rejectedByPolicy(revision: UInt64)
}

/// Records explicit one-shot user approvals so `LiveGatedTool.run` can distinguish an explicit tap
/// from a policy-based bypass if the policy tightens back to `.ask` right before execution starts.
public final class ApprovalReceiptBook: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    public init() {}

    public func record(chat: String, tool: String) {
        let key = "\(chat)\u{0}\(tool)"
        lock.lock()
        counts[key, default: 0] += 1
        lock.unlock()
    }

    public func consume(chat: String, tool: String) -> Bool {
        let key = "\(chat)\u{0}\(tool)"
        lock.lock()
        defer { lock.unlock() }
        guard let count = counts[key], count > 0 else { return false }
        if count == 1 {
            counts.removeValue(forKey: key)
        } else {
            counts[key] = count - 1
        }
        return true
    }

    public func clear(chat: String) {
        let prefix = "\(chat)\u{0}"
        lock.lock()
        counts = counts.filter { !$0.key.hasPrefix(prefix) }
        lock.unlock()
    }
}

/// Coordinates pending approval continuations synchronously with policy revisions so rapid permission toggles
/// (e.g. allow -> ask, or off -> ask/allow) never commit a stale decision.
public final class PendingApprovalQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var revision: UInt64 = 0
    private var waiters: [String: CheckedContinuation<PendingApprovalResolution, Never>] = [:]

    public init() {}

    public var currentRevision: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return revision
    }

    @discardableResult
    public func bumpRevision() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        revision &+= 1
        return revision
    }

    public func isWaiting(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return waiters[id] != nil
    }

    private func register(_ id: String, continuation: CheckedContinuation<PendingApprovalResolution, Never>) {
        lock.lock()
        waiters[id] = continuation
        lock.unlock()
    }

    /// Resolves a waiting approval from an explicit user action or turn cancellation.
    @discardableResult
    public func resolveByUser(id: String, allow: Bool) -> Bool {
        let waiter: CheckedContinuation<PendingApprovalResolution, Never>?
        lock.lock()
        waiter = waiters.removeValue(forKey: id)
        lock.unlock()
        guard let waiter else { return false }
        waiter.resume(returning: allow ? .approvedByUser : .rejectedByUser)
        return true
    }

    /// Atomically bumps the policy revision and synchronously wakes any waiting approvals whose live decision
    /// is now `.allow` or `.reject`. Each woken waiter still re-evaluates live policy before committing.
    @discardableResult
    public func reconcile(decisions: [String: PendingApprovalDecision]) -> [String] {
        var woken: [(String, CheckedContinuation<PendingApprovalResolution, Never>, PendingApprovalResolution)] = []
        lock.lock()
        revision &+= 1
        let rev = revision
        for (id, decision) in decisions {
            guard let waiter = waiters[id] else { continue }
            switch decision {
            case .wait:
                continue
            case .allow:
                waiters.removeValue(forKey: id)
                woken.append((id, waiter, .allowedByPolicy(revision: rev)))
            case .reject:
                waiters.removeValue(forKey: id)
                woken.append((id, waiter, .rejectedByPolicy(revision: rev)))
            }
        }
        lock.unlock()
        for (_, waiter, resolution) in woken {
            waiter.resume(returning: resolution)
        }
        return woken.map(\.0)
    }

    /// Waits until the approval is resolved and atomically re-verifies live policy on policy-driven wakes.
    @MainActor
    public func awaitDecision(
        id: String,
        evaluate: @MainActor () -> PendingApprovalDecision,
        onEnqueue: @MainActor () -> Void,
        onLeave: @MainActor () -> Void,
        onUserApproved: @MainActor () -> Void = {}
    ) async -> Bool {
        while true {
            if Task.isCancelled { return false }
            switch evaluate() {
            case .allow: return true
            case .reject: return false
            case .wait: break
            }
            onEnqueue()
            let resolution = await withCheckedContinuation { (continuation: CheckedContinuation<PendingApprovalResolution, Never>) in
                self.register(id, continuation: continuation)
            }
            onLeave()
            if Task.isCancelled { return false }
            switch resolution {
            case .approvedByUser:
                if evaluate() == .reject { return false }
                onUserApproved()
                return true
            case .rejectedByUser:
                return false
            case .allowedByPolicy, .rejectedByPolicy:
                // Re-read current live policy atomically before committing:
                // tightening `.allow -> .ask` loops back to prompt; restoring `.off -> .ask/.allow` recovers cleanly.
                switch evaluate() {
                case .allow: return true
                case .reject: return false
                case .wait: continue
                }
            }
        }
    }
}

/// Wraps a tool with live permission evaluation so mid-turn permission changes take effect immediately
/// and tightening `.allow -> .ask` or recovering `.off -> .ask/.allow` before execution is checked atomically.
public struct LiveGatedTool: AgentTool {
    public let inner: AgentTool
    let chat: String
    let receipts: ApprovalReceiptBook?
    let policyRevision: (@Sendable () -> UInt64)?
    let access: @Sendable () -> LiveToolAccess
    let reconfirm: (@Sendable (ApprovalAsk, String) async -> Bool)?

    public init(
        inner: AgentTool,
        chat: String = "",
        receipts: ApprovalReceiptBook? = nil,
        policyRevision: (@Sendable () -> UInt64)? = nil,
        access: @escaping @Sendable () -> LiveToolAccess,
        reconfirm: (@Sendable (ApprovalAsk, String) async -> Bool)? = nil
    ) {
        self.inner = inner
        self.chat = chat
        self.receipts = receipts
        self.policyRevision = policyRevision
        self.access = access
        self.reconfirm = reconfirm
    }

    public var spec: ToolSpec { inner.spec }
    public func label(for arguments: JSONValue) -> String { inner.label(for: arguments) }

    public func approval(for arguments: JSONValue) -> ApprovalAsk? {
        evaluate(for: arguments, using: access())
    }

    public func run(_ arguments: JSONValue) async throws -> ToolOutput {
        let userApproved = receipts?.consume(chat: chat, tool: spec.name) ?? false
        if userApproved {
            if case .off(let refusal) = access() {
                return ToolOutput(refusal, isError: true)
            }
            return try await inner.run(arguments)
        }
        // This call was not explicitly approved by the user on the approval slip/card.
        // Re-evaluate live permissions right before executing so tightening `.allow -> .ask`
        // or recovering `.off -> .ask` prompts instead of running silently.
        while true {
            let current = access()
            if case .off(let refusal) = current {
                return ToolOutput(refusal, isError: true)
            }
            guard let ask = evaluate(for: arguments, using: current) else {
                return try await inner.run(arguments)
            }
            guard let reconfirm else {
                return ToolOutput("权限已收紧为需要确认，本次没有继续执行。", isError: true)
            }
            let revBefore = policyRevision?()
            guard await reconfirm(ask, spec.name) else {
                return ToolOutput("用户没有同意这次操作，什么都没做。除非用户再次要求，不要重试。", isError: true)
            }
            let reconfirmedByUser = receipts?.consume(chat: chat, tool: spec.name) ?? false
            if case .off(let refusal) = access() {
                return ToolOutput(refusal, isError: true)
            }
            if reconfirmedByUser {
                return try await inner.run(arguments)
            }
            // `reconfirm` returned true via policy or standing trust. If the policy revision changed
            // while `reconfirm` was running or as it resumed, re-verify before executing.
            if let policyRevision, policyRevision() != revBefore {
                continue
            }
            return try await inner.run(arguments)
        }
    }

    private func evaluate(for arguments: JSONValue, using current: LiveToolAccess) -> ApprovalAsk? {
        switch current {
        case .off:
            return nil
        case .allow(let bypassNonForced):
            guard var existing = inner.approval(for: arguments) else { return nil }
            if !existing.forced, bypassNonForced { return nil }
            if existing.code == nil {
                existing.code = Taint.codePayload(tool: spec.name, arguments: arguments)
            }
            return existing
        case .ask(let title):
            if var existing = inner.approval(for: arguments) {
                if existing.code == nil {
                    existing.code = Taint.codePayload(tool: spec.name, arguments: arguments)
                }
                return existing
            }
            return ApprovalAsk(
                title: title,
                reason: inner.label(for: arguments),
                code: Taint.codePayload(tool: spec.name, arguments: arguments)
            )
        }
    }
}
