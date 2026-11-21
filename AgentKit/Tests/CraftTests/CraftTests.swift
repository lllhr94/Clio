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

final class TurnsTests: XCTestCase {
    private struct Line: Said, Equatable {
        var id: String
        var role: Message.Role
        var text: String
        var isNote = false
        var speaker: String?
        var label: String?
    }

    private func user(_ id: String, _ text: String = "问") -> Line { Line(id: id, role: .user, text: text) }
    private func bot(_ id: String, _ text: String = "答", speaker: String? = nil) -> Line { Line(id: id, role: .assistant, text: text, speaker: speaker) }
    private func tool(_ id: String, _ label: String? = nil) -> Line { Line(id: id, role: .tool, text: "结果", label: label) }
    private func note(_ id: String, _ text: String = "（被你叫停了）") -> Line { Line(id: id, role: .assistant, text: text, isNote: true) }

    func testSizeLeavesNotesOut() {
        XCTAssertEqual(Turns.size([user("1", "abc"), note("n", "很长很长的提示"), bot("2", "de")]), 5)
    }

    func testRetryUndoesTheLastTurnOnly() {
        let lines = [user("u1"), bot("b1"), user("u2"), bot("b2a", ""), tool("t"), bot("b2"), note("n")]
        XCTAssertEqual(Turns.toUndo(lines), ["u2"])
        XCTAssertEqual(Turns.retried(lines)?.map(\.id), ["u1", "b1", "u2"])
    }

    func testRetryWithNothingSaid() {
        let lines = [note("n", "开场白"), bot("b")]
        XCTAssertNil(Turns.retried(lines))
        XCTAssertEqual(Turns.toUndo(lines), [])
    }

    func testANoteFromTheUserSideIsNotATurn() {
        let restored = Line(id: "r", role: .user, text: "把这轮改过的 1 个文件还原了。", isNote: true)
        let lines = [user("u1"), bot("b1"), restored]
        XCTAssertEqual(Turns.toUndo(lines), ["u1"])
        XCTAssertEqual(Turns.retried(lines)?.map(\.id), ["u1"])
    }

    func testEditKeepsWhatCameBeforeAndDropsWhatCameAfter() {
        let lines = [user("u1"), bot("b1"), user("u2"), bot("b2"), user("u3"), bot("b3")]
        XCTAssertEqual(Turns.toUndo(lines, from: "u2"), ["u2", "u3"])
        let edited = Turns.edited(lines, id: "u2") { line in
            var changed = line
            changed.text = "改过的问题"
            return changed
        }
        XCTAssertEqual(edited?.map(\.id), ["u1", "b1", "u2"])
        XCTAssertEqual(edited?.last?.text, "改过的问题")
        XCTAssertNil(Turns.edited(lines, id: "gone") { $0 })
        XCTAssertEqual(Turns.toUndo(lines, from: "gone"), [])
    }

    func testFoldCutsBeforeAUserMessageAndKeepsTheRecentPart() {
        var lines: [Line] = []
        for turn in 1...8 {
            lines.append(user("u\(turn)"))
            lines.append(bot("b\(turn)"))
        }
        // 16 real lines, keep 4: the cut lands on a user message with at least 4 lines after it.
        guard case .success(let cut) = Turns.foldCut(lines, keep: 4) else { return XCTFail("should fold") }
        XCTAssertEqual(lines[cut].role, .user)
        XCTAssertEqual(lines[cut].id, "u7")
        XCTAssertGreaterThanOrEqual(lines.count - cut, 4)
    }

    func testFoldSkipsToolLinesToFindATurnStart() {
        var lines: [Line] = []
        for turn in 1...6 {
            lines += [user("u\(turn)"), bot("c\(turn)", ""), tool("t\(turn)"), bot("b\(turn)")]
        }
        guard case .success(let cut) = Turns.foldCut(lines, keep: 5) else { return XCTFail("should fold") }
        // Earlier to the turn's start, so at least 5 real lines stay as they are.
        XCTAssertEqual(lines[cut].id, "u5")
        XCTAssertGreaterThanOrEqual(lines.count - cut, 5)
    }

    func testFoldKeepsAtLeastWhatTheSettingSays() {
        // The review's sample: keep 5, but a long last turn. Cutting later would have kept only 1 line.
        var lines: [Line] = []
        for turn in 1...4 { lines += [user("u\(turn)"), bot("b\(turn)")] }
        lines += [user("u5"), bot("c1", ""), tool("t1"), bot("c2", ""), tool("t2"), bot("b5")]
        guard case .success(let cut) = Turns.foldCut(lines, keep: 5) else { return XCTFail("should fold") }
        XCTAssertEqual(lines[cut].id, "u5")
        XCTAssertGreaterThanOrEqual(lines.count - cut, 5)
    }

