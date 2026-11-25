import Combine
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

/// Narrow root observer subscribing only to `TeamModel.loading` and `TeamModel.phase`.
@MainActor @Observable
private final class ClioRootGate {
    var loading: Bool
    var phase: TeamModel.Phase
    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []

    init(team: TeamModel) {
        self.loading = team.loading
        self.phase = team.phase
        team.$loading
            .sink { [weak self] next in
                guard let self, self.loading != next else { return }
                self.loading = next
            }
            .store(in: &cancellables)
        team.$phase
            .sink { [weak self] next in
                guard let self, self.phase != next else { return }
                self.phase = next
            }
            .store(in: &cancellables)
    }
}

/// The app's root: setting up a model first, then the desk.
struct ClioRoot: View {
    private let team = TeamModel.shared
    @State private var gate = ClioRootGate(team: TeamModel.shared)
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
            } else if gate.loading {
                ProgressView(L.t("loading.generic"))
            } else if gate.phase == .setup && !introSeen {
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
        .animation(Ink.Motion.settle, value: gate.phase)
        .animation(Ink.Motion.settle, value: introSeen)
        .tint(Ink.accent)
        .clioScheme(scheme)
        .modifier(FormPresenter(inBrowser: false))
        .onOpenURL { url in
            handleIncomingURL(url)
        }
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
                QueuedStore.finishBeforeSuspension()
                DraftTextStore.finishBeforeSuspension()
                DraftAttachments.finishBeforeSuspension()
                Hitches.shared.save()
                WidgetFeed.publish(team, immediate: true)
            }
        }
        .task {
            MemoryNight.noteLaunch()
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

    private func handleIncomingURL(_ url: URL) {
        if url.isFileURL {
            // Acquire security-scoped access synchronously during the UI callback, then move
            // File Provider download, copy, and PDF text extraction off the main thread.
            let lease = InboxImport.ScopedLease(url)
            let filename = url.lastPathComponent
            Task.detached(priority: .userInitiated) {
                do {
                    let rel = try InboxImport.copyOne(lease)
                    await MainActor.run {
                        ShortcutDoor.knock(.importedFiles(paths: [rel], failed: []))
                    }
                } catch {
                    let message = "没拿到「\(filename)」：\(error.localizedDescription)"
                    await MainActor.run {
                        ShortcutDoor.knock(.importedFiles(paths: [], failed: [message]))
                    }
                }
            }
            return
        }
        guard url.scheme == "clio" else { return }
        switch url.host {
        case "chat":
            let target = url.lastPathComponent
            ShortcutDoor.pendingChat = target
            NotificationCenter.default.post(name: .clioOpenChat, object: target)
        case "ask", "share":
            ShortcutDoor.knock(.ask(ShortcutText.fromURL(url)))
        case "dictate":
            ShortcutDoor.knock(.dictate)
        case "new":
            ShortcutDoor.knock(.fresh)
        case "settings":
            let page = url.pathComponents.dropFirst().first.map { item in
                url.fragment.map { item + "#" + $0 } ?? item
            } ?? ""
            ShortcutDoor.pendingSettings = page
            NotificationCenter.default.post(name: .clioSettingsRoute, object: nil)
        default:
            break
        }
    }
}

/// 案头: the companions, the gatherings, and the latest of each conversation.
struct Desk: View {
    let team: TeamModel
    @State private var deskWidth: CGFloat = 0
    @State private var opened: Opened? = Shots.startsInChat ? .companion("chief") : nil
    @State private var editing: DeskEditTarget?
    @State private var tuning = false

    /// 新对话 asks first, like HanaAgent: with whom, and whether this one looks at memory.
    private struct FreshRequest: Identifiable {
        let id = UUID()
        let first: String?
    }

    @State private var freshRequest: FreshRequest?
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var addingService = false
    @State private var archiveUndo: ArchiveUndo?

    private struct ArchiveUndo: Equatable {
        let key: String
        let expires: Date
        let epoch: Int
    }

