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
    @AppStorage("look.leading") private var leading = 0.0
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
        VStack(alignment: .leading, spacing: Pref.size * 0.8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                BlockView(block: block, fading: fade && streaming && index == blocks.count - 1)
            }
        }
        // Changes to reading typography rebuild blocks that do not observe those preferences themselves.
        .id("\(face)-\(code)-\(size)-\(leading)")
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}

/// A reply still being written. The paragraphs already finished are set once and left alone (their text no longer
/// changes, so SwiftUI does not draw them again); only the last one, still growing, is set again as characters come.
/// Setting the whole reply anew for every few characters is what made long replies stutter.
struct StreamingProse: View {
    let text: String

    var body: some View {
        let cut = Self.settled(text)
        VStack(alignment: .leading, spacing: Pref.size * 0.8) {
            if cut > text.startIndex {
                ProseView(text: String(text[..<cut]).trimmingCharacters(in: .newlines))
            }
            ProseView(text: String(text[cut...]), streaming: true)
        }
    }

    /// Where the finished part ends: just after the last blank line that is not inside a code block.
    static func settled(_ text: String) -> String.Index {
        var cut = text.startIndex
        var inFence = false
        var lineStart = text.startIndex
        var previousBlank = false
        var index = text.startIndex
        while index < text.endIndex {
            let next = text[index...].firstIndex(of: "\n") ?? text.endIndex
            let line = text[lineStart..<next].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { inFence.toggle() }
            let blank = line.isEmpty
            // A blank line after text, outside a fence, closes the block above it.
            if blank, !previousBlank, !inFence, lineStart > text.startIndex, next < text.endIndex {
                cut = text.index(after: next)
            }
            previousBlank = blank
            guard next < text.endIndex else { break }
            index = text.index(after: next)
            lineStart = index
        }
        return cut
    }
}

private struct BlockView: View {
    let block: Prose.Block
    let fading: Bool

