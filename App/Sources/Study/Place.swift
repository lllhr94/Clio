import AgentKit
import Craft
import Foundation

/// Where a conversation does its work: 书案 on the phone, 斗室's Linux, or one of 远山's computers.
enum WorkPlace: Hashable {
    case desk
    case den
    case hill(String)

    /// Kept in `ChatOptions.place`: "desk", "den", "hill:<id>".
    init(code: String?) {
        switch code {
        case "den": self = .den
        case let code? where code.hasPrefix("hill:"): self = .hill(String(code.dropFirst(5)))
        default: self = .desk
        }
    }

    var code: String? {
        switch self {
        case .desk: nil
        case .den: "den"
        case .hill(let id): "hill:\(id)"
        }
    }

    var symbol: String {
        switch self {
        case .desk: "books.vertical"
        case .den: "terminal"
        case .hill: "server.rack"
        }
    }

    @MainActor
    var hillHost: Hills.Host? {
        if case .hill(let id) = self { return Hills.shared.hosts.first { $0.id == id } }
        return nil
    }

    @MainActor
    var title: String {
        switch self {
        case .desk: Words.t("书案")
        case .den: Words.t("斗室")
        case .hill: Words.t("远山 · ") + (hillHost?.name ?? "已删的主机")
        }
    }

    /// The same verbs for every place. A 远山 host that was deleted falls back to 书案.
    @MainActor
    var host: WorkspaceHost {
        switch self {
        case .desk: return LocalDeskHost()
        case .den: return DenHost()
        case .hill:
            guard let found = hillHost else { return LocalDeskHost() }
            return SSHHost(found)
        }
    }

    /// Which ability gates the workspace tools here.
    func grant(for tool: String) -> Grant {
        switch self {
        case .desk: tool == "shell" ? .den : .desk
        case .den: .den
        case .hill: .hills
        }
    }

    /// A line for the system prompt, so the companion knows where it is working.
    @MainActor
    var promptLine: String {
        switch self {
        case .desk:
            return "\n\n这段絮语的工作地点是书案（手机里的工作文件夹，路径从书案算起）。read_file、write_file、edit_file、list_dir、glob、grep、view_image 都在书案里；shell 在斗室里跑，从 /root/desk 开始，也就是同一个书案。"
        case .den:
            return "\n\n这段絮语的工作地点是斗室（手机里的 Alpine Linux）。八件工作区工具都在斗室里，相对路径从 /root/desk 算起；/root/desk 就是书案，用户在书案里也能看到。"
        case .hill:
            guard let host = hillHost else { return "\n\n用户把这段絮语的工作地点设在一台远山主机上，但那台主机已经删掉了，现在退回书案。需要时请用户在输入框下重新选地方。" }
            return "\n\n这段絮语的工作地点是远山主机「\(host.name)」（\(host.user)@\(host.address)）。八件工作区工具都在那台电脑上，相对路径从 ~ 算起；要跑很久的命令用 shell 带 background: true 放到后台，之后用 job 查。"
        }
    }
}

/// 书案 on the phone: files read and written directly; commands run in 斗室, which sees 书案 at /root/desk.
struct LocalDeskHost: WorkspaceHost {
    var title: String { Words.t("书案") }
    var shellTitle: String { Words.t("斗室") }
    var root: String { "书案" }
    var canBackground: Bool { false }

    /// "书案/a.md", "/root/desk/a.md" and "a.md" all name the same file.
    private func file(_ path: String) throws -> URL {
        var trimmed = path.trimmingCharacters(in: .whitespaces)
        for prefix in ["/root/desk/", "书案/"] where trimmed.hasPrefix(prefix) { trimmed = String(trimmed.dropFirst(prefix.count)) }
        if trimmed == "/root/desk" || trimmed == "书案" { trimmed = "" }
        guard let url = Workspace.resolve(trimmed) else { throw WorkspaceError.cannot("路径不能跳出书案：\(path)") }
        return url
    }

    func execStream(_ command: String, timeout: Double, onOutput: @escaping @Sendable (String) -> Void) async throws -> ExecResult {
        try await DenHost().execStream(command, timeout: timeout, onOutput: onOutput)
    }

    func readFile(_ path: String) async throws -> Data {
        let url = try file(path)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue else { throw WorkspaceError.missing(path) }
        return try Data(contentsOf: url)
    }

