import Foundation
import Observation
import UIKit
import ZIPFoundation

/// The pets on this phone: Clio's own whale (drawn, wearing the portrait you made) and the packs you imported.
/// What is picked, how big, quiet or not, hidden for a while: all kept here.
@MainActor
@Observable
final class PetLibrary {
    static let shared = PetLibrary()

    /// "whale" (Clio's own), "none", or an imported pack's id.
    var choice: String { didSet { UserDefaults.standard.set(choice, forKey: "pet.choice") } }
    /// "small", "standard", "large" or "custom".
    var size: String { didSet { UserDefaults.standard.set(size, forKey: "pet.size") } }
    /// Custom size, as a share of standard: 0.5…3.
    var custom: Double { didSet { UserDefaults.standard.set(custom, forKey: "pet.custom") } }
    /// Moves, but never speaks up in a bubble.
    var quiet: Bool { didSet { UserDefaults.standard.set(quiet, forKey: "pet.quiet") } }
    /// Put away until then.
    var hiddenUntil: Date? { didSet { UserDefaults.standard.set(hiddenUntil?.timeIntervalSince1970, forKey: "pet.hiddenUntil") } }
    private(set) var packs: [PetPack] = []

    private init() {
        let store = UserDefaults.standard
        // Whoever had put the old companion figure away keeps it away.
        let fallback = store.object(forKey: "mascot.shown") as? Bool == false ? "none" : "whale"
        choice = store.string(forKey: "pet.choice") ?? fallback
        size = store.string(forKey: "pet.size") ?? "standard"
        custom = store.object(forKey: "pet.custom") as? Double ?? 1
        quiet = store.bool(forKey: "pet.quiet")
        hiddenUntil = (store.object(forKey: "pet.hiddenUntil") as? Double).map(Date.init(timeIntervalSince1970:))
        reload()
    }

    var shown: Bool { choice != "none" && (hiddenUntil.map { $0 < Date() } ?? true) }
    var pack: PetPack? { packs.first { $0.id == choice } }

    /// How much bigger than standard.
    var factor: Double {
        switch size {
        case "small": 0.75
        case "large": 1.35
        case "custom": min(3, max(0.5, custom))
        default: 1
        }
    }

