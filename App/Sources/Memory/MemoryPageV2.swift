import Craft
import SwiftUI

enum MemoryV2Copy {
    static let commonKinds: [String] = [
        "fact", "preference", "project", "rule", "goal", "experience", "note",
    ]

    static func layerTitle(_ layer: MemoryLayer) -> String {
        switch layer {
        case .pinned: return L.t("memoryV2.filterPinned")
        case .surface: return L.t("memoryV2.filterSurface")
        case .deep: return L.t("memoryV2.filterDeep")
        case .archived: return L.t("memoryV2.filterArchived")
        }
    }

    static func layerHint(_ layer: MemoryLayer) -> String {
        switch layer {
        case .pinned: return L.t("memoryV2.layerHintPinned")
        case .surface: return L.t("memoryV2.layerHintSurface")
        case .deep: return L.t("memoryV2.layerHintDeep")
        case .archived: return L.t("memoryV2.layerHintArchived")
        }
    }

    static func layerTint(_ layer: MemoryLayer) -> Color {
        switch layer {
        case .pinned: return Ink.accent
        case .surface: return Ink.ok
        case .deep: return Ink.inkSoft
        case .archived: return Ink.inkFaint
        }
    }

    static func layerWash(_ layer: MemoryLayer) -> Color {
        switch layer {
        case .pinned: return Ink.accentWash
        case .surface: return Ink.ok.opacity(0.14)
        case .deep: return Ink.rule.opacity(0.6)
        case .archived: return Ink.rule.opacity(0.4)
        }
    }

    static func layerIcon(_ layer: MemoryLayer) -> String {
        switch layer {
        case .pinned: return "pin.fill"
        case .surface: return "tray.fill"
        case .deep: return "clock.arrow.circlepath"
        case .archived: return "archivebox.fill"
        }
    }

    static func kindTitle(_ kind: String) -> String {
        switch kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "fact", "": return L.t("memoryV2.kindFact")
        case "preference": return L.t("memoryV2.kindPreference")
        case "project": return L.t("memoryV2.kindProject")
        case "rule": return L.t("memoryV2.kindRule")
        case "goal": return L.t("memoryV2.kindGoal")
        case "experience": return L.t("memoryV2.kindExperience")
        case "note": return L.t("memoryV2.kindNote")
        default: return kind
        }
    }

    static func provenanceText(for record: MemoryRecord, bots: [BotInfo]) -> String {
        if let botID = record.byBot, !botID.isEmpty {
            let name = bots.first(where: { $0.id == botID })?.name ?? botID
            return L.format("memoryV2.botWrittenPrefix", name)
        }
        if record.automatic && !record.editedByUser {
            return L.t("memoryV2.autoBadge")
        }
        return L.t("memoryV2.userBadge")
    }
}

struct MemoryBadgePill: View {
    let text: String
    var foreground: Color = Ink.inkSoft
    var background: Color = Ink.rule.opacity(0.55)

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Text(text)
            .font(.system(size: Ink.Size.micro, weight: .medium))
            .foregroundStyle(foreground)
            .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
            .padding(.horizontal, Ink.Space.s)
            .padding(.vertical, Ink.Space.xs / 2)
            .background(background, in: Capsule())
    }
}

struct MemoryPageV2: View {
    @ObservedObject var team: TeamModel
    var showsDone = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    private enum LayerFilter: String, CaseIterable, Identifiable {
        case all, pinned, surface, deep, archived

        var id: Self { self }

        var layer: MemoryLayer? {
            switch self {
            case .all: return nil
            case .pinned: return .pinned
            case .surface: return .surface
            case .deep: return .deep
            case .archived: return .archived
            }
        }

        var title: String {
            switch self {
            case .all: return L.t("memoryV2.filterAll")
            case .pinned: return L.t("memoryV2.filterPinned")
            case .surface: return L.t("memoryV2.filterSurface")
            case .deep: return L.t("memoryV2.filterDeep")
            case .archived: return L.t("memoryV2.filterArchived")
            }
        }
    }

    @State private var query = ""
    @State private var filter: LayerFilter = .all
    @State private var editingRecord: MemoryRecord?
    @State private var deletingRecord: MemoryRecord?
    @State private var showingImport = false
    @State private var showingMirrors = false
    @State private var refreshRevision = 0

    @State private var cachedSnapshotByID: [String: MemoryRecord] = [:]
    @State private var cachedArchived: [MemoryRecord] = []
    @State private var cachedPinnedIDs: Set<String> = []
    @State private var cachedAllRecords: [MemoryRecord] = []
    @State private var snapshotToken = 0
    @State private var mutationError: String?

    private var availableFilters: [LayerFilter] {
        team.keeping ? LayerFilter.allCases : [.all, .surface, .deep]
    }

    private func computeAllRecords() -> [MemoryRecord] {
        var combined: [MemoryRecord] = []
        var seenIDs = Set<String>()
        for memory in team.memories {
            seenIDs.insert(memory.id)
            if var snapshot = cachedSnapshotByID[memory.id] {
                snapshot.text = memory.text
                if team.keeping && cachedPinnedIDs.contains(memory.id) {
                    snapshot.layer = .pinned
                    snapshot.pinned = true
                } else {
                    snapshot.layer = memory.deep == true ? .deep : .surface
                    snapshot.pinned = false
                }
                combined.append(snapshot)
            } else {
                let pinned = team.keeping && cachedPinnedIDs.contains(memory.id)
                let fallbackLayer: MemoryLayer = pinned ? .pinned : (memory.deep == true ? .deep : .surface)
                combined.append(
                    MemoryRecord(
                        id: memory.id,
                        text: memory.text,
                        layer: fallbackLayer,
                        pinned: pinned,
                        createdAtMs: memory.at,
                        usedAtMs: memory.used,
                        byBot: memory.by,
                        automatic: memory.automatic == true,
                        editedByUser: memory.editedByUser == true
                    )
                )
            }
        }
        if team.keeping {
            for archived in cachedArchived where seenIDs.insert(archived.id).inserted {
                combined.append(archived)
            }
        }
        return combined.sorted { lhs, rhs in
            let lTime = max(lhs.usedAtMs ?? 0, lhs.createdAtMs)
            let rTime = max(rhs.usedAtMs ?? 0, rhs.createdAtMs)
            if lTime != rTime { return lTime > rTime }
            return lhs.id < rhs.id
        }
    }

