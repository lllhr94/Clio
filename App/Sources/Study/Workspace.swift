import AgentKit
import Craft
import Darwin
import Foundation
import ImageIO
import UIKit
import JavaScriptCore
import PDFKit
import UniformTypeIdentifiers

/// An external folder (iCloud Drive, Obsidian vault, another app's folder) attached to 书案 via a security-scoped bookmark.
struct MountedFolder: Codable, Identifiable, Equatable, Hashable, Sendable {
    var id: String
    /// Unique folder name shown under 书案/挂载/<name>.
    var name: String
    /// iOS security-scoped bookmark data.
    var bookmark: Data
    var addedAt: Double
}

/// Manages external folders mounted into 书案/挂载/<name>. Removing a mount only deletes the bookmark, never the files.
enum MountedFolders {
    static let virtualFolder = "挂载"
    static let changed = Notification.Name("clio.mountsChanged")

    struct Inspection: Identifiable, Sendable {
        var mount: MountedFolder
        var url: URL?
        var stale: Bool
        var accessible: Bool
        var id: String { mount.id }
    }

    /// Holds an open security-scoped resource for UI browsing and releases it on stop or deinit.
    final class ScopeToken: @unchecked Sendable {
        private let url: URL
        private let lock = NSLock()
        private var active: Bool

        init(url: URL) {
            self.url = url
            self.active = url.startAccessingSecurityScopedResource()
        }

        var isActive: Bool { lock.withLock { active } }

        func stop() {
            let shouldStop: Bool = lock.withLock {
                guard active else { return false }
                active = false
                return true
            }
            if shouldStop { url.stopAccessingSecurityScopedResource() }
        }

        deinit { stop() }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [MountedFolder]?

    private static func allUnlocked(fresh: Bool) -> [MountedFolder] {
        if !fresh, let cache { return cache }
        let loaded = Disk.load([MountedFolder].self, "mounts.json") ?? []
        cache = loaded
        return loaded
    }

    private static func saveUnlocked(_ list: [MountedFolder]) {
        cache = list
        Disk.save(list, "mounts.json")
    }

    private static func notifyChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    static func all(fresh: Bool = false) -> [MountedFolder] {
        lock.withLock { allUnlocked(fresh: fresh) }
    }

    static func named(_ name: String) -> MountedFolder? {
        all().first { $0.name == name }
    }

    private static func safeName(_ raw: String) -> String {
        let cleaned = raw
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." { return "文件夹" }
        return String(cleaned.prefix(48))
    }

    private static func uniqueName(from raw: String, excluding id: String? = nil, in list: [MountedFolder]) -> String {
        let base = safeName(raw)
        let taken = Set(list.filter { $0.id != id }.map(\.name))
        guard taken.contains(base) else { return base }
        var number = 2
        while taken.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }

