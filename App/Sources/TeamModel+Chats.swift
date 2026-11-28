import AgentKit
import Craft
import SwiftUI
import UserNotifications
import UIKit

extension TeamModel {
    // MARK: Chats

    func history(_ key: String) -> [Entry] {
        if let kept = entries[key] { return kept }
        guard keeping else {
            entries[key] = []
            return []
        }
        return applyChatLoadOutcome(Disk.loadChatChecked(key), for: key)
    }

    func loadHistory(_ key: String) async -> [Entry] {
        if let kept = entries[key] { return kept }
        guard keeping else { return [] }
        let outcome = await Task.detached(priority: .userInitiated) {
            Disk.loadChatChecked(key)
        }.value
        if let newer = entries[key] { return newer }
        guard !Task.isCancelled else {
            switch outcome {
            case .loaded(let loaded): return loaded
            case .corrupt(let recovered, _, _): return recovered
            case .missing, .unreadable: return []
            }
        }
        return applyChatLoadOutcome(outcome, for: key)
    }

    @discardableResult
    func applyChatLoadOutcome(_ outcome: Disk.ChatLoadOutcome, for key: String) -> [Entry] {
        switch outcome {
        case .missing:
            unreadableChats.remove(key)
            entries[key] = []
            return []
        case .loaded(let loaded):
            unreadableChats.remove(key)
            entries[key] = loaded
            return loaded
        case .corrupt(let recovered, let quarantined, _):
            if quarantined {
                unreadableChats.remove(key)
                entries[key] = recovered
            } else {
                unreadableChats.insert(key)
            }
            return recovered
        case .unreadable:
            unreadableChats.insert(key)
            return []
        }
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
                names.formUnion(entry.message.mediaReferences ?? [])
            }
        }
        return names
    }
}
