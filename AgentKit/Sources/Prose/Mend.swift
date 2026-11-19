import Foundation

public extension Prose {
    /// While a reply is still arriving its last line is often half written: `**粗` with no closing marks, a link
    /// without its address, a line that is only `#` or `-`. Shown as is, the marks flash and then jump into
    /// formatting. This closes what is open and holds back what cannot be shown yet, so every word appears in
    /// its final form. Only the unfinished tail is touched; copying always uses the real text.
    static func mend(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var lines = text.components(separatedBy: "\n")
        // Inside an open code fence nothing is markdown: leave it.
        let fences = lines.filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }.count
        if fences % 2 == 1 {
            // A fence whose language is still being typed shows nothing yet.
            if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") { lines.removeLast() }
            return lines.joined(separator: "\n")
        }
        guard var last = lines.popLast() else { return text }
        let bare = last.trimmingCharacters(in: .whitespaces)
        // A line that is only a mark: a heading, list or rule just begun.
        if bare.range(of: #"^(#{1,6}|[-*+]|\d+[.)]|>|=+|-{2,}|\|)$"#, options: .regularExpression) != nil {
            return lines.joined(separator: "\n")
        }
        // A table row is shown once the row is finished.
        if bare.hasPrefix("|"), !bare.hasSuffix("|") || bare.count < 2 {
            return lines.joined(separator: "\n")
        }
        last = closeLink(last)
        last = closeMarks(last)
        lines.append(last)
        return lines.joined(separator: "\n")
    }

    /// `[文字](htt` → `[文字](#)`; `![图](` and a lone `[文字` are held back from where they start.
    internal static func closeLink(_ line: String) -> String {
        guard let open = line.range(of: "[", options: .backwards) else { return line }
        let rest = line[open.lowerBound...]
        if rest.contains(")") { return line }
        let isImage = open.lowerBound > line.startIndex && line[line.index(before: open.lowerBound)] == "!"
        let start = isImage ? line.index(before: open.lowerBound) : open.lowerBound
        if isImage { return String(line[..<start]) }
        if let middle = rest.range(of: "](") {
            return String(line[..<middle.lowerBound]) + "](#)"
        }
        // `[文字` alone may still turn into a link: show the words without the bracket.
        if rest.contains("]") { return line }
        return String(line[..<open.lowerBound]) + String(rest.dropFirst())
    }

    /// Closes `**`, `~~`, `` ` `` and `*` left open on the line, innermost last.
    internal static func closeMarks(_ line: String) -> String {
        var out = line
        // Inline code first: inside it nothing else counts.
        let ticks = out.filter { $0 == "`" }.count
        if ticks % 2 == 1 {
            if out.hasSuffix("`") { out.removeLast() } else { out += "`" }
            return out
        }
        var outside = ""
        var inCode = false
        for character in out {
            if character == "`" { inCode.toggle(); continue }
            if !inCode { outside.append(character) }
        }
        var tail = ""
        for mark in ["**", "~~"] {
            let count = outside.components(separatedBy: mark).count - 1
            if count % 2 == 1 {
                if out.hasSuffix(mark) { out.removeLast(mark.count) } else { tail = mark + tail }
            }
        }
        let singles = outside.replacingOccurrences(of: "**", with: "").filter { $0 == "*" }.count
        // A list bullet is not emphasis.
        let bullet = outside.trimmingCharacters(in: .whitespaces).hasPrefix("* ") ? 1 : 0
        if (singles - bullet) % 2 == 1 {
            if out.hasSuffix("*") && !out.hasSuffix("**") { out.removeLast() } else { tail = "*" + tail }
        }
        // Marks right before the closing ones would leave `** **`: trim the space they would wrap.
        if !tail.isEmpty { while out.last == " " { out.removeLast() } }
        return out + tail
    }
}
