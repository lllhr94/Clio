import AgentKit
import CFNetwork
import Craft
import Foundation
import Network
import WebKit

/// Single source of truth for Clio's per-device network routing, local proxy hub,
/// per-scope `URLSession` pooling, `WKWebView` proxy wiring, and Den shell proxy sync.
final class NetworkRuntime: ObservableObject, @unchecked Sendable {
    static let shared = NetworkRuntime()

    /// Device-local key (intentionally NOT prefixed with `chat.` so local proxies never leak into cross-device backups).
    static let settingsKey = "device.networkRouting.v1"

    @Published private(set) var settings: NetworkRoutingSettings
    @Published private(set) var activeEndpoints: ClioNetHub.EntryEndpoints?
    @Published private(set) var alertMessage: String?
    @Published private(set) var recentLogs: [String] = []
    @Published private(set) var isApplying = false

    private let hub: ClioNetHub
    private let snapshot = SnapshotBox()
    private let sessionCache = SessionCacheBox()
    private var generation: UInt64 = 0
    private var started = false
    private weak var registeredBrowserStore: WKWebsiteDataStore?

    private final class SessionCacheBox: @unchecked Sendable {
        private let lock = NSLock()
        private var sessions: [String: URLSession] = [:]
        private var generation: UInt64 = 0

        func resolve(
            key: String,
            generation currentGen: UInt64,
            ephemeral: Bool,
            proxies: [ProxyConfiguration]
        ) -> URLSession {
            var toInvalidate: [URLSession] = []
            let resolved: URLSession = lock.withLock {
                if generation != currentGen {
                    toInvalidate = Array(sessions.values)
                    sessions.removeAll(keepingCapacity: true)
                    generation = currentGen
                }
                if let existing = sessions[key] {
                    return existing
                }
                let config: URLSessionConfiguration = ephemeral ? .ephemeral : .default
                config.timeoutIntervalForRequest = 60
                config.timeoutIntervalForResource = 300
                if !proxies.isEmpty {
                    config.proxyConfigurations = proxies
                }
                let created = URLSession(configuration: config)
                sessions[key] = created
                return created
            }
            for old in toInvalidate {
                old.finishTasksAndInvalidate()
            }
            return resolved
        }

        func retireAll(newGeneration: UInt64) {
            let old: [URLSession] = lock.withLock {
                let list = Array(sessions.values)
                sessions.removeAll(keepingCapacity: true)
                generation = newGeneration
                return list
            }
            for session in old {
                session.finishTasksAndInvalidate()
            }
        }
    }

    private final class SnapshotBox: @unchecked Sendable {
        struct State: Sendable {
            var settings: NetworkRoutingSettings = .default
            var endpoints: ClioNetHub.EntryEndpoints?
            var generation: UInt64 = 0
            var proxyPasswords: [String: String] = [:]
        }

        private let lock = NSLock()
        private var state = State()

        func read() -> State {
            lock.withLock { state }
        }

        func write(_ update: (inout State) -> Void) {
            lock.withLock { update(&state) }
        }
    }

    private init() {
        let loaded = Self.loadSettings()
        self.settings = loaded
        let box = self.snapshot
        self.hub = ClioNetHub(
            passwordProvider: { proxyID in
                let key = proxyID.uppercased()
                if let cached = box.read().proxyPasswords[key] { return cached }
                return Vault.load(String.self, key: "net.proxy.\(key)")
            },
            onAlertChange: { message in
                Task { @MainActor in
                    NetworkRuntime.shared.alertMessage = message
                }
            },
            onLog: { line in
                Task { @MainActor in
                    NetworkRuntime.shared.appendLog(line)
                }
            }
        )
        refreshPasswordSnapshot(for: loaded)
        syncDenNetworkFiles(settings: loaded, endpoints: nil)
    }

    /// Installs `AgentNetworkRouter` hooks once at app launch and starts the local proxy entry if configured.
    @MainActor
    func start() {
        guard !started else { return }
        started = true

        let runtime = self
        AgentNetworkRouter.install(
            configure: { config, scopeTag in
                let scope = NetworkScope(tag: scopeTag) ?? .default
                runtime.configure(config, for: scope)
            },
            signature: {
                runtime.routingSignature()
            }
        )

        Task {
            await applyCurrentSettings()
        }
    }

    // MARK: Persistence & Mutations

    private static func loadSettings() -> NetworkRoutingSettings {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let decoded = try? JSONDecoder().decode(NetworkRoutingSettings.self, from: data) else {
            return .default
        }
        return decoded
    }

    private func persist(_ newSettings: NetworkRoutingSettings) {
        if let data = try? JSONEncoder().encode(newSettings) {
            UserDefaults.standard.set(data, forKey: Self.settingsKey)
        }
    }

