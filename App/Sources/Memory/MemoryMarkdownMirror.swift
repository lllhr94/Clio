import Craft
import Darwin
import Foundation

/// Safely maintains human-readable `档案.md` and `镇纸.md` mirrors inside
/// `Library/Application Support/ClioMemory/Mirrors/`, completely outside model-readable `书案`
/// (`Workspace.root`) and outside `Team/` backup archives.
enum MemoryMarkdownMirror {
    static let danganFilename = "档案.md"
    static let zhenzhiFilename = "镇纸.md"

    nonisolated static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClioMemory", isDirectory: true)
            .appendingPathComponent("Mirrors", isDirectory: true)
    }

    nonisolated static var danganURL: URL {
        defaultRoot.appendingPathComponent(danganFilename)
    }

    nonisolated static var zhenzhiURL: URL {
        defaultRoot.appendingPathComponent(zhenzhiFilename)
    }

    nonisolated static func readDangan(mirrorsRoot: URL = defaultRoot) -> String? {
        readMirror(filename: danganFilename, mirrorsRoot: mirrorsRoot)
    }

    nonisolated static func readZhenzhi(mirrorsRoot: URL = defaultRoot) -> String? {
        readMirror(filename: zhenzhiFilename, mirrorsRoot: mirrorsRoot)
    }

    nonisolated static func clearMirrors(mirrorsRoot: URL = defaultRoot) {
        for filename in [danganFilename, zhenzhiFilename] {
            let fileURL = mirrorsRoot.appendingPathComponent(filename)
            var st = stat()
            if lstat(fileURL.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
    }

    /// Synchronizes both `档案.md` and `镇纸.md` inside `mirrorsRoot` off the main thread.
    nonisolated static func sync(
        records: [MemoryRecord],
        bots: [MemoryMirrorBot],
        secrets: [String],
        mirrorsRoot: URL = defaultRoot,
        timeZone: TimeZone = .current
    ) {
        guard !Disk.frozen else { return }

        let danganBlock = MemoryMarkdownRenderer.renderDangan(
            records: records,
            bots: bots,
            secrets: secrets,
            timeZone: timeZone
        )
        let zhenzhiBlock = MemoryMarkdownRenderer.renderZhenzhi(
            records: records,
            secrets: secrets,
            timeZone: timeZone
        )

        writeMirrorIfChanged(
            filename: danganFilename,
            managedBlock: danganBlock,
            mirrorsRoot: mirrorsRoot
        )
        writeMirrorIfChanged(
            filename: zhenzhiFilename,
            managedBlock: zhenzhiBlock,
            mirrorsRoot: mirrorsRoot
        )
    }

    nonisolated private static func readMirror(filename: String, mirrorsRoot: URL) -> String? {
        let fileURL = mirrorsRoot.appendingPathComponent(filename)
        var st = stat()
        guard lstat(fileURL.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }
        guard isContained(fileURL, inside: mirrorsRoot),
              let data = try? Data(contentsOf: fileURL) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    nonisolated private static func writeMirrorIfChanged(
        filename: String,
        managedBlock: String,
        mirrorsRoot: URL
    ) {
        guard !Disk.frozen else { return }
        let fileURL = mirrorsRoot.appendingPathComponent(filename)

        var st = stat()
        if lstat(fileURL.path, &st) == 0 {
            let mode = st.st_mode & S_IFMT
            if mode == S_IFLNK || mode == S_IFDIR {
                return
            }
        }
        guard isContained(fileURL, inside: mirrorsRoot) else { return }

        let existingText: String?
        if FileManager.default.fileExists(atPath: fileURL.path) {
            guard let data = try? Data(contentsOf: fileURL),
                  let decoded = String(data: data, encoding: .utf8) else {
                // Do not overwrite an unreadable or non-UTF8 file.
                return
            }
            existingText = decoded
        } else {
            existingText = nil
        }

        let merged = MemoryMarkdownRenderer.mergeManagedSection(managedBlock, into: existingText)
        guard MemoryMarkdownRenderer.shouldWrite(merged: merged, existing: existingText) else {
            return
        }

        do {
            try FileManager.default.createDirectory(at: mirrorsRoot, withIntermediateDirectories: true)
            try Data(merged.utf8).write(
                to: fileURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
        } catch {
            // Best-effort mirror: canonical DB and memory.json stay authoritative.
        }
    }

    nonisolated private static func isContained(_ url: URL, inside root: URL) -> Bool {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        let target = url.resolvingSymlinksInPath().standardizedFileURL.path
        return target == base || target.hasPrefix(base + "/")
    }
}
