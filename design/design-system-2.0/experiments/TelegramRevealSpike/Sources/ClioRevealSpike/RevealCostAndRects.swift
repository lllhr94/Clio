import CoreGraphics
import CoreText
import Foundation

/// Single laid-out line holding Telegram-equivalent baseline-relative CoreText glyph ink rects (`characterRects`).
public struct SpikeLaidOutLine: Equatable {
    public let range: NSRange
    public let frame: CGRect
    public let baselineTopDownY: CGFloat
    public let textOriginX: CGFloat
    public let ascent: CGFloat
    public let descent: CGFloat
    public let leading: CGFloat
    public let characterRects: [CGRect]
    public let isRTL: Bool
    public let ctLine: CTLine

    public static func == (lhs: SpikeLaidOutLine, rhs: SpikeLaidOutLine) -> Bool {
        return lhs.range == rhs.range
            && lhs.frame == rhs.frame
            && lhs.baselineTopDownY == rhs.baselineTopDownY
            && lhs.textOriginX == rhs.textOriginX
            && lhs.ascent == rhs.ascent
            && lhs.descent == rhs.descent
            && lhs.characterRects == rhs.characterRects
            && lhs.isRTL == rhs.isRTL
    }
}

/// CoreText geometric layout & ink-bound extraction mirroring `InstantPageV2Layout.swift` (`computeRevealCharacterRects`),
/// hardened with extended-grapheme-cluster and multi-code-unit ligature boundaries.
public enum CoreTextRevealMeasurer {
    private static let frameMeasureHeight: CGFloat = 100_000.0

    public struct LayoutResult {
        public let lines: [SpikeLaidOutLine]
        public let contentSize: CGSize
        public let atomicUnits: [RevealAtomicUnit]
    }

    /// Indivisible UTF-16 reveal span protecting extended grapheme clusters (ZWJ Emoji, skin tones, combining marks,
    /// surrogate pairs) and CoreText ligature slots (where continuation code units have `CGRect.zero`).
    public struct RevealAtomicUnit: Equatable {
        public let utf16Range: Range<Int>
        public let widthCost: CGFloat
    }

    public static func layoutText(
        _ attributed: NSAttributedString,
        maxWidth: CGFloat
    ) -> LayoutResult {
        let clampedWidth = max(40.0, maxWidth)
        let string = attributed.string
        guard attributed.length > 0 else {
            return LayoutResult(lines: [], contentSize: CGSize(width: clampedWidth, height: 0.0), atomicUnits: [])
        }

        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let pathRect = CGRect(x: 0.0, y: 0.0, width: clampedWidth, height: frameMeasureHeight)
        let path = CGPath(rect: pathRect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)

        guard let ctLines = CTFrameGetLines(frame) as? [CTLine], !ctLines.isEmpty else {
            return LayoutResult(lines: [], contentSize: CGSize(width: clampedWidth, height: 0.0), atomicUnits: [])
        }

        var origins = [CGPoint](repeating: .zero, count: ctLines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)

        var laidOut: [SpikeLaidOutLine] = []
        laidOut.reserveCapacity(ctLines.count)

        var glyphClusterSpans: [Range<Int>] = []

        for idx in 0..<ctLines.count {
            let line = ctLines[idx]
            let cfRange = CTLineGetStringRange(line)
            let nsRange = NSRange(location: max(0, cfRange.location), length: max(0, cfRange.length))

            var ascent: CGFloat = 0.0
            var descent: CGFloat = 0.0
            var leading: CGFloat = 0.0
            let lineWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))

            let origin = origins[idx]
            let baselineTopDownY = frameMeasureHeight - origin.y
            let lineHeight = ceil(ascent + descent)
            let lineFrame = CGRect(
                x: origin.x,
                y: baselineTopDownY - ascent,
                width: max(0.0, ceil(lineWidth)),
                height: max(1.0, lineHeight)
            )

            let extraction = computeRevealCharacterRects(line: line, lineRange: nsRange, fullString: string)
            glyphClusterSpans.append(contentsOf: extraction.multiUnitSpans)

