import AgentKit
import CoreText
import Craft
import Foundation
import Prose
import SwiftMath
import SwiftUI
import UIKit

struct ChatBlockDecorations: Equatable {
    let inlineCodeRanges: [NSRange]
    let quoteBlocks: [NSRange]
    let ruleRanges: [NSRange]

    var hasAny: Bool {
        !inlineCodeRanges.isEmpty || !quoteBlocks.isEmpty || !ruleRanges.isEmpty
    }

    static let empty = ChatBlockDecorations(
        inlineCodeRanges: [],
        quoteBlocks: [],
        ruleRanges: []
    )
}

struct ChatRenderedProse {
    let attributed: NSAttributedString
    let decorations: ChatBlockDecorations
    let topInset: CGFloat
    let bottomInset: CGFloat
    let renderToken: UInt64
    let hasLinks: Bool

    var isEmpty: Bool { attributed.length == 0 }

    static let empty = ChatRenderedProse(
        attributed: NSAttributedString(),
        decorations: .empty,
        topInset: 0,
        bottomInset: 0,
        renderToken: 0,
        hasLinks: false
    )
}

struct ChatCodeSlice {
    let language: String
    let rawText: String
    let trimmedText: String
    let isOutput: Bool
    let isLive: Bool
    let lineCount: Int
    let folds: Bool
    let foldedAttributed: NSAttributedString
    let fullAttributed: NSAttributedString?
    let foldedContentSize: CGSize
    let fullContentSize: CGSize?
    let foldedRenderToken: UInt64
    let fullRenderToken: UInt64?

    func resolved(unfolded: Bool) -> (attributed: NSAttributedString, size: CGSize, token: UInt64) {
        if (!folds || unfolded), let fullAttributed, let fullContentSize, let fullRenderToken {
            return (fullAttributed, fullContentSize, fullRenderToken)
        }
        return (foldedAttributed, foldedContentSize, foldedRenderToken)
    }
}

struct ChatTableSlice: Equatable {
    let sliceID: UInt64
    let table: Prose.Table
    let prepared: PreparsedTableModel
    let headerCells: [NSAttributedString]
    let rowCells: [[NSAttributedString]]
    let headerHasLinks: [Bool]
    let rowHasLinks: [[Bool]]
    let naturalWidths: [CGFloat]
}

enum ChatProseSlice {
    case richText(ChatRenderedProse)
    case code(ChatCodeSlice, sliceIndex: Int)
    case table(ChatTableSlice, sliceIndex: Int)
    case math(String, isLive: Bool, sliceIndex: Int)
    case fileCards([PreparsedFileLink], sliceIndex: Int)
    case pictures(words: ChatRenderedProse?, pics: [PreparsedPictureLink], sliceIndex: Int)
}

private extension NSAttributedString.Key {
    static let chatInlineCode = NSAttributedString.Key("ChatListInlineCode")
}

/// Renders tokenized code into an aligned UIKit `NSAttributedString` matching `ProseView`'s colors and CJK alignment.
@MainActor
enum ChatCodeHighlighter {
    private struct AlignedFontPair {
        let narrow: UIFont
        let wide: UIFont
    }

    private struct FontPairKey: Hashable {
        let sizeKey: Int
        let codePref: Pref.Code
        let italic: Bool
    }

    private static let fontPairCache = BoundedLRUCache<FontPairKey, AlignedFontPair>(countLimit: 24)

    private static func alignedCodeFonts(size: CGFloat, preference: Pref.Code, italic: Bool) -> AlignedFontPair {
        let key = FontPairKey(sizeKey: Int((size * 2).rounded()), codePref: preference, italic: italic)
        if let hit = fontPairCache.get(key) { return hit }

        let baseMono = Ink.uiMono(size, preference: preference)
        let targetMono: UIFont
        if italic, let slanted = baseMono.fontDescriptor.withSymbolicTraits(baseMono.fontDescriptor.symbolicTraits.union(.traitItalic)) {
            targetMono = UIFont(descriptor: slanted, size: size)
        } else {
            targetMono = baseMono
        }

        let wideBase = UIFont.systemFont(ofSize: size)
        let targetWide: UIFont
        if italic, let slantedWide = wideBase.fontDescriptor.withSymbolicTraits(wideBase.fontDescriptor.symbolicTraits.union(.traitItalic)) {
            targetWide = UIFont(descriptor: slantedWide, size: size)
        } else {
            targetWide = wideBase
        }

        let native = targetMono as CTFont
        var zero: UniChar = 48
        var glyph: CGGlyph = 0
        let pair: AlignedFontPair
        if CTFontGetGlyphsForCharacters(native, &zero, &glyph, 1) {
            let advance = CTFontGetAdvancesForGlyphs(native, .horizontal, &glyph, nil, 1)
            if advance > 0 {
                let matrix = CGAffineTransform(scaleX: size * 0.5 / advance, y: 1)
                let scaledDescriptor = targetMono.fontDescriptor.withMatrix(matrix)
                let halfFont = UIFont(descriptor: scaledDescriptor, size: size)
                pair = AlignedFontPair(narrow: halfFont, wide: targetWide)
            } else {
                pair = AlignedFontPair(narrow: targetMono, wide: targetWide)
            }
        } else {
            pair = AlignedFontPair(narrow: targetMono, wide: targetWide)
        }
        fontPairCache.set(pair, for: key)
        return pair
    }

    private static func plainCodeFonts(size: CGFloat, preference: Pref.Code, italic: Bool) -> UIFont {
        let baseMono = Ink.uiMono(size, preference: preference)
        if italic, let slanted = baseMono.fontDescriptor.withSymbolicTraits(baseMono.fontDescriptor.symbolicTraits.union(.traitItalic)) {
            return UIFont(descriptor: slanted, size: size)
        }
        return baseMono
    }

    static func highlight(
        _ text: String,
        language: String,
        isOutput: Bool,
        style: ChatListStyle
    ) -> NSAttributedString {
        let model = CodeTokenizer.prepare(text, language: language, isOutput: isOutput)
        let pStyle = NSMutableParagraphStyle()
        pStyle.lineSpacing = style.codeLineSpacing

        let outputColor = isOutput ? style.resolveColor(Ink.Code.output) : nil
        let plainColor = outputColor ?? style.resolveColor(Ink.ink)
        let keywordColor = outputColor ?? style.resolveColor(Ink.Code.keyword)
        let functionColor = outputColor ?? style.resolveColor(Ink.Code.function)
        let numberColor = outputColor ?? style.resolveColor(Ink.Code.number)
        let stringColor = outputColor ?? style.resolveColor(Ink.Code.string)
        let commentColor = outputColor ?? style.resolveColor(Ink.inkFaint)
        func color(for kind: CodeTokenKind) -> UIColor {
            switch kind {
            case .plain: return plainColor
            case .keyword: return keywordColor
            case .function: return functionColor
            case .number: return numberColor
            case .string: return stringColor
            case .comment: return commentColor
            }
        }

        let out = NSMutableAttributedString()
        out.beginEditing()
        if model.hasWide {
            let regular = alignedCodeFonts(size: style.codeSize, preference: style.code, italic: false)
            let italic = alignedCodeFonts(size: style.codeSize, preference: style.code, italic: true)
            for seg in model.segments {
                let pair = seg.kind == .comment ? italic : regular
                let font = seg.isWide ? pair.wide : pair.narrow
                out.append(NSAttributedString(string: seg.text, attributes: [
                    .font: font,
                    .foregroundColor: color(for: seg.kind),
                    .paragraphStyle: pStyle,
                ]))
            }
        } else {
            let regular = plainCodeFonts(size: style.codeSize, preference: style.code, italic: false)
            let italic = plainCodeFonts(size: style.codeSize, preference: style.code, italic: true)
            for seg in model.segments {
                let font = seg.kind == .comment ? italic : regular
                out.append(NSAttributedString(string: seg.text, attributes: [
                    .font: font,
                    .foregroundColor: color(for: seg.kind),
                    .paragraphStyle: pStyle,
                ]))
            }
        }
        out.endEditing()
        return NSAttributedString(attributedString: out)
    }
}

