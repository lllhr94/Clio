import Craft
import Darwin
import Foundation

/// Safely maintains `档案.md` and `镇纸.md` inside Clio's local `书案` folder without clobbering
/// user-authored notes outside Clio's managed markers or writing redundant unchanged files.
enum MemoryMarkdownMirror {
    static let danganFilename = "档案.md"
    static let zhenzhiFilename = "镇纸.md"

    /// Synchronizes both `档案.md` and `镇纸.md` inside `deskRoot` off the main thread.
    nonisolated static func sync(
        records: [MemoryRecord],
        bots: [MemoryMirrorBot],
        secrets: [String],
        deskRoot: URL = Workspace.root,
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
            deskRoot: deskRoot
        )
        writeMirrorIfChanged(
            filename: zhenzhiFilename,
            managedBlock: zhenzhiBlock,
            deskRoot: deskRoot
        )
    }

    nonisolated private static func writeMirrorIfChanged(
        filename: String,
        managedBlock: String,
        deskRoot: URL
    ) {
        guard !Disk.frozen else { return }
        let fileURL = deskRoot.appendingPathComponent(filename)

        var st = stat()
        if lstat(fileURL.path, &st) == 0 {
            let mode = st.st_mode & S_IFMT
            if mode == S_IFLNK || mode == S_IFDIR {
                return
            }
        }
        guard Workspace.isInsideRealRoot(fileURL, root: deskRoot) else { return }

        let existingText: String?
        if FileManager.default.fileExists(atPath: fileURL.path) {
            guard let data = try? Data(contentsOf: fileURL),
                  let decoded = String(data: data, encoding: .utf8) else {
                // Do not overwrite an unreadable or non-UTF8 user file.
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
            try FileManager.default.createDirectory(at: deskRoot, withIntermediateDirectories: true)
            try Data(merged.utf8).write(to: fileURL, options: .atomic)
        } catch {
            // Best-effort mirror: canonical DB and memory.json stay authoritative.
        }
    }
}
