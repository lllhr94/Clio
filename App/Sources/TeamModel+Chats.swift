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

    nonisolated static func threadKey(_ key: String, leaf: String) -> String { "\(key)~\(leaf)" }

    /// Move the list state with the conversation as it changes storage slots.
    func moveThread(_ source: String, to destination: String) {
        pinned = pinned.filter { $0 != destination }.map { $0 == source ? destination : $0 }
        let wasArchived = archived.remove(source) != nil
        archived.remove(destination)
        if wasArchived { archived.insert(destination) }
        let color = threadLabels.removeValue(forKey: source)
        threadLabels[destination] = color
        saveThreadState()
    }

    func forgetThreads(_ key: String, includingLeaves: Bool = false) {
        func matches(_ candidate: String) -> Bool {
            candidate == key || (includingLeaves && candidate.hasPrefix(key + "~"))
        }
        pinned.removeAll(where: matches)
        archived = archived.filter { !matches($0) }
        threadLabels = threadLabels.filter { !matches($0.key) }
        saveThreadState()
    }

    private func saveThreadState() {
        UserDefaults.standard.set(pinned, forKey: "desk.pinned")
        UserDefaults.standard.set(Array(archived), forKey: "desk.archived")
        UserDefaults.standard.set(threadLabels, forKey: "desk.threadLabels")
    }

    /// Snapshot of media filenames currently referenced by in-memory conversations (protects unflushed photos during cache cleanup).
    func referencedMediaNames() -> Set<String> {
        var names: Set<String> = []
        for list in entries.values {
            for entry in list {
                for photo in entry.photos where !photo.isEmpty {
                    names.insert(photo)
                }
            }
        }
        return names
    }
}
