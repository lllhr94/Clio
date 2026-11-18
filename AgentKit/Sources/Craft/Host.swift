import AgentKit
import Foundation

/// One place to work — 书案, 斗室, a 远山 computer — with the same verbs: run a command, read a file, write a file.
/// The file tools are written once against this, so every place gets the same behavior.
public protocol WorkHost: Sendable {
    var title: String { get }
    /// The tool-name prefix: desk, den or hill.
    var prefix: String { get }
    /// Where relative paths start.
    var home: String { get }
    var canRun: Bool { get }
    func run(_ command: String, timeout: Double) async throws -> (code: Int, output: String)
    func read(_ path: String) async throws -> Data
    func write(_ path: String, _ data: Data) async throws
}

public enum Shell {
    /// Words safe to put inside a shell command as one argument.
    public static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Long output keeps its head and its tail; the middle is left out and counted.
    public static func clip(_ text: String, max: Int = 20_000) -> String {
        guard text.count > max else { return text }
        let half = max / 2
        return String(text.prefix(half)) + "\n……（中间省略 \(text.count - half * 2) 字）……\n" + String(text.suffix(half))
    }
}

extension WorkHost {
    /// Reads through the shell: base64 of the file, so any bytes come back whole. At most 4 MB.
    public func readByShell(_ path: String) async throws -> Data {
        let quoted = Shell.quote(path)
        let result = try await run("[ -f \(quoted) ] || { echo CLIO_NOFILE; exit 3; }; s=$(wc -c < \(quoted)); [ \"$s\" -gt 4000000 ] && { echo CLIO_TOOBIG $s; exit 4; }; base64 < \(quoted)", timeout: 60)
        if result.output.hasPrefix("CLIO_NOFILE") { throw ProviderError("没有这个文件：\(path)") }
        if result.output.hasPrefix("CLIO_TOOBIG") { throw ProviderError("\(path) 太大了（超过 4 MB），用命令只看一部分吧。") }
        guard result.code == 0, let data = Data(base64Encoded: result.output.filter { !$0.isWhitespace }) else {
            throw ProviderError("读不出 \(path)：\(result.output.prefix(300))")
        }
        return data
    }

    /// Writes through the shell in pieces, into a side file first, then moves it into place.
    public func writeByShell(_ path: String, _ data: Data) async throws {
        let quoted = Shell.quote(path)
        let part = Shell.quote(path + ".clio-part")
        let text = data.base64EncodedString()
        _ = try await run("mkdir -p \"$(dirname \(quoted))\" && : > \(part)", timeout: 30)
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: 60_000, limitedBy: text.endIndex) ?? text.endIndex
            let result = try await run("printf '%s' '\(text[index..<end])' | base64 -d >> \(part)", timeout: 60)
            if result.code != 0 { throw ProviderError("写 \(path) 时出错：\(result.output.prefix(300))") }
            index = end
        }
        let done = try await run("mv -f \(part) \(quoted) && echo CLIO_OK", timeout: 30)
        guard done.output.contains("CLIO_OK") else { throw ProviderError("写好了但没能放到 \(path)：\(done.output.prefix(300))") }
    }
}

/// Reading, writing and editing text files on any host, with the answers the model sees.
public enum HostFiles {
    public static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// Numbered lines from `from` (1-based), `lines` of them.
    public static func read(_ host: WorkHost, _ path: String, from: Int = 1, lines: Int = 400, notText: String = "") async -> ToolOutput {
        do {
            let data = try await host.read(path)
            guard let text = String(data: data, encoding: .utf8) else {
                return ToolOutput("这不是文本文件（\(size(data.count))）。" + notText, isError: true)
            }
            let all = text.components(separatedBy: "\n")
            let start = max(1, from)
            let count = max(1, lines)
            let slice = all.dropFirst(start - 1).prefix(count)
            if slice.isEmpty { return ToolOutput("文件只有 \(all.count) 行。", isError: true) }
            let numbered = slice.enumerated().map { "\(start + $0.offset)\t\($0.element)" }.joined(separator: "\n")
            let more = start - 1 + slice.count < all.count ? "\n……共 \(all.count) 行，后面还有。" : ""
            return ToolOutput(numbered + more)
        } catch {
            return ToolOutput(error.localizedDescription, isError: true)
        }
    }

    /// The whole file. When it was already there, the answer shows what changed.
    public static func write(_ host: WorkHost, _ path: String, _ content: String) async -> ToolOutput {
        do {
            let before = (try? await host.read(path)).flatMap { String(data: $0, encoding: .utf8) }
            try await host.write(path, Data(content.utf8))
            if let before {
                let change = Diff.between(before, content)
                if change.text.isEmpty { return ToolOutput("\(path) 内容没变。") }
                return ToolOutput("改写了 \(path)：−\(change.removed) +\(change.added) 行\n" + change.text)
            }
            let count = content.components(separatedBy: "\n").count
            return ToolOutput("新建了 \(path)（\(size(content.utf8.count))，\(count) 行）")
        } catch {
            return ToolOutput(error.localizedDescription, isError: true)
        }
    }

    /// Swaps one passage for another. The old passage must appear exactly once.
    public static func edit(_ host: WorkHost, _ path: String, old: String, new: String) async -> ToolOutput {
        do {
            guard let text = String(data: try await host.read(path), encoding: .utf8) else { return ToolOutput("这不是文本文件。", isError: true) }
            switch replaceOnce(in: text, old: old, new: new) {
            case .failure(let problem):
                return ToolOutput(problem.words(prefix: host.prefix), isError: true)
            case .success(let changed):
                try await host.write(path, Data(changed.utf8))
                let change = Diff.between(text, changed)
                return ToolOutput("改好了 \(path)：−\(change.removed) +\(change.added) 行\n" + change.text)
            }
        } catch {
            return ToolOutput(error.localizedDescription, isError: true)
        }
    }

    public enum EditProblem: Error, Equatable {
        case empty
        case missing
        case many(Int)

        func words(prefix: String) -> String {
            switch self {
            case .empty: "old 不能是空的。要整份重写用 \(prefix)_write。"
            case .missing: "文件里找不到这段原文。先 \(prefix)_read 看准了再改（空格、换行都要一样）。"
            case .many(let count): "这段原文出现了 \(count) 次，多带几行上下文让它唯一。"
            }
        }
    }

    public static func replaceOnce(in text: String, old: String, new: String) -> Result<String, EditProblem> {
        guard !old.isEmpty else { return .failure(.empty) }
        let found = text.components(separatedBy: old).count - 1
        if found == 0 { return .failure(.missing) }
        if found > 1 { return .failure(.many(found)) }
        return .success(text.replacingOccurrences(of: old, with: new))
    }
}
