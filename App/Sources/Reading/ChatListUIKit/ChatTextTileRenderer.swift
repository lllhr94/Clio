import CoreText
import SwiftUI
import UIKit

/// Resolved color and geometry constants passed into off-main-thread CoreText tile rendering.
struct ChatTextRenderPalette: @unchecked Sendable {
    let inlineCodeFill: CGColor
    let ruleFill: CGColor
    let quoteBg: CGColor
    let quoteBorder: CGColor
    let quoteStripe: CGColor
    let inlineCodeCorner: CGFloat
    let ruleInset: CGFloat
    let quoteRadius: CGFloat
    let quotePadV: CGFloat
    let quoteStripeX: CGFloat
    let quoteStripeWidth: CGFloat

    nonisolated static func make(style: ChatListStyle) -> ChatTextRenderPalette {
        ChatTextRenderPalette(
            inlineCodeFill: style.colors.inlineCodeFill.cgColor,
            ruleFill: style.colors.ruleFill.cgColor,
            quoteBg: style.colors.quoteBackground.cgColor,
            quoteBorder: style.colors.quoteBorder.cgColor,
            quoteStripe: style.colors.quoteStripe.cgColor,
            inlineCodeCorner: style.metrics.inlineCodeCorner,
            ruleInset: style.metrics.spaceL,
            quoteRadius: style.metrics.radiusSmall,
            quotePadV: style.metrics.spaceM,
            quoteStripeX: style.metrics.spaceM,
            quoteStripeWidth: 2.0
        )
    }
}

/// Cancellable group token shared between background layout prefetchers and `ChatTextTileRenderer`.
final class ChatPrefetchToken: @unchecked Sendable {
    fileprivate var isCancelled = false
    fileprivate var keys: [String] = []
}

/// Immutable request describing one attributed prose or code slice to rasterize into vertical tiles.
struct ChatTextRenderRequest: @unchecked Sendable {
    let cacheKey: String
    let attributed: NSAttributedString
    let decorations: ChatBlockDecorations
    let topInset: CGFloat
    let bottomInset: CGFloat
    let width: CGFloat
    let height: CGFloat
    let scale: CGFloat
    let palette: ChatTextRenderPalette
}

/// Rasterized vertical tile strip backed by premultiplied BGRA8888 `CGImage` slices.
final class ChatRenderedTiles: @unchecked Sendable {
    let tiles: [(y: CGFloat, height: CGFloat, image: CGImage)]
    let totalBytes: Int

    init(tiles: [(y: CGFloat, height: CGFloat, image: CGImage)], totalBytes: Int) {
        self.tiles = tiles
        self.totalBytes = totalBytes
    }
}

/// Outcome of an asynchronous tile rasterization request, distinguishing stale or cancelled work
/// from true rasterization failures.
enum ChatTileRenderResult: @unchecked Sendable {
    case rendered(ChatRenderedTiles)
    case staleOrCancelled
    case failed
}

/// Off-main-thread CoreText tiled bitmap renderer with bounded `NSCache`, coalesced in-flight work,
/// and `UICollectionViewDataSourcePrefetching` support.
final class ChatTextTileRenderer: @unchecked Sendable {
    static let shared = ChatTextTileRenderer()

    private struct QuoteDrawItem {
        let cardRect: CGRect
        let stripeRect: CGRect
    }

    private static let maxTileHeight: CGFloat = 512.0
    private static let maxTexturePixelWidth = 8192