    /// The sidebar is out, the conversation pushed to the right.
    @State private var sideOpen = Shots.name == "sidebar" || Shots.name == "sidebar-past"
    /// What a conversation calls to open the sidebar; one object for the desk's whole life (see `ChatPage.side`).
    @State private var sideControl = SideControl()
    @State private var renaming: DeskRenameTarget?
    @State private var deletingThread: DeskSideConversation?
    @State private var deletingEpoch = 0
    @State private var renameText = ""
    @State private var sideQuery = ""
    @State private var query = ""
    @State private var searchHits: [TeamModel.Hit] = []
    /// A conversation waiting for the user to confirm it should be emptied (or a gathering dissolved).
    @State private var clearing: Opened?
    /// 看名帖: the card, large.
    @State private var cardBot: BotInfo?

    private var sideMotion: Animation? {
        reduceMotion ? nil : Ink.Motion.unfold
    }

    private func startRename(_ key: String) {
        renameText = team.title(of: key) ?? ""
        renaming = .current(key)
    }

    private func startRenamePast(_ past: DeskPastLeaf) {
        renameText = past.leaf.title
        renaming = .past(past)
    }

    private func requestDelete(_ row: DeskSideConversation) {
        deletingEpoch = team.epochs[row.id, default: 0]
        deletingThread = row
    }

    private func changeArchive(_ key: String, archived: Bool) {
        withAnimation(Ink.Motion.settle) {
            team.archive(key, archived)
            if archived {
                archiveUndo = ArchiveUndo(key: key, expires: Date().addingTimeInterval(4), epoch: team.epochs[key, default: 0])
            } else if archiveUndo?.key == key {
                archiveUndo = nil
            }
        }
    }

    private func openSide() {
        Haptics.light()
        DiagTrail.record("开侧边栏")
        withAnimation(sideMotion) { sideOpen = true }
    }

    private func closeSide() {
        DiagTrail.record("关侧边栏")
        withAnimation(sideMotion) { sideOpen = false }
    }

    private func jump(_ target: Opened?) {
        closeSide()
        guard target != opened else { return }
        withAnimation(sideMotion) { opened = target }
    }

    private var lastCompanion: String? {
        DeskThreadHelpers.recent(team: team).compactMap(\.bot).first?.id ?? team.bots.first?.id
    }

    private func startFresh(first: String? = nil) {
        guard !team.bots.isEmpty else { return }
        sideControl.choosingFresh = true
        freshRequest = FreshRequest(first: first ?? lastCompanion)
    }

    /// The chosen companion on a fresh page; what was there goes to its 对话记录 (listed in the sidebar).
    private func begin(_ target: Opened, memory: Bool) {
        guard team.turnLeaf(target.id) else { return }
        team.setAbility(.memory, on: memory, in: target.id)
        withAnimation(sideMotion) { opened = target }
    }

