import AgentKit
import Foundation
import XCTest
@testable import Craft

final class DiffTests: XCTestCase {
    func testOneLineChanged() {
        let change = Diff.between("a\nb\nc\nd", "a\nb\nC\nd")
        XCTAssertEqual(change.removed, 1)
        XCTAssertEqual(change.added, 1)
        XCTAssertEqual(change.text, "@@ 第 3 行\n  a\n  b\n- c\n+ C\n  d")
    }

    func testAddedAtEnd() {
        let change = Diff.between("a\nb", "a\nb\nc")
        XCTAssertEqual(change.removed, 0)
        XCTAssertEqual(change.added, 1)
        XCTAssertTrue(change.text.hasSuffix("+ c"))
    }

    func testNothingChanged() {
        XCTAssertEqual(Diff.between("same\ntext", "same\ntext").text, "")
    }

    func testRepeatedLinesDoNotOverlap() {
        // Prefix and suffix must not both claim the same lines.
        let change = Diff.between("x\nx", "x\nx\nx")
        XCTAssertEqual(change.removed, 0)
        XCTAssertEqual(change.added, 1)
    }

    func testLongChangeIsCut() {
        let old = (1...100).map(String.init).joined(separator: "\n")
        let change = Diff.between(old, "", limit: 20)
        XCTAssertEqual(change.removed, 100)
        XCTAssertTrue(change.text.contains("后面还有"))
        XCTAssertEqual(change.full.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }.count, 100)
    }

    func testTwoChangesFarApartMakeTwoHunks() {
        let old = (1...30).map { "第\($0)行" }.joined(separator: "\n")
        var lines = old.components(separatedBy: "\n")
        lines[2] = "改了三"
        lines[25] = "改了二十六"
        let change = Diff.between(old, lines.joined(separator: "\n"))
        XCTAssertEqual(change.removed, 2)
        XCTAssertEqual(change.added, 2)
        let headers = change.full.components(separatedBy: "\n").filter { $0.hasPrefix(Diff.marker) }
        XCTAssertEqual(headers, ["@@ 第 3 行", "@@ 第 26 行"])
        XCTAssertFalse(change.full.contains("第10行"), "lines far from any change stay out")
    }

    func testInsertionInTheMiddle() {
        let change = Diff.between("a\nb\nc", "a\nb\nNEW\nc")
        XCTAssertEqual(change.removed, 0)
        XCTAssertEqual(change.added, 1)
        XCTAssertEqual(change.full, "@@ 第 3 行\n  a\n  b\n+ NEW\n  c")
    }

    func testCountsAndHunkReadBack() {
        let output = "改好了 notes/a.md：−2 +3 行\n@@ 第 4 行\n- x"
        XCTAssertEqual(Diff.counts(in: output)?.removed, 2)
        XCTAssertEqual(Diff.counts(in: output)?.added, 3)
        XCTAssertEqual(Diff.hunk(in: output), "@@ 第 4 行\n- x")
        XCTAssertNil(Diff.counts(in: "新建了 a.md"))
        XCTAssertNil(Diff.hunk(in: "新建了 a.md"))
    }
}

final class GlobTests: XCTestCase {
    func testNameOnly() {
        XCTAssertTrue(Glob.matches("*.md", path: "notes/旅行.md"))
        XCTAssertFalse(Glob.matches("*.md", path: "notes/旅行.txt"))
        XCTAssertTrue(Glob.matches("*.MD", path: "a.md"))
    }

    func testFolders() {
        XCTAssertTrue(Glob.matches("notes/*.md", path: "notes/a.md"))
        XCTAssertFalse(Glob.matches("notes/*.md", path: "notes/deep/a.md"))
        XCTAssertTrue(Glob.matches("**/*.py", path: "a.py"))
        XCTAssertTrue(Glob.matches("**/*.py", path: "src/tools/a.py"))
        XCTAssertTrue(Glob.matches("src/**", path: "src/x/y/z.txt"))
    }