    private static func validateExternalFolder(_ url: URL) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw WorkspaceError.cannot("请选择一个文件夹，而不是单个文件。")
        }
        let real = url.resolvingSymlinksInPath().standardizedFileURL.path
        var protectedURLs: [URL] = [Workspace.root, Disk.root]
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            protectedURLs.append(appSupport)
        }
        if let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first {
            protectedURLs.append(library)
        }
        for protected in protectedURLs {
            let protectedReal = protected.resolvingSymlinksInPath().standardizedFileURL.path
            if real == protectedReal || real.hasPrefix(protectedReal + "/") || protectedReal.hasPrefix(real + "/") {
                throw WorkspaceError.cannot(Words.t("不能把书案或 Clio 内部目录重复挂载进来。"))
            }
        }
    }

    /// Attaches a user-picked external folder by storing its security-scoped bookmark.
    @discardableResult
    static func add(_ url: URL) throws -> MountedFolder {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        try validateExternalFolder(url)
        let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let pickedReal = url.resolvingSymlinksInPath().standardizedFileURL.path
        let result: MountedFolder = lock.withLock {
            var list = allUnlocked(fresh: true)
            // Re-picking an already-mounted folder refreshes its bookmark instead of creating a duplicate.
            for index in list.indices {
                var stale = false
                if let existing = try? URL(resolvingBookmarkData: list[index].bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale),
                   existing.resolvingSymlinksInPath().standardizedFileURL.path == pickedReal {
                    list[index].bookmark = bookmark
                    saveUnlocked(list)
                    return list[index]
                }
            }
            let name = uniqueName(from: url.lastPathComponent, in: list)
            let mount = MountedFolder(id: UUID().uuidString, name: name, bookmark: bookmark, addedAt: Date().timeIntervalSince1970)
            list.append(mount)
            saveUnlocked(list)
            return mount
        }
        notifyChanged()
        return result
    }

    /// Refreshes a stale or moved mount with a newly selected folder.
    @discardableResult
    static func reauthorize(id: String, with url: URL) throws -> MountedFolder {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        try validateExternalFolder(url)
        let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let updated: MountedFolder? = lock.withLock {
            var list = allUnlocked(fresh: true)
            guard let index = list.firstIndex(where: { $0.id == id }) else { return nil }
            list[index].bookmark = bookmark
            let pickedName = safeName(url.lastPathComponent)
            if pickedName != list[index].name {
                list[index].name = uniqueName(from: pickedName, excluding: id, in: list)
            }
            saveUnlocked(list)
            return list[index]
        }
        if let updated {
            notifyChanged()
            return updated
        }
        return try add(url)
    }

    /// Removes only the bookmark record. External files are never touched.
    static func remove(id: String) {
        lock.withLock {
            var list = allUnlocked(fresh: true)
            list.removeAll { $0.id == id }
            saveUnlocked(list)
        }
        notifyChanged()
    }

    private static func updateBookmark(id: String, data: Data) {
        let didUpdate: Bool = lock.withLock {
            var list = allUnlocked(fresh: true)
            guard let index = list.firstIndex(where: { $0.id == id }) else { return false }
            list[index].bookmark = data
            saveUnlocked(list)
            return true
        }
        if didUpdate { notifyChanged() }
    }

    /// Checks whether a mounted folder's bookmark can currently be resolved and accessed.
    static func inspect(_ mount: MountedFolder) -> Inspection {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: mount.bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return Inspection(mount: mount, url: nil, stale: true, accessible: false)
        }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard accessing else {
            return Inspection(mount: mount, url: url, stale: true, accessible: false)
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return Inspection(mount: mount, url: url, stale: true, accessible: false)
        }
        if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            updateBookmark(id: mount.id, data: fresh)
            stale = false
        }
        return Inspection(mount: mount, url: url, stale: stale, accessible: true)
    }

    /// Opens a security-scoped folder for UI navigation. Caller must call `token.stop()` when leaving.
    static func openForUI(_ mount: MountedFolder) -> (url: URL, token: ScopeToken)? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: mount.bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return nil
        }
        let token = ScopeToken(url: url)
        guard token.isActive else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            token.stop()
            return nil
        }
        if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            updateBookmark(id: mount.id, data: fresh)
        }
        return (url, token)
    }

    /// Resolves a mount, enters its security scope, guards against symlink escape, and runs `body`.
    static func withAccess<T>(_ mount: MountedFolder, innerParts: [String] = [], body: (_ root: URL, _ target: URL) throws -> T) throws -> T {
        var stale = false
        let rootURL: URL
        do {
            rootURL = try URL(resolvingBookmarkData: mount.bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch {
            throw WorkspaceError.cannot(Words.t("挂载的文件夹「\(mount.name)」授权已失效，请在书案里重新选择这个文件夹。"))
        }
        let accessing = rootURL.startAccessingSecurityScopedResource()
        guard accessing else {
            throw WorkspaceError.cannot(Words.t("挂载的文件夹「\(mount.name)」授权已失效，请在书案里重新选择这个文件夹。"))
        }
        defer { rootURL.stopAccessingSecurityScopedResource() }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDir), isDir.boolValue else {
            throw WorkspaceError.cannot(Words.t("挂载的文件夹「\(mount.name)」找不到了（可能已被移动或改名），请在书案里重新选择。"))
        }
        if stale, let fresh = try? rootURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            updateBookmark(id: mount.id, data: fresh)
        }
        let target = innerParts.reduce(rootURL) { $0.appendingPathComponent($1) }
        guard Workspace.isInsideRealRoot(target, root: rootURL) else {
            throw WorkspaceError.cannot("这个路径是指向挂载文件夹「\(mount.name)」外面的软链接，不能访问。")
        }
        return try body(rootURL, target)
    }

    /// Async counterpart to `withAccess` for tools that await inside a mounted folder.
    static func withAccessAsync<T>(_ mount: MountedFolder, innerParts: [String] = [], body: (_ root: URL, _ target: URL) async throws -> T) async throws -> T {
        var stale = false
        let rootURL: URL
        do {
            rootURL = try URL(resolvingBookmarkData: mount.bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch {
            throw WorkspaceError.cannot(Words.t("挂载的文件夹「\(mount.name)」授权已失效，请在书案里重新选择这个文件夹。"))
        }
        let accessing = rootURL.startAccessingSecurityScopedResource()
        guard accessing else {
            throw WorkspaceError.cannot(Words.t("挂载的文件夹「\(mount.name)」授权已失效，请在书案里重新选择这个文件夹。"))
        }
        defer { rootURL.stopAccessingSecurityScopedResource() }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDir), isDir.boolValue else {
            throw WorkspaceError.cannot(Words.t("挂载的文件夹「\(mount.name)」找不到了（可能已被移动或改名），请在书案里重新选择。"))
        }
        if stale, let fresh = try? rootURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            updateBookmark(id: mount.id, data: fresh)
        }
        let target = innerParts.reduce(rootURL) { $0.appendingPathComponent($1) }
        guard Workspace.isInsideRealRoot(target, root: rootURL) else {
            throw WorkspaceError.cannot("这个路径是指向挂载文件夹「\(mount.name)」外面的软链接，不能访问。")
        }
        return try await body(rootURL, target)
    }
}

