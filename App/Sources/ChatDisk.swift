import Foundation
import UIKit

/// Keep per-chat JSON writes off the UI thread. A replacement or deletion supersedes
/// queued snapshots, and an older operation can never finish after the newer one.
enum ChatDisk {
    private static let writer = DispatchQueue(label: "clio.chat-storage", qos: .utility)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pending: [String: UInt64] = [:]
    nonisolated(unsafe) private static var nextSeq: UInt64 = 0
    nonisolated(unsafe) private static var inFlightCounts: [String: Int] = [:]

    /// Files whose last save failed (a full disk, say). A backup refuses to go out while any is left,
    /// since it would carry the older file; the next save of that file tries again.
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

    /// Coalesced off-main persistence for settings, companions, routines, options, and other JSON files.
    /// Shares `ChatDisk.writer`, `failed`, `finishWrites()`, and `finishBeforeSuspension()` with chat storage.
    static func saveValue<Value: Encodable & Sendable>(_ value: Value, file: String) {
        schedule(file, onSaved: nil) {
            do {
                try Disk.write(value, file)
                lock.withLock { _ = failed.remove(file) }
                return true
            } catch {
                guard !Disk.frozen else { return false }
                lock.withLock { _ = failed.insert(file) }
                let reason = error.localizedDescription
                DispatchQueue.main.async { Diag.note("没存进手机：\(file)（\(reason)）") }
                return false
            }
        }
    }

    /// Read-modify-write on `ChatDisk.writer` so field-level patches (e.g. model-ref cleanup on unloaded
    /// `chats/*~options.json`) never clobber sibling fields or race with `saveValue`.
    static func modifyValue<Value: Codable>(
        _ type: Value.Type,
        file: String,
        transform: @escaping @Sendable (inout Value) -> Bool
    ) {
        let seq: UInt64 = lock.withLock {
            nextSeq &+= 1
            inFlightCounts[file, default: 0] += 1
            return nextSeq
        }
        writer.async {
            let shouldRun = lock.withLock {
                if (pending[file] ?? 0) > seq {
                    finishFlight(for: file)
                    return false
                }
                return true
            }
            guard shouldRun else { return }
            if !Disk.frozen, var current = Disk.load(type, file), transform(&current) {
                do {
                    try Disk.write(current, file)
                    lock.withLock { _ = failed.remove(file) }
                } catch {
                    if !Disk.frozen {
                        lock.withLock { _ = failed.insert(file) }
                        let reason = error.localizedDescription
                        DispatchQueue.main.async { Diag.note("没存进手机：\(file)（\(reason)）") }
                    }
                }
            }
            lock.withLock { finishFlight(for: file) }
        }
    }

    /// Writes `value` synchronously through `writer`, superseding earlier queued snapshots for `file`.
    static func writeValueAndWait<Value: Encodable>(_ value: Value, file: String) throws {
        let seq = enqueueFullWriteToken(for: file, onSaved: nil)
        var failure: Error?
        var waiters: [@Sendable (Bool) -> Void] = []
        writer.sync {
            waiters = lock.withLock { callbacks.removeValue(forKey: file) ?? [] }
            do {
                try Disk.write(value, file)
                lock.withLock { _ = failed.remove(file) }
            } catch {
                failure = error
            }
            lock.withLock {
                if pending[file] == seq { pending[file] = nil }
                finishFlight(for: file)
            }
        }
        let ok = failure == nil
        for callback in waiters { callback(ok) }
        if let failure { throw failure }
    }

    /// Waits for queued writes and tells how many files are still not on disk.
    static func finishWritesReportingFailures() -> Int {
        writer.sync {}
        return lock.withLock { failed.count }
    }

    /// Saves now and waits for it, for the few steps that delete something else right after (putting a leaf back,
    /// undoing a compression): the other copy may only go once this one is surely on disk.
    static func saveAndWait(_ entries: [Entry], chat: String) throws {
        let path = Disk.chatFile(chat)
        let seq = enqueueFullWriteToken(for: path, onSaved: nil)
        var failure: Error?
        var waiters: [@Sendable (Bool) -> Void] = []
        writer.sync {
            let taken: [@Sendable (Bool) -> Void]? = lock.withLock {
                guard pending[path] == seq else {
                    finishFlight(for: path)
                    return nil
                }
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
            lock.withLock {
                if pending[path] == seq { pending[path] = nil }
                finishFlight(for: path)
            }
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

    /// Synchronously removes a chat file through the writer queue (used for rolling back an uncommitted leaf open).
    static func removeAndWait(_ chat: String) {
        let path = Disk.chatFile(chat)
        let seq = enqueueFullWriteToken(for: path, onSaved: nil)
        var waiters: [@Sendable (Bool) -> Void] = []
        writer.sync {
            let taken: [@Sendable (Bool) -> Void]? = lock.withLock {
                guard pending[path] == seq else {
                    finishFlight(for: path)
                    return nil
                }
                return callbacks.removeValue(forKey: path) ?? []
            }
            guard let taken else { return }
            waiters = taken
            Disk.remove(path)
            lock.withLock {
                _ = failed.remove(path)
                if pending[path] == seq { pending[path] = nil }
                finishFlight(for: path)
            }
        }
        for callback in waiters { callback(false) }
    }

    private static func enqueueFullWriteToken(for file: String, onSaved: (@Sendable (Bool) -> Void)?) -> UInt64 {
        lock.withLock {
            nextSeq &+= 1
            let seq = nextSeq
            pending[file] = seq
            inFlightCounts[file, default: 0] += 1
            if let onSaved {
                callbacks[file, default: []].append(onSaved)
            }
            return seq
        }
    }

    private static func finishFlight(for file: String) {
        let remaining = (inFlightCounts[file] ?? 1) - 1
        if remaining <= 0 {
            inFlightCounts.removeValue(forKey: file)
        } else {
            inFlightCounts[file] = remaining
        }
    }

    private static func schedule(
        _ file: String,
        onSaved: (@Sendable (Bool) -> Void)?,
        write: @escaping @Sendable () -> Bool
    ) {
        let seq = enqueueFullWriteToken(for: file, onSaved: onSaved)
        writer.async {
            let waiters: [@Sendable (Bool) -> Void]? = lock.withLock {
                guard pending[file] == seq else {
                    finishFlight(for: file)
                    return nil
                }
                return callbacks.removeValue(forKey: file) ?? []
            }
            guard let waiters else { return }
            let ok = write()
            lock.withLock {
                if pending[file] == seq { pending[file] = nil }
                finishFlight(for: file)
            }
            for callback in waiters { callback(ok) }
        }
    }

    /// Called by the backup worker so the archive also sees the newest saved messages.
    static func finishWrites() { writer.sync {} }

    @MainActor
    static func finishBeforeSuspension() {
        guard lock.withLock({ !inFlightCounts.isEmpty }) else { return }
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
