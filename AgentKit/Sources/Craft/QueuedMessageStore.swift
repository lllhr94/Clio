import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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

/// Outcome of isolating pre-restore or mismatched queued message slots out of active `ClioQueued`.
public struct IsolationReport: Equatable, Sendable {
    /// Queued messages whose source slot was verified removed from active `ClioQueued`.
    public var isolatedMessages: Int
    /// Queued messages whose source slot could not be moved/removed and remain persistently blocked.
    public var failedMessages: Int
    /// Chat/leaf slot keys that failed isolation and were persisted as blocked from auto-restoring.
    public var failedSlots: [String]
    /// True if readable Markdown/photo export succeeded for every attempted slot (or when no export was requested / 0 items).
    public var readableExportSucceeded: Bool

    public init(
        isolatedMessages: Int = 0,
        failedMessages: Int = 0,
        failedSlots: [String] = [],
        readableExportSucceeded: Bool = true
    ) {
        self.isolatedMessages = isolatedMessages
        self.failedMessages = failedMessages
        self.failedSlots = failedSlots
        self.readableExportSucceeded = readableExportSucceeded
    }
}

/// Durable journal record written before multi-step `openLeafNow` writes so a crash or failed leaf-index write
/// can cleanly roll back ONLY the exact active files written by this transaction (never deleting later user turns
/// or files restored by a backup).
public struct PendingLeafOpen: Codable, Equatable, Sendable {
    public var chatKey: String
    public var leafId: String
    public var leafKey: String
    public var priorActiveQueuedIds: [UUID]
    /// Entry IDs this transaction wrote into `chats/<chatKey>.json`; rollback requires exact match.
    public var writtenChatEntryIds: [String]
    /// Queued item IDs this transaction wrote into `ClioQueued/<chatKey>`; rollback requires exact match.
    public var writtenActiveQueuedIds: [UUID]
    /// POSIX inode of `chats/<chatKey>.json` captured right after this transaction wrote it; prevents deleting
    /// a different file (e.g. from a restored backup) that happens to share identical entry IDs.
    public var writtenChatInode: UInt64?
    /// POSIX inode of `Team/chats` captured before writes started; if `Backup.restore` swapped `Team/`,
    /// the directory inode changes so stale markers are discarded without touching restored files.
    public var chatsDirInode: UInt64?
    /// POSIX inode of the source leaf file `chats/<leafKey>.json` captured before writes started;
    /// forward cleanup only removes the exact leaf file opened by this transaction.
    public var leafChatInode: UInt64?

    public init(
        chatKey: String,
        leafId: String,
        leafKey: String,
        priorActiveQueuedIds: [UUID] = [],
        writtenChatEntryIds: [String] = [],
        writtenActiveQueuedIds: [UUID] = [],
        writtenChatInode: UInt64? = nil,
        chatsDirInode: UInt64? = nil,
        leafChatInode: UInt64? = nil
    ) {
        self.chatKey = chatKey
        self.leafId = leafId
        self.leafKey = leafKey
        self.priorActiveQueuedIds = priorActiveQueuedIds
        self.writtenChatEntryIds = writtenChatEntryIds
        self.writtenActiveQueuedIds = writtenActiveQueuedIds
        self.writtenChatInode = writtenChatInode
        self.chatsDirInode = chatsDirInode
        self.leafChatInode = leafChatInode
    }
}

/// Atomically persists per-chat queued messages (text + raw photo attachments) so messages queued during a turn
/// survive app termination instead of being lost in memory.
public enum QueuedMessageStore {
    public enum SlotDisposition: Equatable, Sendable {
        /// Slot exists in index and its conversation anchor matches: restore into memory (after deduplication).
        case restore
        /// Slot failed isolation after a backup restore and is persistently blocked: retry isolation, never restore.
        case retryIsolation
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

    private struct LeafIDRecord: Decodable {
        var id: String
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

    private static func blockedSlotsFile(under root: URL) -> URL {
        root.appendingPathComponent(".restore-blocked.json")
    }

