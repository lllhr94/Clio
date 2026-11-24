import AgentKit
import UIKit
import Prose
import SwiftUI

/// Parsed pages kept so a long conversation is not parsed again on every redraw.
enum ParsedCache {
    private final class Box { let blocks: [Prose.Block]; init(_ blocks: [Prose.Block]) { self.blocks = blocks } }
    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 400
        return cache
    }()

    static func blocks(_ text: String) -> [Prose.Block] {
        let key = text as NSString
        if let kept = cache.object(forKey: key) { return kept.blocks }
        let parsed = Prose.parse(text)
        cache.setObject(Box(parsed), forKey: key)
        return parsed
    }
}

/// A companion's words, set as a page: paragraphs, lists, tables, code and quotes.
/// While a reply is still arriving, only its last block changes, and that block's newest glyphs fade in.
struct ProseView: View {
    // Read so a change in 纸墨 redraws the text.
    @AppStorage("look.face") private var face = "serif"
    @AppStorage("look.code") private var code = "maple"
    @AppStorage("look.size") private var size = 17.0
    @AppStorage("look.lineHeight") private var leading = Pref.defaultLineHeight
    @AppStorage("look.fade") private var fade = true
    var text: String
    /// True while more is coming: the tail of the last block fades.
    var streaming = false

    init(text: String, streaming: Bool = false) {
        self.text = text
        self.streaming = streaming
    }

    var body: some View {
        let _ = (face, code, size)
        let blocks = streaming ? Prose.parse(Prose.mend(text)) : ParsedCache.blocks(text)
        // Paragraphs a little under one line apart, as in the reading apps that read best.
        VStack(alignment: .leading, spacing: Ink.paragraphGap) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                BlockView(block: block, fading: fade && streaming && index == blocks.count - 1, live: streaming && index == blocks.count - 1)
            }
        }
        // Changes to reading typography rebuild blocks that do not observe those preferences themselves.
        .id("\(face)-\(code)-\(size)-\(leading)")
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}

/// Once sealed, a block keeps its identity and its original text while the tail grows.
struct StreamingProse: View {
    let text: String
    @State private var scanner = StreamBlocks()
    @State private var sealed: [Prose.Block] = []
    @State private var tail: [Prose.Block] = []

    var body: some View {
        let blocks = scanner.receivedBytes == 0 ? Prose.parse(Prose.mend(text)) : sealed + tail
        ReplyProseLayout(text: text, blocks: blocks, streaming: true)
            .onChange(of: text, initial: true) { _, new in
                // A shortened stream starts over; the caller gives every new reply its own identity.
                if new.utf8.count < scanner.receivedBytes {
                    scanner = StreamBlocks()
                    sealed = []
                }
                let count = scanner.finished.count
                let delta = String(decoding: new.utf8.dropFirst(scanner.receivedBytes), as: UTF8.self)
                scanner.append(delta)
                for source in scanner.finished.dropFirst(count) {
                    sealed.append(contentsOf: ParsedCache.blocks(source))
                }
                tail = Prose.parse(Prose.mend(scanner.tail))
            }
    }
}

/// Incremental blank-line scanner. The rendered tail includes the unfinished line, but the
/// boundary scanner only sees it once its newline arrives. A blank line after a list item, a table row or a quote
/// does not end the block at once: a list with loose items, or a table with a gap, often carries on, and sealing it
/// early drew it as two pieces that jumped together when the reply finished. Such a block ends only when the next
/// written line does not carry it on.
struct StreamBlocks {
    private(set) var finished: [String] = []
    private(set) var receivedBytes = 0
    private var pending = ""
    private var line = ""
    private var fence: String?
    private var previousBlank = false
    /// The last line with words in `pending`, and whether a blank came after it that may or may not end the block.
    private var lastContent = ""
    private var waiting = false

    var tail: String { pending + line }

    mutating func append(_ delta: String) {
        guard !delta.isEmpty else { return }
        receivedBytes += delta.utf8.count
        let lines = delta.utf8.split(separator: 10, omittingEmptySubsequences: false)
        for (index, bytes) in lines.enumerated() {
            line += String(decoding: bytes, as: UTF8.self)
            guard index < lines.count - 1 else { break }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let blank = trimmed.isEmpty
            if !blank, waiting {
                waiting = false
                if !Self.continues(lastContent, line) {
                    finished.append(pending)
                    pending = ""
                }
            }
            if let marker = fence {
                if trimmed.hasPrefix(marker) { fence = nil }
            } else if trimmed.hasPrefix("```") {
                fence = "```"
            } else if trimmed.hasPrefix("~~~") {
                fence = "~~~"
            }
            let boundary = blank && !previousBlank && fence == nil && !pending.isEmpty
            pending += line + "\n"
            line = ""
            if boundary {
                if Self.mayContinue(lastContent) {
                    waiting = true
                } else {
                    finished.append(pending)
                    pending = ""
                }
            }
            if !blank { lastContent = trimmed }
            previousBlank = blank
        }
    }

    /// A list item, a table row or a quote: what may go on after a blank line.
    private static func mayContinue(_ last: String) -> Bool {
        listItem(last) || last.hasPrefix("|") || last.hasPrefix(">")
    }

    /// Whether `next` carries on the block whose last line was `last`.
    private static func continues(_ last: String, _ next: String) -> Bool {
        let trimmed = next.trimmingCharacters(in: .whitespaces)
        if listItem(last) { return listItem(trimmed) || next.hasPrefix("  ") || next.hasPrefix("\t") }
        if last.hasPrefix("|") { return trimmed.hasPrefix("|") }
        if last.hasPrefix(">") { return trimmed.hasPrefix(">") }
        return false
    }

    private static func listItem(_ text: String) -> Bool {
        if text.hasPrefix("- ") || text.hasPrefix("* ") || text.hasPrefix("+ ") { return true }
        let digits = text.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count < 10 else { return false }
        let rest = text.dropFirst(digits.count)
        return rest.hasPrefix(". ") || rest.hasPrefix(") ")
    }
}

/// Shared typographic proportions used by both `BlockView` and `ProseWords` so streaming and finished text match.
private enum ProseMetrics {
    static func headingSize(level: Int) -> CGFloat {
        let base = CGFloat(Pref.size)
        if level <= 1 { return (base * 1.24).rounded() }
        if level == 2 { return (base * 1.13).rounded() }
        return (base * 1.05).rounded()
    }

    static func headingTop(level: Int) -> CGFloat {
        let base = CGFloat(Pref.size)
        if level <= 1 { return base * 1.1 }
        if level == 2 { return base * 0.85 }
        return base * 0.55
    }

    static var headingBottom: CGFloat { CGFloat(Pref.size) * 0.35 }
    static var listSpacing: CGFloat { CGFloat(Pref.size) * 0.42 }
    static var codeLineSpacing: CGFloat { max(1.5, CGFloat(max(12, Pref.size - 3)) * 0.13) }
    static var inlineCodeCorner: CGFloat { 5 * UIScale.factor }
}

/// Shared quote container used by both `BlockView` and `ReplyProseLayout`, keeping native `ProseText` selection inside quotes.
private struct QuoteCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, Ink.Space.m + 2.5)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Ink.accent.opacity(0.45))
                    .frame(width: 2.5)
            }
            .padding(.horizontal, Ink.Space.m)
            .padding(.vertical, Ink.Space.m)
            .background(Ink.paperRaised.opacity(0.75), in: .rect(cornerRadius: Ink.Radius.small, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Ink.Radius.small, style: .continuous).strokeBorder(Ink.rule.opacity(0.55), lineWidth: 0.5))
    }
}

