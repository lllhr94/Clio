import XCTest
@testable import Prose

final class CodeTokenizerIncrementalTests: XCTestCase {
    private func joinedText(_ segments: [CodeTokenSegment]) -> String {
        segments.map(\.text).joined()
    }

    private func kinds(for tokenText: String, in segments: [CodeTokenSegment]) -> [CodeTokenKind] {
        segments.filter { $0.text.contains(tokenText) }.map(\.kind)
    }

    func testSupportsFifteenPlusLanguagesAndAliases() {
        XCTAssertGreaterThanOrEqual(IncrementalCodeTokenizer.supportedLanguages.count, 15)

        let samples: [(lang: String, code: String, keyword: String, funcName: String?, hasComment: Bool)] = [
            ("swift", "public func greet(_ name: String) -> Int {\n    // hi\n    return count(name) + 42\n}", "func", "count", true),
            ("py", "def run(x):\n    # note\n    return helper(x) + 1", "def", "helper", true),
            ("js", "const run = () => { /* note */ return fetchData(1) }", "const", "fetchData", true),
            ("tsx", "export interface Item { readonly id: number }\nconst v = makeItem(7)", "interface", "makeItem", false),
            ("rs", "pub fn calc<'a>(v: &'a str) -> usize { parse(v) }", "fn", "parse", false),
            ("golang", "func main() {\n    // go\n    fmt.Println(123)\n}", "func", "Println", true),
            ("c", "static int add(int a) { /* c */ return sum(a); }", "static", "sum", true),
            ("c++", "constexpr auto x = compute(3.14); // cpp", "constexpr", "compute", true),
            ("objc", "@interface Foo : NSObject\n@end", "@interface", nil, false),
            ("java", "public final class App { void run() { start(); } }", "final", "start", false),
            ("kt", "data class User(val id: Int) { fun go() = runTask(id) }", "fun", "runTask", false),
            ("cs", "public async Task Run() { await FetchAsync(); }", "async", "FetchAsync", false),
            ("rb", "def hello\n  # ruby\n  puts(1)\nend", "def", "puts", true),
            ("sh", "if true; then\n  # shell\n  echo \"ok\"\nfi", "then", nil, true),
            ("sql", "SELECT id FROM users WHERE active = true -- query", "SELECT", nil, true),
            ("json", "{ \"ok\": true, \"n\": 42 }", "true", nil, false),
            ("yml", "# yaml\nenabled: true\ncount: 10", "true", nil, true),
            ("toml", "# toml\nflag = false\nport = 8080", "false", nil, true),
            ("html", "<!-- comment -->\n<div class=\"card\">hi</div>", "div", nil, true),
            ("css", "/* style */\n.box { display: flex; color: #ff00aa; }", "flex", nil, true),
        ]

        for sample in samples {
            let result = IncrementalCodeTokenizer.tokenize(sample.code, language: sample.lang, isOutput: false)
            XCTAssertFalse(result.circuitBroken, "Unexpected circuit break for \(sample.lang)")
            XCTAssertEqual(joinedText(result.segments), sample.code, "Lossy round-trip for \(sample.lang)")
            XCTAssertTrue(
                result.segments.contains { $0.kind == .keyword && $0.text.contains(sample.keyword) },
                "Missing keyword '\(sample.keyword)' for \(sample.lang)"
            )
            if let fn = sample.funcName {
                XCTAssertTrue(
                    result.segments.contains { $0.kind == .function && $0.text.contains(fn) },
                    "Missing function '\(fn)' for \(sample.lang)"
                )
            }
            if sample.hasComment {
                XCTAssertTrue(
                    result.segments.contains { $0.kind == .comment },
                    "Missing comment token for \(sample.lang)"
                )
            }
        }
    }

