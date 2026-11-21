import SwiftUI
import UniformTypeIdentifiers

/// What the desk can open, one at a time.
enum Opened: Identifiable, Hashable {
    case companion(String)
    case gathering(String)

    var id: String {
        switch self {
        case .companion(let id): "bot-\(id)"
        case .gathering(let id): "room-\(id)"
        }
    }
}

/// The app's root: setting up a model first, then the desk.
struct ClioRoot: View {
    @StateObject private var team = TeamModel()
    @ObservedObject private var asker = Asker.shared
    @AppStorage("look.scheme") private var scheme = "system"
    @AppStorage("look.fps") private var fps = false
    @AppStorage("care.hitches") private var hitches = false
    @Environment(\.scenePhase) private var scenePhase
    /// Keeps the first-launch setup on screen through its last page, after the service is already connected.
    @State private var holdingSetup = false
    @State private var sheetForm: Asker.Form?
    @State private var dismissedForm: UUID?

    var body: some View {
        ZStack {
            Ink.paper.ignoresSafeArea()
            if let shot = Shots.name, ShotSettingsPage.names.contains(shot) {
                ShotSettingsPage(name: shot, team: team)
            } else if team.phase == .setup || holdingSetup {
                SetupView(team: team, first: true) { holdingSetup = false }
                    .transition(.blurReplace)
                    .onAppear { holdingSetup = true }
            } else {
                Desk(team: team)
                    .transition(.blurReplace)
            }
        }
        .background {
            if let token = Shots.readyToken {
                ShotReady(token: token)
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .onChange(of: fps, initial: true) { _, on in MeterWindow.set(on) }
        .onChange(of: hitches, initial: true) { _, on in Hitches.shared.set(on) }
        .animation(Ink.Motion.settle, value: team.phase)
        .animation(Ink.Motion.settle, value: holdingSetup)
        .tint(Ink.accent)
        .clioScheme(scheme)
        .sheet(item: $sheetForm, onDismiss: {
            // Swiped away: the slip is put away, and the companion hears so.
            if let shown = dismissedForm, asker.current?.id == shown { asker.cancel() }
            dismissedForm = nil
        }) { form in
            FormSheet(form: form).onAppear { dismissedForm = form.id }
        }
        .onChange(of: asker.current?.id) { _, id in
            guard let form = asker.current, form.id == id else { sheetForm = nil; return }
            guard form.inline else { sheetForm = form; return }
            // A short slip is answered in the conversation if that page is open; otherwise it comes up here.
            Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if asker.current?.id == id, !asker.inlineSeen { sheetForm = asker.current }
            }
        }
        .onChange(of: scenePhase) { _, now in
            if now == .active {
                KeepAwake.stop()
                team.wake()
            }
            // Still on screen for a moment: the last chance to ask for time in the background.
            if now == .inactive { team.keepGoingInBackground() }
            if now == .background {
                team.leaving()
                Hitches.shared.save()
                WidgetFeed.publish(team)
            }
        }
        .task {
            team.wake()
            // Messages set for later land in their chats while the app is open too.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                team.deliverDue()
                team.routinesIfDue()
            }
        }
    }
}

/// 案头: the companions, the gatherings, and the latest of each conversation.
struct Desk: View {
    @ObservedObject var team: TeamModel
    @State private var opened: Opened? = Shots.startsInChat ? .companion("chief") : nil
    @State private var editing: EditTarget?
    @State private var tuning = false
    @State private var settingsPage: String?
    @State private var gathering = false
    @State private var studying = false
    @State private var denning = false
    @State private var granting = false
    @State private var hilling = false
    @State private var importing = false
    @State private var notice: String?
    @State private var vaulting = false
    @State private var caring = false
    @State private var drawer = false
    @State private var picked: DrawerItem?
    @State private var roomEditing: RoomInfo?
    @State private var searching = false
    @State private var showArchived = false
    @State private var listFilter = 0
    /// How far a drag has moved the conversation (right to open the sidebar, left to close it).
    @State private var pull: CGFloat = 0
    /// The sidebar is out, the conversation pushed to the right.
    @State private var sideOpen = Shots.name == "sidebar"
    /// What a conversation calls to open the sidebar; one object for the desk's whole life (see `ChatPage.side`).
    @State private var sideControl = SideControl()
    /// The conversation being renamed from the sidebar, and the words typed so far.
    @State private var renamingKey: String?
    @State private var renameText = ""
    @State private var sideQuery = ""
    @State private var query = ""
    /// A conversation waiting for the user to confirm it should be emptied (or a gathering dissolved).
    @State private var clearing: Opened?