private struct BlockView: View {
    let block: Prose.Block
    let fading: Bool
    /// The last block of a reply still being written, whether or not text fades in: a formula is not typeset and
    /// long code is not folded until it is complete.
    var live = false
    @Environment(\.noteInk) private var noteInk

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Inline(text: text, font: Ink.body(Double(ProseMetrics.headingSize(level: level)), bold: true), fading: fading, tight: true)
                // Much more air above a heading than below it, so it plainly belongs to what follows.
                .padding(.top, ProseMetrics.headingTop(level: level))
                .padding(.bottom, min(0, ProseMetrics.headingBottom - Ink.paragraphGap))
        case .paragraph(let text):
            if let files = FileCard.links(in: text) {
                VStack(alignment: .leading, spacing: Ink.Space.s) {
                    ForEach(Array(files.enumerated()), id: \.offset) { _, file in FileCard(label: file.label, path: file.path) }
                }
            } else if text.contains("![") {
                PictureParagraph(text: text, fading: fading)
            } else {
                Inline(text: text, font: Ink.reading, fading: fading)
            }
        case .list(let items):
            // Items closer together than paragraphs, with enough rhythm for numbered points to breathe.
            VStack(alignment: .leading, spacing: ProseMetrics.listSpacing) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    // A hanging indent: the marker in its own column, wrapped lines start under the text.
                    HStack(alignment: .firstTextBaseline, spacing: Pref.size * 0.45) {
                        marker(item)
                            .frame(width: item.number != nil ? Pref.size * 1.3 : Pref.size * 0.85, alignment: item.number != nil ? .trailing : .center)
                        Inline(text: item.text, font: Ink.reading, fading: fading && index == items.count - 1)
                    }
                    .padding(.leading, CGFloat(item.depth) * Pref.size * 1.25)
                }
            }
        case .quote(let blocks):
            QuoteCard {
                VStack(alignment: .leading, spacing: Ink.Space.s) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { index, inner in
                        BlockView(block: inner, fading: fading && index == blocks.count - 1, live: live && index == blocks.count - 1)
                    }
                }
                .environment(\.noteInk, noteInk ?? Ink.inkSoft)
            }
        case .code(let language, let text, _):
            CodeBlock(language: language, text: text, live: live)
        case .table(let table):
            TableBlock(table: table)
        case .math(let text):
            FormulaBlock(latex: text, streaming: fading || live)
        case .rule:
            LinearGradient(
                colors: [Ink.rule.opacity(0), Ink.rule.opacity(0.85), Ink.rule.opacity(0)],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 0.75)
            .padding(.horizontal, Ink.Space.l)
            .padding(.vertical, CGFloat(Pref.size) * 0.65)
        }
    }

    @ViewBuilder
    private func marker(_ item: Prose.Item) -> some View {
        if let checked = item.checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(.system(size: Ink.Size.sub))
                .foregroundStyle(checked ? Ink.accent : Ink.inkFaint)
        } else if let number = item.number {
            // Numbers in tabular figures and quiet ink: they anchor the left edge without fighting bold lead-ins.
            Text("\(number).")
                .font(Ink.body(Pref.size * 0.92, bold: false).monospacedDigit())
                .foregroundStyle(Ink.inkFaint)
        } else {
            let glyph = item.depth == 0 ? "•" : (item.depth == 1 ? "◦" : "▪")
            Text(glyph)
                .font(.system(size: CGFloat(Pref.size) * (item.depth == 0 ? 0.95 : 0.78), weight: .semibold))
                .foregroundStyle(Ink.inkFaint)
        }
    }
}

/// Words with inline marks: bold, italics, code, links, strikethrough.
private struct Inline: View {
    let text: String
    let font: Font
    let fading: Bool
    /// Headings: closer lines.
    var tight = false
    @Environment(\.noteInk) private var noteInk

    private var styled: Text {
        var out = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        for run in out.runs {
            guard let intent = run.inlinePresentationIntent else { continue }
            if intent.contains(.code) {
                out[run.range].font = Ink.mono(CGFloat(max(12, Pref.size - 2)))
                // In the accent, on its pill, as the Claude app sets inline code (the owner's reference).
                out[run.range].foregroundColor = Ink.accent
            }
            if intent.contains(.stronglyEmphasized), noteInk == nil {
                out[run.range].foregroundColor = Ink.ink
            }
        }
        for run in out.runs where run.link != nil {
            out[run.range].foregroundColor = Ink.accent
            out[run.range].underlineStyle = .single
        }
        guard out.runs.contains(where: { $0.inlinePresentationIntent?.contains(.code) == true }) else {
            return Text(out)
        }
        return out.runs.reduce(Text("")) { text, run in
            let part = Text(AttributedString(out[run.range]))
            return text + (run.inlinePresentationIntent?.contains(.code) == true
                ? part.customAttribute(InlineCodeBadge()) : part)
        }
    }

    var body: some View {
        styled
            .font(font)
            .lineSpacing(tight ? Ink.leading * 0.5 : Ink.leading)
            .foregroundStyle(noteInk ?? Ink.ink)
            .textRenderer(TailFade(on: fading))
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct InlineCodeBadge: TextAttribute {}

/// The last glyphs of text still arriving fade from clear to full: as the text grows, each glyph fades in.
struct TailFade: TextRenderer {
    var on: Bool
    var tail = 12

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line where run[InlineCodeBadge.self] != nil {
                let rect = run.typographicBounds.rect.insetBy(dx: -2.5, dy: -0.5)
                let radius = min(ProseMetrics.inlineCodeCorner, rect.height * 0.3)
                context.fill(Path(roundedRect: rect, cornerRadius: radius), with: .color(Ink.mine.opacity(0.85)))
            }
        }
        guard on else {
            for line in layout { context.draw(line) }
            return
        }
        var slices: [Text.Layout.RunSlice] = []
        for line in layout {
            for run in line {
                for slice in run { slices.append(slice) }
            }
        }
        let total = slices.count
        for (index, slice) in slices.enumerated() {
            let fromEnd = total - 1 - index
            if fromEnd >= tail {
                context.draw(slice)
            } else {
                var soft = context
                soft.opacity = Double(tail - fromEnd) / Double(tail + 1)
                soft.draw(slice)
            }
        }
    }
}

/// Code: its language, a copy button, sideways scrolling, and keywords picked out.
private struct CodeBlock: View {
    let language: String
    let text: String
    /// Still being written: it grows in full, and folds only once complete (folding at line 21 jumped the page).
    var live = false
    @State private var copied = false
    @State private var unfolded = false
    @State private var contentWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    /// A line is wider than the block: only then may it slide.
    private var overflows: Bool { boxWidth > 0 && contentWidth > boxWidth + 1 }

    private var lineCount: Int { text.utf8.reduce(1) { $0 + ($1 == 10 ? 1 : 0) } }
    /// What a program printed (``` text, output, console…): one green, like a terminal, not colored as code.
    private var isOutput: Bool {
        if ["text", "txt", "output", "console", "log", "plaintext", "plain", "stdout", "shell-session"].contains(language.lowercased()) { return true }
        // No language given, and nothing that reads as code: a log or what a command printed.
        guard language.isEmpty else { return false }
        let marks = ["{", "}", ";", " = ", "=>", "->", "def ", "func ", "function ", "import ", "return ", "const ", "let ", "class "]
        return !marks.contains { text.contains($0) }
    }
    /// Long code shows its first lines; the rest opens on a tap.
    private var folds: Bool { !live && lineCount > 20 }
    private var shown: String {
        // Blank lines a model leaves at the top or bottom of a block are not shown (they read as a gap under the label).
        let body = Self.trimmedLines(text)
        guard folds, !unfolded else { return body }
        return body.split(separator: "\n", omittingEmptySubsequences: false).prefix(12).joined(separator: "\n")
    }

    static func trimmedLines(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    private var headerBar: some View {
        HStack(spacing: Ink.Space.s) {
            HStack(spacing: Ink.Space.xs) {
                if isOutput {
                    Image(systemName: "terminal")
                        .font(.system(size: Ink.Size.micro, weight: .semibold))
                        .foregroundStyle(Ink.Code.output)
                }
                Text(isOutput ? "输出" : (language.isEmpty ? "代码" : language.lowercased()))
                    .font(Ink.mono(Ink.Size.micro, weight: .medium))
                    .foregroundStyle(Ink.inkSoft)
            }
            if folds {
                Text("\(lineCount) 行")
                    .font(.system(size: Ink.Size.micro).monospacedDigit())
                    .foregroundStyle(Ink.inkFaint)
            }
            Spacer(minLength: Ink.Space.s)
            Button {
                // As plain code: no-break and zero-width spaces some models write would break a pasted command.
                UIPasteboard.general.string = text
                    .replacingOccurrences(of: "\u{00A0}", with: " ")
                    .replacingOccurrences(of: "\u{200B}", with: "")
                    .replacingOccurrences(of: "\u{FEFF}", with: "")
                Haptics.tick(0.5)
                withAnimation(Ink.Motion.settle) { copied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { withAnimation(Ink.Motion.settle) { copied = false } }
            } label: {
                HStack(spacing: Ink.Space.xs) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                    Text(copied ? "已复制" : "复制")
                }
                .font(.system(size: Ink.Size.micro, weight: .medium))
                .foregroundStyle(copied ? Ink.ok : Ink.inkSoft)
                .padding(.horizontal, Ink.Space.s)
                .frame(height: 26 * UIScale.factor)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle(haptic: false))
            .accessibilityLabel("复制代码")
        }
        .padding(.leading, Ink.Space.l)
        .padding(.trailing, Ink.Space.s)
        .frame(height: 32 * UIScale.factor)
        .background(Ink.mine.opacity(0.42))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Ink.rule.opacity(0.75)).frame(height: 0.5)
        }
    }

    private var codeBody: some View {
        // Lines are kept whole, so long code stays short on the page instead of folding into a tall block.
        // The block only slides sideways when a line really is wider than it; otherwise it cannot move and never
        // takes the drag from the chat (Open Minis' rule). A soft fade at the right edge says there is more.
        ScrollView(.horizontal) {
            Text(isOutput ? Highlight.output(shown, cache: !live) : Highlight.code(shown, language: language, cache: !live))
                .foregroundStyle(isOutput ? Ink.Code.output : Ink.ink)
                .font(Ink.code)
                // Tight column-aligned monospace rhythm (~0.13x font size) with clean vertical padding.
                .lineSpacing(ProseMetrics.codeLineSpacing)
                .padding(.horizontal, Ink.Space.l)
                .padding(.vertical, Ink.Space.m)
                .fixedSize(horizontal: true, vertical: false)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { next in
                    if abs(contentWidth - next) > 0.5 { contentWidth = next }
                }
        }
        .scrollIndicators(.hidden)
        .scrollDisabled(!overflows)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { next in
            if abs(boxWidth - next) > 0.5 { boxWidth = next }
        }
        .overlay(alignment: .leading) {
            if isOutput {
                Rectangle().fill(Ink.Code.output.opacity(0.65)).frame(width: 2.5)
            }
        }
        .overlay(alignment: .trailing) {
            if overflows {
                LinearGradient(colors: [Ink.paperRaised.opacity(0), Ink.paperRaised], startPoint: .leading, endPoint: .trailing)
                    .frame(width: Ink.Space.xl)
                    .allowsHitTesting(false)
            }
        }
    }

    private var foldButton: some View {
        Button {
            Haptics.tick(0.4)
            withAnimation(Ink.Motion.settle) { unfolded.toggle() }
        } label: {
            Label(unfolded ? "收起" : "展开全部 \(lineCount) 行", systemImage: unfolded ? "chevron.up" : "chevron.down")
                .font(.system(size: Ink.Size.small, weight: .medium))
                .foregroundStyle(Ink.accent)
                .frame(maxWidth: .infinity)
                .frame(height: 34 * UIScale.factor)
                .background(Ink.mine.opacity(0.28))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) { Rectangle().fill(Ink.rule.opacity(0.75)).frame(height: 0.5) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            codeBody
            if folds { foldButton }
        }
        .inkBlock()
    }
}

