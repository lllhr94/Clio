import SwiftUI

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
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Ink.paper.ignoresSafeArea()
            if team.phase == .setup {
                SetupView(team: team, first: true) {}
                    .transition(.blurReplace)
            } else {
                Desk(team: team)
                    .transition(.blurReplace)
            }
        }
        .animation(Ink.Motion.settle, value: team.phase)
        .tint(Ink.accent)
        .onChange(of: scenePhase) { _, now in
            if now == .active { team.wake() }
        }
        .task {
            // Messages set for later land in their chats while the app is open too.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                team.deliverDue()
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
    @State private var dressing = false
    @State private var gathering = false

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

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    companions
                    if let next = team.nextLetter { letter(next) }
                    Text("近来的絮语")
                        .font(Ink.title)
                        .foregroundStyle(Ink.ink)
                        .padding(.top, Ink.Space.xxl)
                        .padding(.bottom, Ink.Space.s)
                    if recent.isEmpty {
                        Text("还没有聊过。点上面的旅伴，说第一句话吧。")
                            .font(Ink.secondary)
                            .foregroundStyle(Ink.inkSoft)
                            .padding(.vertical, Ink.Space.l)
                    }
                    ForEach(Array(recent.enumerated()), id: \.element.id) { index, item in
                        thread(item)
                        if index != recent.count - 1 {
                            Rectangle().fill(Ink.rule).frame(height: 1).padding(.leading, 40)
                        }
                    }
                }
                .padding(.horizontal, Ink.Space.page)
                .padding(.bottom, Ink.Space.huge)
            }
            .scrollIndicators(.hidden)
            .opacity(opened == nil ? 1 : 0)
            .scaleEffect(opened == nil ? 1 : 0.96)

            if let opened {
                page(for: opened)
                    .background(Ink.paper)
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .trailing)))
                    .zIndex(1)
            }
        }
        .animation(Ink.Motion.unfold, value: opened)
        .sheet(item: $editing) { target in BotEditor(team: team, bot: target.bot) }
        .sheet(isPresented: $gathering) { RoomEditor(team: team) }
        .sheet(isPresented: $dressing) { PortraitPage() }
        .fullScreenCover(isPresented: $tuning) {
            SettingsView(team: team) {}
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
            Menu {
                Button("新旅伴", systemImage: "person.badge.plus") { editing = EditTarget(id: "new", bot: nil) }
                Button("雅集", systemImage: "person.3") { gathering = true }
                Button("形象", systemImage: "paintpalette") { dressing = true }
                Button("调弦", systemImage: "slider.horizontal.3") { tuning = true }
            } label: {
                Whale(size: 84, pose: team.doing.isEmpty ? .idle : .thinking)
            }
            .accessibilityLabel("菜单")
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
                        Button("改名帖", systemImage: "pencil") { editing = EditTarget(id: bot.id, bot: bot) }
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
                .accessibilityLabel("新旅伴")
            }
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .padding(.top, Ink.Space.xl)
    }

    private func letter(_ next: Later) -> some View {
        HStack(spacing: Ink.Space.s) {
            Image(systemName: "envelope").font(.system(size: 15, weight: .medium)).foregroundStyle(Ink.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("来信 · \(When.show(Date(timeIntervalSince1970: next.at)))").font(Ink.footnote).foregroundStyle(Ink.inkSoft)
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

    private func thread(_ item: (id: Opened, name: String, preview: String, at: Double, bot: BotInfo?)) -> some View {
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
                    Text(item.preview.isEmpty ? "…" : item.preview)
                        .font(Ink.secondary)
                        .foregroundStyle(Ink.inkSoft)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, Ink.Space.m)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(haptic: false))
        .contextMenu {
            if case .gathering(let id) = item.id {
                Button("散了这个雅集", systemImage: "trash", role: .destructive) { team.deleteRoom(id) }
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
