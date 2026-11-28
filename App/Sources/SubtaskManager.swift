import AgentKit
import Combine
import Craft
import CryptoKit
import Foundation
import SwiftUI
import UIKit

/// Manages Canonical async companion subtasks (`Team/subtasks/<threadID>.json`),
/// non-reusable attempt execution identities (`attempt-*`), stop-scope controls,
/// and two-phase crash-safe `clio.question` resumes.
@MainActor
final class SubtaskManager: ObservableObject {
    nonisolated static let sharedCanonicalStore: TaskStore = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dbURL = appSupport.appendingPathComponent("ClioIndex", isDirectory: true).appendingPathComponent("clio-tasks.db")
        return TaskStore(canonicalTeamDirectory: Disk.root, projectionDatabaseURL: dbURL, isWriteFrozen: { Disk.frozen })
    }()

    let store: TaskStore
    @Published private(set) var threads: [SubtaskThread] = []
    @Published private(set) var pendingQuestions: [PendingQuestion] = []

    /// Keyed by `threadID`, storing the active `(attemptID, task)` so stale cleanup never clobbers a newer retry.
    private var runningTasks: [String: (attemptID: String, task: Task<Void, Never>)] = [:]
    private var liveQuestionWaiters: [String: (formID: UUID, fieldKey: String)] = [:]
    /// Subtask deliveries that arrived while `openLeafNow` was in flight for `parentChat`; replayed once flip settles.
    private var deferredDeliveriesWhileOpening: [String: [(threadID: String, attemptID: String, eventID: String)]] = [:]
    private var unlockObserver: AnyCancellable?
    private weak var boundTeam: TeamModel?

    init(store: TaskStore? = nil) {
        self.store = store ?? Self.sharedCanonicalStore
        self.threads = self.store.allThreads()
        self.pendingQuestions = self.store.allPendingQuestions().filter { $0.state == .pending || $0.state == .answered }
    }

    func bind(to team: TeamModel) {
        boundTeam = team
        if unlockObserver == nil {
            unlockObserver = NotificationCenter.default.publisher(for: .clioAppDidUnlock)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    guard let self, let team = self.boundTeam else { return }
                    self.drainPendingQuestionResumes(team: team)
                }
        }
    }

    func refresh() {
        threads = store.allThreads()
        pendingQuestions = store.allPendingQuestions().filter { $0.state == .pending || $0.state == .answered }
        boundTeam?.objectWillChange.send()
    }

    func threads(for parentChat: String) -> [SubtaskThread] {
        threads.filter { $0.stableParentChatID == parentChat }
    }

    func activeThreads(for parentChat: String) -> [SubtaskThread] {
        threads.filter { $0.stableParentChatID == parentChat && $0.status.isActive }
    }

    func reconcileRequiredThreads(for parentChat: String) -> [SubtaskThread] {
        threads.filter { $0.stableParentChatID == parentChat && $0.status == .interruptedNeedsReconcile }
    }

    func hasActiveRemoteHillsTask(for parentChat: String) -> Bool {
        activeThreads(for: parentChat).contains(where: \.isRemoteHills)
    }

    /// Cold-start reconciliation: classifies running remnants into `.interrupted` vs `.interruptedNeedsReconcile`,
    /// replays any completed-but-undelivered parent results idempotently, re-presents `.pending` foreground
    /// questions, and resumes `.answered` questions once App Lock is unlocked.
    @discardableResult
    func reconcileOnLaunch(team: TeamModel) -> ColdStartTaskReconciliation {
        bind(to: team)
        let report = store.reconcileOnColdStart()
        for thread in report.undeliveredFinishedThreads {
            if let attempt = thread.latestAttempt, let eventID = attempt.deliveryEventID {
                deliverIdempotentlyToParent(thread: thread, attemptID: attempt.attemptID, eventID: eventID, team: team)
            }
        }
        for pending in report.pendingForegroundQuestions where !pending.requiresForeground {
            rePresentPendingQuestion(pending, team: team)
        }
        refresh()
        if AppLock.isCurrentlyUnlocked {
            drainPendingQuestionResumes(team: team)
        }
        return report
    }

    // MARK: - Async Subtask Launch & Execution (Non-Reusable Execution Identity)

    func launchAsyncSubtask(
        from askerId: String,
        to helperNameOrHint: String,
        task words: String,
        parentChat: String,
        team: TeamModel
    ) async -> ToolOutput {
        bind(to: team)
        let wanted = helperNameOrHint.trimmingCharacters(in: .whitespacesAndNewlines)
        let names = team.bots.filter { $0.id != askerId }.map(\.name).joined(separator: "、")
        guard let asker = team.bots.first(where: { $0.id == askerId }),
              let helper = team.bots.first(where: { $0.name == wanted && $0.id != askerId })
                ?? team.bots.first(where: { $0.id != askerId && (wanted.contains($0.name) || $0.name.contains(wanted)) }) else {
            return ToolOutput("没有叫「\(wanted)」的旅伴。能请的有：\(names)。", isError: true)
        }
        let cleanTask = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTask.isEmpty else { return ToolOutput("要说清楚请它做什么。", isError: true) }

        let helperBaseChat = TeamModel.key(bot: helper.id)
        let helperPlace = team.place(of: helperBaseChat)
        guard helperPlace.host != nil else { return ToolOutput(WorkPlace.missingHostMessage, isError: true) }

        guard let found = team.resolveActive(helper.model ?? team.settings.defaultModel)
                ?? team.resolveActive(team.settings.defaultModel)
                ?? team.resolve(helper.model ?? team.settings.defaultModel)
                ?? team.resolve(team.settings.defaultModel) else {
            return ToolOutput("\(helper.name)用的模型连不上（没设好或没有密钥）。", isError: true)
        }
        if found.endpoint.isPaused {
            return ToolOutput("\(helper.name)所用的服务「\(found.endpoint.name)」已暂停。", isError: true)
        }

        let inheritedPlanMode = team.isPlanModeActive(for: parentChat)
        let taintedIn = team.taint.isTainted(parentChat) || team.isTurnMemoryTainted(parentChat)

        do {
            let parentConversationID = team.activeConversationID(for: parentChat)
            let (thread, attempt) = try store.createThread(
                stableParentChatID: parentChat,
                parentConversationID: parentConversationID,
                askerBotID: asker.id,
                helperBotID: helper.id,
                helperBotName: helper.name,
                taskPrompt: cleanTask,
                inheritedPlanMode: inheritedPlanMode,
                taintedIn: taintedIn,
                hostCode: helperPlace.code
            )
            refresh()
            spawnExecutionTask(
                thread: thread,
                attempt: attempt,
                asker: asker,
                helper: helper,
                workplace: helperPlace,
                team: team
            )
            return ToolOutput("已派发异步子任务给「\(helper.name)」（线程 \(thread.threadID)）。它会在后台独立推进并在完成后把结果回传到当前对话；你可以先继续回复用户。")
        } catch {
            return ToolOutput("没能创建子任务：\(error.localizedDescription)", isError: true)
        }
    }

    /// Retries an interrupted thread. Rejects active threads and rejects blind retry of `.interruptedNeedsReconcile`.
    func retryThread(_ threadID: String, explicitUserReconciled: Bool, team: TeamModel) throws {
        bind(to: team)
        let (thread, attempt) = try store.retryInterruptedThread(
            threadID: threadID,
            explicitUserReconciled: explicitUserReconciled
        )
        refresh()
        guard let asker = team.bots.first(where: { $0.id == thread.askerBotID }) ?? team.bots.first,
              let helper = team.bots.first(where: { $0.id == thread.helperBotID }) else {
            _ = try? store.finishAttempt(
                threadID: threadID,
                attemptID: attempt.attemptID,
                status: .failed,
                errorMessage: Words.t("目标旅伴已不存在。")
            )
            refresh()
            return
        }
        let workplace = WorkPlace(code: thread.hostCode)
        spawnExecutionTask(
            thread: thread,
            attempt: attempt,
            asker: asker,
            helper: helper,
            workplace: workplace,
            team: team
        )
    }

    private func spawnExecutionTask(
        thread: SubtaskThread,
        attempt: SubtaskAttempt,
        asker: BotInfo,
        helper: BotInfo,
        workplace: WorkPlace,
        team: TeamModel
    ) {
        let threadID = thread.threadID
        let attemptID = attempt.attemptID
        runningTasks[threadID]?.task.cancel()
        syncLiveIndicators(for: thread.stableParentChatID, team: team)
        let task = Task { @MainActor [weak self, weak team] in
            guard let self, let team else { return }
            await self.runAttempt(
                thread: thread,
                attempt: attempt,
                asker: asker,
                helper: helper,
                workplace: workplace,
                team: team
            )
        }
        runningTasks[threadID] = (attemptID: attemptID, task: task)
    }

    private func runAttempt(
        thread: SubtaskThread,
        attempt: SubtaskAttempt,
        asker: BotInfo,
        helper: BotInfo,
        workplace: WorkPlace,
        team: TeamModel
    ) async {
        let threadID = thread.threadID
        // Non-reusable per-attempt execution identity prevents retries from ever colliding on taint/receipts/approvals.
        let executionKey = attempt.attemptID
        let parentChat = thread.stableParentChatID
        let bgToken = UUID()
        BackgroundTurn.begin(chat: executionKey, name: "\(helper.name) · 后台子任务", token: bgToken)

        team.taint.clear(executionKey)
        team.resetTurnMemoryTaint(executionKey)
        if attempt.taintedIn {
            team.taint.mark(executionKey)
            team.markTurnMemoryTainted(executionKey)
        }
        team.livePlanModeLedger.setDelegationParent(parentChat, for: executionKey)
        if attempt.inheritedPlanMode {
            team.livePlanModeLedger.setInheritedReadOnly(true, for: executionKey)
        }
        team.ephemeralPlaces[executionKey] = workplace
        team.hostBindings.set(workplace.hostID, for: executionKey)

        defer {
            team.livePlanModeLedger.setInheritedReadOnly(false, for: executionKey)
            team.livePlanModeLedger.setDelegationParent(nil, for: executionKey)
            team.ephemeralPlaces.removeValue(forKey: executionKey)
            team.hostBindings.remove(for: executionKey)
            team.approvalReceipts.clear(executionChat: executionKey)
            team.taint.reset(executionKey)
            team.resetTurnMemoryTaint(executionKey)
            team.toolTails.removeValue(forKey: executionKey)
            team.clearPlan(executionKey)
            team.browser.release(executionKey)
            Snapshots.shared.forget(executionKey)
            if runningTasks[threadID]?.attemptID == executionKey {
                runningTasks.removeValue(forKey: threadID)
            }
            refresh()
            syncLiveIndicators(for: parentChat, team: team)
        }

        guard let found = team.resolveActive(helper.model ?? team.settings.defaultModel)
                ?? team.resolveActive(team.settings.defaultModel)
                ?? team.resolve(helper.model ?? team.settings.defaultModel)
                ?? team.resolve(team.settings.defaultModel) else {
            await completeAndDeliver(
                thread: thread,
                attempt: attempt,
                status: .failed,
                resultText: nil,
                errorMessage: "\(helper.name)没有可用模型。",
                taintedOut: false,
                bgToken: bgToken,
                team: team
            )
            return
        }

        #if DEBUG
        let overrideProvider = team.turnProviderOverrideForTesting?(found.endpoint, found.model, .subtask)
        #else
        let overrideProvider: (any ModelProvider)? = nil
        #endif

        let apiKey: String
        if overrideProvider != nil {
            apiKey = "test-key"
        } else if let secret = await team.readAPIKey(for: found.endpoint), !secret.isEmpty {
            apiKey = secret
        } else {
            await completeAndDeliver(
                thread: thread,
                attempt: attempt,
                status: .failed,
                resultText: nil,
                errorMessage: "\(found.endpoint.name) 的密钥不可用。",
                taintedOut: false,
                bgToken: bgToken,
                team: team
            )
            return
        }

        guard !Task.isCancelled else {
            await completeAndDeliver(
                thread: thread,
                attempt: attempt,
                status: .cancelled,
                resultText: nil,
                errorMessage: "已取消。",
                taintedOut: false,
                bgToken: bgToken,
                team: team
            )
            return
        }

        let traits = found.endpoint.traits(found.model)
        let helperImageAPIKey: String?
        if traits.tools, team.phase != .demo, let selected = team.imageModelSelection {
            helperImageAPIKey = await team.readAPIKey(for: selected.endpoint.id)
        } else {
            helperImageAPIKey = nil
        }

        let planTail = attempt.inheritedPlanMode
            ? "\n当前父对话处于「规划模式 · 只看不动」，你仅限只读调研与方案梳理，禁止写入文件、执行命令、修改记忆或调用外部扩展。"
            : ""
        let parentUsesMemory = !team.options(parentChat).off.contains(Grant.memory.rawValue) && Grant.memory.policy != .off
        let (refresher, refresherToken) = team.registerLivePromptRefresher(
            for: helper,
            in: parentChat,
            room: nil,
            workplace: workplace,
            memory: parentUsesMemory,
            extraTail: "这是来自\(asker.name)的异步后台子任务（独立线程 \(threadID)）。请专注完成并将结论整理清楚。" + planTail
        )
        defer { team.unregisterLivePromptRefresher(refresherToken) }
        let prompt = refresher.currentPrompt()

        let baseProvider = overrideProvider ?? found.endpoint.provider(key: apiKey, stableSystemPrefix: prompt.prefix)
        let sideEffectContext = (threadID: threadID, attemptID: executionKey, store: store)
        let subtaskTools: [AgentTool] = traits.tools
            ? team.tools(
                for: helper,
                key: executionKey,
                canSee: traits.sees || team.canUseAuxiliaryVision(for: found.endpoint, model: found.model),
                helping: true,
                displayChat: parentChat,
                workplace: workplace,
                imageAPIKey: helperImageAPIKey,
                experienceSource: .subtask,
                subtaskSideEffectContext: sideEffectContext
            )
            : []

        var agent = Agent(
            provider: team.outboundProvider(
                team.recordingProvider(baseProvider, chat: executionKey, refresher: refresher),
                endpoint: found.endpoint,
                model: found.model,
                chat: executionKey
            ),
            model: found.model,
            system: prompt.full,
            tools: subtaskTools,
            approve: { [weak team] ask, tool in
                guard let team else { return false }
                let target = await MainActor.run {
                    team.resolveConversationTarget(
                        slotKey: parentChat,
                        conversationID: thread.parentConversationID,
                        threadCreatedAtMs: thread.createdAtMs
                    )
                }
                switch target {
                case .active(let slot):
                    return await team.ask(ask, tool: tool, bot: helper.id, chat: slot, executionChat: executionKey, workplace: workplace)
                case .leaf(let slot, let leaf):
                    var labeled = ask
                    labeled.reason = "【来自已收起对话「\(leaf.title)」的后台任务】\n" + ask.reason
                    return await team.ask(labeled, tool: tool, bot: helper.id, chat: slot, executionChat: executionKey, workplace: workplace)
                case .ambiguous:
                    var labeled = ask
                    labeled.reason = "【来自更早对话的后台任务】\n" + ask.reason
                    return await team.ask(labeled, tool: tool, bot: helper.id, chat: parentChat, executionChat: executionKey, workplace: workplace)
                case .gone:
                    return false
                }
            }
        )
        agent.screen = TeamModel.screen
        // In Plan mode, never allow native reply images to write PNG files to disk.
        // Outside Plan mode, pre-write a Canonical pending_side_effect BEFORE writing reply images.
        if !attempt.inheritedPlanMode {
            let storeRef = store
            agent.renderReplyImages = { images in
                let callID = "reply-img-\(UUID().uuidString.lowercased())"
                try storeRef.recordPendingSideEffect(
                    threadID: threadID,
                    attemptID: executionKey,
                    callID: callID,
                    tool: "render_reply_images",
                    target: "reply-images(\(images.count))"
                )
                let rendered = try await WorkspaceImages.reply(images)
                _ = try? storeRef.settleSideEffect(threadID: threadID, attemptID: executionKey, callID: callID)
                return rendered
            }
        }
        if Pref.temperature >= 0 { agent.temperature = Pref.temperature }
        if Pref.maxOutput > 0 { agent.outputLimit = Pref.maxOutput }
        agent.thinking = .auto
        agent.contractKey = found.endpoint.contractKey(for: found.model)
        agent.speakerOrThreadID = executionKey
        agent.customHeaders = found.endpoint.customNonSecretHeaders

        final class OutputCollector: @unchecked Sendable {
            private let lock = NSLock()
            private var streamed = ""
            private var finalAssistantText: String?
            func appendText(_ chunk: String) { lock.withLock { streamed += chunk } }
            func setAssistantText(_ text: String) { lock.withLock { finalAssistantText = text } }
            var resolvedText: String { lock.withLock { finalAssistantText ?? streamed } }
        }

        let collector = OutputCollector()
        let promptMessage = "【\(asker.name)派发的后台子任务，这不是用户本人的话】\(thread.taskPrompt)"
        let remoteHostID: String? = workplace.hostID.hasPrefix("hill:") ? String(workplace.hostID.dropFirst(5)) : nil
        let taskStore = store
        var failedMessage: String?

        do {
            try await agent.run(history: [.user(promptMessage)]) { event in
                switch event {
                case .text(let chunk):
                    collector.appendText(chunk)
                case .message(let msg):
                    if msg.role == .assistant, !msg.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        collector.setAssistantText(msg.text)
                    } else if msg.role == .tool, msg.toolName == "ssh_job_start" {
                        // Record started Hills background jobs so explicit remote stop can terminate them cleanly.
                        if let parsed = Self.extractRemoteJobID(from: msg.text), let remoteHostID {
                            _ = try? taskStore.recordRemoteJob(
                                threadID: threadID,
                                attemptID: executionKey,
                                hostID: remoteHostID,
                                jobID: parsed
                            )
                        }
                    }
                case .toolStarted(_, _, let label):
                    await MainActor.run {
                        BackgroundTurn.step(chat: executionKey, doing: label)
                    }
                default:
                    break
                }
            }
        } catch is CancellationError {
            // Handled via Task.isCancelled check below.
        } catch {
            failedMessage = Explain.model(error, service: found.endpoint.name).displayTitle
        }

        let taintedOut = team.taint.isTainted(executionKey) || team.isTurnMemoryTainted(executionKey)
        if taintedOut {
            _ = try? store.markAttemptTaintedOut(threadID: threadID, attemptID: executionKey)
        }

        if Task.isCancelled {
            await completeAndDeliver(
                thread: thread,
                attempt: attempt,
                status: .cancelled,
                resultText: nil,
                errorMessage: "已被用户停止。",
                taintedOut: taintedOut,
                bgToken: bgToken,
                team: team
            )
        } else if let failedMessage {
            await completeAndDeliver(
                thread: thread,
                attempt: attempt,
                status: .failed,
                resultText: nil,
                errorMessage: failedMessage,
                taintedOut: taintedOut,
                bgToken: bgToken,
                team: team
            )
        } else {
            let trimmed = collector.resolvedText.trimmingCharacters(in: .whitespacesAndNewlines)
            await completeAndDeliver(
                thread: thread,
                attempt: attempt,
                status: .succeeded,
                resultText: trimmed.isEmpty ? "已完成（无额外说明）。" : trimmed,
                errorMessage: nil,
                taintedOut: taintedOut,
                bgToken: bgToken,
                team: team
            )
        }
    }

    private nonisolated static func extractRemoteJobID(from toolOutput: String) -> String? {
        let pattern = #"\b([a-f0-9]{8})\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: toolOutput, range: NSRange(toolOutput.startIndex..., in: toolOutput)),
              let range = Range(match.range(at: 1), in: toolOutput) else { return nil }
        return String(toolOutput[range])
    }

    private func completeAndDeliver(
        thread: SubtaskThread,
        attempt: SubtaskAttempt,
        status: SubtaskStatus,
        resultText: String?,
        errorMessage: String?,
        taintedOut: Bool,
        bgToken: UUID,
        team: TeamModel
    ) async {
        BackgroundTurn.end(chat: attempt.attemptID, token: bgToken, ok: status == .succeeded)
        guard let finished = try? store.finishAttempt(
            threadID: thread.threadID,
            attemptID: attempt.attemptID,
            status: status,
            resultText: resultText,
            errorMessage: errorMessage,
            taintedOut: taintedOut
        ) else {
            return
        }
        deliverIdempotentlyToParent(
            thread: finished.thread,
            attemptID: attempt.attemptID,
            eventID: finished.deliveryEventID,
            team: team
        )
    }

    /// Idempotently injects the subtask outcome into the original parent conversation (active slot or shelved leaf)
    /// keyed by `eventID`, confirming on-disk persistence via `onSaved` BEFORE recording `deliveredEventIDs`
    /// so write failures never mark delivery complete and in-memory duplicates never mask disk failures.
    @discardableResult
    func deliverIdempotentlyToParent(
        thread: SubtaskThread,
        attemptID: String,
        eventID: String,
        team: TeamModel
    ) -> Bool {
        if let latest = store.thread(id: thread.threadID), latest.deliveredEventIDs.contains(eventID) {
            return false
        }
        let parentChat = thread.stableParentChatID
        // Never write into a leaf or active slot while `openLeafNow` is swapping files for `parentChat`:
        // defer until the leaf flip commits/rolls back and then re-resolve target cleanly.
        if team.openingLeaves.contains(parentChat) {
            var queue = deferredDeliveriesWhileOpening[parentChat] ?? []
            if !queue.contains(where: { $0.eventID == eventID }) {
                queue.append((threadID: thread.threadID, attemptID: attemptID, eventID: eventID))
                deferredDeliveriesWhileOpening[parentChat] = queue
            }
            return false
        }

        let attempt = thread.attempts.first { $0.attemptID == attemptID } ?? thread.latestAttempt
        let isTainted = attempt?.isTaintedForParent ?? false

        let summary: String
        switch attempt?.status {
        case .succeeded:
            summary = "【后台子任务完成 · \(thread.helperBotName)】\(attempt?.resultText ?? "已完成")"
        case .cancelled:
            summary = "【后台子任务已停止 · \(thread.helperBotName)】\(attempt?.errorMessage ?? "已取消")"
        default:
            summary = "【后台子任务失败 · \(thread.helperBotName)】\(attempt?.errorMessage ?? "执行未完成")"
        }

        var noteEntry = Entry(id: eventID, at: Now.ms, message: .assistant(summary), note: true)
        noteEntry.delegated = true
        if isTainted { noteEntry.tainted = true }

        let target = team.resolveConversationTarget(
            slotKey: parentChat,
            conversationID: thread.parentConversationID,
            threadCreatedAtMs: thread.createdAtMs
        )

        final class SavedReceiptBox: @unchecked Sendable {
            private let lock = NSLock()
            private var saved = false
            func set(_ value: Bool) { lock.withLock { saved = value } }
            func get() -> Bool { lock.withLock { saved } }
        }

        switch target {
        case .ambiguous:
            // Legacy thread lacking `parentConversationID` after a newer leaf was shelved:
            // keep undelivered rather than risking cross-conversation bleed into a different chat.
            Diag.note("旧版后台子任务 \(thread.threadID) 缺少父会话身份且期间已换页，暂保留待核对以避免串投。")
            refresh()
            return false

        case .gone:
            // Parent conversation was deleted or cleared: never inject into a new conversation reusing `parentChat`.
            let recorded = (try? store.recordParentDelivery(
                threadID: thread.threadID,
                attemptID: attemptID,
                eventID: eventID
            )) ?? false
            refresh()
            return recorded

        case .leaf(let slotKey, let leaf):
            // Deliver directly into the shelved leaf file without touching or tainting the newer active conversation.
            guard team.appendToShelvedLeaf(noteEntry, chatKey: slotKey, leaf: leaf) else {
                refresh()
                return false
            }
            let recorded = (try? store.recordParentDelivery(
                threadID: thread.threadID,
                attemptID: attemptID,
                eventID: eventID
            )) ?? false
            refresh()
            return recorded

        case .active(let activeChat):
            if isTainted {
                team.taint.mark(activeChat)
                team.markTurnMemoryTainted(activeChat)
            }

            let alreadyOnDisk: Bool
            if team.keeping {
                switch Disk.loadChatChecked(activeChat) {
                case .loaded(let diskEntries):
                    alreadyOnDisk = diskEntries.contains(where: { $0.id == eventID })
                case .corrupt(let recovered, let quarantined, _):
                    guard quarantined else {
                        refresh()
                        return false
                    }
                    alreadyOnDisk = recovered.contains(where: { $0.id == eventID })
                case .missing:
                    alreadyOnDisk = false
                case .unreadable:
                    refresh()
                    return false
                }
            } else {
                alreadyOnDisk = team.entries[activeChat]?.contains(where: { $0.id == eventID }) ?? false
            }

            if !alreadyOnDisk {
                // Remove any unpersisted in-memory remnant before re-appending so retries never duplicate or mask failures.
                if team.keeping, var mem = team.entries[activeChat] {
                    let before = mem.count
                    mem.removeAll { $0.id == eventID }
                    if mem.count != before {
                        team.entries[activeChat] = mem
                    }
                }
                let receipt = SavedReceiptBox()
                team.append(noteEntry, to: activeChat) { ok in
                    receipt.set(ok)
                }
                if team.keeping {
                    ChatDisk.finishWrites()
                }
                guard receipt.get() else {
                    if team.keeping, var mem = team.entries[activeChat] {
                        mem.removeAll { $0.id == eventID }
                        team.entries[activeChat] = mem
                        team.notify(activeChat, .changed)
                    }
                    refresh()
                    return false
                }
                team.touch(activeChat, preview: summary)
                team.record(attempt?.status == .succeeded ? .done : .failed, in: activeChat)
            } else if !(team.entries[activeChat]?.contains(where: { $0.id == eventID }) ?? false) {
                // Disk already has the event; ensure in-memory view reflects it without rewriting disk.
                var mem = team.history(activeChat)
                if !mem.contains(where: { $0.id == eventID }) {
                    mem.append(noteEntry)
                    team.entries[activeChat] = mem
                    team.notify(activeChat, .changed)
                }
            }

            let recorded = (try? store.recordParentDelivery(
                threadID: thread.threadID,
                attemptID: attemptID,
                eventID: eventID
            )) ?? false
            refresh()
            return recorded
        }
    }

    /// Replays any subtask deliveries deferred while `openLeafNow` was in flight for `parentChat`.
    func drainDeferredDeliveries(for parentChat: String, team: TeamModel) {
        guard !team.openingLeaves.contains(parentChat),
              let pending = deferredDeliveriesWhileOpening.removeValue(forKey: parentChat),
              !pending.isEmpty else { return }
        for item in pending {
            guard let latest = store.thread(id: item.threadID) else { continue }
            _ = deliverIdempotentlyToParent(
                thread: latest,
                attemptID: item.attemptID,
                eventID: item.eventID,
                team: team
            )
        }
    }

    /// Cancels all live subtask tasks and their approvals before/after a backup restore without writing into the swapped directory.
    func cancelAllForBackupRestore(team: TeamModel) {
        let active = runningTasks
        runningTasks.removeAll()
        var keysToClear: Set<String> = []
        for (threadID, entry) in active {
            entry.task.cancel()
            keysToClear.insert(threadID)
            keysToClear.insert(entry.attemptID)
            team.hostBindings.remove(for: entry.attemptID)
            team.ephemeralPlaces.removeValue(forKey: entry.attemptID)
            team.livePlanModeLedger.setInheritedReadOnly(false, for: entry.attemptID)
            team.livePlanModeLedger.setDelegationParent(nil, for: entry.attemptID)
        }
        guard !keysToClear.isEmpty else { return }
        for approval in team.approvals where approval.executionChat.map(keysToClear.contains) == true {
            team.approvalQueue.cancel(id: approval.id)
        }
        for key in keysToClear {
            team.approvalReceipts.clear(executionChat: key)
        }
        team.approvals.removeAll { $0.executionChat.map(keysToClear.contains) == true }
    }

    // MARK: - Stop Scope Controls

    func cancelThread(_ threadID: String, includeRemoteHills: Bool = true, team: TeamModel) {
        let activeAttemptID = runningTasks[threadID]?.attemptID ?? store.thread(id: threadID)?.latestAttempt?.attemptID
        runningTasks[threadID]?.task.cancel()
        runningTasks.removeValue(forKey: threadID)

        let keysToClear = Set([threadID, activeAttemptID].compactMap { $0 })
        for approval in team.approvals where approval.executionChat.map(keysToClear.contains) == true {
            team.approvalQueue.cancel(id: approval.id)
        }
        for key in keysToClear {
            team.approvalReceipts.clear(executionChat: key)
        }
        withAnimation(.smooth) {
            team.approvals.removeAll { $0.executionChat.map(keysToClear.contains) == true }
        }

        if let thread = store.thread(id: threadID),
           let attempt = thread.latestAttempt {
            if includeRemoteHills, !attempt.remoteJobs.isEmpty {
                let jobs = attempt.remoteJobs
                let hosts = Hills.shared.hosts
                Task.detached(priority: .userInitiated) {
                    for job in jobs {
                        if let host = hosts.first(where: { $0.id == job.hostID }) {
                            try? await Hills.stopJob(job.jobID, on: host)
                        }
                    }
                }
            }
            if attempt.status.isActive {
                _ = try? store.finishAttempt(
                    threadID: threadID,
                    attemptID: attempt.attemptID,
                    status: .cancelled,
                    errorMessage: "已被用户停止。"
                )
            }
        }
        refresh()
        if let parent = store.thread(id: threadID)?.stableParentChatID {
            syncLiveIndicators(for: parent, team: team)
        }
    }

    func stopSubtasks(for parentChat: String, includeRemoteHills: Bool, team: TeamModel) {
        let targets = activeThreads(for: parentChat).filter { includeRemoteHills || !$0.isRemoteHills }
        for thread in targets {
            cancelThread(thread.threadID, includeRemoteHills: includeRemoteHills, team: team)
        }
    }

    private func syncLiveIndicators(for parentChat: String, team: TeamModel) {
        let active = activeThreads(for: parentChat)
        let waiting = team.approvals.filter { $0.chat == parentChat }.count
        let summary: String?
        if active.isEmpty {
            summary = nil
        } else if active.count == 1 {
            summary = "\(active[0].helperBotName)后台处理中"
        } else {
            summary = "\(active.count) 个后台子任务进行中"
        }
        LiveTurns.syncSubtasks(chat: parentChat, activeCount: active.count, waitingCount: waiting, summary: summary)
        WidgetFeed.publish(team)
    }

    // MARK: - Two-Phase Crash-Safe Pending Questions (`clio.question`)

    @discardableResult
    func persistQuestion(
        questionID: String,
        formID: UUID,
        chatKey: String,
        threadID: String? = nil,
        botName: String,
        title: String,
        promptText: String,
        fieldKey: String,
        options: [String],
        requiresForeground: Bool
    ) -> PendingQuestion? {
        let q = PendingQuestion(
            questionID: questionID,
            chatKey: chatKey,
            threadID: threadID,
            botName: botName,
            title: title,
            promptText: promptText,
            fieldKey: fieldKey,
            options: options,
            requiresForeground: requiresForeground
        )
        liveQuestionWaiters[questionID] = (formID: formID, fieldKey: fieldKey)
        let saved = try? store.savePendingQuestion(q)
        refresh()
        return saved
    }

    func markLiveQuestionSettled(_ questionID: String, cancelled: Bool) {
        liveQuestionWaiters.removeValue(forKey: questionID)
        if cancelled {
            _ = try? store.cancelPendingQuestion(questionID: questionID)
        } else {
            _ = try? store.markQuestionConsumed(questionID: questionID)
        }
        Notify.clear(questionID)
        refresh()
    }

    /// Re-presents a surviving `.pending` question after cold launch so the user can answer it in foreground.
    private func rePresentPendingQuestion(_ question: PendingQuestion, team: TeamModel) {
        guard liveQuestionWaiters[question.questionID] == nil else { return }
        let form = Asker.Form(
            title: question.title,
            reason: question.promptText,
            from: question.botName,
            fields: [
                Asker.Field(
                    key: question.fieldKey,
                    label: question.promptText,
                    choices: question.options
                ),
            ],
            kind: .note,
            chat: question.chatKey,
            requiresVault: false
        )
        liveQuestionWaiters[question.questionID] = (formID: form.id, fieldKey: question.fieldKey)
        Task { @MainActor [weak self, weak team] in
            guard let self, let team else { return }
            let values = await Asker.shared.ask(form)
            self.liveQuestionWaiters.removeValue(forKey: question.questionID)
            guard let answer = values?[question.fieldKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !answer.isEmpty else {
                _ = try? self.store.cancelPendingQuestion(questionID: question.questionID)
                self.refresh()
                return
            }
            let replyPrompt = "【关于「\(question.title)」的回答】\(answer)"
            if team.send(replyPrompt, photos: [], to: question.chatKey, userInitiated: true) {
                _ = try? self.store.markQuestionConsumed(questionID: question.questionID)
            }
            self.refresh()
        }
    }

    /// Phase 1 entry from `clio.question` background notification response.
    /// Persists `.answered(answerID, resumeAttemptID)` FIRST; never consumes until Phase 2 succeeds after App Lock unlock.
    @discardableResult
    func recordNotificationAnswer(
        questionID: String,
        answerText: String,
        answerID: String = UUID().uuidString.lowercased(),
        team: TeamModel? = nil
    ) -> Bool {
        guard (try? store.recordQuestionAnswer(
            questionID: questionID,
            answerText: answerText,
            answerID: answerID,
            fromBackgroundNotification: true
        )) != nil else {
            return false
        }
        Notify.clear(questionID)
        refresh()
        if let activeTeam = team ?? boundTeam, AppLock.isCurrentlyUnlocked {
            drainPendingQuestionResumes(team: activeTeam)
        }
        return true
    }

    private static func deterministicUUID(from seed: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data(seed.utf8)))
        var bytes: uuid_t = (
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        )
        // RFC 4122 version 5 / variant bits
        bytes.6 = (bytes.6 & 0x0F) | 0x50
        bytes.8 = (bytes.8 & 0x3F) | 0x80
        return UUID(uuid: bytes)
    }

    /// Phase 2: Drains all `.answered` questions once App Lock is unlocked.
    /// Persists the reply under a deterministic `resumeAttemptID`-derived entry/queued ID and confirms disk save
    /// BEFORE claiming the resume manifest & marking `.consumed` so crashes before or after write neither swallow
    /// nor duplicate the reply.
    func drainPendingQuestionResumes(team: TeamModel) {
        bind(to: team)
        guard AppLock.isCurrentlyUnlocked else { return }
        let answered = store.allPendingQuestions().filter { $0.state == .answered }
        for item in answered {
            guard let answerID = item.answerID, !answerID.isEmpty else { continue }
            let resumeID = item.resumeAttemptID
                ?? PendingQuestion.deterministicResumeAttemptID(questionID: item.questionID, answerID: answerID)
            if store.isResumeDispatched(resumeAttemptID: resumeID) {
                _ = try? store.markQuestionConsumed(questionID: item.questionID)
                continue
            }
            let text = item.answerText ?? ""
            let persistedAndDispatched: Bool
            if let live = liveQuestionWaiters.removeValue(forKey: item.questionID) {
                Asker.shared.answer([live.fieldKey: text], to: live.formID)
                persistedAndDispatched = true
            } else {
                let replyPrompt = "【关于「\(item.title)」的回答】\(text)"
                let deterministicEntryID = "qresume-\(resumeID)"
                let deterministicQueuedID = Self.deterministicUUID(from: "qresume-\(resumeID)")
                persistedAndDispatched = team.sendConfirmedForQuestionResume(
                    replyPrompt,
                    to: item.chatKey,
                    deterministicEntryID: deterministicEntryID,
                    deterministicQueuedID: deterministicQueuedID
                )
            }
            guard persistedAndDispatched else { continue }
            _ = try? store.claimQuestionResume(questionID: item.questionID)
            _ = try? store.markQuestionConsumed(questionID: item.questionID)
        }
        refresh()
    }
}