private final class TableCacheKey: NSObject {
    let table: Prose.Table
    let face: Pref.Face
    let size: CGFloat
    let fontGen: Int
    private let cachedHash: Int

    init(table: Prose.Table, face: Pref.Face, size: CGFloat, fontGen: Int) {
        self.table = table
        self.face = face
        self.size = size
        self.fontGen = fontGen
        var hasher = Hasher()
        hasher.combine(face)
        hasher.combine(size)
        hasher.combine(fontGen)
        hasher.combine(table.header)
        hasher.combine(table.rows.count)
        if let first = table.rows.first { hasher.combine(first) }
        if let last = table.rows.last, table.rows.count > 1 { hasher.combine(last) }
        self.cachedHash = hasher.finalize()
    }

    override var hash: Int { cachedHash }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? TableCacheKey else { return false }
        return cachedHash == other.cachedHash
            && face == other.face
            && size == other.size
            && fontGen == other.fontGen
            && table == other.table
    }
}

private final class PreparedTable {
    let widths: [CGFloat]
    let header: [AttributedString]
    let rows: [[AttributedString]]

    init(widths: [CGFloat], header: [AttributedString], rows: [[AttributedString]]) {
        self.widths = widths
        self.header = header
        self.rows = rows
    }
}

@MainActor
private enum TableLayoutCache {
    private static let cache: NSCache<TableCacheKey, PreparedTable> = {
        let cache = NSCache<TableCacheKey, PreparedTable>()
        cache.countLimit = 128
        return cache
    }()

    static func prepare(_ table: Prose.Table, cellSize: CGFloat) -> PreparedTable {
        let key = TableCacheKey(table: table, face: Pref.face, size: cellSize, fontGen: FontShelf.shared.generation)
        if let hit = cache.object(forKey: key) { return hit }
        let columns = max(table.header.count, table.rows.map(\.count).max() ?? 0)
        let headFont = Ink.uiFace(cellSize, bold: true)
        let bodyFont = Ink.uiFace(cellSize, bold: false)
        let widths: [CGFloat] = (0..<columns).map { column in
            var natural = measure(column < table.header.count ? table.header[column] : "", font: headFont)
            for row in table.rows where column < row.count {
                natural = max(natural, measure(row[column], font: bodyFont))
            }
            return max(28, ceil(natural) + 4)
        }
        let header = table.header.map(parseCell)
        let rows = table.rows.map { $0.map(parseCell) }
        let prepared = PreparedTable(widths: widths, header: header, rows: rows)
        cache.setObject(prepared, forKey: key)
        return prepared
    }

