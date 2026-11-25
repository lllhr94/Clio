import SwiftUI

/// Slide-out conversation drawer showing search, navigation places, pinned/recent/earlier threads, and settings entry.
struct DeskSidebarView: View {
    @ObservedObject var team: TeamModel
    let opened: Opened?
    @Binding var sideQuery: String
    @Binding var listFilter: Int
    @Binding var labelFilter: String
    @Binding var studying: Bool
    @Binding var denning: Bool
    @Binding var tuning: Bool

    let closeSide: () -> Void
    let startFresh: () -> Void
    let jump: (Opened?) -> Void
    let startRename: (String) -> Void
    let startRenamePast: (DeskPastLeaf) -> Void
    let requestDelete: (DeskSideConversation) -> Void
    let changeArchive: (String, Bool) -> Void

    private var recent: [DeskThread] {
        DeskThreadHelpers.recent(team: team)
    }

    private var shownThreads: [DeskThread] {
        recent.filter {
            DeskThreadHelpers.matchesFilter($0, team: team, listFilter: listFilter, labelFilter: labelFilter)
        }
    }

    private var sideThreads: [DeskThread] {
        let words = sideQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return shownThreads }
        return recent.filter { item in
            [item.name, item.preview, team.title(of: item.id.id) ?? ""].contains { $0.localizedCaseInsensitiveContains(words) }
        }
    }

    private var sideSections: [DeskSideSection] {
        // 主人定：侧边栏也按 置顶 / 最近 / 更早。
        let past = DeskThreadHelpers.pastLeaves(
            team: team,
            matching: sideQuery,
            listFilter: listFilter,
            labelFilter: labelFilter
        )
        return DeskThreadHelpers.sections(team: team, threads: sideThreads, past: past, byDate: true)
    }

    var body: some View {
        let sections = sideSections
        VStack(alignment: .leading, spacing: 0) {
            topHeader
            searchField
            DeskFilterChips(listFilter: $listFilter, labelFilter: $labelFilter)
                .padding(.horizontal, Ink.Space.l)
                .padding(.bottom, Ink.Space.s)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
                    if sideQuery.isEmpty {
                        sideNav("house", Words.t("案头")) { jump(nil) }
                        sideNav("books.vertical", Words.t("书案")) { closeSide(); studying = true }
                        sideNav("terminal", Words.t("斗室")) { closeSide(); denning = true }
                    }
                    ForEach(sections, id: \.title) { section in
                        Text(section.title)
                            .font(.system(size: Ink.Size.small, weight: .semibold))
                            .foregroundStyle(Ink.inkFaint)
                            .padding(.horizontal, Ink.Space.l)
                            .padding(.top, Ink.Space.l)
                            .padding(.bottom, Ink.Space.xs)
                        ForEach(section.rows) { row in
                            switch row {
                            case .current(let item): sideThread(item)
                            case .past(let past): pastRow(past)
                            }
                        }
                    }
                    if sections.isEmpty {
                        Text(sideQuery.isEmpty ? "还没有对话。" : "没找到「\(sideQuery)」。")
                            .font(Ink.secondary).foregroundStyle(Ink.inkSoft).padding(Ink.Space.l)
                    }
                }
                .padding(.horizontal, Ink.Space.s)
                .padding(.bottom, Ink.Space.l)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)

            // Settings sits at the foot as a full row, like the places above it, not a lone button in a corner.
            Kit.rule(inset: 0)
            Button {
                Haptics.light()
                closeSide()
                tuning = true
            } label: {
                HStack(spacing: Ink.Space.m) {
                    Image(systemName: "gearshape").font(.system(size: Ink.Size.body)).foregroundStyle(Ink.inkSoft).frame(width: 26)
                    Text(Words.t("调弦")).font(.system(size: Ink.Size.body)).foregroundStyle(Ink.ink)
                    Spacer()
                    Text("\(team.bots.count) 位\(Words.t("旅伴"))").font(.system(size: Ink.Size.small)).foregroundStyle(Ink.inkFaint)
                }
                .padding(.horizontal, Ink.Space.s + Ink.Space.m)
                .frame(height: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle(haptic: false))
        }
        .background(Ink.paper.ignoresSafeArea())
    }

    private var topHeader: some View {
        HStack(spacing: Ink.Space.s) {
            HStack(alignment: .center, spacing: Ink.Space.s) {
                Text("Clio")
                    .font(Ink.wordmark((34 * UIScale.factor).rounded()))
                    .foregroundStyle(Ink.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                ClioSeal(size: (20 * UIScale.factor).rounded())
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Clio")
            .accessibilityAddTraits(.isHeader)
            Spacer()
            Button {
                Haptics.light()
                // A gathering starts a fresh page too, not only a companion.
                closeSide()
                startFresh()
            } label: {
                Label(L.t("actions.newChat"), systemImage: "square.and.pencil")
                    .font(.system(size: Ink.Size.sub, weight: .semibold))
                    .foregroundStyle(Ink.paper)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, Ink.Space.m)
                    .frame(minHeight: Ink.Bar.height)
                    .background(Ink.ink, in: .capsule)
            }
            .buttonStyle(PressStyle(haptic: false))
        }
        .padding(.horizontal, Ink.Space.l)
        .padding(.top, Ink.Space.s)
    }

    private var searchField: some View {
        HStack(spacing: Ink.Space.s) {
            Image(systemName: "magnifyingglass").foregroundStyle(Ink.inkFaint)
            TextField("搜索对话", text: $sideQuery)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !sideQuery.isEmpty {
                Button { sideQuery = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Ink.inkFaint) }
                    .accessibilityLabel("清除搜索")
                    .buttonStyle(.plain)
            }
        }
        .font(.system(size: Ink.Size.body))
        .padding(.horizontal, Ink.Space.m)
        .frame(height: 42)
        .background(Ink.paperRaised, in: .capsule)
        .padding(Ink.Space.l)
    }

    private func sideNav(_ icon: String, _ title: String, _ run: @escaping () -> Void) -> some View {
        Button {
            Haptics.light()
            run()
        } label: {
            HStack(spacing: Ink.Space.m) {
                Image(systemName: icon).font(.system(size: Ink.Size.body)).foregroundStyle(Ink.inkSoft).frame(width: 26)
                Text(title).font(.system(size: Ink.Size.body)).foregroundStyle(Ink.ink)
                Spacer()
            }
            .padding(.horizontal, Ink.Space.m)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(haptic: false))
    }

    private func pastRow(_ past: DeskPastLeaf) -> some View {
        let row = DeskSideConversation.past(past)
        return SwipeRow(actions: sidebarSwipes(row)) {
            Button {
                Haptics.light()
                jump(past.owner)
                team.openLeaf(past.owner.id, past.leaf)
            } label: {
                HStack(spacing: Ink.Space.s) {
                    DeskThreadHelpers.threadColor(row.id, team: team)
                    VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
                        Text(past.leaf.title.isEmpty ? L.t("chat.untitled") : past.leaf.title)
                            .font(.system(size: Ink.Size.sub)).foregroundStyle(Ink.ink).lineLimit(1)
                        Text("\(past.ownerName) · \(DeskThreadHelpers.dayName(past.leaf.at)) · \(past.leaf.count) 条")
                            .font(.system(size: Ink.Size.small)).foregroundStyle(Ink.inkFaint).lineLimit(1)
                    }
                    Spacer(minLength: Ink.Space.s)
                    DeskThreadHelpers.archivedIcon(row.id, team: team)
                }
                .padding(.horizontal, Ink.Space.m)
                .padding(.vertical, Ink.Space.s)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle(haptic: false))
            .contextMenu { sidebarMenu(row) }
        }
    }

    private func sideThread(_ item: DeskThread) -> some View {
        let here = item.id == opened
        let key = item.id.id
        let row = DeskSideConversation.current(item)
        return SwipeRow(actions: sidebarSwipes(row)) {
            Button {
                Haptics.light()
                jump(item.id)
            } label: {
                HStack(spacing: Ink.Space.s) {
                    DeskThreadHelpers.threadColor(key, team: team)
                    VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
                        Text(item.name).font(.system(size: Ink.Size.sub, weight: here ? .semibold : .regular)).foregroundStyle(Ink.ink).lineLimit(1)
                        // What the conversation is about (its title, which you can rename), else its last words.
                        let line = team.title(of: key) ?? item.preview
                        if !line.isEmpty {
                            Text(line).font(.system(size: Ink.Size.small)).foregroundStyle(Ink.inkFaint).lineLimit(1)
                        }
                    }
                    Spacer(minLength: Ink.Space.s)
                    if team.archived.contains(key) {
                        DeskThreadHelpers.archivedIcon(key, team: team)
                    } else if team.approvals.contains(where: { $0.chat == key }) {
                        Image(systemName: "exclamationmark.circle").font(.system(size: Ink.Size.sub)).foregroundStyle(Ink.warn)
                    } else if team.isWorking(key) {
                        ProgressView().controlSize(.mini)
                    } else if team.isUnread(key, at: item.at) {
                        Circle().fill(Ink.accent).frame(width: 7, height: 7)
                    }
                }
                .padding(.horizontal, Ink.Space.m)
                .padding(.vertical, Ink.Space.s)
                .background(here ? Ink.paperRaised : Color.clear, in: .rect(cornerRadius: Ink.Radius.small, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle(haptic: false))
            .contextMenu { sidebarMenu(row) }
        }
    }

    private func sidebarSwipes(_ row: DeskSideConversation) -> [SwipeAction] {
        DeskThreadHelpers.pastSwipes(row, team: team, changeArchive: changeArchive, requestDelete: requestDelete)
    }

    @ViewBuilder
    private func sidebarMenu(_ row: DeskSideConversation) -> some View {
        DeskThreadHelpers.conversationMenu(
            row,
            team: team,
            startRename: startRename,
            startRenamePast: startRenamePast,
            changeArchive: changeArchive,
            requestDelete: requestDelete
        )
    }
}
