import AgentKit
@testable import Clio
import Craft
import Foundation
import XCTest

final class ClioAppPR1BTrashTests: XCTestCase {
    private struct Fixture {
        let folder: URL
        let root: URL
        let index: URL
        let trash: DeskTrash

        init() throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("clio-trash-\(UUID().uuidString)")
            root = folder.appendingPathComponent("desk")
            index = folder.appendingPathComponent(DeskTrash.indexName)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            trash = DeskTrash(deskRoot: root, indexURL: index)
        }

        func payload(_ record: DeskTrash.Record) -> URL {
            root.appendingPathComponent(DeskTrash.directoryName).appendingPathComponent(record.id.uuidString)
        }

        func remove() {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    func testMovePersistCollisionAndRestore() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let file = fixture.root.appendingPathComponent("笔记.md")
        let original = Data("原文件".utf8)
        let replacement = Data("新文件".utf8)
        try original.write(to: file)

        let record = try fixture.trash.move(deskItem: file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try Data(contentsOf: fixture.payload(record)), original)

        let reloaded = DeskTrash(deskRoot: fixture.root, indexURL: fixture.index)
        XCTAssertEqual(try reloaded.entries().map(\.id), [record.id])
        try replacement.write(to: file)
        XCTAssertThrowsError(try reloaded.restore(id: record.id)) {
            XCTAssertEqual($0 as? DeskTrash.Failure, .collision)
        }
        XCTAssertEqual(try Data(contentsOf: file), replacement)
        XCTAssertEqual(try Data(contentsOf: fixture.payload(record)), original)

        try FileManager.default.removeItem(at: file)
        try reloaded.restore(id: record.id)
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertTrue(try reloaded.entries().isEmpty)
    }

    func testRestoreRejectsChangedRootOrPayload() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let manager = FileManager.default
        let file = fixture.root.appendingPathComponent("note.md")
        try Data("original".utf8).write(to: file)
        let record = try fixture.trash.move(deskItem: file)

        let oldRoot = fixture.folder.appendingPathComponent("old-desk")
        try manager.moveItem(at: fixture.root, to: oldRoot)
        try manager.createDirectory(at: fixture.root, withIntermediateDirectories: false)
        XCTAssertThrowsError(try fixture.trash.restore(id: record.id)) {
            XCTAssertEqual($0 as? DeskTrash.Failure, .rootChanged)
        }
        try manager.removeItem(at: fixture.root)
        try manager.moveItem(at: oldRoot, to: fixture.root)