    private static func measure(_ cell: String, font: UIFont) -> CGFloat {
        let plain = cell.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "~~", with: "")
        return (plain as NSString).size(withAttributes: [.font: font]).width
    }

    private static func parseCell(_ cell: String) -> AttributedString {
        (try? AttributedString(markdown: cell, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(cell)
    }
}

/// A table that scrolls sideways when it is wider than the page.
/// Each column's width is planned for the room the table has (see `spread`), and each row is as tall
/// as its tallest cell, so a cell that wraps onto several lines pushes the line under it down instead of
/// running over it.
private struct TableBlock: View {
    let table: Prose.Table

    /// Table text, two points under the reading size.
    private static var cellSize: CGFloat { CGFloat(max(12, Pref.size - 2)) }
    private static let gap: CGFloat = 20
    /// How wide the block is on the page, so a narrow table can spread across it.
    @State private var room: CGFloat = 0
    @State private var contentWidth: CGFloat = 0
    private var overflows: Bool { room > 0 && contentWidth > room + 1 }

    /// Column widths planned for the width the table really has, on any phone, the way reading apps lay out tables
    /// (after Open Minis' planner, written anew): a column with more text is never narrower than one with less.
    /// 1. Everything fits on one line: the leftover room is shared in proportion to each column's text.
    /// 2. Each column at a comfortable width (at most 35% of the room) fits: they fill the room, the wordier ones
    ///    getting more, and cells wrap.
    /// 3. Otherwise the table slides sideways, no column wider than 70% of the room, so the next one peeks in.
    private func spread(_ natural: [CGFloat]) -> [CGFloat] {
        guard !natural.isEmpty, room > 0 else { return natural }
        let count = CGFloat(natural.count)
        let available = room - Self.gap * (count - 1) - Ink.Space.l * 2
        guard available > 0 else { return natural }
        let floor = min(80, available / count)
        let total = natural.reduce(0, +)
        if total <= available {
            let extra = available - total
            return natural.map { $0 + extra * $0 / max(1, total) }
        }
        let comfortable = natural.map { max(floor, min($0, available * 0.35)) }
        let snug = comfortable.reduce(0, +)
        if snug <= available {
            // The rest goes to the columns that still want more, in proportion to how much more.
            let wants = zip(natural, comfortable).map { max(0, $0 - $1) }
            let wanted = wants.reduce(0, +)
            let extra = available - snug
            return zip(comfortable, wants).map { $0 + (wanted > 0 ? extra * $1 / wanted : extra / count) }
        }
        return natural.map { max(floor, min($0, available * 0.7)) }
    }

    var body: some View {
        let prepared = TableLayoutCache.prepare(table, cellSize: Self.cellSize)
        let widths = spread(prepared.widths)
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                row(prepared.header, head: true, widths: widths)
                    .background(Ink.mine.opacity(0.45))
                Rectangle().fill(Ink.rule).frame(height: 0.75)
                ForEach(Array(prepared.rows.enumerated()), id: \.offset) { index, cells in
                    if index > 0 { Rectangle().fill(Ink.rule.opacity(0.7)).frame(height: 0.5) }
                    row(cells, head: false, widths: widths)
                        .background(index.isMultiple(of: 2) ? Color.clear : Ink.mine.opacity(0.18))
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { next in
                if abs(contentWidth - next) > 0.5 { contentWidth = next }
            }
        }
        .scrollIndicators(.hidden)
        .scrollDisabled(!overflows)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { next in
            if abs(room - next) > 0.5 { room = next }
        }
        .overlay(alignment: .trailing) {
            if overflows {
                LinearGradient(colors: [Ink.paperRaised.opacity(0), Ink.paperRaised], startPoint: .leading, endPoint: .trailing)
                    .frame(width: Ink.Space.xl)
                    .allowsHitTesting(false)
            }
        }
        .inkBlock()
        .contextMenu {
            Button(L.t("actions.copy"), systemImage: "doc.on.doc") {
                UIPasteboard.general.string = Self.plainTSV(table)
            }
            Button("复制 Markdown", systemImage: "tablecells") {
                UIPasteboard.general.string = Self.markdownSource(table)
            }
        }
    }

    private static func stripInlineMarks(_ cell: String) -> String {
        cell.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "~~", with: "")
    }

    private static func plainTSV(_ table: Prose.Table) -> String {
        let allRows = [table.header] + table.rows
        return allRows
            .map { $0.map(stripInlineMarks).joined(separator: "\t") }
            .joined(separator: "\n")
    }

    private static func markdownSource(_ table: Prose.Table) -> String {
        let cols = max(table.header.count, table.rows.map(\.count).max() ?? 0)
        guard cols > 0 else { return "" }
        func formatRow(_ cells: [String]) -> String {
            let padded = (0..<cols).map { idx in
                let raw = idx < cells.count ? cells[idx] : ""
                return raw.replacingOccurrences(of: "|", with: "\\|")
            }
            return "| " + padded.joined(separator: " | ") + " |"
        }
        var lines = [formatRow(table.header)]
        lines.append("| " + Array(repeating: "---", count: cols).joined(separator: " | ") + " |")
        for row in table.rows {
            lines.append(formatRow(row))
        }
        return lines.joined(separator: "\n")
    }

    private func row(_ cells: [AttributedString], head: Bool, widths: [CGFloat]) -> some View {
        HStack(alignment: .top, spacing: Self.gap) {
            ForEach(Array(widths.enumerated()), id: \.offset) { column, width in
                cellText(column < cells.count ? cells[column] : AttributedString(""), head: head, column: column)
                    .frame(width: width, alignment: frameAlign(column))
            }
        }
        .padding(.horizontal, Ink.Space.l)
        .padding(.vertical, Self.cellSize * 0.62)
    }

    private func frameAlign(_ column: Int) -> Alignment {
        let align = column < table.aligns.count ? table.aligns[column] : .leading
        return align == .center ? .top : (align == .trailing ? .topTrailing : .topLeading)
    }

    private func cellText(_ styled: AttributedString, head: Bool, column: Int) -> some View {
        let align = column < table.aligns.count ? table.aligns[column] : .leading
        // Cells in the reading face, like the words around the table; the body in full ink, as text to read.
        return Text(styled)
            .font(Ink.body(Double(Self.cellSize), bold: head))
            .foregroundStyle(Ink.ink)
            .multilineTextAlignment(align == .center ? .center : (align == .trailing ? .trailing : .leading))
            .lineSpacing(Self.cellSize * 0.25)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private final class HighlightCacheKey: NSObject {
    let isOutput: Bool
    let language: String
    let codePref: Pref.Code
    let size: Double
    let text: String
    private let cachedHash: Int

    init(isOutput: Bool, language: String, codePref: Pref.Code, size: Double, text: String) {
        self.isOutput = isOutput
        self.language = language
        self.codePref = codePref
        self.size = size
        self.text = text
        var hasher = Hasher()
        hasher.combine(isOutput)
        hasher.combine(language)
        hasher.combine(codePref)
        hasher.combine(size)
        mixFastStringHash(text, into: &hasher)
        self.cachedHash = hasher.finalize()
    }

    override var hash: Int { cachedHash }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? HighlightCacheKey else { return false }
        return cachedHash == other.cachedHash
            && isOutput == other.isOutput
            && codePref == other.codePref
            && size == other.size
            && text.utf8.count == other.text.utf8.count
            && language == other.language
            && text == other.text
    }
}

private final class HighlightBox {
    let attributed: AttributedString
    init(_ attributed: AttributedString) { self.attributed = attributed }
}

/// Keyword-level coloring, enough to read code at a glance.
@MainActor enum Highlight {
    private static let cache: NSCache<HighlightCacheKey, HighlightBox> = {
        let cache = NSCache<HighlightCacheKey, HighlightBox>()
        cache.countLimit = 256
        return cache
    }()

    private static let keywords: Set<String> = [
        "func", "let", "var", "if", "else", "for", "while", "return", "import", "struct", "class", "enum", "case", "switch",
        "def", "from", "as", "in", "not", "and", "or", "is", "None", "True", "False", "lambda", "with", "try", "except",
        "const", "function", "async", "await", "new", "this", "self", "true", "false", "null", "nil", "export", "default",
        "public", "private", "static", "void", "int", "string", "bool", "fn", "pub", "mut", "impl", "use", "match",
    ]

    private enum Style {
        case plain, keyword, function, number, string, comment

        var color: Color {
            switch self {
            case .plain: Ink.ink
            case .keyword: Ink.Code.keyword
            case .function: Ink.Code.function
            case .number: Ink.Code.number
            case .string: Ink.Code.string
            case .comment: Ink.inkFaint
            }
        }
    }

    static func output(_ text: String, cache useCache: Bool = true) -> AttributedString {
        if useCache {
            let key = HighlightCacheKey(isOutput: true, language: "", codePref: Pref.code, size: Pref.size, text: text)
            if let hit = cache.object(forKey: key) { return hit.attributed }
            let fonts = fonts(for: text)
            var result = AttributedString()
            append(text[...], fonts: fonts, to: &result)
            cache.setObject(HighlightBox(result), forKey: key)
            return result
        }
        let fonts = fonts(for: text)
        var result = AttributedString()
        append(text[...], fonts: fonts, to: &result)
        return result
    }

    private static func fonts(for text: String) -> (narrow: Font, wide: Font) {
        guard text.contains(where: wide) else { return (Ink.code, Ink.code) }
        return Ink.codeBlockFonts()
    }

    private static func wide(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x00B7, 0x2014, 0x2018...0x2019, 0x201C...0x201D, 0x2026, 0x1100...0x11FF, 0x2E80...0xA4CF, 0xAC00...0xD7FF, 0xF900...0xFAFF,
             0xFE10...0xFE1F, 0xFE30...0xFE6F, 0xFF01...0xFF60, 0xFFE0...0xFFE6, 0x20000...0x323AF:
            return true
        default:
            return false
        }
    }

    private static func append(_ text: Substring, fonts: (narrow: Font, wide: Font),
                               color: Color? = nil, italic: Bool = false, to result: inout AttributedString) {
        guard let first = text.first else { return }
        var isWide = wide(first)
        var start = text.startIndex
        func flush(upTo end: String.Index, into result: inout AttributedString) {
            var part = AttributedString(String(text[start..<end]))
            let face = isWide ? fonts.wide : fonts.narrow
            part.font = italic ? face.italic() : face
            part.foregroundColor = color
            result += part
        }
        for index in text.indices.dropFirst() {
            let next = wide(text[index])
            if next != isWide {
                flush(upTo: index, into: &result)
                start = index
                isWide = next
            }
        }
        flush(upTo: text.endIndex, into: &result)
    }

    static func code(_ text: String, language: String, cache useCache: Bool = true) -> AttributedString {
        let lowerLang = language.lowercased()
        let key: HighlightCacheKey? = useCache
            ? HighlightCacheKey(isOutput: false, language: lowerLang, codePref: Pref.code, size: Pref.size, text: text)
            : nil
        if let key, let hit = cache.object(forKey: key) { return hit.attributed }
        let fonts = fonts(for: text)
        var out = AttributedString()
        var index = text.startIndex
        var start = index
        var style: Style = .plain
        let hashComments = ["python", "py", "bash", "sh", "shell", "zsh", "ruby", "rb", "yaml", "yml", "toml"].contains(lowerLang)
        func flush(upTo end: String.Index) {
            guard start < end else { return }
            append(text[start..<end], fonts: fonts, color: style.color, italic: style == .comment, to: &out)
        }
        while index < text.endIndex {
            let rest = text[index...]
            let character = text[index]
            let next: Style
            var end: String.Index
            if rest.hasPrefix("//") || (hashComments && character == "#") {
                end = rest.firstIndex(of: "\n") ?? text.endIndex
                next = .comment
            } else if character == "\"" || character == "'" || character == "`" {
                end = text.index(after: index)
                while end < text.endIndex, text[end] != character, text[end] != "\n" {
                    if text[end] == "\\" { end = text.index(after: end) }
                    if end < text.endIndex { end = text.index(after: end) }
                }
                if end < text.endIndex, text[end] == character { end = text.index(after: end) }
                next = .string
            } else if character.isLetter || character == "_" {
                end = rest.firstIndex { !($0.isLetter || $0.isNumber || $0 == "_") } ?? text.endIndex
                let word = text[index..<end]
                let calls = end < text.endIndex && text[end] == "("
                next = keywords.contains(String(word)) ? .keyword : (calls ? .function : .plain)
            } else if character.isNumber {
                end = rest.firstIndex { !($0.isNumber || $0 == ".") } ?? text.endIndex
                next = .number
            } else {
                end = text.index(after: index)
                next = .plain
            }
            if next != style {
                flush(upTo: index)
                start = index
                style = next
            }
            index = end
        }
        flush(upTo: index)
        if let key { cache.setObject(HighlightBox(out), forKey: key) }
        return out
    }
}


/// A paragraph with pictures in it (`![描述](地址)`): the words, then each picture under them.
private struct PictureParagraph: View {
    let text: String
    let fading: Bool