    var body: some View {
        switch block {
        case .heading(let level, let text):
            // Headings in the reading face, a step or two larger: never a different family from the text under them.
            Inline(text: text, font: headingFont(level), fading: fading, tight: true)
                // Much more air above a heading than below it, so it plainly belongs to what follows.
                .padding(.top, level <= 1 ? Pref.size * 0.9 : (level == 2 ? Pref.size * 0.7 : Pref.size * 0.35))
                .padding(.bottom, -Pref.size * 0.3)
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
            // Items closer together than paragraphs, so a list reads as one thing.
            VStack(alignment: .leading, spacing: Pref.size * 0.35) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    // A hanging indent: the marker in its own column, wrapped lines start under the text.
                    HStack(alignment: .firstTextBaseline, spacing: Pref.size * 0.45) {
                        marker(item)
                            .frame(width: item.number != nil ? Pref.size * 1.3 : Pref.size * 0.8, alignment: item.number != nil ? .trailing : .center)
                        Inline(text: item.text, font: Ink.reading, fading: fading && index == items.count - 1)
                    }
                    .padding(.leading, CGFloat(item.depth) * Pref.size * 1.25)
                }
            }
        case .quote(let blocks):
            HStack(alignment: .top, spacing: Pref.size * 0.8) {
                Capsule().fill(Ink.rule).frame(width: 3)
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
            Rectangle().fill(Ink.rule).frame(height: 0.5).padding(.vertical, Pref.size * 0.5)
        }
    }

    /// Headings in the reading face, a step or two larger: never a different family from the text under them.
    private func headingFont(_ level: Int) -> Font {
        switch level {
        case ...1: Ink.body(Pref.size + 6, bold: true)
        case 2: Ink.body(Pref.size + 3, bold: true)
        default: Ink.body(Pref.size + 1, bold: true)
        }
    }

    @ViewBuilder
    private func marker(_ item: Prose.Item) -> some View {
        if let checked = item.checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(.system(size: Ink.Size.sub))
                .foregroundStyle(checked ? Ink.accent : Ink.inkFaint)
        } else if let number = item.number {
            // Numbers in the text's own weight and a softer ink: they lead the eye, the words carry it.
            Text("\(number).")
                .font(Ink.body(Pref.size, bold: false).monospacedDigit())
                .foregroundStyle(Ink.inkSoft)
        } else {
            Text(item.depth == 0 ? "•" : (item.depth == 1 ? "◦" : "▪"))
                .font(.system(size: Pref.size * (item.depth == 0 ? 1 : 0.85), weight: .bold))
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

    private var styled: AttributedString {
        var out = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        for run in out.runs {
            guard let intent = run.inlinePresentationIntent else { continue }
            if intent.contains(.code) {
                // Code in a sentence: the code face a little smaller, on a warm tint, in the accent's ink.
                out[run.range].font = Ink.mono(CGFloat(max(12, Pref.size - 2)))
                out[run.range].backgroundColor = Ink.mine
                out[run.range].foregroundColor = Ink.Code.inline
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
            .lineSpacing(tight ? Ink.leading * 0.5 : Ink.leading)
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
    /// What a program printed (``` text, output, console…): one green, like a terminal, not colored as code.
    private var isOutput: Bool {
        if ["text", "txt", "output", "console", "log", "plaintext", "plain", "stdout", "shell-session"].contains(language.lowercased()) { return true }
        // No language given, and nothing that reads as code: a log or what a command printed.
        guard language.isEmpty else { return false }
        let marks = ["{", "}", ";", " = ", "=>", "->", "def ", "func ", "function ", "import ", "return ", "const ", "let ", "class "]
        return !marks.contains { text.contains($0) }
    }
    /// Long code shows its first lines; the rest opens on a tap.
    private var folds: Bool { lineCount > 20 }
    private var shown: String {
        guard folds, !unfolded else { return text }
        return text.split(separator: "\n", omittingEmptySubsequences: false).prefix(12).joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(isOutput ? "输出" : (language.isEmpty ? "代码" : language.lowercased()))
                    .font(Ink.mono(Ink.Size.small, weight: .medium))
                    .foregroundStyle(Ink.inkSoft)
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
                        .font(.system(size: Ink.Size.small, weight: .medium))
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
            Rectangle().fill(Ink.rule).frame(height: 0.5)
            // Long lines wrap inside the block, as Open Minis does: nothing to slide sideways; the copy button copies them whole.
            Text(isOutput ? AttributedString(shown) : Highlight.code(shown, language: language))
                .foregroundStyle(isOutput ? Ink.Code.output : Ink.ink)
                .font(Ink.code)
                .lineSpacing(Pref.size * 0.3)
                .padding(Ink.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
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
                .overlay(alignment: .top) { Rectangle().fill(Ink.rule).frame(height: 0.5) }
            }
        }
        // Set apart from the words around it: a warmer, deeper ground and a firmer edge, so what is to be copied
        // reads as something to copy.
        .background(Ink.mine, in: .rect(cornerRadius: Ink.Radius.small, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Ink.Radius.small, style: .continuous).strokeBorder(Ink.inkFaint.opacity(0.45), lineWidth: 0.8))
        .clipShape(.rect(cornerRadius: Ink.Radius.small, style: .continuous))
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

    private var widths: [CGFloat] {
        let columns = max(table.header.count, table.rows.map(\.count).max() ?? 0)
        // Measured in the face the cells are set in, so a column is as wide as its words really are.
        let head = Pref.face.postScript(bold: true).flatMap { UIFont(name: $0, size: Self.cellSize) } ?? .systemFont(ofSize: Self.cellSize, weight: .semibold)
        let body = Pref.face.postScript(bold: false).flatMap { UIFont(name: $0, size: Self.cellSize) } ?? .systemFont(ofSize: Self.cellSize)
        return (0..<columns).map { column in
            var natural = Self.measure(column < table.header.count ? table.header[column] : "", font: head)
            for row in table.rows where column < row.count {
                natural = max(natural, Self.measure(row[column], font: body))
            }
            return max(28, ceil(natural) + 4)
        }
    }

    /// One line's width, without the Markdown marks that are not drawn.
    private static func measure(_ cell: String, font: UIFont) -> CGFloat {
        let plain = cell.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "~~", with: "")
        return (plain as NSString).size(withAttributes: [.font: font]).width
    }

    var body: some View {
        let widths = spread(self.widths)
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                row(table.header, head: true, widths: widths)
                // The header stands on a firmer line than the rows between themselves.
                Rectangle().fill(Ink.inkFaint.opacity(0.6)).frame(height: 1)
                ForEach(Array(table.rows.enumerated()), id: \.offset) { index, cells in
                    if index > 0 { Rectangle().fill(Ink.rule).frame(height: 0.5) }
                    row(cells, head: false, widths: widths)
                }
            }
            .padding(.horizontal, Ink.Space.l)
            .fixedSize(horizontal: true, vertical: false)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { room = $0 }
        .inkBlock()
    }

    private func row(_ cells: [String], head: Bool, widths: [CGFloat]) -> some View {
        HStack(alignment: .top, spacing: Self.gap) {
            ForEach(Array(widths.enumerated()), id: \.offset) { column, width in
                cellText(column < cells.count ? cells[column] : "", head: head, column: column)
                    .frame(width: width, alignment: frameAlign(column))
            }
        }
        .padding(.vertical, Self.cellSize * 0.65)
    }

    private func frameAlign(_ column: Int) -> Alignment {
        let align = column < table.aligns.count ? table.aligns[column] : .leading
        return align == .center ? .top : (align == .trailing ? .topTrailing : .topLeading)
    }

    private func cellText(_ cell: String, head: Bool, column: Int) -> some View {
        let align = column < table.aligns.count ? table.aligns[column] : .leading
        let styled = (try? AttributedString(markdown: cell, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(cell)
        // Cells in the reading face, like the words around the table; the body in full ink, as text to read.
        return Text(styled)
            .font(Ink.body(Double(Self.cellSize), bold: head))
            .foregroundStyle(Ink.ink)
            .multilineTextAlignment(align == .center ? .center : (align == .trailing ? .trailing : .leading))
            .lineSpacing(Self.cellSize * 0.25)
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
                // Comments in faint italics: notes in the margin, not the code.
                var part = AttributedString(String(text[index..<end]))
                part.foregroundColor = Ink.inkFaint
                part.font = Ink.mono(CGFloat(max(12, Pref.size - 3))).italic()
                out += part
                index = end
            } else if character == "\"" || character == "'" || character == "`" {
                var end = text.index(after: index)
                while end < text.endIndex, text[end] != character, text[end] != "\n" {
                    if text[end] == "\\" { end = text.index(after: end) }
                    if end < text.endIndex { end = text.index(after: end) }
                }
                if end < text.endIndex, text[end] == character { end = text.index(after: end) }
                append(text[index..<end], Ink.Code.string)
                index = end
            } else if character.isLetter || character == "_" {
                let end = rest.firstIndex { !($0.isLetter || $0.isNumber || $0 == "_") } ?? text.endIndex
                let word = text[index..<end]
                // A name called with ( is a function.
                let calls = end < text.endIndex && text[end] == "("
                append(word, keywords.contains(String(word)) ? Ink.Code.keyword : (calls ? Ink.Code.function : Ink.ink))
                index = end
            } else if character.isNumber {
                let end = rest.firstIndex { !($0.isNumber || $0 == ".") } ?? text.endIndex
                append(text[index..<end], Ink.Code.number)
                index = end
            } else {
                append(text[index...index], Ink.ink)
                index = text.index(after: index)
            }
        }
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

/// One picture in a reply: from the web, or from 书案 (a path the companion wrote there). Tap to see it whole,
/// with the system viewer's share and save.
struct ProsePicture: View {
    let source: String
    var label: String = ""
    @State private var image: UIImage?
    @State private var file: URL?
    @State private var failed = false
    @State private var open = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 360, alignment: .leading)
                    .clipShape(.rect(cornerRadius: Ink.Radius.small, style: .continuous))
                    .onTapGesture { if file != nil { Haptics.light(); open = true } }
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
            if let file { QuickPreview(url: file).ignoresSafeArea() }
        }
    }

    private func load() async {
        if let url = URL(string: source), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let picture = UIImage(data: data) else { failed = true; return }
                // Kept as a file so the viewer can share and save it.
                let name = url.lastPathComponent.isEmpty ? "图片.png" : url.lastPathComponent
                let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + name)
                try? data.write(to: local)
                file = local
                image = picture
            } catch {
                failed = true
            }
            return
        }
        var path = source
        if path.hasPrefix("file://"), let url = URL(string: path) { path = url.path }
        if path.hasPrefix(Workspace.root.path) { path = String(path.dropFirst(Workspace.root.path.count)) }
        guard let url = Workspace.resolve(path.removingPercentEncoding ?? path),
              let data = try? Data(contentsOf: url), let picture = UIImage(data: data) else { failed = true; return }
        file = url
        image = picture
    }
}


