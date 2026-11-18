import Foundation

/// What changed between two versions of a text, line by line (Swift's `CollectionDifference`), in hunks with a little context.
public enum Diff {
    public struct Summary: Equatable, Sendable {
        public var removed: Int
        public var added: Int
        /// For the model: the hunks, cut after `limit` lines. Empty when nothing changed.
        public var text: String
        /// For the person: every hunk, whole.
        public var full: String
    }

    /// Each hunk opens with this, then the line number in the new text: `@@ 第 12 行`.
    public static let marker = "@@ 第 "

    enum Line: Equatable {
        case same(String)
        case gone(String)
        case came(String)

        var changed: Bool {
            if case .same = self { return false }
            return true
        }
    }

    public static func between(_ old: String, _ new: String, context: Int = 2, limit: Int = 40) -> Summary {
        let a = old.components(separatedBy: "\n")
        let b = new.components(separatedBy: "\n")
        let lines = script(a, b)
        let removed = lines.filter { if case .gone = $0 { return true } else { return false } }.count
        let added = lines.filter { if case .came = $0 { return true } else { return false } }.count
        guard removed + added > 0 else { return Summary(removed: 0, added: 0, text: "", full: "") }
        let full = render(lines, context: context)
        let all = full.components(separatedBy: "\n")
        let text = all.count > limit
            ? all.prefix(limit).joined(separator: "\n") + "\n……后面还有 \(all.count - limit) 行对比，没列出"
            : full
        return Summary(removed: removed, added: added, text: text, full: full)
    }

    /// The two texts walked side by side. Common lines at both ends are set aside first, so a small edit to a long file stays cheap;
    /// a middle too big to compare line by line counts as replaced whole.
    static func script(_ a: [String], _ b: [String]) -> [Line] {
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let oldMiddle = Array(a[prefix..<(a.count - suffix)])
        let newMiddle = Array(b[prefix..<(b.count - suffix)])
        var lines: [Line] = a[..<prefix].map { Line.same($0) }
        if oldMiddle.count * newMiddle.count > 4_000_000 {
            lines += oldMiddle.map { Line.gone($0) } + newMiddle.map { Line.came($0) }
        } else {
            var gone = Set<Int>()
            var came = Set<Int>()
            for change in newMiddle.difference(from: oldMiddle) {
                switch change {
                case .remove(let offset, _, _): gone.insert(offset)
                case .insert(let offset, _, _): came.insert(offset)
                }
            }
            var i = 0
            var j = 0
            while i < oldMiddle.count || j < newMiddle.count {
                if i < oldMiddle.count, gone.contains(i) {
                    lines.append(.gone(oldMiddle[i]))
                    i += 1
                } else if j < newMiddle.count, came.contains(j) {
                    lines.append(.came(newMiddle[j]))
                    j += 1
                } else if i < oldMiddle.count, j < newMiddle.count {
                    lines.append(.same(oldMiddle[i]))
                    i += 1
                    j += 1
                } else {
                    // Cannot happen with a well-formed difference; never loop forever on a malformed one.
                    lines += oldMiddle[i...].map { Line.gone($0) } + newMiddle[j...].map { Line.came($0) }
                    break
                }
            }
        }
        lines += a[(a.count - suffix)...].map { Line.same($0) }
        return lines
    }

    /// Hunks: each change with `context` unchanged lines around it; hunks that touch are joined.
    static func render(_ lines: [Line], context: Int) -> String {
        var keep = [Bool](repeating: false, count: lines.count)
        for (index, line) in lines.enumerated() where line.changed {
            for near in max(0, index - context)...min(lines.count - 1, index + context) { keep[near] = true }
        }
        var out: [String] = []
        var newLine = 1
        var index = 0
        while index < lines.count {
            guard keep[index] else {
                if case .gone = lines[index] {} else { newLine += 1 }
                index += 1
                continue
            }
            // One hunk: the run of kept lines. Its header names the new line number of its first change.
            var hunk: [String] = []
            var firstChange: Int?
            var number = newLine
            while index < lines.count, keep[index] {
                switch lines[index] {
                case .same(let text):
                    hunk.append("  " + text)
                    number += 1
                case .gone(let text):
                    if firstChange == nil { firstChange = number }
                    hunk.append("- " + text)
                case .came(let text):
                    if firstChange == nil { firstChange = number }
                    hunk.append("+ " + text)
                    number += 1
                }
                index += 1
            }
            newLine = number
            out.append("\(marker)\(firstChange ?? newLine) 行")
            out += hunk
        }
        return out.joined(separator: "\n")
    }

    /// `−2 +3` read back out of a tool's first line.
    public static func counts(in output: String) -> (removed: Int, added: Int)? {
        guard let first = output.split(separator: "\n", maxSplits: 1).first,
              let match = first.firstMatch(of: #/−(\d+) \+(\d+)/#),
              let removed = Int(match.1), let added = Int(match.2) else { return nil }
        return (removed, added)
    }

    /// The hunks part of a tool's output, if it has any.
    public static func hunk(in output: String) -> String? {
        guard let range = output.range(of: marker) else { return nil }
        return String(output[range.lowerBound...])
    }
}
