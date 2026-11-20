import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Turns a folder of plain animations into a pet pack, on the phone: one GIF / APNG / animated WebP per state
/// (named idle.gif, thinking.gif, done.png …), or one folder of numbered PNG frames per state. What a designer hands
/// over can be imported as it is; `tools/make_pet_pack.py` does the same on a computer.
enum PetConvert {
    /// File name (lowercased, `_` as `-`) → the animation's name in the pack.
    static let roles: [String: String] = [
        "idle": "idle", "thinking": "thinking", "working": "working", "sweeping": "sweeping", "carrying": "carrying",
        "notification": "notification", "awaiting-approval": "notification", "waiting": "notification",
        "attention": "attention", "done": "attention", "happy": "attention",
        "error": "error", "sleeping": "sleeping", "waking": "waking",
        "roam": "roam", "walking": "roam", "walk": "roam",
        "react-left": "react-left", "poke-left": "react-left", "tap-left": "react-left",
        "react-right": "react-right", "poke-right": "react-right", "tap-right": "react-right",
        "tickle": "tickle", "annoyed": "annoyed", "drag": "drag", "lifted": "drag",
    ]
    static let once: Set<String> = ["attention", "error", "waking", "react-left", "react-right", "tickle", "annoyed"]

    struct Frame { var image: CGImage; var ms: Int }

