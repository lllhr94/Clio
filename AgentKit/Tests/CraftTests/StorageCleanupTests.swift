import Craft
import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class StorageCleanupTests: XCTestCase {
    private func makeSandbox() throws -> (appSupport: URL, team: URL, chats: URL, media: URL, doccache: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clio-storage-\(UUID().uuidString)", isDirectory: true)
        let team = root.appendingPathComponent("Team", isDirectory: true)
        let chats = team.appendingPathComponent("chats", isDirectory: true)
        let media = team.appendingPathComponent("media", isDirectory: true)
        let doccache = team.appendingPathComponent("doccache", isDirectory: true)
        for dir in [chats, media, doccache] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return (root, team, chats, media, doccache)
    }

    private func writeFile(_ url: URL, contents: Data, ageSeconds: TimeInterval = 3600, now: Date) throws {
        try contents.write(to: url)
        let date = now.addingTimeInterval(-ageSeconds)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    func testCleanRemovesOnlyOldOrphanMediaAndDocCache() throws {
        let box = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.appSupport) }

        let now = Date()
        let activePhoto = "11111111-1111-1111-1111-111111111111.jpg"
        let leafPhoto = "22222222-2222-2222-2222-222222222222.jpg"
        let brokenPhoto = "33333333-3333-3333-3333-333333333333.jpg"
        let inMemoryPhoto = "44444444-4444-4444-4444-444444444444.jpg"
        let freshOrphan = "55555555-5555-5555-5555-555555555555.jpg"
        let oldOrphan = "66666666-6666-6666-6666-666666666666.jpg"

        let blob = Data(repeating: 0xAB, count: 2048)
        for name in [activePhoto, leafPhoto, brokenPhoto, inMemoryPhoto, oldOrphan] {
            try writeFile(box.media.appendingPathComponent(name), contents: blob, ageSeconds: 600, now: now)
        }
        // Within grace window: must NOT be deleted yet.
        try writeFile(box.media.appendingPathComponent(freshOrphan), contents: blob, ageSeconds: 5, now: now)

        // Active chat, archived leaf, and broken backup JSONs
        try Data("[{\"photos\":[\"\(activePhoto)\"]}]".utf8)
            .write(to: box.chats.appendingPathComponent("bot-a.json"))
        try Data("[{\"photos\":[\"\(leafPhoto)\"]}]".utf8)
            .write(to: box.chats.appendingPathComponent("bot-a~leaf1.json"))
        try Data("{\"truncated\":\"\(brokenPhoto)\"".utf8)
            .write(to: box.chats.appendingPathComponent("bot-a.broken-123.json"))

        // Doccache entry
        try writeFile(box.doccache.appendingPathComponent("abc123.txt"), contents: Data(repeating: 0x41, count: 1024), ageSeconds: 10, now: now)

        let before = StorageCleanup.inspect(
            appSupportRoot: box.appSupport,
            teamRoot: box.team,
            extraReferencedMedia: [inMemoryPhoto],
            graceSeconds: 60,
            now: now
        )
        XCTAssertFalse(before.scanSkippedOrphans)
        XCTAssertEqual(before.orphanMediaCount, 1)
        XCTAssertEqual(before.docCacheCount, 1)
        XCTAssertGreaterThan(before.cleanableBytes, 0)

        let cleaned = StorageCleanup.clean(
            teamRoot: box.team,
            extraReferencedMedia: [inMemoryPhoto],
            graceSeconds: 60,
            now: now
        )
        XCTAssertEqual(cleaned.removedMediaCount, 1)
        XCTAssertEqual(cleaned.removedDocCacheCount, 1)
        XCTAssertGreaterThan(cleaned.freedBytes, 0)

        let fm = FileManager.default
        for kept in [activePhoto, leafPhoto, brokenPhoto, inMemoryPhoto, freshOrphan] {
            XCTAssertTrue(fm.fileExists(atPath: box.media.appendingPathComponent(kept).path), "Should keep \(kept)")
        }
        XCTAssertFalse(fm.fileExists(atPath: box.media.appendingPathComponent(oldOrphan).path))
        XCTAssertFalse(fm.fileExists(atPath: box.doccache.appendingPathComponent("abc123.txt").path))
        // Chats untouched
        XCTAssertTrue(fm.fileExists(atPath: box.chats.appendingPathComponent("bot-a.json").path))
    }

    func testSkipsSymlinksInMediaAndDocCache() throws {
        let box = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.appSupport) }

        let outside = box.appSupport.appendingPathComponent("outside-important.txt")
        try Data("keep".utf8).write(to: outside)
        let link = box.doccache.appendingPathComponent("sneaky.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let result = StorageCleanup.clean(teamRoot: box.team, graceSeconds: 0)
        XCTAssertEqual(result.removedDocCacheCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testFailClosedWhenChatFileIsUnreadable() throws {
        // Root user ignores chmod 000; skip only if running as root.
        guard geteuid() != 0 else { return }
        let box = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.appSupport) }

        let now = Date()
        let photo = "77777777-7777-7777-7777-777777777777.jpg"
        try writeFile(box.media.appendingPathComponent(photo), contents: Data(repeating: 0x11, count: 1024), ageSeconds: 600, now: now)
        let unreadable = box.chats.appendingPathComponent("bot-locked.json")
        try Data("[]".utf8).write(to: unreadable)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path) }

        let breakdown = StorageCleanup.inspect(appSupportRoot: box.appSupport, teamRoot: box.team, graceSeconds: 60, now: now)
        XCTAssertTrue(breakdown.scanSkippedOrphans)
        XCTAssertEqual(breakdown.orphanMediaCount, 0)

        let cleaned = StorageCleanup.clean(teamRoot: box.team, graceSeconds: 60, now: now)
        XCTAssertEqual(cleaned.removedMediaCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: box.media.appendingPathComponent(photo).path))
    }
}
