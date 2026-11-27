import CoreTransferable
import Craft
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Lazy export for share menus that use the default privacy setting.
struct NameCardTransfer: Transferable, Sendable {
    let bot: BotInfo

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { item in
            let url = try await NameCard.file(for: item.bot)
            return SentTransferredFile(url)
        }
    }
}

enum NameCard {
    @MainActor
    static func data(for bot: BotInfo, includePrivateNotes: Bool = false) throws -> Data {
        var card = NameCardV3Codec.Card(name: bot.name)
        card.role = bot.role
        card.instructions = bot.instructions
        card.color = bot.color
        card.temper = bot.temper
        card.style = bot.style
        card.seal = bot.seal
        card.relationship = bot.relationship
        card.expressionStyle = bot.expressionStyle
        card.antiSlop = bot.antiSlop
        card.firstPersonThoughts = bot.firstPersonThoughts
        card.expertiseBoundary = bot.expertiseBoundary
        card.privateNotes = bot.privateNotes
        card.publicAgentsCard = bot.publicAgentsCard
        if bot.avatar == "photo", let photo = Avatars.image(bot.id) {
            card.photo = resizedAvatar(photo)
        } else if let face = bot.avatar, face.hasPrefix("pet:") {
            card.pet = face
            if CompanionAvatar.legacyPack(for: face) != nil {
                card.petStill = LiveFace.png(for: bot, side: CGFloat(NameCardV3Codec.maxAvatarPixels))
            }
        }
        return try NameCardV3Codec.encodeV3(card, includePrivateNotes: includePrivateNotes)
    }

    @MainActor
    static func resizedAvatar(_ photo: UIImage) -> Data? {
        let largest = max(photo.size.width, photo.size.height)
        guard largest.isFinite, largest > 0 else { return nil }
        let scale = min(1, CGFloat(NameCardV3Codec.maxAvatarPixels) / largest)
        let size = CGSize(width: max(1, floor(photo.size.width * scale)), height: max(1, floor(photo.size.height * scale)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            photo.draw(in: CGRect(origin: .zero, size: size))
        }
        return image.jpegData(compressionQuality: 0.8)
    }

    static func importedAvatar(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: NameCardV3Codec.maxAvatarPixels
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    /// Each share gets a distinct URL so a private export cannot overwrite an earlier public share.
    @MainActor
    static func file(for bot: BotInfo, includePrivateNotes: Bool = false) throws -> URL {
        let data = try data(for: bot, includePrivateNotes: includePrivateNotes)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safe = String(bot.name.prefix(48)).replacingOccurrences(of: "/", with: "-")
        let url = folder.appendingPathComponent(safe + ".名帖.json")
        try data.write(to: url, options: .atomic)
        return url
    }

    static func read(_ url: URL) throws -> NameCardV3Codec.Card {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let bytes = try file.read(upToCount: NameCardV3Codec.maxFileBytes + 1) ?? Data()
            return try NameCardV3Codec.decode(bytes)
        } catch {
            throw TeamError(message: Words.t("这不是一张有效的 Clio 名帖，或文件超出大小限制。"))
        }
    }
}
