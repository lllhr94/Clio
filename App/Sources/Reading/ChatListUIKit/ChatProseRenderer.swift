import AgentKit
import CoreText
import Craft
import Foundation
import Prose
import SwiftMath
import SwiftUI
import UIKit

struct ChatBlockDecorations: Equatable, Sendable {
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

struct ChatRenderedProse: @unchecked Sendable {
    let attributed: NSAttributedString
    let decorations: ChatBlockDecorations
    let topInset: CGFloat
    let bottomInset: CGFloat
    let renderToken: UInt64
    let hasLinks: Bool
    let liveTailIndex: Int?
    let spacingAfter: CGFloat?

    init(
        attributed: NSAttributedString,
        decorations: ChatBlockDecorations,
        topInset: CGFloat,
        bottomInset: CGFloat,
        renderToken: UInt64,
        hasLinks: Bool,
        liveTailIndex: Int? = nil,
        spacingAfter: CGFloat? = nil
    ) {
        self.attributed = attributed
        self.decorations = decorations
        self.topInset = topInset
        self.bottomInset = bottomInset
        self.renderToken = renderToken
        self.hasLinks = hasLinks
        self.liveTailIndex = liveTailIndex
        self.spacingAfter = spacingAfter
    }

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

struct ChatCodeSlice: @unchecked Sendable {
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

struct ChatTableSlice: Equatable, @unchecked Sendable {
    let sliceID: UInt64
    let table: Prose.Table
    let prepared: PreparsedTableModel
    let headerCells: [NSAttributedString]
    let rowCells: [[NSAttributedString]]
    let headerHasLinks: [Bool]
    let rowHasLinks: [[Bool]]
    let naturalWidths: [CGFloat]
}

enum ChatProseSlice: @unchecked Sendable {
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
enum ChatCodeHighlighter {
    static func highlight(
        _ text: String,
        language: String,
        isOutput: Bool,
        style: ChatListStyle
    ) -> NSAttributedString {
        let model = CodeTokenizer.prepare(text, language: language, isOutput: isOutput)
        return highlight(segments: model.segments, hasWide: model.hasWide, isOutput: isOutput, style: style)
    }

