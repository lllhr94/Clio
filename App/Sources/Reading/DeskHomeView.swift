import SwiftUI

/// Home feed of recent conversations, companions, waiting approvals, and onboarding checklist.
struct DeskHomeView: View {
    @ObservedObject var team: TeamModel
    @Binding var opened: Opened?
    @Binding var editing: DeskEditTarget?
    @Binding var tuning: Bool
    @Binding var settingsPage: String?
    @Binding var caring: Bool
    @Binding var addingService: Bool
    @Binding var cardBot: BotInfo?
    @Binding var roomEditing: RoomInfo?
    @Binding var clearing: Opened?
    @Binding var searching: Bool
    @Binding var query: String
    @Binding var searchHits: [TeamModel.Hit]
    @Binding var showArchived: Bool
    @Binding var listFilter: Int
    @Binding var labelFilter: String

    let startFresh: (String?) -> Void
    let openDrawerItem: (DrawerItem) -> Void
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

    private var pastList: [DeskPastLeaf] {
        DeskThreadHelpers.pastLeaves(
            team: team,
            matching: "",
            listFilter: listFilter,
            labelFilter: labelFilter
        )
    }

    private var archivedRows: [DeskSideConversation] {
        DeskThreadHelpers.archivedRows(team: team, recent: recent)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if team.phase == .setup {
                    setupChecklist
                } else {
                    homeThreads
                }
            }
            .padding(.horizontal, Ink.Space.page)
            .padding(.bottom, Ink.Space.huge)
        }
        .scrollIndicators(.hidden)
        .animation(Ink.Motion.settle, value: team.approvals.count)
    }

    @ViewBuilder
    private var homeThreads: some View {
        header
        companions
            // 看名帖 from anywhere on the desk; kept here so the long body stays quick to check.
            .sheet(item: $cardBot) { bot in NameCardSheet(team: team, bot: bot) }
        waitingCard
        if let next = team.nextLetter { letter(next) }
        recentHeader
        if searching {
            searchBar
        }
        if searching && !query.trimmingCharacters(in: .whitespaces).isEmpty {
            searchResultsSection
        } else {
            mainFeedSections
        }
    }

    private var recentHeader: some View {
        HStack {
            Text(Words.t("近来的絮语"))
                .font(Ink.title)
                .foregroundStyle(Ink.ink)
            Spacer()
            Button {
                Haptics.light()
                withAnimation(Ink.Motion.settle) {
                    searching.toggle()
                    if !searching { query = "" }
                }
            } label: {
                Image(systemName: searching ? "xmark" : "magnifyingglass")
                    .font(.system(size: Ink.Size.body, weight: .medium))
                    .foregroundStyle(Ink.inkSoft)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel(searching ? "不找了" : "找一找")
        }
        .padding(.top, Ink.Space.xxl)
        .padding(.bottom, Ink.Space.s)
    }

    private var searchBar: some View {
        TextField("找过去聊过的话", text: $query)
            .font(.system(size: Ink.Size.body))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.search)
            .padding(.horizontal, Ink.Space.l)
            .frame(height: 44)
            .paperCard()
            .padding(.bottom, Ink.Space.m)
            .transition(.opacity)
            // Looked up a moment after typing stops, off the main thread (it reads every conversation).
            .task(id: query) {
                let words = query
                guard !words.trimmingCharacters(in: .whitespaces).isEmpty else { searchHits = []; return }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                let found = await team.search(words)
                if !Task.isCancelled, words == query { searchHits = found }
            }
    }

    @ViewBuilder
    private var searchResultsSection: some View {
        let hits = searchHits
        if hits.isEmpty {
            Text("没找到「\(query)」。").font(Ink.secondary).foregroundStyle(Ink.inkSoft).padding(.vertical, Ink.Space.l)
        }
        ForEach(hits) { hit in
            Button {
                Haptics.light()
                if let leaf = hit.leaf, let found = team.leaves(hit.key).first(where: { $0.id == leaf }) {
                    team.openLeaf(hit.key, found)
                }
                if hit.key.hasPrefix("bot-") {
                    opened = .companion(String(hit.key.dropFirst(4)))
                } else {
                    opened = .gathering(String(hit.key.dropFirst(5)))
                }
            } label: {
                VStack(alignment: .leading, spacing: Ink.Space.xs) {
                    HStack {
                        Text(hit.name).font(.system(size: Ink.Size.sub, weight: .semibold)).foregroundStyle(Ink.ink)
                        if hit.leaf != nil { Text(Words.t("收起的一叶")).font(.system(size: Ink.Size.micro)).foregroundStyle(Ink.inkFaint) }
                        Spacer()
                        Text(Date(timeIntervalSince1970: hit.at / 1000).formatted(.relative(presentation: .named))).font(Ink.footnote).foregroundStyle(Ink.inkFaint)
                    }
                    Text(hit.snippet).font(Ink.secondary).foregroundStyle(Ink.inkSoft).lineLimit(2).multilineTextAlignment(.leading)
                }
                .padding(.vertical, Ink.Space.m)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .contextMenu {
                DeskThreadHelpers.archiveMenu(hit.leaf.map { TeamModel.threadKey(hit.key, leaf: $0) } ?? hit.key, team: team, changeArchive: changeArchive)
            }
            Kit.rule(inset: 0)
        }
    }

    @ViewBuilder
    private var mainFeedSections: some View {
        let keeperName = team.bots.first { $0.id == team.mainBotId }?.name ?? team.bots.first?.name ?? Words.t("旅伴")
        TideChip(keeper: keeperName)
        DeskFilterChips(listFilter: $listFilter, labelFilter: $labelFilter)
        let sections = DeskThreadHelpers.sections(team: team, threads: shownThreads, past: pastList, byDate: true)
        if sections.isEmpty {
            EmptyNote(
                symbol: recent.isEmpty ? "bubble.left.and.bubble.right" : "archivebox",
                words: recent.isEmpty ? L.t("empty.startConversation") : L.t("empty.activeConversations")
            )
        }
        // Every conversation, not one row per companion: the ones put aside by 新对话 sit in 最近 / 更早 too.
        ForEach(sections, id: \.title) { section in
            Text(section.title)
                .font(.system(size: Ink.Size.small, weight: .medium))
                .foregroundStyle(Ink.inkFaint)
                .padding(.top, Ink.Space.m)
            ForEach(section.rows) { row in
                sectionRow(row)
                if row.id != section.rows.last?.id { Kit.rule(inset: 40) }
            }
        }
        archivedSection
    }

    @ViewBuilder
    private var archivedSection: some View {
        let archived = archivedRows
        if !archived.isEmpty {
            Button {
                Haptics.light()
                withAnimation(Ink.Motion.unfold) { showArchived.toggle() }
            } label: {
                HStack(spacing: Ink.Space.s) {
                    Image(systemName: "archivebox").font(.system(size: Ink.Size.small))
                    Text("已归档 \(archived.count) 段").font(.system(size: Ink.Size.sub, weight: .medium))
                    Image(systemName: "chevron.down").font(.system(size: Ink.Size.micro, weight: .semibold))
                        .rotationEffect(.degrees(showArchived ? 180 : 0))
                    Spacer()
                }
                .foregroundStyle(Ink.inkSoft)
                .padding(.vertical, Ink.Space.l)
                .contentShape(Rectangle())
            }
            .buttonStyle(TapStyle())
            .padding(.top, Ink.Space.l)
            if showArchived {
                ForEach(archived) { row in
                    sectionRow(row)
                        .opacity(0.75)
                    Kit.rule(inset: 40)
                }
            }
        }
    }

    @ViewBuilder
    private func sectionRow(_ row: DeskSideConversation) -> some View {
        switch row {
        case .current(let item):
            thread(item)
        case .past(let past):
            pastRow(past)
        }
    }

    private var setupChecklist: some View {
        VStack(alignment: .leading, spacing: Ink.Space.xl) {
            Text(L.t("homeThreads.getStarted"))
                .font(Ink.mark(Ink.Size.title, bold: true, relativeTo: .title3))
                .foregroundStyle(Ink.ink)
            RowCard {
                Button { addingService = true } label: {
                    RowLabel("server.rack", title: L.t("homeThreads.connect"), line: L.t("homeThreads.connectHelp"))
                }
                .buttonStyle(PressStyle())
                Button { settingsPage = "models"; tuning = true } label: {
                    RowLabel("sparkles", title: L.t("settings.defaultModel"), line: L.t("homeThreads.defaultHelp"))
                }
                .buttonStyle(PressStyle())
                Button { caring = true } label: {
                    RowLabel("externaldrive", title: L.t("homeThreads.backup"), line: L.t("homeThreads.backupHelp"))
                }
                .buttonStyle(PressStyle())
            }
        }
        .padding(.top, Ink.Space.xxl)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: Ink.Space.s) {
                Text(DeskThreadHelpers.greeting()).font(Ink.mark(Ink.Size.title, bold: true, relativeTo: .title3)).foregroundStyle(Ink.ink)
                Text("今天想聊点什么？").font(Ink.reading).foregroundStyle(Ink.inkSoft)
            }
            Spacer()
            HStack(spacing: Ink.Space.s) {
                if !team.bots.isEmpty {
                    Button {
                        Haptics.light()
                        startFresh(nil)
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: Ink.Size.body, weight: .semibold))
                            .foregroundStyle(Ink.ink)
                            .frame(width: Ink.Bar.height, height: Ink.Bar.height)
                            .glassFace(in: Circle())
                    }
                    .buttonStyle(PressStyle(haptic: false))
                    .accessibilityLabel("新对话")
                }
                Menu {
                    Button(Words.t("新旅伴"), systemImage: "person.badge.plus") { openDrawerItem(.newCompanion) }
                    Button(Words.t("开一场雅集"), systemImage: "person.3") { openDrawerItem(.gathering) }
                    Button(Words.t("收名帖"), systemImage: "square.and.arrow.down") { openDrawerItem(.importCard) }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: Ink.Size.body, weight: .semibold))
                        .foregroundStyle(Ink.ink)
                        .frame(width: Ink.Bar.height, height: Ink.Bar.height)
                        .glassFace(in: Circle())
                }
                .accessibilityLabel(Words.t("添一位旅伴或开一场雅集"))
                Button {
                    Haptics.light()
                    tuning = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: Ink.Size.body, weight: .semibold))
                        .foregroundStyle(Ink.ink)
                        .frame(width: Ink.Bar.height, height: Ink.Bar.height)
                        .glassFace(in: Circle())
                }
                .buttonStyle(PressStyle(haptic: false))
                .accessibilityLabel(Words.t("调弦"))
            }
        }
        .padding(.top, Ink.Space.xxl)
    }

    private var companions: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Ink.Space.s) {
                ForEach(team.bots) { bot in
                    Button {
                        Haptics.tick(0.5)
                        opened = .companion(bot.id)
                    } label: {
                        HStack(spacing: Ink.Space.s) {
                            PetStill(size: 28, wash: Ink.wash(for: bot), avatar: true, bot: bot)
                            Text(bot.name).font(Ink.label).foregroundStyle(Ink.ink)
                            if team.isWorking(TeamModel.key(bot: bot.id)) {
                                Circle().fill(Ink.accent).frame(width: 6, height: 6)
                            }
                        }
                        .padding(.leading, Ink.Space.s)
                        .padding(.trailing, Ink.Space.l)
                        .frame(height: 40)
                        .background(Ink.paperRaised, in: .capsule)
                        .overlay(Capsule().strokeBorder(Ink.rule, lineWidth: 1))
                    }
                    .buttonStyle(PressStyle(haptic: false))
                    .contextMenu {
                        Button(Words.t("看名帖"), systemImage: "person.text.rectangle") { cardBot = bot }
                        ShareLink(item: NameCardTransfer(bot: bot), preview: SharePreview(bot.name)) { Label(Words.t("递名帖"), systemImage: "square.and.arrow.up") }
                    }
                }
                Button {
                    editing = DeskEditTarget(id: "new", bot: nil)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: Ink.Size.sub, weight: .semibold))
                        .foregroundStyle(Ink.inkSoft)
                        .frame(width: 40, height: 40)
                        .overlay(Circle().strokeBorder(Ink.rule, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel(Words.t("新旅伴"))
            }
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .padding(.top, Ink.Space.xl)
    }

    @ViewBuilder
    private var waitingCard: some View {
        if let first = team.approvals.first, let chat = first.chat {
            let name = team.bots.first { $0.id == first.botId }?.name ?? L.t("nav.assistant")
            Button {
                Haptics.tick(0.6)
                if chat.hasPrefix("room-") {
                    opened = .gathering(String(chat.dropFirst(5)))
                } else {
                    opened = .companion(String(chat.dropFirst(4)))
                }
            } label: {
                HStack(spacing: Ink.Space.m) {
                    Image(systemName: "seal")
                        .font(.system(size: Ink.Size.body, weight: .semibold))
                        .foregroundStyle(Ink.warn)
                        .frame(width: 34, height: 34)
                        .background(Ink.warn.opacity(0.14), in: .circle)
                    VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
                        Text(team.approvals.count > 1 ? Words.t("\(team.approvals.count) 张笺等你落印") : Words.t("\(name)等你落印"))
                            .font(.system(size: Ink.Size.sub, weight: .semibold)).foregroundStyle(Ink.ink)
                        Text("\(name)想\(first.tool ?? "做一件事")" + ((first.reason ?? "").isEmpty ? "" : "：\(first.reason!)"))
                            .font(Ink.footnote).foregroundStyle(Ink.inkSoft).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text("去看看").font(.system(size: Ink.Size.small, weight: .semibold)).foregroundStyle(Ink.accent)
                }
                .padding(Ink.Space.l)
                .paperCard()
            }
            .buttonStyle(PressStyle(haptic: false))
            .padding(.top, Ink.Space.xl)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private func letter(_ next: Later) -> some View {
        HStack(spacing: Ink.Space.s) {
            Image(systemName: "envelope").font(.system(size: Ink.Size.sub, weight: .medium)).foregroundStyle(Ink.accent)
            VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
                Text(Words.t("来信 · ") + When.show(Date(timeIntervalSince1970: next.at))).font(Ink.footnote).foregroundStyle(Ink.inkSoft)
                Text("\(team.bots.first { $0.id == next.botId }?.name ?? "旅伴")约好来找你：\(next.text)")
                    .font(Ink.secondary)
                    .foregroundStyle(Ink.ink)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(Ink.Space.l)
        .paperCard()
        .padding(.top, Ink.Space.xl)
    }

    private func pastRow(_ past: DeskPastLeaf) -> some View {
        let row = DeskSideConversation.past(past)
        return SwipeRow(actions: DeskThreadHelpers.pastSwipes(row, team: team, changeArchive: changeArchive, requestDelete: requestDelete)) {
            Button {
                Haptics.light()
                opened = past.owner
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
                .padding(.vertical, Ink.Space.m)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle(haptic: false))
            .contextMenu {
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
    }

    private func thread(_ item: DeskThread) -> some View {
        SwipeRow(actions: swipes(item)) {
            Button {
                Haptics.tick(0.5)
                opened = item.id
            } label: {
                HStack(alignment: .top, spacing: Ink.Space.m) {
                    Group {
                        if let bot = item.bot {
                            PetStill(size: 28, wash: Ink.wash(for: bot), avatar: true, bot: bot)
                        } else {
                            Image(systemName: "person.3")
                                .font(.system(size: Ink.Size.micro, weight: .semibold))
                                .foregroundStyle(Ink.accent)
                                .frame(width: 28, height: 28)
                                .background(Ink.accentWash, in: .circle)
                        }
                    }
                    .padding(.top, Ink.Space.xs / 2)
                    VStack(alignment: .leading, spacing: Ink.Space.xs) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(item.name).font(Ink.readingBold).foregroundStyle(Ink.ink)
                            Spacer()
                            Text(Desk.when(item.at)).font(Ink.footnote).foregroundStyle(Ink.inkFaint)
                        }
                        if let live = Live.brief(team.workDetail(for: item.id.id).words, waiting: team.approvals.contains { $0.chat == item.id.id }) {
                            HStack(spacing: Ink.Space.xs) {
                                BreathingDot()
                                Text(live).font(Ink.secondary).foregroundStyle(Ink.accent).lineLimit(1)
                            }
                        } else {
                            Text(item.preview.isEmpty ? "…" : item.preview)
                                .font(Ink.secondary)
                                .foregroundStyle(Ink.inkSoft)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(.vertical, Ink.Space.m)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle(haptic: false))
            .contextMenu {
                Button("重命名", systemImage: "pencil") { startRename(item.id.id) }
                if team.pinned.contains(item.id.id) {
                    Button("取消置顶", systemImage: "pin.slash") { withAnimation(Ink.Motion.settle) { team.pin(item.id.id, false) } }
                } else {
                    Button("置顶", systemImage: "pin") { withAnimation(Ink.Motion.settle) { team.pin(item.id.id, true) } }
                }
                DeskThreadHelpers.archiveMenu(item.id.id, team: team, changeArchive: changeArchive)
                Menu(L.t("homeThreads.colorFilter"), systemImage: "tag") {
                    DeskThreadHelpers.labelChoices(selected: team.threadLabels[item.id.id] ?? "", clearTitle: L.t("homeThreads.removeColor")) {
                        team.setThreadLabel($0, for: item.id.id)
                    }
                }
                if case .gathering(let id) = item.id, let room = team.rooms.first(where: { $0.id == id }) {
                    Button(Words.t("改雅集"), systemImage: "pencil") { roomEditing = room }
                    // Asks first, like the swipe does: it cannot be undone.
                    Button(Words.t("散了这个雅集"), systemImage: "trash", role: .destructive) { clearing = item.id }
                } else if let bot = item.bot {
                    Button(Words.t("看名帖"), systemImage: "person.text.rectangle") { cardBot = bot }
                    Button(Words.t("清空这段絮语"), systemImage: "trash", role: .destructive) { clearing = item.id }
                }
            }
        }
    }

    private func swipes(_ item: DeskThread) -> [SwipeAction] {
        let key = item.id.id
        let pinned = team.pinned.contains(key)
        return [
            SwipeAction(title: pinned ? "取消置顶" : "置顶", symbol: pinned ? "pin.slash" : "pin", tint: Ink.Tile.xiang) {
                withAnimation(Ink.Motion.settle) { team.pin(key, !pinned) }
            },
            DeskThreadHelpers.archiveSwipe(key, team: team, changeArchive: changeArchive),
            SwipeAction(title: item.bot == nil ? "散了" : "清空", symbol: "trash", tint: Ink.Tile.yan) {
                clearing = item.id
            },
        ]
    }
}
