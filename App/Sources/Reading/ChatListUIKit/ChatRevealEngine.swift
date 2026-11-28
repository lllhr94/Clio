import CoreText
import Foundation
import QuartzCore
import UIKit

/// Device, accessibility, compile-time blur isolation, and burst-budget gate for 1:1 Telegram streaming reveal.
@MainActor
enum ChatRevealPolicy {
    static let maxTailAttributedLength: Int = 8_000
    static let maxConcurrentSnippets: Int = 36
    static let snippetDuration: CFTimeInterval = 0.21
    static let snippetBleedPoints: CGFloat = 1.5
    static let snippetInitialScale: CGFloat = 0.5
    static let snippetInitialOffsetY: CGFloat = 6.0
    static let snippetInitialBlurRadius: CGFloat = 2.0

    /// Compile-time isolation marker: App Store / default Release builds MUST NOT compile in private blur filters.
    nonisolated static var isBlurFilterCompiledIn: Bool {
        #if CLIO_ALLOW_BLUR_FILTER
        return true
        #else
        return false
        #endif
    }

    static func isEligible(fade: Bool, reduceMotion: Bool, attributedLength: Int) -> Bool {
        fade && !reduceMotion && attributedLength > 0 && attributedLength <= maxTailAttributedLength
    }

    nonisolated static func allowsMotionEffects(
        reduceMotion: Bool,
        isLowPowerMode: Bool,
        thermalState: ProcessInfo.ThermalState
    ) -> Bool {
        guard !reduceMotion, !isLowPowerMode else { return false }
        switch thermalState {
        case .serious, .critical:
            return false
        default:
            return true
        }
    }

    static func currentAllowsMotionEffects(reduceMotion: Bool) -> Bool {
        !reduceMotion && RuntimeBudgetGovernor.shared.snapshot.allowsRevealSnippets
    }

    static func allowsSnippets(
        fade: Bool,
        reduceMotion: Bool,
        attributedLength: Int,
        tileCount: Int
    ) -> Bool {
        guard isEligible(fade: fade, reduceMotion: reduceMotion, attributedLength: attributedLength),
              tileCount >= 1 else {
            return false
        }
        return currentAllowsMotionEffects(reduceMotion: reduceMotion)
    }

    static func featherWidth(forLineHeight lineHeight: CGFloat) -> CGFloat {
        min(20.0, max(10.0, lineHeight * 0.72))
    }
}

/// Pure, cursor-layer uniform glyph-width pacer paired with verbatim upstream `TextRevealController`.
/// Removes any high-speed floor and `/8.0` width distortion; enforces a smooth reading-speed ceiling
/// with S-curve catch-up acceleration on large backlogs and stream finalization.
enum ChatRevealPacer {
    struct Profile: Equatable, Sendable {
        let durationMultiplier: Double
        let baseCeilingPtsPerSec: Double
        let maxCatchUpMultiplier: Double
        let catchUpBacklogPoints: Double
    }

    nonisolated static func profile(for pace: Pref.RevealPace) -> Profile {
        switch pace {
        case .gentle:
            return Profile(
                durationMultiplier: 1.45,
                baseCeilingPtsPerSec: 260.0,
                maxCatchUpMultiplier: 2.6,
                catchUpBacklogPoints: 480.0
            )
        case .balanced:
            return Profile(
                durationMultiplier: 1.0,
                baseCeilingPtsPerSec: 420.0,
                maxCatchUpMultiplier: 3.2,
                catchUpBacklogPoints: 480.0
            )
        case .fast:
            return Profile(
                durationMultiplier: 0.65,
                baseCeilingPtsPerSec: 720.0,
                maxCatchUpMultiplier: 4.0,
                catchUpBacklogPoints: 440.0
            )
        }
    }

    /// True glyph-width point cost (1 point ≈ 1pt horizontal typographic advance; zero `/8.0` quantization).
    nonisolated static func pointCost(forAdvance advance: CGFloat, isWhitespace: Bool) -> Int {
        if isWhitespace {
            return max(1, Int(min(4.0, max(1.0, advance)).rounded()))
        }
        return max(1, Int(max(2.0, advance).rounded()))
    }

    /// Advances the reveal cursor smoothly while respecting the reading speed ceiling and S-curve catch-up.
    nonisolated static func stepCursor(
        current: Double,
        controllerTarget: Double,
        totalPoints: Int,
        elapsed: Double,
        pace: Pref.RevealPace,
        hasRateSample: Bool,
        isFinalizing: Bool
    ) -> Double {
        let total = Double(max(0, totalPoints))
        guard total > 0 else { return 0 }
        let clampedCurrent = min(total, max(0, current))
        let dt = min(max(0, elapsed), 0.05)
        guard dt > 0 else { return clampedCurrent }

        let prof = profile(for: pace)
        let remaining = max(0, total - clampedCurrent)
        let backlogRatio = min(1.0, remaining / max(1.0, prof.catchUpBacklogPoints))
        let sCurve = backlogRatio * backlogRatio * (3.0 - 2.0 * backlogRatio)
        let finalBoost = isFinalizing ? 1.45 : 1.0
        let ceilingRate = prof.baseCeilingPtsPerSec
            * (1.0 + (prof.maxCatchUpMultiplier - 1.0) * sCurve)
            * finalBoost
        let maxStep = ceilingRate * dt

        let desiredTarget: Double
        if isFinalizing {
            let drainRate = max(prof.baseCeilingPtsPerSec * 0.9, remaining / 0.28)
            let finalizeStep = min(maxStep, drainRate * dt)
            let candidate = max(controllerTarget, clampedCurrent + finalizeStep)
            desiredTarget = min(total, candidate)
        } else if hasRateSample {
            desiredTarget = min(total, max(clampedCurrent, controllerTarget))
        } else {
            // Before the second streaming chunk provides an inter-arrival sample, glide smoothly
            // at the calibrated reading pace rather than stalling at raw unit-count initial rate.
            let initialRate = prof.baseCeilingPtsPerSec * (0.72 + 0.28 * sCurve)
            desiredTarget = min(total, clampedCurrent + initialRate * dt)
        }

        let stepped = min(desiredTarget, clampedCurrent + maxStep)
        if isFinalizing && (total - stepped) < 0.75 {
            return total
        }
        return min(total, max(clampedCurrent, stepped))
    }
}

/// Atomic CoreText glyph/ligature/emoji cluster with true `CTRun` ink bounds and symmetric bleed rect.
struct ChatRevealAtomicUnit: Equatable, Sendable {
    let utf16Location: Int
    let utf16Length: Int
    let minX: CGFloat
    let maxX: CGFloat
    let inkRect: CGRect
    let bleedRect: CGRect
    let hasInlineAttachment: Bool
    let isWhitespace: Bool
    let startPoints: Int
    let endPoints: Int

    var utf16End: Int { utf16Location + utf16Length }
    var costPoints: Int { max(0, endPoints - startPoints) }
}

/// Per-line CoreText band coordinates and ordered atomic clusters for zero-allocation masking & glyph snippets.
struct ChatRevealLineLayout: Equatable, Sendable {
    let bandTop: CGFloat
    let bandBottom: CGFloat
    let rawTop: CGFloat
    let rawBottom: CGFloat
    let hasRTL: Bool
    let startPoints: Int
    let endPoints: Int
    let utf16Start: Int
    let utf16End: Int
    let units: [ChatRevealAtomicUnit]
    let frontierEnds: [CGFloat]

    var bandHeight: CGFloat { max(0, bandBottom - bandTop) }
    var rawHeight: CGFloat { max(1, rawBottom - rawTop) }

    func frontierX(forPoints points: Double, fallbackWidth: CGFloat) -> CGFloat {
        guard !units.isEmpty else { return fallbackWidth }
        let firstInkX = max(0, min(units[0].minX, units[0].inkRect.minX))
        if points <= Double(startPoints) { return firstInkX }
        if points >= Double(endPoints) { return fallbackWidth }

        var low = 0
        var high = units.count - 1
        while low < high {
            let mid = (low + high) / 2
            if points <= Double(units[mid].endPoints) {
                high = mid
            } else {
                low = mid + 1
            }
        }
        let unit = units[low]
        let progress = min(1, max(0, CGFloat((points - Double(unit.startPoints)) / Double(max(1, unit.costPoints)))))
        let startX = low == 0 ? firstInkX : frontierEnds[low - 1]
        return startX + (frontierEnds[low] - startX) * progress
    }

    func utf16Offset(forPoints points: Int) -> Int {
        guard !units.isEmpty else { return utf16End }
        if points <= startPoints { return utf16Start }
        if points >= endPoints { return utf16End }

        var low = 0
        var high = units.count - 1
        while low < high {
            let mid = (low + high) / 2
            if points <= units[mid].endPoints {
                high = mid
            } else {
                low = mid + 1
            }
        }
        let unit = units[low]
        return points >= unit.endPoints ? unit.utf16End : unit.utf16Location
    }

