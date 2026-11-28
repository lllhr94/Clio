import AgentKit
import Craft
import Foundation
import Network
import SwiftUI
import UIKit

/// 斗室: a small Alpine Linux living in the phone. Wakes on first use; stays up while the app runs.
@MainActor
final class Den: ObservableObject {
    static let shared = Den()

    enum State: Equatable {
        case asleep
        case unpacking
        case waking
        case awake
        case broken(String)
    }

    @Published private(set) var state: State = .asleep
    /// What the terminal page shows: commands and what they printed.
    @Published private(set) var log: [Line] = []
    @Published private(set) var running: Set<Int32> = []
    @Published private(set) var cleaningTemp = false

    struct Line: Identifiable, Equatable, Sendable {
        enum Kind: Sendable { case command, out, error, note }
        let id = UUID()
        let kind: Kind
        let text: String
    }

    private nonisolated let output = LiveOutput()
    private var waiting: [CheckedContinuation<Bool, Never>] = []
    private var cleanWaiters: [CheckedContinuation<Void, Never>] = []
    private var pathMonitor: NWPathMonitor?
    private let pathQueue = DispatchQueue(label: "clio.den.network")
    private var thermalObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    private var observersStarted = false

    private nonisolated static let dnsWriteQueue = DispatchQueue(label: "clio.den.dns-write")
    private nonisolated static let dnsRevisionLock = NSLock()
    private nonisolated(unsafe) static var latestDNSRevision: UInt64 = 0

    static let dnsModeDefaultsKey = "chat.denDNSMode"
    static let customDNSDefaultsKey = "chat.denCustomDNS"

    @Published var showingDNSSettings = false
    @Published private(set) var appliedDNSMode: DenDNSMode = .auto
    @Published private(set) var appliedDNSServers: [String] = []
    @Published private(set) var appliedSearchDomains: [String] = []
    @Published private(set) var lastDNSError: String?

    struct TempCleanupOutcome: Equatable, Sendable {
        let skippedBecauseBusy: Bool
        let removedCount: Int
        let freedBytes: Int64
    }

