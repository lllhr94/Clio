import AgentKit
import Craft
import PhotosUI
import SwiftUI
import UIKit

enum ChatTrackMode: String, CaseIterable, Hashable {
    case formal
    case casual

    var titleKey: String {
        switch self {
        case .formal: return "casual.trackFormal"
        case .casual: return "casual.trackCasual"
        }
    }
}

@MainActor
enum CasualTrackDoor {
    static var pendingBotID: String?
}

extension Notification.Name {
    static let clioOpenCasualTrack = Notification.Name("clio.openCasualTrack")
}

/// Dedicated lightweight Casual Track view (`Team/casual/<botID>.jsonl`) with 2.5s burst merging,
/// zero automatic memory/experience writes, custom user-imported stickers (0 presets, max 1/turn),
/// quiet draft restoration on track switch, and inline handoff confirmation into formal chat.
struct CasualChatView: View {
    @ObservedObject var team: TeamModel
    let bot: BotInfo
    let onSwitchToFormal: () -> Void
    let onHandoffToFormal: (String) -> Void

    @StateObject private var controller: CasualTrackController
    @StateObject private var stickers = StickerPackStore.shared
    @State private var draftInput = ""
    @State private var showingStickers = false
    @State private var pendingHandoffSummary: String?
    @State private var reviewCandidateText: String?
    @State private var selectedPhotoItem: PhotosPickerItem?

