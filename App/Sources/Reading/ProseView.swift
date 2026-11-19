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
    @AppStorage("look.size") private var size = 17.0
    @AppStorage("look.leading") private var leading = 10.0
    @AppStorage("look.fade") private var fade = true
    var text: String
    /// True while more is coming: the tail of the last block fades.
    var streaming = false

    init(text: String, streaming: Bool = false) {
        self.text = text
        self.streaming = streaming
    }

    var body: some View {
        let _ = (face, size, leading)
        let blocks = streaming ? Prose.parse(Prose.mend(text)) : ParsedCache.blocks(text)
        VStack(alignment: .leading, spacing: Ink.Space.l) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                BlockView(block: block, fading: fade && streaming && index == blocks.count - 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}

private struct BlockView: View {
    let block: Prose.Block
    let fading: Bool

    var body: some View {
        switch block {
        case .heading(let level, let text):
            // Headings in the reading face, a step or two larger: never a different family from the text under them.
            Inline(text: text, font: level <= 1 ? Ink.body(Pref.size + 4, bold: true) : (level == 2 ? Ink.body(Pref.size + 2, bold: true) : Ink.readingBold), fading: fading)
                .padding(.top, level <= 2 ? Ink.Space.s : 0)
        case .paragraph(let text):
            Inline(text: text, font: Ink.reading, fading: fading)
        case .list(let items):
            VStack(alignment: .leading, spacing: Ink.Space.m) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: Ink.Space.s) {
                        marker(item)
                        Inline(text: item.text, font: Ink.reading, fading: fading && index == items.count - 1)
                    }
                    .padding(.leading, CGFloat(item.depth) * 20)
                }
            }
        case .quote(let blocks):
            HStack(alignment: .top, spacing: Ink.Space.m) {
                RoundedRectangle(cornerRadius: 1.5).fill(Ink.rule).frame(width: 3)
                VStack(alignment: .leading, spacing: Ink.Space.m) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { index, inner in
                        BlockView(block: inner, fading: fading && index == blocks.count - 1)
                    }
                }
                .foregroundStyle(Ink.inkSoft)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let language, let text, _):
            CodeBlock(language: language, text: text)
        case .table(let table):
            TableBlock(table: table)
        case .math(let text):
            FormulaBlock(latex: text, streaming: fading)
        case .rule:
            Rectangle().fill(Ink.rule).frame(height: 1).padding(.vertical, Ink.Space.s)
        }
    }

    @ViewBuilder
    private func marker(_ item: Prose.Item) -> some View {
        if let checked = item.checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(.system(size: 15))
                .foregroundStyle(checked ? Ink.accent : Ink.inkFaint)
        } else if let number = item.number {
            Text("\(number).")
                .font(Ink.reading.monospacedDigit())
                .foregroundStyle(Ink.inkSoft)
        } else {
            Text(item.depth == 0 ? "•" : "◦")
                .font(Ink.reading)
                .foregroundStyle(Ink.inkSoft)
        }
    }
}

/// Words with inline marks: bold, italics, code, links, strikethrough.
private struct Inline: View {
    let text: String
    let font: Font
    let fading: Bool
    @Environment(\.noteInk) private var noteInk

    private var styled: AttributedString {
        var out = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        for run in out.runs {
            guard let intent = run.inlinePresentationIntent else { continue }
            if intent.contains(.code) {
                out[run.range].font = Ink.code
                out[run.range].backgroundColor = Ink.accentWash
            }
            if intent.contains(.stronglyEmphasized), noteInk == nil {
                out[run.range].foregroundColor = Ink.ink
            }
        }
        for run in out.runs where run.link != nil {
            out[run.range].foregroundColor = Ink.accent
            out[run.range].underlineStyle = .single
        }
        return out
    }

