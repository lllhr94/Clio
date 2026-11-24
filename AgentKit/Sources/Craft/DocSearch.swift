import Foundation

/// Finds the passages of the user's papers that answer a few words: by the words themselves, and for Chinese,
/// by pairs of characters too, so 「报销流程」 still finds 「报销的流程」.
public enum DocSearch {
    public struct Hit: Equatable, Sendable {
        public var path: String
        /// For a PDF: the page the passage is on.
        public var page: Int?
        public var snippet: String
        public var score: Int

        public init(path: String, page: Int? = nil, snippet: String, score: Int) {
            self.path = path
            self.page = page
            self.snippet = snippet
            self.score = score
        }
    }

    /// The words of a query: split at spaces and punctuation, lower-cased.
    public static func terms(_ query: String) -> [String] {
        let bounded = String(query.prefix(512))
        let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)
        var seen = Set<String>()
        var result: [String] = []
        for token in bounded.lowercased().components(separatedBy: separators) {
            guard !token.isEmpty else { continue }
            if seen.insert(token).inserted {
                result.append(token)
                if result.count >= 24 {
                    break
                }
            }
        }
        return result
    }

    static func isWide(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) }
    }

    /// Pairs of neighbouring characters of a Chinese word of three or more: 「报销流程」 → 报销, 销流, 流程.
    static func pairs(_ word: String) -> [String] {
        let characters = Array(word)
        guard characters.count >= 3, isWide(word) else { return [] }
        return (0..<(characters.count - 1)).map { String(characters[$0...$0 + 1]) }
    }

    /// Paragraphs of a text, none longer than about `size` characters, each with the PDF page it is on.
    public static func passages(_ text: String, size: Int = 600) -> [(page: Int?, text: String)] {
        var found: [(page: Int?, text: String)] = []
        var page: Int?
        var current = ""
        func close() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { found.append((page, trimmed)) }
            current = ""
        }
        for line in text.components(separatedBy: "\n") {
            let bare = line.trimmingCharacters(in: .whitespaces)
            if bare.hasPrefix("[第 "),
               bare.hasSuffix(" 页]"),
               let number = Int32(bare.dropFirst(3).dropLast(3)),
               number > 0 {
                close()
                page = Int(number)
                continue
            }
            if bare.isEmpty {
                if current.count > 80 { close() }
                continue
            }
            if current.count + bare.count > size { close() }
            current += (current.isEmpty ? "" : "\n") + bare
        }
        close()
        return found
    }

    public static func find(_ query: String, in documents: [(path: String, text: String)], limit: Int = 12) -> [Hit] {
        let words = terms(query)
        guard !words.isEmpty else { return [] }
        let soft = words.flatMap(pairs)
        var hits: [Hit] = []
        for document in documents {
            for passage in passages(document.text) {
                let lower = passage.text.lowercased()
                var score = 0
                var whole = 0
                for word in words where lower.contains(word) {
                    whole += 1
                    score += 10 + min(5, lower.components(separatedBy: word).count - 1)
                }
                let softHits = soft.filter { lower.contains($0) }.count
                if whole == 0 {
                    // No whole word: enough of the pairs, or nothing.
                    guard !soft.isEmpty, softHits * 2 >= soft.count else { continue }
                }
                score += softHits * 2
                if whole == words.count, words.count > 1 { score += 20 }
                hits.append(Hit(path: document.path, page: passage.page, snippet: snippet(passage.text, around: words + soft), score: score))
            }
        }
        return Array(hits.sorted { $0.score > $1.score }.prefix(limit))
    }

    /// About 300 characters of a passage, around the first word found.
    public static func snippet(_ text: String, around words: [String], width: Int = 300) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard flat.count > width else { return flat }
        let lower = flat.lowercased()
        let first = words.compactMap { lower.range(of: $0) }.min { $0.lowerBound < $1.lowerBound }
        let at = first.map { lower.distance(from: lower.startIndex, to: $0.lowerBound) } ?? 0
        let start = max(0, min(at - width / 3, flat.count - width))
        let from = flat.index(flat.startIndex, offsetBy: start)
        let to = flat.index(from, offsetBy: width)
        return (start > 0 ? "…" : "") + String(flat[from..<to]) + (start + width < flat.count ? "…" : "")
    }

    /// Hits as a model reads them.
    public static func shown(_ hits: [Hit], query: String) -> String {
        guard !hits.isEmpty else { return "在资料里没找到和「\(query)」有关的段落。换个说法，或者用更短的关键词再找。" }
        return "和「\(query)」最相关的 \(hits.count) 段：\n\n" + hits.map { hit in
            "【\(hit.path)\(hit.page.map { " 第 \($0) 页" } ?? "")】\n\(hit.snippet)"
        }.joined(separator: "\n\n")
    }
}