    var body: some View {
        let parts = Self.split(text)
        VStack(alignment: .leading, spacing: Pref.size * 0.6) {
            if !parts.words.isEmpty {
                Inline(text: parts.words, font: Ink.reading, fading: fading)
            }
            ForEach(Array(parts.pictures.enumerated()), id: \.offset) { _, picture in
                ProsePicture(source: picture.source, label: picture.label)
            }
        }
    }

    static func split(_ text: String) -> (words: String, pictures: [(label: String, source: String)]) {
        guard let pattern = try? NSRegularExpression(pattern: #"!\[([^\]]*)\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)"#) else {
            return (text, [])
        }
        let whole = NSRange(text.startIndex..., in: text)
        var pictures: [(label: String, source: String)] = []
        for match in pattern.matches(in: text, range: whole) {
            guard let label = Range(match.range(at: 1), in: text), let source = Range(match.range(at: 2), in: text) else { continue }
            pictures.append((String(text[label]), String(text[source])))
        }
        let words = pattern.stringByReplacingMatches(in: text, range: whole, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (words, pictures)
    }
}

/// Blocks HTTP redirects to private/local addresses when downloading remote images in replies.
private final class PublicImageRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard let target = request.url,
              ["http", "https"].contains(target.scheme?.lowercased() ?? ""),
              !LocalAddress.isLocal(target),
              !(await LocalAddress.resolvesToLocal(target)) else {
            return nil
        }
        return request
    }
}

private final class CachedLocalPicture {
    let ref: WorkspaceFileRef
    let image: UIImage
    let modified: Date?

    init(ref: WorkspaceFileRef, image: UIImage, modified: Date?) {
        self.ref = ref
        self.image = image
        self.modified = modified
    }
}

@MainActor
private enum LocalPictureCache {
    private static let cache: NSCache<NSString, CachedLocalPicture> = {
        let cache = NSCache<NSString, CachedLocalPicture>()
        cache.countLimit = 24
        return cache
    }()

    static func get(_ key: String) -> CachedLocalPicture? {
        cache.object(forKey: key as NSString)
    }

    static func set(_ entry: CachedLocalPicture?, for key: String) {
        if let entry {
            cache.setObject(entry, forKey: key as NSString)
        } else {
            cache.removeObject(forKey: key as NSString)
        }
    }
}

/// One picture in a reply: from the web, or from 书案 (a path the companion wrote there). Tap to see it whole,
/// with the system viewer's share and save.
struct ProsePicture: View {
    private static let maxRemoteBytes = 25 * 1024 * 1024

    let source: String
    var label: String = ""
    @State private var image: UIImage?
    @State private var remoteFile: URL?
    @State private var workspaceRef: WorkspaceFileRef?
    @State private var failed = false
    @State private var open = false

    @MainActor
    init(source: String, label: String = "") {
        self.source = source
        self.label = label
        let isRemote = URL(string: source).flatMap { url in
            ["http", "https"].contains(url.scheme?.lowercased() ?? "") ? url : nil
        } != nil
        if !isRemote {
            let decodedPath = source.removingPercentEncoding ?? source
            if let hit = LocalPictureCache.get(decodedPath) {
                _image = State(initialValue: hit.image)
                _workspaceRef = State(initialValue: hit.ref)
                return
            }
        }
        _image = State(initialValue: nil)
        _workspaceRef = State(initialValue: nil)
    }

    private var canOpen: Bool { workspaceRef != nil || remoteFile != nil }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 360, alignment: .leading)
                    .clipShape(.rect(cornerRadius: Ink.Radius.small, style: .continuous))
                    .onTapGesture { if canOpen { Haptics.light(); open = true } }
                    .accessibilityLabel(label.isEmpty ? "图片" : label)
                    .accessibilityAddTraits(.isImage)
            } else if failed {
                Label(label.isEmpty ? "图片打不开" : "图片打不开：\(label)", systemImage: "photo.badge.exclamationmark")
                    .font(.system(size: Ink.Size.small))
                    .foregroundStyle(Ink.inkFaint)
            } else {
                RoundedRectangle(cornerRadius: Ink.Radius.small, style: .continuous)
                    .fill(Ink.mine)
                    .frame(height: 160)
                    .overlay { ProgressView() }
            }
        }
        .task(id: source) { await load() }
        .sheet(isPresented: $open) {
            if let workspaceRef {
                NavigationStack { StudyFile(url: workspaceRef.url, mount: workspaceRef.mount, showsDone: true) }
            } else if let remoteFile {
                QuickPreview(url: remoteFile).ignoresSafeArea()
            }
        }
    }

    private enum LocalOutcome: Sendable {
        case unchanged
        case missing
        case updated(WorkspaceFileRef, UIImage, Date?)
    }

    private func load() async {
        let written = source
        let remote = URL(string: written).flatMap { url in
            ["http", "https"].contains(url.scheme?.lowercased() ?? "") ? url : nil
        }
        if let remote {
            image = nil
            remoteFile = nil
            workspaceRef = nil
            failed = false
            guard !LocalAddress.isLocal(remote), !(await LocalAddress.resolvesToLocal(remote)) else {
                if !Task.isCancelled { failed = true }
                return
            }
            do {
                let downloaded = try await Self.downloadRemoteImage(remote)
                let preview = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                    guard let thumb = Workspace.picture(downloaded) else { return nil }
                    return UIImage(data: thumb.data)
                }.value
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: downloaded)
                    return
                }
                guard let preview else {
                    try? FileManager.default.removeItem(at: downloaded)
                    failed = true
                    return
                }
                remoteFile = downloaded
                image = preview
            } catch {
                if !Task.isCancelled { failed = true }
            }
            return
        }

        let decodedPath = written.removingPercentEncoding ?? written
        let cached = LocalPictureCache.get(decodedPath)
        if let cached {
            if workspaceRef != cached.ref { workspaceRef = cached.ref }
            if image !== cached.image { image = cached.image }
            if remoteFile != nil { remoteFile = nil }
            if failed { failed = false }
        } else {
            image = nil
            remoteFile = nil
            workspaceRef = nil
            failed = false
        }
        let cachedRef = cached?.ref
        let cachedModified = cached?.modified
        let outcome = await Task.detached(priority: .userInitiated) { () -> LocalOutcome in
            guard let ref = WorkspaceFileRef.resolve(decodedPath) else { return .missing }
            let modified = (try? FileManager.default.attributesOfItem(atPath: ref.url.path))?[.modificationDate] as? Date
            if let cachedRef, cachedRef == ref, cachedModified == modified {
                return .unchanged
            }
            guard let picture = WorkspaceFileRef.loadImage(ref) else { return .missing }
            return .updated(ref, picture, modified)
        }.value
        guard !Task.isCancelled else { return }
        switch outcome {
        case .unchanged:
            return
        case .missing:
            LocalPictureCache.set(nil, for: decodedPath)
            image = nil
            workspaceRef = nil
            failed = true
        case .updated(let ref, let picture, let modified):
            LocalPictureCache.set(CachedLocalPicture(ref: ref, image: picture, modified: modified), for: decodedPath)
            workspaceRef = ref
            image = picture
            failed = false
        }
    }

    private static func downloadRemoteImage(_ remote: URL) async throws -> URL {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 45
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        let delegate = PublicImageRedirectDelegate()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: remote)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        if http.expectedContentLength > Int64(maxRemoteBytes) {
            throw URLError(.dataLengthExceedsMaximum)
        }

        let rawExt = remote.pathExtension.lowercased()
        let safeExt = rawExt.allSatisfy({ $0.isLetter || $0.isNumber }) && rawExt.count <= 8 ? rawExt : "img"
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("clio-pic-\(UUID().uuidString).\(safeExt)")
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let handle = try FileHandle(forWritingTo: dest)
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        var total = 0
        do {
            for try await byte in bytes {
                try Task.checkCancellation()
                total += 1
                if total > maxRemoteBytes {
                    throw URLError(.dataLengthExceedsMaximum)
                }
                buffer.append(byte)
                if buffer.count >= 64 * 1024 {
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
            }
            try handle.close()
            return dest
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: dest)
            throw error
        }
    }
}


private final class CachedFileRef {
    let ref: WorkspaceFileRef
    init(_ ref: WorkspaceFileRef) { self.ref = ref }
}

@MainActor
private enum FileCardCache {
    private static let cache: NSCache<NSString, CachedFileRef> = {
        let cache = NSCache<NSString, CachedFileRef>()
        cache.countLimit = 128
        return cache
    }()

    static func get(_ key: String) -> WorkspaceFileRef? {
        cache.object(forKey: key as NSString)?.ref
    }

    static func set(_ ref: WorkspaceFileRef?, for key: String) {
        if let ref {
            cache.setObject(CachedFileRef(ref), forKey: key as NSString)
        } else {
            cache.removeObject(forKey: key as NSString)
        }
    }
}

