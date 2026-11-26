import CoreGraphics
import CoreText
import Foundation
import QuartzCore
import TelegramRevealUpstream

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Section 13 Collaboration Interfaces (Reserved Seams for Parallel Telegram Tech Audit)

public struct SpikeParsedBlock: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case heading, paragraph, listItem, blockquote, codeFence, table, mathBlock
    }
    public let stableID: String
    public let kind: Kind
    public let rawText: String
    public let isClosed: Bool
}

public protocol StableBlockCaching: AnyObject {
    func cachedBlock(forRawSlice raw: String, kind: SpikeParsedBlock.Kind) -> SpikeParsedBlock?
    func storeClosedBlock(_ block: SpikeParsedBlock)
    func purgeAll()
}

public protocol IncrementalCodeHighlighting: AnyObject {
    func highlightLinesIfNeeded(blockID: String, code: String, language: String?) -> Int
}

@MainActor
public protocol RevealAnimationScheduling: AnyObject {
    var isRunning: Bool { get }
    var scheduledFrameCount: Int { get }
    func start(handler: @escaping @MainActor (_ timestamp: Double) -> Void)
    func pause()
    func stop()
}

public protocol PowerThermalPolicyProvider {
    var isLowPowerModeEnabled: Bool { get }
    var isThermalDowngraded: Bool { get }
}

public protocol MemoryPressureHandling: AnyObject {
    func handleMemoryWarning()
}

public protocol AdaptivePrefetchCoordinating: AnyObject {
    func prefetchSettledBlocks(ids: [String])
    func cancelPrefetch(ids: [String])
}

public protocol MediaCacheBudgeting: AnyObject {
    var maxDecodedBytes: Int { get }
    func trimToBudget()
}

public final class InMemoryStableBlockCache: StableBlockCaching {
    private var storage: [String: SpikeParsedBlock] = [:]
    public var hitCount: Int = 0
    public var storeCount: Int = 0

    public init() {}

    public func cachedBlock(forRawSlice raw: String, kind: SpikeParsedBlock.Kind) -> SpikeParsedBlock? {
        let key = "\(kind.rawValue)|\(raw)"
        if let hit = storage[key] {
            hitCount += 1
            return hit
        }
        return nil
    }

    public func storeClosedBlock(_ block: SpikeParsedBlock) {
        guard block.isClosed else { return }
        let key = "\(block.kind.rawValue)|\(block.rawText)"
        storage[key] = block
        storeCount += 1
    }

    public func purgeAll() {
        storage.removeAll()
    }
}

public struct SystemPowerThermalProvider: PowerThermalPolicyProvider {
    public init() {}
    public var isLowPowerModeEnabled: Bool {
        return ProcessInfo.processInfo.isLowPowerModeEnabled
    }
    public var isThermalDowngraded: Bool {
        let state = ProcessInfo.processInfo.thermalState
        return state == .serious || state == .critical
    }
}

@MainActor
public final class VirtualRevealScheduler: RevealAnimationScheduling {
    public private(set) var isRunning: Bool = false
    public private(set) var scheduledFrameCount: Int = 0
    private var handler: (@MainActor (_ timestamp: Double) -> Void)?

    public init() {}

    public func start(handler: @escaping @MainActor (_ timestamp: Double) -> Void) {
        self.handler = handler
        self.isRunning = true
    }

    public func pause() {
        self.isRunning = false
    }

    public func stop() {
        self.isRunning = false
        self.handler = nil
    }

    public func stepFrame(at timestamp: Double) {
        guard isRunning, let handler else { return }
        scheduledFrameCount += 1
        handler(timestamp)
    }
}

#if canImport(UIKit)
@MainActor
public final class CADisplayLinkRevealScheduler: NSObject, RevealAnimationScheduling {
    public private(set) var isRunning: Bool = false
    public private(set) var scheduledFrameCount: Int = 0
    private var displayLink: CADisplayLink?
    private var handler: (@MainActor (_ timestamp: Double) -> Void)?

