@testable import Clio
import Craft
import Foundation
import SQLite3
import XCTest

final class ClioAppPR4BTests: XCTestCase {
    private let light = CardStyleKit.Theme(scheme: "light", palette: "dai", oled: false, white: false)

    func testCardStyleKitBudgetAndOptIn() {
        XCTAssertLessThan(CardStyleKit.totalAssetByteCount, 55_000)
        XCTAssertTrue(CardStyleKit.isOptedIn(#"<META data-x="a>b" CONTENT = '1' NAME="Clio-Card">"#))
        XCTAssertTrue(CardStyleKit.isOptedIn("<meta name=clio-card content=1>"))
        for html in [
            #"name="clio-card" content="1""#,
            #"<!-- <meta name="clio-card" content="1"> -->"#,
            #"&lt;meta name="clio-card" content="1"&gt;"#,
            #"<script>const fake = '<meta name="clio-card" content="1">';</script>"#,
            #"<div title='<meta name="clio-card" content="1">'></div>"#,
            #"<textarea><meta name=clio-card content=1></textarea>"#,
            #"<template><meta name=clio-card content=1></template>"#,
            #"<meta name=no name=clio-card content=1>"#,
            #"<meta name=clio-card><meta content=1>"#,
            #"<meta data-name=clio-card content=1>"#,
            #"<meta name=clio-card content=10>"#
        ] {
            XCTAssertFalse(CardStyleKit.isOptedIn(html), html)
        }
    }

    @MainActor
    func testPreparedPreviewPreservesPolicyAndLegacyBytes() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("preview.html")
        let document = InteractiveDocument(url: file, root: folder)
        let legacy = #"<!doctype html><p>原文 &amp; "引号"</p><!-- <meta name="clio-card" content="1"> -->"#
        try Data(legacy.utf8).write(to: file)
        func prepared(_ theme: CardStyleKit.Theme?) throws -> Data {
            let preview = try XCTUnwrap(PreparedPreview.make(document, theme: theme))
            return try Data(contentsOf: preview.file)
        }
        let baseline = try prepared(nil)
        let themedLegacy = try prepared(light)
        XCTAssertEqual(themedLegacy, baseline)

        try Data((legacy + "<meta name=clio-card content=1>").utf8).write(to: file)
        let html = try XCTUnwrap(String(data: prepared(light), encoding: .utf8))
        let outer = try XCTUnwrap(html.range(of: "frame-src 'self' about:"))
        let sandbox = try XCTUnwrap(html.range(of: #"sandbox="allow-scripts""#))
        let inner = try XCTUnwrap(html.range(of: "frame-src 'none'"))
        let kit = try XCTUnwrap(html.range(of: "--paper:"))
        XCTAssertLessThan(outer.lowerBound, sandbox.lowerBound)
        XCTAssertLessThan(sandbox.lowerBound, inner.lowerBound)
        XCTAssertLessThan(inner.lowerBound, kit.lowerBound)
        XCTAssertEqual(html.components(separatedBy: "connect-src 'none'").count, 3)
        XCTAssertEqual(html.components(separatedBy: "Content-Security-Policy").count, 3)
        XCTAssertFalse(html.contains("allow-same-origin"))
        let dark = CardStyleKit.Theme(scheme: "dark", palette: "dai", oled: true, white: false)
        let alternate = CardStyleKit.Theme(scheme: "light", palette: "zhu", oled: false, white: true)
        let keys = [light, dark, alternate].map { InteractiveThumbnails.cacheKey(revision: "same", theme: $0) }
        XCTAssertEqual(Set(keys).count, 3)
        XCTAssertTrue(keys.allSatisfy { $0.hasPrefix("\(CardStyleKit.kitVersion)|") })
    }

    func testArtifactIdentitySurvivesRenameAndPromotionButCannotBeReused() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let indexFile = folder.appendingPathComponent("artifacts.json")
        let index = ArtifactIndex(file: indexFile)
        let time = Date(timeIntervalSince1970: 100)
        func source(_ id: String, _ chat: String, _ path: String) -> ArtifactIndex.Source {
            .init(entryID: id, chat: chat, row: "row", companion: "bot", path: path, producedAt: time)
        }
        func file(_ path: String, _ identity: String, mount: String? = nil) -> ArtifactIndex.LocatedFile {
            .init(version: .init(fileSize: 10, mtime: time, relativePath: path, mountID: mount), identity: identity, kind: .card)
        }
        let old = source("entry", "bot-a~archive", "a.html")
        let mount = source("mounted", "bot-a", "挂载/X/card.html")
        let found = try await index.reconcile(sources: [old, mount], files: [file("a.html", "1"), file(mount.path, "2", mount: "mount")])
        XCTAssertEqual(Set(found.map(\.entryID)), ["entry", "mounted"])

        let restarted = ArtifactIndex(file: indexFile)
        let promoted = source("entry", "room-a", "a.html")
        let renamed = try await restarted.reconcile(sources: [promoted, mount], files: [file("b.html", "1")])
        XCTAssertEqual(renamed.map(\.entryID), ["entry"])
        XCTAssertEqual(renamed.first?.sourceChatKey, "room-a")
        XCTAssertEqual(renamed.first?.version.relativePath, "b.html")

        let replacement = try await restarted.reconcile(sources: [promoted, mount],
            files: [file("a.html", "different"), file(mount.path, "2", mount: "new-mount")])
        XCTAssertTrue(replacement.isEmpty)
        let deletedChat = try await restarted.reconcile(sources: [], files: [file("b.html", "1")])
        XCTAssertTrue(deletedChat.isEmpty)
    }

    func testSubConversationPersistenceProjectionAndPromotion() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let team = folder.appendingPathComponent("Team")
        let index = folder.appendingPathComponent("ClioIndex")
        let store = SubConversationStore(teamRoot: team, indexRoot: index)
        let origin = SubConversationOrigin(sourceChatKey: "bot-a", sourceEntryID: "entry", selectedQuote: "原文")
        let record = SubConversationRecord(origin: origin, inheritedPlanMode: true, inheritedTaint: false)
        try await store.save(record)
        let updated = try await store.update(record.id) {
            $0.append(.init(question: "追问", reply: "答复"), tainted: true)
        }
        let projection = index.appendingPathComponent("clio-subconv.db")
        XCTAssertTrue(FileManager.default.fileExists(atPath: projection.path))
        try FileManager.default.removeItem(at: projection)
        let reopened = SubConversationStore(teamRoot: team, indexRoot: index)
        let decoded = try await reopened.load(record.id)
        XCTAssertEqual(decoded, updated)
        try await reopened.rebuildProjection()
        let promoted = try await reopened.promote(record.id, summary: "答复")
        let again = try await reopened.promote(record.id, summary: "答复")
        XCTAssertEqual(promoted.chatKey, again.chatKey)
        XCTAssertEqual(promoted.transfer, again.transfer)
        XCTAssertEqual(promoted.transfer.origin, origin)
        XCTAssertTrue(promoted.transfer.inheritedPlanMode)
        XCTAssertTrue(promoted.transfer.tainted)
        let canonical = try Data(contentsOf: team.appendingPathComponent("subconversations/\(record.id.uuidString).json"))
        XCTAssertEqual(try JSONDecoder().decode(SubConversationRecord.self, from: canonical).promotedChatKey, promoted.chatKey)

        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_open_v2(projection.path, &database, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_prepare_v2(database, "SELECT plan, tainted, promoted_chat FROM sub_conversations", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 1)
        XCTAssertEqual(sqlite3_column_int(statement, 1), 1)
        XCTAssertNotNil(sqlite3_column_text(statement, 2))
    }

    @MainActor
    func testParticleGate() {
        XCTAssertTrue(PetPerch.allowsPettingParticles(reduceMotion: false, reduceVisualEffects: false, lowPower: false, thermal: .fair))
        XCTAssertFalse(PetPerch.allowsPettingParticles(reduceMotion: false, reduceVisualEffects: false, lowPower: false, thermal: .serious))
        XCTAssertFalse(PetPerch.allowsPettingParticles(reduceMotion: false, reduceVisualEffects: false, lowPower: true, thermal: .nominal))
        XCTAssertFalse(PetPerch.allowsPettingParticles(reduceMotion: true, reduceVisualEffects: false, lowPower: false, thermal: .nominal))
        XCTAssertFalse(PetPerch.allowsPettingParticles(reduceMotion: false, reduceVisualEffects: true, lowPower: false, thermal: .nominal))
    }

    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
