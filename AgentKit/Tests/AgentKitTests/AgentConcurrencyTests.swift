import Foundation
import XCTest
@testable import AgentKit

private final class ScriptedConcurrencyProvider: ModelProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [[StreamEvent]]
    private var recordedRequests: [ModelRequest] = []

    init(_ replies: [[StreamEvent]]) {
        self.replies = replies
    }

    var requests: [ModelRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        lock.lock()
        recordedRequests.append(request)
        let reply = replies.isEmpty ? [StreamEvent.text("（结束）"), StreamEvent.finish(reason: "stop")] : replies.removeFirst()
        lock.unlock()
        return AsyncThrowingStream { continuation in
            for event in reply {
                continuation.yield(event)
            }
            if !reply.contains(where: {
                if case .finish = $0 { return true }
                return false
            }) {
                continuation.yield(.finish(reason: "stop"))
            }
            continuation.finish()
        }
    }

    func models() async throws -> [String] { ["scripted"] }
}

private actor EventRecorder {
    var events: [AgentEvent] = []

    func add(_ event: AgentEvent) {
        events.append(event)
    }

    var messages: [Message] {
        events.compactMap { event in
            if case .message(let message) = event { return message }
            return nil
        }
    }

    var toolResults: [Message] {
        messages.filter { $0.role == .tool }
    }
}

private actor TimelineTracker {
    enum Mark: Equatable {
        case start(String)
        case finish(String)
    }

    private var inFlight = 0
    private(set) var maxInFlight = 0
    private(set) var marks: [Mark] = []
    private(set) var startedIDs: [String] = []
    private(set) var finishedIDs: [String] = []

    func begin(_ id: String) {
        inFlight += 1
        if inFlight > maxInFlight { maxInFlight = inFlight }
        startedIDs.append(id)
        marks.append(.start(id))
    }

    func end(_ id: String) {
        inFlight = max(0, inFlight - 1)
        finishedIDs.append(id)
        marks.append(.finish(id))
    }

    func waitForInFlight(_ target: Int, timeoutMilliseconds: Int = 2500) async -> Bool {
        if inFlight >= target { return true }
        let deadline = ContinuousClock.now + .milliseconds(timeoutMilliseconds)
        while inFlight < target {
            if ContinuousClock.now >= deadline { return false }
            let remaining = deadline - ContinuousClock.now
            let step: Duration
            if remaining < .milliseconds(10) {
                step = remaining
            } else {
                step = .milliseconds(10)
            }
            try? await Task.sleep(for: step)
        }
        return true
    }

    func waitForFinished(_ id: String, timeoutMilliseconds: Int = 2500) async -> Bool {
        if finishedIDs.contains(id) { return true }
        let deadline = ContinuousClock.now + .milliseconds(timeoutMilliseconds)
        while !finishedIDs.contains(id) {
            if ContinuousClock.now >= deadline { return false }
            let remaining = deadline - ContinuousClock.now
            let step: Duration
            if remaining < .milliseconds(10) {
                step = remaining
            } else {
                step = .milliseconds(10)
            }
            try? await Task.sleep(for: step)
        }
        return true
    }

    func snapshot() -> (maxInFlight: Int, marks: [Mark], started: [String], finished: [String]) {
        (maxInFlight: maxInFlight, marks: marks, started: startedIDs, finished: finishedIDs)
    }
}

private struct DefaultSerialTool: AgentTool {
    let tracker: TimelineTracker
    var spec: ToolSpec { ToolSpec(name: "default_serial", description: "", parameters: ["type": "object"]) }
    func label(for arguments: JSONValue) -> String { "串行" }
    func run(_ arguments: JSONValue) async throws -> ToolOutput {
        let id = arguments["id"]?.string ?? "?"
        await tracker.begin(id)
        try await Task.sleep(for: .milliseconds(20))
        await tracker.end(id)
        return ToolOutput("serial:\(id)")
    }
}

private struct BarrierReadTool: AgentTool {
    let name: String
    let tracker: TimelineTracker
    let targetInFlight: Int
    var spec: ToolSpec { ToolSpec(name: name, description: "", parameters: ["type": "object"]) }
    var isReadOnlySafe: Bool { true }
    func label(for arguments: JSONValue) -> String { "只读" }
    func run(_ arguments: JSONValue) async throws -> ToolOutput {
        let id = arguments["id"]?.string ?? "?"
        await tracker.begin(id)
        if targetInFlight > 1 {
            let reached = await tracker.waitForInFlight(targetInFlight)
            if !reached {
                await tracker.end(id)
                return ToolOutput("未达到并发目标 \(targetInFlight)", isError: true)
            }
        }
        try await Task.sleep(for: .milliseconds(15))
        await tracker.end(id)
        return ToolOutput("read:\(id)")
    }
}

