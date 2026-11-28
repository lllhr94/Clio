import ImageIO
import Observation
import SwiftUI
import UIKit

/// A pet made of drawn frames, in the "schema 1" pet-pack format shared by DSH Go and Clawd on Desk themes:
/// a `pack.json` and the sprite sheets it names. Read here on its own; nothing of their code is used.
struct PetPack: Identifiable, Sendable {
    struct Box: Sendable { var x = 0.0, y = 0.0, w = 1.0, h = 1.0 }

    struct Anim: Sendable {
        var sheet: String
        var frameW: Int
        var frameH: Int
        var cols: Int
        var box: Box
        var loop: Bool
        /// Which cell of the sheet, and for how long.
        var frames: [(i: Int, ms: Int)]
        var total: Int { max(1, frames.reduce(0) { $0 + $1.ms }) }

        /// The frame showing `ms` milliseconds into the animation.
        func cell(at ms: Int) -> Int {
            guard !frames.isEmpty else { return 0 }
            var t = loop ? ms % total : min(ms, total - 1)
            for frame in frames {
                if t < frame.ms { return frame.i }
                t -= frame.ms
            }
            return frames[frames.count - 1].i
        }
    }

    let id: String
    let dir: URL
    var name: String
    var author: String
    var license: String
    var source: String
    var pixelArt: Bool
    var scale: Double
    var canvasW: Double
    var canvasH: Double
    var anchorX: Double
    var baseline: Double
    var content: Box
    var animations: [String: Anim]
    var states: [String: [String]]
    var tiers: [String: [(min: Int, anim: String)]]
    var minDisplay: [String: Int]
    var autoReturn: [String: Int]
    var wakeMs: Int
    var reactions: [String: [String]]
    var idleEvery: (mean: Int, min: Int, max: Int)
    var idlePool: [(anim: String, ms: Int, weight: Double)]
    var roamAnim: String?
    /// Which way the drawing faces: "left", "right" or "front" (never mirrored).
    var faces: String
    var sleepAfter: Int

    enum Problem: LocalizedError {
        case bad(String)
        var errorDescription: String? { if case .bad(let why) = self { return why }; return nil }
    }

    /// The animation for a state, busier as more conversations run (`tiers`), else the state's own, else idle.
    func anim(for state: String, busy: Int = 1) -> String? {
        if let steps = tiers[state], let step = steps.first(where: { busy >= $0.min }), animations[step.anim] != nil { return step.anim }
        if let named = states[state]?.first(where: { animations[$0] != nil }) { return named }
        return states["idle"]?.first(where: { animations[$0] != nil }) ?? animations.keys.sorted().first
    }

    func reaction(_ name: String) -> String? {
        reactions[name]?.filter { animations[$0] != nil }.randomElement()
    }

    /// Optional motion frames keep their own names in imported packs.
    func motionAnimation(_ names: [String]) -> String? {
        for name in names {
            if let named = states[name]?.first(where: { animations[$0] != nil }) { return named }
            if animations[name] != nil { return name }
            if let reaction = reaction(name) { return reaction }
        }
        return nil
    }

    // MARK: Reading pack.json

