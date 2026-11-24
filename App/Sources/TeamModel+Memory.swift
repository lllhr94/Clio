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
        guard keeping else { return [] }
        let pinned = MemoryStoreBridge.shared.pinnedIDsSnapshot()
        return memories.filter { $0.deep != true && pinned.contains($0.id) }
    }

    var archivedMemories: [MemoryRecord] {
        guard keeping else { return [] }
        return MemoryStoreBridge.shared.recordsSnapshot(layer: .archived)
    }

    func isPinnedMemory(_ id: String) -> Bool {
        guard keeping else { return false }
        return MemoryStoreBridge.shared.pinnedIDsSnapshot().contains(id)
    }

    func memoryRecord(id: String) -> MemoryRecord? {
        if keeping, let record = MemoryStoreBridge.shared.recordsSnapshot().first(where: { $0.id == id }) {
            return record
        }
        guard let memory = memories.first(where: { $0.id == id }) else { return nil }
        let pinned = isPinnedMemory(memory.id)
        return MemoryRecord(
            id: memory.id,
            text: memory.text,
            layer: pinned ? .pinned : (memory.deep == true ? .deep : .surface),
            pinned: pinned,
            createdAtMs: memory.at,
            usedAtMs: memory.used,
            byBot: memory.by,
            automatic: memory.automatic == true,
            editedByUser: memory.editedByUser == true
        )
    }

    var canMutateMemoryState: Bool {
        guard !Disk.frozen else { return false }
        if keeping && MemoryStoreBridge.shared.isCanonicalReadOnly { return false }
        return true
    }

    @discardableResult
    func remember(_ fact: String, by bot: String?) -> String? {
        guard canMutateMemoryState else { return nil }
        let orderedSecrets = Vault.allStrings().filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        let safeFact = MemorySafety.redactSecrets(fact, secrets: orderedSecrets)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safeFact.isEmpty else { return nil }

        let now = Now.ms
        var nextMemories = memories
        let added: String?
        let touchedMemory: Memory
        if let index = nextMemories.firstIndex(where: { $0.text == safeFact }) {
            added = nil
            nextMemories[index].deep = nil
            nextMemories[index].used = now
            if bot == nil { nextMemories[index].editedByUser = true }
            touchedMemory = nextMemories[index]
        } else {
            let id = UUID().uuidString
            let created = Memory(id: id, text: safeFact, at: now, by: bot, used: now, editedByUser: bot == nil ? true : nil)
            nextMemories.append(created)
            added = id
            touchedMemory = created
        }

        if !keeping {
            Self.settleMemory(&nextMemories, pinnedIDs: [])
            memories = nextMemories
            memoryBook.memories = nextMemories
            if bot == nil {
                memoryPromptState.clearRetraction(id: touchedMemory.id, text: safeFact)
            } else {
                memoryPromptState.invalidate()
            }
            syncLivePromptsFromMemories()
            return added
        }

        Self.settleMemory(&nextMemories, pinnedIDs: MemoryStoreBridge.shared.pinnedIDsSnapshot())
        var nextBook = memoryBook
        nextBook.memories = nextMemories
        guard let committed = try? commitMemoryBook(
            nextBook,
            mutation: .remember(memory: touchedMemory, explicitUserAction: bot == nil, nowMs: now)
        ) else {
            return nil
        }
        guard let added else { return nil }
        return committed.memories.contains(where: { $0.id == added }) ? added : nil
    }

    /// Keeps the surface small: the least recently used things sink first; pinned (`镇纸`) entries never sink.
    func settleMemory() {
        let pins = keeping ? MemoryStoreBridge.shared.pinnedIDsSnapshot() : []
        Self.settleMemory(&memories, pinnedIDs: pins)
    }

    static func settleMemory(_ memories: inout [Memory]) {
        settleMemory(&memories, pinnedIDs: MemoryStoreBridge.shared.pinnedIDsSnapshot())
    }

    static func settleMemory(_ memories: inout [Memory], pinnedIDs: Set<String>) {
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
        guard canMutateMemoryState else { return [] }
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
        guard !found.isEmpty else { return [] }

        let now = Now.ms
        var nextMemories = memories
        for index in nextMemories.indices where found.contains(nextMemories[index].id) {
            nextMemories[index].deep = nil
            nextMemories[index].used = now
        }
        if !keeping {
            Self.settleMemory(&nextMemories, pinnedIDs: [])
            memories = nextMemories
            memoryBook.memories = nextMemories
            memoryPromptState.invalidate()
            syncLivePromptsFromMemories()
            return scored.map(\.0.text)
        }

        Self.settleMemory(&nextMemories, pinnedIDs: MemoryStoreBridge.shared.pinnedIDsSnapshot())
        var nextBook = memoryBook
        nextBook.memories = nextMemories
        guard (try? commitMemoryBook(
            nextBook,
            mutation: .recall(ids: found, nowMs: now)
        )) != nil else {
            return []
        }
        return scored.map(\.0.text)
    }

    func setDeep(_ id: String, _ deep: Bool) {
        guard canMutateMemoryState, let index = memories.firstIndex(where: { $0.id == id }) else { return }
        let now = Now.ms
        var nextMemories = memories
        nextMemories[index].deep = deep ? true : nil
        nextMemories[index].used = now

        if !keeping {
            if !deep { Self.settleMemory(&nextMemories, pinnedIDs: []) }
            memories = nextMemories
            memoryBook.memories = nextMemories
            memoryPromptState.invalidate()
            syncLivePromptsFromMemories()
            return
        }

        if !deep {
            var candidatePins = MemoryStoreBridge.shared.pinnedIDsSnapshot()
            candidatePins.remove(id)
            Self.settleMemory(&nextMemories, pinnedIDs: candidatePins)
        }
        var nextBook = memoryBook
        nextBook.memories = nextMemories
        _ = try? commitMemoryBook(
            nextBook,
            mutation: .setDeep(id: id, deep: deep, nowMs: now)
        )
    }

    func pinMemory(_ id: String, _ pinned: Bool = true) {
        guard canMutateMemoryState, let index = memories.firstIndex(where: { $0.id == id }) else { return }
        let now = Now.ms
        var nextMemories = memories
        nextMemories[index].deep = nil
        nextMemories[index].used = now
        nextMemories[index].editedByUser = true

        if !keeping {
            Self.settleMemory(&nextMemories, pinnedIDs: [])
            memories = nextMemories
            memoryBook.memories = nextMemories
            memoryPromptState.invalidate()
            syncLivePromptsFromMemories()
            return
        }

        var candidatePins = MemoryStoreBridge.shared.pinnedIDsSnapshot()
        if pinned {
            candidatePins.insert(id)
        } else {
            candidatePins.remove(id)
        }
        Self.settleMemory(&nextMemories, pinnedIDs: candidatePins)
        var nextBook = memoryBook
        nextBook.memories = nextMemories
        _ = try? commitMemoryBook(
            nextBook,
            mutation: .pin(id: id, pinned: pinned, nowMs: now)
        )
    }

    func setMemoryLayer(_ id: String, _ layer: MemoryLayer, kind: String? = nil, topic: String? = nil, confidence: Double? = nil) {
        guard canMutateMemoryState else { return }
        let now = Now.ms
        if layer == .archived {
            if !keeping {
                memories.removeAll { $0.id == id }
                memoryBook.memories = memories
                memoryPromptState.invalidate()
                syncLivePromptsFromMemories()
                return
            }
            let fallback = memories.first { $0.id == id }
            guard fallback != nil || MemoryStoreBridge.shared.hasRecordSnapshot(id: id) else { return }
            var nextMemories = memories
            nextMemories.removeAll { $0.id == id }
            var nextBook = memoryBook
            nextBook.memories = nextMemories
            _ = try? commitMemoryBook(
                nextBook,
                mutation: .layerAndMetadata(
                    id: id,
                    layer: .archived,
                    kind: kind,
                    topic: topic,
                    confidence: confidence,
                    fallbackMemory: fallback,
                    nowMs: now
                )
            )
            return
        }

        var nextMemories = memories
        var fallbackMemory: Memory?
        if let index = nextMemories.firstIndex(where: { $0.id == id }) {
            nextMemories[index].deep = (layer == .deep) ? true : nil
            if layer == .pinned || layer == .surface {
                nextMemories[index].used = now
            }
        } else if keeping, var restored = MemoryStoreBridge.shared.restorableMemorySnapshot(id: id) {
            restored.deep = (layer == .deep) ? true : nil
            if layer == .pinned || layer == .surface {
                restored.used = now
            }
            nextMemories.removeAll { $0.id == id }
            nextMemories.append(restored)
            fallbackMemory = restored
        } else {
            return
        }

        if !keeping {
            if layer != .deep { Self.settleMemory(&nextMemories, pinnedIDs: []) }
            memories = nextMemories
            memoryBook.memories = nextMemories
            memoryPromptState.invalidate()
            syncLivePromptsFromMemories()
            return
        }

        if layer != .deep {
            var candidatePins = MemoryStoreBridge.shared.pinnedIDsSnapshot()
            if layer == .pinned {
                candidatePins.insert(id)
            } else {
                candidatePins.remove(id)
            }
            Self.settleMemory(&nextMemories, pinnedIDs: candidatePins)
        }
        var nextBook = memoryBook
        nextBook.memories = nextMemories
        _ = try? commitMemoryBook(
            nextBook,
            mutation: .layerAndMetadata(
                id: id,
                layer: layer,
                kind: kind,
                topic: topic,
                confidence: confidence,
                fallbackMemory: fallbackMemory,
                nowMs: now
            )
        )
    }

    func updateMemoryDetail(id: String, text: String, layer: MemoryLayer, kind: String, topic: String) {
        guard canMutateMemoryState else { return }
        let orderedSecrets = Vault.allStrings().filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        let safeText = MemorySafety.redactSecrets(text, secrets: orderedSecrets)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if safeText.isEmpty {
            deleteMemory(id)
            return
        }
        let current = memoryRecord(id: id)
        let cleanKind = kind.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedKind = cleanKind.isEmpty ? "fact" : cleanKind
        let cleanTopic = MemorySafety.redactSecrets(topic, secrets: orderedSecrets)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let textChanged = current?.text != safeText
        let metaChanged = current == nil
            || current?.layer != layer
            || current?.kind != resolvedKind
            || current?.topic != cleanTopic

        if layer == .archived {
            if textChanged {
                if !memories.contains(where: { $0.id == id }) {
                    setMemoryLayer(id, .surface)
                }
                editMemory(id, safeText)
            }
            if metaChanged {
                setMemoryLayer(id, .archived, kind: resolvedKind, topic: cleanTopic)
            }
            return
        }

        if !memories.contains(where: { $0.id == id }) {
            setMemoryLayer(id, layer, kind: resolvedKind, topic: cleanTopic)
            if textChanged {
                editMemory(id, safeText)
            }
            return
        }

        if textChanged {
            editMemory(id, safeText)
        }
        if metaChanged {
            setMemoryLayer(id, layer, kind: resolvedKind, topic: cleanTopic)
        }
    }

    @discardableResult
    func importMemoryCandidates(
        _ items: [(text: String, layer: MemoryLayer, kind: String, topic: String)]
    ) -> Int {
        guard canMutateMemoryState, !items.isEmpty else { return 0 }
        let orderedSecrets = Vault.allStrings().filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        if keeping {
            ensureRetractedFlushHashesLoaded()
        }
        let suppressedHashes = memoryPromptState.suppressedFlushHashesSnapshot()
        var existingTexts = memories.map(\.text)
        if keeping {
            existingTexts.append(contentsOf: MemoryStoreBridge.shared.recordsSnapshot().map(\.text))
        }
        var seenKeys = Set(existingTexts.map(MemorySafety.normalizedFactKey).filter { !$0.isEmpty })

        let now = Now.ms
        var accepted: [(memory: Memory, layer: MemoryLayer, kind: String, topic: String)] = []
        for item in items {
            guard !MemoryImporter.looksLikeSecret(item.text, secrets: orderedSecrets),
                  let cleanText = MemorySafety.sanitizeProposedFact(item.text, secrets: orderedSecrets) else {
                continue
            }
            let key = MemorySafety.normalizedFactKey(cleanText)
            let hash = MemorySafety.retractionHash(cleanText)
            guard !key.isEmpty, !hash.isEmpty else { continue }
            guard !suppressedHashes.contains(hash) else { continue }
            if keeping, MemoryStoreBridge.shared.isSuppressedInShadow(text: cleanText) {
                continue
            }
            guard seenKeys.insert(key).inserted else { continue }

            let rawKind = item.kind.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanKind = rawKind.isEmpty ? "fact" : rawKind
            let cleanTopic = MemorySafety.redactSecrets(item.topic, secrets: orderedSecrets)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let deepFlag: Bool? = (item.layer == .deep) ? true : nil
            let memory = Memory(
                id: UUID().uuidString,
                text: cleanText,
                at: now,
                by: nil,
                deep: deepFlag,
                used: now,
                automatic: nil,
                editedByUser: true
            )
            accepted.append((memory: memory, layer: item.layer, kind: cleanKind, topic: cleanTopic))
        }

        guard !accepted.isEmpty else { return 0 }

        if !keeping {
            let activeMemories = accepted.filter { $0.layer != .archived }.map(\.memory)
            guard !activeMemories.isEmpty else { return 0 }
            var nextMemories = memories + activeMemories
            Self.settleMemory(&nextMemories, pinnedIDs: [])
            memories = nextMemories
            memoryBook.memories = nextMemories
            memoryPromptState.invalidate()
            syncLivePromptsFromMemories()
            return activeMemories.count
        }

        let activeEntries = accepted.filter { $0.layer != .archived }
        let archivedEntries = accepted.filter { $0.layer == .archived }
        var committedCount = 0

        if !activeEntries.isEmpty {
            let existingPins = MemoryStoreBridge.shared.pinnedIDsSnapshot()
            let newPinIDs = Set(activeEntries.filter { $0.layer == .pinned }.map(\.memory.id))
            var nextMemories = memories + activeEntries.map(\.memory)
            Self.settleMemory(&nextMemories, pinnedIDs: existingPins.union(newPinIDs))

            var nextBook = memoryBook
            nextBook.memories = nextMemories
            guard (try? commitMemoryBook(nextBook, mutation: .none)) != nil else {
                return 0
            }
            committedCount += activeEntries.count

            for entry in activeEntries {
                let currentLayer: MemoryLayer
                if entry.layer == .pinned {
                    currentLayer = .pinned
                } else if let committed = memories.first(where: { $0.id == entry.memory.id }) {
                    currentLayer = committed.deep == true ? .deep : .surface
                } else {
                    currentLayer = entry.layer
                }
                if currentLayer == .pinned || entry.kind != "fact" || !entry.topic.isEmpty {
                    setMemoryLayer(entry.memory.id, currentLayer, kind: entry.kind, topic: entry.topic)
                }
            }
        }

        for entry in archivedEntries {
            var nextBook = memoryBook
            nextBook.memories = memories
            if (try? commitMemoryBook(
                nextBook,
                mutation: .layerAndMetadata(
                    id: entry.memory.id,
                    layer: .archived,
                    kind: entry.kind,
                    topic: entry.topic,
                    confidence: nil,
                    fallbackMemory: entry.memory,
                    nowMs: now
                )
            )) != nil {
                committedCount += 1
            }
        }

        return committedCount
    }

    func archiveMemory(_ id: String) {
        setMemoryLayer(id, .archived)
    }

    @discardableResult
    func restoreMemory(_ id: String) -> Bool {
        guard canMutateMemoryState, keeping else { return false }
        let now = Now.ms
        guard var restored = MemoryStoreBridge.shared.restorableMemorySnapshot(id: id) else { return false }
        restored.deep = nil
        restored.used = now

        var nextMemories = memories
        nextMemories.removeAll { $0.id == id }
        nextMemories.append(restored)
        var candidatePins = MemoryStoreBridge.shared.pinnedIDsSnapshot()
        candidatePins.remove(id)
        Self.settleMemory(&nextMemories, pinnedIDs: candidatePins)

        var nextBook = memoryBook
        nextBook.memories = nextMemories
        guard (try? commitMemoryBook(
            nextBook,
            mutation: .restore(id: id, memory: restored, nowMs: now)
        )) != nil else {
            return false
        }
        return true
    }

    func forget(about words: String) -> [String] {
        guard canMutateMemoryState else { return [] }
        let needle = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        let gone = memories.filter { memory in
            memory.by != nil && memory.editedByUser != true && memory.text.localizedCaseInsensitiveContains(needle)
        }
        guard !gone.isEmpty else { return [] }

        let now = Now.ms
        let goneIds = Set(gone.map(\.id))
        var nextBook = memoryBook
        nextBook.memories.removeAll { goneIds.contains($0.id) }
        nextBook.reviews = Self.removingReviewDetails(from: nextBook.reviews, memoryIDs: goneIds)

        if !keeping {
            memories = nextBook.memories
            memoryBook = nextBook
            memoryReviews = nextBook.reviews
            for item in gone {
                memoryPromptState.retract(id: item.id, textForInFlightGuard: item.text)
            }
            syncLivePromptsFromMemories()
            return gone.map(\.text)
        }

        let deleteItems = gone.map { (id: $0.id, text: Optional($0.text)) }
        guard (try? commitMemoryBook(
            nextBook,
            mutation: .softDelete(items: deleteItems, reason: "agent_forget", nowMs: now)
        )) != nil else {
            return []
        }
        return gone.map(\.text)
    }

    /// Takes back one thing a companion wrote into 拾遗 (from its step in the trace).
    @discardableResult
    /// 撤回 under a turn: only what a companion wrote and you have not touched; your own entries are never taken.
    func unremember(_ id: String, fact: String) -> Bool {
        guard canMutateMemoryState,
              let memory = memories.first(where: { $0.id == id }),
              memory.text == fact, memory.by != nil, memory.editedByUser != true else { return false }
        return performDeleteMemory(id)
    }

    func deleteMemory(_ id: String) {
        _ = performDeleteMemory(id)
    }

    private func performDeleteMemory(_ id: String) -> Bool {
        guard canMutateMemoryState else { return false }
        let removed = memories.first { $0.id == id }
        let now = Now.ms
        var nextBook = memoryBook
        nextBook.memories.removeAll { $0.id == id }
        nextBook.reviews = Self.removingReviewDetails(from: nextBook.reviews, memoryIDs: [id])

        if !keeping {
            memories = nextBook.memories
            memoryBook = nextBook
            memoryReviews = nextBook.reviews
            memoryPromptState.retract(id: id, textForInFlightGuard: removed?.text)
            syncLivePromptsFromMemories()
            return true
        }

        guard (try? commitMemoryBook(
            nextBook,
            mutation: .softDelete(items: [(id: id, text: removed?.text)], reason: "user_delete", nowMs: now)
        )) != nil else {
            return false
        }
        return true
    }

    func removeReviewDetails(_ ids: Set<String>) {
        memoryBook.reviews = Self.removingReviewDetails(from: memoryBook.reviews, memoryIDs: ids)
        memoryReviews = memoryBook.reviews
    }

    private static func removingReviewDetails(from reviews: [MemoryReviewLog], memoryIDs ids: Set<String>) -> [MemoryReviewLog] {
        guard !ids.isEmpty else { return reviews }
        return reviews.map { log in
            var copy = log
            copy.added.removeAll { ids.contains($0.memoryID) }
            copy.merged.removeAll { ids.contains($0.memoryID) }
            return copy
        }
    }
}