    func testBracesAndQuestion() {
        XCTAssertTrue(Glob.matches("*.{jpg,png}", path: "shot.png"))
        XCTAssertFalse(Glob.matches("*.{jpg,png}", path: "shot.gif"))
        XCTAssertTrue(Glob.matches("第?页.jpg", path: "扫描/第3页.jpg"))
        XCTAssertNil(Glob.regex("*.{jpg,png"))
    }

    func testSpecialCharactersAreLiteral() {
        XCTAssertTrue(Glob.matches("a+b (1).txt", path: "a+b (1).txt"))
        XCTAssertFalse(Glob.matches("a.txt", path: "abtxt"))
    }
}

final class ExplainTests: XCTestCase {
    func testBadKeyGoesToTuning() {
        let advice = Explain.model(ProviderError(status: 401, "invalid api key"), service: "DeepSeek")
        XCTAssertEqual(advice.next, .tuning)
        XCTAssertTrue(advice.title.contains("DeepSeek"))
    }

    func testTooLongAsksToCompress() {
        let advice = Explain.model(ProviderError(status: 400, "This model's maximum context length is 65536 tokens"), service: "x")
        XCTAssertEqual(advice.next, .compress)
    }

    func testUnknownModel() {
        XCTAssertEqual(Explain.model(ProviderError(status: 400, "Model Not Exist"), service: "x").next, .tuning)
    }

    func testServerTroubleIsRetry() {
        XCTAssertEqual(Explain.model(ProviderError(status: 503, "overloaded"), service: "x").next, .retry)
        XCTAssertEqual(Explain.model(ProviderError(status: 429, "slow down"), service: "x").next, .retry)
    }

    func testOffline() {
        let advice = Explain.model(URLError(.notConnectedToInternet), service: "x")
        XCTAssertEqual(advice.next, .retry)
        XCTAssertEqual(advice.button, "再试一次")
        XCTAssertEqual(Explain.model(URLError(.cannotFindHost), service: "x").next, .care)
    }
}

final class ConversationTests: XCTestCase {
    private func call(_ id: String) -> ToolCall { ToolCall(id: id, name: "desk_read", arguments: "{}") }

    private func assistant(_ text: String, calls: [ToolCall] = []) -> Message {
        var message = Message.assistant(text)
        message.toolCalls = calls
        return message
    }

    func testMissingAnswerIsFilledIn() {
        let first = call("1"), second = call("2")
        let messages: [Message] = [.user("读一下"), assistant("", calls: [first, second]), .toolResult("内容", for: first)]
        let mended = Conversation.paired(messages)
        XCTAssertEqual(mended.count, 4)
        XCTAssertEqual(mended[3].toolCallId, "2")
        XCTAssertEqual(mended[3].text, "（这一步没有完成）")
    }

    func testStrayAndDuplicateAnswersAreDropped() {
        let first = call("1")
        let messages: [Message] = [.toolResult("迷路的", for: call("9")), .user("hi"), assistant("", calls: [first]), .toolResult("a", for: first), .toolResult("a again", for: first)]
        let mended = Conversation.paired(messages)
        XCTAssertEqual(mended.map(\.role), [.user, .assistant, .tool])
        XCTAssertEqual(mended.last?.text, "a")
    }

    func testWindowStartsAtTheUser() {
        let messages: [Message] = [
            .user(String(repeating: "旧", count: 100)),
            assistant(String(repeating: "答", count: 100)),
            .user("新问题"),
            assistant("", calls: [call("1")]),
            .toolResult("结果", for: call("1")),
            assistant("新回答"),
        ]
        XCTAssertEqual(Conversation.windowStart(messages, maxChars: 50, maxCount: 0), 2)
        XCTAssertEqual(Conversation.windowStart(messages, maxChars: 10_000, maxCount: 0), 0)
        // Three newest messages start mid-step; with no user message after, it reaches back to the question.
        XCTAssertEqual(Conversation.windowStart(messages, maxChars: 10_000, maxCount: 3), 2)
        XCTAssertEqual(Conversation.windowStart(messages, maxChars: 10_000, maxCount: 4), 2)
    }

