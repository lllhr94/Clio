import Craft
import Foundation

/// Files as they were before a turn changed them, so 「重来一次」 and 「改了重发」 can put them back.
/// A turn is named by the user message that started it. The first time a turn writes a file, the old file is copied
/// to Application Support/Team/snapshots/<chat>/<turn>/ (or noted as not there yet).
@MainActor
final class Snapshots {
    nonisolated static let shared = Snapshots()

    struct Kept: Codable, Equatable {
        /// `WorkPlace.code` of where the file lives; nil is 书案.
        var place: String?
        var path: String
        /// Nil: the file did not exist before the turn (unless `unread`).
        var backup: String?
        /// The file was there but could not be read, so no copy was kept: putting back must leave it alone, never
        /// treat it as new and delete it (the review, #12).
        var unread: Bool?
        /// For a 远山 host: who it was then (user@address:port). A host deleted or pointed elsewhere since is not
        /// written to (the review, #13).
        var hostIdentity: String?
    }

    struct Turn: Codable, Equatable {
        var id: String
        var files: [Kept]
    }

    /// The turn running now in each chat.
    private var current: [String: String] = [:]
    private var books: [String: [Turn]] = [:]

    private static let folder: URL = Disk.url("snapshots")

    nonisolated init() {}

    private static func chatFolder(_ key: String) -> URL {
        folder.appendingPathComponent(key.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
    }

    private func book(_ key: String) -> [Turn] {
        if let kept = books[key] { return kept }
        let url = Self.chatFolder(key).appendingPathComponent("turns.json")
        let loaded = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([Turn].self, from: $0) } ?? []
        books[key] = loaded
        return loaded
    }

    private func save(_ key: String, _ turns: [Turn]) {
        books[key] = turns
        let folder = Self.chatFolder(key)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(turns) { try? data.write(to: folder.appendingPathComponent("turns.json"), options: .atomic) }
    }

    enum PreRead: Sendable {
        case absent
        case bytes(Data)
        case unreadable
    }

    /// A new turn starts in this chat.
    func begin(_ key: String, turn: String) {
        current[key] = turn
    }

    nonisolated static func normalizePath(_ raw: String, place: String?) -> String {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch WorkPlace(code: place) {
        case .desk:
            for prefix in ["/root/desk/", "书案/"] where cleaned.hasPrefix(prefix) {
                cleaned = String(cleaned.dropFirst(prefix.count))
            }
            if cleaned == "/root/desk" || cleaned == "书案" { cleaned = "" }
            while cleaned.hasPrefix("/") { cleaned.removeFirst() }
            if cleaned.hasPrefix("书案/") { cleaned = String(cleaned.dropFirst("书案/".count)) }
            while cleaned.hasPrefix("./") { cleaned = String(cleaned.dropFirst(2)) }
        case .den:
            if cleaned == "/root/desk" || cleaned == "书案" { cleaned = "." }
            for prefix in ["/root/desk/", "书案/"] where cleaned.hasPrefix(prefix) {
                cleaned = String(cleaned.dropFirst(prefix.count))
            }
            if !cleaned.hasPrefix("/") {
                while cleaned.hasPrefix("./") { cleaned = String(cleaned.dropFirst(2)) }
            }
        case .hill:
            if cleaned == "~" { cleaned = "." }
            if cleaned.hasPrefix("~/") { cleaned = String(cleaned.dropFirst(2)) }
            if !cleaned.hasPrefix("/") {
                while cleaned.hasPrefix("./") { cleaned = String(cleaned.dropFirst(2)) }
            }
        }
        let isAbs = cleaned.hasPrefix("/")
        let parts = cleaned.split(separator: "/").filter { !$0.isEmpty && $0 != "." }
        if parts.isEmpty {
            return isAbs ? "/" : "."
        }
        return (isAbs ? "/" : "") + parts.joined(separator: "/")
    }

    /// Before a tool changes `path`: keeps the file as it is, once per turn.
    func keep(_ key: String, place: String?, host: WorkspaceHost, path: String) async {
        guard let turn = current[key] else { return }
        let normalized = Self.normalizePath(path, place: place)
        let existingTurns = book(key)
        if let index = existingTurns.firstIndex(where: { $0.id == turn }),
           existingTurns[index].files.contains(where: { $0.place == place && $0.path == normalized }) {
            return
        }
        let preRead: PreRead
        do {
            let data = try await host.readFile(normalized)
            preRead = .bytes(data)
        } catch {
            // Not there is fine (a new file); any other failure means there is no copy to put back.
            preRead = Self.isMissing(error) ? .absent : .unreadable
        }
        guard current[key] == turn else { return }
        await storeKept(key, turn: turn, place: place, normalizedPath: normalized, preRead: preRead)
    }

    /// Persists a snapshot whose pre-write state was already captured synchronously (such as inside `run_js`).
    func keepPreRead(_ key: String, place: String?, path: String, preRead: PreRead) async {
        guard let turn = current[key] else { return }
        let normalized = Self.normalizePath(path, place: place)
        let existingTurns = book(key)
        if let index = existingTurns.firstIndex(where: { $0.id == turn }),
           existingTurns[index].files.contains(where: { $0.place == place && $0.path == normalized }) {
            return
        }
        await storeKept(key, turn: turn, place: place, normalizedPath: normalized, preRead: preRead)
    }

