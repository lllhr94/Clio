import Foundation
import XCTest
@testable import Craft

final class ExperienceStoreTests: XCTestCase {
    func testWriteProvenance() throws {
        let store = ExperienceStore.inMemory()
        for source in [ExperienceWriteSource.subtask, .casualTrack, .routine] {
            XCTAssertThrowsError(try store.record(title: "Title", content: "Body", source: source)) {
                XCTAssertEqual($0 as? ExperienceStoreError, .writeNotAllowed(source))
            }
        }
        XCTAssertTrue(try store.readBook().records.isEmpty)
        for source in [ExperienceWriteSource.mainChat, .user, .importAction] {
            XCTAssertEqual(try store.record(title: "Title", content: source.rawValue, source: source).source, source)
        }
        XCTAssertEqual(try store.loadAll().count, 3)
    }

    func testRedactionOnWriteAndLegacyReads() throws {
        let url = temporaryCanonicalURL()
        let store = ExperienceStore(canonicalFileURL: url)
        let secret = "secret-token-long"
        let secrets = ["secret-token", secret]
        for content in ["  ", secret] {
            XCTAssertThrowsError(try store.record(title: "Title", content: content, source: .user, secrets: secrets)) {
                XCTAssertEqual($0 as? ExperienceStoreError, .emptyContent)
            }
        }
        let expectedTitle = "Deploy 〔隐去〕"
        let expectedContent = "Rotate 〔隐去〕 after deployment"
        let saved = try store.record(
            title: "Deploy \(secret)", content: "Rotate \(secret) after deployment",
            tags: [secret, "release"], source: .mainChat, secrets: secrets
        )
        XCTAssertEqual(saved.title, expectedTitle)
        XCTAssertEqual(saved.content, expectedContent)
        XCTAssertEqual(saved.tags, ["release"])
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("secret-token"))

