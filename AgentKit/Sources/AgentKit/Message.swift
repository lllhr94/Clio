import Foundation

public struct ImagePart: Codable, Hashable, Sendable {
    public var mediaType: String
    public var data: Data

    public init(mediaType: String = "image/jpeg", data: Data) {
        self.mediaType = mediaType
        self.data = data
    }
}

public struct ToolCall: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// The arguments as the model wrote them: JSON text.
    public var arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// Immutable contract-bound protocol continuation payload, strictly decoupled from public display `reasoning`.
/// Even if a user later edits the same endpoint ID to a different origin/protocol/route, or switches speaker
/// in a gathering, contract validation prevents cross-origin, cross-protocol, or cross-speaker replay.
public struct ProtocolContinuationPayload: Codable, Equatable, Hashable, Sendable {
    public var origin: String
    public var protocolKind: String
    public var route: String
    public var modelID: String
    public var ruleGeneration: UInt64
    public var speakerOrThreadID: String?
    public var responseItemID: String?
    /// Wire kind identifier (e.g. `"anthropic_thinking"`, `"anthropic_redacted_thinking"`,
    /// `"openai_reasoning_content"`, `"responses_reasoning_item"`).
    public var wireKind: String
    public var blockOrder: Int
    /// Opaque protocol payload (signature, redacted blob, encrypted reasoning item, or exact wire thought).
    public var opaqueData: String
    public var toolCallRefs: [String]
    /// Scope over which this payload may be projected (`"turn"`, `"session"`, `"stateless_item"`).
    public var validScope: String
    public var taint: Bool

    public init(
        origin: String,
        protocolKind: String,
        route: String,
        modelID: String,
        ruleGeneration: UInt64 = 1,
        speakerOrThreadID: String? = nil,
        responseItemID: String? = nil,
        wireKind: String,
        blockOrder: Int = 0,
        opaqueData: String,
        toolCallRefs: [String] = [],
        validScope: String = "turn",
        taint: Bool = false
    ) {
        self.origin = EndpointContractKey.normalizeOrigin(origin)
        self.protocolKind = protocolKind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.route = EndpointContractKey.normalizeRoute(route)
        self.modelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.ruleGeneration = ruleGeneration
        self.speakerOrThreadID = speakerOrThreadID
        self.responseItemID = responseItemID
        self.wireKind = wireKind
        self.blockOrder = blockOrder
        self.opaqueData = opaqueData
        self.toolCallRefs = toolCallRefs
        self.validScope = validScope
        self.taint = taint
    }

    public var contractKey: EndpointContractKey {
        EndpointContractKey(origin: origin, protocolKind: protocolKind, route: route, modelID: modelID)
    }

    /// Validates immutable contract identity and optional speaker/thread isolation before wire projection.
    public func isCompatible(with target: EndpointContractKey, speakerOrThreadID targetSpeaker: String? = nil) -> Bool {
        guard contractKey.matches(target) else { return false }
        if let ownSpeaker = speakerOrThreadID, let targetSpeaker, ownSpeaker != targetSpeaker {
            return false
        }
        return true
    }
}

/// Result of verifying whether a target protocol can safely project a message's reasoning continuation.
public enum ContinuationProjectionStatus: Equatable, Sendable {
    case compatible
    case notRequired
    /// Target protocol mandates intact reasoning continuation, but compatible authorized payload is missing/mismatched.
    /// Providers MUST enter explicit non-continuable state rather than forging signatures or replaying public summaries.
    case missingOrIncompatible(reason: String)
}

/// One message of a conversation, in a shape every provider can be written from.
public struct Message: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable { case user, assistant, tool }

    public var role: Role
    public var text: String
    public var images: [ImagePart]
    /// Opaque names for tool images saved by the host. Older transcripts do not have this field.
    public var mediaReferences: [String]?
    /// The tool that originally supplied a reopened image.
    public var mediaSourceTool: String?
    /// Public thinking text shown to the user (decoupled from protocol continuation payloads).
    public var reasoning: String?
    /// Legacy Claude signature over `reasoning` (kept for backward compatibility with older transcripts).
    public var reasoningSignature: String?
    /// Immutable contract-bound continuation payloads (signed thinking, redacted blobs, Responses reasoning items).
    public var continuationPayloads: [ProtocolContinuationPayload]?
    /// An assistant message's tool calls.
    public var toolCalls: [ToolCall]
    /// A tool message: the call it answers.
    public var toolCallId: String?
    public var toolName: String?
    public var isError: Bool
    /// For the person only: kept with the chat, never sent to a model (a changed file's full comparison).
    public var detail: String?

    public init(
        role: Role,
        text: String,
        images: [ImagePart] = [],
        reasoning: String? = nil,
        toolCalls: [ToolCall] = [],
        toolCallId: String? = nil,
        toolName: String? = nil,
        isError: Bool = false,
        continuationPayloads: [ProtocolContinuationPayload]? = nil
    ) {
        self.role = role
        self.text = text
        self.images = images
        self.reasoning = reasoning
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.isError = isError
        self.continuationPayloads = continuationPayloads
    }

    public static func user(_ text: String, images: [ImagePart] = []) -> Message {
        Message(role: .user, text: text, images: images)
    }

    public static func assistant(_ text: String, toolCalls: [ToolCall] = [], reasoning: String? = nil) -> Message {
        Message(role: .assistant, text: text, reasoning: reasoning, toolCalls: toolCalls)
    }

    public static func toolResult(_ text: String, for call: ToolCall, isError: Bool = false) -> Message {
        Message(role: .tool, text: text, toolCallId: call.id, toolName: call.name, isError: isError)
    }
}
