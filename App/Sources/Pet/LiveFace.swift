import UIKit

/// The companion's face made tiny enough to ride along with its Live Activity (the island has no way to read Clio's files).
@MainActor
enum LiveFace {
    private static let maxLiveBytes = 1800

    static func png(for bot: BotInfo?, side: CGFloat = 32) -> Data? {
        guard side > 0 else { return nil }
        let source: (image: CGImage, pixel: Bool, round: Bool)
        if let bot, bot.avatar == "photo", let photo = Avatars.image(bot.id)?.cgImage {
            source = (image: photo, pixel: false, round: true)
        } else {
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
            source = (image: cell, pixel: pack.pixelArt, round: false)
        }
        // Large exports (e.g. NameCard's 256pt still) are for file sharing, not ActivityKit's 4 KB payload.
        if side > 40 {
            return draw(source.image, pixel: source.pixel, round: source.round, side: side)
        }
        let start = min(side, 32)
        var candidateSides: [CGFloat] = []
        for candidate in [start, min(start, 24), min(start, 20)] where candidate > 0 {
            if !candidateSides.contains(candidate) {
                candidateSides.append(candidate)
            }
        }
        for candidate in candidateSides {
            if let data = draw(source.image, pixel: source.pixel, round: source.round, side: candidate),
               data.count <= maxLiveBytes {
                return data
            }
        }
        return nil
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
