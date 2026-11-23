import AVFoundation
import AgentKit
import CoreLocation
import Craft
import PhotosUI
import Observation
import SwiftUI
import UniformTypeIdentifiers
import VisionKit

/// Copies external files safely into `书案/收件` while the caller holds any temporary security scope.
enum InboxImport {
    nonisolated static func sanitizeFilename(_ raw: String) -> String {
        var cleaned = raw
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." {
            return "收件文件"
        }
        return String(cleaned.prefix(120))
    }

    nonisolated static func copyOne(_ url: URL) throws -> String {
        guard !Disk.frozen else {
            throw WorkspaceError.cannot("正在恢复数据，请稍后再试。")
        }
        let inbox = Workspace.root.appendingPathComponent("收件", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        guard Workspace.isInsideRealRoot(inbox, root: Workspace.root) else {
            throw WorkspaceError.cannot("收件目录不可用。")
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let safeName = sanitizeFilename(url.lastPathComponent)
        let safeURL = URL(fileURLWithPath: safeName)
        let base = safeURL.deletingPathExtension().lastPathComponent
        let ext = safeURL.pathExtension
        var target = inbox.appendingPathComponent(safeName)
        var number = 2
        while FileManager.default.fileExists(atPath: target.path) {
            let candidate = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            target = inbox.appendingPathComponent(candidate)
            number += 1
        }
        guard Workspace.isInsideRealRoot(target, root: inbox) else {
            throw WorkspaceError.cannot("目标路径不安全。")
        }
        try FileManager.default.copyItem(at: url, to: target)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: target.path
        )
        if target.pathExtension.lowercased() == "pdf", let text = PDFText.extract(target), !text.isEmpty {
            let sidecar = target.appendingPathExtension("txt")
            if Workspace.isInsideRealRoot(sidecar, root: inbox) {
                try? Data(text.utf8).write(to: sidecar, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
        }
        return Workspace.relative(target)
    }

    nonisolated static func localDayStamp(_ date: Date = Date()) -> String {
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 2026, comps.month ?? 1, comps.day ?? 1)
    }
}

extension ChatPage {
    // MARK: Attachments

    func bring(_ kind: AttachKind) {
        switch kind {
        case .photos: pickerShown = true
        case .camera: takingPhoto = true
        case .files: importingFile = true
        case .desk: deskPicking = true
        case .scan: scanning = true
        }
    }

    /// Keep the pasted text until its attachment is ready and the same draft is still on screen.
    func keepLongPaste(_ old: String, _ new: String) {
        pasteTask?.cancel()
        guard !Disk.frozen, new.utf8.count > DraftInput.pasteLimit else { return }
        let largeChange = new.utf8.count - old.utf8.count > DraftInput.pasteLimit
        let revision = attachmentRevision
        pasteTask = Task {
            if !largeChange {
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            }
            let worker = Task.detached(priority: .userInitiated) { () -> (URL, String, Int)? in
                guard !Disk.frozen, let pasted = DraftInput.longInsertion(from: old, to: new), !Task.isCancelled else { return nil }
                let inbox = Workspace.root.appendingPathComponent("收件", isDirectory: true)
                let stamp = InboxImport.localDayStamp()
                let id = UUID().uuidString.prefix(8)
                let file = inbox.appendingPathComponent("粘贴片段-\(stamp)-\(id).txt")
                do {
                    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
                    guard Workspace.isInsideRealRoot(inbox, root: Workspace.root),
                          Workspace.isInsideRealRoot(file, root: inbox) else { return nil }
                    try Data(pasted.utf8).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                    return (file, Workspace.relative(file), pasted.count)
                } catch {
                    return nil
                }
            }
            let prepared = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard let (url, path, count) = prepared else { return }
            guard !Task.isCancelled, revision == attachmentRevision, draft == new else {
                _ = await Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: url) }.value
                return
            }
            draft = old
            withAnimation(Ink.Motion.settle) { files.append(path) }
            say(L.format("chat.pasteAttached", count, path))
        }
    }

    /// Files picked from the Files app land in 书案/收件, and the companion is told where.
    func receive(_ urls: [URL]) {
        guard !Disk.frozen else { return }
        var addedAny = false
        for url in urls {
            do {
                let rel = try InboxImport.copyOne(url)
                if !files.contains(rel) { files.append(rel) }
                addedAny = true
            } catch {
                say("没拿到「\(url.lastPathComponent)」：\(error.localizedDescription)")
            }
        }
        if addedAny { Haptics.tick(0.6) }
    }

    /// What goes after the message so the companion knows about the files.
    var fileNote: String {
        guard !files.isEmpty else { return "" }
        let mountPrefix = MountedFolders.virtualFolder + "/"
        let hasMounted = files.contains { $0.hasPrefix(mountPrefix) }
        let lines = files.map { path -> String in
            let pdf = !path.hasPrefix(mountPrefix)
                && path.lowercased().hasSuffix(".pdf")
                && FileManager.default.fileExists(atPath: (Workspace.resolve(path + ".txt")?.path ?? ""))
            return "- 书案/\(path)" + (pdf ? "（PDF：用 read_pdf 按页读；文字也抽出到了 \(path).txt）" : "")
        }
        let header = hasMounted
            ? "［我附带的文件（其中 书案/\(MountedFolders.virtualFolder)/… 是挂载的外部文件夹，请直接用 read_file、read_pdf、view_image 等文件工具读，不经过斗室 shell；其余在书案里也可在斗室 /root/desk 访问）：\n"
            : "［我放进书案的文件（书案路径；斗室里是 /root/desk 下同名路径），可以用 read_file 读、read_pdf 读 PDF、view_image 看图，或用 shell 处理：\n"
        return "\n\n" + header + lines.joined(separator: "\n") + "］"
    }
}
