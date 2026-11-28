import AgentKit
import Craft
import Foundation
import SwiftUI
import UIKit

extension TeamModel {
    /// Returns the non-reusable conversation identity for the current active conversation in slot `key`,
    /// lazily allocating and persisting one on first use.
    func activeConversationID(for key: String) -> String {
        let current = options(key)
        if let existing = current.conversationID, !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString.lowercased()
        var updated = current
        updated.conversationID = fresh
        setOptions(key, updated)
        return fresh
    }

    /// Locates where `conversationID` currently resides (the active slot, a shelved leaf, ambiguous legacy slot, or gone).
    func resolveConversationTarget(
        slotKey: String,
        conversationID: String?,
        threadCreatedAtMs: Double? = nil
    ) -> ConversationTarget {
        if let conversationID, !conversationID.isEmpty {
            if options(slotKey).conversationID == conversationID {
                return .active(slotKey)
            }
            if let found = leaves(slotKey).first(where: { $0.conversationID == conversationID }) {
                return .leaf(chatKey: slotKey, leaf: found)
            }
            return .gone
        }
        // Legacy record with `nil` conversationID: if a non-fold leaf was shelved after the thread was created,
        // we cannot prove the active slot still belongs to the original conversation.
        if let createdAtMs = threadCreatedAtMs,
           leaves(slotKey).contains(where: { $0.marker == nil && $0.at >= createdAtMs }) {
            return .ambiguous
        }
        return .active(slotKey)
    }

    /// Idempotently appends an entry directly into a shelved leaf file on disk and confirms write success,
    /// without touching or tainting the newer active conversation occupying `chatKey`.
    func appendToShelvedLeaf(_ entry: Entry, chatKey: String, leaf: Leaf) -> Bool {
        let leafThreadKey = Self.threadKey(chatKey, leaf: leaf.id)
        let list: [Entry]
        if keeping {
            switch Disk.loadChatChecked(leafThreadKey) {
            case .missing:
                list = []
            case .loaded(let existing):
                list = existing
            case .corrupt(let recovered, let quarantined, _):
                guard quarantined else { return false }
                list = recovered
            case .unreadable:
                return false
            }
        } else {
            list = entries[leafThreadKey] ?? []
        }

        if list.contains(where: { $0.id == entry.id }) {
            return true
        }
        var updated = list
        updated.append(entry)
        if keeping {
            do {
                try Disk.write(updated, Self.leafFile(chatKey, leaf.id))
            } catch {
                return false
            }
            var currentLeaves = leaves(chatKey)
            if let idx = currentLeaves.firstIndex(where: { $0.id == leaf.id }) {
                currentLeaves[idx].at = max(currentLeaves[idx].at, entry.at)
                _ = writeEditedLeaves(chatKey, currentLeaves)
                leafBook[chatKey] = currentLeaves
            }
            scheduleIndexSync(chatKey, leafID: leaf.id, leafTitle: leaf.title, entries: updated)
        } else {
            entries[leafThreadKey] = updated
        }
        return true
    }

    func leaves(_ key: String) -> [Leaf] {
        if let kept = leafBook[key] { return kept }
        let loaded = keeping ? (Disk.load([Leaf].self, Self.leafList(key)) ?? []) : []
        leafBook[key] = loaded
        return loaded
    }

    nonisolated static func leafList(_ key: String) -> String { "chats/\(key)~leaves.json" }
    nonisolated static func leafFile(_ key: String, _ id: String) -> String { Disk.chatFile(threadKey(key, leaf: id)) }

    func entries(in leaf: Leaf, of key: String) -> [Entry] {
        Disk.load([Entry].self, Self.leafFile(key, leaf.id)) ?? []
    }
    static func leafSummary(_ key: String, _ id: String) -> String { "chats/\(key)~\(id)~summary.json" }

    func setLeaves(_ key: String, _ list: [Leaf]) {
        objectWillChange.send()
        leafBook[key] = list
        if keeping { Disk.save(list, Self.leafList(key)) }
    }

    @discardableResult
    func renameLeaf(_ key: String, id: String, to title: String) -> Bool {
        guard canAcceptInput(for: key) else { return false }
        var list = leaves(key)
        guard let index = list.firstIndex(where: { $0.id == id && $0.marker == nil }) else { return false }
        let title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard list[index].title != title else { return true }
        list[index].title = title
        let saved = writeEditedLeaves(key, list)
        if saved { scheduleIndexUpdateLeafTitle(key, leafID: id, title: title) }
        return saved
    }

