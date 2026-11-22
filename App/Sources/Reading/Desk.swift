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
    @ObservedObject private var team = TeamModel.shared
    @AppStorage("look.scheme") private var scheme = "system"
    @AppStorage("look.fps") private var fps = false
    @AppStorage("care.hitches") private var hitches = false
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(SetupView.introSeen) private var introSeen = false

    var body: some View {
        ZStack {
            Ink.paper.ignoresSafeArea()
            if let shot = Shots.name, ShotSettingsPage.names.contains(shot) {
                ShotSettingsPage(name: shot, team: team)
            } else if team.loading {
                ProgressView(L.t("loading.generic"))
            } else if team.phase == .setup && !introSeen {
                SetupView(team: team, first: true, welcomeOnly: true) { introSeen = true }
                    .transition(.blurReplace)
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
        .animation(Ink.Motion.settle, value: introSeen)
        .tint(Ink.accent)
        .clioScheme(scheme)
        .modifier(FormPresenter(inBrowser: false))
        .onChange(of: scenePhase) { _, now in
            if now == .active {
                KeepAwake.stop()
                team.wake()
                MemoryNight.tick()
            }
            if now == .background {
                team.keepGoingInBackground()
                MemoryNight.cancelForeground()
                MemoryNight.schedule()
                team.leaving()
                ChatDisk.finishBeforeSuspension()
                Hitches.shared.save()
                WidgetFeed.publish(team)
            }
        }
        .task {
            await team.prepare()
            team.wake()
            MemoryNight.tick()
            // Messages set for later land in their chats while the app is open too.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                team.deliverDue()
                team.routinesIfDue()
                MemoryNight.tick()
            }
        }
    }
}

/// 案头: the companions, the gatherings, and the latest of each conversation.
struct Desk: View {
    @ObservedObject var team: TeamModel
    @State private var deskWidth: CGFloat = 0
    @State private var opened: Opened? = Shots.startsInChat ? .companion("chief") : nil
    @State private var editing: EditTarget?
    @State private var tuning = false
    /// 新对话 asks first, like HanaAgent: with whom, and whether this one looks at memory.
    @State private var startingFresh = false
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
    @AppStorage("desk.threadFilter") private var listFilter = 0
    @AppStorage("desk.threadColorFilter") private var labelFilter = ""
    @Environment(\.scenePhase) private var scenePhase
    @State private var addingService = false
    @State private var archiveUndo: ArchiveUndo?

    private struct ArchiveUndo: Equatable {
        let key: String
        let expires: Date
    }
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
    @State private var searchHits: [TeamModel.Hit] = []
    /// A conversation waiting for the user to confirm it should be emptied (or a gathering dissolved).
    @State private var clearing: Opened?

    /// 看名帖: the card, large.
    @State private var cardBot: BotInfo?

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

    private typealias Thread = (id: Opened, name: String, preview: String, at: Double, bot: BotInfo?)

    private var shownThreads: [Thread] { recent.filter(matchesFilter) }

    private func matchesFilter(_ item: Thread) -> Bool {
        let key = item.id.id
        guard !team.archived.contains(key),
              labelFilter.isEmpty || team.threadLabels[key] == labelFilter else { return false }
        switch listFilter {
        case 1: return team.isWorking(key)
        case 2: return team.approvals.contains { $0.chat == key }
        case 3: return team.isUnread(key, at: item.at)
        default: return true
        }
    }

