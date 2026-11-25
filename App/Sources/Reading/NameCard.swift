import CoreTransferable
import Foundation
import UIKit
import UniformTypeIdentifiers

/// Lazy `Transferable` wrapper so `ShareLink` only builds and writes the `.名帖.json` file when shared.
struct NameCardTransfer: Transferable, Sendable {
    let bot: BotInfo

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { item in
            let url = await MainActor.run { NameCard.file(for: item.bot) }
            return SentTransferredFile(url)
        }
    }
}

/// 名帖: a companion as a small file — who it is and how it talks — to keep, or to hand to someone.
struct NameCard: Codable {
    var kind = "clio.namecard"
    var version = 1
    var name: String
    var role: String?
    var instructions: String?
    var color: String?
    /// Version 2: 性格, 说话风格, 朱印字 and the face (a pet id, or a small photo). Never anything it remembers.
    var temper: String?
    var style: String?
    var seal: String?
    var pet: String?
    var photo: Data?
    /// The pet held still, for a phone that doesn't have that pet: it becomes the face there.
    var petStill: Data?

    @MainActor
    init(_ bot: BotInfo) {
        version = 2
        name = bot.name
        role = bot.role
        instructions = bot.instructions
        color = bot.color
        temper = bot.temper
        style = bot.style
        seal = bot.seal
        if bot.avatar == "photo" {
            photo = Avatars.image(bot.id)?.jpegData(compressionQuality: 0.8)
        } else if let face = bot.avatar, face.hasPrefix("pet:") {
            pet = face
            petStill = LiveFace.png(for: bot, side: 256)
        }
    }

    /// Writes the card where it can be shared from, and returns the file.
    @MainActor
    static func file(for bot: BotInfo) -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("名帖", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safe = bot.name.replacingOccurrences(of: "/", with: "-")
        let url = folder.appendingPathComponent("\(safe).名帖.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(NameCard(bot)) { try? data.write(to: url, options: .atomic) }
        return url
    }

    /// Reads a card from a file the user picked.
    static func read(_ url: URL) throws -> NameCard {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard let card = try? JSONDecoder().decode(NameCard.self, from: data), card.kind == "clio.namecard",
              !card.name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw TeamError(message: Words.t("这不是一张 Clio 的名帖。"))
        }
        return card
    }
}
