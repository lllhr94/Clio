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
            let mounts = MountedFolders.all()
            let mountLine: String
            if mounts.isEmpty {
                mountLine = ""
            } else {
                let paths = mounts.map { "书案/\(MountedFolders.virtualFolder)/\($0.name)/" }.joined(separator: "、")
                mountLine = "\n已挂载的外部文件夹（可直接用文件读写和搜索工具操作，不经过斗室 shell）：\(paths)。"
            }
            return "\n\n这段絮语的工作地点是书案（手机里的工作文件夹，路径从书案算起）。read_file、write_file、edit_file、list_dir、glob、grep、view_image 都在书案里；shell 在斗室里跑，从 /root/desk 开始，也就是同一个书案。\(mountLine)"
        case .den:
            return "\n\n这段絮语的工作地点是斗室（手机里的 Alpine Linux）。八件工作区工具都在斗室里，相对路径从 /root/desk 算起；/root/desk 就是书案，用户在书案里也能看到。"
        case .hill:
            guard let host = hillHost else { return "\n\n用户把这段絮语的工作地点设在一台远山主机上，但那台主机已经删掉了，现在退回书案。需要时请用户在输入框下重新选地方。" }
            return "\n\n这段絮语的工作地点是远山主机「\(host.name)」（\(host.user)@\(host.address)）。八件工作区工具都在那台电脑上，相对路径从 ~ 算起；要跑很久的命令用 shell 带 background: true 放到后台，之后用 job 查。"
        }
    }
}

/// 书案 on the phone: files read and written directly (including external folders mounted at `书案/挂载/<name>/…`);
/// commands run in 斗室, which sees 书案 at /root/desk.
struct LocalDeskHost: WorkspaceHost {
    var title: String { Words.t("书案") }
    var shellTitle: String { Words.t("斗室") }
    var root: String { "书案" }
    var canBackground: Bool { false }

    func execStream(_ command: String, timeout: Double, onOutput: @escaping @Sendable (String) -> Void) async throws -> ExecResult {
        try await DenHost().execStream(command, timeout: timeout, onOutput: onOutput)
    }

    nonisolated func readFile(_ path: String) async throws -> Data {
        switch try Workspace.parse(path) {
        case .desk(let url, _):
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue else { throw WorkspaceError.missing(path) }
            return try Data(contentsOf: url)
        case .mountsRoot:
            throw WorkspaceError.cannot("挂载目录是文件夹，不能当文件读。")
        case .mounted(let mount, let inner, _):
            guard !inner.isEmpty else { throw WorkspaceError.cannot("「\(mount.name)」是文件夹，请指定里面的文件。") }
            return try MountedFolders.withAccess(mount, innerParts: inner) { _, url in
                var isFolder: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue else { throw WorkspaceError.missing(path) }
                return try Data(contentsOf: url)
            }
        }
    }

    nonisolated func writeFile(_ path: String, _ data: Data) async throws {
        try Workspace.writeBytes(path, data: data)
    }

