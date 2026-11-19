import Foundation

/// Markdown split into blocks, for a reply that may still be arriving.
///
/// Only the block structure is parsed here; the words inside a block keep their inline
/// marks (bold, code, links), which the app hands to the system's inline parser.
public enum Prose {
    public enum Block: Equatable, Sendable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case list([Item])
        case quote([Block])
        /// `closed` is false while the closing fence has not arrived yet.
        case code(language: String, text: String, closed: Bool)
        case table(Table)
        case math(String)
        case rule
    }

    public struct Item: Equatable, Sendable {
        /// How far it is nested, 0 for the outermost.
        public var depth: Int
        /// The number an ordered item shows; nil for a bullet.
        public var number: Int?
        /// A task item: whether it is ticked.
        public var checked: Bool?
        public var text: String

        public init(depth: Int, number: Int?, checked: Bool?, text: String) {
            self.depth = depth
            self.number = number
            self.checked = checked
            self.text = text
        }
    }

    public struct Table: Equatable, Sendable {
        public enum Align: Equatable, Sendable { case leading, center, trailing }

        public var header: [String]
        public var aligns: [Align]
        public var rows: [[String]]

        public init(header: [String], aligns: [Align], rows: [[String]]) {
            self.header = header
            self.aligns = aligns
            self.rows = rows
        }
    }

    public static func parse(_ text: String) -> [Block] {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")[...]
        return parse(&lines)
    }

    // MARK: Lines

    private static func parse(_ lines: inout ArraySlice<String>) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []

        func flush() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraph = []
        }

        while let line = lines.first {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flush()
                lines = lines.dropFirst()
                continue
            }

            if let fence = fence(trimmed) {
                flush()
                lines = lines.dropFirst()
                // A fence indented under a list item: its lines carry the same indent, which is not part of the code.
                let indent = line.prefix { $0 == " " || $0 == "\t" }.count
                var body: [String] = []
                var closed = false
                while let next = lines.first {
                    lines = lines.dropFirst()
                    if next.trimmingCharacters(in: .whitespaces).hasPrefix(fence.marker) {
                        closed = true
                        break
                    }
                    var kept = Substring(next)
                    var dropped = 0
                    while dropped < indent, let first = kept.first, first == " " || first == "\t" {
                        kept = kept.dropFirst()
                        dropped += 1
                    }
                    if kept.hasSuffix("\r") { kept = kept.dropLast() }
                    body.append(String(kept))
                }
                blocks.append(.code(language: fence.language, text: body.joined(separator: "\n"), closed: closed))
                continue
            }

            if trimmed.hasPrefix("$$") {
                flush()
                lines = lines.dropFirst()
                let rest = trimmed.dropFirst(2)
                if rest.hasSuffix("$$"), rest.count >= 2 {
                    blocks.append(.math(String(rest.dropLast(2)).trimmingCharacters(in: .whitespaces)))
                    continue
                }
                var body: [String] = rest.isEmpty ? [] : [String(rest)]
                while let next = lines.first {
                    lines = lines.dropFirst()
                    let bare = next.trimmingCharacters(in: .whitespaces)
                    if bare.hasSuffix("$$") {
                        let last = String(bare.dropLast(2))
                        if !last.isEmpty { body.append(last) }
                        break
                    }
                    body.append(next)
                }
                blocks.append(.math(body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
                continue
            }

            if let heading = heading(trimmed) {
                flush()
                blocks.append(heading)
                lines = lines.dropFirst()
                continue
            }

            if isRule(trimmed) {
                flush()
                blocks.append(.rule)
                lines = lines.dropFirst()
                continue
            }

            if trimmed.hasPrefix(">") {
                flush()
                var inner: [String] = []
                while let next = lines.first {
                    let bare = next.trimmingCharacters(in: .whitespaces)
                    guard bare.hasPrefix(">") else { break }
                    var rest = bare.dropFirst()
                    if rest.first == " " { rest = rest.dropFirst() }
                    inner.append(String(rest))
                    lines = lines.dropFirst()
                }
                var nested = inner[...]
                blocks.append(.quote(parse(&nested)))
                continue
            }

            if item(line) != nil {
                flush()
                var items: [Item] = []
                while let next = lines.first {
                    if let found = item(next) {
                        items.append(found)
                        lines = lines.dropFirst()
                    } else if !next.trimmingCharacters(in: .whitespaces).isEmpty, next.hasPrefix("  ") || next.hasPrefix("\t"), !items.isEmpty {
                        // A wrapped line belongs to the item above it.
                        items[items.count - 1].text += "\n" + next.trimmingCharacters(in: .whitespaces)
                        lines = lines.dropFirst()
                    } else if next.trimmingCharacters(in: .whitespaces).isEmpty, let after = lines.dropFirst().first, item(after) != nil {
                        // A blank line between items keeps the list going.
                        lines = lines.dropFirst()
                    } else {
                        break
                    }
                }
                blocks.append(.list(items))
                continue
            }

            if trimmed.contains("|"), let separator = lines.dropFirst().first, let aligns = aligns(separator) {
                flush()
                let header = cells(trimmed)
                lines = lines.dropFirst(2)
                var rows: [[String]] = []
                while let next = lines.first {
                    let bare = next.trimmingCharacters(in: .whitespaces)
                    guard !bare.isEmpty, bare.contains("|") else { break }
                    var row = cells(bare)
                    if row.count < header.count { row += Array(repeating: "", count: header.count - row.count) }
                    rows.append(Array(row.prefix(header.count)))
                    lines = lines.dropFirst()
                }
                let fitted = aligns.count >= header.count ? Array(aligns.prefix(header.count)) : aligns + Array(repeating: .leading, count: header.count - aligns.count)
                blocks.append(.table(Table(header: header, aligns: fitted, rows: rows)))
                continue
            }

            paragraph.append(line)
            lines = lines.dropFirst()
        }
        flush()
        return blocks
    }

    // MARK: Recognizers

    private static func fence(_ line: String) -> (marker: String, language: String)? {
        for marker in ["```", "~~~"] where line.hasPrefix(marker) {
            let language = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
            return (marker, String(language.prefix { !$0.isWhitespace }))
        }
        return nil
    }

    private static func heading(_ line: String) -> Block? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        return .heading(level: hashes, text: text.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ line: String) -> Bool {
        let marks = line.filter { !$0.isWhitespace }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    private static func item(_ line: String) -> Item? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let rest = line.drop { $0 == " " || $0 == "\t" }
        var number: Int?
        var body: Substring
        if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            body = rest.dropFirst(2)
        } else {
            let digits = rest.prefix { $0.isNumber }
            guard !digits.isEmpty, digits.count <= 9 else { return nil }
            let after = rest.dropFirst(digits.count)
            guard let mark = after.first, mark == "." || mark == ")", after.dropFirst().first == " " else { return nil }
            number = Int(digits)
            body = after.dropFirst(2)
        }
        var checked: Bool?
        if body.hasPrefix("[ ] ") || body == "[ ]" {
            checked = false
            body = body.dropFirst(3)
        } else if body.hasPrefix("[x] ") || body.hasPrefix("[X] ") || body == "[x]" || body == "[X]" {
            checked = true
            body = body.dropFirst(3)
        }
        return Item(depth: indent / 2, number: number, checked: checked, text: body.trimmingCharacters(in: .whitespaces))
    }

    private static func cells(_ line: String) -> [String] {
        var bare = line.trimmingCharacters(in: .whitespaces)
        if bare.hasPrefix("|") { bare.removeFirst() }
        if bare.hasSuffix("|"), !bare.hasSuffix("\\|") { bare.removeLast() }
        var out: [String] = []
        var cell = ""
        var escaped = false
        for character in bare {
            if escaped {
                cell.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                out.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
            } else {
                cell.append(character)
            }
        }
        out.append(cell.trimmingCharacters(in: .whitespaces))
        return out
    }

    private static func aligns(_ line: String) -> [Table.Align]? {
        let bare = line.trimmingCharacters(in: .whitespaces)
        guard bare.contains("-") else { return nil }
        let parts = cells(bare)
        var out: [Table.Align] = []
        for part in parts {
            let dashes = part.filter { $0 == "-" }.count
            guard dashes >= 1, part.allSatisfy({ "-:".contains($0) }) else { return nil }
            switch (part.hasPrefix(":"), part.hasSuffix(":")) {
            case (true, true): out.append(.center)
            case (false, true): out.append(.trailing)
            default: out.append(.leading)
            }
        }
        return out.isEmpty ? nil : out
    }
}