/// A file the companion made, handed over in the reply: a line that is only a link into 书案 (`[周报.pdf](书案/周报.pdf)`)
/// becomes a card. Tap it to read it in the system viewer, which can also share it or save it to 文件.
struct FileCard: View {
    let label: String
    let path: String
    @State private var open = false

    private var url: URL? {
        var cleaned = path.removingPercentEncoding ?? path
        if cleaned.hasPrefix("file://"), let url = URL(string: path) { cleaned = url.path }
        if cleaned.hasPrefix(Workspace.root.path) { cleaned = String(cleaned.dropFirst(Workspace.root.path.count)) }
        return Workspace.resolve(cleaned)
    }

    var body: some View {
        let file = url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        Button {
            guard file != nil else { return }
            Haptics.light()
            open = true
        } label: {
            HStack(spacing: Ink.Space.m) {
                IconBadge(symbol: Self.symbol(for: path), tint: file == nil ? Ink.Tile.off : Ink.Tile.accent, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label.isEmpty ? (path as NSString).lastPathComponent : label)
                        .font(.system(size: Ink.Size.sub, weight: .semibold))
                        .foregroundStyle(Ink.ink)
                        .lineLimit(1)
                    Text(file.map(Self.detail) ?? "找不到这个文件了")
                        .font(.system(size: Ink.Size.small))
                        .foregroundStyle(Ink.inkSoft)
                        .lineLimit(1)
                }
                Spacer(minLength: Ink.Space.s)
                if file != nil { Kit.chevron }
            }
            .padding(Ink.Space.m)
            .inkBlock()
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(haptic: false))
        .accessibilityLabel("打开 \(label)")
        .sheet(isPresented: $open) {
            if let file { QuickPreview(url: file).ignoresSafeArea() }
        }
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