    public override init() {
        super.init()
    }

    public func start(handler: @escaping @MainActor (_ timestamp: Double) -> Void) {
        self.handler = handler
        if displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(onTick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else {
            displayLink?.isPaused = false
        }
        isRunning = true
    }

    public func pause() {
        displayLink?.isPaused = true
        isRunning = false
    }

    public func stop() {
        displayLink?.invalidate()
        displayLink = nil
        handler = nil
        isRunning = false
    }

    @objc private func onTick(_ link: CADisplayLink) {
        guard isRunning else { return }
        scheduledFrameCount += 1
        handler?(link.timestamp)
    }
}
#endif

// MARK: - Prefix-Safe Incremental Block Parser (Zero Infinite Loop / Zero Char Loss)

public enum SpikeIncrementalMarkdownParser {
    public static func parse(
        _ markdown: String,
        cache: StableBlockCaching? = nil,
        streamEnded: Bool = false
    ) -> [SpikeParsedBlock] {
        guard !markdown.isEmpty else { return [] }
        let lines = splitLinesPreservingOrder(markdown)
        var blocks: [SpikeParsedBlock] = []
        var idx = 0

        while idx < lines.count {
            let startIdx = idx
            let line = lines[idx]

            if line.hasPrefix("```") {
                var collected = [line]
                idx += 1
                var closed = false
                while idx < lines.count {
                    collected.append(lines[idx])
                    if lines[idx].hasPrefix("```") && lines[idx].trimmingCharacters(in: .whitespaces).count >= 3 {
                        idx += 1
                        closed = true
                        break
                    }
                    idx += 1
                }
                let raw = collected.joined(separator: "\n")
                let finalized = closed || streamEnded
                blocks.append(makeBlock(kind: .codeFence, raw: raw, isClosed: finalized, cache: cache, ordinal: blocks.count))
            } else if line.hasPrefix("$$") {
                var collected = [line]
                idx += 1
                var closed = line.trimmingCharacters(in: .whitespaces).count > 2 && line.trimmingCharacters(in: .whitespaces).hasSuffix("$$")
                while !closed && idx < lines.count {
                    collected.append(lines[idx])
                    if lines[idx].trimmingCharacters(in: .whitespaces).hasSuffix("$$") {
                        idx += 1
                        closed = true
                        break
                    }
                    idx += 1
                }
                let raw = collected.joined(separator: "\n")
                blocks.append(makeBlock(kind: .mathBlock, raw: raw, isClosed: closed || streamEnded, cache: cache, ordinal: blocks.count))
            } else if isHeading(line) {
                idx += 1
                let closed = idx < lines.count || streamEnded || markdown.hasSuffix("\n")
                blocks.append(makeBlock(kind: .heading, raw: line, isClosed: closed, cache: cache, ordinal: blocks.count))
            } else if line.hasPrefix("|") {
                var collected = [line]
                idx += 1
                while idx < lines.count && lines[idx].hasPrefix("|") {
                    collected.append(lines[idx])
                    idx += 1
                }
                let raw = collected.joined(separator: "\n")
                let closed = idx < lines.count || streamEnded
                blocks.append(makeBlock(kind: .table, raw: raw, isClosed: closed, cache: cache, ordinal: blocks.count))
            } else if line.isEmpty {
                idx += 1
            } else {
                var collected = [line]
                idx += 1
                while idx < lines.count && !lines[idx].isEmpty && !lines[idx].hasPrefix("```") && !lines[idx].hasPrefix("$$") && !lines[idx].hasPrefix("|") && !isHeading(lines[idx]) {
                    collected.append(lines[idx])
                    idx += 1
                }
                let raw = collected.joined(separator: "\n")
                let closed = idx < lines.count || streamEnded
                blocks.append(makeBlock(kind: .paragraph, raw: raw, isClosed: closed, cache: cache, ordinal: blocks.count))
            }

            // Guarantee strictly forward index progress on every iteration.
            if idx <= startIdx {
                idx = startIdx + 1
            }
        }
        return blocks
    }