    func testGroupWindowIsNeverEmpty() {
        let messages: [Message] = [.user("大家好"), assistant("我是团子")]
        XCTAssertEqual(Conversation.windowStart(messages, maxChars: 10_000, maxCount: 1), 0)
        XCTAssertEqual(Conversation.windowStart([], maxChars: 10, maxCount: 0), 0)
    }

    func testNewestMessageAlwaysGoes() {
        let messages: [Message] = [.user(String(repeating: "长", count: 1000))]
        XCTAssertEqual(Conversation.windowStart(messages, maxChars: 10, maxCount: 0), 0)
    }
}

/// A host kept in memory: files in a dictionary, a shell that answers from a script and remembers every command.
private class MockHost: WorkspaceHost, @unchecked Sendable {
    let lock = NSLock()
    var files: [String: Data] = [:]
    var commands: [String] = []
    var reply: (String) -> ExecResult = { _ in ExecResult(code: 0, output: "") }

    var title: String { "假主机" }
    var shellTitle: String { "假主机" }
    var root: String { "/work" }
    var canBackground: Bool { false }

    init(_ files: [String: String] = [:]) {
        self.files = files.mapValues { Data($0.utf8) }
    }

    func execStream(_ command: String, timeout: Double, onOutput: @escaping @Sendable (String) -> Void) async throws -> ExecResult {
        lock.lock()
        commands.append(command)
        let answer = reply(command)
        lock.unlock()
        for line in answer.output.split(separator: "\n") { onOutput(String(line)) }
        return answer
    }

    func readFile(_ path: String) async throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let data = files[path] else { throw WorkspaceError.missing(path) }
        return data
    }

    func writeFile(_ path: String, _ data: Data) async throws {
        lock.lock(); defer { lock.unlock() }
        files[path] = data
    }

    func removeFile(_ path: String) async throws {
        lock.lock(); defer { lock.unlock() }
        files[path] = nil
    }

    func listDir(_ path: String, depth: Int) async throws -> String {
        lock.lock(); defer { lock.unlock() }
        return files.keys.sorted().joined(separator: "\n")
    }

    func viewImage(_ path: String) async throws -> (image: ImagePart, width: Int, height: Int) {
        guard files[path] != nil else { throw WorkspaceError.missing(path) }
        return (ImagePart(mediaType: "image/png", data: Data([1, 2, 3])), 10, 20)
    }

    func isInside(_ path: String) -> Bool { WorkspacePath.isInside(path, root: "/work") }

    // Declared here, not left to the protocol's defaults, so the far host below can override them.
    func startJob(_ command: String) async throws -> String { throw WorkspaceError.cannot("没有后台") }
    func checkJob(_ id: String, lines: Int) async throws -> JobState { throw WorkspaceError.cannot("没有后台") }
    func stopJob(_ id: String) async throws { throw WorkspaceError.cannot("没有后台") }

    func text(_ path: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return files[path].flatMap { String(data: $0, encoding: .utf8) }
    }
}

/// A far computer: background jobs work.
private final class FarHost: MockHost, @unchecked Sendable {
    override var canBackground: Bool { true }
    override func startJob(_ command: String) async throws -> String { "job7" }
    override func checkJob(_ id: String, lines: Int) async throws -> JobState { JobState(running: false, exit: 0, tail: "done token=s3cr3t-value") }
    override func stopJob(_ id: String) async throws {}
}

/// Kept changes, for the tests that look at what the tools asked to snapshot.
private final class Book: @unchecked Sendable {
    let lock = NSLock()
    var changed: [String] = []
    func add(_ path: String) { lock.lock(); changed.append(path); lock.unlock() }
}

final class WorkspaceToolTests: XCTestCase {
    private func tools(_ host: WorkspaceHost, canSee: Bool = true, secrets: [String] = [], book: Book = Book()) -> [String: AgentTool] {
        let kit = WorkspaceKit(canSee: canSee, secrets: { secrets }, beforeChange: { _, path in book.add(path) })
        return Dictionary(uniqueKeysWithValues: WorkspaceTools.all(host: host, kit: kit).map { ($0.spec.name, $0) })
    }

