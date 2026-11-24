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
}

struct ChatRenderedProse {
    let attributed: NSAttributedString
    let decorations: ChatBlockDecorations
    let topInset: CGFloat
    let bottomInset: CGFloat
    let renderToken: UInt64
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
    let fullAttributed: NSAttributedString
    let foldedContentSize: CGSize
    let fullContentSize: CGSize
}

struct ChatTableSlice {
    let table: Prose.Table
    let prepared: PreparsedTableModel
    let headerCells: [NSAttributedString]
    let rowCells: [[NSAttributedString]]
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

    private static var fontPairCache: [FontPairKey: AlignedFontPair] = [:]

    private static func tokenColor(_ kind: CodeTokenKind, isOutput: Bool) -> UIColor {
        if isOutput { return UIColor(Ink.Code.output) }
        switch kind {
        case .plain: return UIColor(Ink.ink)
        case .keyword: return UIColor(Ink.Code.keyword)
        case .function: return UIColor(Ink.Code.function)
        case .number: return UIColor(Ink.Code.number)
        case .string: return UIColor(Ink.Code.string)
        case .comment: return UIColor(Ink.inkFaint)
        }
    }

    private static func alignedCodeFonts(size: CGFloat, preference: Pref.Code, italic: Bool) -> AlignedFontPair {
        let key = FontPairKey(sizeKey: Int((size * 2).rounded()), codePref: preference, italic: italic)
        if let hit = fontPairCache[key] { return hit }

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
        if fontPairCache.count > 24 { fontPairCache.removeAll(keepingCapacity: true) }
        fontPairCache[key] = pair
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

        let out = NSMutableAttributedString()
        if model.hasWide {
            let regular = alignedCodeFonts(size: style.codeSize, preference: style.code, italic: false)
            let italic = alignedCodeFonts(size: style.codeSize, preference: style.code, italic: true)
            for seg in model.segments {
                let pair = seg.kind == .comment ? italic : regular
                let font = seg.isWide ? pair.wide : pair.narrow
                out.append(NSAttributedString(string: seg.text, attributes: [
                    .font: font,
                    .foregroundColor: tokenColor(seg.kind, isOutput: isOutput),
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
                    .foregroundColor: tokenColor(seg.kind, isOutput: isOutput),
                    .paragraphStyle: pStyle,
                ]))
            }
        }
        return out
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
        let blockHash: Int
        let isFirst: Bool
        let isLast: Bool
        let text: String
    }

    private struct StreamScannerEntry {
        var scanner: StreamBlocks
        var sealedBlocks: [Prose.Block]
    }

    private struct RichTextSliceKey: Hashable {
        let styleKey: String
        let blockHash: Int
        let keys: [String]
    }

    private var blockCache: [BlockCacheKey: BlockCacheEntry] = [:]
    private var richTextSliceCache: [RichTextSliceKey: ChatRenderedProse] = [:]
    private var streamScanners: [String: StreamScannerEntry] = [:]
    private var nextToken: UInt64 = 1

    private let codeSizeMeasurer: UITextView = {
        let tv = UITextView(usingTextLayoutManager: true)
        tv.isEditable = false
        tv.isSelectable = false
        tv.isScrollEnabled = false
        tv.textContainer.lineFragmentPadding = 0
        tv.textContainerInset = .zero
        return tv
    }()

    func clearCaches() {
        blockCache.removeAll(keepingCapacity: true)
        richTextSliceCache.removeAll(keepingCapacity: true)
        streamScanners.removeAll(keepingCapacity: true)
    }

    func resetStreamScanner(for key: String) {
        streamScanners.removeValue(forKey: key)
    }

