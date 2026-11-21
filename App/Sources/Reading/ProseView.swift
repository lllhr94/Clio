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
        ["text", "txt", "output", "console", "log", "plaintext", "plain", "stdout", "shell-session"].contains(language.lowercased())
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
            ScrollView(.horizontal) {
                Text(isOutput ? AttributedString(shown) : Highlight.code(shown, language: language))
                    .foregroundStyle(isOutput ? Ink.Code.output : Ink.ink)
                    .font(Ink.code)
                    .lineSpacing(Pref.size * 0.3)
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
                .overlay(alignment: .top) { Rectangle().fill(Ink.rule).frame(height: 0.5) }
            }
        }
        .inkBlock()
    }
}

/// A table that scrolls sideways when it is wider than the page.
/// Each column gets a width measured from its words (up to 260 points, then they wrap), and each row is as tall
/// as its tallest cell, so a cell that wraps onto several lines pushes the line under it down instead of
/// running over it.
private struct TableBlock: View {
    let table: Prose.Table

    private static let widest: CGFloat = 260
    /// Table text, two points under the reading size.
    private static var cellSize: CGFloat { CGFloat(max(12, Pref.size - 2)) }
    private static let gap: CGFloat = 20

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