    static func parse(_ data: Data, dir: URL, id: String) throws -> PetPack {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Problem.bad("pack.json 不是一个对象") }
        // Only sensible numbers: NaN, infinity or 1e20 from a pack would stop the app when made into a whole number.
        func num(_ any: Any?) -> Double? {
            guard let value = (any as? NSNumber)?.doubleValue, value.isFinite, abs(value) < 10_000_000 else { return nil }
            return value
        }
        func box(_ any: Any?) -> Box? {
            guard let dict = any as? [String: Any], let w = num(dict["w"]), let h = num(dict["h"]), w > 0, h > 0 else { return nil }
            return Box(x: num(dict["x"]) ?? 0, y: num(dict["y"]) ?? 0, w: w, h: h)
        }
        guard let canvas = root["canvas"] as? [String: Any], let cw = num(canvas["w"]), let ch = num(canvas["h"]), cw.isFinite, ch.isFinite, cw > 0, ch > 0 else {
            throw Problem.bad("pack.json 里没有 canvas")
        }
        guard let rawAnims = root["animations"] as? [String: Any], !rawAnims.isEmpty else { throw Problem.bad("pack.json 里没有动画") }
        let declaredScale = num(root["scale"]) ?? 1
        let scale = declaredScale.isFinite && declaredScale > 0 ? declaredScale : 1
        var animations: [String: Anim] = [:]
        for (name, value) in rawAnims {
            guard let dict = value as? [String: Any], let sheet = dict["sheet"] as? String,
                  !sheet.contains("/"), !sheet.hasPrefix("."), sheet.lowercased().hasSuffix(".png") else {
                throw Problem.bad("动画「\(name)」的图不对：只认同一层里的 PNG")
            }
            let frames: [(i: Int, ms: Int)] = (dict["frames"] as? [[String: Any]] ?? []).compactMap { item in
                guard let i = num(item["i"]), let ms = num(item["ms"]), i >= 0, ms > 0 else { return nil }
                return (Int(i), Int(ms))
            }
            guard !frames.isEmpty else { throw Problem.bad("动画「\(name)」没有帧") }
            let animBox = box(dict["box"]) ?? Box(x: 0, y: 0, w: cw, h: ch)
            let frameW = Int(num(dict["frameW"]) ?? animBox.w * scale)
            let frameH = Int(num(dict["frameH"]) ?? animBox.h * scale)
            let cols = Int(num(dict["cols"]) ?? Double((frames.map(\.i).max() ?? 0) + 1))
            guard frameW > 0, frameH > 0, cols > 0, frameW <= 4096, frameH <= 4096 else { throw Problem.bad("动画「\(name)」的帧格大小不对") }
            animations[name] = Anim(sheet: sheet, frameW: frameW, frameH: frameH, cols: cols, box: animBox,
                                    loop: dict["loop"] as? Bool ?? true, frames: frames)
        }
        var states: [String: [String]] = [:]
        for (state, value) in root["states"] as? [String: Any] ?? [:] {
            if let list = value as? [String] { states[state] = list } else if let one = value as? String { states[state] = [one] }
        }
        // Other names for the same states (the brief given to designers used these), and states named only by
        // an animation of that name.
        let aliases: [String: [String]] = [
            "notification": ["awaiting_approval", "awaiting-approval", "waiting"],
            "attention": ["done", "happy"],
            "roam": ["walking", "walk"],
        ]
        for state in ["idle", "thinking", "working", "notification", "attention", "error", "sleeping", "waking", "sweeping", "roam"] where states[state] == nil {
            let names = [state] + (aliases[state] ?? [])
            if let found = names.lazy.compactMap({ states[$0] }).first {
                states[state] = found
            } else if let anim = names.first(where: { animations[$0] != nil }) {
                states[state] = [anim]
            }
        }
        var tiers: [String: [(min: Int, anim: String)]] = [:]
        for (state, value) in root["tiers"] as? [String: Any] ?? [:] {
            let steps = (value as? [[String: Any]] ?? []).compactMap { step -> (min: Int, anim: String)? in
                guard let min = num(step["min"]), let anim = step["anim"] as? String else { return nil }
                return (Int(min), anim)
            }
            tiers[state] = steps.sorted { $0.min > $1.min }
        }
        // Reactions: a name, a list, or "name2", "name3"… joined onto "name".
        var reactions: [String: [String]] = [:]
        let rawReactions = root["reactions"] as? [String: Any] ?? [:]
        for key in rawReactions.keys.sorted() {
            let names: [String] = (rawReactions[key] as? [String]) ?? ((rawReactions[key] as? String).map { [$0] } ?? [])
            let base = String(key.reversed().drop { $0.isNumber }.reversed())
            if base != key, rawReactions[base] != nil { reactions[base, default: []] += names } else { reactions[key, default: []] += names }
        }
        for (reaction, names) in ["tapLeft": ["poke_left", "poke-left", "react-left"], "tapRight": ["poke_right", "poke-right", "react-right"],
                                  "drag": ["lifted"], "tickle": ["tickle"], "annoyed": ["annoyed"]] where reactions[reaction] == nil {
            if let found = names.lazy.compactMap({ reactions[$0] }).first { reactions[reaction] = found }
            else if let anim = names.first(where: { animations[$0] != nil }) { reactions[reaction] = [anim] }
        }
        let timings = root["timings"] as? [String: Any] ?? [:]
        func ints(_ any: Any?) -> [String: Int] {
            (any as? [String: Any] ?? [:]).compactMapValues { num($0).map(Int.init) }
        }
        let pool = root["idlePool"] as? [String: Any] ?? [:]
        let every = pool["everyMs"] as? [String: Any] ?? [:]
        let poolAnims: [(anim: String, ms: Int, weight: Double)] = (pool["anims"] as? [[String: Any]] ?? []).compactMap { item in
            guard let anim = item["anim"] as? String, animations[anim] != nil else { return nil }
            return (anim, Int(num(item["ms"]) ?? Double(animations[anim]?.total ?? 3000)), num(item["weight"]) ?? 1)
        }
        let anchor = root["anchor"] as? [String: Any] ?? [:]
        let roam = root["roam"] as? [String: Any] ?? [:]
        let content = box(root["contentBox"]) ?? Box(x: 0, y: 0, w: cw, h: ch)
        let rawAnchorX = num(anchor["x"]) ?? content.x + content.w / 2
        let rawBaseline = num(anchor["baseline"]) ?? content.y + content.h
        let clampedAnchorX = min(cw, max(0, rawAnchorX))
        let clampedBaseline = min(ch * 2, max(1, rawBaseline))
        return PetPack(
            id: id, dir: dir,
            name: root["name"] as? String ?? id,
            author: root["author"] as? String ?? "",
            license: root["license"] as? String ?? "",
            source: root["source"] as? String ?? "",
            pixelArt: root["pixelArt"] as? Bool ?? true,
            scale: scale, canvasW: cw, canvasH: ch,
            anchorX: clampedAnchorX,
            baseline: clampedBaseline,
            content: content, animations: animations, states: states, tiers: tiers,
            minDisplay: ints(timings["minDisplay"]), autoReturn: ints(timings["autoReturn"]),
            wakeMs: Int(num(timings["wakeMs"]) ?? 1500), reactions: reactions,
            idleEvery: (Int(num(every["mean"]) ?? 120_000), Int(num(every["min"]) ?? 45_000), Int(num(every["max"]) ?? 300_000)),
            idlePool: poolAnims,
            roamAnim: (roam["anim"] as? String).flatMap { animations[$0] != nil ? $0 : nil } ?? states["roam"]?.first,
            faces: roam["faces"] as? String ?? "left",
            sleepAfter: Int(num((root["sleep"] as? [String: Any])?["afterMs"]) ?? 60_000)
        )
    }
}