    func writeFile(_ path: String, _ data: Data) async throws {
        let url = try file(path)
        guard Workspace.relative(url) != "/" else { throw WorkspaceError.cannot("要写到哪个文件？") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    func removeFile(_ path: String) async throws {
        let url = try file(path)
        guard Workspace.relative(url) != "/" else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func listDir(_ path: String, depth: Int) async throws -> String {
        let folder = try file(path)
        guard FileManager.default.fileExists(atPath: folder.path) else { throw WorkspaceError.missing(path) }
        let name = Workspace.relative(folder)
        return "书案/" + (name == "/" ? "" : name) + "\n" + Workspace.listing(folder, depth: max(1, min(depth, 4)))
    }

    func glob(_ pattern: String, in path: String) async throws -> [String] {
        let folder = try file(path)
        guard let regex = Glob.regex(pattern) else { throw WorkspaceError.cannot("看不懂这个通配符：\(pattern)") }
        let byName = !pattern.contains("/")
        let base = Workspace.relative(folder) == "/" ? "" : Workspace.relative(folder) + "/"
        return Workspace.files(under: folder).filter { item in
            let inside = item.path.hasPrefix(base) ? String(item.path.dropFirst(base.count)) : item.path
            return Glob.matches(regex, byName ? (inside as NSString).lastPathComponent : inside)
        }
        .sorted { $0.date > $1.date }
        .map(\.path)
    }

    func grep(_ pattern: String, in path: String, include: String?, ignoreCase: Bool) async throws -> [String] {
        let place = try file(path)
        let options: NSRegularExpression.Options = ignoreCase ? [.caseInsensitive] : []
        let regex = (try? NSRegularExpression(pattern: pattern, options: options)) ?? (try! NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: pattern), options: options))
        let only = include.flatMap { Glob.regex($0) }
        var isFolder: ObjCBool = false
        FileManager.default.fileExists(atPath: place.path, isDirectory: &isFolder)
        let candidates = isFolder.boolValue ? Workspace.files(under: place).map(\.path) : [Workspace.relative(place)]
        var hits: [String] = []
        for relative in candidates {
            if let only, !Glob.matches(only, (relative as NSString).lastPathComponent) { continue }
            guard let url = Workspace.resolve(relative), let data = try? Data(contentsOf: url), data.count < 4_000_000,
                  let text = String(data: data, encoding: .utf8) else { continue }
            for (number, line) in text.components(separatedBy: "\n").enumerated() where Glob.matches(regex, line) {
                hits.append("\(relative):\(number + 1):\(line)")
                if hits.count >= 300 { return hits }
            }
        }
        return hits
    }

    func viewImage(_ path: String) async throws -> (image: ImagePart, width: Int, height: Int) {
        let url = try file(path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw WorkspaceError.missing(path) }
        guard let shot = Workspace.picture(url) else { throw WorkspaceError.cannot("\(path) 打不开，可能不是图片。") }
        return (ImagePart(mediaType: "image/jpeg", data: shot.data), shot.width, shot.height)
    }

    func isInside(_ path: String) -> Bool { (try? file(path)) != nil }
}

/// 斗室: everything through its shell, starting in /root/desk.
struct DenHost: WorkspaceHost {
    var title: String { Words.t("斗室") }
    var shellTitle: String { Words.t("斗室") }
    var root: String { "/root/desk" }
    var canBackground: Bool { false }

    func execStream(_ command: String, timeout: Double, onOutput: @escaping @Sendable (String) -> Void) async throws -> ExecResult {
        let result = await Den.shared.run("cd /root/desk 2>/dev/null; " + command, timeout: timeout, onOutput: onOutput)
        var output = result.output
        if !result.errorOutput.isEmpty { output += (output.isEmpty ? "" : "\n") + result.errorOutput }
        return ExecResult(code: Int(result.code), output: output, timedOut: result.timedOut)
    }

    func isInside(_ path: String) -> Bool { WorkspacePath.isInside(path, root: "/root/desk") }
}

/// A 远山 computer over SSH (one kept connection, reconnected when it drops).
struct SSHHost: WorkspaceHost {
    let host: Hills.Host
    init(_ host: Hills.Host) { self.host = host }

    var title: String { Words.t("远山 · \(host.name)") }
    var shellTitle: String { Words.t("远山 · \(host.name)") }
    var root: String { "~" }
    var canBackground: Bool { true }

    func execStream(_ command: String, timeout: Double, onOutput: @escaping @Sendable (String) -> Void) async throws -> ExecResult {
        do {
            let result = try await Hills.run(command, on: host, timeout: timeout, onOutput: onOutput)
            return ExecResult(code: result.code, output: result.output)
        } catch let late as Hills.TimedOut {
            return ExecResult(code: -1, output: late.output, timedOut: true)
        }
    }

    func startJob(_ command: String) async throws -> String { try await Hills.startJob(command, on: host) }
    func checkJob(_ id: String, lines: Int) async throws -> JobState { try await Hills.checkJob(id, on: host, lines: lines) }
    func stopJob(_ id: String) async throws { try await Hills.stopJob(id, on: host) }

    func isInside(_ path: String) -> Bool {
        WorkspacePath.isInside(path, root: "~", home: [host.user == "root" ? "/root" : "/home/\(host.user)"])
    }
}
