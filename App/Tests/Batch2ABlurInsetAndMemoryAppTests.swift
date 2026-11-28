@testable import Clio
import Foundation
import UIKit
import XCTest

@MainActor
final class Batch2ABlurInsetAndMemoryAppTests: XCTestCase {
    // MARK: - CLIO-028: Cross-turn streamScanner & override cleanup + memory warning observer

    func testStreamScannersAndBlockHeightOverridesPruneAcrossSameChatTurns() {
        let cache = ChatLayoutCache()
        let style = ChatListStyle.current(traits: UITraitCollection.current, reduceMotion: false)

        // Turn 1 streaming creates "streaming-1" scanner and block height override.
        _ = cache.measureLiveStreamingProse(
            text: "第一轮回复段落\n\n```swift\nlet a = 1\n```\n第二段正在流式输出",
            generation: 1,
            collectionWidth: 390,
            style: style
        )
        _ = cache.setBlockHeightOverride(120, key: "math|streaming-1|0", ownerID: "streaming-1")
        XCTAssertEqual(cache.builder.debugStreamScannerCount, 1)
        XCTAssertEqual(cache.debugBlockHeightOverrideOwnerCount, 1)

        // Turn 2 streaming inside the SAME chat must evict stale "streaming-1" scanner automatically.
        _ = cache.measureLiveStreamingProse(
            text: "第二轮流式回复\n\n新的内容",
            generation: 2,
            collectionWidth: 390,
            style: style
        )
        _ = cache.setBlockHeightOverride(96, key: "math|streaming-2|0", ownerID: "streaming-2")
        XCTAssertEqual(cache.builder.debugStreamScannerCount, 1, "New streaming turn must evict previous turn's streaming scanner")

        // Turn end prunes all "streaming-*" scanners and overrides, while keeping retained finalized rows.
        _ = cache.setBlockHeightOverride(84, key: "math|row-keep|0", ownerID: "row-keep")
        _ = cache.setBlockHeightOverride(84, key: "math|row-evicted|0", ownerID: "row-evicted")
        cache.pruneStaleStreamingState(activeStreamingOwnerID: nil, retainedRowIDs: ["row-keep"])

        XCTAssertEqual(cache.builder.debugStreamScannerCount, 0)
        XCTAssertEqual(cache.debugBlockHeightOverrideOwnerCount, 1, "Only retained non-streaming row override should remain")
    }

    func testFreshScannerEvictsOnFinalizedBuildAndMemoryWarningPurgesCaches() {
        let cache = ChatLayoutCache()
        let style = ChatListStyle.current(traits: UITraitCollection.current, reduceMotion: false)

        _ = cache.builder.buildAssistantSlices(
            "正在显字的回复\n\n第二段",
            style: style,
            isStreaming: true,
            streamKey: "fresh-msg-1"
        )
        XCTAssertEqual(cache.builder.debugStreamScannerCount, 1)

        // Finalizing with the same `streamKey` and `isStreaming: false` must deterministically remove "fresh-msg-1".
        _ = cache.builder.buildAssistantSlices(
            "正在显字的回复\n\n第二段",
            style: style,
            isStreaming: false,
            streamKey: "fresh-msg-1"
        )
        XCTAssertEqual(cache.builder.debugStreamScannerCount, 0)

        // Memory warning notification must purge cached scanners and streaming overrides.
        _ = cache.measureLiveStreamingProse(
            text: "内存压力测试文本",
            generation: 9,
            collectionWidth: 390,
            style: style
        )
        _ = cache.setBlockHeightOverride(110, key: "math|streaming-9|0", ownerID: "streaming-9")
        XCTAssertGreaterThan(cache.builder.debugStreamScannerCount, 0)

        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))

        XCTAssertEqual(cache.builder.debugStreamScannerCount, 0, "Memory warning must clear stream scanners")
        XCTAssertEqual(cache.debugBlockHeightOverrideOwnerCount, 0, "Memory warning must purge stale streaming overrides")
    }
}
