import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Breakdown of app storage under Application Support, highlighting safely reclaimable caches.
public struct StorageBreakdown: Equatable, Sendable {
    public var totalBytes: Int64
    public var mediaBytes: Int64
    public var chatsBytes: Int64
    public var studyBytes: Int64
    public var memoryBytes: Int64
    public var orphanMediaCount: Int
    public var orphanMediaBytes: Int64
    public var docCacheCount: Int
    public var docCacheBytes: Int64
    /// True if the reference scan was skipped or could not verify all manifests.
    public var scanSkippedOrphans: Bool

    public var cleanableBytes: Int64 { orphanMediaBytes + docCacheBytes }
    public var activeMediaBytes: Int64 { max(0, mediaBytes - orphanMediaBytes) }
    public var cacheBytes: Int64 { cleanableBytes }
    public var otherBytes: Int64 {
        max(0, totalBytes - chatsBytes - studyBytes - activeMediaBytes - memoryBytes - cacheBytes)
    }

    public init(
        totalBytes: Int64 = 0,
        mediaBytes: Int64 = 0,
        orphanMediaCount: Int = 0,
        orphanMediaBytes: Int64 = 0,
        docCacheCount: Int = 0,
        docCacheBytes: Int64 = 0,
        scanSkippedOrphans: Bool = false,
        chatsBytes: Int64 = 0,
        studyBytes: Int64 = 0,
        memoryBytes: Int64 = 0
    ) {
        self.totalBytes = totalBytes
        self.mediaBytes = mediaBytes
        self.chatsBytes = chatsBytes
        self.studyBytes = studyBytes
        self.memoryBytes = memoryBytes
        self.orphanMediaCount = orphanMediaCount
        self.orphanMediaBytes = orphanMediaBytes
        self.docCacheCount = docCacheCount
        self.docCacheBytes = docCacheBytes
        self.scanSkippedOrphans = scanSkippedOrphans
    }
}

/// Summary of files deleted during a safe cache cleanup pass.
public struct CleanupResult: Equatable, Sendable {
    public var removedMediaCount: Int
    public var removedDocCacheCount: Int
    public var freedBytes: Int64

    public init(removedMediaCount: Int = 0, removedDocCacheCount: Int = 0, freedBytes: Int64 = 0) {
        self.removedMediaCount = removedMediaCount
        self.removedDocCacheCount = removedDocCacheCount
        self.freedBytes = freedBytes
    }
}

/// Measures Clio's storage and safely reclaims unreferenced `media/` images and regenerable `doccache/` text extracts.
/// Never touches conversation JSONs, memories, notes, or referenced photos; fails closed if any chat file is unreadable.
public enum StorageCleanup {
    public static let mediaGraceSeconds: TimeInterval = 30 * 24 * 60 * 60

    private struct FileIdentity: Hashable {
        let device: UInt64
        let inode: UInt64
    }

    private struct FileInfo {
        let url: URL
        let name: String
        let bytes: Int64
        let modified: Date
        let identity: FileIdentity
    }

    private struct OrphanScan {
        var orphans: [FileInfo] = []
        var skipped = false
        var references = ReferenceScan()
    }

