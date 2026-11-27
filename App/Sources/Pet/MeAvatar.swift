import PhotosUI
import SwiftUI

/// Your own face in the conversation: a character (「我」 until you pick), one of the pets, or a photo from 相册.
/// Tap it to change; kept on this phone (`Avatars`, under the id "me").
struct MeAvatar: View {
    var size: CGFloat = 32
    @AppStorage("me.avatar") private var face = ""
    @State private var choosing = false
    @State private var item: PhotosPickerItem?
    /// Bumped when a new photo is kept, so it is drawn again.
    @State private var version = 0

    var body: some View {
        Menu {
            Button { face = "" } label: { choice("用一个字「我」", picked: face.isEmpty) }
            ForEach(PetLibrary.shared.packs, id: \.id) { pack in
                Button { face = "pet:\(pack.id)" } label: { choice(pack.name, picked: face == "pet:\(pack.id)") }
            }
            Button { choosing = true } label: { Label("从相册选一张", systemImage: "photo") }
        } label: {
            portrait.id(version)
        }
        .accessibilityLabel("我的头像，点一下换")
        .photosPicker(isPresented: $choosing, selection: $item, matching: .images)
        .onChange(of: item) { _, picked in
            guard let picked else { return }
            Task {
                if let data = try? await picked.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    Avatars.save(image, for: "me")
                    face = "photo"
                    version += 1
                }
                item = nil
            }
        }
    }

    @ViewBuilder
    private var portrait: some View {
        if face == "photo", let photo = Avatars.image("me") {
            Image(uiImage: photo).resizable().scaledToFill().frame(width: size, height: size).clipShape(Circle())
        } else if face.hasPrefix("pet:") {
            CompanionAvatar(size: size, face: .some(face), name: "我")
        } else {
            Text("我")
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(Ink.paper)
                .frame(width: size, height: size)
                .background(Ink.accent.gradient, in: .circle)
        }
    }

    @ViewBuilder
    private func choice(_ title: String, picked: Bool) -> some View {
        if picked { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
}