    init(
        team: TeamModel,
        bot: BotInfo,
        onSwitchToFormal: @escaping () -> Void,
        onHandoffToFormal: @escaping (String) -> Void
    ) {
        self.team = team
        self.bot = bot
        self.onSwitchToFormal = onSwitchToFormal
        self.onHandoffToFormal = onHandoffToFormal
        _controller = StateObject(wrappedValue: CasualTrackController(botID: bot.id))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Ink.Space.m) {
                        if !controller.reconcileBatches.isEmpty {
                            reconcileBanner
                        }
                        if controller.entries.isEmpty && controller.pendingBurstSegments.isEmpty {
                            Text(L.format("casual.emptyHint", bot.name))
                                .font(Ink.secondary)
                                .foregroundStyle(Ink.inkSoft)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(Ink.Space.l)
                                .paperCard()
                        } else {
                            ForEach(controller.entries) { entry in
                                bubbleRow(entry)
                                    .id(entry.id)
                            }
                            if !controller.pendingBurstSegments.isEmpty {
                                pendingBurstPreview
                                    .id("casual-pending-burst")
                            }
                        }
                        if let pendingHandoffSummary {
                            HandoffConfirmCard(
                                summary: pendingHandoffSummary,
                                botName: bot.name,
                                onConfirm: {
                                    let text = pendingHandoffSummary
                                    self.pendingHandoffSummary = nil
                                    controller.cancelForTrackSwitch()
                                    onHandoffToFormal(text)
                                },
                                onDismiss: { self.pendingHandoffSummary = nil }
                            )
                        }
                    }
                    .padding(.horizontal, Ink.Space.page)
                    .padding(.vertical, Ink.Space.l)
                }
                .onChange(of: controller.entries.last?.id) { _, lastID in
                    if let lastID {
                        withAnimation(.smooth) { proxy.scrollTo(lastID, anchor: .bottom) }
                    }
                }
            }

            composerBar
        }
        .background(Ink.paper.ignoresSafeArea())
        .onAppear {
            if let restored = controller.restoreQuietDraftIfNeeded(), draftInput.isEmpty {
                draftInput = restored
            }
        }
        .task(id: bot.id) {
            await controller.dispatchRecoveredInitialBatches(team: team, bot: bot) { suggested in
                pendingHandoffSummary = suggested
            }
        }
        .onDisappear {
            // Leaving Casual Track cancels the 2.5s timer and retains uncommitted text quietly in Canonical draft.
            controller.cancelForTrackSwitch(extraUnsentInput: draftInput)
        }
        .sheet(isPresented: $showingStickers) {
            stickerPickerSheet
                .detentPaperBackdrop(initial: .medium, detents: [.medium, .large])
        }
        .alert(
            L.t("casual.promoteMemoryTitle"),
            isPresented: Binding(
                get: { reviewCandidateText != nil },
                set: { if !$0 { reviewCandidateText = nil } }
            )
        ) {
            TextField(
                L.t("casual.promoteMemoryPlaceholder"),
                text: Binding(
                    get: { reviewCandidateText ?? "" },
                    set: { reviewCandidateText = $0 }
                )
            )
            Button(L.t("actions.cancel"), role: .cancel) { reviewCandidateText = nil }
            Button(L.t("casual.promoteMemoryConfirm")) {
                let text = (reviewCandidateText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                reviewCandidateText = nil
                guard !text.isEmpty,
                      CasualTrackPolicy.allowsExplicitUserPromotionToMemoryCandidate(userInitiated: true) else { return }
                _ = team.importMemoryCandidates([(text: text, layer: .surface, kind: "note", topic: "casual")])
            }
        } message: {
            Text(L.t("casual.promoteMemoryMessage"))
        }
        .task(id: selectedPhotoItem) {
            guard let picked = selectedPhotoItem else { return }
            defer { selectedPhotoItem = nil }
            guard let data = try? await picked.loadTransferable(type: Data.self) else { return }
            let pack = stickers.packs.first ?? stickers.createPack(name: L.t("casual.defaultStickerPack"))
            _ = stickers.importSticker(imageData: data, label: "", into: pack.id)
        }
    }

    private var pendingBurstPreview: some View {
        HStack {
            Spacer(minLength: Ink.Space.xxl)
            VStack(alignment: .trailing, spacing: Ink.Space.xs) {
                Text(controller.pendingBurstSegments.joined(separator: "\n"))
                    .font(Ink.reading)
                    .foregroundStyle(Ink.inkSoft)
                    .padding(.horizontal, Ink.Space.m)
                    .padding(.vertical, Ink.Space.s)
                    .background(
                        Ink.bubble.opacity(0.65),
                        in: .rect(cornerRadius: Ink.Radius.small, style: .continuous)
                    )
                Text(L.t("casual.mergingHint"))
                    .font(.system(size: Ink.Size.micro))
                    .foregroundStyle(Ink.inkFaint)
            }
        }
    }

    private var reconcileBanner: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            Text(L.t("casual.reconcileTitle"))
                .font(Ink.label)
                .foregroundStyle(Ink.warn)
            ForEach(controller.reconcileBatches) { batch in
                HStack(spacing: Ink.Space.s) {
                    Text(batch.combinedText)
                        .font(Ink.footnote)
                        .foregroundStyle(Ink.inkSoft)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    Button(L.t("casual.reconcileResend")) {
                        controller.explicitlyResendReconciledBatch(batch, team: team, bot: bot)
                    }
                    .font(.system(size: Ink.Size.micro, weight: .semibold))
                    .foregroundStyle(Ink.accent)
                    Button(L.t("casual.reconcileDiscard"), role: .destructive) {
                        controller.discardReconciledBatch(batch)
                    }
                    .font(.system(size: Ink.Size.micro, weight: .medium))
                }
            }
        }
        .padding(Ink.Space.m)
        .paperCard()
    }

    private func bubbleRow(_ entry: CasualEntry) -> some View {
        let isUser = entry.role == .user
        return HStack {
            if isUser { Spacer(minLength: Ink.Space.xxl) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: Ink.Space.xs) {
                if let stickerID = entry.stickerID, let uiImage = stickers.image(for: stickerID) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 132, maxHeight: 132)
                        .clipShape(.rect(cornerRadius: Ink.Radius.small, style: .continuous))
                }
                if !entry.text.isEmpty {
                    Text(entry.text)
                        .font(Ink.reading)
                        .foregroundStyle(Ink.ink)
                        .padding(.horizontal, Ink.Space.m)
                        .padding(.vertical, Ink.Space.s)
                        .background(
                            isUser ? Ink.bubble : Ink.paperRaised,
                            in: .rect(cornerRadius: Ink.Radius.small, style: .continuous)
                        )
                }
            }
            .contextMenu {
                if !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(L.t("casual.promoteMemoryCandidate"), systemImage: "bookmark") {
                        reviewCandidateText = entry.text
                    }
                    Button(L.t("casual.handoffAction"), systemImage: "arrow.uturn.forward") {
                        pendingHandoffSummary = entry.text
                    }
                }
                Button(L.t("actions.delete"), systemImage: "trash", role: .destructive) {
                    controller.permanentlyDelete(entryID: entry.id)
                }
            }
            if !isUser { Spacer(minLength: Ink.Space.xxl) }
        }
    }

    private var composerBar: some View {
        HStack(spacing: Ink.Space.s) {
            Button {
                Haptics.light()
                showingStickers = true
            } label: {
                Image(systemName: "face.smiling")
                    .font(.system(size: Ink.Size.body, weight: .medium))
                    .foregroundStyle(Ink.inkSoft)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L.t("casual.stickersTitle"))

            TextField(L.format("casual.inputPlaceholder", bot.name), text: $draftInput, axis: .vertical)
                .lineLimit(1...4)
                .font(Ink.reading)
                .padding(.horizontal, Ink.Space.m)
                .padding(.vertical, Ink.Space.s)
                .background(Ink.paperRaised, in: Capsule(style: .continuous))

            Button {
                let text = draftInput.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                draftInput = ""
                Haptics.light()
                controller.enqueueBurstMessage(text, team: team, bot: bot) { suggested in
                    pendingHandoffSummary = suggested
                }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: Ink.Size.title))
                    .foregroundStyle(draftInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Ink.inkFaint : Ink.accent)
            }
            .buttonStyle(.plain)
            .disabled(draftInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, Ink.Space.page)
        .padding(.vertical, Ink.Space.s)
        .background(Ink.paper)
    }

    private var stickerPickerSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Ink.Space.l) {
                    if stickers.packs.allSatisfy({ $0.items.isEmpty }) {
                        Text(L.t("casual.stickersEmpty"))
                            .font(Ink.secondary)
                            .foregroundStyle(Ink.inkSoft)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Ink.Space.l)
                            .paperCard()
                    } else {
                        ForEach(stickers.packs) { pack in
                            if !pack.items.isEmpty {
                                VStack(alignment: .leading, spacing: Ink.Space.s) {
                                    Text(pack.name).font(Ink.label).foregroundStyle(Ink.inkSoft)
                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: Ink.Space.s)], spacing: Ink.Space.s) {
                                        ForEach(pack.items) { item in
                                            Button {
                                                if controller.sendSticker(item.id) {
                                                    showingStickers = false
                                                }
                                            } label: {
                                                if let img = stickers.image(for: item.id) {
                                                    Image(uiImage: img)
                                                        .resizable()
                                                        .scaledToFill()
                                                        .frame(width: 72, height: 72)
                                                        .clipShape(.rect(cornerRadius: Ink.Radius.small, style: .continuous))
                                                }
                                            }
                                            .buttonStyle(.plain)
                                            .disabled(!controller.canSendStickerInCurrentTurn)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        Label(L.t("casual.importSticker"), systemImage: "photo.badge.plus")
                    }
                    .buttonStyle(WideButtonStyle(filled: false))
                }
                .padding(.horizontal, Ink.Space.page)
                .padding(.vertical, Ink.Space.l)
            }
            .background(Ink.paper.ignoresSafeArea())
            .navigationTitle(L.t("casual.stickersTitle"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L.t("actions.done")) { showingStickers = false }
                }
            }
        }
    }
}

