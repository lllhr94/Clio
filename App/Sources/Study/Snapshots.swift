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
        /// Nil: the file did not exist before the turn.
        var backup: String?
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

    /// A new turn starts in this chat.
    func begin(_ key: String, turn: String) {
        current[key] = turn
    }

    /// Before a tool changes `path`: keeps the file as it is, once per turn.
    func keep(_ key: String, place: String?, host: WorkspaceHost, path: String) async {
        guard let turn = current[key] else { return }
        var turns = book(key)
        if let index = turns.firstIndex(where: { $0.id == turn }), turns[index].files.contains(where: { $0.place == place && $0.path == path }) { return }
        let old = try? await host.readFile(path)
        var backup: String?
        if let old {
            let name = UUID().uuidString
            let folder = Self.chatFolder(key).appendingPathComponent(turn, isDirectory: true)
            let stored = await Task.detached(priority: .utility) {
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try old.write(to: folder.appendingPathComponent(name), options: .atomic)
                    return true
                } catch { return false }
            }.value
            if stored { backup = name } else { return }
        }
        turns = book(key)
        let kept = Kept(place: place, path: path, backup: backup)
        if let index = turns.firstIndex(where: { $0.id == turn }) {
            guard !turns[index].files.contains(where: { $0.place == place && $0.path == path }) else {
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

    /// The files these turns changed, for asking before putting them back.
    func files(_ key: String, turns ids: [String]) -> [Kept] {
        book(key).filter { ids.contains($0.id) }.flatMap(\.files)
    }

    /// Puts back every file these turns changed, newest turn first, and forgets them. Returns how many came back,
    /// and the ones that could not.
    func restore(_ key: String, turns ids: [String]) async -> (restored: Int, failed: [String]) {
        let turns = book(key).filter { ids.contains($0.id) }.reversed()
        var restored = 0
        var failed: [String] = []
        for turn in turns {
            for kept in turn.files.reversed() {
                let host = WorkPlace(code: kept.place).host
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
                }
            }
            try? FileManager.default.removeItem(at: Self.chatFolder(key).appendingPathComponent(turn.id, isDirectory: true))
        }
        save(key, book(key).filter { !ids.contains($0.id) })
        return (restored, failed)
    }

    /// A chat emptied for good takes its snapshots with it.
    func forget(_ key: String) {
        books[key] = []
        current[key] = nil
        try? FileManager.default.removeItem(at: Self.chatFolder(key))
    }
}
