import Craft
import Foundation
import SwiftUI

extension TeamModel {
    var canDispatchQueue: Bool {
        QueuedMessageStore.canDispatchQueue(isFrozen: Disk.frozen, isRestoring: queueDispatchSuspended)
    }

    func canAcceptInput(for key: String) -> Bool {
        canDispatchQueue && !openingLeaves.contains(key) && !unresolvedLeafOpenChats.contains(key)
    }

    func beginBackupRestore() {
        queueDispatchSuspended = true
        subtasks.cancelAllForBackupRestore(team: self)
    }

    func finishBackupRestoreSucceeded() {
        queueDispatchSuspended = true
        subtasks.cancelAllForBackupRestore(team: self)
        for key in Array(runs.keys) {
            stop(key)
        }
        sendQueuedNow.removeAll()
        pendingInterjects.removeAll()
        inFlightQueued.removeAll()
        queued.removeAll()
        unresolvedLeafOpenChats.removeAll()
        scheduleIndexResetForRestore()
        prepareMemoryStoreForRestore()
        Task { await ArtifactIndex.shared.invalidateAll() }
    }

    func finishBackupRestoreFailed() {
        if !Disk.frozen {
            queueDispatchSuspended = false
        }
    }

    func allPersistableQueued(_ key: String, extra: [Queued] = []) -> [Queued] {
        var seen: Set<UUID> = []
        var combined: [Queued] = []
        for item in (inFlightQueued[key] ?? []) + (queued[key] ?? []) + extra where seen.insert(item.id).inserted {
            combined.append(item)
        }
        return combined
    }

    func persistQueued(_ key: String) {
        guard keeping, !Disk.frozen else { return }
        let items = allPersistableQueued(key)
        let anchor = items.isEmpty ? nil : ConversationAnchor.from(entryIds: history(key).map(\.id))
        QueuedStore.save(items, for: key, anchor: anchor)
    }

    func confirmQueuedRemoved(_ ids: Set<UUID>, for key: String) {
        guard var items = inFlightQueued[key] else { return }
        let before = items.count
        items.removeAll { ids.contains($0.id) }
        guard items.count != before else { return }
        inFlightQueued[key] = items.isEmpty ? nil : items
        persistQueued(key)
    }

    func restoreInFlightQueued(_ ids: Set<UUID>, to key: String) {
        guard var items = inFlightQueued[key] else { return }
        let restored = items.filter { ids.contains($0.id) }
        guard !restored.isEmpty else { return }
        items.removeAll { ids.contains($0.id) }
        inFlightQueued[key] = items.isEmpty ? nil : items
        let current = queued[key] ?? []
        let existing = Set(current.map(\.id))
        let toPrepend = restored.filter { !existing.contains($0.id) }
        if !toPrepend.isEmpty {
            withAnimation(.smooth) { queued[key] = toPrepend + current }
        }
        persistQueued(key)
    }

    func restoreUnemittedInterjects(for key: String) {
        guard let leftover = pendingInterjects.removeValue(forKey: key), !leftover.isEmpty else { return }
        restoreInFlightQueued(Set(leftover.map(\.id)), to: key)
    }

    func clearQueuedSlot(_ key: String) {
        queued[key] = nil
        inFlightQueued[key] = nil
        pendingInterjects[key] = nil
        if keeping { QueuedStore.clear(key) }
    }

    /// Verifies that `key`'s on-disk history is readable before allowing any write/shelve/openLeaf replacement.
    /// Pass `verifyDisk: true` for whole-file replacement paths (`shelveCurrent` / `openLeafNow`) so even a previously
    /// cached chat whose file later became unreadable on disk is caught before overwriting.
    func ensureChatReadableForWrite(_ key: String, verifyDisk: Bool = false) -> Bool {
        guard keeping else { return true }
        if verifyDisk || unreadableChats.contains(key) {
            let outcome = Disk.loadChatChecked(key)
            switch outcome {
            case .unreadable:
                unreadableChats.insert(key)
                return false
            case .corrupt(_, let quarantined, _) where !quarantined:
                unreadableChats.insert(key)
                return false
            case .missing, .loaded, .corrupt:
                if entries[key] == nil {
                    _ = applyChatLoadOutcome(outcome, for: key)
                } else {
                    unreadableChats.remove(key)
                }
                return true
            }
        } else if entries[key] == nil {
            _ = history(key)
        }
        return !unreadableChats.contains(key)
    }
}