    func pointsBefore(utf16Offset: Int) -> Int {
        guard !units.isEmpty else { return endPoints }
        if utf16Offset <= utf16Start { return startPoints }
        if utf16Offset >= utf16End { return endPoints }

        var low = 0
        var high = units.count - 1
        while low < high {
            let mid = (low + high) / 2
            if utf16Offset <= units[mid].utf16End {
                high = mid
            } else {
                low = mid + 1
            }
        }
        let unit = units[low]
        if utf16Offset >= unit.utf16End { return unit.endPoints }
        if utf16Offset <= unit.utf16Location { return unit.startPoints }
        let ratio = Double(utf16Offset - unit.utf16Location) / Double(max(1, unit.utf16Length))
        return unit.startPoints + Int((Double(unit.costPoints) * ratio).rounded())
    }
}

/// CoreText line + `CTRun` glyph-cluster layout matching `ChatTextTileRenderer.render` coordinates bit-for-bit.
final class ChatRevealLayoutSnapshot: @unchecked Sendable {
    let sourceRenderToken: UInt64
    let attributedLength: Int
    let layoutSize: CGSize
    let textSample: String
    let lines: [ChatRevealLineLayout]
    let totalPoints: Int

    private init(
        sourceRenderToken: UInt64,
        attributedLength: Int,
        layoutSize: CGSize,
        textSample: String,
        lines: [ChatRevealLineLayout],
        totalPoints: Int
    ) {
        self.sourceRenderToken = sourceRenderToken
        self.attributedLength = attributedLength
        self.layoutSize = layoutSize
        self.textSample = textSample
        self.lines = lines
        self.totalPoints = totalPoints
    }

