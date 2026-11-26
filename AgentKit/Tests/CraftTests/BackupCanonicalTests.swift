@testable import Craft
import XCTest

final class BackupCanonicalTests: XCTestCase {
    func testExcludesDeviceLocalMountsTrashJournalsAndSQLiteArtifacts() {
        XCTAssertTrue(BackupArchivePolicy.isExcludedArchivePath("Team/mounts.json"))
        XCTAssertTrue(BackupArchivePolicy.isExcludedArchivePath("Team/trash-index.json"))
        XCTAssertTrue(BackupArchivePolicy.isExcludedArchivePath("Team/.trash/deleted.json"))
        XCTAssertTrue(BackupArchivePolicy.isExcludedArchivePath("Team/memory-revisions/commit.journal"))
        XCTAssertTrue(BackupArchivePolicy.isExcludedArchivePath("Team/memory-revisions/commit-prev.bak.journal"))
        XCTAssertTrue(BackupArchivePolicy.isExcludedArchivePath("Team/secrets.json"))
        XCTAssertTrue(BackupArchivePolicy.isExcludedArchivePath("ClioMemory/clio-memory.db"))
        XCTAssertTrue(BackupArchivePolicy.isExcludedArchivePath("Team/memory.db-wal"))
    }

    func testPreservesCanonicalMemoryExperiencesRetractedAndSnapshots() {
        XCTAssertFalse(BackupArchivePolicy.isExcludedArchivePath("Team/memory.json"))
        XCTAssertFalse(BackupArchivePolicy.isExcludedArchivePath("Team/memory-retracted.json"))
        XCTAssertFalse(BackupArchivePolicy.isExcludedArchivePath("Team/experiences.json"))
        XCTAssertFalse(BackupArchivePolicy.isExcludedArchivePath("Team/memory-revisions/rev-0001.json"))
    }
}
