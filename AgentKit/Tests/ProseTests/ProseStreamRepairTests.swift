import Prose
import XCTest

final class ProseStreamRepairTests: XCTestCase {
    // MARK: - Handoff Spec Vectors (PSR-01 .. PSR-12) + 3 Requested Tweaks

    func testCurrencyValuesNeverTriggerFalseInlineMath() {
        let r1 = ProseStreamRepairCore.repair("这套方案的月度预算大概是 $100 左右，性价比很高")
        XCTAssertEqual(r1, ProseRepairOutput(repaired: "这套方案的月度预算大概是 $100 左右，性价比很高", withheldSuffix: "", appliedClosers: []))

        let r2 = ProseStreamRepairCore.repair("当前报价为 $1,299.99")
        XCTAssertEqual(r2, ProseRepairOutput(repaired: "当前报价为 $1,299.99", withheldSuffix: "", appliedClosers: []))

        let r3 = ProseStreamRepairCore.repair("Total cost is $100 + $20 shipping")
        XCTAssertEqual(r3, ProseRepairOutput(repaired: "Total cost is $100 + $20 shipping", withheldSuffix: "", appliedClosers: []))
    }

    func testUnclosedInlineAndDisplayMathRepairAndCodeFenceDollarShielding() {
        let r4 = ProseStreamRepairCore.repair("线性函数 $2x + 1")
        XCTAssertEqual(r4, ProseRepairOutput(repaired: "线性函数 $2x + 1$", withheldSuffix: "", appliedClosers: ["$"]))

        let r5 = ProseStreamRepairCore.repair("角度满足 $\\alpha + \\beta")
        XCTAssertEqual(r5, ProseRepairOutput(repaired: "角度满足 $\\alpha + \\beta$", withheldSuffix: "", appliedClosers: ["$"]))

        let r6 = ProseStreamRepairCore.repair("```bash\necho $$\n```\n\n下面是推导：\n$$\nE = mc^2")
        XCTAssertEqual(r6, ProseRepairOutput(repaired: "```bash\necho $$\n```\n\n下面是推导：\n$$\nE = mc^2$$", withheldSuffix: "", appliedClosers: ["$$"]))
    }

    func testTripleStarAndCrossNestedEmphasisUnwinding() {
        let r7 = ProseStreamRepairCore.repair("重点关注 ***核心路径延迟")
        XCTAssertEqual(r7, ProseRepairOutput(repaired: "重点关注 ***核心路径延迟***", withheldSuffix: "", appliedClosers: ["***"]))

        let r8 = ProseStreamRepairCore.repair("重点 ***粗斜* 继续粗体")
        XCTAssertEqual(r8, ProseRepairOutput(repaired: "重点 ***粗斜* 继续粗体**", withheldSuffix: "", appliedClosers: ["**"]))

        let r8b = ProseStreamRepairCore.repair("重点 ***粗斜** 继续斜体")
        XCTAssertEqual(r8b, ProseRepairOutput(repaired: "重点 ***粗斜** 继续斜体*", withheldSuffix: "", appliedClosers: ["*"]))

        let r9 = ProseStreamRepairCore.repair("测试 **外层 *内层** 正常结尾")
        XCTAssertEqual(r9, ProseRepairOutput(repaired: "测试 **外层 *内层** 正常结尾", withheldSuffix: "", appliedClosers: []))

        let r9b = ProseStreamRepairCore.repair("测试 *外层 **内层* 正常结尾")
        XCTAssertEqual(r9b, ProseRepairOutput(repaired: "测试 *外层 **内层* 正常结尾", withheldSuffix: "", appliedClosers: []))

        let r10 = ProseStreamRepairCore.repair("Hello **")
        XCTAssertEqual(r10, ProseRepairOutput(repaired: "Hello ", withheldSuffix: "**", appliedClosers: []))
    }

    func testFencedCodeBlocksAndUnnewlinedFenceHeaderWithhold() {
        // PSR-12: open fenced code block with body closes cleanly ignoring inner `$` and `*`.
        let r12 = ProseStreamRepairCore.repair("```swift\nlet price = \"$100 * 2\"")
        XCTAssertEqual(r12, ProseRepairOutput(repaired: "```swift\nlet price = \"$100 * 2\"\n```", withheldSuffix: "", appliedClosers: ["\n```"]))

        // Tweak 1a: un-newlined opening fence header (` ```swi `) is withheld so raw backticks never flash.
        let unnewlined = ProseStreamRepairCore.repair("示例：\n```swi")
        XCTAssertEqual(unnewlined, ProseRepairOutput(repaired: "示例：", withheldSuffix: "\n```swi", appliedClosers: []))

        let bareFence = ProseStreamRepairCore.repair("```swift")
        XCTAssertEqual(bareFence, ProseRepairOutput(repaired: "", withheldSuffix: "```swift", appliedClosers: []))
    }