    private static func isHeading(_ line: String) -> Bool {
        var hashes = 0
        for ch in line {
            if ch == "#" {
                hashes += 1
                if hashes > 6 { return false }
            } else if ch == " " && hashes >= 1 {
                return true
            } else {
                return false
            }
        }
        return false
    }

    private static func splitLinesPreservingOrder(_ text: String) -> [String] {
        return text.components(separatedBy: "\n")
    }

    private static func makeBlock(
        kind: SpikeParsedBlock.Kind,
        raw: String,
        isClosed: Bool,
        cache: StableBlockCaching?,
        ordinal: Int
    ) -> SpikeParsedBlock {
        if isClosed, let cached = cache?.cachedBlock(forRawSlice: raw, kind: kind) {
            return cached
        }
        let block = SpikeParsedBlock(stableID: "blk-\(ordinal)-\(kind.rawValue)-\(raw.utf8.count)", kind: kind, rawText: raw, isClosed: isClosed)
        if isClosed {
            cache?.storeClosedBlock(block)
        }
        return block
    }
}

// MARK: - Complete Lifecycle Streaming Reveal Adapter

@MainActor
public final class StreamRevealAdapter: MemoryPressureHandling {
    public struct DisplayState: Equatable {
        public var revealedPoints: Int = 0
        public var revealedUTF16Count: Int = 0
        public var revealedMaxY: CGFloat = 0.0
        public var currentPointsPerSecond: Double = 0.0
        public var isFinalizing: Bool = false
        public var isSettled: Bool = false
        public var isStoppedByUser: Bool = false
        public var errorMessage: String?
        public var hasPendingDeferredCommit: Bool = false
        public var anchorScrollOffsetY: CGFloat = 0.0
    }

    // 4 strictly separated stages:
    // Stage 1: Received
    public private(set) var receivedText: String = ""
    // Stage 2: Parsed
    public private(set) var parsedBlocks: [SpikeParsedBlock] = []
    // Stage 3: Laid out
    public private(set) var costMap: SpikeRevealCostMap = SpikeRevealCostMap(totalPoints: 0, totalUTF16Length: 0, entries: [], atomicUnits: [], textLines: [])
    // Stage 4: Displayed
    public private(set) var displayState = DisplayState()

    public private(set) var conversationID: String
    public private(set) var isBackgrounded: Bool = false
    public private(set) var isVisible: Bool = true
    public private(set) var isReadingHistory: Bool = false
    public private(set) var isKeyboardVisible: Bool = false
    public private(set) var activeSelectionUTF16Range: NSRange?
    public private(set) var structuralCommitCount: Int = 0

    public var policy: RevealVisualPolicy
    public let blockCache: StableBlockCaching
    public let scheduler: RevealAnimationScheduling
    public let maskCoordinator = RevealMaskCoordinator()
    public let maskContainerLayer = CALayer()
    public let maskHostLayer = CALayer()
    public let font: CTFont
    public let maxWidth: CGFloat

    private var controller: TextRevealController?
    private let durationMultiplier: Double
    private var lastTickTime: Double?
    private var lastTickPoints: Int = 0

    public init(
        conversationID: String = "chat-1",
        maxWidth: CGFloat = 330.0,
        font: CTFont? = nil,
        durationMultiplier: Double = 10.0,
        policy: RevealVisualPolicy = RevealVisualPolicy(),
        blockCache: StableBlockCaching = InMemoryStableBlockCache(),
        scheduler: RevealAnimationScheduling = VirtualRevealScheduler()
    ) {
        self.conversationID = conversationID
        self.maxWidth = maxWidth
        self.font = font ?? ClioFontLoader.systemReadingFont(size: 17.0)
        self.durationMultiplier = durationMultiplier
        self.policy = policy
        self.blockCache = blockCache
        self.scheduler = scheduler
        self.maskContainerLayer.frame = CGRect(x: 0, y: 0, width: maxWidth, height: 600)
        self.maskHostLayer.frame = self.maskContainerLayer.frame
        self.maskHostLayer.addSublayer(self.maskContainerLayer)
    }

