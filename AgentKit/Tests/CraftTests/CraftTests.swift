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
        XCTAssertTrue(change.text.contains("……还有 90 行"))
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

/// A host kept in memory: files in a dictionary, and a shell that only echoes.
private final class FakeHost: WorkHost, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data] = [:]
    var title: String { "假主机" }
    var prefix: String { "fake" }
    var home: String { "/" }
    var canRun: Bool { true }

    init(_ files: [String: String] = [:]) {
        self.files = files.mapValues { Data($0.utf8) }
    }

    func run(_ command: String, timeout: Double) async throws -> (code: Int, output: String) { (0, command) }

    func read(_ path: String) async throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let data = files[path] else { throw ProviderError("没有这个文件：\(path)") }
        return data
    }

    func write(_ path: String, _ data: Data) async throws {
        lock.lock(); defer { lock.unlock() }
        files[path] = data
    }

    func text(_ path: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return files[path].flatMap { String(data: $0, encoding: .utf8) }
    }
}

final class HostFilesTests: XCTestCase {
    func testWriteNewThenOverwrite() async {
        let host = FakeHost()
        let first = await HostFiles.write(host, "a.md", "一\n二")
        XCTAssertFalse(first.isError)
        XCTAssertTrue(first.text.hasPrefix("新建了 a.md"))
        XCTAssertTrue(first.text.contains("2 行"))
        let second = await HostFiles.write(host, "a.md", "一\n三")
        XCTAssertEqual(Diff.counts(in: second.text)?.removed, 1)
        XCTAssertEqual(Diff.counts(in: second.text)?.added, 1)
        XCTAssertEqual(host.text("a.md"), "一\n三")
        let same = await HostFiles.write(host, "a.md", "一\n三")
        XCTAssertTrue(same.text.contains("没变"))
    }

    func testEditOnce() async {
        let host = FakeHost(["n.txt": "苹果\n香蕉\n苹果派"])
        let missing = await HostFiles.edit(host, "n.txt", old: "西瓜", new: "x")
        XCTAssertTrue(missing.isError)
        XCTAssertTrue(missing.text.contains("fake_read"))
        let many = await HostFiles.edit(host, "n.txt", old: "苹果", new: "梨")
        XCTAssertTrue(many.isError)
        XCTAssertTrue(many.text.contains("2 次"))
        let empty = await HostFiles.edit(host, "n.txt", old: "", new: "梨")
        XCTAssertTrue(empty.isError)
        let done = await HostFiles.edit(host, "n.txt", old: "香蕉", new: "橘子")
        XCTAssertFalse(done.isError)
        XCTAssertEqual(host.text("n.txt"), "苹果\n橘子\n苹果派")
        XCTAssertEqual(Diff.hunk(in: done.text)?.contains("- 香蕉"), true)
        XCTAssertEqual(Diff.hunk(in: done.text)?.contains("+ 橘子"), true)
    }

    func testReadRanges() async {
        let host = FakeHost(["l.txt": (1...10).map { "第\($0)行" }.joined(separator: "\n")])
        let part = await HostFiles.read(host, "l.txt", from: 3, lines: 2)
        XCTAssertEqual(part.text, "3\t第3行\n4\t第4行\n……共 10 行，后面还有。")
        let tail = await HostFiles.read(host, "l.txt", from: 9, lines: 5)
        XCTAssertEqual(tail.text, "9\t第9行\n10\t第10行")
        let past = await HostFiles.read(host, "l.txt", from: 30, lines: 5)
        XCTAssertTrue(past.isError)
        let none = await HostFiles.read(host, "nope.txt")
        XCTAssertTrue(none.isError)
        XCTAssertTrue(none.text.contains("没有这个文件"))
    }

    func testBinaryIsNotRead() async throws {
        let host = FakeHost()
        try await host.write("x.bin", Data([0xFF, 0xFE, 0x00, 0xC3]))
        let output = await HostFiles.read(host, "x.bin", notText: "试试别的。")
        XCTAssertTrue(output.isError)
        XCTAssertTrue(output.text.hasSuffix("试试别的。"))
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
    }
}
