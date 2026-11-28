// ProseStreamRepair.swift
// Clio Live-Tail Streaming Markdown Repair & Water-Filling Table Column Solver
// License: GPL-3.0-or-later

import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif

// MARK: - 1. Live-Tail Streaming Markdown Repair

public struct ProseRepairOutput: Equatable, Sendable {
    public let repaired: String
    public let withheldSuffix: String
    public let appliedClosers: [String]

    public init(repaired: String, withheldSuffix: String, appliedClosers: [String]) {
        self.repaired = repaired
        self.withheldSuffix = withheldSuffix
        self.appliedClosers = appliedClosers
    }
}

public enum ProseStreamRepairCore {
    /// Repairs incomplete trailing Markdown syntax on an actively streaming tail block (`StreamBlocks` live tail).
    /// Handles currency `$100` guards, fenced code blocks (holding back un-newlined opening fence headers and
    /// excluding inner `$$` from display math parity), incomplete GFM table header/delimiter holding,
    /// incomplete links/images, `***` bold-italic & cross-nested emphasis unwinding, and dangling block markers.
    public static func repair(_ raw: String) -> ProseRepairOutput {
        guard !raw.isEmpty else {
            return ProseRepairOutput(repaired: "", withheldSuffix: "", appliedClosers: [])
        }

        let lines = raw.components(separatedBy: "\n")
        var inFence = false
        var fenceChar: Character = "`"
        var fenceLen = 0

        for line in lines.dropLast() {
            let trimmed = line.drop(while: { $0 == " " })
            let indent = line.count - trimmed.count
            guard indent <= 3 else { continue }
            if !inFence {
                if let fc = trimmed.first, (fc == "`" || fc == "~") {
                    let fl = trimmed.prefix(while: { $0 == fc }).count
                    let rest = trimmed.dropFirst(fl)
                    if fl >= 3 && (fc != "`" || !rest.contains("`")) {
                        inFence = true
                        fenceChar = fc
                        fenceLen = fl
                    }
                }
            } else {
                let fl = trimmed.prefix(while: { $0 == fenceChar }).count
                let rest = trimmed.dropFirst(fl).trimmingCharacters(in: .whitespaces)
                if fl >= fenceLen && rest.isEmpty {
                    inFence = false
                    fenceLen = 0
                }
            }
        }

        let lastLine = lines.last ?? ""
        let trimmedLast = lastLine.drop(while: { $0 == " " })
        let indentLast = lastLine.count - trimmedLast.count
        var withheld = ""
        var working = raw

        if !inFence {
            let strippedStr = String(trimmedLast)
            let strippedTrimmed = strippedStr.trimmingCharacters(in: .whitespaces)

            // 1a. Partial or un-newlined opening fence header (` ``` `, ` ```swi `, `~`, `~~`, `~~~py`):
            // hold back the incomplete opening fence line so raw backticks/info strings never flash for 1-2 frames.
            if indentLast <= 3 && (strippedStr == "`" || strippedStr == "``" || strippedStr == "~" || strippedStr == "~~") {
                let prefix = lines.dropLast().joined(separator: "\n")
                withheld = (lines.count > 1 ? "\n" : "") + lastLine
                working = prefix
            } else if indentLast <= 3, let fc = trimmedLast.first, (fc == "`" || fc == "~") {
                let fl = trimmedLast.prefix(while: { $0 == fc }).count
                let rest = trimmedLast.dropFirst(fl)
                if fl >= 3 && (fc != "`" || !rest.contains("`")) {
                    let prefix = lines.dropLast().joined(separator: "\n")
                    let held = (lines.count > 1 ? "\n" : "") + lastLine
                    return ProseRepairOutput(repaired: prefix, withheldSuffix: held, appliedClosers: [])
                }
            } else if let tableHold = findUnfinishedTableHold(lines: lines) {
                // 1b. Hold back unfinished GFM table header row (before delimiter commits) or incomplete delimiter/body row.
                working = tableHold.prefix
                withheld = tableHold.withheld
                if working.isEmpty {
                    return ProseRepairOutput(repaired: "", withheldSuffix: withheld, appliedClosers: [])
                }
            } else if isDanglingBareBlockMarker(strippedTrimmed) {
                // 1c. Lone structural marker at the very end (`#`, `##`, `-`, `*`, `+`, `1.`, `>`, `|`).
                let prefix = lines.dropLast().joined(separator: "\n")
                withheld = (lines.count > 1 ? "\n" : "") + lastLine
                working = prefix
                if working.isEmpty {
                    return ProseRepairOutput(repaired: "", withheldSuffix: withheld, appliedClosers: [])
                }
            }
        } else {
            let fl = trimmedLast.prefix(while: { $0 == fenceChar }).count
            let rest = trimmedLast.dropFirst(fl).trimmingCharacters(in: .whitespaces)
            if !(indentLast <= 3 && fl >= fenceLen && rest.isEmpty) {
                let closer = (working.hasSuffix("\n") ? "" : "\n") + String(repeating: String(fenceChar), count: fenceLen)
                return ProseRepairOutput(repaired: working + closer, withheldSuffix: "", appliedClosers: [closer])
            }
        }

        let chars = Array(working)
        let n = chars.count
        var i = 0
        var lineStart = true
        var inBlockFence = false
        var bfChar: Character = "`"
        var bfLen = 0

        var inInlineCode = false
        var inlineTicks = 0
        var inlineCodeOpenIdx: Int?
        var inDisplayMath = false
        var inInlineMath = false
        var openBracketIdx: Int?
        var linkOpenParenIdx: Int?
        var linkParenDepth = 0
        var emphStack: [(Character, Int)] = []

        while i < n {
            if lineStart {
                var j = i
                while j < n && chars[j] == " " && (j - i) < 4 { j += 1 }
                if (j - i) <= 3 && j < n && (chars[j] == "`" || chars[j] == "~") {
                    let fc = chars[j]
                    var k = j
                    while k < n && chars[k] == fc { k += 1 }
                    let fl = k - j
                    var lineEnd = k
                    while lineEnd < n && chars[lineEnd] != "\n" { lineEnd += 1 }
                    let restSlice = chars[k..<lineEnd]
                    if !inBlockFence {
                        if fl >= 3 && (fc != "`" || !restSlice.contains("`")) {
                            inBlockFence = true
                            bfChar = fc
                            bfLen = fl
                            i = lineEnd < n ? lineEnd + 1 : n
                            lineStart = true
                            continue
                        }
                    } else {
                        let restTrimmed = String(restSlice).trimmingCharacters(in: .whitespaces)
                        if fc == bfChar && fl >= bfLen && restTrimmed.isEmpty {
                            inBlockFence = false
                            bfLen = 0
                            i = lineEnd < n ? lineEnd + 1 : n
                            lineStart = true
                            continue
                        }
                    }
                }
            }

            if inBlockFence {
                while i < n && chars[i] != "\n" { i += 1 }
                if i < n { i += 1; lineStart = true }
                continue
            }

            let ch = chars[i]
            lineStart = (ch == "\n")

            if ch == "\n" && (i + 1) < n && chars[i + 1] == "\n" && !inInlineCode && !inDisplayMath {
                inInlineMath = false
                openBracketIdx = nil
                linkOpenParenIdx = nil
                linkParenDepth = 0
                emphStack.removeAll()
                i += 1
                continue
            }

            if ch == "\\" && !inInlineCode {
                i += 2
                continue
            }

            if ch == "`" && !inDisplayMath && !inInlineMath && linkOpenParenIdx == nil {
                var k = i
                while k < n && chars[k] == "`" { k += 1 }
                let run = k - i
                if !inInlineCode {
                    inInlineCode = true
                    inlineTicks = run
                    inlineCodeOpenIdx = i
                } else if run == inlineTicks {
                    inInlineCode = false
                    inlineTicks = 0
                    inlineCodeOpenIdx = nil
                }
                i = k
                continue
            }

            if inInlineCode { i += 1; continue }

            if ch == "$" && (i + 1) < n && chars[i + 1] == "$" && !inInlineMath && linkOpenParenIdx == nil {
                inDisplayMath.toggle()
                i += 2
                continue
            }

            if inDisplayMath { i += 1; continue }

            if ch == "$" && linkOpenParenIdx == nil {
                if !inInlineMath {
                    let prev: Character? = i > 0 ? chars[i - 1] : nil
                    if isValidMathOpenPrev(prev) && !isCurrencyOrNonMathAfterDollar(chars, idxAfterDollar: i + 1) {
                        inInlineMath = true
                    }
                } else if isValidMathClose(chars, closeIdx: i) {
                    inInlineMath = false
                }
                i += 1
                continue
            }

            if inInlineMath {
                if ch == "\n" { inInlineMath = false }
                i += 1
                continue
            }

            // Incomplete links & images: `[label](url)` / `![alt](url)` (tracks nested `()` inside URLs)
            if ch == "[" && linkOpenParenIdx == nil {
                openBracketIdx = i
                i += 1
                continue
            }
            if ch == "]" && openBracketIdx != nil && linkOpenParenIdx == nil {
                if (i + 1) < n && chars[i + 1] == "(" {
                    linkOpenParenIdx = i + 1
                    linkParenDepth = 0
                    i += 2
                    continue
                } else {
                    openBracketIdx = nil
                    i += 1
                    continue
                }
            }
            if ch == "(" && linkOpenParenIdx != nil {
                linkParenDepth += 1
                i += 1
                continue
            }
            if ch == ")" && linkOpenParenIdx != nil {
                if linkParenDepth > 0 {
                    linkParenDepth -= 1
                } else {
                    openBracketIdx = nil
                    linkOpenParenIdx = nil
                }
                i += 1
                continue
            }
            if linkOpenParenIdx != nil {
                // Inside URL `(https://example.com/a_b_c)`: skip emphasis/math scanning!
                if ch == "\n" {
                    openBracketIdx = nil
                    linkOpenParenIdx = nil
                    linkParenDepth = 0
                }
                i += 1
                continue
            }

            if ch == "*" || ch == "_" || ch == "~" {
                var k = i
                while k < n && chars[k] == ch { k += 1 }
                let run = k - i
                let prev: Character? = i > 0 ? chars[i - 1] : nil
                let next: Character? = k < n ? chars[k] : nil

                if ch == "~" && run != 2 { i = k; continue }
                if ch == "_", let p = prev, let nx = next, isASCIIWord(p) && isASCIIWord(nx) { i = k; continue }

                if ch == "*" && run == 1 && next == " " {
                    var ls = i
                    while ls > 0 && chars[ls - 1] != "\n" { ls -= 1 }
                    if chars[ls..<i].allSatisfy({ $0 == " " }) { i = k; continue }
                }

                let canOpen = next != nil && !(next!.isWhitespace)
                let canClose = prev != nil && !(prev!.isWhitespace)
                var remaining = run

                if canClose && !emphStack.isEmpty {
                    while remaining > 0 {
                        if let exactIdx = emphStack.lastIndex(where: { $0.0 == ch && $0.1 == remaining }) {
                            emphStack.removeSubrange(exactIdx..<emphStack.count)
                            remaining = 0
                            break
                        }
                        if ch == "*" || ch == "_", let fallbackIdx = emphStack.lastIndex(where: { $0.0 == ch }) {
                            if fallbackIdx + 1 < emphStack.count {
                                emphStack.removeSubrange((fallbackIdx + 1)..<emphStack.count)
                            }
                            let sCnt = emphStack[fallbackIdx].1
                            let consume = min(sCnt, remaining)
                            remaining -= consume
                            if sCnt > consume {
                                emphStack[fallbackIdx] = (ch, sCnt - consume)
                            } else {
                                emphStack.removeLast()
                            }
                        } else {
                            break
                        }
                    }
                }

                if remaining > 0 && canOpen {
                    if ch == "*" || ch == "_" {
                        emphStack.append((ch, min(remaining, 3)))
                    } else if ch == "~" && remaining == 2 {
                        emphStack.append(("~", 2))
                    }
                } else if remaining > 0 && k == n && !canClose {
                    withheld = String(repeating: String(ch), count: remaining) + withheld
                    working = String(chars[0..<i])
                    break
                }
                i = k
                continue
            }
            i += 1
        }

        var repaired = working
        var applied: [String] = []
        if inInlineCode {
            let closer = String(repeating: "`", count: inlineTicks)
            if let openIdx = inlineCodeOpenIdx, openIdx + inlineTicks == chars.count {
                // Bare trailing backtick(s) with no code body yet: withhold instead of forming empty `` delimiter.
                repaired = String(chars[0..<openIdx])
                withheld = closer + withheld
            } else {
                repaired += closer
                applied.append(closer)
            }
            // Still close any outer emphasis markers (`**code \`ls` -> `**code \`ls\`**`).
            for (sCh, sCnt) in emphStack.reversed() {
                let emphCloser = String(repeating: String(sCh), count: sCnt)
                repaired += emphCloser
                applied.append(emphCloser)
            }
        } else if inDisplayMath {
            if repaired.hasSuffix("$$") {
                repaired.removeLast(2)
                withheld = "$$" + withheld
            } else {
                repaired += "$$"
                applied.append("$$")
            }
        } else if inInlineMath {
            repaired += "$"
            applied.append("$")
        } else {
            // Repair incomplete link or image at tail before closing any outer emphasis.
            if let bracketIdx = openBracketIdx, bracketIdx < chars.count {
                let isImage = bracketIdx > 0 && chars[bracketIdx - 1] == "!"
                if isImage {
                    let cutStart = bracketIdx - 1
                    let heldImage = String(chars[cutStart..<chars.count])
                    repaired = String(chars[0..<cutStart])
                    withheld = heldImage + withheld
                } else if let parenIdx = linkOpenParenIdx, parenIdx < chars.count {
                    // `[label](https://exa` -> `[label](#)` so link text renders steadily without raw URL flash.
                    let heldURL = String(chars[(parenIdx + 1)..<chars.count])
                    repaired = String(chars[0..<parenIdx]) + "(#)"
                    withheld = heldURL + withheld
                    applied.append("#)")
                } else {
                    // Lone `[label...` -> render `label...` cleanly without raw leading `[`.
                    repaired = String(chars[0..<bracketIdx]) + String(chars[(bracketIdx + 1)..<chars.count])
                    withheld = "[" + withheld
                }
            }

            for (sCh, sCnt) in emphStack.reversed() {
                let closer = String(repeating: String(sCh), count: sCnt)
                repaired += closer
                applied.append(closer)
            }
        }
        return ProseRepairOutput(repaired: repaired, withheldSuffix: withheld, appliedClosers: applied)
    }

