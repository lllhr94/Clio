import Foundation

/// Normalizes and tokenizes CJK, ASCII, and mixed conversation text for SQLite FTS5 indexing and queries.
public enum MemoryIndexTokenizer {
    public struct IndexedTokens: Equatable, Sendable {
        public var bodyTokens: String
        public var cjkUnigrams: String

        public init(bodyTokens: String, cjkUnigrams: String) {
            self.bodyTokens = bodyTokens
            self.cjkUnigrams = cjkUnigrams
        }
    }

    private enum ScriptRun: Equatable {
        case word(String)
        case cjk([Character])
    }

    /// Normalizes compatibility characters (e.g. fullwidth ASCII) and folds case/diacritics.
    public static func normalize(_ text: String) -> String {
        text
            .precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    static func isCJKScalar(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x309F, // Hiragana
             0x30A0...0x30FF, // Katakana
             0x3400...0x4DBF, // CJK Extension A
             0x4E00...0x9FFF, // CJK Unified Ideographs
             0xAC00...0xD7AF, // Hangul Syllables
             0xF900...0xFAFF, // CJK Compatibility Ideographs
             0x20000...0x2EBE0, // CJK Extensions B-F
             0x30000...0x323AF: // CJK Extensions G-H
            return true
        default:
            return false
        }
    }

    private static func extractRuns(from text: String) -> [ScriptRun] {
        let normalized = normalize(text)
        var runs: [ScriptRun] = []
        var wordBuffer = ""
        var cjkBuffer: [Character] = []

        func flushWord() {
            if !wordBuffer.isEmpty {
                runs.append(.word(wordBuffer))
                wordBuffer.removeAll(keepingCapacity: true)
            }
        }

        func flushCJK() {
            if !cjkBuffer.isEmpty {
                runs.append(.cjk(cjkBuffer))
                cjkBuffer.removeAll(keepingCapacity: true)
            }
        }

        for scalar in normalized.unicodeScalars {
            if scalar.properties.generalCategory == .nonspacingMark {
                continue
            }
            if isCJKScalar(scalar) {
                flushWord()
                cjkBuffer.append(Character(scalar))
            } else if CharacterSet.alphanumerics.contains(scalar) {
                flushCJK()
                wordBuffer.append(Character(scalar))
            } else {
                flushWord()
                flushCJK()
            }
        }
        flushWord()
        flushCJK()
        return runs
    }

    /// Produces space-delimited FTS5 tokens:
    /// - ASCII/alphanumeric words are preserved cleanly (`xcode`, `postgresql`, `rust`)
    /// - CJK runs of length >= 2 emit overlapping 2-character bigrams (`重庆`, `庆麻`, `麻辣`)
    /// - Standalone 1-character CJK runs emit unigrams in `bodyTokens`, while all CJK characters are indexed in `cjkUnigrams`.
    public static func indexTokens(for text: String) -> IndexedTokens {
        let runs = extractRuns(from: text)
        var body: [String] = []
        var unigrams: [String] = []

        for run in runs {
            switch run {
            case .word(let word):
                body.append(word)
            case .cjk(let chars):
                for ch in chars {
                    unigrams.append(String(ch))
                }
                if chars.count == 1 {
                    body.append(String(chars[0]))
                } else {
                    for index in 0..<(chars.count - 1) {
                        body.append(String(chars[index...index + 1]))
                    }
                }
            }
        }

        return IndexedTokens(
            bodyTokens: body.joined(separator: " "),
            cjkUnigrams: unigrams.joined(separator: " ")
        )
    }

