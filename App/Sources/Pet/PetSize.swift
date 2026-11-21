import Foundation

/// A percentage of a 48-point body. Pixel pets use distinct, whole device-pixel steps.
enum PetSize {
    static let standardHeight: CGFloat = 48
    static let marks: [Double] = [0.34, 0.65, 0.82, 1, 1.34, 1.67, 2, 2.34, 2.67, 3]

    static func migrated(_ style: String?, custom: Double, uiScale: CGFloat) -> Double {
        let old: Double
        switch style {
        case "small": old = 0.75
        case "standard": old = 1
        case "large": old = 1.35
        case "custom": old = custom.isFinite ? min(3, max(0.5, custom)) : 1
        default: return 1
        }
        return Double(30 * uiScale / standardHeight) * old
    }

    static func unit(for pack: PetPack, factor: Double, displayScale: CGFloat,
                     maxWidth: CGFloat = .infinity, maxHeight: CGFloat = .infinity) -> CGFloat {
        let wanted = standardHeight * CGFloat(factor) / CGFloat(pack.content.h)
        let cap = min(maxWidth / CGFloat(pack.canvasW), maxHeight / CGFloat(pack.canvasH))
        guard pack.pixelArt else { return min(wanted, cap) }
        let density = displayScale / CGFloat(pack.scale)
        let desiredPixels = wanted * density
        let limit = cap * density
        let nativeBody = CGFloat(pack.content.h) / density
        if limit >= 1, desiredPixels >= 1 || nativeBody <= standardHeight {
            return min(max(1, desiredPixels.rounded()), limit.rounded(.down)) / density
        }
        // Pixel packs can also contain a large sprite. Reduce those when 1:1
        // exceeds the requested size or the viewport, using whole source-pixel groups.
        let preferredDivisor = (1 / max(0.001, desiredPixels)).rounded()
        let minimumDivisor = (1 / max(0.001, limit)).rounded(.up)
        return 1 / (max(1, preferredDivisor, minimumDivisor) * density)
    }

    static func levels(for pack: PetPack?, displayScale: CGFloat) -> [Double] {
        guard let pack, pack.pixelArt else { return marks }
        var levels: [Double] = []
        for mark in marks {
            let scale = unit(for: pack, factor: mark, displayScale: displayScale, maxHeight: standardHeight * 3)
            let effective = Double(scale * CGFloat(pack.content.h) / standardHeight)
            if levels.last != effective { levels.append(effective) }
        }
        return levels
    }

    static func nearest(_ value: Double, in levels: [Double]) -> Int {
        levels.indices.min { abs(levels[$0] - value) < abs(levels[$1] - value) } ?? 0
    }
}
