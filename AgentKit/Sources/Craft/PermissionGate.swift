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

/// Identifies the exact execution target bound when a turn's tools were created
/// (execution chat, bound host/workplace identity, and resolved permission grant key).
/// Switching a conversation's workplace mid-turn never silently re-evaluates an already-bound tool
/// under a different host's permissions or executes on an obsolete host.
public struct ToolExecutionContext: Equatable, Sendable {
    public let executionChat: String
    /// Stable host/workplace identity bound to this tool instance (e.g. "desk", "den", "hill:<id>", or "" for non-workspace tools).
    public let hostID: String
    /// Stable permission ability key bound to this tool instance (e.g. `Grant.rawValue`).
    public let grantID: String

    public init(executionChat: String, hostID: String = "", grantID: String = "") {
        self.executionChat = executionChat
        self.hostID = hostID
        self.grantID = grantID
    }
}

/// Thread-safe mirror of each conversation's current workplace/host identity so off-MainActor
/// `LiveGatedTool` checks can synchronously detect mid-turn workplace switches.
public final class HostBindingBook: @unchecked Sendable {
    private let lock = NSLock()
    private var hosts: [String: String] = [:]

    public init() {}

    public func set(_ hostID: String, for chat: String) {
        lock.lock()
        hosts[chat] = hostID
        lock.unlock()
    }

    public func current(for chat: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return hosts[chat]
    }
}

/// Records explicit one-shot user approvals bound to one exact tool invocation and execution context
/// so `LiveGatedTool.run` never double-prompts a delegated helper and never leaks an approval to another call, chat, or host.
public final class ApprovalReceiptBook: @unchecked Sendable {
    private struct Entry {
        let context: ToolExecutionContext
        let tool: String
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    public init() {}

    public func record(invocation: String, context: ToolExecutionContext, tool: String) {
        guard !invocation.isEmpty else { return }
        lock.lock()
        entries[invocation] = Entry(context: context, tool: tool)
        lock.unlock()
    }

    public func consume(invocation: String, context: ToolExecutionContext, tool: String) -> Bool {
        guard !invocation.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[invocation],
              entry.context == context,
              entry.tool == tool else {
            return false
        }
        entries.removeValue(forKey: invocation)
        return true
    }

    public func revoke(invocation: String) {
        guard !invocation.isEmpty else { return }
        lock.lock()
        entries.removeValue(forKey: invocation)
        lock.unlock()
    }

    public func clear(executionChat: String) {
        lock.lock()
        entries = entries.filter { $0.value.context.executionChat != executionChat }
        lock.unlock()
    }

    public func clear(executionChat: String, hostID: String) {
        lock.lock()
        entries = entries.filter {
            !($0.value.context.executionChat == executionChat && $0.value.context.hostID == hostID)
        }
        lock.unlock()
    }
}

/// Coordinates pending approval continuations synchronously with policy revisions so rapid permission toggles
/// (e.g. allow -> ask, or off -> ask/allow) never commit a stale decision, and expired approvals never commit grants.
public final class PendingApprovalQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var revision: UInt64 = 0
    private var waiters: [String: CheckedContinuation<PendingApprovalResolution, Never>] = [:]
    private var activeIDs: Set<String> = []
    private var cancelledIDs: Set<String> = []

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

    private func beginWait(_ id: String) {
        lock.lock()
        activeIDs.insert(id)
        lock.unlock()
    }

    private func endWait(_ id: String) {
        lock.lock()
        activeIDs.remove(id)
        cancelledIDs.remove(id)
        lock.unlock()
    }

    private func register(_ id: String, continuation: CheckedContinuation<PendingApprovalResolution, Never>, cancelled: Bool) {
        lock.lock()
        if cancelled || cancelledIDs.remove(id) != nil {
            lock.unlock()
            continuation.resume(returning: .rejectedByUser)
            return
        }
        waiters[id] = continuation
        lock.unlock()
    }

    /// Cancels a waiting (or about-to-wait) approval without risking a missed cancellation race.
    @discardableResult
    public func cancel(id: String) -> Bool {
        let waiter: CheckedContinuation<PendingApprovalResolution, Never>?
        lock.lock()
        waiter = waiters.removeValue(forKey: id)
        if waiter == nil, activeIDs.contains(id) {
            cancelledIDs.insert(id)
        }
        lock.unlock()
        guard let waiter else { return false }
        waiter.resume(returning: .rejectedByUser)
        return true
    }

