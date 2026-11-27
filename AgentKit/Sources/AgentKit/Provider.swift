import Foundation
#if canImport(CFNetwork)
import CFNetwork
#endif
#if canImport(Network)
import Network
#endif

/// A tool as a model sees it.
public struct ToolSpec: Equatable, Sendable {
    public var name: String
    public var description: String
    /// JSON Schema of the arguments.
    public var parameters: JSONValue

    public init(name: String, description: String, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public struct ModelRequest: Sendable {
    public var model: String
    public var system: String
    public var messages: [Message]
    public var tools: [ToolSpec]
    public var maxTokens: Int
    /// Nil: the model's own default.
    public var temperature: Double?
    /// Set when the user chose a limit; providers that need one use `maxTokens` otherwise.
    public var outputLimit: Int?
    /// How hard to think; `.auto` leaves it to the model.
    public var thinking: Thinking
    /// Optional pre-resolved v2 thinking wire fields from `ThinkingRuleResolver` (preserves exact efforts such as
    /// `minimal` / `xhigh` and vendor mutual-exclusion contracts). When non-nil, overrides legacy `style.fields(thinking)`.
    public var thinkingBodyFields: [String: ThinkingWireValue]?
    /// Optional cache-stable prefix of `system` captured from the same snapshot as `system`.
    public var systemCachePrefix: String?

    public init(
        model: String,
        system: String,
        messages: [Message],
        tools: [ToolSpec] = [],
        maxTokens: Int = 8192,
        temperature: Double? = nil,
        outputLimit: Int? = nil,
        thinking: Thinking = .auto,
        thinkingBodyFields: [String: ThinkingWireValue]? = nil,
        systemCachePrefix: String? = nil
    ) {
        self.model = model
        self.system = system
        self.messages = messages
        self.tools = tools
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.outputLimit = outputLimit
        self.thinking = thinking
        self.thinkingBodyFields = thinkingBodyFields
        self.systemCachePrefix = systemCachePrefix
    }
}

/// What a model's stream says, one piece at a time.
public enum StreamEvent: Equatable, Sendable {
    case text(String)
    case image(ReplyImage)
    case reasoning(String)
    /// Claude signs its thoughts; the signature goes back with them, or Claude will not take them.
    case reasoningSignature(String)
    /// A tool call begins; `index` keeps its pieces together.
    case toolCallStart(index: Int, id: String, name: String)
    case toolCallArguments(index: Int, delta: String)
    case finish(reason: String?)
    /// Tokens for one request. `input` counts the whole prompt, `cached` the part of it the service had cached.
    case usage(input: Int, output: Int, cached: Int = 0)
}

public struct ProviderError: Error, LocalizedError, Equatable {
    public var status: Int?
    public var message: String

    public init(status: Int? = nil, _ message: String) {
        self.status = status
        self.message = message
    }

    public var errorDescription: String? {
        guard let code = status else { return message }
        switch code {
        case 401, 403: return "密钥不对或没有权限（\(code)）：\(message)"
        case 402: return "账户余额不足：\(message)"
        case 429: return "请求太频繁或额度用完了：\(message)"
        case 500...: return "模型服务暂时出错（\(code)）：\(message)"
        default: return "模型服务拒绝了请求（\(code)）：\(message)"
        }
    }
}

public protocol ModelProvider: Sendable {
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<StreamEvent, Error>
    /// The models this key can use.
    func models() async throws -> [String]
}

/// Server-Sent Events: the JSON after `data:` on one line.
enum SSE {
    static func payload(of line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let rest = line.dropFirst(5)
        let text = rest.first == " " ? String(rest.dropFirst()) : String(rest)
        return text.isEmpty ? nil : text
    }
}

enum HTTP {
    /// Manages a shared `URLSession` that rotates across network interface or proxy changes
    /// via delayed `finishTasksAndInvalidate()` leases so active and newly-starting streams never hit an invalidated session.
    final class SessionPool: @unchecked Sendable {
        static let shared = SessionPool()

        struct Lease {
            let session: URLSession
            let generation: Int
        }

        private let lock = NSLock()
        private let factory: @Sendable (Int) -> URLSession
        private let proxySignatureProvider: @Sendable () -> String
        private var _currentSession: URLSession
        private var _generation: Int = 0
        private var _lastPathSignature: String?
        private var _lastProxySignature: String
        private var _retiredCount: Int = 0
        private var _activeCheckouts: [Int: Int] = [:]
        private var _pendingRetirement: [Int: URLSession] = [:]
        #if canImport(Network)
        private var monitor: NWPathMonitor?
        private let monitorQueue = DispatchQueue(label: "clio.http.session-pool")
        #endif

        init(
            initialSignature: String? = nil,
            startMonitor: Bool = true,
            proxySignatureProvider: @escaping @Sendable () -> String = SessionPool.currentProxySignature,
            factory: @escaping @Sendable (Int) -> URLSession = SessionPool.makeDefaultSession
        ) {
            self.factory = factory
            self.proxySignatureProvider = proxySignatureProvider
            self._lastPathSignature = initialSignature
            self._lastProxySignature = proxySignatureProvider()
            self._currentSession = factory(0)
            if startMonitor {
                startMonitoringIfNeeded()
            }
        }

        static func makeDefaultSession(_ generation: Int) -> URLSession {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 120
            configuration.timeoutIntervalForResource = 900
            return URLSession(configuration: configuration)
        }

        var currentSession: URLSession {
            refreshProxyIfNeeded()
            lock.lock()
            defer { lock.unlock() }
            return _currentSession
        }

        var generation: Int {
            lock.lock()
            defer { lock.unlock() }
            return _generation
        }

        var retiredSessionCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return _retiredCount
        }

        var pendingRetirementCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return _pendingRetirement.count
        }

        /// Acquires a pinned `URLSession` lease so a concurrent rotation defers `finishTasksAndInvalidate()`
        /// until the caller creates its task inside the session.
        func acquireLease() -> Lease {
            let proxyNow = proxySignatureProvider()
            var retiredNow: URLSession?
            lock.lock()
            if proxyNow != _lastProxySignature {
                _lastProxySignature = proxyNow
                retiredNow = rotateLocked(newPathSignature: _lastPathSignature)
            }
            let gen = _generation
            let sess = _currentSession
            _activeCheckouts[gen, default: 0] += 1
            lock.unlock()

            retiredNow?.finishTasksAndInvalidate()
            return Lease(session: sess, generation: gen)
        }

        func releaseLease(_ lease: Lease) {
            var deferredRetire: URLSession?
            lock.lock()
            let remaining = max(0, (_activeCheckouts[lease.generation] ?? 1) - 1)
            if remaining == 0 {
                _activeCheckouts.removeValue(forKey: lease.generation)
                deferredRetire = _pendingRetirement.removeValue(forKey: lease.generation)
            } else {
                _activeCheckouts[lease.generation] = remaining
            }
            lock.unlock()

            deferredRetire?.finishTasksAndInvalidate()
        }

        /// Checks system proxy state independently of interface callbacks and rotates if changed.
        @discardableResult
        func refreshProxyIfNeeded() -> Bool {
            let proxyNow = proxySignatureProvider()
            var sessionToRetire: URLSession?
            lock.lock()
            guard proxyNow != _lastProxySignature else {
                lock.unlock()
                return false
            }
            _lastProxySignature = proxyNow
            sessionToRetire = rotateLocked(newPathSignature: _lastPathSignature)
            lock.unlock()

            sessionToRetire?.finishTasksAndInvalidate()
            return true
        }

        /// Rotates to a new `URLSession` when the combined network/proxy signature changes.
        @discardableResult
        func rotateIfNeeded(for signature: String) -> Bool {
            let proxyNow = proxySignatureProvider()
            var sessionToRetire: URLSession?
            lock.lock()
            if _lastPathSignature == nil {
                _lastPathSignature = signature
                _lastProxySignature = proxyNow
                lock.unlock()
                return false
            }
            if _lastPathSignature == signature && _lastProxySignature == proxyNow {
                lock.unlock()
                return false
            }
            _lastPathSignature = signature
            _lastProxySignature = proxyNow
            sessionToRetire = rotateLocked(newPathSignature: signature)
            lock.unlock()

            sessionToRetire?.finishTasksAndInvalidate()
            return true
        }

        /// Caller holds `lock`. Returns a session eligible for immediate `finishTasksAndInvalidate()`
        /// or parks it in `_pendingRetirement` until active lease holders complete task setup.
        private func rotateLocked(newPathSignature: String?) -> URLSession? {
            let oldGen = _generation
            let oldSession = _currentSession
            _lastPathSignature = newPathSignature
            _generation &+= 1
            _retiredCount &+= 1
            _currentSession = factory(_generation)
            if (_activeCheckouts[oldGen] ?? 0) > 0 {
                _pendingRetirement[oldGen] = oldSession
                return nil
            }
            return oldSession
        }

        private func startMonitoringIfNeeded() {
            #if canImport(Network)
            lock.lock()
            let alreadyStarted = monitor != nil
            if !alreadyStarted {
                let pathMonitor = NWPathMonitor()
                monitor = pathMonitor
                lock.unlock()
                pathMonitor.pathUpdateHandler = { [weak self] path in
                    guard let self else { return }
                    let signature = Self.buildSignature(
                        status: path.status,
                        interfaces: path.availableInterfaces.map { "\($0.name):\($0.type)" },
                        isExpensive: path.isExpensive,
                        isConstrained: path.isConstrained
                    )
                    self.rotateIfNeeded(for: signature)
                }
                pathMonitor.start(queue: monitorQueue)
                return
            }
            lock.unlock()
            #endif
        }

        #if canImport(Network)
        static func buildSignature(
            status: NWPath.Status,
            interfaces: [String],
            isExpensive: Bool,
            isConstrained: Bool
        ) -> String {
            let statusName: String
            switch status {
            case .satisfied: statusName = "satisfied"
            case .unsatisfied: statusName = "unsatisfied"
            case .requiresConnection: statusName = "requiresConnection"
            @unknown default: statusName = "unknown"
            }
            let sortedInterfaces = interfaces.sorted().joined(separator: ",")
            return "\(statusName)|\(sortedInterfaces)|exp=\(isExpensive)|con=\(isConstrained)"
        }
        #endif

        static func currentProxySignature() -> String {
            #if canImport(CFNetwork)
            guard let raw = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else {
                return "none"
            }
            let keys = [
                "HTTPEnable", "HTTPProxy", "HTTPPort",
                "HTTPSEnable", "HTTPSProxy", "HTTPSPort",
                "SOCKSEnable", "SOCKSProxy", "SOCKSPort",
                "ProxyAutoConfigEnable", "ProxyAutoConfigURLString"
            ]
            return keys.compactMap { key in
                guard let value = raw[key] else { return nil }
                return "\(key)=\(value)"
            }.joined(separator: ";")
            #else
            return "none"
            #endif
        }
    }