    public func appendChunk(_ chunk: String, at now: Double) {
        guard !chunk.isEmpty, !displayState.isStoppedByUser, displayState.errorMessage == nil else { return }
        receivedText += chunk
        rebuildLayoutSnapshot(streamEnded: false)

        if controller == nil {
            controller = TextRevealController(initialRevealedCount: displayState.revealedPoints, initialLength: costMap.totalPoints, durationMultiplier: durationMultiplier)
        }
        controller?.observeUpdate(latestLength: costMap.totalPoints, at: now)
        displayState.isSettled = false
        displayState.isFinalizing = false

        ensureSchedulerStateIfEligible()
    }

    public func tick(at now: Double) {
        guard let controller else {
            scheduler.stop()
            return
        }
        let (revealedPts, isComplete) = controller.tick(now: now)
        if let prevTime = lastTickTime {
            let dt = max(0.001, now - prevTime)
            let dPts = Double(max(0, revealedPts - lastTickPoints))
            displayState.currentPointsPerSecond = dPts / dt
        }
        lastTickTime = now
        lastTickPoints = revealedPts

        displayState.revealedPoints = revealedPts
        let charCount = costMap.charCountForWidthBudget(revealedPts)
        displayState.revealedUTF16Count = charCount
        displayState.revealedMaxY = costMap.revealedMaxY(revealedPoints: revealedPts, revealedCharCount: charCount)
        displayState.isFinalizing = controller.isFinalizing

        maskCoordinator.updateRevealMask(
            hostLayer: maskHostLayer,
            renderContainerLayer: maskContainerLayer,
            lines: costMap.textLines,
            layerSize: maskContainerLayer.bounds.size,
            targetCharacterCount: isComplete ? nil : charCount,
            backingContents: nil,
            animateNewSegments: !isBackgrounded && isVisible,
            pointsPerSecond: displayState.currentPointsPerSecond,
            policy: policy
        )

        if !isReadingHistory {
            displayState.anchorScrollOffsetY = max(displayState.anchorScrollOffsetY, displayState.revealedMaxY)
        }

        if isComplete {
            attemptSettleInPlace()
        }
    }

    public func finishStream(at now: Double) {
        rebuildLayoutSnapshot(streamEnded: true)
        if controller == nil {
            controller = TextRevealController(initialRevealedCount: displayState.revealedPoints, initialLength: costMap.totalPoints, durationMultiplier: durationMultiplier)
        }
        controller?.finalize(finalLength: costMap.totalPoints)
        displayState.isFinalizing = true
        if let ctrl = controller, ctrl.revealedCount >= Double(ctrl.latestLength) {
            attemptSettleInPlace()
        } else {
            ensureSchedulerStateIfEligible()
        }
    }

    public func stopByUser(at now: Double) {
        // Strictly preserve all already-received content on user Stop.
        displayState.isStoppedByUser = true
        rebuildLayoutSnapshot(streamEnded: true)
        controller?.finalize(finalLength: costMap.totalPoints)
        attemptSettleInPlace()
    }

    public func failWithError(_ message: String, at now: Double) {
        // Strictly preserve received prefix while surfacing error state cleanly.
        displayState.errorMessage = message
        rebuildLayoutSnapshot(streamEnded: true)
        controller?.finalize(finalLength: costMap.totalPoints)
        attemptSettleInPlace()
    }

    public func beginSelection(range: NSRange) {
        activeSelectionUTF16Range = range
    }

    public func endSelection(at now: Double) {
        activeSelectionUTF16Range = nil
        if displayState.hasPendingDeferredCommit {
            displayState.hasPendingDeferredCommit = false
            commitStructuralSettle()
        }
    }

