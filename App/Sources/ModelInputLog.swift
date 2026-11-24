import AgentKit
import Combine
import Craft
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
    let memoryBlock: String
    let skillsBlock: String
    var system: String
    var memory: String = ""
    var skills: String = ""

    init(base: String, extra: String, memory: String, skills: String) {
        self.memoryBlock = memory
        self.skillsBlock = skills
        let extracted = Self.extract(from: base + extra, memoryBlock: memory, skillsBlock: skills)
        self.system = extracted.system
        self.memory = extracted.memory
        self.skills = extracted.skills
    }

    func extract(from actualSystem: String) -> (system: String, memory: String, skills: String) {
        Self.extract(from: actualSystem, memoryBlock: memoryBlock, skillsBlock: skillsBlock)
    }

    private static func extract(from fullPrompt: String, memoryBlock: String, skillsBlock: String) -> (system: String, memory: String, skills: String) {
        guard let rules = fullPrompt.range(of: "\n\n做事：\n") else {
            return (fullPrompt, "", "")
        }
        var opening = fullPrompt[..<rules.lowerBound]
        let foundMemory = take(memoryBlock, from: &opening)
        let foundSkills = take(skillsBlock, from: &opening)
        let remainingSystem = String(opening) + String(fullPrompt[rules.lowerBound...])
        return (remainingSystem, foundMemory, foundSkills)
    }

    private static func take(_ block: String, from prompt: inout Substring) -> String {
        guard !block.isEmpty,
              let range = prompt.range(of: "\n\n" + block, options: [.backwards, .anchored, .literal]) else { return "" }
        prompt = prompt[..<range.lowerBound]
        return block
    }
}

/// Observes the actual AgentKit request, including its tool follow-ups. No HTTP headers, tool arguments,
/// message contents, images, or provider configuration go into the log, and any kept Vault secrets are masked.
struct ModelInputProvider: ModelProvider {
    let upstream: any ModelProvider
    let sections: ModelInputSections
    let record: @Sendable (ModelInput) -> Void

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        let order = ContinuousClock.now
        let at = Date()
        let stream = upstream.stream(request)
        let secrets = Vault.allStrings()
        let split = sections.extract(from: request.system)
        let tools = request.tools.map { "\($0.name)\n\($0.description)" }.joined(separator: "\n\n")
        record(ModelInput(
            at: at,
            order: order,
            model: request.model,
            system: Shell.mask(split.system, secrets: secrets),
            memory: Shell.mask(split.memory, secrets: secrets),
            skills: Shell.mask(split.skills, secrets: secrets),
            tools: Shell.mask(tools, secrets: secrets),
            messages: request.messages.count,
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
