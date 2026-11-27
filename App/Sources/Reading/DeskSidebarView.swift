import SwiftUI

/// Slide-out conversation drawer showing unified search trigger, 4+1 capabilities, pinned/recent/earlier/archived threads, and settings footer.
struct DeskSidebarView: View {
    @ObservedObject var team: TeamModel
    let opened: Opened?
    @Binding var listFilter: Int
    @Binding var labelFilter: String
    @Binding var studying: Bool
    @Binding var denning: Bool
    @Binding var tuning: Bool

    let closeSide: () -> Void
    let startFresh: () -> Void
    let openUnifiedSearch: () -> Void
    let openCompanions: () -> Void
    let openMemory: () -> Void
    let openBrowser: () -> Void
    let openHosts: () -> Void
    let openTiming: () -> Void
    let jump: (Opened?) -> Void
    let startRename: (String) -> Void
    let startRenamePast: (DeskPastLeaf) -> Void
    let requestDelete: (DeskSideConversation) -> Void
    let changeArchive: (String, Bool) -> Void

    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showArchived = false

    private var recent: [DeskThread] {
        DeskThreadHelpers.recent(team: team)
    }

    private var shownThreads: [DeskThread] {
        recent.filter {
            DeskThreadHelpers.matchesFilter($0, team: team, listFilter: listFilter, labelFilter: labelFilter)
        }
    }

    private var sideSections: [DeskSideSection] {
        let past = DeskThreadHelpers.pastLeaves(
            team: team,
            matching: "",
            listFilter: listFilter,
            labelFilter: labelFilter
        )
        return DeskThreadHelpers.sections(team: team, threads: shownThreads, past: past, byDate: true)
    }

    private var archivedRows: [DeskSideConversation] {
        DeskThreadHelpers.archivedRows(team: team, recent: recent)
    }

    var body: some View {
        let sections = sideSections
        let archived = archivedRows
        VStack(alignment: .leading, spacing: 0) {
            topHeader
            searchButton
            DeskFilterChips(listFilter: $listFilter, labelFilter: $labelFilter)
                .padding(.horizontal, Ink.Space.l)
                .padding(.bottom, Ink.Space.s)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
                    primaryPlaces
                    workspaceQuickBar
                    threadList(sections: sections, archived: archived)
                }
                .padding(.horizontal, Ink.Space.s)
                .padding(.bottom, Ink.Space.l)
            }
            .scrollIndicators(.hidden)
            .scrollEdgeEffectStyle(.soft, for: .vertical)
            .scrollDismissesKeyboard(.interactively)

            settingsFooter
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

