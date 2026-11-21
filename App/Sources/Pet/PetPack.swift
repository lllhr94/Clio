import SwiftUI
import UIKit

/// A pet made of drawn frames, in the "schema 1" pet-pack format shared by DSH Go and Clawd on Desk themes:
/// a `pack.json` and the sprite sheets it names. Read here on its own; nothing of their code is used.
struct PetPack: Identifiable {
    struct Box { var x = 0.0, y = 0.0, w = 1.0, h = 1.0 }

    struct Anim {
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
        func num(_ any: Any?) -> Double? { (any as? NSNumber)?.doubleValue }
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
        return PetPack(
            id: id, dir: dir,
            name: root["name"] as? String ?? id,
            author: root["author"] as? String ?? "",
            license: root["license"] as? String ?? "",
            source: root["source"] as? String ?? "",
            pixelArt: root["pixelArt"] as? Bool ?? true,
            scale: scale, canvasW: cw, canvasH: ch,
            anchorX: num(anchor["x"]) ?? content.x + content.w / 2,
            baseline: num(anchor["baseline"]) ?? content.y + content.h,
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

/// Decoded sheets and cut frames, kept while they are in use. Only a couple of sheets are held at once:
/// a whole pack decoded can take a lot of memory.
@MainActor
enum PetSheets {
    private static var sheets: [String: CGImage] = [:]
    private static var order: [String] = []
    private static var cells: [String: CGImage] = [:]

    static func sheet(_ pack: PetPack, _ name: String) -> CGImage? {
        let key = pack.id + "/" + name
        if let hit = sheets[key] { return hit }
        let url = pack.dir.appendingPathComponent(name)
        guard let image = UIImage(contentsOfFile: url.path)?.cgImage else { return nil }
        sheets[key] = image
        order.append(key)
        while order.count > 3 {
            let old = order.removeFirst()
            sheets[old] = nil
            cells = cells.filter { !$0.key.hasPrefix(old + "#") }
        }
        return image
    }

    static func cell(_ pack: PetPack, _ anim: PetPack.Anim, _ index: Int) -> CGImage? {
        let key = pack.id + "/" + anim.sheet + "#\(index)"
        if let hit = cells[key] { return hit }
        guard let sheet = sheet(pack, anim.sheet) else { return nil }
        let col = index % anim.cols, row = index / anim.cols
        let rect = CGRect(x: col * anim.frameW, y: row * anim.frameH, width: anim.frameW, height: anim.frameH)
        guard rect.maxX <= CGFloat(sheet.width), rect.maxY <= CGFloat(sheet.height), let cut = sheet.cropping(to: rect) else { return nil }
        cells[key] = cut
        return cut
    }

    static func forget(_ id: String) {
        sheets = sheets.filter { !$0.key.hasPrefix(id + "/") }
        order.removeAll { $0.hasPrefix(id + "/") }
        cells = cells.filter { !$0.key.hasPrefix(id + "/") }
    }
}

/// One drawn pet, playing `anim` since `since`, with a shared scale in points per canvas unit.
/// Its feet (the pack's baseline) sit on the bottom edge of the view, its middle (anchor x) on the view's middle.
struct SpritePet: View {
    let pack: PetPack
    let anim: String
    let since: Date
    let unit: CGFloat
    var mirrored = false

    var body: some View {
        let u = unit
        // The view is as tall as the drawing down to its feet; what lies under the feet (a shadow) hangs below.
        // Pixel frames hold for a tenth of a second or more: twelve looks a second is plenty, and keeps the phone
        // from redrawing the pet thirty times a second for nothing.
        TimelineView(.animation(minimumInterval: 1 / 12)) { timeline in
            frame(at: timeline.date, unit: u)
        }
        .frame(width: CGFloat(pack.canvasW) * u, height: CGFloat(pack.baseline) * u, alignment: .top)
        .scaleEffect(x: mirrored ? -1 : 1, y: 1, anchor: UnitPoint(x: pack.anchorX / pack.canvasW, y: 0.5))
    }

    @ViewBuilder
    private func frame(at date: Date, unit u: CGFloat) -> some View {
        if let animation = pack.animations[anim] {
            let ms = Int(date.timeIntervalSince(since) * 1000)
            let index = animation.cell(at: max(0, ms))
            ZStack(alignment: .topLeading) {
                Color.clear.frame(width: CGFloat(pack.canvasW) * u, height: CGFloat(pack.canvasH) * u)
                if let cell = PetSheets.cell(pack, animation, index) {
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