/// A file the companion made, handed over in the reply: a line that is only a link into 书案 (`[周报.pdf](书案/周报.pdf)`)
/// becomes a card. Tap it to read it in the system viewer, which can also share it or save it to 文件.
struct FileCard: View {
    let label: String
    let path: String
    @State private var resolved: WorkspaceFileRef?
    @State private var checked = false
    @State private var open = false
    @State private var interaction = false

    @MainActor
    init(label: String, path: String) {
        self.label = label
        self.path = path
        let clean = path.removingPercentEncoding ?? path
        if let hit = FileCardCache.get(clean) {
            _resolved = State(initialValue: hit)
            _checked = State(initialValue: true)
        } else {
            _resolved = State(initialValue: nil)
            _checked = State(initialValue: false)
        }
    }

    private var document: InteractiveDocument? {
        guard let resolved, InteractiveDocument.supports(resolved.url) else { return nil }
        return InteractiveDocument(url: resolved.url, root: resolved.rootURL, mount: resolved.mount)
    }

    var body: some View {
        Button {
            guard resolved != nil else { return }
            Haptics.light()
            if document == nil { open = true } else { interaction = true }
        } label: {
            VStack(alignment: .leading, spacing: Ink.Space.s) {
                if let document { InteractivePreviewThumbnail(document: document) }
                HStack(spacing: Ink.Space.m) {
                    IconBadge(symbol: Self.symbol(for: path), tint: resolved == nil ? Ink.Tile.off : Ink.Tile.accent, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label.isEmpty ? (path as NSString).lastPathComponent : label)
                            .font(.system(size: Ink.Size.sub, weight: .semibold))
                            .foregroundStyle(Ink.ink)
                            .lineLimit(1)
                        Text(subtitleText)
                            .font(.system(size: Ink.Size.small))
                            .foregroundStyle(Ink.inkSoft)
                            .lineLimit(1)
                    }
                    Spacer(minLength: Ink.Space.s)
                    if resolved != nil { Kit.chevron }
                }
            }
            .padding(Ink.Space.m)
            .inkBlock()
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(haptic: false))
        .accessibilityLabel("打开 \(label)")
        .task(id: path) {
            let clean = path.removingPercentEncoding ?? path
            let found = await Task.detached(priority: .utility) { WorkspaceFileRef.resolve(clean) }.value
            guard !Task.isCancelled else { return }
            FileCardCache.set(found, for: clean)
            if resolved != found { resolved = found }
            if !checked { checked = true }
        }
        .sheet(isPresented: $open) {
            if let resolved {
                NavigationStack { StudyFile(url: resolved.url, mount: resolved.mount, showsDone: true) }
            }
        }
        .fullScreenCover(isPresented: $interaction) {
            if let document { InteractivePreviewPage(document: document) }
        }
    }

    private var subtitleText: String {
        if document != nil { return L.t("interactivePreview.open") }
        if let resolved { return Self.detail(resolved) }
        return checked ? "找不到这个文件了" : L.t("loading.generic")
    }

    /// The links in a paragraph made only of links to files (one per line), or nil when it is ordinary text.
    static func links(in text: String) -> [(label: String, path: String)]? {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty, let pattern = try? NSRegularExpression(pattern: #"^\[([^\]]+)\]\(\s*<?([^)>]+?)>?\s*\)$"#) else { return nil }
        var found: [(label: String, path: String)] = []
        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = pattern.firstMatch(in: line, range: range),
                  let label = Range(match.range(at: 1), in: line), let target = Range(match.range(at: 2), in: line) else { return nil }
            let path = String(line[target])
            // Only files: a web link stays a link in the text.
            let lower = path.lowercased()
            if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("mailto:") { return nil }
            found.append((String(line[label]), path))
        }
        return found
    }

    static func symbol(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "pdf": "doc.richtext"
        case "doc", "docx", "pages", "rtf": "doc.text"
        case "xls", "xlsx", "csv", "numbers": "tablecells"
        case "ppt", "pptx", "key": "rectangle.on.rectangle"
        case "png", "jpg", "jpeg", "gif", "heic", "webp": "photo"
        case "md", "txt": "text.alignleft"
        case "zip": "doc.zipper"
        case "mp3", "m4a", "wav": "waveform"
        case "mp4", "mov": "film"
        default: "chevron.left.forwardslash.chevron.right"
        }
    }

    static func detail(_ ref: WorkspaceFileRef) -> String {
        let where_ = Words.t("书案/") + ref.relativePath
        return ByteCountFormatter.string(fromByteCount: Int64(ref.byteSize), countStyle: .file) + " · " + where_
    }
}

/// Typing in the composer redraws the page; a reply whose words did not change is not laid out again.
extension ProseView: Equatable {
    static func == (a: ProseView, b: ProseView) -> Bool { a.text == b.text && a.streaming == b.streaming }
}

// MARK: - Selectable replies

/// A finished reply you can select in freely, as in a reading app: the words (paragraphs, headings, lists, quotes)
/// are one native text, so a drag can run from one paragraph into the next. Code, tables, pictures, files and formulas
/// stand between them as their own blocks (code keeps its copy button).
struct SelectableProse: View, Equatable {
    let text: String

    var body: some View {
        ReplyProseLayout(text: text, blocks: ParsedCache.blocks(text))
    }
}

/// Both stages of a reply use the same layout. Only the growing tail needs live formatting.
private struct ReplyProseLayout: View {
    @AppStorage("look.face") private var face = "serif"
    @AppStorage("look.code") private var code = "maple"
    @AppStorage("look.size") private var size = 17.0
    @AppStorage("look.lineHeight") private var leading = Pref.defaultLineHeight
    @AppStorage("look.fade") private var fade = true
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let text: String
    let blocks: [Prose.Block]
    var streaming = false
    var allowFade = true
    var quoted = false
    var cacheScope = ""

    enum Part {
        case words([Prose.Block])
        case block(Prose.Block)
    }

    /// Runs of words, and the blocks that stand on their own.
    static func parts(_ blocks: [Prose.Block]) -> [Part] {
        var out: [Part] = []
        var run: [Prose.Block] = []
        func flush() {
            if !run.isEmpty { out.append(.words(run)) }
            run = []
        }
        for block in blocks {
            if ProseWords.isWords(block) {
                run.append(block)
            } else {
                flush()
                out.append(.block(block))
            }
        }
        flush()
        return out
    }

    var body: some View {
        let _ = (face, code, size, leading)
        let parts = Self.parts(blocks)
        let format = "\(cacheScope)\(quoted ? "q-" : "")\(face)-\(code)-\(size)-\(leading)-\(scheme == .dark)-\(Theme.shared.key)-\(Theme.shared.white)-\(Theme.shared.oled)-\(FontShelf.shared.generation)-\(UIScale.shared.value)"
        VStack(alignment: .leading, spacing: quoted ? Ink.Space.s : Ink.paragraphGap) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                let live = streaming && allowFade && index == parts.count - 1
                switch part {
                case .words(let blocks):
                    ProseText(blocks: blocks, text: text, part: index, format: format,
                              streaming: streaming, fadeTail: live && fade && !reduceMotion, quoted: quoted)
                case .block(let block):
                    if case .quote(let inner) = block {
                        QuoteCard {
                            AnyView(
                                ReplyProseLayout(
                                    text: text,
                                    blocks: inner,
                                    streaming: streaming,
                                    allowFade: live,
                                    quoted: true,
                                    cacheScope: "\(cacheScope)q\(index)."
                                )
                            )
                        }
                    } else {
                        BlockView(block: block, fading: false, live: unfinished(block, live: live))
                    }
                }
            }
        }
        .id(format)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func unfinished(_ block: Prose.Block, live: Bool) -> Bool {
        guard live else { return false }
        if case .code(_, _, let closed) = block { return !closed }
        return true
    }
}

/// The words of a reply as one attributed text, set like `BlockView` sets them.
enum ProseWords {
    static func isWords(_ block: Prose.Block) -> Bool {
        switch block {
        case .heading, .list: return true
        case .paragraph(let text): return FileCard.links(in: text) == nil && !text.contains("![")
        default: return false
        }
    }

    static func make(_ block: Prose.Block, first: Bool, quoted: Bool = false) -> NSAttributedString {
        set(block, quoteDepth: 0, first: first, quoted: quoted)
    }