    private var searchButton: some View {
        Button {
            Haptics.light()
            closeSide()
            openUnifiedSearch()
        } label: {
            HStack(spacing: Ink.Space.s) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: Ink.Size.sub))
                    .foregroundStyle(Ink.inkFaint)
                Text(L.t("unifiedSearch.sidebarPrompt"))
                    .font(.system(size: Ink.Size.sub))
                    .foregroundStyle(Ink.inkFaint)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Ink.Space.m)
            .frame(height: 40 * UIScale.factor)
            .background(Ink.paperRaised, in: Capsule())
            .overlay(Capsule().strokeBorder(Ink.rule, lineWidth: 0.5))
            .padding(.horizontal, Ink.Space.l)
            .padding(.vertical, Ink.Space.m)
        }
        .buttonStyle(PressStyle(haptic: false))
        .accessibilityLabel(L.t("unifiedSearch.title"))
    }

    private var primaryPlaces: some View {
        VStack(spacing: 0) {
            sideNav("house", L.t("nav.home")) { jump(nil) }
            sideNav(
                "person.2",
                L.t("sidebar.companions"),
                count: team.bots.isEmpty ? nil : "\(team.bots.count)"
            ) {
                closeSide()
                openCompanions()
            }
            sideNav(
                "brain",
                L.t("nav.memory"),
                count: team.memories.isEmpty ? nil : "\(team.memories.count)"
            ) {
                closeSide()
                openMemory()
            }
            sideNav("books.vertical", L.t("nav.files")) {
                closeSide()
                studying = true
            }
        }
    }

    private var workspaceQuickBar: some View {
        let twoByTwo = typeSize.isAccessibilitySize
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: Ink.Space.xs),
            count: twoByTwo ? 2 : 4
        )
        return VStack(alignment: .leading, spacing: Ink.Space.xs) {
            Text(L.t("sidebar.workspace"))
                .font(.system(size: Ink.Size.micro, weight: .semibold))
                .foregroundStyle(Ink.inkFaint)
                .padding(.horizontal, Ink.Space.m)
                .padding(.top, Ink.Space.s)
            LazyVGrid(columns: columns, spacing: Ink.Space.xs) {
                workspaceTile("terminal", L.t("nav.terminal")) { closeSide(); denning = true }
                workspaceTile("safari", L.t("nav.browser")) { closeSide(); openBrowser() }
                workspaceTile("server.rack", L.t("nav.remoteHost")) { closeSide(); openHosts() }
                workspaceTile("alarm", L.t("agent.scheduledJobs")) { closeSide(); openTiming() }
            }
            .padding(.horizontal, Ink.Space.m)
            .padding(.bottom, Ink.Space.xs)
        }
    }

    private func workspaceTile(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.light()
            action()
        } label: {
            VStack(spacing: Ink.Space.xs) {
                Image(systemName: symbol)
                    .font(.system(size: Ink.Size.sub, weight: .medium))
                    .foregroundStyle(Ink.inkSoft)
                Text(title)
                    .font(.system(size: Ink.Size.micro))
                    .foregroundStyle(Ink.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50 * UIScale.factor)
            .background(Ink.paperRaised, in: RoundedRectangle(cornerRadius: Ink.Radius.small, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Ink.Radius.small, style: .continuous)
                    .strokeBorder(Ink.rule, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(haptic: false))
    }

    @ViewBuilder
    private func threadList(sections: [DeskSideSection], archived: [DeskSideConversation]) -> some View {
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
        if !archived.isEmpty {
            archivedDisclosure(archived)
        }
        if sections.isEmpty && archived.isEmpty {
            Text(L.t("sidebar.noThreads"))
                .font(Ink.secondary)
                .foregroundStyle(Ink.inkSoft)
                .padding(Ink.Space.l)
        }
    }

    @ViewBuilder
    private func archivedDisclosure(_ archived: [DeskSideConversation]) -> some View {
        Button {
            Haptics.light()
            withAnimation(Ink.Motion.unfold) { showArchived.toggle() }
        } label: {
            HStack(spacing: Ink.Space.s) {
                Image(systemName: "archivebox")
                    .font(.system(size: Ink.Size.small))
                Text("\(L.t("sidebar.archived")) \(archived.count)")
                    .font(.system(size: Ink.Size.small, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: Ink.Size.micro, weight: .semibold))
                    .rotationEffect(.degrees(showArchived ? 180 : 0))
                Spacer()
            }
            .foregroundStyle(Ink.inkFaint)
            .padding(.horizontal, Ink.Space.l)
            .padding(.top, Ink.Space.l)
            .padding(.bottom, Ink.Space.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(haptic: false))

        if showArchived {
            ForEach(archived) { row in
                Group {
                    switch row {
                    case .current(let item): sideThread(item)
                    case .past(let past): pastRow(past)
                    }
                }
                .opacity(0.76)
            }
        }
    }

    private var settingsFooter: some View {
        let toneName = Theme.shared.plain ? L.t("styleSwitcher.dailyLabel") : L.t("styleSwitcher.literaryLabel")
        let summary = "\(L.format("settingsHome.companionsCount", team.bots.count)) · \(toneName)"
        return VStack(spacing: 0) {
            Kit.rule(inset: 0)
            Button {
                Haptics.light()
                closeSide()
                tuning = true
            } label: {
                HStack(spacing: Ink.Space.m) {
                    Image(systemName: "gearshape")
                        .font(.system(size: Ink.Size.body))
                        .foregroundStyle(Ink.inkSoft)
                        .frame(width: 26)
                    Text(L.t("nav.settings"))
                        .font(.system(size: Ink.Size.body))
                        .foregroundStyle(Ink.ink)
                    Spacer()
                    Text(summary)
                        .font(.system(size: Ink.Size.small))
                        .foregroundStyle(Ink.inkFaint)
                }
                .padding(.horizontal, Ink.Space.s + Ink.Space.m)
                .frame(height: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle(haptic: false))
        }
    }

    private func sideNav(_ icon: String, _ title: String, count: String? = nil, _ run: @escaping () -> Void) -> some View {
        Button {
            Haptics.light()
            run()
        } label: {
            HStack(spacing: Ink.Space.m) {
                Image(systemName: icon)
                    .font(.system(size: Ink.Size.body))
                    .foregroundStyle(Ink.inkSoft)
                    .frame(width: 26)
                Text(title)
                    .font(.system(size: Ink.Size.body))
                    .foregroundStyle(Ink.ink)
                Spacer()
                if let count {
                    Text(count)
                        .font(.system(size: Ink.Size.small).monospacedDigit())
                        .foregroundStyle(Ink.inkFaint)
                }
            }
            .padding(.horizontal, Ink.Space.m)
            .frame(height: 42 * UIScale.factor)
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
        if case .current(let item) = row, case .companion(let botID) = item.id {
            Button(L.t("casual.openAction"), systemImage: "bubble.left.and.text.bubble.right") {
                CasualTrackDoor.pendingBotID = botID
                jump(item.id)
                NotificationCenter.default.post(name: .clioOpenCasualTrack, object: botID)
            }
        }
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
