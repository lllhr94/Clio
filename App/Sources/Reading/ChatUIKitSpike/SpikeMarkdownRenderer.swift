#if DEBUG
import CoreText
import Foundation
import Prose
import SwiftUI
import UIKit

@MainActor
struct SpikeStyle: Equatable {
    let face: Pref.Face
    let code: Pref.Code
    let size: Double
    let lineHeight: Double
    let fade: Bool
    let uiScale: Double
    let themeKey: String
    let white: Bool
    let oled: Bool
    let bubble: String
    let fontGeneration: Int
    let isDark: Bool

    var scale: CGFloat { CGFloat(uiScale) }
    var readingSize: CGFloat { CGFloat(size) }
    var codeSize: CGFloat { max(CGFloat(12), CGFloat(size) - 3) }
    var inlineCodeSize: CGFloat { max(CGFloat(12), CGFloat(size) - 2) }
    var tableCellSize: CGFloat { max(CGFloat(12), CGFloat(size) - 2) }
    var leading: CGFloat { Ink.leading(size: size, lineHeight: lineHeight, face: face) }
    var paragraphGap: CGFloat { CGFloat(size) * 0.72 }
    var listSpacing: CGFloat { CGFloat(size) * 0.42 }
    var headingBottom: CGFloat { CGFloat(size) * 0.35 }
    var codeLineSpacing: CGFloat { max(1.5, codeSize * 0.13) }
    var codeHeaderHeight: CGFloat { 26 * scale }
    var inlineCodeCorner: CGFloat { 5 * scale }

    var styleKey: String {
        "\(face.rawValue)|\(code.rawValue)|\(size)|\(lineHeight)|\(uiScale)|\(themeKey)|\(white)|\(oled)|\(bubble)|\(fontGeneration)|\(isDark)"
    }

    static func current(traits: UITraitCollection) -> SpikeStyle {
        let theme = Theme.shared
        return SpikeStyle(
            face: theme.face,
            code: theme.code,
            size: theme.size,
            lineHeight: theme.lineHeight,
            fade: theme.fade,
            uiScale: UIScale.shared.value,
            themeKey: theme.key,
            white: theme.white,
            oled: theme.oled,
            bubble: theme.bubble,
            fontGeneration: theme.fontsArrived,
            isDark: traits.userInterfaceStyle == .dark
        )
    }

    func headingSize(level: Int) -> CGFloat {
        let base = readingSize
        if level <= 1 { return (base * 1.24).rounded() }
        if level == 2 { return (base * 1.13).rounded() }
        return (base * 1.05).rounded()
    }

    func headingTop(level: Int) -> CGFloat {
        let base = readingSize
        if level <= 1 { return base * 1.05 }
        if level == 2 { return base * 0.82 }
        return base * 0.55
    }
}

struct SpikeCodeBlockDecoration: Equatable {
    let range: NSRange
    let language: String
    let isOutput: Bool
    let lineCount: Int
}

struct SpikeBlockDecorations: Equatable {
    let inlineCodeRanges: [NSRange]
    let codeBlocks: [SpikeCodeBlockDecoration]
    let quoteBlocks: [NSRange]
    let ruleRanges: [NSRange]
}

struct SpikeRenderedProse {
    let attributed: NSAttributedString
    let decorations: SpikeBlockDecorations
    let topInset: CGFloat
    let bottomInset: CGFloat
    let renderToken: UInt64
}

extension NSAttributedString.Key {
    static let spikeInlineCode = NSAttributedString.Key("SpikeInlineCode")
}

@MainActor
enum SpikeCodeHighlighter {
    private static let keywords: Set<String> = [
        "func", "let", "var", "if", "else", "for", "while", "return", "import", "struct", "class", "enum", "case", "switch",
        "guard", "in", "as", "is", "try", "catch", "throw", "throws", "async", "await", "private", "public", "static",
        "def", "from", "not", "and", "or", "None", "True", "False", "lambda", "with", "except", "yield",
        "const", "function", "new", "this", "self", "true", "false", "null", "nil", "export", "default",
        "SELECT", "FROM", "WHERE", "GROUP", "BY", "ORDER", "LIMIT", "AS", "DESC", "ASC", "AND", "OR",
        "select", "from", "where", "group", "by", "order", "limit", "as", "desc", "asc",
    ]

