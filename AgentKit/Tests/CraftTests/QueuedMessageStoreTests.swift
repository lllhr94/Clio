import Craft
import Foundation
import XCTest

final class QueuedMessageStoreTests: XCTestCase {
    private func makeTempRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clio-queued-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testRoundTripSavesAndRestoresTextPhotosAndFlags() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = StoredQueuedMessage(
            text: "发完上一句后帮我查一下日志",
            photos: [Data([0xFF, 0xD8, 0xFF, 0xE0]), Data([0x89, 0x50, 0x4E, 0x47])],
            interject: false,
            userInitiated: true
        )
        let second = StoredQueuedMessage(
            text: "顺便看看端口",
            photos: [],
            interject: true,
            userInitiated: true
        )
        let roomItem = StoredQueuedMessage(
            text: "大家一起看看",
            photos: [],
            interject: false,
            userInitiated: false
        )

        try QueuedMessageStore.save([first, second], for: "bot-alpha", under: root)
        try QueuedMessageStore.save([roomItem], for: "room-beta", under: root)

        let loaded = QueuedMessageStore.loadAll(from: root)
        XCTAssertEqual(loaded["bot-alpha"], [first, second])
        XCTAssertEqual(loaded["room-beta"], [roomItem])
    }

    func testEmptySaveRemovesFolderAndReplacesOldPhotosCleanly() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let original = StoredQueuedMessage(text: "第一条", photos: [Data(repeating: 0x01, count: 64)])
        try QueuedMessageStore.save([original], for: "bot-alpha", under: root)

        let updated = StoredQueuedMessage(text: "更新后", photos: [Data(repeating: 0x02, count: 32)])
        try QueuedMessageStore.save([updated], for: "bot-alpha", under: root)

        let afterUpdate = QueuedMessageStore.loadAll(from: root)
        XCTAssertEqual(afterUpdate["bot-alpha"], [updated])

        // Old photo file must not linger after atomic replacement.
        let folder = root.appendingPathComponent("bot-alpha", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertFalse(files.contains("\(original.id.uuidString)-0.img"))

        // Empty save removes the folder completely.
        try QueuedMessageStore.save([], for: "bot-alpha", under: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(QueuedMessageStore.loadAll(from: root).isEmpty)
    }

    func testLoadAllIgnoresAndCleansStaleStagingFolders() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let stale = root.appendingPathComponent(".new-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: stale.appendingPathComponent("queue.json"))

        let valid = StoredQueuedMessage(text: "保留这条")
        try QueuedMessageStore.save([valid], for: "bot-keep", under: root)

        let loaded = QueuedMessageStore.loadAll(from: root)
        XCTAssertEqual(loaded["bot-keep"], [valid])
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }
}
