import Craft
import Foundation
import UIKit

/// App-side serial queue wrapper over `QueuedMessageStore`, storing queued turn messages outside `Team/`
/// so pending messages survive app termination without interfering with `Backup.swift`.
enum QueuedStore {
    private static let writer = DispatchQueue(label: "clio.queued-messages", qos: .utility)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pendingCount = 0

    private static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClioQueued", isDirectory: true)
    }

    private nonisolated static func snapshot(_ items: [TeamModel.Queued]) -> [StoredQueuedMessage] {
        items.map {
            StoredQueuedMessage(
                id: $0.id,
                text: $0.text,
                photos: $0.photos,
                interject: $0.interject,
                userInitiated: $0.userInitiated
            )
        }
    }

    nonisolated static func loadAll() -> [String: [StoredQueuedMessage]] {
        writer.sync {}
        return QueuedMessageStore.loadAll(from: root)
    }

    @MainActor
    static func save(_ items: [TeamModel.Queued], for chatKey: String) {
        guard !Disk.frozen else { return }
        let snapshots = snapshot(items)
        let base = root
        lock.withLock { pendingCount += 1 }
        writer.async {
            defer { lock.withLock { pendingCount = max(0, pendingCount - 1) } }
            guard !Disk.frozen else { return }
            do {
                try QueuedMessageStore.save(snapshots, for: chatKey, under: base)
            } catch {
                let reason = error.localizedDescription
                DispatchQueue.main.async {
                    Diag.note("排队消息没存进手机：\(reason)")
                }
            }
        }
    }

    /// Saves synchronously and throws on error, used when moving queued messages to a new storage slot
    /// so the source slot is only cleared once the destination is surely on disk.
    nonisolated static func saveAndWait(_ items: [TeamModel.Queued], for chatKey: String) throws {
        let snapshots = snapshot(items)
        let base = root
        var failure: Error?
        writer.sync {
            guard !Disk.frozen else {
                failure = TeamError(message: "刚恢复了备份，重新打开 Clio 后才能保存。")
                return
            }
            do {
                try QueuedMessageStore.save(snapshots, for: chatKey, under: base)
            } catch {
                failure = error
            }
        }
        if let failure { throw failure }
    }

    /// Background helper for startup deduplication cleanup.
    nonisolated static func saveDetached(_ items: [StoredQueuedMessage], for chatKey: String) {
        let base = root
        lock.withLock { pendingCount += 1 }
        writer.async {
            defer { lock.withLock { pendingCount = max(0, pendingCount - 1) } }
            guard !Disk.frozen else { return }
            try? QueuedMessageStore.save(items, for: chatKey, under: base)
        }
    }

    @MainActor
    static func clear(_ chatKey: String) {
        save([], for: chatKey)
    }

    @MainActor
    static func finishBeforeSuspension() {
        guard lock.withLock({ pendingCount > 0 }) else { return }
        let app = UIApplication.shared
        var token = UIBackgroundTaskIdentifier.invalid
        func end() {
            guard token != .invalid else { return }
            app.endBackgroundTask(token)
            token = .invalid
        }
        token = app.beginBackgroundTask(withName: "clio-queued-messages") { end() }
        writer.async {
            DispatchQueue.main.async { end() }
        }
    }
}
