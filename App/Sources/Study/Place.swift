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
        case .desk: "书案"
        case .den: "斗室"
        case .hill: "远山 · " + (hillHost?.name ?? "已删的主机")
        }
    }

    /// The same verbs for every place.
    @MainActor
    var host: WorkHost? {
        switch self {
        case .desk: return DeskHost()
        case .den: return DenHost()
        case .hill:
            guard let found = hillHost else { return nil }
            return HillHost(found)
        }
    }

    /// A line for the system prompt, so the companion knows where to put things.
    @MainActor
    var promptLine: String {
        switch self {
        case .desk:
            return ""
        case .den:
            return "\n\n这段絮语的工作地点是斗室（手机里的 Alpine Linux）。命令用 shell，斗室里的文件用 den_read、den_write、den_edit、den_find；工作文件放在 /root/desk 下面，用户在书案里也能看到。"
        case .hill:
            guard let host = hillHost else { return "\n\n用户把这段絮语的工作地点设在一台远山主机上，但那台主机已经删掉了。需要时请用户在输入框下重新选地方。" }
            return "\n\n这段絮语的工作地点是远山主机「\(host.name)」（\(host.user)@\(host.address)）。命令用 ssh_run（host 填「\(host.name)」），跑很久的用 ssh_job_start；那台机器上的文件用 hill_read、hill_write、hill_edit、hill_find。路径从 ~ 算起。"
        }
    }
}

struct DeskHost: WorkHost {
    var title: String { "书案" }
    var prefix: String { "desk" }
    var home: String { "书案" }
    var canRun: Bool { false }

    func run(_ command: String, timeout: Double) async throws -> (code: Int, output: String) {
        throw ProviderError("书案只放文件，不跑命令。要跑命令，把工作地点换到斗室或远山。")
    }

    func read(_ path: String) async throws -> Data {
        guard let file = Workspace.resolve(path) else { throw ProviderError("路径不能跳出书案。") }
        guard FileManager.default.fileExists(atPath: file.path) else { throw ProviderError("没有这个文件：\(Workspace.relative(file))") }
        return try Data(contentsOf: file)
    }

    func write(_ path: String, _ data: Data) async throws {
        guard let file = Workspace.resolve(path), Workspace.relative(file) != "/" else { throw ProviderError("路径不对。") }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }
}

struct DenHost: WorkHost {
    var title: String { "斗室" }
    var prefix: String { "den" }
    var home: String { "/root" }
    var canRun: Bool { true }

    func run(_ command: String, timeout: Double) async throws -> (code: Int, output: String) {
        let result = await Den.shared.run(command, timeout: timeout, shown: false)
        if result.timedOut { throw ProviderError("超过 \(Int(timeout)) 秒没跑完。") }
        let output = result.output + (result.errorOutput.isEmpty ? "" : (result.output.isEmpty ? "" : "\n") + result.errorOutput)
        return (Int(result.code), output)
    }

    func read(_ path: String) async throws -> Data { try await readByShell(path) }
    func write(_ path: String, _ data: Data) async throws { try await writeByShell(path, data) }
}

struct HillHost: WorkHost {
    let host: Hills.Host
    init(_ host: Hills.Host) { self.host = host }

    var title: String { "远山 · \(host.name)" }
    var prefix: String { "hill" }
    var home: String { "~" }
    var canRun: Bool { true }

    func run(_ command: String, timeout: Double) async throws -> (code: Int, output: String) {
        let result = try await Hills.run(command, on: host, timeout: timeout)
        return (result.code, result.output)
    }

    func read(_ path: String) async throws -> Data { try await readByShell(path) }
    func write(_ path: String, _ data: Data) async throws { try await writeByShell(path, data) }
}

/// File tools for a place that is not 书案: read, write, edit and find, named after the place.
enum PlaceTools {
    static func all(for host: WorkHost) -> [AgentTool] {
        guard host.prefix != "desk" else { return [] }
        let prefix = host.prefix
        let title = host.title
        let path: JSONValue = ["type": "string", "description": "路径；相对路径从 \(host.home) 算起"]
        var tools: [AgentTool] = []
        tools.append(DeskTool(name: "\(prefix)_read", description: "读\(title)里的一个文本文件。大文件用 from 和 lines 分段读。", parameters: ["type": "object", "properties": ["path": path, "from": ["type": "number"], "lines": ["type": "number"]], "required": ["path"]], label: { "\(title)：读 \($0["path"]?.string ?? "")" }) { arguments in
            await HostFiles.read(host, arguments["path"]?.string ?? "", from: Int(arguments["from"]?.number ?? 1), lines: Int(arguments["lines"]?.number ?? 400))
        })
        tools.append(DeskTool(name: "\(prefix)_write", description: "在\(title)里写一个文件（整份内容），文件夹会自动建好。只改一小段时用 \(prefix)_edit。", parameters: ["type": "object", "properties": ["path": path, "content": ["type": "string"]], "required": ["path", "content"]], label: { "\(title)：写 \($0["path"]?.string ?? "")" }) { arguments in
            await HostFiles.write(host, arguments["path"]?.string ?? "", arguments["content"]?.string ?? "")
        })
        tools.append(DeskTool(name: "\(prefix)_edit", description: "改\(title)里文件的一段：把 old 换成 new。old 要和文件里一字不差，并且只出现一次。", parameters: ["type": "object", "properties": ["path": path, "old": ["type": "string"], "new": ["type": "string"]], "required": ["path", "old", "new"]], label: { "\(title)：改 \($0["path"]?.string ?? "")" }) { arguments in
            await HostFiles.edit(host, arguments["path"]?.string ?? "", old: arguments["old"]?.string ?? "", new: arguments["new"]?.string ?? "")
        })
        tools.append(DeskTool(name: "\(prefix)_find", description: "在\(title)里按文件名找（name 是通配符，比如 *.py），或者按内容搜（text 是要搜的字）。都用上就是在这些文件里搜这些字。", parameters: ["type": "object", "properties": ["path": ["type": "string", "description": "从哪个文件夹开始，默认 \(host.home)"], "name": ["type": "string"], "text": ["type": "string"]]], label: { "\(title)：找 \($0["text"]?.string ?? $0["name"]?.string ?? "")" }) { arguments in
            let folder = Shell.quote(arguments["path"]?.string ?? ".")
            let name = arguments["name"]?.string
            let command: String
            if let text = arguments["text"]?.string, !text.isEmpty {
                let include = name.map { "--include=\(Shell.quote($0))" } ?? ""
                command = "grep -rIn \(include) --exclude-dir=node_modules --exclude-dir=.git -e \(Shell.quote(text)) \(folder) 2>/dev/null | head -300"
            } else {
                command = "find \(folder) -not -path '*/node_modules/*' -not -path '*/.git/*' -name \(Shell.quote(name ?? "*")) 2>/dev/null | head -300"
            }
            do {
                let result = try await host.run(command, timeout: 60)
                return ToolOutput(result.output.isEmpty ? "什么都没找到。" : Shell.clip(result.output))
            } catch {
                return ToolOutput(error.localizedDescription, isError: true)
            }
        })
        return tools
    }
}