    // MARK: - Incomplete GFM Table & Dangling Marker Guards

    private static func findUnfinishedTableHold(lines: [String]) -> (prefix: String, withheld: String)? {
        guard !lines.isEmpty else { return nil }
        // Ignore a single trailing empty line produced by a lone `\n` after a table header or separator
        // (`"| A | B |\n"` -> `["| A | B |", ""]`), while preserving a blank-line paragraph break (`\n\n`).
        var endIdx = lines.count - 1
        let hasSingleTrailingNewline: Bool
        if lines.count >= 2,
           lines[endIdx].trimmingCharacters(in: .whitespaces).isEmpty,
           lines[endIdx - 1].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
            endIdx -= 1
            hasSingleTrailingNewline = true
        } else {
            hasSingleTrailingNewline = false
        }

        var firstTableIdx: Int?
        for idx in stride(from: endIdx, through: 0, by: -1) {
            let trimmed = lines[idx].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("|") {
                firstTableIdx = idx
            } else {
                break
            }
        }
        guard let startIdx = firstTableIdx else { return nil }
        let runCount = endIdx - startIdx + 1

        // Case 1: Only the header line has started (`| Col A | Col B`, `| Col A | Col B |`, or `| Col A | Col B |\n`),
        // separator row hasn't arrived yet -> hold back the header row so raw pipe text never flashes.
        if runCount == 1 {
            let prefix = lines[..<startIdx].joined(separator: "\n")
            let heldRun = lines[startIdx...].joined(separator: "\n")
            let held = (startIdx > 0 ? "\n" : "") + heldRun
            return (prefix, held)
        }