    static func detail(_ url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let where_ = "书案/" + Workspace.relative(url)
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) + " · " + where_
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
    @AppStorage("look.face") private var face = "serif"
    @AppStorage("look.code") private var code = "maple"
    @AppStorage("look.size") private var size = 17.0
    @AppStorage("look.leading") private var leading = 0.0
    /// Native text takes its colours when set: a change of light and dark sets it again.
    @Environment(\.colorScheme) private var scheme
    let text: String

    static func == (a: SelectableProse, b: SelectableProse) -> Bool { a.text == b.text }

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
        let parts = Self.parts(ParsedCache.blocks(text))
        VStack(alignment: .leading, spacing: Pref.size * 0.8) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                switch part {
                case .words(let blocks):
                    ProseText(attributed: ProseWords.make(blocks))
                case .block(let block):
                    BlockView(block: block, fading: false)
                }
            }
        }
        .id("\(face)-\(code)-\(size)-\(leading)-\(scheme == .dark)-\(Theme.shared.key)")
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The words of a reply as one attributed text, set like `BlockView` sets them.
enum ProseWords {
    static func isWords(_ block: Prose.Block) -> Bool {
        switch block {
        case .heading, .list: return true
        case .paragraph(let text): return FileCard.links(in: text) == nil && !text.contains("![")
        case .quote(let inner): return inner.allSatisfy(isWords)
        default: return false
        }
    }