    func testEightToolsAndViewImageOnlyForSeeingModels() {
        let host = MockHost()
        XCTAssertEqual(Set(tools(host).keys), WorkspaceTools.names)
        XCTAssertNil(tools(host, canSee: false)["view_image"])
        XCTAssertEqual(tools(host, canSee: false).count, 7)
    }

    func testShellClipsHidesSecretsAndReportsExit() async throws {
        let host = MockHost()
        host.reply = { _ in ExecResult(code: 2, output: String(repeating: "x", count: 30_000) + "\npassword=hunter2-long") }
        let output = try await tools(host, secrets: ["hunter2-long"])["shell"]!.run(["command": "cat secrets"])
        XCTAssertTrue(output.isError)
        XCTAssertTrue(output.text.contains("中间省略"))
        XCTAssertTrue(output.text.contains(Shell.hidden))
        XCTAssertFalse(output.text.contains("hunter2-long"))
        XCTAssertTrue(output.text.hasSuffix("（退出码 2）"))
    }

    func testShellTimeoutAndEmptyCommand() async throws {
        let host = MockHost()
        host.reply = { _ in ExecResult(code: -1, output: "", timedOut: true) }
        let shell = tools(host)["shell"]!
        let late = try await shell.run(["command": "sleep 999", "timeout": 5])
        XCTAssertTrue(late.isError)
        XCTAssertTrue(late.text.contains("超过 5 秒"))
        let empty = try await shell.run(["command": "  "])
        XCTAssertTrue(empty.isError)
    }

    func testBackgroundOnlyOnFarHosts() async throws {
        let near = try await tools(MockHost())["shell"]!.run(["command": "make", "background": true])
        XCTAssertTrue(near.isError)
        let far = FarHost()
        let shell = tools(far, secrets: ["s3cr3t-value"])["shell"]!
        let started = try await shell.run(["command": "make", "background": true])
        XCTAssertFalse(started.isError)
        XCTAssertTrue(started.text.contains("job7"))
        let checked = try await shell.run(["job": "job7"])
        XCTAssertTrue(checked.text.contains("跑完了，退出码 0"))
        XCTAssertFalse(checked.text.contains("s3cr3t-value"))
        XCTAssertNil(tools(MockHost())["shell"]!.spec.parameters["properties"]?["background"])
        XCTAssertNotNil(shell.spec.parameters["properties"]?["background"])
    }

    func testReadRangesMissingAndBinary() async throws {
        let host = MockHost(["l.txt": (1...10).map { "第\($0)行" }.joined(separator: "\n")])
        host.files["x.bin"] = Data([0xFF, 0xFE, 0x00])
        let read = tools(host)["read_file"]!
        let part = try await read.run(["path": "l.txt", "from": 3, "lines": 2])
        XCTAssertEqual(part.text, "3\t第3行\n4\t第4行\n……共 10 行，后面还有。")
        let tail = try await read.run(["path": "l.txt", "from": 9, "lines": 5])
        XCTAssertEqual(tail.text, "9\t第9行\n10\t第10行")
        let past = try await read.run(["path": "l.txt", "from": 30])
        XCTAssertTrue(past.isError)
        let none = try await read.run(["path": "nope.txt"])
        XCTAssertTrue(none.isError)
        XCTAssertTrue(none.text.contains("没有这个文件"))
        let binary = try await read.run(["path": "x.bin"])
        XCTAssertTrue(binary.isError)
        XCTAssertTrue(binary.text.contains("view_image"))
    }

