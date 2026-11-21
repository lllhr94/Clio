import UIKit

/// The companion's face made tiny enough to ride along with its Live Activity (the island has no way to read Clio's files).
@MainActor
enum LiveFace {
    static func png(for bot: BotInfo?, side: CGFloat = 40) -> Data? {
        if let bot, bot.avatar == "photo", let photo = Avatars.image(bot.id)?.cgImage {
            return draw(photo, pixel: false, round: true, side: side)
        }
        var pack = PetLibrary.shared.pack
        if let face = bot?.avatar, face.hasPrefix("pet:"),
           let own = PetLibrary.shared.packs.first(where: { $0.id == String(face.dropFirst(4)) }) {
            pack = own
        }
        guard let pack,
              let name = pack.anim(for: "working") ?? pack.anim(for: "idle"),
              let animation = pack.animations[name],
              let first = animation.frames.first,
              let cell = PetSheets.cell(pack, animation, first.i) else { return nil }
        return draw(cell, pixel: pack.pixelArt, round: false, side: side)
    }

    private static func draw(_ image: CGImage, pixel: Bool, round: Bool, side: CGFloat) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let box = CGSize(width: side, height: side)
        let picture = UIGraphicsImageRenderer(size: box, format: format).image { context in
            context.cgContext.interpolationQuality = pixel ? .none : .high
            let width = CGFloat(image.width), height = CGFloat(image.height)
            guard width > 0, height > 0 else { return }
            // A photo fills the circle; a pet fits whole.
            let scale = round ? max(side / width, side / height) : min(side / width, side / height)
            let size = CGSize(width: width * scale, height: height * scale)
            if round { UIBezierPath(ovalIn: CGRect(origin: .zero, size: box)).addClip() }
            UIImage(cgImage: image).draw(in: CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
        }
        return picture.pngData()
    }
}