    func testFitCutFoldsOnlyWhatTheDigestReads() {
        var lines: [Line] = []
        for turn in 1...6 { lines += [user("u\(turn)", String(repeating: "字", count: 30)), bot("b\(turn)", "好")] }
        // Folding up to u6 would be about 170 characters; with room for 80 the cut moves back to whole turns.
        let cut = Turns.fitCut(lines, cut: 10, name: { _ in "旅伴" }, label: { _ in nil }, limit: 80)
        XCTAssertEqual(lines[cut].role, .user)
        let written = Turns.transcript(lines[..<cut], name: { _ in "旅伴" }, label: { _ in nil }, limit: 80)
        XCTAssertLessThanOrEqual(written.text.count, 80)
        XCTAssertFalse(written.text.contains("太长"))
        XCTAssertEqual(written.folded, cut)
    }

    func testFoldRefusesShortConversations() {
        let lines = [user("u1"), bot("b1"), user("u2"), bot("b2"), note("n"), note("m")]
        XCTAssertEqual(Turns.foldCut(lines, keep: 4), .failure(.tooShort))
        XCTAssertEqual(Turns.FoldProblem.tooShort.words, "这段絮语还不长，用不着压缩。")
    }

    func testFoldNeedsAUserMessageToCutBefore() {
        // One question, then a long run of the companion working: nowhere to start a kept turn.
        var lines = [user("u1")]
        for step in 1...12 { lines += [bot("c\(step)", ""), tool("t\(step)")] }
        XCTAssertEqual(Turns.foldCut(lines, keep: 4), .failure(.noBreak))
    }

    func testTranscriptNamesSpeakersAndMentionsTools() {
        let lines = [user("u1", "周六去哪"), bot("c", ""), tool("t", "搜索：重庆天气"), tool("t2"), bot("b1", "磁器口", speaker: "x"), note("n"), bot("b2", "好")]
        let written = Turns.transcript(lines, name: { $0.speaker == "x" ? "团子" : "旅伴" }, label: \.label)
        XCTAssertEqual(written.text, "用户：周六去哪\n（用了工具：搜索：重庆天气）\n团子：磁器口\n旅伴：好")
        XCTAssertEqual(written.folded, 3)
    }

    func testTranscriptKeepsTheNewestPartWhenLong() {
        let lines = [user("u1", String(repeating: "旧", count: 50)), bot("b1", String(repeating: "新", count: 50))]
        let written = Turns.transcript(lines, name: { _ in "旅伴" }, label: { _ in nil }, limit: 20)
        XCTAssertTrue(written.text.hasPrefix("（下面这一段太长，只留了后半部分）……\n"))
        XCTAssertTrue(written.text.hasSuffix(String(repeating: "新", count: 20)))
        XCTAssertFalse(written.text.contains("旧"))
    }

    func testUnfoldBringsBackTheOriginalAndKeepsWhatWasSaidSince() {
        let original = [user("u1"), bot("b1"), user("u2"), bot("b2"), user("u3"), bot("b3")]
        let marker = note("m", "前情提要：较早的 4 条已压缩")
        let current = [marker, user("u3"), bot("b3"), user("u4"), bot("b4")]
        let back = Turns.unfolded(original: original, current: current, marker: "m")
        XCTAssertEqual(back.map(\.id), ["u1", "b1", "u2", "b2", "u3", "b3", "u4", "b4"])
    }
}

final class UsageTests: XCTestCase {
    func testEstimateWeighsChineseAboveLatin() {
        XCTAssertEqual(Tokens.estimate(""), 0)
        XCTAssertEqual(Tokens.estimate("你好世界你好世界你好"), 6, "ten Chinese characters, about six tokens")
        XCTAssertEqual(Tokens.estimate("hello world"), 4, "eleven other characters, 3.3 rounded up")
        XCTAssertEqual(Tokens.estimate("重庆 weather"), 4)
    }

    func testWindowsByModelName() {
        XCTAssertEqual(Tokens.window(for: "deepseek-v4-pro"), 1_048_576)
        XCTAssertEqual(Tokens.window(for: "deepseek-chat"), 1_048_576)
        XCTAssertEqual(Tokens.window(for: "claude-sonnet-4-5"), 200_000)
        XCTAssertEqual(Tokens.window(for: "gemini-2.5-pro"), 1_048_576)
        XCTAssertEqual(Tokens.window(for: "some-local-model"), 131_072)
    }