        // Case 2: Header + second line (with or without trailing `\n`), where delimiter isn't followed by a body row yet
        // or is not yet a valid complete GFM delimiter row -> hold back header + partial separator.
        let delimiterTrimmed = lines[startIdx + 1].trimmingCharacters(in: .whitespaces)
        guard runCount > 2, let expectedCols = validTableDelimiterColumnCount(delimiterTrimmed) else {
            let prefix = lines[..<startIdx].joined(separator: "\n")
            let heldRun = lines[startIdx...].joined(separator: "\n")
            let held = (startIdx > 0 ? "\n" : "") + heldRun
            return (prefix, held)
        }

        // Case 3: Header + valid delimiter row committed; if trailing body row isn't terminated with `|` or
        // hasn't finished all expected columns yet (e.g. `| 零食 |` in a 2-column table), hold back only that
        // half-written body row while letting completed rows render cleanly.
        let lastTrimmed = lines[endIdx].trimmingCharacters(in: .whitespaces)
        if !lastTrimmed.hasSuffix("|") || lastTrimmed.count < 2 || tableRowCellCount(lastTrimmed) < expectedCols {
            let prefix = lines[..<endIdx].joined(separator: "\n")
            let held = "\n" + lines[endIdx...].joined(separator: "\n")
            return (prefix, held)
        }

