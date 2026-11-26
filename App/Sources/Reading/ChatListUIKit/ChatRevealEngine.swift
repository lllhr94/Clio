import CoreText
import Foundation
import QuartzCore
import UIKit

/// Device, accessibility, and burst-budget gate for Telegram-backed live text reveal.
@MainActor
enum ChatRevealPolicy {
    static let durationMultiplier: Double = 2.0
    static let maxTailAttributedLength: Int = 6_000
    static let snippetMaxBacklogPoints: Int = 120

    nonisolated static func pacedPoints(current: Double, target: Double, total: Int, elapsed: Double) -> Double {
        let remaining = max(0, Double(total) - current)
        let dt = min(max(0, elapsed), 0.05)
        // Work through a large initial chunk even before a second chunk supplies an arrival-rate sample.
        let catchup = current + dt * max(0, remaining - 120) * 0.36
        let rate = max(120 + min(240, remaining * 0.25), remaining / 2.2)
        return min(Double(total), max(target, catchup, current), current + dt * rate)
    }

    static func isEligible(fade: Bool, reduceMotion: Bool, attributedLength: Int) -> Bool {
        fade && !reduceMotion && attributedLength > 0 && attributedLength <= maxTailAttributedLength
    }

    static func allowsSnippets(
        fade: Bool,
        reduceMotion: Bool,
        attributedLength: Int,
        tileCount: Int,
        backlogPoints: Int
    ) -> Bool {
        guard isEligible(fade: fade, reduceMotion: reduceMotion, attributedLength: attributedLength),
              tileCount == 1,
              backlogPoints <= snippetMaxBacklogPoints else {
            return false
        }
        let info = ProcessInfo.processInfo
        guard !info.isLowPowerModeEnabled else { return false }
        switch info.thermalState {
        case .serious, .critical:
            return false
        default:
            return true
        }
    }

    static func featherWidth(forLineHeight lineHeight: CGFloat) -> CGFloat {
        min(22.0, max(12.0, lineHeight * 0.85))
    }
}

/// Atomic glyph/ligature/emoji cluster mapped to cumulative CoreText width-cost points.
struct ChatRevealAtomicUnit: Equatable, Sendable {
    let utf16Location: Int
    let utf16Length: Int
    let minX: CGFloat
    let maxX: CGFloat
    let startPoints: Int
    let endPoints: Int

    var utf16End: Int { utf16Location + utf16Length }
    var costPoints: Int { max(0, endPoints - startPoints) }
}