    @discardableResult
    func deleteLeaf(_ key: String, id: String) -> Bool {
        guard canAcceptInput(for: key) else { return false }
        let list = leaves(key)
        guard list.contains(where: { $0.id == id && $0.marker == nil }),
              writeEditedLeaves(key, list.filter { $0.id != id }) else { return false }
        let leafKey = Self.threadKey(key, leaf: id)
        forgetThreads(leafKey)
        clearQueuedSlot(leafKey)
        if keeping {
            Disk.remove(Self.leafFile(key, id))
            Disk.remove(Self.leafSummary(key, id))
        }
        scheduleIndexDeleteChat(key, includingLeaves: false, leafID: id)
        Task { await ArtifactIndex.shared.markChatDirty(leafKey) }
        return true
    }

    func writeEditedLeaves(_ key: String, _ list: [Leaf]) -> Bool {
        do {
            if keeping { try Disk.write(list, Self.leafList(key)) }
        } catch {
            Diag.note("没存进手机：\(Self.leafList(key))（\(error.localizedDescription)）")
            return false
        }
        objectWillChange.send()
        leafBook[key] = list
        return true
    }

    /// The newest compression line, which can be taken out again (the 前情提要 goes back to what it was before).
    func undoableLine(_ key: String) -> Entry? { history(key).last { $0.fold == true } }

    /// Takes the newest compression line out: the model reads those lines word for word again.
    func unfoldLine(_ key: String) {
        guard canAcceptInput(for: key), let line = undoableLine(key) else { return }
        let rest = history(key).filter { $0.id != line.id }
        entries[key] = rest
        if keeping {
            ChatDisk.save(rest, chat: key)
            setSummary(key, record: Disk.load(MemorySafety.SummaryRecord.self, Self.foldSummary(key, line.id)))
            Disk.remove(Self.foldSummary(key, line.id))
        } else {
            setSummary(key, nil)
        }
        scheduleIndexSync(key, entries: rest)
        if !allPersistableQueued(key).isEmpty { persistQueued(key) }
        notify(key, .changed)
    }

    /// The newest leaf made by compressing (the old way, which took the text out), while its note is still in the conversation.
    func undoableFold(_ key: String) -> Leaf? {
        guard let leaf = leaves(key).first(where: { $0.marker != nil }), let marker = leaf.marker,
              history(key).contains(where: { $0.id == marker }) else { return nil }
        return leaf
    }

    /// Undoes a compression: the full text comes back, with everything said since; the summary goes back to what it was before.
    func unfold(_ key: String, _ leaf: Leaf) {
        guard keeping, canAcceptInput(for: key), let marker = leaf.marker, let original = Disk.load([Entry].self, Self.leafFile(key, leaf.id)) else { return }
        stop(key)
        let restored = Turns.unfolded(original: original, current: history(key), marker: marker)
        // The kept original is deleted below: only once the restored conversation is surely saved.
        do { try ChatDisk.saveAndWait(restored, chat: key) } catch {
            fail(key, "没能还原：存不进手机（\(error.localizedDescription)）。原文还在，腾出空间后再试。")
            return
        }
        entries[key] = restored
        setSummary(key, record: Disk.load(MemorySafety.SummaryRecord.self, Self.leafSummary(key, leaf.id)))
        Disk.remove(Self.leafFile(key, leaf.id))
        Disk.remove(Self.leafSummary(key, leaf.id))
        setLeaves(key, leaves(key).filter { $0.id != leaf.id })
        scheduleIndexSync(key, entries: restored)
        scheduleIndexDeleteChat(key, includingLeaves: false, leafID: leaf.id)
        if !allPersistableQueued(key).isEmpty { persistQueued(key) }
        notify(key, .changed)
    }

    /// The person rewrote the 前情提要 by hand.
    func editSummary(_ key: String, _ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        setSummary(key, trimmed.isEmpty ? nil : trimmed, tainted: isSummaryTainted(key))
    }

    /// The current conversation's title, if one was written.
    func title(of key: String) -> String? { options(key).title }

    /// Gives a conversation the title you chose. Empty clears it (the companion names it again after the next exchange).
    func rename(_ key: String, to title: String) {
        var value = options(key)
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        value.title = clean.isEmpty ? nil : String(clean.prefix(40))
        setOptions(key, value)
    }

