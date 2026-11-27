import SwiftUI
import UIKit

@MainActor
struct CompanionAvatar: View {
    var size: CGFloat
    var state = "idle"
    var wash: Color?
    var bot: BotInfo?
    var photo: UIImage?
    var face: String?? = nil
    var name: String? = nil
    var seal: String? = nil

    private var choice: String? { face ?? bot?.avatar }
    private var color: Color { wash ?? bot.map { Ink.wash(for: $0) } ?? Ink.accentWash }
    private var photoID: String? { choice == "photo" && photo == nil ? bot?.id : nil }

    var body: some View {
        let _ = Avatars.revision
        Group {
            if let picture = photo ?? photoID.flatMap(Avatars.cachedImage) {
                Image(uiImage: picture)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else if let pack = Self.legacyPack(for: choice) {
                PetStill(size: size, state: state, wash: color, avatar: true, explicitPack: pack)
            } else {
                Text(Self.character(name: name ?? bot?.name, seal: seal ?? bot?.seal))
                    .font(Ink.mark(size * 0.52, bold: true))
                    .foregroundStyle(Ink.ink)
                    .frame(width: size, height: size)
                    .background(color, in: Circle())
            }
        }
        .accessibilityHidden(true)
        .task(id: photoID) {
            if let photoID { await Avatars.loadAsync(photoID) }
        }
    }

    static func character(name: String?, seal: String?) -> String {
        let character = seal?.trimmingCharacters(in: .whitespacesAndNewlines).first
            ?? name?.trimmingCharacters(in: .whitespacesAndNewlines).first
        return character.map { String($0) } ?? "·"
    }

    static func legacyPack(for face: String?) -> PetPack? {
        guard let face, face.hasPrefix("pet:") else { return nil }
        let id = String(face.dropFirst(4))
        return PetLibrary.shared.packs.first { $0.id == id }
    }

    static func legacyFrame(for face: String?, state: String = "idle") -> (image: UIImage, pixelArt: Bool)? {
        guard let pack = legacyPack(for: face),
              let name = pack.anim(for: state) ?? pack.anim(for: "idle"),
              let animation = pack.animations[name], let first = animation.frames.first,
              let cell = PetSheets.cell(pack, animation, first.i) else { return nil }
        return (UIImage(cgImage: cell), pack.pixelArt)
    }
}
