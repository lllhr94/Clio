import AgentKit
import Craft
import Foundation
import ImageIO
import JavaScriptCore
import UniformTypeIdentifiers

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

    /// Every file under a folder, as paths relative to 书案, with sizes and dates.
    static func files(under folder: URL, cap: Int = 5000) -> [(path: String, size: Int, date: Date)] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        var found: [(path: String, size: Int, date: Date)] = []
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            found.append((relative(url), values.fileSize ?? 0, values.contentModificationDate ?? .distantPast))
            if found.count >= cap { break }
        }
        return found
    }

    static func globRegex(_ pattern: String) -> NSRegularExpression? { Glob.regex(pattern) }

    static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool { Glob.matches(regex, text) }

    /// A picture in 书案, made small enough to send: at most 1280 pixels on its long side, JPEG.
    static func picture(_ file: URL, longest: Int = 1280) -> (data: Data, width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longest,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let target = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(target, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(target) else { return nil }
        return (data as Data, image.width, image.height)
    }

    static func tools(canSee: Bool) -> [AgentTool] {
        let pathParameter: JSONValue = ["type": "string", "description": "书案里的相对路径，比如 notes/旅行.md"]
        var tools: [AgentTool] = []
        tools.append(DeskTool(name: "desk_list", description: "看书案（你和用户共用的工作文件夹）里有哪些文件。path 留空看全部。", parameters: ["type": "object", "properties": ["path": pathParameter]], label: { "书案：翻看 \($0["path"]?.string ?? "")" }) { arguments in
            guard let folder = resolve(arguments["path"]?.string) else { return ToolOutput("路径不能跳出书案。", isError: true) }
            return ToolOutput("书案/\(relative(folder) == "/" ? "" : relative(folder))\n" + listing(folder))
        })
        tools.append(DeskTool(name: "desk_find", description: "按文件名找书案里的文件。pattern 用通配符：*.md 找所有 md；**/*.py 找各层的 py；notes/2026-* 找某个文件夹里的。结果按修改时间排，新的在前。", parameters: ["type": "object", "properties": ["pattern": ["type": "string"], "path": ["type": "string", "description": "只在这个文件夹里找，留空是整个书案"]], "required": ["pattern"]], label: { "书案：找 \($0["pattern"]?.string ?? "")" }) { arguments in
            guard let folder = resolve(arguments["path"]?.string) else { return ToolOutput("路径不能跳出书案。", isError: true) }
            let pattern = (arguments["pattern"]?.string ?? "*").trimmingCharacters(in: .whitespaces)
            guard let regex = globRegex(pattern) else { return ToolOutput("看不懂这个通配符：\(pattern)", isError: true) }
            let byName = !pattern.contains("/")
            let base = relative(folder) == "/" ? "" : relative(folder) + "/"
            let found = files(under: folder).filter { item in
                let inside = item.path.hasPrefix(base) ? String(item.path.dropFirst(base.count)) : item.path
                return matches(regex, byName ? (inside as NSString).lastPathComponent : inside)
            }.sorted { $0.date > $1.date }
            guard !found.isEmpty else { return ToolOutput("没找到符合 \(pattern) 的文件。") }
            let shown = found.prefix(200).map { "\($0.path)  \(size($0.size))" }.joined(separator: "\n")
            return ToolOutput("找到 \(found.count) 个：\n" + shown + (found.count > 200 ? "\n……只列了前 200 个。" : ""))
        })
        tools.append(DeskTool(name: "desk_grep", description: "在书案的文本文件里搜内容，返回「文件:行号: 那一行」。pattern 是正则（搜普通文字也行）。可以用 include 限定文件，比如 *.md。", parameters: ["type": "object", "properties": ["pattern": ["type": "string"], "path": ["type": "string", "description": "只搜这个文件夹或文件，留空是整个书案"], "include": ["type": "string", "description": "文件名通配符，比如 *.swift"], "ignore_case": ["type": "boolean"]], "required": ["pattern"]], label: { "书案：搜 \($0["pattern"]?.string ?? "")" }) { arguments in
            guard let place = resolve(arguments["path"]?.string) else { return ToolOutput("路径不能跳出书案。", isError: true) }
            let words = arguments["pattern"]?.string ?? ""
            guard !words.isEmpty else { return ToolOutput("要搜什么？", isError: true) }
            let options: NSRegularExpression.Options = arguments["ignore_case"]?.bool == true ? [.caseInsensitive] : []
            let regex = (try? NSRegularExpression(pattern: words, options: options)) ?? (try! NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: words), options: options))
            let include = arguments["include"]?.string.flatMap { Glob.regex($0) }
            var isFolder: ObjCBool = false
            FileManager.default.fileExists(atPath: place.path, isDirectory: &isFolder)
            let candidates = isFolder.boolValue ? files(under: place).map(\.path) : [relative(place)]
            var hits: [String] = []
            var fileCount = 0
            for path in candidates {
                if let include, !matches(include, (path as NSString).lastPathComponent) { continue }
                guard let file = resolve(path), let data = try? Data(contentsOf: file), data.count < 4_000_000,
                      let text = String(data: data, encoding: .utf8) else { continue }
                var hitHere = false
                for (number, line) in text.components(separatedBy: "\n").enumerated() where matches(regex, line) {
                    hits.append("\(path):\(number + 1): \(line.count > 200 ? String(line.prefix(200)) + "…" : line)")
                    hitHere = true
                    if hits.count >= 300 { break }
                }
                if hitHere { fileCount += 1 }
                if hits.count >= 300 { break }
            }
            guard !hits.isEmpty else { return ToolOutput("没搜到「\(words)」。") }
            return ToolOutput("\(fileCount) 个文件里有 \(hits.count) 处\(hits.count >= 300 ? "（只列前 300 处）" : "")：\n" + hits.joined(separator: "\n"))
        })
        tools.append(DeskTool(name: "desk_read", description: "读书案里的一个文本文件。大文件可以用 from（从第几行起，1 开始）和 lines（读几行）分段读。", parameters: ["type": "object", "properties": ["path": pathParameter, "from": ["type": "number"], "lines": ["type": "number"]], "required": ["path"]], label: { "书案：读 \($0["path"]?.string ?? "")" }) { arguments in
            await HostFiles.read(DeskHost(), arguments["path"]?.string ?? "", from: Int(arguments["from"]?.number ?? 1), lines: Int(arguments["lines"]?.number ?? 400), notText: canSee ? "是图片的话用 view_image 看。" : "")
        })
        if canSee {
            tools.append(DeskTool(name: "view_image", description: "看书案里的一张图片（jpg、png、heic 等），比如用户发来的截图、扫描件、你在斗室里画的图表。", parameters: ["type": "object", "properties": ["path": pathParameter], "required": ["path"]], label: { "书案：看图 \($0["path"]?.string ?? "")" }) { arguments in
                guard let file = resolve(arguments["path"]?.string) else { return ToolOutput("路径不能跳出书案。", isError: true) }
                guard FileManager.default.fileExists(atPath: file.path) else { return ToolOutput("没有这个文件：\(relative(file))", isError: true) }
                guard let shot = picture(file) else { return ToolOutput("\(relative(file)) 打不开，可能不是图片。", isError: true) }
                return ToolOutput("这是 \(relative(file))（\(shot.width)×\(shot.height)）。", images: [ImagePart(mediaType: "image/jpeg", data: shot.data)])
            })
        }
        tools.append(DeskTool(name: "desk_write", description: "在书案里写一个文件（整份内容）。已有的会被覆盖；文件夹会自动建好。只改一小段时用 desk_edit。", parameters: ["type": "object", "properties": ["path": pathParameter, "content": ["type": "string"]], "required": ["path", "content"]], label: { "书案：写 \($0["path"]?.string ?? "")" }) { arguments in
            await HostFiles.write(DeskHost(), arguments["path"]?.string ?? "", arguments["content"]?.string ?? "")
        })
        tools.append(DeskTool(name: "desk_edit", description: "改书案里文件的一段：把 old 换成 new。old 要和文件里一字不差，并且只出现一次。", parameters: ["type": "object", "properties": ["path": pathParameter, "old": ["type": "string"], "new": ["type": "string"]], "required": ["path", "old", "new"]], label: { "书案：改 \($0["path"]?.string ?? "")" }) { arguments in
            await HostFiles.edit(DeskHost(), arguments["path"]?.string ?? "", old: arguments["old"]?.string ?? "", new: arguments["new"]?.string ?? "")
        })
        tools.append(DeskTool(name: "desk_delete", description: "删掉书案里的文件或文件夹。", parameters: ["type": "object", "properties": ["path": pathParameter], "required": ["path"]], label: { "书案：删 \($0["path"]?.string ?? "")" }, approval: { arguments in
            ApprovalAsk(title: "删掉书案里的东西", reason: arguments["path"]?.string ?? "")
        }) { arguments in
            guard let file = resolve(arguments["path"]?.string), relative(file) != "/" else { return ToolOutput("不能删整个书案。", isError: true) }
            guard FileManager.default.fileExists(atPath: file.path) else { return ToolOutput("没有这个：\(relative(file))", isError: true) }
            try FileManager.default.removeItem(at: file)
            return ToolOutput("删掉了 \(relative(file))")
        })
        tools.append(DeskTool(name: "run_js", description: "跑一段 JavaScript 算东西：算数、处理文本和数据、生成表格。用 console.log 输出；最后一个表达式的值也会返回。可以用 readFile(path) 和 writeFile(path, text) 读写书案里的文件。没有网络，没有 DOM。最多跑 10 秒。", parameters: ["type": "object", "properties": ["code": ["type": "string"]], "required": ["code"]], label: { _ in "书案：演算" }) { arguments in
            await Reckoner.run(arguments["code"]?.string ?? "")
        })
        return tools
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
