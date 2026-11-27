import Foundation
import XCTest
@testable import AgentKit

final class WholeTurnRetryArbiterTests: XCTestCase {
    private final class Script: ModelProvider, @unchecked Sendable {
        let steps: [([StreamEvent], ProviderError?)]
        private(set) var requests: [ModelRequest] = []

        init(_ steps: [([StreamEvent], ProviderError?)]) { self.steps = steps }

        func stream(_ request: ModelRequest) -> AsyncThrowingStream<StreamEvent, Error> {
            let index = requests.count
            requests.append(request)
            return AsyncThrowingStream { continuation in
                guard index < steps.count else {
                    continuation.finish(throwing: ProviderError("unscripted request"))
                    return
                }
                let (events, error) = steps[index]
                for event in events { continuation.yield(event) }
                continuation.finish(throwing: error)
            }
        }

        func models() async throws -> [String] { [] }
    }

    private actor Writes {
        var count = 0
        func add() { count += 1 }
    }

    private struct WriteTool: AgentTool {
        let writes: Writes
        var spec: ToolSpec { ToolSpec(name: "write", description: "", parameters: [:]) }
        func label(for arguments: JSONValue) -> String { "write" }
        func run(_ arguments: JSONValue) async throws -> ToolOutput {
            await writes.add()
            return ToolOutput("saved")
        }
    }

    func testContextRetryKeepsSignedToolContinuationAndDoesNotReexecuteWrites() async throws {
        let writes = Writes()
        let contextError = ProviderError(status: 400, "context_length_exceeded")
        let provider = Script([
            ([.reasoning("thought"), .reasoningSignature("signature"),
              .toolCallStart(index: 0, id: "a", name: "write"), .toolCallArguments(index: 0, delta: "{}"),
              .finish(reason: "tool_calls")], nil),
            ([], contextError),
            ([.text("done"), .finish(reason: "stop")], nil)
        ])
        let arbiter = WholeTurnRetryArbiter()
        let agent = Agent(provider: provider, model: "test", system: "", tools: [WriteTool(writes: writes)])
        try await agent.run(
            history: [.user("old"), .assistant("old answer"), .user("current")], retryArbiter: arbiter
        ) { _ in }

        let count = await writes.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(provider.requests.count, 3)
        let retried = try XCTUnwrap(provider.requests.dropFirst(2).first)
        let rejected = try XCTUnwrap(provider.requests.dropFirst().first)
        XCTAssertEqual(retried.messages, Array(rejected.messages.dropFirst(2)))
        XCTAssertEqual(retried.messages.dropFirst().first?.reasoningSignature, "signature")
        XCTAssertEqual(retried.messages.last?.text, "saved")
        XCTAssertFalse(arbiter.allowsBackup(after: contextError))
    }

    func testPartialReasoningOrSignatureBlocksRetryAndBackup() async {
        let failure = ProviderError(status: 503, "busy")
        for event in [StreamEvent.reasoning("thinking"), .reasoningSignature("partial signature")] {
            let provider = Script([([event], failure)])
            let arbiter = WholeTurnRetryArbiter()
            var agent = Agent(provider: provider, model: "test", system: "")
            agent.retryDelays = [0]
            do {
                try await agent.run(history: [.user("current")], retryArbiter: arbiter) { _ in }
                XCTFail("expected failure")
            } catch {
                XCTAssertEqual(error as? ProviderError, failure)
            }
            XCTAssertEqual(provider.requests.count, 1)
            XCTAssertFalse(arbiter.allowsBackup(after: failure))
        }
    }

    func testOutputFromPreviousModelRequestBlocksTransientRetryAndThinkingFallback() async {
        struct ReadTool: AgentTool {
            var spec: ToolSpec { ToolSpec(name: "read", description: "", parameters: [:]) }
            var isReadOnlySafe: Bool { true }
            func label(for arguments: JSONValue) -> String { "read" }
            func run(_ arguments: JSONValue) async throws -> ToolOutput { ToolOutput("read result") }
        }
        for failure in [ProviderError(status: 503, "busy"), ProviderError(status: 400, "unsupported thinking")] {
            let provider = Script([
                ([.text("starting"), .reasoning("work"), .reasoningSignature("signed"),
                  .toolCallStart(index: 0, id: "a", name: "read"), .toolCallArguments(index: 0, delta: "{}"),
                  .finish(reason: "tool_calls")], nil),
                ([], failure)
            ])
            let arbiter = WholeTurnRetryArbiter()
            var agent = Agent(provider: provider, model: "test", system: "", tools: [ReadTool()])
            agent.retryDelays = [0]
            agent.thinking = .high
            do {
                try await agent.run(history: [.user("current")], retryArbiter: arbiter) { _ in }
                XCTFail("expected failure")
            } catch {
                XCTAssertEqual(error as? ProviderError, failure)
            }
            XCTAssertEqual(provider.requests.map(\.thinking), [.high, .high])
            XCTAssertFalse(arbiter.allowsBackup(after: failure))
        }
    }

    func testExplicitOffDoesNotRetryAsAuto() async {
        let failure = ProviderError(status: 422, "unsupported thinking")
        let provider = Script([([], failure)])
        let arbiter = WholeTurnRetryArbiter()
        var agent = Agent(provider: provider, model: "test", system: "")
        agent.thinking = .off
        do {
            try await agent.run(history: [.user("current")], retryArbiter: arbiter) { _ in }
            XCTFail("expected rejection")
        } catch {
            XCTAssertEqual(error as? ProviderError, failure)
        }
        XCTAssertEqual(provider.requests.map(\.thinking), [.off])
        XCTAssertFalse(arbiter.allowsBackup(after: failure))
    }

    func testTransientFailureBeforeOutputCanRetryAndPermitBackupIfExhausted() async {
        let failure = ProviderError(status: 503, "busy")
        let provider = Script([([], failure), ([], failure)])
        let arbiter = WholeTurnRetryArbiter()
        var agent = Agent(provider: provider, model: "test", system: "")
        agent.retryDelays = [0]
        do {
            try await agent.run(history: [.user("current")], retryArbiter: arbiter) { _ in }
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? ProviderError, failure)
        }
        XCTAssertEqual(provider.requests.count, 2)
        XCTAssertTrue(arbiter.allowsBackup(after: failure))
        XCTAssertFalse(arbiter.allowsBackup(after: CancellationError()))
    }
}