    nonisolated static func build(
        attributed: NSAttributedString,
        width: CGFloat,
        height: CGFloat,
        topInset: CGFloat,
        bottomInset: CGFloat,
        sourceRenderToken: UInt64
    ) -> ChatRevealLayoutSnapshot {
        let safeWidth = max(1, width)
        let safeHeight = max(1, height)
        let fullText = attributed.string
        let realLength = attributed.length
        guard realLength > 0 else {
            return ChatRevealLayoutSnapshot(
                sourceRenderToken: sourceRenderToken,
                attributedLength: 0,
                layoutSize: CGSize(width: safeWidth, height: safeHeight),
                textSample: fullText,
                lines: [],
                totalPoints: 0
            )
        }

        let textHeight = max(1, safeHeight - topInset - bottomInset)
        let source = ChatLayoutCache.prepareCoreTextSource(attributed)
        let framesetter = CTFramesetterCreateWithAttributedString(source as CFAttributedString)
        let framePath = CGPath(rect: CGRect(x: 0, y: 0, width: safeWidth, height: textHeight), transform: nil)
        let ctFrame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: source.length), framePath, nil)
        return build(
            from: ctFrame,
            fullText: fullText,
            realLength: realLength,
            width: safeWidth,
            height: safeHeight,
            topInset: topInset,
            bottomInset: bottomInset,
            sourceRenderToken: sourceRenderToken
        )
    }

    nonisolated static func build(
        from ctFrame: CTFrame,
        fullText: String,
        realLength: Int,
        width: CGFloat,
        height: CGFloat,
        topInset: CGFloat,
        bottomInset: CGFloat,
        sourceRenderToken: UInt64
    ) -> ChatRevealLayoutSnapshot {
        let safeWidth = max(1, width)
        let safeHeight = max(1, height)
        guard realLength > 0 else {
            return ChatRevealLayoutSnapshot(
                sourceRenderToken: sourceRenderToken,
                attributedLength: 0,
                layoutSize: CGSize(width: safeWidth, height: safeHeight),
                textSample: fullText,
                lines: [],
                totalPoints: 0
            )
        }
        let textHeight = max(1, safeHeight - topInset - bottomInset)

        let cfLines = CTFrameGetLines(ctFrame)
        let lineCount = CFArrayGetCount(cfLines)
        guard lineCount > 0 else {
            return ChatRevealLayoutSnapshot(
                sourceRenderToken: sourceRenderToken,
                attributedLength: realLength,
                layoutSize: CGSize(width: safeWidth, height: safeHeight),
                textSample: fullText,
                lines: [],
                totalPoints: 0
            )
        }

        var origins = [CGPoint](repeating: .zero, count: lineCount)
        CTFrameGetLineOrigins(ctFrame, CFRange(location: 0, length: 0), &origins)

        struct RawLineInfo {
            let rawTop: CGFloat
            let rawBottom: CGFloat
            let inkTop: CGFloat
            let inkBottom: CGFloat
            let startPoints: Int
            let endPoints: Int
            let utf16Start: Int
            let utf16End: Int
            let hasRTL: Bool
            let units: [ChatRevealAtomicUnit]
        }

        let nsText = fullText as NSString
        let layoutBounds = CGRect(x: 0, y: 0, width: safeWidth, height: safeHeight)
        var cumulativePoints = 0
        var rawLines: [RawLineInfo] = []
        rawLines.reserveCapacity(lineCount)
        for index in 0..<lineCount {
            let line = unsafeBitCast(CFArrayGetValueAtIndex(cfLines, index), to: CTLine.self)
            let cfRange = CTLineGetStringRange(line)
            guard cfRange.location != kCFNotFound, cfRange.location < realLength else { continue }
            let clampedStart = max(0, cfRange.location)
            let clampedEnd = min(realLength, cfRange.location + cfRange.length)
            guard clampedEnd >= clampedStart else { continue }

            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            let baselineY = topInset + textHeight - origins[index].y
            let rawTop = max(0, baselineY - ascent)
            let rawBottom = max(rawTop + 1, baselineY + descent)

            let cfRuns = CTLineGetGlyphRuns(line)
            let runCount = CFArrayGetCount(cfRuns)
            var hasRTL = false
            for runIndex in 0..<runCount {
                let run = unsafeBitCast(CFArrayGetValueAtIndex(cfRuns, runIndex), to: CTRun.self)
                if CTRunGetStatus(run).contains(.rightToLeft) {
                    hasRTL = true
                    break
                }
            }

            let lineStartPoints = cumulativePoints
            let units = buildAtomicUnits(
                line: line,
                originX: origins[index].x,
                baselineY: baselineY,
                rawTop: rawTop,
                rawBottom: rawBottom,
                layoutBounds: layoutBounds,
                nsText: nsText,
                fullText: fullText,
                utf16Start: clampedStart,
                utf16End: clampedEnd,
                startingPoints: &cumulativePoints
            )
            var lineInk: CGRect = .null
            for unit in units where !unit.isWhitespace {
                lineInk = lineInk.union(unit.inkRect)
            }
            rawLines.append(RawLineInfo(
                rawTop: rawTop,
                rawBottom: rawBottom,
                inkTop: lineInk.isNull ? rawTop : max(0, lineInk.minY),
                inkBottom: lineInk.isNull ? rawBottom : min(safeHeight, lineInk.maxY),
                startPoints: lineStartPoints,
                endPoints: cumulativePoints,
                utf16Start: clampedStart,
                utf16End: clampedEnd,
                hasRTL: hasRTL,
                units: units
            ))
        }

        guard !rawLines.isEmpty else {
            return ChatRevealLayoutSnapshot(
                sourceRenderToken: sourceRenderToken,
                attributedLength: realLength,
                layoutSize: CGSize(width: safeWidth, height: safeHeight),
                textSample: fullText,
                lines: [],
                totalPoints: 0
            )
        }

        var builtLines: [ChatRevealLineLayout] = []
        builtLines.reserveCapacity(rawLines.count)
        for lineIndex in rawLines.indices {
            let info = rawLines[lineIndex]
            let bandTop = builtLines.last?.bandBottom ?? 0
            let bandBottom: CGFloat
            if lineIndex == rawLines.count - 1 {
                bandBottom = max(safeHeight, info.rawBottom + bottomInset + 2)
            } else {
                let next = rawLines[lineIndex + 1]
                let layoutMidpoint = (info.rawBottom + next.rawTop) * 0.5
                // Keep the nominal boundary in the gap between visible lines whenever their ink fits.
                let separator = info.inkBottom <= next.inkTop
                    ? min(next.inkTop, max(info.inkBottom, layoutMidpoint))
                    : (info.inkBottom + next.inkTop) * 0.5
                bandBottom = max(bandTop + 1, separator)
            }

            // Keep the frontier monotonic when an italic glyph reaches past the next glyph's advance.
            var rightEdge: CGFloat = 0
            let frontierEnds = info.units.map { unit in
                rightEdge = max(rightEdge, unit.maxX, unit.inkRect.maxX)
                return rightEdge
            }
            builtLines.append(ChatRevealLineLayout(
                bandTop: bandTop,
                bandBottom: bandBottom,
                rawTop: info.rawTop,
                rawBottom: info.rawBottom,
                hasRTL: info.hasRTL,
                startPoints: info.startPoints,
                endPoints: info.endPoints,
                utf16Start: info.utf16Start,
                utf16End: info.utf16End,
                units: info.units,
                frontierEnds: frontierEnds
            ))
        }

        return ChatRevealLayoutSnapshot(
            sourceRenderToken: sourceRenderToken,
            attributedLength: realLength,
            layoutSize: CGSize(width: safeWidth, height: safeHeight),
            textSample: fullText,
            lines: builtLines,
            totalPoints: cumulativePoints
        )
    }

    nonisolated private static func buildAtomicUnits(
        line: CTLine,
        originX: CGFloat,
        baselineY: CGFloat,
        rawTop: CGFloat,
        rawBottom: CGFloat,
        layoutBounds: CGRect,
        nsText: NSString,
        fullText: String,
        utf16Start: Int,
        utf16End: Int,
        startingPoints cumulativePoints: inout Int
    ) -> [ChatRevealAtomicUnit] {
        guard utf16End > utf16Start else { return [] }

        struct RunGlyphMetric {
            let stringRange: NSRange
            let inkRect: CGRect
            let advance: CGFloat
            let hasAttachment: Bool
        }

        // Extract true CTRun glyph-cluster spans, real ink bounding boxes, and inline attachment/formula markers.
        var ligatureRanges: [NSRange] = []
        var glyphMetrics: [RunGlyphMetric] = []
        let cfRuns = CTLineGetGlyphRuns(line)
        let runCount = CFArrayGetCount(cfRuns)
        for runIndex in 0..<runCount {
            let run = unsafeBitCast(CFArrayGetValueAtIndex(cfRuns, runIndex), to: CTRun.self)
            let isRTL = CTRunGetStatus(run).contains(.rightToLeft)
            let glyphCount = CTRunGetGlyphCount(run)
            guard glyphCount > 0 else { continue }

            let attrs = CTRunGetAttributes(run) as NSDictionary
            let hasAttachment = attrs[kCTRunDelegateAttributeName] != nil
                || attrs[NSAttributedString.Key.attachment] != nil

            var glyphIndices = [CFIndex](repeating: 0, count: glyphCount)
            var positions = [CGPoint](repeating: .zero, count: glyphCount)
            var advances = [CGSize](repeating: .zero, count: glyphCount)
            CTRunGetStringIndices(run, CFRangeMake(0, 0), &glyphIndices)
            CTRunGetPositions(run, CFRangeMake(0, 0), &positions)
            CTRunGetAdvances(run, CFRangeMake(0, 0), &advances)

            let runRange = CTRunGetStringRange(run)
            let runEnd = min(utf16End, max(utf16Start, runRange.location + runRange.length))

            for g in 0..<glyphCount {
                let startLoc = max(utf16Start, glyphIndices[g])
                guard startLoc < utf16End else { continue }
                let nextLoc: Int
                if !isRTL {
                    nextLoc = (g + 1 < glyphCount) ? min(utf16End, max(startLoc + 1, glyphIndices[g + 1])) : runEnd
                } else {
                    nextLoc = min(utf16End, startLoc + 1)
                }
                if !isRTL && nextLoc > startLoc {
                    let composed = nsText.rangeOfComposedCharacterSequence(at: startLoc)
                    if composed.location + composed.length < nextLoc {
                        ligatureRanges.append(NSRange(location: startLoc, length: nextLoc - startLoc))
                    }
                }

                let glyphRange = CFRangeMake(g, 1)
                let imageBounds: CGRect = hasAttachment ? .null : CTRunGetImageBounds(run, nil, glyphRange)
                let adv = max(0, advances[g].width)
                let glyphRect: CGRect
                if !imageBounds.isNull, !imageBounds.isEmpty,
                   imageBounds.minX.isFinite, imageBounds.minY.isFinite,
                   imageBounds.maxX.isFinite, imageBounds.maxY.isFinite {
                    // The run's image bounds use the line origin and Core Text's Y-up coordinates.
                    glyphRect = CGRect(
                        x: originX + imageBounds.minX,
                        y: baselineY - imageBounds.maxY,
                        width: imageBounds.width,
                        height: imageBounds.height
                    )
                } else if hasAttachment {
                    var ascent: CGFloat = 0
                    var descent: CGFloat = 0
                    _ = CTRunGetTypographicBounds(run, glyphRange, &ascent, &descent, nil)
                    glyphRect = CGRect(
                        x: originX + positions[g].x,
                        y: baselineY - positions[g].y - ascent,
                        width: max(1, adv),
                        height: max(1, ascent + descent)
                    )
                } else {
                    glyphRect = .null
                }

                let spanLen = max(1, nextLoc - startLoc)
                glyphMetrics.append(RunGlyphMetric(
                    stringRange: NSRange(location: startLoc, length: spanLen),
                    inkRect: glyphRect,
                    advance: adv,
                    hasAttachment: hasAttachment
                ))
            }
        }

        let bleed = ChatRevealPolicy.snippetBleedPoints
        var units: [ChatRevealAtomicUnit] = []
        var cursor = utf16Start
        while cursor < utf16End {
            var atomicRange = nsText.rangeOfComposedCharacterSequence(at: cursor)
            if atomicRange.location < cursor {
                let delta = cursor - atomicRange.location
                atomicRange = NSRange(location: cursor, length: max(1, atomicRange.length - delta))
            }
            if let ligRange = ligatureRanges.first(where: { NSLocationInRange(cursor, $0) }) {
                let endLoc = max(atomicRange.location + atomicRange.length, ligRange.location + ligRange.length)
                atomicRange = NSRange(location: cursor, length: min(utf16End, endLoc) - cursor)
            }
            if atomicRange.location + atomicRange.length > utf16End {
                atomicRange.length = utf16End - atomicRange.location
            }
            guard atomicRange.length > 0 else { break }

            let rangeEnd = atomicRange.location + atomicRange.length
            let x0 = originX + CGFloat(CTLineGetOffsetForStringIndex(line, atomicRange.location, nil))
            let x1 = originX + CGFloat(CTLineGetOffsetForStringIndex(line, rangeEnd, nil))
            let minX = max(0, min(x0, x1))
            let maxX = max(minX, max(x0, x1))
            var advance = maxX - minX

            var combinedInk: CGRect = .null
            // A plain object replacement character can survive even when attribute metadata is missing.
            var hasAttachment = (atomicRange.location..<rangeEnd).contains { nsText.character(at: $0) == 0xFFFC }
            var matchedAdvance: CGFloat = 0
            for metric in glyphMetrics {
                let mStart = metric.stringRange.location
                let mEnd = mStart + metric.stringRange.length
                if mStart < rangeEnd && mEnd > atomicRange.location {
                    combinedInk = combinedInk.union(metric.inkRect)
                    matchedAdvance += metric.advance
                    if metric.hasAttachment { hasAttachment = true }
                }
            }
            if advance < 0.5 && matchedAdvance > 0.5 {
                advance = matchedAdvance
            }

            let resolvedInk: CGRect
            if !combinedInk.isNull && !combinedInk.isEmpty {
                resolvedInk = combinedInk
            } else {
                resolvedInk = CGRect(
                    x: minX,
                    y: rawTop,
                    width: max(1, advance),
                    height: max(1, rawBottom - rawTop)
                )
            }
            let finalBleed = resolvedInk.insetBy(dx: -bleed, dy: -bleed).intersection(layoutBounds)

            let isWhitespace: Bool
            if let swiftRange = Range(atomicRange, in: fullText) {
                isWhitespace = fullText[swiftRange].allSatisfy { $0.isWhitespace || $0.isNewline }
            } else {
                isWhitespace = false
            }

            let cost = ChatRevealPacer.pointCost(forAdvance: advance, isWhitespace: isWhitespace)
            let startPts = cumulativePoints
            cumulativePoints += cost
            units.append(ChatRevealAtomicUnit(
                utf16Location: atomicRange.location,
                utf16Length: atomicRange.length,
                minX: minX,
                maxX: maxX,
                inkRect: resolvedInk,
                bleedRect: finalBleed,
                hasInlineAttachment: hasAttachment,
                isWhitespace: isWhitespace,
                startPoints: startPts,
                endPoints: cumulativePoints
            ))
            cursor = rangeEnd
        }

        return units
    }

    func unitsNewlyRevealed(from prevPoints: Double, to nextPoints: Double) -> [(lineHasRTL: Bool, units: [ChatRevealAtomicUnit])] {
        let lower = max(0.0, prevPoints)
        guard nextPoints > lower, !lines.isEmpty else { return [] }
        var groups: [(lineHasRTL: Bool, units: [ChatRevealAtomicUnit])] = []
        for line in lines {
            if Double(line.endPoints) <= lower { continue }
            if Double(line.startPoints) >= nextPoints { break }
            var lineUnits: [ChatRevealAtomicUnit] = []
            for unit in line.units {
                // Disjoint half-open partition [lower, nextPoints): every atomic glyph spawns strictly ONCE.
                if Double(unit.startPoints) < lower { continue }
                if Double(unit.startPoints) >= nextPoints { break }
                lineUnits.append(unit)
            }
            if !lineUnits.isEmpty {
                groups.append((lineHasRTL: line.hasRTL, units: lineUnits))
            }
        }
        return groups
    }

    func pointsBefore(utf16Offset: Int) -> Int {
        guard !lines.isEmpty else { return totalPoints }
        if utf16Offset <= lines[0].utf16Start { return 0 }
        if utf16Offset >= attributedLength { return totalPoints }

        var low = 0
        var high = lines.count - 1
        while low < high {
            let mid = (low + high) / 2
            if utf16Offset <= lines[mid].utf16End {
                high = mid
            } else {
                low = mid + 1
            }
        }
        return lines[low].pointsBefore(utf16Offset: utf16Offset)
    }

    func utf16Offset(forPoints points: Int) -> Int {
        guard !lines.isEmpty else { return attributedLength }
        if points <= 0 { return 0 }
        if points >= totalPoints { return attributedLength }

        var low = 0
        var high = lines.count - 1
        while low < high {
            let mid = (low + high) / 2
            if points <= lines[mid].endPoints {
                high = mid
            } else {
                low = mid + 1
            }
        }
        return lines[low].utf16Offset(forPoints: points)
    }

    enum MaskState: Equatable, Sendable {
        case hidden
        case partial(
            fullyRevealedBottom: CGFloat,
            activeBandY: CGFloat,
            activeBandHeight: CGFloat,
            activeLineHeight: CGFloat,
            frontierX: CGFloat,
            hasRTL: Bool
        )
        case complete
    }

    func maskState(forPoints points: Double) -> MaskState {
        guard totalPoints > 0, !lines.isEmpty else { return .complete }
        if points <= 0 { return .hidden }
        if points >= Double(totalPoints) { return .complete }

        var low = 0
        var high = lines.count - 1
        while low < high {
            let mid = (low + high) / 2
            if points <= Double(lines[mid].endPoints) {
                high = mid
            } else {
                low = mid + 1
            }
        }
        let line = lines[low]
        let fullyBottom: CGFloat = low > 0 ? lines[low - 1].bandBottom : 0
        let frontier = line.frontierX(forPoints: points, fallbackWidth: layoutSize.width)
        return .partial(
            fullyRevealedBottom: fullyBottom,
            activeBandY: line.bandTop,
            activeBandHeight: line.bandHeight,
            activeLineHeight: line.rawHeight,
            frontierX: min(layoutSize.width, frontier),
            hasRTL: line.hasRTL
        )
    }
}