    static func make(_ blocks: [Prose.Block]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            if index > 0 { out.append(NSAttributedString(string: "\n")) }
            out.append(set(block, quoteDepth: 0, first: index == 0))
        }
        return out
    }

    private static func style(spacing: CGFloat = Pref.size * 0.8, before: CGFloat = 0, indent: CGFloat = 0, hanging: CGFloat = 0, tight: Bool = false) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = tight ? Ink.leading * 0.5 : Ink.leading
        style.paragraphSpacing = spacing
        style.paragraphSpacingBefore = before
        style.firstLineHeadIndent = indent
        style.headIndent = indent + hanging
        if hanging > 0 { style.tabStops = [NSTextTab(textAlignment: .left, location: indent + hanging)] }
        return style
    }

    private static func set(_ block: Prose.Block, quoteDepth: Int, first: Bool) -> NSAttributedString {
        let quote = CGFloat(quoteDepth) * Pref.size * 1.1
        let ink = quoteDepth > 0 ? UIColor(Ink.inkSoft) : UIColor(Ink.ink)
        switch block {
        case .heading(let level, let text):
            let grow: CGFloat = level <= 1 ? 6 : (level == 2 ? 3 : 1)
            let before: CGFloat = first ? 0 : (level <= 1 ? Pref.size * 0.9 : (level == 2 ? Pref.size * 0.7 : Pref.size * 0.35))
            return inline(text, size: Pref.size + grow, bold: true, ink: ink,
                          paragraph: style(spacing: Pref.size * 0.5, before: before, indent: quote, tight: true))
        case .paragraph(let text):
            return inline(text, size: Pref.size, bold: false, ink: ink, paragraph: style(indent: quote))
        case .list(let items):
            let out = NSMutableAttributedString()
            for (index, item) in items.enumerated() {
                if index > 0 { out.append(NSAttributedString(string: "\n")) }
                let marker: String
                if let checked = item.checked { marker = checked ? "☑︎" : "☐" }
                else if let number = item.number { marker = "\(number)." }
                else { marker = item.depth == 0 ? "•" : (item.depth == 1 ? "◦" : "▪") }
                let indent = quote + CGFloat(item.depth) * Pref.size * 1.25
                let hang = item.number != nil ? Pref.size * 1.75 : Pref.size * 1.25
                let last = index == items.count - 1
                let paragraph = style(spacing: last ? Pref.size * 0.8 : Pref.size * 0.35, indent: indent, hanging: hang)
                out.append(NSAttributedString(string: marker + "\t", attributes: [
                    .font: Ink.uiFace(Pref.size), .foregroundColor: UIColor(Ink.inkSoft), .paragraphStyle: paragraph,
                ]))
                out.append(inline(item.text, size: Pref.size, bold: false, ink: ink, paragraph: paragraph))
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
                attributes[.backgroundColor] = UIColor(Ink.mine)
                attributes[.foregroundColor] = UIColor(Ink.Code.inline)
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

/// Native text that can be selected across lines and paragraphs: long-press a word, drag the handles, 拷贝.
private struct ProseText: UIViewRepresentable {
    let attributed: NSAttributedString
    @Environment(\.openURL) private var openURL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(usingTextLayoutManager: true)
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

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.open = openURL
        if !view.attributedText.isEqual(to: attributed) { view.attributedText = attributed }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.window?.windowScene?.screen.bounds.width ?? 360
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(fitted.height))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var open: OpenURLAction?

        /// A tapped link goes where the rest of Clio sends links (the in-app browser, 书案 files …).
        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
            if case .link(let url) = textItem.content, let open {
                return UIAction { _ in open(url) }
            }
            return defaultAction
        }
    }
}

extension Ink {
    /// The reading face as a UIKit font, for native selectable text.
    static func uiFace(_ size: CGFloat, bold: Bool = false) -> UIFont {
        if let name = Pref.face.postScript(bold: bold), has(name), let font = UIFont(name: name, size: size) { return font }
        let base = UIFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        let design: UIFontDescriptor.SystemDesign
        switch Pref.face {
        case .sans: design = .default
        case .rounded: design = .rounded
        default: design = .serif
        }
        guard let described = base.fontDescriptor.withDesign(design) else { return base }
        return UIFont(descriptor: described, size: size)
    }
}
