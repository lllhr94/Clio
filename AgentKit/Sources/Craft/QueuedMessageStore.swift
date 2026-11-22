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

/// Persistent conversation identity bound to a persisted queue so restoring an older backup
/// of the same companion can never silently attach or auto-send another conversation's queued messages.
public struct ConversationAnchor: Codable, Equatable, Sendable {
    public var firstEntryId: String?
    public var lastEntryId: String?

    public init(firstEntryId: String? = nil, lastEntryId: String? = nil) {
        self.firstEntryId = firstEntryId
        self.lastEntryId = lastEntryId
    }

    public static func from(entryIds: [String]) -> ConversationAnchor {
        ConversationAnchor(firstEntryId: entryIds.first, lastEntryId: entryIds.last)
    }

    /// True when `entryIds` belongs to the same conversation at or after the point the queue was saved.
    public func matches(entryIds: [String]) -> Bool {
        guard let first = firstEntryId else {
            return entryIds.isEmpty
        }
        let idSet = Set(entryIds)
        guard idSet.contains(first) else { return false }
        if let last = lastEntryId {
            return idSet.contains(last)
        }
        return true
    }
}

/// Loaded queued messages for a chat/leaf slot together with its bound conversation anchor.
public struct StoredQueuedSlot: Equatable, Sendable {
    public var items: [StoredQueuedMessage]
    public var anchor: ConversationAnchor?

    public init(items: [StoredQueuedMessage], anchor: ConversationAnchor? = nil) {
        self.items = items
        self.anchor = anchor
    }
}

/// Atomically persisted text draft paired with any unqueued message IDs, replacing non-durable `UserDefaults`
/// so a text-only unqueue only removes the source queue item after the draft file is atomically written on disk.
public struct StoredTextDraft: Codable, Equatable, Sendable {
    public var text: String
    public var queuedIds: [UUID]

    public init(text: String, queuedIds: [UUID] = []) {
        self.text = text
        self.queuedIds = queuedIds
    }
}

/// Atomically persists per-chat queued messages (text + raw photo attachments) so messages queued during a turn
/// survive app termination instead of being lost in memory.
public enum QueuedMessageStore {
    public enum SlotDisposition: Equatable, Sendable {
        /// Slot exists in index and its conversation anchor matches: restore into memory (after deduplication).
        case restore
        /// Index could not be read or the chat/leaf file still exists on disk: leave untouched on disk (fail-closed).
        case preserveUnreadable
        /// Slot belongs to a different conversation (e.g. after restoring an older backup): isolate out of active queues.
        case isolateMismatched
        /// Verified absent from readable index and chat file does not exist: safe to remove orphaned queue folder.
        case deleteOrphan
    }

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
        var anchor: ConversationAnchor?
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

    private static func textDraftFile(for chatKey: String, under root: URL) -> URL {
        root.appendingPathComponent(folderName(for: chatKey) + "-text.json")
    }