final class AgentConcurrencyTests: XCTestCase {
    private func makeCalls(_ items: [(id: String, name: String, args: String)]) -> [StreamEvent] {
        var events: [StreamEvent] = []
        for (index, item) in items.enumerated() {
            events.append(.toolCallStart(index: index, id: item.id, name: item.name))
            events.append(.toolCallArguments(index: index, delta: item.args))
        }
        events.append(.finish(reason: "tool_calls"))
        return events
    }

    func testDefaultToolProtocolIsFailClosedAndRunsSerially() async throws {
        let tracker = TimelineTracker()
        let tool = DefaultSerialTool(tracker: tracker)
        XCTAssertFalse(tool.isReadOnlySafe)

        let batch = makeCalls([
            ("c0", "default_serial", #"{"id":"0"}"#),
            ("c1", "default_serial", #"{"id":"1"}"#),
            ("c2", "default_serial", #"{"id":"2"}"#),
            ("c3", "default_serial", #"{"id":"3"}"#),
        ])
        let provider = ScriptedConcurrencyProvider([batch, [.text("好了")]])
        let recorder = EventRecorder()
        let agent = Agent(provider: provider, model: "m", system: "", tools: [tool])
        try await agent.run(history: [.user("跑")]) { await recorder.add($0) }

        let snapshot = await tracker.snapshot()
        XCTAssertEqual(snapshot.maxInFlight, 1)
        XCTAssertEqual(snapshot.started, ["0", "1", "2", "3"])
        XCTAssertEqual(snapshot.finished, ["0", "1", "2", "3"])
    }

    func testReadOnlyToolsRunConcurrentlyWithBoundedMaxConcurrency4() async throws {
        let tracker = TimelineTracker()
        let readTool = BarrierReadTool(name: "read_item", tracker: tracker, targetInFlight: 4)
        XCTAssertTrue(readTool.isReadOnlySafe)

        let batch = makeCalls([
            ("c0", "read_item", #"{"id":"0"}"#),
            ("c1", "read_item", #"{"id":"1"}"#),
            ("c2", "read_item", #"{"id":"2"}"#),
            ("c3", "read_item", #"{"id":"3"}"#),
            ("c4", "read_item", #"{"id":"4"}"#),
            ("c5", "read_item", #"{"id":"5"}"#),
        ])
        let provider = ScriptedConcurrencyProvider([batch, [.text("完成")]])
        let recorder = EventRecorder()
        let agent = Agent(provider: provider, model: "m", system: "", tools: [readTool])
        try await agent.run(history: [.user("全读")]) { await recorder.add($0) }

        let snapshot = await tracker.snapshot()
        XCTAssertEqual(snapshot.maxInFlight, 4)
        XCTAssertEqual(snapshot.finished.count, 6)
        let results = await recorder.toolResults
        XCTAssertEqual(results.map(\.toolCallId), ["c0", "c1", "c2", "c3", "c4", "c5"])
        XCTAssertEqual(results.map(\.text), ["read:0", "read:1", "read:2", "read:3", "read:4", "read:5"])
        XCTAssertTrue(results.allSatisfy { !$0.isError })
    }

    func testOutOfOrderCompletionPreservesExactResultOrder() async throws {
        struct OrderedWaitTool: AgentTool {
            let tracker: TimelineTracker
            var spec: ToolSpec { ToolSpec(name: "ordered_read", description: "", parameters: ["type": "object"]) }
            var isReadOnlySafe: Bool { true }
            func label(for arguments: JSONValue) -> String { "按序" }
            func run(_ arguments: JSONValue) async throws -> ToolOutput {
                let id = arguments["id"]?.string ?? ""
                await tracker.begin(id)
                if id == "0" {
                    let ok1 = await tracker.waitForFinished("1")
                    let ok2 = await tracker.waitForFinished("2")
                    guard ok1 && ok2 else {
                        await tracker.end(id)
                        return ToolOutput("timeout waiting for 1 and 2", isError: true)
                    }
                } else if id == "1" {
                    let ok2 = await tracker.waitForFinished("2")
                    guard ok2 else {
                        await tracker.end(id)
                        return ToolOutput("timeout waiting for 2", isError: true)
                    }
                }
                await tracker.end(id)
                return ToolOutput("res:\(id)")
            }
        }

        let tracker = TimelineTracker()
        let batch = makeCalls([
            ("c0", "ordered_read", #"{"id":"0"}"#),
            ("c1", "ordered_read", #"{"id":"1"}"#),
            ("c2", "ordered_read", #"{"id":"2"}"#),
        ])
        let provider = ScriptedConcurrencyProvider([batch, [.text("ok")]])
        let recorder = EventRecorder()
        let agent = Agent(provider: provider, model: "m", system: "", tools: [OrderedWaitTool(tracker: tracker)])
        try await agent.run(history: [.user("测试顺序")]) { await recorder.add($0) }

        let snapshot = await tracker.snapshot()
        XCTAssertEqual(snapshot.finished, ["2", "1", "0"])

        let toolResults = await recorder.toolResults
        XCTAssertEqual(toolResults.map(\.toolCallId), ["c0", "c1", "c2"])
        XCTAssertEqual(toolResults.map(\.text), ["res:0", "res:1", "res:2"])
        XCTAssertTrue(toolResults.allSatisfy { !$0.isError })

        let secondRequest = try XCTUnwrap(provider.requests.dropFirst().first)
        let sentToolIds = secondRequest.messages.filter { $0.role == .tool }.compactMap(\.toolCallId)
        XCTAssertEqual(sentToolIds, ["c0", "c1", "c2"])
    }

    func testBarrierSerializationAroundNonReadOnlyTool() async throws {
        struct WriteTool: AgentTool {
            let tracker: TimelineTracker
            var spec: ToolSpec { ToolSpec(name: "write_item", description: "", parameters: ["type": "object"]) }
            func label(for arguments: JSONValue) -> String { "写" }
            func run(_ arguments: JSONValue) async throws -> ToolOutput {
                let id = arguments["id"]?.string ?? "w"
                await tracker.begin(id)
                try await Task.sleep(for: .milliseconds(15))
                await tracker.end(id)
                return ToolOutput("wrote:\(id)")
            }
        }

        let tracker = TimelineTracker()
        let readTool = BarrierReadTool(name: "read_item", tracker: tracker, targetInFlight: 2)
        let writeTool = WriteTool(tracker: tracker)
        let batch = makeCalls([
            ("c0", "read_item", #"{"id":"r1"}"#),
            ("c1", "read_item", #"{"id":"r2"}"#),
            ("c2", "write_item", #"{"id":"w1"}"#),
            ("c3", "read_item", #"{"id":"r3"}"#),
            ("c4", "read_item", #"{"id":"r4"}"#),
        ])
        let provider = ScriptedConcurrencyProvider([batch, [.text("搞定")]])
        let recorder = EventRecorder()
        let agent = Agent(provider: provider, model: "m", system: "", tools: [readTool, writeTool])
        try await agent.run(history: [.user("读写混排")]) { await recorder.add($0) }

        let snapshot = await tracker.snapshot()
        let marks = snapshot.marks
        let w1Start = try XCTUnwrap(marks.firstIndex(of: .start("w1")))
        let w1Finish = try XCTUnwrap(marks.firstIndex(of: .finish("w1")))
        let r1Finish = try XCTUnwrap(marks.firstIndex(of: .finish("r1")))
        let r2Finish = try XCTUnwrap(marks.firstIndex(of: .finish("r2")))
        let r3Start = try XCTUnwrap(marks.firstIndex(of: .start("r3")))
        let r4Start = try XCTUnwrap(marks.firstIndex(of: .start("r4")))

        XCTAssertLessThan(r1Finish, w1Start)
        XCTAssertLessThan(r2Finish, w1Start)
        XCTAssertLessThan(w1Finish, r3Start)
        XCTAssertLessThan(w1Finish, r4Start)
        XCTAssertEqual(snapshot.maxInFlight, 2)

        let toolResults = await recorder.toolResults
        XCTAssertEqual(toolResults.map(\.toolCallId), ["c0", "c1", "c2", "c3", "c4"])
    }

    func testDynamicApprovalForcesSerializationEvenWhenReadOnlySafe() async throws {
        struct ConditionalReadTool: AgentTool {
            let tracker: TimelineTracker
            var spec: ToolSpec { ToolSpec(name: "cond_read", description: "", parameters: ["type": "object"]) }
            var isReadOnlySafe: Bool { true }
            func label(for arguments: JSONValue) -> String { "条件读" }
            func approval(for arguments: JSONValue) -> ApprovalAsk? {
                if arguments["ask"]?.bool == true {
                    return ApprovalAsk(title: "需要确认", reason: arguments["id"]?.string ?? "")
                }
                return nil
            }
            func run(_ arguments: JSONValue) async throws -> ToolOutput {
                let id = arguments["id"]?.string ?? ""
                await tracker.begin(id)
                try await Task.sleep(for: .milliseconds(20))
                await tracker.end(id)
                return ToolOutput("cond:\(id)")
            }
        }

        let approvalTracker = TimelineTracker()
        let runTracker = TimelineTracker()
        let tool = ConditionalReadTool(tracker: runTracker)
        let batch = makeCalls([
            ("c0", "cond_read", #"{"id":"r0","ask":false}"#),
            ("c1", "cond_read", #"{"id":"r1","ask":true}"#),
            ("c2", "cond_read", #"{"id":"r2","ask":true}"#),
            ("c3", "cond_read", #"{"id":"r3","ask":false}"#),
            ("c4", "cond_read", #"{"id":"r4","ask":false}"#),
        ])
        let provider = ScriptedConcurrencyProvider([batch, [.text("好了")]])
        let recorder = EventRecorder()
        let agent = Agent(provider: provider, model: "m", system: "", tools: [tool]) { ask, _ in
            await approvalTracker.begin(ask.reason)
            try? await Task.sleep(for: .milliseconds(20))
            await approvalTracker.end(ask.reason)
            return true
        }
        try await agent.run(history: [.user("审批串行")]) { await recorder.add($0) }

        let approveSnap = await approvalTracker.snapshot()
        XCTAssertEqual(approveSnap.maxInFlight, 1)
        XCTAssertEqual(approveSnap.started, ["r1", "r2"])

        let runSnap = await runTracker.snapshot()
        let r0Finish = try XCTUnwrap(runSnap.marks.firstIndex(of: .finish("r0")))
        let r1Start = try XCTUnwrap(runSnap.marks.firstIndex(of: .start("r1")))
        let r1Finish = try XCTUnwrap(runSnap.marks.firstIndex(of: .finish("r1")))
        let r2Start = try XCTUnwrap(runSnap.marks.firstIndex(of: .start("r2")))
        let r2Finish = try XCTUnwrap(runSnap.marks.firstIndex(of: .finish("r2")))
        let r3Start = try XCTUnwrap(runSnap.marks.firstIndex(of: .start("r3")))
        let r4Start = try XCTUnwrap(runSnap.marks.firstIndex(of: .start("r4")))

        XCTAssertLessThan(r0Finish, r1Start)
        XCTAssertLessThan(r1Finish, r2Start)
        XCTAssertLessThan(r2Finish, r3Start)
        XCTAssertLessThan(r2Finish, r4Start)

        let pairApprovalTracker = TimelineTracker()
        let pairRunTracker = TimelineTracker()
        let pairAgent = Agent(
            provider: ScriptedConcurrencyProvider([
                makeCalls([
                    ("p1", "cond_read", #"{"id":"p1","ask":true}"#),
                    ("p2", "cond_read", #"{"id":"p2","ask":true}"#),
                ]),
                [.text("done")],
            ]),
            model: "m",
            system: "",
            tools: [ConditionalReadTool(tracker: pairRunTracker)]
        ) { ask, _ in
            await pairApprovalTracker.begin(ask.reason)
            try? await Task.sleep(for: .milliseconds(15))
            await pairApprovalTracker.end(ask.reason)
            return true
        }
        try await pairAgent.run(history: [.user("双审批")]) { _ in }
        let pairApproveSnap = await pairApprovalTracker.snapshot()
        let pairRunSnap = await pairRunTracker.snapshot()
        XCTAssertEqual(pairApproveSnap.maxInFlight, 1)
        XCTAssertEqual(pairRunSnap.maxInFlight, 1)
    }

    func testToolInvocationCurrentIDIsIsolatedPerSiblingTask() async throws {
        actor CaptureBox {
            var seen: [String: (before: String?, after: String?)] = [:]
            func record(_ callKey: String, before: String?, after: String?) {
                seen[callKey] = (before: before, after: after)
            }
        }

        struct ScopedReadTool: AgentTool {
            let tracker: TimelineTracker
            let box: CaptureBox
            var spec: ToolSpec { ToolSpec(name: "scoped_read", description: "", parameters: ["type": "object"]) }
            var isReadOnlySafe: Bool { true }
            func label(for arguments: JSONValue) -> String { "隔离" }
            func run(_ arguments: JSONValue) async throws -> ToolOutput {
                let id = arguments["id"]?.string ?? ""
                let before = ToolInvocation.currentID
                await tracker.begin(id)
                _ = await tracker.waitForInFlight(4)
                await Task.yield()
                let after = ToolInvocation.currentID
                await box.record(id, before: before, after: after)
                await tracker.end(id)
                return ToolOutput(after ?? "nil")
            }
        }

        let tracker = TimelineTracker()
        let box = CaptureBox()
        let batch = makeCalls([
            ("callA", "scoped_read", #"{"id":"A"}"#),
            ("callB", "scoped_read", #"{"id":"B"}"#),
            ("callC", "scoped_read", #"{"id":"C"}"#),
            ("callD", "scoped_read", #"{"id":"D"}"#),
        ])
        let provider = ScriptedConcurrencyProvider([batch, [.text("ok")]])
        let agent = Agent(provider: provider, model: "m", system: "", tools: [ScopedReadTool(tracker: tracker, box: box)])
        try await agent.run(history: [.user("查")]) { _ in }

        let seen = await box.seen
        XCTAssertEqual(seen.count, 4)
        var uniqueIDs: Set<String> = []
        for (key, pair) in seen {
            let before = try XCTUnwrap(pair.before)
            let after = try XCTUnwrap(pair.after)
            XCTAssertEqual(before, after, "TaskLocal changed across suspension for \(key)")
            XCTAssertTrue(before.hasPrefix("call\(key)-"), "Unexpected TaskLocal prefix: \(before)")
            uniqueIDs.insert(before)
        }
        XCTAssertEqual(uniqueIDs.count, 4)
    }

    func testIndividualToolFailureDoesNotCrashParallelSiblings() async throws {
        struct FlakyReadTool: AgentTool {
            let tracker: TimelineTracker
            var spec: ToolSpec { ToolSpec(name: "flaky_read", description: "", parameters: ["type": "object"]) }
            var isReadOnlySafe: Bool { true }
            func label(for arguments: JSONValue) -> String { "试读" }
            func run(_ arguments: JSONValue) async throws -> ToolOutput {
                let id = arguments["id"]?.string ?? ""
                await tracker.begin(id)
                try await Task.sleep(for: .milliseconds(10))
                if id == "throw" {
                    await tracker.end(id)
                    throw ProviderError("读失败")
                }
                if id == "err" {
                    await tracker.end(id)
                    return ToolOutput("不存在", isError: true)
                }
                await tracker.end(id)
                return ToolOutput("ok:\(id)")
            }
        }

        let tracker = TimelineTracker()
        let batch = makeCalls([
            ("c0", "flaky_read", #"{"id":"ok1"}"#),
            ("c1", "flaky_read", #"{"id":"throw"}"#),
            ("c2", "flaky_read", #"{"id":"err"}"#),
            ("c3", "flaky_read", #"{"id":"ok2"}"#),
        ])
        let provider = ScriptedConcurrencyProvider([batch, [.text("知道了")]])
        let recorder = EventRecorder()
        let agent = Agent(provider: provider, model: "m", system: "", tools: [FlakyReadTool(tracker: tracker)])
        try await agent.run(history: [.user("读")]) { await recorder.add($0) }

        let results = await recorder.toolResults
        XCTAssertEqual(results.map(\.toolCallId), ["c0", "c1", "c2", "c3"])
        XCTAssertEqual(results.map(\.isError), [false, true, true, false])
        XCTAssertEqual(results[0].text, "ok:ok1")
        XCTAssertTrue(results[1].text.contains("读失败"))
        XCTAssertEqual(results[2].text, "不存在")
        XCTAssertEqual(results[3].text, "ok:ok2")

        let events = await recorder.events
        XCTAssertTrue(events.contains(.toolFinished(id: "c0", ok: true)))
        XCTAssertTrue(events.contains(.toolFinished(id: "c1", ok: false)))
        XCTAssertTrue(events.contains(.toolFinished(id: "c2", ok: false)))
        XCTAssertTrue(events.contains(.toolFinished(id: "c3", ok: true)))
    }

    func testTaskCancellationInterruptsParallelBatchCleanly() async throws {
        struct SlowReadTool: AgentTool {
            let tracker: TimelineTracker
            var spec: ToolSpec { ToolSpec(name: "slow_read", description: "", parameters: ["type": "object"]) }
            var isReadOnlySafe: Bool { true }
            func label(for arguments: JSONValue) -> String { "慢读" }
            func run(_ arguments: JSONValue) async throws -> ToolOutput {
                let id = arguments["id"]?.string ?? ""
                await tracker.begin(id)
                do {
                    try await Task.sleep(for: .seconds(10))
                    await tracker.end(id)
                    return ToolOutput("done:\(id)")
                } catch {
                    await tracker.end(id)
                    throw error
                }
            }
        }

        let tracker = TimelineTracker()
        let batch = makeCalls([
            ("c0", "slow_read", #"{"id":"0"}"#),
            ("c1", "slow_read", #"{"id":"1"}"#),
            ("c2", "slow_read", #"{"id":"2"}"#),
            ("c3", "slow_read", #"{"id":"3"}"#),
            ("c4", "slow_read", #"{"id":"4"}"#),
            ("c5", "slow_read", #"{"id":"5"}"#),
        ])
        let provider = ScriptedConcurrencyProvider([batch, [.text("不该到这里")]])
        let recorder = EventRecorder()
        let agent = Agent(provider: provider, model: "m", system: "", tools: [SlowReadTool(tracker: tracker)])

        let task = Task {
            try await agent.run(history: [.user("取消测试")]) { await recorder.add($0) }
        }
        let startedFour = await tracker.waitForInFlight(4)
        XCTAssertTrue(startedFour)
        task.cancel()

        do {
            try await task.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        let snapshot = await tracker.snapshot()
        XCTAssertEqual(snapshot.started.count, 4, "Queued tools 4 and 5 must not start after cancellation")
        let events = await recorder.events
        let started = events.compactMap { event -> String? in
            if case .toolStarted(let id, _, _) = event { return id }
            return nil
        }
        let finished = events.compactMap { event -> (String, Bool)? in
            if case .toolFinished(let id, let ok) = event { return (id, ok) }
            return nil
        }
        XCTAssertEqual(Set(started), Set(finished.map(\.0)))
        XCTAssertTrue(finished.allSatisfy { !$0.1 })
    }

    func testBadJSONUnknownAndUncertainDoNotJoinConcurrentRun() async throws {
        struct UncertainWriteTool: AgentTool {
            var spec: ToolSpec { ToolSpec(name: "uncertain_send", description: "", parameters: ["type": "object"]) }
            func label(for arguments: JSONValue) -> String { "发" }
            func approval(for arguments: JSONValue) -> ApprovalAsk? { ApprovalAsk(title: "发", reason: "发") }
            func run(_ arguments: JSONValue) async throws -> ToolOutput { throw URLError(.timedOut) }
        }

        let tracker = TimelineTracker()
        let readTool = BarrierReadTool(name: "read_item", tracker: tracker, targetInFlight: 2)
        let firstTurn = makeCalls([("u0", "uncertain_send", "{}")])
        let secondTurn = makeCalls([
            ("u1", "uncertain_send", "{}"),
            ("r0", "read_item", #"{"id":"0"}"#),
            ("bad", "read_item", "{broken"),
            ("r1", "read_item", #"{"id":"1"}"#),
            ("unk", "missing_tool", "{}"),
            ("r2", "read_item", #"{"id":"2"}"#),
            ("r3", "read_item", #"{"id":"3"}"#),
        ])
        let provider = ScriptedConcurrencyProvider([firstTurn, secondTurn, [.text("完")]])
        let recorder = EventRecorder()
        let agent = Agent(provider: provider, model: "m", system: "", tools: [UncertainWriteTool(), readTool]) { _, _ in true }
        try await agent.run(history: [.user("试")] ) { await recorder.add($0) }

        let results = await recorder.toolResults
        XCTAssertEqual(results.map(\.toolCallId), ["u0", "u1", "r0", "bad", "r1", "unk", "r2", "r3"])
        XCTAssertTrue(results[0].text.hasPrefix(Agent.unknownMark))
        XCTAssertTrue(results[1].text.contains("没有再做一次"))
        XCTAssertEqual(results[2].text, "read:0")
        XCTAssertTrue(results[3].text.contains("合法的 JSON"))
        XCTAssertEqual(results[4].text, "read:1")
        XCTAssertTrue(results[5].text.contains("没有叫 missing_tool"))
        XCTAssertEqual(results[6].text, "read:2")
        XCTAssertEqual(results[7].text, "read:3")
        let maxConcurrent = await tracker.snapshot().maxInFlight
        XCTAssertEqual(maxConcurrent, 2)
    }

    func testCircuitBreakerTripsAfterThreeConsecutiveNormalizedCalls() async throws {
        let tracker = TimelineTracker()
        let readTool = BarrierReadTool(name: "read_item", tracker: tracker, targetInFlight: 1)
        let provider = ScriptedConcurrencyProvider([
            makeCalls([("c1", "read_item", #"{"b":2,"a":{"y":9,"x":8},"step_title":"第一次"}"#)]),
            makeCalls([("c2", "read_item", #"{"step_title":"第二次","a":{"x":8,"y":9},"b":2}"#)]),
            makeCalls([("c3", "read_item", #"{ "a" : { "y" : 9 , "x" : 8 } , "b" : 2 }"#)]),
            makeCalls([("c4", "read_item", #"{"a":{"x":8,"y":9},"b":2}"#)]),
            makeCalls([("c5", "read_item", #"{"a":{"x":8,"y":9},"b":2}"#)]),
        ])
        let recorder = EventRecorder()
        var agent = Agent(provider: provider, model: "m", system: "", tools: [readTool])
        agent.maxSteps = 10
        try await agent.run(history: [.user("循环测试")]) { await recorder.add($0) }

        XCTAssertEqual(provider.requests.count, 3)
        let finishedCount = await tracker.snapshot().finished.count
        XCTAssertEqual(finishedCount, 3)

        let messages = await recorder.messages
        XCTAssertEqual(messages.last, .assistant(Agent.repeatedLoopStopMessage))
        // Ensure every emitted assistant tool_calls message has its matching tool result before the circuit-breaker message.
        for index in messages.indices where messages[index].role == .assistant && !messages[index].toolCalls.isEmpty {
            XCTAssertLessThan(index + 1, messages.count)
            XCTAssertEqual(messages[index + 1].role, .tool)
        }
    }

    func testCircuitBreakerTripsForMultiCallBatchEmptyAndMalformedCalls() async throws {
        let tracker = TimelineTracker()
        let readTool = BarrierReadTool(name: "read_item", tracker: tracker, targetInFlight: 1)

        let multiBatchA = makeCalls([
            ("a1", "read_item", #"{"id":"a","step_title":"x"}"#),
            ("b1", "read_item", #"{"id":"b","step_title":"y"}"#),
        ])
        let multiBatchB = makeCalls([
            ("a2", "read_item", #"{"id":"a","step_title":"z"}"#),
            ("b2", "read_item", #"{"id":"b"}"#),
        ])
        let multiBatchC = makeCalls([
            ("a3", "read_item", #"{"id":"a"}"#),
            ("b3", "read_item", #"{"id":"b","step_title":"w"}"#),
        ])
        let multiProvider = ScriptedConcurrencyProvider([multiBatchA, multiBatchB, multiBatchC, multiBatchA])
        let multiRecorder = EventRecorder()
        var multiAgent = Agent(provider: multiProvider, model: "m", system: "", tools: [readTool])
        multiAgent.maxSteps = 10
        try await multiAgent.run(history: [.user("多步重复")]) { await multiRecorder.add($0) }
        XCTAssertEqual(multiProvider.requests.count, 3)
        let multiMessages = await multiRecorder.messages
        XCTAssertEqual(multiMessages.last, .assistant(Agent.repeatedLoopStopMessage))

        let emptyProvider = ScriptedConcurrencyProvider([
            makeCalls([("e1", "read_item", "")]),
            makeCalls([("e2", "read_item", "{}")]),
            makeCalls([("e3", "read_item", #"{"step_title":"空参"}"#)]),
            makeCalls([("e4", "read_item", "{}")]),
        ])
        let emptyRecorder = EventRecorder()
        var emptyAgent = Agent(provider: emptyProvider, model: "m", system: "", tools: [readTool])
        emptyAgent.maxSteps = 8
        try await emptyAgent.run(history: [.user("空参重复")]) { await emptyRecorder.add($0) }
        XCTAssertEqual(emptyProvider.requests.count, 3)
        let emptyMessages = await emptyRecorder.messages
        XCTAssertEqual(emptyMessages.last, .assistant(Agent.repeatedLoopStopMessage))

        let badProvider = ScriptedConcurrencyProvider([
            makeCalls([("m1", "read_item", "{bad")]),
            makeCalls([("m2", "read_item", " {bad ")]),
            makeCalls([("m3", "read_item", "{bad")]),
            makeCalls([("m4", "read_item", "{bad")]),
        ])
        let badRecorder = EventRecorder()
        var badAgent = Agent(provider: badProvider, model: "m", system: "", tools: [readTool])
        badAgent.maxSteps = 8
        try await badAgent.run(history: [.user("坏 JSON 重复")]) { await badRecorder.add($0) }
        XCTAssertEqual(badProvider.requests.count, 3)
        let badMessages = await badRecorder.messages
        XCTAssertEqual(badMessages.last, .assistant(Agent.repeatedLoopStopMessage))
    }

    func testCircuitBreakerDoesNotTripOnDistinctMixedOrInterruptedCalls() async throws {
        let tracker = TimelineTracker()
        let readTool = BarrierReadTool(name: "read_item", tracker: tracker, targetInFlight: 1)

        // 1. Iterative reading of distinct files + mixed batches must not false-trip.
        let mixedProvider = ScriptedConcurrencyProvider([
            makeCalls([("c1", "read_item", #"{"id":"a"}"#), ("c2", "read_item", #"{"id":"b"}"#)]),
            makeCalls([("c3", "read_item", #"{"id":"a"}"#), ("c4", "read_item", #"{"id":"c"}"#)]),
            makeCalls([("c5", "read_item", #"{"id":"a"}"#), ("c6", "read_item", #"{"id":"d"}"#)]),
            makeCalls([("c7", "read_item", #"{"id":"a"}"#), ("c8", "read_item", #"{"id":"a"}"#)]),
            makeCalls([("c9", "read_item", #"{"id":"a"}"#), ("c10", "read_item", #"{"id":"a"}"#)]),
            makeCalls([("c11", "read_item", #"{"id":"e"}"#)]),
            makeCalls([("c12", "read_item", #"{"id":"a"}"#), ("c13", "read_item", #"{"id":"a"}"#)]),
            [.text("全部读完了")],
        ])
        let mixedRecorder = EventRecorder()
        var mixedAgent = Agent(provider: mixedProvider, model: "m", system: "", tools: [readTool])
        mixedAgent.maxSteps = 12
        try await mixedAgent.run(history: [.user("迭代读取")]) { await mixedRecorder.add($0) }

        XCTAssertEqual(mixedProvider.requests.count, 8)
        let mixedMessages = await mixedRecorder.messages
        XCTAssertEqual(mixedMessages.last, .assistant("全部读完了"))

        // 2. User interjection via inbox between identical repeats resets the counter.
        final class InterjectionBox: @unchecked Sendable {
            private let lock = NSLock()
            private var delivered = false
            private var calls = 0

            func next() -> [String] {
                lock.lock()
                defer { lock.unlock() }
                calls += 1
                if calls == 2 && !delivered {
                    delivered = true
                    return ["换个思路再试一次"]
                }
                return []
            }
        }
        let inbox = InterjectionBox()
        let inboxProvider = ScriptedConcurrencyProvider([
            makeCalls([("i1", "read_item", #"{"id":"same"}"#)]),
            makeCalls([("i2", "read_item", #"{"id":"same"}"#)]),
            makeCalls([("i3", "read_item", #"{"id":"same"}"#)]),
            makeCalls([("i4", "read_item", #"{"id":"same"}"#)]),
            [.text("按新要求完成")],
        ])
        let inboxRecorder = EventRecorder()
        var inboxAgent = Agent(provider: inboxProvider, model: "m", system: "", tools: [readTool])
        inboxAgent.maxSteps = 10
        inboxAgent.inbox = { inbox.next() }
        try await inboxAgent.run(history: [.user("插话重置")]) { await inboxRecorder.add($0) }

        XCTAssertEqual(inboxProvider.requests.count, 5)
        let inboxMessages = await inboxRecorder.messages
        XCTAssertEqual(inboxMessages.last, .assistant("按新要求完成"))
    }
}
