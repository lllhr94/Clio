import AgentKit
import Craft
import SwiftUI
import UserNotifications
import UIKit

extension TeamModel {
    // MARK: Memory

    /// How many things stay in every conversation; older ones sink into 旧事.
    static let surfaceLimit = 40

    var surfaceMemories: [Memory] { memories.filter { $0.deep != true } }
    var deepMemories: [Memory] { memories.filter { $0.deep == true } }

    @discardableResult
    func remember(_ fact: String, by bot: String?) -> String? {
        let added: String?
        if let index = memories.firstIndex(where: { $0.text == fact }) {
            added = nil
            memories[index].deep = nil
            memories[index].used = Now.ms
            if bot == nil { memories[index].editedByUser = true }
        } else {
            let id = UUID().uuidString
            memories.append(Memory(id: id, text: fact, at: Now.ms, by: bot, used: Now.ms))
            added = id
        }
        settleMemory()
        saveMemory()
        return added
    }

    /// Keeps the surface small: the least recently used things sink first.
    func settleMemory() {
        Self.settleMemory(&memories)
    }

    static func settleMemory(_ memories: inout [Memory]) {
        let surface = memories.filter { $0.deep != true }.sorted { ($0.used ?? $0.at) < ($1.used ?? $1.at) }
        guard surface.count > Self.surfaceLimit else { return }
        let sinking = Set(surface.prefix(surface.count - Self.surfaceLimit).map(\.id))
        for index in memories.indices where sinking.contains(memories[index].id) { memories[index].deep = true }
    }

    /// Looks through everything kept, deep or not, for what matches the words. What is found comes back to the surface.
    func recall(_ words: String) -> [String] {
        let query = words.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }
        var terms = query.split(whereSeparator: { $0.isWhitespace || "，,、。".contains($0) }).map(String.init)
        // Chinese has no spaces: also try every two-character piece of a long term.
        for term in terms where term.count > 2 {
            let chars = Array(term)
            for i in 0..<(chars.count - 1) { terms.append(String(chars[i...i + 1])) }
        }
        let scored = memories.map { memory -> (Memory, Int) in
            let text = memory.text.lowercased()
            return (memory, terms.reduce(0) { $0 + (text.contains($1) ? ($1.count > 2 ? 3 : 1) : 0) })
        }
        .filter { $0.1 > 0 }
        .sorted { $0.1 > $1.1 }
        .prefix(8)
        let found = Set(scored.map(\.0.id))
        for index in memories.indices where found.contains(memories[index].id) {
            memories[index].deep = nil
            memories[index].used = Now.ms
        }
        if !found.isEmpty {
            settleMemory()
            saveMemory()
        }
        return scored.map(\.0.text)
    }

    func setDeep(_ id: String, _ deep: Bool) {
        guard let index = memories.firstIndex(where: { $0.id == id }) else { return }
        memories[index].deep = deep ? true : nil
        memories[index].used = Now.ms
        if !deep { settleMemory() }
        saveMemory()
    }

    func forget(about words: String) -> [String] {
        let needle = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        let gone = memories.filter { $0.text.localizedCaseInsensitiveContains(needle) }
        memories.removeAll { gone.contains($0) }
        removeReviewDetails(Set(gone.map(\.id)))
        saveMemory()
        return gone.map(\.text)
    }

    /// Takes back one thing a companion wrote into 拾遗 (from its step in the trace).
    @discardableResult
    /// 撤回 under a turn: only what a companion wrote and you have not touched; your own entries are never taken.
    func unremember(_ id: String, fact: String) -> Bool {
        guard let memory = memories.first(where: { $0.id == id }),
              memory.text == fact, memory.by != nil, memory.editedByUser != true else { return false }
        deleteMemory(id)
        return true
    }

    func deleteMemory(_ id: String) {
        memories.removeAll { $0.id == id }
        removeReviewDetails([id])
        saveMemory()
    }

    func removeReviewDetails(_ ids: Set<String>) {
        for index in memoryBook.reviews.indices {
            memoryBook.reviews[index].added.removeAll { ids.contains($0.memoryID) }
            memoryBook.reviews[index].merged.removeAll { ids.contains($0.memoryID) }
        }
        memoryReviews = memoryBook.reviews
    }
}
