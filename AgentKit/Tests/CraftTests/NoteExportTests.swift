import Craft
import Foundation
import XCTest

final class NoteExportTests: XCTestCase {
    func testWriteUniqueNewFileNeverOverwritesExistingBytesOrLimit() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("clio-note-test-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let firstBytes = Data("original-1".utf8)
        let secondBytes = Data("original-2".utf8)
        let thirdBytes = Data("original-3".utf8)

        let n1 = try NoteExport.writeUniqueNewFile(in: dir, fileName: "周报.md", data: firstBytes, maxAttempts: 3)
        let n2 = try NoteExport.writeUniqueNewFile(in: dir, fileName: "周报.md", data: secondBytes, maxAttempts: 3)
        let n3 = try NoteExport.writeUniqueNewFile(in: dir, fileName: "周报.md", data: thirdBytes, maxAttempts: 3)
        XCTAssertEqual([n1, n2, n3], ["周报.md", "周报 2.md", "周报 3.md"])

        // When all slots up to maxAttempts are taken, fail clearly and leave every existing file byte-identical.
        XCTAssertThrowsError(
            try NoteExport.writeUniqueNewFile(in: dir, fileName: "周报.md", data: Data("clobber".utf8), maxAttempts: 3)
        ) { error in
            XCTAssertEqual(error as? NoteExportError, .nameExhausted)
        }

        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("周报.md")), firstBytes)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("周报 2.md")), secondBytes)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("周报 3.md")), thirdBytes)
    }

    func testConcurrentWritesCreateDistinctFilesWithoutClobbering() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("clio-note-race-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let seed = Data("seed-do-not-overwrite".utf8)
        try seed.write(to: dir.appendingPathComponent("想法.md"))

        let results = try await withThrowingTaskGroup(of: (String, Data).self) { group in
            for idx in 0..<12 {
                let payload = Data("concurrent-note-\(idx)".utf8)
                group.addTask {
                    let name = try NoteExport.writeUniqueNewFile(in: dir, fileName: "想法.md", data: payload, maxAttempts: 50)
                    return (name, payload)
                }
            }
            var collected: [(String, Data)] = []
            for try await item in group { collected.append(item) }
            return collected
        }

        XCTAssertEqual(Set(results.map(\.0)).count, 12)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("想法.md")), seed)
        for (name, expected) in results {
            XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(name)), expected)
        }
    }

    func testYAMLFrontMatterEscapesSpecialCharactersAndUsesISO8601Date() {
        let fixed = Date(timeIntervalSince1970: 1_763_800_000)
        let md = NoteExport.markdown(
            body: "正文内容",
            question: "问题一\n问题二",
            sender: "群聊: #测试 \"小克\" \\ 换行\n第二行",
            date: fixed,
            timeZone: TimeZone(secondsFromGMT: 0)!,
            includeHeader: true
        )
        XCTAssertTrue(md.hasPrefix("---\ndate: 2025-11-22T08:26:40Z\n"))
        XCTAssertTrue(md.contains("from: \"群聊: #测试 \\\"小克\\\" \\\\ 换行\\n第二行\"\n---\n"))
        XCTAssertTrue(md.contains("> 问题一\n> 问题二\n\n正文内容\n"))
    }
}