        // Complete row with optional single trailing newline renders cleanly as a table.
        _ = hasSingleTrailingNewline
        return nil
    }

    private static func validTableDelimiterColumnCount(_ trimmedLine: String) -> Int? {
        let inner = trimmedLine.trimmingCharacters(in: CharacterSet(charactersIn: "| "))
        guard !inner.isEmpty else { return nil }
        let cells = inner.split(separator: "|", omittingEmptySubsequences: false)
        guard !cells.isEmpty else { return nil }
        for rawCell in cells {
            let cell = rawCell.trimmingCharacters(in: .whitespaces)
            guard !cell.isEmpty else { return nil }
            var slice = cell[...]
            if slice.first == ":" { slice = slice.dropFirst() }
            if slice.last == ":" { slice = slice.dropLast() }
            if slice.isEmpty || !slice.allSatisfy({ $0 == "-" }) {
                return nil
            }
        }
        return cells.count
    }

    private static func tableRowCellCount(_ trimmedLine: String) -> Int {
        guard trimmedLine.hasPrefix("|"), trimmedLine.hasSuffix("|"), trimmedLine.count >= 2 else { return 0 }
        let chars = Array(trimmedLine)
        var unescapedPipes = 0
        var i = 0
        while i < chars.count {
            if chars[i] == "\\" && i + 1 < chars.count {
                i += 2
                continue
            }
            if chars[i] == "|" {
                unescapedPipes += 1
            }
            i += 1
        }
        return max(0, unescapedPipes - 1)
    }

    private static func isDanglingBareBlockMarker(_ trimmed: String) -> Bool {
        guard !trimmed.isEmpty else { return false }
        if trimmed.count <= 6 && trimmed.allSatisfy({ $0 == "#" }) { return true }
        if trimmed == "-" || trimmed == "*" || trimmed == "+" || trimmed == ">" || trimmed == "|" { return true }
        if trimmed.count >= 2 && (trimmed.last == "." || trimmed.last == ")"),
           trimmed.dropLast().allSatisfy({ $0.isWholeNumber && $0.isASCII }) {
            return true
        }
        return false
    }

    private static func isASCIIWord(_ c: Character) -> Bool {
        c.isLetter || c.isNumber
    }

    private static func isCJK(_ c: Character) -> Bool {
        guard let scalar = c.unicodeScalars.first else { return false }
        let v = scalar.value
        return (0x3000...0x303F).contains(v) || (0x4E00...0x9FFF).contains(v) || (0xFF00...0xFFEF).contains(v)
    }

    private static func isValidMathOpenPrev(_ prev: Character?) -> Bool {
        guard let p = prev else { return true }
        if p.isWhitespace || isCJK(p) { return true }
        return "([{\"'«„-—–:：，。；！？、（【《「『".contains(p)
    }

    private static func isCurrencyOrNonMathAfterDollar(_ chars: [Character], idxAfterDollar: Int) -> Bool {
        let n = chars.count
        guard idxAfterDollar < n else { return true }
        let ch = chars[idxAfterDollar]
        if ch.isWhitespace || ch == "$" { return true }
        if ch.isWholeNumber && ch.isASCII {
            var j = idxAfterDollar
            while j < n && ((chars[j].isWholeNumber && chars[j].isASCII) || chars[j] == "," || chars[j] == ".") {
                j += 1
            }
            guard j < n else { return true }
            let nextCh = chars[j]
            if "kKmMbB".contains(nextCh) {
                let afterMult: Character? = (j + 1) < n ? chars[j + 1] : nil
                if afterMult == nil || !(afterMult!.isLetter) { return true }
            }
            if (nextCh.isLetter && nextCh.isASCII) || "\\^_{".contains(nextCh) {
                return false
            }
            return true
        }
        return false
    }

    private static func isValidMathClose(_ chars: [Character], closeIdx: Int) -> Bool {
        guard closeIdx > 0 else { return false }
        let prev = chars[closeIdx - 1]
        if prev.isWhitespace || prev == "\\" { return false }
        if (closeIdx + 1) < chars.count, chars[closeIdx + 1].isWholeNumber, chars[closeIdx + 1].isASCII {
            return false
        }
        return true
    }
}