private enum PetAtlasGenerations {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var map: [String: UInt64] = [:]

    static func current(for id: String) -> UInt64 {
        lock.withLock { map[id, default: 0] }
    }

    static func matches(_ id: String, expected: UInt64) -> Bool {
        lock.withLock { map[id, default: 0] == expected }
    }

    static func bump(for id: String) {
        lock.withLock { map[id, default: 0] &+= 1 }
    }

    static func bumpAll() {
        lock.withLock {
            for key in Array(map.keys) {
                map[key, default: 0] &+= 1
            }
        }
    }
}

@MainActor @Observable
fileprivate final class PetAtlasSignal {
    var revision: UInt64 = 0
}

/// Decoded sheets and cut frames, kept while they are in use.
/// Only active pet packs retain animation frames (downscaled to display pixels when oversized);
/// inactive packs keep only compact single-frame still thumbnails so switching or picking never spikes memory.
@MainActor
enum PetSheets {
    private final class ImageBox {
        let image: CGImage
        let bytes: Int

        init(_ image: CGImage) {
            self.image = image
            self.bytes = max(1, image.bytesPerRow * image.height)
        }
    }

    private struct SheetEntry {
        let image: CGImage
        let bytes: Int
        var lastUsed: UInt64
    }

    private struct SlicedFrame: @unchecked Sendable {
        let index: Int
        let image: CGImage
        let bytes: Int
    }

    private struct PlaceholderEntry {
        let index: Int
        let image: CGImage
    }

    private static let maxActiveSheetBytes = 8 * 1024 * 1024
    private static let maxRetainedSingleSheetBytes = 4 * 1024 * 1024
    private static let maxActiveSheets = 2
    private static let maxInactiveStillPixels = 192
    private static let maxActiveFramePixels = 512
    private static let maxAtlasBatchBytes = 6 * 1024 * 1024
    private static let maxPlaceholders = 12

