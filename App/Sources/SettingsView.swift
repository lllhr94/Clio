import AgentKit
import Craft
import SwiftUI

struct SettingsView: View {
    @ObservedObject var team: TeamModel
    /// The destination in a `clio://settings/<page>` link.
    var startAt: String? = nil

    @Environment(\.dismiss) private var dismiss
    @AppStorage("look.scheme") private var scheme = "system"

    @State private var path: [SettingsPage] = []
    @State private var query = ""
    @State private var searching = false
    @State private var sheet: SettingsPage?
    @State private var editingBot: BotInfo?
    @State private var creatingRoom = false
    @State private var editingRoom: RoomInfo?

    private static let groups: [(title: String, tint: Color, pages: [SettingsPage])] = [
        ("settingsHome.modelsGroup", Ink.Tile.dai, [.services, .models]),
        ("settingsHome.companionsGroup", Ink.Tile.yan, [.companions, .rooms, .pet, .morning]),
        ("settings.appearance", Ink.Tile.teng, [.theme, .font, .size, .tone]),
        ("settingsHome.chatGroup", Ink.Tile.mo, [.display, .context]),
        ("agent.capabilities", Ink.Tile.xiang, [.grants, .searchEngine, .connectors, .skills, .timing, .hosts]),
        ("settingsHome.privacyGroup", Ink.Tile.zhu, [.notifications, .lock, .care]),
    ]

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Ink.Space.xl) {
                    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ForEach(Self.groups, id: \.title) { group in
                            RowCard(title: L.t(group.title)) {
                                ForEach(group.pages) { page in pageRow(page, group.tint) }
                            }
                        }
                    } else {
                        searchResults
                    }
                }
                .padding(.horizontal, Ink.Space.page)
                .padding(.vertical, Ink.Space.l)
            }
            .background(Ink.paper.ignoresSafeArea())
            .searchable(text: $query, isPresented: $searching, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: L.t("settingsHome.search"))
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .hitchPage("调弦")
            .navigationTitle(L.t("nav.settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L.t("actions.done")) { Haptics.light(); dismiss() }
                }
            }
            .navigationDestination(for: SettingsPage.self, destination: destination)
        }
        .clioScheme(scheme)
        .task {
            guard let startAt, let page = SettingsPage(link: startAt) else { return }
            if page.opensSheet {
                // Wait for the full-screen settings presentation before opening a second one.
                do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
            }
            open(page)
        }
        .sheet(item: $sheet, content: sheetContent)
        .sheet(item: $editingBot) { BotEditor(team: team, bot: $0) }
        .sheet(isPresented: $creatingRoom) { RoomEditor(team: team) }
        .sheet(item: $editingRoom) { RoomEditor(team: team, room: $0) }
    }

    private var found: [SettingsPage] {
        let words = query.split(whereSeparator: \.isWhitespace)
        let pages = Self.groups.flatMap(\.pages) + [.memory, .vault, .voice]
        return pages.filter { page in
            let terms = [L.daily[page.titleKey], L.literary[page.titleKey],
                         L.daily[page.lineKey], L.literary[page.lineKey], page.keywords].compactMap { $0 }
            return words.allSatisfy { word in terms.contains { $0.localizedCaseInsensitiveContains(String(word)) } }
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        if found.isEmpty {
            Text(L.format("settings.searchNothing", query))
                .font(Ink.secondary).foregroundStyle(Ink.inkSoft)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            RowCard {
                ForEach(found) { page in
                    pageRow(page, Self.groups.first { $0.pages.contains(page) }?.tint ?? Ink.accent)
                }
            }
        }
    }

    private func pageRow(_ page: SettingsPage, _ tint: Color) -> some View {
        Button {
            Haptics.light()
            open(page)
        } label: {
            RowLabel(page.symbol, tint: tint, title: L.t(page.titleKey), line: L.t(page.lineKey))
        }
        .buttonStyle(PressStyle(haptic: false))
    }

    private func open(_ page: SettingsPage) {
        searching = false
        query = ""
        if page.opensSheet {
            sheet = page
        } else {
            path.append(page)
        }
    }

    @ViewBuilder
    private func destination(_ page: SettingsPage) -> some View {
        switch page {
        case .services:
            subpage(page) { services }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            Haptics.light()
                            open(.add)
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel(L.t("settings.addService"))
                    }
                }
        case .models:
            DefaultModelsPage(team: team) {
                path.append(.services)
            }
        case .image:
            ImageModelPage(team: team)
        case .companions:
            subpage(page) { companions }
        case .rooms:
            subpage(page) { rooms }
        case .theme:
            LookPage()
        case .font:
            FontPage()
        case .size:
            ReadingSizePage()
        case .tone:
            ToneSettingsPage()
        case .display:
            ChatDisplayPage()
        case .voice:
            VoiceSettingsPage()
        case .context:
            ChatContextPage()
        case .searchEngine:
            SearchSettingsPage()
        case .notifications:
            NotificationSettingsPage()
        case .morning:
            MorningSettingsPage()
        case .lock:
            PrivacySettingsPage {
                pageRow(.vault, Ink.Tile.zhu)
                    .padding(.horizontal, -Ink.Space.l)
            }
        case .memory:
            MemoryPageV2(team: team)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func sheetContent(_ page: SettingsPage) -> some View {
        switch page {
        case .add: SetupView(team: team) { sheet = nil }
        case .pet: PetPage()
        case .grants: GrantsPage(team: team)
        case .connectors: ConnectorsPage()
        case .skills: SkillsPage()
        case .timing: RoutinesPage(team: team)
        case .hosts: HillsPage()
        case .care: CarePage(team: team)
        case .vault: SecretsPage()
        default: EmptyView()
        }
    }

    private func subpage<Content: View>(_ page: SettingsPage, @ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Ink.Space.xl) { content() }
                .padding(.horizontal, Ink.Space.page)
                .padding(.vertical, Ink.Space.l)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Ink.paper.ignoresSafeArea())
        .navigationTitle(L.t(page.titleKey))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var services: some View {
        RowCard(note: team.phase == .demo ? L.t("settings.demoData") : nil) {
            ForEach(team.settings.endpoints) { endpoint in
                let host = URL(string: endpoint.baseURL)?.host ?? endpoint.baseURL
                NavigationLink {
                    ServicePage(team: team, id: endpoint.id)
                } label: {
                    RowLabel(title: endpoint.name, line: L.format("settings.providerCountSummary", host, endpoint.models.count)) {
                        ServiceIcon(service: Service.of(endpoint), size: Kit.badge, name: endpoint.name)
                    }
                }
                .buttonStyle(PressStyle())
            }
            pageRow(.add, Ink.Tile.dai)
        }
    }

    private var companions: some View {
        RowCard {
            if team.bots.isEmpty {
                Text(L.t("settingsHome.noCompanions"))
                    .font(Ink.secondary).foregroundStyle(Ink.inkSoft)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(Ink.Space.l)
            }
            ForEach(team.bots) { companionRow($0) }
            if team.phase != .demo { pageRow(.memory, Ink.Tile.yan) }
        }
    }

    private var rooms: some View {
        RowCard(note: team.bots.count < 2 ? L.t("settingsHome.roomsNeedCompanions") : nil) {
            ForEach(team.rooms) { room in
                Button {
                    Haptics.light()
                    editingRoom = room
                } label: {
                    RowLabel("person.3", tint: Ink.Tile.yan, title: room.name,
                             line: L.t("settingsHome.editRoomLine"))
                }
                .buttonStyle(PressStyle(haptic: false))
            }
            Button { creatingRoom = true } label: {
                RowLabel("plus", tint: Ink.Tile.yan, title: L.t("chat.newGroup"))
            }
            .buttonStyle(PressStyle())
            .disabled(team.bots.count < 2)
        }
    }

    private func companionRow(_ bot: BotInfo) -> some View {
        Button {
            Haptics.light()
            editingBot = bot
        } label: {
            RowLabel(title: bot.name, line: L.t("settingsHome.companionsLine")) {
                PetStill(size: Kit.badge, wash: Ink.wash(for: bot), avatar: true, bot: bot)
            }
        }
        .buttonStyle(PressStyle(haptic: false))
        .accessibilityLabel(L.format("settingsHome.editCompanion", bot.name))
    }
}