    var folder: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("pets", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func reload() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        packs = dirs.filter { !$0.lastPathComponent.hasPrefix(".") }.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("pack.json")) else { return nil }
            return try? PetPack.parse(data, dir: dir, id: dir.lastPathComponent)
        }.sorted { $0.name < $1.name }
        if choice != "whale", choice != "none", pack == nil { choice = "whale" }
    }

    /// Puts the pet away for an hour; it comes back by itself.
    func hideForAnHour() { hiddenUntil = Date().addingTimeInterval(3600) }

    /// The next pet in the list, for 换宠物 on the pet itself.
    func next() {
        let all = ["whale"] + packs.map(\.id)
        let at = all.firstIndex(of: choice) ?? -1
        choice = all[(at + 1) % all.count]
    }

    func delete(_ id: String) {
        guard id.hasPrefix("user-") else { return }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(id))
        PetSheets.forget(id)
        if choice == id { choice = "whale" }
        reload()
    }

    // MARK: Importing a pack

    /// Takes a pet-pack zip (schema 1: `pack.json` and its PNG sheets, at the top or in one folder),
    /// checks everything it names, and keeps only those files. The same pack imported again replaces the old one.
    func install(_ zip: URL) throws -> PetPack {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("pet-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: scratch) }
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        let reading = zip.startAccessingSecurityScopedResource()
        defer { if reading { zip.stopAccessingSecurityScopedResource() } }
        let size = (try? zip.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= 64 << 20 else { throw PetPack.Problem.bad("包太大了（超过 64 MB）") }

        let archive: Archive
        do { archive = try Archive(url: zip, accessMode: .read) } catch { throw PetPack.Problem.bad("打不开这个 zip") }
        var entries = 0, unpacked = 0
        for entry in archive {
            entries += 1
            unpacked += Int(entry.uncompressedSize)
            guard entries <= 256, unpacked <= 64 << 20 else { throw PetPack.Problem.bad("包里的文件太多或太大") }
            guard entry.type == .file else { continue }
            let path = entry.path
            guard !path.hasPrefix("/"), !path.split(separator: "/").contains(".."), !path.hasPrefix("__MACOSX") else { continue }
            let target = scratch.appendingPathComponent(path)
            guard target.standardizedFileURL.path.hasPrefix(scratch.standardizedFileURL.path) else { continue }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = try archive.extract(entry, to: target)
        }

        // pack.json at the top, or in exactly one folder.
        var candidates: [URL] = []
        let top = scratch.appendingPathComponent("pack.json")
        if fm.fileExists(atPath: top.path) { candidates = [top] } else {
            for dir in (try? fm.contentsOfDirectory(at: scratch, includingPropertiesForKeys: nil)) ?? [] {
                let inner = dir.appendingPathComponent("pack.json")
                if fm.fileExists(atPath: inner.path) { candidates.append(inner) }
            }
        }
        guard candidates.count == 1, let manifest = candidates.first else {
            throw PetPack.Problem.bad(candidates.isEmpty ? "包里找不到 pack.json（这里认 DSH Go / Clawd 那种 schema 1 宠物包）" : "包里有好几个 pack.json，不知道用哪个")
        }
        let base = manifest.deletingLastPathComponent()
        let data = try Data(contentsOf: manifest)
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PetPack.Problem.bad("pack.json 读不懂") }
        let id = Self.folderName(raw["id"] as? String ?? raw["name"] as? String ?? "pet")
        let pack = try PetPack.parse(data, dir: base, id: id)

        // Every sheet it names: there, a real PNG, not too big, and every frame inside it.
        var total = 0
        let sheets = Set(pack.animations.values.map(\.sheet))
        guard sheets.count <= 64 else { throw PetPack.Problem.bad("图太多了（最多 64 张）") }
        for name in sheets {
            let url = base.appendingPathComponent(name)
            guard let bytes = try? Data(contentsOf: url) else { throw PetPack.Problem.bad("少了图：\(name)") }
            total += bytes.count
            guard bytes.count <= 8 << 20, total <= 48 << 20 else { throw PetPack.Problem.bad("图太大了：\(name)") }
            guard bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]), let image = UIImage(data: bytes)?.cgImage else { throw PetPack.Problem.bad("不是能用的 PNG：\(name)") }
            guard image.width <= 4096, image.height <= 4096 else { throw PetPack.Problem.bad("图的边长超过 4096：\(name)") }
            for (animName, anim) in pack.animations where anim.sheet == name {
                for frame in anim.frames {
                    let col = frame.i % anim.cols, row = frame.i / anim.cols
                    guard (col + 1) * anim.frameW <= image.width, (row + 1) * anim.frameH <= image.height else {
                        throw PetPack.Problem.bad("动画「\(animName)」有一帧落在图外面")
                    }
                }
            }
        }

        // Only pack.json and its sheets are kept; the old version is swapped out in one step.
        let staging = folder.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try data.write(to: staging.appendingPathComponent("pack.json"))
        for name in sheets { try fm.copyItem(at: base.appendingPathComponent(name), to: staging.appendingPathComponent(name)) }
        let final = folder.appendingPathComponent(id, isDirectory: true)
        if fm.fileExists(atPath: final.path) {
            _ = try fm.replaceItemAt(final, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: final)
        }
        PetSheets.forget(id)
        reload()
        guard let installed = packs.first(where: { $0.id == id }) else { throw PetPack.Problem.bad("装好了却读不出来") }
        return installed
    }

    /// A folder name from the pack's id: lowercase letters, digits and dashes, with `user-` in front.
    private static func folderName(_ raw: String) -> String {
        let cleaned = raw.lowercased().map { ch -> Character in (ch.isASCII && (ch.isLetter || ch.isNumber)) ? ch : "-" }
        var name = String(cleaned).split(separator: "-").joined(separator: "-")
        if name.isEmpty || name.count > 40 {
            let hash = raw.unicodeScalars.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1.value)) &* 1099511628211 }
            name = String(name.prefix(24)) + (name.isEmpty ? "" : "-") + String(hash, radix: 16).prefix(8)
        }
        return name.hasPrefix("user-") ? name : "user-" + name
    }
}

/// What the pet has to say: something finished, failed or waits for you in a conversation.
/// In the conversation on screen it only moves; about another one it shows a bubble.
@MainActor
@Observable
final class PetNews {
    static let shared = PetNews()

    enum Kind { case done, failed, approval, answer
        var key: String {
            switch self {
            case .done: "pet.done"
            case .failed: "pet.failed"
            case .approval: "pet.needsApproval"
            case .answer: "pet.needsAnswer"
            }
        }
        var seconds: Double {
            switch self {
            case .done: 4
            case .failed: 6
            case .approval, .answer: 8
            }
        }
    }

    struct Bubble: Identifiable, Equatable {
        let id = UUID()
        var kind: Kind
        var chat: String
        var text: String
    }

    /// The conversation on screen, if any.
    var focused: String?
    /// The latest thing that happened in the focused conversation, for the pet to act out.
    private(set) var react: (kind: Kind, at: Date)?
    private(set) var bubble: Bubble?
    private var batch: [(kind: Kind, chat: String, title: String, at: Date)] = []

    func post(_ kind: Kind, chat: String, title: String) {
        if chat == focused {
            react = (kind, Date())
            return
        }
        let library = PetLibrary.shared
        guard library.shown, !library.quiet else { return }
        // Several in two seconds become one bubble; something waiting for you comes first.
        let now = Date()
        batch = batch.filter { now.timeIntervalSince($0.at) < 2 } + [(kind, chat, title, now)]
        let waiting = batch.last { $0.kind == .approval || $0.kind == .answer }
        let lead = waiting ?? batch[batch.count - 1]
        let short = lead.title.count > 12 ? String(lead.title.prefix(12)) + "…" : lead.title
        let text = batch.count > 1 && waiting == nil ? "\(batch.count) 个\(L.t("chat.conversation"))\(L.t(kind.key))" : "\(short) · \(L.t(lead.kind.key))"
        let shown = Bubble(kind: lead.kind, chat: lead.chat, text: text)
        bubble = shown
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(lead.kind.seconds * 1_000_000_000))
            if self.bubble?.id == shown.id { self.bubble = nil }
        }
    }

    func dismiss() { bubble = nil }
}
