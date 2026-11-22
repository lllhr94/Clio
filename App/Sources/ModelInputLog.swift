import AgentKit
import Combine
import Foundation

struct ModelInput: Identifiable, Sendable {
    let id = UUID()
    let at: Date
    let order: ContinuousClock.Instant
    let model: String
    let system: String
    let memory: String
    let skills: String
    let tools: String
    let messages: Int
    let characters: Int

    var bytes: Int { system.utf8.count + memory.utf8.count + skills.utf8.count + tools.utf8.count }
}

/// Separates known blocks from the exact prompt, without changing what the provider receives.
struct ModelInputSections: Sendable {
    var system: String
    var memory: String = ""
    var skills: String = ""

    init(base: String, extra: String, memory: String, skills: String) {
        system = base + extra
        guard let rules = base.range(of: "\n\n做事：\n", options: .backwards) else { return }
        var opening = base[..<rules.lowerBound]
        self.memory = Self.take(memory, from: &opening)
        self.skills = Self.take(skills, from: &opening)
        system = String(opening) + String(base[rules.lowerBound...]) + extra
    }

    private static func take(_ block: String, from prompt: inout Substring) -> String {
        guard !block.isEmpty,
              let range = prompt.range(of: "\n\n" + block, options: [.backwards, .anchored, .literal]) else { return "" }
        prompt = prompt[..<range.lowerBound]
        return block
    }
}

/// Observes the actual AgentKit request, including its tool follow-ups. No HTTP headers, tool arguments,
/// message contents, images, or provider configuration go into the log.
struct ModelInputProvider: ModelProvider {
    let upstream: any ModelProvider
    let sections: ModelInputSections
    let record: @Sendable (ModelInput) -> Void

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        let order = ContinuousClock.now
        let at = Date()
        let stream = upstream.stream(request)
        let tools = request.tools.map { "\($0.name)\n\($0.description)" }.joined(separator: "\n\n")
        record(ModelInput(
            at: at, order: order, model: request.model, system: sections.system, memory: sections.memory,
            skills: sections.skills, tools: tools, messages: request.messages.count,
            characters: request.messages.reduce(0) { $0 + $1.text.count }
        ))
        return stream
    }

    func models() async throws -> [String] { try await upstream.models() }
}

@MainActor
final class ModelInputLog: ObservableObject {
    @Published private var recent: [Row] = []
    private(set) var session = UUID()

    private struct Row {
        let chat: String
        let input: ModelInput
        let bytes: Int
    }

    func requests(in chat: String) -> [ModelInput] {
        recent.reversed().filter { $0.chat == chat }.map(\.input)
    }

    func add(_ input: ModelInput, in chat: String) {
        var rows = recent
        rows.append(Row(chat: chat, input: input, bytes: input.bytes))
        rows.sort { $0.input.order < $1.input.order }
        var bytes = 0
        // Keep the newest request even if its prompt alone exceeds the retention budget.
        recent = Array(rows.reversed().prefix(24).prefix { row in
            let first = bytes == 0
            bytes += max(row.bytes, 1)
            return first || bytes <= 4 * 1024 * 1024
        }.reversed())
    }

    func clear(_ chat: String) {
        recent.removeAll { $0.chat == chat }
    }

    func reset() {
        session = UUID()
        recent = []
    }
}
