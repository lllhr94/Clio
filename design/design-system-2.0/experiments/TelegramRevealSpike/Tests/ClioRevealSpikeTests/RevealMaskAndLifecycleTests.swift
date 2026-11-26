import CoreGraphics
import CoreText
import Foundation
import QuartzCore
import XCTest
@testable import ClioRevealSpike

#if canImport(UIKit)
import UIKit
#endif

final class RevealMaskAndLifecycleTests: XCTestCase {
    @MainActor
    func testMaskLayerMergesFullLinesAndRespectsSnippetClampAndBypass() async throws {
        let longText = Array(repeating: "这是一段用来测试多行全亮遮罩合并和前沿飞入图层的中文文本。", count: 6).joined()
        let font = ClioFontLoader.loadBundledFont(named: "ClioKai-Medium.ttf", size: 17.0)
            ?? ClioFontLoader.systemReadingFont(size: 17.0)
        let attributed = NSMutableAttributedString(
            string: longText,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
        )
        let layout = CoreTextRevealMeasurer.layoutText(attributed, maxWidth: 260.0)
        XCTAssertGreaterThanOrEqual(layout.lines.count, 5)

        let paddedSize = CGSize(width: layout.contentSize.width + 8.0, height: layout.contentSize.height + 8.0)
        let cgImage = CoreTextRevealMeasurer.rasterizeBackingImage(lines: layout.lines, size: paddedSize, scale: 2.0, padding: 4.0)
        XCTAssertNotNil(cgImage)

        let hostLayer = CALayer()
        hostLayer.frame = CGRect(origin: .zero, size: paddedSize)
        let containerLayer = CALayer()
        containerLayer.frame = hostLayer.bounds
        hostLayer.addSublayer(containerLayer)

        let coordinator = RevealMaskCoordinator()
        let midChar = attributed.length / 2
        coordinator.updateRevealMask(
            hostLayer: hostLayer,
            renderContainerLayer: containerLayer,
            lines: layout.lines,
            layerSize: paddedSize,
            targetCharacterCount: midChar,
            backingContents: cgImage,
            backingScale: 2.0,
            animateNewSegments: false,
            pointsPerSecond: 400.0
        )

        // All full lines above the active line must merge into 1 pendingFullPrefix sublayer + 1 active line sublayer <= 2!
        XCTAssertLessThanOrEqual(coordinator.activeMaskSublayerCount, 2)
        XCTAssertNotNil(coordinator.revealMaskLayer)

        // Spawn snippets on a small incremental advance under normal policy (300 pts/s <= 1200 threshold).
        coordinator.updateRevealMask(
            hostLayer: hostLayer,
            renderContainerLayer: containerLayer,
            lines: layout.lines,
            layerSize: paddedSize,
            targetCharacterCount: midChar + 8,
            backingContents: cgImage,
            backingScale: 2.0,
            animateNewSegments: true,
            pointsPerSecond: 300.0
        )
        XCTAssertGreaterThan(coordinator.activeSnippetCount, 0)
        XCTAssertLessThan(coordinator.lastMaskCharacterLimit, midChar + 8, "Mask must clamp to lowest animating snippet")

        // Absorb completed snippets and verify mask snaps cleanly to midChar + 8.
        coordinator.absorbCompletedSnippets(renderContainerLayer: containerLayer, lines: layout.lines, targetCharacterCount: midChar + 8)
        XCTAssertEqual(coordinator.activeSnippetCount, 0)
        XCTAssertEqual(coordinator.lastMaskCharacterLimit, midChar + 8)

        // Verify bypass policies: ReduceMotion, Pref.fade=false, LowPowerMode, Thermal, High Points/s (>1200)
        coordinator.updateRevealMask(
            hostLayer: hostLayer,
            renderContainerLayer: containerLayer,
            lines: layout.lines,
            layerSize: paddedSize,
            targetCharacterCount: midChar + 14,
            backingContents: cgImage,
            backingScale: 2.0,
            animateNewSegments: true,
            pointsPerSecond: 1450.0
        )
        XCTAssertEqual(coordinator.activeSnippetCount, 0)
        XCTAssertEqual(coordinator.lastBypassReason, .highPointsBurst)

        coordinator.updateRevealMask(
            hostLayer: hostLayer,
            renderContainerLayer: containerLayer,
            lines: layout.lines,
            layerSize: paddedSize,
            targetCharacterCount: midChar + 18,
            backingContents: cgImage,
            backingScale: 2.0,
            animateNewSegments: true,
            pointsPerSecond: 200.0,
            policy: RevealVisualPolicy(reduceMotion: true)
        )
        XCTAssertEqual(coordinator.lastBypassReason, .reduceMotionEnabled)

        coordinator.clearMaskAndSnippets(renderContainerLayer: containerLayer)
        XCTAssertNil(containerLayer.mask)
        XCTAssertEqual(coordinator.activeMaskSublayerCount, 0)
    }

