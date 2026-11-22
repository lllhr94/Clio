import Foundation
import UIKit

/// Keep per-chat JSON writes off the UI thread. A replacement or deletion supersedes
/// queued snapshots, and an older operation can never finish after the newer one.
enum ChatDisk {
    private static let writer = DispatchQueue(label: "clio.chat-storage", qos: .utility)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pending: [String: UUID] = [:]

    /// Conversations whose last save failed (a full disk, say). A backup refuses to go out while any is left,
    /// since it would carry the older file; the next save of that conversation tries again.
    nonisolated(unsafe) private static var failed: Set<String> = []
    /// Completion callbacks waiting for the next write of a given chat file to land (or fail).
    /// Coalesced superseded writes transfer their callbacks to the winning write so no waiter is dropped.
    nonisolated(unsafe) private static var callbacks: [String: [@Sendable (Bool) -> Void]] = [:]

    static func save(_ entries: [Entry], chat: String, onSaved: (@Sendable (Bool) -> Void)? = nil) {
        let path = Disk.chatFile(chat)
        schedule(path, onSaved: onSaved) {
            do {
                try Disk.write(entries, path)
                lock.withLock { _ = failed.remove(path) }
                return true
            } catch {
                guard !Disk.frozen else { return false }
                lock.withLock { _ = failed.insert(path) }
                let reason = error.localizedDescription
                DispatchQueue.main.async { Diag.note("对话没存进手机：\(reason)") }
                return false
            }
        }
    }

    /// Waits for queued writes and tells how many conversations are still not on disk.
    static func finishWritesReportingFailures() -> Int {
        writer.sync {}
        return lock.withLock { failed.count }
    }

    /// Saves now and waits for it, for the few steps that delete something else right after (putting a leaf back,
    /// undoing a compression): the other copy may only go once this one is surely on disk.
    static func saveAndWait(_ entries: [Entry], chat: String) throws {
        let path = Disk.chatFile(chat)
        let id = UUID()
        lock.withLock { pending[path] = id }
        var failure: Error?
        var waiters: [@Sendable (Bool) -> Void] = []
        writer.sync {
            let taken: [@Sendable (Bool) -> Void]? = lock.withLock {
                guard pending[path] == id else { return nil }
                return callbacks.removeValue(forKey: path) ?? []
            }
            guard let taken else { return }
            waiters = taken
            do {
                try Disk.write(entries, path)
                lock.withLock { _ = failed.remove(path) }
            } catch {
                failure = error
            }
            lock.withLock { if pending[path] == id { pending[path] = nil } }
        }
        let ok = failure == nil
        for callback in waiters { callback(ok) }
        if let failure { throw failure }
    }

    static func remove(_ chat: String) {
        let path = Disk.chatFile(chat)
        schedule(path, onSaved: nil) {
            Disk.remove(path)
            return false
        }
    }

    private static func schedule(
        _ file: String,
        onSaved: (@Sendable (Bool) -> Void)?,
        write: @escaping @Sendable () -> Bool
    ) {
        let id = UUID()
        lock.withLock {
            pending[file] = id
            if let onSaved {
                callbacks[file, default: []].append(onSaved)
            }
        }
        writer.async {
            let waiters: [@Sendable (Bool) -> Void]? = lock.withLock {
                guard pending[file] == id else { return nil }
                return callbacks.removeValue(forKey: file) ?? []
            }
            guard let waiters else { return }
            let ok = write()
            lock.withLock { if pending[file] == id { pending[file] = nil } }
            for callback in waiters { callback(ok) }
        }
    }

    /// Called by the backup worker so the archive also sees the newest saved messages.
    static func finishWrites() { writer.sync {} }

    @MainActor
    static func finishBeforeSuspension() {
        guard lock.withLock({ !pending.isEmpty }) else { return }
        let app = UIApplication.shared
        var token = UIBackgroundTaskIdentifier.invalid
        func end() {
            guard token != .invalid else { return }
            app.endBackgroundTask(token)
            token = .invalid
        }
        token = app.beginBackgroundTask(withName: "clio-chat-storage") { end() }
        writer.async {
            DispatchQueue.main.async { end() }
        }
    }
}