private enum SettingsPage: String, Identifiable {
    case services, models, image, companions, rooms, pet, theme, font, size, tone
    case display, context, grants, searchEngine, connectors, skills, timing, hosts, notifications, morning, lock, care
    case memory, vault, voice, add

    var id: Self { self }

    init?(link: String) {
        switch link {
        case "model": self = .models
        case "search": self = .searchEngine
        case "look": self = .theme
        case "look#font": self = .font
        case "look#size", "look#ui": self = .size
        case "look#tone": self = .tone
        case "look#motion": self = .display
        case "look#voice", "voice": self = .voice
        case "look#context", "look#compress": self = .context
        case "look#notify": self = .notifications
        case "look#morning": self = .morning
        case "look#lock": self = .lock
        default: self.init(rawValue: link)
        }
    }

    var opensSheet: Bool {
        switch self {
        case .add, .pet, .grants, .connectors, .skills, .timing, .hosts, .care, .vault: true
        default: false
        }
    }

    var titleKey: String {
        switch self {
        case .services: "settings.modelService"
        case .image: "settings.imageModel"
        case .rooms: "nav.groupChat"
        case .pet: "nav.pet"
        case .font: "settings.fonts"
        case .tone: "styleSwitcher.title"
        case .connectors: "agent.connectors"
        case .skills: "agent.skills"
        case .timing: "agent.scheduledJobs"
        case .hosts: "nav.remoteHost"
        case .lock: "settings.faceLock"
        case .memory: "nav.memory"
        case .vault: "settings.vault"
        case .voice: "voiceSettings.title"
        case .add: "settings.addService"
        default: "settingsHome." + rawValue
        }
    }