    var body: some View {
        Text(styled)
            .font(font)
            .lineSpacing(Ink.leading)
            .foregroundStyle(noteInk ?? Ink.ink)
            .textRenderer(TailFade(on: fading))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The last glyphs of text still arriving fade from clear to full: as the text grows, each glyph fades in.
struct TailFade: TextRenderer {
    var on: Bool
    var tail = 12

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
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
    @State private var copied = false
    @State private var unfolded = false

    private var lineCount: Int { text.split(separator: "\n", omittingEmptySubsequences: false).count }
    /// Long code shows its first lines; the rest opens on a tap.
    private var folds: Bool { lineCount > 20 }
    private var shown: String {
        guard folds, !unfolded else { return text }
        return text.split(separator: "\n", omittingEmptySubsequences: false).prefix(12).joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text((language.isEmpty ? "代码" : language) + " · \(lineCount) 行").font(Ink.footnote).foregroundStyle(Ink.inkSoft)
                Spacer()
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
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(copied ? Ink.ok : Ink.inkSoft)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle(haptic: false))
                .accessibilityLabel("复制代码")
            }
            .padding(.leading, Ink.Space.l)
            .padding(.trailing, Ink.Space.xs)
            .frame(height: 34)
            Rectangle().fill(Ink.rule).frame(height: 1)
            ScrollView(.horizontal) {
                Text(Highlight.code(shown, language: language))
                    .font(Ink.code)
                    .lineSpacing(4)
                    .padding(Ink.Space.l)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .scrollIndicators(.hidden)
            if folds {
                Button {
                    Haptics.tick(0.4)
                    withAnimation(Ink.Motion.settle) { unfolded.toggle() }
                } label: {
                    Label(unfolded ? "收起" : "展开全部 \(lineCount) 行", systemImage: unfolded ? "chevron.up" : "chevron.down")
                        .font(Ink.footnote)
                        .foregroundStyle(Ink.accent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(alignment: .top) { Rectangle().fill(Ink.rule).frame(height: 1) }
            }
        }
        .paperCard()
    }
}

/// A table that scrolls sideways when it is wider than the page.
/// Each column gets a width measured from its words (up to 260 points, then they wrap), and each row is as tall
/// as its tallest cell, so a cell that wraps onto several lines pushes the line under it down instead of
/// running over it.
private struct TableBlock: View {
    let table: Prose.Table

    private static let widest: CGFloat = 260
    private static let gap: CGFloat = 20

    private var widths: [CGFloat] {
        let columns = max(table.header.count, table.rows.map(\.count).max() ?? 0)
        let head = UIFont.systemFont(ofSize: 14, weight: .semibold)
        let body = UIFont.systemFont(ofSize: 14)
        return (0..<columns).map { column in
            var natural = Self.measure(column < table.header.count ? table.header[column] : "", font: head)
            for row in table.rows where column < row.count {
                natural = max(natural, Self.measure(row[column], font: body))
            }
            return min(Self.widest, max(28, ceil(natural) + 4))
        }
    }

    /// One line's width, without the Markdown marks that are not drawn.
    private static func measure(_ cell: String, font: UIFont) -> CGFloat {
        let plain = cell.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "~~", with: "")
        return (plain as NSString).size(withAttributes: [.font: font]).width
    }

    var body: some View {
        let widths = self.widths
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                row(table.header, head: true, widths: widths)
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, cells in
                    Rectangle().fill(Ink.rule).frame(height: 1)
                    row(cells, head: false, widths: widths)
                }
            }
            .padding(.horizontal, Ink.Space.l)
            .fixedSize(horizontal: true, vertical: false)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .paperCard()
    }

    private func row(_ cells: [String], head: Bool, widths: [CGFloat]) -> some View {
        HStack(alignment: .top, spacing: Self.gap) {
            ForEach(Array(widths.enumerated()), id: \.offset) { column, width in
                cellText(column < cells.count ? cells[column] : "", head: head, column: column)
                    .frame(width: width, alignment: frameAlign(column))
            }
        }
        .padding(.vertical, Ink.Space.m)
    }

    private func frameAlign(_ column: Int) -> Alignment {
        let align = column < table.aligns.count ? table.aligns[column] : .leading
        return align == .center ? .top : (align == .trailing ? .topTrailing : .topLeading)
    }

    private func cellText(_ cell: String, head: Bool, column: Int) -> some View {
        let align = column < table.aligns.count ? table.aligns[column] : .leading
        let styled = (try? AttributedString(markdown: cell, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(cell)
        return Text(styled)
            .font(head ? .system(size: 14, weight: .semibold) : Ink.secondary)
            .foregroundStyle(head ? Ink.ink : Ink.inkSoft)
            .multilineTextAlignment(align == .center ? .center : (align == .trailing ? .trailing : .leading))
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Keyword-level coloring, enough to read code at a glance.
enum Highlight {
    private static let keywords: Set<String> = [
        "func", "let", "var", "if", "else", "for", "while", "return", "import", "struct", "class", "enum", "case", "switch",
        "def", "from", "as", "in", "not", "and", "or", "is", "None", "True", "False", "lambda", "with", "try", "except",
        "const", "function", "async", "await", "new", "this", "self", "true", "false", "null", "nil", "export", "default",
        "public", "private", "static", "void", "int", "string", "bool", "fn", "pub", "mut", "impl", "use", "match",
    ]

    static func code(_ text: String, language: String) -> AttributedString {
        var out = AttributedString()
        var index = text.startIndex
        let hashComments = ["python", "py", "bash", "sh", "shell", "zsh", "ruby", "rb", "yaml", "yml", "toml"].contains(language.lowercased())
        func append(_ piece: Substring, _ color: Color) {
            var part = AttributedString(String(piece))
            part.foregroundColor = color
            out += part
        }
        while index < text.endIndex {
            let rest = text[index...]
            let character = text[index]
            if rest.hasPrefix("//") || (hashComments && character == "#") {
                let end = rest.firstIndex(of: "\n") ?? text.endIndex
                append(text[index..<end], Ink.inkFaint)
                index = end
            } else if character == "\"" || character == "'" || character == "`" {
                var end = text.index(after: index)
                while end < text.endIndex, text[end] != character, text[end] != "\n" {
                    if text[end] == "\\" { end = text.index(after: end) }
                    if end < text.endIndex { end = text.index(after: end) }
                }
                if end < text.endIndex, text[end] == character { end = text.index(after: end) }
                append(text[index..<end], Ink.ok)
                index = end
            } else if character.isLetter || character == "_" {
                let end = rest.firstIndex { !($0.isLetter || $0.isNumber || $0 == "_") } ?? text.endIndex
                let word = text[index..<end]
                append(word, keywords.contains(String(word)) ? Ink.accent : Ink.ink)
                index = end
            } else if character.isNumber {
                let end = rest.firstIndex { !($0.isNumber || $0 == ".") } ?? text.endIndex
                append(text[index..<end], Ink.warn)
                index = end
            } else {
                append(text[index...index], Ink.ink)
                index = text.index(after: index)
            }
        }
        return out
    }
}
