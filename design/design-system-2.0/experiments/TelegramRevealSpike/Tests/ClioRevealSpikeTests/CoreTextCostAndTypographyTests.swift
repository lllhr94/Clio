import CoreGraphics
import CoreText
import Foundation
import XCTest
@testable import ClioRevealSpike

final class CoreTextCostAndTypographyTests: XCTestCase {
    func testRealBundledFontsLoadViaCoreTextAndMatchPostScriptNames() throws {
        guard let root = ClioFontLoader.locateRepoRoot() else {
            XCTFail("Could not locate Clio repo root containing App/Fonts/ClioKai-Medium.ttf")
            return
        }
        let kai = ClioFontLoader.loadBundledFont(named: "ClioKai-Medium.ttf", size: 17.0, repoRoot: root)
        XCTAssertNotNil(kai, "ClioKai-Medium.ttf must load via CTFontManagerCreateFontDescriptorsFromURL")
        if let kai {
            let psName = CTFontCopyPostScriptName(kai) as String
            XCTAssertEqual(psName, "ClioKai-Medium")
        }

        let mapleWithCN = ClioFontLoader.loadMapleWithChinese(size: 14.0, bold: false, repoRoot: root)
        XCTAssertNotNil(mapleWithCN, "MapleMono + ClioMonoCN cascade font must construct via CoreText")
        if let mapleWithCN {
            XCTAssertEqual(CTFontCopyPostScriptName(mapleWithCN) as String, "MapleMono-Regular")
        }
    }

    func testSafeLineBoxEnforcesZeroLineSpacingZeroMaxLineHeightAndUnifiedMetrics() {
        let kai = ClioFontLoader.loadBundledFont(named: "ClioKai-Medium.ttf", size: 17.0)
            ?? ClioFontLoader.systemReadingFont(size: 17.0)
        let system = ClioFontLoader.systemReadingFont(size: 17.0)

        let kaiMetrics = SafeLineBox.resolve(
            userReadingSize: 17.0,
            contentMultiplier: 1.65,
            fontForNaturalBox: kai,
            profile: .clioKaiMedium
        )
        let sysMetrics = SafeLineBox.resolve(
            userReadingSize: 17.0,
            contentMultiplier: 1.65,
            fontForNaturalBox: system,
            profile: .systemProse
        )

        // Half-point optical snap for ClioKai-Medium: 17 * 1.045 = 17.765 -> 18.0pt
        XCTAssertEqual(kaiMetrics.effectivePointSize, 18.0, accuracy: 0.001)
        XCTAssertEqual(kaiMetrics.lineSpacing, 0.0, accuracy: 0.001)
        XCTAssertEqual(kaiMetrics.maximumLineHeight, 0.0, accuracy: 0.001)
        XCTAssertEqual(kaiMetrics.fallbackSafePaddingApplied, 0.0, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(kaiMetrics.minimumLineHeight, kaiMetrics.naturalBoxHeight)

        let paraStyle = kaiMetrics.makeParagraphStyle(paragraphSpacing: 13.0)
        XCTAssertEqual(paraStyle.lineSpacing, 0.0, accuracy: 0.001)
        XCTAssertEqual(paraStyle.maximumLineHeight, 0.0, accuracy: 0.001)
        XCTAssertEqual(paraStyle.minimumLineHeight, kaiMetrics.minimumLineHeight, accuracy: 0.001)

        // User bubble and AI prose call the exact same resolver -> identical metric contract.
        let userBubbleMetrics = SafeLineBox.resolve(
            userReadingSize: 17.0,
            contentMultiplier: 1.65,
            fontForNaturalBox: system,
            profile: .systemProse
        )
        XCTAssertEqual(sysMetrics, userBubbleMetrics)
    }

    func testMixedScriptKerningNeverDoublesExistingSpaces() {
        let font = ClioFontLoader.systemReadingFont(size: 17.0)
        let fontAttr = NSAttributedString.Key(kCTFontAttributeName as String)

        let tight = NSMutableAttributedString(string: "使用Swift与Rust2026版", attributes: [fontAttr: font])
        ClioMixedScriptKerning.apply(to: tight, fontSize: 17.0)

        var kernBoundaryChars = 0
        tight.enumerateAttribute(.kern, in: NSRange(location: 0, length: tight.length)) { val, range, _ in
            if let num = val as? NSNumber, num.doubleValue > 0 {
                // enumerateAttribute merges adjacent equal attributes (e.g. "t" and "与" in "Swift与Rust"),
                // so sum range.length to count every kerned boundary character accurately.
                kernBoundaryChars += range.length
            }
        }
        // Boundaries in "使用Swift与Rust2026版": 用|S, t|与, 与|R, 6|版 -> 4 boundaries.
        XCTAssertEqual(kernBoundaryChars, 4, "Every direct CJK<->Latin/Digit boundary must receive optical kern")

        // When source already contains spaces (halfwidth or fullwidth), zero additional kern may be added.
        let spaced = NSMutableAttributedString(string: "使用 Swift 与 Rust 2026 版\u{3000}Test", attributes: [fontAttr: font])
        ClioMixedScriptKerning.apply(to: spaced, fontSize: 17.0)

        var spacedKernCount = 0
        spaced.enumerateAttribute(.kern, in: NSRange(location: 0, length: spaced.length)) { val, _, _ in
            if val != nil {
                spacedKernCount += 1
            }
        }
        XCTAssertEqual(spacedKernCount, 0, "Existing literal whitespace must strictly prevent extra CJK-Latin kerning")
    }

    func testExhaustivePointsBudgetRespectsCJKZWJEmojiLigaturesAndCombiningMarks() {
        let complexSample = "中文排版与fi/fl连字测试 👨‍👩‍👧‍👦 👍🏽 cafe\u{0301} 𠮷野家 `let x = y` | col1 | col2 | $$\\sum_{i=1}^n x_i$$"
        let kai = ClioFontLoader.loadBundledFont(named: "ClioKai-Medium.ttf", size: 17.0)
            ?? ClioFontLoader.systemReadingFont(size: 17.0)
        let metrics = SafeLineBox.resolve(userReadingSize: 17.0, contentMultiplier: 1.65, fontForNaturalBox: kai, profile: .clioKaiMedium)
        let attributed = NSMutableAttributedString(
            string: complexSample,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): kai,
                .paragraphStyle: metrics.makeParagraphStyle(),
            ]
        )
        ClioMixedScriptKerning.apply(to: attributed, fontSize: metrics.effectivePointSize)

