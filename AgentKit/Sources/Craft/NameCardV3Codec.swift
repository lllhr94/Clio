import Foundation

public enum NameCardV3Codec: Sendable {
    public static let schemaVersion = 3
    public static let maxFileBytes = 2 * 1024 * 1024
    public static let maxAvatarBytes = 512 * 1024
    public static let maxAvatarPixels = 256
    public static let maxShortFieldBytes = 1024
    public static let maxTextBytes = 64 * 1024

    public struct Card: Codable, Equatable, Sendable {
        public var kind = "clio.namecard"
        public var version = NameCardV3Codec.schemaVersion
        public var name: String
        public var role: String?
        public var instructions: String?
        public var color: String?
        public var temper: String?
        public var style: String?
        public var seal: String?
        public var pet: String?
        public var photo: Data?
        public var petStill: Data?
        public var relationship: String?
        public var expressionStyle: String?
        public var antiSlop: Bool?
        public var firstPersonThoughts: Bool?
        public var expertiseBoundary: String?
        public var privateNotes: String?
        public var publicAgentsCard: String?

        public init(name: String) { self.name = name }
    }

    public enum InvalidCard: Error, Equatable, Sendable {
        case invalidIdentity
        case unsupportedVersion(Int)
        case fieldTooLarge
        case avatarTooLarge
        case fileTooLarge
    }

    public static func decode(_ data: Data) throws -> Card {
        guard data.count <= maxFileBytes else { throw InvalidCard.fileTooLarge }
        let card = try JSONDecoder().decode(Card.self, from: data)
        try validate(card)
        return projected(card, version: card.version, includePrivateNotes: true)
    }

    public static func encodeV3(_ card: Card, includePrivateNotes: Bool = false) throws -> Data {
        try encode(card, version: schemaVersion, includePrivateNotes: includePrivateNotes)
    }

    public static func encode(_ card: Card, version: Int, includePrivateNotes: Bool = false) throws -> Data {
        let export = projected(card, version: version, includePrivateNotes: includePrivateNotes)
        try validate(export)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(export)
        guard data.count <= maxFileBytes else { throw InvalidCard.fileTooLarge }
        return data
    }

    private static func projected(_ card: Card, version: Int, includePrivateNotes: Bool) -> Card {
        var result = card
        result.version = version
        if version < 2 {
            result.temper = nil
            result.style = nil
            result.seal = nil
            result.pet = nil
            result.photo = nil
            result.petStill = nil
        }
        if version < 3 {
            result.relationship = nil
            result.expressionStyle = nil
            result.antiSlop = nil
            result.firstPersonThoughts = nil
            result.expertiseBoundary = nil
            result.publicAgentsCard = nil
        }
        if version < 3 || !includePrivateNotes { result.privateNotes = nil }
        return result
    }

    private static func validate(_ card: Card) throws {
        guard card.kind == "clio.namecard", !card.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InvalidCard.invalidIdentity
        }
        guard (1...schemaVersion).contains(card.version) else { throw InvalidCard.unsupportedVersion(card.version) }
        let short = [card.name, card.role, card.color, card.temper, card.style, card.seal, card.pet]
        let long = [card.instructions, card.relationship, card.expressionStyle, card.expertiseBoundary, card.privateNotes, card.publicAgentsCard]
        guard short.allSatisfy({ ($0?.utf8.count ?? 0) <= maxShortFieldBytes }),
              long.allSatisfy({ ($0?.utf8.count ?? 0) <= maxTextBytes }) else { throw InvalidCard.fieldTooLarge }
        guard [card.photo, card.petStill].allSatisfy({ ($0?.count ?? 0) <= maxAvatarBytes }) else {
            throw InvalidCard.avatarTooLarge
        }
    }
}
