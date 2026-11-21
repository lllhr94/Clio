import Foundation

/// Something the user told a Bot to remember about them.
struct Memory: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var text: String
    var at: Double
    var by: String?
    /// 旧事: kept, but not in every conversation; found again with `recall`.
    var deep: Bool?
    /// Milliseconds: when it was last recalled or written.
    var used: Double?
    var automatic: Bool?
    var editedByUser: Bool?
}

struct MemoryReviewLog: Codable, Identifiable, Sendable {
    var id: UUID
    var at: Date
    var day: String
    var conversation: String
    var added: [Addition]
    var merged: [Change]

    struct Addition: Codable, Sendable {
        var memoryID: String
        var text: String
    }

    struct Change: Codable, Sendable {
        var memoryID: String
        var before: String
        var after: String
    }
}

/// Written atomically with the memories so a restart cannot replay half an update.
struct MemoryBook: Codable, Sendable {
    var memories: [Memory] = []
    var reviews: [MemoryReviewLog] = []
    var processed: [String: Set<String>] = [:]
    var reviewFromDay: String?
    var budgetDay: String?
    var requests: Int = 0
    var diaryRequests: Int = 0
}

struct MemoryReviewProposal: Decodable {
    var text: String
    var merge: String?
}

enum MemoryReviewRules {
    static let idle: TimeInterval = 600
    static let inputBytes = 10_000
    static let outputTokens = 450
    static let requestsPerDay = 24
    static let diaryRequestsPerDay = 12

    static func clip(_ text: String, bytes: Int) -> String {
        var prefix = text.utf8.prefix(max(0, bytes))
        while let byte = prefix.last, byte >= 0x80 {
            if let valid = String(bytes: prefix, encoding: .utf8) { return valid }
            prefix = prefix.dropLast()
        }
        return String(decoding: prefix, as: UTF8.self)
    }

    static func normalized(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
    }

    static func mayMerge(_ memory: Memory) -> Bool {
        memory.automatic == true && memory.editedByUser != true
    }

    static func redacted(_ text: String, secrets: [String]) -> String {
        secrets.filter { !$0.isEmpty }.reduce(text) { words, secret in
            words.replacingOccurrences(of: secret, with: "〔隐去〕")
        }
    }

    static func apply(_ proposals: [MemoryReviewProposal], seen: [String: String], to memories: inout [Memory],
                      at now: Double, secrets: [String]) -> (added: [MemoryReviewLog.Addition], merged: [MemoryReviewLog.Change]) {
        var added: [MemoryReviewLog.Addition] = []
        var merged: [MemoryReviewLog.Change] = []
        for proposal in proposals.prefix(6) {
            let text = proposal.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let comparisonKey = normalized(text)
            guard !comparisonKey.isEmpty, text.utf8.count <= 450, !text.contains("〔隐去〕"),
                  redacted(text, secrets: secrets) == text,
                  !memories.contains(where: { Self.normalized($0.text) == comparisonKey }) else { continue }
            if let merge = proposal.merge {
                guard let index = memories.firstIndex(where: { $0.id == merge }),
                      mayMerge(memories[index]), seen[merge] == memories[index].text else { continue }
                let before = memories[index].text
                memories[index].text = text
                memories[index].used = now
                memories[index].deep = nil
                merged.append(.init(memoryID: merge, before: before, after: text))
            } else {
                let id = UUID().uuidString
                memories.append(Memory(id: id, text: text, at: now, by: nil, used: now, automatic: true))
                added.append(.init(memoryID: id, text: text))
            }
        }
        return (added, merged)
    }
}