            laidOut.append(
                SpikeLaidOutLine(
                    range: nsRange,
                    frame: lineFrame,
                    baselineTopDownY: baselineTopDownY,
                    textOriginX: origin.x,
                    ascent: ascent,
                    descent: descent,
                    leading: leading,
                    characterRects: extraction.rects,
                    isRTL: extraction.isRTL,
                    ctLine: line
                )
            )
        }

        let maxBottom = laidOut.map { $0.frame.maxY }.max() ?? 0.0
        let atomicUnits = buildAtomicUnits(for: string, lines: laidOut, extraSpans: glyphClusterSpans)
        return LayoutResult(
            lines: laidOut,
            contentSize: CGSize(width: clampedWidth, height: ceil(maxBottom)),
            atomicUnits: atomicUnits
        )
    }

    private struct CharacterRectExtraction {
        let rects: [CGRect]
        let isRTL: Bool
        let multiUnitSpans: [Range<Int>]
    }

    /// Mirrors `InstantPageV2Layout.swift` lines 4651-4691 using `CTRunGetGlyphs`, `CTRunGetPositions`,
    /// `CTRunGetStringIndices`, and `CTFontGetBoundingRectsForGlyphs`.
    private static func computeRevealCharacterRects(
        line: CTLine,
        lineRange: NSRange,
        fullString: String
    ) -> CharacterRectExtraction {
        guard lineRange.length > 0 else {
            return CharacterRectExtraction(rects: [], isRTL: false, multiUnitSpans: [])
        }

        var rects = [CGRect](repeating: .zero, count: lineRange.length)
        var isRTL = false
        var multiUnitSpans: [Range<Int>] = []
        let utf16 = fullString.utf16

        let glyphRuns = CTLineGetGlyphRuns(line) as NSArray
        for rawRun in glyphRuns {
            let run = rawRun as! CTRun
            let status = CTRunGetStatus(run)
            if status.contains(.rightToLeft) {
                isRTL = true
            }
            let glyphCount = CTRunGetGlyphCount(run)
            if glyphCount == 0 {
                continue
            }

            var glyphs = [CGGlyph](repeating: 0, count: glyphCount)
            CTRunGetGlyphs(run, CFRangeMake(0, glyphCount), &glyphs)

            var positions = [CGPoint](repeating: .zero, count: glyphCount)
            CTRunGetPositions(run, CFRangeMake(0, glyphCount), &positions)

            var stringIndices = [CFIndex](repeating: 0, count: glyphCount)
            CTRunGetStringIndices(run, CFRangeMake(0, glyphCount), &stringIndices)

            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let rawFont = attributes[kCTFontAttributeName as String] else {
                continue
            }
            let cfFont = rawFont as CFTypeRef
            guard CFGetTypeID(cfFont) == CTFontGetTypeID() else {
                continue
            }
            let font = unsafeBitCast(cfFont, to: CTFont.self)

            var boundingRects = [CGRect](repeating: .zero, count: glyphCount)
            CTFontGetBoundingRectsForGlyphs(font, .default, &glyphs, &boundingRects, glyphCount)

            let sortedStarts = stringIndices.sorted()
            for i in 0..<glyphCount {
                let globalIdx = stringIndices[i]
                let localIdx = globalIdx - lineRange.location
                if localIdx >= 0 && localIdx < lineRange.length {
                    let pos = positions[i]
                    let bbox = boundingRects[i]
                    let candidate = CGRect(
                        x: pos.x + bbox.origin.x,
                        y: pos.y + bbox.origin.y,
                        width: bbox.width,
                        height: bbox.height
                    )
                    if rects[localIdx].isEmpty {
                        rects[localIdx] = candidate
                    } else if !candidate.isEmpty {
                        rects[localIdx] = rects[localIdx].union(candidate)
                    }

                    // Detect multi-code-unit glyph groups (e.g., Latin "fi" ligatures or grapheme sequences)
                    // where one glyph covers multiple UTF-16 indices up to the next distinct glyph start.
                    let runEnd = CTRunGetStringRange(run).location + CTRunGetStringRange(run).length
                    let nextStart = sortedStarts.first { $0 > globalIdx } ?? min(runEnd, utf16.count)
                    if nextStart - globalIdx > 1 {
                        multiUnitSpans.append(globalIdx..<nextStart)
                    }
                }
            }
        }

        return CharacterRectExtraction(rects: rects, isRTL: isRTL, multiUnitSpans: multiUnitSpans)
    }

    private static func buildAtomicUnits(
        for text: String,
        lines: [SpikeLaidOutLine],
        extraSpans: [Range<Int>]
    ) -> [RevealAtomicUnit] {
        var ranges: [Range<Int>] = []
        let utf16Base = text.utf16
        for idx in text.indices {
            let next = text.index(after: idx)
            let start = utf16Base.distance(from: utf16Base.startIndex, to: idx.samePosition(in: utf16Base) ?? utf16Base.startIndex)
            let end = utf16Base.distance(from: utf16Base.startIndex, to: next.samePosition(in: utf16Base) ?? utf16Base.endIndex)
            if end > start {
                ranges.append(start..<end)
            }
        }

        // Coalesce any CoreText multi-code-unit glyph span (such as a typographic ligature like "fi")
        // so partial reveal budgets never split ligatures or extended grapheme clusters.
        for span in extraSpans {
            var merged: [Range<Int>] = []
            var accumulator: Range<Int>?
            for r in ranges {
                if r.overlaps(span) {
                    if let acc = accumulator {
                        accumulator = min(acc.lowerBound, r.lowerBound)..<max(acc.upperBound, r.upperBound)
                    } else {
                        accumulator = r
                    }
                } else {
                    if let acc = accumulator {
                        merged.append(acc)
                        accumulator = nil
                    }
                    merged.append(r)
                }
            }
            if let acc = accumulator {
                merged.append(acc)
            }
            ranges = merged
        }

        // Accumulate true ink width per atomic unit across lines.
        return ranges.map { range in
            var widthSum: CGFloat = 0.0
            for line in lines {
                if range.upperBound <= line.range.location || range.lowerBound >= line.range.location + line.range.length {
                    continue
                }
                let localStart = max(0, range.lowerBound - line.range.location)
                let localEnd = min(line.characterRects.count, range.upperBound - line.range.location)
                for localIdx in localStart..<localEnd {
                    let rect = line.characterRects[localIdx]
                    if !rect.isEmpty {
                        widthSum += rect.width
                    }
                }
            }
            return RevealAtomicUnit(utf16Range: range, widthCost: widthSum)
        }
    }

    public static func snapUTF16Index(_ proposed: Int, atomicUnits: [RevealAtomicUnit]) -> Int {
        guard proposed > 0 else { return 0 }
        for unit in atomicUnits {
            if proposed >= unit.utf16Range.lowerBound && proposed < unit.utf16Range.upperBound {
                // Always round up or down cleanly to the unit boundary (never inside).
                return unit.utf16Range.lowerBound
            }
        }
        return min(proposed, atomicUnits.last?.utf16Range.upperBound ?? proposed)
    }

    /// Draws the CoreText lines into a premultiplied top-down `CGImage` so `RevealSnippetLayer` can crop real textures.
    public static func rasterizeBackingImage(
        lines: [SpikeLaidOutLine],
        size: CGSize,
        scale: CGFloat = 2.0,
        padding: CGFloat = 4.0
    ) -> CGImage? {
        let safeScale = max(1.0, min(3.0, scale))
        let pxW = max(1, Int(ceil(size.width * safeScale)))
        let pxH = max(1, Int(ceil(size.height * safeScale)))
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: pxW,
            height: pxH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        ctx.clear(CGRect(x: 0, y: 0, width: pxW, height: pxH))
        ctx.scaleBy(x: safeScale, y: safeScale)
        ctx.textMatrix = .identity

        let totalHeight = size.height
        for line in lines {
            let cgBaselineY = totalHeight - line.baselineTopDownY - padding
            ctx.textPosition = CGPoint(x: line.textOriginX + padding, y: cgBaselineY)
            CTLineDraw(line.ctLine, ctx)
        }
        return ctx.makeImage()
    }
}