    private static let signal = PetAtlasSignal()
    private static let atlasDecodeQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "clio.pet-atlas-decode"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private static var primaryPackID: String?
    private static var playbackPackID: String?
    private static var accessTick: UInt64 = 0
    private static var sheets: [String: SheetEntry] = [:]
    private static var totalSheetBytes = 0
    private static var sheetByteEstimates: [String: Int] = [:]
    private static var inFlightAtlases: Set<String> = []
    private static var failedAtlases: Set<String> = []
    private static var placeholders: [String: PlaceholderEntry] = [:]

    private static let activeCells: NSCache<NSString, ImageBox> = {
        let cache = NSCache<NSString, ImageBox>()
        cache.countLimit = 48
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()

    private static let inactiveStills: NSCache<NSString, ImageBox> = {
        let cache = NSCache<NSString, ImageBox>()
        cache.countLimit = 24
        cache.totalCostLimit = 2 * 1024 * 1024
        return cache
    }()

    private static let observersInstalled: Bool = {
        let governor = RuntimeBudgetGovernor.shared
        governor.observeMemoryWarning { PetSheets.purgeAll() }
        governor.observeBudget { snapshot in
            let cache = PetSheets.inactiveStills
            switch snapshot.tier {
            case .full:
                cache.countLimit = 24
                cache.totalCostLimit = 2 * 1024 * 1024
            case .conserve, .critical:
                cache.countLimit = 12
                cache.totalCostLimit = 1024 * 1024
                cache.removeAllObjects()
                PetSheets.evictPlaceholders(except: PetSheets.activeIDs)
            }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PetSheets.purgeTransient() }
        }
        return true
    }()

    nonisolated private static func currentGeneration(for id: String) -> UInt64 {
        PetAtlasGenerations.current(for: id)
    }

    nonisolated private static func bumpGeneration(for id: String) {
        PetAtlasGenerations.bump(for: id)
    }

    nonisolated private static func bumpAllGenerations() {
        PetAtlasGenerations.bumpAll()
    }

    /// Sets the user's selected pack as primary and evicts decoded animation caches for inactive packs.
    static func activate(_ id: String) {
        _ = observersInstalled
        guard primaryPackID != id else { return }
        if let previous = primaryPackID {
            bumpGeneration(for: previous)
        }
        bumpGeneration(for: id)
        primaryPackID = id
        if let playing = playbackPackID, playing != id {
            playbackPackID = nil
        }
        evictSheets(except: activeIDs)
        evictPlaceholders(except: activeIDs)
        activeCells.removeAllObjects()
    }

    /// Clears transient full-sheet and still caches (e.g. on background entry) while keeping tiny active frames if bounded.
    static func purgeTransient() {
        clearSheets()
        inactiveStills.removeAllObjects()
    }

    /// Drops every decoded sheet and frame on memory pressure.
    static func purgeAll() {
        bumpAllGenerations()
        clearSheets()
        activeCells.removeAllObjects()
        inactiveStills.removeAllObjects()
        placeholders.removeAll()
        failedAtlases.removeAll()
        sheetByteEstimates.removeAll()
    }

    private static var activeIDs: Set<String> {
        var ids: Set<String> = []
        if let primaryPackID { ids.insert(primaryPackID) }
        if let playbackPackID { ids.insert(playbackPackID) }
        return ids
    }

    private static func isActivePack(_ id: String) -> Bool {
        id == primaryPackID || id == playbackPackID
    }

    private static func nextTick() -> UInt64 {
        accessTick &+= 1
        return accessTick
    }

    private static func clearSheets() {
        sheets.removeAll()
        totalSheetBytes = 0
    }

    private static func evictSheets(except keptIDs: Set<String>) {
        for key in Array(sheets.keys) {
            let packID = String(key.split(separator: "/", maxSplits: 1).first ?? "")
            if !keptIDs.contains(packID), let removed = sheets.removeValue(forKey: key) {
                totalSheetBytes = max(0, totalSheetBytes - removed.bytes)
            }
        }
    }

    private static func evictPlaceholders(except keptIDs: Set<String>) {
        for key in Array(placeholders.keys) {
            let packID = String(key.split(separator: "/", maxSplits: 1).first ?? "")
            if !keptIDs.contains(packID) {
                placeholders.removeValue(forKey: key)
            }
        }
    }

