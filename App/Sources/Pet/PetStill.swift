import Observation
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

    private var avatarPhotoLoadID: String? {
        guard avatar, photo == nil, look == "photo", let id = bot?.id else { return nil }
        return Avatars.cachedImage(id) == nil && !Avatars.isKnownMissing(id) ? id : nil
    }

    var body: some View {
        Group {
            if avatar, let picture = portrait {
                Image(uiImage: picture)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                    .accessibilityHidden(true)
            } else if avatar, photo == nil, look == "photo", let id = bot?.id, !Avatars.isKnownMissing(id) {
                Circle()
                    .fill(wash ?? Ink.accentWash)
                    .frame(width: size, height: size)
                    .accessibilityHidden(true)
            } else {
                drawn
            }
        }
        .task(id: avatarPhotoLoadID) {
            guard let id = avatarPhotoLoadID else { return }
            await Avatars.loadAsync(id)
        }
    }

    private var portrait: UIImage? {
        if let photo { return photo }
        guard look == "photo", let bot else { return nil }
        _ = Avatars.revision
        return Avatars.cachedImage(bot.id)
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
           let first = animation.frames.first {
            if let cell = PetSheets.cell(pack, animation, first.i, maxPixelSize: nil, forPlayback: false, deferLargeSheet: true) {
                let ratio = animation.box.w / animation.box.h
                Image(decorative: cell, scale: 1)
                    .resizable()
                    .interpolation(pack.pixelArt ? .none : .high)
                    .aspectRatio(ratio.isFinite && ratio > 0 ? CGFloat(ratio) : nil, contentMode: .fit)
            } else if PetSheets.isDecodingLargeSheet(pack, animation) {
                Color.clear
            } else {
                Image(systemName: "person.crop.circle")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Ink.inkFaint)
                    .padding(inner * 0.12)
            }
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
    @MainActor @Observable
    private final class Signal {
        var revision: UInt64 = 0
    }

    @MainActor private static let signal = Signal()
    @MainActor static var revision: UInt64 { signal.revision }

    private static let cache = NSCache<NSString, UIImage>()
    private static let folder: URL = Disk.root.appendingPathComponent("avatars", isDirectory: true)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var missingIDs: Set<String> = []
    nonisolated(unsafe) private static var inFlightIDs: Set<String> = []
    nonisolated(unsafe) private static var generations: [String: UInt64] = [:]

    static func url(_ id: String) -> URL {
        folder.appendingPathComponent("\(id).jpg")
    }

    private static func ensureFolder() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    static func cachedImage(_ id: String) -> UIImage? {
        cache.object(forKey: id as NSString)
    }

    static func isKnownMissing(_ id: String) -> Bool {
        lock.withLock { missingIDs.contains(id) }
    }

    static func image(_ id: String) -> UIImage? {
        if let hit = cache.object(forKey: id as NSString) { return hit }
        if lock.withLock({ missingIDs.contains(id) }) { return nil }
        let expectedGen = lock.withLock { generations[id, default: 0] }
        guard let data = try? Data(contentsOf: url(id)), let raw = UIImage(data: data) else {
            lock.withLock {
                if generations[id, default: 0] == expectedGen {
                    missingIDs.insert(id)
                }
            }
            return nil
        }
        let prepared = raw.preparingForDisplay() ?? raw
        lock.withLock {
            if generations[id, default: 0] == expectedGen {
                missingIDs.remove(id)
                cache.setObject(prepared, forKey: id as NSString)
            }
        }
        return prepared
    }

    static func loadAsync(_ id: String) async {
        if cache.object(forKey: id as NSString) != nil { return }
        let expectedGen: UInt64? = lock.withLock {
            if missingIDs.contains(id) || inFlightIDs.contains(id) { return nil }
            inFlightIDs.insert(id)
            return generations[id, default: 0]
        }
        guard let expectedGen else { return }
        let fileURL = url(id)
        let loaded: UIImage? = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: fileURL),
                  let raw = UIImage(data: data) else { return nil }
            return raw.preparingForDisplay() ?? raw
        }.value
        let committed: Bool = lock.withLock {
            inFlightIDs.remove(id)
            guard generations[id, default: 0] == expectedGen else { return false }
            if let loaded {
                missingIDs.remove(id)
                cache.setObject(loaded, forKey: id as NSString)
            } else {
                missingIDs.insert(id)
            }
            return true
        }
        if committed {
            await MainActor.run { signal.revision &+= 1 }
        }
    }

    /// Cut to a square from the middle, 512 points across, and kept.
    static func save(_ picture: UIImage, for id: String) {
        let side = min(picture.size.width, picture.size.height)
        guard side > 0 else { return }
        ensureFolder()
        let target = CGSize(width: 512, height: 512)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let square = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            let scale = 512 / side
            let drawn = CGSize(width: picture.size.width * scale, height: picture.size.height * scale)
            picture.draw(in: CGRect(x: (512 - drawn.width) / 2, y: (512 - drawn.height) / 2, width: drawn.width, height: drawn.height))
        }
        try? square.jpegData(compressionQuality: 0.85)?.write(to: url(id), options: .atomic)
        let prepared = square.preparingForDisplay() ?? square
        lock.withLock {
            generations[id, default: 0] &+= 1
            missingIDs.remove(id)
            cache.setObject(prepared, forKey: id as NSString)
        }
        bumpRevision()
    }

    static func forget(_ id: String) {
        try? FileManager.default.removeItem(at: url(id))
        lock.withLock {
            generations[id, default: 0] &+= 1
            cache.removeObject(forKey: id as NSString)
            missingIDs.insert(id)
        }
        bumpRevision()
    }

    private static func bumpRevision() {
        if Thread.isMainThread {
            MainActor.assumeIsolated { signal.revision &+= 1 }
        } else {
            Task { @MainActor in signal.revision &+= 1 }
        }
    }
}