        let payload = fixture.payload(record)
        let moved = fixture.folder.appendingPathComponent("original")
        try manager.moveItem(at: payload, to: moved)
        try Data("replacement".utf8).write(to: payload)
        XCTAssertThrowsError(try fixture.trash.restore(id: record.id)) {
            XCTAssertEqual($0 as? DeskTrash.Failure, .itemChanged)
        }
        XCTAssertThrowsError(try fixture.trash.empty()) {
            XCTAssertEqual($0 as? DeskTrash.Failure, .itemChanged)
        }
        XCTAssertTrue(manager.fileExists(atPath: payload.path))
        XCTAssertTrue(manager.fileExists(atPath: moved.path))
        XCTAssertFalse(manager.fileExists(atPath: file.path))
    }

    func testUnreadableIndexLeavesSourceUntouched() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let file = fixture.root.appendingPathComponent("note.md")
        let original = Data("original".utf8)
        let corruptIndex = Data("{".utf8)
        try original.write(to: file)
        try corruptIndex.write(to: fixture.index)

        XCTAssertThrowsError(try fixture.trash.move(deskItem: file)) {
            XCTAssertEqual($0 as? DeskTrash.Failure, .unavailable)
        }
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(try Data(contentsOf: fixture.index), corruptIndex)
    }

    func testExpiryAndEmptyPreserveOfflineMountRecords() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 50_000_000)
        let folder = fixture.root.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("body".utf8).write(to: folder.appendingPathComponent("note.md"))
        let expired = try fixture.trash.move(deskItem: folder, now: now.addingTimeInterval(-DeskTrash.retention))
        let offline = MountedFolder(id: UUID().uuidString, name: "Offline", bookmark: Data(), addedAt: 0)
        let mountFile = fixture.root.appendingPathComponent("mount.md")
        try Data("body".utf8).write(to: mountFile)
        let pending = try fixture.trash.move(root: fixture.root, mount: offline, relativePath: "mount.md", now: now)

        XCTAssertEqual(try fixture.trash.entries(now: now).map(\.id), [pending.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.payload(expired).path))
        XCTAssertThrowsError(try fixture.trash.restore(id: pending.id, now: now)) {
            XCTAssertEqual($0 as? DeskTrash.Failure, .offline)
        }
        XCTAssertThrowsError(try fixture.trash.empty()) {
            XCTAssertEqual($0 as? DeskTrash.Failure, .offline)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.payload(pending).path))
        XCTAssertEqual(try fixture.trash.entries(now: now).map(\.id), [pending.id])
    }

    func testTrashNamespaceAndSymlinkParentAreRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let manager = FileManager.default
        let originalParent = fixture.root.appendingPathComponent("notes")
        try manager.createDirectory(at: originalParent, withIntermediateDirectories: false)
        let file = originalParent.appendingPathComponent("note.md")
        try Data("original".utf8).write(to: file)
        let record = try fixture.trash.move(deskItem: file)
        try manager.removeItem(at: originalParent)
        XCTAssertThrowsError(try fixture.trash.restore(id: record.id)) {
            XCTAssertEqual($0 as? DeskTrash.Failure, .destinationMissing)
        }

        try manager.createSymbolicLink(at: originalParent, withDestinationURL: fixture.folder)
        XCTAssertThrowsError(try fixture.trash.restore(id: record.id)) {
            XCTAssertEqual($0 as? DeskTrash.Failure, .badPath)
        }
        XCTAssertTrue(manager.fileExists(atPath: fixture.payload(record).path))
        let alias = fixture.root.appendingPathComponent("alias")
        try manager.createSymbolicLink(at: alias, withDestinationURL: fixture.payload(record))
        XCTAssertFalse(Workspace.isInsideRealRoot(alias, root: fixture.root))
        XCTAssertThrowsError(try fixture.trash.move(deskItem: fixture.payload(record))) {
            XCTAssertEqual($0 as? DeskTrash.Failure, .badPath)
        }
    }

    func testBackupStagingRemovesTrashArtifactsRecursively() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let manager = FileManager.default
        let folder = fixture.root.appendingPathComponent("subfolder")
        let trash = folder.appendingPathComponent(".trash")
        try manager.createDirectory(at: trash, withIntermediateDirectories: true)
        try Data("trashed".utf8).write(to: trash.appendingPathComponent("payload"))
        let index = folder.appendingPathComponent(DeskTrash.indexName)
        try Data("[]".utf8).write(to: index)
        let kept = folder.appendingPathComponent("kept.md")
        try Data("kept".utf8).write(to: kept)

        try Backup.stripStagedTrashArtifacts(in: fixture.root)
        XCTAssertFalse(manager.fileExists(atPath: trash.path))
        XCTAssertFalse(manager.fileExists(atPath: index.path))
        XCTAssertTrue(manager.fileExists(atPath: kept.path))
    }
}

final class ClioAppPR1BModelTests: XCTestCase {
    private struct ImageProbe: ModelProvider {
        func models() async throws -> [String] { [] }

        func stream(_ request: ModelRequest) -> AsyncThrowingStream<StreamEvent, Error> {
            let counts = request.messages.map { String($0.images.count) }.joined(separator: ",")
            return AsyncThrowingStream { continuation in
                continuation.yield(.text(counts))
                continuation.finish()
            }
        }
    }