/// Per-line CoreText band coordinates and ordered atomic units for zero-allocation masking.
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

    var bandHeight: CGFloat { max(0, bandBottom - bandTop) }
    var rawHeight: CGFloat { max(1, rawBottom - rawTop) }

    func frontierX(forPoints points: Double, fallbackWidth: CGFloat) -> CGFloat {
        guard !units.isEmpty else { return fallbackWidth }
        if points <= Double(startPoints) { return max(0, units[0].minX) }
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
        let span = Double(unit.costPoints)
        let progress: CGFloat
        if span > 0 {
            progress = min(1, max(0, CGFloat((points - Double(unit.startPoints)) / span)))
        } else {
            progress = 1
        }
        return max(0, unit.minX + (unit.maxX - unit.minX) * progress)
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

/// CoreText line + grapheme/ligature layout matching `ChatTextTileRenderer.render` coordinates bit-for-bit.
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
            let ctLine: CTLine
            let originX: CGFloat
            let rawTop: CGFloat
            let rawBottom: CGFloat
            let utf16Start: Int
            let utf16End: Int
            let hasRTL: Bool
        }

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

            rawLines.append(RawLineInfo(
                ctLine: line,
                originX: origins[index].x,
                rawTop: rawTop,
                rawBottom: rawBottom,
                utf16Start: clampedStart,
                utf16End: clampedEnd,
                hasRTL: hasRTL
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

        let nsText = fullText as NSString
        var builtLines: [ChatRevealLineLayout] = []
        builtLines.reserveCapacity(rawLines.count)
        var cumulativePoints = 0

        for lineIndex in rawLines.indices {
            let info = rawLines[lineIndex]
            let bandTop: CGFloat
            if lineIndex == 0 {
                bandTop = 0
            } else {
                let prevBottom = rawLines[lineIndex - 1].rawBottom
                let mid = (prevBottom + info.rawTop) * 0.5
                bandTop = max(builtLines[lineIndex - 1].bandTop + 1, mid)
            }

            let bandBottom: CGFloat
            if lineIndex == rawLines.count - 1 {
                bandBottom = max(safeHeight, info.rawBottom + bottomInset + 2)
            } else {
                let nextTop = rawLines[lineIndex + 1].rawTop
                let mid = (info.rawBottom + nextTop) * 0.5
                bandBottom = max(bandTop + 1, mid)
            }

            let lineStartPoints = cumulativePoints
            let units = buildAtomicUnits(
                line: info.ctLine,
                originX: info.originX,
                nsText: nsText,
                fullText: fullText,
                utf16Start: info.utf16Start,
                utf16End: info.utf16End,
                startingPoints: &cumulativePoints
            )

            builtLines.append(ChatRevealLineLayout(
                bandTop: bandTop,
                bandBottom: bandBottom,
                rawTop: info.rawTop,
                rawBottom: info.rawBottom,
                hasRTL: info.hasRTL,
                startPoints: lineStartPoints,
                endPoints: cumulativePoints,
                utf16Start: info.utf16Start,
                utf16End: info.utf16End,
                units: units
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
        nsText: NSString,
        fullText: String,
        utf16Start: Int,
        utf16End: Int,
        startingPoints cumulativePoints: inout Int
    ) -> [ChatRevealAtomicUnit] {
        guard utf16End > utf16Start else { return [] }

        // Gather glyph cluster spans so multi-grapheme ligatures stay atomic.
        var ligatureRanges: [NSRange] = []
        let cfRuns = CTLineGetGlyphRuns(line)
        let runCount = CFArrayGetCount(cfRuns)
        for runIndex in 0..<runCount {
            let run = unsafeBitCast(CFArrayGetValueAtIndex(cfRuns, runIndex), to: CTRun.self)
            guard !CTRunGetStatus(run).contains(.rightToLeft) else { continue }
            let glyphCount = CTRunGetGlyphCount(run)
            guard glyphCount > 0 else { continue }
            var glyphIndices = [CFIndex](repeating: 0, count: glyphCount)
            CTRunGetStringIndices(run, CFRangeMake(0, 0), &glyphIndices)
            let runRange = CTRunGetStringRange(run)
            let runEnd = min(utf16End, max(utf16Start, runRange.location + runRange.length))
            for g in 0..<glyphCount {
                let startLoc = max(utf16Start, glyphIndices[g])
                guard startLoc < utf16End else { continue }
                let nextLoc = (g + 1 < glyphCount) ? min(utf16End, glyphIndices[g + 1]) : runEnd
                if nextLoc > startLoc {
                    let composed = nsText.rangeOfComposedCharacterSequence(at: startLoc)
                    if composed.location + composed.length < nextLoc {
                        ligatureRanges.append(NSRange(location: startLoc, length: nextLoc - startLoc))
                    }
                }
            }
        }

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

            let x0 = originX + CGFloat(CTLineGetOffsetForStringIndex(line, atomicRange.location, nil))
            let x1 = originX + CGFloat(CTLineGetOffsetForStringIndex(line, atomicRange.location + atomicRange.length, nil))
            let minX = max(0, min(x0, x1))
            let maxX = max(minX, max(x0, x1))
            let advance = maxX - minX

            let isWhitespace: Bool
            if let swiftRange = Range(atomicRange, in: fullText) {
                isWhitespace = fullText[swiftRange].allSatisfy { $0.isWhitespace || $0.isNewline }
            } else {
                isWhitespace = false
            }

            let cost: Int
            if isWhitespace {
                cost = 1
            } else {
                cost = max(1, Int(ceil(max(4.0, advance) / 8.0)))
            }

            let startPts = cumulativePoints
            cumulativePoints += cost
            units.append(ChatRevealAtomicUnit(
                utf16Location: atomicRange.location,
                utf16Length: atomicRange.length,
                minX: minX,
                maxX: maxX,
                startPoints: startPts,
                endPoints: cumulativePoints
            ))
            cursor = atomicRange.location + atomicRange.length
        }

        return units
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

    enum MaskState: Equatable {
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

/// Target protocol driven cleanly by `ChatRevealDisplayDriver` without retaining cells or views.
@MainActor
protocol ChatRevealDisplayClient: AnyObject {
    func revealDisplayTick(now: CFTimeInterval)
}

/// Idle-zero shared `CADisplayLink` supporting ProMotion 120Hz and background pause/resume.
@MainActor
final class ChatRevealDisplayDriver: NSObject {
    static let shared = ChatRevealDisplayDriver()

    private final class WeakBox {
        weak var client: ChatRevealDisplayClient?
        init(_ client: ChatRevealDisplayClient) { self.client = client }
    }

    private var clients: [ObjectIdentifier: WeakBox] = [:]
    private var displayLink: CADisplayLink?
    private var isBackgrounded = false
    private var lastDispatchedNow: CFTimeInterval = 0

    private override init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    func register(_ client: ChatRevealDisplayClient) {
        let key = ObjectIdentifier(client)
        clients[key] = WeakBox(client)
        pruneDeadClients()
        syncDisplayLinkState()
    }

    func unregister(_ client: ChatRevealDisplayClient) {
        clients.removeValue(forKey: ObjectIdentifier(client))
        pruneDeadClients()
        syncDisplayLinkState()
    }

    @objc private func appDidEnterBackground() {
        isBackgrounded = true
        stopDisplayLink()
    }

    @objc private func appWillEnterForeground() {
        isBackgrounded = false
        pruneDeadClients()
        syncDisplayLinkState()
    }

    private func pruneDeadClients() {
        clients = clients.filter { $0.value.client != nil }
    }

    private func syncDisplayLinkState() {
        if clients.isEmpty || isBackgrounded {
            stopDisplayLink()
            return
        }
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(handleDisplayLink(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func handleDisplayLink(_ link: CADisplayLink) {
        pruneDeadClients()
        guard !clients.isEmpty, !isBackgrounded else {
            stopDisplayLink()
            return
        }
        let mediaNow = CACurrentMediaTime()
        let tickNow = max(lastDispatchedNow, mediaNow)
        lastDispatchedNow = tickNow
        let snapshot = clients.values.compactMap(\.client)
        for client in snapshot {
            client.revealDisplayTick(now: tickNow)
        }
        pruneDeadClients()
        if clients.isEmpty {
            stopDisplayLink()
        }
    }
}

/// Lightweight pooled frontier ink motes rendered only on slow, single-tile normal-power typing.
@MainActor
final class ChatRevealSnippetLayer: CALayer {
    private struct Mote {
        let layer: CALayer
        var bornAt: CFTimeInterval = 0
        var origin: CGPoint = .zero
        var velocity: CGPoint = .zero
        var life: CFTimeInterval = 0.16
        var active = false
    }

    private var motes: [Mote] = []
    private var lastSpawnTime: CFTimeInterval = 0
    private var lastSpawnFrontier: CGPoint = .zero
    private var seedCounter = 0

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
        for _ in 0..<6 {
            let moteLayer = CALayer()
            moteLayer.isHidden = true
            moteLayer.cornerRadius = 1.6
            moteLayer.bounds = CGRect(x: 0, y: 0, width: 3.2, height: 3.2)
            addSublayer(moteLayer)
            motes.append(Mote(layer: moteLayer))
        }
    }

    func updateThemeColor(_ color: CGColor) {
        for index in motes.indices {
            motes[index].layer.backgroundColor = color
        }
    }

    func step(frontier: CGPoint?, allowsSpawn: Bool, now: CFTimeInterval, bounds: CGRect) {
        if allowsSpawn,
           let frontier,
           frontier.x > 4,
           now - lastSpawnTime >= 0.048,
           hypot(frontier.x - lastSpawnFrontier.x, frontier.y - lastSpawnFrontier.y) >= 5.0 {
            lastSpawnTime = now
            lastSpawnFrontier = frontier
            spawn(at: frontier, now: now)
        }

        var anyActive = false
        for index in motes.indices {
            guard motes[index].active else { continue }
            let elapsed = now - motes[index].bornAt
            if elapsed >= motes[index].life || elapsed < 0 {
                motes[index].active = false
                motes[index].layer.isHidden = true
                continue
            }
            anyActive = true
            let progress = CGFloat(elapsed / motes[index].life)
            let x = max(0, min(bounds.width, motes[index].origin.x + motes[index].velocity.x * CGFloat(elapsed)))
            let y = max(0, min(bounds.height, motes[index].origin.y + motes[index].velocity.y * CGFloat(elapsed)))
            motes[index].layer.isHidden = false
            motes[index].layer.position = CGPoint(x: x, y: y)
            motes[index].layer.opacity = Float((1.0 - progress) * 0.22)
        }
        isHidden = !anyActive
    }

    func clear() {
        lastSpawnTime = 0
        lastSpawnFrontier = .zero
        for index in motes.indices {
            motes[index].active = false
            motes[index].layer.isHidden = true
        }
        isHidden = true
    }

    private func spawn(at point: CGPoint, now: CFTimeInterval) {
        guard let slot = motes.firstIndex(where: { !$0.active }) else { return }
        seedCounter &+= 1
        let yOffset = CGFloat((seedCounter % 5) - 2) * 2.2
        let driftX = 8.0 + CGFloat(seedCounter % 4) * 3.0
        let driftY = CGFloat(((seedCounter % 3) - 1)) * 9.0
        motes[slot].active = true
        motes[slot].bornAt = now
        motes[slot].origin = CGPoint(x: max(2, point.x - 3), y: point.y + yOffset)
        motes[slot].velocity = CGPoint(x: driftX, y: driftY)
        motes[slot].life = 0.16
        motes[slot].layer.isHidden = false
        motes[slot].layer.position = motes[slot].origin
        motes[slot].layer.opacity = 0.22
        isHidden = false
    }
}

/// Zero-allocation O(1) CALayer mask coordinator (single merged prefix + active band + gradient feather).
@MainActor
final class ChatRevealMaskCoordinator {
    private let maskRoot = CALayer()
    private let prefixLayer = CALayer()
    private let activeOpaqueLayer = CALayer()
    private let featherLayer = CAGradientLayer()
    let snippetLayer = ChatRevealSnippetLayer()

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

    func updateTheme(traitCollection: UITraitCollection) {
        let color = UIColor(Ink.inkFaint).resolvedColor(with: traitCollection).cgColor
        snippetLayer.updateThemeColor(color)
    }

    /// Must be called inside `CATransaction.setDisableActions(true)` or safe UIKit layout update.
    func apply(
        maskState: ChatRevealLayoutSnapshot.MaskState,
        bounds: CGRect,
        allowsSnippets: Bool,
        now: CFTimeInterval,
        tileRoot: CALayer,
        snippetHost: CALayer
    ) {
        switch maskState {
        case .complete:
            tileRoot.mask = nil
            snippetLayer.step(frontier: nil, allowsSpawn: false, now: now, bounds: bounds)
            return

        case .hidden:
            attachMaskIfNeeded(to: tileRoot, snippetHost: snippetHost, bounds: bounds)
            maskRoot.frame = bounds
            prefixLayer.isHidden = true
            activeOpaqueLayer.isHidden = true
            featherLayer.isHidden = true
            snippetLayer.step(frontier: nil, allowsSpawn: false, now: now, bounds: bounds)

        case let .partial(fullyBottom, bandY, bandHeight, lineHeight, frontierX, hasRTL):
            attachMaskIfNeeded(to: tileRoot, snippetHost: snippetHost, bounds: bounds)
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
                snippetLayer.step(frontier: nil, allowsSpawn: false, now: now, bounds: bounds)
                return
            }

            if hasRTL {
                activeOpaqueLayer.isHidden = false
                activeOpaqueLayer.frame = CGRect(x: 0, y: bandY, width: bounds.width, height: bandHeight)
                featherLayer.isHidden = true
                snippetLayer.step(frontier: nil, allowsSpawn: false, now: now, bounds: bounds)
                return
            }

            let clampedFrontier = max(0, min(bounds.width, frontierX))
            let feather = ChatRevealPolicy.featherWidth(forLineHeight: lineHeight)
            let solidWidth = max(0, clampedFrontier - feather)

            if solidWidth > 0.5 {
                activeOpaqueLayer.isHidden = false
                activeOpaqueLayer.frame = CGRect(x: 0, y: bandY, width: solidWidth, height: bandHeight)
            } else {
                activeOpaqueLayer.isHidden = true
            }

            let featherStartX = solidWidth
            let featherActualW = max(0, clampedFrontier - featherStartX)
            if featherActualW > 0.5 {
                featherLayer.isHidden = false
                featherLayer.frame = CGRect(x: featherStartX, y: bandY, width: featherActualW, height: bandHeight)
            } else {
                featherLayer.isHidden = true
            }

            snippetLayer.frame = bounds
            let frontierPoint = CGPoint(x: clampedFrontier, y: bandY + lineHeight * 0.5)
            snippetLayer.step(frontier: frontierPoint, allowsSpawn: allowsSnippets, now: now, bounds: bounds)
        }
    }

    func detach(from tileRoot: CALayer) {
        tileRoot.mask = nil
        prefixLayer.isHidden = true
        activeOpaqueLayer.isHidden = true
        featherLayer.isHidden = true
        snippetLayer.clear()
        snippetLayer.removeFromSuperlayer()
    }

    private func attachMaskIfNeeded(to tileRoot: CALayer, snippetHost: CALayer, bounds: CGRect) {
        if tileRoot.mask !== maskRoot {
            tileRoot.mask = maskRoot
        }
        if snippetLayer.superlayer !== snippetHost {
            snippetLayer.frame = bounds
            snippetHost.addSublayer(snippetLayer)
        }
    }
}

/// Captures in-progress reveal cursor across sealed-tail splits or structural streaming -> settled commit.
struct ChatRevealHandoff {
    let tailText: String
    let remainingRevealedUTF16: Int
    let wasFinalizing: Bool
    let capturedAt: CFTimeInterval
    var startsAtBeginning = false

    static var unseenReply: ChatRevealHandoff {
        ChatRevealHandoff(
            tailText: "", remainingRevealedUTF16: 0, wasFinalizing: false,
            capturedAt: 0, startsAtBeginning: true
        )
    }
}

/// Stateful streaming reveal coordinator wrapping Telegram's verbatim `TextRevealController`.
@MainActor
final class ChatRevealSession {
    private var controller: TextRevealController
    private(set) var snapshot: ChatRevealLayoutSnapshot
    private(set) var isComplete = false
    private var displayedPoints: Double
    private var lastDisplayTime: CFTimeInterval
    private var lastClock: CFTimeInterval

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
        now: CFTimeInterval = CACurrentMediaTime()
    ) {
        self.snapshot = snapshot
        self.lastClock = now

        let clampedOffset = max(0, min(snapshot.attributedLength, initialRevealedUTF16))
        let initialPoints = snapshot.pointsBefore(utf16Offset: clampedOffset)
        self.displayedPoints = Double(initialPoints)
        self.lastDisplayTime = now

        self.controller = TextRevealController(
            initialRevealedCount: initialPoints,
            initialLength: snapshot.totalPoints,
            durationMultiplier: ChatRevealPolicy.durationMultiplier
        )

        if finalizeImmediately {
            self.controller.finalize(finalLength: snapshot.totalPoints)
        } else {
            self.controller.observeUpdate(latestLength: snapshot.totalPoints, at: now)
        }

        if snapshot.totalPoints == 0 || (controller.isFinalizing && displayedPoints >= Double(snapshot.totalPoints)) {
            self.isComplete = true
        }
    }

    var currentPoints: Double {
        displayedPoints
    }

    var currentRevealedUTF16: Int {
        snapshot.utf16Offset(forPoints: Int(displayedPoints))
    }

    var isFinalizing: Bool {
        controller.isFinalizing
    }

    var backlogPoints: Int {
        max(0, snapshot.totalPoints - Int(displayedPoints))
    }

    func update(snapshot nextSnapshot: ChatRevealLayoutSnapshot, isLive: Bool, now: CFTimeInterval = CACurrentMediaTime()) {
        let clock = max(lastClock, now)
        lastClock = clock

        let prevRevealedUTF16 = currentRevealedUTF16
        let prevLength = snapshot.attributedLength
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
                durationMultiplier: ChatRevealPolicy.durationMultiplier
            )
            displayedPoints = Double(remappedPoints)
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

    func step(now: CFTimeInterval) -> (maskState: ChatRevealLayoutSnapshot.MaskState, backlogPoints: Int, isComplete: Bool) {
        guard !isComplete else {
            return (.complete, 0, true)
        }
        let clock = max(lastClock, now)
        lastClock = clock
        _ = controller.tick(now: clock)
        // The upstream controller eases asymptotically; once it is subpixel-close, drain the final point.
        let target = Double(snapshot.totalPoints) - controller.revealedCount < 1
            ? Double(snapshot.totalPoints)
            : controller.revealedCount
        displayedPoints = ChatRevealPolicy.pacedPoints(
            current: displayedPoints, target: target, total: snapshot.totalPoints,
            elapsed: clock - lastDisplayTime
        )
        lastDisplayTime = clock
        let maskState = snapshot.maskState(forPoints: displayedPoints)
        isComplete = maskState == .complete && controller.isFinalizing
        return (maskState, backlogPoints, isComplete)
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
