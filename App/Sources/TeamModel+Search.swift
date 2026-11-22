import AgentKit
import Craft
import SwiftUI
import UserNotifications
import UIKit

extension TeamModel {
    // MARK: Searching

    struct Hit: Identifiable, Sendable {
        let id = UUID()
        var key: String
        var name: String
        var snippet: String
        var at: Double
        /// In a leaf put aside, not the conversation now.
        var leaf: String?
    }

    /// Finds the words in every conversation, now and put aside. Newest first. The reading and matching happen off
    /// the main thread, and conversations not open are read for this search only, not kept in memory.
    func search(_ words: String) async -> [Hit] {
        let needle = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.count >= 1 else { return [] }
        var chats: [(String, String)] = bots.map { (Self.key(bot: $0.id), $0.name) }
        chats += rooms.map { (Self.key(room: $0.id), $0.name) }
        let keeping = self.keeping
        let sources = chats.map { key, name in
            (key: key, name: name, open: entries[key], leaves: leaves(key).map { (id: $0.id, title: $0.title, at: $0.at) })
        }
        return await Task.detached(priority: .userInitiated) {
            var hits: [Hit] = []
            func scan(_ list: [Entry], key: String, name: String, leaf: String?) {
                for entry in list.reversed() where entry.note != true && entry.message.role != .tool {
                    if Task.isCancelled || hits.count > 200 { return }
                    let text = entry.message.text
                    guard let range = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) else { continue }
                    let start = text.index(range.lowerBound, offsetBy: -24, limitedBy: text.startIndex) ?? text.startIndex
                    let end = text.index(range.upperBound, offsetBy: 60, limitedBy: text.endIndex) ?? text.endIndex
                    let snippet = (start == text.startIndex ? "" : "…") + text[start..<end].replacingOccurrences(of: "\n", with: " ") + (end == text.endIndex ? "" : "…")
                    hits.append(Hit(key: key, name: name, snippet: snippet, at: entry.at, leaf: leaf))
                }
            }
            for source in sources {
                if Task.isCancelled { break }
                scan(source.open ?? (keeping ? Disk.loadChat(source.key) : []), key: source.key, name: source.name, leaf: nil)
                for leaf in source.leaves {
                    if leaf.title.localizedCaseInsensitiveContains(needle) {
                        hits.append(Hit(key: source.key, name: source.name, snippet: leaf.title, at: leaf.at, leaf: leaf.id))
                    }
                    if keeping, let kept = Disk.load([Entry].self, Self.leafFile(source.key, leaf.id)) {
                        scan(kept, key: source.key, name: source.name, leaf: leaf.id)
                    }
                }
            }
            return Array(hits.sorted { $0.at > $1.at }.prefix(80))
        }.value
    }
}
