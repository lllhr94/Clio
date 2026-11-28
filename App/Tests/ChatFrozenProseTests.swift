@testable import Clio
import UIKit
import XCTest

@MainActor
final class ChatFrozenProseTests: XCTestCase {
    func testTailUpdatesKeepFrozenTokenAndSealingPreservesRichText() throws {
        let builder = ChatProseBuilder()
        let style = ChatListStyle.current(traits: UITraitCollection(userInterfaceStyle: .light))
        let base = "段一 `内联`\n\n段二 *斜体*\n\n活动尾段"
        let frozen = try XCTUnwrap(firstProse(builder, base, style: style))
        let tailGrew = try XCTUnwrap(firstProse(builder, base + "延长", style: style))
        XCTAssertGreaterThan(frozen.frozenPrefixLength, 0)
        XCTAssertEqual(frozen.renderToken, tailGrew.renderToken)

        let advanced = base + "延长\n\n新的尾段"
        let expanded = try XCTUnwrap(firstProse(builder, advanced, style: style))
        let freshlyBuilt = try XCTUnwrap(firstProse(ChatProseBuilder(), advanced, style: style))
        XCTAssertNotEqual(frozen.renderToken, expanded.renderToken)
        XCTAssertGreaterThan(expanded.frozenPrefixLength, frozen.frozenPrefixLength)
        XCTAssertTrue(expanded.attributed.isEqual(to: freshlyBuilt.attributed))
        XCTAssertEqual(expanded.decorations, freshlyBuilt.decorations)
    }

    func testEqualByteCountReplacementInvalidatesSealedPrefix() throws {
        let builder = ChatProseBuilder()
        let style = ChatListStyle.current(traits: UITraitCollection(userInterfaceStyle: .light))
        let original = "旧文\n\n第二段\n\n尾段"
        let replacement = "新文\n\n第二段\n\n尾段"
        XCTAssertEqual(original.utf8.count, replacement.utf8.count)
        let old = try XCTUnwrap(firstProse(builder, original, style: style))
        let new = try XCTUnwrap(firstProse(builder, replacement, style: style))
        XCTAssertTrue(new.attributed.string.hasPrefix("新文"))
        XCTAssertNotEqual(old.renderToken, new.renderToken)
    }

    func testReusableTileBoundaryRequiresMatchingTextStyleAndGeometry() {
        let line = ChatFrozenTilePrefix.Line(range: NSRange(location: 0, length: 1),
                                              origin: CGPoint(x: 0, y: 120), ascent: 15, descent: 4, inkTop: 104)
        let prior = prefix("A", lines: [line], boundary: 750)
        let next = ChatFrozenTilePrefix.Line(range: NSRange(location: 1, length: 1),
                                              origin: CGPoint(x: 0, y: 730), ascent: 15, descent: 4, inkTop: 709)
        XCTAssertEqual(prefix("AB", lines: [line, next], boundary: 900).reusableBottom(comparedWith: prior, padding: 12), 697)
        XCTAssertEqual(prefix("XB", lines: [line, next], boundary: 900).reusableBottom(comparedWith: prior, padding: 12), 0)
        XCTAssertEqual(prefix("AB", lines: [line, next], boundary: 900, style: "dark").reusableBottom(comparedWith: prior, padding: 12), 0)
        XCTAssertEqual(prefix("AB", lines: [next], boundary: 900).reusableBottom(comparedWith: prior, padding: 12), 0)
    }

    func testOversizedSealedPrefixYieldsUnifiedRevealWhileTailRemainsEligible() {
        let cap = ChatRevealPolicy.maxTailAttributedLength
        XCTAssertTrue(ChatRevealPolicy.shouldUseUnifiedReveal(
            fade: true, reduceMotion: false, hasActiveSelection: false,
            sliceLengths: [cap, 400]
        ))
        XCTAssertFalse(ChatRevealPolicy.shouldUseUnifiedReveal(
            fade: true, reduceMotion: false, hasActiveSelection: false,
            sliceLengths: [cap + 1, 400]
        ))
        XCTAssertFalse(ChatRevealPolicy.shouldUseUnifiedReveal(
            fade: true, reduceMotion: false, hasActiveSelection: false,
            sliceLengths: [cap, cap, cap, 1]
        ))
        XCTAssertTrue(ChatRevealPolicy.isEligible(fade: true, reduceMotion: false, attributedLength: 400))
    }

    func testLiveOversizedSealedPrefixStaysOnTilesWithoutMountingTextView() {
        let style = ChatListStyle.current(traits: UITraitCollection(userInterfaceStyle: .light))
        let longText = String(repeating: "长回复正文", count: 2_000)
        let rendered = ChatRenderedProse(
            attributed: NSAttributedString(string: longText),
            decorations: .empty,
            topInset: 0,
            bottomInset: 2,
            renderToken: 42,
            hasLinks: false,
            liveTailIndex: nil,
            spacingAfter: nil,
            frozenPrefixLength: longText.utf16.count - 50
        )
        let view = ChatRichTextView(frame: CGRect(x: 0, y: 0, width: 320, height: 600))
        view.apply(
            ownerID: "streaming-long#rt0",
            rendered: rendered,
            style: style,
            isLive: true,
            isLiveTail: false,
            externalRevealControlled: false
        )
        XCTAssertFalse(view.subviews.contains { $0 is UITextView })
    }

    private func prefix(_ text: String, lines: [ChatFrozenTilePrefix.Line], boundary: CGFloat,
                        style: String = "light") -> ChatFrozenTilePrefix {
        ChatFrozenTilePrefix(text: NSAttributedString(string: text), decorations: .empty,
                             lines: lines, boundaryY: boundary, styleKey: style, width: 300, scale: 3)
    }

    private func firstProse(_ builder: ChatProseBuilder, _ text: String, style: ChatListStyle) -> ChatRenderedProse? {
        for slice in builder.buildAssistantSlices(text, style: style, isStreaming: true, streamKey: "streaming-test") {
            if case .richText(let prose) = slice { return prose }
        }
        return nil
    }
}