    /// Inspects storage breakdown under `appSupportRoot` and `teamRoot` without deleting anything.
    public static func inspect(
        appSupportRoot: URL,
        teamRoot: URL,
        extraReferencedMedia: Set<String> = [],
        skipOrphanMedia: Bool = false,
        graceSeconds: TimeInterval = mediaGraceSeconds,
        now: Date = Date(),
        workspaceRoot: URL? = nil
    ) -> StorageBreakdown {
        let chatsDir = teamRoot.appendingPathComponent("chats", isDirectory: true)
        let mediaDir = teamRoot.appendingPathComponent("media", isDirectory: true)
        let docCacheDir = teamRoot.appendingPathComponent("doccache", isDirectory: true)
        let memoryRoots = memoryLocations(in: teamRoot)

        let mediaFiles = regularFiles(in: mediaDir)

        let orphanScan: OrphanScan
        if skipOrphanMedia {
            orphanScan = OrphanScan(skipped: true)
        } else {
            orphanScan = findOrphanMedia(
                mediaFiles: mediaFiles,
                teamRoot: teamRoot,
                extraReferenced: extraReferencedMedia,
                graceSeconds: graceSeconds,
                now: now
            )
        }

        var bucketSeen = Set<FileIdentity>()
        let orphanNames = Set(orphanScan.orphans.map(\.name))
        var activeMediaBytes: Int64 = 0
        for file in mediaFiles where !orphanNames.contains(file.name) {
            if bucketSeen.insert(file.identity).inserted {
                activeMediaBytes += file.bytes
            }
        }
        var orphanBytes: Int64 = 0
        for orphan in orphanScan.orphans where bucketSeen.insert(orphan.identity).inserted {
            orphanBytes += orphan.bytes
        }
        let mediaBytes = activeMediaBytes + orphanBytes

        let docCacheFiles = regularFiles(in: docCacheDir)
        var docCacheBytes: Int64 = 0
        for file in docCacheFiles where bucketSeen.insert(file.identity).inserted {
            docCacheBytes += file.bytes
        }

        let chatsBytes = directorySize(chatsDir, seen: &bucketSeen)
        let memoryBytes = memoryRoots.reduce(Int64(0)) { $0 + itemSize($1, seen: &bucketSeen) }
        let studyBytes = workspaceRoot.map {
            directorySize($0, excluding: [chatsDir, mediaDir, docCacheDir] + memoryRoots, seen: &bucketSeen)
        } ?? 0

        return StorageBreakdown(
            totalBytes: totalSize(appSupportRoot: appSupportRoot, workspaceRoot: workspaceRoot),
            mediaBytes: mediaBytes,
            orphanMediaCount: orphanScan.orphans.count,
            orphanMediaBytes: orphanBytes,
            docCacheCount: docCacheFiles.count,
            docCacheBytes: docCacheBytes,
            scanSkippedOrphans: orphanScan.skipped,
            chatsBytes: chatsBytes,
            studyBytes: studyBytes,
            memoryBytes: memoryBytes
        )
    }

    /// Measures Application Support and the local workspace, counting shared paths and identical files once.
    public static func totalSize(appSupportRoot: URL, workspaceRoot: URL? = nil) -> Int64 {
        var seen = Set<FileIdentity>()
        let appBytes = directorySize(appSupportRoot, seen: &seen)
        guard let workspaceRoot, !Task.isCancelled else { return appBytes }
        return appBytes + directorySize(workspaceRoot, excluding: [appSupportRoot], seen: &seen)
    }

    private static func memoryLocations(in teamRoot: URL) -> [URL] {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: teamRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return children.filter {
            let name = $0.lastPathComponent.lowercased()
            return name == "diary" || name.hasPrefix("memor")
        }
    }

    /// Removes only unreferenced `media/` files older than `graceSeconds` and regenerable `doccache/` files.
    /// Verifies `abortIf`, task cancellation, `teamRoot`/subdirectory identity, and per-file inode before each delete
    /// so a concurrent backup restore swapping `Team/` can never lose restored files.
    public static func clean(
        teamRoot: URL,
        extraReferencedMedia: Set<String> = [],
        skipOrphanMedia: Bool = false,
        graceSeconds: TimeInterval = mediaGraceSeconds,
        now: Date = Date(),
        abortIf: @Sendable () -> Bool = { false }
    ) -> CleanupResult {
        guard !abortIf(), !Task.isCancelled, let teamIdentity = directoryIdentity(teamRoot) else {
            return CleanupResult()
        }
        let fm = FileManager.default
        let mediaDir = teamRoot.appendingPathComponent("media", isDirectory: true)
        let mediaIdentity = directoryIdentity(mediaDir)
        let mediaFiles = mediaIdentity != nil ? regularFiles(in: mediaDir) : []
        let orphanScan: OrphanScan
        if skipOrphanMedia || mediaFiles.isEmpty {
            orphanScan = OrphanScan(skipped: skipOrphanMedia)
        } else {
            orphanScan = findOrphanMedia(
                mediaFiles: mediaFiles,
                teamRoot: teamRoot,
                extraReferenced: extraReferencedMedia,
                graceSeconds: graceSeconds,
                now: now,
                abortIf: abortIf
            )
        }

        guard skipOrphanMedia || !orphanScan.skipped else { return CleanupResult() }

        var removedMedia = 0
        var removedDocCache = 0
        var freed: Int64 = 0

        if let mediaIdentity {
            for file in orphanScan.orphans {
                guard !abortIf(),
                      !Task.isCancelled,
                      directoryIdentity(teamRoot) == teamIdentity,
                      directoryIdentity(mediaDir) == mediaIdentity else {
                    return CleanupResult(
                        removedMediaCount: removedMedia,
                        removedDocCacheCount: removedDocCache,
                        freedBytes: freed
                    )
                }
                guard orphanScan.references.isCurrent else {
                    return CleanupResult(removedMediaCount: removedMedia, freedBytes: freed)
                }
                guard regularFileIdentity(file.url) == file.identity,
                      let modified = modificationDate(file.url), modified == file.modified else { continue }
                if (try? fm.removeItem(at: file.url)) != nil {
                    removedMedia += 1
                    freed += file.bytes
                }
            }
        }

        let docCacheDir = teamRoot.appendingPathComponent("doccache", isDirectory: true)
        if let docCacheIdentity = directoryIdentity(docCacheDir) {
            let docCacheFiles = regularFiles(in: docCacheDir)
            for file in docCacheFiles {
                guard !abortIf(),
                      !Task.isCancelled,
                      directoryIdentity(teamRoot) == teamIdentity,
                      directoryIdentity(docCacheDir) == docCacheIdentity else {
                    break
                }
                guard regularFileIdentity(file.url) == file.identity else { continue }
                if (try? fm.removeItem(at: file.url)) != nil {
                    removedDocCache += 1
                    freed += file.bytes
                }
            }
        }

        return CleanupResult(
            removedMediaCount: removedMedia,
            removedDocCacheCount: removedDocCache,
            freedBytes: freed
        )
    }