    private func refreshPasswordSnapshot(for s: NetworkRoutingSettings) {
        var map: [String: String] = [:]
        for proxy in s.proxies {
            if let pw = Vault.load(String.self, key: proxy.vaultKey), !pw.isEmpty {
                map[proxy.id.uppercased()] = pw
            }
        }
        snapshot.write { state in
            state.settings = s
            state.proxyPasswords = map
        }
    }

    @MainActor
    func update(_ transform: (inout NetworkRoutingSettings) -> Void) {
        var copy = settings
        transform(&copy)
        settings = copy
        persist(copy)
        refreshPasswordSnapshot(for: copy)
        Task {
            await applyCurrentSettings()
        }
    }

    @MainActor
    func saveProxy(_ profile: ProxyProfile, password: String?) {
        var copy = settings
        if let idx = copy.proxies.firstIndex(where: { $0.id.uppercased() == profile.id.uppercased() }) {
            copy.proxies[idx] = profile
        } else {
            copy.proxies.append(profile)
        }
        if let password {
            if password.isEmpty {
                Vault.remove(profile.vaultKey)
            } else {
                Vault.save(password, as: profile.vaultKey)
            }
        }
        settings = copy
        persist(copy)
        refreshPasswordSnapshot(for: copy)
        Task {
            await applyCurrentSettings()
        }
    }

    @MainActor
    func deleteProxy(id: String) {
        if let existing = settings.proxy(id: id) {
            Vault.remove(existing.vaultKey)
        }
        let updated = settings.removingProxy(id: id)
        settings = updated
        persist(updated)
        refreshPasswordSnapshot(for: updated)
        Task {
            await applyCurrentSettings()
        }
    }

    func hasStoredPassword(for proxyID: String) -> Bool {
        let key = "net.proxy.\(proxyID.uppercased())"
        return !(Vault.load(String.self, key: key) ?? "").isEmpty
    }

    @MainActor
    func applyCurrentSettings() async {
        isApplying = true
        defer { isApplying = false }
        let current = settings
        let endpoints = await hub.apply(settings: current)
        activeEndpoints = endpoints
        generation &+= 1
        let gen = generation
        snapshot.write { state in
            state.settings = current
            state.endpoints = endpoints
            state.generation = gen
        }
        retireCachedSessions()
        syncDenNetworkFiles(settings: current, endpoints: endpoints)
        if let store = registeredBrowserStore {
            applyToBrowser(store)
        }
        AgentNetworkRouter.notifyChanged()
    }

    // MARK: Nonisolated Client Configuration

    nonisolated func routingSignature() -> String {
        let st = snapshot.read()
        let portTag = st.endpoints.map { "\($0.socksPort):\($0.httpPort)" } ?? "off"
        return "g\(st.generation)|on=\(st.settings.routingEnabled)|p=\(portTag)"
    }

