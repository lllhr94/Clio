import AgentKit
import Foundation

/// What a command left behind.
public struct ExecResult: Equatable, Sendable {
    public var code: Int
    public var output: String
    public var timedOut: Bool

    public init(code: Int, output: String, timedOut: Bool = false) {
        self.code = code
        self.output = output
        self.timedOut = timedOut
    }
}

/// A command left running in the background on a far computer.
public struct JobState: Equatable, Sendable {
    public var running: Bool
    public var exit: Int?
    public var tail: String

    public init(running: Bool, exit: Int?, tail: String) {
        self.running = running
        self.exit = exit
        self.tail = tail
    }
}

/// A file before and after a change.
public struct FileChange: Equatable, Sendable {
    /// Nil: the file was not there before.
    public var before: String?
    public var after: String
    public var diff: Diff.Summary

    public init(before: String?, after: String) {
        self.before = before
        self.after = after
        diff = Diff.between(before ?? "", after)
    }
}

/// One place to work — 书案 on the phone, 斗室's Linux, a 远山 computer — with the same verbs.
/// The eight workspace tools are written once against this. Hosts that only have a shell get every file verb
/// from the defaults below, each one a single command (`find`, `grep -rnI`, `base64`), never a file-by-file walk.
public protocol WorkspaceHost: Sendable {
    /// 「书案」「斗室」「远山 · 香港」: the start of every step's label.
    var title: String { get }
    /// Where `shell` runs, for its label: 书案's commands run in 斗室.
    var shellTitle: String { get }
    /// Where relative paths start, as the model should write it: 「书案」「/root/desk」「~」.
    var root: String { get }
    /// Only a far computer keeps a command running after the phone looks away.
    var canBackground: Bool { get }

    func execStream(_ command: String, timeout: Double, onOutput: @escaping @Sendable (String) -> Void) async throws -> ExecResult
    func readFile(_ path: String) async throws -> Data
    func writeFile(_ path: String, _ data: Data) async throws
    func removeFile(_ path: String) async throws
    func editFile(_ path: String, old: String, new: String) async throws -> FileChange
    func listDir(_ path: String, depth: Int) async throws -> String
    func glob(_ pattern: String, in path: String) async throws -> [String]
    func grep(_ pattern: String, in path: String, include: String?, ignoreCase: Bool) async throws -> [String]
    func viewImage(_ path: String) async throws -> (image: ImagePart, width: Int, height: Int)
    /// Whether a path stays inside the workspace (书案, /root/desk, the home folder).
    func isInside(_ path: String) -> Bool

    func startJob(_ command: String) async throws -> String
    func checkJob(_ id: String, lines: Int) async throws -> JobState
    func stopJob(_ id: String) async throws
}

public enum WorkspaceError: LocalizedError, Equatable {
    case missing(String)
    case notText(String, Int)
    case tooBig(String)
    case edit(HostEdit.Problem)
    case cannot(String)

    public var errorDescription: String? {
        switch self {
        case .missing(let path): "没有这个文件：\(path)"
        case .notText(let path, let size): "\(path) 不是文本文件（\(HostEdit.size(size))）。"
        case .tooBig(let path): "\(path) 太大了（超过 4 MB），用命令只看一部分吧。"
        case .edit(let problem): problem.words
        case .cannot(let words): words
        }
    }
}

/// Swapping one passage for another.
public enum HostEdit {
    public enum Problem: Error, Equatable, Sendable {
        case empty
        case missing
        case many(Int)

        public var words: String {
            switch self {
            case .empty: "old 不能是空的。要整份重写用 write_file。"
            case .missing: "文件里找不到这段原文。先 read_file 看准了再改（空格、换行都要一样）。"
            case .many(let count): "这段原文出现了 \(count) 次，多带几行上下文让它唯一。"
            }
        }
    }

    public static func replaceOnce(in text: String, old: String, new: String) -> Result<String, Problem> {
        guard !old.isEmpty else { return .failure(.empty) }
        let found = text.components(separatedBy: old).count - 1
        if found == 0 { return .failure(.missing) }
        if found > 1 { return .failure(.many(found)) }
        return .success(text.replacingOccurrences(of: old, with: new))
    }

    public static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

// MARK: Defaults: everything through the shell

extension WorkspaceHost {
    public func exec(_ command: String, timeout: Double = 120) async throws -> ExecResult {
        try await execStream(command, timeout: timeout, onOutput: { _ in })
    }

    /// Base64 of the file, so any bytes come back whole. At most 4 MB.
    public func readFile(_ path: String) async throws -> Data {
        let quoted = Shell.quote(path)
        let result = try await exec("[ -f \(quoted) ] || { echo CLIO_NOFILE; exit 3; }; s=$(wc -c < \(quoted)); [ \"$s\" -gt 4000000 ] && { echo CLIO_TOOBIG; exit 4; }; base64 < \(quoted)", timeout: 60)
        if result.output.hasPrefix("CLIO_NOFILE") { throw WorkspaceError.missing(path) }
        if result.output.hasPrefix("CLIO_TOOBIG") { throw WorkspaceError.tooBig(path) }
        guard result.code == 0, let data = Data(base64Encoded: result.output.filter { !$0.isWhitespace }) else {
            throw WorkspaceError.cannot("读不出 \(path)：\(result.output.prefix(300))")
        }
        return data
    }

