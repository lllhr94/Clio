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

    func testCleanAbortsWhenAbortFlagTrips() throws {
        let box = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.appSupport) }

        let now = Date()
        let orphan = "88888888-8888-8888-8888-888888888888.jpg"
        try writeFile(box.media.appendingPathComponent(orphan), contents: Data(repeating: 0x22, count: 1024), ageSeconds: 600, now: now)
        try writeFile(box.doccache.appendingPathComponent("cache.txt"), contents: Data("abc".utf8), ageSeconds: 10, now: now)

        let cleaned = StorageCleanup.clean(teamRoot: box.team, graceSeconds: 60, now: now, abortIf: { true })
        XCTAssertEqual(cleaned.removedMediaCount, 0)
        XCTAssertEqual(cleaned.removedDocCacheCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: box.media.appendingPathComponent(orphan).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: box.doccache.appendingPathComponent("cache.txt").path))
    }

    func testCleanAbortsAndPreservesRestoredPhotoWhenTeamDirectorySwaps() throws {
        let box = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.appSupport) }

        let now = Date()
        let sharedName = "99999999-9999-9999-9999-999999999999.jpg"
        try writeFile(box.media.appendingPathComponent(sharedName), contents: Data("old-orphan".utf8), ageSeconds: 600, now: now)
        try Data("[]".utf8).write(to: box.chats.appendingPathComponent("bot-a.json"))

        // Prepare a replacement Team/ directory simulating Backup.restore swapping in a backup that references the same photo name.
        let restoredStaging = box.appSupport.appendingPathComponent("Team-restored", isDirectory: true)
        let restoredMedia = restoredStaging.appendingPathComponent("media", isDirectory: true)
        let restoredChats = restoredStaging.appendingPathComponent("chats", isDirectory: true)
        try FileManager.default.createDirectory(at: restoredMedia, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: restoredChats, withIntermediateDirectories: true)
        try writeFile(restoredMedia.appendingPathComponent(sharedName), contents: Data("restored-precious-photo".utf8), ageSeconds: 600, now: now)
        try Data("[{\"photos\":[\"\(sharedName)\"]}]".utf8).write(to: restoredChats.appendingPathComponent("bot-a.json"))

        let oldAside = box.appSupport.appendingPathComponent("Team-old", isDirectory: true)
        final class SwapBox: @unchecked Sendable {
            let lock = NSLock()
            var checks = 0
            var swapped = false
        }
        let state = SwapBox()

        // Simulate a swap right between orphan scan and delete, while abortIf still returns false,
        // proving inode verification on Team/ and media/ independently stops deletion of restored files.
        let cleaned = StorageCleanup.clean(teamRoot: box.team, graceSeconds: 60, now: now) {
            state.lock.withLock {
                state.checks += 1
                // Check 1 is at entry, check 2 is inside findOrphanMedia (1 chat file), check 3 is right before unlink.
                if state.checks == 3, !state.swapped {
                    state.swapped = true
                    try? FileManager.default.moveItem(at: box.team, to: oldAside)
                    try? FileManager.default.moveItem(at: restoredStaging, to: box.team)
                }
            }
            return false
        }

        XCTAssertTrue(state.lock.withLock { state.swapped })
        XCTAssertEqual(cleaned.removedMediaCount, 0)
        let surviving = try Data(contentsOf: box.team.appendingPathComponent("media/\(sharedName)"))
        XCTAssertEqual(surviving, Data("restored-precious-photo".utf8))
    }

    func testFailClosedWhenChatFileIsSymlink() throws {
        let box = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.appSupport) }

        let now = Date()
        let photo = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.jpg"
        try writeFile(box.media.appendingPathComponent(photo), contents: Data(repeating: 0x33, count: 1024), ageSeconds: 600, now: now)

        let externalChat = box.appSupport.appendingPathComponent("external-chat.json")
        try Data("[{\"photos\":[\"\(photo)\"]}]".utf8).write(to: externalChat)
        let symlinkChat = box.chats.appendingPathComponent("bot-symlink.json")
        try FileManager.default.createSymbolicLink(at: symlinkChat, withDestinationURL: externalChat)

        let breakdown = StorageCleanup.inspect(appSupportRoot: box.appSupport, teamRoot: box.team, graceSeconds: 60, now: now)
        XCTAssertTrue(breakdown.scanSkippedOrphans)
        XCTAssertEqual(breakdown.orphanMediaCount, 0)

        let cleaned = StorageCleanup.clean(teamRoot: box.team, graceSeconds: 60, now: now)
        XCTAssertEqual(cleaned.removedMediaCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: box.media.appendingPathComponent(photo).path))
    }
}