/// Telegram `InstantPageV2RevealCost.swift` Points-cost equivalent for Clio structured content blocks.
public struct SpikeRevealCostMap: Equatable {
    public enum BlockEntry: Equatable {
        case text(startPoint: Int, endPoint: Int, startUTF16: Int, endUTF16: Int, frame: CGRect)
        case codeBlock(startPoint: Int, endPoint: Int, startUTF16: Int, endUTF16: Int, frame: CGRect)
        case table(startPoint: Int, endPoint: Int, startUTF16: Int, endUTF16: Int, frame: CGRect)
        case math(startPoint: Int, endPoint: Int, startUTF16: Int, endUTF16: Int, frame: CGRect)
        case thinking(startPoint: Int, startUTF16: Int, endUTF16: Int, frame: CGRect)
    }

    public let totalPoints: Int
    public let totalUTF16Length: Int
    public let entries: [BlockEntry]
    public let atomicUnits: [CoreTextRevealMeasurer.RevealAtomicUnit]
    public let textLines: [SpikeLaidOutLine]

    public init(
        totalPoints: Int,
        totalUTF16Length: Int,
        entries: [BlockEntry],
        atomicUnits: [CoreTextRevealMeasurer.RevealAtomicUnit],
        textLines: [SpikeLaidOutLine]
    ) {
        self.totalPoints = totalPoints
        self.totalUTF16Length = totalUTF16Length
        self.entries = entries
        self.atomicUnits = atomicUnits
        self.textLines = textLines
    }