    func testIncompleteTableHeaderAndSeparatorHolding() {
        // Tweak 1b: withhold unfinished table header row before delimiter arrives.
        let headerOnly = ProseStreamRepairCore.repair("对比如下：\n| 指标 | 数值 |")
        XCTAssertEqual(headerOnly, ProseRepairOutput(repaired: "对比如下：", withheldSuffix: "\n| 指标 | 数值 |", appliedClosers: []))

        // Incomplete separator row holds back both header & partial separator so bare pipes never flash.
        let partialSep = ProseStreamRepairCore.repair("| 指标 | 数值 |\n| :--- | :")
        XCTAssertEqual(partialSep, ProseRepairOutput(repaired: "", withheldSuffix: "| 指标 | 数值 |\n| :--- | :", appliedClosers: []))

        // Once delimiter commits and body row is complete, table passes through cleanly.
        let completeTable = ProseStreamRepairCore.repair("| 指标 | 数值 |\n| :--- | ---: |\n| 延迟 | 8ms |")
        XCTAssertEqual(completeTable.repaired, "| 指标 | 数值 |\n| :--- | ---: |\n| 延迟 | 8ms |")
        XCTAssertEqual(completeTable.withheldSuffix, "")

        // Half-written body row holds back only the trailing body line while keeping committed table rows.
        let partialBody = ProseStreamRepairCore.repair("| 指标 | 数值 |\n| :--- | ---: |\n| 延迟 | 8ms |\n| 内存 | 42")
        XCTAssertEqual(partialBody.repaired, "| 指标 | 数值 |\n| :--- | ---: |\n| 延迟 | 8ms |")
        XCTAssertEqual(partialBody.withheldSuffix, "\n| 内存 | 42")
    }

    func testIncompleteLinksImagesAndUnderscoresInURLs() {
        // Tweak 1c: incomplete link `[label](url` renders cleanly as `[label](#)` without flashing partial URL.
        let partialLink = ProseStreamRepairCore.repair("看[官网](https://example.com/a_b")
        XCTAssertEqual(partialLink.repaired, "看[官网](#)")
        XCTAssertEqual(partialLink.withheldSuffix, "https://example.com/a_b")

        // Complete link with underscores in URL never corrupts emphasis stack.
        let fullLink = ProseStreamRepairCore.repair("参考 [文档](https://example.com/foo_bar_baz) 继续")
        XCTAssertEqual(fullLink, ProseRepairOutput(repaired: "参考 [文档](https://example.com/foo_bar_baz) 继续", withheldSuffix: "", appliedClosers: []))

        // Incomplete image `![alt` or `![alt](url` is held back cleanly.
        let partialImg = ProseStreamRepairCore.repair("图示：![架构图](https://cdn.exa")
        XCTAssertEqual(partialImg.repaired, "图示：")
        XCTAssertEqual(partialImg.withheldSuffix, "![架构图](https://cdn.exa")

        // Bare unclosed `[label` strips `[` into withheldSuffix while streaming words naturally.
        let bareBracket = ProseStreamRepairCore.repair("请看[说明文字")
        XCTAssertEqual(bareBracket.repaired, "请看说明文字")
        XCTAssertEqual(bareBracket.withheldSuffix, "[")
    }

    // MARK: - TableWaterfillSolver Vectors (TBL-01 .. TBL-03)

    func testTableWaterfillSolverMatchesVerifiedVectors() {
        // TBL-01: fits naturally
        let tbl1 = TableWaterfillSolver.allocate(
            availableWidth: 360.0,
            minFloor: 60.0,
            maxShare: 0.5,
            columns: [
                ColumnWidthMetric(minTokenWidth: 48.0, naturalWidth: 80.0),
                ColumnWidthMetric(minTokenWidth: 64.0, naturalWidth: 140.0),
            ]
        )
        XCTAssertEqual(tbl1, [80.0, 140.0])

        // TBL-02: waterfill protects narrow unbreakable token floor
        let tbl2 = TableWaterfillSolver.allocate(
            availableWidth: 320.0,
            minFloor: 60.0,
            maxShare: 0.65,
            columns: [
                ColumnWidthMetric(minTokenWidth: 92.0, naturalWidth: 100.0),
                ColumnWidthMetric(minTokenWidth: 60.0, naturalWidth: 90.0),
                ColumnWidthMetric(minTokenWidth: 65.0, naturalWidth: 340.0),
            ]
        )
        XCTAssertEqual(tbl2.count, 3)
        XCTAssertEqual(tbl2[0], 100.0, accuracy: 0.1)
        XCTAssertEqual(tbl2[1], 90.0, accuracy: 0.1)
        XCTAssertEqual(tbl2[2], 130.0, accuracy: 0.1)

        // TBL-03: unbreakable floors exceed viewport -> return floor array to trigger horizontal scroll
        let tbl3 = TableWaterfillSolver.allocate(
            availableWidth: 240.0,
            minFloor: 60.0,
            maxShare: 0.5,
            columns: [
                ColumnWidthMetric(minTokenWidth: 110.0, naturalWidth: 150.0),
                ColumnWidthMetric(minTokenWidth: 95.0, naturalWidth: 140.0),
                ColumnWidthMetric(minTokenWidth: 105.0, naturalWidth: 160.0),
            ]
        )
        XCTAssertEqual(tbl3, [110.0, 95.0, 105.0])
    }
}
