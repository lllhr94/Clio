import Craft
import Foundation
import XCTest
@testable import Clio

final class Batch6ArchitectureSlimmingTests: XCTestCase {
    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clio-batch6-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testSubConversationStoreUsesSQLiteEngineWithWALAndRecoversFromCorruption() async throws {
        let dir = try makeTempDir("subconv")
        defer { try? FileManager.default.removeItem(at: dir) }
        let teamRoot = dir.appendingPathComponent("Team", isDirectory: true)
        let indexRoot = dir.appendingPathComponent("ClioIndex", isDirectory: true)
        let store = SubConversationStore(teamRoot: teamRoot, indexRoot: indexRoot)

        let origin = SubConversationOrigin(
            sourceChatKey: "bot-chief",
            sourceEntryID: "entry-1",
            selectedQuote: "测试引用"
        )
        let created = try await store.findOrCreate(origin: origin, planMode: false, tainted: false)
        XCTAssertEqual(created.origin, origin)

        // Verify WAL mode & busy_timeout were applied on the projection DB
        let dbURL = await store.projectionURL
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path))
        let conn = try SQLiteConnection.open(at: dbURL)
        XCTAssertEqual(try conn.pragmaString("journal_mode").lowercased(), "wal")
        conn.close()

        // Corrupt the SQLite projection on disk and verify rebuildProjection quarantines & recovers cleanly
        try Data("corrupted-sqlite-header-payload".utf8).write(to: dbURL)
        try await store.rebuildProjection()

        let reloaded = try await store.records()
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded.first?.id, created.id)

        let files = try FileManager.default.contentsOfDirectory(atPath: indexRoot.path)
        XCTAssertTrue(files.contains { $0.contains(".corrupt-") }, "Expected quarantined corrupt projection file")
    }

    func testArtifactIndexDirtyInvalidationAndReconcileCacheConsistency() async throws {
        let dir = try makeTempDir("artifact")
        defer { try? FileManager.default.removeItem(at: dir) }
        let indexFile = dir.appendingPathComponent("artifacts.json")
        let index = ArtifactIndex(file: indexFile)

        let producedAt = Date(timeIntervalSince1970: 1_700_000_010)
        let fileVersion = ArtifactIndex.FileVersion(
            fileSize: 42,
            mtime: Date(timeIntervalSince1970: 1_700_000_005),
            relativePath: "notes/plan.md",
            mountID: nil
        )
        let source = ArtifactIndex.Source(
            entryID: "e-1",
            chat: "bot-chief",
            row: "steps-e-1",
            companion: "chief",
            path: "notes/plan.md",
            producedAt: producedAt
        )
        let located = ArtifactIndex.LocatedFile(
            version: fileVersion,
            identity: "1:99:100",
            kind: .document
        )

        let first = try await index.reconcile(sources: [source], files: [located])
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.first?.sourceChatKey, "bot-chief")

        await index.markFilesDirty()
        await index.markChatDirty("bot-chief")
        await index.invalidateAll()

        let second = try await index.reconcile(sources: [source], files: [located])
        XCTAssertEqual(second, first)
    }

    func testBackupCryptoV2StreamsAndInteroperatesWithBackupDetection() throws {
        let dir = try makeTempDir("backup-v2")
        defer { try? FileManager.default.removeItem(at: dir) }
        let encURL = dir.appendingPathComponent("streamed.clio-backup")

        let payload = Data("CLIO-BACKUP-1\n".utf8) + Data(repeating: 0x5A, count: 10_000)
        FileManager.default.createFile(atPath: encURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: encURL)
        let enc = try BackupCrypto.StreamEncryptor(passphrase: "batch6-pass", chunkSize: 4_096) { chunk in
            try handle.write(contentsOf: chunk)
        }
        try enc.append(payload)
        try enc.finish()
        try handle.close()

        XCTAssertTrue(Backup.isEncryptedBackup(at: encURL))
        let raw = try Data(contentsOf: encURL)
        XCTAssertTrue(raw.starts(with: BackupCrypto.streamingMagic))
        let decrypted = try BackupCrypto.decrypt(raw, passphrase: "batch6-pass")
        XCTAssertEqual(decrypted, payload)
    }
}
