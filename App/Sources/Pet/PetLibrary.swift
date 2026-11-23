import Foundation
import ImageIO
import Observation
import UIKit
import ZIPFoundation

/// The pets on this phone: the bundled ones (小克, 肉包) and the ones you imported.
/// Which one is yours, whether it stands on the composer, how big, quiet or not, hidden for a while: all kept here.
/// The pet you pick is also every portrait and illustration in Clio, shown or not.
@MainActor
@Observable
final class PetLibrary {
    static let shared = PetLibrary()

    /// The pack that is yours. Bundled packs are "builtin-<folder>", imported ones "user-<name>".
    var choice: String { didSet { UserDefaults.standard.set(choice, forKey: "pet.choice") } }
    /// Stands on the composer. Off, it still appears in portraits and illustrations.
    var visible: Bool { didSet { UserDefaults.standard.set(visible, forKey: "pet.visible") } }
    /// Requested size relative to the 48-point standard, rounded for the current sprite and screen when drawn.
    var factor: Double { didSet { UserDefaults.standard.set(factor, forKey: "pet.sizeScale") } }
    /// Moves, but never speaks up in a bubble.
    var quiet: Bool { didSet { UserDefaults.standard.set(quiet, forKey: "pet.quiet") } }
    /// Put away until then.
    var hiddenUntil: Date? { didSet { UserDefaults.standard.set(hiddenUntil?.timeIntervalSince1970, forKey: "pet.hiddenUntil") } }
    private(set) var packs: [PetPack] = []
    private(set) var loading = true

    private init() {
        let store = UserDefaults.standard
        // From before there was only one kind of pet: "whale" (the old drawn figures) and "none" become 小克,
        // and whoever had put the figure away keeps it off the composer.
        let stored = store.string(forKey: "pet.choice")
        let old = stored == nil || stored == "whale" || stored == "none"
        choice = old ? Self.standard : stored!
        if let kept = store.object(forKey: "pet.visible") as? Bool {
            visible = kept
        } else {
            visible = !(stored == "none" || store.object(forKey: "mascot.shown") as? Bool == false)
        }
        let savedScale = store.object(forKey: "pet.sizeScale") as? Double
        let oldSize = store.string(forKey: "pet.size")
        factor = savedScale.flatMap { $0.isFinite && $0 > 0 ? min(3, $0) : nil }
            ?? PetSize.migrated(oldSize, custom: store.object(forKey: "pet.custom") as? Double ?? 1, uiScale: UIScale.factor)
        quiet = store.bool(forKey: "pet.quiet")
        hiddenUntil = (store.object(forKey: "pet.hiddenUntil") as? Double).map(Date.init(timeIntervalSince1970:))
        if savedScale == nil, oldSize != nil { store.set(factor, forKey: "pet.sizeScale") }
        Task { await reload() }
    }

    /// 小克: the pet every phone starts with, and the one that stands in if yours is gone.
    nonisolated static let standard = "builtin-xiaoke"

    /// On the composer now.
    var shown: Bool { visible && (hiddenUntil.map { $0 < Date() } ?? true) }
    /// Yours; 小克 if yours cannot be read.
    var pack: PetPack? { packs.first { $0.id == choice } ?? packs.first { $0.id == Self.standard } ?? packs.first }

    func pack(for face: String?) -> PetPack? {
        if let face, face.hasPrefix("pet:"),
           let own = packs.first(where: { $0.id == String(face.dropFirst(4)) }) { return own }
        return pack
    }

    nonisolated private static let packsFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("pets", isDirectory: true)

    private func reload() async {
        let found = await Task.detached(priority: .utility) {
            let bundled = Bundle.main.resourceURL.map { Self.loadPacks(in: $0.appendingPathComponent("Pets", isDirectory: true), idPrefix: "builtin-") } ?? []
            return bundled + Self.loadPacks(in: Self.packsFolder)
        }.value
        packs = Self.ordered(found)
        if !packs.isEmpty, !packs.contains(where: { $0.id == choice }) { choice = Self.standard }
        loading = false
    }

