import AgentKit
import Foundation
import JavaScriptCore

/// 书案: the companions' working folder. It lives in the app's Documents, so the Files app shows it too.
enum Workspace {
    static var root: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("书案", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// A path the model wrote, kept inside the desk. Nil when it tries to step outside.
    static func resolve(_ path: String?) -> URL? {
        var cleaned = (path ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix("/") { cleaned.removeFirst() }
        if cleaned.hasPrefix("书案/") { cleaned.removeFirst(3) }
        let parts = cleaned.split(separator: "/").map(String.init).filter { !$0.isEmpty && $0 != "." }
        if parts.contains("..") { return nil }
        return parts.reduce(root) { $0.appendingPathComponent($1) }
    }

    static func relative(_ url: URL) -> String {
        let base = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(base) else { return url.lastPathComponent }
        let rest = String(path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return rest.isEmpty ? "/" : rest
    }

    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// Everything under a folder, a few levels deep, the way `tree` shows it.
    static func listing(_ folder: URL, depth: Int = 3) -> String {
        var lines: [String] = []
        func walk(_ url: URL, _ level: Int) {
            guard lines.count < 300 else { return }
            let items = ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles])) ?? [])
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            for item in items {
                let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                let indent = String(repeating: "  ", count: level)
                if values?.isDirectory == true {
                    lines.append("\(indent)\(item.lastPathComponent)/")
                    if level + 1 < depth { walk(item, level + 1) }
                } else {
                    lines.append("\(indent)\(item.lastPathComponent)  \(size(values?.fileSize ?? 0))")
                }
            }
        }
        walk(folder, 0)
        return lines.isEmpty ? "（空的）" : lines.joined(separator: "\n")
    }

    static func tools() -> [AgentTool] {
        let pathParameter: JSONValue = ["type": "string", "description": "书案里的相对路径，比如 notes/旅行.md"]
        return [
            DeskTool(name: "desk_list", description: "看书案（你和用户共用的工作文件夹）里有哪些文件。path 留空看全部。", parameters: ["type": "object", "properties": ["path": pathParameter]], label: { "书案：翻看 \($0["path"]?.string ?? "")" }) { arguments in
                guard let folder = resolve(arguments["path"]?.string) else { return ToolOutput("路径不能跳出书案。", isError: true) }
                return ToolOutput("书案/\(relative(folder) == "/" ? "" : relative(folder))\n" + listing(folder))
            },
            DeskTool(name: "desk_read", description: "读书案里的一个文本文件。大文件可以用 from（从第几行起，1 开始）和 lines（读几行）分段读。", parameters: ["type": "object", "properties": ["path": pathParameter, "from": ["type": "number"], "lines": ["type": "number"]], "required": ["path"]], label: { "书案：读 \($0["path"]?.string ?? "")" }) { arguments in
                guard let file = resolve(arguments["path"]?.string) else { return ToolOutput("路径不能跳出书案。", isError: true) }
                guard let data = try? Data(contentsOf: file) else { return ToolOutput("没有这个文件：\(relative(file))", isError: true) }
                guard let text = String(data: data, encoding: .utf8) else { return ToolOutput("这不是文本文件（\(size(data.count))）。", isError: true) }
                let all = text.components(separatedBy: "\n")
                let from = max(1, Int(arguments["from"]?.number ?? 1))
                let count = max(1, Int(arguments["lines"]?.number ?? 400))
                let slice = all.dropFirst(from - 1).prefix(count)
                let numbered = slice.enumerated().map { "\(from + $0.offset)\t\($0.element)" }.joined(separator: "\n")
                let more = from - 1 + slice.count < all.count ? "\n……共 \(all.count) 行，后面还有。" : ""
                return ToolOutput(numbered + more)
            },
            DeskTool(name: "desk_write", description: "在书案里写一个文件（整份内容）。已有的会被覆盖；文件夹会自动建好。", parameters: ["type": "object", "properties": ["path": pathParameter, "content": ["type": "string"]], "required": ["path", "content"]], label: { "书案：写 \($0["path"]?.string ?? "")" }) { arguments in
                guard let file = resolve(arguments["path"]?.string), relative(file) != "/" else { return ToolOutput("路径不对。", isError: true) }
                let existed = FileManager.default.fileExists(atPath: file.path)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                let content = arguments["content"]?.string ?? ""
                try Data(content.utf8).write(to: file, options: .atomic)
                return ToolOutput("\(existed ? "改写" : "新建")了 \(relative(file))（\(size(content.utf8.count))）")
            },
            DeskTool(name: "desk_edit", description: "改书案里文件的一段：把 old 换成 new。old 要和文件里一字不差，并且只出现一次。", parameters: ["type": "object", "properties": ["path": pathParameter, "old": ["type": "string"], "new": ["type": "string"]], "required": ["path", "old", "new"]], label: { "书案：改 \($0["path"]?.string ?? "")" }) { arguments in
                guard let file = resolve(arguments["path"]?.string), let text = try? String(contentsOf: file, encoding: .utf8) else { return ToolOutput("读不到这个文件。", isError: true) }
                let old = arguments["old"]?.string ?? ""
                let found = old.isEmpty ? 0 : text.components(separatedBy: old).count - 1
                guard found == 1 else { return ToolOutput(found == 0 ? "文件里找不到这段原文。先 desk_read 看准了再改。" : "这段原文出现了 \(found) 次，多带几行上下文让它唯一。", isError: true) }
                try Data(text.replacingOccurrences(of: old, with: arguments["new"]?.string ?? "").utf8).write(to: file, options: .atomic)
                return ToolOutput("改好了 \(relative(file))")
            },
            DeskTool(name: "desk_delete", description: "删掉书案里的文件或文件夹。", parameters: ["type": "object", "properties": ["path": pathParameter], "required": ["path"]], label: { "书案：删 \($0["path"]?.string ?? "")" }, approval: { arguments in
                ApprovalAsk(title: "删掉书案里的东西", reason: arguments["path"]?.string ?? "")
            }) { arguments in
                guard let file = resolve(arguments["path"]?.string), relative(file) != "/" else { return ToolOutput("不能删整个书案。", isError: true) }
                guard FileManager.default.fileExists(atPath: file.path) else { return ToolOutput("没有这个：\(relative(file))", isError: true) }
                try FileManager.default.removeItem(at: file)
                return ToolOutput("删掉了 \(relative(file))")
            },
            DeskTool(name: "run_js", description: "跑一段 JavaScript 算东西：算数、处理文本和数据、生成表格。用 console.log 输出；最后一个表达式的值也会返回。可以用 readFile(path) 和 writeFile(path, text) 读写书案里的文件。没有网络，没有 DOM。最多跑 10 秒。", parameters: ["type": "object", "properties": ["code": ["type": "string"]], "required": ["code"]], label: { _ in "书案：演算" }) { arguments in
                await Reckoner.run(arguments["code"]?.string ?? "")
            },
        ]
    }
}