    func buildUserText(_ text: String, style: ChatListStyle) -> ChatRenderedProse {
        let pStyle = NSMutableParagraphStyle()
        pStyle.lineSpacing = 4
        let font = UIFont.systemFont(ofSize: Ink.Size.body)
        let attr = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: UIColor(Ink.ink),
            .paragraphStyle: pStyle,
        ])
        let token = nextToken
        nextToken &+= 1
        return ChatRenderedProse(
            attributed: attr,
            decorations: ChatBlockDecorations(inlineCodeRanges: [], quoteBlocks: [], ruleRanges: []),
            topInset: 0,
            bottomInset: 0,
            renderToken: token
        )
    }

    func buildDisclosureText(_ text: String, style: ChatListStyle) -> ChatRenderedProse {
        let pStyle = NSMutableParagraphStyle()
        pStyle.lineSpacing = 3
        let attr = NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: Ink.Size.small),
            .foregroundColor: UIColor(Ink.inkSoft),
            .paragraphStyle: pStyle,
        ])
        let token = nextToken
        nextToken &+= 1
        return ChatRenderedProse(
            attributed: attr,
            decorations: ChatBlockDecorations(inlineCodeRanges: [], quoteBlocks: [], ruleRanges: []),
            topInset: 0,
            bottomInset: 0,
            renderToken: token
        )
    }

    func buildAssistantSlices(
        _ rawText: String,
        style: ChatListStyle,
        isStreaming: Bool,
        streamKey: String? = nil
    ) -> [ChatProseSlice] {
        let blocks = parseBlocks(rawText, isStreaming: isStreaming, streamKey: streamKey)
        if blocks.isEmpty {
            let pStyle = makeParagraphStyle(style: style)
            let placeholder = NSAttributedString(string: isStreaming ? " " : "", attributes: [
                .font: Ink.uiFace(style.readingSize, bold: false, face: style.face),
                .foregroundColor: UIColor(Ink.ink),
                .paragraphStyle: pStyle,
            ])
            let token = nextToken
            nextToken &+= 1
            return [
                .richText(ChatRenderedProse(
                    attributed: placeholder,
                    decorations: ChatBlockDecorations(inlineCodeRanges: [], quoteBlocks: [], ruleRanges: []),
                    topInset: 0,
                    bottomInset: 2,
                    renderToken: token
                ))
            ]
        }

        enum PendingSegment {
            case proseRun([Prose.Block])
            case block(Prose.Block)
        }

        var segments: [PendingSegment] = []
        var run: [Prose.Block] = []
        func flushRun() {
            if !run.isEmpty {
                segments.append(.proseRun(run))
                run = []
            }
        }

        for block in blocks {
            if isProseRunBlock(block) {
                run.append(block)
            } else {
                flushRun()
                segments.append(.block(block))
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

            case .block(let block):
                switch block {
                case .code(let lang, let codeText, let closed):
                    let liveCode = isStreaming && isLastSegment && !closed
                    let slice = buildCodeSlice(language: lang, rawText: codeText, isLive: liveCode, style: style)
                    slices.append(.code(slice, sliceIndex: sliceIdx))
                    sliceIdx += 1

                case .table(let table):
                    let slice = buildTableSlice(table, style: style)
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

    private func parseBlocks(_ rawText: String, isStreaming: Bool, streamKey: String?) -> [Prose.Block] {
        guard isStreaming else {
            if let streamKey { streamScanners.removeValue(forKey: streamKey) }
            return ParsedCache.blocks(rawText)
        }
        guard let streamKey else {
            return Prose.parse(Prose.mend(rawText))
        }
        var entry = streamScanners[streamKey] ?? StreamScannerEntry(scanner: StreamBlocks(), sealedBlocks: [])
        if rawText.utf8.count < entry.scanner.receivedBytes {
            entry = StreamScannerEntry(scanner: StreamBlocks(), sealedBlocks: [])
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
            return Prose.parse(Prose.mend(rawText))
        }
        let tailBlocks = Prose.parse(Prose.mend(entry.scanner.tail))
        return entry.sealedBlocks + tailBlocks
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
        let trimmed = CodeTokenizer.trimmedLines(rawText)
        let body = trimmed.isEmpty ? " " : trimmed
        let count = CodeTokenizer.lineCount(body)
        let isOutput = CodeTokenizer.isOutputBlock(language: language, text: body)
        let folds = !isLive && count > 20

        let fullAttr = ChatCodeHighlighter.highlight(body, language: language, isOutput: isOutput, style: style)
        let fullSize = measureCodeUnwrappedSize(fullAttr)

        let foldedAttr: NSAttributedString
        let foldedSize: CGSize
        if folds {
            let foldedBody = body.split(separator: "\n", omittingEmptySubsequences: false).prefix(12).joined(separator: "\n")
            foldedAttr = ChatCodeHighlighter.highlight(foldedBody, language: language, isOutput: isOutput, style: style)
            foldedSize = measureCodeUnwrappedSize(foldedAttr)
        } else {
            foldedAttr = fullAttr
            foldedSize = fullSize
        }

        return ChatCodeSlice(
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
            fullContentSize: fullSize
        )
    }

    private func measureCodeUnwrappedSize(_ attributed: NSAttributedString) -> CGSize {
        codeSizeMeasurer.attributedText = attributed
        let fitted = codeSizeMeasurer.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        return CGSize(width: ceil(fitted.width), height: ceil(fitted.height))
    }

    private func buildTableSlice(_ table: Prose.Table, style: ChatListStyle) -> ChatTableSlice {
        let prepared = TablePreparer.prepare(table)
        let columns = max(table.header.count, table.rows.map(\.count).max() ?? 0)
        let headerCells: [NSAttributedString] = (0..<columns).map { column in
            let align = column < table.aligns.count ? table.aligns[column] : .leading
            let source = column < prepared.header.count ? prepared.header[column] : AttributedString("")
            return buildTableCellAttributed(source, isHeader: true, align: align, style: style)
        }
        let rowCells: [[NSAttributedString]] = prepared.rows.map { row in
            (0..<columns).map { column in
                let align = column < table.aligns.count ? table.aligns[column] : .leading
                let source = column < row.count ? row[column] : AttributedString("")
                return buildTableCellAttributed(source, isHeader: false, align: align, style: style)
            }
        }
        let widths: [CGFloat] = (0..<columns).map { column in
            var natural: CGFloat = column < headerCells.count ? ceil(headerCells[column].size().width) : 0
            for row in rowCells where column < row.count {
                natural = max(natural, ceil(row[column].size().width))
            }
            return max(28, natural + 4)
        }
        return ChatTableSlice(
            table: table,
            prepared: prepared,
            headerCells: headerCells,
            rowCells: rowCells,
            naturalWidths: widths
        )
    }

    private func buildTableCellAttributed(
        _ source: AttributedString,
        isHeader: Bool,
        align: Prose.Table.Align,
        style: ChatListStyle
    ) -> NSAttributedString {
        let cellSize = style.tableCellSize
        let pStyle = NSMutableParagraphStyle()
        pStyle.lineSpacing = cellSize * 0.25
        switch align {
        case .center: pStyle.alignment = .center
        case .trailing: pStyle.alignment = .right
        case .leading: pStyle.alignment = .left
        }

        let ink = UIColor(Ink.ink)
        let out = NSMutableAttributedString()
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
                attrs[.font] = Ink.uiMono(max(CGFloat(12), cellSize - 2), preference: style.code)
                attrs[.foregroundColor] = UIColor(Ink.accent)
            }
            if isStrike {
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = run.link {
                attrs[.link] = link
                attrs[.foregroundColor] = UIColor(Ink.accent)
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            out.append(NSAttributedString(string: chunk, attributes: attrs))
        }
        return out
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
            if let hit = richTextSliceCache[candidate] {
                return hit
            }
            sliceCacheKey = candidate
        } else {
            sliceCacheKey = nil
        }

        let out = NSMutableAttributedString()
        var inlineCodeRanges: [NSRange] = []
        var quoteBlocks: [NSRange] = []
        var ruleRanges: [NSRange] = []

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
                    .font: Ink.uiFace(style.readingSize, bold: false, face: style.face),
                ]
                out.append(NSAttributedString(string: "\n", attributes: separatorAttrs))
            }
        }

        if fadeTail && out.length > 0 {
            applyStreamingTailFade(to: out)
        }

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

        let token = nextToken
        nextToken &+= 1
        let rendered = ChatRenderedProse(
            attributed: out,
            decorations: ChatBlockDecorations(
                inlineCodeRanges: inlineCodeRanges,
                quoteBlocks: quoteBlocks,
                ruleRanges: ruleRanges
            ),
            topInset: topInset,
            bottomInset: bottomInset,
            renderToken: token
        )
        if let sliceCacheKey {
            if richTextSliceCache.count > 1200 {
                richTextSliceCache.removeAll(keepingCapacity: true)
            }
            richTextSliceCache[sliceCacheKey] = rendered
        }
        return rendered
    }

    private func applyStreamingTailFade(to attributed: NSMutableAttributedString) {
        let raw = attributed.string
        let tailIndices = Array(raw.indices.suffix(12))
        let count = tailIndices.count
        guard count > 0 else { return }
        for (offset, strIndex) in tailIndices.enumerated() {
            let range = NSRange(strIndex..<raw.index(after: strIndex), in: raw)
            guard range.location >= 0, range.location + range.length <= attributed.length else { continue }
            guard let color = attributed.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? UIColor else { continue }
            let alpha = CGFloat(count - offset) / CGFloat(count + 1)
            attributed.addAttribute(.foregroundColor, value: color.withAlphaComponent(alpha), range: range)
        }
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
            blockHash: keyString.hashValue,
            isFirst: isFirst,
            isLast: isLast,
            text: keyString
        )
        if cacheable, let hit = blockCache[cacheKey] {
            return hit
        }

        let built = buildSingleBlock(block, style: style, isFirst: isFirst, isLast: isLast)
        if cacheable {
            if blockCache.count > 800 { blockCache.removeAll(keepingCapacity: true) }
            blockCache[cacheKey] = built
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
            let attr = buildInline(text, size: style.headingSize(level: level), bold: true, style: style, ink: UIColor(Ink.ink), paragraph: pStyle)
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
            let attr = buildInline(text, size: style.readingSize, bold: false, style: style, ink: UIColor(Ink.ink), paragraph: pStyle)
            return BlockCacheEntry(
                attributed: attr,
                trailingSeparatorStyle: pStyle,
                inlineCodeOffsets: extractInlineCodeRanges(in: attr),
                quoteSpan: nil,
                isRule: false
            )

        case .list(let items):
            let out = NSMutableAttributedString()
            let base = style.readingSize
            var lastPStyle = makeParagraphStyle(style: style, spacing: isLast ? 0 : style.paragraphGap)
            for (itemIndex, item) in items.enumerated() {
                let marker: String
                let markerSize: CGFloat
                let markerColor: UIColor
                if let checked = item.checked {
                    marker = checked ? "☑︎" : "☐"
                    markerSize = base
                    markerColor = UIColor(checked ? Ink.accent : Ink.inkFaint)
                } else if let number = item.number {
                    marker = "\(number)."
                    markerSize = base * 0.92
                    markerColor = UIColor(Ink.inkFaint)
                } else {
                    marker = item.depth == 0 ? "•" : (item.depth == 1 ? "◦" : "▪")
                    markerSize = base * (item.depth == 0 ? 0.95 : 0.78)
                    markerColor = UIColor(Ink.inkFaint)
                }
                let indent = CGFloat(item.depth) * base * 1.25
                let hang = item.number != nil ? base * 1.75 : base * 1.25
                let itemLast = itemIndex == items.count - 1
                let spacing = itemLast ? (isLast ? 0 : style.paragraphGap) : style.listSpacing
                let pStyle = makeParagraphStyle(style: style, spacing: spacing, indent: indent, hanging: hang)
                lastPStyle = pStyle
                if itemIndex > 0 {
                    out.append(NSAttributedString(string: "\n", attributes: [
                        .font: Ink.uiFace(base, face: style.face),
                        .paragraphStyle: pStyle,
                    ]))
                }
                out.append(NSAttributedString(string: marker + "\t", attributes: [
                    .font: Ink.uiFace(markerSize, face: style.face),
                    .foregroundColor: markerColor,
                    .paragraphStyle: pStyle,
                ]))
                out.append(buildInline(item.text, size: base, bold: false, style: style, ink: UIColor(Ink.ink), paragraph: pStyle))
            }
            return BlockCacheEntry(
                attributed: out,
                trailingSeparatorStyle: lastPStyle,
                inlineCodeOffsets: extractInlineCodeRanges(in: out),
                quoteSpan: nil,
                isRule: false
            )

        case .quote(let inner):
            let out = NSMutableAttributedString()
            let indent = Ink.Space.l + 4
            let tail = -Ink.Space.m
            let cardPadV = Ink.Space.m
            let quoteInk = UIColor(Ink.inkSoft)
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
                        .font: Ink.uiFace(style.readingSize, face: style.face),
                        .paragraphStyle: lastPStyle,
                    ]))
                }
                lastPStyle = pStyle
                let textSize = line.isHeading ? style.headingSize(level: 3) : style.readingSize
                out.append(buildInline(line.text, size: textSize, bold: line.isHeading, style: style, ink: quoteInk, paragraph: pStyle))
            }
            if out.length == 0 {
                out.append(NSAttributedString(string: " ", attributes: [
                    .font: Ink.uiFace(style.readingSize, face: style.face),
                    .foregroundColor: quoteInk,
                    .paragraphStyle: lastPStyle,
                ]))
            }
            let span = NSRange(location: 0, length: out.length)
            return BlockCacheEntry(
                attributed: out,
                trailingSeparatorStyle: lastPStyle,
                inlineCodeOffsets: extractInlineCodeRanges(in: out),
                quoteSpan: span,
                isRule: false
            )

        case .rule:
            let pStyle = NSMutableParagraphStyle()
            pStyle.paragraphSpacingBefore = isFirst ? 0 : style.paragraphGap * 0.35
            pStyle.paragraphSpacing = isLast ? 0 : style.paragraphGap * 0.85
            pStyle.maximumLineHeight = Ink.Size.micro
            pStyle.minimumLineHeight = Ink.Size.micro
            let attr = NSAttributedString(string: "\u{200B}", attributes: [
                .font: UIFont.systemFont(ofSize: Ink.Size.micro),
                .foregroundColor: UIColor.clear,
                .paragraphStyle: pStyle,
            ])
            return BlockCacheEntry(
                attributed: attr,
                trailingSeparatorStyle: pStyle,
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
    ) -> NSMutableParagraphStyle {
        let pStyle = NSMutableParagraphStyle()
        pStyle.lineSpacing = tight ? style.leading * 0.5 : style.leading
        pStyle.paragraphSpacing = spacing
        pStyle.paragraphSpacingBefore = before
        pStyle.firstLineHeadIndent = indent
        pStyle.headIndent = indent + hanging
        if tailIndent != 0 { pStyle.tailIndent = tailIndent }
        if hanging > 0 { pStyle.tabStops = [NSTextTab(textAlignment: .left, location: indent + hanging)] }
        return pStyle
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
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            let isBold = bold || run.bold
            var font = Ink.uiFace(size, bold: isBold, face: style.face)
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
                attributes[.font] = Ink.uiMono(max(CGFloat(12), size - 2), preference: style.code)
                attributes[.foregroundColor] = UIColor(Ink.accent)
                attributes[.chatInlineCode] = true
            }
            if run.strikethrough {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = run.link {
                attributes[.link] = link
                attributes[.foregroundColor] = UIColor(Ink.accent)
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            out.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return out
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
        let text: String
        let reasoning: String
        let pulse: String
        let lookbackNote: String
        let lookbackRest: String
        let opens: Bool
        let faces: Bool
        let isRoom: Bool
        let showThinking: Bool
        let showStats: Bool
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
    }

    private struct UserKey: Hashable {
        let id: String
        let styleKey: String
        let widthKey: Int
        let text: String
        let photoCount: Int
        let isFirst: Bool
        let opens: Bool
        let faces: Bool
        let hasTimeGap: Bool
    }

    let builder = ChatProseBuilder()

    private var assistantFinalizedCache: [AssistantKey: AssistantLayoutEntry] = [:]
    private var assistantStreamingCache: [String: (key: AssistantKey, entry: AssistantLayoutEntry)] = [:]
    private var userCache: [UserKey: UserLayoutEntry] = [:]
    private var blockHeightOverrides: [String: CGFloat] = [:]
    private var hostingHeights: [String: CGFloat] = [:]
    private var overrideVersionsByOwner: [String: UInt64] = [:]

    private let textMeasurer: UITextView = {
        let tv = UITextView(usingTextLayoutManager: true)
        tv.isEditable = false
        tv.isSelectable = false
        tv.isScrollEnabled = false
        tv.textContainer.lineFragmentPadding = 0
        tv.linkTextAttributes = [:]
        return tv
    }()

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
        assistantFinalizedCache.removeAll(keepingCapacity: true)
        assistantStreamingCache.removeAll(keepingCapacity: true)
        userCache.removeAll(keepingCapacity: true)
        builder.clearCaches()
    }

    func invalidateMessage(id: String) {
        assistantStreamingCache.removeValue(forKey: id)
        assistantFinalizedCache = assistantFinalizedCache.filter { $0.key.id != id }
        userCache = userCache.filter { $0.key.id != id }
    }

    func setBlockHeightOverride(_ height: CGFloat, key: String, ownerID: String) -> Bool {
        let rounded = ceil(height)
        if let old = blockHeightOverrides[key], abs(old - rounded) <= 0.5 {
            return false
        }
        blockHeightOverrides[key] = rounded
        overrideVersionsByOwner[ownerID, default: 1] &+= 1
        assistantStreamingCache.removeValue(forKey: ownerID)
        return true
    }

    func hostingHeight(for key: String) -> CGFloat? {
        hostingHeights[key]
    }

    func setHostingHeight(_ height: CGFloat, for key: String) -> Bool {
        let rounded = ceil(height)
        if let old = hostingHeights[key], abs(old - rounded) <= 0.5 {
            return false
        }
        hostingHeights[key] = rounded
        return true
    }

    func measureHostingView<V: View>(_ view: V, width: CGFloat, cacheKey: String) -> CGFloat {
        if let hit = hostingHeights[cacheKey] { return hit }
        hostingMeasurer.rootView = AnyView(view)
        let size = hostingMeasurer.sizeThatFits(in: CGSize(width: max(120, width), height: CGFloat.greatestFiniteMagnitude))
        let h = max(24, ceil(size.height))
        if hostingHeights.count > 600 { hostingHeights.removeAll(keepingCapacity: true) }
        hostingHeights[cacheKey] = h
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
        if let hit = userCache[key] { return hit }

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
        if userCache.count > 1200 { userCache.removeAll(keepingCapacity: true) }
        userCache[key] = entry
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
            showStats: row.showStats,
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
            if let hit = assistantFinalizedCache[key] {
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
            if assistantFinalizedCache.count > 1000 {
                assistantFinalizedCache.removeAll(keepingCapacity: true)
            }
            assistantFinalizedCache[key] = entry
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
        return AssistantLayoutEntry(
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
                let bodySize = (codeSlice.folds && !unfolded) ? codeSlice.foldedContentSize : codeSlice.fullContentSize
                let bodyH = max(16, bodySize.height) + Ink.Space.m * 2
                let foldH = codeSlice.folds ? style.codeFoldButtonHeight : 0
                let total = ceil(style.codeHeaderHeight + bodyH + foldH)
                return MeasuredSlice(slice: slice, height: total, pictureHeights: [])

            case .table(let tableSlice, _):
                let h = ChatTableBlockView.measureHeight(slice: tableSlice, maxWidth: contentWidth, style: style)
                return MeasuredSlice(slice: slice, height: ceil(h), pictureHeights: [])

            case .math(let latex, let isLive, _):
                let h = ChatFormulaBlockView.measureHeight(latex: latex, maxWidth: contentWidth, style: style, streaming: isLive)
                return MeasuredSlice(slice: slice, height: ceil(h), pictureHeights: [])

            case .fileCards(let links, let sliceIndex):
                let key = "file|\(ownerID)|\(sliceIndex)|\(widthKey)|\(links.map(\.path).joined(separator: "|"))"
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
                    let key = "pic|\(ownerID)|\(sliceIndex)|\(picIndex)|\(widthKey)|\(pic.source)"
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
        let contentWidth = max(120, collectionWidth - Ink.Space.page * 2)
        if line.fold {
            return NoteLayoutEntry(titleHeight: 36, detailHeight: 0, cellHeight: ceil(36 + ChatCellMetrics.rowSpacing))
        }
        if let next = line.next {
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
            return NoteLayoutEntry(titleHeight: titleH, detailHeight: detailH, cellHeight: ceil(total + ChatCellMetrics.rowSpacing))
        }
        labelMeasurer.font = UIFont.systemFont(ofSize: Ink.Size.small)
        labelMeasurer.text = line.text
        let h = ceil(labelMeasurer.sizeThatFits(CGSize(width: contentWidth, height: .greatestFiniteMagnitude)).height)
        return NoteLayoutEntry(titleHeight: h, detailHeight: 0, cellHeight: ceil(h + ChatCellMetrics.rowSpacing))
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

    func measureTextSize(rendered: ChatRenderedProse, maxWidth: CGFloat) -> CGSize {
        textMeasurer.attributedText = rendered.attributed
        textMeasurer.textContainerInset = UIEdgeInsets(top: rendered.topInset, left: 0, bottom: rendered.bottomInset, right: 0)
        let fitted = textMeasurer.sizeThatFits(CGSize(width: maxWidth, height: .greatestFiniteMagnitude))
        return CGSize(width: min(maxWidth, ceil(fitted.width)), height: ceil(fitted.height))
    }
}
