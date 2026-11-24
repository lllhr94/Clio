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

    var body: some View {
        Text(text)
            .font(.system(size: Ink.Size.micro, weight: .medium))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, Ink.Space.s)
            .padding(.vertical, Ink.Space.xs / 2)
            .background(background, in: Capsule())
    }
}

struct MemoryPageV2: View {
    @ObservedObject var team: TeamModel

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
    @State private var draft = ""
    @State private var editingRecord: MemoryRecord?
    @State private var deletingRecord: MemoryRecord?
    @State private var showingImport = false
    @State private var showingMirrors = false
    @State private var importFeedback: String?
    @State private var refreshRevision = 0

    private var allRecords: [MemoryRecord] {
        _ = refreshRevision
        var byID: [String: MemoryRecord] = [:]
        if team.keeping {
            for record in MemoryStoreBridge.shared.recordsSnapshot() {
                byID[record.id] = record
            }
        }

        var combined: [MemoryRecord] = []
        var seenIDs = Set<String>()
        for memory in team.memories {
            seenIDs.insert(memory.id)
            if var snapshot = byID[memory.id] {
                snapshot.text = memory.text
                if snapshot.layer != .pinned {
                    snapshot.layer = memory.deep == true ? .deep : .surface
                }
                combined.append(snapshot)
            } else if let record = team.memoryRecord(id: memory.id) {
                combined.append(record)
            }
        }
        for archived in team.archivedMemories where seenIDs.insert(archived.id).inserted {
            combined.append(archived)
        }
        return combined.sorted { lhs, rhs in
            let lTime = max(lhs.usedAtMs ?? 0, lhs.createdAtMs)
            let rTime = max(rhs.usedAtMs ?? 0, rhs.createdAtMs)
            if lTime != rTime { return lTime > rTime }
            return lhs.id < rhs.id
        }
    }

    private var filteredRecords: [MemoryRecord] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return allRecords.filter { record in
            if let targetLayer = filter.layer, record.layer != targetLayer {
                return false
            }
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
    }

    private func count(for layer: MemoryLayer, in records: [MemoryRecord]) -> Int {
        records.reduce(0) { $0 + ($1.layer == layer ? 1 : 0) }
    }

    var body: some View {
        let recordsSnapshot = allRecords
        let visibleRecords = filteredRecords
        return contentScrollView(allCount: recordsSnapshot.count, visible: visibleRecords)
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
            .sheet(item: $editingRecord) { record in
                MemoryDetailSheet(team: team, record: record) {
                    refreshRevision &+= 1
                }
            }
            .sheet(isPresented: $showingImport) {
                MemoryImportSheet(team: team) { importedCount in
                    refreshRevision &+= 1
                    importFeedback = L.format("memoryV2.importedToast", importedCount)
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
                        withAnimation(Ink.Motion.settle) {
                            team.deleteMemory(target.id)
                            refreshRevision &+= 1
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

    private func contentScrollView(allCount: Int, visible: [MemoryRecord]) -> some View {
        let recordsSnapshot = allRecords
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: Ink.Space.xl) {
                if team.phase == .demo {
                    noticeBanner(L.t("settings.demoData"), tint: Ink.inkSoft)
                } else if !team.canMutateMemoryState {
                    noticeBanner(L.t("memoryV2.readOnlyNotice"), tint: Ink.warn)
                }

                if let importFeedback {
                    feedbackBanner(importFeedback)
                }

                layerFilterSection(recordsSnapshot)
                quickAddAndToolsSection
                memoryListSection(allCount: allCount, visible: visible)
                MemoryReviewHistory(records: team.memoryReviews)
            }
            .padding(.horizontal, Ink.Space.page)
            .padding(.vertical, Ink.Space.l)
        }
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

    private func feedbackBanner(_ text: String) -> some View {
        HStack(spacing: Ink.Space.s) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Ink.ok)
            Text(text)
                .font(.system(size: Ink.Size.sub, weight: .medium))
                .foregroundStyle(Ink.ink)
            Spacer(minLength: Ink.Space.s)
            Button {
                withAnimation(Ink.Motion.settle) {
                    importFeedback = nil
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: Ink.Size.small, weight: .semibold))
                    .foregroundStyle(Ink.inkFaint)
            }
            .buttonStyle(TapStyle(grow: Ink.Space.xs))
        }
        .padding(.horizontal, Ink.Space.l)
        .padding(.vertical, Ink.Space.m)
        .paperCard()
    }