/// Pure, nonisolated planner for `GlyphSnippetLayer` tile slicing, burst batching, animation evaluation,
/// and anti-ghosting static-mask clamping.
enum ChatRevealSnippetPlanner {
    struct TileMetrics: Equatable, Sendable {
        let y: CGFloat
        let height: CGFloat
        let pixelWidth: Int
        let pixelHeight: Int
    }

    struct SnippetBatch: Equatable, Sendable {
        let startPoints: Int
        let endPoints: Int
        let bleedRect: CGRect
        let tileIndex: Int
        let contentsRect: CGRect
    }

    struct AnimationFrame: Equatable, Sendable {
        let scale: CGFloat
        let translateY: CGFloat
        let opacity: Float
        let blurRadius: CGFloat
    }

    /// Computes exact 1:1 physical-pixel normalized `contentsRect` within a single tile.
    /// Returns `nil` whenever `bleedRect` straddles a tile seam (gracefully falling back to pure fade).
    nonisolated static func tileSlice(
        for bleedRect: CGRect,
        tiles: [TileMetrics],
        scale: CGFloat
    ) -> (tileIndex: Int, contentsRect: CGRect)? {
        guard bleedRect.width > 0.5, bleedRect.height > 0.5, scale > 0, !tiles.isEmpty else {
            return nil
        }
        let tolerance: CGFloat = 0.25 / max(1, scale)
        for (idx, tile) in tiles.enumerated() {
            let tileTop = tile.y
            let tileBottom = tile.y + tile.height
            if bleedRect.minY >= tileTop - tolerance && bleedRect.maxY <= tileBottom + tolerance {
                let tileW = CGFloat(tile.pixelWidth) / scale
                let tileH = CGFloat(tile.pixelHeight) / scale
                guard tileW > 0.5, tileH > 0.5 else { return nil }
                let localX = max(0, min(tileW, bleedRect.minX))
                let localY = max(0, min(tileH, bleedRect.minY - tileTop))
                let localMaxX = max(localX, min(tileW, bleedRect.maxX))
                let localMaxY = max(localY, min(tileH, bleedRect.maxY - tileTop))
                let normRect = CGRect(
                    x: localX / tileW,
                    y: localY / tileH,
                    width: max(0, (localMaxX - localX) / tileW),
                    height: max(0, (localMaxY - localY) / tileH)
                )
                guard normRect.width > 0, normRect.height > 0 else { return nil }
                return (idx, normRect)
            }
        }
        // Straddles a tile seam or lies outside rendered tiles -> degrade cleanly to pure fade.
        return nil
    }

    /// Plans concurrent-capped (`<= 36`) glyph-cluster snippets with 2~3 word/cluster burst batching.
    /// Automatically skips whitespace, RTL lines, inline attachments/formulas, and tile-seam spans.
    nonisolated static func planBatches(
        for units: [ChatRevealAtomicUnit],
        lineHasRTL: Bool,
        tiles: [TileMetrics],
        scale: CGFloat,
        activeCount: Int,
        maxPoolSize: Int = ChatRevealPolicy.maxConcurrentSnippets
    ) -> [SnippetBatch] {
        guard !lineHasRTL, !units.isEmpty, !tiles.isEmpty else { return [] }
        let remainingSlots = max(0, maxPoolSize - activeCount)
        guard remainingSlots > 0 else { return [] }

        var segment = 0
        let eligible = units.compactMap { unit -> (unit: ChatRevealAtomicUnit, segment: Int)? in
            if unit.hasInlineAttachment {
                segment += 1
                return nil
            }
            guard !unit.isWhitespace, unit.bleedRect.width > 0.5, unit.bleedRect.height > 0.5 else { return nil }
            return (unit, segment)
        }
        guard !eligible.isEmpty else { return [] }

        let batchSize: Int
        if eligible.count > remainingSlots {
            batchSize = max(2, Int(ceil(Double(eligible.count) / Double(remainingSlots))))
        } else if eligible.count >= 6 || activeCount >= maxPoolSize - 8 {
            batchSize = 2
        } else {
            // Normal streaming pace: animate each glyph around its own center so adjacent CJK chars never drift sideways.
            batchSize = 1
        }

        var batches: [SnippetBatch] = []
        batches.reserveCapacity(min(remainingSlots, eligible.count))

        var cursor = 0
        while cursor < eligible.count && batches.count < remainingSlots {
            let groupEnd = min(eligible.count, cursor + batchSize)
            let first = eligible[cursor]
            var mergedRect = first.unit.bleedRect
            let startPts = first.unit.startPoints
            var endPts = first.unit.endPoints
            var lastValidIdx = cursor

            if groupEnd > cursor + 1 {
                for nextIdx in (cursor + 1)..<groupEnd {
                    let next = eligible[nextIdx]
                    guard next.segment == first.segment else { break }
                    let candidateRect = mergedRect.union(next.unit.bleedRect)
                    if tileSlice(for: candidateRect, tiles: tiles, scale: scale) != nil {
                        mergedRect = candidateRect
                        endPts = next.unit.endPoints
                        lastValidIdx = nextIdx
                    } else {
                        break
                    }
                }
            }

            if let slice = tileSlice(for: mergedRect, tiles: tiles, scale: scale) {
                batches.append(SnippetBatch(
                    startPoints: startPts,
                    endPoints: endPts,
                    bleedRect: mergedRect,
                    tileIndex: slice.tileIndex,
                    contentsRect: slice.contentsRect
                ))
            }
            cursor = lastValidIdx + 1
        }
        return batches
    }

    /// Anti-ghosting invariant: static reveal mask MUST stay clamped strictly before the earliest flying snippet.
    nonisolated static func clampedStaticMaskPoints(
        cursorPoints: Double,
        lowestAnimatingStartPoints: Int?
    ) -> Double {
        guard let lowest = lowestAnimatingStartPoints else { return cursorPoints }
        return max(0, min(cursorPoints, Double(lowest)))
    }