    func testCrossLineBlockCommentsNestedAndTripleQuotedStrings() {
        // Swift nested /* /* */ */ block comment
        let swiftNested = """
        /* outer
           /* inner */
           still comment
        */
        let value = 1
        """
        var swiftTok = IncrementalCodeTokenizer(language: "swift")
        let swiftSegs = swiftTok.update(source: swiftNested)
        XCTAssertEqual(joinedText(swiftSegs), swiftNested)
        XCTAssertEqual(swiftTok.lines[0].endState, .blockComment(depth: 1))
        XCTAssertEqual(swiftTok.lines[1].endState, .blockComment(depth: 1))
        XCTAssertEqual(swiftTok.lines[2].endState, .blockComment(depth: 1))
        XCTAssertEqual(swiftTok.lines[3].endState, .normal)
        XCTAssertTrue(swiftTok.lines[2].segments.allSatisfy { $0.kind == .comment })
        XCTAssertTrue(swiftTok.lines[4].segments.contains { $0.kind == .keyword && $0.text == "let" })

        // Python triple-quoted string spanning lines with CJK & escaped quote
        let pythonTriple = """
        doc = \"\"\"第一行 \\\"引文\\\"
        def not_a_keyword():
            return 0
        \"\"\"
        def real_func():
            return 1
        """
        var pyTok = IncrementalCodeTokenizer(language: "python")
        let pySegs = pyTok.update(source: pythonTriple)
        XCTAssertEqual(joinedText(pySegs), pythonTriple)
        XCTAssertTrue(pyTok.hasWide)
        XCTAssertEqual(pyTok.lines[0].endState, .tripleQuote(delimiter: 0x22))
        XCTAssertTrue(pyTok.lines[1].segments.allSatisfy { $0.kind == .string })
        XCTAssertEqual(pyTok.lines[3].endState, .normal)
        XCTAssertTrue(pyTok.lines[4].segments.contains { $0.kind == .keyword && $0.text == "def" })

        // JS multi-line template literal
        let jsTemplate = """
        const msg = `hello
        const insideTemplate = 1
        `
        const after = 2
        """
        var jsTok = IncrementalCodeTokenizer(language: "javascript")
        let jsSegs = jsTok.update(source: jsTemplate)
        XCTAssertEqual(joinedText(jsSegs), jsTemplate)
        XCTAssertEqual(jsTok.lines[0].endState, .backtickString)
        XCTAssertTrue(jsTok.lines[1].segments.allSatisfy { $0.kind == .string })
        XCTAssertTrue(jsTok.lines[3].segments.contains { $0.kind == .keyword && $0.text == "const" })
    }

    func testIncrementalTailAppendOnlyRecomputesTrailingLines() {
        var sourceLines: [String] = []
        for i in 0..<120 {
            sourceLines.append("let item\(i) = compute(\(i)) // 中文注释 \(i)")
        }
        let baseSource = sourceLines.joined(separator: "\n")

        var incremental = IncrementalCodeTokenizer(language: "swift")
        let initialSegs = incremental.update(source: baseSource)
        XCTAssertEqual(incremental.lastRecomputedLineCount, 120)
        XCTAssertEqual(joinedText(initialSegs), baseSource)

        // Append one new line as streaming does.
        let grownSource = baseSource + "\nreturn compute(999)"
        let grownSegs = incremental.update(source: grownSource)
        // Line 119 gained '\n' and line 120 was appended -> at most 2 lines recomputed!
        XCTAssertLessThanOrEqual(incremental.lastRecomputedLineCount, 2)

        let fresh = IncrementalCodeTokenizer.tokenize(grownSource, language: "swift", isOutput: false)
        XCTAssertEqual(grownSegs, fresh.segments)
        XCTAssertEqual(incremental.hasWide, fresh.hasWide)

        // Updating with identical source recomputes 0 lines.
        let repeatSegs = incremental.update(source: grownSource)
        XCTAssertEqual(incremental.lastRecomputedLineCount, 0)
        XCTAssertEqual(repeatSegs, grownSegs)
    }