    private let cache: NSCache<NSString, ChatRenderedTiles> = {
        let cache = NSCache<NSString, ChatRenderedTiles>()
        cache.totalCostLimit = 40 * 1024 * 1024
        cache.countLimit = 250
        return cache
    }()

    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "clio.chat-text-tiles"
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .userInitiated
        return queue
    }()

    private let lock = NSLock()
    private var inFlight: [String: (op: Operation, completions: [@MainActor (String, ChatTileRenderResult) -> Void])] = [:]
    private var generation: UInt64 = 0
    private var memoryWarningObserver: NSObjectProtocol?

    private init() {
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.purgeMemoryCache()
        }
    }

    deinit {
        if let observer = memoryWarningObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func purgeMemoryCache() {
        lock.lock()
        cache.removeAllObjects()
        lock.unlock()
    }

    static func cacheKey(token: UInt64, width: CGFloat, height: CGFloat, styleKey: String, scale: CGFloat) -> String {
        let safeScale = max(1, scale)
        let wKey = Int((width * safeScale).rounded())
        let hKey = Int((height * safeScale).rounded())
        let sKey = Int((safeScale * 2).rounded())
        return "\(token)|\(wKey)|\(hKey)|\(sKey)|\(styleKey)"
    }

    func cached(for key: String) -> ChatRenderedTiles? {
        cache.object(forKey: key as NSString)
    }

    func renderSync(_ request: ChatTextRenderRequest) -> ChatRenderedTiles? {
        if let hit = cache.object(forKey: request.cacheKey as NSString) {
            return hit
        }
        guard let rendered = Self.render(request) else { return nil }
        cache.setObject(rendered, forKey: request.cacheKey as NSString, cost: rendered.totalBytes)
        return rendered
    }

    func renderAsync(
        _ request: ChatTextRenderRequest,
        completion: @escaping @MainActor (String, ChatTileRenderResult) -> Void
    ) {
        if let hit = cache.object(forKey: request.cacheKey as NSString) {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    completion(request.cacheKey, .rendered(hit))
                }
            }
            return
        }

        lock.lock()
        if let hit = cache.object(forKey: request.cacheKey as NSString) {
            lock.unlock()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    completion(request.cacheKey, .rendered(hit))
                }
            }
            return
        }
        if var existing = inFlight[request.cacheKey] {
            existing.completions.append(completion)
            existing.op.queuePriority = .veryHigh
            inFlight[request.cacheKey] = existing
            lock.unlock()
            return
        }

        let opGen = generation
        let op = makeOperation(for: request, generation: opGen)
        op.queuePriority = .high
        inFlight[request.cacheKey] = (op: op, completions: [completion])
        lock.unlock()

        queue.addOperation(op)
    }

    func isCancelled(_ token: ChatPrefetchToken) -> Bool {
        lock.lock()
        let cancelled = token.isCancelled
        lock.unlock()
        return cancelled
    }

    func prefetch(
        _ requests: [ChatTextRenderRequest],
        token: ChatPrefetchToken? = nil,
        queuePriority: Operation.QueuePriority = .low
    ) {
        guard !requests.isEmpty else { return }
        var opsToAdd: [Operation] = []

        lock.lock()
        if token?.isCancelled == true {
            lock.unlock()
            return
        }
        let opGen = generation
        for request in requests {
            guard request.width > 0, request.height > 0, request.attributed.length > 0 else { continue }
            if cache.object(forKey: request.cacheKey as NSString) != nil { continue }
            if let existing = inFlight[request.cacheKey] {
                if existing.completions.isEmpty && existing.op.queuePriority.rawValue < queuePriority.rawValue {
                    existing.op.queuePriority = queuePriority
                }
                continue
            }

            let op = makeOperation(for: request, generation: opGen)
            op.queuePriority = queuePriority
            inFlight[request.cacheKey] = (op: op, completions: [])
            token?.keys.append(request.cacheKey)
            opsToAdd.append(op)
        }
        lock.unlock()

        if !opsToAdd.isEmpty {
            queue.addOperations(opsToAdd, waitUntilFinished: false)
        }
    }

    func cancelPrefetch(token: ChatPrefetchToken) {
        lock.lock()
        token.isCancelled = true
        for key in token.keys {
            if let entry = inFlight[key], entry.completions.isEmpty {
                entry.op.cancel()
                inFlight.removeValue(forKey: key)
            }
        }
        token.keys.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    func cancelPrefetch(keys: [String]) {
        guard !keys.isEmpty else { return }
        lock.lock()
        for key in keys {
            if let entry = inFlight[key], entry.completions.isEmpty {
                entry.op.cancel()
                inFlight.removeValue(forKey: key)
            }
        }
        lock.unlock()
    }

    func invalidateAll() {
        lock.lock()
        generation &+= 1
        var cancelledKeys: [String] = []
        for (key, entry) in inFlight where entry.completions.isEmpty {
            entry.op.cancel()
            cancelledKeys.append(key)
        }
        for key in cancelledKeys {
            inFlight.removeValue(forKey: key)
        }
        cache.removeAllObjects()
        lock.unlock()
    }

    private func makeOperation(for request: ChatTextRenderRequest, generation opGen: UInt64) -> BlockOperation {
        let key = request.cacheKey
        let op = BlockOperation()
        op.addExecutionBlock { [weak self, weak op] in
            guard let self else { return }
            if op?.isCancelled == true {
                self.finishOperation(key: key, op: op, opGen: opGen, rendered: nil, cancelled: true)
                return
            }
            let rendered = Self.render(request)
            let cancelled = op?.isCancelled ?? true
            self.finishOperation(key: key, op: op, opGen: opGen, rendered: rendered, cancelled: cancelled)
        }
        return op
    }

    private func finishOperation(
        key: String,
        op: Operation?,
        opGen: UInt64,
        rendered: ChatRenderedTiles?,
        cancelled: Bool
    ) {
        lock.lock()
        let isCurrent = inFlight[key]?.op === op
        let completions = isCurrent ? (inFlight.removeValue(forKey: key)?.completions ?? []) : []
        let validGen = (generation == opGen) && !cancelled
        if validGen, let rendered {
            cache.setObject(rendered, forKey: key as NSString, cost: rendered.totalBytes)
        }
        lock.unlock()

        guard !completions.isEmpty else { return }
        let result: ChatTileRenderResult
        if !validGen {
            result = .staleOrCancelled
        } else if let rendered {
            result = .rendered(rendered)
        } else {
            result = .failed
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                for cb in completions {
                    cb(key, result)
                }
            }
        }
    }

    nonisolated static func render(_ req: ChatTextRenderRequest) -> ChatRenderedTiles? {
        guard req.width > 0, req.height > 0, req.scale > 0, req.attributed.length > 0 else {
            return nil
        }
        let scale = max(1, req.scale)
        let pixelW = max(1, Int((req.width * scale).rounded(.up)))
        guard pixelW <= maxTexturePixelWidth else { return nil }

        let source = ChatLayoutCache.prepareCoreTextSource(req.attributed)
        let textHeight = max(1, req.height - req.topInset - req.bottomInset)
        let framesetter = CTFramesetterCreateWithAttributedString(source as CFAttributedString)
        let framePath = CGPath(rect: CGRect(x: 0, y: 0, width: max(1, req.width), height: textHeight), transform: nil)
        let ctFrame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: source.length), framePath, nil)

        var quoteDrawItems: [QuoteDrawItem] = []
        var inlineCodeRects: [CGRect] = []
        var ruleRects: [CGRect] = []

        let maxAttrLen = req.attributed.length
        let codeRanges = req.decorations.inlineCodeRanges
            .filter { $0.length > 0 && $0.location >= 0 && NSMaxRange($0) <= maxAttrLen }
            .sorted { $0.location < $1.location }
        let ruleRanges = req.decorations.ruleRanges
            .filter { $0.length > 0 && $0.location >= 0 && NSMaxRange($0) <= maxAttrLen }
            .sorted { $0.location < $1.location }
        let quoteRanges = req.decorations.quoteBlocks
            .filter { $0.length > 0 && $0.location >= 0 && NSMaxRange($0) <= maxAttrLen }
            .sorted { $0.location < $1.location }

        if !codeRanges.isEmpty || !ruleRanges.isEmpty || !quoteRanges.isEmpty {
            let cfLines = CTFrameGetLines(ctFrame)
            let lineCount = CFArrayGetCount(cfLines)
            if lineCount > 0 {
                var origins = [CGPoint](repeating: .zero, count: lineCount)
                CTFrameGetLineOrigins(ctFrame, CFRange(location: 0, length: 0), &origins)

                let nsSource = codeRanges.isEmpty ? nil : (source.string as NSString)
                var quoteSpans: [(minY: CGFloat, maxY: CGFloat)?] = Array(repeating: nil, count: quoteRanges.count)
                var ruleSpans: [(minY: CGFloat, maxY: CGFloat)?] = Array(repeating: nil, count: ruleRanges.count)

                var qIdx = 0
                var rIdx = 0
                var cIdx = 0

                for i in 0..<lineCount {
                    let line = unsafeBitCast(CFArrayGetValueAtIndex(cfLines, i), to: CTLine.self)
                    let cfRange = CTLineGetStringRange(line)
                    guard cfRange.location != kCFNotFound, cfRange.length > 0 else { continue }
                    let lineStart = cfRange.location
                    let lineEnd = lineStart + cfRange.length

                    var ascent: CGFloat = 0
                    var descent: CGFloat = 0
                    var leading: CGFloat = 0
                    _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
                    let baselineY = req.topInset + (textHeight - origins[i].y)
                    let lineTopY = baselineY - ascent
                    let lineBottomY = baselineY + descent
                    let lineHeight = max(1, lineBottomY - lineTopY)

                    while qIdx < quoteRanges.count && NSMaxRange(quoteRanges[qIdx]) <= lineStart {
                        qIdx += 1
                    }
                    var qScan = qIdx
                    while qScan < quoteRanges.count && quoteRanges[qScan].location < lineEnd {
                        let existing = quoteSpans[qScan]
                        let minY = min(existing?.minY ?? CGFloat.greatestFiniteMagnitude, lineTopY)
                        let maxY = max(existing?.maxY ?? -CGFloat.greatestFiniteMagnitude, lineBottomY)
                        quoteSpans[qScan] = (minY: minY, maxY: maxY)
                        if NSMaxRange(quoteRanges[qScan]) <= lineEnd {
                            qIdx = qScan + 1
                        }
                        qScan += 1
                    }

                    while rIdx < ruleRanges.count && NSMaxRange(ruleRanges[rIdx]) <= lineStart {
                        rIdx += 1
                    }
                    var rScan = rIdx
                    while rScan < ruleRanges.count && ruleRanges[rScan].location < lineEnd {
                        let existing = ruleSpans[rScan]
                        let minY = min(existing?.minY ?? CGFloat.greatestFiniteMagnitude, lineTopY)
                        let maxY = max(existing?.maxY ?? -CGFloat.greatestFiniteMagnitude, lineBottomY)
                        ruleSpans[rScan] = (minY: minY, maxY: maxY)
                        if NSMaxRange(ruleRanges[rScan]) <= lineEnd {
                            rIdx = rScan + 1
                        }
                        rScan += 1
                    }

                    if let nsSource {
                        while cIdx < codeRanges.count && NSMaxRange(codeRanges[cIdx]) <= lineStart {
                            cIdx += 1
                        }
                        var cScan = cIdx
                        while cScan < codeRanges.count && codeRanges[cScan].location < lineEnd {
                            let target = codeRanges[cScan]
                            let overlapStart = max(target.location, lineStart)
                            let overlapEnd = min(NSMaxRange(target), lineEnd)
                            var effectiveEnd = overlapEnd
                            if effectiveEnd == lineEnd,
                               effectiveEnd > overlapStart,
                               effectiveEnd <= nsSource.length,
                               nsSource.character(at: effectiveEnd - 1) == 0x000A {
                                effectiveEnd -= 1
                            }
                            if effectiveEnd > overlapStart {
                                let x0 = origins[i].x + CTLineGetOffsetForStringIndex(line, overlapStart, nil)
                                let x1 = origins[i].x + CTLineGetOffsetForStringIndex(line, effectiveEnd, nil)
                                let minX = min(x0, x1)
                                let maxX = max(x0, x1)
                                if maxX > minX {
                                    let rawRect = CGRect(x: minX, y: lineTopY, width: maxX - minX, height: lineHeight)
                                    let pillRect = rawRect.insetBy(dx: -2.5, dy: lineHeight * 0.06)
                                    if pillRect.width > 0, pillRect.height > 0 {
                                        inlineCodeRects.append(pillRect)
                                    }
                                }
                            }
                            if NSMaxRange(target) <= lineEnd {
                                cIdx = cScan + 1
                            }
                            cScan += 1
                        }
                    }
                }

                for span in quoteSpans {
                    guard let span, span.minY <= span.maxY, span.minY.isFinite, span.maxY.isFinite else { continue }
                    let padV = req.palette.quotePadV
                    let topY = max(0, span.minY - padV)
                    let bottomY = min(req.height, span.maxY + padV)
                    let cardH = max(padV * 2, bottomY - topY)
                    let cardRect = CGRect(x: 0, y: topY, width: req.width, height: cardH)
                    let stripeRect = CGRect(
                        x: req.palette.quoteStripeX,
                        y: topY + padV,
                        width: req.palette.quoteStripeWidth,
                        height: max(6, cardH - padV * 2)
                    )
                    quoteDrawItems.append(QuoteDrawItem(cardRect: cardRect, stripeRect: stripeRect))
                }

                let ruleInset = req.palette.ruleInset
                let ruleWidth = max(24, req.width - ruleInset * 2)
                for span in ruleSpans {
                    guard let span, span.minY <= span.maxY, span.minY.isFinite, span.maxY.isFinite else { continue }
                    let midY = (span.minY + span.maxY) * 0.5
                    ruleRects.append(CGRect(x: ruleInset, y: midY - 0.375, width: ruleWidth, height: 0.75))
                }
            }
        }

        let hasDecorations = !quoteDrawItems.isEmpty || !inlineCodeRects.isEmpty || !ruleRects.isEmpty
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

        var tiles: [(y: CGFloat, height: CGFloat, image: CGImage)] = []
        var totalBytes = 0
        var tileY: CGFloat = 0
        let totalHeight = req.height
        let tolerance = 0.25 / scale

        while tileY < totalHeight - tolerance {
            let remaining = max(1.0 / scale, totalHeight - tileY)
            let rawTileH = min(maxTileHeight, remaining)
            let pixelH = max(1, Int((rawTileH * scale).rounded(.up)))
            let tileDisplayH = CGFloat(pixelH) / scale

            guard let ctx = CGContext(
                data: nil,
                width: pixelW,
                height: pixelH,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else {
                return nil
            }
            ctx.clear(CGRect(x: 0, y: 0, width: pixelW, height: pixelH))
            ctx.setShouldAntialias(true)
            ctx.setAllowsAntialiasing(true)

            let tileRect = CGRect(x: 0, y: tileY, width: req.width, height: tileDisplayH)

            if hasDecorations {
                ctx.saveGState()
                ctx.translateBy(x: 0, y: CGFloat(pixelH))
                ctx.scaleBy(x: scale, y: -scale)
                ctx.translateBy(x: 0, y: -tileY)

                for quote in quoteDrawItems where quote.cardRect.intersects(tileRect) {
                    let r = min(req.palette.quoteRadius, min(quote.cardRect.width, quote.cardRect.height) * 0.5)
                    let cardPath = CGPath(roundedRect: quote.cardRect, cornerWidth: r, cornerHeight: r, transform: nil)

                    ctx.saveGState()
                    ctx.addPath(cardPath)
                    ctx.clip()
                    ctx.setFillColor(req.palette.quoteBg)
                    ctx.fill(quote.cardRect)

                    let sr = quote.stripeRect
                    let stripeCorner = min(1.25, min(sr.width, sr.height) * 0.5)
                    let stripePath = CGPath(roundedRect: sr, cornerWidth: stripeCorner, cornerHeight: stripeCorner, transform: nil)
                    ctx.addPath(stripePath)
                    ctx.setFillColor(req.palette.quoteStripe)
                    ctx.fillPath()
                    ctx.restoreGState()

                    if req.palette.quoteBorder.alpha > 0.01 {
                        let borderRect = quote.cardRect.insetBy(dx: 0.25, dy: 0.25)
                        let borderR = max(0, r - 0.25)
                        let borderPath = CGPath(roundedRect: borderRect, cornerWidth: borderR, cornerHeight: borderR, transform: nil)
                        ctx.addPath(borderPath)
                        ctx.setStrokeColor(req.palette.quoteBorder)
                        ctx.setLineWidth(0.5)
                        ctx.strokePath()
                    }
                }

                if !inlineCodeRects.isEmpty {
                    ctx.setFillColor(req.palette.inlineCodeFill)
                    for rect in inlineCodeRects where rect.intersects(tileRect) {
                        let r = min(req.palette.inlineCodeCorner, min(rect.width, rect.height) * 0.3)
                        let pillPath = CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
                        ctx.addPath(pillPath)
                        ctx.fillPath()
                    }
                }

                if !ruleRects.isEmpty {
                    ctx.setFillColor(req.palette.ruleFill)
                    for rect in ruleRects where rect.intersects(tileRect) {
                        ctx.fill(rect)
                    }
                }

                ctx.restoreGState()
            }

            ctx.saveGState()
            ctx.translateBy(x: 0, y: CGFloat(pixelH))
            ctx.scaleBy(x: scale, y: -scale)
            ctx.translateBy(x: 0, y: -tileY)
            ctx.translateBy(x: 0, y: req.topInset + textHeight)
            ctx.scaleBy(x: 1, y: -1)
            ctx.textMatrix = .identity
            CTFrameDraw(ctFrame, ctx)
            ctx.restoreGState()

            guard let image = ctx.makeImage() else { return nil }
            tiles.append((y: tileY, height: tileDisplayH, image: image))
            totalBytes += ctx.bytesPerRow * pixelH
            tileY += tileDisplayH
        }

        guard !tiles.isEmpty else { return nil }
        return ChatRenderedTiles(tiles: tiles, totalBytes: totalBytes)
    }
}
