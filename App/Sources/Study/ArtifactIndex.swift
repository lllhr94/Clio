import AgentKit
import Foundation

actor ArtifactIndex {
    enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case document, card, image, code, other
        var id: Self { self }
        var titleKey: String { "artifacts.kind.\(rawValue)" }

        static func classify(_ url: URL) -> Self {
            switch url.pathExtension.lowercased() {
            case "html", "htm", "svg": .card
            case "png", "jpeg", "jpg", "gif", "webp", "heic", "tiff": .image
            case "pdf", "md", "txt", "rtf", "docx", "csv", "xlsx", "pptx": .document
            case "swift", "js", "ts", "py", "sh", "json", "yaml", "yml", "css", "sql": .code
            default: .other
            }
        }
    }

    struct FileVersion: Codable, Equatable, Hashable, Sendable {
        let fileSize: Int
        let mtime: Date
        let relativePath: String
        let mountID: String?
    }

    struct Record: Codable, Equatable, Identifiable, Sendable {
        // The producer entry is the permanent identity. Reusing a path cannot reassign it.
        let entryID: String
        var sourceChatKey: String
        let sourceRowID: String
        let companionID: String?
        let kind: Kind
        var version: FileVersion
        let fileIdentity: String
        let producedAt: Date
        var id: String { entryID }
    }

    struct LocatedFile: Sendable {
        let version: FileVersion
        let identity: String
        let kind: Kind
    }

    struct Source: Sendable {
        let entryID: String
        let chat: String
        let row: String
        let companion: String?
        let path: String
        let producedAt: Date
    }

    static let shared = ArtifactIndex(file: Disk.url("artifacts.json"))
    private let file: URL

    init(file: URL) { self.file = file }

    // Keep bindings for unavailable artifacts so a later file at the same path
    // cannot claim an old message. Moving a transcript only changes its chat key.
    func reconcile(sources: [Source], files: [LocatedFile]) throws -> [Record] {
        let prior: [String: Record]
        if FileManager.default.fileExists(atPath: file.path) {
            prior = try JSONDecoder().decode([String: Record].self, from: Data(contentsOf: file))
        } else {
            prior = [:]
        }
        var records = prior
        var available: [Record] = []
        let byIdentity = Dictionary(grouping: files, by: \.identity)
        let byPath = Dictionary(grouping: files, by: { $0.version.relativePath })
        let byEntry = Dictionary(grouping: sources, by: \.entryID)
        for (id, matches) in byEntry {
            // An ambiguous copied transcript cannot move provenance to a random chat.
            guard matches.count == 1, let source = matches.first else { continue }
            if var record = records[id] {
                record.sourceChatKey = source.chat
                let sameVersion = (byIdentity[record.fileIdentity] ?? []).filter {
                    $0.version.mountID == record.version.mountID && $0.version.fileSize == record.version.fileSize
                        && $0.version.mtime == record.version.mtime
                }
                let match = sameVersion.first { $0.version == record.version }
                    ?? (sameVersion.count == 1 ? sameVersion.first : nil)
                if let match {
                    record.version = match.version
                    available.append(record)
                }
                records[id] = record
            } else if let candidates = byPath[source.path], candidates.count == 1, let found = candidates.first,
                      found.version.mtime <= source.producedAt,
                      source.producedAt.timeIntervalSince(found.version.mtime) <= 15 {
                let record = Record(entryID: id, sourceChatKey: source.chat, sourceRowID: source.row,
                                    companionID: source.companion, kind: found.kind, version: found.version,
                                    fileIdentity: found.identity, producedAt: source.producedAt)
                records[id] = record
                available.append(record)
            }
        }
        if records != prior {
            guard !Disk.frozen else { throw CancellationError() }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(records).write(to: file, options: [.atomic, .completeFileProtection])
        }
        return available.sorted { ($0.producedAt, $0.entryID) > ($1.producedAt, $1.entryID) }
    }

    func refresh(live: [String: [Entry]], keeping: Bool) throws -> [Record] {
        var transcripts = live
        if keeping {
            let directory = Disk.url("chats")
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            for url in files where url.pathExtension == "json" {
                try Task.checkCancellation()
                let key = url.deletingPathExtension().lastPathComponent
                guard (key.hasPrefix("bot-") || key.hasPrefix("room-")), transcripts[key] == nil,
                      let data = try? Data(contentsOf: url),
                      let entries = try? JSONDecoder().decode([Entry].self, from: data) else { continue }
                transcripts[key] = entries
            }
        }
        let sources = transcripts.flatMap { Self.sources(in: $0.value, chat: $0.key) }
        let mounts = MountedFolders.all()
        var files = try Self.files(root: Workspace.root, mount: nil)
        for mount in mounts {
            try Task.checkCancellation()
            guard let opened = MountedFolders.openForUI(mount) else { continue }
            defer { opened.token.stop() }
            let located = try Self.files(root: opened.url, mount: mount)
            if MountedFolders.isCurrent(mount) { files += located }
        }
        return try reconcile(sources: sources, files: files)
    }

    private static func sources(in entries: [Entry], chat: String) -> [Source] {
        var calls: [String: ToolCall] = [:]
        var row: String?
        var result: [Source] = []
        let rootChat = chat.split(separator: "~", maxSplits: 1).first.map(String.init) ?? chat
        for item in entries {
            let message = item.message
            if item.note == true || message.role == .user || (message.role == .assistant && !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                row = nil
            }
            for call in message.toolCalls { calls[call.id] = call }
            if !message.toolCalls.isEmpty && row == nil { row = "steps-\(item.id)" }
            guard message.role == .tool, item.note != true else { continue }
            if row == nil { row = "steps-\(item.id)" }
            guard !message.isError, let callID = message.toolCallId,
                  let call = calls.removeValue(forKey: callID), ["write_file", "edit_file"].contains(call.name),
                  let path = JSONValue.parse(call.arguments)?["path"]?.string,
                  let workspaceTarget = try? Workspace.parse(path), let row else { continue }
            let relative: String
            switch workspaceTarget {
            case .desk(_, let value), .mounted(_, _, let value): relative = value
            case .mountsRoot: continue
            }
            let companion = item.speaker ?? (rootChat.hasPrefix("bot-") ? String(rootChat.dropFirst(4)) : nil)
            result.append(Source(entryID: item.id, chat: chat, row: row, companion: companion,
                                 path: relative.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                                 producedAt: Date(timeIntervalSince1970: item.at / 1000)))
        }
        return result
    }

    private static func files(root: URL, mount: MountedFolder?) throws -> [LocatedFile] {
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let prefix = base.path + "/"
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: keys,
                                                            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var files: [LocatedFile] = []
        for case let url as URL in walker {
            try Task.checkCancellation()
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true,
                  values.isRegularFile == true, url.path.hasPrefix(prefix),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? NSNumber, let mtime = attributes[.modificationDate] as? Date,
                  let created = attributes[.creationDate] as? Date,
                  let inode = attributes[.systemFileNumber] as? NSNumber,
                  let device = attributes[.systemNumber] as? NSNumber else { continue }
            let path = String(url.path.dropFirst(prefix.count))
            let relative = mount.map { "\(MountedFolders.virtualFolder)/\($0.name)/\(path)" } ?? path
            let version = FileVersion(fileSize: size.intValue, mtime: mtime, relativePath: relative, mountID: mount?.id)
            files.append(LocatedFile(version: version, identity: "\(device):\(inode):\(created.timeIntervalSinceReferenceDate)",
                                     kind: Kind.classify(url)))
        }
        return files
    }
}
