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
            if team.phase == .setup || holdingSetup {
                SetupView(team: team, first: true) { holdingSetup = false }
                    .transition(.blurReplace)
                    .onAppear { holdingSetup = true }
            } else {
                Desk(team: team)
                    .transition(.blurReplace)
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
            if now == .active { team.wake() }
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
    @State private var opened: Opened?
    @State private var editing: EditTarget?
    @State private var tuning = false
    @State private var settingsPage: String?
    @State private var dressing = false
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
    @State private var looking = false
    @State private var roomEditing: RoomInfo?
    @State private var searching = false
    @State private var showArchived = false
    @State private var listFilter = 0
    /// How far the open conversation has been pulled to the right by a swipe from the left edge.
    @State private var pull: CGFloat = 0
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
                            .font(.system(size: 13, weight: listFilter == item.0 ? .semibold : .regular))
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
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(Ink.inkSoft)
                                .frame(width: 36, height: 36)
                        }
                        .accessibilityLabel(searching ? "不找了" : "找一找")
                    }
                    .padding(.top, Ink.Space.xxl)
                    .padding(.bottom, Ink.Space.s)
                    if searching {
                        TextField("找过去聊过的话", text: $query)
                            .font(.system(size: 16))
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
                                        Text(hit.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.ink)
                                        if hit.leaf != nil { Text(Words.t("收起的一叶")).font(.system(size: 11)).foregroundStyle(Ink.inkFaint) }
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
                            words: recent.isEmpty ? Words.t("还没有聊过。点上面的旅伴，说第一句话吧。") : "都归档了，下面能翻出来。"
                        )
                    }
                    ForEach(Self.byDay(shownThreads), id: \.title) { group in
                        Text(group.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Ink.inkFaint)
                            .padding(.top, Ink.Space.m)
                        ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                            thread(item)
                            if index != group.items.count - 1 {
                                Rectangle().fill(Ink.rule).frame(height: 1).padding(.leading, 40)
                            }
                        }
                    }
                    if !archivedThreads.isEmpty {
                        Button {
                            Haptics.light()
                            withAnimation(Ink.Motion.unfold) { showArchived.toggle() }
                        } label: {
                            HStack(spacing: Ink.Space.s) {
                                Image(systemName: "archivebox").font(.system(size: 13))
                                Text("已归档 \(archivedThreads.count) 段").font(.system(size: 14, weight: .medium))
                                Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
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
                                Rectangle().fill(Ink.rule).frame(height: 1).padding(.leading, 40)
                            }
                        }
                    }
                    }
                }
                .padding(.horizontal, Ink.Space.page)
                .padding(.bottom, Ink.Space.huge)
            }
            .scrollIndicators(.hidden)
            // While a conversation is pulled aside, the desk shows through underneath, like a sidebar.
            .opacity(opened == nil ? 1 : min(1, pull / 220))
            .scaleEffect(opened == nil ? 1 : 0.96 + 0.04 * min(1, pull / 300))

            if let opened {
                page(for: opened)
                    .background(Ink.paper)
                    .clipShape(RoundedRectangle(cornerRadius: pull > 0 ? 28 : 0, style: .continuous))
                    .shadow(color: .black.opacity(pull > 0 ? 0.18 : 0), radius: 18, x: -4)
                    .offset(x: pull)
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .trailing)))
                    .zIndex(1)
                    .simultaneousGesture(
                        // From the left edge: the conversation follows the finger, and the desk comes out from under it.
                        DragGesture(minimumDistance: 10, coordinateSpace: .global)
                            .onChanged { value in
                                guard value.startLocation.x < 32, value.translation.width > 0,
                                      abs(value.translation.height) < max(60, value.translation.width) else { return }
                                pull = value.translation.width
                            }
                            .onEnded { value in
                                guard pull > 0 else { return }
                                if pull > 110 || value.predictedEndTranslation.width > 260 {
                                    Haptics.light()
                                    withAnimation(Ink.Motion.unfold) { self.opened = nil; pull = 0 }
                                } else {
                                    withAnimation(Ink.Motion.settle) { pull = 0 }
                                }
                            }
                    )
            }
        }
        .animation(Ink.Motion.unfold, value: opened)
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
        .sheet(isPresented: $looking) { LookPage() }
        .sheet(item: $editing) { target in BotEditor(team: team, bot: target.bot) }
        .sheet(isPresented: $gathering) { RoomEditor(team: team) }
        .sheet(item: $roomEditing) { room in RoomEditor(team: team, room: room) }
        .sheet(isPresented: $dressing) { PortraitPage() }
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
        .fullScreenCover(isPresented: $tuning, onDismiss: { settingsPage = nil }) {
            SettingsView(team: team, onLeaveDemo: {}, startAt: settingsPage)
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
                settingsPage = url.pathComponents.dropFirst().first
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
        case .portrait: dressing = true
        case .study: studying = true
        case .den: denning = true
        case .hills: hilling = true
        case .vault: vaulting = true
        case .tuning: tuning = true
        case .look: looking = true
        case .grants: granting = true
        case .care: caring = true
        }
    }

    @ViewBuilder
    private func page(for target: Opened) -> some View {
        switch target {
        case .companion(let id):
            if let bot = team.bots.first(where: { $0.id == id }) {
                ChatPage(team: team, bot: bot) { opened = nil }
                    .id(target.id)
            }
        case .gathering(let id):
            if let room = team.rooms.first(where: { $0.id == id }) {
                ChatPage(team: team, room: room) { opened = nil }
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
            Button {
                Haptics.light()
                drawer = true
            } label: {
                Whale(size: 84, pose: team.doing.isEmpty ? .idle : .thinking)
            }
            .buttonStyle(PressStyle(haptic: false))
            .accessibilityLabel("打开抽屉")
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
                            Whale(size: 28, wash: Ink.wash(for: bot), still: true)
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
                        .font(.system(size: 14, weight: .semibold))
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
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Ink.warn)
                        .frame(width: 34, height: 34)
                        .background(Ink.warn.opacity(0.14), in: .circle)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(team.approvals.count > 1 ? Words.t("\(team.approvals.count) 张笺等你落印") : Words.t("\(name)等你落印"))
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.ink)
                        Text("\(name)想\(first.tool ?? "做一件事")" + ((first.reason ?? "").isEmpty ? "" : "：\(first.reason!)"))
                            .font(Ink.footnote).foregroundStyle(Ink.inkSoft).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text("去看看").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.accent)
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
            Image(systemName: "envelope").font(.system(size: 15, weight: .medium)).foregroundStyle(Ink.accent)
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
        return [
            SwipeAction(title: archived ? "拿回来" : "归档", symbol: archived ? "tray.and.arrow.up" : "archivebox", tint: Ink.accent) {
                withAnimation(Ink.Motion.settle) { team.archive(key, !archived) }
            },
            SwipeAction(title: item.bot == nil ? "散了" : "清空", symbol: "trash", tint: Ink.stop) {
                clearing = item.id
            },
        ]
    }

    /// 今天 / 昨天 / 本周 / 更早, newest first, empty groups left out.
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
                        Whale(size: 28, wash: Ink.wash(for: bot), still: true)
                    } else {
                        Image(systemName: "person.3")
                            .font(.system(size: 11, weight: .semibold))
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
