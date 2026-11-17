import Prose
import SwiftUI

/// A companion's words, set as a page: paragraphs, lists, tables, code and quotes.
/// While a reply is still arriving, only its last block changes, and that block's newest glyphs fade in.
struct ProseView: View {
    var text: String
    /// True while more is coming: the tail of the last block fades.
    var streaming = false

    var body: some View {
        let blocks = Prose.parse(text)
        VStack(alignment: .leading, spacing: Ink.Space.l) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                BlockView(block: block, fading: streaming && index == blocks.count - 1)
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
            Inline(text: text, font: level <= 1 ? Ink.title : (level == 2 ? Ink.serif(19, bold: true, relativeTo: .title3) : Ink.readingBold), fading: fading)
                .padding(.top, level <= 2 ? Ink.Space.s : 0)
        case .paragraph(let text):
            Inline(text: text, font: Ink.reading, fading: fading)
        case .list(let items):
            VStack(alignment: .leading, spacing: Ink.Space.s) {
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
            // Typeset formulas come in stage 7; until then the source, set apart.
            Text(text)
                .font(Ink.code)
                .foregroundStyle(Ink.ink)
                .padding(Ink.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Ink.accentWash.opacity(0.5), in: .rect(cornerRadius: Ink.Radius.small))
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

    private var styled: AttributedString {
        var out = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        for run in out.runs {
            guard let intent = run.inlinePresentationIntent else { continue }
            if intent.contains(.code) {
                out[run.range].font = Ink.code
                out[run.range].backgroundColor = Ink.accentWash
            }
            if intent.contains(.stronglyEmphasized) {
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
            .foregroundStyle(Ink.ink)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "代码" : language).font(Ink.footnote).foregroundStyle(Ink.inkSoft)
                Spacer()
                Button {
                    UIPasteboard.general.string = text
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
                Text(Highlight.code(text, language: language))
                    .font(Ink.code)
                    .lineSpacing(4)
                    .padding(Ink.Space.l)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .scrollIndicators(.hidden)
        }
        .paperCard()
    }
}

/// A table that scrolls sideways when it is wider than the page.
private struct TableBlock: View {
    let table: Prose.Table

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: Ink.Space.xl, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(table.header.enumerated()), id: \.offset) { column, cell in
                        cellText(cell, head: true, column: column)
                    }
                }
                .padding(.vertical, Ink.Space.m)
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    Divider().overlay(Ink.rule).gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                            cellText(cell, head: false, column: column)
                        }
                    }
                    .padding(.vertical, Ink.Space.m)
                }
            }
            .padding(.horizontal, Ink.Space.l)
            .frame(minWidth: 0, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .paperCard()
    }

    private func cellText(_ cell: String, head: Bool, column: Int) -> some View {
        let align = column < table.aligns.count ? table.aligns[column] : .leading
        let styled = (try? AttributedString(markdown: cell, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(cell)
        return Text(styled)
            .font(head ? .system(size: 14, weight: .semibold) : Ink.secondary)
            .foregroundStyle(head ? Ink.ink : Ink.inkSoft)
            .gridColumnAlignment(align == .center ? .center : (align == .trailing ? .trailing : .leading))
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