// MARK: - 2. Water-Filling Adaptive Table Column Solver & UAX #14 Tokenizer

public struct ColumnWidthMetric: Equatable, Sendable {
    public let minTokenWidth: Double
    public let naturalWidth: Double

    public init(minTokenWidth: Double, naturalWidth: Double) {
        self.minTokenWidth = minTokenWidth
        self.naturalWidth = naturalWidth
    }
}

public enum TableWaterfillSolver {
    /// Allocates table column widths using water-filling compression bounded by per-column unbreakable floors.
    /// When the sum of unbreakable token floors exceeds `availableWidth`, returns the floor array so the caller
    /// enables horizontal scrolling rather than breaking words mid-character.
    public static func allocate(
        availableWidth: Double,
        minFloor: Double = 60.0,
        maxShare: Double = 0.5,
        columns: [ColumnWidthMetric]
    ) -> [Double] {
        guard !columns.isEmpty, availableWidth > 0 else { return [] }
        let k = columns.count
        let floors = columns.map { max(minFloor, $0.minTokenWidth) }
        let naturals = zip(floors, columns).map { max($0, $1.naturalWidth) }

        let totalNatural = naturals.reduce(0, +)
        if totalNatural <= availableWidth { return naturals }

        let totalFloors = floors.reduce(0, +)
        if totalFloors >= availableWidth { return floors }

        let cap = maxShare * availableWidth
        var widths = (0..<k).map { min(naturals[$0], max(floors[$0], cap)) }
        let cappedSum = widths.reduce(0, +)
        if cappedSum <= availableWidth {
            let slack = availableWidth - cappedSum
            let headrooms = (0..<k).map { max(0.0, naturals[$0] - widths[$0]) }
            let totalHr = headrooms.reduce(0, +)
            if totalHr > 0 {
                for idx in 0..<k { widths[idx] += slack * (headrooms[idx] / totalHr) }
            }
            return widths
        }

        var lo = floors.min() ?? 0
        var hi = widths.max() ?? availableWidth
        for _ in 0..<60 {
            let mid = 0.5 * (lo + hi)
            let s = (0..<k).reduce(0.0) { $0 + max(floors[$1], min(widths[$1], mid)) }
            if s > availableWidth { hi = mid } else { lo = mid }
        }
        let lvl = 0.5 * (lo + hi)
        return (0..<k).map { max(floors[$0], min(widths[$0], lvl)) }
    }