/// 书案: the companions' working folder. It lives in the app's Documents, so the Files app shows it too.
/// External folders attached via `MountedFolders` appear virtually at `书案/挂载/<name>/…`.
enum Workspace {
    enum Target {
        case desk(url: URL, relative: String)
        case mountsRoot
        case mounted(mount: MountedFolder, innerParts: [String], relative: String)
    }

    static var root: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("书案", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// A path the model wrote, kept inside the local desk. Nil when it tries to step outside.
    static func resolve(_ path: String?) -> URL? {
        guard let parts = cleanParts(path) else { return nil }
        let url = parts.reduce(root) { $0.appendingPathComponent($1) }
        guard isInsideRealRoot(url, root: root) else { return nil }
        return url
    }

    /// Parses a desk or mounted-folder path (`书案/a.md`, `/root/desk/a.md`, `挂载/<name>/a.md`, `书案/挂载/<name>/a.md`).
    static func parse(_ path: String?) throws -> Target {
        let raw = path ?? ""
        guard let parts = cleanParts(raw) else {
            throw WorkspaceError.cannot(Words.t("路径不能跳出书案：\(raw)"))
        }
        if parts.first == MountedFolders.virtualFolder {
            if parts.count == 1 { return .mountsRoot }
            let mountName = parts[1]
            guard let mount = MountedFolders.named(mountName) else {
                throw WorkspaceError.cannot(Words.t("没有叫「\(mountName)」的挂载文件夹。请先在书案里添加文件夹。"))
            }
            let inner = Array(parts.dropFirst(2))
            return .mounted(mount: mount, innerParts: inner, relative: parts.joined(separator: "/"))
        }
        let url = parts.reduce(root) { $0.appendingPathComponent($1) }
        guard isInsideRealRoot(url, root: root) else {
            throw WorkspaceError.cannot(Words.t("这个路径是指向书案外面的链接，不能用：\(raw)"))
        }
        let relative = parts.isEmpty ? "/" : parts.joined(separator: "/")
        return .desk(url: url, relative: relative)
    }

    private static func cleanParts(_ path: String?) -> [String]? {
        var cleaned = (path ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["/root/desk/", "书案/"] where cleaned.hasPrefix(prefix) {
            cleaned = String(cleaned.dropFirst(prefix.count))
        }
        if cleaned == "/root/desk" || cleaned == "书案" { cleaned = "" }
        while cleaned.hasPrefix("/") { cleaned.removeFirst() }
        if cleaned.hasPrefix("书案/") { cleaned.removeFirst(3) }
        let parts = cleaned.split(separator: "/").map(String.init).filter { !$0.isEmpty && $0 != "." }
        if parts.contains("..") { return nil }
        return parts
    }

    /// True only when `url` (including existing ancestors and any symlinks, even dangling ones) stays within `root`.
    static func isInsideRealRoot(_ url: URL, root: URL) -> Bool {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        func contained(_ path: String) -> Bool { path == base || path.hasPrefix(base + "/") }

        let resolvedTarget = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard contained(resolvedTarget) else { return false }

        // Walk upward to verify every existing prefix (catches intermediate symlinks before non-existent write targets
        // and dangling symlinks pointing outside the root).
        let fm = FileManager.default
        let rootStd = root.standardizedFileURL.path
        var current = url.standardizedFileURL
        while true {
            var st = stat()
            if lstat(current.path, &st) == 0 {
                let isLink = (st.st_mode & S_IFMT) == S_IFLNK
                if isLink {
                    let linkResolved = current.resolvingSymlinksInPath().standardizedFileURL.path
                    guard contained(linkResolved) else { return false }
                    if let dest = try? fm.destinationOfSymbolicLink(atPath: current.path) {
                        let destURL: URL
                        if dest.hasPrefix("/") {
                            destURL = URL(fileURLWithPath: dest).standardizedFileURL
                        } else {
                            destURL = current.deletingLastPathComponent().appendingPathComponent(dest).standardizedFileURL
                        }
                        guard contained(destURL.resolvingSymlinksInPath().standardizedFileURL.path) else { return false }
                    }
                } else {
                    guard contained(current.resolvingSymlinksInPath().standardizedFileURL.path) else { return false }
                }
            }
            if current.path == rootStd || current.path == base || current.path == "/" { break }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return true
    }

    static func relative(_ url: URL, to baseRoot: URL = Workspace.root, prefix: String = "") -> String {
        let base = baseRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let rawBase = baseRoot.standardizedFileURL.path
        let rawPath = url.standardizedFileURL.path
        let rest: String
        if path.hasPrefix(base) {
            rest = String(path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else if rawPath.hasPrefix(rawBase) {
            rest = String(rawPath.dropFirst(rawBase.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else {
            rest = url.lastPathComponent
        }
        if prefix.isEmpty { return rest.isEmpty ? "/" : rest }
        return rest.isEmpty ? prefix : "\(prefix)/\(rest)"
    }

    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// Everything under a folder, a few levels deep, the way `tree` shows it. Symlinks escaping `baseRoot` are skipped.
    static func listing(_ folder: URL, depth: Int = 3, root baseRoot: URL = Workspace.root) -> String {
        var lines: [String] = []
        func walk(_ url: URL, _ level: Int) {
            guard lines.count < 300 else { return }
            let items = ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? [])
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            for item in items {
                guard isInsideRealRoot(item, root: baseRoot) else { continue }
                let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey])
                let indent = String(repeating: "  ", count: level)
                if values?.isDirectory == true {
                    lines.append("\(indent)\(item.lastPathComponent)/")
                    if level + 1 < depth && values?.isSymbolicLink != true { walk(item, level + 1) }
                } else {
                    lines.append("\(indent)\(item.lastPathComponent)  \(size(values?.fileSize ?? 0))")
                }
            }
        }
        walk(folder, 0)
        return lines.isEmpty ? "（空的）" : lines.joined(separator: "\n")
    }

    /// Every regular file under a folder, skipping symlinks that escape `baseRoot`.
    static func files(under folder: URL, cap: Int = 5000, root baseRoot: URL = Workspace.root, prefix: String = "") -> [(path: String, size: Int, date: Date)] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]
        var found: [(path: String, size: Int, date: Date)] = []
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        for case let url as URL in walker {
            if Task.isCancelled { break }
            guard isInsideRealRoot(url, root: baseRoot) else { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            found.append((relative(url, to: baseRoot, prefix: prefix), values.fileSize ?? 0, values.contentModificationDate ?? .distantPast))
            if found.count >= cap { break }
        }
        return found
    }

    static func globRegex(_ pattern: String) -> NSRegularExpression? { Glob.regex(pattern) }

    static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool { Glob.matches(regex, text) }

    /// A picture in 书案 (or a mounted folder), made small enough to send: at most 1280 pixels on its long side, JPEG.
    static func picture(_ file: URL, longest: Int = 1280) -> (data: Data, width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longest,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let target = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(target, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(target) else { return nil }
        return (data as Data, image.width, image.height)
    }

    /// Reads file bytes from either the local desk or a mounted external folder.
    static func readBytes(_ path: String?) throws -> (data: Data, displayPath: String) {
        switch try parse(path) {
        case .desk(let url, let rel):
            return (try Data(contentsOf: url), rel)
        case .mountsRoot:
            throw WorkspaceError.cannot("挂载目录是文件夹，请指定具体文件。")
        case .mounted(let mount, let inner, let rel):
            guard !inner.isEmpty else { throw WorkspaceError.cannot("请指定挂载文件夹里的具体文件。") }
            return try MountedFolders.withAccess(mount, innerParts: inner) { _, target in
                (try Data(contentsOf: target), rel)
            }
        }
    }

    private final class PreReadCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: Set<String> = []
        private var entries: [(path: String, preRead: Snapshots.PreRead)] = []

        func recordOnce(path: String, capture: () -> Snapshots.PreRead) {
            lock.withLock {
                guard !seen.contains(path) else { return }
                seen.insert(path)
                entries.append((path, capture()))
            }
        }

        func drain() -> [(path: String, preRead: Snapshots.PreRead)] {
            lock.withLock { entries }
        }
    }

    /// Writes file bytes to either the local desk or a mounted external folder.
    static func writeBytes(_ path: String?, data: Data) throws {
        switch try parse(path) {
        case .desk(let url, let rel):
            guard rel != "/" else { throw WorkspaceError.cannot("要写到哪个文件？") }
            var st = stat()
            if lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFLNK {
                throw WorkspaceError.cannot("目标路径是软链接，不能覆盖：\(rel)")
            }
            let parent = url.deletingLastPathComponent()
            guard isInsideRealRoot(parent, root: root) else {
                throw WorkspaceError.cannot(Words.t("目标路径跳出了书案，不能写入：\(rel)"))
            }
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        case .mountsRoot:
            throw WorkspaceError.cannot("不能直接写到挂载根目录，请指定某个挂载文件夹里的文件路径。")
        case .mounted(let mount, let inner, _):
            guard !inner.isEmpty else { throw WorkspaceError.cannot("要写到挂载文件夹里的哪个文件？") }
            try MountedFolders.withAccess(mount, innerParts: inner) { rootURL, target in
                var st = stat()
                if lstat(target.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFLNK {
                    throw WorkspaceError.cannot("目标路径是软链接，不能覆盖。")
                }
                let parent = target.deletingLastPathComponent()
                guard isInsideRealRoot(parent, root: rootURL) else {
                    throw WorkspaceError.cannot("这个路径通过软链接跳出了挂载文件夹「\(mount.name)」，不能写入。")
                }
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                try data.write(to: target, options: .atomic)
            }
        }
    }

    /// What only 书案 has: deleting, and a quick JavaScript calculator. Reading, writing and finding are the workspace tools.
    static func tools(
        beforeChange: (@Sendable (String) async -> Void)? = nil,
        recordPreRead: (@Sendable (String, Snapshots.PreRead) async -> Void)? = nil
    ) -> [AgentTool] {
        let pathParameter: JSONValue = ["type": "string", "description": "书案里的相对路径，比如 notes/旅行.md 或 挂载/Obsidian/笔记.md"]
        var tools: [AgentTool] = []
        tools.append(DeskTool(name: "desk_delete", description: "删掉书案（或挂载文件夹）里的文件或子文件夹。", parameters: ["type": "object", "properties": ["path": pathParameter], "required": ["path"]], label: { "书案：删 \($0["path"]?.string ?? "")" }, approval: { arguments in
            ApprovalAsk(title: Words.t("删掉书案里的东西"), reason: arguments["path"]?.string ?? "")
        }) { arguments in
            let target: Target
            do {
                target = try parse(arguments["path"]?.string)
            } catch {
                return ToolOutput(error.localizedDescription, isError: true)
            }
            switch target {
            case .desk(let file, let rel):
                guard rel != "/" else { return ToolOutput("不能删整个书案。", isError: true) }
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir) else { return ToolOutput("没有这个：\(rel)", isError: true) }
                if !isDir.boolValue { await beforeChange?(rel) }
                try FileManager.default.removeItem(at: file)
                return ToolOutput("删掉了 \(rel)")
            case .mountsRoot:
                return ToolOutput("不能删挂载目录；要取消挂载请在文件页面移除书签。", isError: true)
            case .mounted(let mount, let inner, let rel):
                guard !inner.isEmpty else {
                    return ToolOutput("不能删挂载的整个文件夹「\(mount.name)」；取消挂载只会删书签，请在文件页面操作。", isError: true)
                }
                let existsAndIsFile: Bool
                do {
                    existsAndIsFile = try MountedFolders.withAccess(mount, innerParts: inner) { _, file in
                        var isDir: ObjCBool = false
                        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir) else {
                            throw WorkspaceError.missing(rel)
                        }
                        return !isDir.boolValue
                    }
                } catch {
                    return ToolOutput(error.localizedDescription, isError: true)
                }
                if existsAndIsFile { await beforeChange?(rel) }
                do {
                    return try MountedFolders.withAccess(mount, innerParts: inner) { _, file in
                        guard FileManager.default.fileExists(atPath: file.path) else { return ToolOutput("没有这个：\(rel)", isError: true) }
                        try FileManager.default.removeItem(at: file)
                        return ToolOutput("删掉了 \(rel)")
                    }
                } catch {
                    return ToolOutput(error.localizedDescription, isError: true)
                }
            }
        })
        tools.append(DeskTool(name: "photo_text", description: "读出图片上的字（中文、英文都行）：用户发来的照片（给对话里［］中写的照片编号），或书案/挂载文件夹里的图片（给相对路径）。看不了图的模型也能靠它读题目、截图、文件照片。机器识别，可能有错字。", parameters: ["type": "object", "properties": ["photo": ["type": "string", "description": "照片编号，或书案里的图片路径"]], "required": ["photo"]], label: { "读图上的字：\(($0["photo"]?.string ?? "").prefix(24))" }) { arguments in
            let name = arguments["photo"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // A photo sent in a chat is a bare file name; anything with a folder in it is a path in 书案.
            let photoData = name.contains("/") ? nil : Disk.photo(name)
            let resolvedData: Data?
            if let photoData {
                resolvedData = photoData
            } else {
                resolvedData = try? readBytes(name).data
            }
            guard let data = resolvedData, let image = UIImage(data: data) else {
                return ToolOutput("找不到这张图：\(name)。用户发的照片给编号，书案里的图给路径。", isError: true)
            }
            let text = await Scan.read(image)
            guard !text.isEmpty else { return ToolOutput("这张图上没认出字。") }
            return ToolOutput("图上的字（机器识别，可能有错字）：\n\n" + String(text.prefix(12_000)))
        })
        tools.append(DeskTool(name: "read_pdf", description: "读书案（或挂载文件夹）里的 PDF：论文、说明书、合同、报告。按页读，长的分段读（from 从第几页起，pages 读几页，默认 15）。扫描件没有文字层的页，会自动认字。", parameters: ["type": "object", "properties": ["path": pathParameter, "from": ["type": "number", "description": "从第几页读起，默认 1"], "pages": ["type": "number", "description": "读几页，默认 15，最多 40"]], "required": ["path"]], label: { "读 PDF：\(($0["path"]?.string ?? "").split(separator: "/").last ?? "")" }) { arguments in
            let rawPath = arguments["path"]?.string ?? ""
            let loaded: (data: Data, displayPath: String)
            do {
                loaded = try readBytes(rawPath)
            } catch let failure as WorkspaceError {
                return ToolOutput(failure.localizedDescription, isError: true)
            } catch {
                return ToolOutput("书案里没有这个文件：\(rawPath)", isError: true)
            }
            let from = (arguments["from"]?.int ?? 1)
            let count = min(40, max(1, (arguments["pages"]?.int ?? 15)))
            guard var reading = PDFText.read(loaded.data, from: from, count: count) else { return ToolOutput("\(loaded.displayPath) 打不开，可能不是 PDF、坏了或加了密码。", isError: true) }
            // Pages that are only pictures: read the words off them, a few at a time.
            let blank = reading.blank.prefix(5)
            if !blank.isEmpty, let document = PDFDocument(data: loaded.data) {
                for number in blank {
                    guard let page = document.page(at: number - 1) else { continue }
                    let bounds = page.bounds(for: .mediaBox)
                    let scale = 1600 / max(bounds.width, bounds.height, 1)
                    let image = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
                    let words = await Scan.read(image)
                    if let index = reading.read.firstIndex(where: { $0.number == number }), !words.isEmpty {
                        reading.read[index].text = "（扫描页，机器认的字，可能有错）\n" + words
                    }
                }
            }
            return ToolOutput(reading.shown(limit: 24_000))
        })
        tools.append(DeskTool(name: "search_docs", description: "在书案和挂载文件夹的资料里找和问题有关的段落：PDF、Markdown、文本、网页存档、表格都算。先用它找到在哪个文件哪一页，再用 read_pdf 或 read_file 细读。关键词用空格隔开。", parameters: ["type": "object", "properties": ["query": ["type": "string", "description": "关键词，比如：报销 发票 期限"], "folder": ["type": "string", "description": "只在这个文件夹里找（可不填，如 挂载/Obsidian）"]], "required": ["query"]], label: { "翻资料：\(($0["query"]?.string ?? "").prefix(20))" }) { arguments in
            let query = arguments["query"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !query.isEmpty else { return ToolOutput("要给关键词。", isError: true) }
            let target: Target
            do {
                target = try parse(arguments["folder"]?.string)
            } catch {
                return ToolOutput(error.localizedDescription, isError: true)
            }
            let documents: [(path: String, text: String)]
            let scopeName: String
            switch target {
            case .desk(let folder, let rel):
                scopeName = rel
                var collected = PaperShelf.documents(under: folder, root: Workspace.root)
                if rel == "/" {
                    for mount in MountedFolders.all() {
                        if let mountedDocs = try? MountedFolders.withAccess(mount, body: { rootURL, targetURL in
                            PaperShelf.documents(under: targetURL, root: rootURL, prefix: "\(MountedFolders.virtualFolder)/\(mount.name)")
                        }) {
                            collected.append(contentsOf: mountedDocs)
                        }
                    }
                }
                documents = collected
            case .mountsRoot:
                scopeName = MountedFolders.virtualFolder
                var collected: [(path: String, text: String)] = []
                for mount in MountedFolders.all() {
                    if let mountedDocs = try? MountedFolders.withAccess(mount, body: { rootURL, targetURL in
                        PaperShelf.documents(under: targetURL, root: rootURL, prefix: "\(MountedFolders.virtualFolder)/\(mount.name)")
                    }) {
                        collected.append(contentsOf: mountedDocs)
                    }
                }
                documents = collected
            case .mounted(let mount, let inner, let rel):
                scopeName = rel
                do {
                    documents = try MountedFolders.withAccess(mount, innerParts: inner) { rootURL, targetURL in
                        PaperShelf.documents(under: targetURL, root: rootURL, prefix: "\(MountedFolders.virtualFolder)/\(mount.name)")
                    }
                } catch {
                    return ToolOutput(error.localizedDescription, isError: true)
                }
            }
            guard !documents.isEmpty else { return ToolOutput("\(scopeName) 里还没有能翻的资料（PDF、md、txt 等）。用户可以从文件 App 把资料放进书案，或挂载外部文件夹。") }
            let hits = DocSearch.find(query, in: documents)
            return ToolOutput("翻了 \(documents.count) 份资料。" + DocSearch.shown(hits, query: query))
        })
        tools.append(DeskTool(name: "run_js", description: "跑一段 JavaScript 算东西：算数、处理文本和数据、生成表格。用 console.log 输出；最后一个表达式的值也会返回。可以用 readFile(path) 读书案和挂载文件夹里的文件，用 writeFile(path, text) 写书案本地文件（不能写挂载文件夹；写挂载文件夹请改用 write_file 或 edit_file）。没有网络，没有 DOM。最多跑 10 秒。", parameters: ["type": "object", "properties": ["code": ["type": "string"]], "required": ["code"]], label: { _ in "书案：演算" }) { arguments in
            let collector = PreReadCollector()
            let output = await Reckoner.run(
                arguments["code"]?.string ?? "",
                read: { path in (try? readBytes(path)).flatMap { String(data: $0.data, encoding: .utf8) } },
                write: { path, text in
                    guard let target = try? parse(path),
                          case .desk(let url, let rel) = target,
                          rel != "/",
                          isInsideRealRoot(url, root: root),
                          isInsideRealRoot(url.deletingLastPathComponent(), root: root) else {
                        return false
                    }
                    var st = stat()
                    if lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFLNK {
                        return false
                    }
                    if recordPreRead != nil {
                        collector.recordOnce(path: rel) {
                            var isDir: ObjCBool = false
                            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
                                return .absent
                            }
                            if isDir.boolValue { return .unreadable }
                            if let oldData = try? Data(contentsOf: url) {
                                return .bytes(oldData)
                            }
                            return .unreadable
                        }
                    }
                    do {
                        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try Data(text.utf8).write(to: url, options: .atomic)
                        return true
                    } catch {
                        return false
                    }
                }
            )
            if let recordPreRead {
                for item in collector.drain() {
                    await recordPreRead(item.path, item.preRead)
                }
            }
            return output
        })
        tools.append(DocMaker.tool(beforeChange: beforeChange))
        return tools
    }
}

/// One desk tool: its spec, how it shows, and what it does.
struct DeskTool: AgentTool {
    let spec: ToolSpec
    let shown: @Sendable (JSONValue) -> String
    let asking: (@Sendable (JSONValue) -> ApprovalAsk?)?
    let act: @Sendable (JSONValue) async throws -> ToolOutput

    init(name: String, description: String, parameters: JSONValue, label: @escaping @Sendable (JSONValue) -> String, approval: (@Sendable (JSONValue) -> ApprovalAsk?)? = nil, act: @escaping @Sendable (JSONValue) async throws -> ToolOutput) {
        spec = ToolSpec(name: name, description: description, parameters: parameters)
        shown = label
        asking = approval
        self.act = act
    }

    func label(for arguments: JSONValue) -> String { shown(arguments) }
    func approval(for arguments: JSONValue) -> ApprovalAsk? { asking?(arguments) }
    func run(_ arguments: JSONValue) async throws -> ToolOutput { try await act(arguments) }
}

/// Runs JavaScript off the main thread. The watchdog interrupts JavaScriptCore itself, not just its caller.
enum Reckoner {
    static func run(
        _ code: String,
        read: @escaping @Sendable (String) -> String? = { path in
            guard let file = Workspace.resolve(path) else { return nil }
            return try? String(contentsOf: file, encoding: .utf8)
        },
        write: @escaping @Sendable (String, String) -> Bool = { path, text in
            guard let file = Workspace.resolve(path) else { return false }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            return (try? Data(text.utf8).write(to: file, options: .atomic)) != nil
        }
    ) async -> ToolOutput {
        let run = Run()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let thread = Thread { continuation.resume(returning: evaluate(code, run: run, read: read, write: write)) }
                thread.stackSize = 8 << 20
                thread.start()
            }
        } onCancel: { run.cancel() }
    }

    private final class Run: @unchecked Sendable {
        private let deadline = DispatchTime.now() + .seconds(10)
        private let lock = NSLock()
        private var cancelled = false

        func cancel() { lock.withLock { cancelled = true } }

        var interruption: ToolOutput? {
            if lock.withLock({ cancelled }) { return ToolOutput("演算已取消。", isError: true) }
            if DispatchTime.now() >= deadline { return ToolOutput("演算超过 10 秒，已停止。", isError: true) }
            return nil
        }
    }

    // JavaScriptCore's C watchdog is SPI on Apple platforms. Resolve it at runtime and decline to start
    // if this OS does not provide it: executing with no watchdog leaves a worker running indefinitely.
    private typealias ShouldTerminate = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Bool
    private typealias SetLimit = @convention(c) (OpaquePointer?, Double, ShouldTerminate?, UnsafeMutableRawPointer?) -> Void
    private static let setLimit: SetLimit? = {
        guard let framework = dlopen("/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore", RTLD_LAZY | RTLD_LOCAL),
              let symbol = dlsym(framework, "JSContextGroupSetExecutionTimeLimit") else { return nil }
        return unsafeBitCast(symbol, to: SetLimit.self)
    }()

    private static let shouldTerminate: ShouldTerminate = { context, pointer in
        Reckoner.checkTime(context, pointer)
    }

    private static func checkTime(_ context: OpaquePointer?, _ pointer: UnsafeMutableRawPointer?) -> Bool {
        guard let context, let pointer, let group = JSContextGetGroup(context), let setLimit else { return true }
        let run = Unmanaged<Run>.fromOpaque(pointer).takeUnretainedValue()
        if run.interruption != nil { return true }
        // Explicitly re-arm the next check. Some WebKit versions only invoke this callback once otherwise.
        setLimit(group, 0.25, shouldTerminate, pointer)
        return false
    }

    private static func evaluate(_ code: String, run: Run, read: @escaping @Sendable (String) -> String?, write: @escaping @Sendable (String, String) -> Bool) -> ToolOutput {
        if let interruption = run.interruption { return interruption }
        guard let setLimit, let context = JSContext(), let group = JSContextGetGroup(context.jsGlobalContextRef) else {
            return ToolOutput("这个系统无法为演算设置超时。", isError: true)
        }
        setLimit(group, 0.25, shouldTerminate, Unmanaged.passUnretained(run).toOpaque())
        return withExtendedLifetime(run) { evaluate(code, context: context, run: run, read: read, write: write) }
    }

    private static func evaluate(_ code: String, context: JSContext, run: Run, read: @escaping @Sendable (String) -> String?, write: @escaping @Sendable (String, String) -> Bool) -> ToolOutput {
        let outputLimit = 12_000
        var printed = ""
        var clipped = false
        var failure: String?
        context.exceptionHandler = { _, exception in
            guard run.interruption == nil else { return }
            let line = exception?.objectForKeyedSubscript("line")?.toString() ?? "?"
            failure = "出错（第 \(line) 行）：\(exception?.toString() ?? "未知错误")"
        }
        let log: @convention(block) () -> Void = {
            guard printed.count < outputLimit, run.interruption == nil else { clipped = true; return }
            let words = (JSContext.currentArguments() as? [JSValue] ?? []).map(show).joined(separator: " ")
            if !printed.isEmpty { printed += "\n" }
            let left = max(0, outputLimit - printed.count)
            printed += words.prefix(left)
            if words.count > left { clipped = true }
        }
        let console = JSValue(newObjectIn: context)
        for name in ["log", "info", "warn", "error"] { console?.setObject(log, forKeyedSubscript: name as NSString) }
        context.setObject(console, forKeyedSubscript: "console" as NSString)
        let readFile: @convention(block) (String) -> Any = { path in
            guard run.interruption == nil, let text = read(path) else { return NSNull() }
            return text
        }
        let writeFile: @convention(block) (String, String) -> Bool = { path, text in
            guard run.interruption == nil else { return false }
            return write(path, text)
        }
        context.setObject(readFile, forKeyedSubscript: "readFile" as NSString)
        context.setObject(writeFile, forKeyedSubscript: "writeFile" as NSString)
        let result = context.evaluateScript(code)
        if let interruption = run.interruption { return interruption }
        var out = printed
        if let result, !result.isUndefined, failure == nil, !clipped {
            out += (out.isEmpty ? "" : "\n") + "→ " + show(result)
        }
        if let interruption = run.interruption { return interruption }
        if clipped || out.count > outputLimit { out = String(out.prefix(outputLimit)) + "\n……（输出太长，截断了）" }
        if let failure { return ToolOutput((out.isEmpty ? "" : out + "\n") + failure, isError: true) }
        return ToolOutput(out.isEmpty ? "（跑完了，没有输出）" : out)
    }

    private static func show(_ value: JSValue) -> String {
        if value.isString { return value.toString() }
        if value.isObject, let context = value.context,
           let json = context.objectForKeyedSubscript("JSON")?.invokeMethod("stringify", withArguments: [value, NSNull(), 2]), json.isString {
            return json.toString()
        }
        return value.toString() ?? ""
    }
}


/// The papers in 书案 (and mounted folders) as text, for `search_docs`. A PDF's text is kept aside after the first reading, until the file changes.
enum PaperShelf {
    static let kinds: Set<String> = ["pdf", "txt", "md", "markdown", "csv", "tsv", "json", "html", "htm", "xml", "yaml", "yml", "log", "org", "rst", "tex"]

    private static var shelf: URL {
        let folder = Disk.url("doccache")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func documents(under folder: URL, root baseRoot: URL = Workspace.root, prefix: String = "") -> [(path: String, text: String)] {
        var found: [(path: String, text: String)] = []
        var total = 0
        for file in Workspace.files(under: folder, cap: 3000, root: baseRoot, prefix: prefix) {
            let ext = (file.path as NSString).pathExtension.lowercased()
            guard kinds.contains(ext), file.size > 0, file.size < 40_000_000 else { continue }
            let relativeInside: String
            if !prefix.isEmpty, file.path.hasPrefix(prefix + "/") {
                relativeInside = String(file.path.dropFirst(prefix.count + 1))
            } else {
                relativeInside = file.path
            }
            let url = relativeInside.split(separator: "/").reduce(baseRoot) { $0.appendingPathComponent(String($1)) }
            guard Workspace.isInsideRealRoot(url, root: baseRoot) else { continue }
            // The text kept beside a PDF when it came in: the PDF itself is read instead, with its pages.
            if file.path.lowercased().hasSuffix(".pdf.txt") {
                let pdfPath = String(url.path.dropLast(4))
                if FileManager.default.fileExists(atPath: pdfPath) { continue }
            }
            guard let text = text(of: url, displayPath: file.path, ext: ext, size: file.size, date: file.date), !text.isEmpty else { continue }
            found.append((file.path, text))
            total += text.count
            if total > 30_000_000 { break }
        }
        return found
    }

    private static func text(of url: URL, displayPath: String, ext: String, size: Int, date: Date) -> String? {
        guard ext == "pdf" else {
            guard size < 8_000_000, let data = try? Data(contentsOf: url) else { return nil }
            let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16)
            return ext.hasPrefix("htm") ? text.map { WebText.page($0).text } : text
        }
        let name = String(format: "%016llx", Tide.fnv("\(displayPath)|\(size)|\(date.timeIntervalSince1970)")) + ".txt"
        let kept = shelf.appendingPathComponent(name)
        if let text = try? String(contentsOf: kept, encoding: .utf8) { return text }
        guard let data = try? Data(contentsOf: url), let text = PDFText.all(data) else { return nil }
        try? Data(text.utf8).write(to: kept, options: .atomic)
        return text
    }
}