    /// Builds `pack.json` and its sheets in a new folder inside `dir`; returns the pack.json.
    static func build(from dir: URL, name: String) throws -> URL {
        let fm = FileManager.default
        var root = dir
        let items = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]).filter { !$0.lastPathComponent.hasPrefix(".") && !$0.lastPathComponent.hasPrefix("__") }
        // Everything wrapped in one folder: look inside it.
        if items.count == 1, (try? items[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
           role(of: items[0]) == nil { root = items[0] }

        var anims: [String: [Frame]] = [:]
        for item in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
            guard let role = role(of: item) else { continue }
            let frames = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? folderFrames(item) : fileFrames(item)
            if !frames.isEmpty { anims[role] = Array(frames.prefix(120)) }
        }
        guard anims["idle"] != nil else {
            throw PetPack.Problem.bad("包里找不到 pack.json，也找不到 idle（空闲）动画。放每个状态一个 GIF 或 APNG，文件名用状态名，比如 idle.gif、thinking.gif。")
        }

        // One canvas for all: the largest frame; smaller ones stand bottom-centre on it.
        let width = anims.values.flatMap { $0 }.map(\.image.width).max() ?? 1
        let height = anims.values.flatMap { $0 }.map(\.image.height).max() ?? 1
        guard width <= 1024, height <= 1024 else { throw PetPack.Problem.bad("动图太大了（边长最多 1024）") }

        let out = dir.appendingPathComponent(".clio-pack", isDirectory: true)
        try? fm.removeItem(at: out)
        try fm.createDirectory(at: out, withIntermediateDirectories: true)

        var animations: [String: Any] = [:]
        var content: CGRect?
        for (key, frames) in anims {
            var laid: [(image: CGImage, box: CGRect?, ms: Int, hash: Int)] = []
            for frame in frames {
                guard let placed = place(frame.image, width: width, height: height) else { continue }
                laid.append((placed.0, placed.1, frame.ms, placed.2))
            }
            guard !laid.isEmpty else { continue }
            var union: CGRect?
            for item in laid {
                guard let one = item.box else { continue }
                union = union.map { $0.union(one) } ?? one
            }
            let box = union ?? CGRect(x: 0, y: 0, width: width, height: height)
            if key == "idle" { content = box }
            let fw = Int(box.width), fh = Int(box.height)
            // Same picture, one cell.
            var cells: [CGImage] = [], index: [Int: Int] = [:], list: [[String: Int]] = []
            for item in laid {
                if index[item.hash] == nil, let cut = item.image.cropping(to: box) {
                    index[item.hash] = cells.count
                    cells.append(cut)
                }
                list.append(["i": index[item.hash] ?? 0, "ms": item.ms])
            }
            let cols = max(1, min(cells.count, 4096 / max(fw, 1)))
            let rows = (cells.count + cols - 1) / cols
            guard rows * fh <= 4096 else { throw PetPack.Problem.bad("「\(key)」帧太多了，放不进一张图") }
            guard let sheet = CGContext(data: nil, width: cols * fw, height: rows * fh, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            for (n, cell) in cells.enumerated() {
                let col = n % cols, row = n / cols
                sheet.draw(cell, in: CGRect(x: col * fw, y: (rows - row - 1) * fh, width: fw, height: fh))
            }
            guard let made = sheet.makeImage(), let png = UIImage(cgImage: made).pngData() else { continue }
            let file = key + ".png"
            try png.write(to: out.appendingPathComponent(file))
            animations[key] = [
                "sheet": file, "frameW": fw, "frameH": fh, "cols": cols,
                "box": ["x": Int(box.minX), "y": Int(box.minY), "w": fw, "h": fh],
                "loop": !once.contains(key) && !key.hasPrefix("idle-"), "frames": list,
            ] as [String: Any]
        }

        let body = content ?? CGRect(x: 0, y: 0, width: width, height: height)
        var states: [String: [String]] = [:]
        for state in ["idle", "thinking", "working", "notification", "attention", "error", "sleeping", "waking", "sweeping", "carrying", "roam"]
        where animations[state] != nil { states[state] = [state] }
        var reactions: [String: String] = [:]
        for (file, reaction) in ["react-left": "tapLeft", "react-right": "tapRight", "tickle": "tickle", "annoyed": "annoyed", "drag": "drag"]
        where animations[file] != nil { reactions[reaction] = file }
        let pool: [[String: Any]] = animations.keys.filter { $0.hasPrefix("idle-") }.sorted().map { ["anim": $0, "weight": 1] }
        var pack: [String: Any] = [
            "schema": 1, "id": name, "name": name, "author": "", "license": "",
            "pixelArt": max(width, height) <= 256, "scale": 1,
            "canvas": ["w": width, "h": height],
            "anchor": ["x": Double(body.midX), "baseline": Double(body.maxY)],
            "contentBox": ["x": Int(body.minX), "y": Int(body.minY), "w": Int(body.width), "h": Int(body.height)],
            "animations": animations, "states": states, "reactions": reactions,
            "idlePool": ["everyMs": ["mean": 120_000, "min": 45_000, "max": 300_000], "anims": pool] as [String: Any],
            "timings": ["minDisplay": ["attention": 3000, "error": 3000, "notification": 2000], "wakeMs": 1200] as [String: Any],
            "sleep": ["afterMs": 60_000],
        ]
        if animations["roam"] != nil { pack["roam"] = ["anim": "roam", "faces": "left"] }
        let json = try JSONSerialization.data(withJSONObject: pack, options: [.prettyPrinted, .sortedKeys])
        let manifest = out.appendingPathComponent("pack.json")
        try json.write(to: manifest)
        return manifest
    }

    /// The animation a file or folder is for, from its name; nil when it is none of them.
    static func role(of url: URL) -> String? {
        let stem = url.deletingPathExtension().lastPathComponent.lowercased().replacingOccurrences(of: "_", with: "-")
        if stem.hasPrefix("idle-") { return stem }
        return roles[stem]
    }

    private static func fileFrames(_ url: URL) -> [Frame] {
        guard ["gif", "png", "apng", "webp"].contains(url.pathExtension.lowercased()),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
        let count = CGImageSourceGetCount(source)
        return (0..<min(count, 120)).compactMap { i in
            guard let image = CGImageSourceCreateImageAtIndex(source, i, nil) else { return nil }
            let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let png = props?[kCGImagePropertyPNGDictionary] as? [CFString: Any]
            let webp = props?[kCGImagePropertyWebPDictionary] as? [CFString: Any]
            let delays: [Any?] = [gif?[kCGImagePropertyGIFUnclampedDelayTime], gif?[kCGImagePropertyGIFDelayTime],
                                  png?[kCGImagePropertyAPNGUnclampedDelayTime], png?[kCGImagePropertyAPNGDelayTime],
                                  webp?[kCGImagePropertyWebPUnclampedDelayTime], webp?[kCGImagePropertyWebPDelayTime]]
            let seconds = delays.compactMap { ($0 as? NSNumber)?.doubleValue }.first { $0 > 0.01 } ?? 0.1
            return Frame(image: image, ms: max(20, Int(seconds * 1000)))
        }
    }

    private static func folderFrames(_ url: URL) -> [Frame] {
        let files = ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "png" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return files.compactMap { file in
            guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            return Frame(image: image, ms: 100)
        }
    }

    /// The frame drawn bottom-centre on the shared canvas, with the box around what is not transparent
    /// (top-left origin) and a hash of its pixels, so repeated frames share one cell.
    private static func place(_ image: CGImage, width: Int, height: Int) -> (CGImage, CGRect?, Int)? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: (width - image.width) / 2, y: 0, width: image.width, height: image.height))
        guard let bytes = context.data?.assumingMemoryBound(to: UInt8.self), let made = context.makeImage() else { return nil }
        var minX = width, minY = height, maxX = -1, maxY = -1
        var hasher = Hasher()
        for y in 0..<height {
            let row = bytes + y * width * 4
            hasher.combine(bytes: UnsafeRawBufferPointer(start: row, count: width * 4))
            for x in 0..<width where row[x * 4 + 3] > 8 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        let box = maxX < 0 ? nil : CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        return (made, box, hasher.finalize())
    }
}