    // MARK: - Filter & Quick-Add

    private func layerFilterSection(_ records: [MemoryRecord]) -> some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            Picker(L.t("memoryV2.layerLabel"), selection: $filter) {
                ForEach(LayerFilter.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)

            let pinnedCount = count(for: .pinned, in: records)
            let surfaceCount = count(for: .surface, in: records)
            let deepCount = count(for: .deep, in: records)
            let archivedCount = count(for: .archived, in: records)

            Text(L.format("memoryV2.countsSummary", pinnedCount, surfaceCount, deepCount, archivedCount))
                .font(.system(size: Ink.Size.small, weight: .medium))
                .foregroundStyle(Ink.inkSoft)
                .padding(.horizontal, Ink.Space.l)

            Text(L.format("memoryV2.surfaceLimitNote", TeamModel.surfaceLimit))
                .font(.system(size: Ink.Size.small))
                .foregroundStyle(Ink.inkFaint)
                .padding(.horizontal, Ink.Space.l)
        }
    }

    private var quickAddAndToolsSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: Ink.Space.s) {
                TextField(L.t("settings.memoryPlaceholder"), text: $draft)
                    .font(.system(size: Ink.Size.sub))
                    .foregroundStyle(Ink.ink)
                    .submitLabel(.done)
                    .onSubmit(addQuickMemory)

                Button(L.t("actions.save"), action: addQuickMemory)
                    .font(.system(size: Ink.Size.sub, weight: .semibold))
                    .foregroundStyle(Ink.accent)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !team.canMutateMemoryState)
            }
            .padding(Ink.Space.l)

            Kit.rule(inset: Ink.Space.l)

            Button {
                Haptics.light()
                showingImport = true
            } label: {
                RowLabel(
                    "tray.and.arrow.down",
                    tint: Ink.Tile.dai,
                    title: L.t("memoryV2.importActionTitle"),
                    line: L.t("memoryV2.importActionLine")
                )
            }
            .buttonStyle(PressStyle(haptic: false))

            Kit.divider

            Button {
                Haptics.light()
                showingMirrors = true
            } label: {
                RowLabel(
                    "doc.plaintext",
                    tint: Ink.Tile.teng,
                    title: L.t("memoryV2.mirrorsActionTitle"),
                    line: L.t("memoryV2.mirrorsActionLine")
                )
            }
            .buttonStyle(PressStyle(haptic: false))
        }
        .paperCard()
    }

    // MARK: - Memory List

    @ViewBuilder
    private func memoryListSection(allCount: Int, visible: [MemoryRecord]) -> some View {
        if visible.isEmpty {
            emptyStateCard(allCount: allCount)
        } else if filter == .all {
            VStack(alignment: .leading, spacing: Ink.Space.l) {
                ForEach(MemoryLayer.allCases, id: \.self) { layer in
                    let bucket = visible.filter { $0.layer == layer }
                    if !bucket.isEmpty {
                        layerBucketCard(title: MemoryV2Copy.layerTitle(layer), records: bucket)
                    }
                }
            }
        } else if let targetLayer = filter.layer {
            layerBucketCard(title: MemoryV2Copy.layerTitle(targetLayer), records: visible)
        }
    }

    private func layerBucketCard(title: String, records: [MemoryRecord]) -> some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle(title)
            VStack(spacing: 0) {
                ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                    if index > 0 {
                        Kit.rule(inset: Ink.Space.l)
                    }
                    memoryRow(record)
                }
            }
            .paperCard()
        }
    }

    private func memoryRow(_ record: MemoryRecord) -> some View {
        VStack(alignment: .leading, spacing: Ink.Space.xs) {
            Text(record.text)
                .font(.system(size: Ink.Size.sub))
                .foregroundStyle(record.layer == .archived ? Ink.inkSoft : Ink.ink)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: Ink.Space.xs) {
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

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, Ink.Space.l)
        .padding(.vertical, Ink.Space.m)
        .contentShape(Rectangle())
        .onTapGesture {
            Haptics.light()
            editingRecord = record
        }
        .contextMenu {
            rowContextMenu(record)
        }
    }

    @ViewBuilder
    private func rowContextMenu(_ record: MemoryRecord) -> some View {
        Button(L.t("actions.edit"), systemImage: "pencil") {
            editingRecord = record
        }

        if record.layer != .pinned {
            Button(L.t("memoryV2.moveToPinned"), systemImage: "pin") {
                moveRecord(record.id, to: .pinned)
            }
        }

        if record.layer != .surface {
            if record.layer == .archived {
                Button(L.t("memoryV2.restoreToSurface"), systemImage: "arrow.uturn.backward") {
                    withAnimation(Ink.Motion.settle) {
                        _ = team.restoreMemory(record.id)
                        refreshRevision &+= 1
                    }
                }
            } else {
                Button(L.t("memoryV2.moveToSurface"), systemImage: "tray") {
                    moveRecord(record.id, to: .surface)
                }
            }
        }

        if record.layer != .deep {
            Button(L.t("memoryV2.moveToDeep"), systemImage: "clock.arrow.circlepath") {
                moveRecord(record.id, to: .deep)
            }
        }

        if record.layer != .archived {
            Button(L.t("memoryV2.moveToArchived"), systemImage: "archivebox") {
                withAnimation(Ink.Motion.settle) {
                    team.archiveMemory(record.id)
                    refreshRevision &+= 1
                }
            }
        }

        Divider()

        Button(L.t("actions.delete"), systemImage: "trash", role: .destructive) {
            deletingRecord = record
        }
    }

    private func emptyStateCard(allCount: Int) -> some View {
        let message: String
        let detail: String?
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            message = L.t("empty.searchNoResult")
            detail = nil
        } else if allCount == 0 {
            message = L.t("empty.memory")
            detail = L.t("settings.memoryEmptyNote")
        } else if filter == .archived {
            message = L.t("memoryV2.emptyArchived")
            detail = nil
        } else {
            message = L.t("memoryV2.emptyLayer")
            detail = nil
        }

        return VStack(alignment: .leading, spacing: Ink.Space.xs) {
            Text(message)
                .font(.system(size: Ink.Size.sub))
                .foregroundStyle(Ink.inkSoft)
            if let detail {
                Text(detail)
                    .font(.system(size: Ink.Size.small))
                    .foregroundStyle(Ink.inkFaint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Ink.Space.l)
        .paperCard()
    }

    // MARK: - Actions

    private func addQuickMemory() {
        let words = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, team.canMutateMemoryState else { return }
        withAnimation(Ink.Motion.settle) {
            _ = team.remember(words, by: nil)
            refreshRevision &+= 1
        }
        draft = ""
        Haptics.tick(0.6)
    }

    private func moveRecord(_ id: String, to layer: MemoryLayer) {
        withAnimation(Ink.Motion.settle) {
            team.setMemoryLayer(id, layer)
            refreshRevision &+= 1
        }
        Haptics.tick(0.5)
    }
}