    private func matchesQuery(_ record: MemoryRecord, trimmedQuery: String) -> Bool {
        if trimmedQuery.isEmpty {
            return true
        }
        if record.text.localizedCaseInsensitiveContains(trimmedQuery) {
            return true
        }
        if !record.topic.isEmpty && record.topic.localizedCaseInsensitiveContains(trimmedQuery) {
            return true
        }
        if MemoryV2Copy.kindTitle(record.kind).localizedCaseInsensitiveContains(trimmedQuery) {
            return true
        }
        if MemoryV2Copy.provenanceText(for: record, bots: team.bots)
            .localizedCaseInsensitiveContains(trimmedQuery) {
            return true
        }
        return false
    }

    private func count(for layer: MemoryLayer, in records: [MemoryRecord]) -> Int {
        records.reduce(0) { $0 + ($1.layer == layer ? 1 : 0) }
    }

    var body: some View {
        let recordsSnapshot = cachedAllRecords
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryMatched = recordsSnapshot.filter { matchesQuery($0, trimmedQuery: trimmedQuery) }
        let effectiveFilter = availableFilters.contains(filter) ? filter : .all
        let visibleRecords = queryMatched.filter { record in
            if let targetLayer = effectiveFilter.layer {
                return record.layer == targetLayer
            }
            return true
        }

        return contentScrollView(
            allRecords: recordsSnapshot,
            visible: visibleRecords,
            effectiveFilter: effectiveFilter,
            otherLayerMatchCount: effectiveFilter == .all ? 0 : queryMatched.count,
            trimmedQuery: trimmedQuery
        )
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .background(Ink.paper.ignoresSafeArea())
        .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: L.t("memoryV2.searchPrompt")
        )
        .navigationTitle(L.t("nav.memory"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarItems }
        .onAppear {
            if cachedAllRecords.isEmpty && !team.memories.isEmpty {
                cachedAllRecords = computeAllRecords()
            }
        }
        .task {
            await reloadSnapshots()
        }
        .onChange(of: team.memories) { _, _ in
            cachedAllRecords = computeAllRecords()
            Task { await reloadSnapshots() }
        }
        .onChange(of: refreshRevision) { _, _ in
            Task { await reloadSnapshots() }
        }
        .sheet(item: $editingRecord) { record in
            MemoryDetailSheet(team: team, record: record) { targetLayer in
                withAnimation(Ink.Motion.settle) {
                    if let targetLayer {
                        applyLocalLayerTransition(id: record.id, to: targetLayer)
                    } else {
                        cachedPinnedIDs.remove(record.id)
                        cachedSnapshotByID.removeValue(forKey: record.id)
                        cachedArchived.removeAll { $0.id == record.id }
                        cachedAllRecords = computeAllRecords()
                    }
                    refreshRevision &+= 1
                }
            }
        }
        .sheet(isPresented: $showingImport) {
            MemoryImportSheet(team: team) { importedCount in
                refreshRevision &+= 1
                ToastCenter.shared.show(
                    L.format("memoryV2.importedToast", importedCount),
                    symbol: "checkmark.circle.fill",
                    tint: Ink.ok
                )
            }
        }
        .sheet(isPresented: $showingMirrors) {
            MemoryMirrorViewerSheet(team: team)
        }
        .confirmationDialog(
            L.t("memoryV2.deleteConfirmTitle"),
            isPresented: Binding(
                get: { deletingRecord != nil },
                set: { if !$0 { deletingRecord = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L.t("actions.delete"), role: .destructive) {
                if let target = deletingRecord {
                    let targetID = target.id
                    Task {
                        do {
                            let ok = try await team.deleteMemoryOffMain(targetID)
                            guard ok else {
                                Haptics.lock()
                                return
                            }
                            mutationError = nil
                            withAnimation(Ink.Motion.settle) {
                                cachedPinnedIDs.remove(targetID)
                                cachedSnapshotByID.removeValue(forKey: targetID)
                                cachedArchived.removeAll { $0.id == targetID }
                                cachedAllRecords = computeAllRecords()
                                refreshRevision &+= 1
                            }
                            Haptics.thud()
                        } catch {
                            Haptics.lock()
                            mutationError = error.localizedDescription
                        }
                    }
                }
                deletingRecord = nil
            }
            Button(L.t("actions.cancel"), role: .cancel) {
                deletingRecord = nil
            }
        } message: {
            Text(L.t("errors.cannotUndo"))
        }
    }

    private func contentScrollView(
        allRecords recordsSnapshot: [MemoryRecord],
        visible: [MemoryRecord],
        effectiveFilter: LayerFilter,
        otherLayerMatchCount: Int,
        trimmedQuery: String
    ) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Ink.Space.xl) {
                if team.phase == .demo {
                    noticeBanner(L.t("settings.demoData"), tint: Ink.inkSoft)
                } else if !team.canMutateMemoryState {
                    noticeBanner(L.t("memoryV2.readOnlyNotice"), tint: Ink.warn)
                }

                if let mutationError {
                    noticeBanner(mutationError, tint: Ink.stop)
                }

                layerFilterSection(recordsSnapshot, effectiveFilter: effectiveFilter)
                quickAddAndToolsSection
                memoryListSection(
                    allCount: recordsSnapshot.count,
                    visible: visible,
                    effectiveFilter: effectiveFilter,
                    otherLayerMatchCount: otherLayerMatchCount,
                    trimmedQuery: trimmedQuery
                )
                MemoryReviewHistory(records: team.memoryReviews)
            }
            .padding(.horizontal, Ink.Space.page)
            .padding(.vertical, Ink.Space.l)
        }
        .scrollEdgeEffectStyle(.soft, for: .vertical)
    }

    // MARK: - Snapshot Sync

    private func reloadSnapshots() async {
        snapshotToken &+= 1
        let token = snapshotToken
        guard team.keeping else {
            cachedSnapshotByID = [:]
            cachedArchived = []
            cachedPinnedIDs = []
            cachedAllRecords = computeAllRecords()
            return
        }
        let all = await Task.detached(priority: .userInitiated) {
            MemoryStoreBridge.shared.recordsSnapshot()
        }.value
        guard token == snapshotToken else { return }
        var byID: [String: MemoryRecord] = [:]
        var archived: [MemoryRecord] = []
        var pins = Set<String>()
        for record in all {
            byID[record.id] = record
            if record.layer == .archived {
                archived.append(record)
            } else if record.layer == .pinned {
                pins.insert(record.id)
            }
        }
        cachedSnapshotByID = byID
        cachedArchived = archived
        cachedPinnedIDs = pins
        cachedAllRecords = computeAllRecords()
    }

    // MARK: - Toolbar & Banners

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                Haptics.light()
                showingMirrors = true
            } label: {
                Image(systemName: "doc.plaintext")
            }
            .accessibilityLabel(L.t("memoryV2.mirrorsButton"))

            Button {
                Haptics.light()
                showingImport = true
            } label: {
                Image(systemName: "tray.and.arrow.down")
            }
            .accessibilityLabel(L.t("memoryV2.importButton"))

            if showsDone {
                Button(L.t("actions.done")) {
                    Haptics.light()
                    dismiss()
                }
            }
        }
    }

    private func noticeBanner(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: Ink.Size.small))
            .foregroundStyle(tint)
            .padding(.horizontal, Ink.Space.l)
            .padding(.vertical, Ink.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .paperCard()
    }

    // MARK: - Filter & Quick-Add

    private func layerFilterSection(_ records: [MemoryRecord], effectiveFilter: LayerFilter) -> some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            if typeSize.isAccessibilitySize {
                WrapLayout(spacing: Ink.Space.s) {
                    ForEach(availableFilters) { option in
                        let selected = effectiveFilter == option
                        Button {
                            Haptics.tick(0.45)
                            filter = option
                        } label: {
                            Text(option.title)
                                .font(.system(size: Ink.Size.sub, weight: selected ? .semibold : .regular))
                                .foregroundStyle(selected ? Ink.paper : Ink.ink)
                                .padding(.horizontal, Ink.Space.m)
                                .padding(.vertical, Ink.Space.xs)
                                .background(selected ? Ink.accent : Ink.rule.opacity(0.45), in: Capsule())
                        }
                        .buttonStyle(TapStyle())
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            } else {
                SlidingCapsuleControl(
                    selection: $filter,
                    options: availableFilters
                ) { $0.title }
                .accessibilityLabel(L.t("memoryV2.layerLabel"))
            }

            let surfaceCount = count(for: .surface, in: records)
            let deepCount = count(for: .deep, in: records)
            if team.keeping {
                let pinnedCount = count(for: .pinned, in: records)
                let archivedCount = count(for: .archived, in: records)
                let totalCount = pinnedCount + surfaceCount + deepCount + archivedCount
                Text(L.format("memoryV2.countsSummary", pinnedCount, surfaceCount, deepCount, archivedCount))
                    .font(.system(size: Ink.Size.small, weight: .medium).monospacedDigit())
                    .foregroundStyle(Ink.inkSoft)
                    .contentTransition(.numericText(value: Double(totalCount)))
                    .animation(Ink.Motion.quick, value: [pinnedCount, surfaceCount, deepCount, archivedCount])
                    .padding(.horizontal, Ink.Space.l)
            } else {
                let totalCount = surfaceCount + deepCount
                Text(L.format("settings.memoryCounts", surfaceCount, deepCount))
                    .font(.system(size: Ink.Size.small, weight: .medium).monospacedDigit())
                    .foregroundStyle(Ink.inkSoft)
                    .contentTransition(.numericText(value: Double(totalCount)))
                    .animation(Ink.Motion.quick, value: [surfaceCount, deepCount])
                    .padding(.horizontal, Ink.Space.l)
            }

            Text(L.format("memoryV2.surfaceLimitNote", TeamModel.surfaceLimit))
                .font(.system(size: Ink.Size.small))
                .foregroundStyle(Ink.inkFaint)
                .padding(.horizontal, Ink.Space.l)
        }
    }

    private var quickAddAndToolsSection: some View {
        MemoryQuickAddCard(
            canMutate: team.canMutateMemoryState,
            onAdd: addQuickMemory,
            onImport: { showingImport = true },
            onMirrors: { showingMirrors = true }
        )
    }

    // MARK: - Memory List

    @ViewBuilder
    private func memoryListSection(
        allCount: Int,
        visible: [MemoryRecord],
        effectiveFilter: LayerFilter,
        otherLayerMatchCount: Int,
        trimmedQuery: String
    ) -> some View {
        if visible.isEmpty {
            emptyStateCard(
                allCount: allCount,
                effectiveFilter: effectiveFilter,
                otherLayerMatchCount: otherLayerMatchCount,
                trimmedQuery: trimmedQuery
            )
        } else if effectiveFilter == .all {
            let layers: [MemoryLayer] = team.keeping ? MemoryLayer.allCases : [.surface, .deep]
            ForEach(layers, id: \.self) { layer in
                let bucket = visible.filter { $0.layer == layer }
                if !bucket.isEmpty {
                    layerBucketCard(title: MemoryV2Copy.layerTitle(layer), records: bucket)
                }
            }
        } else if let targetLayer = effectiveFilter.layer {
            layerBucketCard(title: MemoryV2Copy.layerTitle(targetLayer), records: visible)
        }
    }

    private func layerBucketCard(title: String, records: [MemoryRecord]) -> some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle(title)
            LazyVStack(spacing: 0) {
                ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                    if index > 0 {
                        Kit.rule(inset: Ink.Space.l)
                    }
                    memoryRow(record)
                }
            }
            .clipShape(.rect(cornerRadius: Ink.Radius.card, style: .continuous))
            .paperCard()
        }
    }

    private func memoryRow(_ record: MemoryRecord) -> some View {
        Button {
            Haptics.light()
            editingRecord = record
        } label: {
            VStack(alignment: .leading, spacing: Ink.Space.xs) {
                Text(record.text)
                    .font(.system(size: Ink.Size.sub))
                    .foregroundStyle(record.layer == .archived ? Ink.inkSoft : Ink.ink)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                WrapLayout(spacing: Ink.Space.xs) {
                    MemoryBadgePill(
                        text: MemoryV2Copy.layerTitle(record.layer),
                        foreground: MemoryV2Copy.layerTint(record.layer),
                        background: MemoryV2Copy.layerWash(record.layer)
                    )

                    MemoryBadgePill(
                        text: MemoryV2Copy.provenanceText(for: record, bots: team.bots),
                        foreground: Ink.inkSoft,
                        background: Ink.rule.opacity(0.5)
                    )

                    if !record.kind.isEmpty && record.kind != "fact" {
                        MemoryBadgePill(
                            text: MemoryV2Copy.kindTitle(record.kind),
                            foreground: Ink.inkSoft,
                            background: Ink.rule.opacity(0.45)
                        )
                    }

                    if !record.topic.isEmpty {
                        MemoryBadgePill(
                            text: record.topic,
                            foreground: Ink.inkSoft,
                            background: Ink.rule.opacity(0.4)
                        )
                    }
                }
            }
            .padding(.horizontal, Ink.Space.l)
            .padding(.vertical, Ink.Space.m)
            .background(Ink.paperRaised)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(haptic: false, elevated: true))
        .contextMenu {
            rowContextMenu(record)
        }
    }

    @ViewBuilder
    private func rowContextMenu(_ record: MemoryRecord) -> some View {
        Button(L.t("actions.edit"), systemImage: "pencil") {
            editingRecord = record
        }

        if team.keeping && record.layer != .pinned {
            Button(L.t("memoryV2.moveToPinned"), systemImage: "pin") {
                moveRecord(record.id, to: .pinned)
            }
            .disabled(!team.canMutateMemoryState)
        }

        if record.layer != .surface {
            if record.layer == .archived {
                Button(L.t("memoryV2.restoreToSurface"), systemImage: "arrow.uturn.backward") {
                    restoreRecord(record.id)
                }
                .disabled(!team.canMutateMemoryState)
            } else {
                Button(L.t("memoryV2.moveToSurface"), systemImage: "tray") {
                    moveRecord(record.id, to: .surface)
                }
                .disabled(!team.canMutateMemoryState)
            }
        }

        if record.layer != .deep {
            Button(L.t("memoryV2.moveToDeep"), systemImage: "clock.arrow.circlepath") {
                moveRecord(record.id, to: .deep)
            }
            .disabled(!team.canMutateMemoryState)
        }

        if team.keeping && record.layer != .archived {
            Button(L.t("memoryV2.moveToArchived"), systemImage: "archivebox") {
                moveRecord(record.id, to: .archived)
            }
            .disabled(!team.canMutateMemoryState)
        }

        Divider()

        Button(L.t("actions.delete"), systemImage: "trash", role: .destructive) {
            deletingRecord = record
        }
        .disabled(!team.canMutateMemoryState)
    }

    private func emptyStateCard(
        allCount: Int,
        effectiveFilter: LayerFilter,
        otherLayerMatchCount: Int,
        trimmedQuery: String
    ) -> some View {
        let message: String
        let detail: String?
        if !trimmedQuery.isEmpty {
            if otherLayerMatchCount > 0 {
                message = L.format("memoryV2.searchFoundInOtherLayers", otherLayerMatchCount)
            } else {
                message = L.t("empty.searchNoResult")
            }
            detail = nil
        } else if allCount == 0 {
            message = L.t("empty.memory")
            detail = L.t("settings.memoryEmptyNote")
        } else if effectiveFilter == .archived {
            message = L.t("memoryV2.emptyArchived")
            detail = nil
        } else {
            message = L.t("memoryV2.emptyLayer")
            detail = nil
        }

        return VStack(alignment: .leading, spacing: Ink.Space.s) {
            Text(message)
                .font(.system(size: Ink.Size.sub))
                .foregroundStyle(Ink.inkSoft)
            if let detail {
                Text(detail)
                    .font(.system(size: Ink.Size.small))
                    .foregroundStyle(Ink.inkFaint)
            }
            if !trimmedQuery.isEmpty && otherLayerMatchCount > 0 {
                Button {
                    Haptics.light()
                    withAnimation(Ink.Motion.settle) {
                        filter = .all
                    }
                } label: {
                    Text(L.t("memoryV2.switchToAll"))
                        .font(.system(size: Ink.Size.small, weight: .semibold))
                        .foregroundStyle(Ink.accent)
                        .padding(.horizontal, Ink.Space.m)
                        .padding(.vertical, Ink.Space.xs)
                        .background(Ink.accentWash, in: Capsule())
                }
                .buttonStyle(TapStyle())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Ink.Space.l)
        .paperCard()
    }

    // MARK: - Actions

    private func addQuickMemory(_ words: String) async -> Bool {
        guard !words.isEmpty, team.canMutateMemoryState else { return false }
        do {
            _ = try await team.rememberOffMain(words, by: nil)
            mutationError = nil
            withAnimation(Ink.Motion.settle) {
                cachedAllRecords = computeAllRecords()
                refreshRevision &+= 1
            }
            Haptics.tick(0.6)
            return true
        } catch {
            Haptics.lock()
            mutationError = error.localizedDescription
            return false
        }
    }

    private func moveRecord(_ id: String, to layer: MemoryLayer) {
        guard team.canMutateMemoryState else { return }
        let cachedFallbackLayer = cachedSnapshotByID[id]?.layer ?? (cachedPinnedIDs.contains(id) ? .pinned : .surface)
        Task {
            do {
                let ok: Bool
                let previousLayer: MemoryLayer
                if layer == .archived {
                    let outcome = try await team.archiveMemoryCapturingLayerOffMain(id)
                    ok = outcome.succeeded
                    previousLayer = outcome.previousLayer == .archived ? cachedFallbackLayer : outcome.previousLayer
                } else {
                    ok = try await team.setMemoryLayerOffMain(id, layer)
                    previousLayer = cachedFallbackLayer
                }
                guard ok else {
                    Haptics.lock()
                    return
                }
                mutationError = nil
                withAnimation(Ink.Motion.settle) {
                    applyLocalLayerTransition(id: id, to: layer)
                    refreshRevision &+= 1
                }
                Haptics.tick(0.5)
                if layer == .archived {
                    ToastCenter.shared.show(
                        L.t("homeThreads.archived"),
                        symbol: "archivebox",
                        tint: Ink.inkSoft,
                        actionTitle: L.t("homeThreads.undo"),
                        dedupeKey: "archive-memory-\(id)",
                        duration: 4
                    ) {
                        restoreRecord(id, to: previousLayer)
                    }
                }
            } catch {
                Haptics.lock()
                mutationError = error.localizedDescription
            }
        }
    }

    private func restoreRecord(_ id: String, to targetLayer: MemoryLayer = .surface) {
        guard team.canMutateMemoryState else { return }
        let resolvedLayer: MemoryLayer = targetLayer == .archived ? .surface : targetLayer
        Task {
            do {
                let ok = try await team.restoreMemoryOffMain(id, toLayer: resolvedLayer)
                guard ok else {
                    Haptics.lock()
                    return
                }
                mutationError = nil
                withAnimation(Ink.Motion.settle) {
                    applyLocalLayerTransition(id: id, to: resolvedLayer)
                    refreshRevision &+= 1
                }
                Haptics.tick(0.6)
            } catch {
                Haptics.lock()
                mutationError = error.localizedDescription
            }
        }
    }

    private func applyLocalLayerTransition(id: String, to layer: MemoryLayer) {
        if layer == .pinned {
            cachedPinnedIDs.insert(id)
        } else {
            cachedPinnedIDs.remove(id)
        }
        var updated = cachedSnapshotByID[id] ?? cachedArchived.first(where: { $0.id == id })
        if var record = updated {
            record.layer = layer
            record.pinned = (layer == .pinned)
            cachedSnapshotByID[id] = record
            updated = record
        }
        if layer == .archived {
            if let archived = updated {
                cachedArchived.removeAll { $0.id == id }
                cachedArchived.insert(archived, at: 0)
            }
        } else {
            cachedArchived.removeAll { $0.id == id }
        }
        cachedAllRecords = computeAllRecords()
    }
}