    static func highlight(
        segments: [CodeTokenSegment],
        hasWide: Bool,
        isOutput: Bool,
        style: ChatListStyle
    ) -> NSAttributedString {
        let immutableParagraphStyle = style.metrics.codeBox.makeParagraphStyle()

        let colors = style.colors
        let outputColor = isOutput ? colors.codeOutput : nil
        let plainColor = outputColor ?? colors.ink
        let keywordColor = outputColor ?? colors.codeKeyword
        let functionColor = outputColor ?? colors.codeFunction
        let numberColor = outputColor ?? colors.codeNumber
        let stringColor = outputColor ?? colors.codeString
        let commentColor = outputColor ?? colors.inkFaint
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

        let fonts = style.fonts
        let out = NSMutableAttributedString()
        out.beginEditing()
        if hasWide {
            for seg in segments {
                let font: UIFont
                if seg.kind == .comment {
                    font = seg.isWide ? fonts.codeAlignedItalicWide : fonts.codeAlignedItalicNarrow
                } else {
                    font = seg.isWide ? fonts.codeAlignedRegularWide : fonts.codeAlignedRegularNarrow
                }
                out.append(NSAttributedString(string: seg.text, attributes: [
                    .font: font,
                    .foregroundColor: color(for: seg.kind),
                    .paragraphStyle: immutableParagraphStyle,
                ]))
            }
        } else {
            for seg in segments {
                let font = seg.kind == .comment ? fonts.codePlainItalic : fonts.codePlainRegular
                out.append(NSAttributedString(string: seg.text, attributes: [
                    .font: font,
                    .foregroundColor: color(for: seg.kind),
                    .paragraphStyle: immutableParagraphStyle,
                ]))
            }
        }
        out.endEditing()
        return NSAttributedString(attributedString: out)
    }
}

/// Incremental + cached prose builder producing continuous rich-text runs and interactive block slices.
final class ChatProseBuilder: @unchecked Sendable {
    private static let picturePattern = try? NSRegularExpression(pattern: #"!\[([^\]]*)\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)"#)
    private static let numericCellPattern = try? NSRegularExpression(pattern: #"^[\s±+\-$€¥£]*[\d,]+(?:\.\d+)?(?:\s*(?:%|ms|s|Hz|pt|em|px|KB|MB|GB|TB|Tokens|tokens|倍|次|行|:1))?\s*$"#)

    private struct BlockCacheEntry: @unchecked Sendable {
        let attributed: NSAttributedString
        let trailingSeparatorStyle: NSParagraphStyle
        let inlineCodeOffsets: [NSRange]
        let quoteSpan: NSRange?
        let isRule: Bool
    }

    private struct BlockCacheKey: Hashable, Sendable {
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

    private struct StreamScannerEntry: @unchecked Sendable {
        var scanner: StreamBlocks
        var sealedBlocks: [Prose.Block]
        var sealedStyleKey: String
        var sealedCodeSlices: [Int: ChatCodeSlice] = [:]
        var sealedTableSlices: [Int: ChatTableSlice] = [:]
        var liveCodeTokenizers: [Int: IncrementalCodeTokenizer] = [:]
    }

    private struct RichTextSliceKey: Hashable, Sendable {
        let styleKey: String
        let blockHash: Int
        let keys: [String]
    }

    private struct CodeSliceKey: Hashable, Sendable {
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

    private struct TableSliceKey: Hashable, Sendable {
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
    private let scannerLock = NSLock()
    private var streamScanners: [String: StreamScannerEntry] = [:]
    private static let tokenLock = NSLock()
    private static var nextToken: UInt64 = 1

    private static func nextGlobalRenderToken() -> UInt64 {
        tokenLock.lock()
        let token = nextToken
        nextToken &+= 1
        if nextToken == 0 {
            nextToken = 1
        }
        tokenLock.unlock()
        return token
    }

    private func allocateRenderToken() -> UInt64 {
        Self.nextGlobalRenderToken()
    }

    func clearCaches() {
        blockCache.removeAll()
        richTextSliceCache.removeAll()
        codeSliceCache.removeAll()
        tableSliceCache.removeAll()
        scannerLock.lock()
        streamScanners.removeAll(keepingCapacity: true)
        scannerLock.unlock()
    }

    func resetStreamScanner(for key: String) {
        scannerLock.lock()
        streamScanners.removeValue(forKey: key)
        scannerLock.unlock()
    }

    func buildUserText(_ text: String, style: ChatListStyle) -> ChatRenderedProse {
        let box = style.metrics.userBox
        let pStyle = box.makeParagraphStyle()
        var attrs: [NSAttributedString.Key: Any] = [
            .font: style.fonts.userBody,
            .foregroundColor: style.colors.ink,
            .paragraphStyle: pStyle,
        ]
        if box.trackingPoints != 0 {
            attrs[.kern] = NSNumber(value: Double(box.trackingPoints))
        }
        let mutable = NSMutableAttributedString(string: text, attributes: attrs)
        ClioMixedScriptKerning.apply(
            to: mutable,
            fontSize: box.effectivePointSize,
            squeezePunctuation: style.metrics.clreqSqueeze
        )
        let token = allocateRenderToken()
        return ChatRenderedProse(
            attributed: NSAttributedString(attributedString: mutable),
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
        let immutableStyle = (pStyle.copy() as? NSParagraphStyle) ?? pStyle
        let attr = NSAttributedString(string: text, attributes: [
            .font: style.fonts.disclosureSmall,
            .foregroundColor: style.colors.inkSoft,
            .paragraphStyle: immutableStyle,
        ])
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
            let pStyle = style.metrics.bodyBox.makeParagraphStyle()
            let placeholder = NSAttributedString(string: isStreaming ? " " : "", attributes: [
                .font: style.fonts.reading.regular,
                .foregroundColor: style.colors.ink,
                .paragraphStyle: pStyle,
            ])
            let token = allocateRenderToken()
            return [
                .richText(ChatRenderedProse(
                    attributed: placeholder,
                    decorations: .empty,
                    topInset: 0,
                    bottomInset: 2,
                    renderToken: token,
                    hasLinks: false,
                    liveTailIndex: isStreaming ? 0 : nil
                ))
            ]
        }

        enum PendingSegment {
            case proseRun(blocks: [Prose.Block], isMessageTop: Bool, containsLiveTail: Bool)
            case block(Prose.Block, sealedIndex: Int?, isMessageTop: Bool)
        }

        var segments: [PendingSegment] = []
        var run: [Prose.Block] = []
        var runStartIndex = 0
        func flushRun(containsLiveTail: Bool) {
            if !run.isEmpty {
                segments.append(.proseRun(blocks: run, isMessageTop: runStartIndex == 0, containsLiveTail: containsLiveTail))
                run = []
            }
        }

        for blockIndex in blocks.indices {
            if isStreaming && sealedCount > 0 && blockIndex == sealedCount {
                flushRun(containsLiveTail: false)
            }
            let block = blocks[blockIndex]
            if isProseRunBlock(block) {
                if run.isEmpty { runStartIndex = blockIndex }
                run.append(block)
            } else {
                let runHasTail = isStreaming && runStartIndex >= sealedCount
                flushRun(containsLiveTail: runHasTail)
                let sealedIndex: Int? = blockIndex < sealedCount ? blockIndex : nil
                segments.append(.block(block, sealedIndex: sealedIndex, isMessageTop: blockIndex == 0))
            }
        }
        flushRun(containsLiveTail: isStreaming && runStartIndex >= sealedCount)

        var slices: [ChatProseSlice] = []
        var sliceIdx = 0
        for segIndex in segments.indices {
            let isLastSegment = segIndex == segments.count - 1
            let isFollowedBySegment = !isLastSegment
            switch segments[segIndex] {
            case .proseRun(let runBlocks, let isMessageTop, let containsLiveTail):
                let hasLiveTail = isStreaming && containsLiveTail && isLastSegment
                let rendered = buildRichTextSlice(
                    blocks: runBlocks,
                    style: style,
                    isStreaming: hasLiveTail,
                    isMessageTop: isMessageTop,
                    isFollowedBySegment: isFollowedBySegment,
                    liveTailIndex: hasLiveTail ? sealedCount : nil
                )
                slices.append(.richText(rendered))
                sliceIdx += 1

            case .block(let block, let sealedIndex, let isMessageTop):
                switch block {
                case .code(let lang, let codeText, let closed):
                    let liveCode = isStreaming && isLastSegment && !closed
                    let slice: ChatCodeSlice
                    var cachedSealed: ChatCodeSlice?
                    if !liveCode, let streamKey, let sealedIndex {
                        scannerLock.lock()
                        cachedSealed = streamScanners[streamKey]?.sealedCodeSlices[sealedIndex]
                        scannerLock.unlock()
                    }
                    if let cachedSealed {
                        slice = cachedSealed
                    } else {
                        let built = buildCodeSlice(
                            language: lang,
                            rawText: codeText,
                            isLive: liveCode,
                            style: style,
                            streamKey: streamKey,
                            sliceIndex: sliceIdx
                        )
                        if !liveCode, let streamKey, let sealedIndex {
                            scannerLock.lock()
                            streamScanners[streamKey]?.sealedCodeSlices[sealedIndex] = built
                            streamScanners[streamKey]?.liveCodeTokenizers.removeValue(forKey: sliceIdx)
                            scannerLock.unlock()
                        }
                        slice = built
                    }
                    slices.append(.code(slice, sliceIndex: sliceIdx))
                    sliceIdx += 1

                case .table(let table):
                    let isSealed = sealedIndex != nil || !(isStreaming && isLastSegment)
                    let slice: ChatTableSlice
                    var cachedSealed: ChatTableSlice?
                    if isSealed, let streamKey, let sealedIndex {
                        scannerLock.lock()
                        cachedSealed = streamScanners[streamKey]?.sealedTableSlices[sealedIndex]
                        scannerLock.unlock()
                    }
                    if let cachedSealed {
                        slice = cachedSealed
                    } else {
                        let built = buildTableSlice(table, style: style, cacheable: isSealed)
                        if isSealed, let streamKey, let sealedIndex {
                            scannerLock.lock()
                            streamScanners[streamKey]?.sealedTableSlices[sealedIndex] = built
                            scannerLock.unlock()
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
                            let hasLiveWords = isStreaming && isLastSegment
                            wordsProse = buildRichTextSlice(
                                blocks: [.paragraph(split.words)],
                                style: style,
                                isStreaming: hasLiveWords,
                                isMessageTop: isMessageTop,
                                isFollowedBySegment: isFollowedBySegment,
                                liveTailIndex: hasLiveWords ? sealedCount : nil
                            )
                        } else {
                            wordsProse = nil
                        }
                        let pics = split.pictures.map { PreparsedPictureLink(label: $0.label, source: $0.source) }
                        slices.append(.pictures(words: wordsProse, pics: pics, sliceIndex: sliceIdx))
                        sliceIdx += 1
                    } else {
                        let hasLiveWords = isStreaming && isLastSegment
                        let rendered = buildRichTextSlice(
                            blocks: [block],
                            style: style,
                            isStreaming: hasLiveWords,
                            isMessageTop: isMessageTop,
                            isFollowedBySegment: isFollowedBySegment,
                            liveTailIndex: hasLiveWords ? sealedCount : nil
                        )
                        slices.append(.richText(rendered))
                        sliceIdx += 1
                    }

                default:
                    let hasLiveWords = isStreaming && isLastSegment
                    let rendered = buildRichTextSlice(
                        blocks: [block],
                        style: style,
                        isStreaming: hasLiveWords,
                        isMessageTop: isMessageTop,
                        isFollowedBySegment: isFollowedBySegment,
                        liveTailIndex: hasLiveWords ? sealedCount : nil
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
            if let streamKey {
                scannerLock.lock()
                streamScanners.removeValue(forKey: streamKey)
                scannerLock.unlock()
            }
            return (ParsedCache.blocks(rawText), 0)
        }
        guard let streamKey else {
            return (Prose.parse(Prose.mend(rawText)), 0)
        }
        scannerLock.lock()
        defer { scannerLock.unlock() }
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
        style: ChatListStyle,
        streamKey: String? = nil,
        sliceIndex: Int = 0
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
        let folds = !isLive && count > 18

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
            let highlighted: NSAttributedString
            if isLive, let streamKey {
                let canonical = IncrementalCodeTokenizer.canonicalLanguage(language)
                scannerLock.lock()
                var tokenizer = streamScanners[streamKey]?.liveCodeTokenizers[sliceIndex]
                if tokenizer == nil || tokenizer?.language != canonical || tokenizer?.isOutput != isOutput {
                    tokenizer = IncrementalCodeTokenizer(language: canonical, isOutput: isOutput)
                }
                let segments = tokenizer!.update(source: body)
                let hasWide = tokenizer!.hasWide
                streamScanners[streamKey]?.liveCodeTokenizers[sliceIndex] = tokenizer
                scannerLock.unlock()
                highlighted = NSAttributedString(attributedString: ChatCodeHighlighter.highlight(
                    segments: segments,
                    hasWide: hasWide,
                    isOutput: isOutput,
                    style: style
                ))
            } else {
                highlighted = NSAttributedString(attributedString: ChatCodeHighlighter.highlight(body, language: language, isOutput: isOutput, style: style))
            }
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
        var numericColumns = Array(repeating: false, count: columns)
        var resolvedAligns = Array(repeating: Prose.Table.Align.leading, count: columns)
        for column in 0..<columns {
            let declared = column < table.aligns.count ? table.aligns[column] : .leading
            let isNumeric = Self.isNumericColumn(column: column, in: table.rows)
            numericColumns[column] = isNumeric
            resolvedAligns[column] = (declared == .leading && isNumeric) ? .trailing : declared
        }
        var headerCells: [NSAttributedString] = []
        var headerHasLinks: [Bool] = []
        headerCells.reserveCapacity(columns)
        headerHasLinks.reserveCapacity(columns)
        for column in 0..<columns {
            let align = resolvedAligns[column]
            let isNumeric = numericColumns[column]
            let source = column < prepared.header.count ? prepared.header[column] : AttributedString("")
            let built = buildTableCellAttributed(source, isHeader: true, align: align, isNumeric: isNumeric, style: style)
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
                let align = resolvedAligns[column]
                let isNumeric = numericColumns[column]
                let source = column < row.count ? row[column] : AttributedString("")
                let built = buildTableCellAttributed(source, isHeader: false, align: align, isNumeric: isNumeric, style: style)
                cells.append(built.attributed)
                links.append(built.hasLink)
            }
            rowCells.append(cells)
            rowHasLinks.append(links)
        }

        let widths: [CGFloat] = (0..<columns).map { column in
            var natural: CGFloat = column < headerCells.count ? Self.naturalSingleLineWidth(headerCells[column]) : 0
            for row in rowCells where column < row.count {
                natural = max(natural, Self.naturalSingleLineWidth(row[column]))
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

    private static func naturalSingleLineWidth(_ attributed: NSAttributedString) -> CGFloat {
        guard attributed.length > 0 else { return 0 }
        let rect = attributed.boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        return ceil(rect.width)
    }

    private static func isNumericColumn(column: Int, in rows: [[String]]) -> Bool {
        guard let pattern = numericCellPattern else { return false }
        var nonEmpty = 0
        var numeric = 0
        for row in rows where column < row.count {
            let stripped = row[column]
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "`", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !stripped.isEmpty else { continue }
            nonEmpty += 1
            let range = NSRange(stripped.startIndex..., in: stripped)
            if pattern.firstMatch(in: stripped, range: range) != nil {
                numeric += 1
            }
        }
        return nonEmpty > 0 && numeric * 10 >= nonEmpty * 7
    }

    private func buildTableCellAttributed(
        _ source: AttributedString,
        isHeader: Bool,
        align: Prose.Table.Align,
        isNumeric: Bool,
        style: ChatListStyle
    ) -> (attributed: NSAttributedString, hasLink: Bool) {
        let alignment: NSTextAlignment
        switch align {
        case .center: alignment = .center
        case .trailing: alignment = .right
        case .leading: alignment = .left
        }
        let immutableParagraphStyle = style.metrics.tableBox.makeParagraphStyle(alignment: alignment)

        let ink = style.colors.ink
        let accent = style.colors.accent
        let tableFonts = style.fonts.table
        let monoFont = tableFonts.inlineCode
        let tableStroke = style.metrics.opticalProfile.tableBoldStroke
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

            let font: UIFont
            if isNumeric && !isItalic && !isCode {
                font = isBold ? style.fonts.tableNumericBold : style.fonts.tableNumericRegular
            } else if isBold {
                font = isItalic ? tableFonts.boldItalic : tableFonts.bold
            } else {
                font = isItalic ? tableFonts.italic : tableFonts.regular
            }
            var attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: ink,
                .paragraphStyle: immutableParagraphStyle,
            ]
            if tableStroke != 0, isBold, !isCode {
                attrs[.strokeWidth] = Double(tableStroke)
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
        ClioMixedScriptKerning.apply(
            to: out,
            fontSize: style.metrics.tableBox.effectivePointSize,
            squeezePunctuation: style.metrics.clreqSqueeze
        )
        return (NSAttributedString(attributedString: out), hasLink)
    }

    private func buildRichTextSlice(
        blocks: [Prose.Block],
        style: ChatListStyle,
        isStreaming: Bool,
        isMessageTop: Bool = true,
        isFollowedBySegment: Bool = false,
        liveTailIndex: Int? = nil
    ) -> ChatRenderedProse {
        let sliceCacheKey: RichTextSliceKey?
        if !isStreaming && liveTailIndex == nil {
            var keys = blocks.map { cacheKeyString(for: $0) }
            keys.append("meta:\(isMessageTop ? 1 : 0)|\(isFollowedBySegment ? 1 : 0)")
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
        let separatorFont = style.fonts.reading.regular

        for index in blocks.indices {
            let block = blocks[index]
            let isFirst = isMessageTop && index == 0
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
        out.endEditing()

        let topInset: CGFloat
        if case .quote = blocks.first {
            topInset = style.metrics.spaceM
        } else if !isMessageTop, case .heading(let level, _) = blocks.first {
            topInset = style.headingTop(level: level)
        } else {
            topInset = 0
        }

        let bottomInset: CGFloat
        if case .quote = blocks.last {
            bottomInset = style.metrics.spaceM
        } else {
            bottomInset = isFollowedBySegment ? 0 : 2
        }

        let spacingAfter: CGFloat?
        if isFollowedBySegment {
            if case .heading(let level, _) = blocks.last {
                spacingAfter = style.headingBottom(level: level)
            } else if case .quote = blocks.last {
                spacingAfter = style.metrics.spaceM + style.paragraphGap
            } else {
                spacingAfter = style.paragraphGap
            }
        } else {
            spacingAfter = nil
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
            hasLinks: Self.containsLinks(immutable),
            liveTailIndex: liveTailIndex,
            spacingAfter: spacingAfter
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
            let spacing = isLast ? 0 : style.headingBottom(level: level)
            let box = style.metrics.headingBox(level: level)
            let pStyle = box.makeParagraphStyle(spacing: spacing, before: before)
            let attr = buildInline(
                text,
                fontGroup: style.fonts.headingGroup(level: level),
                box: box,
                bold: level <= 3,
                isHeading: true,
                headingLevel: level,
                style: style,
                ink: style.colors.ink,
                paragraph: pStyle
            )
            return BlockCacheEntry(
                attributed: attr,
                trailingSeparatorStyle: pStyle,
                inlineCodeOffsets: extractInlineCodeRanges(in: attr),
                quoteSpan: nil,
                isRule: false
            )

        case .paragraph(let text):
            let box = style.metrics.bodyBox
            let spacing = isLast ? 0 : style.paragraphGap
            let pStyle = box.makeParagraphStyle(spacing: spacing)
            let attr = buildInline(
                text,
                fontGroup: style.fonts.reading,
                box: box,
                bold: false,
                style: style,
                ink: style.colors.ink,
                paragraph: pStyle
            )
            return BlockCacheEntry(
                attributed: attr,
                trailingSeparatorStyle: pStyle,
                inlineCodeOffsets: extractInlineCodeRanges(in: attr),
                quoteSpan: nil,
                isRule: false
            )

        case .list(let items):
            let box = style.metrics.listBox
            let out = NSMutableAttributedString()
            out.beginEditing()
            let base = style.readingSize
            let bodyInk = style.colors.ink
            let faintInk = style.colors.inkFaint
            let accentInk = style.colors.accent
            let separatorFont = style.fonts.reading.regular
            var lastPStyle = box.makeParagraphStyle(spacing: isLast ? 0 : style.paragraphGap)
            for (itemIndex, item) in items.enumerated() {
                let marker: String
                let markerFont: UIFont
                let markerColor: UIColor
                if let checked = item.checked {
                    marker = checked ? "☑︎" : "☐"
                    markerFont = style.fonts.reading.regular
                    markerColor = checked ? accentInk : faintInk
                } else if let number = item.number {
                    marker = "\(number)."
                    markerFont = style.fonts.listNumberMarker
                    markerColor = faintInk
                } else {
                    marker = item.depth == 0 ? "•" : (item.depth == 1 ? "◦" : "▪")
                    markerFont = item.depth == 0 ? style.fonts.listBulletDepth0 : style.fonts.listBulletDepthNested
                    markerColor = faintInk
                }
                let indent = CGFloat(item.depth) * base * 1.25
                let hang = item.number != nil ? base * 1.75 : base * 1.25
                let itemLast = itemIndex == items.count - 1
                let spacing = itemLast ? (isLast ? 0 : style.paragraphGap) : style.listSpacing
                let pStyle = box.makeParagraphStyle(spacing: spacing, indent: indent, hanging: hang)
                lastPStyle = pStyle
                if itemIndex > 0 {
                    out.append(NSAttributedString(string: "\n", attributes: [
                        .font: separatorFont,
                        .paragraphStyle: pStyle,
                    ]))
                }
                out.append(NSAttributedString(string: marker + "\t", attributes: [
                    .font: markerFont,
                    .foregroundColor: markerColor,
                    .paragraphStyle: pStyle,
                ]))
                out.append(buildInline(
                    item.text,
                    fontGroup: style.fonts.reading,
                    box: box,
                    bold: false,
                    style: style,
                    ink: bodyInk,
                    paragraph: pStyle
                ))
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
            let quoteBox = style.metrics.quoteBox
            let headingBox = style.metrics.headingBox(level: 3)
            let out = NSMutableAttributedString()
            out.beginEditing()
            let indent = style.metrics.spaceL + 4
            let tail = -style.metrics.spaceM
            let cardPadV = style.metrics.spaceM
            let quoteInk = style.colors.inkSoft
            let separatorFont = style.fonts.quote.regular
            var lastPStyle = quoteBox.makeParagraphStyle(spacing: isLast ? 0 : cardPadV + style.paragraphGap, indent: indent, tailIndent: tail)
            let flatLines = flattenQuoteBlocks(inner, listHanging: style.metrics.sizeSub)
            for (idx, line) in flatLines.enumerated() {
                let firstInQuote = idx == 0
                let lastInQuote = idx == flatLines.count - 1
                let before: CGFloat = (firstInQuote && !isFirst) ? cardPadV : 0
                let after = lastInQuote ? (isLast ? 0 : (cardPadV + style.paragraphGap)) : style.paragraphGap * 0.65
                let lineBox = line.isHeading ? headingBox : quoteBox
                let pStyle = lineBox.makeParagraphStyle(
                    spacing: after,
                    before: before,
                    indent: indent,
                    hanging: line.hanging,
                    tailIndent: tail
                )
                if idx > 0 {
                    out.append(NSAttributedString(string: "\n", attributes: [
                        .font: separatorFont,
                        .paragraphStyle: lastPStyle,
                    ]))
                }
                lastPStyle = pStyle
                let fontGroup = line.isHeading ? style.fonts.heading3 : style.fonts.quote
                out.append(buildInline(
                    line.text,
                    fontGroup: fontGroup,
                    box: lineBox,
                    bold: line.isHeading,
                    isHeading: line.isHeading,
                    headingLevel: line.isHeading ? 3 : 0,
                    style: style,
                    ink: quoteInk,
                    paragraph: pStyle
                ))
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
            pStyle.maximumLineHeight = style.metrics.sizeMicro
            pStyle.minimumLineHeight = style.metrics.sizeMicro
            let immutableStyle = (pStyle.copy() as? NSParagraphStyle) ?? pStyle
            let attr = NSAttributedString(string: "\u{200B}", attributes: [
                .font: style.fonts.ruleMicro,
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
            let pStyle = style.metrics.bodyBox.makeParagraphStyle()
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

    private func flattenQuoteBlocks(_ blocks: [Prose.Block], listHanging: CGFloat) -> [QuoteLine] {
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
                    result.append(QuoteLine(text: prefix + item.text, isHeading: false, hanging: listHanging))
                }
            case .quote(let nested):
                result.append(contentsOf: flattenQuoteBlocks(nested, listHanging: listHanging))
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

    private func buildInline(
        _ text: String,
        fontGroup: ChatFontGroup,
        box: SafeLineBoxMetrics,
        bold: Bool,
        isHeading: Bool = false,
        headingLevel: Int = 0,
        style: ChatListStyle,
        ink: UIColor,
        paragraph: NSParagraphStyle
    ) -> NSAttributedString {
        let parsed = PreparsedInline.parse(text)
        let accent = style.colors.accent
        let monoFont = fontGroup.inlineCode
        let profile = style.metrics.opticalProfile
        let out = NSMutableAttributedString()
        out.beginEditing()
        for run in parsed.runs {
            let isBold = bold || run.bold
            let font: UIFont
            if isBold {
                font = run.italic ? fontGroup.boldItalic : fontGroup.bold
            } else {
                font = run.italic ? fontGroup.italic : fontGroup.regular
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: ink,
                .paragraphStyle: paragraph,
            ]
            if !run.code && run.link == nil && box.trackingPoints != 0 {
                attributes[.kern] = NSNumber(value: Double(box.trackingPoints))
            }
            if profile.proseBoldStroke != 0 && !run.code {
                if isHeading {
                    let hWeight: Pref.HeadingWeight = headingLevel >= 4 ? .medium : style.headingWeight
                    let stroke = profile.headingStroke(weight: hWeight)
                    if stroke != 0 {
                        attributes[.strokeWidth] = Double(stroke)
                        attributes[.strokeColor] = ink
                    }
                } else if isBold {
                    attributes[.strokeWidth] = Double(profile.proseBoldStroke)
                    attributes[.strokeColor] = ink
                }
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
        ClioMixedScriptKerning.apply(
            to: out,
            fontSize: box.effectivePointSize,
            squeezePunctuation: style.metrics.clreqSqueeze,
            skipAttributeKeys: [.chatInlineCode]
        )
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
final class ChatLayoutCache: @unchecked Sendable {
    struct MeasuredSlice: @unchecked Sendable {
        let slice: ChatProseSlice
        let height: CGFloat
        let pictureHeights: [CGFloat]
    }

    struct AssistantLayoutEntry: @unchecked Sendable {
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
        let hasEstimatedFormula: Bool
    }

    struct UserLayoutEntry: @unchecked Sendable {
        let timeGapHeight: CGFloat
        let photosHeight: CGFloat
        let rendered: ChatRenderedProse
        let textWidth: CGFloat
        let textHeight: CGFloat
        let bubbleWidth: CGFloat
        let bubbleHeight: CGFloat
        let cellHeight: CGFloat
    }

    struct NoteLayoutEntry: Sendable {
        let titleHeight: CGFloat
        let detailHeight: CGFloat
        let cellHeight: CGFloat
    }

    struct LiveTextEntry: @unchecked Sendable {
        let rendered: ChatRenderedProse
        let textHeight: CGFloat
        let cellHeight: CGFloat
    }

    struct QueuedLayoutEntry: Sendable {
        let textHeight: CGFloat
        let hasPhotos: Bool
        let cellHeight: CGFloat
    }

    struct TraceSummaryLayoutEntry: Sendable {
        let timeGapHeight: CGFloat
        let speakerHeight: CGFloat
        let summaryHeight: CGFloat
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

    private struct NoteKey: Hashable, Sendable {
        let id: String
        let text: String
        let nextRaw: String
        let fold: Bool
        let isLatestNote: Bool
        let widthKey: Int
        let styleKey: String
    }

    let builder = ChatProseBuilder()

    private let assistantFinalizedCache = BoundedLRUCache<AssistantKey, AssistantLayoutEntry>(countLimit: 1000)
    private let userCache = BoundedLRUCache<UserKey, UserLayoutEntry>(countLimit: 1200)
    private let noteCache = BoundedLRUCache<NoteKey, NoteLayoutEntry>(countLimit: 256)
    private let hostingHeights = BoundedLRUCache<String, CGFloat>(countLimit: 600)

    private let stateLock = NSLock()
    private var cacheGeneration: UInt64 = 1
    private var assistantStreamingCache: [String: (key: AssistantKey, entry: AssistantLayoutEntry)] = [:]
    private var lastLiveStreamingEntry: (key: LiveStreamingKey, entry: AssistantLayoutEntry)?
    private var blockHeightOverridesByOwner: [String: [String: CGFloat]] = [:]
    private var overrideVersionsByOwner: [String: UInt64] = [:]

    func invalidateAll(clearOverrides: Bool = false) {
        stateLock.lock()
        cacheGeneration &+= 1
        assistantStreamingCache.removeAll(keepingCapacity: true)
        lastLiveStreamingEntry = nil
        if clearOverrides {
            blockHeightOverridesByOwner.removeAll(keepingCapacity: true)
            overrideVersionsByOwner.removeAll(keepingCapacity: true)
        }
        assistantFinalizedCache.removeAll()
        userCache.removeAll()
        noteCache.removeAll()
        hostingHeights.removeAll()
        stateLock.unlock()
        builder.clearCaches()
    }

    func invalidateHeightsOnly() {
        stateLock.lock()
        cacheGeneration &+= 1
        assistantStreamingCache.removeAll(keepingCapacity: true)
        lastLiveStreamingEntry = nil
        assistantFinalizedCache.removeAll()
        userCache.removeAll()
        noteCache.removeAll()
        hostingHeights.removeAll()
        stateLock.unlock()
    }

    func invalidateMessage(id: String) {
        stateLock.lock()
        assistantStreamingCache.removeValue(forKey: id)
        assistantFinalizedCache.removeAll { $0.id == id }
        userCache.removeAll { $0.id == id }
        noteCache.removeAll { $0.id == id }
        stateLock.unlock()
    }

    func overrideSnapshot(for ownerID: String) -> BlockOverrideSnapshot {
        stateLock.lock()
        let version = overrideVersionsByOwner[ownerID] ?? 1
        let heights = blockHeightOverridesByOwner[ownerID] ?? [:]
        stateLock.unlock()
        return BlockOverrideSnapshot(ownerID: ownerID, version: version, heights: heights)
    }

    func setBlockHeightOverride(_ height: CGFloat, key: String, ownerID: String) -> Bool {
        let rounded = ceil(height)
        stateLock.lock()
        defer { stateLock.unlock() }
        if let old = blockHeightOverridesByOwner[ownerID]?[key], abs(old - rounded) <= 0.5 {
            return false
        }
        blockHeightOverridesByOwner[ownerID, default: [:]][key] = rounded
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

    @MainActor
    func measureUser(
        row: ChatListRowItem,
        collectionWidth: CGFloat,
        style: ChatListStyle
    ) -> UserLayoutEntry {
        measureUser(input: UserMeasureInput(row: row, collectionWidth: collectionWidth, style: style))
    }

    func measureUser(input: UserMeasureInput) -> UserLayoutEntry {
        let style = input.style
        let metrics = style.metrics
        let widthKey = Int((input.collectionWidth * 2).rounded())
        let key = UserKey(
            id: input.id,
            styleKey: style.styleKey,
            widthKey: widthKey,
            text: input.text,
            photoCount: input.photoCount,
            isFirst: input.isFirst,
            opens: input.opens,
            faces: input.faces,
            hasTimeGap: input.hasTimeGap
        )
        if let hit = userCache.get(key) { return hit }
        stateLock.lock()
        let startGeneration = cacheGeneration
        stateLock.unlock()

        let pageMargin = metrics.spacePage
        let avatarSpace: CGFloat = input.faces ? (metrics.faceSize + metrics.spaceS) : 0
        let contentArea = max(160, input.collectionWidth - pageMargin * 2 - avatarSpace)
        let maxBubbleWidth = max(120, contentArea - metrics.spaceHuge)
        let maxTextWidth = max(60, maxBubbleWidth - metrics.userBubblePadH * 2)

        let timeGapH: CGFloat = input.hasTimeGap ? metrics.timeGapHeight : 0
        let photosH: CGFloat = input.photoCount == 0 ? 0 : metrics.photoSize

        let rendered = builder.buildUserText(input.text, style: style)
        let textSize: CGSize
        let bubbleW: CGFloat
        let bubbleH: CGFloat
        if input.text.isEmpty {
            textSize = .zero
            bubbleW = 0
            bubbleH = 0
        } else {
            textSize = measureTextSize(rendered: rendered, maxWidth: maxTextWidth)
            bubbleW = min(maxBubbleWidth, max(44, textSize.width + metrics.userBubblePadH * 2))
            bubbleH = ceil(textSize.height + metrics.userBubblePadV * 2)
        }

        var total: CGFloat = input.isFirst ? 0 : metrics.userTurnTopPad
        if timeGapH > 0 {
            total += timeGapH + metrics.timeGapBottomPad + metrics.sectionSpacing
        }
        var bodyH: CGFloat = 0
        if photosH > 0 { bodyH += photosH }
        if photosH > 0 && bubbleH > 0 { bodyH += metrics.spaceS }
        if bubbleH > 0 { bodyH += bubbleH }
        if input.faces && input.opens {
            bodyH = max(bodyH, metrics.faceSize)
        }
        total += bodyH + metrics.rowSpacing

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
        stateLock.lock()
        let validGeneration = cacheGeneration == startGeneration
        if validGeneration {
            userCache.set(entry, for: key)
        }
        stateLock.unlock()
        return entry
    }

    @MainActor
    func measureAssistant(
        row: ChatListRowItem,
        collectionWidth: CGFloat,
        style: ChatListStyle,
        expandedThinking: Bool,
        expandedPulse: Bool,
        expandedLookback: Bool,
        unfoldedSlices: Set<Int>,
        allowMainThreadMathMeasure: Bool = false
    ) -> AssistantLayoutEntry {
        let input = AssistantMeasureInput(
            row: row,
            collectionWidth: collectionWidth,
            style: style,
            expandedThinking: expandedThinking,
            expandedPulse: expandedPulse,
            expandedLookback: expandedLookback,
            unfoldedSlices: unfoldedSlices,
            overrides: overrideSnapshot(for: row.line.id)
        )
        return measureAssistant(input: input, allowMainThreadMathMeasure: allowMainThreadMathMeasure)
    }

    func measureAssistant(
        input: AssistantMeasureInput,
        allowMainThreadMathMeasure: Bool = false
    ) -> AssistantLayoutEntry {
        let style = input.style
        let metrics = style.metrics
        let widthKey = Int((input.collectionWidth * 2).rounded())
        let isFresh = input.isFresh
        let shown = input.freshShown ?? input.text.count
        let rawBody = input.lookbackRest
        let sortedUnfolded = input.unfoldedSlices.sorted()

        let key = AssistantKey(
            id: input.id,
            styleKey: style.styleKey,
            widthKey: widthKey,
            text: input.text,
            reasoning: input.reasoning ?? "",
            pulse: input.pulse ?? "",
            lookbackNote: input.lookbackNote ?? "",
            lookbackRest: rawBody,
            opens: input.opens,
            faces: input.faces,
            isRoom: input.isRoom,
            showThinking: input.showThinking,
            hasTimeGap: input.hasTimeGap,
            hasSources: input.hasSources,
            hasContinue: input.hasContinue,
            hasFooter: input.hasFooter,
            isStreaming: isFresh,
            freshShown: isFresh ? shown : -1,
            expandedThinking: input.expandedThinking,
            expandedPulse: input.expandedPulse,
            expandedLookback: input.expandedLookback,
            unfoldedSlices: sortedUnfolded,
            overrideVersion: input.overrides.version
        )

        if isFresh {
            stateLock.lock()
            let hit = assistantStreamingCache[input.id]
            stateLock.unlock()
            if let hit, hit.key == key, !Self.needsFormulaRefresh(entry: hit.entry, style: style) {
                return hit.entry
            }
        } else {
            stateLock.lock()
            if !assistantStreamingCache.isEmpty {
                assistantStreamingCache.removeValue(forKey: input.id)
            }
            stateLock.unlock()
            if let hit = assistantFinalizedCache.get(key), !Self.needsFormulaRefresh(entry: hit, style: style) {
                return hit
            }
        }

        stateLock.lock()
        let startGeneration = cacheGeneration
        stateLock.unlock()

        let contentWidth = metrics.effectiveContentWidth(for: input.collectionWidth)
        let timeGapH: CGFloat = input.hasTimeGap ? metrics.timeGapHeight : 0
        let speakerH: CGFloat = (input.opens && (input.faces || input.isRoom))
            ? (input.faces ? metrics.faceSize : metrics.compactSpeakerSize)
            : 0

        var thinkingRendered: ChatRenderedProse?
        var thinkingH: CGFloat = 0
        if let reasoning = input.reasoning, input.showThinking {
            let built = builder.buildDisclosureText(reasoning, style: style)
            thinkingRendered = built
            if input.expandedThinking {
                let innerWidth = max(80, contentWidth - metrics.spaceM)
                thinkingH = measureTextSize(rendered: built, maxWidth: innerWidth).height
            }
        }

        var pulseRendered: ChatRenderedProse?
        var pulseH: CGFloat = 0
        if let pulse = input.pulse {
            let built = builder.buildDisclosureText(pulse, style: style)
            pulseRendered = built
            if input.expandedPulse {
                let innerWidth = max(80, contentWidth - metrics.spaceM * 2)
                pulseH = measureTextSize(rendered: built, maxWidth: innerWidth).height
            }
        }

        var lookbackH: CGFloat = 0
        if !isFresh, let note = input.lookbackNote {
            lookbackH = measureLookbackHeight(note: note, maxWidth: contentWidth, expanded: input.expandedLookback, style: style)
        }

        let slices = builder.buildAssistantSlices(
            rawBody,
            style: style,
            isStreaming: isFresh,
            streamKey: isFresh ? "fresh-\(input.id)" : nil
        )
        let measuredResult = measureSlices(
            slices,
            ownerID: input.id,
            contentWidth: contentWidth,
            widthKey: widthKey,
            style: style,
            unfoldedSlices: input.unfoldedSlices,
            overrides: input.overrides.heights,
            allowMainThreadMathMeasure: allowMainThreadMathMeasure
        )
        let measuredSlices = measuredResult.slices

        var total: CGFloat = 0
        if timeGapH > 0 {
            total += timeGapH + metrics.timeGapBottomPad + metrics.sectionSpacing
        }
        if speakerH > 0 {
            total += speakerH + metrics.sectionSpacing
        }

        var bodyItems: [CGFloat] = []
        if thinkingRendered != nil {
            bodyItems.append(metrics.disclosureHeaderHeight + (input.expandedThinking ? metrics.disclosureGap + thinkingH : 0))
        }
        if pulseRendered != nil {
            bodyItems.append(metrics.disclosureHeaderHeight + (input.expandedPulse ? metrics.disclosureGap + pulseH + metrics.spaceS * 2 : 0))
        }
        if lookbackH > 0 {
            bodyItems.append(lookbackH)
        }
        if !measuredSlices.isEmpty {
            var proseStackH: CGFloat = 0
            for (idx, item) in measuredSlices.enumerated() {
                if idx > 0 {
                    let gap: CGFloat
                    if case .richText(let prevRendered) = measuredSlices[idx - 1].slice,
                       let explicitGap = prevRendered.spacingAfter {
                        gap = explicitGap
                    } else {
                        gap = style.paragraphGap
                    }
                    proseStackH += gap
                }
                proseStackH += item.height
            }
            bodyItems.append(proseStackH)
        }
        if input.hasSources { bodyItems.append(metrics.sourcesPillHeight) }
        if input.hasContinue { bodyItems.append(metrics.continueButtonHeight) }
        if input.hasFooter { bodyItems.append(metrics.footerHeight) }

        for (idx, h) in bodyItems.enumerated() {
            if idx > 0 { total += metrics.botBlockGap }
            total += h
        }
        if thinkingRendered != nil && bodyItems.count > 1 {
            total += 6 * metrics.scale
        }
        total += metrics.rowSpacing

        let entry = AssistantLayoutEntry(
            timeGapHeight: timeGapH,
            speakerHeight: speakerH,
            thinkingText: thinkingRendered,
            thinkingTextHeight: thinkingH,
            pulseText: pulseRendered,
            pulseTextHeight: pulseH,
            lookbackHeight: lookbackH,
            slices: measuredSlices,
            hasSources: input.hasSources,
            hasContinueButton: input.hasContinue,
            hasFooter: input.hasFooter,
            contentWidth: contentWidth,
            cellHeight: ceil(total),
            hasEstimatedFormula: measuredResult.hasEstimatedFormula
        )

        if isFresh {
            stateLock.lock()
            assistantStreamingCache[input.id] = (key: key, entry: entry)
            stateLock.unlock()
        } else {
            stateLock.lock()
            let currentOverrideVersion = overrideVersionsByOwner[input.id] ?? 1
            let validGeneration = cacheGeneration == startGeneration
            if validGeneration && currentOverrideVersion == input.overrides.version {
                assistantFinalizedCache.set(entry, for: key)
            }
            stateLock.unlock()
        }
        return entry
    }

    private nonisolated static func needsFormulaRefresh(entry: AssistantLayoutEntry, style: ChatListStyle) -> Bool {
        guard entry.hasEstimatedFormula else { return false }
        for measured in entry.slices {
            if case .math(let latex, let isLive, _) = measured.slice, !isLive {
                if let exact = ChatFormulaHeightCache.cachedHeight(latex: latex, style: style),
                   abs(exact - measured.height) > 0.5 {
                    return true
                }
            }
        }
        return false
    }

    func measureLiveStreamingProse(
        text: String,
        generation: Int,
        collectionWidth: CGFloat,
        style: ChatListStyle
    ) -> AssistantLayoutEntry {
        let metrics = style.metrics
        let contentWidth = metrics.effectiveContentWidth(for: collectionWidth)
        let widthKey = Int((collectionWidth * 2).rounded())
        let cacheKey = LiveStreamingKey(
            generation: generation,
            widthKey: widthKey,
            styleKey: style.styleKey,
            text: text
        )
        let ownerID = "streaming-\(generation)"
        stateLock.lock()
        let cached = lastLiveStreamingEntry
        let overrides = blockHeightOverridesByOwner[ownerID] ?? [:]
        stateLock.unlock()
        if let cached, cached.key == cacheKey, !Self.needsFormulaRefresh(entry: cached.entry, style: style) {
            return cached.entry
        }

        let slices = builder.buildAssistantSlices(
            text,
            style: style,
            isStreaming: true,
            streamKey: ownerID
        )
        let measuredResult = measureSlices(
            slices,
            ownerID: ownerID,
            contentWidth: contentWidth,
            widthKey: widthKey,
            style: style,
            unfoldedSlices: [],
            overrides: overrides,
            allowMainThreadMathMeasure: false
        )
        let measured = measuredResult.slices
        var proseStackH: CGFloat = 0
        for (idx, item) in measured.enumerated() {
            if idx > 0 {
                let gap: CGFloat
                if case .richText(let prevRendered) = measured[idx - 1].slice,
                   let explicitGap = prevRendered.spacingAfter {
                    gap = explicitGap
                } else {
                    gap = style.paragraphGap
                }
                proseStackH += gap
            }
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
            cellHeight: ceil(proseStackH + metrics.rowSpacing),
            hasEstimatedFormula: measuredResult.hasEstimatedFormula
        )
        stateLock.lock()
        lastLiveStreamingEntry = (key: cacheKey, entry: entry)
        stateLock.unlock()
        return entry
    }

    private func measureSlices(
        _ slices: [ChatProseSlice],
        ownerID: String,
        contentWidth: CGFloat,
        widthKey: Int,
        style: ChatListStyle,
        unfoldedSlices: Set<Int>,
        overrides: [String: CGFloat],
        allowMainThreadMathMeasure: Bool
    ) -> (slices: [MeasuredSlice], hasEstimatedFormula: Bool) {
        let metrics = style.metrics
        var hasEstimatedFormula = false
        let measured: [MeasuredSlice] = slices.map { slice in
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
                let bodyH = max(16, bodySize.height) + metrics.spaceM * 2
                let foldH = resolvedCode.folds ? style.codeFoldButtonHeight : 0
                let total = ceil(style.codeHeaderHeight + bodyH + foldH)
                return MeasuredSlice(slice: .code(resolvedCode, sliceIndex: sliceIndex), height: total, pictureHeights: [])

            case .table(let tableSlice, _):
                let h = ChatTableBlockView.measureHeight(slice: tableSlice, maxWidth: contentWidth, style: style)
                return MeasuredSlice(slice: slice, height: ceil(h), pictureHeights: [])

            case .math(let latex, let isLive, let sliceIndex):
                let mathKey = "math|\(ownerID)|\(sliceIndex)|\(widthKey)|\(style.styleKey)|\(fnv1a64(latex))"
                if let overrideH = overrides[mathKey] {
                    return MeasuredSlice(slice: slice, height: ceil(overrideH), pictureHeights: [])
                }
                let result = ChatFormulaBlockView.measureHeightInfo(
                    latex: latex,
                    maxWidth: contentWidth,
                    style: style,
                    streaming: isLive,
                    allowMainThreadMathMeasure: allowMainThreadMathMeasure
                )
                if result.isEstimated {
                    hasEstimatedFormula = true
                }
                return MeasuredSlice(slice: slice, height: ceil(result.height), pictureHeights: [])

            case .fileCards(let links, let sliceIndex):
                let key = "file|\(ownerID)|\(sliceIndex)|\(widthKey)|\(style.styleKey)|\(links.map(\.path).joined(separator: "|"))"
                let h = overrides[key]
                    ?? ChatMediaLayoutCache.fileCardsHeight(links: links, maxWidth: contentWidth, style: style)
                    ?? ChatFileCardsBlockView.baseMeasureHeight(links: links, maxWidth: contentWidth, style: style)
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
                    let picH = overrides[key]
                        ?? ChatMediaLayoutCache.pictureHeight(source: pic.source, maxWidth: contentWidth, scale: style.scale)
                        ?? 160
                    picHeights.append(picH)
                    if picIndex > 0 { total += style.readingSize * 0.6 }
                    total += picH
                }
                return MeasuredSlice(slice: slice, height: ceil(total), pictureHeights: picHeights)
            }
        }
        return (measured, hasEstimatedFormula)
    }

    @MainActor
    func measureTraceSummary(
        row: ChatListRowItem,
        collectionWidth: CGFloat,
        style: ChatListStyle
    ) -> TraceSummaryLayoutEntry {
        let metrics = style.metrics
        let timeGapH: CGFloat = (row.faces && row.opens && row.timeGap != nil) ? metrics.timeGapHeight : 0
        let speakerH: CGFloat = (row.opens && (row.faces || row.isRoom))
            ? (row.faces ? metrics.faceSize : metrics.compactSpeakerSize)
            : 0
        let summaryFont = UIFont.systemFont(ofSize: metrics.sizeSub)
        let summaryH = max(metrics.disclosureHeaderHeight, ceil(summaryFont.lineHeight))
        var total: CGFloat = 0
        if timeGapH > 0 {
            total += timeGapH + metrics.timeGapBottomPad + metrics.sectionSpacing
        }
        if speakerH > 0 {
            total += speakerH + metrics.sectionSpacing
        }
        total += summaryH + metrics.rowSpacing
        return TraceSummaryLayoutEntry(
            timeGapHeight: timeGapH,
            speakerHeight: speakerH,
            summaryHeight: summaryH,
            cellHeight: ceil(total)
        )
    }

    func measureNote(
        line: ChatLine,
        isLatestNote: Bool,
        collectionWidth: CGFloat,
        style: ChatListStyle,
        adviceTitle: String? = nil
    ) -> NoteLayoutEntry {
        let metrics = style.metrics
        let fonts = style.fonts
        let widthKey = Int((collectionWidth * 2).rounded())
        let key = NoteKey(
            id: line.id,
            text: line.text,
            nextRaw: line.next?.rawValue ?? "",
            fold: line.fold,
            isLatestNote: isLatestNote,
            widthKey: widthKey,
            styleKey: style.styleKey
        )
        if let hit = noteCache.get(key) {
            return hit
        }

        let contentWidth = max(120, collectionWidth - metrics.spacePage * 2)
        let entry: NoteLayoutEntry
        if line.fold {
            entry = NoteLayoutEntry(titleHeight: 36, detailHeight: 0, cellHeight: ceil(36 + metrics.rowSpacing))
        } else if let next = line.next {
            let parts = line.text.split(separator: "\n", maxSplits: 1).map(String.init)
            let advice = Explain.Advice(title: parts.first ?? line.text, detail: parts.count > 1 ? parts[1] : "", next: next)
            let resolvedTitle = adviceTitle ?? advice.title
            let innerW = max(80, contentWidth - metrics.spaceL * 2)
            let titleH = Self.measureNSStringHeight(
                resolvedTitle,
                font: fonts.noteAdviceTitle,
                maxWidth: max(40, innerW - 28)
            )

            var detailH: CGFloat = 0
            if !advice.detail.isEmpty {
                detailH = Self.measureNSStringHeight(
                    advice.detail,
                    font: fonts.noteAdviceDetail,
                    maxWidth: innerW
                )
            }

            var total = metrics.spaceL * 2 + titleH
            if detailH > 0 { total += metrics.spaceS + detailH }
            if isLatestNote && advice.button != nil { total += metrics.spaceS + metrics.spaceXS + 34 }
            entry = NoteLayoutEntry(titleHeight: titleH, detailHeight: detailH, cellHeight: ceil(total + metrics.rowSpacing))
        } else {
            let h = Self.measureNSStringHeight(line.text, font: fonts.notePlain, maxWidth: contentWidth)
            let verticalPad = metrics.spaceS * 2
            entry = NoteLayoutEntry(titleHeight: h, detailHeight: 0, cellHeight: ceil(h + verticalPad + metrics.rowSpacing))
        }
        noteCache.set(entry, for: key)
        return entry
    }

    func measureLiveText(_ text: String, collectionWidth: CGFloat, style: ChatListStyle, cardInsetH: CGFloat, cardInsetV: CGFloat) -> LiveTextEntry {
        let metrics = style.metrics
        let contentWidth = metrics.effectiveContentWidth(for: collectionWidth)
        let innerWidth = max(80, contentWidth - cardInsetH * 2)
        let rendered = builder.buildDisclosureText(text, style: style)
        let textH = measureTextSize(rendered: rendered, maxWidth: innerWidth).height
        let cardH = metrics.disclosureHeaderHeight + metrics.disclosureGap + textH + cardInsetV * 2
        return LiveTextEntry(rendered: rendered, textHeight: textH, cellHeight: ceil(cardH + metrics.rowSpacing))
    }

    func measureQueued(_ item: TeamModel.Queued, collectionWidth: CGFloat, style: ChatListStyle) -> QueuedLayoutEntry {
        let metrics = style.metrics
        let contentWidth = metrics.effectiveContentWidth(for: collectionWidth)
        let maxBubbleW = max(120, contentWidth - metrics.spaceHuge)
        let innerW = max(60, maxBubbleW - metrics.spaceL * 2)
        var bubbleH: CGFloat = metrics.spaceM * 2
        let hasPhotos = !item.photos.isEmpty
        if hasPhotos { bubbleH += 20 }
        var textH: CGFloat = 0
        if !item.text.isEmpty {
            textH = Self.measureNSStringHeight(
                item.text,
                font: style.fonts.queuedMessage,
                maxWidth: innerW,
                maxLines: 4
            )
            if hasPhotos { bubbleH += 4 }
            bubbleH += textH
        }
        let actionsH: CGFloat = metrics.queuedActionsHeight
        let total = bubbleH + metrics.spaceXS + actionsH + metrics.rowSpacing
        return QueuedLayoutEntry(textHeight: textH, hasPhotos: hasPhotos, cellHeight: ceil(total))
    }

    func measureFailure(error: String, working: Bool, collectionWidth: CGFloat, style: ChatListStyle) -> CGFloat {
        let metrics = style.metrics
        let contentWidth = metrics.effectiveContentWidth(for: collectionWidth)
        let buttonReserve: CGFloat = working ? 0 : (92 + metrics.spaceM)
        let textW = max(80, contentWidth - metrics.spaceL * 2 - 24 - metrics.spaceM - buttonReserve)
        let textH = Self.measureNSStringHeight(error, font: style.fonts.failureMessage, maxWidth: textW)
        let cardH = max(32 + metrics.spaceM * 2, textH + metrics.spaceM * 2)
        return ceil(cardH + metrics.rowSpacing)
    }

    private func measureLookbackHeight(note: String, maxWidth: CGFloat, expanded: Bool, style: ChatListStyle) -> CGFloat {
        let h = Self.measureNSStringHeight(
            "回望 · " + note,
            font: style.fonts.lookbackSmall,
            maxWidth: max(40, maxWidth - 22),
            maxLines: expanded ? 0 : 1
        )
        return ceil(max(18, h))
    }

    private nonisolated static func measureNSStringHeight(_ text: String, font: UIFont, maxWidth: CGFloat, maxLines: Int = 0) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        if maxLines == 1 {
            return ceil(font.lineHeight)
        }
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: max(1, maxWidth), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        )
        let rawH = ceil(rect.height)
        if maxLines > 1 {
            return min(rawH, ceil(font.lineHeight * CGFloat(maxLines)))
        }
        return rawH
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