    /// In pieces, into a side file first, then moved into place, so a half-written file never stands under the real name.
    public func writeFile(_ path: String, _ data: Data) async throws {
        let quoted = Shell.quote(path)
        let part = Shell.quote(path + ".clio-part")
        let text = data.base64EncodedString()
        _ = try await exec("mkdir -p \"$(dirname \(quoted))\" && : > \(part)", timeout: 30)
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: 60_000, limitedBy: text.endIndex) ?? text.endIndex
            let result = try await exec("printf '%s' '\(text[index..<end])' | base64 -d >> \(part)", timeout: 60)
            if result.code != 0 { throw WorkspaceError.cannot("写 \(path) 时出错：\(result.output.prefix(300))") }
            index = end
        }
        let done = try await exec("mv -f \(part) \(quoted) && echo CLIO_OK", timeout: 30)
        guard done.output.contains("CLIO_OK") else { throw WorkspaceError.cannot("写好了但没能放到 \(path)：\(done.output.prefix(300))") }
    }

    public func removeFile(_ path: String) async throws {
        _ = try await exec("rm -f \(Shell.quote(path))", timeout: 30)
    }

    public func editFile(_ path: String, old: String, new: String) async throws -> FileChange {
        guard let text = String(data: try await readFile(path), encoding: .utf8) else { throw WorkspaceError.notText(path, 0) }
        switch HostEdit.replaceOnce(in: text, old: old, new: new) {
        case .failure(let problem):
            throw WorkspaceError.edit(problem)
        case .success(let changed):
            try await writeFile(path, Data(changed.utf8))
            return FileChange(before: text, after: changed)
        }
    }

    public func listDir(_ path: String, depth: Int) async throws -> String {
        let folder = Shell.quote(path.isEmpty ? "." : path)
        let result = try await exec("cd \(folder) 2>/dev/null || { echo CLIO_NODIR; exit 3; }; find . -maxdepth \(max(1, min(depth, 4))) -not -path '*/.*' -not -path '*/node_modules/*' | sort | head -400", timeout: 60)
        if result.output.hasPrefix("CLIO_NODIR") { throw WorkspaceError.missing(path) }
        return result.output.isEmpty ? "（空文件夹）" : result.output
    }

    /// One `find`; the pattern itself is matched here, so `**` and `{a,b}` work the same on every host.
    public func glob(_ pattern: String, in path: String) async throws -> [String] {
        guard let regex = Glob.regex(pattern) else { throw WorkspaceError.cannot("看不懂这个通配符：\(pattern)") }
        let folder = Shell.quote(path.isEmpty ? "." : path)
        let result = try await exec("cd \(folder) 2>/dev/null || { echo CLIO_NODIR; exit 3; }; find . -type f -not -path '*/.git/*' -not -path '*/node_modules/*' 2>/dev/null | head -20000", timeout: 120)
        if result.output.hasPrefix("CLIO_NODIR") { throw WorkspaceError.missing(path) }
        let byName = !pattern.contains("/")
        return result.output.split(separator: "\n").map { String($0.hasPrefix("./") ? $0.dropFirst(2) : $0) }.filter { found in
            Glob.matches(regex, byName ? (found as NSString).lastPathComponent : found)
        }
    }

    /// One `grep -rnI`.
    public func grep(_ pattern: String, in path: String, include: String?, ignoreCase: Bool) async throws -> [String] {
        let folder = Shell.quote(path.isEmpty ? "." : path)
        let includeFlag = include.map { "--include=\(Shell.quote($0)) " } ?? ""
        let result = try await exec("grep -rnIE \(ignoreCase ? "-i " : "")\(includeFlag)--exclude-dir=.git --exclude-dir=node_modules -e \(Shell.quote(pattern)) \(folder) 2>/dev/null | head -300", timeout: 120)
        return result.output.split(separator: "\n").map(String.init)
    }

    public func viewImage(_ path: String) async throws -> (image: ImagePart, width: Int, height: Int) {
        let data = try await readFile(path)
        guard let shot = Picture.shrink(data) else { throw WorkspaceError.cannot("\(path) 打不开，可能不是图片。") }
        return (ImagePart(mediaType: "image/jpeg", data: shot.data), shot.width, shot.height)
    }

    public func startJob(_ command: String) async throws -> String {
        throw WorkspaceError.cannot("只有远山的电脑能把命令放到后台；\(shellTitle)里请直接跑，或者换到远山。")
    }

    public func checkJob(_ id: String, lines: Int) async throws -> JobState {
        throw WorkspaceError.cannot("\(shellTitle)没有后台任务。")
    }

    public func stopJob(_ id: String) async throws {
        throw WorkspaceError.cannot("\(shellTitle)没有后台任务。")
    }
}

/// Paths written the way a model writes them, checked against a workspace root.
public enum WorkspacePath {
    /// Whether `path` stays inside `root`: relative paths that never climb out, or absolute ones under it.
    /// `home` is how the root may also be written (`~`).
    public static func isInside(_ path: String, root: String, home: [String] = []) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        var parts: [Substring]
        if trimmed.hasPrefix("/") {
            let prefixes = ([root] + home).filter { $0.hasPrefix("/") }.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
            guard let prefix = prefixes.first(where: { trimmed == String($0.dropLast()) || trimmed.hasPrefix($0) }) else { return false }
            parts = trimmed.dropFirst(prefix.count).split(separator: "/")
        } else if trimmed == "~" || trimmed.hasPrefix("~/") {
            guard home.contains("~") || root == "~" else { return false }
            parts = trimmed.dropFirst(1).split(separator: "/")
        } else {
            parts = trimmed.split(separator: "/")
        }
        var depth = 0
        for part in parts {
            if part == ".." { depth -= 1 } else if part != "." { depth += 1 }
            if depth < 0 { return false }
        }
        return true
    }
}
