import AgentKit
import Craft
import SwiftUI

/// Four-tab unified search across conversations/leaves, memories, and workspace/mounted documents (including PDFs).
struct UnifiedGlobalSearchSheet: View {
    @ObservedObject var team: TeamModel
    let onOpenChat: (Opened, TeamModel.Leaf?) -> Void
    let onOpenMemory: () -> Void
    let onOpenStudy: () -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var searchFocused: Bool

    @State private var query = ""
    @State private var completedQuery = ""
    @State private var scope: Scope = .all
    @State private var loading = false
    @State private var chatHits: [TeamModel.Hit] = []
    @State private var memoryHits: [Memory] = []
    @State private var fileHits: [FileHit] = []
    @State private var path: [StudyFileTarget] = []

    enum Scope: Int, CaseIterable, Identifiable {
        case all
        case chats
        case memory
        case files

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .all: L.t("unifiedSearch.tabAll")
            case .chats: L.t("unifiedSearch.tabChats")
            case .memory: L.t("unifiedSearch.tabMemory")
            case .files: L.t("unifiedSearch.tabFiles")
            }
        }
    }

    struct FileHit: Identifiable, Sendable {
        let id: String
        let hit: DocSearch.Hit
    }

    struct StudyFileTarget: Identifiable, Hashable, Sendable {
        let id: String
        let url: URL
        let mount: MountedFolder?
        let page: Int?
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var resultsCurrent: Bool {
        !trimmedQuery.isEmpty && completedQuery == trimmedQuery
    }

    private var totalCount: Int {
        chatHits.count + memoryHits.count + fileHits.count
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                headerControls
                Kit.rule(inset: 0)
                resultsBody
            }
            .background(Ink.paper.ignoresSafeArea())
            .navigationTitle(L.t("unifiedSearch.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L.t("actions.done")) {
                        Haptics.light()
                        dismiss()
                    }
                }
            }
            .navigationDestination(for: StudyFileTarget.self) { target in
                StudyFile(url: target.url, mount: target.mount, initialPage: target.page)
            }
        }
        .hitchPage("全局搜索")
        .onAppear {
            searchFocused = true
        }
        .task(id: query) {
            await runSearch()
        }
    }

    private var headerControls: some View {
        VStack(spacing: Ink.Space.s) {
            HStack(spacing: Ink.Space.s) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: Ink.Size.sub))
                    .foregroundStyle(Ink.inkFaint)
                TextField(L.t("unifiedSearch.placeholder"), text: $query)
                    .font(.system(size: Ink.Size.body))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($searchFocused)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Ink.inkFaint)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除搜索")
                }
            }
            .padding(.horizontal, Ink.Space.m)
            .frame(height: 42 * UIScale.factor)
            .background(Ink.paperRaised, in: Capsule())
            .overlay(Capsule().strokeBorder(Ink.rule, lineWidth: 0.5))

            ScrollView(.horizontal) {
                HStack(spacing: Ink.Space.s) {
                    ForEach(Scope.allCases) { tab in
                        scopeChip(tab)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, Ink.Space.page)
        .padding(.top, Ink.Space.s)
        .padding(.bottom, Ink.Space.m)
    }

    private func scopeChip(_ tab: Scope) -> some View {
        let active = scope == tab
        let count = count(for: tab)
        let label = resultsCurrent ? "\(tab.title) \(count)" : tab.title
        return Button {
            Haptics.selection()
            withAnimation(Ink.Motion.settle) {
                scope = tab
            }
        } label: {
            Text(label)
                .font(.system(size: Ink.Size.small, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Ink.accent : Ink.inkSoft)
                .padding(.horizontal, Ink.Space.m)
                .padding(.vertical, Ink.Space.s)
                .background(active ? Ink.accentWash : Ink.paperRaised, in: Capsule())
                .overlay(Capsule().strokeBorder(active ? Ink.accent.opacity(0.4) : Ink.rule, lineWidth: 0.5))
        }
        .buttonStyle(PressStyle(haptic: false))
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func count(for tab: Scope) -> Int {
        switch tab {
        case .all: totalCount
        case .chats: chatHits.count
        case .memory: memoryHits.count
        case .files: fileHits.count
        }
    }

    @ViewBuilder
    private var resultsBody: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Ink.Space.xl) {
                if trimmedQuery.isEmpty {
                    Text(L.t("unifiedSearch.emptyHint"))
                        .font(Ink.secondary)
                        .foregroundStyle(Ink.inkSoft)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, Ink.Space.m)
                } else if loading || !resultsCurrent {
                    HStack(spacing: Ink.Space.s) {
                        ProgressView().controlSize(.small)
                        Text(L.t("unifiedSearch.searching"))
                            .font(Ink.secondary)
                            .foregroundStyle(Ink.inkSoft)
                    }
                    .padding(.top, Ink.Space.m)
                } else if !hasVisibleHits {
                    Text(L.format("unifiedSearch.noResults", trimmedQuery))
                        .font(Ink.secondary)
                        .foregroundStyle(Ink.inkSoft)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, Ink.Space.m)
                } else {
                    visibleSections
                }
            }
            .padding(.horizontal, Ink.Space.page)
            .padding(.vertical, Ink.Space.l)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    private var hasVisibleHits: Bool {
        switch scope {
        case .all: totalCount > 0
        case .chats: !chatHits.isEmpty
        case .memory: !memoryHits.isEmpty
        case .files: !fileHits.isEmpty
        }
    }

    @ViewBuilder
    private var visibleSections: some View {
        switch scope {
        case .all:
            if !chatHits.isEmpty {
                chatSection(limit: 4, showSeeAll: chatHits.count > 4)
            }
            if !memoryHits.isEmpty {
                memorySection(limit: 4, showSeeAll: memoryHits.count > 4)
            }
            if !fileHits.isEmpty {
                fileSection(limit: 4, showSeeAll: fileHits.count > 4)
            }
        case .chats:
            chatSection(limit: chatHits.count, showSeeAll: false)
        case .memory:
            memorySection(limit: memoryHits.count, showSeeAll: false)
        case .files:
            fileSection(limit: fileHits.count, showSeeAll: false)
        }
    }

    private func chatSection(limit: Int, showSeeAll: Bool) -> some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            sectionHeader(L.t("unifiedSearch.sectionChats"), total: chatHits.count, showSeeAll: showSeeAll, targetScope: .chats)
            VStack(spacing: 0) {
                let slice = Array(chatHits.prefix(limit))
                ForEach(slice) { hit in
                    chatRow(hit)
                    if hit.id != slice.last?.id { Kit.divider }
                }
            }
            .paperCard()
        }
    }

    private func memorySection(limit: Int, showSeeAll: Bool) -> some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            sectionHeader(L.t("unifiedSearch.sectionMemory"), total: memoryHits.count, showSeeAll: showSeeAll, targetScope: .memory)
            VStack(spacing: 0) {
                let slice = Array(memoryHits.prefix(limit))
                ForEach(slice) { memory in
                    memoryRow(memory)
                    if memory.id != slice.last?.id { Kit.divider }
                }
            }
            .paperCard()
        }
    }

    private func fileSection(limit: Int, showSeeAll: Bool) -> some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            sectionHeader(L.t("unifiedSearch.sectionFiles"), total: fileHits.count, showSeeAll: showSeeAll, targetScope: .files)
            VStack(spacing: 0) {
                let slice = Array(fileHits.prefix(limit))
                ForEach(slice) { entry in
                    fileRow(entry.hit)
                    if entry.id != slice.last?.id { Kit.divider }
                }
            }
            .paperCard()
        }
    }

    private func sectionHeader(_ title: String, total: Int, showSeeAll: Bool, targetScope: Scope) -> some View {
        HStack {
            SectionTitle(title)
            Spacer()
            if showSeeAll {
                Button(L.format("unifiedSearch.seeAll", total)) {
                    Haptics.selection()
                    withAnimation(Ink.Motion.settle) { scope = targetScope }
                }
                .font(.system(size: Ink.Size.small, weight: .medium))
                .foregroundStyle(Ink.accent)
            }
        }
    }

    private func chatRow(_ hit: TeamModel.Hit) -> some View {
        Button {
            Haptics.light()
            let opened: Opened = hit.key.hasPrefix("room-")
                ? .gathering(String(hit.key.dropFirst(5)))
                : .companion(String(hit.key.dropFirst(4)))
            let leaf = hit.leaf.flatMap { leafID in
                team.leaves(hit.key).first(where: { $0.id == leafID })
            }
            dismiss()
            onOpenChat(opened, leaf)
        } label: {
            HStack(alignment: .top, spacing: Ink.Space.m) {
                IconBadge(symbol: hit.key.hasPrefix("room-") ? "person.3" : "bubble.left.and.bubble.right", tint: Ink.Tile.dai)
                VStack(alignment: .leading, spacing: Ink.Space.xs) {
                    HStack {
                        Text(hit.name)
                            .font(.system(size: Ink.Size.sub, weight: .semibold))
                            .foregroundStyle(Ink.ink)
                            .lineLimit(1)
                        if hit.leaf != nil {
                            Text(L.t("chat.oldConversation"))
                                .font(.system(size: Ink.Size.micro))
                                .foregroundStyle(Ink.inkFaint)
                        }
                        Spacer(minLength: Ink.Space.s)
                        Text(Desk.when(hit.at))
                            .font(Ink.footnote)
                            .foregroundStyle(Ink.inkFaint)
                    }
                    Text(hit.snippet)
                        .font(Ink.secondary)
                        .foregroundStyle(Ink.inkSoft)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(.horizontal, Ink.Space.l)
            .padding(.vertical, Ink.Space.m)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(haptic: false))
    }

    private func memoryRow(_ memory: Memory) -> some View {
        let layerTitle = memory.deep == true ? L.t("unifiedSearch.layerDeep") : L.t("unifiedSearch.layerSurface")
        return Button {
            Haptics.light()
            dismiss()
            onOpenMemory()
        } label: {
            HStack(alignment: .top, spacing: Ink.Space.m) {
                IconBadge(symbol: "brain", tint: Ink.Tile.yan)
                VStack(alignment: .leading, spacing: Ink.Space.xs) {
                    HStack {
                        MemoryBadgePill(
                            text: layerTitle,
                            foreground: memory.deep == true ? Ink.inkSoft : Ink.ok,
                            background: memory.deep == true ? Ink.rule.opacity(0.6) : Ink.ok.opacity(0.14)
                        )
                        Spacer(minLength: Ink.Space.s)
                        Text(Desk.when(memory.used ?? memory.at))
                            .font(Ink.footnote)
                            .foregroundStyle(Ink.inkFaint)
                    }
                    Text(memory.text)
                        .font(Ink.secondary)
                        .foregroundStyle(Ink.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(.horizontal, Ink.Space.l)
            .padding(.vertical, Ink.Space.m)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(haptic: false))
    }

    private func fileRow(_ hit: DocSearch.Hit) -> some View {
        let filename = (hit.path as NSString).lastPathComponent
        return Button {
            openFile(hit)
        } label: {
            HStack(alignment: .top, spacing: Ink.Space.m) {
                IconBadge(symbol: hit.page != nil ? "doc.richtext" : "doc.text", tint: Ink.Tile.xiang)
                VStack(alignment: .leading, spacing: Ink.Space.xs) {
                    HStack(spacing: Ink.Space.xs) {
                        Text(filename.isEmpty ? hit.path : filename)
                            .font(.system(size: Ink.Size.sub, weight: .semibold))
                            .foregroundStyle(Ink.ink)
                            .lineLimit(1)
                        if let page = hit.page {
                            Text(L.format("unifiedSearch.pdfPage", page))
                                .font(.system(size: Ink.Size.micro, weight: .medium))
                                .foregroundStyle(Ink.accent)
                                .padding(.horizontal, Ink.Space.xs)
                                .padding(.vertical, Ink.Space.xs / 2)
                                .background(Ink.accentWash, in: Capsule())
                        }
                        Spacer(minLength: 0)
                    }
                    Text(hit.path)
                        .font(Ink.mono(Ink.Size.micro))
                        .foregroundStyle(Ink.inkFaint)
                        .lineLimit(1)
                    if !hit.snippet.isEmpty {
                        Text(hit.snippet)
                            .font(Ink.secondary)
                            .foregroundStyle(Ink.inkSoft)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
            }
            .padding(.horizontal, Ink.Space.l)
            .padding(.vertical, Ink.Space.m)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(haptic: false))
    }

    private func openFile(_ hit: DocSearch.Hit) {
        Haptics.light()
        guard let parsed = try? Workspace.parse(hit.path) else {
            dismiss()
            onOpenStudy()
            return
        }
        let targetID = "\(hit.path)#\(hit.page ?? 0)"
        switch parsed {
        case .desk(let url, _):
            path.append(StudyFileTarget(id: targetID, url: url, mount: nil, page: hit.page))
        case .mounted(let mount, let innerParts, _):
            if let opened = MountedFolders.openForUI(mount) {
                let fileURL = innerParts.reduce(opened.url) { $0.appendingPathComponent($1) }
                opened.token.stop()
                path.append(StudyFileTarget(id: targetID, url: fileURL, mount: mount, page: hit.page))
            } else {
                dismiss()
                onOpenStudy()
            }
        case .mountsRoot:
            dismiss()
            onOpenStudy()
        }
    }

    private func runSearch() async {
        let snapshot = trimmedQuery
        guard !snapshot.isEmpty else {
            loading = false
            completedQuery = ""
            chatHits = []
            memoryHits = []
            fileHits = []
            return
        }
        if snapshot != completedQuery {
            completedQuery = ""
            chatHits = []
            memoryHits = []
            fileHits = []
        }
        loading = true
        do { try await Task.sleep(for: .milliseconds(220)) } catch { return }
        guard !Task.isCancelled, snapshot == trimmedQuery else { return }

        let memorySnapshot = team.memories
        let botNames = Dictionary(uniqueKeysWithValues: team.bots.map { ($0.id, $0.name) })
        let canSearchDocs = !Disk.frozen
        let rootTarget = canSearchDocs ? (try? Workspace.parse(nil)) : nil

        async let chatsTask: [TeamModel.Hit] = team.search(snapshot)
        async let memoryTask: [Memory] = Task.detached(priority: .userInitiated) {
            let needle = snapshot.lowercased()
            return memorySnapshot.filter { item in
                if item.text.localizedCaseInsensitiveContains(snapshot) { return true }
                if let by = item.by, let name = botNames[by], name.lowercased().contains(needle) { return true }
                return false
            }
            .sorted { ($0.used ?? $0.at) > ($1.used ?? $1.at) }
        }.value
        async let filesTask: [FileHit] = Task.detached(priority: .utility) {
            guard let rootTarget else { return [] }
            guard let result = try? await DocSearchIndexService.shared.search(query: snapshot, target: rootTarget) else {
                return []
            }
            return result.hits.enumerated().map { idx, hit in
                FileHit(id: "\(idx)|\(hit.path)#\(hit.page ?? -1)", hit: hit)
            }
        }.value

        let (chats, memories, files) = await (chatsTask, memoryTask, filesTask)
        guard !Task.isCancelled, snapshot == trimmedQuery else { return }
        chatHits = chats
        memoryHits = Array(memories.prefix(40))
        fileHits = files
        completedQuery = snapshot
        loading = false
    }
}
