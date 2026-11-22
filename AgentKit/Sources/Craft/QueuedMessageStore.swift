import Foundation

/// Serializable snapshot of a message queued while a conversation turn is running.
public struct StoredQueuedMessage: Equatable, Sendable {
    public var id: UUID
    public var text: String
    public var photos: [Data]
    public var interject: Bool
    public var userInitiated: Bool

    public init(
        id: UUID = UUID(),
        text: String,
        photos: [Data] = [],
        interject: Bool = false,
        userInitiated: Bool = true
    ) {
        self.id = id
        self.text = text
        self.photos = photos
        self.interject = interject
        self.userInitiated = userInitiated
    }
}

/// Atomically persists per-chat queued messages (text + raw photo attachments) so messages queued during a turn
/// survive app termination instead of being lost in memory.
public enum QueuedMessageStore {
    private struct Manifest: Codable {
        struct Entry: Codable {
            var id: UUID
            var text: String
            var photoCount: Int
            var interject: Bool
            var userInitiated: Bool
        }
        var chatKey: String
        var items: [Entry]
    }

    private static func folderName(for chatKey: String) -> String {
        let safe = chatKey.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "..", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return safe.isEmpty ? "chat" : safe
    }

    private static func folder(for chatKey: String, under root: URL) -> URL {
        root.appendingPathComponent(folderName(for: chatKey), isDirectory: true)
    }

    /// Saves `items` for `chatKey` atomically (temp folder + `replaceItemAt`), or deletes the folder when empty.
    public static func save(_ items: [StoredQueuedMessage], for chatKey: String, under root: URL) throws {
        let fm = FileManager.default
        let target = folder(for: chatKey, under: root)
        guard !items.isEmpty else {
            if fm.fileExists(atPath: target.path) {
                try? fm.removeItem(at: target)
            }
            return
        }

        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(".new-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            var entries: [Manifest.Entry] = []
            entries.reserveCapacity(items.count)
            for item in items {
                for (index, photo) in item.photos.enumerated() {
                    let photoURL = staging.appendingPathComponent("\(item.id.uuidString)-\(index).img")
                    try photo.write(to: photoURL, options: fileWriteOptions)
                }
                entries.append(Manifest.Entry(
                    id: item.id,
                    text: item.text,
                    photoCount: item.photos.count,
                    interject: item.interject,
                    userInitiated: item.userInitiated
                ))
            }
            let manifest = Manifest(chatKey: chatKey, items: entries)
            let data = try JSONEncoder().encode(manifest)
            try data.write(to: staging.appendingPathComponent("queue.json"), options: fileWriteOptions)

            if fm.fileExists(atPath: target.path) {
                _ = try fm.replaceItemAt(target, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: target)
            }
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    /// Loads all persisted chat queues under `root`, ignoring symlinks and cleaning up any leftover `.new-*` staging folders.
    public static func loadAll(from root: URL) -> [String: [StoredQueuedMessage]] {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else {
            return [:]
        }

        var loaded: [String: [StoredQueuedMessage]] = [:]
        for dir in children {
            let name = dir.lastPathComponent
            guard let values = try? dir.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isSymbolicLink != true,
                  values.isDirectory == true else {
                continue
            }
            if name.hasPrefix(".new-") {
                try? fm.removeItem(at: dir)
                continue
            }
            let manifestURL = dir.appendingPathComponent("queue.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
                  !manifest.chatKey.isEmpty else {
                continue
            }
            var items: [StoredQueuedMessage] = []
            items.reserveCapacity(manifest.items.count)
            for entry in manifest.items {
                var photos: [Data] = []
                if entry.photoCount > 0 {
                    photos.reserveCapacity(entry.photoCount)
                    for index in 0..<entry.photoCount {
                        let photoURL = dir.appendingPathComponent("\(entry.id.uuidString)-\(index).img")
                        if let photoData = try? Data(contentsOf: photoURL), !photoData.isEmpty {
                            photos.append(photoData)
                        }
                    }
                }
                if !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !photos.isEmpty {
                    items.append(StoredQueuedMessage(
                        id: entry.id,
                        text: entry.text,
                        photos: photos,
                        interject: entry.interject,
                        userInitiated: entry.userInitiated
                    ))
                }
            }
            if !items.isEmpty {
                loaded[manifest.chatKey] = items
            }
        }
        return loaded
    }

    /// Filters out queued items whose transfer to a persisted chat entry or persisted draft already landed on disk.
    /// Items carrying photos are only deduplicated when confirmed in `persistedInChat` or `persistedInDraftAttachments`
    /// (never by text-only draft markers alone), preventing photo loss if text flushed before attachment write succeeded.
    public static func deduplicated(
        _ items: [StoredQueuedMessage],
        persistedInChat: Set<UUID>,
        persistedInDraftText: Set<UUID> = [],
        persistedInDraftAttachments: Set<UUID> = []
    ) -> [StoredQueuedMessage] {
        items.filter { item in
            if persistedInChat.contains(item.id) { return false }
            if item.photos.isEmpty {
                return !persistedInDraftText.contains(item.id) && !persistedInDraftAttachments.contains(item.id)
            } else {
                return !persistedInDraftAttachments.contains(item.id)
            }
        }
    }

    private static var fileWriteOptions: Data.WritingOptions {
        #if os(iOS)
        return [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        return [.atomic]
        #endif
    }
}
