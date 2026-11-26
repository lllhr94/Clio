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

    private static var offMainMutationTails: [ObjectIdentifier: (id: UInt64, task: Task<Void, Never>)] = [:]
    private static var offMainMutationSeq: UInt64 = 0

    private func serializedMemoryMutation<T: Sendable>(
        _ work: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        let key = ObjectIdentifier(self)
        let previous = Self.offMainMutationTails[key]?.task
        Self.offMainMutationSeq &+= 1
        let mySeq = Self.offMainMutationSeq
        let myTask = Task<Result<T, Error>, Never> { @MainActor in
            await previous?.value
            do {
                return .success(try await work())
            } catch {
                return .failure(error)
            }
        }
        let anchor = Task<Void, Never> { @MainActor in
            _ = await myTask.value
            if Self.offMainMutationTails[key]?.id == mySeq {
                Self.offMainMutationTails.removeValue(forKey: key)
            }
        }
        Self.offMainMutationTails[key] = (mySeq, anchor)
        return try await myTask.value.get()
    }

    private func applyCommittedMemoryBook(_ committedBook: MemoryBook) {
        memoryBook = committedBook
        if memories != committedBook.memories {
            memories = committedBook.memories
        }
        memoryReviews = committedBook.reviews
        syncLivePromptsFromMemories()
    }

    @discardableResult
    private func commitMemoryBookPrepared(
        _ book: MemoryBook,
        mutation: MemoryCommitMutation = .none,
        orderedSecrets: [String]
    ) throws -> MemoryBook {
        guard keeping, !Disk.frozen else {
            throw TeamError(message: "刚恢复了备份，重新打开 Clio 后才能保存。")
        }
        guard !MemoryStoreBridge.shared.isCanonicalReadOnly else {
            throw TeamError(message: "记忆文件暂不可读，已跳过覆盖写入以防丢失原有记忆。")
        }
        ensureRetractedFlushHashesLoaded()
        let suppressed = memoryPromptState.suppressedFlushHashesSnapshot()
        let committed = try MemoryStoreBridge.shared.commitAppBook(
            book,
            mutation: mutation,
            suppressedHashes: suppressed,
            promptState: memoryPromptState,
            bots: bots,
            mainBotId: mainBotId,
            secrets: orderedSecrets
        )
        applyCommittedMemoryBook(committed.book)
        return committed.book
    }

    @discardableResult
    private func commitMemoryBookPreparedAsync(
        _ book: MemoryBook,
        mutation: MemoryCommitMutation = .none,
        orderedSecrets: [String]
    ) async throws -> MemoryBook {
        guard keeping, !Disk.frozen else {
            throw TeamError(message: "刚恢复了备份，重新打开 Clio 后才能保存。")
        }
        guard !MemoryStoreBridge.shared.isCanonicalReadOnly else {
            throw TeamError(message: "记忆文件暂不可读，已跳过覆盖写入以防丢失原有记忆。")
        }
        ensureRetractedFlushHashesLoaded()
        let suppressed = memoryPromptState.suppressedFlushHashesSnapshot()
        let committed = try await MemoryStoreBridge.shared.commitAppBookAsync(
            book,
            mutation: mutation,
            suppressedHashes: suppressed,
            promptState: memoryPromptState,
            bots: bots,
            mainBotId: mainBotId,
            secrets: orderedSecrets
        )
        applyCommittedMemoryBook(committed.book)
        return committed.book
    }

    private enum RememberPlan {
        case empty
        case local(nextMemories: [Memory], touchedID: String, safeFact: String, added: String?)
        case commit(book: MemoryBook, mutation: MemoryCommitMutation, added: String?)
    }

    private func buildRememberPlan(
        _ fact: String,
        by bot: String?,
        orderedSecrets: [String],
        pinnedIDs: Set<String>
    ) -> RememberPlan {
        let safeFact = MemorySafety.redactSecrets(fact, secrets: orderedSecrets)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safeFact.isEmpty else { return .empty }

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
            return .local(nextMemories: nextMemories, touchedID: touchedMemory.id, safeFact: safeFact, added: added)
        }

        Self.settleMemory(&nextMemories, pinnedIDs: pinnedIDs)
        var nextBook = memoryBook
        nextBook.memories = nextMemories
        return .commit(
            book: nextBook,
            mutation: .remember(memory: touchedMemory, explicitUserAction: bot == nil, nowMs: now),
            added: added
        )
    }

    @discardableResult
    func remember(_ fact: String, by bot: String?) -> String? {
        guard canMutateMemoryState else { return nil }
        let orderedSecrets = Vault.allStrings().filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        let pins = keeping ? MemoryStoreBridge.shared.pinnedIDsSnapshot() : []
        switch buildRememberPlan(fact, by: bot, orderedSecrets: orderedSecrets, pinnedIDs: pins) {
        case .empty:
            return nil
        case .local(let nextMemories, let touchedID, let safeFact, let added):
            memories = nextMemories
            memoryBook.memories = nextMemories
            if bot == nil {
                memoryPromptState.clearRetraction(id: touchedID, text: safeFact)
            } else {
                memoryPromptState.invalidate()
            }
            syncLivePromptsFromMemories()
            return added
        case .commit(let nextBook, let mutation, let added):
            guard let committed = try? commitMemoryBookPrepared(
                nextBook,
                mutation: mutation,
                orderedSecrets: orderedSecrets
            ) else {
                return nil
            }
            guard let added else { return nil }
            return committed.memories.contains(where: { $0.id == added }) ? added : nil
        }
    }

    @discardableResult
    func rememberOffMain(_ fact: String, by bot: String?) async throws -> String? {
        try await serializedMemoryMutation {
            guard self.canMutateMemoryState else { return nil }
            let keeping = self.keeping
            let prep = await Task.detached(priority: .userInitiated) { () -> (secrets: [String], pins: Set<String>) in
                let secrets = Vault.allStrings().filter { !$0.isEmpty }.sorted { $0.count > $1.count }
                let pins = keeping ? MemoryStoreBridge.shared.pinnedIDsSnapshot() : []
                return (secrets, pins)
            }.value
            guard self.canMutateMemoryState else { return nil }
            switch self.buildRememberPlan(fact, by: bot, orderedSecrets: prep.secrets, pinnedIDs: prep.pins) {
            case .empty:
                return nil
            case .local(let nextMemories, let touchedID, let safeFact, let added):
                self.memories = nextMemories
                self.memoryBook.memories = nextMemories
                if bot == nil {
                    self.memoryPromptState.clearRetraction(id: touchedID, text: safeFact)
                } else {
                    self.memoryPromptState.invalidate()
                }
                self.syncLivePromptsFromMemories()
                return added
            case .commit(let nextBook, let mutation, let added):
                let committed = try await self.commitMemoryBookPreparedAsync(
                    nextBook,
                    mutation: mutation,
                    orderedSecrets: prep.secrets
                )
                guard let added else { return nil }
                return committed.memories.contains(where: { $0.id == added }) ? added : nil
            }
        }
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

    private enum MemoryMutationPlan {
        case noOp(succeeded: Bool)
        case local(nextMemories: [Memory], nextReviews: [MemoryReviewLog]?, retract: (id: String, text: String?)?, clearRetract: (id: String, text: String)?)
        case commit(book: MemoryBook, mutation: MemoryCommitMutation)
    }

    private func executeLocalPlan(
        nextMemories: [Memory],
        nextReviews: [MemoryReviewLog]?,
        retract: (id: String, text: String?)?,
        clearRetract: (id: String, text: String)?
    ) {
        memories = nextMemories
        memoryBook.memories = nextMemories
        if let nextReviews {
            memoryBook.reviews = nextReviews
            memoryReviews = nextReviews
        }
        if let retract {
            memoryPromptState.retract(id: retract.id, textForInFlightGuard: retract.text)
        } else if let clearRetract {
            memoryPromptState.clearRetraction(id: clearRetract.id, text: clearRetract.text)
        } else {
            memoryPromptState.invalidate()
        }
        syncLivePromptsFromMemories()
    }

    private func buildSetLayerPlan(
        _ id: String,
        _ layer: MemoryLayer,
        kind: String?,
        topic: String?,
        confidence: Double?,
        archivedFallback: Memory?,
        hasBridgeRecord: Bool,
        pinnedIDs: Set<String>
    ) -> MemoryMutationPlan {
        let now = Now.ms
        if layer == .archived {
            if !keeping {
                var nextMemories = memories
                nextMemories.removeAll { $0.id == id }
                return .local(nextMemories: nextMemories, nextReviews: nil, retract: nil, clearRetract: nil)
            }
            let fallback = memories.first { $0.id == id }
            guard fallback != nil || hasBridgeRecord else { return .noOp(succeeded: false) }
            var nextMemories = memories
            nextMemories.removeAll { $0.id == id }
            var nextBook = memoryBook
            nextBook.memories = nextMemories
            return .commit(
                book: nextBook,
                mutation: .layerAndMetadata(
                    id: id,
                    layer: .archived,
                    kind: kind,
                    topic: topic,
                    confidence: confidence,
                    text: nil,
                    editedByUser: false,
                    fallbackMemory: fallback,
                    nowMs: now
                )
            )
        }

        var nextMemories = memories
        var fallbackMemory: Memory?
        if let index = nextMemories.firstIndex(where: { $0.id == id }) {
            nextMemories[index].deep = (layer == .deep) ? true : nil
            if layer == .pinned || layer == .surface {
                nextMemories[index].used = now
            }
        } else if keeping, var archived = archivedFallback {
            archived.deep = (layer == .deep) ? true : nil
            if layer == .pinned || layer == .surface {
                archived.used = now
            }
            nextMemories.removeAll { $0.id == id }
            nextMemories.append(archived)
            fallbackMemory = archived
        } else {
            return .noOp(succeeded: false)
        }

        if !keeping {
            if layer != .deep { Self.settleMemory(&nextMemories, pinnedIDs: []) }
            return .local(nextMemories: nextMemories, nextReviews: nil, retract: nil, clearRetract: nil)
        }

        if layer != .deep {
            var candidatePins = pinnedIDs
            if layer == .pinned {
                candidatePins.insert(id)
            } else {
                candidatePins.remove(id)
            }
            Self.settleMemory(&nextMemories, pinnedIDs: candidatePins)
        }
        var nextBook = memoryBook
        nextBook.memories = nextMemories
        return .commit(
            book: nextBook,
            mutation: .layerAndMetadata(
                id: id,
                layer: layer,
                kind: kind,
                topic: topic,
                confidence: confidence,
                text: nil,
                editedByUser: false,
                fallbackMemory: fallbackMemory,
                nowMs: now
            )
        )
    }

    func setMemoryLayer(_ id: String, _ layer: MemoryLayer, kind: String? = nil, topic: String? = nil, confidence: Double? = nil) {
        guard canMutateMemoryState else { return }
        let orderedSecrets = keeping ? Vault.allStrings().filter { !$0.isEmpty }.sorted { $0.count > $1.count } : []
        let hasRecord = (keeping && layer == .archived) ? MemoryStoreBridge.shared.hasRecordSnapshot(id: id) : false
        let archivedFallback = (keeping && layer != .archived && !memories.contains(where: { $0.id == id }))
            ? MemoryStoreBridge.shared.archivedMemorySnapshot(id: id)
            : nil
        let pins = (keeping && layer != .deep && layer != .archived) ? MemoryStoreBridge.shared.pinnedIDsSnapshot() : []
        switch buildSetLayerPlan(
            id,
            layer,
            kind: kind,
            topic: topic,
            confidence: confidence,
            archivedFallback: archivedFallback,
            hasBridgeRecord: hasRecord,
            pinnedIDs: pins
        ) {
        case .noOp:
            return
        case .local(let nextMemories, let nextReviews, let retract, let clearRetract):
            executeLocalPlan(nextMemories: nextMemories, nextReviews: nextReviews, retract: retract, clearRetract: clearRetract)
        case .commit(let nextBook, let mutation):
            _ = try? commitMemoryBookPrepared(nextBook, mutation: mutation, orderedSecrets: orderedSecrets)
        }
    }

    @discardableResult
    func setMemoryLayerOffMain(_ id: String, _ layer: MemoryLayer, kind: String? = nil, topic: String? = nil, confidence: Double? = nil) async throws -> Bool {
        try await setMemoryLayerCapturingPreviousOffMain(id, layer, kind: kind, topic: topic, confidence: confidence).succeeded
    }

    func archiveMemoryCapturingLayerOffMain(_ id: String) async throws -> (succeeded: Bool, previousLayer: MemoryLayer) {
        let outcome = try await setMemoryLayerCapturingPreviousOffMain(id, .archived)
        return (outcome.succeeded, outcome.previousLayer ?? .surface)
    }

    private func setMemoryLayerCapturingPreviousOffMain(
        _ id: String,
        _ layer: MemoryLayer,
        kind: String? = nil,
        topic: String? = nil,
        confidence: Double? = nil
    ) async throws -> (succeeded: Bool, previousLayer: MemoryLayer?) {
        try await serializedMemoryMutation {
            guard self.canMutateMemoryState else { return (false, nil) }
            let keeping = self.keeping
            let needsArchiveLookup = keeping && layer != .archived
            let needsHasRecord = keeping && layer == .archived
            let needsPins = keeping
            let prep = await Task.detached(priority: .userInitiated) { () -> (secrets: [String], archived: Memory?, hasRecord: Bool, pins: Set<String>, bridgeLayer: MemoryLayer?) in
                let secrets = keeping ? Vault.allStrings().filter { !$0.isEmpty }.sorted { $0.count > $1.count } : []
                let archived = needsArchiveLookup ? MemoryStoreBridge.shared.archivedMemorySnapshot(id: id) : nil
                let hasRecord = needsHasRecord ? MemoryStoreBridge.shared.hasRecordSnapshot(id: id) : false
                let pins = needsPins ? MemoryStoreBridge.shared.pinnedIDsSnapshot() : []
                let bridgeLayer = needsHasRecord
                    ? MemoryStoreBridge.shared.recordsSnapshot().first(where: { $0.id == id })?.layer
                    : nil
                return (secrets, archived, hasRecord, pins, bridgeLayer)
            }.value
            guard self.canMutateMemoryState else { return (false, nil) }
            let capturedLayer: MemoryLayer? = {
                guard layer == .archived else { return nil }
                if let bridgeLayer = prep.bridgeLayer, bridgeLayer != .archived {
                    return bridgeLayer
                }
                if let memory = self.memories.first(where: { $0.id == id }) {
                    if prep.pins.contains(id) { return .pinned }
                    return memory.deep == true ? .deep : .surface
                }
                return nil
            }()
            let fallbackForCurrentState = self.memories.contains(where: { $0.id == id }) ? nil : prep.archived
            switch self.buildSetLayerPlan(
                id,
                layer,
                kind: kind,
                topic: topic,
                confidence: confidence,
                archivedFallback: fallbackForCurrentState,
                hasBridgeRecord: prep.hasRecord,
                pinnedIDs: prep.pins
            ) {
            case .noOp(let succeeded):
                return (succeeded, capturedLayer)
            case .local(let nextMemories, let nextReviews, let retract, let clearRetract):
                self.executeLocalPlan(nextMemories: nextMemories, nextReviews: nextReviews, retract: retract, clearRetract: clearRetract)
                return (true, capturedLayer)
            case .commit(let nextBook, let mutation):
                _ = try await self.commitMemoryBookPreparedAsync(nextBook, mutation: mutation, orderedSecrets: prep.secrets)
                return (true, capturedLayer)
            }
        }
    }

    private func buildUpdateDetailPlan(
        id: String,
        text: String,
        layer: MemoryLayer,
        kind: String,
        topic: String,
        orderedSecrets: [String],
        currentRecord: MemoryRecord?,
        archivedFallback: Memory?,
        hasBridgeRecord: Bool,
        archivedDeleteText: String?,
        pinnedIDs: Set<String>
    ) -> MemoryMutationPlan {
        let safeText = MemorySafety.redactSecrets(text, secrets: orderedSecrets)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if safeText.isEmpty {
            return buildDeletePlan(id, archivedText: archivedDeleteText)
        }
        let cleanKind = kind.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedKind = cleanKind.isEmpty ? "fact" : cleanKind
        let cleanTopic = MemorySafety.redactSecrets(topic, secrets: orderedSecrets)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let textChanged = currentRecord?.text != safeText
        let metaChanged: Bool
        if keeping {
            metaChanged = currentRecord == nil
                || currentRecord?.layer != layer
                || currentRecord?.kind != resolvedKind
                || currentRecord?.topic != cleanTopic
        } else {
            metaChanged = currentRecord == nil || currentRecord?.layer != layer
        }
        guard textChanged || metaChanged else { return .noOp(succeeded: true) }

        let now = Now.ms
        if layer == .archived {
            if !keeping {
                var nextMemories = memories
                nextMemories.removeAll { $0.id == id }
                return .local(nextMemories: nextMemories, nextReviews: nil, retract: nil, clearRetract: nil)
            }
            let fallback = memories.first { $0.id == id }
            guard fallback != nil || hasBridgeRecord else { return .noOp(succeeded: false) }
            var nextMemories = memories
            nextMemories.removeAll { $0.id == id }
            var nextBook = memoryBook
            nextBook.memories = nextMemories
            return .commit(
                book: nextBook,
                mutation: .layerAndMetadata(
                    id: id,
                    layer: .archived,
                    kind: resolvedKind,
                    topic: cleanTopic,
                    confidence: nil,
                    text: textChanged ? safeText : nil,
                    editedByUser: textChanged,
                    fallbackMemory: fallback,
                    nowMs: now
                )
            )
        }

        var nextMemories = memories
        var fallbackMemory: Memory?
        if let index = nextMemories.firstIndex(where: { $0.id == id }) {
            if textChanged {
                nextMemories[index].text = safeText
                nextMemories[index].editedByUser = true
            }
            nextMemories[index].deep = (layer == .deep) ? true : nil
            if (layer == .pinned || layer == .surface) && currentRecord?.layer != layer {
                nextMemories[index].used = now
            }
        } else if keeping, var archived = archivedFallback {
            if textChanged {
                archived.text = safeText
                archived.editedByUser = true
            }
            archived.deep = (layer == .deep) ? true : nil
            if layer == .pinned || layer == .surface {
                archived.used = now
            }
            nextMemories.removeAll { $0.id == id }
            nextMemories.append(archived)
            fallbackMemory = archived
        } else {
            return .noOp(succeeded: false)
        }

        if !keeping {
            if layer != .deep { Self.settleMemory(&nextMemories, pinnedIDs: []) }
            return .local(
                nextMemories: nextMemories,
                nextReviews: nil,
                retract: nil,
                clearRetract: textChanged ? (id: id, text: safeText) : nil
            )
        }

        if layer != .deep {
            var candidatePins = pinnedIDs
            if layer == .pinned {
                candidatePins.insert(id)
            } else {
                candidatePins.remove(id)
            }
            Self.settleMemory(&nextMemories, pinnedIDs: candidatePins)
        }
        var nextBook = memoryBook
        nextBook.memories = nextMemories
        return .commit(
            book: nextBook,
            mutation: .layerAndMetadata(
                id: id,
                layer: layer,
                kind: resolvedKind,
                topic: cleanTopic,
                confidence: nil,
                text: textChanged ? safeText : nil,
                editedByUser: textChanged,
                fallbackMemory: fallbackMemory,
                nowMs: now
            )
        )
    }

    func updateMemoryDetail(id: String, text: String, layer: MemoryLayer, kind: String, topic: String) {
        guard canMutateMemoryState else { return }
        let orderedSecrets = Vault.allStrings().filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        let currentRecord = memoryRecord(id: id)
        let hasRecord = (keeping && layer == .archived) ? MemoryStoreBridge.shared.hasRecordSnapshot(id: id) : false
        let archivedFallback = (keeping && layer != .archived && !memories.contains(where: { $0.id == id }))
            ? MemoryStoreBridge.shared.archivedMemorySnapshot(id: id)
            : nil
        let archivedDeleteText = (keeping && !memories.contains(where: { $0.id == id }))
            ? MemoryStoreBridge.shared.recordsSnapshot(layer: .archived).first(where: { $0.id == id })?.text
            : nil
        let pins = (keeping && layer != .deep && layer != .archived) ? MemoryStoreBridge.shared.pinnedIDsSnapshot() : []
        switch buildUpdateDetailPlan(
            id: id,
            text: text,
            layer: layer,
            kind: kind,
            topic: topic,
            orderedSecrets: orderedSecrets,
            currentRecord: currentRecord,
            archivedFallback: archivedFallback,
            hasBridgeRecord: hasRecord,
            archivedDeleteText: archivedDeleteText,
            pinnedIDs: pins
        ) {
        case .noOp:
            return
        case .local(let nextMemories, let nextReviews, let retract, let clearRetract):
            executeLocalPlan(nextMemories: nextMemories, nextReviews: nextReviews, retract: retract, clearRetract: clearRetract)
        case .commit(let nextBook, let mutation):
            _ = try? commitMemoryBookPrepared(nextBook, mutation: mutation, orderedSecrets: orderedSecrets)
        }
    }

    @discardableResult
    func updateMemoryDetailOffMain(id: String, text: String, layer: MemoryLayer, kind: String, topic: String) async throws -> Bool {
        try await serializedMemoryMutation {
            guard self.canMutateMemoryState else { return false }
            let keeping = self.keeping
            let needsArchiveLookup = keeping && layer != .archived
            let prep = await Task.detached(priority: .userInitiated) { () -> (
                secrets: [String],
                bridgeRecord: MemoryRecord?,
                archivedFallback: Memory?,
                hasRecord: Bool,
                pins: Set<String>
            ) in
                let secrets = Vault.allStrings().filter { !$0.isEmpty }.sorted { $0.count > $1.count }
                guard keeping else { return (secrets, nil, nil, false, []) }
                let allRecords = MemoryStoreBridge.shared.recordsSnapshot()
                let bridgeRecord = allRecords.first(where: { $0.id == id })
                let archivedFallback = needsArchiveLookup ? MemoryStoreBridge.shared.archivedMemorySnapshot(id: id) : nil
                let hasRecord = bridgeRecord != nil
                let pins = MemoryStoreBridge.shared.pinnedIDsSnapshot()
                return (secrets, bridgeRecord, archivedFallback, hasRecord, pins)
            }.value
            guard self.canMutateMemoryState else { return false }
            let currentRecord: MemoryRecord? = {
                if keeping, let found = prep.bridgeRecord { return found }
                if let mem = self.memories.first(where: { $0.id == id }) {
                    let isPinned = keeping && prep.pins.contains(mem.id)
                    let resolvedLayer: MemoryLayer = isPinned ? .pinned : (mem.deep == true ? .deep : .surface)
                    return MemoryRecord(
                        id: mem.id,
                        text: mem.text,
                        layer: resolvedLayer,
                        pinned: isPinned,
                        createdAtMs: mem.at,
                        usedAtMs: mem.used,
                        byBot: mem.by,
                        automatic: mem.automatic == true,
                        editedByUser: mem.editedByUser == true
                    )
                }
                return nil
            }()
            let fallbackForCurrentState = self.memories.contains(where: { $0.id == id }) ? nil : prep.archivedFallback
            let archivedDeleteText = (keeping && prep.bridgeRecord?.layer == .archived) ? prep.bridgeRecord?.text : nil
            switch self.buildUpdateDetailPlan(
                id: id,
                text: text,
                layer: layer,
                kind: kind,
                topic: topic,
                orderedSecrets: prep.secrets,
                currentRecord: currentRecord,
                archivedFallback: fallbackForCurrentState,
                hasBridgeRecord: prep.hasRecord,
                archivedDeleteText: archivedDeleteText,
                pinnedIDs: prep.pins
            ) {
            case .noOp(let succeeded):
                return succeeded
            case .local(let nextMemories, let nextReviews, let retract, let clearRetract):
                self.executeLocalPlan(nextMemories: nextMemories, nextReviews: nextReviews, retract: retract, clearRetract: clearRetract)
                return true
            case .commit(let nextBook, let mutation):
                _ = try await self.commitMemoryBookPreparedAsync(nextBook, mutation: mutation, orderedSecrets: prep.secrets)
                return true
            }
        }
    }

    private enum ImportPlan {
        case empty
        case local(nextMemories: [Memory], count: Int)
        case commit(book: MemoryBook, mutation: MemoryCommitMutation, candidateIDs: [String])
    }

    private func buildImportPlan(
        _ items: [(text: String, layer: MemoryLayer, kind: String, topic: String)],
        orderedSecrets: [String],
        bridgeExistingTexts: [String],
        pinnedIDs: Set<String>,
        isSuppressed: (String) -> Bool
    ) -> ImportPlan {
        guard !items.isEmpty else { return .empty }
        if keeping {
            ensureRetractedFlushHashesLoaded()
        }
        let suppressedHashes = memoryPromptState.suppressedFlushHashesSnapshot()
        var existingTexts = memories.map(\.text)
        if keeping {
            existingTexts.append(contentsOf: bridgeExistingTexts)
        }
        var seenKeys = Set(existingTexts.map(MemorySafety.normalizedFactKey).filter { !$0.isEmpty })

        let now = Now.ms
        var accepted: [(memory: Memory, layer: MemoryLayer, kind: String, topic: String)] = []
        for item in items {
            guard !MemoryImporter.looksLikeSecret(item.text, secrets: orderedSecrets),
                  !MemoryImporter.looksLikeSecret(item.kind, secrets: orderedSecrets),
                  !MemoryImporter.looksLikeSecret(item.topic, secrets: orderedSecrets),
                  let cleanText = MemorySafety.sanitizeProposedFact(item.text, secrets: orderedSecrets) else {
                continue
            }
            let rawKind = item.kind.trimmingCharacters(in: .whitespacesAndNewlines)
            let redactedKind = MemorySafety.redactSecrets(rawKind, secrets: orderedSecrets)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard redactedKind == rawKind, !redactedKind.contains("〔隐去〕") else { continue }
            let cleanKind = redactedKind.isEmpty ? "fact" : redactedKind

            let rawTopic = item.topic.trimmingCharacters(in: .whitespacesAndNewlines)
            let redactedTopic = MemorySafety.redactSecrets(rawTopic, secrets: orderedSecrets)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard redactedTopic == rawTopic, !redactedTopic.contains("〔隐去〕") else { continue }

            let key = MemorySafety.normalizedFactKey(cleanText)
            let hash = MemorySafety.retractionHash(cleanText)
            guard !key.isEmpty, !hash.isEmpty else { continue }
            guard !suppressedHashes.contains(hash) else { continue }
            if keeping, isSuppressed(cleanText) {
                continue
            }
            guard seenKeys.insert(key).inserted else { continue }

            let targetLayer: MemoryLayer
            if !keeping && item.layer == .pinned {
                targetLayer = .surface
            } else {
                targetLayer = item.layer
            }

            let deepFlag: Bool? = (targetLayer == .deep) ? true : nil
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
            accepted.append((memory: memory, layer: targetLayer, kind: cleanKind, topic: redactedTopic))
        }

        guard !accepted.isEmpty else { return .empty }

        if !keeping {
            let activeMemories = accepted.filter { $0.layer != .archived }.map(\.memory)
            guard !activeMemories.isEmpty else { return .empty }
            var nextMemories = memories + activeMemories
            Self.settleMemory(&nextMemories, pinnedIDs: [])
            return .local(nextMemories: nextMemories, count: activeMemories.count)
        }

        let activeEntries = accepted.filter { $0.layer != .archived }
        let newPinIDs = Set(activeEntries.filter { $0.layer == .pinned }.map(\.memory.id))
        var nextMemories = memories + activeEntries.map(\.memory)
        Self.settleMemory(&nextMemories, pinnedIDs: pinnedIDs.union(newPinIDs))

        let batchEntries: [MemoryImportBatchEntry] = accepted.map { entry in
            let finalLayer: MemoryLayer
            if entry.layer == .surface,
               let settled = nextMemories.first(where: { $0.id == entry.memory.id }),
               settled.deep == true {
                finalLayer = .deep
            } else {
                finalLayer = entry.layer
            }
            return MemoryImportBatchEntry(
                memory: entry.memory,
                layer: finalLayer,
                kind: entry.kind,
                topic: entry.topic
            )
        }

        var nextBook = memoryBook
        nextBook.memories = nextMemories
        return .commit(
            book: nextBook,
            mutation: .importBatch(items: batchEntries, nowMs: now),
            candidateIDs: accepted.map(\.memory.id)
        )
    }

    @discardableResult
    func importMemoryCandidates(
        _ items: [(text: String, layer: MemoryLayer, kind: String, topic: String)]
    ) -> Int {
        guard canMutateMemoryState, !items.isEmpty else { return 0 }
        let orderedSecrets = Vault.allStrings().filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        let bridgeExisting = keeping ? MemoryStoreBridge.shared.recordsSnapshot().map(\.text) : []
        let pins = keeping ? MemoryStoreBridge.shared.pinnedIDsSnapshot() : []
        switch buildImportPlan(
            items,
            orderedSecrets: orderedSecrets,
            bridgeExistingTexts: bridgeExisting,
            pinnedIDs: pins,
            isSuppressed: { MemoryStoreBridge.shared.isSuppressedInShadow(text: $0) }
        ) {
        case .empty:
            return 0
        case .local(let nextMemories, let count):
            executeLocalPlan(nextMemories: nextMemories, nextReviews: nil, retract: nil, clearRetract: nil)
            return count
        case .commit(let nextBook, let mutation, let candidateIDs):
            guard let committed = try? commitMemoryBookPrepared(
                nextBook,
                mutation: mutation,
                orderedSecrets: orderedSecrets
            ) else {
                return 0
            }
            var committedIDs = Set(committed.memories.map(\.id))
            committedIDs.formUnion(MemoryStoreBridge.shared.recordsSnapshot(layer: .archived).map(\.id))
            return candidateIDs.reduce(0) { $0 + (committedIDs.contains($1) ? 1 : 0) }
        }
    }

    @discardableResult
    func importMemoryCandidatesOffMain(
        _ items: [(text: String, layer: MemoryLayer, kind: String, topic: String)]
    ) async throws -> Int {
        try await serializedMemoryMutation {
            guard self.canMutateMemoryState, !items.isEmpty else { return 0 }
            let keeping = self.keeping
            let prep = await Task.detached(priority: .userInitiated) { () -> (
                secrets: [String],
                bridgeTexts: [String],
                pins: Set<String>,
                suppressedCheck: @Sendable (String) -> Bool
            ) in
                let secrets = Vault.allStrings().filter { !$0.isEmpty }.sorted { $0.count > $1.count }
                let bridgeTexts = keeping ? MemoryStoreBridge.shared.recordsSnapshot().map(\.text) : []
                let pins = keeping ? MemoryStoreBridge.shared.pinnedIDsSnapshot() : []
                return (secrets, bridgeTexts, pins, { MemoryStoreBridge.shared.isSuppressedInShadow(text: $0) })
            }.value
            guard self.canMutateMemoryState else { return 0 }
            switch self.buildImportPlan(
                items,
                orderedSecrets: prep.secrets,
                bridgeExistingTexts: prep.bridgeTexts,
                pinnedIDs: prep.pins,
                isSuppressed: prep.suppressedCheck
            ) {
            case .empty:
                return 0
            case .local(let nextMemories, let count):
                self.executeLocalPlan(nextMemories: nextMemories, nextReviews: nil, retract: nil, clearRetract: nil)
                return count
            case .commit(let nextBook, let mutation, let candidateIDs):
                let committed = try await self.commitMemoryBookPreparedAsync(
                    nextBook,
                    mutation: mutation,
                    orderedSecrets: prep.secrets
                )
                let archivedIDs = await Task.detached(priority: .userInitiated) {
                    MemoryStoreBridge.shared.recordsSnapshot(layer: .archived).map(\.id)
                }.value
                var committedIDs = Set(committed.memories.map(\.id))
                committedIDs.formUnion(archivedIDs)
                return candidateIDs.reduce(0) { $0 + (committedIDs.contains($1) ? 1 : 0) }
            }
        }
    }

    func archiveMemory(_ id: String) {
        setMemoryLayer(id, .archived)
    }

    private func buildRestorePlan(
        _ id: String,
        restored initial: Memory,
        toLayer targetLayer: MemoryLayer = .surface,
        pinnedIDs: Set<String>
    ) -> (book: MemoryBook, mutation: MemoryCommitMutation) {
        let resolvedLayer = targetLayer == .archived ? .surface : targetLayer
        let now = Now.ms
        var restored = initial
        restored.deep = (resolvedLayer == .deep) ? true : nil
        restored.used = now

        var nextMemories = memories
        nextMemories.removeAll { $0.id == id }
        nextMemories.append(restored)
        var candidatePins = pinnedIDs
        if resolvedLayer == .pinned {
            candidatePins.insert(id)
        } else {
            candidatePins.remove(id)
        }
        Self.settleMemory(&nextMemories, pinnedIDs: candidatePins)

        var nextBook = memoryBook
        nextBook.memories = nextMemories
        return (nextBook, .restore(id: id, memory: restored, layer: resolvedLayer, nowMs: now))
    }

    @discardableResult
    func restoreMemory(_ id: String, toLayer targetLayer: MemoryLayer = .surface) -> Bool {
        guard canMutateMemoryState, keeping else { return false }
        let orderedSecrets = Vault.allStrings().filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        guard let restored = MemoryStoreBridge.shared.restorableMemorySnapshot(id: id) else { return false }
        let pins = MemoryStoreBridge.shared.pinnedIDsSnapshot()
        let plan = buildRestorePlan(id, restored: restored, toLayer: targetLayer, pinnedIDs: pins)
        return (try? commitMemoryBookPrepared(
            plan.book,
            mutation: plan.mutation,
            orderedSecrets: orderedSecrets
        )) != nil
    }

    @discardableResult
    func restoreMemoryOffMain(_ id: String, toLayer targetLayer: MemoryLayer = .surface) async throws -> Bool {
        try await serializedMemoryMutation {
            guard self.canMutateMemoryState, self.keeping else { return false }
            let prep = await Task.detached(priority: .userInitiated) { () -> (secrets: [String], restored: Memory?, pins: Set<String>) in
                let secrets = Vault.allStrings().filter { !$0.isEmpty }.sorted { $0.count > $1.count }
                let restored = MemoryStoreBridge.shared.restorableMemorySnapshot(id: id)
                let pins = MemoryStoreBridge.shared.pinnedIDsSnapshot()
                return (secrets, restored, pins)
            }.value
            guard self.canMutateMemoryState, self.keeping, let restored = prep.restored else { return false }
            let plan = self.buildRestorePlan(id, restored: restored, toLayer: targetLayer, pinnedIDs: prep.pins)
            _ = try await self.commitMemoryBookPreparedAsync(
                plan.book,
                mutation: plan.mutation,
                orderedSecrets: prep.secrets
            )
            return true
        }
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
        let orderedSecrets = keeping ? Vault.allStrings().filter { !$0.isEmpty }.sorted { $0.count > $1.count } : []
        return performDeleteMemory(id, orderedSecrets: orderedSecrets, archivedText: nil)
    }

    private func buildDeletePlan(_ id: String, archivedText: String?) -> MemoryMutationPlan {
        let removedText = memories.first(where: { $0.id == id })?.text ?? (keeping ? archivedText : nil)
        let now = Now.ms
        var nextBook = memoryBook
        nextBook.memories.removeAll { $0.id == id }
        nextBook.reviews = Self.removingReviewDetails(from: nextBook.reviews, memoryIDs: [id])

        if !keeping {
            return .local(
                nextMemories: nextBook.memories,
                nextReviews: nextBook.reviews,
                retract: (id: id, text: removedText),
                clearRetract: nil
            )
        }

        return .commit(
            book: nextBook,
            mutation: .softDelete(items: [(id: id, text: removedText)], reason: "user_delete", nowMs: now)
        )
    }

    private func performDeleteMemory(_ id: String, orderedSecrets: [String], archivedText: String?) -> Bool {
        guard canMutateMemoryState else { return false }
        switch buildDeletePlan(id, archivedText: archivedText) {
        case .noOp(let succeeded):
            return succeeded
        case .local(let nextMemories, let nextReviews, let retract, let clearRetract):
            executeLocalPlan(nextMemories: nextMemories, nextReviews: nextReviews, retract: retract, clearRetract: clearRetract)
            return true
        case .commit(let nextBook, let mutation):
            return (try? commitMemoryBookPrepared(
                nextBook,
                mutation: mutation,
                orderedSecrets: orderedSecrets
            )) != nil
        }
    }

    func deleteMemory(_ id: String) {
        guard canMutateMemoryState else { return }
        let orderedSecrets = keeping ? Vault.allStrings().filter { !$0.isEmpty }.sorted { $0.count > $1.count } : []
        let archivedText = (keeping && !memories.contains(where: { $0.id == id }))
            ? MemoryStoreBridge.shared.recordsSnapshot(layer: .archived).first(where: { $0.id == id })?.text
            : nil
        _ = performDeleteMemory(id, orderedSecrets: orderedSecrets, archivedText: archivedText)
    }

    @discardableResult
    func deleteMemoryOffMain(_ id: String) async throws -> Bool {
        try await serializedMemoryMutation {
            guard self.canMutateMemoryState else { return false }
            let keeping = self.keeping
            let needsArchivedText = keeping && !self.memories.contains(where: { $0.id == id })
            let prep = await Task.detached(priority: .userInitiated) { () -> (secrets: [String], archivedText: String?) in
                guard keeping else { return ([], nil) }
                let secrets = Vault.allStrings().filter { !$0.isEmpty }.sorted { $0.count > $1.count }
                let archivedText = needsArchivedText
                    ? MemoryStoreBridge.shared.recordsSnapshot(layer: .archived).first(where: { $0.id == id })?.text
                    : nil
                return (secrets, archivedText)
            }.value
            guard self.canMutateMemoryState else { return false }
            switch self.buildDeletePlan(id, archivedText: prep.archivedText) {
            case .noOp(let succeeded):
                return succeeded
            case .local(let nextMemories, let nextReviews, let retract, let clearRetract):
                self.executeLocalPlan(nextMemories: nextMemories, nextReviews: nextReviews, retract: retract, clearRetract: clearRetract)
                return true
            case .commit(let nextBook, let mutation):
                _ = try await self.commitMemoryBookPreparedAsync(
                    nextBook,
                    mutation: mutation,
                    orderedSecrets: prep.secrets
                )
                return true
            }
        }
    }

    private static let nightlyPromotionDayKey = "memory.nightlyPromotion.lastDay"

    /// Evaluates `.pinned`, `.surface`, and `.deep` memory lifecycles once per tide day after nightly review,
    /// promoting frequently/recently recalled `.deep` entries to `.surface` and demoting/archiving stale unpinned ones
    /// strictly through throwing `commitMemoryBook` transactions (never marking the day complete on commit failure).
    func applyNightlyPromotionIfNeeded(now: Date = Date(), force: Bool = false) {
        guard phase == .ready, keeping, canMutateMemoryState, !Disk.frozen, !Task.isCancelled else { return }
        guard Grant.memory.policy == .allow else { return }

        let day = Tide.day(of: now)
        if !force, UserDefaults.standard.string(forKey: Self.nightlyPromotionDayKey) == day {
            return
        }

        let records = MemoryStoreBridge.shared.recordsSnapshot()
        guard !records.isEmpty else {
            UserDefaults.standard.set(day, forKey: Self.nightlyPromotionDayKey)
            return
        }

        ensureRetractedFlushHashesLoaded()
        let usageStats = MemoryRecallBridge.shared.usageStatsSnapshot()
        let suppressed = memoryPromptState.suppressedFlushHashesSnapshot()
        let nowMs = now.timeIntervalSince1970 * 1000
        let plan = MemoryPromotionPolicy.evaluate(
            records: records,
            usageStats: usageStats,
            suppressedHashes: suppressed,
            nowMs: nowMs,
            config: MemoryPromotionPolicy.Config(surfaceLimit: Self.surfaceLimit)
        )

        let pinnedIDs = MemoryStoreBridge.shared.pinnedIDsSnapshot()
        let recordsByID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let isImmune: (String) -> Bool = { id in
            pinnedIDs.contains(id)
                || recordsByID[id]?.pinned == true
                || recordsByID[id]?.layer == .pinned
                || recordsByID[id]?.deletedAtMs != nil
        }

        let promoteSet = Set(plan.promoteToSurface.filter { recordsByID[$0]?.deletedAtMs == nil })
        let demoteSet = Set(plan.demoteToDeep.filter { !isImmune($0) })
        let safeArchiveIDs = plan.archiveIDs.filter { id in
            !isImmune(id) && (memories.contains(where: { $0.id == id }) || MemoryStoreBridge.shared.hasRecordSnapshot(id: id))
        }

        var nextMemories = memories
        var mutated = false

        for index in nextMemories.indices {
            let id = nextMemories[index].id
            guard recordsByID[id]?.deletedAtMs == nil else { continue }
            if let refreshedUsed = plan.refreshedUsedAtMs[id],
               refreshedUsed > (nextMemories[index].used ?? 0) {
                nextMemories[index].used = refreshedUsed
                mutated = true
            }
            if promoteSet.contains(id) {
                if nextMemories[index].deep == true {
                    nextMemories[index].deep = nil
                    mutated = true
                }
                let bumpedUsed = max(nextMemories[index].used ?? 0, plan.refreshedUsedAtMs[id] ?? nowMs)
                if (nextMemories[index].used ?? 0) < bumpedUsed {
                    nextMemories[index].used = bumpedUsed
                    mutated = true
                }
            } else if demoteSet.contains(id), !isImmune(id) {
                if nextMemories[index].deep != true {
                    nextMemories[index].deep = true
                    mutated = true
                }
            }
        }

        if !promoteSet.isEmpty || !demoteSet.isEmpty {
            Self.settleMemory(&nextMemories, pinnedIDs: pinnedIDs)
        }

        do {
            if let firstArchiveID = safeArchiveIDs.first {
                let firstFallback = nextMemories.first { $0.id == firstArchiveID }
                nextMemories.removeAll { $0.id == firstArchiveID }
                var nextBook = memoryBook
                nextBook.memories = nextMemories
                _ = try commitMemoryBook(
                    nextBook,
                    mutation: .layerAndMetadata(
                        id: firstArchiveID,
                        layer: .archived,
                        kind: nil,
                        topic: nil,
                        confidence: nil,
                        text: nil,
                        editedByUser: false,
                        fallbackMemory: firstFallback,
                        nowMs: nowMs
                    )
                )
            } else if mutated {
                var nextBook = memoryBook
                nextBook.memories = nextMemories
                _ = try commitMemoryBook(nextBook)
            }

            for archiveID in safeArchiveIDs.dropFirst() {
                guard canMutateMemoryState, !Disk.frozen, !Task.isCancelled else { return }
                guard !isImmune(archiveID), !isPinnedMemory(archiveID) else { continue }
                let fallback = memories.first { $0.id == archiveID }
                guard fallback != nil || MemoryStoreBridge.shared.hasRecordSnapshot(id: archiveID) else { continue }
                var nextArchiveMemories = memories
                nextArchiveMemories.removeAll { $0.id == archiveID }
                var archiveBook = memoryBook
                archiveBook.memories = nextArchiveMemories
                _ = try commitMemoryBook(
                    archiveBook,
                    mutation: .layerAndMetadata(
                        id: archiveID,
                        layer: .archived,
                        kind: nil,
                        topic: nil,
                        confidence: nil,
                        text: nil,
                        editedByUser: false,
                        fallbackMemory: fallback,
                        nowMs: nowMs
                    )
                )
            }

            UserDefaults.standard.set(day, forKey: Self.nightlyPromotionDayKey)
            MemoryRecallBridge.shared.scheduleSync()
        } catch {
            // Do not stamp `nightlyPromotionDayKey` when persistence fails so the next eligible check retries.
            return
        }
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