// MARK: - Detail / Edit Sheet

private struct MemoryDetailSheet: View {
    @ObservedObject var team: TeamModel
    let record: MemoryRecord
    var onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var text: String
    @State private var layer: MemoryLayer
    @State private var kind: String
    @State private var topic: String
    @State private var confirmingDelete = false

    init(team: TeamModel, record: MemoryRecord, onChanged: @escaping () -> Void) {
        self.team = team
        self.record = record
        self.onChanged = onChanged
        _text = State(initialValue: record.text)
        _layer = State(initialValue: record.layer)
        _kind = State(initialValue: record.kind.isEmpty ? "fact" : record.kind)
        _topic = State(initialValue: record.topic)
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
                    contentSection
                    layerSection
                    metadataSection
                    provenanceSection
                    deleteSection
                }
                .padding(.horizontal, Ink.Space.page)
                .padding(.vertical, Ink.Space.l)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .background(Ink.paper.ignoresSafeArea())
            .navigationTitle(L.t("memoryV2.detailTitle"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L.t("actions.cancel")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L.t("actions.save")) {
                        save()
                    }
                    .fontWeight(.semibold)
                    .disabled(!canSave)
                }
            }
            .confirmationDialog(
                L.t("memoryV2.deleteConfirmTitle"),
                isPresented: $confirmingDelete,
                titleVisibility: .visible
            ) {
                Button(L.t("actions.delete"), role: .destructive) {
                    team.deleteMemory(record.id)
                    Haptics.thud()
                    onChanged()
                    dismiss()
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
                .font(.system(size: Ink.Size.small))
                .foregroundStyle(utf8Count > 450 ? Ink.stop : Ink.inkFaint)
                .padding(.horizontal, Ink.Space.l)
        }
    }

    private var layerSection: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle(L.t("memoryV2.layerLabel"))
            Picker(L.t("memoryV2.layerLabel"), selection: $layer) {
                ForEach(MemoryLayer.allCases, id: \.self) { option in
                    Text(MemoryV2Copy.layerTitle(option)).tag(option)
                }
            }
            .pickerStyle(.segmented)

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
        team.updateMemoryDetail(
            id: record.id,
            text: text,
            layer: layer,
            kind: kind,
            topic: topic
        )
        Haptics.tick(0.7)
        onChanged()
        dismiss()
    }
}