    private static func ordered(_ packs: [PetPack]) -> [PetPack] {
        packs.sorted {
            func rank(_ pack: PetPack) -> Int { pack.id == standard ? 0 : (pack.id.hasPrefix("builtin-") ? 1 : 2) }
            return (rank($0), $0.name) < (rank($1), $1.name)
        }
    }

    nonisolated private static func loadPacks(in root: URL, idPrefix: String = "") -> [PetPack] {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("pack.json")) else { return nil }
            let id = idPrefix + dir.lastPathComponent
            guard let pack = try? PetPack.parse(data, dir: dir, id: id) else { return nil }
            if !idPrefix.isEmpty {
                let sheets = Set(pack.animations.values.map(\.sheet))
                guard sheets.allSatisfy({ fm.fileExists(atPath: dir.appendingPathComponent($0).path) }) else { return nil }
            }
            return pack
        }
    }

    /// Puts the pet away for an hour; it comes back by itself.
    func hideForAnHour() { hiddenUntil = Date().addingTimeInterval(3600) }

    /// The next pet in the list, for 换宠物 on the pet itself.
    func next() {
        let all = packs.map(\.id)
        guard !all.isEmpty else { return }
        let at = all.firstIndex(of: choice) ?? -1
        choice = all[(at + 1) % all.count]
    }

    func canDelete(_ pack: PetPack) -> Bool {
        guard pack.id.hasPrefix("user-") else { return false }
        let parentPath = pack.dir.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        let rootPath = Self.packsFolder.resolvingSymlinksInPath().standardizedFileURL.path
        return parentPath == rootPath
    }

    func delete(_ id: String) {
        guard let pack = packs.first(where: { $0.id == id }), canDelete(pack) else { return }
        do { try FileManager.default.removeItem(at: pack.dir) } catch { return }
        PetSheets.forget(id)
        if choice == id { choice = Self.standard }
        packs.removeAll { $0.id == id }
    }

    // MARK: Importing a pack

    /// Takes a pet-pack zip (schema 1: `pack.json` and its PNG sheets, at the top or in one folder),
    /// checks everything it names, and keeps only those files. The same pack imported again replaces the old one.
    /// A single picture or animation (PNG, GIF, APNG, WebP) becomes a pet that only has its idle state.
    func install(_ zip: URL) async throws -> PetPack {
        let job = Task.detached(priority: .userInitiated) { try Self.unpack(zip) }
        let pack = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
        PetSheets.forget(pack.id)
        packs = Self.ordered(packs.filter { $0.id != pack.id } + [pack])
        return pack
    }

    nonisolated private static func unpack(_ zip: URL) throws -> PetPack {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("pet-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: scratch) }
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        let reading = zip.startAccessingSecurityScopedResource()
        defer { if reading { zip.stopAccessingSecurityScopedResource() } }
        guard let size = try zip.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            throw PetPack.Problem.bad("读不到宠物包的大小")
        }
        guard size <= 64 << 20 else { throw PetPack.Problem.bad("包太大了（超过 64 MB）") }

        let ext = zip.pathExtension.lowercased()
        if ext != "zip" {
            guard ["png", "gif", "apng", "webp"].contains(ext) else { throw PetPack.Problem.bad("认不得这种文件：用 zip、PNG、GIF 或 WebP") }
            try fm.copyItem(at: zip, to: scratch.appendingPathComponent("idle." + ext))
        }
        let archive: Archive? = ext == "zip" ? try? Archive(url: zip, accessMode: .read) : nil
        if ext == "zip", archive == nil { throw PetPack.Problem.bad("打不开这个 zip") }
        if let archive { try extract(archive, into: scratch) }

        // pack.json at the top, or in exactly one folder.
        var candidates: [URL] = []
        let top = scratch.appendingPathComponent("pack.json")
        if fm.fileExists(atPath: top.path) { candidates = [top] } else {
            for dir in (try? fm.contentsOfDirectory(at: scratch, includingPropertiesForKeys: nil)) ?? [] {
                let inner = dir.appendingPathComponent("pack.json")
                if fm.fileExists(atPath: inner.path) { candidates.append(inner) }
            }
        }
        // No pack.json: plain animations, one per state, made into a pack here.
        if candidates.isEmpty {
            candidates = [try PetConvert.build(from: scratch, name: zip.deletingPathExtension().lastPathComponent)]
        }
        guard candidates.count == 1, let manifest = candidates.first else {
            throw PetPack.Problem.bad("包里有好几个 pack.json，不知道用哪个")
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
        let noCache = [kCGImageSourceShouldCache: false] as CFDictionary
        for name in sheets {
            try autoreleasepool {
                let url = base.appendingPathComponent(name)
                guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { throw PetPack.Problem.bad("少了图：\(name)") }
                total += size
                guard size <= 8 << 20, total <= 48 << 20 else { throw PetPack.Problem.bad("图太大了：\(name)") }
                guard let source = CGImageSourceCreateWithURL(url as CFURL, noCache),
                      let type = CGImageSourceGetType(source), type as String == "public.png",
                      let dimensions = PetConvert.dimensions(source, at: 0) else {
                    throw PetPack.Problem.bad("不是能用的 PNG：\(name)")
                }
                guard dimensions.width <= 4096, dimensions.height <= 4096 else { throw PetPack.Problem.bad("图的边长超过 4096：\(name)") }
                guard CGImageSourceCreateImageAtIndex(source, 0, noCache) != nil else {
                    throw PetPack.Problem.bad("读不出这张 PNG：\(name)")
                }
                for (animName, anim) in pack.animations where anim.sheet == name {
                    for frame in anim.frames {
                        let col = frame.i % anim.cols, row = frame.i / anim.cols
                        guard (col + 1) * anim.frameW <= dimensions.width, (row + 1) * anim.frameH <= dimensions.height else {
                            throw PetPack.Problem.bad("动画「\(animName)」有一帧落在图外面")
                        }
                    }
                }
            }
        }

        // Only pack.json and its sheets are kept; the old version is swapped out in one step.
        let folder = packsFolder
        let staging = folder.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        try data.write(to: staging.appendingPathComponent("pack.json"))
        for name in sheets { try fm.copyItem(at: base.appendingPathComponent(name), to: staging.appendingPathComponent(name)) }
        try Task.checkCancellation()
        let final = folder.appendingPathComponent(id, isDirectory: true)
        if fm.fileExists(atPath: final.path) {
            _ = try fm.replaceItemAt(final, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: final)
        }
        return try PetPack.parse(data, dir: final, id: id)
    }

    nonisolated private static func extract(_ archive: Archive, into scratch: URL) throws {
        let fm = FileManager.default
        let limit = 64 << 20
        var written = 0
        for (index, entry) in archive.enumerated() {
            try Task.checkCancellation()
            guard index < 256 else { throw PetPack.Problem.bad("包里的文件太多或太大") }
            guard entry.type == .file else { continue }
            let path = entry.path
            guard !path.hasPrefix("/"), !path.split(separator: "/").contains(".."), !path.hasPrefix("__MACOSX") else { continue }
            let target = scratch.appendingPathComponent(path).standardizedFileURL
            guard target.path.hasPrefix(scratch.standardizedFileURL.path + "/") else { continue }
            guard entry.uncompressedSize <= UInt64(limit - written) else { throw PetPack.Problem.bad("包里的文件太多或太大") }

            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard !fm.fileExists(atPath: target.path), fm.createFile(atPath: target.path, contents: nil) else {
                throw PetPack.Problem.bad("包里有重复或无效的文件名")
            }
            let file = try FileHandle(forWritingTo: target)
            defer { try? file.close() }
            var size = 0
            let checksum = try archive.extract(entry) { chunk in
                guard chunk.count <= limit - written else { throw PetPack.Problem.bad("解开的文件超过 64 MB") }
                try Task.checkCancellation()
                try file.write(contentsOf: chunk)
                written += chunk.count
                size += chunk.count
            }
            guard UInt64(size) == entry.uncompressedSize, checksum == entry.checksum else {
                throw PetPack.Problem.bad("包里的文件大小或校验不对")
            }
        }
    }

    /// A folder name from the pack's id: lowercase letters, digits and dashes, with `user-` in front.
    nonisolated private static func folderName(_ raw: String) -> String {
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
