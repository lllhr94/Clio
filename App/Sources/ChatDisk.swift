import Foundation
import UIKit

/// Keep per-chat JSON writes off the UI thread. A replacement or deletion supersedes
/// queued snapshots, and an older operation can never finish after the newer one.
enum ChatDisk {
    private static let writer = DispatchQueue(label: "clio.chat-storage", qos: .utility)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pending: [String: UUID] = [:]

    static func save(_ entries: [Entry], chat: String) {
        let path = Disk.chatFile(chat)
        schedule(path) { Disk.save(entries, path) }
    }

    static func remove(_ chat: String) {
        let path = Disk.chatFile(chat)
        schedule(path) { Disk.remove(path) }
    }

    private static func schedule(_ file: String, write: @escaping @Sendable () -> Void) {
        let id = UUID()
        lock.withLock { pending[file] = id }
        writer.async {
            guard lock.withLock({ pending[file] == id }) else { return }
            write()
            lock.withLock { if pending[file] == id { pending[file] = nil } }
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
