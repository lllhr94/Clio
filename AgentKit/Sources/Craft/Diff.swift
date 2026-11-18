import Foundation

/// What changed between two versions of a text, as one hunk: what went, what came, a little context around it.
public enum Diff {
    public struct Summary: Equatable, Sendable {
        public var removed: Int
        public var added: Int
        /// Starts with `@@ 第 N 行`; lines begin with "  ", "- " or "+ ". Empty when nothing changed.
        public var text: String
    }

    /// The opening of the hunk inside a tool's output.
    public static let marker = "@@ 第 "

    public static func between(_ old: String, _ new: String, context: Int = 2, limit: Int = 40) -> Summary {
        let a = old.components(separatedBy: "\n")
        let b = new.components(separatedBy: "\n")
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let gone = Array(a[prefix..<(a.count - suffix)])
        let came = Array(b[prefix..<(b.count - suffix)])
        guard !gone.isEmpty || !came.isEmpty else { return Summary(removed: 0, added: 0, text: "") }
        var lines = ["\(marker)\(prefix + 1) 行"]
        for line in a[max(0, prefix - context)..<prefix] { lines.append("  " + line) }
        let half = max(4, limit / 2)
        func add(_ list: [String], _ sign: String) {
            for line in list.prefix(half) { lines.append(sign + " " + line) }
            if list.count > half { lines.append("\(sign) ……还有 \(list.count - half) 行") }
        }
        add(gone, "-")
        add(came, "+")
        let after = a.count - suffix
        for line in a[after..<min(a.count, after + context)] { lines.append("  " + line) }
        return Summary(removed: gone.count, added: came.count, text: lines.joined(separator: "\n"))
    }

    /// `−2 +3` read back out of a tool's first line.
    public static func counts(in output: String) -> (removed: Int, added: Int)? {
        guard let first = output.split(separator: "\n", maxSplits: 1).first,
              let match = first.firstMatch(of: #/−(\d+) \+(\d+)/#),
              let removed = Int(match.1), let added = Int(match.2) else { return nil }
        return (removed, added)
    }

    /// The hunk part of a tool's output, if it has one.
    public static func hunk(in output: String) -> String? {
        guard let range = output.range(of: marker) else { return nil }
        return String(output[range.lowerBound...])
    }
}