    func testShortNumbers() {
        XCTAssertEqual(Tokens.short(657), "657")
        XCTAssertEqual(Tokens.short(15_520), "15.5K")
        XCTAssertEqual(Tokens.short(262_144), "262K")
        XCTAssertEqual(Tokens.short(1_048_576), "1.05M")
    }

    func testSpendAddsUpAndRemembersTheLastRequest() {
        var spend = Spend()
        spend.add(input: 10_000, output: 300, cached: 0)
        spend.add(input: 12_000, output: 357, cached: 9_000)
        spend.add(input: 0, output: 20, cached: 0)
        XCTAssertEqual(spend.input, 22_000)
        XCTAssertEqual(spend.output, 677)
        XCTAssertEqual(spend.lastInput, 12_000, "an output-only report does not reset the last input")
        XCTAssertEqual(spend.cacheShare, 9_000.0 / 22_000.0, accuracy: 0.0001)
        XCTAssertEqual(Spend().cacheShare, 0)
    }

    func testBalanceSources() {
        XCTAssertEqual(Balance.source(baseURL: "https://api.deepseek.com")?.url.absoluteString, "https://api.deepseek.com/user/balance")
        XCTAssertEqual(Balance.source(baseURL: "https://api.deepseek.com/v1")?.topUp.absoluteString, "https://platform.deepseek.com/top_up")
        XCTAssertNotNil(Balance.source(baseURL: "https://openrouter.ai/api/v1"))
        XCTAssertNil(Balance.source(baseURL: "https://api.anthropic.com"))
        XCTAssertNil(Balance.source(baseURL: "https://"))
    }

    func testDeepSeekBalance() {
        let body = #"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"9.24","granted_balance":"0.00","topped_up_balance":"9.24"}]}"#
        let reading = Balance.parse(body, baseURL: "https://api.deepseek.com")
        XCTAssertEqual(reading?.amount, 9.24)
        XCTAssertEqual(reading?.shown, "¥9.24")
        XCTAssertEqual(reading?.detail, "充值 ¥9.24")
        XCTAssertNil(Balance.parse(#"{"error":"bad key"}"#, baseURL: "https://api.deepseek.com"))
    }

    func testMoonshotAndSiliconFlowBalance() {
        XCTAssertEqual(Balance.source(baseURL: "https://api.moonshot.cn/v1")?.url.absoluteString, "https://api.moonshot.cn/v1/users/me/balance")
        let moon = Balance.parse(#"{"code":0,"data":{"available_balance":49.58,"voucher_balance":46.58,"cash_balance":3},"status":true}"#, baseURL: "https://api.moonshot.cn/v1")
        XCTAssertEqual(moon?.shown, "¥49.58")
        XCTAssertEqual(moon?.detail, "现金 ¥3.00 · 代金券 ¥46.58")
        XCTAssertEqual(Balance.source(baseURL: "https://api.siliconflow.cn/v1")?.url.absoluteString, "https://api.siliconflow.cn/v1/user/info")
        let silicon = Balance.parse(#"{"code":20000,"data":{"balance":"0.88","chargeBalance":"88.00","totalBalance":"88.88"}}"#, baseURL: "https://api.siliconflow.cn/v1")
        XCTAssertEqual(silicon?.shown, "¥88.88")
        XCTAssertEqual(silicon?.detail, "充值 ¥88.00 · 赠送 ¥0.88")
    }

    func testOpenRouterBalance() {
        let reading = Balance.parse(#"{"data":{"total_credits":20,"total_usage":4.5}}"#, baseURL: "https://openrouter.ai/api/v1")
        XCTAssertEqual(reading?.amount, 15.5)
        XCTAssertEqual(reading?.shown, "$15.50")
    }
}

final class TideTests: XCTestCase {
    func testTheDayTurnsAtFiveInTheMorning() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let lateNight = calendar.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 2))!
        let morning = calendar.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 6))!
        XCTAssertEqual(Tide.day(of: lateNight, calendar: calendar), "2026-11-18")
        XCTAssertEqual(Tide.day(of: morning, calendar: calendar), "2026-11-19")
    }

