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

    private struct FrameRef {
        var url: URL
        var index: Int
        var ms: Int
    }

    private static let noCache: CFDictionary = [kCGImageSourceShouldCache: false] as CFDictionary

    /// Builds `pack.json` and its sheets in a new folder inside `dir`; returns the pack.json.
    static func build(from dir: URL, name: String) throws -> URL {
        let fm = FileManager.default
        var root = dir
        let items = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { !$0.lastPathComponent.hasPrefix(".") && !$0.lastPathComponent.hasPrefix("__") }
        // Everything wrapped in one folder: look inside it.
        if items.count == 1, (try? items[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
           role(of: items[0]) == nil { root = items[0] }

        // Pass 1: inspect image headers only (zero bitmap allocation) to enforce pixel budget and compute shared canvas size.
        var specs: [String: [FrameRef]] = [:]
        var pixelsLeft = 32 * 1024 * 1024
        var maxWidth = 1
        var maxHeight = 1
        for item in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
            guard let role = role(of: item) else { continue }
            let refs: [FrameRef]
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                refs = try inspectFolder(item, pixelsLeft: &pixelsLeft, maxWidth: &maxWidth, maxHeight: &maxHeight)
            } else {
                refs = try inspectFile(item, pixelsLeft: &pixelsLeft, maxWidth: &maxWidth, maxHeight: &maxHeight)
            }
            if !refs.isEmpty { specs[role] = Array(refs.prefix(120)) }
        }
        guard specs["idle"] != nil else {
            throw PetPack.Problem.bad("包里找不到 pack.json，也找不到 idle（空闲）动画。放每个状态一个 GIF 或 APNG，文件名用状态名，比如 idle.gif、thinking.gif。")
        }
        let width = maxWidth
        let height = maxHeight
        guard width <= 1024, height <= 1024 else { throw PetPack.Problem.bad("动图太大了（边长最多 1024）") }

        let out = dir.appendingPathComponent(".clio-pack", isDirectory: true)
        try? fm.removeItem(at: out)
        try fm.createDirectory(at: out, withIntermediateDirectories: true)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        var scratch = [UInt8](repeating: 0, count: width * height * 4)

        var animations: [String: Any] = [:]
        var content: CGRect?

        // Process "idle" first so its bounding box is captured, then remaining states one at a time.
        let orderedKeys = ["idle"] + specs.keys.filter { $0 != "idle" }.sorted()
        for key in orderedKeys {
            guard let refs = specs[key], !refs.isEmpty else { continue }
            try Task.checkCancellation()
            try autoreleasepool {
                // Pass 2a: scan per-frame bounding boxes and pixel hashes using the single reusable scratch buffer.
                var frameMeta: [(ref: FrameRef, ms: Int, hash: Int)] = []
                var union: CGRect?
                for ref in refs {
                    try Task.checkCancellation()
                    let measured: (CGRect?, Int)? = autoreleasepool {
                        guard let image = decodeFrame(ref) else { return nil }
                        return measureInScratch(&scratch, image: image, width: width, height: height, colorSpace: colorSpace, bitmapInfo: bitmapInfo)
                    }
                    guard let (frameBox, hash) = measured else { continue }
                    if let one = frameBox {
                        union = union.map { $0.union(one) } ?? one
                    }
                    frameMeta.append((ref, ref.ms, hash))
                }
                guard !frameMeta.isEmpty else { return }

                let box = union ?? CGRect(x: 0, y: 0, width: width, height: height)
                if key == "idle" { content = box }
                let fw = max(1, Int(box.width))
                let fh = max(1, Int(box.height))

                var uniqueIndex: [Int: Int] = [:]
                var uniqueRefs: [FrameRef] = []
                var list: [[String: Int]] = []
                for item in frameMeta {
                    if let existing = uniqueIndex[item.hash] {
                        list.append(["i": existing, "ms": item.ms])
                    } else {
                        let assigned = uniqueRefs.count
                        uniqueIndex[item.hash] = assigned
                        uniqueRefs.append(item.ref)
                        list.append(["i": assigned, "ms": item.ms])
                    }
                }
                guard !uniqueRefs.isEmpty else { return }

                let cols = max(1, min(uniqueRefs.count, 4096 / fw))
                let rows = (uniqueRefs.count + cols - 1) / cols
                guard rows * fh <= 4096 else { throw PetPack.Problem.bad("「\(key)」帧太多了，放不进一张图") }

                // Pass 2b: stream each unique frame onto the state's sprite sheet and encode directly to disk.
                guard let sheet = CGContext(
                    data: nil,
                    width: cols * fw,
                    height: rows * fh,
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo
                ) else { return }

                for (n, ref) in uniqueRefs.enumerated() {
                    try Task.checkCancellation()
                    autoreleasepool {
                        guard let cell = renderCroppedCell(&scratch, ref: ref, width: width, height: height, box: box, colorSpace: colorSpace, bitmapInfo: bitmapInfo) else {
                            return
                        }
                        let col = n % cols, row = n / cols
                        sheet.draw(cell, in: CGRect(x: col * fw, y: (rows - row - 1) * fh, width: fw, height: fh))
                    }
                }

                let file = key + ".png"
                let fileURL = out.appendingPathComponent(file)
                guard let made = sheet.makeImage(),
                      let dest = CGImageDestinationCreateWithURL(fileURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                    return
                }
                CGImageDestinationAddImage(dest, made, nil)
                guard CGImageDestinationFinalize(dest) else { return }

                animations[key] = [
                    "sheet": file, "frameW": fw, "frameH": fh, "cols": cols,
                    "box": ["x": Int(box.minX), "y": Int(box.minY), "w": fw, "h": fh],
                    "loop": !once.contains(key) && !key.hasPrefix("idle-"), "frames": list,
                ] as [String: Any]
            }
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

    private static func inspectFile(_ url: URL, pixelsLeft: inout Int, maxWidth: inout Int, maxHeight: inout Int) throws -> [FrameRef] {
        guard ["gif", "png", "apng", "webp"].contains(url.pathExtension.lowercased()),
              let source = CGImageSourceCreateWithURL(url as CFURL, noCache) else { return [] }
        let count = CGImageSourceGetCount(source)
        var out: [FrameRef] = []
        for i in 0..<min(count, 120) {
            try Task.checkCancellation()
            guard let size = dimensions(source, at: i) else { continue }
            guard size.width <= 1024, size.height <= 1024 else { throw PetPack.Problem.bad("动图太大了（边长最多 1024）") }
            let pixels = size.width * size.height
            guard pixels <= pixelsLeft else { throw PetPack.Problem.bad("动图的总像素太多") }
            pixelsLeft -= pixels
            maxWidth = max(maxWidth, size.width)
            maxHeight = max(maxHeight, size.height)

            let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let png = props?[kCGImagePropertyPNGDictionary] as? [CFString: Any]
            let webp = props?[kCGImagePropertyWebPDictionary] as? [CFString: Any]
            let delays: [Any?] = [gif?[kCGImagePropertyGIFUnclampedDelayTime], gif?[kCGImagePropertyGIFDelayTime],
                                  png?[kCGImagePropertyAPNGUnclampedDelayTime], png?[kCGImagePropertyAPNGDelayTime],
                                  webp?[kCGImagePropertyWebPUnclampedDelayTime], webp?[kCGImagePropertyWebPDelayTime]]
            let seconds = delays.compactMap { ($0 as? NSNumber)?.doubleValue }.first { $0.isFinite && $0 > 0.01 && $0 <= 60 } ?? 0.1
            out.append(FrameRef(url: url, index: i, ms: max(20, Int(seconds * 1000))))
        }
        return out
    }

    private static func inspectFolder(_ url: URL, pixelsLeft: inout Int, maxWidth: inout Int, maxHeight: inout Int) throws -> [FrameRef] {
        let files = ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "png" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var out: [FrameRef] = []
        for file in files.prefix(120) {
            try Task.checkCancellation()
            guard let source = CGImageSourceCreateWithURL(file as CFURL, noCache),
                  let size = dimensions(source, at: 0) else { continue }
            guard size.width <= 1024, size.height <= 1024 else { throw PetPack.Problem.bad("动图太大了（边长最多 1024）") }
            let pixels = size.width * size.height
            guard pixels <= pixelsLeft else { throw PetPack.Problem.bad("动图的总像素太多") }
            pixelsLeft -= pixels
            maxWidth = max(maxWidth, size.width)
            maxHeight = max(maxHeight, size.height)
            out.append(FrameRef(url: file, index: 0, ms: 100))
        }
        return out
    }

    static func dimensions(_ source: CGImageSource, at index: Int) -> (width: Int, height: Int)? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { return nil }
        return (width, height)
    }

    private static func decodeFrame(_ ref: FrameRef) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(ref.url as CFURL, noCache) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, ref.index, noCache)
    }

    /// Draws `image` bottom-centre into the reusable RGBA scratch buffer and computes its opaque box and pixel hash.
    private static func measureInScratch(
        _ scratch: inout [UInt8],
        image: CGImage,
        width: Int,
        height: Int,
        colorSpace: CGColorSpace,
        bitmapInfo: UInt32
    ) -> (CGRect?, Int)? {
        scratch.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return nil }
            memset(base, 0, rawBuffer.count)
            guard let context = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else { return nil }
            context.draw(image, in: CGRect(x: (width - image.width) / 2, y: 0, width: image.width, height: image.height))
            let bytes = base.assumingMemoryBound(to: UInt8.self)
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
            return (box, hasher.finalize())
        }
    }

    private static func renderCroppedCell(
        _ scratch: inout [UInt8],
        ref: FrameRef,
        width: Int,
        height: Int,
        box: CGRect,
        colorSpace: CGColorSpace,
        bitmapInfo: UInt32
    ) -> CGImage? {
        guard let image = decodeFrame(ref) else { return nil }
        return scratch.withUnsafeMutableBytes { rawBuffer -> CGImage? in
            guard let base = rawBuffer.baseAddress else { return nil }
            memset(base, 0, rawBuffer.count)
            guard let context = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else { return nil }
            context.draw(image, in: CGRect(x: (width - image.width) / 2, y: 0, width: image.width, height: image.height))
            guard let full = context.makeImage() else { return nil }
            return full.cropping(to: box)
        }
    }
}