/// Isolated quick-add card owning its own `draft` state so typing never re-evaluates/re-filters `MemoryPageV2`.
private struct MemoryQuickAddCard: View {
    let canMutate: Bool
    let onAdd: (String) async -> Bool
    let onImport: () -> Void
    let onMirrors: () -> Void

    @State private var draft = ""
    @State private var saving = false

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Ink.Space.s) {
                TextField(L.t("settings.memoryPlaceholder"), text: $draft)
                    .font(.system(size: Ink.Size.sub))
                    .foregroundStyle(Ink.ink)
                    .submitLabel(.done)
                    .onSubmit(submit)

                Button(L.t("actions.save"), action: submit)
                    .font(.system(size: Ink.Size.sub, weight: .semibold))
                    .foregroundStyle(Ink.accent)
                    .disabled(saving || trimmedDraft.isEmpty || !canMutate)
            }
            .padding(Ink.Space.l)

            Kit.rule(inset: Ink.Space.l)

            Button {
                Haptics.light()
                onImport()
            } label: {
                RowLabel(
                    "tray.and.arrow.down",
                    tint: Ink.Tile.dai,
                    title: L.t("memoryV2.importActionTitle"),
                    line: L.t("memoryV2.importActionLine")
                )
                .background(Ink.paperRaised)
            }
            .buttonStyle(PressStyle(haptic: false, elevated: true))

            Kit.divider

            Button {
                Haptics.light()
                onMirrors()
            } label: {
                RowLabel(
                    "doc.plaintext",
                    tint: Ink.Tile.teng,
                    title: L.t("memoryV2.mirrorsActionTitle"),
                    line: L.t("memoryV2.mirrorsActionLine")
                )
                .background(Ink.paperRaised)
            }
            .buttonStyle(PressStyle(haptic: false, elevated: true))
        }
        .clipShape(.rect(cornerRadius: Ink.Radius.card, style: .continuous))
        .paperCard()
    }

    private func submit() {
        let words = trimmedDraft
        guard !saving, !words.isEmpty, canMutate else { return }
        saving = true
        draft = ""
        Task {
            let ok = await onAdd(words)
            saving = false
            if !ok && draft.isEmpty {
                draft = words
            }
        }
    }
}