    @MainActor
    func testActualRequestRechecksCategoryConsentOnEachSend() async throws {
        let team = TeamModel()
        team.phase = .demo
        let endpoint = Endpoint(id: "e", name: "Vision", kind: .openai,
                                baseURL: "https://example.test/v1", models: ["gpt-4o"])
        team.settings.endpoints = [endpoint]
        let identity = try XCTUnwrap(endpoint.recipientIdentity)
        let provider = team.outboundProvider(ImageProbe(), endpoint: endpoint, model: "gpt-4o", chat: "pr1b-images")
        let bytes = [ImagePart(data: Data([1]))]
        var tool = Message(role: .tool, text: "old screenshot", images: bytes, toolName: "view_image")
        tool.mediaSourceTool = "mcp_image_capture"
        let request = ModelRequest(model: "gpt-4o", system: "",
                                   messages: [.user("image attached", images: bytes), tool])
        func readCounts() async throws -> [StreamEvent] {
            var output: [StreamEvent] = []
            for try await event in provider.stream(request) { output.append(event) }
            return output
        }

        let denied = try await readCounts()
        XCTAssertEqual(denied, [.text("0,0")])
        team.setOutboundConsent(true, for: identity, category: .userImage)
        team.setOutboundConsent(true, for: identity, category: .toolScreenshot)
        let localConsent = try await readCounts()
        XCTAssertEqual(localConsent, [.text("1,0")])
        team.setOutboundConsent(true, for: identity, category: .mcpImage)
        let mcpConsent = try await readCounts()
        XCTAssertEqual(mcpConsent, [.text("1,1")])
        team.setOutboundConsent(false, for: identity, category: .userImage)
        let revoked = try await readCounts()
        XCTAssertEqual(revoked, [.text("0,1")])
    }

    @MainActor
    func testMemoryWriteGuardRechecksAfterExtractionAndLeavesWatermarkUntouched() async {
        let previous = Grant.memory.policy
        let frozen = Disk.frozen
        Grant.memory.policy = .allow
        Disk.frozen = false
        defer {
            Grant.memory.policy = previous
            Disk.frozen = frozen
        }
        let team = TeamModel()
        team.phase = .ready
        let bot = BotInfo(id: UUID().uuidString, name: "测试旅伴")
        let key = TeamModel.key(bot: bot.id)
        let source = [
            Entry(id: "u0", at: Now.ms, message: .user("我工作日早上八点喝茶。")),
            Entry(id: "a0", at: Now.ms, message: .assistant("记下了你的日常习惯。"))
        ]
        team.entries[key] = source + [Entry(id: "keep", at: Now.ms, message: .user("继续"))]
        let extract: @MainActor @Sendable (String, String) async throws -> String = { [weak team] _, _ in
            team?.memoryWriteGuard.modeAllowsWrite = { _ in false }
            return #"[{"text":"工作日早上八点喝茶。"}]"#
        }
        team.memoryWriteGuard.modeAllowsWrite = { _ in false }
        await team.flushMemoriesBeforeCompress(key: key, historyUpToCut: source, eligibleIDs: ["u0", "a0"],
                                               bot: bot, startEpoch: 0, firstKeptID: "keep") { _, _ in
            XCTFail("The guard must prevent starting extraction.")
            return "[]"
        }
        team.memoryWriteGuard.modeAllowsWrite = { $0 == key }
        await team.flushMemoriesBeforeCompress(key: key, historyUpToCut: source, eligibleIDs: ["u0", "a0"],
                                               bot: bot, startEpoch: 0, firstKeptID: "keep", extract: extract)
        XCTAssertFalse(team.canWriteMemories(beforeCompressing: key))
        XCTAssertTrue(team.memories.isEmpty)
        XCTAssertTrue(team.memoryBook.processed.isEmpty)
        XCTAssertNil(team.memoryBook.reviewFromDay)
    }