    /// Returns UAX #14 line-break unbreakable token ranges for `text` so callers can measure exact
    /// minimum column token floors (CJK characters break between hanzi; English/code words stay intact).
    public static func unbreakableTokenRanges(in text: String) -> [Range<String.Index>] {
        guard !text.isEmpty else { return [] }
        #if canImport(CoreFoundation) && !os(Linux)
        let cfStr = text as CFString
        let fullRange = CFRangeMake(0, CFStringGetLength(cfStr))
        guard let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault,
            cfStr,
            fullRange,
            UInt(kCFStringTokenizerUnitLineBreak),
            nil
        ) else {
            return [text.startIndex..<text.endIndex]
        }

        var ranges: [Range<String.Index>] = []
        var tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        while tokenType != [] {
            let cfTokenRange = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            if cfTokenRange.location != kCFNotFound && cfTokenRange.length > 0,
               let nsRange = Range(NSRange(location: cfTokenRange.location, length: cfTokenRange.length), in: text) {
                let trimmed = text[nsRange].trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, let subRange = text.range(of: trimmed, range: nsRange) {
                    ranges.append(subRange)
                }
            }
            tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        }
        return ranges
        #else
        var ranges: [Range<String.Index>] = []
        var idx = text.startIndex
        while idx < text.endIndex {
            let ch = text[idx]
            if ch.isWhitespace {
                idx = text.index(after: idx)
                continue
            }
            if let scalar = ch.unicodeScalars.first,
               (0x3000...0x9FFF).contains(scalar.value) || (0xFF00...0xFFEF).contains(scalar.value) {
                let next = text.index(after: idx)
                ranges.append(idx..<next)
                idx = next
                continue
            }
            let start = idx
            while idx < text.endIndex && !text[idx].isWhitespace {
                if let scalar = text[idx].unicodeScalars.first,
                   (0x3000...0x9FFF).contains(scalar.value) || (0xFF00...0xFFEF).contains(scalar.value) {
                    break
                }
                idx = text.index(after: idx)
            }
            if start < idx {
                ranges.append(start..<idx)
            }
        }
        return ranges
        #endif
    }
}
