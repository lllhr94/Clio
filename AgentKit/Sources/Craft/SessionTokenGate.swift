import Foundation

public struct SessionTokenKey: Hashable, Sendable {
    public let account: String
    public let issuer: String
    public let resource: String
    public let epoch: UInt64

    public init(account: String, issuer: String, resource: String, epoch: UInt64) {
        self.account = account
        self.issuer = issuer
        self.resource = resource
        self.epoch = epoch
    }
}

/// Single-flight access token cache bound to a monotonically increasing session epoch.
/// Any session reset (sign-out) or credential replacement (account switch / re-login)
/// bumps the epoch synchronously, cancels any in-flight refresh, and prevents older
/// refresh requests from writing back to cache, clearing expiry, or returning stale tokens.
public actor SessionTokenGate {
    public struct RefreshOutput: Sendable {
        public let token: String
        public let expiresAt: Date

        public init(token: String, expiresAt: Date) {
            self.token = token
            self.expiresAt = expiresAt
        }
    }

    public struct Lease: Sendable, Equatable {
        public let token: String
        public let epoch: UInt64

        public init(token: String, epoch: UInt64) {
            self.token = token
            self.epoch = epoch
        }
    }

    public struct SignInAttempt: Sendable, Equatable {
        public let baseEpoch: UInt64

        public init(baseEpoch: UInt64) {
            self.baseEpoch = baseEpoch
        }
    }

    public enum GateError: Error, Equatable, Sendable {
        case sessionChanged
    }

    private struct CachedEntry {
        let token: String
        let expiresAt: Date
        let epoch: UInt64
    }

    private struct InFlight {
        let id: UUID
        let epoch: UInt64
        let task: Task<Lease, Error>
    }

    private final class AtomicEpoch: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 0

        func load() -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        @discardableResult
        func bump(_ update: () -> Void = {}) -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            update()
            value += 1
            return value
        }

        func compareAndBump(expected: UInt64, update: () throws -> Void) rethrows -> UInt64? {
            lock.lock()
            defer { lock.unlock() }
            guard value == expected else { return nil }
            try update()
            value += 1
            return value
        }

        func withCurrent<T>(_ expected: UInt64?, _ operation: (UInt64) throws -> T) throws -> T {
            lock.lock()
            defer { lock.unlock() }
            if let expected, expected != value { throw GateError.sessionChanged }
            return try operation(value)
        }
    }

    private struct Scope: Hashable, Sendable {
        let account: String
        let issuer: String
        let resource: String
    }

    private final class Scopes: @unchecked Sendable {
        private let lock = NSLock()
        private var gates: [Scope: SessionTokenGate] = [:]

        func gate(_ scope: Scope) -> SessionTokenGate {
            lock.lock()
            defer { lock.unlock() }
            if let gate = gates[scope] { return gate }
            let gate = SessionTokenGate(scope: scope)
            gates[scope] = gate
            return gate
        }

    }

    private let scopes = Scopes()
    private let scope: Scope?
    private let epochCounter = AtomicEpoch()
    private var cached: CachedEntry?
    private var inFlight: InFlight?

    public init() { scope = nil }

    private init(scope: Scope) { self.scope = scope }

    public nonisolated func scoped(account: String, issuer: String, resource: String) -> SessionTokenGate {
        scopes.gate(Scope(account: account, issuer: issuer, resource: resource))
    }

    public nonisolated func sessionKey() -> SessionTokenKey? {
        scope.map { SessionTokenKey(account: $0.account, issuer: $0.issuer, resource: $0.resource, epoch: currentEpoch()) }
    }

    public static func validateLeaseOrigin(_ url: URL, allowedHTTPSOrigins: Set<String>) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              let origin = EndpointAddressPolicy.rawOrigin(url.absoluteString) else { return false }
        return allowedHTTPSOrigins.contains { raw in
            guard let candidate = URL(string: raw), candidate.scheme?.lowercased() == "https",
                  candidate.user == nil, candidate.password == nil, candidate.query == nil,
                  candidate.fragment == nil, candidate.path.isEmpty || candidate.path == "/" else { return false }
            return EndpointAddressPolicy.rawOrigin(raw) == origin
        }
    }

    /// Current session epoch. Safe to read from any context.
    public nonisolated func currentEpoch() -> UInt64 {
        epochCounter.load()
    }

    /// Captures the current session epoch before starting an interactive sign-in / re-login flow.
    /// If `signOut()` bumps the epoch while OAuth authorization or token exchange is in flight,
    /// `isSignInActive(_:)` and `commitSignInSynchronously(_:)` will reject the stale login.
    public nonisolated func beginSignIn() -> SignInAttempt {
        SignInAttempt(baseEpoch: epochCounter.load())
    }

    /// Returns true while no sign-out or competing sign-in has bumped the epoch since `beginSignIn()`.
    public nonisolated func isSignInActive(_ attempt: SignInAttempt) -> Bool {
        epochCounter.load() == attempt.baseEpoch
    }

    /// Atomically verifies that `attempt` is still active and advances the session epoch to
    /// supersede any older refresh tasks. Returns nil if the user signed out or another login won.
    public nonisolated func commitSignInSynchronously(_ attempt: SignInAttempt) -> UInt64? {
        commitSignIn(attempt) {}
    }

    /// Runs the durable write under the same epoch lock used by sign-out and refresh commits.
    public nonisolated func commitSignIn(_ attempt: SignInAttempt, persist: () throws -> Void) rethrows -> UInt64? {
        guard let next = try epochCounter.compareAndBump(expected: attempt.baseEpoch, update: persist) else {
            return nil
        }
        Task { await self.discardState(before: next) }
        return next
    }

    /// Synchronously invalidates the current session (e.g. from synchronous `signOut()`
    /// or right after writing new credentials to Keychain) so no older in-flight refresh
    /// can commit or return after this call returns, and schedules actor-side cleanup.
    @discardableResult
    public nonisolated func invalidateSessionSynchronously() -> UInt64 {
        invalidateSession {}
    }

    @discardableResult
    public nonisolated func invalidateSession(remove: () -> Void) -> UInt64 {
        let next = epochCounter.bump(remove)
        Task { await self.discardState(before: next) }
        return next
    }

    /// Keep a short synchronous credential transaction fenced against a session change.
    public nonisolated func withCurrentEpoch<T>(_ expected: UInt64? = nil, _ operation: (UInt64) throws -> T) throws -> T {
        try epochCounter.withCurrent(expected, operation)
    }

    /// Async session invalidation: bumps the epoch, cancels any in-flight refresh, and clears cache.
    @discardableResult
    public func resetSession() -> UInt64 {
        let next = epochCounter.bump()
        discardState(before: next)
        return next
    }

    /// Replaces the session: bumps the epoch, cancels any older in-flight refresh, and optionally
    /// seeds the new session's access token.
    @discardableResult
    public func replaceSession(token: String?, expiresAt: Date?) -> UInt64 {
        let next = epochCounter.bump()
        discardState(before: next)
        if let token, let expiresAt {
            cached = CachedEntry(token: token, expiresAt: expiresAt, epoch: next)
        } else {
            cached = nil
        }
        return next
    }

    /// Stores a session token only if the epoch captured before storing is still current.
    public func store(token: String?, expiresAt: Date?, epoch: UInt64) {
        let current = epochCounter.load()
        discardState(before: current)
        guard current == epoch else { return }
        if let token, let expiresAt {
            cached = CachedEntry(token: token, expiresAt: expiresAt, epoch: epoch)
        } else {
            cached = nil
        }
    }

    /// Clears the cached access token for a specific session/token (e.g. on HTTP 401),
    /// without disturbing a newer session or an already-refreshed token.
    public func invalidateCached(token: String? = nil, epoch: UInt64? = nil) {
        let current = epochCounter.load()
        discardState(before: current)
        guard let cached else { return }
        if let epoch, cached.epoch != epoch { return }
        if let token, cached.token != token { return }
        self.cached = nil
    }

    /// Returns a valid access token lease for the current session, deduplicating concurrent refreshes.
    public func access(
        forceRefresh: Bool = false,
        expectedEpoch: UInt64? = nil,
        now: @Sendable () -> Date = Date.init,
        refresh: @escaping @Sendable (UInt64) async throws -> RefreshOutput,
        onCommitted: (@Sendable (UInt64) async -> Void)? = nil
    ) async throws -> Lease {
        let epoch = epochCounter.load()
        discardState(before: epoch)

        if let expectedEpoch, expectedEpoch != epoch {
            throw GateError.sessionChanged
        }

        if let existing = inFlight, existing.epoch == epoch {
            do {
                let lease = try await existing.task.value
                guard epochCounter.load() == epoch else { throw GateError.sessionChanged }
                return lease
            } catch {
                if epochCounter.load() != epoch { throw GateError.sessionChanged }
                throw error
            }
        }

        if !forceRefresh, let cached, cached.epoch == epoch, cached.expiresAt > now() {
            return Lease(token: cached.token, epoch: epoch)
        }
        if forceRefresh, cached?.epoch == epoch {
            cached = nil
        }

        let taskId = UUID()
        let task = Task<Lease, Error> {
            do {
                let output = try await refresh(epoch)
                try Task.checkCancellation()
                return try await self.commitRefresh(id: taskId, epoch: epoch, output: output, onCommitted: onCommitted)
            } catch {
                await self.clearInFlight(id: taskId)
                throw error
            }
        }
        inFlight = InFlight(id: taskId, epoch: epoch, task: task)

        do {
            let lease = try await task.value
            guard epochCounter.load() == epoch else { throw GateError.sessionChanged }
            return lease
        } catch {
            clearInFlight(id: taskId)
            if epochCounter.load() != epoch {
                throw GateError.sessionChanged
            }
            throw error
        }
    }

    private func commitRefresh(
        id: UUID,
        epoch: UInt64,
        output: RefreshOutput,
        onCommitted: (@Sendable (UInt64) async -> Void)?
    ) async throws -> Lease {
        defer { clearInFlight(id: id) }
        guard epochCounter.load() == epoch else {
            discardState(before: epochCounter.load())
            throw GateError.sessionChanged
        }
        cached = CachedEntry(token: output.token, expiresAt: output.expiresAt, epoch: epoch)
        if let onCommitted {
            await onCommitted(epoch)
        }
        guard epochCounter.load() == epoch else {
            discardState(before: epochCounter.load())
            throw GateError.sessionChanged
        }
        return Lease(token: output.token, epoch: epoch)
    }

    private func discardState(before currentEpoch: UInt64) {
        if let cached, cached.epoch < currentEpoch {
            self.cached = nil
        }
        if let inFlight, inFlight.epoch < currentEpoch {
            inFlight.task.cancel()
            self.inFlight = nil
        }
    }

    private func clearInFlight(id: UUID) {
        if inFlight?.id == id {
            inFlight = nil
        }
    }
}