    func testTheSameDayBringsTheSameThing() {
        XCTAssertEqual(Tide.find(on: "2026-11-18", seed: "a"), Tide.find(on: "2026-11-18", seed: "a"))
        let week = (10...16).map { Tide.find(on: "2026-11-\($0)", seed: "a").name }
        XCTAssertGreaterThan(Set(week).count, 1, "different days bring different things")
        XCTAssertEqual(Tide.find(on: "2027-01-01", seed: "a").name, "一页新日历")
    }

    func testDaysAfterTheLastVisit() {
        XCTAssertEqual(Tide.days(after: nil, through: "2026-11-18"), ["2026-11-18"])
        XCTAssertEqual(Tide.days(after: "2026-11-18", through: "2026-11-18"), [])
        XCTAssertEqual(Tide.days(after: "2026-11-29", through: "2026-12-02"), ["2026-11-30", "2026-12-01", "2026-12-02"])
    }

    func testAWeekWaitsAndTheRestIsPutAway() {
        let away = Tide.arrivals(after: "2026-11-01", through: "2026-11-11", seed: "a")
        XCTAssertEqual(away.waiting.map(\.day), (5...11).map { String(format: "2026-11-%02d", $0) })
        XCTAssertEqual(away.putAway.map(\.day), ["2026-11-02", "2026-11-03", "2026-11-04"])
        XCTAssertEqual(Tide.arrivals(after: "2026-11-10", through: "2026-11-11", seed: "a").waiting.count, 1)
    }
}

final class ModelTraitsTests: XCTestCase {
    func testDeepSeekFlashSeesAndProDoesNot() {
        XCTAssertTrue(ModelTraits.guess("deepseek-flash").sees)
        XCTAssertTrue(ModelTraits.guess("deepseek-v4-flash").sees, "the old Flash name leads to V4.1 Flash")
        XCTAssertFalse(ModelTraits.guess("deepseek-v4-pro").sees)
        XCTAssertFalse(ModelTraits.guess("deepseek-chat").sees)
        XCTAssertTrue(ModelTraits.guess("deepseek-flash").thinks)
        XCTAssertEqual(ModelTraits.guess("deepseek-flash").window, 1_048_576)
    }

    func testOtherFamilies() {
        XCTAssertTrue(ModelTraits.guess("claude-sonnet-4-5").sees)
        XCTAssertTrue(ModelTraits.guess("claude-sonnet-4-5").thinks)
        XCTAssertFalse(ModelTraits.guess("claude-3-5-haiku").thinks)
        XCTAssertTrue(ModelTraits.guess("gpt-5").sees)
        XCTAssertTrue(ModelTraits.guess("o4-mini").sees)
        XCTAssertFalse(ModelTraits.guess("o3-mini").sees)
        XCTAssertTrue(ModelTraits.guess("qwen-vl-max").sees)
        XCTAssertTrue(ModelTraits.guess("qwen3-vl-plus").sees)
        XCTAssertFalse(ModelTraits.guess("qwen-max").sees)
        XCTAssertTrue(ModelTraits.guess("glm-4.5v").sees)
        XCTAssertFalse(ModelTraits.guess("glm-5.3").sees)
        XCTAssertTrue(ModelTraits.guess("openai/gpt-5").sees, "the maker in front is ignored")
        XCTAssertTrue(ModelTraits.guess("google/gemini-2.5-flash").thinks)
        XCTAssertFalse(ModelTraits.guess("some-local-model").sees)
        XCTAssertTrue(ModelTraits.guess("some-local-model").tools)
    }

    func testListsDropModelsThatCannotChat() {
        let listed = ["gpt-5", "text-embedding-3-small", "tts-1", "whisper-1", "dall-e-3", "gpt-image-1", "omni-moderation-latest", "gpt-4o-realtime-preview", "BAAI/bge-m3", "Qwen/Qwen3-8B"]
        XCTAssertEqual(listed.filter(ModelTraits.isChat), ["gpt-5", "Qwen/Qwen3-8B"])
    }

    func testSummary() {
        XCTAssertEqual(ModelTraits(sees: true, thinks: true, window: 1_048_576).summary, "看图 · 思考 · 1M")
        XCTAssertEqual(ModelTraits(sees: false, window: 131_072).summary, "131K")
    }
}

final class ExplainPictureTests: XCTestCase {
    func testARefusedPictureSaysSo() {
        let advice = Explain.model(ProviderError(status: 400, "image_url is not supported by this model"), service: "某服务")
        XCTAssertEqual(advice.title, "这个模型好像不收图片")
        XCTAssertEqual(advice.next, .tuning)
    }
}