    nonisolated func removeFile(_ path: String) async throws {
        switch try Workspace.parse(path) {
        case .desk(let url, let rel):
            guard rel != "/" else { return }
            try? FileManager.default.removeItem(at: url)
        case .mountsRoot:
            return
        case .mounted(let mount, let inner, _):
            // Never remove the external folder itself; removing a mount only deletes its bookmark in StudyPage.
            guard !inner.isEmpty else { return }
            try? MountedFolders.withAccess(mount, innerParts: inner) { _, url in
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    nonisolated func listDir(_ path: String, depth: Int) async throws -> String {
        let clamped = max(1, min(depth, 4))
        switch try Workspace.parse(path) {
        case .desk(let folder, let rel):
            guard FileManager.default.fileExists(atPath: folder.path) else { throw WorkspaceError.missing(path) }
            var body = Workspace.listing(folder, depth: clamped, root: Workspace.root)
            if rel == "/" {
                let mounts = MountedFolders.all()
                if !mounts.isEmpty {
                    let mountLines = Self.formatMountsListing(mounts, depth: clamped - 1, baseIndent: "  ")
                    let section = "\(MountedFolders.virtualFolder)/" + (mountLines.isEmpty ? "" : "\n" + mountLines)
                    body = body == "（空的）" ? section : body + "\n" + section
                }
            }
            return "书案/" + (rel == "/" ? "" : rel) + "\n" + body
        case .mountsRoot:
            let mounts = MountedFolders.all()
            guard !mounts.isEmpty else {
                return "书案/\(MountedFolders.virtualFolder)\n（还没有挂载外部文件夹）"
            }
            let body = Self.formatMountsListing(mounts, depth: clamped, baseIndent: "")
            return "书案/\(MountedFolders.virtualFolder)\n" + body
        case .mounted(let mount, let inner, let rel):
            return try MountedFolders.withAccess(mount, innerParts: inner) { rootURL, folder in
                guard FileManager.default.fileExists(atPath: folder.path) else { throw WorkspaceError.missing(path) }
                return "书案/\(rel)\n" + Workspace.listing(folder, depth: clamped, root: rootURL)
            }
        }
    }

    private static func formatMountsListing(_ mounts: [MountedFolder], depth: Int, baseIndent: String) -> String {
        var lines: [String] = []
        for mount in mounts {
            if depth <= 0 {
                lines.append("\(baseIndent)\(mount.name)/")
                continue
            }
            do {
                let listing = try MountedFolders.withAccess(mount) { rootURL, folder in
                    Workspace.listing(folder, depth: depth, root: rootURL)
                }
                lines.append("\(baseIndent)\(mount.name)/")
                if depth > 1 {
                    let childIndent = baseIndent + "  "
                    if listing == "（空的）" {
                        lines.append("\(childIndent)（空的）")
                    } else {
                        for line in listing.split(separator: "\n", omittingEmptySubsequences: false) {
                            lines.append("\(childIndent)\(line)")
                        }
                    }
                }
            } catch {
                lines.append("\(baseIndent)\(mount.name)/  （授权已失效，需重新选择）")
            }
        }
        return lines.joined(separator: "\n")
    }

    nonisolated func glob(_ pattern: String, in path: String) async throws -> [String] {
        guard let regex = Glob.regex(pattern) else { throw WorkspaceError.cannot("看不懂这个通配符：\(pattern)") }
        let byName = !pattern.contains("/")
        func filterItems(_ items: [(path: String, size: Int, date: Date)], basePrefix: String) -> [(path: String, size: Int, date: Date)] {
            items.filter { item in
                let inside = item.path.hasPrefix(basePrefix) ? String(item.path.dropFirst(basePrefix.count)) : item.path
                return Glob.matches(regex, byName ? (inside as NSString).lastPathComponent : inside)
            }
        }

        var matches: [(path: String, size: Int, date: Date)] = []
        switch try Workspace.parse(path) {
        case .desk(let folder, let rel):
            let base = rel == "/" ? "" : rel + "/"
            matches.append(contentsOf: filterItems(Workspace.files(under: folder, root: Workspace.root), basePrefix: base))
            if rel == "/" {
                for mount in MountedFolders.all() {
                    let prefix = "\(MountedFolders.virtualFolder)/\(mount.name)"
                    if let items = try? MountedFolders.withAccess(mount, body: { rootURL, target in
                        Workspace.files(under: target, root: rootURL, prefix: prefix)
                    }) {
                        matches.append(contentsOf: filterItems(items, basePrefix: ""))
                    }
                }
            }
        case .mountsRoot:
            for mount in MountedFolders.all() {
                let prefix = "\(MountedFolders.virtualFolder)/\(mount.name)"
                if let items = try? MountedFolders.withAccess(mount, body: { rootURL, target in
                    Workspace.files(under: target, root: rootURL, prefix: prefix)
                }) {
                    matches.append(contentsOf: filterItems(items, basePrefix: "\(MountedFolders.virtualFolder)/"))
                }
            }
        case .mounted(let mount, let inner, let rel):
            let prefix = "\(MountedFolders.virtualFolder)/\(mount.name)"
            let base = rel + "/"
            let items = try MountedFolders.withAccess(mount, innerParts: inner) { rootURL, target in
                Workspace.files(under: target, root: rootURL, prefix: prefix)
            }
            matches.append(contentsOf: filterItems(items, basePrefix: base))
        }
        return matches.sorted { $0.date > $1.date }.map(\.path)
    }

    nonisolated func grep(_ pattern: String, in path: String, include: String?, ignoreCase: Bool) async throws -> [String] {
        let options: NSRegularExpression.Options = ignoreCase ? [.caseInsensitive] : []
        let regex = (try? NSRegularExpression(pattern: pattern, options: options)) ?? (try! NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: pattern), options: options))
        let only = include.flatMap { Glob.regex($0) }
        var hits: [String] = []

        func scan(file url: URL, displayPath: String, root baseRoot: URL) {
            guard hits.count < 300 else { return }
            if let only, !Glob.matches(only, (displayPath as NSString).lastPathComponent) { return }
            guard Workspace.isInsideRealRoot(url, root: baseRoot),
                  let data = try? Data(contentsOf: url), data.count < 4_000_000,
                  let text = String(data: data, encoding: .utf8) else { return }
            for (number, line) in text.components(separatedBy: "\n").enumerated() where Glob.matches(regex, line) {
                hits.append("\(displayPath):\(number + 1):\(line)")
                if hits.count >= 300 { return }
            }
        }

        func scanFolder(_ folder: URL, root baseRoot: URL, prefix: String) {
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder) else { return }
            if !isFolder.boolValue {
                scan(file: folder, displayPath: Workspace.relative(folder, to: baseRoot, prefix: prefix), root: baseRoot)
                return
            }
            for item in Workspace.files(under: folder, root: baseRoot, prefix: prefix) {
                if hits.count >= 300 { return }
                let inside = (!prefix.isEmpty && item.path.hasPrefix(prefix + "/"))
                    ? String(item.path.dropFirst(prefix.count + 1))
                    : item.path
                let url = inside.split(separator: "/").reduce(baseRoot) { $0.appendingPathComponent(String($1)) }
                scan(file: url, displayPath: item.path, root: baseRoot)
            }
        }

        switch try Workspace.parse(path) {
        case .desk(let place, let rel):
            scanFolder(place, root: Workspace.root, prefix: "")
            if rel == "/" && hits.count < 300 {
                for mount in MountedFolders.all() {
                    if hits.count >= 300 { break }
                    let prefix = "\(MountedFolders.virtualFolder)/\(mount.name)"
                    _ = try? MountedFolders.withAccess(mount) { rootURL, target in
                        scanFolder(target, root: rootURL, prefix: prefix)
                    }
                }
            }
        case .mountsRoot:
            for mount in MountedFolders.all() {
                if hits.count >= 300 { break }
                let prefix = "\(MountedFolders.virtualFolder)/\(mount.name)"
                _ = try? MountedFolders.withAccess(mount) { rootURL, target in
                    scanFolder(target, root: rootURL, prefix: prefix)
                }
            }
        case .mounted(let mount, let inner, _):
            let prefix = "\(MountedFolders.virtualFolder)/\(mount.name)"
            try MountedFolders.withAccess(mount, innerParts: inner) { rootURL, target in
                scanFolder(target, root: rootURL, prefix: prefix)
            }
        }
        return hits
    }