/// Incremental + cached prose builder producing continuous rich-text runs and interactive block slices.
@MainActor
final class ChatProseBuilder {
    private static let picturePattern = try? NSRegularExpression(pattern: #"!\[([^\]]*)\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)"#)

    private struct BlockCacheEntry {
        let attributed: NSAttributedString
        let trailingSeparatorStyle: NSParagraphStyle
        let inlineCodeOffsets: [NSRange]
        let quoteSpan: NSRange?
        let isRule: Bool
    }

    private struct BlockCacheKey: Hashable {
        let styleKey: String
        let blockHash: UInt64
        let byteCount: Int
        let isFirst: Bool
        let isLast: Bool
        let text: String

        init(styleKey: String, isFirst: Bool, isLast: Bool, text: String) {
            self.styleKey = styleKey
            self.blockHash = fnv1a64(text)
            self.byteCount = text.utf8.count
            self.isFirst = isFirst
            self.isLast = isLast
            self.text = text
        }

        static func == (lhs: BlockCacheKey, rhs: BlockCacheKey) -> Bool {
            lhs.blockHash == rhs.blockHash
                && lhs.byteCount == rhs.byteCount
                && lhs.isFirst == rhs.isFirst
                && lhs.isLast == rhs.isLast
                && lhs.styleKey == rhs.styleKey
                && lhs.text == rhs.text
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(styleKey)
            hasher.combine(blockHash)
            hasher.combine(byteCount)
            hasher.combine(isFirst)
            hasher.combine(isLast)
        }
    }

    private struct StreamScannerEntry {
        var scanner: StreamBlocks
        var sealedBlocks: [Prose.Block]
        var sealedStyleKey: String
        var sealedCodeSlices: [Int: ChatCodeSlice] = [:]
        var sealedTableSlices: [Int: ChatTableSlice] = [:]
    }

    private struct RichTextSliceKey: Hashable {
        let styleKey: String
        let blockHash: Int
        let keys: [String]
    }

    private struct CodeSliceKey: Hashable {
        let styleKey: String
        let language: String
        let byteCount: Int
        let textHash: UInt64
        let rawText: String

        init(styleKey: String, language: String, rawText: String) {
            self.styleKey = styleKey
            self.language = language
            self.byteCount = rawText.utf8.count
            self.textHash = fnv1a64(rawText)
            self.rawText = rawText
        }

        static func == (lhs: CodeSliceKey, rhs: CodeSliceKey) -> Bool {
            lhs.textHash == rhs.textHash
                && lhs.byteCount == rhs.byteCount
                && lhs.language == rhs.language
                && lhs.styleKey == rhs.styleKey
                && lhs.rawText == rhs.rawText
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(styleKey)
            hasher.combine(language)
            hasher.combine(byteCount)
            hasher.combine(textHash)
        }
    }

    private struct TableSliceKey: Hashable {
        let styleKey: String
        let table: Prose.Table
        private let cachedHash: Int

        init(styleKey: String, table: Prose.Table) {
            self.styleKey = styleKey
            self.table = table
            var hasher = Hasher()
            hasher.combine(styleKey)
            hasher.combine(table.header)
            hasher.combine(table.rows.count)
            if let first = table.rows.first { hasher.combine(first) }
            if let last = table.rows.last, table.rows.count > 1 { hasher.combine(last) }
            self.cachedHash = hasher.finalize()
        }

        static func == (lhs: TableSliceKey, rhs: TableSliceKey) -> Bool {
            lhs.cachedHash == rhs.cachedHash && lhs.styleKey == rhs.styleKey && lhs.table == rhs.table
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(cachedHash)
        }
    }

    private let blockCache = BoundedLRUCache<BlockCacheKey, BlockCacheEntry>(countLimit: 800)
    private let richTextSliceCache = BoundedLRUCache<RichTextSliceKey, ChatRenderedProse>(countLimit: 1200)
    private let codeSliceCache = BoundedLRUCache<CodeSliceKey, ChatCodeSlice>(countLimit: 400)
    private let tableSliceCache = BoundedLRUCache<TableSliceKey, ChatTableSlice>(countLimit: 256)
    private var streamScanners: [String: StreamScannerEntry] = [:]
    private var nextToken: UInt64 = 1

    private func allocateRenderToken() -> UInt64 {
        let token = nextToken
        nextToken &+= 1
        return token
    }

    func clearCaches() {
        blockCache.removeAll()
        richTextSliceCache.removeAll()
        codeSliceCache.removeAll()
        tableSliceCache.removeAll()
        streamScanners.removeAll(keepingCapacity: true)
    }

    func resetStreamScanner(for key: String) {
        streamScanners.removeValue(forKey: key)
    }

    func buildUserText(_ text: String, style: ChatListStyle) -> ChatRenderedProse {
        let pStyle = NSMutableParagraphStyle()
        pStyle.lineSpacing = 4
        let font = UIFont.systemFont(ofSize: Ink.Size.body)
        let attr = NSAttributedString(attributedString: NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: style.resolveColor(Ink.ink),
            .paragraphStyle: pStyle,
        ]))
        let token = allocateRenderToken()
        return ChatRenderedProse(
            attributed: attr,
            decorations: .empty,
            topInset: 0,
            bottomInset: 0,
            renderToken: token,
            hasLinks: false
        )
    }

    func buildDisclosureText(_ text: String, style: ChatListStyle) -> ChatRenderedProse {
        let pStyle = NSMutableParagraphStyle()
        pStyle.lineSpacing = 3
        let attr = NSAttributedString(attributedString: NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: Ink.Size.small),
            .foregroundColor: style.resolveColor(Ink.inkSoft),
            .paragraphStyle: pStyle,
        ]))
        let token = allocateRenderToken()
        return ChatRenderedProse(
            attributed: attr,
            decorations: .empty,
            topInset: 0,
            bottomInset: 0,
            renderToken: token,
            hasLinks: false
        )
    }

    func buildAssistantSlices(
        _ rawText: String,
        style: ChatListStyle,
        isStreaming: Bool,
        streamKey: String? = nil
    ) -> [ChatProseSlice] {
        let parsed = parseBlocks(rawText, isStreaming: isStreaming, streamKey: streamKey, styleKey: style.styleKey)
        let blocks = parsed.blocks
        let sealedCount = parsed.sealedCount
        if blocks.isEmpty {
            let pStyle = makeParagraphStyle(style: style)
            let placeholder = NSAttributedString(attributedString: NSAttributedString(string: isStreaming ? " " : "", attributes: [
                .font: Ink.uiFace(style.readingSize, bold: false, face: style.face),
                .foregroundColor: style.resolveColor(Ink.ink),
                .paragraphStyle: pStyle,
            ]))
            let token = allocateRenderToken()
            return [
                .richText(ChatRenderedProse(
                    attributed: placeholder,
                    decorations: .empty,
                    topInset: 0,
                    bottomInset: 2,
                    renderToken: token,
                    hasLinks: false
                ))
            ]
        }

        enum PendingSegment {
            case proseRun([Prose.Block])
            case block(Prose.Block, sealedIndex: Int?)
        }

        var segments: [PendingSegment] = []
        var run: [Prose.Block] = []
        func flushRun() {
            if !run.isEmpty {
                segments.append(.proseRun(run))
                run = []
            }
        }

        for blockIndex in blocks.indices {
            let block = blocks[blockIndex]
            if isProseRunBlock(block) {
                run.append(block)
            } else {
                flushRun()
                let sealedIndex: Int? = blockIndex < sealedCount ? blockIndex : nil
                segments.append(.block(block, sealedIndex: sealedIndex))
            }
        }
        flushRun()

        var slices: [ChatProseSlice] = []
        var sliceIdx = 0
        for segIndex in segments.indices {
            let isLastSegment = segIndex == segments.count - 1
            let shouldFadeTail = isStreaming && isLastSegment && style.fade && !style.reduceMotion
            switch segments[segIndex] {
            case .proseRun(let runBlocks):
                let rendered = buildRichTextSlice(
                    blocks: runBlocks,
                    style: style,
                    isStreaming: isStreaming && isLastSegment,
                    fadeTail: shouldFadeTail
                )
                slices.append(.richText(rendered))
                sliceIdx += 1

            case .block(let block, let sealedIndex):
                switch block {
                case .code(let lang, let codeText, let closed):
                    let liveCode = isStreaming && isLastSegment && !closed
                    let slice: ChatCodeSlice
                    if !liveCode,
                       let streamKey,
                       let sealedIndex,
                       let cachedSealed = streamScanners[streamKey]?.sealedCodeSlices[sealedIndex] {
                        slice = cachedSealed
                    } else {
                        let built = buildCodeSlice(language: lang, rawText: codeText, isLive: liveCode, style: style)
                        if !liveCode, let streamKey, let sealedIndex {
                            streamScanners[streamKey]?.sealedCodeSlices[sealedIndex] = built
                        }
                        slice = built
                    }
                    slices.append(.code(slice, sliceIndex: sliceIdx))
                    sliceIdx += 1

                case .table(let table):
                    let isSealed = sealedIndex != nil || !(isStreaming && isLastSegment)
                    let slice: ChatTableSlice
                    if isSealed,
                       let streamKey,
                       let sealedIndex,
                       let cachedSealed = streamScanners[streamKey]?.sealedTableSlices[sealedIndex] {
                        slice = cachedSealed
                    } else {
                        let built = buildTableSlice(table, style: style, cacheable: isSealed)
                        if isSealed, let streamKey, let sealedIndex {
                            streamScanners[streamKey]?.sealedTableSlices[sealedIndex] = built
                        }
                        slice = built
                    }
                    slices.append(.table(slice, sliceIndex: sliceIdx))
                    sliceIdx += 1

                case .math(let latex):
                    slices.append(.math(latex, isLive: isStreaming && isLastSegment, sliceIndex: sliceIdx))
                    sliceIdx += 1

                case .paragraph(let text):
                    if let files = FileCard.links(in: text) {
                        let links = files.map { PreparsedFileLink(label: $0.label, path: $0.path) }
                        slices.append(.fileCards(links, sliceIndex: sliceIdx))
                        sliceIdx += 1
                    } else if text.contains("![") {
                        let split = splitPictures(text)
                        let wordsProse: ChatRenderedProse?
                        if !split.words.isEmpty {
                            wordsProse = buildRichTextSlice(
                                blocks: [.paragraph(split.words)],
                                style: style,
                                isStreaming: isStreaming && isLastSegment,
                                fadeTail: shouldFadeTail
                            )
                        } else {
                            wordsProse = nil
                        }
                        let pics = split.pictures.map { PreparsedPictureLink(label: $0.label, source: $0.source) }
                        slices.append(.pictures(words: wordsProse, pics: pics, sliceIndex: sliceIdx))
                        sliceIdx += 1
                    } else {
                        let rendered = buildRichTextSlice(
                            blocks: [block],
                            style: style,
                            isStreaming: isStreaming && isLastSegment,
                            fadeTail: shouldFadeTail
                        )
                        slices.append(.richText(rendered))
                        sliceIdx += 1
                    }

                default:
                    let rendered = buildRichTextSlice(
                        blocks: [block],
                        style: style,
                        isStreaming: isStreaming && isLastSegment,
                        fadeTail: shouldFadeTail
                    )
                    slices.append(.richText(rendered))
                    sliceIdx += 1
                }
            }
        }
        return slices
    }

    private func parseBlocks(
        _ rawText: String,
        isStreaming: Bool,
        streamKey: String?,
        styleKey: String
    ) -> (blocks: [Prose.Block], sealedCount: Int) {
        guard isStreaming else {
            if let streamKey { streamScanners.removeValue(forKey: streamKey) }
            return (ParsedCache.blocks(rawText), 0)
        }
        guard let streamKey else {
            return (Prose.parse(Prose.mend(rawText)), 0)
        }
        var entry = streamScanners[streamKey] ?? StreamScannerEntry(
            scanner: StreamBlocks(),
            sealedBlocks: [],
            sealedStyleKey: styleKey
        )
        if rawText.utf8.count < entry.scanner.receivedBytes {
            entry = StreamScannerEntry(
                scanner: StreamBlocks(),
                sealedBlocks: [],
                sealedStyleKey: styleKey
            )
        }
        if entry.sealedStyleKey != styleKey {
            entry.sealedStyleKey = styleKey
            entry.sealedCodeSlices.removeAll(keepingCapacity: true)
            entry.sealedTableSlices.removeAll(keepingCapacity: true)
        }
        let priorFinished = entry.scanner.finished.count
        let delta = String(decoding: rawText.utf8.dropFirst(entry.scanner.receivedBytes), as: UTF8.self)
        if !delta.isEmpty {
            entry.scanner.append(delta)
            for source in entry.scanner.finished.dropFirst(priorFinished) {
                entry.sealedBlocks.append(contentsOf: ParsedCache.blocks(source))
            }
        }
        streamScanners[streamKey] = entry
        if entry.scanner.receivedBytes == 0 {
            return (Prose.parse(Prose.mend(rawText)), 0)
        }
        let tailBlocks = Prose.parse(Prose.mend(entry.scanner.tail))
        return (entry.sealedBlocks + tailBlocks, entry.sealedBlocks.count)
    }

    private func isProseRunBlock(_ block: Prose.Block) -> Bool {
        switch block {
        case .heading, .list, .quote, .rule:
            return true
        case .paragraph(let text):
            return FileCard.links(in: text) == nil && !text.contains("![")
        case .code, .table, .math:
            return false
        }
    }

    private func splitPictures(_ text: String) -> (words: String, pictures: [(label: String, source: String)]) {
        guard let pattern = Self.picturePattern else {
            return (text, [])
        }
        let whole = NSRange(text.startIndex..., in: text)
        var pictures: [(label: String, source: String)] = []
        for match in pattern.matches(in: text, range: whole) {
            guard let labelRange = Range(match.range(at: 1), in: text),
                  let sourceRange = Range(match.range(at: 2), in: text) else { continue }
            pictures.append((String(text[labelRange]), String(text[sourceRange])))
        }
        let words = pattern.stringByReplacingMatches(in: text, range: whole, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (words, pictures)
    }

    private func buildCodeSlice(
        language: String,
        rawText: String,
        isLive: Bool,
        style: ChatListStyle
    ) -> ChatCodeSlice {
        let cacheKey: CodeSliceKey?
        if !isLive {
            let candidate = CodeSliceKey(styleKey: style.styleKey, language: language, rawText: rawText)
            if let hit = codeSliceCache.get(candidate) {
                return hit
            }
            cacheKey = candidate
        } else {
            cacheKey = nil
        }

        let trimmed = CodeTokenizer.trimmedLines(rawText)
        let body = trimmed.isEmpty ? " " : trimmed
        let count = CodeTokenizer.lineCount(body)
        let isOutput = CodeTokenizer.isOutputBlock(language: language, text: body)
        let folds = !isLive && count > 20

        let foldedAttr: NSAttributedString
        let foldedSize: CGSize
        let foldedToken: UInt64
        let fullAttr: NSAttributedString?
        let fullSize: CGSize?
        let fullToken: UInt64?

        if folds {
            let foldedBody = body.split(separator: "\n", omittingEmptySubsequences: false).prefix(12).joined(separator: "\n")
            foldedAttr = NSAttributedString(attributedString: ChatCodeHighlighter.highlight(foldedBody, language: language, isOutput: isOutput, style: style))
            foldedSize = measureCodeUnwrappedSize(foldedAttr, knownLineCount: min(count, 12))
            foldedToken = allocateRenderToken()
            fullAttr = nil
            fullSize = nil
            fullToken = nil
        } else {
            let highlighted = NSAttributedString(attributedString: ChatCodeHighlighter.highlight(body, language: language, isOutput: isOutput, style: style))
            let measuredSize = measureCodeUnwrappedSize(highlighted, knownLineCount: count)
            let token = allocateRenderToken()
            foldedAttr = highlighted
            foldedSize = measuredSize
            foldedToken = token
            fullAttr = highlighted
            fullSize = measuredSize
            fullToken = token
        }

        let built = ChatCodeSlice(
            language: language,
            rawText: rawText,
            trimmedText: body,
            isOutput: isOutput,
            isLive: isLive,
            lineCount: count,
            folds: folds,
            foldedAttributed: foldedAttr,
            fullAttributed: fullAttr,
            foldedContentSize: foldedSize,
            fullContentSize: fullSize,
            foldedRenderToken: foldedToken,
            fullRenderToken: fullToken
        )
        if let cacheKey {
            codeSliceCache.set(built, for: cacheKey)
        }
        return built
    }

    func resolvedCodeSlice(_ slice: ChatCodeSlice, unfolded: Bool, style: ChatListStyle) -> ChatCodeSlice {
        guard slice.folds, unfolded, slice.fullAttributed == nil else {
            return slice
        }
        let fullAttr = NSAttributedString(attributedString: ChatCodeHighlighter.highlight(slice.trimmedText, language: slice.language, isOutput: slice.isOutput, style: style))
        let fullSize = measureCodeUnwrappedSize(fullAttr, knownLineCount: slice.lineCount)
        let fullToken = allocateRenderToken()
        let updated = ChatCodeSlice(
            language: slice.language,
            rawText: slice.rawText,
            trimmedText: slice.trimmedText,
            isOutput: slice.isOutput,
            isLive: slice.isLive,
            lineCount: slice.lineCount,
            folds: slice.folds,
            foldedAttributed: slice.foldedAttributed,
            fullAttributed: fullAttr,
            foldedContentSize: slice.foldedContentSize,
            fullContentSize: fullSize,
            foldedRenderToken: slice.foldedRenderToken,
            fullRenderToken: fullToken
        )
        if !slice.isLive {
            let cacheKey = CodeSliceKey(styleKey: style.styleKey, language: slice.language, rawText: slice.rawText)
            codeSliceCache.set(updated, for: cacheKey)
        }
        return updated
    }

    private func measureCodeUnwrappedSize(_ attributed: NSAttributedString, knownLineCount: Int? = nil) -> CGSize {
        let (fitted, lineCount) = ChatLayoutCache.measureCoreTextMetrics(
            attributed,
            maxWidth: .greatestFiniteMagnitude,
            knownLineCount: knownLineCount
        )
        guard fitted.width > 0 || fitted.height > 0 else { return .zero }
        return CGSize(width: ceil(fitted.width) + 2, height: ceil(fitted.height + max(1.0, CGFloat(lineCount) * 0.35)))
    }

    private func buildTableSlice(_ table: Prose.Table, style: ChatListStyle, cacheable: Bool) -> ChatTableSlice {
        let cacheKey: TableSliceKey?
        if cacheable {
            let candidate = TableSliceKey(styleKey: style.styleKey, table: table)
            if let hit = tableSliceCache.get(candidate) {
                return hit
            }
            cacheKey = candidate
        } else {
            cacheKey = nil
        }

        let prepared = TablePreparer.prepare(table)
        let columns = max(table.header.count, table.rows.map(\.count).max() ?? 0)
        var headerCells: [NSAttributedString] = []
        var headerHasLinks: [Bool] = []
        headerCells.reserveCapacity(columns)
        headerHasLinks.reserveCapacity(columns)
        for column in 0..<columns {
            let align = column < table.aligns.count ? table.aligns[column] : .leading
            let source = column < prepared.header.count ? prepared.header[column] : AttributedString("")
            let built = buildTableCellAttributed(source, isHeader: true, align: align, style: style)
            headerCells.append(built.attributed)
            headerHasLinks.append(built.hasLink)
        }

        var rowCells: [[NSAttributedString]] = []
        var rowHasLinks: [[Bool]] = []
        rowCells.reserveCapacity(prepared.rows.count)
        rowHasLinks.reserveCapacity(prepared.rows.count)
        for row in prepared.rows {
            var cells: [NSAttributedString] = []
            var links: [Bool] = []
            cells.reserveCapacity(columns)
            links.reserveCapacity(columns)
            for column in 0..<columns {
                let align = column < table.aligns.count ? table.aligns[column] : .leading
                let source = column < row.count ? row[column] : AttributedString("")
                let built = buildTableCellAttributed(source, isHeader: false, align: align, style: style)
                cells.append(built.attributed)
                links.append(built.hasLink)
            }
            rowCells.append(cells)
            rowHasLinks.append(links)
        }

        let widths: [CGFloat] = (0..<columns).map { column in
            var natural: CGFloat = column < headerCells.count ? ceil(headerCells[column].size().width) : 0
            for row in rowCells where column < row.count {
                natural = max(natural, ceil(row[column].size().width))
            }
            return max(28, natural + 4)
        }
        let built = ChatTableSlice(
            sliceID: allocateRenderToken(),
            table: table,
            prepared: prepared,
            headerCells: headerCells,
            rowCells: rowCells,
            headerHasLinks: headerHasLinks,
            rowHasLinks: rowHasLinks,
            naturalWidths: widths
        )
        if let cacheKey {
            tableSliceCache.set(built, for: cacheKey)
        }
        return built
    }

    private func buildTableCellAttributed(
        _ source: AttributedString,
        isHeader: Bool,
        align: Prose.Table.Align,
        style: ChatListStyle
    ) -> (attributed: NSAttributedString, hasLink: Bool) {
        let cellSize = style.tableCellSize
        let pStyle = NSMutableParagraphStyle()
        pStyle.lineSpacing = cellSize * 0.25
        switch align {
        case .center: pStyle.alignment = .center
        case .trailing: pStyle.alignment = .right
        case .leading: pStyle.alignment = .left
        }

        let ink = style.resolveColor(Ink.ink)
        let accent = style.resolveColor(Ink.accent)
        let monoFont = Ink.uiMono(max(CGFloat(12), cellSize - 2), preference: style.code)
        var hasLink = false
        let out = NSMutableAttributedString()
        out.beginEditing()
        for run in source.runs {
            let chunk = String(source[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            let isBold = isHeader || intent.contains(.stronglyEmphasized)
            let isItalic = intent.contains(.emphasized)
            let isCode = intent.contains(.code)
            let isStrike = intent.contains(.strikethrough)

            var font = Ink.uiFace(cellSize, bold: isBold, face: style.face)
            if isItalic,
               let slanted = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.traitItalic)) {
                font = UIFont(descriptor: slanted, size: cellSize)
            }
            var attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: ink,
                .paragraphStyle: pStyle,
            ]
            if style.face == .wenkai, isBold {
                attrs[.strokeWidth] = -3.0
                attrs[.strokeColor] = ink
            }
            if isCode {
                attrs[.font] = monoFont
                attrs[.foregroundColor] = accent
            }
            if isStrike {
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = run.link {
                hasLink = true
                attrs[.link] = link
                attrs[.foregroundColor] = accent
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            out.append(NSAttributedString(string: chunk, attributes: attrs))
        }
        out.endEditing()
        return (NSAttributedString(attributedString: out), hasLink)
    }

    private func buildRichTextSlice(
        blocks: [Prose.Block],
        style: ChatListStyle,
        isStreaming: Bool,
        fadeTail: Bool
    ) -> ChatRenderedProse {
        let sliceCacheKey: RichTextSliceKey?
        if !isStreaming && !fadeTail {
            let keys = blocks.map { cacheKeyString(for: $0) }
            var hasher = Hasher()
            for key in keys { hasher.combine(key) }
            let candidate = RichTextSliceKey(styleKey: style.styleKey, blockHash: hasher.finalize(), keys: keys)
            if let hit = richTextSliceCache.get(candidate) {
                return hit
            }
            sliceCacheKey = candidate
        } else {
            sliceCacheKey = nil
        }

        let out = NSMutableAttributedString()
        out.beginEditing()
        var inlineCodeRanges: [NSRange] = []
        var quoteBlocks: [NSRange] = []
        var ruleRanges: [NSRange] = []
        let separatorFont = Ink.uiFace(style.readingSize, bold: false, face: style.face)

        for index in blocks.indices {
            let block = blocks[index]
            let isFirst = index == 0
            let isLast = index == blocks.count - 1
            let entry = renderedBlock(
                block,
                style: style,
                isFirst: isFirst,
                isLast: isLast,
                cacheable: !isStreaming || !isLast
            )

            let baseOffset = out.length
            out.append(entry.attributed)

            for r in entry.inlineCodeOffsets {
                inlineCodeRanges.append(NSRange(location: baseOffset + r.location, length: r.length))
            }
            if let qSpan = entry.quoteSpan {
                quoteBlocks.append(NSRange(location: baseOffset + qSpan.location, length: qSpan.length))
            }
            if entry.isRule, entry.attributed.length > 0 {
                ruleRanges.append(NSRange(location: baseOffset, length: entry.attributed.length))
            }

            if !isLast {
                let separatorAttrs: [NSAttributedString.Key: Any] = [
                    .paragraphStyle: entry.trailingSeparatorStyle,
                    .font: separatorFont,
                ]
                out.append(NSAttributedString(string: "\n", attributes: separatorAttrs))
            }
        }

        if fadeTail && out.length > 0 {
            applyStreamingTailFade(to: out)
        }
        out.endEditing()

        let topInset: CGFloat
        if case .quote = blocks.first {
            topInset = Ink.Space.m
        } else {
            topInset = 0
        }

        let bottomInset: CGFloat
        if case .quote = blocks.last {
            bottomInset = Ink.Space.m
        } else {
            bottomInset = 2
        }

        let token = allocateRenderToken()
        let immutable = NSAttributedString(attributedString: out)
        let rendered = ChatRenderedProse(
            attributed: immutable,
            decorations: ChatBlockDecorations(
                inlineCodeRanges: inlineCodeRanges,
                quoteBlocks: quoteBlocks,
                ruleRanges: ruleRanges
            ),
            topInset: topInset,
            bottomInset: bottomInset,
            renderToken: token,
            hasLinks: Self.containsLinks(immutable)
        )
        if let sliceCacheKey {
            richTextSliceCache.set(rendered, for: sliceCacheKey)
        }
        return rendered
    }

    private static func containsLinks(_ attributed: NSAttributedString) -> Bool {
        guard attributed.length > 0 else { return false }
        var found = false
        attributed.enumerateAttribute(
            .link,
            in: NSRange(location: 0, length: attributed.length),
            options: .longestEffectiveRangeNotRequired
        ) { value, _, stop in
            if value != nil {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    private func applyStreamingTailFade(to attributed: NSMutableAttributedString) {
        let raw = attributed.string
        let tailIndices = Array(raw.indices.suffix(12))
        let count = tailIndices.count
        guard count > 0 else { return }
        attributed.beginEditing()
        for (offset, strIndex) in tailIndices.enumerated() {
            let range = NSRange(strIndex..<raw.index(after: strIndex), in: raw)
            guard range.location >= 0, range.location + range.length <= attributed.length else { continue }
            let alpha = CGFloat(count - offset) / CGFloat(count + 1)
            if let color = attributed.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? UIColor {
                attributed.addAttribute(.foregroundColor, value: color.withAlphaComponent(alpha), range: range)
            }
            if let stroke = attributed.attribute(.strokeColor, at: range.location, effectiveRange: nil) as? UIColor {
                attributed.addAttribute(.strokeColor, value: stroke.withAlphaComponent(alpha), range: range)
            }
        }
        attributed.endEditing()
    }

    private func renderedBlock(
        _ block: Prose.Block,
        style: ChatListStyle,
        isFirst: Bool,
        isLast: Bool,
        cacheable: Bool
    ) -> BlockCacheEntry {
        let keyString = cacheKeyString(for: block)
        let cacheKey = BlockCacheKey(
            styleKey: style.styleKey,
            isFirst: isFirst,
            isLast: isLast,
            text: keyString
        )
        if cacheable, let hit = blockCache.get(cacheKey) {
            return hit
        }

        let built = buildSingleBlock(block, style: style, isFirst: isFirst, isLast: isLast)
        if cacheable {
            blockCache.set(built, for: cacheKey)
        }
        return built
    }

    private func cacheKeyString(for block: Prose.Block) -> String {
        switch block {
        case .heading(let level, let text):
            return "H\(level):\(text)"
        case .paragraph(let text):
            return "P:\(text)"
        case .list(let items):
            return "L:" + items.map { "\($0.depth)|\($0.number ?? -1)|\($0.checked.map { $0 ? "1" : "0" } ?? "-")|\($0.text)" }.joined(separator: "\n")
        case .quote(let inner):
            return "Q:" + inner.map(cacheKeyString).joined(separator: "|")
        case .code(let lang, let text, let closed):
            return "C:\(lang):\(closed ? 1 : 0):\(text)"
        case .table(let table):
            return "T:" + table.header.joined(separator: "|") + "/" + table.rows.map { $0.joined(separator: "|") }.joined(separator: ";")
        case .math(let latex):
            return "M:\(latex)"
        case .rule:
            return "R"
        }
    }

    private func buildSingleBlock(
        _ block: Prose.Block,
        style: ChatListStyle,
        isFirst: Bool,
        isLast: Bool
    ) -> BlockCacheEntry {
        switch block {
        case .heading(let level, let text):
            let before = isFirst ? 0 : style.headingTop(level: level)
            let spacing = isLast ? 0 : style.headingBottom
            let pStyle = makeParagraphStyle(style: style, spacing: spacing, before: before, tight: true)
            let attr = buildInline(text, size: style.headingSize(level: level), bold: true, style: style, ink: style.resolveColor(Ink.ink), paragraph: pStyle)
            return BlockCacheEntry(
                attributed: attr,
                trailingSeparatorStyle: pStyle,
                inlineCodeOffsets: extractInlineCodeRanges(in: attr),
                quoteSpan: nil,
                isRule: false
            )

        case .paragraph(let text):
            let spacing = isLast ? 0 : style.paragraphGap
            let pStyle = makeParagraphStyle(style: style, spacing: spacing)
            let attr = buildInline(text, size: style.readingSize, bold: false, style: style, ink: style.resolveColor(Ink.ink), paragraph: pStyle)
            return BlockCacheEntry(
                attributed: attr,
                trailingSeparatorStyle: pStyle,
                inlineCodeOffsets: extractInlineCodeRanges(in: attr),
                quoteSpan: nil,
                isRule: false
            )

        case .list(let items):
            let out = NSMutableAttributedString()
            out.beginEditing()
            let base = style.readingSize
            let bodyInk = style.resolveColor(Ink.ink)
            let faintInk = style.resolveColor(Ink.inkFaint)
            let accentInk = style.resolveColor(Ink.accent)
            let separatorFont = Ink.uiFace(base, face: style.face)
            var lastPStyle = makeParagraphStyle(style: style, spacing: isLast ? 0 : style.paragraphGap)
            for (itemIndex, item) in items.enumerated() {
                let marker: String
                let markerSize: CGFloat
                let markerColor: UIColor
                if let checked = item.checked {
                    marker = checked ? "☑︎" : "☐"
                    markerSize = base
                    markerColor = checked ? accentInk : faintInk
                } else if let number = item.number {
                    marker = "\(number)."
                    markerSize = base * 0.92
                    markerColor = faintInk
                } else {
                    marker = item.depth == 0 ? "•" : (item.depth == 1 ? "◦" : "▪")
                    markerSize = base * (item.depth == 0 ? 0.95 : 0.78)
                    markerColor = faintInk
                }
                let indent = CGFloat(item.depth) * base * 1.25
                let hang = item.number != nil ? base * 1.75 : base * 1.25
                let itemLast = itemIndex == items.count - 1
                let spacing = itemLast ? (isLast ? 0 : style.paragraphGap) : style.listSpacing
                let pStyle = makeParagraphStyle(style: style, spacing: spacing, indent: indent, hanging: hang)
                lastPStyle = pStyle
                if itemIndex > 0 {
                    out.append(NSAttributedString(string: "\n", attributes: [
                        .font: separatorFont,
                        .paragraphStyle: pStyle,
                    ]))
                }
                out.append(NSAttributedString(string: marker + "\t", attributes: [
                    .font: Ink.uiFace(markerSize, face: style.face),
                    .foregroundColor: markerColor,
                    .paragraphStyle: pStyle,
                ]))
                out.append(buildInline(item.text, size: base, bold: false, style: style, ink: bodyInk, paragraph: pStyle))
            }
            out.endEditing()
            let immutable = NSAttributedString(attributedString: out)
            return BlockCacheEntry(
                attributed: immutable,
                trailingSeparatorStyle: lastPStyle,
                inlineCodeOffsets: extractInlineCodeRanges(in: immutable),
                quoteSpan: nil,
                isRule: false
            )

        case .quote(let inner):
            let out = NSMutableAttributedString()
            out.beginEditing()
            let indent = Ink.Space.l + 4
            let tail = -Ink.Space.m
            let cardPadV = Ink.Space.m
            let quoteInk = style.resolveColor(Ink.inkSoft)
            let separatorFont = Ink.uiFace(style.readingSize, face: style.face)
            var lastPStyle = makeParagraphStyle(style: style, spacing: isLast ? 0 : cardPadV + style.paragraphGap, indent: indent, tailIndent: tail)
            let flatLines = flattenQuoteBlocks(inner)
            for (idx, line) in flatLines.enumerated() {
                let firstInQuote = idx == 0
                let lastInQuote = idx == flatLines.count - 1
                let before: CGFloat = (firstInQuote && !isFirst) ? cardPadV : 0
                let after = lastInQuote ? (isLast ? 0 : (cardPadV + style.paragraphGap)) : style.paragraphGap * 0.65
                let pStyle = makeParagraphStyle(
                    style: style,
                    spacing: after,
                    before: before,
                    indent: indent,
                    hanging: line.hanging,
                    tailIndent: tail,
                    tight: line.isHeading
                )
                if idx > 0 {
                    out.append(NSAttributedString(string: "\n", attributes: [
                        .font: separatorFont,
                        .paragraphStyle: lastPStyle,
                    ]))
                }
                lastPStyle = pStyle
                let textSize = line.isHeading ? style.headingSize(level: 3) : style.readingSize
                out.append(buildInline(line.text, size: textSize, bold: line.isHeading, style: style, ink: quoteInk, paragraph: pStyle))
            }
            if out.length == 0 {
                out.append(NSAttributedString(string: " ", attributes: [
                    .font: separatorFont,
                    .foregroundColor: quoteInk,
                    .paragraphStyle: lastPStyle,
                ]))
            }
            out.endEditing()
            let immutable = NSAttributedString(attributedString: out)
            let span = NSRange(location: 0, length: immutable.length)
            return BlockCacheEntry(
                attributed: immutable,
                trailingSeparatorStyle: lastPStyle,
                inlineCodeOffsets: extractInlineCodeRanges(in: immutable),
                quoteSpan: span,
                isRule: false
            )

        case .rule:
            let pStyle = NSMutableParagraphStyle()
            pStyle.paragraphSpacingBefore = isFirst ? 0 : style.paragraphGap * 0.35
            pStyle.paragraphSpacing = isLast ? 0 : style.paragraphGap * 0.85
            pStyle.maximumLineHeight = Ink.Size.micro
            pStyle.minimumLineHeight = Ink.Size.micro
            let immutableStyle = (pStyle.copy() as? NSParagraphStyle) ?? pStyle
            let attr = NSAttributedString(string: "\u{200B}", attributes: [
                .font: UIFont.systemFont(ofSize: Ink.Size.micro),
                .foregroundColor: UIColor.clear,
                .paragraphStyle: immutableStyle,
            ])
            return BlockCacheEntry(
                attributed: attr,
                trailingSeparatorStyle: immutableStyle,
                inlineCodeOffsets: [],
                quoteSpan: nil,
                isRule: true
            )

        case .code, .table, .math:
            let pStyle = makeParagraphStyle(style: style)
            return BlockCacheEntry(
                attributed: NSAttributedString(),
                trailingSeparatorStyle: pStyle,
                inlineCodeOffsets: [],
                quoteSpan: nil,
                isRule: false
            )
        }
    }

    private struct QuoteLine {
        let text: String
        let isHeading: Bool
        let hanging: CGFloat
    }

    private func flattenQuoteBlocks(_ blocks: [Prose.Block]) -> [QuoteLine] {
        var result: [QuoteLine] = []
        for inner in blocks {
            switch inner {
            case .heading(_, let text):
                result.append(QuoteLine(text: text, isHeading: true, hanging: 0))
            case .paragraph(let text):
                result.append(QuoteLine(text: text, isHeading: false, hanging: 0))
            case .list(let items):
                for item in items {
                    let prefix: String
                    if let checked = item.checked {
                        prefix = checked ? "☑︎ " : "☐ "
                    } else if let num = item.number {
                        prefix = "\(num). "
                    } else {
                        prefix = "• "
                    }
                    result.append(QuoteLine(text: prefix + item.text, isHeading: false, hanging: Ink.Size.sub))
                }
            case .quote(let nested):
                result.append(contentsOf: flattenQuoteBlocks(nested))
            case .code(_, let text, _):
                result.append(QuoteLine(text: text, isHeading: false, hanging: 0))
            case .math(let latex):
                result.append(QuoteLine(text: latex, isHeading: false, hanging: 0))
            case .table(let table):
                result.append(QuoteLine(text: table.header.joined(separator: " · "), isHeading: true, hanging: 0))
                for row in table.rows {
                    result.append(QuoteLine(text: row.joined(separator: " · "), isHeading: false, hanging: 0))
                }
            case .rule:
                break
            }
        }
        return result
    }

    private func makeParagraphStyle(
        style: ChatListStyle,
        spacing: CGFloat = 0,
        before: CGFloat = 0,
        indent: CGFloat = 0,
        hanging: CGFloat = 0,
        tailIndent: CGFloat = 0,
        tight: Bool = false
    ) -> NSParagraphStyle {
        let pStyle = NSMutableParagraphStyle()
        pStyle.lineSpacing = tight ? style.leading * 0.5 : style.leading
        pStyle.paragraphSpacing = spacing
        pStyle.paragraphSpacingBefore = before
        pStyle.firstLineHeadIndent = indent
        pStyle.headIndent = indent + hanging
        if tailIndent != 0 { pStyle.tailIndent = tailIndent }
        if hanging > 0 { pStyle.tabStops = [NSTextTab(textAlignment: .left, location: indent + hanging)] }
        return (pStyle.copy() as? NSParagraphStyle) ?? pStyle
    }

    private func buildInline(
        _ text: String,
        size: CGFloat,
        bold: Bool,
        style: ChatListStyle,
        ink: UIColor,
        paragraph: NSParagraphStyle
    ) -> NSAttributedString {
        let parsed = PreparsedInline.parse(text)
        let accent = style.resolveColor(Ink.accent)
        let regularFont = Ink.uiFace(size, bold: bold, face: style.face)
        let boldFont = bold ? regularFont : Ink.uiFace(size, bold: true, face: style.face)
        let monoFont = Ink.uiMono(max(CGFloat(12), size - 2), preference: style.code)
        let out = NSMutableAttributedString()
        out.beginEditing()
        for run in parsed.runs {
            let isBold = bold || run.bold
            var font = isBold ? boldFont : regularFont
            if run.italic,
               let slanted = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.traitItalic)) {
                font = UIFont(descriptor: slanted, size: size)
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: ink,
                .paragraphStyle: paragraph,
            ]
            if style.face == .wenkai, isBold {
                attributes[.strokeWidth] = -3.0
                attributes[.strokeColor] = ink
            }
            if run.code {
                attributes[.font] = monoFont
                attributes[.foregroundColor] = accent
                attributes[.chatInlineCode] = true
            }
            if run.strikethrough {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = run.link {
                attributes[.link] = link
                attributes[.foregroundColor] = accent
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            out.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        out.endEditing()
        return NSAttributedString(attributedString: out)
    }

    private func extractInlineCodeRanges(in attr: NSAttributedString) -> [NSRange] {
        var ranges: [NSRange] = []
        attr.enumerateAttribute(.chatInlineCode, in: NSRange(location: 0, length: attr.length)) { value, range, _ in
            if value != nil { ranges.append(range) }
        }
        return ranges
    }
}

/// Deterministic layout measurement and height caching for every chat cell type.
@MainActor
final class ChatLayoutCache {
    struct MeasuredSlice {
        let slice: ChatProseSlice
        let height: CGFloat
        let pictureHeights: [CGFloat]
    }

    struct AssistantLayoutEntry {
        let timeGapHeight: CGFloat
        let speakerHeight: CGFloat
        let thinkingText: ChatRenderedProse?
        let thinkingTextHeight: CGFloat
        let pulseText: ChatRenderedProse?
        let pulseTextHeight: CGFloat
        let lookbackHeight: CGFloat
        let slices: [MeasuredSlice]
        let hasSources: Bool
        let hasContinueButton: Bool
        let hasFooter: Bool
        let contentWidth: CGFloat
        let cellHeight: CGFloat
    }

    struct UserLayoutEntry {
        let timeGapHeight: CGFloat
        let photosHeight: CGFloat
        let rendered: ChatRenderedProse
        let textWidth: CGFloat
        let textHeight: CGFloat
        let bubbleWidth: CGFloat
        let bubbleHeight: CGFloat
        let cellHeight: CGFloat
    }

    struct NoteLayoutEntry {
        let titleHeight: CGFloat
        let detailHeight: CGFloat
        let cellHeight: CGFloat
    }

    struct LiveTextEntry {
        let rendered: ChatRenderedProse
        let textHeight: CGFloat
        let cellHeight: CGFloat
    }

    struct QueuedLayoutEntry {
        let textHeight: CGFloat
        let hasPhotos: Bool
        let cellHeight: CGFloat
    }

    private struct AssistantKey: Hashable {
        let id: String
        let styleKey: String
        let widthKey: Int
        let textByteCount: Int
        let textHash: UInt64
        let text: String
        let reasoningByteCount: Int
        let reasoningHash: UInt64
        let reasoning: String
        let pulseByteCount: Int
        let pulseHash: UInt64
        let pulse: String
        let lookbackNoteByteCount: Int
        let lookbackNoteHash: UInt64
        let lookbackNote: String
        let lookbackRestByteCount: Int
        let lookbackRestHash: UInt64
        let lookbackRest: String
        let opens: Bool
        let faces: Bool
        let isRoom: Bool
        let showThinking: Bool
        let hasTimeGap: Bool
        let hasSources: Bool
        let hasContinue: Bool
        let hasFooter: Bool
        let isStreaming: Bool
        let freshShown: Int
        let expandedThinking: Bool
        let expandedPulse: Bool
        let expandedLookback: Bool
        let unfoldedSlices: [Int]
        let overrideVersion: UInt64
        private let cachedHash: Int

        init(
            id: String,
            styleKey: String,
            widthKey: Int,
            text: String,
            reasoning: String,
            pulse: String,
            lookbackNote: String,
            lookbackRest: String,
            opens: Bool,
            faces: Bool,
            isRoom: Bool,
            showThinking: Bool,
            hasTimeGap: Bool,
            hasSources: Bool,
            hasContinue: Bool,
            hasFooter: Bool,
            isStreaming: Bool,
            freshShown: Int,
            expandedThinking: Bool,
            expandedPulse: Bool,
            expandedLookback: Bool,
            unfoldedSlices: [Int],
            overrideVersion: UInt64
        ) {
            self.id = id
            self.styleKey = styleKey
            self.widthKey = widthKey
            self.textByteCount = text.utf8.count
            self.textHash = fnv1a64(text)
            self.text = text
            self.reasoningByteCount = reasoning.utf8.count
            self.reasoningHash = fnv1a64(reasoning)
            self.reasoning = reasoning
            self.pulseByteCount = pulse.utf8.count
            self.pulseHash = fnv1a64(pulse)
            self.pulse = pulse
            self.lookbackNoteByteCount = lookbackNote.utf8.count
            self.lookbackNoteHash = fnv1a64(lookbackNote)
            self.lookbackNote = lookbackNote
            self.lookbackRestByteCount = lookbackRest.utf8.count
            self.lookbackRestHash = fnv1a64(lookbackRest)
            self.lookbackRest = lookbackRest
            self.opens = opens
            self.faces = faces
            self.isRoom = isRoom
            self.showThinking = showThinking
            self.hasTimeGap = hasTimeGap
            self.hasSources = hasSources
            self.hasContinue = hasContinue
            self.hasFooter = hasFooter
            self.isStreaming = isStreaming
            self.freshShown = freshShown
            self.expandedThinking = expandedThinking
            self.expandedPulse = expandedPulse
            self.expandedLookback = expandedLookback
            self.unfoldedSlices = unfoldedSlices
            self.overrideVersion = overrideVersion

            var hasher = Hasher()
            hasher.combine(id)
            hasher.combine(styleKey)
            hasher.combine(widthKey)
            hasher.combine(self.textByteCount)
            hasher.combine(self.textHash)
            hasher.combine(self.reasoningByteCount)
            hasher.combine(self.reasoningHash)
            hasher.combine(self.pulseByteCount)
            hasher.combine(self.pulseHash)
            hasher.combine(self.lookbackNoteByteCount)
            hasher.combine(self.lookbackNoteHash)
            hasher.combine(self.lookbackRestByteCount)
            hasher.combine(self.lookbackRestHash)
            hasher.combine(opens)
            hasher.combine(faces)
            hasher.combine(isRoom)
            hasher.combine(showThinking)
            hasher.combine(hasTimeGap)
            hasher.combine(hasSources)
            hasher.combine(hasContinue)
            hasher.combine(hasFooter)
            hasher.combine(isStreaming)
            hasher.combine(freshShown)
            hasher.combine(expandedThinking)
            hasher.combine(expandedPulse)
            hasher.combine(expandedLookback)
            hasher.combine(unfoldedSlices)
            hasher.combine(overrideVersion)
            self.cachedHash = hasher.finalize()
        }

        static func == (lhs: AssistantKey, rhs: AssistantKey) -> Bool {
            lhs.cachedHash == rhs.cachedHash
                && lhs.widthKey == rhs.widthKey
                && lhs.textByteCount == rhs.textByteCount
                && lhs.textHash == rhs.textHash
                && lhs.lookbackRestByteCount == rhs.lookbackRestByteCount
                && lhs.lookbackRestHash == rhs.lookbackRestHash
                && lhs.reasoningByteCount == rhs.reasoningByteCount
                && lhs.reasoningHash == rhs.reasoningHash
                && lhs.pulseByteCount == rhs.pulseByteCount
                && lhs.pulseHash == rhs.pulseHash
                && lhs.lookbackNoteByteCount == rhs.lookbackNoteByteCount
                && lhs.lookbackNoteHash == rhs.lookbackNoteHash
                && lhs.freshShown == rhs.freshShown
                && lhs.overrideVersion == rhs.overrideVersion
                && lhs.opens == rhs.opens
                && lhs.faces == rhs.faces
                && lhs.isRoom == rhs.isRoom
                && lhs.showThinking == rhs.showThinking
                && lhs.hasTimeGap == rhs.hasTimeGap
                && lhs.hasSources == rhs.hasSources
                && lhs.hasContinue == rhs.hasContinue
                && lhs.hasFooter == rhs.hasFooter
                && lhs.isStreaming == rhs.isStreaming
                && lhs.expandedThinking == rhs.expandedThinking
                && lhs.expandedPulse == rhs.expandedPulse
                && lhs.expandedLookback == rhs.expandedLookback
                && lhs.unfoldedSlices == rhs.unfoldedSlices
                && lhs.id == rhs.id
                && lhs.styleKey == rhs.styleKey
                && lhs.lookbackRest == rhs.lookbackRest
                && lhs.text == rhs.text
                && lhs.reasoning == rhs.reasoning
                && lhs.pulse == rhs.pulse
                && lhs.lookbackNote == rhs.lookbackNote
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(cachedHash)
        }
    }

    private struct UserKey: Hashable {
        let id: String
        let styleKey: String
        let widthKey: Int
        let textByteCount: Int
        let textHash: UInt64
        let text: String
        let photoCount: Int
        let isFirst: Bool
        let opens: Bool
        let faces: Bool
        let hasTimeGap: Bool

        init(
            id: String,
            styleKey: String,
            widthKey: Int,
            text: String,
            photoCount: Int,
            isFirst: Bool,
            opens: Bool,
            faces: Bool,
            hasTimeGap: Bool
        ) {
            self.id = id
            self.styleKey = styleKey
            self.widthKey = widthKey
            self.textByteCount = text.utf8.count
            self.textHash = fnv1a64(text)
            self.text = text
            self.photoCount = photoCount
            self.isFirst = isFirst
            self.opens = opens
            self.faces = faces
            self.hasTimeGap = hasTimeGap
        }

        static func == (lhs: UserKey, rhs: UserKey) -> Bool {
            lhs.textHash == rhs.textHash
                && lhs.textByteCount == rhs.textByteCount
                && lhs.widthKey == rhs.widthKey
                && lhs.photoCount == rhs.photoCount
                && lhs.isFirst == rhs.isFirst
                && lhs.opens == rhs.opens
                && lhs.faces == rhs.faces
                && lhs.hasTimeGap == rhs.hasTimeGap
                && lhs.id == rhs.id
                && lhs.styleKey == rhs.styleKey
                && lhs.text == rhs.text
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
            hasher.combine(styleKey)
            hasher.combine(widthKey)
            hasher.combine(textByteCount)
            hasher.combine(textHash)
            hasher.combine(photoCount)
            hasher.combine(isFirst)
            hasher.combine(opens)
            hasher.combine(faces)
            hasher.combine(hasTimeGap)
        }
    }

    private struct LiveStreamingKey: Equatable {
        let generation: Int
        let widthKey: Int
        let styleKey: String
        let byteCount: Int
        let contentHash: UInt64
        let text: String

        init(generation: Int, widthKey: Int, styleKey: String, text: String) {
            self.generation = generation
            self.widthKey = widthKey
            self.styleKey = styleKey
            self.byteCount = text.utf8.count
            self.contentHash = fnv1a64(text)
            self.text = text
        }

        static func == (lhs: LiveStreamingKey, rhs: LiveStreamingKey) -> Bool {
            lhs.generation == rhs.generation
                && lhs.widthKey == rhs.widthKey
                && lhs.byteCount == rhs.byteCount
                && lhs.contentHash == rhs.contentHash
                && lhs.styleKey == rhs.styleKey
                && lhs.text == rhs.text
        }
    }

    private struct NoteKey: Hashable {
        let id: String
        let text: String
        let nextRaw: String
        let fold: Bool
        let isLatestNote: Bool
        let widthKey: Int
        let uiScale: Double
    }

    let builder = ChatProseBuilder()

    private let assistantFinalizedCache = BoundedLRUCache<AssistantKey, AssistantLayoutEntry>(countLimit: 1000)
    private var assistantStreamingCache: [String: (key: AssistantKey, entry: AssistantLayoutEntry)] = [:]
    private let userCache = BoundedLRUCache<UserKey, UserLayoutEntry>(countLimit: 1200)
    private let noteCache = BoundedLRUCache<NoteKey, NoteLayoutEntry>(countLimit: 256)
    private var lastLiveStreamingEntry: (key: LiveStreamingKey, entry: AssistantLayoutEntry)?
    private var blockHeightOverrides: [String: CGFloat] = [:]
    private let hostingHeights = BoundedLRUCache<String, CGFloat>(countLimit: 600)
    private var overrideVersionsByOwner: [String: UInt64] = [:]

    private let labelMeasurer: UILabel = {
        let label = UILabel()
        label.numberOfLines = 0
        return label
    }()

    private lazy var hostingMeasurer: UIHostingController<AnyView> = {
        let vc = UIHostingController(rootView: AnyView(EmptyView()))
        vc.safeAreaRegions = []
        return vc
    }()

    func invalidateAll() {
        assistantFinalizedCache.removeAll()
        assistantStreamingCache.removeAll(keepingCapacity: true)
        userCache.removeAll()
        noteCache.removeAll()
        hostingHeights.removeAll()
        lastLiveStreamingEntry = nil
        builder.clearCaches()
    }

    func invalidateHeightsOnly() {
        assistantFinalizedCache.removeAll()
        assistantStreamingCache.removeAll(keepingCapacity: true)
        userCache.removeAll()
        noteCache.removeAll()
        hostingHeights.removeAll()
        lastLiveStreamingEntry = nil
    }

    func invalidateMessage(id: String) {
        assistantStreamingCache.removeValue(forKey: id)
        assistantFinalizedCache.removeAll { $0.id == id }
        userCache.removeAll { $0.id == id }
        noteCache.removeAll { $0.id == id }
    }

    func setBlockHeightOverride(_ height: CGFloat, key: String, ownerID: String) -> Bool {
        let rounded = ceil(height)
        if let old = blockHeightOverrides[key], abs(old - rounded) <= 0.5 {
            return false
        }
        blockHeightOverrides[key] = rounded
        overrideVersionsByOwner[ownerID, default: 1] &+= 1
        assistantStreamingCache.removeValue(forKey: ownerID)
        if ownerID.hasPrefix("streaming-") {
            lastLiveStreamingEntry = nil
        }
        return true
    }

    func hostingHeight(for key: String) -> CGFloat? {
        hostingHeights.get(key)
    }

    func setHostingHeight(_ height: CGFloat, for key: String) -> Bool {
        let rounded = ceil(height)
        if let old = hostingHeights.get(key), abs(old - rounded) <= 0.5 {
            return false
        }
        hostingHeights.set(rounded, for: key)
        return true
    }

    func measureHostingView<V: View>(_ view: V, width: CGFloat, cacheKey: String) -> CGFloat {
        if let hit = hostingHeights.get(cacheKey) { return hit }
        hostingMeasurer.rootView = AnyView(view)
        let size = hostingMeasurer.sizeThatFits(in: CGSize(width: max(120, width), height: CGFloat.greatestFiniteMagnitude))
        let h = max(24, ceil(size.height))
        hostingHeights.set(h, for: cacheKey)
        return h
    }

    func measureUser(
        row: ChatListRowItem,
        collectionWidth: CGFloat,
        style: ChatListStyle
    ) -> UserLayoutEntry {
        let widthKey = Int((collectionWidth * 2).rounded())
        let key = UserKey(
            id: row.line.id,
            styleKey: style.styleKey,
            widthKey: widthKey,
            text: row.line.text,
            photoCount: row.line.refs.count,
            isFirst: row.isFirst,
            opens: row.opens,
            faces: row.faces,
            hasTimeGap: row.faces && row.opens && row.timeGap != nil
        )
        if let hit = userCache.get(key) { return hit }

        let pageMargin = Ink.Space.page
        let avatarSpace: CGFloat = row.faces ? (ChatCellMetrics.faceSize + Ink.Space.s) : 0
        let contentArea = max(160, collectionWidth - pageMargin * 2 - avatarSpace)
        let maxBubbleWidth = max(120, contentArea - Ink.Space.huge)
        let maxTextWidth = max(60, maxBubbleWidth - ChatCellMetrics.userBubblePadH * 2)

        let timeGapH: CGFloat = (row.faces && row.opens && row.timeGap != nil) ? ChatCellMetrics.timeGapHeight : 0
        let photosH: CGFloat = row.line.refs.isEmpty ? 0 : ChatCellMetrics.photoSize

        let rendered = builder.buildUserText(row.line.text, style: style)
        let textSize: CGSize
        let bubbleW: CGFloat
        let bubbleH: CGFloat
        if row.line.text.isEmpty {
            textSize = .zero
            bubbleW = 0
            bubbleH = 0
        } else {
            textSize = measureTextSize(rendered: rendered, maxWidth: maxTextWidth)
            bubbleW = min(maxBubbleWidth, max(44, textSize.width + ChatCellMetrics.userBubblePadH * 2))
            bubbleH = ceil(textSize.height + ChatCellMetrics.userBubblePadV * 2)
        }

        var total: CGFloat = row.isFirst ? 0 : ChatCellMetrics.userTurnTopPad
        if timeGapH > 0 {
            total += timeGapH + ChatCellMetrics.timeGapBottomPad + ChatCellMetrics.sectionSpacing
        }
        var bodyH: CGFloat = 0
        if photosH > 0 { bodyH += photosH }
        if photosH > 0 && bubbleH > 0 { bodyH += Ink.Space.s }
        if bubbleH > 0 { bodyH += bubbleH }
        if row.faces && row.opens {
            bodyH = max(bodyH, ChatCellMetrics.faceSize)
        }
        total += bodyH + ChatCellMetrics.rowSpacing

        let entry = UserLayoutEntry(
            timeGapHeight: timeGapH,
            photosHeight: photosH,
            rendered: rendered,
            textWidth: textSize.width,
            textHeight: textSize.height,
            bubbleWidth: bubbleW,
            bubbleHeight: bubbleH,
            cellHeight: ceil(total)
        )
        userCache.set(entry, for: key)
        return entry
    }

    func measureAssistant(
        row: ChatListRowItem,
        collectionWidth: CGFloat,
        style: ChatListStyle,
        expandedThinking: Bool,
        expandedPulse: Bool,
        expandedLookback: Bool,
        unfoldedSlices: Set<Int>
    ) -> AssistantLayoutEntry {
        let widthKey = Int((collectionWidth * 2).rounded())
        let isFresh = row.isFreshWriting
        let shown = row.freshShown ?? row.line.text.count
        let rawBody = isFresh ? String(row.line.text.prefix(shown)) : row.lookbackRest
        let hasSources = !isFresh && (row.lineMeta?.urls.isEmpty == false)
        let hasContinue = !isFresh && row.hitStepLimit
        let hasFooter = !isFresh && (row.isLatestBot ? !row.working : row.endsTurn)
        let sortedUnfolded = unfoldedSlices.sorted()

        let key = AssistantKey(
            id: row.line.id,
            styleKey: style.styleKey,
            widthKey: widthKey,
            text: row.line.text,
            reasoning: row.line.reasoning ?? "",
            pulse: row.line.pulse ?? "",
            lookbackNote: row.lookbackNote ?? "",
            lookbackRest: rawBody,
            opens: row.opens,
            faces: row.faces,
            isRoom: row.isRoom,
            showThinking: row.showThinking,
            hasTimeGap: row.faces && row.opens && row.timeGap != nil,
            hasSources: hasSources,
            hasContinue: hasContinue,
            hasFooter: hasFooter,
            isStreaming: isFresh,
            freshShown: isFresh ? shown : -1,
            expandedThinking: expandedThinking,
            expandedPulse: expandedPulse,
            expandedLookback: expandedLookback,
            unfoldedSlices: sortedUnfolded,
            overrideVersion: overrideVersionsByOwner[row.line.id] ?? 1
        )

        if isFresh {
            if let hit = assistantStreamingCache[row.line.id], hit.key == key {
                return hit.entry
            }
        } else {
            assistantStreamingCache.removeValue(forKey: row.line.id)
            if let hit = assistantFinalizedCache.get(key) {
                return hit
            }
        }

        let contentWidth = max(120, collectionWidth - Ink.Space.page * 2)
        let timeGapH: CGFloat = (row.faces && row.opens && row.timeGap != nil) ? ChatCellMetrics.timeGapHeight : 0
        let speakerH: CGFloat = (row.opens && (row.faces || row.isRoom))
            ? (row.faces ? ChatCellMetrics.faceSize : ChatCellMetrics.compactSpeakerSize)
            : 0

        var thinkingRendered: ChatRenderedProse?
        var thinkingH: CGFloat = 0
        if let reasoning = row.line.reasoning, row.showThinking {
            let built = builder.buildDisclosureText(reasoning, style: style)
            thinkingRendered = built
            if expandedThinking {
                let innerWidth = max(80, contentWidth - Ink.Space.m)
                thinkingH = measureTextSize(rendered: built, maxWidth: innerWidth).height
            }
        }

        var pulseRendered: ChatRenderedProse?
        var pulseH: CGFloat = 0
        if let pulse = row.line.pulse {
            let built = builder.buildDisclosureText(pulse, style: style)
            pulseRendered = built
            if expandedPulse {
                let innerWidth = max(80, contentWidth - Ink.Space.m * 2)
                pulseH = measureTextSize(rendered: built, maxWidth: innerWidth).height
            }
        }

        var lookbackH: CGFloat = 0
        if !isFresh, let note = row.lookbackNote {
            lookbackH = measureLookbackHeight(note: note, maxWidth: contentWidth, expanded: expandedLookback)
        }

        let slices = builder.buildAssistantSlices(
            rawBody,
            style: style,
            isStreaming: isFresh,
            streamKey: isFresh ? "fresh-\(row.line.id)" : nil
        )
        let measuredSlices = measureSlices(
            slices,
            ownerID: row.line.id,
            contentWidth: contentWidth,
            widthKey: widthKey,
            style: style,
            unfoldedSlices: unfoldedSlices
        )

        var total: CGFloat = 0
        if timeGapH > 0 {
            total += timeGapH + ChatCellMetrics.timeGapBottomPad + ChatCellMetrics.sectionSpacing
        }
        if speakerH > 0 {
            total += speakerH + ChatCellMetrics.sectionSpacing
        }

        var bodyItems: [CGFloat] = []
        if thinkingRendered != nil {
            bodyItems.append(ChatCellMetrics.disclosureHeaderHeight + (expandedThinking ? ChatCellMetrics.disclosureGap + thinkingH : 0))
        }
        if pulseRendered != nil {
            bodyItems.append(ChatCellMetrics.disclosureHeaderHeight + (expandedPulse ? ChatCellMetrics.disclosureGap + pulseH + Ink.Space.s * 2 : 0))
        }
        if lookbackH > 0 {
            bodyItems.append(lookbackH)
        }
        if !measuredSlices.isEmpty {
            var proseStackH: CGFloat = 0
            for (idx, item) in measuredSlices.enumerated() {
                if idx > 0 { proseStackH += style.paragraphGap }
                proseStackH += item.height
            }
            bodyItems.append(proseStackH)
        }
        if hasSources { bodyItems.append(ChatCellMetrics.sourcesPillHeight) }
        if hasContinue { bodyItems.append(ChatCellMetrics.continueButtonHeight) }
        if hasFooter { bodyItems.append(ChatCellMetrics.footerHeight) }

        for (idx, h) in bodyItems.enumerated() {
            if idx > 0 { total += ChatCellMetrics.botBlockGap }
            total += h
        }
        total += ChatCellMetrics.rowSpacing

        let entry = AssistantLayoutEntry(
            timeGapHeight: timeGapH,
            speakerHeight: speakerH,
            thinkingText: thinkingRendered,
            thinkingTextHeight: thinkingH,
            pulseText: pulseRendered,
            pulseTextHeight: pulseH,
            lookbackHeight: lookbackH,
            slices: measuredSlices,
            hasSources: hasSources,
            hasContinueButton: hasContinue,
            hasFooter: hasFooter,
            contentWidth: contentWidth,
            cellHeight: ceil(total)
        )

        if isFresh {
            assistantStreamingCache[row.line.id] = (key: key, entry: entry)
        } else {
            assistantFinalizedCache.set(entry, for: key)
        }
        return entry
    }

    func measureLiveStreamingProse(
        text: String,
        generation: Int,
        collectionWidth: CGFloat,
        style: ChatListStyle
    ) -> AssistantLayoutEntry {
        let contentWidth = max(120, collectionWidth - Ink.Space.page * 2)
        let widthKey = Int((collectionWidth * 2).rounded())
        let cacheKey = LiveStreamingKey(
            generation: generation,
            widthKey: widthKey,
            styleKey: style.styleKey,
            text: text
        )
        if let cached = lastLiveStreamingEntry, cached.key == cacheKey {
            return cached.entry
        }
        let ownerID = "streaming-\(generation)"
        let slices = builder.buildAssistantSlices(
            text,
            style: style,
            isStreaming: true,
            streamKey: ownerID
        )
        let measured = measureSlices(
            slices,
            ownerID: ownerID,
            contentWidth: contentWidth,
            widthKey: widthKey,
            style: style,
            unfoldedSlices: []
        )
        var proseStackH: CGFloat = 0
        for (idx, item) in measured.enumerated() {
            if idx > 0 { proseStackH += style.paragraphGap }
            proseStackH += item.height
        }
        let entry = AssistantLayoutEntry(
            timeGapHeight: 0,
            speakerHeight: 0,
            thinkingText: nil,
            thinkingTextHeight: 0,
            pulseText: nil,
            pulseTextHeight: 0,
            lookbackHeight: 0,
            slices: measured,
            hasSources: false,
            hasContinueButton: false,
            hasFooter: false,
            contentWidth: contentWidth,
            cellHeight: ceil(proseStackH + ChatCellMetrics.rowSpacing)
        )
        lastLiveStreamingEntry = (key: cacheKey, entry: entry)
        return entry
    }

    private func measureSlices(
        _ slices: [ChatProseSlice],
        ownerID: String,
        contentWidth: CGFloat,
        widthKey: Int,
        style: ChatListStyle,
        unfoldedSlices: Set<Int>
    ) -> [MeasuredSlice] {
        slices.map { slice in
            switch slice {
            case .richText(let rendered):
                let h = measureTextSize(rendered: rendered, maxWidth: contentWidth).height
                return MeasuredSlice(slice: slice, height: h, pictureHeights: [])

            case .code(let codeSlice, let sliceIndex):
                let unfolded = unfoldedSlices.contains(sliceIndex)
                let resolvedCode = (codeSlice.folds && unfolded)
                    ? builder.resolvedCodeSlice(codeSlice, unfolded: true, style: style)
                    : codeSlice
                let bodySize = (resolvedCode.folds && !unfolded)
                    ? resolvedCode.foldedContentSize
                    : resolvedCode.resolved(unfolded: unfolded).size
                let bodyH = max(16, bodySize.height) + Ink.Space.m * 2
                let foldH = resolvedCode.folds ? style.codeFoldButtonHeight : 0
                let total = ceil(style.codeHeaderHeight + bodyH + foldH)
                return MeasuredSlice(slice: .code(resolvedCode, sliceIndex: sliceIndex), height: total, pictureHeights: [])

            case .table(let tableSlice, _):
                let h = ChatTableBlockView.measureHeight(slice: tableSlice, maxWidth: contentWidth, style: style)
                return MeasuredSlice(slice: slice, height: ceil(h), pictureHeights: [])

            case .math(let latex, let isLive, _):
                let h = ChatFormulaBlockView.measureHeight(latex: latex, maxWidth: contentWidth, style: style, streaming: isLive)
                return MeasuredSlice(slice: slice, height: ceil(h), pictureHeights: [])

            case .fileCards(let links, let sliceIndex):
                let key = "file|\(ownerID)|\(sliceIndex)|\(widthKey)|\(style.styleKey)|\(links.map(\.path).joined(separator: "|"))"
                let h: CGFloat
                if let overrideH = blockHeightOverrides[key] {
                    h = overrideH
                } else {
                    let singleH = 68 * style.scale
                    h = CGFloat(links.count) * singleH + CGFloat(max(0, links.count - 1)) * Ink.Space.s
                }
                return MeasuredSlice(slice: slice, height: ceil(h), pictureHeights: [])

            case .pictures(let words, let pics, let sliceIndex):
                var total: CGFloat = 0
                if let words {
                    total += measureTextSize(rendered: words, maxWidth: contentWidth).height
                    if !pics.isEmpty { total += style.readingSize * 0.6 }
                }
                var picHeights: [CGFloat] = []
                for (picIndex, pic) in pics.enumerated() {
                    let key = "pic|\(ownerID)|\(sliceIndex)|\(picIndex)|\(widthKey)|\(style.styleKey)|\(pic.source)"
                    let picH = blockHeightOverrides[key] ?? 160
                    picHeights.append(picH)
                    if picIndex > 0 { total += style.readingSize * 0.6 }
                    total += picH
                }
                return MeasuredSlice(slice: slice, height: ceil(total), pictureHeights: picHeights)
            }
        }
    }

    func measureNote(line: ChatLine, isLatestNote: Bool, collectionWidth: CGFloat) -> NoteLayoutEntry {
        let widthKey = Int((collectionWidth * 2).rounded())
        let key = NoteKey(
            id: line.id,
            text: line.text,
            nextRaw: line.next?.rawValue ?? "",
            fold: line.fold,
            isLatestNote: isLatestNote,
            widthKey: widthKey,
            uiScale: UIScale.shared.value
        )
        if let hit = noteCache.get(key) {
            return hit
        }

        let contentWidth = max(120, collectionWidth - Ink.Space.page * 2)
        let entry: NoteLayoutEntry
        if line.fold {
            entry = NoteLayoutEntry(titleHeight: 36, detailHeight: 0, cellHeight: ceil(36 + ChatCellMetrics.rowSpacing))
        } else if let next = line.next {
            let parts = line.text.split(separator: "\n", maxSplits: 1).map(String.init)
            let advice = Explain.Advice(title: parts.first ?? line.text, detail: parts.count > 1 ? parts[1] : "", next: next)
            let innerW = max(80, contentWidth - Ink.Space.l * 2)
            labelMeasurer.font = UIFont.systemFont(ofSize: Ink.Size.sub, weight: .semibold)
            labelMeasurer.text = advice.displayTitle
            let titleH = ceil(labelMeasurer.sizeThatFits(CGSize(width: max(40, innerW - 28), height: .greatestFiniteMagnitude)).height)

            var detailH: CGFloat = 0
            if !advice.detail.isEmpty {
                labelMeasurer.font = UIFont.systemFont(ofSize: Ink.Size.sub)
                labelMeasurer.text = advice.detail
                detailH = ceil(labelMeasurer.sizeThatFits(CGSize(width: innerW, height: .greatestFiniteMagnitude)).height)
            }

            var total = Ink.Space.l * 2 + titleH
            if detailH > 0 { total += Ink.Space.s + detailH }
            if isLatestNote && advice.button != nil { total += Ink.Space.s + Ink.Space.xs + 34 }
            entry = NoteLayoutEntry(titleHeight: titleH, detailHeight: detailH, cellHeight: ceil(total + ChatCellMetrics.rowSpacing))
        } else {
            labelMeasurer.font = UIFont.systemFont(ofSize: Ink.Size.small)
            labelMeasurer.text = line.text
            let h = ceil(labelMeasurer.sizeThatFits(CGSize(width: contentWidth, height: .greatestFiniteMagnitude)).height)
            entry = NoteLayoutEntry(titleHeight: h, detailHeight: 0, cellHeight: ceil(h + ChatCellMetrics.rowSpacing))
        }
        noteCache.set(entry, for: key)
        return entry
    }

    func measureLiveText(_ text: String, collectionWidth: CGFloat, style: ChatListStyle, cardInsetH: CGFloat, cardInsetV: CGFloat) -> LiveTextEntry {
        let contentWidth = max(120, collectionWidth - Ink.Space.page * 2)
        let innerWidth = max(80, contentWidth - cardInsetH * 2)
        let rendered = builder.buildDisclosureText(text, style: style)
        let textH = measureTextSize(rendered: rendered, maxWidth: innerWidth).height
        let cardH = ChatCellMetrics.disclosureHeaderHeight + ChatCellMetrics.disclosureGap + textH + cardInsetV * 2
        return LiveTextEntry(rendered: rendered, textHeight: textH, cellHeight: ceil(cardH + ChatCellMetrics.rowSpacing))
    }

    func measureQueued(_ item: TeamModel.Queued, collectionWidth: CGFloat) -> QueuedLayoutEntry {
        let contentWidth = max(120, collectionWidth - Ink.Space.page * 2)
        let maxBubbleW = max(120, contentWidth - Ink.Space.huge)
        let innerW = max(60, maxBubbleW - Ink.Space.l * 2)
        var bubbleH: CGFloat = Ink.Space.m * 2
        let hasPhotos = !item.photos.isEmpty
        if hasPhotos { bubbleH += 20 }
        var textH: CGFloat = 0
        if !item.text.isEmpty {
            labelMeasurer.font = UIFont.systemFont(ofSize: Ink.Size.body, weight: .medium)
            labelMeasurer.numberOfLines = 4
            labelMeasurer.text = item.text
            textH = ceil(labelMeasurer.sizeThatFits(CGSize(width: innerW, height: .greatestFiniteMagnitude)).height)
            labelMeasurer.numberOfLines = 0
            if hasPhotos { bubbleH += 4 }
            bubbleH += textH
        }
        let actionsH: CGFloat = 24 * UIScale.factor
        let total = bubbleH + Ink.Space.xs + actionsH + ChatCellMetrics.rowSpacing
        return QueuedLayoutEntry(textHeight: textH, hasPhotos: hasPhotos, cellHeight: ceil(total))
    }

    func measureFailure(error: String, working: Bool, collectionWidth: CGFloat) -> CGFloat {
        let contentWidth = max(120, collectionWidth - Ink.Space.page * 2)
        let buttonReserve: CGFloat = working ? 0 : (92 + Ink.Space.m)
        let textW = max(80, contentWidth - Ink.Space.l * 2 - 24 - Ink.Space.m - buttonReserve)
        labelMeasurer.font = UIFont.systemFont(ofSize: Ink.Size.sub)
        labelMeasurer.text = error
        let textH = ceil(labelMeasurer.sizeThatFits(CGSize(width: textW, height: .greatestFiniteMagnitude)).height)
        let cardH = max(32 + Ink.Space.m * 2, textH + Ink.Space.m * 2)
        return ceil(cardH + ChatCellMetrics.rowSpacing)
    }

    private func measureLookbackHeight(note: String, maxWidth: CGFloat, expanded: Bool) -> CGFloat {
        labelMeasurer.font = UIFont.systemFont(ofSize: Ink.Size.small)
        labelMeasurer.numberOfLines = expanded ? 0 : 1
        labelMeasurer.text = "回望 · " + note
        let fitted = labelMeasurer.sizeThatFits(CGSize(width: max(40, maxWidth - 22), height: .greatestFiniteMagnitude))
        labelMeasurer.numberOfLines = 0
        return ceil(max(18, fitted.height))
    }

    nonisolated static func prepareCoreTextSource(_ attributed: NSAttributedString) -> NSAttributedString {
        guard attributed.length > 0 else { return attributed }
        if attributed.string.hasSuffix("\n") {
            let copy = NSMutableAttributedString(attributedString: attributed)
            let tailAttrs = attributed.attributes(at: attributed.length - 1, effectiveRange: nil)
            copy.append(NSAttributedString(string: "\u{200B}", attributes: tailAttrs))
            return NSAttributedString(attributedString: copy)
        }
        return attributed
    }

    nonisolated static func measureCoreTextMetrics(
        _ attributed: NSAttributedString,
        maxWidth: CGFloat,
        checkNarrowBoundary: Bool = false,
        knownLineCount: Int? = nil
    ) -> (size: CGSize, lineCount: Int) {
        guard attributed.length > 0 else { return (.zero, 0) }
        let measuredSource = prepareCoreTextSource(attributed)
        let framesetter = CTFramesetterCreateWithAttributedString(measuredSource as CFAttributedString)
        let isUnbounded = !maxWidth.isFinite || maxWidth > 1_000_000
        let constrainedWidth = isUnbounded ? CGFloat.greatestFiniteMagnitude : max(1, maxWidth)
        let wholeRange = CFRange(location: 0, length: measuredSource.length)
        let fitted = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            wholeRange,
            nil,
            CGSize(width: constrainedWidth, height: .greatestFiniteMagnitude),
            nil
        )
        var maxHeight = fitted.height
        var effectiveWidth: CGFloat = isUnbounded ? max(1000, ceil(fitted.width) + 64) : constrainedWidth
        if checkNarrowBoundary && !isUnbounded && fitted.width >= constrainedWidth - 3.0 {
            let narrowWidth = max(1, constrainedWidth - 2.0)
            let narrowFitted = CTFramesetterSuggestFrameSizeWithConstraints(
                framesetter,
                wholeRange,
                nil,
                CGSize(width: narrowWidth, height: .greatestFiniteMagnitude),
                nil
            )
            if narrowFitted.height > maxHeight {
                maxHeight = narrowFitted.height
                effectiveWidth = narrowWidth
            }
        }
        if let knownLineCount {
            return (CGSize(width: fitted.width, height: maxHeight), max(1, knownLineCount))
        }
        let path = CGPath(
            rect: CGRect(x: 0, y: 0, width: effectiveWidth, height: max(1000, ceil(maxHeight) + 64)),
            transform: nil
        )
        let frame = CTFramesetterCreateFrame(framesetter, wholeRange, path, nil)
        let lineCount = max(1, CFArrayGetCount(CTFrameGetLines(frame)))
        return (CGSize(width: fitted.width, height: maxHeight), lineCount)
    }

    nonisolated static func measureCoreTextSize(_ attributed: NSAttributedString, maxWidth: CGFloat) -> CGSize {
        measureCoreTextMetrics(attributed, maxWidth: maxWidth).size
    }

    func measureTextSize(rendered: ChatRenderedProse, maxWidth: CGFloat) -> CGSize {
        let insetHeight = rendered.topInset + rendered.bottomInset
        guard rendered.attributed.length > 0 else {
            return CGSize(width: 0, height: ceil(insetHeight))
        }
        let safeMaxWidth = max(1, maxWidth)
        let (fitted, lineCount) = Self.measureCoreTextMetrics(
            rendered.attributed,
            maxWidth: safeMaxWidth,
            checkNarrowBoundary: true
        )
        let width = min(safeMaxWidth, fitted.width > 0 ? ceil(fitted.width + 1.5) : 0)
        let height = ceil(fitted.height + insetHeight + max(1.0, CGFloat(lineCount) * 0.35))
        return CGSize(width: width, height: height)
    }
}