final class DocSearchTests: XCTestCase {
    func testFindsPassagesAndPages() {
        let manual = "[第 1 页]\n公司简介\n\n[第 2 页]\n报销的流程：先填单，再找主管签字，最后交财务。\n\n[第 3 页]\n请假要提前三天说。"
        let notes = "周末去重庆吃火锅。\n\n报销记得留发票。"
        let hits = DocSearch.find("报销流程", in: [("手册.pdf", manual), ("笔记.md", notes)])
        XCTAssertEqual(hits.first?.path, "手册.pdf")
        XCTAssertEqual(hits.first?.page, 2)
        XCTAssertTrue(hits.first?.snippet.contains("主管签字") == true)
        XCTAssertTrue(DocSearch.find("火锅 重庆", in: [("笔记.md", notes)]).first?.snippet.contains("火锅") == true)
        XCTAssertTrue(DocSearch.find("天气", in: [("笔记.md", notes)]).isEmpty)
    }

    func testTermsAndPairs() {
        XCTAssertEqual(DocSearch.terms("Swift，并发  swift"), ["swift", "并发"])
        XCTAssertEqual(DocSearch.pairs("报销流程"), ["报销", "销流", "流程"])
        XCTAssertEqual(DocSearch.pairs("ab"), [])
    }
}

final class RoutineTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    func testDueOnceTheTimeHasCome() {
        // 2026-11-16 is a Monday.
        let routine = Routine(botId: "b", title: "新闻", prompt: "整理新闻", hour: 8, minute: 30, created: date(15, 12).timeIntervalSince1970)
        XCTAssertNil(routine.due(now: date(16, 8, 0), calendar: calendar))
        let due = routine.due(now: date(16, 9, 0), calendar: calendar)
        XCTAssertEqual(due?.at, date(16, 8, 30))
        XCTAssertEqual(due?.missed, 0)
        var done = routine
        done.lastRun = date(16, 9, 0).timeIntervalSince1970
        XCTAssertNil(done.due(now: date(16, 20, 0), calendar: calendar))
        // Three days away: done once, two missed.
        XCTAssertEqual(done.due(now: date(19, 10, 0), calendar: calendar)?.missed, 2)
    }

    func testWeekdaysOnly() {
        let routine = Routine(botId: "b", title: "日报", prompt: "写日报", hour: 18, minute: 0, days: [1, 2, 3, 4, 5], created: date(13, 0).timeIntervalSince1970)
        // Saturday the 21st and Sunday the 22nd are skipped: Friday the 20th is the latest.
        XCTAssertEqual(routine.due(now: date(22, 20, 0), calendar: calendar)?.at, date(20, 18, 0))
        XCTAssertEqual(routine.next(after: date(20, 19, 0), calendar: calendar), date(23, 18, 0))
        XCTAssertEqual(routine.when, "工作日 18:00")
    }

    func testReadingDaysAndClocks() {
        XCTAssertEqual(Routine.days(from: "每天"), [])
        XCTAssertEqual(Routine.days(from: "工作日"), [1, 2, 3, 4, 5])
        XCTAssertEqual(Routine.days(from: "周一、周三、周五"), [1, 3, 5])
        XCTAssertEqual(Routine.days(from: "6,7"), [6, 7])
        XCTAssertEqual(Routine.clock("08:30")?.hour, 8)
        XCTAssertEqual(Routine.clock("8点半")?.minute, 30)
        XCTAssertEqual(Routine.clock("下午3点")?.hour, 15)
        XCTAssertNil(Routine.clock("明天"))
        XCTAssertEqual(Routine.weekday(7), 1)
        XCTAssertEqual(Routine.weekday(1), 2)
    }
}

final class SkillTests: XCTestCase {
    func testReadsTheBlockOnTop() {
        let skill = Skill.parse("---\nname: 周报\ndescription: \"写周报时用\"\n---\n\n# 周报\n先列做完的事。", fallback: "文件名")
        XCTAssertEqual(skill.name, "周报")
        XCTAssertEqual(skill.description, "写周报时用")
        XCTAssertEqual(skill.body, "# 周报\n先列做完的事。")
        XCTAssertEqual(Skill.parse(skill.text, fallback: "x"), skill, "what is written reads back the same")
    }

    func testWithoutTheBlock() {
        let skill = Skill.parse("# 记账\n\n把花销记进账本。\n每月底汇总。", fallback: "记账")
        XCTAssertEqual(skill.name, "记账")
        XCTAssertEqual(skill.description, "把花销记进账本。")
        XCTAssertTrue(Skill.menu([skill]).hasPrefix("- 记账：把花销记进账本。"))
    }
}