    /// Builds a safe, injection-proof SQLite FTS5 `MATCH` expression for mixed CJK/ASCII queries.
    /// Returns `nil` when the query contains only whitespace or punctuation.
    public static func fts5MatchExpression(for query: String) -> String? {
        let runs = Array(extractRuns(from: query).prefix(12))
        guard !runs.isEmpty else { return nil }

        var clauses: [String] = []
        for run in runs {
            switch run {
            case .word(let word):
                let safe = quotedFTS5Literal(word)
                guard !safe.isEmpty else { continue }
                if word.count >= 2 {
                    clauses.append("body_tokens : \(safe)*")
                } else {
                    clauses.append("body_tokens : \(safe)")
                }
            case .cjk(let chars):
                if chars.count == 1 {
                    let safe = quotedFTS5Literal(String(chars[0]))
                    if !safe.isEmpty {
                        clauses.append("cjk_unigrams : \(safe)")
                    }
                } else if chars.count == 2 {
                    let safe = quotedFTS5Literal(String(chars))
                    if !safe.isEmpty {
                        clauses.append("body_tokens : \(safe)")
                    }
                } else {
                    let allBigrams = (0..<(chars.count - 1)).map { String(chars[$0...$0 + 1]) }
                    var covering: [String] = []
                    var idx = 0
                    while idx + 1 < chars.count {
                        covering.append(String(chars[idx...idx + 1]))
                        idx += 2
                    }
                    if chars.count % 2 == 1, let tail = allBigrams.last, covering.last != tail {
                        covering.append(tail)
                    }
                    let coveringSet = Set(covering)
                    let coveringClauses = covering.compactMap { bigram -> String? in
                        let safe = quotedFTS5Literal(bigram)
                        return safe.isEmpty ? nil : "body_tokens : \(safe)"
                    }
                    guard !coveringClauses.isEmpty else { continue }
                    let extras = allBigrams.filter { !coveringSet.contains($0) }
                    if extras.isEmpty {
                        clauses.append(contentsOf: coveringClauses)
                    } else {
                        // Logically equivalent to AND over covering bigrams, while letting exact contiguous matches score higher in BM25.
                        let extraClauses = extras.prefix(8).compactMap { bigram -> String? in
                            let safe = quotedFTS5Literal(bigram)
                            return safe.isEmpty ? nil : "body_tokens : \(safe)"
                        }
                        if let firstCovering = coveringClauses.first, !extraClauses.isEmpty {
                            let core = coveringClauses.joined(separator: " AND ")
                            let boost = (extraClauses + [firstCovering]).joined(separator: " OR ")
                            clauses.append("(\(core)) AND (\(boost))")
                        } else {
                            clauses.append(contentsOf: coveringClauses)
                        }
                    }
                }
            }
        }

        guard !clauses.isEmpty else { return nil }
        return clauses.joined(separator: " AND ")
    }

    /// Search terms used ONLY when SQLite is compiled without FTS5 (fallback LIKE mode).
    public static func fallbackLikeTerms(for query: String) -> [String] {
        let runs = Array(extractRuns(from: query).prefix(8))
        var seen = Set<String>()
        var terms: [String] = []
        for run in runs {
            let term: String
            switch run {
            case .word(let word): term = word
            case .cjk(let chars): term = String(chars)
            }
            if !term.isEmpty, seen.insert(term).inserted {
                terms.append(term)
            }
        }
        return terms
    }

    /// Extracts a readable snippet centered around the first matching query term.
    public static func extractSnippet(from text: String, query: String, maxChars: Int = 220) -> String {
        let flat = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flat.isEmpty else { return "" }
        let width = max(40, maxChars)
        guard flat.count > width else { return flat }

        let runs = extractRuns(from: query)
        var candidates: [String] = []
        for run in runs {
            switch run {
            case .word(let word):
                candidates.append(word)
            case .cjk(let chars):
                candidates.append(String(chars))
                if chars.count >= 2 {
                    for i in 0..<(chars.count - 1) {
                        candidates.append(String(chars[i...i + 1]))
                    }
                }
            }
        }

        let firstRange = candidates.compactMap { term in
            flat.range(of: term, options: [.caseInsensitive, .diacriticInsensitive])
        }.min { $0.lowerBound < $1.lowerBound }

        let anchorOffset = firstRange.map { flat.distance(from: flat.startIndex, to: $0.lowerBound) } ?? 0
        let startOffset = max(0, min(anchorOffset - width / 3, flat.count - width))
        let startIdx = flat.index(flat.startIndex, offsetBy: startOffset)
        let endIdx = flat.index(startIdx, offsetBy: width, limitedBy: flat.endIndex) ?? flat.endIndex
        let prefix = startOffset > 0 ? "…" : ""
        let suffix = endIdx < flat.endIndex ? "…" : ""
        return prefix + String(flat[startIdx..<endIdx]) + suffix
    }

    private static func quotedFTS5Literal(_ token: String) -> String {
        let sanitized = token.replacingOccurrences(of: "\"", with: "")
        guard !sanitized.isEmpty else { return "" }
        return "\"\(sanitized)\""
    }
}
