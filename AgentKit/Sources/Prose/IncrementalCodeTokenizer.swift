import Foundation

/// Semantic token kind produced by `IncrementalCodeTokenizer`.
/// App layers map these kinds onto WCAG AA paper/ink color palettes.
public enum CodeTokenKind: UInt8, Equatable, Hashable, Sendable {
    case plain = 0
    case keyword = 1
    case function = 2
    case number = 3
    case string = 4
    case comment = 5
}

/// Coalesced display segment annotated with token kind and CJK/full-width alignment flag.
public struct CodeTokenSegment: Equatable, Hashable, Sendable {
    public let text: String
    public let kind: CodeTokenKind
    public let isWide: Bool

    public init(text: String, kind: CodeTokenKind, isWide: Bool) {
        self.text = text
        self.kind = kind
        self.isWide = isWide
    }
}

/// Cross-line lexical state preserved at the end of each scanned line.
public enum CodeLexerLineState: Equatable, Hashable, Sendable {
    case normal
    case blockComment(depth: Int)
    case htmlComment
    case tripleQuote(delimiter: UInt8)
    case backtickString
}

/// Single tokenized source line paired with its exit state for O(1) incremental reuse.
public struct TokenizedCodeLine: Equatable, Sendable {
    public let rawLine: String
    public let segments: [CodeTokenSegment]
    public let hasWide: Bool
    public let entryState: CodeLexerLineState
    public let endState: CodeLexerLineState
    public let circuitBroken: Bool

    public init(
        rawLine: String,
        segments: [CodeTokenSegment],
        hasWide: Bool,
        entryState: CodeLexerLineState,
        endState: CodeLexerLineState,
        circuitBroken: Bool
    ) {
        self.rawLine = rawLine
        self.segments = segments
        self.hasWide = hasWide
        self.entryState = entryState
        self.endState = endState
        self.circuitBroken = circuitBroken
    }
}

/// Pure UTF-8 byte-scanning incremental syntax tokenizer living in the SwiftPM `Prose` target.
///
/// Tracks end-of-line cross-line lexical states (`/* */`, nested block comments, HTML comments,
/// triple-quoted strings, and multi-line backtick strings) so streaming tail appends only
/// re-scan newly modified trailing lines. Circuit-breaks oversized lines (>2,000 chars) and
/// oversized blocks (>2,000 lines) cleanly back to plain monospace.
public struct IncrementalCodeTokenizer: Equatable, Sendable {
    public static let maxLineCharacters = 2_000
    public static let maxBlockLines = 2_000

    public private(set) var language: String
    public private(set) var isOutput: Bool
    public private(set) var lines: [TokenizedCodeLine] = []
    public private(set) var revision: UInt64 = 0
    public private(set) var circuitBrokenBlock: Bool = false
    public private(set) var lastRecomputedLineCount: Int = 0
    public private(set) var hasWide: Bool = false

    private var cachedSegments: [CodeTokenSegment] = []
    private var lastSource: String = ""

    public init(language: String, isOutput: Bool = false) {
        self.language = Self.canonicalLanguage(language)
        self.isOutput = isOutput
    }

    public var segments: [CodeTokenSegment] {
        cachedSegments
    }

    /// Recomputes only the affected lines between the previous source and `source`.
    /// Returns flattened, coalesced segments ready for rendering.
    @discardableResult
    public mutating func update(source: String) -> [CodeTokenSegment] {
        if revision > 0 && source == lastSource {
            lastRecomputedLineCount = 0
            return cachedSegments
        }
        revision &+= 1
        lastSource = source

        guard !source.isEmpty else {
            lines = []
            cachedSegments = []
            hasWide = false
            circuitBrokenBlock = false
            lastRecomputedLineCount = 0
            return []
        }

        let totalLines = Self.lineCount(source)
        if isOutput || totalLines > Self.maxBlockLines {
            circuitBrokenBlock = !isOutput && totalLines > Self.maxBlockLines
            let plain = Self.plainSegments(for: source)
            lines = []
            cachedSegments = plain.segments
            hasWide = plain.hasWide
            lastRecomputedLineCount = totalLines
            return cachedSegments
        }

        circuitBrokenBlock = false
        let rawLines = Self.splitPreservingNewlines(source)
        let profile = LanguageProfile.resolve(canonical: language)

        // Reuse unchanged prefix lines whose raw text matches exactly.
        var prefixCount = 0
        let minCount = min(lines.count, rawLines.count)
        while prefixCount < minCount && lines[prefixCount].rawLine == rawLines[prefixCount] {
            prefixCount += 1
        }

        var nextLines: [TokenizedCodeLine] = []
        nextLines.reserveCapacity(rawLines.count)
        if prefixCount > 0 {
            nextLines.append(contentsOf: lines[0..<prefixCount])
        }

        var state: CodeLexerLineState = prefixCount > 0 ? nextLines[prefixCount - 1].endState : .normal
        var recomputed = 0

        for idx in prefixCount..<rawLines.count {
            let rawLine = rawLines[idx]
            // If an existing line at the same index has identical text AND identical entry state,
            // we can reuse it directly even after an earlier middle-line edit.
            if idx < lines.count,
               lines[idx].rawLine == rawLine,
               lines[idx].entryState == state {
                let reused = lines[idx]
                nextLines.append(reused)
                state = reused.endState
                continue
            }
            let scanned = Self.scanLine(rawLine, entryState: state, profile: profile)
            nextLines.append(scanned)
            state = scanned.endState
            recomputed += 1
        }

        lines = nextLines
        lastRecomputedLineCount = recomputed

        var flattened: [CodeTokenSegment] = []
        flattened.reserveCapacity(max(8, nextLines.count * 3))
        var anyWide = false
        for line in nextLines {
            if line.hasWide { anyWide = true }
            for seg in line.segments {
                if let last = flattened.last, last.kind == seg.kind, last.isWide == seg.isWide {
                    flattened[flattened.count - 1] = CodeTokenSegment(
                        text: last.text + seg.text,
                        kind: seg.kind,
                        isWide: seg.isWide
                    )
                } else {
                    flattened.append(seg)
                }
            }
        }
        hasWide = anyWide
        cachedSegments = flattened
        return flattened
    }