// MARK: - Read-Only Mirror Viewer Sheet

private struct MemoryMirrorViewerSheet: View {
    @ObservedObject var team: TeamModel
    @Environment(\.dismiss) private var dismiss

    private enum MirrorTab: String, CaseIterable, Identifiable {
        case dangan, zhenzhi
        var id: Self { self }
    }

    @State private var tab: MirrorTab = .dangan
    @State private var useMonospace = true

    private var currentFilename: String {
        switch tab {
        case .dangan: return MemoryMarkdownMirror.danganFilename
        case .zhenzhi: return MemoryMarkdownMirror.zhenzhiFilename
        }
    }

    private var currentFileURL: URL? {
        guard team.keeping else { return nil }
        let url: URL
        switch tab {
        case .dangan: url = MemoryMarkdownMirror.danganURL
        case .zhenzhi: url = MemoryMarkdownMirror.zhenzhiURL
        }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private var currentText: String {
        if team.keeping {
            let fromDisk: String?
            switch tab {
            case .dangan: fromDisk = MemoryMarkdownMirror.readDangan()
            case .zhenzhi: fromDisk = MemoryMarkdownMirror.readZhenzhi()
            }
            if let fromDisk, !fromDisk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return fromDisk
            }
        }

        let records = fallbackRecords
        let secrets = Vault.allStrings()
        switch tab {
        case .dangan:
            let bots = team.bots.map {
                MemoryMirrorBot(
                    name: $0.name,
                    role: $0.role,
                    isMain: $0.id == team.mainBotId || $0.main == true
                )
            }
            return MemoryMarkdownRenderer.renderDangan(records: records, bots: bots, secrets: secrets)
        case .zhenzhi:
            return MemoryMarkdownRenderer.renderZhenzhi(records: records, secrets: secrets)
        }
    }

    private var fallbackRecords: [MemoryRecord] {
        if team.keeping {
            return MemoryStoreBridge.shared.recordsSnapshot()
        }
        return team.memories.compactMap { team.memoryRecord(id: $0.id) }
    }

    var body: some View {
        let content = currentText
        let fileURL = currentFileURL
        return NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Ink.Space.l) {
                    Picker(L.t("memoryV2.mirrorsTitle"), selection: $tab) {
                        Text(L.t("memoryV2.mirrorDanganTab")).tag(MirrorTab.dangan)
                        Text(L.t("memoryV2.mirrorZhenzhiTab")).tag(MirrorTab.zhenzhi)
                    }
                    .pickerStyle(.segmented)

                    HStack(spacing: Ink.Space.m) {
                        Text(L.t("memoryV2.mirrorLocationNote"))
                            .font(.system(size: Ink.Size.small))
                            .foregroundStyle(Ink.inkSoft)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Picker("", selection: $useMonospace) {
                            Text(L.t("memoryV2.mirrorFontCode")).tag(true)
                            Text(L.t("memoryV2.mirrorFontSerif")).tag(false)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 112 * UIScale.factor)
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
                    } else {
                        ShareLink(
                            item: content,
                            preview: SharePreview(currentFilename)
                        ) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }

                    Button(L.t("actions.done")) {
                        Haptics.light()
                        dismiss()
                    }
                }
            }
        }
    }
}