    /// Public API 3-way baseline (`scale 0.5→1.0`, `y +6→0`, `alpha 0→1`); blur value is only consumed under `#if CLIO_ALLOW_BLUR_FILTER`.
    nonisolated static func evaluateAnimation(
        progress rawProgress: Double,
        motionEnabled: Bool
    ) -> AnimationFrame {
        let t = min(1.0, max(0.0, rawProgress))
        let eased = 1.0 - pow(1.0 - t, 3.0)
        if !motionEnabled {
            return AnimationFrame(scale: 1.0, translateY: 0.0, opacity: Float(eased), blurRadius: 0.0)
        }
        let scale = ChatRevealPolicy.snippetInitialScale + (1.0 - ChatRevealPolicy.snippetInitialScale) * CGFloat(eased)
        let translateY = ChatRevealPolicy.snippetInitialOffsetY * CGFloat(1.0 - eased)
        let blur = ChatRevealPolicy.snippetInitialBlurRadius * CGFloat(1.0 - eased)
        return AnimationFrame(scale: scale, translateY: translateY, opacity: Float(eased), blurRadius: blur)
    }
}

/// Pooled real-glyph `CALayer` flying snippet host capped strictly at 36 concurrent layers.
/// Uses exact rasterized tile slices at 1:1 physical pixel ratio; private blur filter is compile-isolated
/// under `#if CLIO_ALLOW_BLUR_FILTER`.
@MainActor
final class ChatRevealGlyphSnippetHost: CALayer {
    private struct Slot {
        let layer: CALayer
        var active: Bool = false
        var startPoints: Int = 0
        var endPoints: Int = 0
        var bornAt: CFTimeInterval = 0
        var duration: CFTimeInterval = ChatRevealPolicy.snippetDuration
    }

    private var slots: [Slot] = []
    private var tileImages: [CGImage] = []
    private var tileMetrics: [ChatRevealSnippetPlanner.TileMetrics] = []
    private var tileScale: CGFloat = 3.0
    private(set) var activeCount: Int = 0

    override init() {
        super.init()
        configurePool()
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configurePool()
    }

    private func configurePool() {
        isHidden = true
        masksToBounds = false
        slots.reserveCapacity(ChatRevealPolicy.maxConcurrentSnippets)
        for _ in 0..<ChatRevealPolicy.maxConcurrentSnippets {
            let snippet = CALayer()
            snippet.isHidden = true
            snippet.contentsGravity = .resize
            snippet.masksToBounds = true
            snippet.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            addSublayer(snippet)
            slots.append(Slot(layer: snippet))
        }
    }

    func updateTiles(_ rendered: ChatRenderedTiles, scale: CGFloat) {
        tileScale = max(1, scale)
        tileImages = rendered.tiles.map(\.image)
        tileMetrics = rendered.tiles.map {
            ChatRevealSnippetPlanner.TileMetrics(
                y: $0.y,
                height: $0.height,
                pixelWidth: $0.image.width,
                pixelHeight: $0.image.height
            )
        }
    }

    var lowestAnimatingStartPoints: Int? {
        var minStart: Int?
        for slot in slots where slot.active {
            if let existing = minStart {
                if slot.startPoints < existing { minStart = slot.startPoints }
            } else {
                minStart = slot.startPoints
            }
        }
        return minStart
    }

    func spawn(
        newlyRevealed: [(lineHasRTL: Bool, units: [ChatRevealAtomicUnit])],
        now: CFTimeInterval,
        motionEnabled: Bool
    ) {
        guard !newlyRevealed.isEmpty, !tileImages.isEmpty, !tileMetrics.isEmpty else { return }
        for group in newlyRevealed {
            let batches = ChatRevealSnippetPlanner.planBatches(
                for: group.units,
                lineHasRTL: group.lineHasRTL,
                tiles: tileMetrics,
                scale: tileScale,
                activeCount: activeCount,
                maxPoolSize: ChatRevealPolicy.maxConcurrentSnippets
            )
            for batch in batches {
                guard batch.tileIndex >= 0, batch.tileIndex < tileImages.count,
                      let slotIndex = slots.firstIndex(where: { !$0.active }) else {
                    break
                }
                let layer = slots[slotIndex].layer
                slots[slotIndex].active = true
                slots[slotIndex].startPoints = batch.startPoints
                slots[slotIndex].endPoints = batch.endPoints
                slots[slotIndex].bornAt = now
                slots[slotIndex].duration = ChatRevealPolicy.snippetDuration
                activeCount += 1

                layer.transform = CATransform3DIdentity
                layer.contents = tileImages[batch.tileIndex]
                layer.contentsScale = tileScale
                layer.contentsRect = batch.contentsRect
                layer.frame = batch.bleedRect
                applyFrame(
                    ChatRevealSnippetPlanner.evaluateAnimation(progress: 0, motionEnabled: motionEnabled),
                    to: layer,
                    motionEnabled: motionEnabled
                )
                layer.isHidden = false
                isHidden = false
            }
        }
    }

    /// Advances all active snippets atomically inside caller's `CATransaction(disableActions: true)`.
    /// Returns the lowest `startPoints` among still-flying snippets so static mask advances atomically on landing.
    func step(now: CFTimeInterval, motionEnabled: Bool) -> (lowestAnimatingStartPoints: Int?, anyActive: Bool) {
        var remainingActive = 0
        var minStart: Int?

        for idx in slots.indices {
            guard slots[idx].active else { continue }
            let elapsed = now - slots[idx].bornAt
            if elapsed >= slots[idx].duration || elapsed < 0 {
                slots[idx].active = false
                slots[idx].layer.isHidden = true
                slots[idx].layer.contents = nil
                slots[idx].layer.transform = CATransform3DIdentity
                #if CLIO_ALLOW_BLUR_FILTER
                slots[idx].layer.filters = nil
                #endif
                continue
            }
            remainingActive += 1
            if let currentMin = minStart {
                if slots[idx].startPoints < currentMin { minStart = slots[idx].startPoints }
            } else {
                minStart = slots[idx].startPoints
            }
            let frame = ChatRevealSnippetPlanner.evaluateAnimation(
                progress: elapsed / max(0.01, slots[idx].duration),
                motionEnabled: motionEnabled
            )
            applyFrame(frame, to: slots[idx].layer, motionEnabled: motionEnabled)
        }

        activeCount = remainingActive
        isHidden = remainingActive == 0
        return (minStart, remainingActive > 0)
    }

    func clear() {
        for idx in slots.indices {
            slots[idx].active = false
            slots[idx].layer.isHidden = true
            slots[idx].layer.contents = nil
            slots[idx].layer.transform = CATransform3DIdentity
            #if CLIO_ALLOW_BLUR_FILTER
            slots[idx].layer.filters = nil
            #endif
        }
        activeCount = 0
        isHidden = true
    }

    func clearTilesAndSnippets() {
        clear()
        tileImages.removeAll(keepingCapacity: true)
        tileMetrics.removeAll(keepingCapacity: true)
    }

    private func applyFrame(
        _ frame: ChatRevealSnippetPlanner.AnimationFrame,
        to layer: CALayer,
        motionEnabled: Bool
    ) {
        layer.opacity = frame.opacity
        if motionEnabled {
            var transform = CATransform3DMakeTranslation(0, frame.translateY, 0)
            transform = CATransform3DScale(transform, frame.scale, frame.scale, 1)
            layer.transform = transform
        } else {
            layer.transform = CATransform3DIdentity
        }
        #if CLIO_ALLOW_BLUR_FILTER
        if motionEnabled && frame.blurRadius > 0.05 {
            if let blur = Self.makeExperimentalBlurFilter(radius: frame.blurRadius) {
                layer.filters = [blur]
            }
        } else if layer.filters != nil {
            layer.filters = nil
        }
        #endif
    }

    #if CLIO_ALLOW_BLUR_FILTER
    private static func makeExperimentalBlurFilter(radius: CGFloat) -> NSObject? {
        guard let filterClass = NSClassFromString("CAFilter") as? NSObject.Type else { return nil }
        let selector = NSSelectorFromString("filterWithName:")
        guard filterClass.responds(to: selector),
              let unmanaged = filterClass.perform(selector, with: "gaussianBlur"),
              let filter = unmanaged.takeUnretainedValue() as? NSObject else {
            return nil
        }
        filter.setValue(NSNumber(value: Double(radius)), forKey: "inputRadius")
        return filter
    }
    #endif
}

/// Target protocol driven cleanly by `ChatRevealDisplayDriver` without retaining cells or views.
@MainActor
protocol ChatRevealDisplayClient: AnyObject {
    func revealDisplayTick(now: CFTimeInterval)
}

/// Associates active reveal clients with the application's shared frame clock.
@MainActor
final class ChatRevealDisplayDriver {
    static let shared = ChatRevealDisplayDriver()

    private var links: [ObjectIdentifier: SharedFrameLink] = [:]

    func register<T: UIView & ChatRevealDisplayClient>(_ client: T) {
        let key = ObjectIdentifier(client)
        guard client.window != nil, !client.isHidden, links[key] == nil else { return }
        links[key] = SharedFrameDriver.shared.add(rate: .max, isActive: { [weak self, weak client] in
            guard let client else {
                self?.links.removeValue(forKey: key)
                return false
            }
            return client.window != nil && !client.isHidden
        }) { [weak client] _ in
            client?.revealDisplayTick(now: CACurrentMediaTime())
        }
    }