// MARK: - Detail / Edit Sheet

private struct MemoryDetailSheet: View {
    @ObservedObject var team: TeamModel
    let record: MemoryRecord
    var onChanged: (MemoryLayer?) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    @State private var text: String
    @State private var layer: MemoryLayer
    @State private var kind: String
    @State private var topic: String
    @State private var confirmingDelete = false
    @State private var saving = false
    @State private var actionError: String?

    init(team: TeamModel, record: MemoryRecord, onChanged: @escaping (MemoryLayer?) -> Void) {
        self.team = team
        self.record = record
        self.onChanged = onChanged
        _text = State(initialValue: record.text)
        let initialLayer: MemoryLayer
        if team.keeping {
            initialLayer = record.layer
        } else {
            initialLayer = record.layer == .deep ? .deep : .surface
        }
        _layer = State(initialValue: initialLayer)
        _kind = State(initialValue: record.kind.isEmpty ? "fact" : record.kind)
        _topic = State(initialValue: record.topic)
    }

    private var availableLayers: [MemoryLayer] {
        team.keeping ? MemoryLayer.allCases : [.surface, .deep]
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var utf8Count: Int {
        trimmedText.utf8.count
    }

    private var canSave: Bool {
        !trimmedText.isEmpty && team.canMutateMemoryState
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Ink.Space.xl) {
                    if let actionError {
                        Text(actionError)
                            .font(.system(size: Ink.Size.small))
                            .foregroundStyle(Ink.stop)
                            .padding(.horizontal, Ink.Space.l)
                            .padding(.vertical, Ink.Space.m)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .paperCard()
                    }
                    contentSection
                    layerSection
                    if team.keeping {
                        metadataSection
                    }
                    provenanceSection
                    deleteSection
                }
                .padding(.horizontal, Ink.Space.page)
                .padding(.vertical, Ink.Space.l)
            }
            .scrollIndicators(.hidden)
            .scrollEdgeEffectStyle(.soft, for: .vertical)
            .scrollDismissesKeyboard(.interactively)
            .background(Ink.paper.ignoresSafeArea())
            .navigationTitle(L.t("memoryV2.detailTitle"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L.t("actions.cancel")) {
                        dismiss()
                    }
                    .disabled(saving)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L.t("actions.save")) {
                        save()
                    }
                    .fontWeight(.semibold)
                    .disabled(saving || !canSave)
                }
            }
            .interactiveDismissDisabled(saving)
            .confirmationDialog(
                L.t("memoryV2.deleteConfirmTitle"),
                isPresented: $confirmingDelete,
                titleVisibility: .visible
            ) {
                Button(L.t("actions.delete"), role: .destructive) {
                    guard !saving else { return }
                    saving = true
                    actionError = nil
                    let id = record.id
                    Task {
                        do {
                            let ok = try await team.deleteMemoryOffMain(id)
                            guard ok else {
                                saving = false
                                Haptics.lock()
                                return
                            }
                            Haptics.thud()
                            onChanged(nil)
                            dismiss()
                        } catch {
                            saving = false
                            Haptics.lock()
                            actionError = error.localizedDescription
                        }
                    }
                }
                Button(L.t("actions.cancel"), role: .cancel) {}
            } message: {
                Text(L.t("errors.cannotUndo"))
            }
        }
    }

    private var contentSection: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle(L.t("memoryV2.contentLabel"))
            TextEditor(text: $text)
                .font(Ink.reading)
                .foregroundStyle(Ink.ink)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 110, maxHeight: 200)
                .padding(Ink.Space.m)
                .paperCard()

            Text(L.format("memoryV2.byteCount", utf8Count, 450))
                .font(.system(size: Ink.Size.small).monospacedDigit())
                .foregroundStyle(utf8Count > 450 ? Ink.stop : Ink.inkFaint)
                .contentTransition(.numericText(value: Double(utf8Count)))
                .animation(Ink.Motion.quick, value: utf8Count)
                .padding(.horizontal, Ink.Space.l)
        }
    }

    private var layerSection: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle(L.t("memoryV2.layerLabel"))
            if typeSize.isAccessibilitySize {
                WrapLayout(spacing: Ink.Space.s) {
                    ForEach(availableLayers, id: \.self) { option in
                        let selected = layer == option
                        Button {
                            Haptics.tick(0.45)
                            layer = option
                        } label: {
                            Text(MemoryV2Copy.layerTitle(option))
                                .font(.system(size: Ink.Size.sub, weight: selected ? .semibold : .regular))
                                .foregroundStyle(selected ? Ink.paper : Ink.ink)
                                .padding(.horizontal, Ink.Space.m)
                                .padding(.vertical, Ink.Space.xs)
                                .background(selected ? Ink.accent : Ink.rule.opacity(0.45), in: Capsule())
                        }
                        .buttonStyle(TapStyle())
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            } else {
                SlidingCapsuleControl(
                    selection: $layer,
                    options: availableLayers
                ) { MemoryV2Copy.layerTitle($0) }
                .accessibilityLabel(L.t("memoryV2.layerLabel"))
            }

            Text(MemoryV2Copy.layerHint(layer))
                .font(.system(size: Ink.Size.small))
                .foregroundStyle(Ink.inkSoft)
                .padding(.horizontal, Ink.Space.l)
        }
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle(L.t("memoryV2.metadataLabel"))
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: Ink.Space.s) {
                    Text(L.t("memoryV2.kindLabel"))
                        .font(.system(size: Ink.Size.small, weight: .medium))
                        .foregroundStyle(Ink.inkSoft)

                    ScrollView(.horizontal, showsIndicators: false) {
                        let choices = MemoryV2Copy.commonKinds.contains(kind.lowercased())
                            ? MemoryV2Copy.commonKinds
                            : MemoryV2Copy.commonKinds + [kind]
                        HStack(spacing: Ink.Space.s) {
                            ForEach(choices, id: \.self) { candidateKind in
                                let selected = kind.lowercased() == candidateKind.lowercased()
                                Button {
                                    Haptics.tick(0.45)
                                    kind = candidateKind
                                } label: {
                                    Text(MemoryV2Copy.kindTitle(candidateKind))
                                        .font(.system(size: Ink.Size.small, weight: selected ? .semibold : .regular))
                                        .foregroundStyle(selected ? Ink.paper : Ink.ink)
                                        .padding(.horizontal, Ink.Space.m)
                                        .padding(.vertical, Ink.Space.s * 0.75)
                                        .background(selected ? Ink.accent : Ink.rule.opacity(0.45), in: Capsule())
                                }
                                .buttonStyle(TapStyle())
                            }
                        }
                    }
                }
                .padding(Ink.Space.l)

                Kit.rule(inset: Ink.Space.l)

                HStack(spacing: Ink.Space.m) {
                    Text(L.t("memoryV2.topicLabel"))
                        .font(.system(size: Ink.Size.sub))
                        .foregroundStyle(Ink.inkSoft)
                    TextField(L.t("memoryV2.topicPlaceholder"), text: $topic)
                        .font(.system(size: Ink.Size.sub))
                        .foregroundStyle(Ink.ink)
                        .multilineTextAlignment(.trailing)
                }
                .padding(Ink.Space.l)
            }
            .paperCard()
        }
    }

    private var provenanceSection: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle(L.t("memoryV2.provenanceLabel"))
            RowCard {
                RowLabel(
                    "person.text.rectangle",
                    tint: Ink.Tile.dai,
                    title: L.t("memoryV2.sourceLabel"),
                    end: .value(MemoryV2Copy.provenanceText(for: record, bots: team.bots))
                )
                if let sourceChat = record.sourceChat, !sourceChat.isEmpty {
                    RowLabel(
                        "bubble.left",
                        tint: Ink.Tile.mo,
                        title: L.t("memoryV2.sourceChatLabel"),
                        end: .value(team.title(of: sourceChat) ?? sourceChat)
                    )
                }
                RowLabel(
                    "checkmark.seal",
                    tint: Ink.Tile.zhu,
                    title: L.t("memoryV2.confidenceLabel"),
                    end: .value("\(Int((record.confidence * 100).rounded()))%")
                )
                RowLabel(
                    "calendar",
                    tint: Ink.Tile.xiang,
                    title: L.t("memoryV2.createdAtLabel"),
                    end: .value(formatMs(record.createdAtMs))
                )
                RowLabel(
                    "clock",
                    tint: Ink.Tile.teng,
                    title: L.t("memoryV2.usedAtLabel"),
                    end: .value(record.usedAtMs.map(formatMs) ?? L.t("memoryV2.neverUsed"))
                )
                RowLabel(
                    "pencil.circle",
                    tint: Ink.Tile.yan,
                    title: L.t("memoryV2.updatedAtLabel"),
                    end: .value(formatMs(record.updatedAtMs))
                )
            }
        }
    }

    private var deleteSection: some View {
        Button {
            Haptics.light()
            confirmingDelete = true
        } label: {
            Text(L.t("actions.delete"))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(WideButtonStyle(tint: Ink.stop, filled: false))
        .disabled(!team.canMutateMemoryState)
    }

    private func formatMs(_ ms: Double) -> String {
        guard ms > 0 else { return "-" }
        return Date(timeIntervalSince1970: ms / 1000)
            .formatted(date: .abbreviated, time: .shortened)
    }

    private func save() {
        guard !saving else { return }
        saving = true
        actionError = nil
        let id = record.id
        let nextText = text
        let nextLayer = layer
        let nextKind = kind
        let nextTopic = topic
        Task {
            do {
                let ok = try await team.updateMemoryDetailOffMain(
                    id: id,
                    text: nextText,
                    layer: nextLayer,
                    kind: nextKind,
                    topic: nextTopic
                )
                guard ok else {
                    saving = false
                    Haptics.lock()
                    return
                }
                Haptics.tick(0.7)
                onChanged(nextLayer)
                dismiss()
            } catch {
                saving = false
                Haptics.lock()
                actionError = error.localizedDescription
            }
        }
    }
}