    // MARK: Private helpers

    private static func findOrphanMedia(
        mediaFiles: [FileInfo],
        teamRoot: URL,
        extraReferenced: Set<String>,
        graceSeconds: TimeInterval,
        now: Date,
        abortIf: @Sendable () -> Bool = { false }
    ) -> OrphanScan {
        let cutoff = now.addingTimeInterval(-max(0, graceSeconds))
        let eligible = mediaFiles.filter { !extraReferenced.contains($0.name) && $0.modified <= cutoff }
        guard !eligible.isEmpty else { return OrphanScan() }

        var remaining = Set(eligible.map(\.name))
        guard let references = scanReferences(teamRoot: teamRoot, remaining: &remaining, abortIf: abortIf),
              references.isCurrent else { return OrphanScan(skipped: true) }

        let orphans = eligible.filter { remaining.contains($0.name) }
        return OrphanScan(orphans: orphans, references: references)
    }

    private struct DirectoryStamp: Equatable {
        let identity: FileIdentity
        let modified: Date
    }

    private struct ReferenceScan {
        var directories: [URL: DirectoryStamp] = [:]
        var absentRoots: [URL] = []

        var isCurrent: Bool {
            directories.allSatisfy { StorageCleanup.directoryStamp($0.key) == $0.value } && absentRoots.allSatisfy {
                var info = stat()
                return lstat($0.path, &info) != 0 && errno == ENOENT
            }
        }
    }

    private static func directoryStamp(_ url: URL) -> DirectoryStamp? {
        guard let identity = directoryIdentity(url), let modified = modificationDate(url) else { return nil }
        return DirectoryStamp(identity: identity, modified: modified)
    }