    func unregister(_ client: ChatRevealDisplayClient) {
        links.removeValue(forKey: ObjectIdentifier(client))?.invalidate()
    }
}

/// Zero-allocation O(1) CALayer mask coordinator paired with pooled `ChatRevealGlyphSnippetHost`.
@MainActor
final class ChatRevealMaskCoordinator {
    private let maskRoot = CALayer()
    private let prefixLayer = CALayer()
    private let activeOpaqueLayer = CALayer()
    private let featherLayer = CAGradientLayer()
    let snippetHost = ChatRevealGlyphSnippetHost()

    init() {
        maskRoot.backgroundColor = nil
        prefixLayer.backgroundColor = UIColor.white.cgColor
        activeOpaqueLayer.backgroundColor = UIColor.white.cgColor

        featherLayer.colors = [UIColor.white.cgColor, UIColor.clear.cgColor]
        featherLayer.startPoint = CGPoint(x: 0, y: 0.5)
        featherLayer.endPoint = CGPoint(x: 1, y: 0.5)

        maskRoot.addSublayer(prefixLayer)
        maskRoot.addSublayer(activeOpaqueLayer)
        maskRoot.addSublayer(featherLayer)
    }

    /// Locks the static mask to hidden/current state BEFORE tile contents are written (anti-flash redline).
    func lockMaskBeforeTileContents(
        maskState: ChatRevealLayoutSnapshot.MaskState,
        bounds: CGRect,
        tileRoot: CALayer,
        overlayHost: CALayer,
        useFeather: Bool = true
    ) {
        applyStaticMask(
            maskState: maskState,
            bounds: bounds,
            tileRoot: tileRoot,
            overlayHost: overlayHost,
            useFeather: useFeather
        )
    }

    func updateTiles(_ rendered: ChatRenderedTiles, scale: CGFloat) {
        snippetHost.updateTiles(rendered, scale: scale)
    }

    /// Must be called inside `CATransaction.setDisableActions(true)`.
    func apply(
        snapshot: ChatRevealLayoutSnapshot,
        cursorPoints: Double,
        newlyRevealed: [(lineHasRTL: Bool, units: [ChatRevealAtomicUnit])],
        bounds: CGRect,
        allowsSnippets: Bool,
        motionEnabled: Bool,
        now: CFTimeInterval,
        tileRoot: CALayer,
        overlayHost: CALayer
    ) {
        snippetHost.frame = bounds
        if allowsSnippets && !newlyRevealed.isEmpty {
            attachOverlayHostIfNeeded(overlayHost, bounds: bounds)
            snippetHost.spawn(newlyRevealed: newlyRevealed, now: now, motionEnabled: motionEnabled)
        }

        let stepResult = snippetHost.step(now: now, motionEnabled: motionEnabled)
        let clampedPoints = ChatRevealSnippetPlanner.clampedStaticMaskPoints(
            cursorPoints: cursorPoints,
            lowestAnimatingStartPoints: stepResult.lowestAnimatingStartPoints
        )
        let maskState = snapshot.maskState(forPoints: clampedPoints)
        // When flying snippets own the leading edge, characters strictly before lowestAnimatingStartPoints
        // have ALREADY landed at full opacity — never fade them backward with a trailing feather gradient.
        applyStaticMask(
            maskState: maskState,
            bounds: bounds,
            tileRoot: tileRoot,
            overlayHost: overlayHost,
            useFeather: !stepResult.anyActive
        )
    }

    private func applyStaticMask(
        maskState: ChatRevealLayoutSnapshot.MaskState,
        bounds: CGRect,
        tileRoot: CALayer,
        overlayHost: CALayer,
        useFeather: Bool
    ) {
        switch maskState {
        case .complete:
            if snippetHost.activeCount == 0 {
                tileRoot.mask = nil
            } else {
                attachMaskIfNeeded(to: tileRoot, overlayHost: overlayHost, bounds: bounds)
                maskRoot.frame = bounds
                prefixLayer.isHidden = false
                prefixLayer.frame = bounds
                activeOpaqueLayer.isHidden = true
                featherLayer.isHidden = true
            }

        case .hidden:
            attachMaskIfNeeded(to: tileRoot, overlayHost: overlayHost, bounds: bounds)
            maskRoot.frame = bounds
            prefixLayer.isHidden = true
            activeOpaqueLayer.isHidden = true
            featherLayer.isHidden = true

        case let .partial(fullyBottom, bandY, bandHeight, lineHeight, frontierX, hasRTL):
            attachMaskIfNeeded(to: tileRoot, overlayHost: overlayHost, bounds: bounds)
            maskRoot.frame = bounds

            if fullyBottom > 0.5 {
                prefixLayer.isHidden = false
                prefixLayer.frame = CGRect(x: 0, y: 0, width: bounds.width, height: fullyBottom)
            } else {
                prefixLayer.isHidden = true
            }

            guard bandHeight > 0 else {
                activeOpaqueLayer.isHidden = true
                featherLayer.isHidden = true
                return
            }

            if hasRTL {
                activeOpaqueLayer.isHidden = false
                activeOpaqueLayer.frame = CGRect(x: 0, y: bandY, width: bounds.width, height: bandHeight)
                featherLayer.isHidden = true
                return
            }

            let clampedFrontier = max(0, min(bounds.width, frontierX))
            let feather = useFeather ? ChatRevealPolicy.featherWidth(forLineHeight: lineHeight) : 0
            let solidWidth = max(0, clampedFrontier - feather)

            if solidWidth > 0.5 {
                activeOpaqueLayer.isHidden = false
                activeOpaqueLayer.frame = CGRect(x: 0, y: bandY, width: solidWidth, height: bandHeight)
            } else {
                activeOpaqueLayer.isHidden = true
            }

            let featherStartX = solidWidth
            let featherActualW = max(0, clampedFrontier - featherStartX)
            if useFeather && featherActualW > 0.5 {
                featherLayer.isHidden = false
                featherLayer.frame = CGRect(x: featherStartX, y: bandY, width: featherActualW, height: bandHeight)
            } else {
                featherLayer.isHidden = true
            }
        }
    }

    func clearFlyingSnippets() {
        snippetHost.clear()
    }

    func detach(from tileRoot: CALayer) {
        tileRoot.mask = nil
        prefixLayer.isHidden = true
        activeOpaqueLayer.isHidden = true
        featherLayer.isHidden = true
        snippetHost.clearTilesAndSnippets()
        snippetHost.removeFromSuperlayer()
    }

    private func attachOverlayHostIfNeeded(_ overlayHost: CALayer, bounds: CGRect) {
        if snippetHost.superlayer !== overlayHost {
            snippetHost.frame = bounds
            overlayHost.addSublayer(snippetHost)
        }
    }

    private func attachMaskIfNeeded(to tileRoot: CALayer, overlayHost: CALayer, bounds: CGRect) {
        if tileRoot.mask !== maskRoot {
            tileRoot.mask = maskRoot
        }
        attachOverlayHostIfNeeded(overlayHost, bounds: bounds)
    }
}

/// Captures in-progress reveal cursor across sealed-tail splits or structural streaming -> settled commit.
struct ChatRevealHandoff: Equatable, Sendable {
    let tailText: String
    let remainingRevealedUTF16: Int
    let globalCursorPoints: Double?
    let wasFinalizing: Bool
    let capturedAt: CFTimeInterval
    var startsAtBeginning = false

    init(
        tailText: String,
        remainingRevealedUTF16: Int,
        globalCursorPoints: Double? = nil,
        wasFinalizing: Bool,
        capturedAt: CFTimeInterval,
        startsAtBeginning: Bool = false
    ) {
        self.tailText = tailText
        self.remainingRevealedUTF16 = remainingRevealedUTF16
        self.globalCursorPoints = globalCursorPoints
        self.wasFinalizing = wasFinalizing
        self.capturedAt = capturedAt
        self.startsAtBeginning = startsAtBeginning
    }

    static var unseenReply: ChatRevealHandoff {
        ChatRevealHandoff(
            tailText: "", remainingRevealedUTF16: 0, globalCursorPoints: 0, wasFinalizing: false,
            capturedAt: 0, startsAtBeginning: true
        )
    }
}

/// Pure, message-level unified cross-block reveal timeline spanning sealed paragraphs, live tail,
/// code blocks, tables, formulas, file cards, and pictures under one monotonic progress cursor.
struct MessageRevealTimeline: Equatable, Sendable {
    enum SliceKind: Equatable, Sendable {
        case richText
        case code
        case table
        case math
        case fileCards
        case pictures
    }

    struct SliceSpec: Equatable, Sendable {
        let id: String
        let kind: SliceKind
        let weightPoints: Int

        init(id: String, kind: SliceKind, weightPoints: Int) {
            self.id = id
            self.kind = kind
            self.weightPoints = max(1, weightPoints)
        }
    }

    struct SliceInterval: Equatable, Sendable {
        let spec: SliceSpec
        let startPoints: Int
        let endPoints: Int
    }