    private static func style(spacing: CGFloat = Ink.paragraphGap, before: CGFloat = 0, indent: CGFloat = 0, hanging: CGFloat = 0, tight: Bool = false) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = tight ? Ink.leading * 0.5 : Ink.leading
        style.paragraphSpacing = spacing
        style.paragraphSpacingBefore = before
        style.firstLineHeadIndent = indent
        style.headIndent = indent + hanging
        if hanging > 0 { style.tabStops = [NSTextTab(textAlignment: .left, location: indent + hanging)] }
        return style
    }

    private static func set(_ block: Prose.Block, quoteDepth: Int, first: Bool, quoted: Bool = false) -> NSAttributedString {
        let quote = CGFloat(quoteDepth) * Pref.size * 1.1
        let ink = (quoted || quoteDepth > 0) ? UIColor(Ink.inkSoft) : UIColor(Ink.ink)
        switch block {
        case .heading(let level, let text):
            let before: CGFloat = first ? 0 : ProseMetrics.headingTop(level: level)
            return inline(text, size: ProseMetrics.headingSize(level: level), bold: true, ink: ink,
                          paragraph: style(spacing: ProseMetrics.headingBottom, before: before, indent: quote, tight: true))
        case .paragraph(let text):
            return inline(text, size: Pref.size, bold: false, ink: ink, paragraph: style(indent: quote))
        case .list(let items):
            let out = NSMutableAttributedString()
            let base = CGFloat(Pref.size)
            for (index, item) in items.enumerated() {
                if index > 0 { out.append(NSAttributedString(string: "\n")) }
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
                let indent = quote + CGFloat(item.depth) * base * 1.25
                let hang = item.number != nil ? base * 1.75 : base * 1.25
                let last = index == items.count - 1
                let paragraph = style(spacing: last ? Ink.paragraphGap : ProseMetrics.listSpacing, indent: indent, hanging: hang)
                out.append(NSAttributedString(string: marker + "\t", attributes: [
                    .font: Ink.uiFace(markerSize), .foregroundColor: markerColor, .paragraphStyle: paragraph,
                ]))
                out.append(inline(item.text, size: base, bold: false, ink: ink, paragraph: paragraph))
            }
            return out
        case .quote(let inner):
            let out = NSMutableAttributedString()
            for (index, block) in inner.enumerated() {
                if index > 0 { out.append(NSAttributedString(string: "\n")) }
                out.append(set(block, quoteDepth: quoteDepth + 1, first: first && index == 0))
            }
            return out
        default:
            return NSAttributedString()
        }
    }

    /// One block's words with their marks: bold, italics, code, links, strikethrough.
    private static func inline(_ text: String, size: CGFloat, bold: Bool, ink: UIColor, paragraph: NSParagraphStyle) -> NSAttributedString {
        let parsed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            var font = Ink.uiFace(size, bold: bold || intent.contains(.stronglyEmphasized))
            if intent.contains(.emphasized), let slanted = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.traitItalic)) {
                font = UIFont(descriptor: slanted, size: size)
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink, .paragraphStyle: paragraph]
            // 文楷 has one weight for reading and bold: bold words are drawn with a thin outline so they still stand out.
            if Pref.face == .wenkai, bold || intent.contains(.stronglyEmphasized) {
                attributes[.strokeWidth] = -3.0
                attributes[.strokeColor] = ink
            }
            if intent.contains(.code) {
                attributes[.font] = Ink.uiMono(max(12, size - 2))
                attributes[.foregroundColor] = UIColor(Ink.accent)
                attributes[.clioInlineCode] = true
            }
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link {
                attributes[.link] = link
                attributes[.foregroundColor] = UIColor(Ink.accent)
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            out.append(NSAttributedString(string: piece, attributes: attributes))
        }
        return out
    }
}

private struct ChatSelectionKey: EnvironmentKey {
    static let defaultValue: (@MainActor (UUID, Bool) -> Void)? = nil
}

private struct ChatQuoteSelectionKey: EnvironmentKey {
    static let defaultValue: (@MainActor (String) -> Void)? = nil
}

private struct ChatSpeakSelectionKey: EnvironmentKey {
    static let defaultValue: (@MainActor (String) -> Void)? = nil
}

extension EnvironmentValues {
    var chatSelectionChanged: (@MainActor (UUID, Bool) -> Void)? {
        get { self[ChatSelectionKey.self] }
        set { self[ChatSelectionKey.self] = newValue }
    }

    var chatQuoteSelection: (@MainActor (String) -> Void)? {
        get { self[ChatQuoteSelectionKey.self] }
        set { self[ChatQuoteSelectionKey.self] = newValue }
    }

    var chatSpeakSelection: (@MainActor (String) -> Void)? {
        get { self[ChatSpeakSelectionKey.self] }
        set { self[ChatSpeakSelectionKey.self] = newValue }
    }
}

private extension NSAttributedString.Key {
    static let clioInlineCode = Self("ClioInlineCode")
}

private func mixFastStringHash(_ text: String, into hasher: inout Hasher) {
    let utf8 = text.utf8
    hasher.combine(utf8.count)
    for byte in utf8.prefix(64) { hasher.combine(byte) }
    if utf8.count > 64 {
        for byte in utf8.suffix(64) { hasher.combine(byte) }
    }
}

private final class ProsePartKey: NSObject {
    let format: String
    let part: Int
    let text: String
    private let cachedHash: Int

    init(format: String, part: Int, text: String) {
        self.format = format
        self.part = part
        self.text = text
        var hasher = Hasher()
        hasher.combine(format)
        hasher.combine(part)
        mixFastStringHash(text, into: &hasher)
        self.cachedHash = hasher.finalize()
    }

    override var hash: Int { cachedHash }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? ProsePartKey else { return false }
        return cachedHash == other.cachedHash
            && part == other.part
            && text.utf8.count == other.text.utf8.count
            && format == other.format
            && text == other.text
    }
}

private final class ProseHeightKey: NSObject {
    let format: String
    let part: Int
    let widthKey: Int
    let text: String
    private let cachedHash: Int

    init(format: String, part: Int, widthKey: Int, text: String) {
        self.format = format
        self.part = part
        self.widthKey = widthKey
        self.text = text
        var hasher = Hasher()
        hasher.combine(format)
        hasher.combine(part)
        hasher.combine(widthKey)
        mixFastStringHash(text, into: &hasher)
        self.cachedHash = hasher.finalize()
    }

    override var hash: Int { cachedHash }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? ProseHeightKey else { return false }
        return cachedHash == other.cachedHash
            && part == other.part
            && widthKey == other.widthKey
            && text.utf8.count == other.text.utf8.count
            && format == other.format
            && text == other.text
    }
}

@MainActor
private final class ProseRenderedWords {
    let attributed: NSAttributedString
    let codeRanges: [NSRange]
    var pathsByWidth: [Int: CGPath] = [:]

    init(attributed: NSAttributedString, codeRanges: [NSRange]) {
        self.attributed = attributed
        self.codeRanges = codeRanges
    }

    func storePath(_ path: CGPath, for widthKey: Int) {
        if pathsByWidth.count >= 4 { pathsByWidth.removeAll(keepingCapacity: true) }
        pathsByWidth[widthKey] = path
    }
}

@MainActor
private enum ProseLayoutCache {
    private static let wordsCache: NSCache<ProsePartKey, ProseRenderedWords> = {
        let cache = NSCache<ProsePartKey, ProseRenderedWords>()
        cache.countLimit = 300
        return cache
    }()

    private static let heightsCache: NSCache<ProseHeightKey, NSNumber> = {
        let cache = NSCache<ProseHeightKey, NSNumber>()
        cache.countLimit = 512
        return cache
    }()

    static func words(format: String, part: Int, text: String) -> ProseRenderedWords? {
        wordsCache.object(forKey: ProsePartKey(format: format, part: part, text: text))
    }

    static func storeWords(_ rendered: ProseRenderedWords, format: String, part: Int, text: String) {
        wordsCache.setObject(rendered, forKey: ProsePartKey(format: format, part: part, text: text))
    }

    static func height(format: String, part: Int, widthKey: Int, text: String) -> CGFloat? {
        heightsCache.object(forKey: ProseHeightKey(format: format, part: part, widthKey: widthKey, text: text))
            .map { CGFloat($0.doubleValue) }
    }

    static func storeHeight(_ height: CGFloat, format: String, part: Int, widthKey: Int, text: String) {
        heightsCache.setObject(NSNumber(value: Double(height)), forKey: ProseHeightKey(format: format, part: part, widthKey: widthKey, text: text))
    }

    static func extractCodeRanges(in words: NSAttributedString) -> [NSRange] {
        var ranges: [NSRange] = []
        words.enumerateAttribute(.clioInlineCode, in: NSRange(location: 0, length: words.length)) { value, range, _ in
            if value != nil { ranges.append(range) }
        }
        return ranges
    }
}

/// Draw code backgrounds from the same native text ranges that selection uses.
private final class InlineCodeTextView: UITextView {
    private var codeRanges: [NSRange] = []
    private var pathCache: ProseRenderedWords?
    private var paintedWidth: CGFloat?
    private let codeBackground = CAShapeLayer()

