import Foundation

/// Breakdown of app storage under Application Support, highlighting safely reclaimable caches.
public struct StorageBreakdown: Equatable, Sendable {
    public var totalBytes: Int64
    public var mediaBytes: Int64
    public var orphanMediaCount: Int
    public var orphanMediaBytes: Int64
    public var docCacheCount: Int
    public var docCacheBytes: Int64
    /// True if any chat file could not be read, in which case orphan media detection fails closed (0 orphans).
    public var scanSkippedOrphans: Bool

    public var cleanableBytes: Int64 { orphanMediaBytes + docCacheBytes }

    public init(
        totalBytes: Int64 = 0,
        mediaBytes: Int64 = 0,
        orphanMediaCount: Int = 0,
        orphanMediaBytes: Int64 = 0,
        docCacheCount: Int = 0,
        docCacheBytes: Int64 = 0,
        scanSkippedOrphans: Bool = false
    ) {
        self.totalBytes = totalBytes
        self.mediaBytes = mediaBytes
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
    private struct FileInfo {
        let url: URL
        let name: String
        let bytes: Int64
        let modified: Date
    }

    /// Inspects storage breakdown under `appSupportRoot` and `teamRoot` without deleting anything.
    public static func inspect(
        appSupportRoot: URL,
        teamRoot: URL,
        extraReferencedMedia: Set<String> = [],
        skipOrphanMedia: Bool = false,
        graceSeconds: TimeInterval = 60,
        now: Date = Date()
    ) -> StorageBreakdown {
        let totalBytes = directorySize(appSupportRoot)
        let mediaFiles = regularFiles(in: teamRoot.appendingPathComponent("media", isDirectory: true))
        let mediaBytes = mediaFiles.reduce(Int64(0)) { $0 + $1.bytes }

        let orphanScan: (orphans: [FileInfo], skipped: Bool)
        if skipOrphanMedia {
            orphanScan = ([], true)
        } else {
            orphanScan = findOrphanMedia(
                mediaFiles: mediaFiles,
                chatsDir: teamRoot.appendingPathComponent("chats", isDirectory: true),
                extraReferenced: extraReferencedMedia,
                graceSeconds: graceSeconds,
                now: now
            )
        }
        let orphanBytes = orphanScan.orphans.reduce(Int64(0)) { $0 + $1.bytes }

        let docCacheFiles = regularFiles(in: teamRoot.appendingPathComponent("doccache", isDirectory: true))
        let docCacheBytes = docCacheFiles.reduce(Int64(0)) { $0 + $1.bytes }

        return StorageBreakdown(
            totalBytes: totalBytes,
            mediaBytes: mediaBytes,
            orphanMediaCount: orphanScan.orphans.count,
            orphanMediaBytes: orphanBytes,
            docCacheCount: docCacheFiles.count,
            docCacheBytes: docCacheBytes,
            scanSkippedOrphans: orphanScan.skipped
        )
    }

    /// Removes only unreferenced `media/` files older than `graceSeconds` and regenerable `doccache/` files.
    public static func clean(
        teamRoot: URL,
        extraReferencedMedia: Set<String> = [],
        skipOrphanMedia: Bool = false,
        graceSeconds: TimeInterval = 60,
        now: Date = Date()
    ) -> CleanupResult {
        let fm = FileManager.default
        let mediaFiles = regularFiles(in: teamRoot.appendingPathComponent("media", isDirectory: true))
        let orphanScan: (orphans: [FileInfo], skipped: Bool)
        if skipOrphanMedia {
            orphanScan = ([], true)
        } else {
            orphanScan = findOrphanMedia(
                mediaFiles: mediaFiles,
                chatsDir: teamRoot.appendingPathComponent("chats", isDirectory: true),
                extraReferenced: extraReferencedMedia,
                graceSeconds: graceSeconds,
                now: now
            )
        }

        var removedMedia = 0
        var removedDocCache = 0
        var freed: Int64 = 0

        for file in orphanScan.orphans {
            guard isSafeRegularFile(file.url) else { continue }
            if (try? fm.removeItem(at: file.url)) != nil {
                removedMedia += 1
                freed += file.bytes
            }
        }

        let docCacheFiles = regularFiles(in: teamRoot.appendingPathComponent("doccache", isDirectory: true))
        for file in docCacheFiles {
            guard isSafeRegularFile(file.url) else { continue }
            if (try? fm.removeItem(at: file.url)) != nil {
                removedDocCache += 1
                freed += file.bytes
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
        chatsDir: URL,
        extraReferenced: Set<String>,
        graceSeconds: TimeInterval,
        now: Date
    ) -> (orphans: [FileInfo], skipped: Bool) {
        let cutoff = now.addingTimeInterval(-max(0, graceSeconds))
        let eligible = mediaFiles.filter { !extraReferenced.contains($0.name) && $0.modified <= cutoff }
        guard !eligible.isEmpty else { return ([], false) }

        var remaining = Set(eligible.map(\.name))
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: chatsDir.path, isDirectory: &isDir), isDir.boolValue {
            guard let items = try? fm.contentsOfDirectory(
                at: chatsDir,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else {
                // Fail closed: cannot verify chat references safely.
                return ([], true)
            }
            for item in items where item.pathExtension.lowercased() == "json" {
                guard let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true else {
                    continue
                }
                guard let data = try? Data(contentsOf: item) else {
                    // Fail closed: an unreadable chat file might still reference media files.
                    return ([], true)
                }
                markReferencedStrings(in: data, remaining: &remaining)
                if remaining.isEmpty { break }
            }
        }

        let orphans = eligible.filter { remaining.contains($0.name) }
        return (orphans, false)
    }

    /// Scans JSON double-quoted string slices in O(bytes) to eliminate every referenced filename.
    /// Falls back to substring scan for any filename containing quotes or backslashes.
    private static func markReferencedStrings(in data: Data, remaining: inout Set<String>) {
        guard !remaining.isEmpty, !data.isEmpty else { return }
        var simple = Set<String>()
        var complex: [String] = []
        var minBytes = Int.max
        var maxBytes = 0
        for name in remaining {
            if name.contains("\"") || name.contains("\\") {
                complex.append(name)
            } else {
                simple.insert(name)
                let count = name.utf8.count
                if count < minBytes { minBytes = count }
                if count > maxBytes { maxBytes = count }
            }
        }

        if !simple.isEmpty {
            let quote = UInt8(ascii: "\"")
            data.withUnsafeBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                let n = bytes.count
                var i = 0
                while i < n && !simple.isEmpty {
                    if bytes[i] == quote {
                        let start = i + 1
                        var end = start
                        while end < n && bytes[end] != quote {
                            if bytes[end] == UInt8(ascii: "\\"), end + 1 < n {
                                end += 2
                            } else {
                                end += 1
                            }
                        }
                        let length = end - start
                        if end < n, length >= minBytes, length <= maxBytes {
                            let slice = UnsafeBufferPointer(rebasing: bytes[start..<end])
                            let token = String(decoding: slice, as: UTF8.self)
                            if simple.remove(token) != nil {
                                remaining.remove(token)
                            }
                        }
                        i = end + 1
                    } else {
                        i += 1
                    }
                }
            }
        }

        if !complex.isEmpty {
            let text = String(decoding: data, as: UTF8.self)
            for name in complex where text.contains(name) {
                remaining.remove(name)
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
                  values.isSymbolicLink != true else {
                continue
            }
            let size = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            let modified = values.contentModificationDate ?? .distantPast
            result.append(FileInfo(url: url, name: url.lastPathComponent, bytes: size, modified: modified))
        }
        return result
    }

    private static func isSafeRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static func directorySize(_ root: URL) -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        guard let walker = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileSizeKey],
            options: [.skipsPackageDescendants]
        ) else {
            return 0
        }
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileSizeKey]) else {
                continue
            }
            if values.isSymbolicLink == true {
                walker.skipDescendants()
                continue
            }
            if values.isRegularFile == true {
                total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            }
        }
        return total
    }
}