    nonisolated func viewImage(_ path: String) async throws -> (image: ImagePart, width: Int, height: Int) {
        switch try Workspace.parse(path) {
        case .desk(let url, _):
            guard FileManager.default.fileExists(atPath: url.path) else { throw WorkspaceError.missing(path) }
            guard let shot = Workspace.picture(url) else { throw WorkspaceError.cannot("\(path) 打不开，可能不是图片。") }
            return (ImagePart(mediaType: "image/jpeg", data: shot.data), shot.width, shot.height)
        case .mountsRoot:
            throw WorkspaceError.cannot("挂载目录不是图片。")
        case .mounted(let mount, let inner, _):
            guard !inner.isEmpty else { throw WorkspaceError.cannot("请指定挂载文件夹里的图片路径。") }
            return try MountedFolders.withAccess(mount, innerParts: inner) { _, url in
                guard FileManager.default.fileExists(atPath: url.path) else { throw WorkspaceError.missing(path) }
                guard let shot = Workspace.picture(url) else { throw WorkspaceError.cannot("\(path) 打不开，可能不是图片。") }
                return (ImagePart(mediaType: "image/jpeg", data: shot.data), shot.width, shot.height)
            }
        }
    }

    /// Inside 书案 itself. A mounted outside folder (Obsidian, iCloud) holds the person's own files elsewhere, so
    /// after outside text (a web page, an email) a write there is asked about, like any write outside 书案.
    func isInside(_ path: String) -> Bool {
        guard let parsed = try? Workspace.parse(path) else { return false }
        if case .desk = parsed { return true }
        return false
    }
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

    /// File reads and writes are not printed line by line into 斗室's terminal (a 4 MB file is 70,000 lines of base64).
    func execQuiet(_ command: String, timeout: Double) async throws -> ExecResult {
        let result = await Den.shared.run("cd /root/desk 2>/dev/null; " + command, timeout: timeout, shown: false)
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

    /// The file verbs keep the whole output: a read is up to 4 MB as base64, far past what a command's output keeps.
    func execQuiet(_ command: String, timeout: Double) async throws -> ExecResult {
        do {
            let result = try await Hills.run(command, on: host, timeout: timeout, keep: 6_000_000)
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