    static var session: URLSession { SessionPool.shared.currentSession }

    /// Reads an error body and finds the message in it.
    static func failure(status: Int, bytes: URLSession.AsyncBytes) async -> ProviderError {
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > 8000 { break }
            }
        } catch {}
        return failure(status: status, data: data)
    }

    static func failure(status: Int, data: Data) -> ProviderError {
        let text = String(decoding: data, as: UTF8.self)
        if let json = JSONValue.parse(text) {
            if let message = json["error"]?["message"]?.string ?? json["message"]?.string ?? json["error"]?.string {
                return ProviderError(status: status, message)
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ProviderError(status: status, trimmed.isEmpty ? "没有说明" : String(trimmed.prefix(300)))
    }

    static func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
    }

    static let maxJSONBytes = 32_000_000

    /// Splits a raw byte buffer into lines strictly on ASCII `\r`, `\n`, or `\r\n` (never `U+2028`/`U+2029`).
    static func splitASCIILines(_ data: Data) -> [String] {
        var lines: [String] = []
        var current: [UInt8] = []
        var pendingCR = false
        for byte in data {
            if byte == 0x0D {
                lines.append(String(decoding: current, as: UTF8.self))
                current.removeAll(keepingCapacity: true)
                pendingCR = true
            } else if byte == 0x0A {
                if pendingCR {
                    pendingCR = false
                } else {
                    lines.append(String(decoding: current, as: UTF8.self))
                    current.removeAll(keepingCapacity: true)
                }
            } else {
                pendingCR = false
                current.append(byte)
            }
        }
        if !current.isEmpty {
            lines.append(String(decoding: current, as: UTF8.self))
        }
        return lines
    }

    private static func hasFinish(_ events: [StreamEvent]) -> Bool {
        events.contains { event in
            if case .finish = event { return true }
            return false
        }
    }

    /// Rejects cross-origin and HTTPS-to-HTTP redirects on API calls so auth headers never leak.
    final class RedirectGuardDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        static let shared = RedirectGuardDelegate()

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard let source = task.currentRequest?.url ?? task.originalRequest?.url,
                  let target = request.url,
                  Self.shouldAllowRedirect(from: source, to: target) else {
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }

        static func shouldAllowRedirect(from source: URL, to target: URL) -> Bool {
            guard let sourceScheme = source.scheme?.lowercased(),
                  let targetScheme = target.scheme?.lowercased(),
                  let sourceHost = source.host?.lowercased(),
                  let targetHost = target.host?.lowercased() else {
                return false
            }
            if sourceScheme == "https" && targetScheme != "https" {
                return false
            }
            guard sourceScheme == targetScheme, sourceHost == targetHost else {
                return false
            }
            return effectivePort(for: source, scheme: sourceScheme) == effectivePort(for: target, scheme: targetScheme)
        }

        private static func effectivePort(for url: URL, scheme: String) -> Int? {
            if let port = url.port { return port }
            switch scheme {
            case "https": return 443
            case "http": return 80
            default: return nil
            }
        }
    }

    /// Runs a streaming request and passes each SSE data line to `decode`.
    static func stream(_ request: URLRequest, acceptsJSON: Bool = false, session: URLSession? = nil, decode: @escaping @Sendable (String) throws -> [StreamEvent]) -> AsyncThrowingStream<StreamEvent, Error> {
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let lease = session == nil ? SessionPool.shared.acquireLease() : nil
                    let activeSession = session ?? lease?.session ?? HTTP.session
                    let bytes: URLSession.AsyncBytes
                    let response: URLResponse
                    do {
                        (bytes, response) = try await activeSession.bytes(for: request, delegate: RedirectGuardDelegate.shared)
                    } catch {
                        if let lease { SessionPool.shared.releaseLease(lease) }
                        throw error
                    }
                    if let lease { SessionPool.shared.releaseLease(lease) }
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else { throw await failure(status: status, bytes: bytes) }
                    if acceptsJSON, response.mimeType == "application/json" {
                        if response.expectedContentLength > Int64(maxJSONBytes) {
                            throw ProviderError("模型服务返回的数据太大（超过 \(maxJSONBytes / 1_000_000) MB）。")
                        }
                        var body = Data()
                        for try await byte in bytes {
                            if (body.count & 0xFFF) == 0 { try Task.checkCancellation() }
                            body.append(byte)
                            if body.count > maxJSONBytes {
                                throw ProviderError("模型服务返回的数据太大（超过 \(maxJSONBytes / 1_000_000) MB）。")
                            }
                        }
                        try Task.checkCancellation()
                        let events = try decode(String(decoding: body, as: UTF8.self))
                        for event in events { continuation.yield(event) }
                        if !events.isEmpty && !hasFinish(events) {
                            continuation.yield(.finish(reason: "done"))
                        }
                        continuation.finish()
                        return
                    }
                    var sawSSE = false
                    var plain = ""
                    var lineBuffer: [UInt8] = []
                    var pendingCR = false
                    var byteCounter = 0

                    func handleLine(_ line: String) throws {
                        try Task.checkCancellation()
                        if let payload = SSE.payload(of: line) {
                            sawSSE = true
                            // 「[DONE]」 is the service saying the answer is complete, for those that send no finish reason.
                            if payload == "[DONE]" {
                                continuation.yield(.finish(reason: "done"))
                                return
                            }
                            for event in try decode(payload) { continuation.yield(event) }
                        } else if !sawSSE, plain.utf8.count < 16_000 {
                            if !plain.isEmpty { plain.append("\n") }
                            plain.append(line)
                        }
                    }

                    for try await byte in bytes {
                        byteCounter &+= 1
                        if (byteCounter & 0xFFF) == 0 { try Task.checkCancellation() }
                        if byte == 0x0D {
                            let line = String(decoding: lineBuffer, as: UTF8.self)
                            lineBuffer.removeAll(keepingCapacity: true)
                            pendingCR = true
                            try handleLine(line)
                        } else if byte == 0x0A {
                            if pendingCR {
                                pendingCR = false
                            } else {
                                let line = String(decoding: lineBuffer, as: UTF8.self)
                                lineBuffer.removeAll(keepingCapacity: true)
                                try handleLine(line)
                            }
                        } else {
                            pendingCR = false
                            lineBuffer.append(byte)
                            if lineBuffer.count > maxJSONBytes {
                                throw ProviderError("模型服务单行数据过大（超过 \(maxJSONBytes / 1_000_000) MB）。")
                            }
                        }
                    }
                    if !lineBuffer.isEmpty {
                        let line = String(decoding: lineBuffer, as: UTF8.self)
                        lineBuffer.removeAll()
                        try handleLine(line)
                    }
                    if !sawSSE {
                        let trimmed = plain.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.hasPrefix("{"), let json = JSONValue.parse(trimmed) {
                            let events = try decode(trimmed)
                            if !events.isEmpty {
                                for event in events { continuation.yield(event) }
                                if !hasFinish(events) {
                                    continuation.yield(.finish(reason: "done"))
                                }
                            } else if (json["error"] != nil && json["error"] != .null) || json["message"]?.string != nil || json["msg"]?.string != nil {
                                throw failure(status: 200, data: Data(trimmed.utf8))
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func get(_ request: URLRequest, session: URLSession? = nil) async throws -> JSONValue {
        let lease = session == nil ? SessionPool.shared.acquireLease() : nil
        defer { if let lease { SessionPool.shared.releaseLease(lease) } }
        let activeSession = session ?? lease?.session ?? HTTP.session
        let (data, response) = try await activeSession.data(for: request, delegate: RedirectGuardDelegate.shared)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw failure(status: status, data: data) }
        guard let value = JSONValue.parse(String(decoding: data, as: UTF8.self)) else { throw ProviderError(status: status, "返回的不是 JSON") }
        return value
    }

    static func endpoint(_ base: String, _ path: String) throws -> URL {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed + path), url.scheme?.hasPrefix("http") == true else {
            throw ProviderError("服务地址不对：\(base)")
        }
        return url
    }
}
