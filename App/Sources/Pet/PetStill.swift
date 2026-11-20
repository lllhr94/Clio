import SwiftUI

/// A pack's first frame for portraits and illustrations, with the existing figure as a fallback.
@MainActor
struct PetStill: View {
    var size: CGFloat
    var state = "idle"
    var pose: WhalePose = .idle
    var wash: Color?
    var tone: Color?
    var still = false
    var avatar = false

    var body: some View {
        if let pack = PetLibrary.shared.pack,
           let name = pack.anim(for: state),
           let animation = pack.animations[name],
           let first = animation.frames.first,
           let cell = PetSheets.cell(pack, animation, first.i) {
            sprite(cell, animation: animation, pixelArt: pack.pixelArt)
        } else {
            Whale(size: size, pose: pose, wash: wash, tone: tone, still: still)
        }
    }

    private func sprite(_ cell: CGImage, animation: PetPack.Anim, pixelArt: Bool) -> some View {
        let ratio = animation.box.w / animation.box.h
        let inner = avatar ? size * 0.78 : size
        return Image(decorative: cell, scale: 1)
            .resizable()
            .interpolation(pixelArt ? .none : .high)
            .aspectRatio(ratio.isFinite && ratio > 0 ? CGFloat(ratio) : nil, contentMode: .fit)
            .frame(width: inner, height: inner)
            .frame(width: size, height: size)
            .background {
                if avatar {
                    Circle().fill(wash ?? Ink.accentWash)
                }
            }
            .accessibilityHidden(true)
    }
}