        let layout = CoreTextRevealMeasurer.layoutText(attributed, maxWidth: 280.0)
        let costMap = SpikeRevealCostMap.buildSingleTextDocument(
            lines: layout.lines,
            atomicUnits: layout.atomicUnits,
            contentSize: layout.contentSize,
            utf16Length: attributed.length
        )

        XCTAssertGreaterThan(costMap.totalPoints, 100)
        XCTAssertGreaterThan(layout.lines.count, 1)

        // Collect all valid extended grapheme cluster UTF-16 end boundaries (plus 0).
        let ns = complexSample as NSString
        var validBoundaries = Set<Int>([0, ns.length])
        for idx in complexSample.indices {
            let next = complexSample.index(after: idx)
            let range = NSRange(idx..<next, in: complexSample)
            validBoundaries.insert(range.location)
            validBoundaries.insert(range.location + range.length)
        }

        // Explicitly compute ZWJ family emoji & "fi" range so we verify they are NEVER split.
        let zwjRange = ns.range(of: "👨‍👩‍👧‍👦")
        let skinRange = ns.range(of: "👍🏽")
        let combiningRange = ns.range(of: "e\u{0301}")
        let astralRange = ns.range(of: "𠮷")
        XCTAssertGreaterThan(zwjRange.length, 4)
        XCTAssertGreaterThan(skinRange.length, 2)
        XCTAssertEqual(combiningRange.length, 2)
        XCTAssertEqual(astralRange.length, 2)

        var previousCount = 0
        for budget in 0...costMap.totalPoints {
            let count = costMap.charCountForWidthBudget(budget)
            XCTAssertGreaterThanOrEqual(count, previousCount)
            XCTAssertLessThanOrEqual(count, ns.length)
            XCTAssertTrue(
                validBoundaries.contains(count),
                "Width budget \(budget) cut inside a grapheme/surrogate cluster at UTF-16 offset \(count)"
            )
            // Must never stop strictly inside ZWJ, skin-tone, combining mark, or surrogate pair.
            XCTAssertFalse(count > zwjRange.location && count < zwjRange.location + zwjRange.length)
            XCTAssertFalse(count > skinRange.location && count < skinRange.location + skinRange.length)
            XCTAssertFalse(count > combiningRange.location && count < combiningRange.location + combiningRange.length)
            XCTAssertFalse(count > astralRange.location && count < astralRange.location + astralRange.length)
            previousCount = count
        }

        XCTAssertEqual(costMap.charCountForWidthBudget(costMap.totalPoints), ns.length)
    }
}