// MARK: - Read-Only Mirror Viewer Sheet

private struct MemoryMirrorViewerSheet: View {
    @ObservedObject var team: TeamModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    private enum MirrorTab: String, CaseIterable, Identifiable {
        case dangan, zhenzhi
        var id: Self { self }
    }

    @State private var tab: MirrorTab = .dangan
    @State private var useMonospace = true
    @State private var content = ""
    @State private var fileURL: URL?
    @State private var loading = true

    private var currentFilename: String {
        switch tab {
        case .dangan: return MemoryMarkdownMirror.danganFilename
        case .zhenzhi: return MemoryMarkdownMirror.zhenzhiFilename
        }
    }

    private var fontPicker: some View {
        SlidingCapsuleControl(
            selection: $useMonospace,
            items: [
                (value: true, title: L.t("memoryV2.mirrorFontCode")),
                (value: false, title: L.t("memoryV2.mirrorFontSerif")),
            ],
            compact: true
        )
        .fixedSize()
        .accessibilityLabel(L.t("memoryV2.mirrorFontLabel"))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Ink.Space.l) {
                    SlidingCapsuleControl(
                        selection: $tab,
                        items: [
                            (value: MirrorTab.dangan, title: L.t("memoryV2.mirrorDanganTab")),
                            (value: MirrorTab.zhenzhi, title: L.t("memoryV2.mirrorZhenzhiTab")),
                        ]
                    )
                    .accessibilityLabel(L.t("memoryV2.mirrorsTitle"))

                    if typeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: Ink.Space.s) {
                            Text(L.t("memoryV2.mirrorLocationNote"))
                                .font(.system(size: Ink.Size.small))
                                .foregroundStyle(Ink.inkSoft)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            fontPicker
                        }
                    } else {
                        HStack(spacing: Ink.Space.m) {
                            Text(L.t("memoryV2.mirrorLocationNote"))
                                .font(.system(size: Ink.Size.small))
                                .foregroundStyle(Ink.inkSoft)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            fontPicker
                        }
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        if loading {
                            ProgressView(L.t("loading.generic"))
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, Ink.Space.l)
                        } else if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(L.t("memoryV2.mirrorEmpty"))
                                .font(.system(size: Ink.Size.sub))
                                .foregroundStyle(Ink.inkSoft)
                        } else {
                            Text(content)
                                .font(useMonospace ? Ink.mono(Ink.Size.small) : Ink.reading)
                                .foregroundStyle(Ink.ink)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(Ink.Space.l)
                    .paperCard()
                }
                .padding(.horizontal, Ink.Space.page)
                .padding(.vertical, Ink.Space.l)
            }
            .scrollIndicators(.hidden)
            .scrollEdgeEffectStyle(.soft, for: .vertical)
            .background(Ink.paper.ignoresSafeArea())
            .navigationTitle(L.t("memoryV2.mirrorsTitle"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if let fileURL {
                        ShareLink(
                            item: fileURL,
                            preview: SharePreview(currentFilename)
                        ) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel(L.t("actions.share"))
                    } else if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ShareLink(
                            item: content,
                            preview: SharePreview(currentFilename)
                        ) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel(L.t("actions.share"))
                    }

                    Button(L.t("actions.done")) {
                        Haptics.light()
                        dismiss()
                    }
                }
            }
            .task(id: tab) {
                await loadMirror()
            }
        }
    }

    private func loadMirror() async {
        loading = true
        let selectedTab = tab
        let keeping = team.keeping
        let fallbackRecords: [MemoryRecord]
        if keeping {
            fallbackRecords = []
        } else {
            fallbackRecords = team.memories.map { mem in
                MemoryRecord(
                    id: mem.id,
                    text: mem.text,
                    layer: mem.deep == true ? .deep : .surface,
                    createdAtMs: mem.at,
                    usedAtMs: mem.used,
                    byBot: mem.by,
                    automatic: mem.automatic == true,
                    editedByUser: mem.editedByUser == true
                )
            }
        }
        let mirrorBots = team.bots.map {
            MemoryMirrorBot(
                name: $0.name,
                role: $0.role,
                isMain: $0.id == team.mainBotId || $0.main == true
            )
        }

        let loaded: (text: String, url: URL?) = await Task.detached(priority: .userInitiated) {
            let secrets = Vault.allStrings()
            if keeping {
                MemoryStoreBridge.shared.flushSync()
                let records = MemoryStoreBridge.shared.recordsSnapshot()
                switch selectedTab {
                case .dangan:
                    let disk = MemoryMarkdownMirror.readDangan()
                    let text: String
                    if let disk, !disk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        text = disk
                    } else {
                        text = MemoryMarkdownRenderer.renderDangan(records: records, bots: mirrorBots, secrets: secrets)
                    }
                    let url = FileManager.default.fileExists(atPath: MemoryMarkdownMirror.danganURL.path)
                        ? MemoryMarkdownMirror.danganURL
                        : nil
                    return (text, url)
                case .zhenzhi:
                    let disk = MemoryMarkdownMirror.readZhenzhi()
                    let text: String
                    if let disk, !disk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        text = disk
                    } else {
                        text = MemoryMarkdownRenderer.renderZhenzhi(records: records, secrets: secrets)
                    }
                    let url = FileManager.default.fileExists(atPath: MemoryMarkdownMirror.zhenzhiURL.path)
                        ? MemoryMarkdownMirror.zhenzhiURL
                        : nil
                    return (text, url)
                }
            } else {
                switch selectedTab {
                case .dangan:
                    return (MemoryMarkdownRenderer.renderDangan(records: fallbackRecords, bots: mirrorBots, secrets: secrets), nil)
                case .zhenzhi:
                    return (MemoryMarkdownRenderer.renderZhenzhi(records: fallbackRecords, secrets: secrets), nil)
                }
            }
        }.value

        content = loaded.text
        fileURL = loaded.url
        loading = false
    }
}