    // MARK: - Stateless Convenience API

    public static func tokenize(
        _ text: String,
        language: String,
        isOutput: Bool
    ) -> (segments: [CodeTokenSegment], hasWide: Bool, circuitBroken: Bool) {
        var tokenizer = IncrementalCodeTokenizer(language: language, isOutput: isOutput)
        let segs = tokenizer.update(source: text)
        let broken = tokenizer.circuitBrokenBlock || tokenizer.lines.contains(where: \.circuitBroken)
        return (segs, tokenizer.hasWide, broken)
    }

    public static func trimmedLines(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    public static func lineCount(_ text: String) -> Int {
        text.utf8.reduce(1) { $0 + ($1 == 0x0A ? 1 : 0) }
    }

    private static let outputLanguages: Set<String> = [
        "text", "txt", "output", "console", "log", "plaintext", "plain", "stdout", "shell-session",
    ]

    private static let codeMarks: [String] = [
        "{", "}", ";", " = ", "=>", "->", "def ", "func ", "function ", "import ", "return ", "const ", "let ", "class ",
    ]

    public static func isOutputBlock(language: String, text: String) -> Bool {
        let lower = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if outputLanguages.contains(lower) { return true }
        guard lower.isEmpty else { return false }
        return !codeMarks.contains { text.contains($0) }
    }

    public static func isWide(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        return isWideScalar(scalar.value)
    }

    @inline(__always)
    public static func isWideScalar(_ value: UInt32) -> Bool {
        switch value {
        case 0x00B7,
             0x2014,
             0x2018...0x2019,
             0x201C...0x201D,
             0x2026,
             0x1100...0x11FF,
             0x2E80...0xA4CF,
             0xAC00...0xD7FF,
             0xF900...0xFAFF,
             0xFE10...0xFE1F,
             0xFE30...0xFE6F,
             0xFF01...0xFF60,
             0xFFE0...0xFFE6,
             0x20000...0x323AF:
            return true
        default:
            return false
        }
    }

    /// Resolves common fenced code-block aliases onto 18+ canonical language identifiers.
    public static func canonicalLanguage(_ raw: String) -> String {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch key {
        case "swift": return "swift"
        case "py", "python", "python3", "py3": return "python"
        case "js", "javascript", "jsx", "mjs", "cjs": return "javascript"
        case "ts", "typescript", "tsx", "mts", "cts": return "typescript"
        case "rs", "rust": return "rust"
        case "go", "golang": return "go"
        case "c", "h": return "c"
        case "cpp", "c++", "cc", "cxx", "hpp", "hh", "hxx": return "cpp"
        case "objc", "objective-c", "obj-c", "m", "mm": return "objc"
        case "java": return "java"
        case "kt", "kotlin", "kts": return "kotlin"
        case "cs", "csharp", "c#": return "csharp"
        case "rb", "ruby": return "ruby"
        case "sh", "bash", "zsh", "shell", "fish": return "shell"
        case "sql", "sqlite", "postgres", "postgresql", "mysql", "tsql": return "sql"
        case "json", "jsonc", "json5": return "json"
        case "yaml", "yml": return "yaml"
        case "toml": return "toml"
        case "html", "htm", "xml", "svg", "xhtml": return "html"
        case "css", "scss", "sass", "less": return "css"
        case "php": return "php"
        case "dart": return "dart"
        case "lua": return "lua"
        case "md", "markdown": return "markdown"
        default: return key
        }
    }

    public static let supportedLanguages: [String] = [
        "swift", "python", "javascript", "typescript", "rust", "go",
        "c", "cpp", "objc", "java", "kotlin", "csharp", "ruby",
        "shell", "sql", "json", "yaml", "toml", "html", "css",
        "php", "dart", "lua",
    ]

    // MARK: - Line Splitting & Plain Fast Path

    private static func splitPreservingNewlines(_ source: String) -> [String] {
        var result: [String] = []
        let utf8 = source.utf8
        var lineStart = utf8.startIndex
        var i = lineStart
        while i < utf8.endIndex {
            if utf8[i] == 0x0A {
                let next = utf8.index(after: i)
                result.append(String(source[lineStart..<next]))
                lineStart = next
                i = next
            } else {
                i = utf8.index(after: i)
            }
        }
        if lineStart < utf8.endIndex {
            result.append(String(source[lineStart..<utf8.endIndex]))
        }
        return result
    }

    private static func plainSegments(for text: String) -> (segments: [CodeTokenSegment], hasWide: Bool) {
        var segments: [CodeTokenSegment] = []
        var anyWide = false
        appendUTF8Span(text, from: text.startIndex, to: text.endIndex, kind: .plain, into: &segments, anyWide: &anyWide)
        return (segments, anyWide)
    }

    // MARK: - Single-Line UTF-8 Byte Scanner

    private static func scanLine(
        _ line: String,
        entryState: CodeLexerLineState,
        profile: LanguageProfile
    ) -> TokenizedCodeLine {
        // Circuit-break single line exceeding maxLineCharacters (excluding trailing newline) cleanly to plain monospace.
        let hasTrailingNewline = line.utf8.last == 0x0A
        let contentByteBudget = maxLineCharacters + (hasTrailingNewline ? 1 : 0)
        if line.utf8.count > contentByteBudget {
            let contentCharCount = line.count - (hasTrailingNewline ? 1 : 0)
            if contentCharCount > maxLineCharacters {
                let plain = plainSegments(for: line)
                return TokenizedCodeLine(
                    rawLine: line,
                    segments: plain.segments,
                    hasWide: plain.hasWide,
                    entryState: entryState,
                    endState: entryState,
                    circuitBroken: true
                )
            }
        }

        let utf8 = line.utf8
        let endIdx = utf8.endIndex
        var segments: [CodeTokenSegment] = []
        var anyWide = false
        var state = entryState

        var pos = utf8.startIndex
        var runStart = pos
        var runKind: CodeTokenKind = .plain

        @inline(__always)
        func emit(_ nextKind: CodeTokenKind, upTo nextPos: String.UTF8View.Index) {
            if nextKind != runKind {
                if runStart < pos {
                    appendUTF8Span(line, from: runStart, to: pos, kind: runKind, into: &segments, anyWide: &anyWide)
                }
                runStart = pos
                runKind = nextKind
            }
            pos = nextPos
        }

        @inline(__always)
        func byte(at idx: String.UTF8View.Index) -> UInt8 {
            utf8[idx]
        }

        @inline(__always)
        func peek(_ idx: String.UTF8View.Index, offset: Int) -> UInt8? {
            var cur = idx
            var remaining = offset
            while remaining > 0 {
                cur = utf8.index(after: cur)
                if cur >= endIdx { return nil }
                remaining -= 1
            }
            return cur < endIdx ? utf8[cur] : nil
        }

        @inline(__always)
        func advance(_ idx: String.UTF8View.Index, by count: Int) -> String.UTF8View.Index {
            var cur = idx
            var remaining = count
            while remaining > 0 && cur < endIdx {
                cur = utf8.index(after: cur)
                remaining -= 1
            }
            return cur
        }

        @inline(__always)
        func advanceScalar(_ idx: String.UTF8View.Index) -> String.UTF8View.Index {
            guard idx < endIdx else { return endIdx }
            var cur = utf8.index(after: idx)
            while cur < endIdx && (utf8[cur] & 0xC0) == 0x80 {
                cur = utf8.index(after: cur)
            }
            return cur
        }

        while pos < endIdx {
            switch state {
            case .blockComment(var depth):
                var scan = pos
                while scan < endIdx {
                    let b = byte(at: scan)
                    if profile.nestedBlockComments && b == 0x2F && peek(scan, offset: 1) == 0x2A { // /*
                        depth += 1
                        scan = advance(scan, by: 2)
                        continue
                    }
                    if b == 0x2A && peek(scan, offset: 1) == 0x2F { // */
                        scan = advance(scan, by: 2)
                        depth -= 1
                        if depth <= 0 {
                            state = .normal
                            break
                        }
                        continue
                    }
                    scan = utf8.index(after: scan)
                }
                if case .blockComment = state {
                    state = .blockComment(depth: depth)
                }
                emit(.comment, upTo: scan)

            case .htmlComment:
                var scan = pos
                while scan < endIdx {
                    if byte(at: scan) == 0x2D && peek(scan, offset: 1) == 0x2D && peek(scan, offset: 2) == 0x3E { // -->
                        scan = advance(scan, by: 3)
                        state = .normal
                        break
                    }
                    scan = utf8.index(after: scan)
                }
                emit(.comment, upTo: scan)

            case .tripleQuote(let delim):
                var scan = pos
                while scan < endIdx {
                    let b = byte(at: scan)
                    if b == 0x5C { // backslash escape
                        scan = utf8.index(after: scan)
                        if scan < endIdx { scan = advanceScalar(scan) }
                        continue
                    }
                    if b == delim && peek(scan, offset: 1) == delim && peek(scan, offset: 2) == delim {
                        scan = advance(scan, by: 3)
                        state = .normal
                        break
                    }
                    scan = utf8.index(after: scan)
                }
                emit(.string, upTo: scan)

            case .backtickString:
                var scan = pos
                while scan < endIdx {
                    let b = byte(at: scan)
                    if profile.backtickEscapes && b == 0x5C {
                        scan = utf8.index(after: scan)
                        if scan < endIdx { scan = advanceScalar(scan) }
                        continue
                    }
                    if b == 0x60 { // `
                        scan = utf8.index(after: scan)
                        state = .normal
                        break
                    }
                    scan = utf8.index(after: scan)
                }
                emit(.string, upTo: scan)

            case .normal:
                let b = byte(at: pos)

                // Line comments: //
                if profile.slashComments && b == 0x2F && peek(pos, offset: 1) == 0x2F {
                    var scan = pos
                    while scan < endIdx && byte(at: scan) != 0x0A {
                        scan = utf8.index(after: scan)
                    }
                    emit(.comment, upTo: scan)
                    continue
                }

                // Block comments: /* ... */
                if profile.blockComments && b == 0x2F && peek(pos, offset: 1) == 0x2A {
                    var depth = 1
                    var scan = advance(pos, by: 2)
                    while scan < endIdx {
                        let cb = byte(at: scan)
                        if profile.nestedBlockComments && cb == 0x2F && peek(scan, offset: 1) == 0x2A {
                            depth += 1
                            scan = advance(scan, by: 2)
                            continue
                        }
                        if cb == 0x2A && peek(scan, offset: 1) == 0x2F {
                            scan = advance(scan, by: 2)
                            depth -= 1
                            if depth <= 0 { break }
                            continue
                        }
                        scan = utf8.index(after: scan)
                    }
                    if depth > 0 {
                        state = .blockComment(depth: depth)
                    }
                    emit(.comment, upTo: scan)
                    continue
                }

                // HTML/XML comments: <!-- ... -->
                if profile.htmlComments && b == 0x3C && peek(pos, offset: 1) == 0x21 && peek(pos, offset: 2) == 0x2D && peek(pos, offset: 3) == 0x2D {
                    var scan = advance(pos, by: 4)
                    var closed = false
                    while scan < endIdx {
                        if byte(at: scan) == 0x2D && peek(scan, offset: 1) == 0x2D && peek(scan, offset: 2) == 0x3E {
                            scan = advance(scan, by: 3)
                            closed = true
                            break
                        }
                        scan = utf8.index(after: scan)
                    }
                    if !closed {
                        state = .htmlComment
                    }
                    emit(.comment, upTo: scan)
                    continue
                }

                // Hash line comments: #
                if profile.hashComments && b == 0x23 {
                    var scan = pos
                    while scan < endIdx && byte(at: scan) != 0x0A {
                        scan = utf8.index(after: scan)
                    }
                    emit(.comment, upTo: scan)
                    continue
                }

                // Dash line comments: -- (SQL, Lua)
                if profile.dashComments && b == 0x2D && peek(pos, offset: 1) == 0x2D {
                    var scan = pos
                    while scan < endIdx && byte(at: scan) != 0x0A {
                        scan = utf8.index(after: scan)
                    }
                    emit(.comment, upTo: scan)
                    continue
                }

                // Triple-quoted strings: """ or '''
                if profile.tripleQuotes && (b == 0x22 || b == 0x27) && peek(pos, offset: 1) == b && peek(pos, offset: 2) == b {
                    let delim = b
                    var scan = advance(pos, by: 3)
                    var closed = false
                    while scan < endIdx {
                        let sb = byte(at: scan)
                        if sb == 0x5C {
                            scan = utf8.index(after: scan)
                            if scan < endIdx { scan = utf8.index(after: scan) }
                            continue
                        }
                        if sb == delim && peek(scan, offset: 1) == delim && peek(scan, offset: 2) == delim {
                            scan = advance(scan, by: 3)
                            closed = true
                            break
                        }
                        scan = utf8.index(after: scan)
                    }
                    if !closed {
                        state = .tripleQuote(delimiter: delim)
                    }
                    emit(.string, upTo: scan)
                    continue
                }

                // Multi-line backtick strings (JS/TS template strings, Go raw strings)
                if profile.multilineBacktick && b == 0x60 {
                    var scan = utf8.index(after: pos)
                    var closed = false
                    while scan < endIdx {
                        let sb = byte(at: scan)
                        if profile.backtickEscapes && sb == 0x5C {
                            scan = utf8.index(after: scan)
                            if scan < endIdx { scan = utf8.index(after: scan) }
                            continue
                        }
                        if sb == 0x60 {
                            scan = utf8.index(after: scan)
                            closed = true
                            break
                        }
                        scan = utf8.index(after: scan)
                    }
                    if !closed {
                        state = .backtickString
                    }
                    emit(.string, upTo: scan)
                    continue
                }

                // Single-line quoted strings: ", ', `
                if b == 0x22 || b == 0x27 || b == 0x60 {
                    // Rust lifetimes like `'a` should not eat the rest of the line as a string.
                    if b == 0x27 && profile.rustLifetimes {
                        let afterQuote = utf8.index(after: pos)
                        if afterQuote < endIdx && isASCIIIdentStart(byte(at: afterQuote)) {
                            let second = utf8.index(after: afterQuote)
                            if second >= endIdx || byte(at: second) != 0x27 {
                                // Scan lifetime identifier as keyword/plain without unclosed string swallow.
                                var scan = afterQuote
                                while scan < endIdx && isASCIIIdentPart(byte(at: scan)) {
                                    scan = utf8.index(after: scan)
                                }
                                emit(.keyword, upTo: scan)
                                continue
                            }
                        }
                    }
                    var scan = utf8.index(after: pos)
                    while scan < endIdx {
                        let sb = byte(at: scan)
                        if sb == 0x0A { break }
                        if sb == 0x5C {
                            scan = utf8.index(after: scan)
                            if scan < endIdx && byte(at: scan) != 0x0A {
                                scan = advanceScalar(scan)
                            }
                            continue
                        }
                        if sb == b {
                            scan = utf8.index(after: scan)
                            break
                        }
                        scan = utf8.index(after: scan)
                    }
                    emit(.string, upTo: scan)
                    continue
                }

                // HTML/XML tag name right after `<` or `</`
                if profile.htmlTags && b == 0x3C {
                    var tagStart = utf8.index(after: pos)
                    if tagStart < endIdx && byte(at: tagStart) == 0x2F {
                        tagStart = utf8.index(after: tagStart)
                    }
                    if tagStart < endIdx && isASCIIAlpha(byte(at: tagStart)) {
                        emit(.plain, upTo: tagStart)
                        var tagEnd = tagStart
                        while tagEnd < endIdx {
                            let tb = byte(at: tagEnd)
                            if isASCIIIdentPart(tb) || tb == 0x2D || tb == 0x3A {
                                tagEnd = utf8.index(after: tagEnd)
                            } else {
                                break
                            }
                        }
                        emit(.keyword, upTo: tagEnd)
                        continue
                    }
                }

                // CSS hex color or preprocessor directive
                if b == 0x23 && profile.cssColors {
                    let afterHash = utf8.index(after: pos)
                    if afterHash < endIdx && isASCIIHexDigit(byte(at: afterHash)) {
                        var scan = afterHash
                        while scan < endIdx && isASCIIHexDigit(byte(at: scan)) {
                            scan = utf8.index(after: scan)
                        }
                        emit(.number, upTo: scan)
                        continue
                    }
                }

                // Numbers (decimal, hex 0x, bin 0b, oct 0o, float, underscores)
                if isASCIIDigit(b) {
                    var scan = utf8.index(after: pos)
                    if b == 0x30 && scan < endIdx {
                        let prefix = byte(at: scan)
                        if prefix == 0x78 || prefix == 0x58 { // 0x
                            scan = utf8.index(after: scan)
                            while scan < endIdx && (isASCIIHexDigit(byte(at: scan)) || byte(at: scan) == 0x5F) {
                                scan = utf8.index(after: scan)
                            }
                            emit(.number, upTo: scan)
                            continue
                        } else if prefix == 0x62 || prefix == 0x42 || prefix == 0x6F || prefix == 0x4F { // 0b / 0o
                            scan = utf8.index(after: scan)
                            while scan < endIdx && (isASCIIDigit(byte(at: scan)) || byte(at: scan) == 0x5F) {
                                scan = utf8.index(after: scan)
                            }
                            emit(.number, upTo: scan)
                            continue
                        }
                    }
                    while scan < endIdx {
                        let nb = byte(at: scan)
                        if isASCIIDigit(nb) || nb == 0x2E || nb == 0x5F {
                            scan = utf8.index(after: scan)
                        } else {
                            break
                        }
                    }
                    emit(.number, upTo: scan)
                    continue
                }

                // Identifiers / keywords / function calls
                if isASCIIIdentStart(b) || (profile.atKeywords && b == 0x40) {
                    var scan = utf8.index(after: pos)
                    while scan < endIdx {
                        let ib = byte(at: scan)
                        if isASCIIIdentPart(ib) || (profile.hyphenIdent && ib == 0x2D) {
                            scan = utf8.index(after: scan)
                        } else {
                            break
                        }
                    }
                    let word = String(line[pos..<scan])
                    let lookup = profile.caseInsensitiveKeywords ? word.lowercased() : word
                    let isCall = scan < endIdx && byte(at: scan) == 0x28 // '('
                    let nextKind: CodeTokenKind
                    if profile.keywords.contains(lookup) {
                        nextKind = .keyword
                    } else if isCall {
                        nextKind = .function
                    } else {
                        nextKind = .plain
                    }
                    emit(nextKind, upTo: scan)
                    continue
                }

                // Non-ASCII multi-byte sequence or punctuation: step one full UTF-8 character safely.
                let nextCharIdx: String.UTF8View.Index
                if b < 0x80 {
                    nextCharIdx = utf8.index(after: pos)
                } else {
                    // Advance past UTF-8 continuation bytes (10xxxxxx).
                    var scan = utf8.index(after: pos)
                    while scan < endIdx && (byte(at: scan) & 0xC0) == 0x80 {
                        scan = utf8.index(after: scan)
                    }
                    nextCharIdx = scan
                }
                emit(.plain, upTo: nextCharIdx)
            }
        }

        if runStart < endIdx {
            appendUTF8Span(line, from: runStart, to: endIdx, kind: runKind, into: &segments, anyWide: &anyWide)
        }

        return TokenizedCodeLine(
            rawLine: line,
            segments: segments,
            hasWide: anyWide,
            entryState: entryState,
            endState: state,
            circuitBroken: false
        )
    }

    private static func appendUTF8Span(
        _ source: String,
        from start: String.Index,
        to end: String.Index,
        kind: CodeTokenKind,
        into segments: inout [CodeTokenSegment],
        anyWide: inout Bool
    ) {
        guard start < end else { return }
        // Fast pure-ASCII path: if every byte in [start..<end] is < 0x80, no wide character exists.
        let utf8 = source.utf8
        var hasNonASCII = false
        var scan = start
        while scan < end {
            if utf8[scan] >= 0x80 {
                hasNonASCII = true
                break
            }
            scan = utf8.index(after: scan)
        }

        if !hasNonASCII {
            let piece = String(source[start..<end])
            if let last = segments.last, last.kind == kind, !last.isWide {
                segments[segments.count - 1] = CodeTokenSegment(text: last.text + piece, kind: kind, isWide: false)
            } else {
                segments.append(CodeTokenSegment(text: piece, kind: kind, isWide: false))
            }
            return
        }

        let slice = source[start..<end]
        guard let first = slice.first else { return }
        var currentWide = isWide(first)
        if currentWide { anyWide = true }
        var segStart = slice.startIndex

        func flush(upTo segEnd: String.Index) {
            guard segStart < segEnd else { return }
            let piece = String(slice[segStart..<segEnd])
            if let last = segments.last, last.kind == kind, last.isWide == currentWide {
                segments[segments.count - 1] = CodeTokenSegment(text: last.text + piece, kind: kind, isWide: currentWide)
            } else {
                segments.append(CodeTokenSegment(text: piece, kind: kind, isWide: currentWide))
            }
        }

        for idx in slice.indices.dropFirst() {
            let nextWide = isWide(slice[idx])
            if nextWide { anyWide = true }
            if nextWide != currentWide {
                flush(upTo: idx)
                segStart = idx
                currentWide = nextWide
            }
        }
        flush(upTo: slice.endIndex)
    }

    // MARK: - ASCII Predicates

    @inline(__always)
    private static func isASCIIDigit(_ b: UInt8) -> Bool {
        b >= 0x30 && b <= 0x39
    }

    @inline(__always)
    private static func isASCIIHexDigit(_ b: UInt8) -> Bool {
        (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x46) || (b >= 0x61 && b <= 0x66)
    }

    @inline(__always)
    private static func isASCIIAlpha(_ b: UInt8) -> Bool {
        (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
    }

    @inline(__always)
    private static func isASCIIIdentStart(_ b: UInt8) -> Bool {
        isASCIIAlpha(b) || b == 0x5F || b == 0x24
    }

    @inline(__always)
    private static func isASCIIIdentPart(_ b: UInt8) -> Bool {
        isASCIIAlpha(b) || isASCIIDigit(b) || b == 0x5F || b == 0x24
    }
}

// MARK: - Language Profiles (18+ Languages)

private struct LanguageProfile: Sendable {
    let keywords: Set<String>
    let slashComments: Bool
    let blockComments: Bool
    let nestedBlockComments: Bool
    let hashComments: Bool
    let dashComments: Bool
    let htmlComments: Bool
    let htmlTags: Bool
    let tripleQuotes: Bool
    let multilineBacktick: Bool
    let backtickEscapes: Bool
    let caseInsensitiveKeywords: Bool
    let rustLifetimes: Bool
    let atKeywords: Bool
    let cssColors: Bool
    let hyphenIdent: Bool

    static func resolve(canonical: String) -> LanguageProfile {
        switch canonical {
        case "swift": return swift
        case "python": return python
        case "javascript": return javascript
        case "typescript": return typescript
        case "rust": return rust
        case "go": return go
        case "c": return cLang
        case "cpp": return cpp
        case "objc": return objc
        case "java": return java
        case "kotlin": return kotlin
        case "csharp": return csharp
        case "ruby": return ruby
        case "shell": return shell
        case "sql": return sql
        case "json": return json
        case "yaml": return yaml
        case "toml": return toml
        case "html": return html
        case "css": return css
        case "php": return php
        case "dart": return dart
        case "lua": return lua
        default: return generic
        }
    }

    private static let swift = LanguageProfile(
        keywords: [
            "actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch", "class",
            "continue", "default", "defer", "deinit", "do", "else", "enum", "extension", "fallthrough",
            "false", "fileprivate", "final", "for", "func", "get", "guard", "if", "import", "in", "indirect",
            "init", "inout", "internal", "is", "isolated", "lazy", "let", "mutating", "nil", "nonisolated",
            "nonmutating", "open", "operator", "optional", "override", "private", "protocol", "public",
            "repeat", "required", "rethrows", "return", "self", "Self", "set", "some", "static", "struct",
            "subscript", "super", "switch", "throw", "throws", "true", "try", "typealias", "unowned", "var",
            "weak", "where", "while", "@MainActor", "@Observable", "@State", "@Binding", "@Sendable", "@escaping",
        ],
        slashComments: true, blockComments: true, nestedBlockComments: true, hashComments: false,
        dashComments: false, htmlComments: false, htmlTags: false, tripleQuotes: true,
        multilineBacktick: false, backtickEscapes: false, caseInsensitiveKeywords: false,
        rustLifetimes: false, atKeywords: true, cssColors: false, hyphenIdent: false
    )

    private static let python = LanguageProfile(
        keywords: [
            "False", "None", "True", "and", "as", "assert", "async", "await", "break", "case", "class",
            "continue", "def", "del", "elif", "else", "except", "finally", "for", "from", "global", "if",
            "import", "in", "is", "lambda", "match", "nonlocal", "not", "or", "pass", "raise", "return",
            "self", "try", "type", "while", "with", "yield",
        ],
        slashComments: false, blockComments: false, nestedBlockComments: false, hashComments: true,
        dashComments: false, htmlComments: false, htmlTags: false, tripleQuotes: true,
        multilineBacktick: false, backtickEscapes: false, caseInsensitiveKeywords: false,
        rustLifetimes: false, atKeywords: true, cssColors: false, hyphenIdent: false
    )

    private static let jsBaseKeywords: Set<String> = [
        "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default",
        "delete", "do", "else", "export", "extends", "false", "finally", "for", "from", "function", "get",
        "if", "import", "in", "instanceof", "let", "new", "null", "of", "return", "set", "static", "super",
        "switch", "this", "throw", "true", "try", "typeof", "undefined", "var", "void", "while", "with", "yield",
    ]

    private static let javascript = LanguageProfile(
        keywords: jsBaseKeywords,
        slashComments: true, blockComments: true, nestedBlockComments: false, hashComments: false,
        dashComments: false, htmlComments: false, htmlTags: false, tripleQuotes: false,
        multilineBacktick: true, backtickEscapes: true, caseInsensitiveKeywords: false,
        rustLifetimes: false, atKeywords: false, cssColors: false, hyphenIdent: false
    )

    private static let typescript = LanguageProfile(
        keywords: jsBaseKeywords.union([
            "abstract", "any", "as", "asserts", "bigint", "boolean", "declare", "enum", "implements",
            "infer", "interface", "is", "keyof", "module", "namespace", "never", "number", "object",
            "override", "private", "protected", "public", "readonly", "satisfies", "string", "symbol",
            "type", "unique", "unknown",
        ]),
        slashComments: true, blockComments: true, nestedBlockComments: false, hashComments: false,
        dashComments: false, htmlComments: false, htmlTags: false, tripleQuotes: false,
        multilineBacktick: true, backtickEscapes: true, caseInsensitiveKeywords: false,
        rustLifetimes: false, atKeywords: false, cssColors: false, hyphenIdent: false
    )

    private static let rust = LanguageProfile(
        keywords: [
            "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern",
            "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub",
            "ref", "return", "self", "Self", "static", "struct", "super", "trait", "true", "type", "unsafe",
            "use", "where", "while", "Option", "Result", "Some", "None", "Ok", "Err", "String", "Vec", "bool",
            "u8", "u16", "u32", "u64", "usize", "i8", "i16", "i32", "i64", "isize", "f32", "f64",
        ],
        slashComments: true, blockComments: true, nestedBlockComments: true, hashComments: false,
        dashComments: false, htmlComments: false, htmlTags: false, tripleQuotes: false,
        multilineBacktick: false, backtickEscapes: false, caseInsensitiveKeywords: false,
        rustLifetimes: true, atKeywords: false, cssColors: false, hyphenIdent: false
    )

    private static let go = LanguageProfile(
        keywords: [
            "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for",
            "func", "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select",
            "struct", "switch", "type", "var", "true", "false", "nil", "iota", "bool", "byte", "error",
            "int", "int32", "int64", "uint", "uint32", "uint64", "float32", "float64", "rune", "string", "any",
        ],
        slashComments: true, blockComments: true, nestedBlockComments: false, hashComments: false,
        dashComments: false, htmlComments: false, htmlTags: false, tripleQuotes: false,
        multilineBacktick: true, backtickEscapes: false, caseInsensitiveKeywords: false,
        rustLifetimes: false, atKeywords: false, cssColors: false, hyphenIdent: false
    )

    private static let cKeywords: Set<String> = [
        "auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum",
        "extern", "float", "for", "goto", "if", "inline", "int", "long", "register", "restrict", "return",
        "short", "signed", "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void",
        "volatile", "while", "bool", "true", "false", "NULL", "size_t", "uint8_t", "uint32_t", "uint64_t",
        "int32_t", "int64_t",
    ]

    private static let cLang = LanguageProfile(
        keywords: cKeywords,
        slashComments: true, blockComments: true, nestedBlockComments: false, hashComments: false,
        dashComments: false, htmlComments: false, htmlTags: false, tripleQuotes: false,
        multilineBacktick: false, backtickEscapes: false, caseInsensitiveKeywords: false,
        rustLifetimes: false, atKeywords: false, cssColors: false, hyphenIdent: false
    )

    private static let cpp = LanguageProfile(
        keywords: cKeywords.union([
            "alignas", "alignof", "class", "co_await", "co_return", "co_yield", "concept", "constexpr",
            "consteval", "delete", "explicit", "export", "final", "friend", "module", "mutable", "namespace",
            "new", "noexcept", "nullptr", "operator", "override", "private", "protected", "public", "requires",
            "static_cast", "dynamic_cast", "reinterpret_cast", "template", "this", "throw", "try", "catch",
            "typename", "using", "virtual", "std", "string", "vector",
        ]),
        slashComments: true, blockComments: true, nestedBlockComments: false, hashComments: false,
        dashComments: false, htmlComments: false, htmlTags: false, tripleQuotes: false,
        multilineBacktick: false, backtickEscapes: false, caseInsensitiveKeywords: false,
        rustLifetimes: false, atKeywords: false, cssColors: false, hyphenIdent: false
    )

    private static let objc = LanguageProfile(
        keywords: cKeywords.union([
            "id", "Class", "SEL", "IMP", "BOOL", "YES", "NO", "nil", "Nil", "self", "super", "instancetype",
            "nonatomic", "atomic", "strong", "weak", "copy", "assign", "readonly", "readwrite", "nullable",
            "nonnull", "@interface", "@implementation", "@end", "@property", "@synthesize", "@protocol",
            "@selector", "@autoreleasepool", "@class", "@try", "@catch", "@finally", "@throw",
        ]),
        slashComments: true, blockComments: true, nestedBlockComments: false, hashComments: false,
        dashComments: false, htmlComments: false, htmlTags: false, tripleQuotes: false,
        multilineBacktick: false, backtickEscapes: false, caseInsensitiveKeywords: false,
        rustLifetimes: false, atKeywords: true, cssColors: false, hyphenIdent: false
    )

    private static let java = LanguageProfile(
        keywords: [
            "abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class", "const",
            "continue", "default", "do", "double", "else", "enum", "extends", "false", "final", "finally",
            "float", "for", "if", "implements", "import", "instanceof", "int", "interface", "long", "native",
            "new", "null", "package", "private", "protected", "public", "record", "return", "sealed", "short",
            "static", "super", "switch", "synchronized", "this", "throw", "throws", "transient", "true", "try",
            "var", "void", "volatile", "while", "yield", "String",
        ],
        slashComments: true, blockComments: true, nestedBlockComments: false, hashComments: false,
        dashComments: false, htmlComments: false, htmlTags: false, tripleQuotes: true,
        multilineBacktick: false, backtickEscapes: false, caseInsensitiveKeywords: false,
        rustLifetimes: false, atKeywords: true, cssColors: false, hyphenIdent: false
    )

    private static let kotlin = LanguageProfile(
        keywords: [
            "abstract", "actual", "annotation", "as", "break", "by", "catch", "class", "companion", "const",
            "constructor", "continue", "crossinline", "data", "do", "else", "enum", "expect", "external",
            "false", "final", "finally", "for", "fun", "if", "import", "in", "infix", "init", "inline",
            "inner", "interface", "internal", "is", "lateinit", "noinline", "null", "object", "open", "operator",
            "out", "override", "package", "private", "protected", "public", "reified", "return", "sealed",
            "super", "suspend", "tailrec", "this", "throw", "true", "try", "typealias", "val", "var", "vararg",
            "when", "where", "while",
        ],
        slashComments: true, blockComments: true, nestedBlockComments: true, hashComments: false,
        dashComments: false, htmlComments: false, htmlTags: false, tripleQuotes: true,
        multilineBacktick: false, backtickEscapes: false, caseInsensitiveKeywords: false,
        rustLifetimes: false, atKeywords: true, cssColors: false, hyphenIdent: false
    )

    private static let csharp = LanguageProfile(
        keywords: [
            "abstract", "as", "async", "await", "base", "bool", "break", "byte", "case", "catch", "char",
            "checked", "class", "const", "continue", "decimal", "default", "delegate", "do", "double", "else",
            "enum", "event", "explicit", "extern", "false", "finally", "fixed", "float", "for", "foreach",
            "goto", "if", "implicit", "in", "int", "interface", "internal", "is", "lock", "long", "namespace",
            "new", "null", "object", "operator", "out", "override", "params", "partial", "private", "protected",
            "public", "readonly", "record", "ref", "return", "sbyte", "sealed", "short", "sizeof", "static",
            "string", "struct", "switch", "this", "throw", "true", "try", "typeof", "uint", "ulong", "unchecked",
            "unsafe", "ushort", "using", "var", "virtual", "void", "volatile", "while", "yield",
        ],
        slashComments: true, blockComments: true, nestedBlockComments: false, hashComments: false,
        dashComments: false, htmlComments: false, htmlTags: false, tripleQuotes: true,
        multilineBacktick: false, backtickEscapes: false, caseInsensitiveKeywords: false,
        rustLifetimes: false, atKeywords: false, cssColors: false, hyphenIdent: false
    )

    private static let ruby = LanguageProfile(
        keywords: [
            "BEGIN", "END", "alias", "and", "begin", "break", "case", "class", "def", "defined?", "do",
            "else", "elsif", "end", "ensure", "false", "for", "if", "in", "module", "next", "nil", "not",
            "or", "redo", "rescue", "retry", "return", "self", "super", "then", "true", "undef", "unless",
            "until", "when", "while", "yield", "require", "require_relative", "attr_reader", "attr_accessor",
        ],
        slashComments: false, blockComments: false, nestedBlockComments: false, hashComments: true,
        dashComments: false, htmlComments: false, htmlTags: false, tripleQuotes: false,
        multilineBacktick: false, backtickEscapes: false, caseInsensitiveKeywords: false,
        rustLifetimes: false, atKeywords: false, cssColors: false, hyphenIdent: false
    )

    private static let shell = LanguageProfile(
        keywords: [
            "if", "then", "else", "elif", "fi", "case", "esac", "for", "select", "while", "until", "do",
            "done", "in", "function", "time", "local", "export", "readonly", "declare", "typeset", "unset",
            "return", "exit", "break", "continue", "shift", "source", "set", "eval", "exec", "trap", "true", "false",
        ],
        slashComments: false, blockComments: false, nestedBlockComments: false, hashComments: true,
        dashComments: false, htmlComments: false, htmlTags: false, tripleQuotes: false,
        multilineBacktick: false, backtickEscapes: false, caseInsensitiveKeywords: false,
        rustLifetimes: false, atKeywords: false, cssColors: false, hyphenIdent: false
    )

    private static let sql = LanguageProfile(
        keywords: [
            "select", "from", "where", "insert", "into", "values", "update", "set", "delete", "create",
            "table", "index", "view", "drop", "alter", "add", "column", "join", "inner", "left", "right",
            "outer", "full", "cross", "on", "as", "and", "or", "not", "in", "is", "null", "true", "false",
            "like", "between", "exists", "case", "when", "then", "else", "end", "group", "by", "having",
            "order", "asc", "desc", "limit", "offset", "distinct", "union", "all", "with", "primary", "key",
            "foreign", "references", "unique", "default", "begin", "commit", "rollback", "transaction", "pragma",
            "integer", "text", "real", "blob", "varchar", "boolean", "timestamp",
        ],
        slashComments: false, blockComments: true, nestedBlockComments: false, hashComments: false,
        dashComments: true, htmlComments: false, htmlTags: false, tripleQuotes: false,
        multilineBacktick: false, backtickEscapes: false, caseInsensitiveKeywords: true,
        rustLifetimes: false, atKeywords: false, cssColors: false, hyphenIdent: false
    )

    private static let json = LanguageProfile(
        keywords: ["true", "false", "null"],
        slashComments: true, blockComments: true, nestedBlockComments: false, hashComments: false,
        dashComments: false, htmlComments: false, htmlTags: false, tripleQuotes: false,
        multilineBacktick: false, backtickEscapes: false, caseInsensitiveKeywords: false,
        rustLifetimes: false, atKeywords: false, cssColors: false, hyphenIdent: false
    )

    private static let yaml = LanguageProfile(
        keywords: ["true", "false", "null", "yes", "no", "on", "off"],
        slashComments: false, blockComments: false, nestedBlockComments: false, hashComments: true,
        dashComments: false, htmlComments: false, htmlTags: false, tripleQuotes: false,
        multilineBacktick: false, backtickEscapes: false, caseInsensitiveKeywords: true,
        rustLifetimes: false, atKeywords: false, cssColors: false, hyphenIdent: false
    )

    private static let toml = LanguageProfile(
        keywords: ["true", "false"],
        slashComments: false, blockComments: false, nestedBlockComments: false, hashComments: true,
        dashComments: false, htmlComments: false, htmlTags: false, tripleQuotes: true,
        multilineBacktick: false, backtickEscapes: false, caseInsensitiveKeywords: false,
        rustLifetimes: false, atKeywords: false, cssColors: false, hyphenIdent: false
    )

    private static let html = LanguageProfile(
        keywords: ["doctype"],
        slashComments: false, blockComments: false, nestedBlockComments: false, hashComments: false,
        dashComments: false, htmlComments: true, htmlTags: true, tripleQuotes: false,
        multilineBacktick: false, backtickEscapes: false, caseInsensitiveKeywords: true,
        rustLifetimes: false, atKeywords: false, cssColors: false, hyphenIdent: false
    )

    private static let css = LanguageProfile(
        keywords: [
            "important", "inherit", "initial", "unset", "none", "auto", "block", "inline", "flex", "grid",
            "absolute", "relative", "fixed", "sticky", "solid", "dashed", "dotted", "hidden", "visible",
            "center", "left", "right", "top", "bottom", "@media", "@keyframes", "@import", "@supports",
            "@layer", "@font-face",
        ],
        slashComments: true, blockComments: true, nestedBlockComments: false, hashComments: false,
        dashComments: false, htmlComments: false, htmlTags: false, tripleQuotes: false,
        multilineBacktick: false, backtickEscapes: false, caseInsensitiveKeywords: true,
        rustLifetimes: false, atKeywords: true, cssColors: true, hyphenIdent: true
    )

    private static let php = LanguageProfile(
        keywords: [
            "abstract", "and", "array", "as", "break", "callable", "case", "catch", "class", "clone",
            "const", "continue", "declare", "default", "do", "echo", "else", "elseif", "empty", "enum",
            "extends", "false", "final", "finally", "fn", "for", "foreach", "function", "global", "if",
            "implements", "include", "instanceof", "interface", "isset", "match", "namespace", "new",
            "null", "or", "private", "protected", "public", "readonly", "require", "return", "static",
            "switch", "throw", "trait", "true", "try", "unset", "use", "var", "while", "yield",
        ],
        slashComments: true, blockComments: true, nestedBlockComments: false, hashComments: true,
        dashComments: false, htmlComments: false, htmlTags: false, tripleQuotes: false,
        multilineBacktick: false, backtickEscapes: false, caseInsensitiveKeywords: false,
        rustLifetimes: false, atKeywords: false, cssColors: false, hyphenIdent: false
    )

    private static let dart = LanguageProfile(
        keywords: [
            "abstract", "as", "assert", "async", "await", "base", "break", "case", "catch", "class",
            "const", "continue", "covariant", "default", "deferred", "do", "dynamic", "else", "enum",
            "export", "extends", "extension", "external", "factory", "false", "final", "finally", "for",
            "get", "hide", "if", "implements", "import", "in", "interface", "is", "late", "library",
            "mixin", "new", "null", "on", "operator", "part", "required", "rethrow", "return", "sealed",
            "set", "show", "static", "super", "switch", "sync", "this", "throw", "true", "try", "typedef",
            "var", "void", "when", "while", "with", "yield",
        ],
        slashComments: true, blockComments: true, nestedBlockComments: false, hashComments: false,
        dashComments: false, htmlComments: false, htmlTags: false, tripleQuotes: true,
        multilineBacktick: false, backtickEscapes: false, caseInsensitiveKeywords: false,
        rustLifetimes: false, atKeywords: true, cssColors: false, hyphenIdent: false
    )

    private static let lua = LanguageProfile(
        keywords: [
            "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if",
            "in", "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while",
        ],
        slashComments: false, blockComments: false, nestedBlockComments: false, hashComments: false,
        dashComments: true, htmlComments: false, htmlTags: false, tripleQuotes: false,
        multilineBacktick: false, backtickEscapes: false, caseInsensitiveKeywords: false,
        rustLifetimes: false, atKeywords: false, cssColors: false, hyphenIdent: false
    )

    private static let generic = LanguageProfile(
        keywords: [
            "func", "let", "var", "if", "else", "for", "while", "return", "import", "struct", "class",
            "enum", "case", "switch", "def", "from", "as", "in", "not", "and", "or", "is", "None", "True",
            "False", "lambda", "with", "try", "except", "const", "function", "async", "await", "new",
            "this", "self", "true", "false", "null", "nil", "export", "default", "public", "private",
            "static", "void", "int", "string", "bool", "fn", "pub", "mut", "impl", "use", "match",
        ],
        slashComments: true, blockComments: true, nestedBlockComments: false, hashComments: false,
        dashComments: false, htmlComments: false, htmlTags: false, tripleQuotes: true,
        multilineBacktick: false, backtickEscapes: false, caseInsensitiveKeywords: false,
        rustLifetimes: false, atKeywords: false, cssColors: false, hyphenIdent: false
    )
}