    var lineKey: String {
        switch self {
        case .voice: "voiceSettings.rowFooter"
        default: "settingsHome." + rawValue + "Line"
        }
    }

    var symbol: String {
        switch self {
        case .services: "server.rack"
        case .models: "sparkles"
        case .image: "photo.badge.plus"
        case .companions: "person.2"
        case .rooms: "person.3"
        case .pet: "pawprint"
        case .theme: "paintpalette"
        case .font: "textformat"
        case .size: "textformat.size"
        case .tone: "quote.bubble"
        case .display: "bubble.left"
        case .context: "text.alignleft"
        case .grants: "checkmark.shield"
        case .searchEngine: "magnifyingglass"
        case .connectors: "powerplug"
        case .skills: "books.vertical"
        case .timing: "alarm"
        case .hosts: "server.rack"
        case .notifications: "bell"
        case .morning: "sun.horizon"
        case .lock: "faceid"
        case .care: "stethoscope"
        case .memory: "brain"
        case .vault: "lock.rectangle.stack"
        case .voice: "waveform.and.mic"
        case .add: "plus"
        }
    }

    var keywords: String {
        switch self {
        case .services: "添一家 添加模型服务 密钥 key api deepseek kimi claude openai ollama lm studio 本地 中转"
        case .models: "默认 备用 换模型 兜底 出错 失败 记忆整理模型 小模型 画图 绘图 生图 图像 generate_image"
        case .image: "画图 绘图 生图 图像 generate_image"
        case .companions: "人物 角色 改名 头像 性格"
        case .rooms: "群聊 雅集 开一场 成员"
        case .pet: "宠物 伴读 小克 肉包 形象 头像 气泡 安静 导入 宠物包 图片 gif"
        case .theme: "纸墨 主题 深色 夜间 纯黑 主色"
        case .font: "字体 文楷 霞鹜 楷体 宋体 苹方 圆体 书卷 标题 题词"
        case .size: "字号 行距 大小 紧凑 放大 缩小 ui"
        case .tone: "叫法 名字 诗意 普通 书卷 日常 称呼 旁注"
        case .display: "思考 心绪 pulse 人味 淡入 触感 震动 耗时 用量 行迹 帧率 语音 听写 朗读"
        case .context: "压缩 上下文 温度 输出 长度 步数 最多步数"
        case .grants: "权限 批准 允许 智能审批 联网 浏览器 日历 提醒 位置 通讯录 照片 健康 拾遗 书案 斗室"
        case .searchEngine: "联网 搜索 引擎 anysearch tavily exa brave bing duckduckgo 查资料 密钥 key"
        case .connectors: "连接 谷歌 google gmail 邮箱 邮件 云盘 云端硬盘 drive 高德 地图 导航 github notion linear jira confluence asana canva figma zapier composio rube mcp"
        case .skills: "skill 本事"
        case .timing: "每天 每周 到点"
        case .hosts: "ssh vps 远山"
        case .notifications: "通知 锁屏 灵动岛 后台 实时活动 续跑 保活 keepawake"
        case .morning: "晨信 日记 早上"
        case .lock: "面容 face id faceid 锁 密码 隐私"
        case .care: "养护 恢复 日志 诊断 掉帧 清理 缓存 存储"
        case .memory: "记忆 拾遗 记住 忘掉"
        case .vault: "密码匣 密码 信匣 账号"
        case .voice: "语音 听写 转写 朗读 麦克风 whisper sensevoice groq siliconflow stt"
        case .add: ""
        }
    }
}