    /// Saves `items` for `chatKey` atomically (temp folder + `replaceItemAt`), or deletes the folder when empty.
    public static func save(
        _ items: [StoredQueuedMessage],
        for chatKey: String,
        anchor: ConversationAnchor? = nil,
        under root: URL
    ) throws {
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
            let manifest = Manifest(chatKey: chatKey, items: entries, anchor: anchor)
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

    /// Loads all persisted chat queues under `root` along with each slot's conversation anchor,
    /// ignoring symlinks and cleaning up any leftover `.new-*` staging folders.
    public static func loadAllSlots(from root: URL) -> [String: StoredQueuedSlot] {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else {
            return [:]
        }

        var loaded: [String: StoredQueuedSlot] = [:]
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
                loaded[manifest.chatKey] = StoredQueuedSlot(items: items, anchor: manifest.anchor)
            }
        }
        return loaded
    }

    /// Loads all persisted chat queues under `root`, ignoring symlinks and cleaning up any leftover `.new-*` staging folders.
    public static func loadAll(from root: URL) -> [String: [StoredQueuedMessage]] {
        loadAllSlots(from: root).mapValues(\.items)
    }

    /// Fail-closed startup decision for a persisted queue slot.
    /// Never recommends deleting a slot when the index could not be read or its chat file still exists on disk.
    public static func evaluateSlot(
        existsInIndex: Bool,
        indexReadable: Bool,
        chatFileExists: Bool,
        anchor: ConversationAnchor?,
        chatEntryIds: [String]?
    ) -> SlotDisposition {
        if !existsInIndex {
            if !indexReadable || chatFileExists {
                return .preserveUnreadable
            }
            return .deleteOrphan
        }
        if let anchor, let entryIds = chatEntryIds, !anchor.matches(entryIds: entryIds) {
            return .isolateMismatched
        }
        return .restore
    }

    /// Moves every persisted queue slot out of `root` into `quarantineRoot` (e.g. after restoring a backup)
    /// and optionally writes a human-readable Markdown + photo export under `readableExportRoot`.
    /// Returns the total number of isolated queued messages.
    @discardableResult
    public static func isolateAll(
        from root: URL,
        to quarantineRoot: URL,
        readableExportRoot: URL? = nil,
        now: Date = Date()
    ) -> Int {
        let slots = loadAllSlots(from: root)
        guard !slots.isEmpty else { return 0 }
        let stamp = Self.exportStamp(now)
        var total = 0
        for chatKey in slots.keys.sorted() {
            total += isolateSlot(
                chatKey,
                from: root,
                to: quarantineRoot,
                readableExportRoot: readableExportRoot,
                stamp: stamp
            )
        }
        return total
    }

    /// Moves a single persisted queue slot out of `root` into `quarantineRoot` so it can never auto-send
    /// into a different conversation, while keeping a readable copy if `readableExportRoot` is provided.
    @discardableResult
    public static func isolateSlot(
        _ chatKey: String,
        from root: URL,
        to quarantineRoot: URL,
        readableExportRoot: URL? = nil,
        now: Date = Date()
    ) -> Int {
        isolateSlot(chatKey, from: root, to: quarantineRoot, readableExportRoot: readableExportRoot, stamp: exportStamp(now))
    }

    private static func isolateSlot(
        _ chatKey: String,
        from root: URL,
        to quarantineRoot: URL,
        readableExportRoot: URL?,
        stamp: String
    ) -> Int {
        let fm = FileManager.default
        let source = folder(for: chatKey, under: root)
        guard fm.fileExists(atPath: source.path) else { return 0 }
        let items = loadAllSlots(from: root)[chatKey]?.items ?? []
        guard !items.isEmpty else {
            try? fm.removeItem(at: source)
            return 0
        }

        if let readableExportRoot {
            writeReadableExport(items: items, chatKey: chatKey, under: readableExportRoot, stamp: stamp)
        }

        let batchDir = quarantineRoot.appendingPathComponent(stamp, isDirectory: true)
        do {
            try fm.createDirectory(at: batchDir, withIntermediateDirectories: true)
            let dest = batchDir.appendingPathComponent("\(folderName(for: chatKey))-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try fm.moveItem(at: source, to: dest)
        } catch {
            // Fallback: if move fails (e.g. cross-volume), copy then remove source only on copy success.
            let dest = batchDir.appendingPathComponent("\(folderName(for: chatKey))-\(UUID().uuidString.prefix(8))", isDirectory: true)
            if (try? fm.copyItem(at: source, to: dest)) != nil {
                try? fm.removeItem(at: source)
            }
        }
        return items.count
    }

    private static func writeReadableExport(items: [StoredQueuedMessage], chatKey: String, under exportRoot: URL, stamp: String) {
        let fm = FileManager.default
        let dir = exportRoot.appendingPathComponent(stamp, isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let safeKey = folderName(for: chatKey)
            var lines: [String] = ["# 恢复前未发出的排队消息（\(stamp)）", "", "原对话标识：`\(chatKey)`", ""]
            for (itemIndex, item) in items.enumerated() {
                lines.append("## 第 \(itemIndex + 1) 条")
                if !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lines.append("")
                    lines.append(item.text)
                }
                for (photoIndex, photo) in item.photos.enumerated() {
                    let photoName = "\(safeKey)-\(itemIndex + 1)-\(photoIndex + 1).jpg"
                    try? photo.write(to: dir.appendingPathComponent(photoName), options: fileWriteOptions)
                    lines.append("")
                    lines.append("![附图 \(photoIndex + 1)](\(photoName))")
                }
                lines.append("")
            }
            let noteURL = dir.appendingPathComponent("\(safeKey).md")
            try Data(lines.joined(separator: "\n").utf8).write(to: noteURL, options: fileWriteOptions)
        } catch {
            // Best-effort readable export; raw quarantine copy in Application Support still holds full data.
        }
    }

    private static func exportStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: date)
    }

    /// Atomically persists a chat's text draft and unqueued IDs on disk (or deletes the file when text is empty).
    public static func saveTextDraft(_ draft: StoredTextDraft, for chatKey: String, under root: URL) throws {
        let fm = FileManager.default
        let file = textDraftFile(for: chatKey, under: root)
        guard !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if fm.fileExists(atPath: file.path) {
                try? fm.removeItem(at: file)
            }
            return
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(draft)
        try data.write(to: file, options: fileWriteOptions)
    }

    /// Reads an atomically persisted text draft from disk, returning `nil` when absent or empty.
    public static func loadTextDraft(for chatKey: String, under root: URL) -> StoredTextDraft? {
        let file = textDraftFile(for: chatKey, under: root)
        guard let data = try? Data(contentsOf: file),
              let draft = try? JSONDecoder().decode(StoredTextDraft.self, from: data),
              !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return draft
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