    func testWriteNewThenOverwriteKeepsAFullComparison() async throws {
        let host = MockHost()
        let book = Book()
        let write = tools(host, book: book)["write_file"]!
        let first = try await write.run(["path": "a.md", "content": "一\n二"])
        XCTAssertTrue(first.text.hasPrefix("新建了 a.md：−0 +2 行"))
        let second = try await write.run(["path": "a.md", "content": "一\n三"])
        XCTAssertEqual(Diff.counts(in: second.text)?.removed, 1)
        XCTAssertEqual(Diff.counts(in: second.text)?.added, 1)
        XCTAssertEqual(second.detail, "@@ 第 2 行\n  一\n- 二\n+ 三")
        XCTAssertEqual(host.text("a.md"), "一\n三")
        let same = try await write.run(["path": "a.md", "content": "一\n三"])
        XCTAssertTrue(same.text.contains("没变"))
        XCTAssertEqual(book.changed, ["a.md", "a.md", "a.md"], "every write first asks for a snapshot")
    }

    func testEditOnce() async throws {
        let host = MockHost(["n.txt": "苹果\n香蕉\n苹果派"])
        let edit = tools(host)["edit_file"]!
        let missing = try await edit.run(["path": "n.txt", "old": "西瓜", "new": "x"])
        XCTAssertTrue(missing.isError)
        XCTAssertTrue(missing.text.contains("read_file"))
        let many = try await edit.run(["path": "n.txt", "old": "苹果", "new": "梨"])
        XCTAssertTrue(many.text.contains("2 次"))
        let empty = try await edit.run(["path": "n.txt", "old": "", "new": "梨"])
        XCTAssertTrue(empty.isError)
        let done = try await edit.run(["path": "n.txt", "old": "香蕉", "new": "橘子"])
        XCTAssertFalse(done.isError)
        XCTAssertEqual(host.text("n.txt"), "苹果\n橘子\n苹果派")
        XCTAssertEqual(done.detail?.contains("- 香蕉"), true)
        XCTAssertEqual(done.detail?.contains("+ 橘子"), true)
        XCTAssertTrue(done.text.contains("  苹果"), "the answer shows the lines around the change")
    }

    func testGlobIsOneFindCommand() async throws {
        let host = MockHost()
        host.reply = { command in
            command.contains("find . -type f") ? ExecResult(code: 0, output: "./a.md\n./notes/b.md\n./c.txt\n./src/x/y.py") : ExecResult(code: 0, output: "")
        }
        let glob = tools(host)["glob"]!
        let md = try await glob.run(["pattern": "*.md"])
        XCTAssertTrue(md.text.contains("a.md"))
        XCTAssertTrue(md.text.contains("notes/b.md"))
        XCTAssertFalse(md.text.contains("c.txt"))
        let deep = try await glob.run(["pattern": "src/**/*.py"])
        XCTAssertTrue(deep.text.contains("src/x/y.py"))
        XCTAssertEqual(host.commands.count, 2, "one command per search, never a walk file by file")
    }

    func testGrepIsOneGrepCommandAndHidesSecrets() async throws {
        let host = MockHost()
        host.reply = { command in
            command.contains("grep -rnIE") ? ExecResult(code: 0, output: "app/.env:3:TOKEN=abcdef123456\napp/main.py:9:print(1)") : ExecResult(code: 1, output: "")
        }
        let grep = tools(host, secrets: ["abcdef123456"])["grep"]!
        let found = try await grep.run(["pattern": "TOKEN|print", "include": "*.py", "ignore_case": true])
        XCTAssertTrue(found.text.contains("搜到 2 处"))
        XCTAssertFalse(found.text.contains("abcdef123456"))
        XCTAssertEqual(host.commands.count, 1)
        XCTAssertTrue(host.commands[0].contains("--include='*.py'"))
        XCTAssertTrue(host.commands[0].contains("-i "))
    }

    func testListDirAndViewImage() async throws {
        let host = MockHost(["b.txt": "", "a.png": "png"])
        let listed = try await tools(host)["list_dir"]!.run([:])
        XCTAssertEqual(listed.text, "a.png\nb.txt")
        let picture = try await tools(host)["view_image"]!.run(["path": "a.png"])
        XCTAssertEqual(picture.images.count, 1)
        XCTAssertTrue(picture.text.contains("10×20"))
    }