/// One desk tool: its spec, how it shows, and what it does.
struct DeskTool: AgentTool {
    let spec: ToolSpec
    let shown: @Sendable (JSONValue) -> String
    let asking: (@Sendable (JSONValue) -> ApprovalAsk?)?
    let act: @Sendable (JSONValue) async throws -> ToolOutput

    init(name: String, description: String, parameters: JSONValue, label: @escaping @Sendable (JSONValue) -> String, approval: (@Sendable (JSONValue) -> ApprovalAsk?)? = nil, act: @escaping @Sendable (JSONValue) async throws -> ToolOutput) {
        spec = ToolSpec(name: name, description: description, parameters: parameters)
        shown = label
        asking = approval
        self.act = act
    }

    func label(for arguments: JSONValue) -> String { shown(arguments) }
    func approval(for arguments: JSONValue) -> ApprovalAsk? { asking?(arguments) }
    func run(_ arguments: JSONValue) async throws -> ToolOutput { try await act(arguments) }
}

/// Runs JavaScript on its own thread, away from the screen, and gives up waiting after ten seconds.
enum Reckoner {
    static func run(_ code: String) async -> ToolOutput {
        await withCheckedContinuation { (continuation: CheckedContinuation<ToolOutput, Never>) in
            let once = Once(continuation)
            let thread = Thread {
                once.finish(evaluate(code))
            }
            thread.stackSize = 8 << 20
            thread.start()
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                once.finish(ToolOutput("跑了 10 秒还没完，停止等待。可能有死循环，或者算得太多。", isError: true))
            }
        }
    }

    private final class Once: @unchecked Sendable {
        private var continuation: CheckedContinuation<ToolOutput, Never>?
        private let lock = NSLock()
        init(_ continuation: CheckedContinuation<ToolOutput, Never>) { self.continuation = continuation }
        func finish(_ output: ToolOutput) {
            lock.lock()
            let waiting = continuation
            continuation = nil
            lock.unlock()
            waiting?.resume(returning: output)
        }
    }

    private static func evaluate(_ code: String) -> ToolOutput {
        guard let context = JSContext() else { return ToolOutput("JavaScript 引擎起不来。", isError: true) }
        var printed: [String] = []
        var failure: String?
        context.exceptionHandler = { _, exception in
            let line = exception?.objectForKeyedSubscript("line")?.toString() ?? "?"
            failure = "出错（第 \(line) 行）：\(exception?.toString() ?? "未知错误")"
        }
        let log: @convention(block) () -> Void = {
            let words = (JSContext.currentArguments() as? [JSValue] ?? []).map(show)
            printed.append(words.joined(separator: " "))
        }
        let console = JSValue(newObjectIn: context)
        for name in ["log", "info", "warn", "error"] { console?.setObject(log, forKeyedSubscript: name as NSString) }
        context.setObject(console, forKeyedSubscript: "console" as NSString)
        let readFile: @convention(block) (String) -> Any = { path in
            guard let file = Workspace.resolve(path), let text = try? String(contentsOf: file, encoding: .utf8) else { return NSNull() }
            return text
        }
        let writeFile: @convention(block) (String, String) -> Bool = { path, text in
            guard let file = Workspace.resolve(path) else { return false }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            return (try? Data(text.utf8).write(to: file, options: .atomic)) != nil
        }
        context.setObject(readFile, forKeyedSubscript: "readFile" as NSString)
        context.setObject(writeFile, forKeyedSubscript: "writeFile" as NSString)
        let result = context.evaluateScript(code)
        var out = printed.joined(separator: "\n")
        if let result, !result.isUndefined, failure == nil {
            out += (out.isEmpty ? "" : "\n") + "→ " + show(result)
        }
        if out.count > 12000 { out = String(out.prefix(12000)) + "\n……（输出太长，截断了）" }
        if let failure { return ToolOutput((out.isEmpty ? "" : out + "\n") + failure, isError: true) }
        return ToolOutput(out.isEmpty ? "（跑完了，没有输出）" : out)
    }

    private static func show(_ value: JSValue) -> String {
        if value.isString { return value.toString() }
        if value.isObject, let context = value.context,
           let json = context.objectForKeyedSubscript("JSON")?.invokeMethod("stringify", withArguments: [value, NSNull(), 2]), json.isString {
            return json.toString()
        }
        return value.toString() ?? ""
    }
}