    private func storeKept(_ key: String, turn: String, place: String?, normalizedPath: String, preRead: PreRead) async {
        var backup: String?
        var unread = false
        switch preRead {
        case .absent:
            break
        case .unreadable:
            unread = true
        case .bytes(let old):
            let name = UUID().uuidString
            let folder = Self.chatFolder(key).appendingPathComponent(turn, isDirectory: true)
            let fileURL = folder.appendingPathComponent(name)
            let stored = await Task.detached(priority: .utility) {
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try old.write(to: fileURL, options: .atomic)
                    return true
                } catch { return false }
            }.value
            guard current[key] == turn else {
                if stored {
                    try? FileManager.default.removeItem(at: fileURL)
                    if (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
                        try? FileManager.default.removeItem(at: folder)
                    }
                }
                return
            }
            // No room for the copy: noted as having none, so undo says so instead of skipping it silently.
            if stored { backup = name } else { unread = true }
        }
        guard current[key] == turn else { return }
        var turns = book(key)
        let kept = Kept(place: place, path: normalizedPath, backup: backup, unread: unread ? true : nil,
                        hostIdentity: WorkPlace(code: place).hillHost.map(Self.identity))
        if let index = turns.firstIndex(where: { $0.id == turn }) {
            guard !turns[index].files.contains(where: { $0.place == place && $0.path == normalizedPath }) else {
                if let backup {
                    let duplicate = Self.chatFolder(key).appendingPathComponent(turn).appendingPathComponent(backup)
                    try? FileManager.default.removeItem(at: duplicate)
                }
                return
            }
            turns[index].files.append(kept)
        } else {
            turns.append(Turn(id: turn, files: [kept]))
        }
        // Only the last few turns are worth keeping.
        while turns.count > 12 {
            let dropped = turns.removeFirst()
            try? FileManager.default.removeItem(at: Self.chatFolder(key).appendingPathComponent(dropped.id, isDirectory: true))
        }
        save(key, turns)
    }

    /// 「No such file」 from any place: the desk's file system, 斗室 or a 远山 host over SFTP.
    nonisolated static func isMissing(_ error: Error) -> Bool {
        if let workspaceError = error as? WorkspaceError {
            if case .missing = workspaceError { return true }
            return false
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(nsError.code) { return true }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOENT) { return true }
        // Only a plain 「no such file」: a broader match (「not found」) would count 「host not found」 as a new file,
        // and putting back would then delete the real one.
        return nsError.localizedDescription.lowercased().contains("no such file")
    }

    static func identity(_ host: Hills.Host) -> String { "\(host.user)@\(host.address):\(host.port)" }

    /// The files these turns changed, for asking before putting them back.
    func files(_ key: String, turns ids: [String]) -> [Kept] {
        book(key).filter { ids.contains($0.id) }.flatMap(\.files)
    }

    /// Puts back every file these turns changed, newest turn first, and forgets them. Returns how many came back,
    /// and the ones that could not.
    /// Only what was put back is forgotten: a file that failed keeps its copy, so it can be tried again once the
    /// host is reachable (the review, #14).
    func restore(_ key: String, turns ids: [String]) async -> (restored: Int, failed: [String]) {
        let turns = book(key).filter { ids.contains($0.id) }.reversed()
        var restored = 0
        var failed: [String] = []
        var left: [String: [Kept]] = [:]
        // A file whose newer copy could not go back is not taken further back either: putting the older copy in now and
        // the newer one on a later try would leave it in the wrong state.
        var held: Set<String> = []
        for turn in turns {
            for kept in turn.files.reversed() {
                let place = WorkPlace(code: kept.place)
                let which = (kept.place ?? "") + "|" + kept.path
                if held.contains(which) {
                    failed.append("\(place.title)：\(kept.path)（较新的一步没还原成，这一步先不动）")
                    left[turn.id, default: []].append(kept)
                    continue
                }
                // The same place, or nowhere: a 远山 host that is gone or now points elsewhere is not written to,
                // and nothing falls back to the phone's 书案.
                if case .hill = place {
                    guard let found = place.hillHost, kept.hostIdentity == nil || kept.hostIdentity == Self.identity(found) else {
                        failed.append("\(place.title)：\(kept.path)（主机已删或改了地址，没动）")
                        left[turn.id, default: []].append(kept)
                        held.insert(which)
                        continue
                    }
                }
                if kept.unread == true {
                    failed.append("\(place.title)：\(kept.path)（改之前没能留下旧版本，没动）")
                    held.insert(which)
                    continue
                }
                guard let host = place.host else {
                    failed.append("\(place.title)：\(kept.path)（主机不可用，没动）")
                    left[turn.id, default: []].append(kept)
                    held.insert(which)
                    continue
                }
                do {
                    if let backup = kept.backup {
                        let data = try Data(contentsOf: Self.chatFolder(key).appendingPathComponent(turn.id).appendingPathComponent(backup))
                        try await host.writeFile(kept.path, data)
                    } else {
                        try await host.removeFile(kept.path)
                    }
                    restored += 1
                } catch {
                    failed.append("\(host.title)：\(kept.path)")
                    left[turn.id, default: []].append(kept)
                    held.insert(which)
                }
            }
            if left[turn.id] == nil {
                try? FileManager.default.removeItem(at: Self.chatFolder(key).appendingPathComponent(turn.id, isDirectory: true))
            }
        }
        var remaining = book(key).filter { !ids.contains($0.id) || left[$0.id] != nil }
        for index in remaining.indices {
            if let still = left[remaining[index].id] { remaining[index].files = still.reversed() }
        }
        save(key, remaining)
        return (restored, failed)
    }

    /// A chat emptied for good takes its snapshots with it.
    func forget(_ key: String) {
        books[key] = []
        current[key] = nil
        try? FileManager.default.removeItem(at: Self.chatFolder(key))
    }
}