    nonisolated func proxyConfigurations(for scope: NetworkScope) -> [ProxyConfiguration] {
        let st = snapshot.read()
        guard st.settings.routingEnabled,
              case .proxy = st.settings.effectiveRoute(for: scope),
              let endpoints = st.endpoints,
              let httpPort = NWEndpoint.Port(rawValue: endpoints.httpPort) else {
            return []
        }
        let proxy = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: .ipv4(.loopback), port: httpPort))
        proxy.applyCredential(username: scope.tag, password: endpoints.password)
        return [proxy]
    }

    /// Applies scope routing to a `URLSessionConfiguration`. Leaves it completely untouched when direct.
    nonisolated func configure(_ config: URLSessionConfiguration, for scope: NetworkScope) {
        let proxies = proxyConfigurations(for: scope)
        if !proxies.isEmpty {
            config.proxyConfigurations = proxies
        }
    }

    /// Returns a pooled `URLSession` for the given scope. Returns `URLSession.shared` untouched when direct and non-ephemeral.
    nonisolated func session(for scope: NetworkScope, ephemeral: Bool = false) -> URLSession {
        let st = snapshot.read()
        let proxies = proxyConfigurations(for: scope)
        if proxies.isEmpty && !ephemeral {
            return URLSession.shared
        }
        let cacheKey = "\(scope.tag)|ephemeral=\(ephemeral)"
        return sessionCache.resolve(
            key: cacheKey,
            generation: st.generation,
            ephemeral: ephemeral,
            proxies: proxies
        )
    }

    private func retireCachedSessions() {
        sessionCache.retireAll(newGeneration: generation)
    }

    // MARK: Browser Integration

    @MainActor
    func registerBrowserStore(_ store: WKWebsiteDataStore) {
        registeredBrowserStore = store
        applyToBrowser(store)
    }

    @MainActor
    func applyToBrowser(_ store: WKWebsiteDataStore) {
        store.proxyConfigurations = proxyConfigurations(for: .browser)
    }

    // MARK: Den Shell & OpenSSH Integration

    static var denNetDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Den/net", isDirectory: true)
    }

    func shellEnvironment() -> [String: String] {
        let st = snapshot.read()
        return NetworkShellConfig.environment(
            settings: st.settings,
            socksPort: st.endpoints?.socksPort,
            httpPort: st.endpoints?.httpPort,
            entryPassword: st.endpoints?.password ?? ""
        )
    }

    func redactSecrets(in text: String) -> String {
        let st = snapshot.read()
        var secrets: [String] = []
        if let pw = st.endpoints?.password, !pw.isEmpty {
            secrets.append(pw)
        }
        secrets.append(contentsOf: st.proxyPasswords.values)
        return NetworkRedaction.redact(text, secrets: secrets)
    }

    func syncDenNetworkFiles(settings: NetworkRoutingSettings, endpoints: ClioNetHub.EntryEndpoints?) {
        let dir = Self.denNetDirectory
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let sshConfigURL = dir.appendingPathComponent("ssh_config", isDirectory: false)
            let helperURL = dir.appendingPathComponent("ssh-proxy", isDirectory: false)

            let sshConfigBody = NetworkShellConfig.renderSSHConfig(
                settings: settings,
                proxyActive: endpoints != nil
            )
            try sshConfigBody.write(to: sshConfigURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: sshConfigURL.path)

            try NetworkShellConfig.sshProxyHelperScript.write(to: helperURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)
        } catch {
            // Non-fatal: Den boots cleanly even if helper directory write is unavailable in tests.
        }
    }

    // MARK: Diagnostics & Logging

    @MainActor
    private func appendLog(_ line: String) {
        let stamp = Self.timeFormatter.string(from: Date())
        recentLogs.append("[\(stamp)] \(line)")
        if recentLogs.count > 120 {
            recentLogs.removeFirst(recentLogs.count - 120)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func systemProxySummary() -> String {
        guard let cf = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else {
            return "无系统代理"
        }
        var parts: [String] = []
        if (cf["HTTPEnable"] as? Int) == 1, let h = cf["HTTPProxy"] as? String {
            let p = (cf["HTTPPort"] as? Int).map { ":\($0)" } ?? ""
            parts.append("HTTP \(h)\(p)")
        }
        if (cf["HTTPSEnable"] as? Int) == 1, let h = cf["HTTPSProxy"] as? String {
            let p = (cf["HTTPSPort"] as? Int).map { ":\($0)" } ?? ""
            parts.append("HTTPS \(h)\(p)")
        }
        if (cf["SOCKSEnable"] as? Int) == 1, let h = cf["SOCKSProxy"] as? String {
            let p = (cf["SOCKSPort"] as? Int).map { ":\($0)" } ?? ""
            parts.append("SOCKS \(h)\(p)")
        }
        if (cf["ProxyAutoConfigEnable"] as? Int) == 1, let pac = cf["ProxyAutoConfigURLString"] as? String {
            parts.append("PAC \(pac)")
        }
        return parts.isEmpty ? "直连（无系统代理配置）" : parts.joined(separator: " · ")
    }

    @MainActor
    func runDiagnostics() async -> [ClioNetHub.DiagnosticItem] {
        let current = settings
        let sysProxy = Self.systemProxySummary()
        let dnsServers = Den.shared.appliedDNSServers
        let kernelStatus = DenKernel.kernelNetworkStatus()
        return await hub.runDiagnostics(
            settings: current,
            systemProxySummary: sysProxy,
            denDNSServers: dnsServers,
            kernelNetStatus: kernelStatus
        )
    }

    @MainActor
    func formattedDiagnosticReport(items: [ClioNetHub.DiagnosticItem]) -> String {
        var lines: [String] = ["# Clio 网络诊断报告", ""]
        for item in items {
            let badge: String
            switch item.status {
            case .ok: badge = "OK"
            case .warn: badge = "WARN"
            case .fail: badge = "FAIL"
            case .skip: badge = "SKIP"
            }
            let ms = item.elapsedMs > 0 ? " (\(item.elapsedMs)ms)" : ""
            lines.append("[\(badge)] \(item.name)\(ms): \(item.detail)")
        }
        if !recentLogs.isEmpty {
            lines.append("")
            lines.append("## 最近网络日志")
            lines.append(contentsOf: recentLogs.suffix(30))
        }
        return redactSecrets(in: lines.joined(separator: "\n"))
    }
}