    private enum TokenKind {
        case plain, keyword, function, number, string, comment

        var color: UIColor {
            switch self {
            case .plain: return UIColor(Ink.ink)
            case .keyword: return UIColor(Ink.Code.keyword)
            case .function: return UIColor(Ink.Code.function)
            case .number: return UIColor(Ink.Code.number)
            case .string: return UIColor(Ink.Code.string)
            case .comment: return UIColor(Ink.inkFaint)
            }
        }
    }

    static func isOutputBlock(language: String, text: String) -> Bool {
        let lower = language.lowercased()
        if ["text", "txt", "output", "console", "log", "plaintext", "plain", "stdout", "shell-session"].contains(lower) {
            return true
        }
        guard lower.isEmpty else { return false }
        let codeSignals = ["{", "}", ";", " = ", "=>", "->", "def ", "func ", "function ", "import ", "return ", "const ", "let ", "class ", "SELECT "]
        return !codeSignals.contains { text.contains($0) }
    }

    private struct AlignedFontPair {
        let narrow: UIFont
        let wide: UIFont
    }

    private static func isWide(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x00B7, 0x2014, 0x2018...0x2019, 0x201C...0x201D, 0x2026, 0x1100...0x11FF, 0x2E80...0xA4CF, 0xAC00...0xD7FF, 0xF900...0xFAFF,
             0xFE10...0xFE1F, 0xFE30...0xFE6F, 0xFF01...0xFF60, 0xFFE0...0xFFE6, 0x20000...0x323AF:
            return true
        default:
            return false
        }
    }

    private static func alignedCodeFonts(size: CGFloat, preference: Pref.Code, italic: Bool) -> AlignedFontPair {
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
        guard CTFontGetGlyphsForCharacters(native, &zero, &glyph, 1) else {
            return AlignedFontPair(narrow: targetMono, wide: targetWide)
        }
        let advance = CTFontGetAdvancesForGlyphs(native, .horizontal, &glyph, nil, 1)
        guard advance > 0 else {
            return AlignedFontPair(narrow: targetMono, wide: targetWide)
        }
        let matrix = CGAffineTransform(scaleX: size * 0.5 / advance, y: 1)
        let scaledDescriptor = targetMono.fontDescriptor.withMatrix(matrix)
        let halfFont = UIFont(descriptor: scaledDescriptor, size: size)
        return AlignedFontPair(narrow: halfFont, wide: targetWide)
    }

    private static func appendAligned(
        _ segment: Substring,
        alignWide: Bool,
        regularPair: AlignedFontPair,
        italicPair: AlignedFontPair,
        italic: Bool,
        color: UIColor,
        paragraphStyle: NSParagraphStyle,
        to out: NSMutableAttributedString
    ) {
        guard let first = segment.first else { return }
        let pair = italic ? italicPair : regularPair
        if !alignWide {
            out.append(NSAttributedString(string: String(segment), attributes: [
                .font: pair.narrow,
                .foregroundColor: color,
                .paragraphStyle: paragraphStyle,
            ]))
            return
        }

        var currentWide = isWide(first)
        var runStart = segment.startIndex

        func flushRun(upTo end: String.Index) {
            guard runStart < end else { return }
            let font = currentWide ? pair.wide : pair.narrow
            out.append(NSAttributedString(string: String(segment[runStart..<end]), attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraphStyle,
            ]))
        }

        for idx in segment.indices.dropFirst() {
            let nextWide = isWide(segment[idx])
            if nextWide != currentWide {
                flushRun(upTo: idx)
                runStart = idx
                currentWide = nextWide
            }
        }
        flushRun(upTo: segment.endIndex)
    }

    static func highlight(
        _ text: String,
        language: String,
        isOutput: Bool,
        style: SpikeStyle,
        paragraphStyle: NSParagraphStyle
    ) -> NSAttributedString {
        let hasWide = text.contains(where: isWide)
        let regularPair: AlignedFontPair
        let italicPair: AlignedFontPair
        if hasWide {
            regularPair = alignedCodeFonts(size: style.codeSize, preference: style.code, italic: false)
            italicPair = alignedCodeFonts(size: style.codeSize, preference: style.code, italic: true)
        } else {
            let baseMono = Ink.uiMono(style.codeSize, preference: style.code)
            let slantedMono: UIFont
            if let slanted = baseMono.fontDescriptor.withSymbolicTraits(baseMono.fontDescriptor.symbolicTraits.union(.traitItalic)) {
                slantedMono = UIFont(descriptor: slanted, size: style.codeSize)
            } else {
                slantedMono = baseMono
            }
            regularPair = AlignedFontPair(narrow: baseMono, wide: baseMono)
            italicPair = AlignedFontPair(narrow: slantedMono, wide: slantedMono)
        }

        if isOutput {
            let out = NSMutableAttributedString()
            appendAligned(
                text[...],
                alignWide: hasWide,
                regularPair: regularPair,
                italicPair: italicPair,
                italic: false,
                color: UIColor(Ink.Code.output),
                paragraphStyle: paragraphStyle,
                to: out
            )
            return out
        }

        let lowerLang = language.lowercased()
        let hashComments = ["python", "py", "bash", "sh", "shell", "zsh", "ruby", "rb", "yaml", "yml", "toml"].contains(lowerLang)
        let sqlComments = ["sql", "sqlite", "postgres", "mysql"].contains(lowerLang)

        let out = NSMutableAttributedString()
        var index = text.startIndex
        var start = index
        var kind: TokenKind = .plain

        func flush(upTo end: String.Index) {
            guard start < end else { return }
            appendAligned(
                text[start..<end],
                alignWide: hasWide,
                regularPair: regularPair,
                italicPair: italicPair,
                italic: kind == .comment,
                color: kind.color,
                paragraphStyle: paragraphStyle,
                to: out
            )
        }

        while index < text.endIndex {
            let rest = text[index...]
            let character = text[index]
            let nextKind: TokenKind
            var end: String.Index

            if rest.hasPrefix("//") || (hashComments && character == "#") || (sqlComments && rest.hasPrefix("--")) {
                end = rest.firstIndex(of: "\n") ?? text.endIndex
                nextKind = .comment
            } else if character == "\"" || character == "'" || character == "`" {
                end = text.index(after: index)
                while end < text.endIndex, text[end] != character, text[end] != "\n" {
                    if text[end] == "\\" { end = text.index(after: end) }
                    if end < text.endIndex { end = text.index(after: end) }
                }
                if end < text.endIndex, text[end] == character { end = text.index(after: end) }
                nextKind = .string
            } else if character.isLetter || character == "_" {
                end = rest.firstIndex { !($0.isLetter || $0.isNumber || $0 == "_") } ?? text.endIndex
                let word = String(text[index..<end])
                let calls = end < text.endIndex && text[end] == "("
                if keywords.contains(word) {
                    nextKind = .keyword
                } else if calls {
                    nextKind = .function
                } else {
                    nextKind = .plain
                }
            } else if character.isNumber {
                end = rest.firstIndex { !($0.isNumber || $0 == ".") } ?? text.endIndex
                nextKind = .number
            } else {
                end = text.index(after: index)
                nextKind = .plain
            }

            if nextKind != kind {
                flush(upTo: index)
                start = index
                kind = nextKind
            }
            index = end
        }
        flush(upTo: text.endIndex)
        return out
    }
}