    /// After the first exchange of a new conversation, one small request writes its title.
    func nameChatIfNew(_ key: String) {
        guard options(key).title == nil else { return }
        let said = history(key).filter { $0.note != true && $0.message.role != .tool && !$0.message.text.isEmpty }
        guard said.filter({ $0.message.role == .user }).count == 1, said.contains(where: { $0.message.role == .assistant }) else { return }
        let transcript = said.prefix(4).map { ($0.message.role == .user ? "用户：" : Words.t("旅伴：")) + String($0.message.text.prefix(400)) }.joined(separator: "\n")
        let epoch = epochs[key, default: 0]
        Task { [weak self] in
            guard let self,
                  let agent = await self.helperAsync(for: key, system: "你给对话起标题：不超过 12 个字，中文，不要标点、引号和表情，只输出标题。"),
                  self.epochs[key, default: 0] == epoch,
                  self.options(key).title == nil,
                  let raw = try? await agent.ask("给这段对话起个标题：\n\n" + transcript) else { return }
            let clean = String(raw.unicodeScalars.filter { !CharacterSet.punctuationCharacters.contains($0) && !CharacterSet.symbols.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0) }).prefix(12)
            guard !clean.isEmpty, self.epochs[key, default: 0] == epoch,
                  self.options(key).title == nil else { return }
            var value = self.options(key)
            value.title = String(clean)
            self.setOptions(key, value)
        }
    }

    /// Puts the current conversation aside and starts an empty one. Nothing happens to an empty chat. False when the
    /// conversation could not be put aside (the disk is full, say): then it stays as it is.
    @discardableResult
    func turnLeaf(_ key: String) -> Bool {
        guard canAcceptInput(for: key) else { return false }
        return shelveCurrent(key)
    }

    func removeFoldSummaries(_ key: String, in list: [Entry]) {
        guard keeping else { return }
        for entry in list where entry.fold == true {
            Disk.remove(Self.foldSummary(key, entry.id))
        }
        let chatsDir = Disk.root.appendingPathComponent("chats", isDirectory: true)
        let prefix = "\(key)~fold-"
        let suffix = "~summary.json"
        if let items = try? FileManager.default.contentsOfDirectory(at: chatsDir, includingPropertiesForKeys: nil) {
            for item in items where item.lastPathComponent.hasPrefix(prefix) && item.lastPathComponent.hasSuffix(suffix) {
                try? FileManager.default.removeItem(at: item)
            }
        }
    }

    private func shelveCurrent(_ key: String) -> Bool {
        guard canDispatchQueue, !unresolvedLeafOpenChats.contains(key) else { return false }
        guard ensureChatReadableForWrite(key, verifyDisk: true) else {
            let reason = "当前对话历史暂时无法读取，已中止收起/翻页以防止覆盖原记录。"
            Diag.note(reason)
            notify(key, .failed(reason))
            return false
        }
        stop(key)
        restoreUnemittedInterjects(for: key)
        epochs[key, default: 0] += 1
        browser.release(key)
        let current = history(key)
        guard !keeping || !unreadableChats.contains(key) else {
            let reason = "当前对话历史暂时无法读取，已中止收起/翻页以防止覆盖原记录。"
            Diag.note(reason)
            notify(key, .failed(reason))
            return false
        }
        guard current.contains(where: { $0.note != true }) else {
            // Leave unsent queued messages and thread labels untouched when there is no conversation to shelve,
            // while cleaning any leftover note-only lines or state.
            modelInputLog.clear(key)
            clearPlan(key)
            trusted.remove(key)
            taint.reset(key)
            resetTurnMemoryTaint(key)
            Snapshots.shared.forget(key)
            removeFoldSummaries(key, in: current)
            setSummary(key, nil)
            if !current.isEmpty {
                entries[key] = []
                if keeping { ChatDisk.save([Entry](), chat: key) }
                scheduleIndexSync(key, entries: [])
                clearPreview(key)
                notify(key, .changed)
            }
            return true
        }
        let first = current.first { $0.message.role == .user && !$0.message.text.isEmpty }?.message.text ?? Words.t("一段絮语")
        let priorOptions = options(key)
        let named = priorOptions.title
        let title = named ?? String(first.replacingOccurrences(of: "\n", with: " ").prefix(28))
        let shelvedConversationID = activeConversationID(for: key)
        let leaf = Leaf(
            id: UUID().uuidString,
            title: title,
            at: current.last?.at ?? Now.ms,
            count: current.filter { $0.note != true && $0.message.role != .tool }.count,
            conversationID: shelvedConversationID
        )
        let leafKey = Self.threadKey(key, leaf: leaf.id)
        let waiting = queued[key] ?? []
        let nextLeaves = [leaf] + leaves(key)
        let leafAnchor = ConversationAnchor.from(entryIds: current.map(\.id))
        var rotatedOptions = options(key)
        rotatedOptions.title = nil
        rotatedOptions.conversationID = UUID().uuidString.lowercased()
        if keeping {
            // The page is emptied synchronously inside the same transaction as its leaf copy, leaf index, and rotated
            // conversationID options so crashes never leave old active history paired with a rotated identity.
            let priorPersistedOptions = options(key)
            var clearedActive = false
            do {
                try Disk.write(current, Self.leafFile(key, leaf.id))
                if let old = summaryRecord(key) {
                    try Disk.write(old, Self.leafSummary(key, leaf.id))
                }
                if !waiting.isEmpty { try QueuedStore.saveAndWait(waiting, for: leafKey, anchor: leafAnchor) }
                try Disk.write(nextLeaves, Self.leafList(key))
                try ChatDisk.saveAndWait([Entry](), chat: key)
                clearedActive = true
                try ChatDisk.writeValueAndWait(rotatedOptions, file: Self.optionsFile(key))
            } catch {
                if clearedActive {
                    try? ChatDisk.saveAndWait(current, chat: key)
                }
                Disk.remove(Self.leafFile(key, leaf.id))
                Disk.remove(Self.leafSummary(key, leaf.id))
                if !waiting.isEmpty { try? QueuedStore.saveAndWait([], for: leafKey) }
                try? Disk.write(leaves(key), Self.leafList(key))
                try? ChatDisk.writeValueAndWait(priorPersistedOptions, file: Self.optionsFile(key))
                fail(key, "没能把这段收起来：存不进手机（\(error.localizedDescription)）。对话原样留着，腾出空间后再试。")
                return false
            }
        }
        setOptions(key, rotatedOptions)
        setSummary(key, nil)
        clearPlan(key)
        trusted.remove(key)
        taint.reset(key)
        resetTurnMemoryTaint(key)
        Snapshots.shared.forget(key)
        removeFoldSummaries(key, in: current)
        objectWillChange.send()
        leafBook[key] = nextLeaves
        moveThread(key, to: leafKey)
        if named == nil { nameLeaf(key, leaf.id, from: current) }
        entries[key] = []
        // In-flight queued items already merged into `current` are now durably on disk inside `leafFile`.
        let persistedIds = Set(current.flatMap { $0.queuedIds ?? [] })
        if !persistedIds.isEmpty {
            inFlightQueued[key]?.removeAll { persistedIds.contains($0.id) }
            if inFlightQueued[key]?.isEmpty == true { inFlightQueued[key] = nil }
        }
        if !waiting.isEmpty {
            queued[leafKey] = waiting
        }
        queued[key] = nil
        persistQueued(key)
        modelInputLog.clear(key)
        scheduleIndexSync(key, leafID: leaf.id, leafTitle: leaf.title, entries: current)
        scheduleIndexSync(key, entries: [])
        clearPreview(key)
        notify(key, .changed)
        return true
    }

    /// 从这里另起一叶: the conversation so far goes into a leaf, untouched, and a new one begins with everything
    /// up to and including entry `id`, to take another way from there.
    func fork(_ key: String, at id: String) {
        let current = history(key)
        guard let index = current.firstIndex(where: { $0.id == id }) else { return }
        let kept = Array(current[...index]).filter { $0.note != true }
        guard turnLeaf(key) else { return }
        let restarted = kept.map { entry -> Entry in
            var copy = entry
            copy.id = UUID().uuidString
            return copy
        }
        var marker = Entry(id: UUID().uuidString, at: Now.ms, message: .assistant(Words.t("从这里另起了一叶，原来的那段收在絮语页，随时能翻回去。")))
        marker.note = true
        entries[key] = restarted + [marker]
        if keeping { ChatDisk.save(entries[key] ?? [], chat: key) }
        scheduleIndexSync(key, entries: entries[key] ?? [])
        notify(key, .changed)
    }

    /// Empties the current conversation. The legacy clear action can also remove every conversation put aside.
    @discardableResult
    func clearChat(_ key: String, includingLeaves: Bool = true) -> Bool {
        guard canAcceptInput(for: key) else { return false }
        let current = history(key)
        clearQueuedSlot(key)
        stop(key)
        epochs[key, default: 0] += 1
        browser.release(key)
        clearPlan(key)
        trusted.remove(key)
        taint.reset(key)
        resetTurnMemoryTaint(key)
        modelInputLog.clear(key)
        Snapshots.shared.forget(key)
        removeFoldSummaries(key, in: current)
        if includingLeaves {
            let oldLeaves = leaves(key)
            if keeping {
                for leaf in oldLeaves {
                    Disk.remove(Self.leafFile(key, leaf.id))
                    Disk.remove(Self.leafSummary(key, leaf.id))
                }
            }
            for leaf in oldLeaves {
                let leafKey = Self.threadKey(key, leaf: leaf.id)
                clearQueuedSlot(leafKey)
                Task { await ArtifactIndex.shared.markChatDirty(leafKey) }
            }
            setLeaves(key, [])
        }
        if keeping { ChatDisk.save([Entry](), chat: key) }
        scheduleIndexDeleteChat(key, includingLeaves: includingLeaves)
        forgetThreads(key, includingLeaves: includingLeaves)
        setSummary(key, nil)
        var cleared = options(key)
        cleared.title = nil
        cleared.conversationID = UUID().uuidString.lowercased()
        setOptions(key, cleared)
        unreadableChats.remove(key)
        entries[key] = []
        clearPreview(key)
        notify(key, .changed)
        Task { await ArtifactIndex.shared.markChatDirty(key) }
        return true
    }

    /// Brings an earlier conversation back to the front; the current one is put aside in its place.
    func openLeaf(_ key: String, _ leaf: Leaf) {
        // Reading and saving a long conversation took the main thread long enough to stall the sidebar's tap:
        // the file work now runs off it, and the steps that change what is on screen stay in order here.
        guard canAcceptInput(for: key) else { return }
        openingLeaves.insert(key)
        let task = Task { [weak self] in
            await self?.openLeafNow(key, leaf)
            self?.openingLeaves.remove(key)
            self?.openingLeafTasks[key] = nil
            if let self {
                self.subtasks.drainDeferredDeliveries(for: key, team: self)
            }
        }
        openingLeafTasks[key] = task
    }

    /// Waits for any already-running `openLeafNow` transactions to finish committing or rolling back
    /// before a backup restore arms its barrier and replaces `Team/`.
    func waitForOpeningLeaves() async {
        while !openingLeafTasks.isEmpty {
            let pending = Array(openingLeafTasks.values)
            for task in pending {
                await task.value
            }
        }
    }

    private func openLeafNow(_ key: String, _ leaf: Leaf) async {
        // A leaf that is there but cannot be read stays where it is, untouched: opening it must not throw it away
        // (the review, #15).
        var kept: [Entry] = []
        var keptSummary: MemorySafety.SummaryRecord?
        if keeping {
            let file = Disk.url(Self.leafFile(key, leaf.id))
            let summaryPath = Self.leafSummary(key, leaf.id)
            let read: (entries: [Entry]?, summary: MemorySafety.SummaryRecord?, exists: Bool) = await Task.detached(priority: .userInitiated) {
                guard FileManager.default.fileExists(atPath: file.path) else {
                    return (nil, Disk.load(MemorySafety.SummaryRecord.self, summaryPath), false)
                }
                guard let data = try? Data(contentsOf: file), let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
                    return (nil, nil, true)
                }
                return (entries, Disk.load(MemorySafety.SummaryRecord.self, summaryPath), true)
            }.value
            if read.exists, read.entries == nil {
                fail(key, Words.t("这一段旧絮语读不出来，先留着没动。\n可能是格式不认识或文件坏了；先别删，备份一份。"))
                return
            }
            kept = read.entries ?? []
            keptSummary = read.summary
        }
        guard canDispatchQueue, !unresolvedLeafOpenChats.contains(key) else { return }
        guard ensureChatReadableForWrite(key, verifyDisk: true) else {
            let reason = "当前对话历史暂时无法读取，已中止翻页以防止覆盖原记录。"
            Diag.note(reason)
            notify(key, .failed(reason))
            return
        }
        guard let leaf = leaves(key).first(where: { $0.id == leaf.id }) else { return }
        guard shelveCurrent(key) else { return }
        let leafKey = Self.threadKey(key, leaf: leaf.id)
        let leafQueued = queued[leafKey] ?? []
        let priorEntries = entries[key] ?? []
        let priorQueued = allPersistableQueued(key)
        let priorAnchor = priorQueued.isEmpty ? nil : ConversationAnchor.from(entryIds: priorEntries.map(\.id))
        let persistSnapshot = allPersistableQueued(key, extra: leafQueued)
        let remainingLeaves = leaves(key).filter { $0.id != leaf.id }
        let targetAnchor = ConversationAnchor.from(entryIds: kept.map(\.id))
        let priorOptions = options(key)
        var reopenedOptions = priorOptions
        reopenedOptions.conversationID = leaf.conversationID ?? UUID().uuidString.lowercased()
        if leaf.marker == nil {
            reopenedOptions.title = leaf.title
        }
        if keeping {
            // The leaf's own files (and its queued messages) go only once the restored page, queue, options (`conversationID`),
            // and leaf index are surely saved. A PendingLeafOpen marker guards against crashes between writes;
            // any failure rolls back active writes immediately.
            let toSave = kept
            let saveQueue = !persistSnapshot.isEmpty
            let listPath = Self.leafList(key)
            let optionsPath = Self.optionsFile(key)
            let targetOptions = reopenedOptions
            let chatsDirURL = Disk.root.appendingPathComponent("chats", isDirectory: true)
            let activeChatURL = Disk.url(Disk.chatFile(key))
            let leafChatURL = Disk.url(Self.leafFile(key, leaf.id))
            let initialTx = PendingLeafOpen(
                chatKey: key,
                leafId: leaf.id,
                leafKey: leafKey,
                priorActiveQueuedIds: priorQueued.map(\.id),
                writtenChatEntryIds: toSave.map(\.id),
                writtenActiveQueuedIds: saveQueue ? persistSnapshot.map(\.id) : [],
                writtenChatInode: nil,
                chatsDirInode: QueuedMessageStore.directoryInode(at: chatsDirURL),
                leafChatInode: QueuedMessageStore.fileInode(at: leafChatURL),
                priorConversationID: priorOptions.conversationID,
                targetConversationID: targetOptions.conversationID
            )
            let saved: (error: Error?, unresolvedRollback: Bool) = await Task.detached(priority: .userInitiated) {
                var wroteChat = false
                var wroteQueue = false
                var wroteOptions = false
                var tx = initialTx
                do {
                    try QueuedStore.savePendingLeafOpen(tx)
                    try ChatDisk.saveAndWait(toSave, chat: key)
                    wroteChat = true
                    tx.writtenChatInode = QueuedMessageStore.fileInode(at: activeChatURL)
                    try QueuedStore.savePendingLeafOpen(tx)
                    if saveQueue {
                        try QueuedStore.saveAndWait(persistSnapshot, for: key, anchor: targetAnchor)
                        wroteQueue = true
                    }
                    try ChatDisk.writeValueAndWait(targetOptions, file: optionsPath)
                    wroteOptions = true
                    try Disk.write(remainingLeaves, listPath)
                    return (nil, false)
                } catch {
                    var rollbackClean = true
                    if wroteOptions {
                        do {
                            try ChatDisk.writeValueAndWait(priorOptions, file: optionsPath)
                        } catch {
                            rollbackClean = false
                        }
                    }
                    if wroteQueue {
                        do {
                            try QueuedStore.saveAndWait(priorQueued, for: key, anchor: priorAnchor)
                        } catch {
                            rollbackClean = false
                        }
                    }
                    if wroteChat {
                        if priorEntries.isEmpty {
                            ChatDisk.removeAndWait(key)
                            if FileManager.default.fileExists(atPath: activeChatURL.path) {
                                rollbackClean = false
                            }
                        } else {
                            do {
                                try ChatDisk.saveAndWait(priorEntries, chat: key)
                            } catch {
                                rollbackClean = false
                            }
                        }
                    }
                    if rollbackClean {
                        QueuedStore.clearPendingLeafOpen(for: key)
                    }
                    return (error, !rollbackClean)
                }
            }.value
            if let error = saved.error {
                if saved.unresolvedRollback {
                    // Pause further writes to this chat without touching chats/<key>.json until relaunch reconciles it.
                    unresolvedLeafOpenChats.insert(key)
                    let text = Words.t("没能翻回这一段，且清理临时写入也失败（\(error.localizedDescription)）。它还在絮语页里；为防覆盖，已暂停这段对话的新发送，请腾出空间后重启 Clio。")
                    Diag.note(text)
                    notify(key, .failed(text))
                    PetNews.shared.post(.failed, chat: key, title: chatName(key))
                    if PetNews.shared.focused != key, UIApplication.shared.applicationState == .active {
                        ToastCenter.shared.show(
                            "\(chatName(key)) · \(L.t("pet.failed"))",
                            symbol: "exclamationmark.triangle.fill",
                            tint: Ink.stop
                        )
                    }
                } else {
                    fail(key, Words.t("没能翻回这一段：存不进手机（\(error.localizedDescription)）。它还在絮语页里。"))
                }
                return
            }
        }
        setSummary(key, record: keptSummary)
        if keeping { Disk.remove(Self.leafSummary(key, leaf.id)) }
        entries[key] = kept
        if !leafQueued.isEmpty {
            var merged = queued[key] ?? []
            let existing = Set(merged.map(\.id))
            merged.append(contentsOf: leafQueued.filter { !existing.contains($0.id) })
            queued[key] = merged.isEmpty ? nil : merged
            queued[leafKey] = nil
            inFlightQueued[leafKey] = nil
            if keeping { QueuedStore.clear(leafKey) }
        }
        if keeping {
            Disk.remove(Self.leafFile(key, leaf.id))
            QueuedStore.clearPendingLeafOpen(for: key)
        }
        objectWillChange.send()
        leafBook[key] = remainingLeaves
        if leaf.marker == nil {
            moveThread(leafKey, to: key)
        }
        setOptions(key, reopenedOptions)
        unreadableChats.remove(key)
        scheduleIndexDeleteChat(key, includingLeaves: false, leafID: leaf.id)
        scheduleIndexSync(key, entries: kept)
        let last = kept.last { $0.message.role == .assistant && !$0.message.text.isEmpty }?.message.text
        touch(key, preview: last, at: leaf.at)
        notify(key, .changed)
    }

    /// Gives a leaf put aside a short title written by the model, in place of its first words.
    func nameLeaf(_ key: String, _ id: String, from entries: [Entry]) {
        let lines = entries.filter { $0.note != true && $0.message.role != .tool && !$0.message.text.isEmpty }
            .prefix(12)
            .map { ($0.message.role == .user ? "用户：" : Words.t("旅伴：")) + String($0.message.text.prefix(300)) }
        guard lines.count >= 2 else { return }
        let transcript = lines.joined(separator: "\n")
        let initialTitle = leaves(key).first { $0.id == id }?.title
        Task { [weak self] in
            guard let self,
                  let agent = await self.helperAsync(for: key, system: "你给对话起标题：8 到 14 个字，中文，不加引号和标点，只输出标题。"),
                  let title = try? await agent.ask("给下面这段对话起个标题：\n\n" + transcript) else { return }
            let clean = title.trimmingCharacters(in: CharacterSet(charactersIn: "「」\"'《》 \n。.")).prefix(20)
            guard self.canAcceptInput(for: key), !clean.isEmpty else { return }
            var list = self.leaves(key)
            guard let index = list.firstIndex(where: { $0.id == id }), list[index].title == initialTitle else { return }
            list[index].title = String(clean)
            self.setLeaves(key, list)
            self.scheduleIndexUpdateLeafTitle(key, leafID: id, title: String(clean))
        }
    }

    func dropLeaf(_ key: String, _ leaf: Leaf) {
        guard canAcceptInput(for: key) else { return }
        if keeping {
            Disk.remove(Self.leafFile(key, leaf.id))
            Disk.remove(Self.leafSummary(key, leaf.id))
        }
        setLeaves(key, leaves(key).filter { $0.id != leaf.id })
        let leafKey = Self.threadKey(key, leaf: leaf.id)
        forgetThreads(leafKey)
        clearQueuedSlot(leafKey)
        scheduleIndexDeleteChat(key, includingLeaves: false, leafID: leaf.id)
        Task { await ArtifactIndex.shared.markChatDirty(leafKey) }
    }
}
