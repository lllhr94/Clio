import AgentKit
import Craft
import Foundation
import SwiftUI

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

    struct Line: Identifiable, Equatable, Sendable {
        enum Kind: Sendable { case command, out, error, note }
        let id = UUID()
        let kind: Kind
        let text: String
    }

    private nonisolated let output = LiveOutput()
    private var waiting: [CheckedContinuation<Bool, Never>] = []

    nonisolated private static var home: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Den", isDirectory: true)
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
        let code: Int32 = await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                let code = DenKernel.bootRoot(root.path, desk: desk)
                continuation.resume(returning: code)
            }
        }
        if code < 0 {
            finish(.broken("Linux 没能启动（错误 \(code)）"))
            Diag.note("斗室没能启动：\(code)")
            return false
        }
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
    func run(_ command: String, timeout: Double = 120, shown: Bool = true, onOutput: (@Sendable (String) -> Void)? = nil) async -> Outcome {
        guard await wake() else {
            if case .broken(let why) = state { return Outcome(code: -1, output: "", errorOutput: why, timedOut: false) }
            return Outcome(code: -1, output: "", errorOutput: Words.t("斗室没醒。"), timedOut: false)
        }
        let stopped = Outcome(code: -1, output: "", errorOutput: "命令已取消。", timedOut: false)
        guard !Task.isCancelled else { return stopped }
        let duration = timeout.isFinite ? max(1, min(timeout, 86_400)) : 120
        if shown { note(.command, command) }
        let control = CommandControl()
        let printed = PrintedLines()
        let receive: @Sendable (String, Bool) -> Void = { [weak self] line, isError in
            printed.add(line)
            onOutput?(line)
            if shown { self?.buffer(Line(kind: isError ? .error : .out, text: line)) }
        }
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let once = Once(continuation)
                let pid = DenKernel.run("cd /root 2>/dev/null; " + command, environment: nil, onLine: receive, done: { code, output, errorOutput in
                    once.finish(Outcome(code: code, output: output, errorOutput: errorOutput, timedOut: false))
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


/// Lines a running command printed, kept for the timer that may stop it.
private final class PrintedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.withLock { if lines.count < 4000 { lines.append(line) } } }
    var value: String { lock.withLock { lines.joined(separator: "\n") } }
}