    private var filterChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Ink.Space.s) {
                ForEach(["all", "working", "waiting", "unread"].enumerated().map { ($0.offset, $0.element) }, id: \.0) { index, label in
                    Button {
                        withAnimation(Ink.Motion.settle) { listFilter = index }
                    } label: {
                        Text(L.t("homeThreads." + label))
                            .font(.system(size: Ink.Size.small, weight: listFilter == index ? .semibold : .regular))
                            .foregroundStyle(listFilter == index ? Ink.accent : Ink.inkSoft)
                            .padding(.horizontal, Ink.Space.m)
                            .padding(.vertical, Ink.Space.s)
                            .background(listFilter == index ? Ink.accentWash : Ink.mine, in: .capsule)
                    }
                    .buttonStyle(PressStyle())
                    .accessibilityAddTraits(listFilter == index ? .isSelected : [])
                }
                Menu {
                    labelChoices(selected: labelFilter, clearTitle: L.t("homeThreads.allColors")) { labelFilter = $0 }
                } label: {
                    Label(ThreadLabel(rawValue: labelFilter)?.title ?? L.t("homeThreads.colorFilter"), systemImage: "tag")
                        .font(Ink.footnote)
                        .foregroundStyle(labelFilter.isEmpty ? Ink.inkSoft : Ink.accent)
                        .padding(.horizontal, Ink.Space.m)
                        .padding(.vertical, Ink.Space.s)
                        .background(labelFilter.isEmpty ? Ink.mine : Ink.accentWash, in: .capsule)
                }
            }
        }
        .scrollIndicators(.hidden)
        // The last chip fades out at the edge instead of being cut by a hard line, so it reads as 「more this way」.
        .mask {
            HStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: Ink.Space.xl)
            }
        }
    }

    @ViewBuilder
    private func labelChoices(selected: String, clearTitle: String, pick: @escaping (String) -> Void) -> some View {
        Button { pick("") } label: {
            if selected.isEmpty { Label(clearTitle, systemImage: "checkmark") }
            else { Text(clearTitle) }
        }
        ForEach(ThreadLabel.allCases) { label in
            Button { pick(label.rawValue) } label: {
                Label(label.title, systemImage: selected == label.rawValue ? "checkmark" : "circle.fill")
            }
        }
    }

    private func changeArchive(_ key: String, archived: Bool) {
        withAnimation(Ink.Motion.settle) {
            team.archive(key, archived)
            if archived { archiveUndo = ArchiveUndo(key: key, expires: Date().addingTimeInterval(4)) }
            else if archiveUndo?.key == key { archiveUndo = nil }
        }
    }

    private var archiveBanner: some View {
        Group {
            if let undo = archiveUndo {
                HStack(spacing: Ink.Space.m) {
                    Text(L.t("homeThreads.archived")).font(Ink.secondary).foregroundStyle(Ink.ink)
                    Spacer()
                    Button(L.t("homeThreads.undo")) {
                        guard Date() < undo.expires else { archiveUndo = nil; return }
                        changeArchive(undo.key, archived: false)
                    }
                    .buttonStyle(PressStyle())
                }
                .padding(Ink.Space.l)
                .paperCard()
                .padding(.horizontal, Ink.Space.page)
                .padding(.bottom, Ink.Space.s)
                .task(id: undo.expires) {
                    do { try await Task.sleep(for: .seconds(4)) } catch { return }
                    if archiveUndo == undo { archiveUndo = nil }
                }
            }
        }
    }

    // MARK: Sidebar

    private var sideWidth: CGFloat {
        min(deskWidth * 0.82, Ink.Size.body * 21)
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

    private var sideThreads: [Thread] {
        let words = sideQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return shownThreads }
        return recent.filter { item in
            [item.name, item.preview, team.title(of: item.id.id) ?? ""].contains { $0.localizedCaseInsensitiveContains(words) }
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
                    // A gathering starts a fresh page too, not only a companion.
                    closeSide()
                    startFresh()
                } label: {
                    Label("新对话", systemImage: "square.and.pencil")
                        .font(.system(size: Ink.Size.sub, weight: .semibold))
                        .foregroundStyle(Ink.paper)
                        .padding(.horizontal, Ink.Space.l)
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

            filterChips
                .padding(.horizontal, Ink.Space.l)
                .padding(.bottom, Ink.Space.s)

            ScrollView {
                VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
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
                            .padding(.bottom, Ink.Space.xs)
                        ForEach(group.items, id: \.id) { item in
                            sideThread(item)
                        }
                    }
                    if !pastLeaves.isEmpty {
                        // Put-aside conversations follow on under 对话, after the ones open with each companion.
                        if !sideThreads.contains(where: { !team.pinned.contains($0.id.id) }) {
                            Text("对话")
                                .font(.system(size: Ink.Size.small, weight: .semibold))
                                .foregroundStyle(Ink.inkFaint)
                                .padding(.horizontal, Ink.Space.l)
                                .padding(.top, Ink.Space.l)
                                .padding(.bottom, Ink.Space.xs)
                        }
                        ForEach(pastLeaves) { past in pastRow(past) }
                    }
                    if sideThreads.isEmpty && pastLeaves.isEmpty {
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

    /// 新对话: asks with whom and whether memory is on, then a fresh page; what was there stays in the sidebar.
    /// The companion talked with last, picked already in 新对话.
    private var lastCompanion: String? {
        recent.compactMap(\.bot).first?.id ?? team.bots.first?.id
    }

    private func startFresh() {
        guard !team.bots.isEmpty else { return }
        startingFresh = true
    }

    /// The chosen companion on a fresh page; what was there goes to its 对话记录 (listed in the sidebar).
    private func begin(_ target: Opened, memory: Bool) {
        team.turnLeaf(target.id)
        team.setAbility(.memory, on: memory, in: target.id)
        withAnimation(Ink.Motion.unfold) { opened = target }
    }

    /// A conversation put aside by 新对话: kept in its companion's 对话记录. Listed here one by one, newest first,
    /// so starting afresh never looks like losing the old ones.
    private struct PastLeaf: Identifiable {
        let owner: Opened
        let ownerName: String
        let leaf: TeamModel.Leaf
        var id: String { owner.id + "/" + leaf.id }
    }

    private var pastLeaves: [PastLeaf] {
        let words = sideQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = recent.flatMap { item in
            team.leaves(item.id.id)
                .filter { $0.marker == nil && $0.count > 0 }
                .map { PastLeaf(owner: item.id, ownerName: item.name, leaf: $0) }
        }
        let found = words.isEmpty ? all : all.filter { $0.leaf.title.localizedCaseInsensitiveContains(words) || $0.ownerName.localizedCaseInsensitiveContains(words) }
        return Array(found.sorted { $0.leaf.at > $1.leaf.at }.prefix(60))
    }

    private func pastRow(_ past: PastLeaf) -> some View {
        Button {
            Haptics.light()
            jump(past.owner)
            team.openLeaf(past.owner.id, past.leaf)
        } label: {
            VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
                Text(past.leaf.title.isEmpty ? "没有标题的对话" : past.leaf.title)
                    .font(.system(size: Ink.Size.sub)).foregroundStyle(Ink.ink).lineLimit(1)
                Text("\(past.ownerName) · \(Self.dayName(past.leaf.at)) · \(past.leaf.count) 条")
                    .font(.system(size: Ink.Size.small)).foregroundStyle(Ink.inkFaint).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Ink.Space.m)
            .padding(.vertical, Ink.Space.s)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(haptic: false))
    }

    private static func dayName(_ at: Double) -> String {
        let date = Date(timeIntervalSince1970: at / 1000)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInYesterday(date) { return "昨天" }
        return date.formatted(.dateTime.month().day())
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
        return SwipeRow(actions: [archiveSwipe(key)]) {
        Button {
            Haptics.light()
            jump(item.id)
        } label: {
            HStack(spacing: Ink.Space.s) {
                if let value = team.threadLabels[key], let label = ThreadLabel(rawValue: value) {
                    Circle().fill(label.tint).frame(width: Ink.Space.s, height: Ink.Space.s)
                        .accessibilityLabel(label.title)
                }
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
                    Image(systemName: "archivebox").foregroundStyle(Ink.inkFaint)
                        .accessibilityLabel(L.t("homeThreads.archived"))
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
        .contextMenu {
            Button(team.pinned.contains(key) ? "取消置顶" : "置顶", systemImage: team.pinned.contains(key) ? "pin.slash" : "pin") {
                withAnimation(Ink.Motion.settle) { team.pin(key, !team.pinned.contains(key)) }
            }
            Button("重命名", systemImage: "pencil") { startRename(key) }
            archiveMenu(key)
            Menu(L.t("homeThreads.colorFilter"), systemImage: "tag") {
                labelChoices(selected: team.threadLabels[key] ?? "", clearTitle: L.t("homeThreads.removeColor")) {
                    team.setThreadLabel($0, for: key)
                }
            }
        }
        }
    }

    private func archiveSwipe(_ key: String) -> SwipeAction {
        let archived = team.archived.contains(key)
        return SwipeAction(title: L.t(archived ? "homeThreads.restore" : "homeThreads.archive"),
                           symbol: archived ? "tray.and.arrow.up" : "archivebox", tint: Ink.Tile.accent) {
            changeArchive(key, archived: !archived)
        }
    }

    private func archiveMenu(_ key: String) -> some View {
        let archived = team.archived.contains(key)
        return Button(L.t(archived ? "homeThreads.restore" : "homeThreads.archive"),
                      systemImage: archived ? "tray.and.arrow.up" : "archivebox") {
            changeArchive(key, archived: !archived)
        }
    }

    /// 收名帖: a card file picked from Files becomes a new companion, with its 性格, 风格, seal and face.
    private func receiveCard(_ result: Result<URL, Error>) {
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
                        // A pet the phone doesn't have falls back to the default; a photo comes with the card.
                        let pet = card.pet.flatMap { face in PetLibrary.shared.packs.contains { "pet:\($0.id)" == face } ? face : nil }
                        // A pet this phone doesn't have comes as its still picture, and you are told so.
                        let missingPet = card.pet != nil && pet == nil
                        let picture = (card.photo ?? (missingPet ? card.petStill : nil)).flatMap(UIImage.init(data:))
                        let id = try await team.saveBot(id: nil, name: name, role: card.role ?? "", color: card.color ?? "dai", instructions: card.instructions,
                                                        avatar: picture != nil ? "photo" : pet, temper: card.temper, style: card.style, seal: card.seal)
                        if let picture { Avatars.save(picture, for: id) }
                        Haptics.thud()
                        notice = Words.t("收下了\(name)的名帖。")
                        if missingPet {
                            notice = (notice ?? "") + (picture == nil ? L.t("companion.missingPetDefault") : L.t("companion.missingPetStill"))
                        }
                    } catch {
                        notice = "没收下：\(error.localizedDescription)"
                    }
                }
            } catch {
                notice = error.localizedDescription
            }
        }
    }

    private var archivedThreads: [(id: Opened, name: String, preview: String, at: Double, bot: BotInfo?)] {
        recent.filter { team.archived.contains($0.id.id) }
    }

    @ViewBuilder
    private var homeThreads: some View {
        header
        companions
            // 看名帖 from anywhere on the desk; kept here so the long body stays quick to check.
            .sheet(item: $cardBot) { bot in NameCardSheet(team: team, bot: bot) }
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
                // Looked up a moment after typing stops, off the main thread (it reads every conversation).
                .task(id: query) {
                    let words = query
                    guard !words.trimmingCharacters(in: .whitespaces).isEmpty else { searchHits = []; return }
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                    let found = await team.search(words)
                    if !Task.isCancelled, words == query { searchHits = found }
                }
        }
        if searching && !query.trimmingCharacters(in: .whitespaces).isEmpty {
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
                    if hit.key.hasPrefix("bot-") { opened = .companion(String(hit.key.dropFirst(4))) } else { opened = .gathering(String(hit.key.dropFirst(5))) }
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
                .contextMenu { archiveMenu(hit.key) }
                Kit.rule(inset: 0)
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

    private var deskContent: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
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
            .opacity(opened == nil ? 1 : 0)
            .scaleEffect(opened == nil ? 1 : 0.96)

            // The sidebar lies under the conversation and comes out as the conversation slides to the right.
            if opened != nil {
                sidebar
                    .frame(width: sideWidth)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(sideWidth > 0 ? min(1, shift / sideWidth * 1.3) : 0)
            }

            if let opened {
                page(for: opened)
                    .clipShape(RoundedRectangle(cornerRadius: shift > 0 ? Ink.Radius.card : 0, style: .continuous))
                    // The shadow is cast by a plain rounded sheet of paper under the page, not by the page itself:
                    // shadowing the page made iOS trace every word and button for each frame of the slide.
                    .background {
                        RoundedRectangle(cornerRadius: shift > 0 ? Ink.Radius.card : 0, style: .continuous)
                            .fill(Ink.paper)
                            .shadow(color: Ink.Artwork.black.opacity(shift > 0 ? 0.22 : 0), radius: 20, x: -4)
                    }
                    .overlay {
                        // Open sidebar: a tap on the conversation's edge closes it.
                        if sideOpen {
                            Ink.ink.opacity(0.001)
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
                                guard pull != 0, sideWidth > 0 else { return }
                                let fling = value.predictedEndTranslation.width
                                if sideOpen {
                                    if -pull > sideWidth * 0.3 || fling < -180 { closeSide() } else { withAnimation(Ink.Motion.settle) { pull = 0 } }
                                } else {
                                    if pull > sideWidth * 0.35 || fling > sideWidth * 0.72 { openSide() } else { withAnimation(Ink.Motion.settle) { pull = 0 } }
                                }
                            }
                    )
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { deskWidth = $0 }
        .overlay(alignment: .bottom) { archiveBanner }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { archiveUndo = nil }
        }
        .sheet(isPresented: $addingService) { SetupView(team: team) { addingService = false } }
        .sheet(isPresented: $startingFresh) {
            NewChatSheet(team: team, first: lastCompanion) { id, memory in
                startingFresh = false
                begin(.companion(id), memory: memory)
            }
        }
    }

    var body: some View {
        deskContent
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
        .sheet(isPresented: $caring) { CarePage(team: team, openRestore: team.phase == .setup) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .plainText, .data]) { receiveCard($0) }
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
            if let chat = note.object as? String { openChat(chat) }
            takeNotifications()
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
        .task {
            takeNotifications()
            answerShortcut()
        }
    }

    private func takeNotifications() {
        for action in ChatNotificationRoute.take() {
            switch action {
            case .open(let chat): openChat(chat)
            case .answer(let id, let allow): team.answerFromNotification(id, allow: allow)
            }
        }
    }

    private func openChat(_ chat: String) {
        if chat.hasPrefix("room-") { opened = .gathering(String(chat.dropFirst(5))) }
        if chat.hasPrefix("bot-") { opened = .companion(String(chat.dropFirst(4))) }
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
                Text(greeting).font(Ink.mark(Ink.Size.title, bold: true, relativeTo: .title3)).foregroundStyle(Ink.ink)
                Text("今天想聊点什么？").font(Ink.reading).foregroundStyle(Ink.inkSoft)
            }
            Spacer()
            HStack(spacing: Ink.Space.s) {
                if !team.bots.isEmpty {
                    Button {
                        Haptics.light()
                        startFresh()
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
                        .padding(.leading, Ink.Space.s)
                        .padding(.trailing, Ink.Space.l)
                        .frame(height: 40)
                        .background(Ink.paperRaised, in: .capsule)
                        .overlay(Capsule().strokeBorder(Ink.rule, lineWidth: 1))
                    }
                    .buttonStyle(PressStyle(haptic: false))
                    .contextMenu {
                        Button(Words.t("看名帖"), systemImage: "person.text.rectangle") { cardBot = bot }
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
            let name = team.bots.first { $0.id == first.botId }?.name ?? L.t("nav.assistant")
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

    private func swipes(_ item: (id: Opened, name: String, preview: String, at: Double, bot: BotInfo?)) -> [SwipeAction] {
        let key = item.id.id
        let pinned = team.pinned.contains(key)
        return [
            SwipeAction(title: pinned ? "取消置顶" : "置顶", symbol: pinned ? "pin.slash" : "pin", tint: Ink.Tile.xiang) {
                withAnimation(Ink.Motion.settle) { team.pin(key, !pinned) }
            },
            archiveSwipe(key),
            SwipeAction(title: item.bot == nil ? "散了" : "清空", symbol: "trash", tint: Ink.Tile.yan) {
                clearing = item.id
            },
        ]
    }

    /// 置顶 first (in the order pinned), then the rest.
    static func grouped(_ items: [(id: Opened, name: String, preview: String, at: Double, bot: BotInfo?)], pinned: [String]) -> [(title: String, items: [(id: Opened, name: String, preview: String, at: Double, bot: BotInfo?)])] {
        let top = pinned.compactMap { key in items.first { $0.id.id == key } }
        // 主人定: no 今天 / 昨天 / 本周 — just 置顶 (when there is any) and the rest, newest first.
        let others = items.filter { !pinned.contains($0.id.id) }
        let rest: [(title: String, items: [(id: Opened, name: String, preview: String, at: Double, bot: BotInfo?)])] = others.isEmpty ? [] : [("对话", others)]
        return top.isEmpty ? rest : [("置顶", top)] + rest
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
                .padding(.top, Ink.Space.xs / 2)
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
            archiveMenu(item.id.id)
            Menu(L.t("homeThreads.colorFilter"), systemImage: "tag") {
                labelChoices(selected: team.threadLabels[item.id.id] ?? "", clearTitle: L.t("homeThreads.removeColor")) {
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

private enum ThreadLabel: String, CaseIterable, Identifiable {
    case dai, yan, xiang, teng, zhu

    var id: String { rawValue }
    var title: String { L.t("homeThreads." + rawValue) }

    var tint: Color {
        switch self {
        case .dai: Ink.Tile.dai
        case .yan: Ink.Tile.yan
        case .xiang: Ink.Tile.xiang
        case .teng: Ink.Tile.teng
        case .zhu: Ink.Tile.zhu
        }
    }
}

/// 新对话, the HanaAgent way: pick who to talk with and whether this conversation looks at memory, then start.
/// Turning memory off is cheaper too (the model's cache hits more often) and keeps this one out of what is remembered.
private struct NewChatSheet: View {
    @ObservedObject var team: TeamModel
    let start: (String, Bool) -> Void
    @State private var pick: String
    @State private var memory = true
    @Environment(\.dismiss) private var dismiss

    init(team: TeamModel, first: String?, start: @escaping (String, Bool) -> Void) {
        self.team = team
        self.start = start
        _pick = State(initialValue: first ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                PaperRows {
                    Section {
                        ForEach(team.bots) { bot in
                            Button {
                                Haptics.tick(0.5)
                                pick = bot.id
                            } label: {
                                HStack(spacing: Ink.Space.m) {
                                    PetStill(size: 32, wash: Ink.wash(for: bot), avatar: true, bot: bot)
                                    Text(bot.name).foregroundStyle(Ink.ink)
                                    Spacer()
                                    if pick == bot.id {
                                        Image(systemName: "checkmark").font(.system(size: Ink.Size.sub, weight: .semibold)).foregroundStyle(Ink.accent)
                                    }
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                    } header: { Text(Words.t("跟哪位旅伴聊")) }
                    Section {
                        Toggle(Words.t("这次参考拾遗"), isOn: $memory).tint(Ink.accent)
                    } footer: {
                        Text(Words.t("关掉后，这段对话里旅伴不翻拾遗、也不往里记；更省钱。之前的对话还在侧边栏里。"))
                    }
                }
            }
            .paperForm()
            .navigationTitle(L.t("chat.newConversation"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(L.t("actions.cancel")) { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("开始") {
                        Haptics.light()
                        start(pick, memory)
                    }
                    .disabled(!team.bots.contains { $0.id == pick })
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