/// Process-wide single-shot cold-start coordinator for Casual Track outbox batches.
/// Ensures `reconcileOnColdStart()` runs strictly ONCE on app launch rather than every time a Casual page opens,
/// so opening companion B's Casual page can NEVER flip companion A's live `.inFlight` batch to `.needsReconcile`.
final class CasualColdStartCoordinator: @unchecked Sendable {
    static let shared = CasualColdStartCoordinator()

    private let lock = NSLock()
    private var hasReconciled = false
    private var pendingInitialByBot: [String: [CasualOutboxBatch]] = [:]

    func reconcileOnceOnLaunch(store: CasualTrackStore = CasualTrackController.sharedStore) {
        let shouldRun = lock.withLock { () -> Bool in
            guard !hasReconciled else { return false }
            hasReconciled = true
            return true
        }
        guard shouldRun else { return }
        let recovery = store.reconcileOnColdStart()
        let grouped = Dictionary(grouping: recovery.batchesReadyForInitialSend, by: \.botID)
        lock.withLock {
            pendingInitialByBot = grouped
        }
    }

    func takeRecoveredInitialBatches(for botID: String) -> [CasualOutboxBatch] {
        lock.withLock {
            pendingInitialByBot.removeValue(forKey: botID) ?? []
        }
    }