    nonisolated private static var home: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Den", isDirectory: true)
    }

    nonisolated static var dnsDirectory: URL {
        home.appendingPathComponent("dns", isDirectory: true)
    }

    nonisolated static var resolvConfURL: URL {
        dnsDirectory.appendingPathComponent("resolv.conf", isDirectory: false)
    }

    nonisolated static var managedTempDirectory: URL {
        home.appendingPathComponent("alpine/data/tmp", isDirectory: true)
    }

    nonisolated static func readDNSMode(defaults: UserDefaults = .standard) -> DenDNSMode {
        guard let raw = defaults.string(forKey: dnsModeDefaultsKey),
              let mode = DenDNSMode(rawValue: raw) else {
            return .auto
        }
        return mode
    }

    nonisolated static func readCustomDNSInput(defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: customDNSDefaultsKey) ?? ""
    }

    var dnsMode: DenDNSMode {
        Self.readDNSMode()
    }

    var customDNSInput: String {
        Self.readCustomDNSInput()
    }

    nonisolated private static func nextDNSRevision() -> UInt64 {
        dnsRevisionLock.withLock {
            latestDNSRevision &+= 1
            return latestDNSRevision
        }
    }

    nonisolated private static func isCurrentDNSRevision(_ revision: UInt64) -> Bool {
        dnsRevisionLock.withLock { latestDNSRevision == revision }
    }

    /// Saves DNS preferences into backup-included `chat.*` keys and serializes `/etc/clio-dns/resolv.conf`.
    @discardableResult
    func updateDNSConfiguration(
        mode: DenDNSMode,
        customInput: String,
        defaults: UserDefaults = .standard,
        resolvURL: URL = Den.resolvConfURL
    ) -> (valid: [String], invalid: [String]) {
        let parsed = DenDNSConfig.parseCustomDNSList(customInput)
        objectWillChange.send()
        defaults.set(mode.rawValue, forKey: Self.dnsModeDefaultsKey)
        defaults.set(parsed.valid.joined(separator: ", "), forKey: Self.customDNSDefaultsKey)
        appliedDNSMode = mode
        let validationError: String?
        if mode == .custom && parsed.valid.isEmpty {
            validationError = "请输入至少一个有效的 IPv4 或 IPv6 地址"
        } else if !parsed.invalid.isEmpty {
            validationError = "已忽略无效地址：\(parsed.invalid.joined(separator: "、"))"
        } else {
            validationError = nil
        }
        lastDNSError = validationError

        let revision = Self.nextDNSRevision()
        let capturedCustom = parsed.valid
        Self.dnsWriteQueue.async {
            guard Self.isCurrentDNSRevision(revision) else { return }
            let outcome = Self.writeResolvConfNow(mode: mode, customServers: capturedCustom, resolvURL: resolvURL)
            guard Self.isCurrentDNSRevision(revision) else { return }
            Task { @MainActor in
                guard Self.isCurrentDNSRevision(revision) else { return }
                Den.shared.appliedDNSMode = mode
                Den.shared.appliedDNSServers = outcome.servers
                Den.shared.appliedSearchDomains = outcome.searchDomains
                Den.shared.lastDNSError = outcome.errorMessage ?? validationError
            }
        }
        return parsed
    }

    /// Refreshes host DNS into `/etc/clio-dns/resolv.conf` on a serialized revision-checked queue.
    func refreshDNSFromHostIfAuto() {
        let mode = Self.readDNSMode()
        guard mode == .auto else { return }
        let revision = Self.nextDNSRevision()
        let custom = DenDNSConfig.parseCustomDNSList(Self.readCustomDNSInput()).valid
        Self.dnsWriteQueue.async {
            guard Self.isCurrentDNSRevision(revision) else { return }
            let outcome = Self.writeResolvConfNow(mode: .auto, customServers: custom, resolvURL: Self.resolvConfURL)
            guard Self.isCurrentDNSRevision(revision) else { return }
            Task { @MainActor in
                guard Self.isCurrentDNSRevision(revision) else { return }
                Den.shared.appliedDNSMode = .auto
                Den.shared.appliedDNSServers = outcome.servers
                Den.shared.appliedSearchDomains = outcome.searchDomains
                if let error = outcome.errorMessage {
                    Den.shared.lastDNSError = error
                }
            }
        }
    }

    nonisolated static func writeResolvConfNow(
        mode: DenDNSMode,
        customServers: [String],
        resolvURL: URL = Den.resolvConfURL,
        systemServersOverride: [String]? = nil,
        searchDomainsOverride: [String]? = nil
    ) -> (servers: [String], searchDomains: [String], wrote: Bool, errorMessage: String?) {
        let sysServers = systemServersOverride ?? DenKernel.systemDNSServers()
        let sysDomains = searchDomainsOverride ?? DenKernel.systemSearchDomains()
        let existing = try? String(contentsOf: resolvURL, encoding: .utf8)
        let decision = DenDNSConfig.renderResolvConf(
            mode: mode,
            systemServers: sysServers,
            customServers: customServers,
            searchDomains: sysDomains,
            existingContent: existing
        )
        let cleanCustom = DenDNSConfig.normalizeNameservers(customServers)
        let cleanSys = DenDNSConfig.normalizeNameservers(sysServers)
        let effectiveServers = mode == .custom ? (cleanCustom.isEmpty ? cleanSys : cleanCustom) : cleanSys
        let effectiveDomains = DenDNSConfig.sanitizeSearchDomains(sysDomains)

        switch decision {
        case .preserveExisting:
            return (effectiveServers, effectiveDomains, false, nil)
        case .write(let body):
            do {
                try DenDNSConfig.atomicWriteResolvConf(content: body, to: resolvURL)
                return (effectiveServers, effectiveDomains, true, nil)
            } catch {
                return (effectiveServers, effectiveDomains, false, error.localizedDescription)
            }
        }
    }

    func applyThermalForkLimit(_ thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState) {
        let limit = DenThermalForkLimit.limit(for: thermalState)
        DenKernel.setForkRateLimit(limit.perSecond, burst: limit.burst)
    }

    private func startRuntimeObserversIfNeeded() {
        guard !observersStarted else { return }
        observersStarted = true
        CPUGuard.shared.start()

        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applyThermalForkLimit()
            }
        }

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshDNSFromHostIfAuto()
            }
        }

        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] _ in
            // Always re-query res_ninit on path events even when interface/flags look identical (e.g. DHCP/VPN DNS swap).
            Task { @MainActor [weak self] in
                self?.refreshDNSFromHostIfAuto()
            }
        }
        monitor.start(queue: pathQueue)
    }

    /// Measures host-visible temporary files owned by Den (`/tmp` mirror and `densock*` sockets).
    nonisolated static func managedTempBytes(
        home: URL = Den.home,
        tempDirectory: URL = FileManager.default.temporaryDirectory
    ) -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        let alpineTmp = home.appendingPathComponent("alpine/data/tmp", isDirectory: true)
        if let enumerator = fm.enumerator(at: alpineTmp, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsPackageDescendants]) {
            for case let fileURL as URL in enumerator {
                let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                if values?.isRegularFile == true, let size = values?.fileSize {
                    total += Int64(size)
                }
            }
        }
        if let entries = try? fm.contentsOfDirectory(at: tempDirectory, includingPropertiesForKeys: [.fileSizeKey], options: []) {
            for entry in entries where entry.lastPathComponent.hasPrefix("densock") {
                let values = try? entry.resourceValues(forKeys: [.fileSizeKey])
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }

    /// Cleans Den temporary files ONLY when `running.isEmpty` and no other cleanup is active.
    /// Acquires `cleaningTemp` across the entire `await` window so `Den.run` cannot spawn commands concurrently.
    func cleanManagedTempFiles() async -> TempCleanupOutcome {
        guard running.isEmpty, !cleaningTemp else {
            return TempCleanupOutcome(skippedBecauseBusy: true, removedCount: 0, freedBytes: 0)
        }
        cleaningTemp = true
        defer {
            cleaningTemp = false
            let waiters = cleanWaiters
            cleanWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }

        if DenKernel.booted() {
            return await Self.cleanHostTempFiles(
                runningPIDs: running,
                home: Self.home,
                tempDirectory: FileManager.default.temporaryDirectory,
                cleanInKernel: {
                    _ = await self.runExecutingCommand("rm -rf /tmp/* /tmp/.[!.]* /tmp/..?* 2>/dev/null; true", timeout: 20, keep: 4_000, shown: false, onOutput: nil)
                }
            )
        }
        return await Self.cleanHostTempFiles(
            runningPIDs: running,
            home: Self.home,
            tempDirectory: FileManager.default.temporaryDirectory,
            cleanInKernel: nil
        )
    }

    nonisolated static func cleanHostTempFiles(
        runningPIDs: Set<Int32>,
        home: URL = Den.home,
        tempDirectory: URL = FileManager.default.temporaryDirectory,
        cleanInKernel: (@Sendable () async -> Void)? = nil
    ) async -> TempCleanupOutcome {
        guard runningPIDs.isEmpty else {
            return TempCleanupOutcome(skippedBecauseBusy: true, removedCount: 0, freedBytes: 0)
        }
        let beforeBytes = managedTempBytes(home: home, tempDirectory: tempDirectory)
        var removedCount = 0

        if let cleanInKernel {
            await cleanInKernel()
        } else {
            let fm = FileManager.default
            let alpineTmp = home.appendingPathComponent("alpine/data/tmp", isDirectory: true)
            if let children = try? fm.contentsOfDirectory(at: alpineTmp, includingPropertiesForKeys: nil, options: []) {
                for child in children {
                    do {
                        try fm.removeItem(at: child)
                        removedCount += 1
                    } catch {
                        // Ignore locked entries
                    }
                }
            }
        }

        let fm = FileManager.default
        if let entries = try? fm.contentsOfDirectory(at: tempDirectory, includingPropertiesForKeys: nil, options: []) {
            for entry in entries where entry.lastPathComponent.hasPrefix("densock") {
                do {
                    try fm.removeItem(at: entry)
                    removedCount += 1
                } catch {
                    // Ignore in-use sockets
                }
            }
        }

        let afterBytes = managedTempBytes(home: home, tempDirectory: tempDirectory)
        let freed = max(0, beforeBytes - afterBytes)
        if cleanInKernel != nil && freed > 0 && removedCount == 0 {
            removedCount = 1
        }
        return TempCleanupOutcome(skippedBecauseBusy: false, removedCount: removedCount, freedBytes: freed)
    }

    /// Unpacks the root the first time, then boots. Returns false when Linux cannot start.
    func wake() async -> Bool {
        switch state {
        case .awake: return true
        case .unpacking, .waking:
            return await withCheckedContinuation { waiting.append($0) }
        case .asleep, .broken:
            break
        }
        state = .unpacking
        let root = Self.home.appendingPathComponent("alpine", isDirectory: true)
        let desk = Workspace.root.path
        let outcome: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
            do {
                if !FileManager.default.fileExists(atPath: root.appendingPathComponent("meta.db").path) {
                    guard let bundled = Bundle.main.url(forResource: "alpine", withExtension: nil) else {
                        throw ProviderError(Words.t("这个安装包里没有带斗室的 Linux。"))
                    }
                    try? FileManager.default.removeItem(at: root)
                    try FileManager.default.createDirectory(at: Self.home, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: bundled, to: root)
                }
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value
        if case .failure(let error) = outcome {
            finish(.broken("解不开 Linux：\(error.localizedDescription)"))
            return false
        }
        state = .waking
        let dnsMode = Self.readDNSMode()
        let customServers = DenDNSConfig.parseCustomDNSList(Self.readCustomDNSInput()).valid
        let dnsDir = Self.dnsDirectory
        let netDir = NetworkRuntime.denNetDirectory
        let resolvURL = Self.resolvConfURL
        let bootRevision = Self.nextDNSRevision()
        applyThermalForkLimit()

        let bootOutcome: (code: Int32, dnsResult: (servers: [String], searchDomains: [String], wrote: Bool, errorMessage: String?), fallbackError: String?) = await withCheckedContinuation { continuation in
            Self.dnsWriteQueue.async {
                let dnsResult: (servers: [String], searchDomains: [String], wrote: Bool, errorMessage: String?)
                if Self.isCurrentDNSRevision(bootRevision) {
                    dnsResult = Self.writeResolvConfNow(
                        mode: dnsMode,
                        customServers: customServers,
                        resolvURL: resolvURL
                    )
                } else {
                    dnsResult = ([], [], false, nil)
                }
                Thread.detachNewThread {
                    let code = DenKernel.bootRoot(root.path, desk: desk, dnsDir: dnsDir.path, netDir: netDir.path)
                    let fallbackErr = DenKernel.lastDNSFallbackError()
                    continuation.resume(returning: (code, dnsResult, fallbackErr))
                }
            }
        }
        if Self.isCurrentDNSRevision(bootRevision) {
            appliedDNSMode = dnsMode
            appliedDNSServers = bootOutcome.dnsResult.servers
            appliedSearchDomains = bootOutcome.dnsResult.searchDomains
            if let error = bootOutcome.fallbackError ?? bootOutcome.dnsResult.errorMessage {
                lastDNSError = error
            }
        } else if let error = bootOutcome.fallbackError {
            lastDNSError = error
        }
        let code = bootOutcome.code
        if code < 0 {
            finish(.broken("Linux 没能启动（错误 \(code)）"))
            Diag.note("斗室没能启动：\(code)")
            return false
        }
        startRuntimeObserversIfNeeded()
        applyThermalForkLimit()
        finish(.awake)
        return true
    }

    private func finish(_ state: State) {
        self.state = state
        let ok = state == .awake
        for continuation in waiting { continuation.resume(returning: ok) }
        waiting = []
    }

    struct Outcome {
        var code: Int32
        var output: String
        var errorOutput: String
        var timedOut: Bool
    }

    /// Runs a shell command. Stops waiting after `timeout` seconds and kills it.
    /// Runs one command. `onOutput` hears each line as it is printed.
    func run(_ command: String, timeout: Double = 120, keep: Int = 400_000, shown: Bool = true, onOutput: (@Sendable (String) -> Void)? = nil) async -> Outcome {
        while cleaningTemp {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                cleanWaiters.append(continuation)
            }
            if Task.isCancelled {
                return Outcome(code: -1, output: "", errorOutput: "命令已取消。", timedOut: false)
            }
        }
        return await runExecutingCommand(command, timeout: timeout, keep: keep, shown: shown, onOutput: onOutput)
    }

    private func runExecutingCommand(_ command: String, timeout: Double, keep: Int, shown: Bool, onOutput: (@Sendable (String) -> Void)?) async -> Outcome {
        guard await wake() else {
            if case .broken(let why) = state { return Outcome(code: -1, output: "", errorOutput: why, timedOut: false) }
            return Outcome(code: -1, output: "", errorOutput: Words.t("斗室没醒。"), timedOut: false)
        }
        let stopped = Outcome(code: -1, output: "", errorOutput: "命令已取消。", timedOut: false)
        guard !Task.isCancelled else { return stopped }
        let duration = timeout.isFinite ? max(1, min(timeout, 86_400)) : 120
        let maxKeep = UInt(max(1, keep))
        if shown { note(.command, command) }
        let control = CommandControl()
        let printed = PrintedLines()
        let receive: @Sendable (String, Bool) -> Void = { [weak self] rawLine, isError in
            let line = NetworkRuntime.shared.redactSecrets(in: rawLine)
            printed.add(line)
            onOutput?(line)
            if shown { self?.buffer(Line(kind: isError ? .error : .out, text: line)) }
        }
        let shellEnv = NetworkRuntime.shared.shellEnvironment()
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let once = Once(continuation)
                let pid = DenKernel.run("cd /root 2>/dev/null; " + command, environment: shellEnv.isEmpty ? nil : shellEnv, maxOutput: maxKeep, onLine: receive, done: { code, output, errorOutput in
                    let cleanOut = NetworkRuntime.shared.redactSecrets(in: output)
                    var cleanErr = NetworkRuntime.shared.redactSecrets(in: errorOutput)
                    if code != 0, let hint = NetworkErrorDiagnostics.hint(for: cleanOut + "\n" + cleanErr) {
                        if !cleanErr.isEmpty && !cleanErr.hasSuffix("\n") { cleanErr += "\n" }
                        cleanErr += hint + "\n"
                    }
                    once.finish(Outcome(code: code, output: cleanOut, errorOutput: cleanErr, timedOut: false))
                })
                guard pid >= 0 else {
                    once.finish(Outcome(code: pid, output: "", errorOutput: "命令没能启动（错误 \(pid)）", timedOut: false))
                    return
                }
                running.insert(pid)
                control.pid = pid
                control.once = once
                control.timer = Task { @MainActor in
                    do { try await Task.sleep(for: .seconds(duration)) } catch { return }
                    control.stop(Outcome(code: -1, output: printed.value, errorOutput: "", timedOut: true))
                }
            }
        } onCancel: {
            Task { @MainActor in
                control.stop(Outcome(code: -1, output: printed.value, errorOutput: stopped.errorOutput, timedOut: false))
            }
        }
        control.timer?.cancel()
        control.timer = nil
        control.once = nil
        if let pid = control.pid { running.remove(pid) }
        if shown {
            if result.timedOut {
                note(.note, "超过 \(Int(duration)) 秒，停掉了")
            } else if result.code != 0 {
                note(.note, "退出码 \(result.code)")
            } else {
                append(output.drain())
            }
        }
        return result
    }

    func stopAll() {
        for pid in running { DenKernel.kill(pid) }
    }

    func clear() {
        _ = output.drain()
        if !log.isEmpty { log = [] }
    }

    private func note(_ kind: Line.Kind, _ text: String) {
        append(output.drain() + [Line(kind: kind, text: text)])
    }

    private nonisolated func buffer(_ line: Line) {
        guard output.add(line) else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self else { return }
            self.append(self.output.drain(finishingBatch: true))
        }
    }

    private func append(_ lines: [Line]) {
        guard !lines.isEmpty else { return }
        log = Array((log + lines).suffix(2000))
    }

    private final class LiveOutput: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [Line] = []
        private var scheduled = false

        func add(_ line: Line) -> Bool {
            lock.withLock {
                if lines.count >= 4000 { lines.removeFirst(2000) }
                lines.append(line)
                guard !scheduled else { return false }
                scheduled = true
                return true
            }
        }

        func drain(finishingBatch: Bool = false) -> [Line] {
            lock.withLock {
                defer { lines = []; if finishingBatch { scheduled = false } }
                return lines
            }
        }
    }

    @MainActor
    private final class CommandControl {
        var pid: Int32?
        var once: Once?
        var timer: Task<Void, Never>?

        func stop(_ outcome: Outcome) {
            guard let pid, once?.finish(outcome) == true else { return }
            DenKernel.kill(pid)
        }
    }

    private final class Once: @unchecked Sendable {
        private var continuation: CheckedContinuation<Outcome, Never>?
        private let lock = NSLock()
        init(_ continuation: CheckedContinuation<Outcome, Never>) { self.continuation = continuation }
        @discardableResult
        func finish(_ outcome: Outcome) -> Bool {
            lock.lock()
            let waiting = continuation
            continuation = nil
            lock.unlock()
            waiting?.resume(returning: outcome)
            return waiting != nil
        }
    }
}


/// Lines a running command printed, kept for the timer that may stop it (first 2000 + last 2000 lines).
private final class PrintedLines: @unchecked Sendable {
    private static let cap = 2000
    private let lock = NSLock()
    private var head: [String] = []
    private var tail: [String] = []
    private var tailStart = 0
    private var omitted = 0

    func add(_ line: String) {
        lock.withLock {
            if head.count < Self.cap {
                head.append(line)
            } else if tail.count < Self.cap {
                tail.append(line)
            } else {
                tail[tailStart] = line
                tailStart = (tailStart + 1) % Self.cap
                omitted += 1
            }
        }
    }

    var value: String {
        lock.withLock {
            let orderedTail = tailStart == 0 ? tail : Array(tail[tailStart...] + tail[..<tailStart])
            if omitted > 0 {
                return (head + ["…（中间省略 \(omitted) 行）…"] + orderedTail).joined(separator: "\n")
            }
            return (head + orderedTail).joined(separator: "\n")
        }
    }
}
