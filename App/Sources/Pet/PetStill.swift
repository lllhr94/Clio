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

    var body: some View {
        let inner = avatar ? size * 0.78 : size
        content(inner)
            .frame(width: inner, height: inner)
            .frame(width: size, height: size)
            .background {
                if avatar { Circle().fill(wash ?? Ink.accentWash) }
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func content(_ inner: CGFloat) -> some View {
        if let pack = PetLibrary.shared.pack,
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