    nonisolated private static func estimatedSheetBytes(at url: URL) -> Int? {
        let noCache = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, noCache),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, noCache) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { return nil }
        return w * h * 4
    }

    nonisolated private static func decodeSheetImage(at url: URL) -> CGImage? {
        let noCache = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, noCache) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, noCache)
    }

    private static func isOversizedSheet(_ pack: PetPack, _ name: String) -> Bool {
        let key = pack.id + "/" + name
        if let known = sheetByteEstimates[key] {
            return known > maxRetainedSingleSheetBytes
        }
        let url = pack.dir.appendingPathComponent(name)
        guard let bytes = estimatedSheetBytes(at: url) else { return false }
        sheetByteEstimates[key] = bytes
        return bytes > maxRetainedSingleSheetBytes
    }

    private static func storeActiveSheet(_ image: CGImage, for key: String) {
        let bytes = max(1, image.bytesPerRow * image.height)
        guard bytes <= maxRetainedSingleSheetBytes else { return }
        if let existing = sheets.removeValue(forKey: key) {
            totalSheetBytes = max(0, totalSheetBytes - existing.bytes)
        }
        sheets[key] = SheetEntry(image: image, bytes: bytes, lastUsed: nextTick())
        totalSheetBytes += bytes
        while sheets.count > maxActiveSheets || totalSheetBytes > maxActiveSheetBytes {
            guard let oldest = sheets.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key,
                  let removed = sheets.removeValue(forKey: oldest) else { break }
            totalSheetBytes = max(0, totalSheetBytes - removed.bytes)
        }
    }

    static func sheet(_ pack: PetPack, _ name: String) -> CGImage? {
        _ = observersInstalled
        let key = pack.id + "/" + name
        if var hit = sheets[key] {
            hit.lastUsed = nextTick()
            sheets[key] = hit
            return hit.image
        }
        guard let image = decodeSheetImage(at: pack.dir.appendingPathComponent(name)) else { return nil }
        if isActivePack(pack.id) {
            storeActiveSheet(image, for: key)
        }
        return image
    }

    static func cell(_ pack: PetPack, _ anim: PetPack.Anim, _ index: Int) -> CGImage? {
        cell(pack, anim, index, maxPixelSize: nil, forPlayback: false, deferLargeSheet: false)
    }

    static func isDecodingLargeSheet(_ pack: PetPack, _ anim: PetPack.Anim) -> Bool {
        let prefix = "\(pack.id)/\(anim.sheet)@"
        return inFlightAtlases.contains { $0.hasPrefix(prefix) }
    }

    static func cell(
        _ pack: PetPack,
        _ anim: PetPack.Anim,
        _ index: Int,
        maxPixelSize: Int? = nil,
        forPlayback: Bool,
        deferLargeSheet: Bool = false
    ) -> CGImage? {
        _ = observersInstalled
        if forPlayback, playbackPackID != pack.id {
            playbackPackID = pack.id
            evictSheets(except: activeIDs)
            evictPlaceholders(except: activeIDs)
        }

        let active = forPlayback || isActivePack(pack.id)
        let targetLimit: Int
        if active {
            targetLimit = min(maxActiveFramePixels, max(24, maxPixelSize ?? maxActiveFramePixels))
        } else {
            targetLimit = min(maxInactiveStillPixels, max(24, maxPixelSize ?? maxInactiveStillPixels))
        }
        let targetDims = scaledDimensions(
            width: anim.frameW,
            height: anim.frameH,
            pixelArt: pack.pixelArt,
            maxPixelSize: targetLimit
        )
        let key = "\(pack.id)/\(anim.sheet)#\(index)@\(targetDims.width)x\(targetDims.height)" as NSString

        if active {
            if let hit = activeCells.object(forKey: key) { return hit.image }
        } else if let hit = inactiveStills.object(forKey: key) {
            return hit.image
        }

        let sheetKey = pack.id + "/" + anim.sheet
        // Avoid decoding >4 MiB sprite sheets synchronously on MainActor for live playback or SwiftUI stills (`deferLargeSheet`):
        // schedule a single serialized background batch while returning any nearest cached frame.
        // Non-SwiftUI synchronous callers (e.g. LiveFace / UIKit accessories) keep `deferLargeSheet == false`.
        if (forPlayback || deferLargeSheet), sheets[sheetKey] == nil && isOversizedSheet(pack, anim.sheet) {
            _ = signal.revision
            let placeholderKey = "\(sheetKey)@\(targetDims.width)x\(targetDims.height)"
            scheduleLargeAtlasBatch(
                pack: pack,
                anim: anim,
                requestedIndex: index,
                targetWidth: targetDims.width,
                targetHeight: targetDims.height,
                active: active,
                placeholderKey: placeholderKey
            )
            return nearestCachedCell(pack: pack, anim: anim, requestedIndex: index, targetDims: targetDims, active: active, placeholderKey: placeholderKey)
        }

        let built: CGImage? = autoreleasepool {
            let sourceSheet: CGImage?
            if active {
                sourceSheet = sheet(pack, anim.sheet)
            } else {
                // Inactive packs decode once on demand without retaining the full sprite sheet in memory.
                sourceSheet = decodeSheetImage(at: pack.dir.appendingPathComponent(anim.sheet))
            }
            guard let sourceSheet else { return nil }
            return cropCell(
                from: sourceSheet,
                anim: anim,
                index: index,
                pixelArt: pack.pixelArt,
                targetWidth: targetDims.width,
                targetHeight: targetDims.height
            )
        }

        guard let built else { return nil }
        let box = ImageBox(built)
        if active {
            activeCells.setObject(box, forKey: key, cost: box.bytes)
        } else {
            inactiveStills.setObject(box, forKey: key, cost: box.bytes)
        }
        return built
    }

    private static func nearestCachedCell(
        pack: PetPack,
        anim: PetPack.Anim,
        requestedIndex: Int,
        targetDims: (width: Int, height: Int),
        active: Bool,
        placeholderKey: String
    ) -> CGImage? {
        if active {
            var bestDistance = Int.max
            var bestImage: CGImage?
            for frame in anim.frames {
                let candidateKey = "\(pack.id)/\(anim.sheet)#\(frame.i)@\(targetDims.width)x\(targetDims.height)" as NSString
                if let hit = activeCells.object(forKey: candidateKey) {
                    let distance = abs(frame.i - requestedIndex)
                    if distance < bestDistance {
                        bestDistance = distance
                        bestImage = hit.image
                    }
                }
            }
            if let bestImage { return bestImage }
        }
        return placeholders[placeholderKey]?.image
    }

    private static func scheduleLargeAtlasBatch(
        pack: PetPack,
        anim: PetPack.Anim,
        requestedIndex: Int,
        targetWidth: Int,
        targetHeight: Int,
        active: Bool,
        placeholderKey: String
    ) {
        let packID = pack.id
        let gen = currentGeneration(for: packID)
        let batchKey = "\(placeholderKey)#\(active ? 1 : 0)#g\(gen)"
        guard !failedAtlases.contains(batchKey), !inFlightAtlases.contains(batchKey) else { return }
        inFlightAtlases.insert(batchKey)

        var indices: [Int] = [requestedIndex]
        if active {
            var seen: Set<Int> = [requestedIndex]
            for candidate in anim.frames where !seen.contains(candidate.i) {
                seen.insert(candidate.i)
                let key = "\(pack.id)/\(anim.sheet)#\(candidate.i)@\(targetWidth)x\(targetHeight)" as NSString
                if activeCells.object(forKey: key) == nil { indices.append(candidate.i) }
            }
            for other in pack.animations.values where other.sheet == anim.sheet && other.frameW == anim.frameW && other.frameH == anim.frameH && other.cols == anim.cols {
                for candidate in other.frames where !seen.contains(candidate.i) {
                    seen.insert(candidate.i)
                    let key = "\(pack.id)/\(anim.sheet)#\(candidate.i)@\(targetWidth)x\(targetHeight)" as NSString
                    if activeCells.object(forKey: key) == nil { indices.append(candidate.i) }
                }
            }
        }
        let url = pack.dir.appendingPathComponent(anim.sheet)
        let sheetName = anim.sheet
        let pixelArt = pack.pixelArt
        let frameOrder = indices
        let batchByteLimit = active ? maxAtlasBatchBytes : 512 * 1024

        atlasDecodeQueue.addOperation {
            guard PetAtlasGenerations.matches(packID, expected: gen) else {
                Task { @MainActor in
                    PetSheets.inFlightAtlases.remove(batchKey)
                    PetSheets.signal.revision &+= 1
                }
                return
            }
            let sliced: [SlicedFrame] = autoreleasepool {
                guard let atlas = Self.decodeSheetImage(at: url) else { return [] }
                var out: [SlicedFrame] = []
                var batchBytes = 0
                for idx in frameOrder {
                    if !PetAtlasGenerations.matches(packID, expected: gen) { break }
                    guard let cell = Self.cropCell(
                        from: atlas,
                        anim: anim,
                        index: idx,
                        pixelArt: pixelArt,
                        targetWidth: targetWidth,
                        targetHeight: targetHeight
                    ) else { continue }
                    let bytes = max(1, cell.bytesPerRow * cell.height)
                    if !out.isEmpty && batchBytes + bytes > batchByteLimit { break }
                    batchBytes += bytes
                    out.append(SlicedFrame(index: idx, image: cell, bytes: bytes))
                }
                return out
            }

            Task { @MainActor in
                PetSheets.inFlightAtlases.remove(batchKey)
                guard !sliced.isEmpty else {
                    if PetAtlasGenerations.matches(packID, expected: gen) {
                        if PetSheets.failedAtlases.count >= 64 { PetSheets.failedAtlases.removeAll() }
                        PetSheets.failedAtlases.insert(batchKey)
                    }
                    PetSheets.signal.revision &+= 1
                    return
                }
                guard PetAtlasGenerations.matches(packID, expected: gen) else {
                    PetSheets.signal.revision &+= 1
                    return
                }
                if active && !PetSheets.isActivePack(packID) { return }
                for item in sliced {
                    let itemKey = "\(packID)/\(sheetName)#\(item.index)@\(targetWidth)x\(targetHeight)" as NSString
                    let box = ImageBox(item.image)
                    if active {
                        PetSheets.activeCells.setObject(box, forKey: itemKey, cost: item.bytes)
                    } else {
                        PetSheets.inactiveStills.setObject(box, forKey: itemKey, cost: item.bytes)
                    }
                }
                if let first = sliced.first {
                    if PetSheets.placeholders.count >= PetSheets.maxPlaceholders {
                        PetSheets.placeholders.removeAll(keepingCapacity: true)
                    }
                    PetSheets.placeholders[placeholderKey] = PlaceholderEntry(index: first.index, image: first.image)
                }
                PetSheets.signal.revision &+= 1
            }
        }
    }

    nonisolated private static func scaledDimensions(
        width: Int,
        height: Int,
        pixelArt: Bool,
        maxPixelSize: Int?
    ) -> (width: Int, height: Int) {
        let safeW = max(1, width)
        let safeH = max(1, height)
        guard let maxPixelSize, maxPixelSize > 0 else { return (safeW, safeH) }
        let peak = max(safeW, safeH)
        guard peak > maxPixelSize else { return (safeW, safeH) }
        if pixelArt {
            let divisor = max(2, Int(ceil(Double(peak) / Double(maxPixelSize))))
            let outW = max(1, safeW / divisor)
            let outH = max(1, safeH / divisor)
            return (outW, outH)
        }
        let ratio = Double(maxPixelSize) / Double(peak)
        let outW = max(1, Int((Double(safeW) * ratio).rounded()))
        let outH = max(1, Int((Double(safeH) * ratio).rounded()))
        return (outW, outH)
    }

    nonisolated private static func cropCell(
        from sheet: CGImage,
        anim: PetPack.Anim,
        index: Int,
        pixelArt: Bool,
        targetWidth: Int,
        targetHeight: Int
    ) -> CGImage? {
        let col = index % anim.cols, row = index / anim.cols
        let rect = CGRect(x: col * anim.frameW, y: row * anim.frameH, width: anim.frameW, height: anim.frameH)
        guard rect.maxX <= CGFloat(sheet.width), rect.maxY <= CGFloat(sheet.height),
              let cropped = sheet.cropping(to: rect) else { return nil }
        let srcW = cropped.width
        let srcH = cropped.height
        guard srcW > 0, srcH > 0 else { return nil }
        let dstW = max(1, targetWidth)
        let dstH = max(1, targetHeight)
        // Materialize an independent tightly-sized bitmap so giant parent sprite sheets can be released immediately.
        guard let context = CGContext(
            data: nil,
            width: dstW,
            height: dstH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return cropped }
        context.interpolationQuality = pixelArt ? .none : .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: dstW, height: dstH))
        return context.makeImage() ?? cropped
    }

    static func forget(_ id: String) {
        bumpGeneration(for: id)
        let prefix = id + "/"
        for key in Array(sheets.keys) where key.hasPrefix(prefix) {
            if let removed = sheets.removeValue(forKey: key) {
                totalSheetBytes = max(0, totalSheetBytes - removed.bytes)
            }
        }
        for key in Array(sheetByteEstimates.keys) where key.hasPrefix(prefix) {
            sheetByteEstimates.removeValue(forKey: key)
        }
        for key in Array(placeholders.keys) where key.hasPrefix(prefix) {
            placeholders.removeValue(forKey: key)
        }
        if isActivePack(id) {
            activeCells.removeAllObjects()
        }
        inactiveStills.removeAllObjects()
        if playbackPackID == id { playbackPackID = nil }
    }
}