    enum SliceRevealState: Equatable, Sendable {
        case hidden
        case revealing(localPoints: Double, progress: Double)
        case complete
    }

    let intervals: [SliceInterval]
    let totalPoints: Int

    init(slices: [SliceSpec]) {
        var built: [SliceInterval] = []
        built.reserveCapacity(slices.count)
        var cursor = 0
        for spec in slices {
            let start = cursor
            cursor += spec.weightPoints
            built.append(SliceInterval(spec: spec, startPoints: start, endPoints: cursor))
        }
        self.intervals = built
        self.totalPoints = cursor
    }

    func state(forSliceAt index: Int, cursorPoints: Double) -> SliceRevealState {
        guard index >= 0 && index < intervals.count else { return .complete }
        let interval = intervals[index]
        if cursorPoints <= Double(interval.startPoints) {
            return .hidden
        }
        if cursorPoints >= Double(interval.endPoints) {
            return .complete
        }
        let local = cursorPoints - Double(interval.startPoints)
        let span = Double(max(1, interval.endPoints - interval.startPoints))
        return .revealing(localPoints: local, progress: min(1.0, max(0.0, local / span)))
    }

    func activeSliceIndex(forCursor cursorPoints: Double) -> Int? {
        guard !intervals.isEmpty else { return nil }
        if cursorPoints <= 0 { return 0 }
        if cursorPoints >= Double(totalPoints) { return intervals.count - 1 }
        for (idx, interval) in intervals.enumerated() {
            if cursorPoints <= Double(interval.endPoints) {
                return idx
            }
        }
        return intervals.count - 1
    }

    /// Compact proportional reveal weight for non-text block slices (code/table/math/cards/pictures).
    static func blockWeight(forHeight height: CGFloat) -> Int {
        max(36, min(140, Int((max(24, height) * 0.55).rounded())))
    }

    /// Estimated glyph-width point weight for a rich-text slice before its CoreText snapshot returns.
    static func estimatedTextWeight(attributedLength: Int, fontSize: CGFloat) -> Int {
        max(1, Int((Double(max(1, attributedLength)) * Double(max(10, fontSize)) * 0.72).rounded()))
    }

    /// Script-aware glyph-width point estimator matching CoreText CJK (~1.0em) vs Latin (~0.56em) advances closely
    /// so freshly merged sealed slices never severely underestimate total points before their async tile returns.
    static func estimatedTextWeight(text: String, fontSize: CGFloat) -> Int {
        guard !text.isEmpty else { return 1 }
        let em = Double(max(10, fontSize))
        var total: Double = 0
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if scalar.properties.isWhitespace {
                total += min(4.0, em * 0.22)
            } else if (0x2E80...0x9FFF).contains(v) || (0xAC00...0xD7AF).contains(v) || (0xFF00...0xFFEF).contains(v) || (0x3000...0x303F).contains(v) {
                total += em
            } else {
                total += em * 0.56
            }
        }
        return max(1, Int(total.rounded()))
    }
}

/// Message-level reveal coordinator driving one global monotonic cursor across every slice in a reply.
/// Eliminates `\n\n` paragraph sealing pop-outs and unifies text, code, tables, and formulas.
@MainActor
final class MessageRevealCoordinator {
    private(set) var timeline: MessageRevealTimeline
    private var controller: TextRevealController
    private(set) var cursorPoints: Double
    private(set) var isComplete: Bool
    private var pace: Pref.RevealPace
    private var lastDisplayTime: CFTimeInterval
    private var lastClock: CFTimeInterval
    private var updateCount: Int

    init(
        slices: [MessageRevealTimeline.SliceSpec],
        initialCursorPoints: Double = 0,
        finalizeImmediately: Bool = false,
        pace: Pref.RevealPace = .balanced,
        now: CFTimeInterval = CACurrentMediaTime()
    ) {
        let timeline = MessageRevealTimeline(slices: slices)
        self.timeline = timeline
        self.pace = pace
        self.lastClock = now
        self.lastDisplayTime = now

        let clamped = min(Double(timeline.totalPoints), max(0, initialCursorPoints))
        self.cursorPoints = clamped
        let prof = ChatRevealPacer.profile(for: pace)
        self.controller = TextRevealController(
            initialRevealedCount: Int(clamped),
            initialLength: timeline.totalPoints,
            durationMultiplier: prof.durationMultiplier
        )
        self.updateCount = 1

        if finalizeImmediately {
            controller.finalize(finalLength: timeline.totalPoints)
        } else {
            controller.observeUpdate(latestLength: timeline.totalPoints, at: now)
        }
        _ = controller.tick(now: now)
        self.isComplete = timeline.totalPoints == 0
            || (controller.isFinalizing && clamped >= Double(timeline.totalPoints))
    }

    var isFinalizing: Bool { controller.isFinalizing }

    var backlogPoints: Int {
        max(0, timeline.totalPoints - Int(cursorPoints))
    }

    func update(
        slices: [MessageRevealTimeline.SliceSpec],
        isLive: Bool,
        pace nextPace: Pref.RevealPace,
        now: CFTimeInterval = CACurrentMediaTime()
    ) {
        let clock = max(lastClock, now)
        lastClock = clock
        let nextTimeline = MessageRevealTimeline(slices: slices)
        let prevTotal = timeline.totalPoints
        var prefixShift = 0
        if let activeIdx = timeline.activeSliceIndex(forCursor: cursorPoints),
           activeIdx < timeline.intervals.count {
            let activeInterval = timeline.intervals[activeIdx]
            if let matchingNext = nextTimeline.intervals.first(where: { $0.spec.id == activeInterval.spec.id }) {
                prefixShift = matchingNext.startPoints - activeInterval.startPoints
            }
        }
        timeline = nextTimeline

        if pace != nextPace {
            pace = nextPace
            controller.durationMultiplier = ChatRevealPacer.profile(for: nextPace).durationMultiplier
        }

        if prefixShift != 0 {
            cursorPoints = min(Double(nextTimeline.totalPoints), max(0, cursorPoints + Double(prefixShift)))
            let wasFinalizing = controller.isFinalizing
            controller = TextRevealController(
                initialRevealedCount: Int(cursorPoints),
                initialLength: nextTimeline.totalPoints,
                durationMultiplier: ChatRevealPacer.profile(for: pace).durationMultiplier
            )
            if wasFinalizing || !isLive {
                controller.finalize(finalLength: nextTimeline.totalPoints)
            }
        }

        if nextTimeline.totalPoints > prevTotal {
            updateCount += 1
        }
        // Never rewind cursorPoints backward during live streaming when a freshly merged slice temporarily
        // uses an estimated weight before its exact CoreText snapshot arrives; only clamp when finalizing or empty.
        if (!isLive || nextTimeline.totalPoints == 0) && cursorPoints > Double(nextTimeline.totalPoints) {
            cursorPoints = Double(nextTimeline.totalPoints)
        }

        if isLive {
            controller.observeUpdate(latestLength: nextTimeline.totalPoints, at: clock)
        } else {
            controller.finalize(finalLength: nextTimeline.totalPoints)
        }
        isComplete = nextTimeline.totalPoints == 0
            || (controller.isFinalizing && cursorPoints >= Double(nextTimeline.totalPoints))
    }

    func markFinalizing(now: CFTimeInterval = CACurrentMediaTime()) {
        guard !controller.isFinalizing else { return }
        let clock = max(lastClock, now)
        lastClock = clock
        controller.finalize(finalLength: timeline.totalPoints)
        if cursorPoints >= Double(timeline.totalPoints) {
            isComplete = true
        }
    }

    func step(now: CFTimeInterval) -> (cursorPoints: Double, isComplete: Bool) {
        guard !isComplete else {
            return (Double(timeline.totalPoints), true)
        }
        let clock = max(lastClock, now)
        lastClock = clock
        _ = controller.tick(now: clock)
        let elapsed = clock - lastDisplayTime
        lastDisplayTime = clock

        cursorPoints = ChatRevealPacer.stepCursor(
            current: cursorPoints,
            controllerTarget: controller.revealedCount,
            totalPoints: timeline.totalPoints,
            elapsed: elapsed,
            pace: pace,
            hasRateSample: updateCount >= 2,
            isFinalizing: controller.isFinalizing
        )
        isComplete = controller.isFinalizing && cursorPoints >= Double(timeline.totalPoints)
        return (cursorPoints, isComplete)
    }

    func revealAll() {
        cursorPoints = Double(timeline.totalPoints)
        controller.finalize(finalLength: timeline.totalPoints)
        isComplete = true
    }

    func sliceState(at index: Int) -> MessageRevealTimeline.SliceRevealState {
        if isComplete { return .complete }
        return timeline.state(forSliceAt: index, cursorPoints: cursorPoints)
    }