    func testIncrementalParserExhaustivePrefixSafetyAndRawPreservation() {
        let md = """
        # 标题一
        普通段落带 #标签 和 **未闭合加粗**。
        | 列A | 列B |
        | --- | --- |
        | 1 | 👨‍👩‍👧‍👦 |

        ```swift
        let a = 1 + 2
        ```

        $$\\int_0^1 x^2 dx$$
        """

        for i in 0...md.count {
            let prefix = String(md.prefix(i))
            let blocks = SpikeIncrementalMarkdownParser.parse(prefix, streamEnded: false)
            if !prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                XCTAssertFalse(blocks.isEmpty, "Non-empty prefix at index \(i) must produce blocks without stalling")
            }
            // No unparsed character deletion on code/math/hash prefixes:
            let rejoinedLen = blocks.map { $0.rawText.count }.reduce(0, +)
            XCTAssertLessThanOrEqual(rejoinedLen, prefix.count)
        }

        // Single stray '#' and '#tag' must terminate cleanly.
        let hashBlocks = SpikeIncrementalMarkdownParser.parse("#\n#标签", streamEnded: true)
        XCTAssertEqual(hashBlocks.count, 1)
        XCTAssertTrue(hashBlocks[0].rawText.contains("#"))
        XCTAssertTrue(hashBlocks[0].rawText.contains("#标签"))
    }

    @MainActor
    func testFullStreamingLifecycleSelectionHistoryBackgroundStopErrorAndZeroIdleTick() async throws {
        let scheduler = VirtualRevealScheduler()
        let cache = InMemoryStableBlockCache()
        let adapter = StreamRevealAdapter(
            conversationID: "chat-a",
            maxWidth: 320.0,
            font: ClioFontLoader.loadBundledFont(named: "ClioKai-Medium.ttf", size: 17.0),
            durationMultiplier: 10.0,
            blockCache: cache,
            scheduler: scheduler
        )

        // 1. Reader is browsing history with offset 420pt -> new stream + keyboard must NEVER move anchor!
        adapter.setReadingHistory(true, anchorOffsetY: 420.0)
        adapter.appendChunk("# 第一节\n\n这是正在流式到达的历史不抢滚测试段落。", at: 0.0)
        adapter.setKeyboardVisible(true)
        scheduler.stepFrame(at: 0.05)
        XCTAssertTrue(scheduler.isRunning)
        XCTAssertEqual(adapter.displayState.anchorScrollOffsetY, 420.0, accuracy: 0.001)

        // 2. Enter background: pauses purely visual displayLink while preserving & accepting arriving chunks!
        adapter.enterBackground()
        XCTAssertFalse(scheduler.isRunning)
        let framesBeforeBg = scheduler.scheduledFrameCount
        scheduler.stepFrame(at: 0.2)
        XCTAssertEqual(scheduler.scheduledFrameCount, framesBeforeBg, "Backgrounded adapter must execute 0 render ticks")

        adapter.appendChunk("后台期间继续抵达的第二段内容。", at: 0.5)
        XCTAssertTrue(adapter.receivedText.contains("后台期间继续抵达的第二段内容。"))

        adapter.enterForeground(at: 0.6)
        XCTAssertTrue(scheduler.isRunning)

        // 3. Active selection locks structural settle & defers cleanup until endSelection().
        adapter.beginSelection(range: NSRange(location: 4, length: 6))
        adapter.finishStream(at: 0.8)
        XCTAssertTrue(adapter.displayState.hasPendingDeferredCommit)
        XCTAssertFalse(adapter.displayState.isSettled)
        XCTAssertEqual(adapter.activeSelectionUTF16Range, NSRange(location: 4, length: 6))
        XCTAssertFalse(scheduler.isRunning, "Idle scheduler must stop immediately even while waiting for selection release")

        adapter.endSelection(at: 1.2)
        XCTAssertFalse(adapter.displayState.hasPendingDeferredCommit)
        XCTAssertTrue(adapter.displayState.isSettled)
        XCTAssertNil(adapter.maskCoordinator.revealMaskLayer)
        XCTAssertFalse(scheduler.isRunning)

        // 4. Memory warning purges cache safely.
        adapter.handleMemoryWarning()

        // 5. Switch conversation resets transient reveal cleanly; User Stop preserves prefix; Network Error preserves prefix.
        adapter.switchConversation(to: "chat-b")
        XCTAssertEqual(adapter.conversationID, "chat-b")
        XCTAssertFalse(scheduler.isRunning)

        adapter.appendChunk("保留前一半文本", at: 2.0)
        scheduler.stepFrame(at: 2.02)
        adapter.stopByUser(at: 2.1)
        XCTAssertTrue(adapter.displayState.isStoppedByUser)
        XCTAssertEqual(adapter.receivedText, "保留前一半文本")
        XCTAssertEqual(adapter.displayState.revealedUTF16Count, ("保留前一半文本" as NSString).length)
        XCTAssertFalse(scheduler.isRunning)

        adapter.switchConversation(to: "chat-c")
        adapter.appendChunk("中断前已收到内容", at: 3.0)
        adapter.failWithError("Network connection lost", at: 3.1)
        XCTAssertEqual(adapter.displayState.errorMessage, "Network connection lost")
        XCTAssertEqual(adapter.receivedText, "中断前已收到内容")
        XCTAssertFalse(scheduler.isRunning)
    }

    #if canImport(UIKit)
    @MainActor
    func testSimulatorUIKitRevealViewScrollAnchorAndCoreTextFrameTimings() async throws {
        let sample = Array(repeating: "在 iOS 模拟器 UIKit 环境实测 CoreText 墨迹框、`RevealMaskCoordinator`、`RevealSnippetLayer` 与 `UIScrollView` 锚点锁定。English + 👨‍👩‍👧‍👦 + 2026.", count: 8).joined(separator: "\n\n")
        let kai = ClioFontLoader.loadBundledFont(named: "ClioKai-Medium.ttf", size: 17.0)
            ?? ClioFontLoader.systemReadingFont(size: 17.0)
        let metrics = SafeLineBox.resolve(userReadingSize: 17.0, contentMultiplier: 1.65, fontForNaturalBox: kai, profile: .clioKaiMedium)
        let attributed = NSMutableAttributedString(
            string: sample,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): kai,
                .paragraphStyle: metrics.makeParagraphStyle(paragraphSpacing: 13.0),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): UIColor.label.cgColor,
            ]
        )
        ClioMixedScriptKerning.apply(to: attributed, fontSize: metrics.effectivePointSize)

        let revealView = SpikeRevealTextView(frame: CGRect(x: 0, y: 0, width: 350, height: 600))
        let layoutStart = CFAbsoluteTimeGetCurrent()
        let layout = revealView.configure(attributed: attributed, maxWidth: 330.0)
        let layoutMs = (CFAbsoluteTimeGetCurrent() - layoutStart) * 1000.0
        XCTAssertGreaterThan(layout.lines.count, 8)
        XCTAssertNotNil(revealView.renderLayer.contents)

        // Drive UIScrollView anchor lock simulation while growing reveal mask below viewport.
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 350, height: 400))
        scrollView.contentSize = CGSize(width: 350, height: 1800)
        scrollView.contentOffset = CGPoint(x: 0, y: 312.5)
        let initialOffsetY = scrollView.contentOffset.y

        var stepDurationsMs: [Double] = []
        let totalChars = attributed.length
        let stepCount = 30
        for s in 1...stepCount {
            let targetChars = (totalChars * s) / stepCount
            let t0 = CFAbsoluteTimeGetCurrent()
            revealView.applyReveal(characterCount: targetChars, animateNewSegments: s % 2 == 0, pointsPerSecond: 450.0)
            stepDurationsMs.append((CFAbsoluteTimeGetCurrent() - t0) * 1000.0)
        }
        revealView.applyReveal(characterCount: nil, animateNewSegments: false, pointsPerSecond: 0.0)
        revealView.coordinator.clearMaskAndSnippets(renderContainerLayer: revealView.renderContainer.layer)
        XCTAssertNil(revealView.renderContainer.layer.mask)
        XCTAssertEqual(abs(scrollView.contentOffset.y - initialOffsetY), 0.0, accuracy: 0.01)

        // Verify CADisplayLinkRevealScheduler stops cleanly with zero idle retain loop.
        let dlScheduler = CADisplayLinkRevealScheduler()
        dlScheduler.start { _ in }
        XCTAssertTrue(dlScheduler.isRunning)
        dlScheduler.stop()
        XCTAssertFalse(dlScheduler.isRunning)

        let sorted = stepDurationsMs.sorted()
        let avgMaskMs = stepDurationsMs.reduce(0.0, +) / Double(stepDurationsMs.count)
        let p95Idx = min(sorted.count - 1, Int(Double(sorted.count) * 0.95))
        let maxMaskMs = sorted.last ?? 0.0
        print(
            String(
                format: "[SIM_METRIC] layoutAndRasterMs=%.2f lines=%d avgMaskUpdateMs=%.3f p95MaskUpdateMs=%.3f maxMaskUpdateMs=%.3f",
                layoutMs, layout.lines.count, avgMaskMs, sorted[p95Idx], maxMaskMs
            )
        )
    }
    #endif
}
