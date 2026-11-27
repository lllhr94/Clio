import AgentKit
@testable import Clio
import Craft
import Synchronization
import UIKit
import XCTest

final class ClioAppPR3CTests: XCTestCase {
    func testLegacyBotDecodesWithOptionalPersonaFields() throws {
        let bytes = Data(#"{"id":"legacy","name":"青禾","avatar":"pet:builtin-xiaoke","instructions":"Use sources."}"#.utf8)
        let bot = try JSONDecoder().decode(BotInfo.self, from: bytes)
        XCTAssertEqual(bot.avatar, "pet:builtin-xiaoke")
        XCTAssertEqual(bot.instructions, "Use sources.")
        XCTAssertNil(bot.relationship)
        XCTAssertNil(bot.expressionStyle)
        XCTAssertNil(bot.antiSlop)
        XCTAssertNil(bot.firstPersonThoughts)
        XCTAssertNil(bot.expertiseBoundary)
        XCTAssertNil(bot.privateNotes)
        XCTAssertNil(bot.publicAgentsCard)
        var updated = bot
        updated.relationship = "Study partner"
        updated.expressionStyle = "Plain"
        updated.antiSlop = true
        updated.firstPersonThoughts = false
        updated.expertiseBoundary = "Source evaluation"
        updated.privateNotes = "Private"
        updated.publicAgentsCard = "Collaborate on citations"
        XCTAssertEqual(try JSONDecoder().decode(BotInfo.self, from: JSONEncoder().encode(updated)), updated)
    }

    @MainActor
    func testAvatarResolvesNameSealAndExplicitLegacyPetWithoutChangingDeskPet() async throws {
        let library = PetLibrary.shared
        for _ in 0..<100 where library.loading { try await Task.sleep(for: .milliseconds(20)) }
        let priorChoice = library.choice
        let priorVisibility = library.visible
        let priorPack = library.pack?.id
        XCTAssertEqual(CompanionAvatar.character(name: "青禾", seal: " "), "青")
        XCTAssertEqual(CompanionAvatar.character(name: "青禾", seal: "禾"), "禾")
        XCTAssertNil(CompanionAvatar.legacyPack(for: nil))
        XCTAssertNil(CompanionAvatar.legacyPack(for: "pet:missing"))
        let legacy = try XCTUnwrap(library.packs.first { $0.id == "builtin-roubao" })
        let face = "pet:\(legacy.id)"
        XCTAssertEqual(CompanionAvatar.legacyPack(for: face)?.id, legacy.id)
        XCTAssertNotNil(CompanionAvatar.legacyFrame(for: face))
        XCTAssertEqual(library.choice, priorChoice)
        XCTAssertEqual(library.visible, priorVisibility)
        XCTAssertEqual(library.pack?.id, priorPack)
    }

    @MainActor
    func testChannelPassIsGatheringOnlyAndFinishesWithoutAnotherProviderRequest() async throws {
        let bot = BotInfo(id: "bot", name: "青禾")
        let room = RoomInfo(id: "room", name: "Room", members: ["bot", "peer"])
        let state = ChannelPassState()
        XCTAssertNil(ChannelPassTool.forRoom(nil, helping: false, state: state))
        XCTAssertNil(ChannelPassTool.forRoom(room, helping: true, state: state))
        let tool = try XCTUnwrap(ChannelPassTool.forRoom(room, helping: false, state: state))
        XCTAssertEqual(tool.spec.name, "channel_pass")
        let team = TeamModel()
        team.phase = .demo
        let roomTools = team.tools(for: bot, key: TeamModel.key(room: room.id), canSee: false,
                                   workplace: .desk, channelPass: tool)
        let directTools = team.tools(for: bot, key: TeamModel.key(bot: bot.id), canSee: false,
                                     workplace: .desk)
        let helperTools = team.tools(for: bot, key: TeamModel.key(bot: bot.id), canSee: false,
                                     helping: true, workplace: .desk)
        let channel = try XCTUnwrap(roomTools.first { $0.spec.name == ChannelPassTool.name })
        XCTAssertFalse(directTools.contains { $0.spec.name == ChannelPassTool.name })
        XCTAssertFalse(helperTools.contains { $0.spec.name == ChannelPassTool.name })
        let presentation = CompanionTurnPresentation(bot: bot, channelPass: state)
        let recorder = EventRecorder()
        let provider = PassFixture()
        let agent = Agent(provider: ChannelPassProvider(base: provider, state: state),
                          model: "fixture", system: "", tools: [channel], approve: { _, _ in false })
        try await agent.run(history: [.user("Anything to add?")]) { event in
            let silent = await presentation.isSilent(event)
            if !silent { await recorder.add(event) }
        }
        XCTAssertTrue(state.passed)
        XCTAssertEqual(provider.calls, 1)
        let visible = await recorder.events
        XCTAssertTrue(visible.isEmpty, "\(visible)")
    }

    @MainActor
    func testInboxSuppressesTheSecondPulseAndKeepsProviderReasoningIntact() async {
        let team = TeamModel()
        team.phase = .demo
        let bot = BotInfo(id: "inbox", name: "青禾", firstPersonThoughts: true)
        let key = TeamModel.key(bot: bot.id)
        let presentation = CompanionTurnPresentation(bot: bot)
        var pulses: [String] = []
        let listener = team.listen(key) { event in
            if case .pulse(let text, _) = event { pulses.append(text) }
        }
        defer { team.unlisten(listener) }

        let first = "<pulse>First</pulse>"
        await team.hear(.text(first), chat: key, speaker: nil, presentation: presentation)
        await team.hear(.message(.assistant(first)), chat: key, speaker: nil, presentation: presentation)
        team.pendingInterjects[key] = [(UUID(), "Correction")]
        await team.hear(.message(.user("Correction")), chat: key, speaker: nil, presentation: presentation)

        let second = "<pulse>Second</pulse>Answer"
        let reasoning = "The user wants a summary."
        var reply = Message.assistant(second, reasoning: reasoning)
        reply.reasoningSignature = "signature"
        await team.hear(.text(second), chat: key, speaker: nil, presentation: presentation)
        await team.hear(.message(reply), chat: key, speaker: nil, presentation: presentation)

        XCTAssertEqual(pulses, ["First"])
        let last = team.history(key).last
        XCTAssertNil(last?.pulse)
        XCTAssertEqual(last?.message.text, "Answer")
        XCTAssertEqual(last?.message.reasoning, reasoning)
        XCTAssertEqual(last?.message.reasoningSignature, "signature")
        let display = ChatLiveStreamState()
        display.rawReasoning = reasoning
        display.firstPersonThoughts = last?.firstPersonThoughts == true
        XCTAssertEqual(display.reasoning, "I need to help with a summary.")
        XCTAssertEqual(display.rawReasoning, reasoning)
    }

    @MainActor
    func testNameCardExportStripsPrivateNotesAndResizesAlbumPhoto() throws {
        let id = UUID().uuidString
        defer { Avatars.forget(id) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 420)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 420))
        }
        Avatars.save(image, for: id)
        let bot = BotInfo(id: id, name: "青禾", avatar: "photo", privateNotes: "private",
                          publicAgentsCard: "public")
        let report = try NameCardV3Codec.decode(NameCard.data(for: bot))
        XCTAssertNil(report.privateNotes)
        XCTAssertEqual(report.publicAgentsCard, "public")
        let photo = try XCTUnwrap(report.photo)
        let exported = try XCTUnwrap(UIImage(data: photo)?.cgImage)
        XCTAssertLessThanOrEqual(max(exported.width, exported.height), NameCardV3Codec.maxAvatarPixels)
        XCTAssertLessThanOrEqual(photo.count, NameCardV3Codec.maxAvatarBytes)
        let optedIn = try NameCard.data(for: bot, includePrivateNotes: true)
        XCTAssertEqual(try NameCardV3Codec.decode(optedIn).privateNotes, "private")
    }

    private actor EventRecorder {
        var events: [AgentEvent] = []
        func add(_ event: AgentEvent) { events.append(event) }
    }

    private final class PassFixture: ModelProvider, Sendable {
        private let requests = Mutex(0)
        var calls: Int { requests.withLock { $0 } }

        func stream(_ request: ModelRequest) -> AsyncThrowingStream<StreamEvent, Error> {
            requests.withLock { $0 += 1 }
            return AsyncThrowingStream { continuation in
                continuation.yield(.toolCallStart(index: 0, id: "pass-1", name: "channel_pass"))
                continuation.yield(.toolCallArguments(index: 0, delta: #"{"step_title":"pass"}"#))
                continuation.yield(.finish(reason: "tool_calls"))
                continuation.finish()
            }
        }

        func models() async throws -> [String] { ["fixture"] }
    }
}
