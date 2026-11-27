import Foundation

public struct SubConversationOrigin: Codable, Equatable, Sendable {
    public let sourceChatKey: String
    public let sourceEntryID: String
    public let selectedQuote: String

    public init(sourceChatKey: String, sourceEntryID: String, selectedQuote: String) {
        self.sourceChatKey = sourceChatKey
        self.sourceEntryID = sourceEntryID
        self.selectedQuote = selectedQuote
    }
}

public struct SubConversationRecord: Codable, Equatable, Identifiable, Sendable {
    public struct Exchange: Codable, Equatable, Sendable {
        public let question: String
        public let reply: String

        public init(question: String, reply: String) {
            self.question = question
            self.reply = reply
        }
    }

    public let id: UUID
    public let origin: SubConversationOrigin
    public private(set) var inheritedPlanMode: Bool
    public private(set) var inheritedTaint: Bool
    public private(set) var taintedOut = false
    public private(set) var exchanges: [Exchange] = []
    public private(set) var promotedChatKey: String?

    public var tainted: Bool { inheritedTaint || taintedOut }

    public init(id: UUID = UUID(), origin: SubConversationOrigin, inheritedPlanMode: Bool, inheritedTaint: Bool) {
        self.id = id
        self.origin = origin
        self.inheritedPlanMode = inheritedPlanMode
        self.inheritedTaint = inheritedTaint
    }

    public mutating func inheritParent(planMode: Bool, tainted: Bool) {
        inheritedPlanMode = inheritedPlanMode || planMode
        inheritedTaint = inheritedTaint || tainted
    }

    public mutating func append(_ exchange: Exchange, tainted: Bool) {
        exchanges.append(exchange)
        taintedOut = taintedOut || tainted
    }

    public mutating func recordPromotion(to chatKey: String) -> Bool {
        guard promotedChatKey == nil || promotedChatKey == chatKey else { return false }
        promotedChatKey = chatKey
        return true
    }
}

public enum SubConversationPolicy {
    public struct Transfer: Codable, Equatable, Sendable {
        public let origin: SubConversationOrigin
        public let inheritedPlanMode: Bool
        public let tainted: Bool
        public let summary: String
    }

    public static func returnToParent(
        _ record: inout SubConversationRecord, summary: String, parentPlanMode: Bool, parentTainted: Bool
    ) -> Transfer {
        record.inheritParent(planMode: parentPlanMode, tainted: parentTainted)
        return promoteToIndependentChat(record, summary: summary)
    }

    public static func promoteToIndependentChat(_ record: SubConversationRecord, summary: String) -> Transfer {
        Transfer(origin: record.origin, inheritedPlanMode: record.inheritedPlanMode, tainted: record.tainted, summary: summary)
    }
}