@MainActor
final class SpikeProseBuilder {
    private struct BlockCacheEntry {
        let attributed: NSAttributedString
        let trailingSeparatorStyle: NSParagraphStyle
        let inlineCodeOffsets: [NSRange]
        let codeMeta: SpikeCodeBlockDecoration?
        let quoteSpan: NSRange?
        let isRule: Bool
    }

    private struct BlockCacheKey: Hashable {
        let styleKey: String
        let blockHash: Int
        let isFirst: Bool
        let isLast: Bool
        let widthKey: Int
        let text: String
    }

    private var blockCache: [BlockCacheKey: BlockCacheEntry] = [:]
    private var nextToken: UInt64 = 1

    func buildUserText(_ text: String, style: SpikeStyle) -> SpikeRenderedProse {
        let pStyle = NSMutableParagraphStyle()
        pStyle.lineSpacing = max(2, style.leading * 0.65)
        let font = Ink.uiFace(Ink.Size.body, bold: false, face: style.face)
        let attr = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: UIColor(Ink.ink),
            .paragraphStyle: pStyle,
        ])
        let token = nextToken
        nextToken &+= 1
        return SpikeRenderedProse(
            attributed: attr,
            decorations: SpikeBlockDecorations(inlineCodeRanges: [], codeBlocks: [], quoteBlocks: [], ruleRanges: []),
            topInset: 0,
            bottomInset: 0,
            renderToken: token
        )
    }

    func buildAssistantProse(
        _ rawText: String,
        style: SpikeStyle,
        contentWidth: CGFloat,
        isStreaming: Bool
    ) -> SpikeRenderedProse {
        let blocks: [Prose.Block]
        if isStreaming {
            blocks = Prose.parse(Prose.mend(rawText))
        } else {
            blocks = Prose.parse(rawText)
        }

        if blocks.isEmpty {
            let pStyle = makeParagraphStyle(style: style)
            let placeholder = NSAttributedString(string: isStreaming ? " " : "", attributes: [
                .font: Ink.uiFace(style.readingSize, bold: false, face: style.face),
                .foregroundColor: UIColor(Ink.ink),
                .paragraphStyle: pStyle,
            ])
            let token = nextToken
            nextToken &+= 1
            return SpikeRenderedProse(
                attributed: placeholder,
                decorations: SpikeBlockDecorations(inlineCodeRanges: [], codeBlocks: [], quoteBlocks: [], ruleRanges: []),
                topInset: 0,
                bottomInset: 2,
                renderToken: token
            )
        }

        let widthKey = Int((contentWidth * 2).rounded())
        let out = NSMutableAttributedString()
        var inlineCodeRanges: [NSRange] = []
        var codeBlocks: [SpikeCodeBlockDecoration] = []
        var quoteBlocks: [NSRange] = []
        var ruleRanges: [NSRange] = []

        for index in blocks.indices {
            let block = blocks[index]
            let isFirst = index == 0
            let isLast = index == blocks.count - 1
            let entry = renderedBlock(
                block,
                style: style,
                contentWidth: contentWidth,
                widthKey: widthKey,
                isFirst: isFirst,
                isLast: isLast,
                cacheable: !isStreaming || !isLast
            )

            let baseOffset = out.length
            out.append(entry.attributed)

            for r in entry.inlineCodeOffsets {
                inlineCodeRanges.append(NSRange(location: baseOffset + r.location, length: r.length))
            }
            if let meta = entry.codeMeta {
                codeBlocks.append(
                    SpikeCodeBlockDecoration(
                        range: NSRange(location: baseOffset + meta.range.location, length: meta.range.length),
                        language: meta.language,
                        isOutput: meta.isOutput,
                        lineCount: meta.lineCount
                    )
                )
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

        if isStreaming && style.fade && out.length > 0 {
            applyStreamingTailFade(to: out)
        }

        let topInset = topCardInset(for: blocks.first, style: style)
        let bottomInset = bottomCardInset(for: blocks.last, style: style)
        let token = nextToken
        nextToken &+= 1

        return SpikeRenderedProse(
            attributed: out,
            decorations: SpikeBlockDecorations(
                inlineCodeRanges: inlineCodeRanges,
                codeBlocks: codeBlocks,
                quoteBlocks: quoteBlocks,
                ruleRanges: ruleRanges
            ),
            topInset: topInset,
            bottomInset: bottomInset,
            renderToken: token
        )
    }

    private func topCardInset(for firstBlock: Prose.Block?, style: SpikeStyle) -> CGFloat {
        guard let firstBlock else { return 0 }
        switch firstBlock {
        case .code:
            return style.codeHeaderHeight + Ink.Space.m
        case .quote, .table:
            return Ink.Space.m
        default:
            return 0
        }
    }

    private func bottomCardInset(for lastBlock: Prose.Block?, style: SpikeStyle) -> CGFloat {
        guard let lastBlock else { return 2 }
        switch lastBlock {
        case .code, .quote, .table:
            return Ink.Space.m
        default:
            return 2
        }
    }

    private func applyStreamingTailFade(to attributed: NSMutableAttributedString) {
        let raw = attributed.string
        let tailIndices = Array(raw.indices.suffix(10))
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
        style: SpikeStyle,
        contentWidth: CGFloat,
        widthKey: Int,
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
            widthKey: widthKey,
            text: keyString
        )
        if cacheable, let hit = blockCache[cacheKey] {
            return hit
        }

        let built = buildSingleBlock(
            block,
            style: style,
            contentWidth: contentWidth,
            isFirst: isFirst,
            isLast: isLast
        )
        if cacheable {
            if blockCache.count > 600 { blockCache.removeAll(keepingCapacity: true) }
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
        style: SpikeStyle,
        contentWidth: CGFloat,
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
                codeMeta: nil,
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
                codeMeta: nil,
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
                let spacing: CGFloat
                if itemLast {
                    spacing = isLast ? 0 : style.paragraphGap
                } else {
                    spacing = style.listSpacing
                }
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
                codeMeta: nil,
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
                let after: CGFloat
                if lastInQuote {
                    after = isLast ? 0 : (cardPadV + style.paragraphGap)
                } else {
                    after = style.paragraphGap * 0.65
                }
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
                codeMeta: nil,
                quoteSpan: span,
                isRule: false
            )

        case .code(let language, let rawCode, _):
            let trimmed = trimCodeEdgeBlanks(rawCode)
            let body = trimmed.isEmpty ? " " : trimmed
            let lines = body.components(separatedBy: "\n")
            let isOutput = SpikeCodeHighlighter.isOutputBlock(language: language, text: body)
            let cardPadV = Ink.Space.m
            let topPad = style.codeHeaderHeight + cardPadV
            let indent = Ink.Space.l
            let tail = -Ink.Space.l

            let out = NSMutableAttributedString()
            var lastPStyle = makeCodeParagraphStyle(
                style: style,
                before: isFirst ? 0 : topPad,
                after: isLast ? 0 : (cardPadV + style.paragraphGap),
                indent: indent,
                tailIndent: tail
            )

            if lines.count <= 1 {
                let highlighted = SpikeCodeHighlighter.highlight(body, language: language, isOutput: isOutput, style: style, paragraphStyle: lastPStyle)
                out.append(highlighted)
            } else {
                let firstStyle = makeCodeParagraphStyle(style: style, before: isFirst ? 0 : topPad, after: 0, indent: indent, tailIndent: tail)
                let midStyle = makeCodeParagraphStyle(style: style, before: 0, after: 0, indent: indent, tailIndent: tail)
                let endStyle = makeCodeParagraphStyle(style: style, before: 0, after: isLast ? 0 : (cardPadV + style.paragraphGap), indent: indent, tailIndent: tail)
                lastPStyle = endStyle

                let fullHighlighted = SpikeCodeHighlighter.highlight(body, language: language, isOutput: isOutput, style: style, paragraphStyle: midStyle)
                let mutable = NSMutableAttributedString(attributedString: fullHighlighted)
                let nsBody = body as NSString
                let firstNewline = nsBody.range(of: "\n")
                if firstNewline.location != NSNotFound {
                    let firstRange = NSRange(location: 0, length: firstNewline.location + 1)
                    mutable.addAttribute(.paragraphStyle, value: firstStyle, range: firstRange)
                }
                let lastNewline = nsBody.range(of: "\n", options: .backwards)
                if lastNewline.location != NSNotFound && lastNewline.location + 1 < mutable.length {
                    let lastRange = NSRange(location: lastNewline.location + 1, length: mutable.length - (lastNewline.location + 1))
                    mutable.addAttribute(.paragraphStyle, value: endStyle, range: lastRange)
                }
                out.append(mutable)
            }

            let span = NSRange(location: 0, length: out.length)
            let decoration = SpikeCodeBlockDecoration(
                range: span,
                language: language,
                isOutput: isOutput,
                lineCount: max(1, lines.count)
            )
            return BlockCacheEntry(
                attributed: out,
                trailingSeparatorStyle: lastPStyle,
                inlineCodeOffsets: [],
                codeMeta: decoration,
                quoteSpan: nil,
                isRule: false
            )

        case .table(let table):
            let out = NSMutableAttributedString()
            let columns = max(1, max(table.header.count, table.rows.map(\.count).max() ?? 0))
            let usableWidth = max(180, contentWidth - Ink.Space.l * 2)
            let colStep = usableWidth / CGFloat(columns)
            var tabStops: [NSTextTab] = []
            for col in 1..<columns {
                tabStops.append(NSTextTab(textAlignment: .left, location: Ink.Space.m + colStep * CGFloat(col)))
            }
            let cardPadV = Ink.Space.m
            let headerP = makeParagraphStyle(
                style: style,
                spacing: style.listSpacing,
                before: isFirst ? 0 : cardPadV,
                indent: Ink.Space.m,
                tailIndent: -Ink.Space.m,
                tight: true
            )
            headerP.tabStops = tabStops

            let rowCount = table.rows.count
            let headerLine = table.header.joined(separator: "\t")
            out.append(buildInline(headerLine, size: style.tableCellSize, bold: true, style: style, ink: UIColor(Ink.ink), paragraph: headerP))

            var lastPStyle = headerP
            for (rIdx, row) in table.rows.enumerated() {
                let rowLast = rIdx == rowCount - 1
                let rowP = makeParagraphStyle(
                    style: style,
                    spacing: rowLast ? (isLast ? 0 : cardPadV + style.paragraphGap) : style.listSpacing,
                    before: 0,
                    indent: Ink.Space.m,
                    tailIndent: -Ink.Space.m,
                    tight: true
                )
                rowP.tabStops = tabStops
                out.append(NSAttributedString(string: "\n", attributes: [
                    .font: Ink.uiFace(style.tableCellSize, face: style.face),
                    .paragraphStyle: lastPStyle,
                ]))
                lastPStyle = rowP
                out.append(buildInline(row.joined(separator: "\t"), size: style.tableCellSize, bold: false, style: style, ink: UIColor(Ink.inkSoft), paragraph: rowP))
            }
            let span = NSRange(location: 0, length: out.length)
            return BlockCacheEntry(
                attributed: out,
                trailingSeparatorStyle: lastPStyle,
                inlineCodeOffsets: extractInlineCodeRanges(in: out),
                codeMeta: nil,
                quoteSpan: span,
                isRule: false
            )

        case .math(let latex):
            let spacing = isLast ? 0 : style.paragraphGap
            let pStyle = makeCodeParagraphStyle(style: style, before: 0, after: spacing, indent: Ink.Space.l, tailIndent: -Ink.Space.l)
            let attr = NSAttributedString(string: latex.isEmpty ? " " : latex, attributes: [
                .font: Ink.uiMono(style.codeSize, preference: style.code),
                .foregroundColor: UIColor(Ink.ink),
                .paragraphStyle: pStyle,
            ])
            return BlockCacheEntry(
                attributed: attr,
                trailingSeparatorStyle: pStyle,
                inlineCodeOffsets: [],
                codeMeta: nil,
                quoteSpan: NSRange(location: 0, length: attr.length),
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
                codeMeta: nil,
                quoteSpan: nil,
                isRule: true
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

    private func trimCodeEdgeBlanks(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    private func makeParagraphStyle(
        style: SpikeStyle,
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
        if tailIndent != 0 {
            pStyle.tailIndent = tailIndent
        }
        if hanging > 0 {
            pStyle.tabStops = [NSTextTab(textAlignment: .left, location: indent + hanging)]
        }
        return pStyle
    }

    private func makeCodeParagraphStyle(
        style: SpikeStyle,
        before: CGFloat,
        after: CGFloat,
        indent: CGFloat,
        tailIndent: CGFloat
    ) -> NSMutableParagraphStyle {
        let pStyle = NSMutableParagraphStyle()
        pStyle.lineSpacing = style.codeLineSpacing
        pStyle.paragraphSpacingBefore = before
        pStyle.paragraphSpacing = after
        pStyle.firstLineHeadIndent = indent
        pStyle.headIndent = indent
        pStyle.tailIndent = tailIndent
        return pStyle
    }

    private func buildInline(
        _ text: String,
        size: CGFloat,
        bold: Bool,
        style: SpikeStyle,
        ink: UIColor,
        paragraph: NSParagraphStyle
    ) -> NSAttributedString {
        let parsed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            let isBold = bold || intent.contains(.stronglyEmphasized)
            var font = Ink.uiFace(size, bold: isBold, face: style.face)
            if intent.contains(.emphasized),
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
            if intent.contains(.code) {
                attributes[.font] = Ink.uiMono(max(CGFloat(12), size - 2), preference: style.code)
                attributes[.foregroundColor] = UIColor(Ink.accent)
                attributes[.spikeInlineCode] = true
            }
            if intent.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = run.link {
                attributes[.link] = link
                attributes[.foregroundColor] = UIColor(Ink.accent)
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            out.append(NSAttributedString(string: piece, attributes: attributes))
        }
        return out
    }

    private func extractInlineCodeRanges(in attr: NSAttributedString) -> [NSRange] {
        var ranges: [NSRange] = []
        attr.enumerateAttribute(.spikeInlineCode, in: NSRange(location: 0, length: attr.length)) { value, range, _ in
            if value != nil {
                ranges.append(range)
            }
        }
        return ranges
    }
}

@MainActor
enum SpikeCellMetrics {
    static var speakerHeight: CGFloat { Ink.Size.micro * 1.4 }
    static var speakerGap: CGFloat { Ink.Space.xs }
    static var assistantTopPad: CGFloat { Ink.Space.xs }
    static var footerGap: CGFloat { Ink.Space.s }
    static var footerHeight: CGFloat { 18 * UIScale.factor }
    static var assistantBottomPad: CGFloat { Ink.Space.l }

    static var userBubbleTopPad: CGFloat { 10 * UIScale.factor }
    static var userBubbleBottomPad: CGFloat { 10 * UIScale.factor }
    static var userBubbleHorizontalPad: CGFloat { Ink.Space.l }
    static var userQuoteHeightGap: CGFloat { Ink.Space.s }
    static var userRowBottomPad: CGFloat { Ink.Space.m }
}

@MainActor
final class SpikeLayoutCache {
    struct Entry {
        let rendered: SpikeRenderedProse
        let textHeight: CGFloat
        let textWidth: CGFloat
        let quoteHeight: CGFloat
        let bubbleWidth: CGFloat
        let cellHeight: CGFloat
    }

    private struct CacheKey: Hashable {
        let id: UUID
        let styleKey: String
        let widthKey: Int
        let text: String
        let quote: String
        let isStreaming: Bool
        let showSpeaker: Bool
    }

    let builder = SpikeProseBuilder()
    private var finalizedCache: [CacheKey: Entry] = [:]
    private var streamingCache: [UUID: (key: CacheKey, entry: Entry)] = [:]
    private let measurer: UITextView = {
        let tv = UITextView(usingTextLayoutManager: true)
        tv.isEditable = false
        tv.isSelectable = false
        tv.isScrollEnabled = false
        tv.textContainer.lineFragmentPadding = 0
        tv.linkTextAttributes = [:]
        return tv
    }()

    private let quoteMeasurer: UILabel = {
        let label = UILabel()
        label.numberOfLines = 2
        return label
    }()

    func invalidateAll() {
        finalizedCache.removeAll(keepingCapacity: true)
        streamingCache.removeAll(keepingCapacity: true)
    }

    func invalidate(messageId: UUID) {
        streamingCache.removeValue(forKey: messageId)
        finalizedCache = finalizedCache.filter { $0.key.id != messageId }
    }

    func measure(
        message: SpikeMessage,
        collectionWidth: CGFloat,
        style: SpikeStyle,
        showSpeaker: Bool
    ) -> Entry {
        let widthKey = Int((collectionWidth * 2).rounded())
        let key = CacheKey(
            id: message.id,
            styleKey: style.styleKey,
            widthKey: widthKey,
            text: message.text,
            quote: message.quote ?? "",
            isStreaming: message.isStreaming,
            showSpeaker: showSpeaker
        )
        if message.isStreaming {
            if let hit = streamingCache[message.id], hit.key == key {
                return hit.entry
            }
        } else {
            streamingCache.removeValue(forKey: message.id)
            if let hit = finalizedCache[key] {
                return hit
            }
        }

        let entry: Entry
        switch message.role {
        case .assistant:
            let textWidth = max(120, collectionWidth - Ink.Space.page * 2)
            let rendered = builder.buildAssistantProse(
                message.text,
                style: style,
                contentWidth: textWidth,
                isStreaming: message.isStreaming
            )
            let textSize = measureTextSize(rendered: rendered, maxWidth: textWidth)
            var total = SpikeCellMetrics.assistantTopPad
            if showSpeaker {
                total += SpikeCellMetrics.speakerHeight + SpikeCellMetrics.speakerGap
            }
            total += textSize.height
            total += SpikeCellMetrics.footerGap + SpikeCellMetrics.footerHeight + SpikeCellMetrics.assistantBottomPad
            entry = Entry(
                rendered: rendered,
                textHeight: textSize.height,
                textWidth: textWidth,
                quoteHeight: 0,
                bubbleWidth: textWidth,
                cellHeight: ceil(total)
            )

        case .user:
            let maxBubbleWidth = max(140, collectionWidth - Ink.Space.page - Ink.Space.huge)
            let maxTextWidth = max(80, maxBubbleWidth - SpikeCellMetrics.userBubbleHorizontalPad * 2)
            let rendered = builder.buildUserText(message.text, style: style)
            let textSize = measureTextSize(rendered: rendered, maxWidth: maxTextWidth)
            var quoteH: CGFloat = 0
            var quoteW: CGFloat = 0
            if let quote = message.quote, !quote.isEmpty {
                quoteMeasurer.font = UIFont.systemFont(ofSize: Ink.Size.small)
                quoteMeasurer.text = quote
                let qSize = quoteMeasurer.sizeThatFits(CGSize(width: maxTextWidth - Ink.Space.s - 2.5, height: .greatestFiniteMagnitude))
                quoteH = ceil(qSize.height)
                quoteW = ceil(qSize.width) + Ink.Space.s + 2.5
            }
            let contentW = min(maxTextWidth, max(24, max(textSize.width, quoteW)))
            let bubbleW = min(maxBubbleWidth, contentW + SpikeCellMetrics.userBubbleHorizontalPad * 2)
            let bubbleH = SpikeCellMetrics.userBubbleTopPad
                + (quoteH > 0 ? quoteH + SpikeCellMetrics.userQuoteHeightGap : 0)
                + textSize.height
                + SpikeCellMetrics.userBubbleBottomPad
            let total = ceil(bubbleH + SpikeCellMetrics.userRowBottomPad)
            entry = Entry(
                rendered: rendered,
                textHeight: textSize.height,
                textWidth: contentW,
                quoteHeight: quoteH,
                bubbleWidth: bubbleW,
                cellHeight: total
            )
        }

        if message.isStreaming {
            streamingCache[message.id] = (key: key, entry: entry)
        } else {
            if finalizedCache.count > 1200 {
                finalizedCache.removeAll(keepingCapacity: true)
            }
            finalizedCache[key] = entry
        }
        return entry
    }

    func measureTextSize(rendered: SpikeRenderedProse, maxWidth: CGFloat) -> CGSize {
        measurer.attributedText = rendered.attributed
        measurer.textContainerInset = UIEdgeInsets(top: rendered.topInset, left: 0, bottom: rendered.bottomInset, right: 0)
        let fitted = measurer.sizeThatFits(CGSize(width: maxWidth, height: .greatestFiniteMagnitude))
        return CGSize(width: min(maxWidth, ceil(fitted.width)), height: ceil(fitted.height))
    }
}
#endif
