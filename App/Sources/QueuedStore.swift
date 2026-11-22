import Craft
import Foundation

/// App-side serial queue wrapper over `QueuedMessageStore`, storing queued turn messages outside `Team/`
/// so pending messages survive app termination without interfering with `Backup.swift`.
enum QueuedStore {
    private static let writer = DispatchQueue(label: "clio.queued-messages", qos: .utility)

    private static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClioQueued", isDirectory: true)
    }

    nonisolated static func loadAll() -> [String: [StoredQueuedMessage]] {
        writer.sync {}
        return QueuedMessageStore.loadAll(from: root)
    }

    @MainActor
    static func save(_ items: [TeamModel.Queued], for chatKey: String) {
        guard !Disk.frozen else { return }
        let snapshots = items.map {
            StoredQueuedMessage(
                id: $0.id,
                text: $0.text,
                photos: $0.photos,
                interject: $0.interject,
                userInitiated: $0.userInitiated
            )
        }
        let base = root
        writer.async {
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

    @MainActor
    static func clear(_ chatKey: String) {
        save([], for: chatKey)
    }
}
