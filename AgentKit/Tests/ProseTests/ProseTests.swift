import XCTest
@testable import Prose

final class ProseTests: XCTestCase {
    func testParagraphsAndHeadings() {
        XCTAssertEqual(Prose.parse("# 标题\n\n第一段\n接着一行\n\n第二段"), [
            .heading(level: 1, text: "标题"),
            .paragraph("第一段\n接着一行"),
            .paragraph("第二段"),
        ])
        XCTAssertEqual(Prose.parse("#没有空格"), [.paragraph("#没有空格")])
    }

    func testLists() {
        XCTAssertEqual(Prose.parse("- 一\n- 二\n  - 二点一\n\n- 三"), [.list([
            Prose.Item(depth: 0, number: nil, checked: nil, text: "一"),
            Prose.Item(depth: 0, number: nil, checked: nil, text: "二"),
            Prose.Item(depth: 1, number: nil, checked: nil, text: "二点一"),
            Prose.Item(depth: 0, number: nil, checked: nil, text: "三"),
        ])])
        XCTAssertEqual(Prose.parse("1. 甲\n2) 乙\n- [x] 做完\n- [ ] 没做"), [.list([
            Prose.Item(depth: 0, number: 1, checked: nil, text: "甲"),
            Prose.Item(depth: 0, number: 2, checked: nil, text: "乙"),
            Prose.Item(depth: 0, number: nil, checked: true, text: "做完"),
            Prose.Item(depth: 0, number: nil, checked: false, text: "没做"),
        ])])
        XCTAssertEqual(Prose.parse("-不是列表"), [.paragraph("-不是列表")])
    }

    func testCode() {
        XCTAssertEqual(Prose.parse("```python\nprint(1)\n```\n后面"), [
            .code(language: "python", text: "print(1)", closed: true),
            .paragraph("后面"),
        ])
        // Still streaming: the closing fence has not come yet.
        XCTAssertEqual(Prose.parse("看：\n```js\nlet a = 1\nlet b"), [
            .paragraph("看："),
            .code(language: "js", text: "let a = 1\nlet b", closed: false),
        ])
    }

    func testTable() {
        let blocks = Prose.parse("| 时段 | 气温 |\n| :-- | --: |\n| 上午 | 14° |\n| 午后 |\n\n完")
        XCTAssertEqual(blocks, [
            .table(Prose.Table(header: ["时段", "气温"], aligns: [.leading, .trailing], rows: [["上午", "14°"], ["午后", ""]])),
            .paragraph("完"),
        ])
        // Without its separator line it is not a table yet.
        XCTAssertEqual(Prose.parse("| 时段 | 气温 |"), [.paragraph("| 时段 | 气温 |")])
    }

    func testQuoteRuleAndMath() {
        XCTAssertEqual(Prose.parse("> 引一句\n> - 还有列表\n\n---\n\n$$\nE = mc^2\n$$"), [
            .quote([.paragraph("引一句"), .list([Prose.Item(depth: 0, number: nil, checked: nil, text: "还有列表")])]),
            .rule,
            .math("E = mc^2"),
        ])
        XCTAssertEqual(Prose.parse("$$a+b$$"), [.math("a+b")])
    }

    func testEscapedPipeInCell() {
        XCTAssertEqual(Prose.parse("a | b\n---|---\nx \\| y | z"), [
            .table(Prose.Table(header: ["a", "b"], aligns: [.leading, .leading], rows: [["x | y", "z"]])),
        ])
    }
}

final class MendTests: XCTestCase {
    func testOpenMarksAreClosed() {
        XCTAssertEqual(Prose.mend("这是**重"), "这是**重**")
        XCTAssertEqual(Prose.mend("这是**重点**和*斜"), "这是**重点**和*斜*")
        XCTAssertEqual(Prose.mend("用 `ls -l"), "用 `ls -l`")
        XCTAssertEqual(Prose.mend("删~~掉"), "删~~掉~~")
        XCTAssertEqual(Prose.mend("这是**"), "这是")
        XCTAssertEqual(Prose.mend("完整的**粗体**"), "完整的**粗体**")
    }

    func testHalfThingsWait() {
        XCTAssertEqual(Prose.mend("第一行\n#"), "第一行")
        XCTAssertEqual(Prose.mend("第一行\n- "), "第一行")
        XCTAssertEqual(Prose.mend("第一行\n12."), "第一行")
        XCTAssertEqual(Prose.mend("看[官网](https://exa"), "看[官网](#)")
        XCTAssertEqual(Prose.mend("图![示意"), "图")
        XCTAssertEqual(Prose.mend("| 名字 | 价"), "")
        XCTAssertEqual(Prose.mend("代码\n```sw"), "代码")
        XCTAssertEqual(Prose.mend("```swift\nlet a = \"**\""), "```swift\nlet a = \"**\"")
    }
}