    func testIncrementalCrossLineStatePropagationMatchesFreshScan() {
        let openComment = """
        let a = 1
        /* start comment
        let b = 2
        let c = 3
        """
        var tok = IncrementalCodeTokenizer(language: "swift")
        _ = tok.update(source: openComment)
        XCTAssertTrue(tok.lines[2].segments.allSatisfy { $0.kind == .comment })
        XCTAssertTrue(tok.lines[3].segments.allSatisfy { $0.kind == .comment })

        // Close the comment on line 2 -> lines 3 & 4 must flip back to normal keywords/numbers.
        let closedComment = """
        let a = 1
        /* start comment */
        let b = 2
        let c = 3
        """
        let updated = tok.update(source: closedComment)
        let fresh = IncrementalCodeTokenizer.tokenize(closedComment, language: "swift", isOutput: false)
        XCTAssertEqual(updated, fresh.segments)
        XCTAssertTrue(tok.lines[2].segments.contains { $0.kind == .keyword && $0.text == "let" })
        XCTAssertTrue(tok.lines[3].segments.contains { $0.kind == .number && $0.text == "3" })
    }

    func testCircuitBreakersForOversizedLineAndOversizedBlock() {
        // Exactly 2,000 chars stays highlighted.
        let exact2000 = "let a = " + String(repeating: "1", count: 2_000 - 8)
        var exactTok = IncrementalCodeTokenizer(language: "swift")
        _ = exactTok.update(source: exact2000)
        XCTAssertFalse(exactTok.lines[0].circuitBroken)
        XCTAssertTrue(exactTok.lines[0].segments.contains { $0.kind == .keyword && $0.text == "let" })

        // 2,001 chars circuit-breaks that line to plain monospace without breaking the next line.
        let over2000 = "let a = " + String(repeating: "1", count: 2_001 - 8) + "\nreturn 42"
        var lineBrokenTok = IncrementalCodeTokenizer(language: "swift")
        let lineBrokenSegs = lineBrokenTok.update(source: over2000)
        XCTAssertEqual(joinedText(lineBrokenSegs), over2000)
        XCTAssertTrue(lineBrokenTok.lines[0].circuitBroken)
        XCTAssertTrue(lineBrokenTok.lines[0].segments.allSatisfy { $0.kind == .plain })
        XCTAssertFalse(lineBrokenTok.lines[1].circuitBroken)
        XCTAssertTrue(lineBrokenTok.lines[1].segments.contains { $0.kind == .keyword && $0.text == "return" })

        // 2,001 lines circuit-breaks the entire block cleanly to plain monospace.
        let hugeBlock = (0..<2_001).map { "let x\($0) = \($0)" }.joined(separator: "\n")
        var blockTok = IncrementalCodeTokenizer(language: "swift")
        let blockSegs = blockTok.update(source: hugeBlock)
        XCTAssertTrue(blockTok.circuitBrokenBlock)
        XCTAssertEqual(joinedText(blockSegs), hugeBlock)
        XCTAssertTrue(blockSegs.allSatisfy { $0.kind == .plain })
    }

    func testOutputBlockAndWideCharacterDetection() {
        XCTAssertTrue(IncrementalCodeTokenizer.isOutputBlock(language: "txt", text: "let a = 1"))
        XCTAssertTrue(IncrementalCodeTokenizer.isOutputBlock(language: "", text: "纯文本输出日志"))
        XCTAssertFalse(IncrementalCodeTokenizer.isOutputBlock(language: "", text: "func main() { return 1 }"))

        let res = IncrementalCodeTokenizer.tokenize("ok 中文 123", language: "log", isOutput: true)
        XCTAssertTrue(res.hasWide)
        XCTAssertTrue(res.segments.allSatisfy { $0.kind == .plain })
        XCTAssertTrue(res.segments.contains { $0.isWide && $0.text == "中文" })
    }

    func testIncrementalStreamingPerformanceSanity() {
        var tok = IncrementalCodeTokenizer(language: "swift")
        var buf = ""
        let start = CFAbsoluteTimeGetCurrent()
        for i in 0..<200 {
            if i > 0 { buf += "\n" }
            buf += "func step\(i)(_ x: Int) -> Int { return x + \(i) }"
            _ = tok.update(source: buf)
        }
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
        // Generous CI ceiling while confirming incremental O(1)-tail behavior (200 appends should take single-digit ms).
        XCTAssertLessThan(elapsedMs, 500.0, "200 incremental tail appends took \(elapsedMs)ms")
    }
}