        try seed([
            ExperienceRecord(id: "legacy", title: "Deploy \(secret)", content: "Rotate \(secret) after deployment", tags: [secret, "release"]),
            ExperienceRecord(id: "secret-only", title: "Deploy", content: secret),
        ], at: url)
        let loaded = try store.loadAll(secrets: secrets)
        XCTAssertEqual(loaded.map(\.id), ["legacy"])
        XCTAssertEqual(loaded.first?.title, expectedTitle)
        XCTAssertEqual(loaded.first?.content, expectedContent)
        XCTAssertEqual(loaded.first?.tags, ["release"])
        let hits = try store.search(query: "deployment", secrets: secrets)
        XCTAssertEqual(hits.map(\.id), ["legacy"])
        XCTAssertEqual(hits.first?.title, expectedTitle)
        XCTAssertEqual(hits.first?.content, expectedContent)
        XCTAssertEqual(hits.first?.tags, ["release"])
        XCTAssertTrue(try store.search(query: secret, secrets: secrets).isEmpty)
    }

    func testAllTombstoneIdentitiesAndExplicitRerecord() throws {
        let url = temporaryCanonicalURL()
        let store = ExperienceStore(canonicalFileURL: url)
        let secret = "legacy-private-token"
        let raw = ExperienceRecord(
            id: "legacy", title: "Deployment", content: "Rotate \(secret) after deployment",
            contentSHA256: MemorySafety.retractionHash("legacy stored identity")
        )
        let redactedBody = "Rotate 〔隐去〕 after deployment"
        let hashes = Set([
            raw.contentSHA256,
            MemorySafety.retractionHash("Deployment\n\(redactedBody)"),
            MemorySafety.retractionHash(redactedBody),
        ])
        XCTAssertEqual(hashes.count, 3)
        for hash in hashes {
            for useLocal in [false, true] {
                try seed([raw], at: url, hashes: useLocal ? [hash] : [])
                let external: Set<String> = useLocal ? [] : [hash.uppercased()]
                XCTAssertEqual(try store.loadAll(suppressedHashes: external, secrets: [secret]), [])
                XCTAssertEqual(try store.search(query: "deployment", suppressedHashes: external, secrets: [secret]), [])
                XCTAssertThrowsError(try store.record(
                    title: raw.title, content: raw.content, source: .mainChat,
                    secrets: [secret], suppressedHashes: external
                )) {
                    XCTAssertEqual($0 as? ExperienceStoreError, .suppressedByTombstone)
                }
            }
        }
        let unrelated = MemorySafety.retractionHash("Unrelated")
        for source in [ExperienceWriteSource.user, .importAction] {
            try seed([raw], at: url, hashes: hashes.union([unrelated]).sorted())
            let saved = try store.record(id: raw.id, title: raw.title, content: raw.content, source: source, secrets: [secret])
            XCTAssertEqual(saved.id, raw.id)
            XCTAssertEqual(try store.readBook().retractedHashes, [unrelated])
            XCTAssertEqual(try store.loadAll().map(\.id), [raw.id])
        }
    }

    func testLexicalRankingUsageBonusAndClamping() throws {
        let url = temporaryCanonicalURL()
        let store = ExperienceStore(canonicalFileURL: url)
        let title = "北海道滑雪 Hokkaido skiing"
        let content = "北海道滑雪攻略 Hokkaido skiing itinerary"
        let records = [
            ExperienceRecord(id: "a", title: title, content: content, createdAtMs: 10),
            ExperienceRecord(id: "b", title: title, content: content, createdAtMs: 10),
            ExperienceRecord(id: "recent", title: title, content: content, createdAtMs: 20),
            ExperienceRecord(id: "used", title: title, content: content, createdAtMs: 1, useCount: Int(Int32.max)),
            ExperienceRecord(id: "other", title: "Cooking", content: "Kitchen recipes", createdAtMs: 99),
        ]
        try seed(records, at: url)
        let data = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(data.contains(String(Int32.max)))
        try Data(data.replacingOccurrences(of: String(Int32.max), with: String(Int64.max)).utf8).write(to: url)
        XCTAssertEqual(try store.loadAll().map(\.id), ["other", "recent", "a", "b", "used"])
        for query in ["北海道滑雪", "Hokkaido skiing"] {
            let hits = try store.search(query: query)
            XCTAssertEqual(hits.map(\.id), ["used", "recent", "a", "b"])
            XCTAssertEqual(hits.first?.useCount, Int(Int32.max))
            XCTAssertEqual(try XCTUnwrap(hits.first?.score) - XCTUnwrap(hits.last?.score), 3, accuracy: 0.0001)
        }
        let marked = try XCTUnwrap(store.search(query: title, limit: 1, markUsedNowMs: 100).first)
        XCTAssertEqual(marked.useCount, Int(Int32.max))
        XCTAssertEqual(marked.usedAtMs, 100)
    }

    func testReadOnlySearchAndExplicitUsagePersistence() throws {
        let url = temporaryCanonicalURL()
        let store = ExperienceStore(canonicalFileURL: url)
        XCTAssertEqual(try store.search(query: "Swift"), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
        let saved = try store.record(title: "Swift", content: "Build and test", source: .user, nowMs: 10)
        let fm = FileManager.default
        let oldModifiedAt = Date(timeIntervalSince1970: 10_000)
        try fm.setAttributes([.modificationDate: oldModifiedAt], ofItemAtPath: url.path)
        let before = try Data(contentsOf: url)
        XCTAssertEqual(try store.search(query: "Swift").first?.useCount, 0)
        XCTAssertEqual(try store.search(query: "Unrelated", markUsedNowMs: 20), [])
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(try fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date, oldModifiedAt)
        let hit = try XCTUnwrap(store.search(query: "Swift", markUsedNowMs: 30).first)
        XCTAssertEqual(hit.id, saved.id)
        XCTAssertEqual(hit.useCount, 1)
        XCTAssertEqual(hit.usedAtMs, 30)
        XCTAssertEqual(hit.updatedAtMs, 30)
        let fromDisk = try XCTUnwrap(ExperienceStore(canonicalFileURL: url).loadAll().first)
        XCTAssertEqual(fromDisk.useCount, 1)
        XCTAssertEqual(fromDisk.usedAtMs, 30)
        XCTAssertEqual(fromDisk.updatedAtMs, 30)
    }

    func testCorruptAndEmptyCanonicalFilesFailClosed() throws {
        let url = temporaryCanonicalURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let store = ExperienceStore(canonicalFileURL: url)
        for payload in [Data(), Data("{invalid JSON".utf8)] {
            try payload.write(to: url)
            XCTAssertThrowsError(try store.loadAll())
            XCTAssertThrowsError(try store.search(query: "Swift"))
            XCTAssertThrowsError(try store.search(query: "Swift", markUsedNowMs: 10))
            XCTAssertThrowsError(try store.record(title: "Swift", content: "Build and test", source: .user))
            XCTAssertThrowsError(try store.delete(id: "missing"))
            XCTAssertThrowsError(try store.mergeRetractedHashesAndPrune(["hash"], nowMs: 10))
            XCTAssertEqual(try Data(contentsOf: url), payload)
        }
    }

    func testExistingReadOnlyCanonicalRejectsAtomicReplacement() throws {
        let url = temporaryCanonicalURL()
        let store = ExperienceStore(canonicalFileURL: url)
        let record = try store.record(title: "Swift", content: "Build and test", source: .user)
        let before = try Data(contentsOf: url)
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        XCTAssertEqual(try store.search(query: "Swift").map(\.id), [record.id])
        XCTAssertThrowsError(try store.delete(id: record.id)) {
            XCTAssertEqual($0 as? ExperienceStoreError, .canonicalReadOnly("experiences.json"))
        }
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testUpsertDeleteAndMergeInMemoryAndOnDisk() throws {
        let url = temporaryCanonicalURL()
        for store in [ExperienceStore.inMemory(), ExperienceStore(canonicalFileURL: url)] {
            let saved = try store.record(id: "deploy", title: "Deploy", content: "Run the tests", source: .user, nowMs: 10)
            XCTAssertEqual(try store.record(title: " deploy ", content: "RUN THE TESTS", source: .mainChat, nowMs: 20).id, saved.id)
            try store.delete(id: saved.id, nowMs: 30)
            let deleted = try store.readBook()
            XCTAssertEqual(deleted.records.count, 1)
            XCTAssertEqual(deleted.records.first?.deletedAtMs, 30)
            XCTAssertEqual(Set(deleted.retractedHashes), [
                saved.contentSHA256, MemorySafety.retractionHash(saved.content),
            ])
            XCTAssertTrue(try store.loadAll(includeDeleted: true).isEmpty)

            let other = try store.record(id: "release", title: "Release", content: "Upload artifacts", source: .user, nowMs: 40)
            XCTAssertEqual(try store.search(query: "Release", markUsedNowMs: 50).first?.useCount, 1)
            try store.mergeRetractedHashesAndPrune([MemorySafety.retractionHash(other.content)], nowMs: 60)
            let persisted = store.canonicalFileURL.map { ExperienceStore(canonicalFileURL: $0) } ?? store
            let book = try persisted.readBook()
            XCTAssertEqual(book.records.first { $0.id == other.id }?.deletedAtMs, 60)
            XCTAssertTrue(try persisted.search(query: "Release").isEmpty)
        }
    }

    private func temporaryCanonicalURL() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock {
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
        }
        return root.appendingPathComponent("Team/experiences.json")
    }

    private func seed(_ records: [ExperienceRecord], at url: URL, hashes: [String] = []) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(CanonicalExperienceBook(records: records, retractedHashes: hashes)).write(to: url)
    }
}