    /// Atomically claims a waiting approval for an explicit user decision.
    /// `beforeResume` runs ONLY when the approval is still actively waiting (never for expired/settled IDs)
    /// and completes before resuming the continuation so woken callers immediately observe updated grants.
    @discardableResult
    public func resolveByUser(id: String, allow: Bool, beforeResume: () -> Void = {}) -> Bool {
        let waiter: CheckedContinuation<PendingApprovalResolution, Never>?
        lock.lock()
        waiter = waiters.removeValue(forKey: id)
        lock.unlock()
        guard let waiter else { return false }
        beforeResume()
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
        beginWait(id)
        defer { endWait(id) }
        while true {
            if Task.isCancelled { return false }
            switch evaluate() {
            case .allow: return true
            case .reject: return false
            case .wait: break
            }
            onEnqueue()
            let cancelled = Task.isCancelled
            let resolution = await withCheckedContinuation { (continuation: CheckedContinuation<PendingApprovalResolution, Never>) in
                self.register(id, continuation: continuation, cancelled: cancelled)
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

/// Wraps a tool with live permission evaluation so mid-turn permission changes take effect immediately,
/// tightening `.allow -> .ask` or recovering `.off -> .ask/.allow` before execution is checked atomically,
/// and switching a conversation's workplace/host blocks stale executions on the previous host.
public struct LiveGatedTool: AgentTool {
    public let inner: AgentTool
    public let context: ToolExecutionContext
    let receipts: ApprovalReceiptBook?
    let policyRevision: (@Sendable () -> UInt64)?
    let isContextStillValid: (@Sendable () -> Bool)?
    let access: @Sendable () -> LiveToolAccess
    let reconfirm: (@Sendable (ApprovalAsk, String) async -> Bool)?

    public static let workplaceChangedRefusal = "这段对话的工作地点已经切换，为避免在原来的主机上误操作，本次没有继续执行。请按新的工作地点重新发起。"

    public init(
        inner: AgentTool,
        context: ToolExecutionContext = ToolExecutionContext(executionChat: ""),
        receipts: ApprovalReceiptBook? = nil,
        policyRevision: (@Sendable () -> UInt64)? = nil,
        isContextStillValid: (@Sendable () -> Bool)? = nil,
        access: @escaping @Sendable () -> LiveToolAccess,
        reconfirm: (@Sendable (ApprovalAsk, String) async -> Bool)? = nil
    ) {
        self.inner = inner
        self.context = context
        self.receipts = receipts
        self.policyRevision = policyRevision
        self.isContextStillValid = isContextStillValid
        self.access = access
        self.reconfirm = reconfirm
    }

    public var spec: ToolSpec { inner.spec }
    public func label(for arguments: JSONValue) -> String { inner.label(for: arguments) }

    public func approval(for arguments: JSONValue) -> ApprovalAsk? {
        if let isContextStillValid, !isContextStillValid() {
            return nil
        }
        return evaluate(for: arguments, using: access())
    }

    public func run(_ arguments: JSONValue) async throws -> ToolOutput {
        if let activeID = ToolInvocation.currentID {
            return try await runBound(arguments, invocationID: activeID)
        }
        let fallbackID = UUID().uuidString
        return try await ToolInvocation.$currentID.withValue(fallbackID) {
            try await runBound(arguments, invocationID: fallbackID)
        }
    }

    private func runBound(_ arguments: JSONValue, invocationID: String) async throws -> ToolOutput {
        defer { receipts?.revoke(invocation: invocationID) }
        if let isContextStillValid, !isContextStillValid() {
            return ToolOutput(Self.workplaceChangedRefusal, isError: true)
        }
        let userApproved = receipts?.consume(invocation: invocationID, context: context, tool: spec.name) ?? false
        if userApproved {
            if Task.isCancelled {
                return ToolOutput("这一轮已经停下，这一步没有做。", isError: true)
            }
            if let isContextStillValid, !isContextStillValid() {
                return ToolOutput(Self.workplaceChangedRefusal, isError: true)
            }
            if case .off(let refusal) = access() {
                return ToolOutput(refusal, isError: true)
            }
            return try await inner.run(arguments)
        }
        // This invocation was not explicitly approved by the user on the approval slip/card.
        // Re-evaluate live permissions right before executing so tightening `.allow -> .ask`
        // or recovering `.off -> .ask` prompts instead of running silently.
        while true {
            if Task.isCancelled {
                return ToolOutput("这一轮已经停下，这一步没有做。", isError: true)
            }
            if let isContextStillValid, !isContextStillValid() {
                return ToolOutput(Self.workplaceChangedRefusal, isError: true)
            }
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
            if Task.isCancelled {
                return ToolOutput("这一轮已经停下，这一步没有做。", isError: true)
            }
            if let isContextStillValid, !isContextStillValid() {
                return ToolOutput(Self.workplaceChangedRefusal, isError: true)
            }
            let reconfirmedByUser = receipts?.consume(invocation: invocationID, context: context, tool: spec.name) ?? false
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