    private static func pendingLeafOpenDir(under root: URL) -> URL {
        root.appendingPathComponent(".pending-leaf-open", isDirectory: true)
    }

    private static func pendingLeafOpenFile(for chatKey: String, under root: URL) -> URL {
        pendingLeafOpenDir(under: root).appendingPathComponent(folderName(for: chatKey) + ".json")
    }

    /// True only when queued messages are allowed to be flushed or handed to a model turn.
    /// Blocked while a backup restore is in progress or after a restore has frozen writes until relaunch.
    public static func canDispatchQueue(isFrozen: Bool, isRestoring: Bool) -> Bool {
        !isFrozen && !isRestoring
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
    /// ignoring symlinks and hidden internal metadata folders while cleaning up leftover `.new-*` staging folders.
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
            if name.hasPrefix(".") {
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

    /// Loads slot keys persistently blocked from auto-restoring after an incomplete post-restore isolation.
    public static func loadBlockedSlots(from root: URL) -> Set<String> {
        let file = blockedSlotsFile(under: root)
        guard let data = try? Data(contentsOf: file),
              let keys = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(keys)
    }

    /// Atomically persists the set of blocked slot keys under `root` (or deletes the marker when empty), throwing on error.
    public static func saveBlockedSlotsThrowing(_ slots: Set<String>, under root: URL) throws {
        let fm = FileManager.default
        let file = blockedSlotsFile(under: root)
        guard !slots.isEmpty else {
            if fm.fileExists(atPath: file.path) {
                try fm.removeItem(at: file)
            }
            return
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(slots.sorted())
        try data.write(to: file, options: fileWriteOptions)
    }

    /// Best-effort wrapper around `saveBlockedSlotsThrowing`.
    public static func saveBlockedSlots(_ slots: Set<String>, under root: URL) {
        try? saveBlockedSlotsThrowing(slots, under: root)
    }

    /// Atomically persists every currently queued slot key into `.restore-blocked.json` BEFORE `Backup.restore`
    /// replaces `Team/`. Returns the newly armed slot keys (empty if nothing is queued).
    @discardableResult
    public static func armPreRestoreBarrier(under root: URL) throws -> Set<String> {
        let existingSlots = Set(loadAllSlots(from: root).keys)
        guard !existingSlots.isEmpty else { return [] }
        let previouslyBlocked = loadBlockedSlots(from: root)
        let combined = previouslyBlocked.union(existingSlots)
        try saveBlockedSlotsThrowing(combined, under: root)
        return existingSlots.subtracting(previouslyBlocked)
    }

    /// Rolls back newly armed barrier entries if `Backup.restore` failed before replacing `Team/`,
    /// keeping any previously blocked slots intact.
    public static func disarmPreRestoreBarrier(newlyArmed: Set<String>, previouslyBlocked: Set<String>, under root: URL) {
        guard !newlyArmed.isEmpty else { return }
        var current = loadBlockedSlots(from: root)
        current.subtract(newlyArmed)
        current.formUnion(previouslyBlocked)
        saveBlockedSlots(current, under: root)
    }

    /// Fail-closed startup decision for a persisted queue slot.
    /// Blocked slots always retry isolation (even without an anchor or with a matching anchor).
    /// Unreadable indexes or surviving chat files are preserved without deletion.
    public static func evaluateSlot(
        existsInIndex: Bool,
        indexReadable: Bool,
        chatFileExists: Bool,
        anchor: ConversationAnchor?,
        chatEntryIds: [String]?,
        isBlockedByRestore: Bool = false
    ) -> SlotDisposition {
        if isBlockedByRestore {
            return .retryIsolation
        }
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
    /// Verifies each source slot is actually removed from `root`; any failure is recorded in `failedSlots`
    /// and persisted in `.restore-blocked.json` so relaunch cannot silently re-attach it.
    @discardableResult
    public static func isolateAll(
        from root: URL,
        to quarantineRoot: URL,
        readableExportRoot: URL? = nil,
        now: Date = Date()
    ) -> IsolationReport {
        let slots = loadAllSlots(from: root)
        guard !slots.isEmpty else { return IsolationReport() }
        let stamp = Self.exportStamp(now)
        var combined = IsolationReport()
        for chatKey in slots.keys.sorted() {
            let part = isolateSlot(
                chatKey,
                from: root,
                to: quarantineRoot,
                readableExportRoot: readableExportRoot,
                stamp: stamp
            )
            combined.isolatedMessages += part.isolatedMessages
            combined.failedMessages += part.failedMessages
            combined.failedSlots.append(contentsOf: part.failedSlots)
            if !part.readableExportSucceeded {
                combined.readableExportSucceeded = false
            }
        }
        return combined
    }

    /// Moves a single persisted queue slot out of `root` into `quarantineRoot` so it can never auto-send
    /// into a different conversation, reporting isolation and readable export outcomes separately.
    @discardableResult
    public static func isolateSlot(
        _ chatKey: String,
        from root: URL,
        to quarantineRoot: URL,
        readableExportRoot: URL? = nil,
        now: Date = Date()
    ) -> IsolationReport {
        isolateSlot(chatKey, from: root, to: quarantineRoot, readableExportRoot: readableExportRoot, stamp: exportStamp(now))
    }

    private static func isolateSlot(
        _ chatKey: String,
        from root: URL,
        to quarantineRoot: URL,
        readableExportRoot: URL?,
        stamp: String
    ) -> IsolationReport {
        let fm = FileManager.default
        let source = folder(for: chatKey, under: root)
        guard fm.fileExists(atPath: source.path) else {
            var blocked = loadBlockedSlots(from: root)
            if blocked.remove(chatKey) != nil {
                saveBlockedSlots(blocked, under: root)
            }
            return IsolationReport()
        }
        let items = loadAllSlots(from: root)[chatKey]?.items ?? []
        guard !items.isEmpty else {
            try? fm.removeItem(at: source)
            return IsolationReport()
        }

        let exportOk: Bool
        if let readableExportRoot {
            exportOk = writeReadableExport(items: items, chatKey: chatKey, under: readableExportRoot, stamp: stamp)
        } else {
            exportOk = true
        }

        let batchDir = quarantineRoot.appendingPathComponent(stamp, isDirectory: true)
        var moved = false
        do {
            try fm.createDirectory(at: batchDir, withIntermediateDirectories: true)
            let dest = batchDir.appendingPathComponent("\(folderName(for: chatKey))-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try fm.moveItem(at: source, to: dest)
            moved = !fm.fileExists(atPath: source.path)
        } catch {
            // Fallback: if move fails (e.g. cross-volume), copy then remove source only when copy succeeded.
            do {
                try fm.createDirectory(at: batchDir, withIntermediateDirectories: true)
                let dest = batchDir.appendingPathComponent("\(folderName(for: chatKey))-\(UUID().uuidString.prefix(8))", isDirectory: true)
                try fm.copyItem(at: source, to: dest)
                try fm.removeItem(at: source)
                moved = !fm.fileExists(atPath: source.path)
            } catch {
                moved = false
            }
        }

        var blocked = loadBlockedSlots(from: root)
        if moved {
            if blocked.remove(chatKey) != nil {
                saveBlockedSlots(blocked, under: root)
            }
            return IsolationReport(
                isolatedMessages: items.count,
                failedMessages: 0,
                failedSlots: [],
                readableExportSucceeded: exportOk
            )
        } else {
            blocked.insert(chatKey)
            saveBlockedSlots(blocked, under: root)
            return IsolationReport(
                isolatedMessages: 0,
                failedMessages: items.count,
                failedSlots: [chatKey],
                readableExportSucceeded: exportOk
            )
        }
    }

    private static func writeReadableExport(items: [StoredQueuedMessage], chatKey: String, under exportRoot: URL, stamp: String) -> Bool {
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
                    try photo.write(to: dir.appendingPathComponent(photoName), options: fileWriteOptions)
                    lines.append("")
                    lines.append("![附图 \(photoIndex + 1)](\(photoName))")
                }
                lines.append("")
            }
            let noteURL = dir.appendingPathComponent("\(safeKey).md")
            try Data(lines.joined(separator: "\n").utf8).write(to: noteURL, options: fileWriteOptions)
            return true
        } catch {
            return false
        }
    }

    /// Saves a transaction marker before multi-step `openLeafNow` writes so an interrupted or partially failed
    /// leaf restore can be cleanly rolled back or finished on next launch.
    public static func savePendingLeafOpen(_ tx: PendingLeafOpen, under root: URL) throws {
        let fm = FileManager.default
        let dir = pendingLeafOpenDir(under: root)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(tx)
        try data.write(to: pendingLeafOpenFile(for: tx.chatKey, under: root), options: fileWriteOptions)
    }

    /// Loads all unfinished `openLeafNow` transaction markers under `root`.
    public static func loadPendingLeafOpens(from root: URL) -> [PendingLeafOpen] {
        let fm = FileManager.default
        let dir = pendingLeafOpenDir(under: root)
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        return files.compactMap { url in
            guard url.pathExtension == "json",
                  let data = try? Data(contentsOf: url),
                  let tx = try? JSONDecoder().decode(PendingLeafOpen.self, from: data) else {
                return nil
            }
            return tx
        }
    }

    /// Returns the POSIX inode of a regular (non-symlink) file at `url`, or `nil` if absent/not a regular file.
    public static func fileInode(at url: URL) -> UInt64? {
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }
        return UInt64(truncatingIfNeeded: st.st_ino)
    }

    /// Returns the POSIX inode of a (non-symlink) directory at `url`, or `nil` if absent/not a directory.
    public static func directoryInode(at url: URL) -> UInt64? {
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else {
            return nil
        }
        return UInt64(truncatingIfNeeded: st.st_ino)
    }

    /// Removes the `openLeafNow` transaction marker for `chatKey`.
    public static func clearPendingLeafOpen(for chatKey: String, under root: URL) {
        let fm = FileManager.default
        let file = pendingLeafOpenFile(for: chatKey, under: root)
        if fm.fileExists(atPath: file.path) {
            try? fm.removeItem(at: file)
        }
    }

    /// Removes all `openLeafNow` transaction markers under `root` (e.g. after `Backup.restore` replaces `Team/`).
    public static func clearAllPendingLeafOpens(under root: URL) {
        let fm = FileManager.default
        let dir = pendingLeafOpenDir(under: root)
        if fm.fileExists(atPath: dir.path) {
            try? fm.removeItem(at: dir)
        }
    }

    /// Reconciles any interrupted or partially failed `openLeafNow` transactions on startup:
    /// - If `Team/chats` itself was replaced (e.g. by a backup restore), discards the stale marker without touching files.
    /// - If the leaf is still listed in `<chatKey>~leaves.json` and its leaf chat file still exists on disk,
    ///   rolls back ONLY the exact active chat file and active queue copy written by this transaction (verified by
    ///   entry IDs, queue item IDs, and POSIX inode) so newer turns or restored backups are never deleted.
    /// - If the leaf was already removed from `<chatKey>~leaves.json`, completes cleanup of the leftover leaf files and queue.
    public static func reconcilePendingLeafOpens(teamRoot: URL, queuedRoot: URL) {
        let transactions = loadPendingLeafOpens(from: queuedRoot)
        guard !transactions.isEmpty else { return }
        let fm = FileManager.default
        let chatsDir = teamRoot.appendingPathComponent("chats", isDirectory: true)
        let currentChatsDirInode = directoryInode(at: chatsDir)
        let slots = loadAllSlots(from: queuedRoot)

        for tx in transactions {
            if let expectedDirInode = tx.chatsDirInode, currentChatsDirInode != expectedDirInode {
                // `Team/chats` was replaced (for example by `Backup.restore`): discard stale marker safely.
                clearPendingLeafOpen(for: tx.chatKey, under: queuedRoot)
                continue
            }

            let safeChat = tx.chatKey.replacingOccurrences(of: "/", with: "_")
            let safeLeaf = tx.leafKey.replacingOccurrences(of: "/", with: "_")
            let activeChatURL = chatsDir.appendingPathComponent("\(safeChat).json")
            let leafChatURL = chatsDir.appendingPathComponent("\(safeLeaf).json")
            let leafSummaryURL = chatsDir.appendingPathComponent("\(safeChat)~\(tx.leafId)~summary.json")
            let leafListURL = chatsDir.appendingPathComponent("\(safeChat)~leaves.json")

            // Determine whether the leaf index already dropped `tx.leafId`.
            let indexExists = fm.fileExists(atPath: leafListURL.path)
            let leafStillInIndex: Bool
            if !indexExists {
                leafStillInIndex = false
            } else if let data = try? Data(contentsOf: leafListURL),
                      let list = try? JSONDecoder().decode([LeafIDRecord].self, from: data) {
                leafStillInIndex = list.contains(where: { $0.id == tx.leafId })
            } else {
                // Index unreadable: fail closed, leave files untouched until readable.
                continue
            }

            if leafStillInIndex && fm.fileExists(atPath: leafChatURL.path) {
                // Index write never committed: roll back active chat / queue ONLY if they still match this transaction.
                var rollbackOk = true
                if fm.fileExists(atPath: activeChatURL.path) {
                    if let chatData = try? Data(contentsOf: activeChatURL),
                       let records = try? JSONDecoder().decode([LeafIDRecord].self, from: chatData) {
                        let matchesEntries = records.map(\.id) == tx.writtenChatEntryIds
                        let matchesInode = tx.writtenChatInode == nil || fileInode(at: activeChatURL) == tx.writtenChatInode
                        if matchesEntries && matchesInode {
                            try? fm.removeItem(at: activeChatURL)
                            if fm.fileExists(atPath: activeChatURL.path) { rollbackOk = false }
                        }
                    } else {
                        // Active chat exists but cannot be decoded: fail closed, do not delete.
                        rollbackOk = false
                    }
                }
                if !tx.writtenActiveQueuedIds.isEmpty,
                   let activeSlot = slots[tx.chatKey],
                   activeSlot.items.map(\.id) == tx.writtenActiveQueuedIds {
                    let keepIds = Set(tx.priorActiveQueuedIds)
                    let restoredPrior = activeSlot.items.filter { keepIds.contains($0.id) }
                    do {
                        try save(restoredPrior, for: tx.chatKey, anchor: restoredPrior.isEmpty ? nil : ConversationAnchor(), under: queuedRoot)
                    } catch {
                        rollbackOk = false
                    }
                }
                if rollbackOk {
                    clearPendingLeafOpen(for: tx.chatKey, under: queuedRoot)
                }
            } else if !leafStillInIndex {
                // Index write already committed before crash: finish deleting leftover leaf files and leaf queue.
                let leafMatchesInode = tx.leafChatInode == nil || fileInode(at: leafChatURL) == tx.leafChatInode
                if fm.fileExists(atPath: leafChatURL.path), leafMatchesInode {
                    try? fm.removeItem(at: leafChatURL)
                }
                if fm.fileExists(atPath: leafSummaryURL.path), leafMatchesInode {
                    try? fm.removeItem(at: leafSummaryURL)
                }
                if !fm.fileExists(atPath: leafChatURL.path) {
                    try? save([], for: tx.leafKey, under: queuedRoot)
                }
                if !leafMatchesInode {
                    clearPendingLeafOpen(for: tx.chatKey, under: queuedRoot)
                } else if !fm.fileExists(atPath: leafChatURL.path),
                          !fm.fileExists(atPath: folder(for: tx.leafKey, under: queuedRoot).path) {
                    clearPendingLeafOpen(for: tx.chatKey, under: queuedRoot)
                }
            } else {
                // Leaf file already gone: clear stale transaction marker.
                clearPendingLeafOpen(for: tx.chatKey, under: queuedRoot)
            }
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
