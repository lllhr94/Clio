import AgentKit
import Foundation

/// A tool made of closures.
public struct HostTool: AgentTool {
    public let spec: ToolSpec
    let shown: @Sendable (JSONValue) -> String
    let act: @Sendable (JSONValue) async throws -> ToolOutput

    public init(name: String, description: String, parameters: JSONValue, label: @escaping @Sendable (JSONValue) -> String, act: @escaping @Sendable (JSONValue) async throws -> ToolOutput) {
        spec = ToolSpec(name: name, description: description, parameters: parameters)
        shown = label
        self.act = act
    }

    public func label(for arguments: JSONValue) -> String { shown(arguments) }
    public func run(_ arguments: JSONValue) async throws -> ToolOutput { try await act(arguments) }
}

/// What the workspace tools need from the app around them.
public struct WorkspaceKit: Sendable {
    /// Whether the model can look at pictures (view_image is left out when it cannot).
    public var canSee: Bool
    /// Kept secrets, to hide from what a command prints or a file holds.
    public var secrets: @Sendable () -> [String]
    /// Called before a file is first changed in a turn, so the turn can be undone.
    public var beforeChange: @Sendable (_ host: WorkspaceHost, _ path: String) async -> Void
    /// Each line a command prints, as it prints it.
    public var tail: @Sendable (String) -> Void

    public init(canSee: Bool, secrets: @escaping @Sendable () -> [String] = { [] }, beforeChange: @escaping @Sendable (WorkspaceHost, String) async -> Void = { _, _ in }, tail: @escaping @Sendable (String) -> Void = { _ in }) {
        self.canSee = canSee
        self.secrets = secrets
        self.beforeChange = beforeChange
        self.tail = tail
    }
}

/// The eight workspace tools, the same on every host: shell, read_file, write_file, edit_file, list_dir, glob, grep, view_image.
public enum WorkspaceTools {
    public static let names: Set<String> = ["shell", "read_file", "write_file", "edit_file", "list_dir", "glob", "grep", "view_image"]
    /// Tools that change files.
    public static let writers: Set<String> = ["write_file", "edit_file"]

    public static func all(host: WorkspaceHost, kit: WorkspaceKit) -> [AgentTool] {
        var tools: [AgentTool] = [shell(host, kit)]
        tools.append(readFile(host, kit))
        tools.append(writeFile(host, kit))
        tools.append(editFile(host, kit))
        tools.append(listDir(host))
        tools.append(glob(host))
        tools.append(grep(host, kit))
        if kit.canSee { tools.append(viewImage(host)) }
        return tools
    }

    static func path(_ host: WorkspaceHost) -> JSONValue {
        ["type": "string", "description": "路径。相对路径从 \(host.root) 算起"]
    }

    // MARK: shell

