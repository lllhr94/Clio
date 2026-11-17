import AgentKit
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

    struct Line: Identifiable, Equatable {
        enum Kind { case command, out, error, note }
        let id = UUID()
        let kind: Kind
        let text: String
    }

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
                        throw ProviderError("这个安装包里没有带斗室的 Linux。")
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
    func run(_ command: String, timeout: Double = 120, shown: Bool = true) async -> Outcome {
        guard await wake() else {
            if case .broken(let why) = state { return Outcome(code: -1, output: "", errorOutput: why, timedOut: false) }
            return Outcome(code: -1, output: "", errorOutput: "斗室没醒。", timedOut: false)
        }
        if shown { note(.command, command) }
        var pid: Int32 = -1
        let result: Outcome = await withCheckedContinuation { continuation in
            let once = Once(continuation)
            pid = DenKernel.run("cd /root 2>/dev/null; " + command, environment: nil, onLine: { [weak self] line, isError in
                guard shown else { return }
                MainActor.assumeIsolated { self?.note(isError ? .error : .out, line) }
            }, done: { code, output, errorOutput in
                once.finish(Outcome(code: code, output: output, errorOutput: errorOutput, timedOut: false))
            })
            if pid < 0 {
                once.finish(Outcome(code: pid, output: "", errorOutput: "命令没能启动（错误 \(pid)）", timedOut: false))
                return
            }
            running.insert(pid)
            let started = pid
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(1, timeout) * 1_000_000_000))
                if once.finish(Outcome(code: -1, output: "", errorOutput: "", timedOut: true)) {
                    DenKernel.kill(started)
                }
            }
        }
        running.remove(pid)
        if shown {
            if result.timedOut { note(.note, "超过 \(Int(timeout)) 秒，停掉了") } else if result.code != 0 { note(.note, "退出码 \(result.code)") }
        }
        return result
    }

    func stopAll() {
        for pid in running { DenKernel.kill(pid) }
    }

    func clear() { log = [] }

    private func note(_ kind: Line.Kind, _ text: String) {
        log.append(Line(kind: kind, text: text))
        if log.count > 2000 { log.removeFirst(log.count - 2000) }
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

    // MARK: Tools

    static func tools() -> [AgentTool] {
        [
            DeskTool(name: "shell", description: """
            在斗室里跑 shell 命令。斗室是手机里的一个 Alpine Linux（aarch64，模拟运行，比电脑慢很多）。
            - 书案就在 /root/desk，desk_* 工具写的文件这里都能看到。
            - 缺什么就 apk add（比如 python3、git、curl、nodejs）。装过的东西会一直留着。
            - 一次跑一条或几条命令，命令要能自己结束，不要开交互程序（vim、top、python 交互模式）。长任务可以加 timeout（秒，最多 600）。
            - 输出太长会被截断，必要时用 head、tail、grep 缩小范围。
            """, parameters: ["type": "object", "properties": ["command": ["type": "string"], "timeout": ["type": "number", "description": "最多等几秒，默认 120"]], "required": ["command"]], label: { "斗室：\(($0["command"]?.string ?? "").prefix(40))" }) { arguments in
                let command = arguments["command"]?.string ?? ""
                guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return ToolOutput("命令是空的。", isError: true) }
                let timeout = min(600, max(5, arguments["timeout"]?.number ?? 120))
                let result = await Den.shared.run(command, timeout: timeout)
                var text = result.output
                if !result.errorOutput.isEmpty { text += (text.isEmpty ? "" : "\n") + result.errorOutput }
                if text.count > 12000 { text = String(text.prefix(4000)) + "\n……（中间省略 \(text.count - 8000) 字）……\n" + String(text.suffix(4000)) }
                if result.timedOut { return ToolOutput((text.isEmpty ? "" : text + "\n") + "（超过 \(Int(timeout)) 秒没跑完，已经停掉。）", isError: true) }
                let tail = result.code == 0 ? "" : "\n（退出码 \(result.code)）"
                return ToolOutput((text.isEmpty ? "（没有输出）" : text) + tail, isError: result.code != 0)
            },
        ]
    }
}
