import AgentKit
import Craft
import Foundation
import ImageIO
import UIKit
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

    /// What only 书案 has: deleting, and a quick JavaScript calculator. Reading, writing and finding are the workspace tools.
    static func tools() -> [AgentTool] {
        let pathParameter: JSONValue = ["type": "string", "description": "书案里的相对路径，比如 notes/旅行.md"]
        var tools: [AgentTool] = []
        tools.append(DeskTool(name: "desk_delete", description: "删掉书案里的文件或文件夹。", parameters: ["type": "object", "properties": ["path": pathParameter], "required": ["path"]], label: { "书案：删 \($0["path"]?.string ?? "")" }, approval: { arguments in
            ApprovalAsk(title: "删掉书案里的东西", reason: arguments["path"]?.string ?? "")
        }) { arguments in
            guard let file = resolve(arguments["path"]?.string), relative(file) != "/" else { return ToolOutput("不能删整个书案。", isError: true) }
            guard FileManager.default.fileExists(atPath: file.path) else { return ToolOutput("没有这个：\(relative(file))", isError: true) }
            try FileManager.default.removeItem(at: file)
            return ToolOutput("删掉了 \(relative(file))")
        })
        tools.append(DeskTool(name: "photo_text", description: "读出图片上的字（中文、英文都行）：用户发来的照片（给对话里［］中写的照片编号），或书案里的图片（给相对路径）。看不了图的模型也能靠它读题目、截图、文件照片。机器识别，可能有错字。", parameters: ["type": "object", "properties": ["photo": ["type": "string", "description": "照片编号，或书案里的图片路径"]], "required": ["photo"]], label: { "读图上的字：\(($0["photo"]?.string ?? "").prefix(24))" }) { arguments in
            let name = arguments["photo"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // A photo sent in a chat is a bare file name; anything with a folder in it is a path in 书案.
            let data = name.contains("/") ? nil : Disk.photo(name)
            guard let data = data ?? resolve(name).flatMap({ try? Data(contentsOf: $0) }), let image = UIImage(data: data) else {
                return ToolOutput("找不到这张图：\(name)。用户发的照片给编号，书案里的图给路径。", isError: true)
            }
            let text = await Scan.read(image)
            guard !text.isEmpty else { return ToolOutput("这张图上没认出字。") }
            return ToolOutput("图上的字（机器识别，可能有错字）：\n\n" + String(text.prefix(12_000)))
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