    /// Mirrors `InstantPageV2RevealCost.textInkWidth`: sums actual CoreText glyph ink widths (in points).
    public static func textInkWidth(_ lines: [SpikeLaidOutLine]) -> Int {
        var total: CGFloat = 0.0
        for line in lines {
            if line.characterRects.isEmpty {
                total += line.frame.width
            } else {
                for rect in line.characterRects where !rect.isEmpty {
                    total += rect.width
                }
            }
        }
        return max(0, Int(total.rounded()))
    }

    /// Converts a reveal budget (in Points) into an exact UTF-16 reveal count aligned to intact atomic clusters/ligatures.
    public func charCountForWidthBudget(_ widthBudget: Int) -> Int {
        if widthBudget <= 0 {
            return 0
        }
        if widthBudget >= totalPoints {
            return totalUTF16Length
        }

        var remaining = CGFloat(widthBudget)
        var revealedUTF16 = 0
        for unit in atomicUnits {
            let cost = max(0.0, unit.widthCost)
            if remaining >= cost {
                remaining -= cost
                revealedUTF16 = unit.utf16Range.upperBound
            } else {
                break
            }
        }
        return min(totalUTF16Length, revealedUTF16)
    }

    /// Mirrors `InstantPageV2RevealCost.revealedContentSize`: height rises only when revealed Points enter new lines/blocks.
    public func revealedMaxY(revealedPoints: Int, revealedCharCount: Int) -> CGFloat {
        if revealedPoints <= 0 {
            return 0.0
        }
        var maxY: CGFloat = 0.0
        for entry in entries {
            switch entry {
            case let .thinking(start, _, _, frame):
                if revealedPoints >= start {
                    maxY = max(maxY, frame.maxY)
                }
            case let .codeBlock(start, _, _, _, frame):
                if revealedPoints > start {
                    maxY = max(maxY, frame.maxY)
                }
            case let .table(start, end, _, _, frame),
                 let .math(start, end, _, _, frame):
                let _ = start
                if revealedPoints >= end {
                    maxY = max(maxY, frame.maxY)
                }
            case let .text(start, end, startUTF16, _, frame):
                if revealedPoints <= start {
                    continue
                }
                if revealedPoints >= end {
                    maxY = max(maxY, frame.maxY)
                } else {
                    var localChars = revealedCharCount - startUTF16
                    for line in textLines {
                        if localChars <= 0 { break }
                        let len = max(1, line.range.length)
                        maxY = max(maxY, frame.minY + line.frame.maxY)
                        localChars -= len
                    }
                }
            }
        }
        return ceil(maxY)
    }

    public static func buildSingleTextDocument(
        lines: [SpikeLaidOutLine],
        atomicUnits: [CoreTextRevealMeasurer.RevealAtomicUnit],
        contentSize: CGSize,
        utf16Length: Int
    ) -> SpikeRevealCostMap {
        let ink = textInkWidth(lines)
        let entry = BlockEntry.text(
            startPoint: 0,
            endPoint: ink,
            startUTF16: 0,
            endUTF16: utf16Length,
            frame: CGRect(origin: .zero, size: contentSize)
        )
        return SpikeRevealCostMap(
            totalPoints: ink,
            totalUTF16Length: utf16Length,
            entries: [entry],
            atomicUnits: atomicUnits,
            textLines: lines
        )
    }
}