    static func shell(_ host: WorkspaceHost, _ kit: WorkspaceKit) -> AgentTool {
        var properties: [String: JSONValue] = [
            "command": ["type": "string"],
            "timeout": ["type": "number", "description": "最多等几秒，默认 120，最多 600"],
        ]
        var extra = ""
        if host.canBackground {
            properties["background"] = ["type": "boolean", "description": "放到后台跑（编译、下载、训练）。手机锁屏、断网都不影响，返回任务编号"]
            properties["job"] = ["type": "string", "description": "查一个后台任务：填任务编号（这时不用填 command）"]
            properties["stop"] = ["type": "boolean", "description": "和 job 一起用：停掉这个后台任务"]
            properties["lines"] = ["type": "number", "description": "查后台任务时看最后几行，默认 40"]
            extra = "\n- 要跑很久的命令带 background: true 放到后台，之后用 job 查进度和日志。"
        }
        let description = """
        在\(host.shellTitle)跑 shell 命令，从 \(host.root) 开始。
        - 一次跑一条或几条，命令要能自己结束，不要开交互程序（vim、top、python 交互模式）。
        - 输出超过两万字只留头尾各一万字，必要时用 head、tail、grep 缩小范围。\(extra)
        """
        return HostTool(name: "shell", description: description, parameters: ["type": "object", "properties": .object(properties)], label: { arguments in
            if let job = arguments["job"]?.string, !job.isEmpty {
                return "\(host.shellTitle)：\(arguments["stop"]?.bool == true ? "停掉" : "看看")后台任务 \(job)"
            }
            let command = (arguments["command"]?.string ?? "").prefix(40)
            return "\(host.shellTitle)：\(command)\(arguments["background"]?.bool == true ? "（后台）" : "")"
        }) { arguments in
            let hide: (String) -> String = { Shell.mask($0, secrets: kit.secrets()) }
            if let job = arguments["job"]?.string, !job.isEmpty {
                do {
                    if arguments["stop"]?.bool == true {
                        try await host.stopJob(job)
                        return ToolOutput("停掉了后台任务 \(job)。")
                    }
                    let state = try await host.checkJob(job, lines: min(400, max(5, (arguments["lines"]?.int ?? 40))))
                    let head = state.running ? "还在跑。" : "跑完了，退出码 \(state.exit.map(String.init) ?? "不明")。"
                    return ToolOutput(head + "\n最后的输出：\n" + (state.tail.isEmpty ? "（还没有输出）" : hide(Shell.clip(state.tail))))
                } catch {
                    return ToolOutput(error.localizedDescription, isError: true)
                }
            }
            let command = arguments["command"]?.string ?? ""
            guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return ToolOutput("命令是空的。", isError: true) }
            if arguments["background"]?.bool == true {
                do {
                    let id = try await host.startJob(command)
                    return ToolOutput("放到后台了，任务编号 \(id)。手机锁屏、断网都不影响。过一会儿用 shell 带 job: \"\(id)\" 看进度和日志。")
                } catch {
                    return ToolOutput(error.localizedDescription, isError: true)
                }
            }
            let timeout = min(600, max(5, arguments["timeout"]?.number ?? 120))
            do {
                let result = try await host.execStream(command, timeout: timeout, onOutput: kit.tail)
                let text = hide(Shell.clip(result.output))
                if result.timedOut {
                    let hint = host.canBackground ? "要跑很久的命令可以带 background: true 放到后台。" : ""
                    return ToolOutput((text.isEmpty ? "" : text + "\n") + "（超过 \(Int(timeout)) 秒没跑完，已经停掉。\(hint)）", isError: true)
                }
                let tail = result.code == 0 ? "" : "\n（退出码 \(result.code)）"
                return ToolOutput((text.isEmpty ? "（没有输出）" : text) + tail, isError: result.code != 0)
            } catch {
                return ToolOutput(error.localizedDescription, isError: true)
            }
        }
    }

    // MARK: Files

    static func readFile(_ host: WorkspaceHost, _ kit: WorkspaceKit) -> AgentTool {
        HostTool(name: "read_file", description: "读\(host.title)里的一个文本文件，每行带行号。大文件用 from（从第几行起，1 开始）和 lines（读几行，默认 400）分段读。", parameters: ["type": "object", "properties": ["path": path(host), "from": ["type": "number"], "lines": ["type": "number"]], "required": ["path"]], label: { "\(host.title)：读 \($0["path"]?.string ?? "")" }) { arguments in
            let target = arguments["path"]?.string ?? ""
            do {
                let data = try await host.readFile(target)
                guard let text = String(data: data, encoding: .utf8) else {
                    let hint = kit.canSee ? "是图片的话用 view_image 看。" : ""
                    return ToolOutput(WorkspaceError.notText(target, data.count).localizedDescription + hint, isError: true)
                }
                let all = text.components(separatedBy: "\n")
                let start = max(1, (arguments["from"]?.int ?? 1))
                let count = max(1, (arguments["lines"]?.int ?? 400))
                let slice = all.dropFirst(start - 1).prefix(count)
                if slice.isEmpty { return ToolOutput("文件只有 \(all.count) 行。", isError: true) }
                let numbered = slice.enumerated().map { "\(start + $0.offset)\t\($0.element)" }.joined(separator: "\n")
                let more = start - 1 + slice.count < all.count ? "\n……共 \(all.count) 行，后面还有。" : ""
                return ToolOutput(Shell.mask(Shell.clip(numbered), secrets: kit.secrets()) + more)
            } catch {
                return ToolOutput(error.localizedDescription, isError: true)
            }
        }
    }

    static func writeFile(_ host: WorkspaceHost, _ kit: WorkspaceKit) -> AgentTool {
        HostTool(name: "write_file", description: "在\(host.title)里写一个文件（整份内容），文件夹会自动建好，已有的会被覆盖。只改一小段时用 edit_file。", parameters: ["type": "object", "properties": ["path": path(host), "content": ["type": "string"]], "required": ["path", "content"]], label: { "\(host.title)：写 \($0["path"]?.string ?? "")" }) { arguments in
            let target = arguments["path"]?.string ?? ""
            let content = arguments["content"]?.string ?? ""
            guard !target.isEmpty else { return ToolOutput("要写到哪个文件？", isError: true) }
            do {
                await kit.beforeChange(host, target)
                let before = (try? await host.readFile(target)).flatMap { String(data: $0, encoding: .utf8) }
                try await host.writeFile(target, Data(content.utf8))
                let change = FileChange(before: before, after: content)
                if before == nil {
                    let lines = content.components(separatedBy: "\n").count
                    return ToolOutput("新建了 \(target)：−0 +\(lines) 行（\(HostEdit.size(content.utf8.count))）", detail: change.diff.full)
                }
                if change.diff.text.isEmpty { return ToolOutput("\(target) 内容没变。") }
                return ToolOutput("改写了 \(target)：−\(change.diff.removed) +\(change.diff.added) 行\n" + change.diff.text, detail: change.diff.full)
            } catch {
                return ToolOutput(error.localizedDescription, isError: true)
            }
        }
    }

    static func editFile(_ host: WorkspaceHost, _ kit: WorkspaceKit) -> AgentTool {
        HostTool(name: "edit_file", description: "改\(host.title)里文件的一段：把 old 换成 new。old 要和文件里一字不差（空格、换行都算），并且只出现一次。回来的是改动前后的对比。", parameters: ["type": "object", "properties": ["path": path(host), "old": ["type": "string"], "new": ["type": "string"]], "required": ["path", "old", "new"]], label: { "\(host.title)：改 \($0["path"]?.string ?? "")" }) { arguments in
            let target = arguments["path"]?.string ?? ""
            do {
                await kit.beforeChange(host, target)
                let change = try await host.editFile(target, old: arguments["old"]?.string ?? "", new: arguments["new"]?.string ?? "")
                return ToolOutput("改好了 \(target)：−\(change.diff.removed) +\(change.diff.added) 行\n" + change.diff.text, detail: change.diff.full)
            } catch {
                return ToolOutput(error.localizedDescription, isError: true)
            }
        }
    }

    static func listDir(_ host: WorkspaceHost) -> AgentTool {
        HostTool(name: "list_dir", description: "看\(host.title)里一个文件夹有什么。path 留空看 \(host.root)；depth 是往下看几层，默认 2。", parameters: ["type": "object", "properties": ["path": path(host), "depth": ["type": "number"]]], label: { "\(host.title)：翻看 \($0["path"]?.string ?? "")" }) { arguments in
            do {
                return ToolOutput(try await host.listDir(arguments["path"]?.string ?? "", depth: (arguments["depth"]?.int ?? 2)))
            } catch {
                return ToolOutput(error.localizedDescription, isError: true)
            }
        }
    }

    static func glob(_ host: WorkspaceHost) -> AgentTool {
        HostTool(name: "glob", description: "按文件名找\(host.title)里的文件。pattern 用通配符：*.md 是所有 md；**/*.py 是各层的 py；notes/2026-* 是某个文件夹里的；*.{jpg,png} 是两种都要。", parameters: ["type": "object", "properties": ["pattern": ["type": "string"], "path": ["type": "string", "description": "只在这个文件夹里找，留空是整个 \(host.root)"]], "required": ["pattern"]], label: { "\(host.title)：找 \($0["pattern"]?.string ?? "")" }) { arguments in
            let pattern = (arguments["pattern"]?.string ?? "*").trimmingCharacters(in: .whitespaces)
            do {
                let found = try await host.glob(pattern, in: arguments["path"]?.string ?? "")
                guard !found.isEmpty else { return ToolOutput("没找到符合 \(pattern) 的文件。") }
                let shown = found.prefix(200).joined(separator: "\n")
                return ToolOutput("找到 \(found.count) 个：\n" + shown + (found.count > 200 ? "\n……只列了前 200 个。" : ""))
            } catch {
                return ToolOutput(error.localizedDescription, isError: true)
            }
        }
    }

    static func grep(_ host: WorkspaceHost, _ kit: WorkspaceKit) -> AgentTool {
        HostTool(name: "grep", description: "在\(host.title)的文本文件里搜内容，返回「文件:行号:那一行」。pattern 是正则（搜普通文字也行）；include 限定文件名，比如 *.swift。", parameters: ["type": "object", "properties": ["pattern": ["type": "string"], "path": ["type": "string", "description": "只搜这个文件夹或文件，留空是整个 \(host.root)"], "include": ["type": "string"], "ignore_case": ["type": "boolean"]], "required": ["pattern"]], label: { "\(host.title)：搜 \($0["pattern"]?.string ?? "")" }) { arguments in
            let pattern = arguments["pattern"]?.string ?? ""
            guard !pattern.isEmpty else { return ToolOutput("要搜什么？", isError: true) }
            do {
                let hits = try await host.grep(pattern, in: arguments["path"]?.string ?? "", include: arguments["include"]?.string, ignoreCase: arguments["ignore_case"]?.bool == true)
                guard !hits.isEmpty else { return ToolOutput("没搜到「\(pattern)」。") }
                let lines = hits.prefix(300).map { $0.count > 240 ? String($0.prefix(240)) + "…" : $0 }
                let text = "搜到 \(hits.count) 处\(hits.count >= 300 ? "（只列前 300 处）" : "")：\n" + lines.joined(separator: "\n")
                return ToolOutput(Shell.mask(Shell.clip(text), secrets: kit.secrets()))
            } catch {
                return ToolOutput(error.localizedDescription, isError: true)
            }
        }
    }

    static func viewImage(_ host: WorkspaceHost) -> AgentTool {
        HostTool(name: "view_image", description: "看\(host.title)里的一张图片（jpg、png、heic 等）：用户发来的截图、扫描件、画出来的图表。会缩到长边 1280 像素。", parameters: ["type": "object", "properties": ["path": path(host)], "required": ["path"]], label: { "\(host.title)：看图 \($0["path"]?.string ?? "")" }) { arguments in
            let target = arguments["path"]?.string ?? ""
            do {
                let shot = try await host.viewImage(target)
                return ToolOutput("这是 \(target)（\(shot.width)×\(shot.height)）。", images: [shot.image])
            } catch {
                return ToolOutput(error.localizedDescription, isError: true)
            }
        }
    }
}
