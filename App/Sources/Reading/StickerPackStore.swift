import Craft
import Foundation
import UIKit

/// User-imported custom sticker pack store rooted at Canonical `Team/stickers/` + `index.json`.
/// Ships with ZERO bundled/preset sticker packs; strictly limited to Casual Track (max 1 per turn).
@MainActor
final class StickerPackStore: ObservableObject {
    struct StickerItem: Codable, Equatable, Hashable, Identifiable, Sendable {
        var id: String
        var label: String
        var filename: String
        var addedAtMs: Double
    }

    struct StickerPack: Codable, Equatable, Hashable, Identifiable, Sendable {
        var id: String
        var name: String
        var items: [StickerItem]
        var createdAtMs: Double
    }

    private struct IndexFile: Codable {
        var version: Int = 1
        var packs: [StickerPack] = []
    }

    static let shared = StickerPackStore()

    @Published private(set) var packs: [StickerPack] = []
    private let rootDir: URL
    private let indexURL: URL

    init(teamDirectory: URL? = nil) {
        let base = teamDirectory ?? Disk.root
        self.rootDir = base.appendingPathComponent("stickers", isDirectory: true)
        self.indexURL = rootDir.appendingPathComponent("index.json")
        reload()
    }

    func reload() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode(IndexFile.self, from: data) else {
            // Ships strictly with 0 preset packs.
            packs = []
            return
        }
        packs = decoded.packs
    }

    @discardableResult
    func createPack(name: String) -> StickerPack {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let pack = StickerPack(
            id: "pack-\(UUID().uuidString.lowercased())",
            name: trimmed.isEmpty ? "我的表情" : trimmed,
            items: [],
            createdAtMs: Now.ms
        )
        packs.append(pack)
        persistIndex()
        return pack
    }

    @discardableResult
    func importSticker(imageData: Data, label: String, into packID: String) -> StickerItem? {
        guard let idx = packs.firstIndex(where: { $0.id == packID }),
              let image = UIImage(data: imageData) else { return nil }
        let resized = downscaleSticker(image, maxSide: 320)
        guard let png = resized.pngData() else { return nil }
        let itemID = "stk-\(UUID().uuidString.lowercased())"
        let filename = "\(itemID).png"
        try? FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        let fileURL = rootDir.appendingPathComponent(filename)
        guard (try? png.write(to: fileURL, options: .atomic)) != nil else { return nil }
        let item = StickerItem(
            id: itemID,
            label: label.trimmingCharacters(in: .whitespacesAndNewlines),
            filename: filename,
            addedAtMs: Now.ms
        )
        packs[idx].items.append(item)
        persistIndex()
        return item
    }

    func removeSticker(itemID: String, from packID: String) {
        guard let pIdx = packs.firstIndex(where: { $0.id == packID }),
              let iIdx = packs[pIdx].items.firstIndex(where: { $0.id == itemID }) else { return }
        let item = packs[pIdx].items.remove(at: iIdx)
        try? FileManager.default.removeItem(at: rootDir.appendingPathComponent(item.filename))
        persistIndex()
    }

    func removePack(packID: String) {
        guard let pIdx = packs.firstIndex(where: { $0.id == packID }) else { return }
        let removed = packs.remove(at: pIdx)
        for item in removed.items {
            try? FileManager.default.removeItem(at: rootDir.appendingPathComponent(item.filename))
        }
        persistIndex()
    }

    func image(for itemID: String) -> UIImage? {
        for pack in packs {
            if let item = pack.items.first(where: { $0.id == itemID }) {
                let url = rootDir.appendingPathComponent(item.filename)
                if let data = try? Data(contentsOf: url) {
                    return UIImage(data: data)
                }
            }
        }
        return nil
    }

    private func persistIndex() {
        try? FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        let index = IndexFile(version: 1, packs: packs)
        if let data = try? JSONEncoder().encode(index) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    private func downscaleSticker(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxSide, longest > 0 else { return image }
        let scale = maxSide / longest
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let renderer = UIGraphicsImageRenderer(size: target)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