/// One drawn pet, playing `anim` since `since`, with a shared scale in points per canvas unit.
/// Its feet (the pack's baseline) sit on the bottom edge of the view, its middle (anchor x) on the view's middle.
struct SpritePet: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale
    let pack: PetPack
    let anim: String
    let since: Date
    let unit: CGFloat
    var mirrored = false

    private struct Playback: Equatable {
        let pack: String
        let animation: String
        let since: Date
    }

    @State private var ended: Playback?

    var body: some View {
        let playback = Playback(pack: pack.id, animation: anim, since: since)
        let animation = pack.animations[anim]
        let finish: Date? = animation.flatMap { $0.loop ? nil : since.addingTimeInterval(Double($0.total) / 1000) }
        Group {
            if let animation, scenePhase == .active, ended != playback,
               let first = animation.frames.first, animation.frames.contains(where: { $0.i != first.i }) {
                let sleeping = pack.states["sleeping"]?.contains(anim) == true
                let idle = pack.states["idle"]?.contains(anim) == true
                let fps = sleeping ? 4 : (idle ? RuntimeBudgetGovernor.shared.snapshot.petIdleFPS : 12)
                TimelineView(.animation(minimumInterval: 1.0 / Double(fps))) { timeline in
                    frame(at: timeline.date, unit: unit)
                }
            } else {
                frame(at: ended == playback ? finish ?? since : since, unit: unit)
            }
        }
        .task(id: playback) {
            guard let finish else { return }
            let remaining = finish.timeIntervalSinceNow
            if remaining > 0 {
                do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            ended = playback
        }
        .frame(width: CGFloat(pack.canvasW) * unit, height: CGFloat(pack.baseline) * unit, alignment: .top)
        .scaleEffect(x: mirrored ? -1 : 1, y: 1, anchor: UnitPoint(x: pack.anchorX / pack.canvasW, y: 0.5))
    }

    @ViewBuilder
    private func frame(at date: Date, unit u: CGFloat) -> some View {
        if let animation = pack.animations[anim] {
            let ms = Int(date.timeIntervalSince(since) * 1000)
            let index = animation.cell(at: max(0, ms))
            let rawPixels = max(animation.box.w, animation.box.h) * Double(u * displayScale)
            let targetPixels = max(24, pack.pixelArt ? Int(rawPixels.rounded()) : Int(ceil(rawPixels)))
            ZStack(alignment: .topLeading) {
                Color.clear.frame(width: CGFloat(pack.canvasW) * u, height: CGFloat(pack.canvasH) * u)
                if let cell = PetSheets.cell(pack, animation, index, maxPixelSize: targetPixels, forPlayback: true) {
                    Image(decorative: cell, scale: 1)
                        .resizable()
                        .interpolation(pack.pixelArt ? .none : .high)
                        .frame(width: CGFloat(animation.box.w) * u, height: CGFloat(animation.box.h) * u)
                        .offset(x: CGFloat(animation.box.x) * u, y: CGFloat(animation.box.y) * u)
                }
            }
        }
    }
}
