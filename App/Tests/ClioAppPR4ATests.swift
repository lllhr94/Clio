import Craft
import UIKit
import XCTest
@testable import Clio

@MainActor
final class ClioAppPR4ATests: XCTestCase {
    private func makeTempDir(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clio-pr4a-\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeTinyPNG() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        let img = renderer.image { ctx in
            UIColor.systemRed.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        return img.pngData() ?? Data()
    }

    // MARK: - StickerPackStore (0 presets + import/delete + max 1/turn in Casual Track)

    func testStickerPackStoreShipsWithZeroPresetsAndPersistsCustomImports() {
        let dir = makeTempDir("stickers")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = StickerPackStore(teamDirectory: dir)
        XCTAssertTrue(store.packs.isEmpty, "StickerPackStore must ship with zero preset packs")

        let pack = store.createPack(name: "日常小图")
        let png = makeTinyPNG()
        XCTAssertFalse(png.isEmpty)
        let item = store.importSticker(imageData: png, label: "早安", into: pack.id)
        XCTAssertNotNil(item)

        let reloaded = StickerPackStore(teamDirectory: dir)
        XCTAssertEqual(reloaded.packs.count, 1)
        XCTAssertEqual(reloaded.packs[0].items.count, 1)
        XCTAssertNotNil(reloaded.image(for: item!.id))

        reloaded.removeSticker(itemID: item!.id, from: pack.id)
        XCTAssertTrue(reloaded.packs[0].items.isEmpty)
        XCTAssertNil(reloaded.image(for: item!.id))
    }

    func testCasualTrackControllerEnforcesOneStickerPerTurnAndQuietDraftRestore() {
        let dir = makeTempDir("casual-ctrl")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = CasualTrackStore(
            canonicalTeamDirectory: dir,
            projectionDatabaseURL: dir.appendingPathComponent("casual.db")
        )
        let ctrl = CasualTrackController(botID: "chief", store: store, mergeWindowSeconds: 5.0)

        XCTAssertTrue(ctrl.canSendStickerInCurrentTurn)
        XCTAssertTrue(ctrl.sendSticker("stk-1"))
        XCTAssertFalse(ctrl.canSendStickerInCurrentTurn)
        XCTAssertFalse(ctrl.sendSticker("stk-2"), "Second sticker in same turn must be rejected")

        // Leaving Casual Track cancels timer and persists quiet draft without sending
        ctrl.saveComposerDraft("明天记得买咖啡")
        ctrl.cancelForTrackSwitch(extraUnsentInput: "还有牛奶")
        XCTAssertTrue(ctrl.pendingBurstSegments.isEmpty)
        let restored = ctrl.restoreQuietDraftIfNeeded()
        XCTAssertEqual(restored, "明天记得买咖啡\n还有牛奶")
    }

    func testCasualTrackFiltersBuiltInHiddenSkills() {
        let items = [
            "builtin/quiet-musing",
            "builtin/user-guide",
            "quiet-musing",
            "user-guide",
            "custom/poetry"
        ]
        let filtered = CasualTrackPolicy.filterSkills(items, id: { $0 })
        XCTAssertEqual(filtered, ["custom/poetry"])
    }
}