    func makeHandoff(tailText: String, tailRevealedUTF16: Int, now: CFTimeInterval = CACurrentMediaTime()) -> ChatRevealHandoff? {
        guard !isComplete else { return nil }
        return ChatRevealHandoff(
            tailText: tailText,
            remainingRevealedUTF16: max(0, tailRevealedUTF16),
            globalCursorPoints: cursorPoints,
            wasFinalizing: controller.isFinalizing,
            capturedAt: now
        )
    }
}

/// Stateful standalone streaming reveal session wrapping Telegram's verbatim `TextRevealController`
/// + `ChatRevealPacer` (used by standalone `ChatRichTextView` or direct tests).
@MainActor
final class ChatRevealSession {
    private var controller: TextRevealController
    private(set) var snapshot: ChatRevealLayoutSnapshot
    private(set) var isComplete = false
    private var displayedPoints: Double
    private var pace: Pref.RevealPace
    private var lastDisplayTime: CFTimeInterval
    private var lastClock: CFTimeInterval
    private var updateCount: Int

    static func resolveInitialUTF16(handoff: ChatRevealHandoff, in targetText: String) -> Int? {
        let targetNS = targetText as NSString
        guard targetNS.length > 0 else { return nil }
        if handoff.startsAtBeginning { return 0 }
        if targetText == handoff.tailText {
            return max(0, min(targetNS.length, handoff.remainingRevealedUTF16))
        }
        let tailNS = handoff.tailText as NSString
        guard tailNS.length > 0 else { return nil }
        // Case A: tailText merged at the end of a committed reply (match tailText prefix in targetText).
        let tailAnchorLen = min(32, tailNS.length)
        let tailAnchor = tailNS.substring(to: tailAnchorLen)
        let foundInTarget = targetNS.range(of: tailAnchor, options: .backwards)
        if foundInTarget.location != NSNotFound {
            return max(0, min(targetNS.length, foundInTarget.location + handoff.remainingRevealedUTF16))
        }
        // Case B: earlier prefix sealed away in-place so targetText is the suffix of tailText.
        let targetAnchorLen = min(32, targetNS.length)
        let targetAnchor = targetNS.substring(to: targetAnchorLen)
        let foundInTail = tailNS.range(of: targetAnchor, options: .backwards)
        if foundInTail.location != NSNotFound {
            return max(0, min(targetNS.length, handoff.remainingRevealedUTF16 - foundInTail.location))
        }
        return nil
    }

    init(
        snapshot: ChatRevealLayoutSnapshot,
        initialRevealedUTF16: Int = 0,
        finalizeImmediately: Bool = false,
        pace: Pref.RevealPace = .balanced,
        now: CFTimeInterval = CACurrentMediaTime()
    ) {
        self.snapshot = snapshot
        self.pace = pace
        self.lastClock = now

        let clampedOffset = max(0, min(snapshot.attributedLength, initialRevealedUTF16))
        let initialPoints = snapshot.pointsBefore(utf16Offset: clampedOffset)
        self.displayedPoints = Double(initialPoints)
        self.lastDisplayTime = now
        self.updateCount = 1

        let prof = ChatRevealPacer.profile(for: pace)
        self.controller = TextRevealController(
            initialRevealedCount: initialPoints,
            initialLength: snapshot.totalPoints,
            durationMultiplier: prof.durationMultiplier
        )

        if finalizeImmediately {
            self.controller.finalize(finalLength: snapshot.totalPoints)
        } else {
            self.controller.observeUpdate(latestLength: snapshot.totalPoints, at: now)
        }
        _ = self.controller.tick(now: now)

        if snapshot.totalPoints == 0 || (controller.isFinalizing && displayedPoints >= Double(snapshot.totalPoints)) {
            self.isComplete = true
        }
    }

    var currentPoints: Double { displayedPoints }

    var currentRevealedUTF16: Int {
        snapshot.utf16Offset(forPoints: Int(displayedPoints))
    }

    var isFinalizing: Bool { controller.isFinalizing }

    var backlogPoints: Int {
        max(0, snapshot.totalPoints - Int(displayedPoints))
    }

    func update(
        snapshot nextSnapshot: ChatRevealLayoutSnapshot,
        isLive: Bool,
        pace nextPace: Pref.RevealPace = .balanced,
        now: CFTimeInterval = CACurrentMediaTime()
    ) {
        let clock = max(lastClock, now)
        lastClock = clock

        if pace != nextPace {
            pace = nextPace
            controller.durationMultiplier = ChatRevealPacer.profile(for: nextPace).durationMultiplier
        }

        let prevRevealedUTF16 = currentRevealedUTF16
        let prevLength = snapshot.attributedLength
        let prevTotal = snapshot.totalPoints
        let textShrunk = nextSnapshot.attributedLength < prevLength
            || (!nextSnapshot.textSample.hasPrefix(snapshot.textSample)
                && Self.commonUTF16PrefixLength(snapshot.textSample, nextSnapshot.textSample) < max(0, prevRevealedUTF16 - 4))

        self.snapshot = nextSnapshot

        if textShrunk {
            let clamped = max(0, min(nextSnapshot.attributedLength, prevRevealedUTF16))
            let remappedPoints = nextSnapshot.pointsBefore(utf16Offset: clamped)
            self.controller = TextRevealController(
                initialRevealedCount: remappedPoints,
                initialLength: nextSnapshot.totalPoints,
                durationMultiplier: ChatRevealPacer.profile(for: pace).durationMultiplier
            )
            displayedPoints = Double(remappedPoints)
            updateCount = 1
        } else if nextSnapshot.totalPoints > prevTotal {
            updateCount += 1
        }
        displayedPoints = min(displayedPoints, Double(nextSnapshot.totalPoints))

        if isLive {
            controller.observeUpdate(latestLength: nextSnapshot.totalPoints, at: clock)
        } else {
            controller.finalize(finalLength: nextSnapshot.totalPoints)
        }
        isComplete = nextSnapshot.totalPoints == 0
            || (controller.isFinalizing && displayedPoints >= Double(nextSnapshot.totalPoints))
    }

    func markFinalizing(now: CFTimeInterval = CACurrentMediaTime()) {
        guard !controller.isFinalizing else { return }
        let clock = max(lastClock, now)
        lastClock = clock
        controller.finalize(finalLength: snapshot.totalPoints)
        if displayedPoints >= Double(snapshot.totalPoints) {
            isComplete = true
        }
    }

    func revealAll() {
        displayedPoints = Double(snapshot.totalPoints)
        controller.finalize(finalLength: snapshot.totalPoints)
        isComplete = true
    }

    func step(now: CFTimeInterval) -> (
        prevPoints: Double,
        nextPoints: Double,
        maskState: ChatRevealLayoutSnapshot.MaskState,
        backlogPoints: Int,
        isComplete: Bool
    ) {
        guard !isComplete else {
            let total = Double(snapshot.totalPoints)
            return (total, total, .complete, 0, true)
        }
        let clock = max(lastClock, now)
        lastClock = clock
        _ = controller.tick(now: clock)
        let prev = displayedPoints
        let elapsed = clock - lastDisplayTime
        lastDisplayTime = clock

        displayedPoints = ChatRevealPacer.stepCursor(
            current: prev,
            controllerTarget: controller.revealedCount,
            totalPoints: snapshot.totalPoints,
            elapsed: elapsed,
            pace: pace,
            hasRateSample: updateCount >= 2,
            isFinalizing: controller.isFinalizing
        )
        let maskState = snapshot.maskState(forPoints: displayedPoints)
        isComplete = maskState == .complete && controller.isFinalizing
        return (prev, displayedPoints, maskState, backlogPoints, isComplete)
    }

    func currentMaskState() -> ChatRevealLayoutSnapshot.MaskState {
        if isComplete { return .complete }
        return snapshot.maskState(forPoints: displayedPoints)
    }

    func makeHandoff(sealedPrefixUTF16: Int = 0, now: CFTimeInterval = CACurrentMediaTime()) -> ChatRevealHandoff? {
        guard !isComplete else { return nil }
        let safePrefix = max(0, sealedPrefixUTF16)
        let nsText = snapshot.textSample as NSString
        let tailText: String
        if safePrefix > 0 && safePrefix <= nsText.length {
            tailText = nsText.substring(from: safePrefix)
        } else if safePrefix > nsText.length {
            tailText = ""
        } else {
            tailText = snapshot.textSample
        }
        let remaining = max(0, currentRevealedUTF16 - safePrefix)
        return ChatRevealHandoff(
            tailText: tailText,
            remainingRevealedUTF16: remaining,
            wasFinalizing: controller.isFinalizing,
            capturedAt: now
        )
    }

    private static func commonUTF16PrefixLength(_ lhs: String, _ rhs: String) -> Int {
        let a = lhs.utf16
        let b = rhs.utf16
        var count = 0
        var ia = a.startIndex
        var ib = b.startIndex
        while ia < a.endIndex, ib < b.endIndex, a[ia] == b[ib] {
            count += 1
            ia = a.index(after: ia)
            ib = b.index(after: ib)
        }
        return count
    }
}
