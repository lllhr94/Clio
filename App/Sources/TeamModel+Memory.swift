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
    var pinnedMemories: [Memory] {
        let pinned = MemoryStoreBridge.shared.pinnedIDsSnapshot()
        return memories.filter { $0.deep != true && pinned.contains($0.id) }
    }

    func isPinnedMemory(_ id: String) -> Bool {
        MemoryStoreBridge.shared.pinnedIDsSnapshot().contains(id)
    }

    @discardableResult
    func remember(_ fact: String, by bot: String?) -> String? {
        let orderedSecrets = Vault.allStrings().filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        let safeFact = MemorySafety.redactSecrets(fact, secrets: orderedSecrets)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safeFact.isEmpty else { return nil }

        let now = Now.ms
        let added: String?
        let touchedMemory: Memory
        if let index = memories.firstIndex(where: { $0.text == safeFact }) {
            added = nil
            memories[index].deep = nil
            memories[index].used = now
            if bot == nil { memories[index].editedByUser = true }
            touchedMemory = memories[index]
        } else {
            let id = UUID().uuidString
            let created = Memory(id: id, text: safeFact, at: now, by: bot, used: now, editedByUser: bot == nil ? true : nil)
            memories.append(created)
            added = id
            touchedMemory = created
        }
        MemoryStoreBridge.shared.recordRemember(
            memory: touchedMemory,
            explicitUserAction: bot == nil,
            nowMs: now
        )
        settleMemory()
        memoryBook.memories = memories
        if bot == nil {
            clearMemoryRetraction(text: safeFact)
        } else {
            invalidateMemoryPromptCache()
        }
        saveMemory()
        return added
    }

    /// Keeps the surface small: the least recently used things sink first; pinned (`镇纸`) entries never sink.
    func settleMemory() {
        Self.settleMemory(&memories)
    }

    static func settleMemory(_ memories: inout [Memory]) {
        let pinnedIDs = MemoryStoreBridge.shared.pinnedIDsSnapshot()
        let totalSurface = memories.filter { $0.deep != true }.count
        guard totalSurface > Self.surfaceLimit else { return }
        let candidates = memories
            .filter { $0.deep != true && !pinnedIDs.contains($0.id) }
            .sorted { ($0.used ?? $0.at) < ($1.used ?? $1.at) }
        let sinkCount = min(totalSurface - Self.surfaceLimit, candidates.count)
        guard sinkCount > 0 else { return }
        let sinking = Set(candidates.prefix(sinkCount).map(\.id))
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
        let now = Now.ms
        let found = Set(scored.map(\.0.id))
        for index in memories.indices where found.contains(memories[index].id) {
            memories[index].deep = nil
            memories[index].used = now
        }
        if !found.isEmpty {
            MemoryStoreBridge.shared.recordRecall(ids: found, nowMs: now)
            settleMemory()
            memoryBook.memories = memories
            invalidateMemoryPromptCache()
            saveMemory()
        }
        return scored.map(\.0.text)
    }

    func setDeep(_ id: String, _ deep: Bool) {
        guard let index = memories.firstIndex(where: { $0.id == id }) else { return }
        let now = Now.ms
        memories[index].deep = deep ? true : nil
        memories[index].used = now
        MemoryStoreBridge.shared.recordSetDeep(id: id, deep: deep, nowMs: now)
        if !deep { settleMemory() }
        memoryBook.memories = memories
        invalidateMemoryPromptCache()
        saveMemory()
    }

    func pinMemory(_ id: String, _ pinned: Bool = true) {
        guard let index = memories.firstIndex(where: { $0.id == id }) else { return }
        let now = Now.ms
        memories[index].deep = nil
        memories[index].used = now
        memories[index].editedByUser = true
        MemoryStoreBridge.shared.recordPin(id: id, pinned: pinned, nowMs: now)
        settleMemory()
        memoryBook.memories = memories
        invalidateMemoryPromptCache()
        saveMemory()
    }

    func setMemoryLayer(_ id: String, _ layer: MemoryLayer, kind: String? = nil, topic: String? = nil, confidence: Double? = nil) {
        let now = Now.ms
        if layer == .archived {
            MemoryStoreBridge.shared.recordLayerAndMetadata(
                id: id,
                layer: .archived,
                kind: kind,
                topic: topic,
                confidence: confidence,
                nowMs: now
            )
            memories.removeAll { $0.id == id }
            memoryBook.memories = memories
            invalidateMemoryPromptCache()
            saveMemory()
            return
        }
        guard let index = memories.firstIndex(where: { $0.id == id }) else { return }
        memories[index].deep = (layer == .deep) ? true : nil
        if layer == .pinned || layer == .surface {
            memories[index].used = now
        }
        MemoryStoreBridge.shared.recordLayerAndMetadata(
            id: id,
            layer: layer,
            kind: kind,
            topic: topic,
            confidence: confidence,
            nowMs: now
        )
        if layer != .deep { settleMemory() }
        memoryBook.memories = memories
        invalidateMemoryPromptCache()
        saveMemory()
    }

    func archiveMemory(_ id: String) {
        setMemoryLayer(id, .archived)
    }

    @discardableResult
    func restoreMemory(_ id: String) -> Bool {
        let now = Now.ms
        guard var restored = MemoryStoreBridge.shared.recordRestore(id: id, nowMs: now) else { return false }
        restored.deep = nil
        restored.used = now
        memories.removeAll { $0.id == id }
        memories.append(restored)
        settleMemory()
        memoryBook.memories = memories
        clearMemoryRetraction(text: restored.text)
        saveMemory()
        return true
    }

    func forget(about words: String) -> [String] {
        let needle = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        let gone = memories.filter { memory in
            memory.by != nil && memory.editedByUser != true && memory.text.localizedCaseInsensitiveContains(needle)
        }
        guard !gone.isEmpty else { return [] }
        let now = Now.ms
        let goneIds = Set(gone.map(\.id))
        memories.removeAll { goneIds.contains($0.id) }
        memoryBook.memories = memories
        removeReviewDetails(goneIds)
        MemoryStoreBridge.shared.recordSoftDelete(
            items: gone.map { (id: $0.id, text: $0.text) },
            nowMs: now,
            reason: "agent_forget"
        )
        invalidateMemoryPromptCache(retractedItems: gone.map { (id: $0.id, text: $0.text) })
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
        let removed = memories.first { $0.id == id }
        let now = Now.ms
        memories.removeAll { $0.id == id }
        memoryBook.memories = memories
        removeReviewDetails([id])
        MemoryStoreBridge.shared.recordSoftDelete(
            items: [(id: id, text: removed?.text)],
            nowMs: now,
            reason: "user_delete"
        )
        invalidateMemoryPromptCache(retractedID: id, textForInFlightGuard: removed?.text)
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