    func resetForTesting() {
        lock.withLock {
            hasReconciled = false
            pendingInitialByBot.removeAll()
        }
    }
}

/// Owns the per-`(botID, casualSessionID)` `CasualSendQueue` independently of keyboard/focus callbacks.
@MainActor
final class CasualTrackController: ObservableObject {
    nonisolated static let sharedStore: CasualTrackStore = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dbURL = appSupport.appendingPathComponent("ClioIndex", isDirectory: true).appendingPathComponent("clio-casual.db")
        return CasualTrackStore(canonicalTeamDirectory: Disk.root, projectionDatabaseURL: dbURL, isWriteFrozen: { Disk.frozen })
    }()

    let botID: String
    let store: CasualTrackStore
    let queue: CasualSendQueue
    private let coldStartCoordinator: CasualColdStartCoordinator?
    @Published private(set) var entries: [CasualEntry] = []
    @Published private(set) var pendingBurstSegments: [String] = []
    @Published private(set) var reconcileBatches: [CasualOutboxBatch] = []
    @Published private(set) var stickersUsedInCurrentTurn = 0
    private var recoveredInitialBatches: [CasualOutboxBatch] = []

    var canSendStickerInCurrentTurn: Bool {
        CasualTrackPolicy.allowsSticker(usedInCurrentTurn: stickersUsedInCurrentTurn, isCasualTrack: true)
    }

    init(
        botID: String,
        store: CasualTrackStore? = nil,
        coordinator: CasualColdStartCoordinator? = nil,
        mergeWindowSeconds: TimeInterval = CasualTrackPolicy.mergeWindowSeconds
    ) {
        self.botID = botID
        let resolvedStore = store ?? Self.sharedStore
        self.store = resolvedStore
        self.coldStartCoordinator = coordinator ?? (resolvedStore === Self.sharedStore ? CasualColdStartCoordinator.shared : nil)
        self.queue = CasualSendQueue(botID: botID, store: resolvedStore, mergeWindowSeconds: mergeWindowSeconds)
        reload()
    }

    func reload() {
        entries = store.entries(for: botID)
        if let coordinator = coldStartCoordinator {
            coordinator.reconcileOnceOnLaunch(store: store)
            let newlyClaimed = coordinator.takeRecoveredInitialBatches(for: botID)
            if !newlyClaimed.isEmpty {
                let existingIDs = Set(recoveredInitialBatches.map(\.batchID))
                recoveredInitialBatches.append(contentsOf: newlyClaimed.filter { !existingIDs.contains($0.batchID) })
            }
        } else {
            let queued = store.outboxBatches(for: botID).filter { $0.state == .queuedBeforeSend }
            let existingIDs = Set(recoveredInitialBatches.map(\.batchID))
            recoveredInitialBatches.append(contentsOf: queued.filter { !existingIDs.contains($0.batchID) })
        }
        reconcileBatches = store.outboxBatches(for: botID).filter { $0.state == .needsReconcile }
    }

    func restoreQuietDraftIfNeeded() -> String? {
        guard let draft = store.loadDraft(botID: botID), !draft.isEmpty else { return nil }
        return draft.combinedText
    }

    func saveComposerDraft(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? store.saveDraft(CasualDraft(botID: botID, casualSessionID: queue.casualSessionID, segments: [trimmed]))
    }

    /// Cancels any active 2.5s burst countdown and preserves buffered + composer text quietly into the Canonical draft.
    func cancelForTrackSwitch(extraUnsentInput: String = "") {
        let buffered = queue.cancelForTrackSwitch()?.segments ?? []
        pendingBurstSegments = []
        let trimmedExtra = extraUnsentInput.trimmingCharacters(in: .whitespacesAndNewlines)
        var combined = buffered
        if !trimmedExtra.isEmpty && combined.last != trimmedExtra {
            combined.append(trimmedExtra)
        }
        if !combined.isEmpty {
            try? store.saveDraft(CasualDraft(botID: botID, casualSessionID: queue.casualSessionID, segments: combined))
        }
    }

    func permanentlyDelete(entryID: String) {
        try? store.permanentlyDelete(entryID: entryID, botID: botID)
        entries = store.entries(for: botID)
    }

    @discardableResult
    func sendSticker(_ stickerID: String) -> Bool {
        guard canSendStickerInCurrentTurn else { return false }
        let entry = CasualEntry(botID: botID, role: .user, text: "", stickerID: stickerID)
        guard (try? store.appendEntry(entry)) == true else { return false }
        stickersUsedInCurrentTurn += 1
        entries = store.entries(for: botID)
        return true
    }

    func enqueueBurstMessage(
        _ text: String,
        team: TeamModel,
        bot: BotInfo,
        onSuggestHandoff: @escaping @MainActor (String) -> Void
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingBurstSegments.append(trimmed)
        try? queue.enqueue(trimmed) { [weak self, weak team] batch in
            guard let self, let team else { return }
            await self.dispatchBatch(batch, team: team, bot: bot, onSuggestHandoff: onSuggestHandoff)
        }
    }

    /// Cold-start recovery for Window #2 (`queued_before_send`): advances each batch via Step 2 (`in_flight`)
    /// BEFORE launching network dispatch, sending at most once without dropping it.
    func dispatchRecoveredInitialBatches(
        team: TeamModel,
        bot: BotInfo,
        onSuggestHandoff: @escaping @MainActor (String) -> Void
    ) async {
        let batches = recoveredInitialBatches
        recoveredInitialBatches = []
        for queued in batches {
            if let inFlight = try? store.commitStep2MarkInFlight(batchID: queued.batchID) {
                await dispatchBatch(inFlight, team: team, bot: bot, onSuggestHandoff: onSuggestHandoff)
            }
        }
    }

    @discardableResult
    func explicitlyResendReconciledBatch(_ batch: CasualOutboxBatch, team: TeamModel, bot: BotInfo, dispatchNow: Bool = true) -> Bool {
        let fresh = CasualOutboxBatch(
            botID: botID,
            casualSessionID: queue.casualSessionID,
            segments: batch.segments,
            state: .queuedBeforeSend,
            trackEpoch: queue.currentTrackEpoch,
            supersedesBatchID: batch.batchID
        )
        // Atomically persist `fresh` AND close `batch` BEFORE dispatching; if closing fails, `fresh` is rolled back.
        let replacement: CasualOutboxBatch
        do {
            replacement = try store.replaceReconciledBatch(oldBatchID: batch.batchID, with: fresh)
        } catch {
            Diag.note("没能安全替换重发的闲谈批次（\(error.localizedDescription)），已保留原待核对记录。")
            return false
        }
        reconcileBatches.removeAll { $0.batchID == batch.batchID }
        if dispatchNow {
            Task { @MainActor [weak self, weak team] in
                guard let self, let team else { return }
                if let inFlight = try? self.store.commitStep2MarkInFlight(batchID: replacement.batchID) {
                    await self.dispatchBatch(inFlight, team: team, bot: bot, onSuggestHandoff: { _ in })
                }
            }
        }
        return true
    }

    func discardReconciledBatch(_ batch: CasualOutboxBatch) {
        _ = try? store.markOutboxCompleted(batchID: batch.batchID)
        reconcileBatches.removeAll { $0.batchID == batch.batchID }
    }

    private func recordUserBatchEntryIfNeeded(_ batch: CasualOutboxBatch) {
        pendingBurstSegments = []
        let userEntryID = "u-\(batch.batchID)"
        guard !entries.contains(where: { $0.id == userEntryID }) else { return }
        let userEntry = CasualEntry(
            id: userEntryID,
            botID: botID,
            role: .user,
            text: batch.combinedText,
            batchID: batch.batchID
        )
        _ = try? store.appendEntry(userEntry)
        entries = store.entries(for: botID)
    }

    private func dispatchBatch(
        _ batch: CasualOutboxBatch,
        team: TeamModel,
        bot: BotInfo,
        onSuggestHandoff: @escaping @MainActor (String) -> Void
    ) async {
        recordUserBatchEntryIfNeeded(batch)

        // Casual Track uses the companion's flagship/default model, filtered skills (no quiet-musing/user-guide),
        // and strictly ZERO automatic memory or experience writes.
        guard let found = team.resolveActive(bot.model ?? team.settings.defaultModel)
                ?? team.resolveActive(team.settings.defaultModel),
              let apiKey = await team.readAPIKey(for: found.endpoint), !apiKey.isEmpty else {
            return
        }

        let recentHistory = store.entries(for: botID).suffix(20).compactMap { item -> Message? in
            let body = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return nil }
            return item.role == .user ? .user(body) : .assistant(body)
        }

        let allowedSkills = CasualTrackPolicy.filterSkills(SkillShelf.enabled, id: \.skill.name)
        let skillHint = allowedSkills.isEmpty ? "" : "\n可用技能：" + allowedSkills.map(\.skill.name).joined(separator: "、")
        let systemPrompt = "你是「\(bot.name)」，当前在轻松闲谈轨和用户聊天。语气温和自然、简短分句；禁止自动改写记忆或执行重型任务；如果用户提出需要写代码、改文件或长流程处理的事项，先友好回应并建议转入正式对话。" + skillHint

        let provider = found.endpoint.provider(key: apiKey, stableSystemPrefix: systemPrompt)
        var agent = Agent(provider: provider, model: found.model, system: systemPrompt, tools: [])
        agent.thinking = .auto
        agent.customHeaders = found.endpoint.customNonSecretHeaders

        final class ReplyBuffer: @unchecked Sendable {
            private let lock = NSLock()
            private var streamed = ""
            private var finalMessage: String?
            func append(_ chunk: String) { lock.withLock { streamed += chunk } }
            func setFinal(_ text: String) { lock.withLock { finalMessage = text } }
            var text: String { lock.withLock { finalMessage ?? streamed } }
        }

        let prompt = batch.combinedText
        let buffer = ReplyBuffer()
        let history = Array(recentHistory.dropLast()) + [.user(prompt)]
        do {
            try await agent.run(history: history) { event in
                switch event {
                case .text(let chunk):
                    buffer.append(chunk)
                case .message(let msg) where msg.role == .assistant && !msg.text.isEmpty:
                    buffer.setFinal(msg.text)
                default:
                    break
                }
            }
        } catch {
            // Leave outbox uncompleted on transient failure so user can reconcile cleanly.
            return
        }
        let reply = buffer.text
        guard persistReplyAndComplete(batchID: batch.batchID, reply: reply) else {
            return
        }

        let heavyHints = ["写代码", "改文件", "重型", "正式对话", "转入正式"]
        if heavyHints.contains(where: { prompt.contains($0) || reply.contains($0) }) {
            onSuggestHandoff(prompt)
        }
    }

    /// Atomically persists all reply segments BEFORE marking the outbox batch `.completed`.
    /// Returns `false` if persistence failed, leaving the outbox batch uncompleted so nothing is lost.
    @discardableResult
    func persistReplyAndComplete(batchID: String, reply: String) -> Bool {
        let segments = reply
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let replyEntries = segments.enumerated().map { idx, seg in
            CasualEntry(
                id: "a-\(batchID)-\(idx)",
                botID: botID,
                role: .assistant,
                text: seg,
                batchID: batchID
            )
        }
        do {
            _ = try store.appendEntriesAndCompleteOutbox(entries: replyEntries, batchID: batchID)
        } catch {
            Diag.note("没能保存闲谈回复（\(error.localizedDescription)），已保留发件箱待核对。")
            return false
        }
        stickersUsedInCurrentTurn = 0
        entries = store.entries(for: botID)
        return true
    }
}