    public func setReadingHistory(_ reading: Bool, anchorOffsetY: CGFloat? = nil) {
        isReadingHistory = reading
        if let anchorOffsetY {
            displayState.anchorScrollOffsetY = anchorOffsetY
        }
    }

    public func setKeyboardVisible(_ visible: Bool) {
        isKeyboardVisible = visible
        // Keep history anchor locked even across keyboard transitions.
    }

    public func enterBackground() {
        isBackgrounded = true
        // Pause purely visual reveal ticks without aborting received text or upstream ingestion.
        scheduler.pause()
    }

    public func enterForeground(at now: Double) {
        isBackgrounded = false
        ensureSchedulerStateIfEligible()
    }

    public func switchConversation(to nextID: String) {
        scheduler.stop()
        maskCoordinator.clearMaskAndSnippets(renderContainerLayer: maskContainerLayer)
        conversationID = nextID
        controller = nil
        receivedText = ""
        parsedBlocks = []
        costMap = SpikeRevealCostMap(totalPoints: 0, totalUTF16Length: 0, entries: [], atomicUnits: [], textLines: [])
        displayState = DisplayState()
        activeSelectionUTF16Range = nil
        lastTickTime = nil
        lastTickPoints = 0
    }

    public func handleMemoryWarning() {
        blockCache.purgeAll()
        maskCoordinator.absorbCompletedSnippets(
            renderContainerLayer: maskContainerLayer,
            lines: costMap.textLines,
            targetCharacterCount: displayState.isSettled ? nil : displayState.revealedUTF16Count
        )
    }

    private func ensureSchedulerStateIfEligible() {
        guard !isBackgrounded, isVisible, !displayState.isSettled else {
            scheduler.pause()
            return
        }
        if let ctrl = controller, !displayState.isSettled {
            let _ = ctrl
            scheduler.start { [weak self] ts in
                self?.tick(at: ts)
            }
        }
    }

    private func attemptSettleInPlace() {
        displayState.revealedPoints = costMap.totalPoints
        displayState.revealedUTF16Count = costMap.totalUTF16Length
        displayState.revealedMaxY = costMap.revealedMaxY(revealedPoints: costMap.totalPoints, revealedCharCount: costMap.totalUTF16Length)
        scheduler.stop()

        if activeSelectionUTF16Range != nil {
            // Defer structural replacement/cleanup until the reader releases selection.
            displayState.hasPendingDeferredCommit = true
            return
        }
        commitStructuralSettle()
    }

    private func commitStructuralSettle() {
        displayState.isSettled = true
        displayState.isFinalizing = false
        maskCoordinator.clearMaskAndSnippets(renderContainerLayer: maskContainerLayer)
        controller = nil
        structuralCommitCount += 1
    }

    private func rebuildLayoutSnapshot(streamEnded: Bool) {
        parsedBlocks = SpikeIncrementalMarkdownParser.parse(receivedText, cache: blockCache, streamEnded: streamEnded)
        let profile = FontOpticalProfile.systemProse
        let safeBox = SafeLineBox.resolve(userReadingSize: 17.0, contentMultiplier: 1.65, fontForNaturalBox: font, profile: profile)
        let pStyle = safeBox.makeParagraphStyle()
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            .paragraphStyle: pStyle,
        ]
        let attributed = NSMutableAttributedString(string: receivedText, attributes: attrs)
        ClioMixedScriptKerning.apply(to: attributed, fontSize: safeBox.effectivePointSize)
        let layout = CoreTextRevealMeasurer.layoutText(attributed, maxWidth: maxWidth)
        costMap = SpikeRevealCostMap.buildSingleTextDocument(
            lines: layout.lines,
            atomicUnits: layout.atomicUnits,
            contentSize: layout.contentSize,
            utf16Length: attributed.length
        )
        maskContainerLayer.frame = CGRect(origin: .zero, size: CGSize(width: maxWidth, height: max(20.0, layout.contentSize.height + 8.0)))
    }
}
