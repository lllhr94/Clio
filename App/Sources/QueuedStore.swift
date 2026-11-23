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

    private static var quarantineRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClioQueuedIsolated", isDirectory: true)
    }

    private static var readableExportRoot: URL {
        Workspace.root.appendingPathComponent("恢复前排队", isDirectory: true)
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

    nonisolated static func loadAllSlots() -> [String: StoredQueuedSlot] {
        writer.sync {}
        return QueuedMessageStore.loadAllSlots(from: root)
    }

    nonisolated static func loadAll() -> [String: [StoredQueuedMessage]] {
        loadAllSlots().mapValues(\.items)
    }

    @MainActor
    static func save(_ items: [TeamModel.Queued], for chatKey: String, anchor: ConversationAnchor? = nil) {
        guard !Disk.frozen else { return }
        let snapshots = snapshot(items)
        let base = root
        lock.withLock { pendingCount += 1 }
        writer.async {
            defer { lock.withLock { pendingCount = max(0, pendingCount - 1) } }
            guard !Disk.frozen else { return }
            do {
                try QueuedMessageStore.save(snapshots, for: chatKey, anchor: anchor, under: base)
            } catch QueuedMessageStoreError.restoreBarrierActive {
                return
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
    nonisolated static func saveAndWait(_ items: [TeamModel.Queued], for chatKey: String, anchor: ConversationAnchor? = nil) throws {
        let snapshots = snapshot(items)
        let base = root
        var failure: Error?
        writer.sync {
            guard !Disk.frozen else {
                failure = TeamError(message: "刚恢复了备份，重新打开 Clio 后才能保存。")
                return
            }
            do {
                try QueuedMessageStore.save(snapshots, for: chatKey, anchor: anchor, under: base)
            } catch {
                failure = error
            }
        }
        if let failure { throw failure }
    }

    /// Background helper for startup deduplication cleanup.
    nonisolated static func saveDetached(_ items: [StoredQueuedMessage], for chatKey: String, anchor: ConversationAnchor? = nil) {
        let base = root
        lock.withLock { pendingCount += 1 }
        writer.async {
            defer { lock.withLock { pendingCount = max(0, pendingCount - 1) } }
            guard !Disk.frozen else { return }
            try? QueuedMessageStore.save(items, for: chatKey, anchor: anchor, under: base)
        }
    }

    private static let blockedDefaultsKey = "clio.blockedPreRestoreQueues"

    /// Atomically writes `.restore-barrier.json` (recording existing slots and pre-restore `Team/chats` identity)
    /// BEFORE `Backup.restore` touches `Team/`. Serializes on `writer.sync` to drain earlier async queue writes,
    /// and blocks all subsequent queue / pending-leaf writes until disarmed or post-restore isolation completes.
    nonisolated static func armPreRestoreBarrier(teamRoot: URL) throws {
        var failure: Error?
        writer.sync {
            do {
                _ = try QueuedMessageStore.armPreRestoreBarrier(teamRoot: teamRoot, under: root)
            } catch {
                failure = error
            }
        }
        if let failure { throw failure }
    }

    /// Removes `.restore-barrier.json` when `Backup.restore` fails and leaves `Team/` untouched,
    /// preserving any previously blocked slots in `.restore-blocked.json`.
    nonisolated static func disarmPreRestoreBarrier() {
        writer.sync {
            QueuedMessageStore.disarmPreRestoreBarrier(under: root)
        }
    }

    /// Reconciles an unfinished `.restore-barrier.json` on startup: disarms if `Team/chats` was never swapped,
    /// or promotes pre-restore slots into `.restore-blocked.json` (and `UserDefaults` fallback) if `Team/` changed.
    nonisolated static func reconcilePreRestoreBarrier(teamRoot: URL) -> Set<String> {
        writer.sync {
            let promoted = QueuedMessageStore.reconcilePreRestoreBarrier(teamRoot: teamRoot, queuedRoot: root)
            if !promoted.isEmpty {
                recordBlockedSlotsInDefaults(Array(promoted))
            }
            return promoted
        }
    }

    /// Isolates all pre-restore queued messages out of active `ClioQueued` right after `Backup.restore` succeeds
    /// and disarms `.restore-barrier.json` once every slot is either removed or durably recorded as blocked.
    @discardableResult
    nonisolated static func isolatePreRestoreQueues() -> IsolationReport {
        writer.sync {
            let report = QueuedMessageStore.finishPreRestoreIsolation(
                from: root,
                to: quarantineRoot,
                readableExportRoot: readableExportRoot
            )
            let remainingBlocked = QueuedMessageStore.loadBlockedSlots(from: root)
            if remainingBlocked.isEmpty && report.failedSlots.isEmpty {
                UserDefaults.standard.removeObject(forKey: blockedDefaultsKey)
            } else {
                let union = remainingBlocked.union(report.failedSlots)
                UserDefaults.standard.set(union.sorted(), forKey: blockedDefaultsKey)
            }
            return report
        }
    }

    /// Isolates a single slot whose conversation anchor no longer matches the chat on disk, or retries a blocked slot.
    @discardableResult
    nonisolated static func isolateSlot(_ chatKey: String) -> IsolationReport {
        writer.sync {
            let report = QueuedMessageStore.isolateSlot(chatKey, from: root, to: quarantineRoot, readableExportRoot: readableExportRoot)
            if report.failedMessages == 0 {
                removeBlockedSlotFromDefaults(chatKey)
            } else {
                recordBlockedSlotsInDefaults(report.failedSlots)
            }
            return report
        }
    }

    /// Returns all slot keys persistently blocked from auto-restoring (union of marker file and UserDefaults fallback).
    nonisolated static func loadBlockedSlots() -> Set<String> {
        writer.sync {
            let fromFile = QueuedMessageStore.loadBlockedSlots(from: root)
            let fromDefaults = Set(UserDefaults.standard.stringArray(forKey: blockedDefaultsKey) ?? [])
            return fromFile.union(fromDefaults)
        }
    }

    nonisolated static func clearBlockedSlot(_ chatKey: String) {
        writer.sync {
            var fromFile = QueuedMessageStore.loadBlockedSlots(from: root)
            if fromFile.remove(chatKey) != nil {
                QueuedMessageStore.saveBlockedSlots(fromFile, under: root)
            }
            removeBlockedSlotFromDefaults(chatKey)
        }
    }

    nonisolated static func savePendingLeafOpen(_ tx: PendingLeafOpen) throws {
        var failure: Error?
        writer.sync {
            guard !Disk.frozen else {
                failure = TeamError(message: "刚恢复了备份，重新打开 Clio 后才能保存。")
                return
            }
            do {
                try QueuedMessageStore.savePendingLeafOpen(tx, under: root)
            } catch {
                failure = error
            }
        }
        if let failure { throw failure }
    }

    nonisolated static func clearPendingLeafOpen(for chatKey: String) {
        writer.sync {
            QueuedMessageStore.clearPendingLeafOpen(for: chatKey, under: root)
        }
    }

    nonisolated static func clearAllPendingLeafOpens() {
        writer.sync {
            QueuedMessageStore.clearAllPendingLeafOpens(under: root)
        }
    }

    nonisolated static func reconcilePendingLeafOpens(teamRoot: URL) {
        writer.sync {
            QueuedMessageStore.reconcilePendingLeafOpens(teamRoot: teamRoot, queuedRoot: root)
        }
    }

    private nonisolated static func recordBlockedSlotsInDefaults(_ slots: [String]) {
        guard !slots.isEmpty else { return }
        var current = Set(UserDefaults.standard.stringArray(forKey: blockedDefaultsKey) ?? [])
        current.formUnion(slots)
        UserDefaults.standard.set(current.sorted(), forKey: blockedDefaultsKey)
    }

    private nonisolated static func removeBlockedSlotFromDefaults(_ chatKey: String) {
        var current = Set(UserDefaults.standard.stringArray(forKey: blockedDefaultsKey) ?? [])
        guard current.remove(chatKey) != nil else { return }
        if current.isEmpty {
            UserDefaults.standard.removeObject(forKey: blockedDefaultsKey)
        } else {
            UserDefaults.standard.set(current.sorted(), forKey: blockedDefaultsKey)
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