    @MainActor
    func testVisionRecipientConsentInvalidatesOnRouteOriginAndProtocolEdits() throws {
        let team = TeamModel()
        team.phase = .demo
        let endpoint = Endpoint(id: "e", name: "Vision", kind: .openai,
                                baseURL: "https://example.test/v1", models: ["gpt-4o"])
        team.settings.endpoints = [endpoint]
        XCTAssertNil(team.settings.visionModel)
        team.setVisionModel("e/gpt-4o")
        let original = try XCTUnwrap(team.visionModelSelection?.endpoint.recipientIdentity)
        XCTAssertFalse(team.settings.allowsOutbound(original, .userImage))
        team.setOutboundConsent(true, for: original, category: .userImage)
        let encoded = try JSONEncoder().encode(team.settings)
        let decoded = try JSONDecoder().decode(TeamSettings.self, from: encoded)
        XCTAssertTrue(decoded.allowsOutbound(original, .userImage))
        XCTAssertFalse(decoded.allowsOutbound(original, .toolScreenshot))

        team.settings.endpoints[0].baseURL = "https://example.test/other"
        let moved = try XCTUnwrap(team.visionModelSelection?.endpoint.recipientIdentity)
        XCTAssertEqual(moved.identityRevision, original.identityRevision + 1)
        XCTAssertEqual(moved.route, "/other/chat/completions")
        XCTAssertFalse(team.settings.allowsOutbound(original, .userImage))
        XCTAssertFalse(team.settings.allowsOutbound(moved, .userImage))
        team.setOutboundConsent(true, for: moved, category: .toolScreenshot)
        team.settings.endpoints[0].baseURL = "https://other.test/other"
        let hosted = try XCTUnwrap(team.visionModelSelection?.endpoint.recipientIdentity)
        XCTAssertEqual(hosted.canonicalOrigin, "https://other.test:443")
        XCTAssertFalse(team.settings.allowsOutbound(hosted, .toolScreenshot))
        team.setOutboundConsent(true, for: hosted, category: .mcpImage)
        team.settings.endpoints[0].kind = .anthropic
        let protocolChange = try XCTUnwrap(team.visionModelSelection?.endpoint.recipientIdentity)
        XCTAssertEqual(protocolChange.identityRevision, hosted.identityRevision + 1)
        XCTAssertEqual(protocolChange.route, "/other/v1/messages")
        XCTAssertFalse(team.settings.allowsOutbound(protocolChange, .mcpImage))
    }

    func testEstimateCacheReusesEntriesAndInvalidatesProjection() async {
        let cache = ContextEstimateCache()
        let recipient = RecipientIdentity(endpointID: "e", canonicalOrigin: "https://example.test:443",
                                          protocolKind: "openai", route: "/v1/chat/completions", identityRevision: 0)
        let image = ImagePart(data: Data([1]))
        var projection = ContextEstimateCache.Projection(
            messages: [.user("hello", images: [image]), .assistant("welcome")], entryIDs: ["u", "a"],
            mediaFiles: [:], permittedImageCategories: [.userImage], describedImageCategories: [],
            recipient: recipient, visionRecipient: nil, visionModel: nil, consentGeneration: 0,
            echoes: false, toolsEnabled: true, tools: [], prompt: "greeting",
            base: TeamModel.ContextEstimate()
        )
        let initial = await cache.estimate(projection, chat: "chat")
        let reused = await cache.estimate(projection, chat: "chat")
        let initialRequestHits = await cache.requestHits
        let initialEntryHits = await cache.entryHits
        XCTAssertEqual(reused, initial)
        XCTAssertEqual(initialRequestHits, 1)
        XCTAssertEqual(initialEntryHits, 2)

        projection.messages[1].text = String(repeating: "welcome ", count: 30)
        let edited = await cache.estimate(projection, chat: "chat")
        let editedEntryHits = await cache.entryHits
        XCTAssertGreaterThan(edited.messages, initial.messages)
        XCTAssertEqual(editedEntryHits, 3)

        projection.permittedImageCategories = []
        projection.consentGeneration = 1
        let noImage = await cache.estimate(projection, chat: "chat")
        XCTAssertLessThan(noImage.messages, edited.messages)
        projection.toolsEnabled = false
        _ = await cache.estimate(projection, chat: "chat")
        projection.entryIDs.removeFirst()
        projection.messages.removeFirst()
        _ = await cache.estimate(projection, chat: "chat")
        projection.recipient = RecipientIdentity(endpointID: "e", canonicalOrigin: "https://example.test:443",
                                                 protocolKind: "anthropic", route: "/v1/messages", identityRevision: 1)
        _ = await cache.estimate(projection, chat: "chat")
        let finalRequestHits = await cache.requestHits
        XCTAssertEqual(finalRequestHits, 1)
    }