    func testShellHostDefaultsReadAndWriteThroughBase64() async throws {
        let host = MockHost()
        host.reply = { command in
            if command.contains("base64 <") { return ExecResult(code: 0, output: Data("你好".utf8).base64EncodedString()) }
            if command.contains("CLIO_OK") { return ExecResult(code: 0, output: "CLIO_OK") }
            return ExecResult(code: 0, output: "")
        }
        // A host with only a shell: the protocol's defaults do the file work.
        struct ShellOnly: WorkspaceHost {
            let inner: MockHost
            var title: String { "壳" }
            var shellTitle: String { "壳" }
            var root: String { "~" }
            var canBackground: Bool { false }
            func execStream(_ command: String, timeout: Double, onOutput: @escaping @Sendable (String) -> Void) async throws -> ExecResult {
                try await inner.execStream(command, timeout: timeout, onOutput: onOutput)
            }
            func isInside(_ path: String) -> Bool { true }
        }
        let shellOnly = ShellOnly(inner: host)
        let data = try await shellOnly.readFile("a.txt")
        XCTAssertEqual(String(data: data, encoding: .utf8), "你好")
        try await shellOnly.writeFile("dir/b.txt", Data("嗨".utf8))
        XCTAssertTrue(host.commands.contains { $0.contains("base64 -d >> 'dir/b.txt.clio-part'") })
        XCTAssertTrue(host.commands.last?.contains("mv -f 'dir/b.txt.clio-part' 'dir/b.txt'") == true)
    }
}

final class WorkspacePathTests: XCTestCase {
    func testInsideAndOutside() {
        XCTAssertTrue(WorkspacePath.isInside("notes/a.md", root: "/root/desk"))
        XCTAssertTrue(WorkspacePath.isInside("/root/desk/notes/a.md", root: "/root/desk"))
        XCTAssertFalse(WorkspacePath.isInside("/etc/passwd", root: "/root/desk"))
        XCTAssertFalse(WorkspacePath.isInside("../../etc/passwd", root: "/root/desk"))
        XCTAssertTrue(WorkspacePath.isInside("a/../b", root: "/root/desk"))
        XCTAssertTrue(WorkspacePath.isInside("~/proj/x", root: "~", home: ["/home/lin"]))
        XCTAssertTrue(WorkspacePath.isInside("/home/lin/proj", root: "~", home: ["/home/lin"]))
        XCTAssertFalse(WorkspacePath.isInside("/var/www", root: "~", home: ["/home/lin"]))
        XCTAssertFalse(WorkspacePath.isInside("/root/desk-other/x", root: "/root/desk"))
    }
}

final class ShellTests: XCTestCase {
    func testQuote() {
        XCTAssertEqual(Shell.quote("a b"), "'a b'")
        XCTAssertEqual(Shell.quote("it's"), "'it'\\''s'")
        XCTAssertEqual(Shell.quote(""), "''")
    }

    func testClipKeepsHeadAndTail() {
        let text = String(repeating: "a", count: 50) + String(repeating: "b", count: 50)
        let clipped = Shell.clip(text, max: 20)
        XCTAssertTrue(clipped.hasPrefix(String(repeating: "a", count: 10)))
        XCTAssertTrue(clipped.hasSuffix(String(repeating: "b", count: 10)))
        XCTAssertTrue(clipped.contains("省略 80 字"))
        XCTAssertEqual(Shell.clip("short", max: 20), "short")
        let big = String(repeating: "z", count: 25_000)
        XCTAssertTrue(Shell.clip(big).hasPrefix(String(repeating: "z", count: 10_000) + "\n……"))
    }

    func testMaskLongestFirstAndSkipsShortValues() {
        let text = "key=sk-abcdef123456 short=abc again sk-abcdef123456"
        let masked = Shell.mask(text, secrets: ["sk-abcdef", "sk-abcdef123456", "abc"])
        XCTAssertEqual(masked, "key=\(Shell.hidden) short=abc again \(Shell.hidden)")
    }
}