    private static func modificationDate(_ url: URL) -> Date? {
        // A fresh URL avoids the resource-value cache populated by directory enumeration.
        let fresh = URL(fileURLWithPath: url.path)
        return (try? fresh.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private static func scanReferences(
        teamRoot: URL, remaining: inout Set<String>, abortIf: @Sendable () -> Bool
    ) -> ReferenceScan? {
        let appSupportRoot = teamRoot.deletingLastPathComponent()
        // Active chats, archived leaves and undoable folds share chats/. Snapshot and queue
        // metadata also cover interrupted branches, and drafts have their own sibling store.
        let teamRoots = ["chats", "snapshots"].map { teamRoot.appendingPathComponent($0, isDirectory: true) }
        let siblingRoots = ["ClioDrafts", "ClioQueued", "ClioQueuedIsolated"].map {
            appSupportRoot.appendingPathComponent($0, isDirectory: true)
        }
        let roots = Set(teamRoots + siblingRoots)
        var pending = teamRoots + siblingRoots
        var scan = ReferenceScan()
        let fm = FileManager.default
        while let item = pending.popLast() {
            guard !Task.isCancelled else { return nil }
            var info = stat()
            if lstat(item.path, &info) != 0 {
                guard errno == ENOENT, roots.contains(item) else { return nil }
                scan.absentRoots.append(item)
                continue
            }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                guard let stamp = directoryStamp(item), let children = try? fm.contentsOfDirectory(
                    at: item, includingPropertiesForKeys: nil, options: []
                ) else { return nil }
                scan.directories[item] = stamp
                pending.append(contentsOf: children)
            case S_IFREG:
                guard !roots.contains(item) else { return nil }
                guard item.pathExtension.lowercased() == "json" else { continue }
                guard !abortIf(), !Task.isCancelled,
                      let data = try? Data(contentsOf: item),
                      let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
                markReferencedStrings(in: json, remaining: &remaining)
            default:
                // A reference directory or manifest must never be reached through a symlink.
                return nil
            }
        }
        return scan
    }

    private static func markReferencedStrings(in json: Any, remaining: inout Set<String>) {
        var pending: [Any] = [json]
        while !remaining.isEmpty, let value = pending.popLast() {
            if let string = value as? String {
                remaining.remove(string)
                if string.hasPrefix("media/") { remaining.remove(String(string.dropFirst("media/".count))) }
            } else if let array = value as? [Any] {
                pending.append(contentsOf: array)
            } else if let dictionary = value as? [String: Any] {
                remaining.subtract(dictionary.keys)
                pending.append(contentsOf: dictionary.values)
            }
        }
    }

    private static func regularFiles(in dir: URL) -> [FileInfo] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var result: [FileInfo] = []
        for url in items {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileSizeKey, .contentModificationDateKey]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let identity = regularFileIdentity(url) else {
                continue
            }
            let size = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            let modified = values.contentModificationDate ?? .distantFuture
            result.append(FileInfo(url: url, name: url.lastPathComponent, bytes: size, modified: modified, identity: identity))
        }
        return result
    }

    private static func directoryIdentity(_ url: URL) -> FileIdentity? {
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else {
            return nil
        }
        return FileIdentity(
            device: UInt64(truncatingIfNeeded: st.st_dev),
            inode: UInt64(truncatingIfNeeded: st.st_ino)
        )
    }

    private static func regularFileIdentity(_ url: URL) -> FileIdentity? {
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }
        return FileIdentity(
            device: UInt64(truncatingIfNeeded: st.st_dev),
            inode: UInt64(truncatingIfNeeded: st.st_ino)
        )
    }

    private static func itemSize(_ url: URL, seen: inout Set<FileIdentity>) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileSizeKey,
        ]), values.isSymbolicLink != true else { return 0 }
        if values.isDirectory == true { return directorySize(url, seen: &seen) }
        guard values.isRegularFile == true else { return 0 }
        if let id = regularFileIdentity(url), !seen.insert(id).inserted { return 0 }
        return Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
    }

    private static func itemIdentity(_ url: URL) -> FileIdentity? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        return FileIdentity(
            device: UInt64(truncatingIfNeeded: st.st_dev),
            inode: UInt64(truncatingIfNeeded: st.st_ino)
        )
    }

    private static func isExcludedRoot(_ url: URL, excludedIDs: Set<FileIdentity>) -> Bool {
        guard !excludedIDs.isEmpty else { return false }
        var current = url.resolvingSymlinksInPath().standardizedFileURL
        while true {
            if let id = itemIdentity(current), excludedIDs.contains(id) {
                return true
            }
            if current.pathComponents.count <= 1 { break }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path == current.path { break }
            current = parent
        }
        return false
    }

    private static func directorySize(
        _ root: URL,
        excluding exclusions: [URL] = [],
        seen: inout Set<FileIdentity>
    ) -> Int64 {
        guard !Task.isCancelled, directoryIdentity(root) != nil else { return 0 }
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let excludedIDs = Set(exclusions.compactMap { itemIdentity($0) })
        guard !isExcludedRoot(resolvedRoot, excludedIDs: excludedIDs) else { return 0 }

        let fm = FileManager.default
        var total: Int64 = 0
        guard let walker = fm.enumerator(
            at: resolvedRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileSizeKey],
            options: [.skipsPackageDescendants]
        ) else {
            return 0
        }
        for case let url as URL in walker {
            if Task.isCancelled { break }
            let id = itemIdentity(url)
            if !excludedIDs.isEmpty, let id, excludedIDs.contains(id) {
                walker.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileSizeKey]) else {
                continue
            }
            if values.isSymbolicLink == true {
                walker.skipDescendants()
                continue
            }
            if values.isRegularFile == true {
                if let id, !seen.insert(id).inserted { continue }
                total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            }
        }
        return total
    }
}