    @ViewBuilder
    private var archiveBanner: some View {
        if let undo = archiveUndo {
            HStack(spacing: Ink.Space.m) {
                Text(L.t("homeThreads.archived")).font(Ink.secondary).foregroundStyle(Ink.ink)
                Spacer()
                Button(L.t("homeThreads.undo")) {
                    guard Date() < undo.expires, team.archived.contains(undo.key),
                          team.epochs[undo.key, default: 0] == undo.epoch else { archiveUndo = nil; return }
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

    private var deskContent: some View {
        ZStack {
            DeskHomeView(
                team: team,
                opened: $opened,
                editing: $editing,
                tuning: $tuning,
                settingsPage: $settingsPage,
                caring: $caring,
                addingService: $addingService,
                cardBot: $cardBot,
                roomEditing: $roomEditing,
                clearing: $clearing,
                searching: $searching,
                query: $query,
                searchHits: $searchHits,
                showArchived: $showArchived,
                listFilter: $listFilter,
                labelFilter: $labelFilter,
                startFresh: { startFresh(first: $0) },
                openDrawerItem: { open($0) },
                startRename: startRename,
                startRenamePast: startRenamePast,
                requestDelete: requestDelete,
                changeArchive: changeArchive
            )
            .opacity(opened == nil ? 1 : 0)
            .scaleEffect(opened == nil ? 1 : (reduceMotion ? 1 : 0.96))

            // Only mount the active slide host when a conversation is opened.
            if let opened {
                DeskSlideHost(
                    team: team,
                    opened: opened,
                    sideControl: sideControl,
                    deskWidth: deskWidth,
                    sideOpen: $sideOpen,
                    openSide: openSide,
                    closeSide: closeSide
                ) {
                    DeskSidebarView(
                        team: team,
                        opened: opened,
                        sideQuery: $sideQuery,
                        listFilter: $listFilter,
                        labelFilter: $labelFilter,
                        studying: $studying,
                        denning: $denning,
                        tuning: $tuning,
                        closeSide: closeSide,
                        startFresh: { startFresh() },
                        jump: jump,
                        startRename: startRename,
                        startRenamePast: startRenamePast,
                        requestDelete: requestDelete,
                        changeArchive: changeArchive
                    )
                }
                .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .trailing)))
                .zIndex(1)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { deskWidth = $0 }
        .overlay(alignment: .bottom) { archiveBanner }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { archiveUndo = nil }
        }
        .sheet(isPresented: $addingService) { SetupView(team: team) { addingService = false } }
        .sheet(item: $freshRequest, onDismiss: { sideControl.choosingFresh = false }) { request in
            NewChatSheet(team: team, first: request.first) { id, memory in
                freshRequest = nil
                begin(.companion(id), memory: memory)
            }
        }
    }

    var body: some View {
        deskContent
            .animation(sideMotion, value: opened)
            .onAppear {
                sideControl.open = { openSide() }
                sideControl.fresh = { startFresh(first: $0) }
            }
            .alert(L.t("chat.rename"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField(L.t("chat.titleField"), text: $renameText)
                Button(L.t("actions.cancel"), role: .cancel) { renaming = nil }
                Button(L.t("actions.save")) {
                    switch renaming {
                    case .current(let key): team.rename(key, to: renameText)
                    case .past(let past):
                        if !team.renameLeaf(past.owner.id, id: past.leaf.id, to: renameText) {
                            notice = L.t("errors.saveConversation")
                        }
                    case nil: break
                    }
                    renaming = nil
                }
            }
            .confirmationDialog(
                L.t("chat.deleteConversationConfirm"),
                isPresented: Binding(get: { deletingThread != nil }, set: { if !$0 { deletingThread = nil } }),
                titleVisibility: .visible,
                presenting: deletingThread
            ) { row in
                Button(L.t("actions.delete"), role: .destructive) {
                    let deleted: Bool
                    switch row {
                    case .current(let thread):
                        deleted = team.epochs[row.id, default: 0] == deletingEpoch
                            && team.clearChat(thread.id.id, includingLeaves: false)
                    case .past(let past):
                        deleted = team.deleteLeaf(past.owner.id, id: past.leaf.id)
                    }
                    if deleted { Haptics.thud() }
                    else { notice = L.t("errors.saveConversation") }
                    deletingThread = nil
                }
                Button(L.t("actions.cancel"), role: .cancel) { deletingThread = nil }
            } message: { _ in
                Text(L.t("errors.cannotUndo"))
            }
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
                if let chat = ShortcutDoor.pendingChat ?? (note.object as? String) {
                    ShortcutDoor.pendingChat = nil
                    openChat(chat)
                }
                takeNotifications()
            }
            .onReceive(NotificationCenter.default.publisher(for: .clioSettingsRoute)) { _ in
                takePendingRoutes()
            }
            .onReceive(NotificationCenter.default.publisher(for: .clioShortcut)) { _ in answerShortcut() }
            .task {
                takeNotifications()
                takePendingRoutes()
                answerShortcut()
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

    private func takePendingRoutes() {
        if let chat = ShortcutDoor.pendingChat {
            ShortcutDoor.pendingChat = nil
            openChat(chat)
        }
        if let page = ShortcutDoor.pendingSettings {
            ShortcutDoor.pendingSettings = nil
            settingsPage = page.isEmpty ? nil : page
            tuning = true
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
        let recent = DeskThreadHelpers.recent(team: team)
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
        let recent = DeskThreadHelpers.recent(team: team)
        return Words.t(clearingIsRoom ? "散了这个雅集？" : "清空和\(recent.first { $0.id == target }?.name ?? "旅伴")的絮语？")
    }

    private func open(_ item: DrawerItem) {
        switch item {
        case .newCompanion: editing = DeskEditTarget(id: "new", bot: nil)
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

    private static let whenLock = NSLock()
    private static let whenFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter
    }()

    /// 「方才」「14:20」「昨日」「周一」「11月3日」
    static func when(_ ms: Double) -> String {
        guard ms > 0 else { return "" }
        let date = Date(timeIntervalSince1970: ms / 1000)
        let calendar = Calendar.current
        if Date().timeIntervalSince(date) < 120 { return "方才" }
        if calendar.isDateInYesterday(date) { return "昨日" }
        let format: String
        if calendar.isDateInToday(date) {
            format = "HH:mm"
        } else if let days = calendar.dateComponents([.day], from: date, to: Date()).day, days < 7 {
            format = "EEE"
        } else {
            format = "M月d日"
        }
        return whenLock.withLock {
            if whenFormatter.dateFormat != format {
                whenFormatter.dateFormat = format
            }
            return whenFormatter.string(from: date)
        }
    }
}

struct DeskThread {
    let id: Opened
    let name: String
    let preview: String
    let at: Double
    let bot: BotInfo?
}

struct DeskEditTarget: Identifiable {
    let id: String
    let bot: BotInfo?
}

enum DeskRenameTarget {
    case current(String)
    case past(DeskPastLeaf)
}

struct DeskPastLeaf: Identifiable {
    let owner: Opened
    let ownerName: String
    let leaf: TeamModel.Leaf
    var id: String { TeamModel.threadKey(owner.id, leaf: leaf.id) }
}

enum DeskSideConversation: Identifiable {
    case current(DeskThread)
    case past(DeskPastLeaf)

    var id: String {
        switch self {
        case .current(let thread): thread.id.id
        case .past(let past): past.id
        }
    }

    var at: Double {
        switch self {
        case .current(let thread): thread.at
        case .past(let past): past.leaf.at
        }
    }
}

struct DeskSideSection {
    let title: String
    let rows: [DeskSideConversation]
}

struct DeskFilterChips: View {
    @Binding var listFilter: Int
    @Binding var labelFilter: String

    var body: some View {
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
                    DeskThreadHelpers.labelChoices(selected: labelFilter, clearTitle: L.t("homeThreads.allColors")) { labelFilter = $0 }
                } label: {
                    Label(DeskThreadLabel(rawValue: labelFilter)?.title ?? L.t("homeThreads.colorFilter"), systemImage: "tag")
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
}

@MainActor
enum DeskThreadHelpers {
    static func greeting() -> String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<11: "晨安"
        case 11..<13: "午安"
        case 13..<18: "午后好"
        case 18..<23: "晚上好"
        default: "夜深了"
        }
    }

    /// Conversations with something in them, newest first.
    static func recent(team: TeamModel) -> [DeskThread] {
        let bots = team.bots.compactMap { bot -> DeskThread? in
            guard let at = bot.lastAt else { return nil }
            return DeskThread(id: .companion(bot.id), name: bot.name, preview: bot.preview ?? "", at: at, bot: bot)
        }
        let rooms = team.rooms.compactMap { room -> DeskThread? in
            guard let at = room.lastAt else { return nil }
            return DeskThread(id: .gathering(room.id), name: room.name, preview: room.preview ?? "还没有人说话", at: at, bot: nil)
        }
        return (bots + rooms).sorted { $0.at > $1.at }
    }

    static func matchesFilter(_ item: DeskThread, team: TeamModel, listFilter: Int, labelFilter: String) -> Bool {
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

    static func pastLeaves(team: TeamModel, matching query: String, listFilter: Int, labelFilter: String) -> [DeskPastLeaf] {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let owners = team.bots.map { (Opened.companion($0.id), $0.name) }
            + team.rooms.map { (Opened.gathering($0.id), $0.name) }
        return owners.flatMap { owner, name in
            team.leaves(owner.id).compactMap { leaf -> DeskPastLeaf? in
                guard leaf.marker == nil, leaf.count > 0 else { return nil }
                let past = DeskPastLeaf(owner: owner, ownerName: name, leaf: leaf)
                if words.isEmpty {
                    guard listFilter == 0, !team.archived.contains(past.id),
                          labelFilter.isEmpty || team.threadLabels[past.id] == labelFilter else { return nil }
                } else {
                    guard leaf.title.localizedCaseInsensitiveContains(words) || name.localizedCaseInsensitiveContains(words) else { return nil }
                }
                return past
            }
        }
    }

    static func archivedRows(team: TeamModel, recent: [DeskThread]) -> [DeskSideConversation] {
        let currentRows = recent
            .filter { team.archived.contains($0.id.id) }
            .map(DeskSideConversation.current)
        let owners = team.bots.map { (Opened.companion($0.id), $0.name) }
            + team.rooms.map { (Opened.gathering($0.id), $0.name) }
        let leafRows = owners.flatMap { owner, name in
            team.leaves(owner.id).compactMap { leaf -> DeskSideConversation? in
                guard leaf.marker == nil, leaf.count > 0 else { return nil }
                let past = DeskPastLeaf(owner: owner, ownerName: name, leaf: leaf)
                guard team.archived.contains(past.id) else { return nil }
                return .past(past)
            }
        }
        return (currentRows + leafRows).sorted { $0.at > $1.at }
    }

    static func sections(team: TeamModel, threads: [DeskThread], past: [DeskPastLeaf], byDate: Bool) -> [DeskSideSection] {
        let rows = threads.map(DeskSideConversation.current) + past.map(DeskSideConversation.past)
        let byKey = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        let pinned = team.pinned.compactMap { byKey[$0] }.filter { !team.archived.contains($0.id) }
        let keys = Set(pinned.map(\.id))
        let others = rows.filter { !keys.contains($0.id) }.sorted { $0.at > $1.at }
        var sections: [DeskSideSection] = []
        if !pinned.isEmpty { sections.append(DeskSideSection(title: L.t("homeThreads.pin"), rows: pinned)) }
        if byDate {
            let recent = others.filter { isRecent($0.at) }
            let older = others.filter { !isRecent($0.at) }
            if !recent.isEmpty { sections.append(DeskSideSection(title: "最近", rows: recent)) }
            if !older.isEmpty { sections.append(DeskSideSection(title: "更早", rows: older)) }
        } else if !others.isEmpty {
            sections.append(DeskSideSection(title: L.t("homeThreads.conversations"), rows: others))
        }
        return sections
    }

    /// Within the last seven days (milliseconds since 1970).
    static func isRecent(_ at: Double) -> Bool {
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Calendar.current.startOfDay(for: Date())) ?? Date()
        return Date(timeIntervalSince1970: at / 1000) >= weekAgo
    }

    static func dayName(_ at: Double) -> String {
        let date = Date(timeIntervalSince1970: at / 1000)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInYesterday(date) { return "昨天" }
        return date.formatted(.dateTime.month().day())
    }

    @ViewBuilder
    static func labelChoices(selected: String, clearTitle: String, pick: @escaping (String) -> Void) -> some View {
        Button { pick("") } label: {
            if selected.isEmpty { Label(clearTitle, systemImage: "checkmark") }
            else { Text(clearTitle) }
        }
        ForEach(DeskThreadLabel.allCases) { label in
            Button { pick(label.rawValue) } label: {
                Label(label.title, systemImage: selected == label.rawValue ? "checkmark" : "circle.fill")
            }
        }
    }

    @ViewBuilder
    static func threadColor(_ key: String, team: TeamModel) -> some View {
        if let value = team.threadLabels[key], let label = DeskThreadLabel(rawValue: value) {
            Circle().fill(label.tint).frame(width: Ink.Space.s, height: Ink.Space.s)
                .accessibilityLabel(label.title)
        }
    }

    @ViewBuilder
    static func archivedIcon(_ key: String, team: TeamModel) -> some View {
        if team.archived.contains(key) {
            Image(systemName: "archivebox").foregroundStyle(Ink.inkFaint)
                .accessibilityLabel(L.t("homeThreads.archived"))
        }
    }

    static func archiveSwipe(_ key: String, team: TeamModel, changeArchive: @escaping (String, Bool) -> Void) -> SwipeAction {
        let archived = team.archived.contains(key)
        return SwipeAction(
            title: L.t(archived ? "homeThreads.restore" : "homeThreads.archive"),
            symbol: archived ? "tray.and.arrow.up" : "archivebox",
            tint: Ink.Tile.accent
        ) {
            changeArchive(key, !archived)
        }
    }

    static func archiveMenu(_ key: String, team: TeamModel, changeArchive: @escaping (String, Bool) -> Void) -> some View {
        let archived = team.archived.contains(key)
        return Button(
            L.t(archived ? "homeThreads.restore" : "homeThreads.archive"),
            systemImage: archived ? "tray.and.arrow.up" : "archivebox"
        ) {
            changeArchive(key, !archived)
        }
    }

    static func pastSwipes(
        _ row: DeskSideConversation,
        team: TeamModel,
        changeArchive: @escaping (String, Bool) -> Void,
        requestDelete: @escaping (DeskSideConversation) -> Void
    ) -> [SwipeAction] {
        [
            archiveSwipe(row.id, team: team, changeArchive: changeArchive),
            SwipeAction(title: L.t("actions.delete"), symbol: "trash", tint: Ink.stop) { requestDelete(row) },
        ]
    }

    @ViewBuilder
    static func conversationMenu(
        _ row: DeskSideConversation,
        team: TeamModel,
        startRename: @escaping (String) -> Void,
        startRenamePast: @escaping (DeskPastLeaf) -> Void,
        changeArchive: @escaping (String, Bool) -> Void,
        requestDelete: @escaping (DeskSideConversation) -> Void
    ) -> some View {
        let key = row.id
        let pinned = team.pinned.contains(key)
        Button(L.t(pinned ? "homeThreads.unpin" : "homeThreads.pin"), systemImage: pinned ? "pin.slash" : "pin") {
            withAnimation(Ink.Motion.settle) { team.pin(key, !pinned) }
        }
        Button(L.t("chat.rename"), systemImage: "pencil") {
            switch row {
            case .current: startRename(key)
            case .past(let past): startRenamePast(past)
            }
        }
        Menu(L.t("homeThreads.colorFilter"), systemImage: "tag") {
            labelChoices(selected: team.threadLabels[key] ?? "", clearTitle: L.t("homeThreads.removeColor")) {
                team.setThreadLabel($0, for: key)
            }
        }
        archiveMenu(key, team: team, changeArchive: changeArchive)
        Button(L.t("actions.delete"), systemImage: "trash", role: .destructive) { requestDelete(row) }
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
@MainActor @Observable
final class SideControl {
    @ObservationIgnored var open: () -> Void = {}
    @ObservationIgnored var fresh: (String?) -> Void = { _ in }
    var choosingFresh = false
}

enum DeskThreadLabel: String, CaseIterable, Identifiable {
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