    @MainActor
    func testContextEstimateUsesEditedTranscriptAndCurrentConsent() async throws {
        let team = TeamModel()
        team.phase = .demo
        let endpoint = Endpoint(id: "estimate", name: "Estimate", kind: .openai,
                                baseURL: "https://example.test/v1", models: ["gpt-4o"])
        team.settings.endpoints = [endpoint]
        team.settings.defaultModel = "estimate/gpt-4o"
        let bot = BotInfo(id: "pr1b-estimate", name: "测试", role: nil, instructions: nil, model: nil)
        team.bots = [bot]
        let key = TeamModel.key(bot: bot.id)
        let message = Message.user("look", images: [ImagePart(data: Data([1]))])
        team.entries[key] = [Entry(id: "u", at: 1, message: message)]

        let withheld = await team.contextEstimate(key)
        let recipient = try XCTUnwrap(endpoint.recipientIdentity)
        team.setOutboundConsent(true, for: recipient, category: .userImage)
        let visible = await team.contextEstimate(key)
        XCTAssertGreaterThan(visible.messages, withheld.messages)

        team.entries[key]?[0].message.text = String(repeating: "look closely ", count: 50)
        let edited = await team.contextEstimate(key)
        XCTAssertGreaterThan(edited.messages, visible.messages)
    }

    @MainActor
    func testTeamCompactionCanUndoWithoutChangingToolIdentityOrTaint() {
        let team = TeamModel()
        team.phase = .demo
        let key = "pr1b-compaction"
        let call = ToolCall(id: "r", name: "web_read", arguments: "{}")
        let original = [
            Entry(id: "u0", at: 1, message: .user("first")),
            Entry(id: "a0", at: 2, message: .assistant("", toolCalls: [call])),
            Entry(id: "t0", at: 3, message: .toolResult(String(repeating: "a", count: 3_000), for: call), tainted: true),
            Entry(id: "u1", at: 4, message: .user("next")),
            Entry(id: "u2", at: 5, message: .user("latest"))
        ]
        team.entries[key] = original
        let compacted = team.compactOldToolOutputs(key)
        XCTAssertEqual(compacted, 1)
        XCTAssertEqual(team.history(key)[2].message.toolCallId, call.id)
        XCTAssertEqual(team.history(key)[2].tainted, true)
        XCTAssertLessThan(team.history(key)[2].message.text.count, original[2].message.text.count)
        let undone = team.undoToolOutputCompaction(key)
        XCTAssertTrue(undone)
        XCTAssertEqual(team.history(key), original)
    }
}

final class ClioAppMediaLoadTests: XCTestCase {
    private let oldReference = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA.jpg"
    private let recentReference = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB.jpg"