/// A tool that does nothing, asks nothing, and remembers being run.
private struct Quiet: AgentTool {
    let spec: ToolSpec
    init(_ name: String) { spec = ToolSpec(name: name, description: "", parameters: ["type": "object"]) }
    func label(for arguments: JSONValue) -> String { spec.name }
    func run(_ arguments: JSONValue) async throws -> ToolOutput { ToolOutput("好") }
}

final class TaintTests: XCTestCase {
    private let inside: @Sendable (String) -> Bool = { WorkspacePath.isInside($0, root: "/root/desk") }

    func testWhatReadsTheWeb() {
        XCTAssertTrue(Taint.reads("browser_read"))
        XCTAssertTrue(Taint.reads("web_read"))
        XCTAssertTrue(Taint.reads("mcp_vps__browser_snapshot"))
        XCTAssertFalse(Taint.reads("read_file"))
        XCTAssertFalse(Taint.reads("shell"))
    }

    func testWhatNeedsASealAfterReading() {
        XCTAssertTrue(Taint.needsSeal(tool: "shell", arguments: ["command": "ls"], isInside: inside))
        XCTAssertTrue(Taint.needsSeal(tool: "browser_fill_secret", arguments: [:], isInside: inside))
        XCTAssertTrue(Taint.needsSeal(tool: "ssh_run", arguments: [:], isInside: inside))
        XCTAssertTrue(Taint.needsSeal(tool: "write_file", arguments: ["path": "/etc/hosts"], isInside: inside))
        XCTAssertTrue(Taint.needsSeal(tool: "edit_file", arguments: ["path": "../../x"], isInside: inside))
        XCTAssertFalse(Taint.needsSeal(tool: "write_file", arguments: ["path": "notes/a.md"], isInside: inside))
        XCTAssertFalse(Taint.needsSeal(tool: "read_file", arguments: ["path": "/etc/hosts"], isInside: inside))
    }

    func testGuardForcesAskingOnlyAfterTheTurnReadTheWeb() async throws {
        let book = TaintBook()
        let shell = TaintGuard(Quiet("shell"), key: "bot-a", book: book, isInside: inside)
        let reader = TaintGuard(Quiet("browser_read"), key: "bot-a", book: book, isInside: inside)
        let otherChat = TaintGuard(Quiet("shell"), key: "bot-b", book: book, isInside: inside)
        XCTAssertNil(shell.approval(for: ["command": "ls"]), "before any web reading, standing permission applies")
        _ = try await reader.run([:])
        let ask = shell.approval(for: ["command": "ls"])
        XCTAssertEqual(ask?.forced, true)
        XCTAssertTrue(ask?.detail?.contains("外部网页") == true)
        XCTAssertNil(otherChat.approval(for: ["command": "ls"]), "only the chat that read the web is marked")
        book.clear("bot-a")
        XCTAssertNil(shell.approval(for: ["command": "ls"]), "a new turn starts clean")
    }
}

final class RelayTests: XCTestCase {
    private let members = [(id: "1", name: "团子"), (id: "2", name: "小团子"), (id: "3", name: "阿青")]

    func testTrailingMentionHandsOn() {
        XCTAssertEqual(Relay.next(after: "我说完了。\n@阿青", from: "1", among: members), "3")
        XCTAssertEqual(Relay.next(after: "这个问题请 @小团子 来答", from: "1", among: members), "2")
        XCTAssertEqual(Relay.next(after: "交给＠团子。", from: "3", among: members), "1")
    }

    func testNoMentionOrSelfOrStranger() {
        XCTAssertNil(Relay.next(after: "就这样吧。", from: "1", among: members))
        XCTAssertNil(Relay.next(after: "@团子", from: "1", among: members), "nobody hands the word to itself")
        XCTAssertNil(Relay.next(after: "@路人甲", from: "1", among: members))
        XCTAssertNil(Relay.next(after: "@阿青 你看\n然后我们继续聊", from: "1", among: members), "only the last line counts")
    }
}