    func replaceWords(with words: NSAttributedString, codeRanges: [NSRange], pathCache: ProseRenderedWords?) {
        attributedText = words
        self.codeRanges = codeRanges
        self.pathCache = pathCache
        if codeRanges.isEmpty { codeBackground.removeFromSuperlayer() }
        paintedWidth = nil
        if !codeRanges.isEmpty { setNeedsLayout() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !codeRanges.isEmpty, bounds.width > 0, paintedWidth != bounds.width else { return }
        let widthKey = Int((bounds.width * 2).rounded())
        let resolvedPath: CGPath
        if let cached = pathCache?.pathsByWidth[widthKey] {
            resolvedPath = cached
        } else {
            let path = CGMutablePath()
            for range in codeRanges {
                guard let start = position(from: beginningOfDocument, offset: range.location),
                      let end = position(from: start, offset: range.length),
                      let textRange = textRange(from: start, to: end) else { continue }
                for fragment in selectionRects(for: textRange) {
                    guard fragment.rect.width > 0, fragment.rect.height > 0 else { continue }
                    let rect = fragment.rect.insetBy(dx: -2.5, dy: fragment.rect.height * 0.06)
                    let radius = min(ProseMetrics.inlineCodeCorner, rect.height * 0.3)
                    path.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
                }
            }
            // The new width may arrive before TextKit has produced selection rectangles.
            guard !path.isEmpty else { return }
            pathCache?.storePath(path, for: widthKey)
            resolvedPath = path
        }
        paintedWidth = bounds.width
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        codeBackground.path = resolvedPath
        codeBackground.fillColor = UIColor(Ink.mine).resolvedColor(with: traitCollection).withAlphaComponent(0.85).cgColor
        if codeBackground.superlayer == nil { layer.insertSublayer(codeBackground, at: 0) }
        CATransaction.commit()
    }
}

/// Native text that can be selected across lines and paragraphs: long-press a word, drag the handles, 拷贝.
private struct ProseText: UIViewRepresentable {
    let blocks: [Prose.Block]
    let text: String
    let part: Int
    let format: String
    let streaming: Bool
    let fadeTail: Bool
    var quoted = false

    @Environment(\.openURL) private var openURL
    @Environment(\.chatSelectionChanged) private var selectionChanged
    @Environment(\.chatQuoteSelection) private var quoteSelection
    @Environment(\.chatSpeakSelection) private var speakSelection

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> InlineCodeTextView {
        let view = InlineCodeTextView(usingTextLayoutManager: true)
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        // Our own link colours stay.
        view.linkTextAttributes = [:]
        view.delegate = context.coordinator
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: InlineCodeTextView, context: Context) {
        context.coordinator.open = openURL
        context.coordinator.selectionChanged = selectionChanged
        context.coordinator.quoteSelection = quoteSelection
        context.coordinator.speakSelection = speakSelection
        if let update = context.coordinator.words(
            for: blocks,
            text: text,
            part: part,
            format: format,
            streaming: streaming,
            fade: fadeTail,
            quoted: quoted
        ) {
            let selection = view.selectedRange
            let keepsSelection = selection.length > 0 && update.attributed.string.hasPrefix(view.attributedText?.string ?? "")
            view.replaceWords(with: update.attributed, codeRanges: update.codeRanges, pathCache: update.cache)
            if keepsSelection { view.selectedRange = selection }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: InlineCodeTextView, context: Context) -> CGSize? {
        guard let width = proposal.width ?? uiView.superview?.bounds.width ?? uiView.window?.bounds.width,
              width > 0 else { return nil }
        if streaming {
            let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            return CGSize(width: width, height: ceil(fitted.height))
        }
        let widthKey = Int((width * 2).rounded())
        if let height = ProseLayoutCache.height(format: format, part: part, widthKey: widthKey, text: text) {
            return CGSize(width: width, height: height)
        }
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let height = ceil(fitted.height)
        ProseLayoutCache.storeHeight(height, format: format, part: part, widthKey: widthKey, text: text)
        return CGSize(width: width, height: height)
    }

    static func dismantleUIView(_ view: InlineCodeTextView, coordinator: Coordinator) {
        coordinator.publishSelection(false)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var open: OpenURLAction?
        var selectionChanged: (@MainActor (UUID, Bool) -> Void)?
        var quoteSelection: (@MainActor (String) -> Void)?
        var speakSelection: (@MainActor (String) -> Void)?
        private let id = UUID()
        private var selected = false

        private var settledKey: (format: String, part: Int, text: String)?
        private var blocks: [Prose.Block] = []
        private var spans: [NSAttributedString] = []
        private var fading = false
        private var isQuoted = false

        @MainActor
        func words(
            for next: [Prose.Block],
            text: String,
            part: Int,
            format: String,
            streaming: Bool,
            fade: Bool,
            quoted: Bool
        ) -> (attributed: NSAttributedString, codeRanges: [NSRange], cache: ProseRenderedWords?)? {
            if !streaming && !fade {
                if let settled = settledKey,
                   settled.part == part,
                   settled.format == format,
                   settled.text == text {
                    return nil
                }
                if let cached = ProseLayoutCache.words(format: format, part: part, text: text) {
                    settledKey = (format: format, part: part, text: text)
                    blocks = []
                    spans = []
                    fading = false
                    isQuoted = quoted
                    return (attributed: cached.attributed, codeRanges: cached.codeRanges, cache: cached)
                }
                let built = NSMutableAttributedString()
                for (index, block) in next.enumerated() {
                    if index > 0 { built.append(NSAttributedString(string: "\n")) }
                    built.append(ProseWords.make(block, first: index == 0, quoted: quoted))
                }
                let ranges = ProseLayoutCache.extractCodeRanges(in: built)
                let rendered = ProseRenderedWords(attributed: built, codeRanges: ranges)
                ProseLayoutCache.storeWords(rendered, format: format, part: part, text: text)
                settledKey = (format: format, part: part, text: text)
                blocks = []
                spans = []
                fading = false
                isQuoted = quoted
                return (attributed: rendered.attributed, codeRanges: rendered.codeRanges, cache: rendered)
            }

            settledKey = nil
            guard next != blocks || fade != fading || quoted != isQuoted else { return nil }
            let shared: Int
            if quoted == isQuoted {
                shared = zip(blocks, next).prefix { $0.0 == $0.1 }.count
            } else {
                shared = 0
            }
            spans.removeSubrange(shared...)
            for index in next.indices.dropFirst(shared) {
                spans.append(ProseWords.make(next[index], first: index == 0, quoted: quoted))
            }
            blocks = next
            fading = fade
            isQuoted = quoted

            let words = NSMutableAttributedString()
            for (index, span) in spans.enumerated() {
                if index > 0 { words.append(NSAttributedString(string: "\n")) }
                words.append(span)
            }
            if fade {
                let raw = words.string
                let tail = raw.suffix(12)
                for (offset, index) in tail.indices.enumerated() {
                    let range = NSRange(index..<raw.index(after: index), in: raw)
                    guard let color = words.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? UIColor else { continue }
                    words.addAttribute(.foregroundColor, value: color.withAlphaComponent(Double(12 - offset) / 13), range: range)
                }
            }
            let ranges = ProseLayoutCache.extractCodeRanges(in: words)
            return (attributed: words, codeRanges: ranges, cache: nil)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            publishSelection(textView.selectedRange.length > 0)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            publishSelection(false)
        }

        func publishSelection(_ active: Bool) {
            guard active != selected else { return }
            selected = active
            let callback = selectionChanged
            let id = self.id
            DispatchQueue.main.async { callback?(id, active) }
        }

        /// Adds 「引用追问」 and 「朗读」 right inside the native iOS text-selection menu.
        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard range.length > 0, let full = textView.text as NSString?,
                  range.location >= 0, range.location + range.length <= full.length else {
                return UIMenu(children: suggestedActions)
            }
            let picked = full.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !picked.isEmpty else { return UIMenu(children: suggestedActions) }

            var custom: [UIMenuElement] = []
            if let onQuote = quoteSelection {
                custom.append(UIAction(title: "引用追问", image: UIImage(systemName: "text.quote")) { [weak self, weak textView] _ in
                    textView?.selectedRange = NSRange(location: 0, length: 0)
                    self?.publishSelection(false)
                    DispatchQueue.main.async { onQuote(picked) }
                })
            }
            if let onSpeak = speakSelection {
                custom.append(UIAction(title: "朗读", image: UIImage(systemName: "speaker.wave.2")) { [weak self, weak textView] _ in
                    textView?.selectedRange = NSRange(location: 0, length: 0)
                    self?.publishSelection(false)
                    DispatchQueue.main.async { onSpeak(picked) }
                })
            }
            guard !custom.isEmpty else { return UIMenu(children: suggestedActions) }
            return UIMenu(children: custom + suggestedActions)
        }

        /// A tapped link goes where the rest of Clio sends links (the in-app browser, 书案 files …).
        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
            if case .link(let url) = textItem.content, let open {
                return UIAction { _ in open(url) }
            }
            return defaultAction
        }
    }
}
