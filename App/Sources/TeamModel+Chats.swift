import AgentKit
import Craft
import SwiftUI
import UserNotifications
import UIKit

extension TeamModel {
    // MARK: Chats

    func history(_ key: String) -> [Entry] {
        if let kept = entries[key] { return kept }
        let loaded = keeping ? Disk.loadChat(key) : []
        entries[key] = loaded
        return loaded
    }

    func loadHistory(_ key: String) async -> [Entry] {
        if let kept = entries[key] { return kept }
        guard keeping else { return [] }
        let loaded = await Task.detached(priority: .userInitiated) {
            Disk.loadChat(key)
        }.value
        if let newer = entries[key] { return newer }
        if !Task.isCancelled { entries[key] = loaded }
        return loaded
    }

    // MARK: Archive


    func setThreadLabel(_ label: String, for key: String) {
        threadLabels[key] = label.isEmpty ? nil : label
        UserDefaults.standard.set(threadLabels, forKey: "desk.threadLabels")
    }



    func pin(_ key: String, _ on: Bool) {
        if on { if !pinned.contains(key) { pinned.append(key) } } else { pinned.removeAll { $0 == key } }
        UserDefaults.standard.set(pinned, forKey: "desk.pinned")
        Haptics.tick(0.5)
    }

    func archive(_ key: String, _ on: Bool) {
        if on { archived.insert(key) } else { archived.remove(key) }
        UserDefaults.standard.set(Array(archived), forKey: "desk.archived")
    }
}
