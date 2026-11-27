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

    // MARK: - DraftTransfer (`Move to...` collision policy + revision-checked 5s undo)

    func testDraftTransferMoveCollisionAppendReplaceAndRevisionCheckedUndo() async {
        let src = "test-pr4a-src-\(UUID().uuidString.lowercased())"
        let dst = "test-pr4a-dst-\(UUID().uuidString.lowercased())"
        let qid1 = UUID()
        let qid2 = UUID()
        let photo = makeTinyPNG()
        defer {
            Task {
                _ = await DraftTransfer.saveSnapshot(.init(text: "", photos: [], files: [], queuedIds: []), for: src)
                _ = await DraftTransfer.saveSnapshot(.init(text: "", photos: [], files: [], queuedIds: []), for: dst)
            }
        }

        let initialSource = DraftTransfer.Snapshot(text: "源草稿内容", photos: [photo], files: ["notes/a.md"], queuedIds: [qid1])
        let initialTarget = DraftTransfer.Snapshot(text: "目标原有草稿", photos: [], files: ["notes/b.md"], queuedIds: [qid2])
        let savedSrc = await DraftTransfer.saveSnapshot(initialSource, for: src)
        let savedDst = await DraftTransfer.saveSnapshot(initialTarget, for: dst)
        XCTAssertTrue(savedSrc && savedDst)

        // Without policy -> asks for collision choice
        let probe = await DraftTransfer.move(from: src, to: dst, policy: nil)
        XCTAssertEqual(probe, .needsCollisionChoice)

        // Append policy preserves both text, files, photos, and queuedIds
        let now = Date()
        let moved = await DraftTransfer.move(from: src, to: dst, policy: .append, now: now)
        guard case .moved(let receipt) = moved else {
            return XCTFail("Expected .moved receipt, got \(moved)")
        }

        let afterSource = await DraftTransfer.loadSnapshot(for: src)
        let afterTarget = await DraftTransfer.loadSnapshot(for: dst)
        XCTAssertTrue(afterSource.isEmpty)
        XCTAssertEqual(afterTarget.text, "目标原有草稿\n\n源草稿内容")
        XCTAssertEqual(afterTarget.files, ["notes/b.md", "notes/a.md"])
        XCTAssertEqual(afterTarget.photos.count, 1)
        XCTAssertEqual(Set(afterTarget.queuedIds), Set([qid1, qid2]))

        // Expired undo (> 5s) must refuse
        let expired = await DraftTransfer.undo(receipt, now: now.addingTimeInterval(6.0))
        XCTAssertEqual(expired, .expired)

        // If target was edited after the move, revision-checked undo MUST return `.conflicted`
        var editedTarget = afterTarget
        editedTarget.text += "（新编辑）"
        _ = await DraftTransfer.saveSnapshot(editedTarget, for: dst)
        let conflicted = await DraftTransfer.undo(receipt, now: now.addingTimeInterval(2.0))
        XCTAssertEqual(conflicted, .conflicted)

        // Restore unedited post-move state and verify clean undo within 5s restores both chats exactly
        _ = await DraftTransfer.saveSnapshot(afterTarget, for: dst)
        let restored = await DraftTransfer.undo(receipt, now: now.addingTimeInterval(2.0))
        XCTAssertEqual(restored, .restored)
        let restoredSource = await DraftTransfer.loadSnapshot(for: src)
        let restoredTarget = await DraftTransfer.loadSnapshot(for: dst)
        XCTAssertEqual(restoredSource.text, initialSource.text)
        XCTAssertEqual(restoredSource.files, initialSource.files)
        XCTAssertEqual(restoredTarget.text, initialTarget.text)
        XCTAssertEqual(restoredTarget.files, initialTarget.files)
    }
}