    @MainActor
    func testToolImagesAreRebuiltInToolRoleAndRetireAfterTheNextUserTurn() throws {
        let team = TeamModel()
        team.phase = .demo
        let key = "bot-media-tests"
        let bot = BotInfo(id: "media-tests", name: "小测", role: nil, instructions: nil, model: nil)
        let firstCall = ToolCall(id: "first", name: "browser_screenshot", arguments: "{}")
        let recentCall = ToolCall(id: "recent", name: "view_image", arguments: "{}")
        let noteCall = ToolCall(id: "note", name: "image_note", arguments: "{}")
        team.entries[key] = [
            Entry(id: "u1", at: 1, message: .user("第一轮")),
            Entry(id: "a1", at: 2, message: .assistant("", toolCalls: [firstCall, noteCall])),
            Entry(id: "t1", at: 3, message: .toolResult("第一张截图", for: firstCall), photos: [oldReference]),
            Entry(id: "n1", at: 4, message: .toolResult(MediaLoadRetire.noteMarker(oldReference) + "蓝色按钮", for: noteCall)),
            Entry(id: "u2", at: 5, message: .user("第二轮")),
            Entry(id: "a2", at: 6, message: .assistant("", toolCalls: [recentCall])),
            Entry(id: "t2", at: 7, message: .toolResult("第二张截图", for: recentCall), photos: [recentReference]),
            Entry(id: "u3", at: 8, message: .user("第三轮")),
        ]

        let bytes = Data([0xFF, 0xD8, 0xFF])
        let context = team.context(for: key, bot: bot, room: nil, vision: true)
        let resolved = context.resolvedMessages { name in name == self.recentReference ? bytes : nil }
        let old = try XCTUnwrap(resolved.first(where: { $0.toolCallId == "first" }))
        let recent = try XCTUnwrap(resolved.first(where: { $0.toolCallId == "recent" }))
        XCTAssertEqual(old.role, .tool)
        XCTAssertTrue(old.images.isEmpty)
        XCTAssertTrue(old.text.contains("[image_ref: \(oldReference) | note: 蓝色按钮]"))
        XCTAssertEqual(recent.role, .tool)
        XCTAssertEqual(recent.images, [ImagePart(data: bytes)])
        XCTAssertEqual(context.messages.count, context.entryIDs.count)

        let unavailable = context.resolvedMessages { _ in nil }
        XCTAssertTrue(unavailable.first(where: { $0.toolCallId == "recent" })?.text.contains("截图已过期") == true)

        // A fold hides the original text, while the approved active conversation still retains the image reference.
        team.entries[key]?.insert(Entry(id: "fold", at: 4.5, message: .assistant("摘要"), note: true, fold: true), at: 4)
        let folded = team.context(for: key, bot: bot, room: nil, vision: true)
        XCTAssertFalse(folded.messages.contains { $0.toolCallId == "first" })
        XCTAssertTrue(folded.messages.last?.text.contains("[image_ref: \(oldReference) | note: 蓝色按钮]") == true)
    }

    func testImageNoteChecksOwnershipAndRejectsNonReferenceArguments() async throws {
        let reference = oldReference
        let tool = ConversationImageTools.note { $0 == reference }
        let fields: JSONValue = ["ref": .string(reference), "note": "可见一盏灯"]
        let accepted = try await tool.run(fields)
        XCTAssertFalse(accepted.isError)
        XCTAssertEqual(accepted.text, MediaLoadRetire.noteMarker(reference) + "可见一盏灯")

        let foreign = try await tool.run(["ref": .string(recentReference), "note": "不能写"])
        XCTAssertTrue(foreign.isError)
        let traversal = try await tool.run(["ref": .string("../\(reference)"), "note": "不能写"])
        XCTAssertTrue(traversal.isError)
        let withPath = try await tool.run(["ref": .string(reference), "note": "不能写", "path": "a.png"])
        XCTAssertTrue(withPath.isError)
        let long = try await tool.run(["ref": .string(reference), "note": .string(String(repeating: "字", count: 501))])
        XCTAssertTrue(long.isError)
    }
}
