import SwiftUI

/// The pet held still: one state's first frame, for portraits, empty pages and illustrations.
/// It is always the pet picked in 宠物设置 (小克 unless you picked another), whether or not it stands on the composer.
@MainActor
struct PetStill: View {
    var size: CGFloat
    /// The pet's state to show: idle, thinking, working, notification, attention, error, sleeping …
    var state = "idle"
    /// The ground behind a portrait.
    var wash: Color?
    /// A portrait: the pet a little smaller, on a round ground.
    var avatar = false
    /// Whose portrait: a companion with a face of its own (a pet, or a photo) shows that instead of the default pet.
    var bot: BotInfo? = nil
    /// A photo not saved yet (the editor's preview).
    var photo: UIImage? = nil
    /// The editor's choice before it is saved: overrides `bot.avatar` (`.some(nil)` = the default pet).
    var face: String?? = nil

    private var look: String? {
        if let face { return face }
        return bot?.avatar
    }

    var body: some View {
        if avatar, let picture = portrait {
            Image(uiImage: picture)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
                .accessibilityHidden(true)
        } else {
            drawn
        }
    }

    private var portrait: UIImage? {
        if let photo { return photo }
        guard look == "photo", let bot else { return nil }
        return Avatars.image(bot.id)
    }

    /// This companion's pet if it has one of its own, else the one picked in 宠物设置.
    private var pack: PetPack? {
        if let chosen = look, chosen.hasPrefix("pet:") {
            let id = String(chosen.dropFirst(4))
            if let own = PetLibrary.shared.packs.first(where: { $0.id == id }) { return own }
        }
        return PetLibrary.shared.pack
    }

    private var drawn: some View {
        let inner = avatar ? size * 0.78 : size
        return content(inner)
            .frame(width: inner, height: inner)
            .frame(width: size, height: size)
            .background {
                if avatar { Circle().fill(wash ?? Ink.accentWash) }
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func content(_ inner: CGFloat) -> some View {
        if let pack,
           let name = pack.anim(for: state) ?? pack.anim(for: "idle"),
           let animation = pack.animations[name],
           let first = animation.frames.first,
           let cell = PetSheets.cell(pack, animation, first.i) {
            let ratio = animation.box.w / animation.box.h
            Image(decorative: cell, scale: 1)
                .resizable()
                .interpolation(pack.pixelArt ? .none : .high)
                .aspectRatio(ratio.isFinite && ratio > 0 ? CGFloat(ratio) : nil, contentMode: .fit)
        } else {
            // Only if no pack can be read at all.
            Image(systemName: "person.crop.circle")
                .resizable()
                .scaledToFit()
                .foregroundStyle(Ink.inkFaint)
                .padding(inner * 0.12)
        }
    }
}


/// Companions' photos, kept on this phone only (never in the repository, never sent anywhere): a square JPEG each.
enum Avatars {
    private static let cache = NSCache<NSString, UIImage>()

    static func url(_ id: String) -> URL {
        let folder = Disk.root.appendingPathComponent("avatars", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("\(id).jpg")
    }

    static func image(_ id: String) -> UIImage? {
        if let hit = cache.object(forKey: id as NSString) { return hit }
        guard let data = try? Data(contentsOf: url(id)), let picture = UIImage(data: data) else { return nil }
        cache.setObject(picture, forKey: id as NSString)
        return picture
    }

    /// Cut to a square from the middle, 512 points across, and kept.
    static func save(_ picture: UIImage, for id: String) {
        let side = min(picture.size.width, picture.size.height)
        guard side > 0 else { return }
        let target = CGSize(width: 512, height: 512)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let square = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            let scale = 512 / side
            let drawn = CGSize(width: picture.size.width * scale, height: picture.size.height * scale)
            picture.draw(in: CGRect(x: (512 - drawn.width) / 2, y: (512 - drawn.height) / 2, width: drawn.width, height: drawn.height))
        }
        try? square.jpegData(compressionQuality: 0.85)?.write(to: url(id), options: .atomic)
        cache.setObject(square, forKey: id as NSString)
    }

    static func forget(_ id: String) {
        try? FileManager.default.removeItem(at: url(id))
        cache.removeObject(forKey: id as NSString)
    }
}