    private struct EditTarget: Identifiable {
        let id: String
        let bot: BotInfo?
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<11: "晨安"
        case 11..<13: "午安"
        case 13..<18: "午后好"
        case 18..<23: "晚上好"
        default: "夜深了"
        }
    }

    /// Conversations with something in them, newest first.
    private var recent: [(id: Opened, name: String, preview: String, at: Double, bot: BotInfo?)] {
        let bots = team.bots.compactMap { bot -> (Opened, String, String, Double, BotInfo?)? in
            guard let at = bot.lastAt else { return nil }
            return (.companion(bot.id), bot.name, bot.preview ?? "", at, bot)
        }
        let rooms = team.rooms.map { room in
            (Opened.gathering(room.id), room.name, room.preview ?? "还没有人说话", room.lastAt ?? 0, BotInfo?.none)
        }
        return (bots + rooms).sorted { $0.3 > $1.3 }.map { (id: $0.0, name: $0.1, preview: $0.2, at: $0.3, bot: $0.4) }
    }

    /// The conversations on the desk, without the ones put away.
    private var shownThreads: [(id: Opened, name: String, preview: String, at: Double, bot: BotInfo?)] {
        recent.filter { item in
            guard !team.archived.contains(item.id.id) else { return false }
            switch listFilter {
            case 1: return team.isWorking(item.id.id)
            case 2: return team.approvals.contains { $0.chat == item.id.id }
            case 3: return team.isUnread(item.id.id, at: item.at)
            default: return true
            }
        }
    }

    /// 全部 / 在做 / 等批准, shown once there is something to filter.
    @ViewBuilder
    private var filterChips: some View {
        let working = recent.filter { team.isWorking($0.id.id) }.count
        let waiting = recent.filter { item in team.approvals.contains { $0.chat == item.id.id } }.count
        let unread = recent.filter { team.isUnread($0.id.id, at: $0.at) }.count
        if recent.count > 1 || listFilter != 0 {
            HStack(spacing: Ink.Space.s) {
                ForEach([(0, "全部"), (1, working > 0 ? "在做 \(working)" : "在做"), (2, waiting > 0 ? "等批准 \(waiting)" : "等批准"), (3, unread > 0 ? "未读 \(unread)" : "未读")], id: \.0) { item in
                    Button {
                        Haptics.tick(0.4)
                        withAnimation(Ink.Motion.settle) { listFilter = item.0 }
                    } label: {
                        Text(item.1)
                            .font(.system(size: Ink.Size.small, weight: listFilter == item.0 ? .semibold : .regular))
                            .foregroundStyle(listFilter == item.0 ? Ink.accent : Ink.inkSoft)
                            .padding(.horizontal, Ink.Space.m)
                            .frame(height: 28)
                            .background(listFilter == item.0 ? Ink.accentWash : Ink.mine, in: .capsule)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
        }
    }

    // MARK: Sidebar

    private var sideWidth: CGFloat {
        let screen = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds.width ?? 390
        return min(340, screen * 0.82)
    }

    /// How far right the conversation sits.
    private var shift: CGFloat { max(0, (sideOpen ? sideWidth : 0) + pull) }

    private func startRename(_ key: String) {
        renameText = team.title(of: key) ?? ""
        renamingKey = key
    }

    private func openSide() {
        Haptics.light()
        withAnimation(Ink.Motion.unfold) { sideOpen = true; pull = 0 }
    }

    private func closeSide() {
        withAnimation(Ink.Motion.unfold) { sideOpen = false; pull = 0 }
    }

    /// Goes to a conversation from the sidebar.
    private func jump(_ target: Opened?) {
        closeSide()
        guard target != opened else { return }
        withAnimation(Ink.Motion.unfold) { opened = target }
    }

    private var sideThreads: [(id: Opened, name: String, preview: String, at: Double, bot: BotInfo?)] {
        let words = sideQuery.trimmingCharacters(in: .whitespaces).lowercased()
        return recent.filter { item in
            !team.archived.contains(item.id.id)
                && (words.isEmpty || item.name.lowercased().contains(words) || item.preview.lowercased().contains(words))
        }
    }

    /// Claude- and DSH-like: search, a new conversation, the places to go, pinned and recent conversations,
    /// and settings at the bottom. It lies under the conversation; swiping from the left edge or the ☰ brings it out.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Ink.Space.s) {
                HStack(alignment: .center, spacing: Ink.Space.s) {
                    Text("Clio").font(Ink.wordmark((34 * UIScale.factor).rounded())).foregroundStyle(Ink.ink)
                    ClioSeal(size: (20 * UIScale.factor).rounded())
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Clio")
                .accessibilityAddTraits(.isHeader)
                Spacer()
                Button {
                    Haptics.light()
                    if case .companion(let id) = opened { team.turnLeaf("bot-" + id) }
                    closeSide()
                } label: {
                    Label("新对话", systemImage: "square.and.pencil")
                        .font(.system(size: Ink.Size.sub, weight: .semibold))
                        .foregroundStyle(Ink.paper)
                        .padding(.horizontal, 14)
                        .frame(height: 38)
                        .background(Ink.ink, in: .capsule)
                }
                .buttonStyle(PressStyle(haptic: false))
            }
            .padding(.horizontal, Ink.Space.l)
            .padding(.top, Ink.Space.s)

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

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if sideQuery.isEmpty {
                        sideNav("house", Words.t("案头")) { jump(nil) }
                        sideNav("books.vertical", Words.t("书案")) { closeSide(); studying = true }
                        sideNav("terminal", Words.t("斗室")) { closeSide(); denning = true }
                    }
                    ForEach(Self.grouped(sideThreads, pinned: team.pinned), id: \.title) { group in
                        Text(group.title)
                            .font(.system(size: Ink.Size.small, weight: .semibold))
                            .foregroundStyle(Ink.inkFaint)
                            .padding(.horizontal, Ink.Space.l)
                            .padding(.top, Ink.Space.l)
                            .padding(.bottom, 4)
                        ForEach(group.items, id: \.id) { item in
                            sideThread(item)
                        }
                    }
                    if sideThreads.isEmpty {
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

    private func sideThread(_ item: (id: Opened, name: String, preview: String, at: Double, bot: BotInfo?)) -> some View {
        let here = item.id == opened
        let key = item.id.id
        return Button {
            Haptics.light()
            jump(item.id)
        } label: {
            HStack(spacing: Ink.Space.s) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.system(size: Ink.Size.sub, weight: here ? .semibold : .regular)).foregroundStyle(Ink.ink).lineLimit(1)
                    // What the conversation is about (its title, which you can rename), else its last words.
                    let line = team.title(of: key) ?? item.preview
                    if !line.isEmpty {
                        Text(line).font(.system(size: Ink.Size.small)).foregroundStyle(Ink.inkFaint).lineLimit(1)
                    }
                }
                Spacer(minLength: Ink.Space.s)
                if team.approvals.contains(where: { $0.chat == key }) {
                    Image(systemName: "exclamationmark.circle").font(.system(size: Ink.Size.sub)).foregroundStyle(Ink.warn)
                } else if team.isWorking(key) {
                    ProgressView().controlSize(.mini)
                } else if team.isUnread(key, at: item.at) {
                    Circle().fill(Ink.accent).frame(width: 7, height: 7)
                }
            }
            .padding(.horizontal, Ink.Space.m)
            .padding(.vertical, 9)
            .background(here ? Ink.paperRaised : Color.clear, in: .rect(cornerRadius: Ink.Radius.small, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(haptic: false))
        .contextMenu {
            Button(team.pinned.contains(key) ? "取消置顶" : "置顶", systemImage: team.pinned.contains(key) ? "pin.slash" : "pin") {
                withAnimation(Ink.Motion.settle) { team.pin(key, !team.pinned.contains(key)) }
            }
            Button("重命名", systemImage: "pencil") { startRename(key) }
        }
    }

    private var archivedThreads: [(id: Opened, name: String, preview: String, at: Double, bot: BotInfo?)] {
        recent.filter { team.archived.contains($0.id.id) }
    }

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    companions
                    waitingCard
                    if let next = team.nextLetter { letter(next) }
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
                    if searching {
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
                    }
                    if searching && !query.trimmingCharacters(in: .whitespaces).isEmpty {
                        let hits = team.search(query)
                        if hits.isEmpty {
                            Text("没找到「\(query)」。").font(Ink.secondary).foregroundStyle(Ink.inkSoft).padding(.vertical, Ink.Space.l)
                        }
                        ForEach(hits) { hit in
                            Button {
                                Haptics.light()
                                if let leaf = hit.leaf, let found = team.leaves(hit.key).first(where: { $0.id == leaf }) {
                                    team.openLeaf(hit.key, found)
                                }
                                if hit.key.hasPrefix("bot-") { opened = .companion(String(hit.key.dropFirst(4))) } else { opened = .gathering(String(hit.key.dropFirst(5))) }
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
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
                            Rectangle().fill(Ink.rule).frame(height: 1)
                        }
                    } else {
                    TideChip(keeper: team.bots.first { $0.id == team.mainBotId }?.name ?? team.bots.first?.name ?? Words.t("旅伴"))
                    filterChips
                    if shownThreads.isEmpty {
                        EmptyNote(
                            symbol: recent.isEmpty ? "bubble.left.and.bubble.right" : "archivebox",
                            words: recent.isEmpty ? L.t("empty.startConversation") : L.t("empty.activeConversations")
                        )
                    }
                    ForEach(Self.grouped(shownThreads, pinned: team.pinned), id: \.title) { group in
                        Text(group.title)
                            .font(.system(size: Ink.Size.small, weight: .medium))
                            .foregroundStyle(Ink.inkFaint)
                            .padding(.top, Ink.Space.m)
                        ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                            thread(item)
                            if index != group.items.count - 1 {
                                Kit.rule(inset: 40)
                            }
                        }
                    }
                    if !archivedThreads.isEmpty {
                        Button {
                            Haptics.light()
                            withAnimation(Ink.Motion.unfold) { showArchived.toggle() }
                        } label: {
                            HStack(spacing: Ink.Space.s) {
                                Image(systemName: "archivebox").font(.system(size: Ink.Size.small))
                                Text("已归档 \(archivedThreads.count) 段").font(.system(size: Ink.Size.sub, weight: .medium))
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
                            ForEach(archivedThreads, id: \.id) { item in
                                thread(item)
                                    .opacity(0.75)
                                Kit.rule(inset: 40)
                            }
                        }
                    }
                    }
                }
                .padding(.horizontal, Ink.Space.page)
                .padding(.bottom, Ink.Space.huge)
            }
            .scrollIndicators(.hidden)
            .opacity(opened == nil ? 1 : 0)
            .scaleEffect(opened == nil ? 1 : 0.96)

            // The sidebar lies under the conversation and comes out as the conversation slides to the right.
            if opened != nil {
                sidebar
                    .frame(width: sideWidth)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(min(1, shift / sideWidth * 1.3))
            }

            if let opened {
                page(for: opened)
                    .clipShape(RoundedRectangle(cornerRadius: shift > 0 ? 28 : 0, style: .continuous))
                    // The shadow is cast by a plain rounded sheet of paper under the page, not by the page itself:
                    // shadowing the page made iOS trace every word and button for each frame of the slide.
                    .background {
                        RoundedRectangle(cornerRadius: shift > 0 ? 28 : 0, style: .continuous)
                            .fill(Ink.paper)
                            .shadow(color: .black.opacity(shift > 0 ? 0.22 : 0), radius: 20, x: -4)
                    }
                    .overlay {
                        // Open sidebar: a tap on the conversation's edge closes it.
                        if sideOpen {
                            Color.black.opacity(0.001)
                                .onTapGesture { closeSide() }
                        }
                    }
                    .offset(x: shift)
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .trailing)))
                    .zIndex(1)
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 10, coordinateSpace: .global)
                            .onChanged { value in
                                let across = value.translation.width
                                guard abs(value.translation.height) < max(60, abs(across)) else { return }
                                if sideOpen {
                                    pull = min(0, across)
                                } else if value.startLocation.x < 32, across > 0 {
                                    pull = min(across, sideWidth)
                                }
                            }
                            .onEnded { value in
                                guard pull != 0 else { return }
                                let fling = value.predictedEndTranslation.width
                                if sideOpen {
                                    if -pull > sideWidth * 0.3 || fling < -180 { closeSide() } else { withAnimation(Ink.Motion.settle) { pull = 0 } }
                                } else {
                                    if pull > sideWidth * 0.35 || fling > 220 { openSide() } else { withAnimation(Ink.Motion.settle) { pull = 0 } }
                                }
                            }
                    )
            }
        }
        .animation(Ink.Motion.unfold, value: opened)
        .onAppear { sideControl.open = { openSide() } }
        .alert("重命名对话", isPresented: Binding(get: { renamingKey != nil }, set: { if !$0 { renamingKey = nil } })) {
            TextField("对话标题", text: $renameText)
            Button(L.t("actions.cancel"), role: .cancel) { renamingKey = nil }
            Button(L.t("actions.save")) {
                if let key = renamingKey { team.rename(key, to: renameText) }
                renamingKey = nil
            }
        }
        .onChange(of: opened) { _, _ in
            if sideOpen || pull != 0 { sideOpen = false; pull = 0 }
        }
        .animation(Ink.Motion.settle, value: team.approvals.count)
        .sheet(isPresented: $drawer, onDismiss: {
            // Open what was picked once the drawer is out of the way.
            if let item = picked {
                picked = nil
                open(item)
            }
        }) {
            DrawerSheet { picked = $0 }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $editing) { target in BotEditor(team: team, bot: target.bot) }
        .sheet(isPresented: $gathering) { RoomEditor(team: team) }
        .sheet(item: $roomEditing) { room in RoomEditor(team: team, room: room) }
        .sheet(isPresented: $studying) { StudyPage() }
        .fullScreenCover(isPresented: $denning) { DenPage() }
        .sheet(isPresented: $granting) { GrantsPage(team: team) }
        .sheet(isPresented: $hilling) { HillsPage() }
        .sheet(isPresented: $vaulting) { SecretsPage() }
        .sheet(isPresented: $caring) { CarePage(team: team) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .plainText, .data]) { result in
            switch result {
            case .failure(let error): notice = "没打开：\(error.localizedDescription)"
            case .success(let url):
                do {
                    let card = try NameCard.read(url)
                    let taken = Set(team.bots.map(\.name))
                    var name = card.name
                    if taken.contains(name) { name += "·二" }
                    Task {
                        do {
                            try await team.saveBot(id: nil, name: name, role: card.role ?? "", color: card.color ?? "dai", instructions: card.instructions)
                            Haptics.thud()
                            notice = Words.t("收下了\(name)的名帖。")
                        } catch {
                            notice = "没收下：\(error.localizedDescription)"
                        }
                    }
                } catch {
                    notice = error.localizedDescription
                }
            }
        }
        .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("好", role: .cancel) { notice = nil }
        }
        .fullScreenCover(isPresented: $tuning, onDismiss: {
            settingsPage = nil
        }) {
            SettingsView(team: team, startAt: settingsPage)
        }
        .confirmationDialog(clearingTitle, isPresented: Binding(get: { clearing != nil }, set: { if !$0 { clearing = nil } }), titleVisibility: .visible) {
            Button(clearingIsRoom ? "散了" : "清空", role: .destructive) {
                guard let target = clearing else { return }
                switch target {
                case .gathering(let id): team.deleteRoom(id)
                case .companion: team.clearChat(target.id)
                }
                Haptics.thud()
                clearing = nil
            }
            Button("算了", role: .cancel) { clearing = nil }
        } message: {
            Text(clearingIsRoom ? Words.t("雅集和里面的话都会删掉，旅伴们还在。") : Words.t("这段絮语和收起的旧叶都会删掉，删了找不回来。旅伴和拾遗都还在。"))
        }
        .onReceive(NotificationCenter.default.publisher(for: .clioOpenChat)) { note in
            guard let chat = note.object as? String else { return }
            if chat.hasPrefix("room-") { opened = .gathering(String(chat.dropFirst(5))) } else if chat.hasPrefix("bot-") { opened = .companion(String(chat.dropFirst(4))) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .clioShortcut)) { _ in answerShortcut() }
        .onOpenURL { url in
            // The home-screen widget: clio://chat/bot-…. Control Center and the Action Button: clio://ask, clio://dictate.
            // Shared from another app: the file waits in the newest conversation's composer.
            if url.isFileURL {
                ShortcutDoor.knock(.files([url]))
                return
            }
            guard url.scheme == "clio" else { return }
            switch url.host {
            case "chat": NotificationCenter.default.post(name: .clioOpenChat, object: url.lastPathComponent)
            case "ask": ShortcutDoor.knock(.ask(""))
            case "dictate": ShortcutDoor.knock(.dictate)
            case "new": ShortcutDoor.knock(.fresh)
            case "settings":
                settingsPage = url.pathComponents.dropFirst().first.map { page in
                    url.fragment.map { page + "#" + $0 } ?? page
                }
                tuning = true
            default: break
            }
        }
        .task { answerShortcut() }
    }

    /// Siri or a shortcut: the newest conversation, or a fresh leaf with the newest companion. Nothing is sent.
    private func answerShortcut() {
        guard let ask = ShortcutDoor.pending else { return }
        ShortcutDoor.pending = nil
        let newestCompanion = recent.first { thread in
            if case .companion = thread.id { return true }
            return false
        }?.id ?? team.bots.first.map { Opened.companion($0.id) }
        let target = ask == .fresh ? newestCompanion : (recent.first?.id ?? newestCompanion)
        guard let target else { return }
        if ask == .fresh { team.turnLeaf(target.id) }
        ShortcutDoor.forChat[target.id] = ask
        if opened == target {
            NotificationCenter.default.post(name: .clioShortcutReady, object: nil)
        } else {
            opened = target
        }
    }

    private var clearingIsRoom: Bool {
        if case .gathering = clearing { return true }
        return false
    }

    private var clearingTitle: String {
        guard let target = clearing else { return "" }
        return Words.t(clearingIsRoom ? "散了这个雅集？" : "清空和\(recent.first { $0.id == target }?.name ?? "旅伴")的絮语？")
    }

    private func open(_ item: DrawerItem) {
        switch item {
        case .newCompanion: editing = EditTarget(id: "new", bot: nil)
        case .importCard: importing = true
        case .gathering: gathering = true
        case .study: studying = true
        case .den: denning = true
        case .hills: hilling = true
        case .vault: vaulting = true
        case .tuning: tuning = true
        case .look: settingsPage = "look"; tuning = true
        case .grants: granting = true
        case .care: caring = true
        }
    }

    @ViewBuilder
    private func page(for target: Opened) -> some View {
        switch target {
        case .companion(let id):
            if let bot = team.bots.first(where: { $0.id == id }) {
                ChatPage(team: team, bot: bot, side: sideControl)
                    .id(target.id)
            }
        case .gathering(let id):
            if let room = team.rooms.first(where: { $0.id == id }) {
                ChatPage(team: team, room: room, side: sideControl)
                    .id(target.id)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: Ink.Space.s) {
                Text(greeting).font(Ink.display).foregroundStyle(Ink.ink)
                Text("今天想聊点什么？").font(Ink.reading).foregroundStyle(Ink.inkSoft)
            }
            Spacer()
            HStack(spacing: Ink.Space.s) {
                Menu {
                    Button(Words.t("新旅伴"), systemImage: "person.badge.plus") { open(.newCompanion) }
                    Button(Words.t("开一场雅集"), systemImage: "person.3") { open(.gathering) }
                    Button(Words.t("收名帖"), systemImage: "square.and.arrow.down") { open(.importCard) }
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
                        .padding(.leading, Ink.Space.xs + 2)
                        .padding(.trailing, Ink.Space.l)
                        .frame(height: 40)
                        .background(Ink.paperRaised, in: .capsule)
                        .overlay(Capsule().strokeBorder(Ink.rule, lineWidth: 1))
                    }
                    .buttonStyle(PressStyle(haptic: false))
                    .contextMenu {
                        Button(Words.t("看名帖"), systemImage: "person.text.rectangle") { editing = EditTarget(id: bot.id, bot: bot) }
                        ShareLink(item: NameCard.file(for: bot)) { Label(Words.t("递名帖"), systemImage: "square.and.arrow.up") }
                    }
                }
                Button {
                    editing = EditTarget(id: "new", bot: nil)
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

    /// Slips waiting for the user's seal, any conversation: one card, tap to go there.
    @ViewBuilder
    private var waitingCard: some View {
        if let first = team.approvals.first, let chat = first.chat {
            let name = team.bots.first { $0.id == first.botId }?.name ?? "旅伴"
            Button {
                Haptics.tick(0.6)
                if chat.hasPrefix("room-") { opened = .gathering(String(chat.dropFirst(5))) } else { opened = .companion(String(chat.dropFirst(4))) }
            } label: {
                HStack(spacing: Ink.Space.m) {
                    Image(systemName: "seal")
                        .font(.system(size: Ink.Size.body, weight: .semibold))
                        .foregroundStyle(Ink.warn)
                        .frame(width: 34, height: 34)
                        .background(Ink.warn.opacity(0.14), in: .circle)
                    VStack(alignment: .leading, spacing: 2) {
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
            VStack(alignment: .leading, spacing: 2) {
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

    private func swipes(_ item: (id: Opened, name: String, preview: String, at: Double, bot: BotInfo?)) -> [SwipeAction] {
        let key = item.id.id
        let archived = team.archived.contains(key)
        let pinned = team.pinned.contains(key)
        return [
            SwipeAction(title: pinned ? "取消置顶" : "置顶", symbol: pinned ? "pin.slash" : "pin", tint: Ink.Tile.xiang) {
                withAnimation(Ink.Motion.settle) { team.pin(key, !pinned) }
            },
            SwipeAction(title: archived ? "拿回来" : "归档", symbol: archived ? "tray.and.arrow.up" : "archivebox", tint: Ink.Tile.accent) {
                withAnimation(Ink.Motion.settle) { team.archive(key, !archived) }
            },
            SwipeAction(title: item.bot == nil ? "散了" : "清空", symbol: "trash", tint: Ink.Tile.yan) {
                clearing = item.id
            },
        ]
    }

    /// 今天 / 昨天 / 本周 / 更早, newest first, empty groups left out.
    /// 已置顶 first (in the order pinned), then the rest by day.
    static func grouped(_ items: [(id: Opened, name: String, preview: String, at: Double, bot: BotInfo?)], pinned: [String]) -> [(title: String, items: [(id: Opened, name: String, preview: String, at: Double, bot: BotInfo?)])] {
        let top = pinned.compactMap { key in items.first { $0.id.id == key } }
        let rest = byDay(items.filter { !pinned.contains($0.id.id) })
        return top.isEmpty ? rest : [("已置顶", top)] + rest
    }

    static func byDay(_ items: [(id: Opened, name: String, preview: String, at: Double, bot: BotInfo?)]) -> [(title: String, items: [(id: Opened, name: String, preview: String, at: Double, bot: BotInfo?)])] {
        let calendar = Calendar.current
        let now = Date()
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: now)) ?? now
        func title(_ at: Double) -> String {
            let date = Date(timeIntervalSince1970: at / 1000)
            if calendar.isDateInToday(date) { return "今天" }
            if calendar.isDateInYesterday(date) { return "昨天" }
            return date >= weekAgo ? "本周" : "更早"
        }
        var groups: [(title: String, items: [(id: Opened, name: String, preview: String, at: Double, bot: BotInfo?)])] = []
        for item in items {
            let name = title(item.at)
            if let index = groups.firstIndex(where: { $0.title == name }) { groups[index].items.append(item) } else { groups.append((name, [item])) }
        }
        return groups
    }

    private func thread(_ item: (id: Opened, name: String, preview: String, at: Double, bot: BotInfo?)) -> some View {
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
                .padding(.top, 2)
                VStack(alignment: .leading, spacing: Ink.Space.xs) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.name).font(Ink.readingBold).foregroundStyle(Ink.ink)
                        Spacer()
                        Text(Self.when(item.at)).font(Ink.footnote).foregroundStyle(Ink.inkFaint)
                    }
                    if let live = Live.brief(team.doing[item.id.id], waiting: team.approvals.contains { $0.chat == item.id.id }) {
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
            if team.archived.contains(item.id.id) {
                Button("从归档里拿回来", systemImage: "tray.and.arrow.up") { withAnimation(Ink.Motion.settle) { team.archive(item.id.id, false) } }
            } else {
                Button("归档", systemImage: "archivebox") {
                    withAnimation(Ink.Motion.settle) { team.archive(item.id.id, true) }
                    Haptics.tick(0.5)
                }
            }
            if case .gathering(let id) = item.id, let room = team.rooms.first(where: { $0.id == id }) {
                Button(Words.t("改雅集"), systemImage: "pencil") { roomEditing = room }
                Button(Words.t("散了这个雅集"), systemImage: "trash", role: .destructive) { team.deleteRoom(id) }
            } else if let bot = item.bot {
                Button(Words.t("看名帖"), systemImage: "person.text.rectangle") { editing = EditTarget(id: bot.id, bot: bot) }
                Button(Words.t("清空这段絮语"), systemImage: "trash", role: .destructive) { clearing = item.id }
            }
        }
        }
    }

    /// 「方才」「14:20」「昨日」「周一」「11月3日」
    static func when(_ ms: Double) -> String {
        guard ms > 0 else { return "" }
        let date = Date(timeIntervalSince1970: ms / 1000)
        let calendar = Calendar.current
        if Date().timeIntervalSince(date) < 120 { return "方才" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        if calendar.isDateInToday(date) { formatter.dateFormat = "HH:mm"; return formatter.string(from: date) }
        if calendar.isDateInYesterday(date) { return "昨日" }
        if let days = calendar.dateComponents([.day], from: date, to: Date()).day, days < 7 { formatter.dateFormat = "EEE"; return formatter.string(from: date) }
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }
}


/// A small dot that breathes while a conversation is at work.
struct BreathingDot: View {
    @State private var full = false

    var body: some View {
        Circle()
            .fill(Ink.accent)
            .frame(width: 6, height: 6)
            .opacity(full ? 1 : 0.35)
            .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: full)
            .onAppear { full = true }
            .accessibilityHidden(true)
    }
}


/// The sidebar's "open" for a conversation page: the same object every time the desk is drawn.
@MainActor
final class SideControl {
    var open: () -> Void = {}
}
