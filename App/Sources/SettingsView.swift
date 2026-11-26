import AgentKit
import Craft
import SwiftUI

struct SettingsView: View {
    @ObservedObject var team: TeamModel
    /// The destination in a `clio://settings/<page>` link.
    var startAt: String? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @ObservedObject private var hills = Hills.shared

    @AppStorage("look.scheme") private var scheme = "system"
    @AppStorage("lock.faceid") private var faceLock = false
    @AppStorage("morning.on") private var morningOn = false
    @AppStorage("diary.on") private var diaryOn = false
    @AppStorage("notify.done") private var notifyDone = true
    @AppStorage("live.on") private var liveOn = true
    @AppStorage(VoiceTranscription.modeKey) private var voiceModeRaw = VoiceTranscription.Mode.system.rawValue
    @AppStorage(VoiceTranscription.modelKey) private var voiceModel = ""
    @AppStorage(SearchEngine.providerKey) private var searchProviderRaw = WebSearchProvider.builtin.rawValue

    @State private var path: [SettingsPage] = []
    @State private var query = ""
    @State private var searching = false
    @State private var sheet: SettingsPage?
    @State private var editingBot: BotInfo?
    @State private var creatingRoom = false
    @State private var editingRoom: RoomInfo?

    private static let groups: [(title: String, tint: Color, pages: [SettingsPage])] = [
        ("settingsHome.modelsGroup", Ink.Tile.dai, [.services, .models, .image]),
        ("settings.appearance", Ink.Tile.teng, [.theme, .font, .size, .tone]),
        ("settingsHome.chatGroup", Ink.Tile.mo, [.display, .context, .voice]),
        ("settingsHome.companionsGroup", Ink.Tile.yan, [.companions, .rooms, .memory, .pet, .morning]),
        ("agent.capabilities", Ink.Tile.xiang, [.connectors, .skills, .searchEngine, .hosts, .timing]),
        ("settingsHome.privacyGroup", Ink.Tile.zhu, [.grants, .vault, .lock]),
        ("settingsHome.notifyGroup", Ink.Tile.dai, [.notifications]),
        ("settingsHome.dataGroup", Ink.Tile.mo, [.careBackup, .careUsage, .careStorage, .careDiagnostics]),
        ("settingsHome.aboutGroup", Ink.Tile.teng, [.about]),
    ]

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                listContent
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

    private var listContent: some View {
        LazyVStack(alignment: .leading, spacing: Ink.Space.xl) {
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                identityHeader
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

    private var primaryBot: BotInfo? {
        team.bots.first { $0.id == team.mainBotId } ?? team.bots.first
    }

    private var identityHeader: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Ink.Space.m))
            : AnyLayout(HStackLayout(spacing: Ink.Space.m))
        return layout {
            Button {
                Haptics.light()
                if let bot = primaryBot {
                    editingBot = bot
                } else {
                    open(.companions)
                }
            } label: {
                HStack(spacing: Ink.Space.m) {
                    if let bot = primaryBot {
                        PetStill(size: 36 * UIScale.factor, wash: Ink.wash(for: bot), avatar: true, bot: bot)
                    } else {
                        IconBadge(symbol: "person.2", tint: Ink.Tile.yan, size: 36 * UIScale.factor)
                    }
                    VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
                        Text(primaryBot?.name ?? L.t("settingsHome.identityDefaultBot"))
                            .font(.system(size: Ink.Size.sub, weight: .semibold))
                            .foregroundStyle(Ink.ink)
                            .lineLimit(1)
                        Text(L.t("settingsHome.identityDefaultBot"))
                            .font(.system(size: Ink.Size.micro))
                            .foregroundStyle(Ink.inkSoft)
                            .lineLimit(1)
                    }
                    Spacer(minLength: Ink.Space.xs)
                    Kit.chevron
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle(haptic: false))
            .frame(maxWidth: .infinity, alignment: .leading)

            if typeSize.isAccessibilitySize {
                Kit.rule(inset: 0)
            } else {
                Rectangle()
                    .fill(Ink.rule)
                    .frame(width: 0.5, height: 32 * UIScale.factor)
            }

            HStack(spacing: Ink.Space.m) {
                MeAvatar(size: 36 * UIScale.factor)
                VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
                    Text(L.t("settingsHome.identityMe"))
                        .font(.system(size: Ink.Size.sub, weight: .semibold))
                        .foregroundStyle(Ink.ink)
                        .lineLimit(1)
                    Text(L.t("settingsHome.identityTapAvatar"))
                        .font(.system(size: Ink.Size.micro))
                        .foregroundStyle(Ink.inkSoft)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Ink.Space.l)
        .paperCard()
    }

    private var found: [SettingsPage] {
        let words = query.split(whereSeparator: \.isWhitespace)
        let pages = Self.groups.flatMap(\.pages)
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
                    let group = Self.groups.first { $0.pages.contains(page) }
                    let breadcrumb = group.map { "\(L.t($0.title)) · \(L.t(page.lineKey))" }
                    pageRow(page, group?.tint ?? Ink.accent, lineOverride: breadcrumb)
                }
            }
        }
    }

    private func pageRow(_ page: SettingsPage, _ tint: Color, lineOverride: String? = nil) -> some View {
        let end: RowEnd = summary(for: page).map { .valueChevron($0) } ?? .chevron
        return Button {
            Haptics.light()
            open(page)
        } label: {
            RowLabel(
                page.symbol,
                tint: tint,
                title: L.t(page.titleKey),
                line: lineOverride ?? L.t(page.lineKey),
                end: end
            )
        }
        .buttonStyle(PressStyle(haptic: false))
    }

    private var schemeSummary: String {
        switch scheme {
        case "light": L.t("settings.lightAppearance")
        case "dark": L.t("settings.darkAppearance")
        default: L.t("settings.followSystem")
        }
    }

    private var voiceSummary: String {
        let mode = VoiceTranscription.Mode(rawValue: voiceModeRaw) ?? .system
        if mode == .cloud {
            let trimmed = voiceModel.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? L.t("voiceSettings.cloudShort") : trimmed
        }
        return mode.title
    }

    private var searchSummary: String {
        let provider = WebSearchProvider(rawValue: searchProviderRaw) ?? .builtin
        return provider == .builtin ? "内置网页" : provider.name
    }

    private func summary(for page: SettingsPage) -> String? {
        switch page {
        case .services:
            return team.settings.endpoints.isEmpty
                ? L.t("settingsHome.notConnected")
                : L.format("settingsHome.connectedCount", team.settings.endpoints.count)
        case .models:
            if let resolved = team.resolve(team.settings.defaultModel) {
                return ChatPage.shortModelName(resolved.model)
            }
            return L.t("settingsHome.unset")
        case .image:
            if let selection = team.imageModelSelection {
                return ChatPage.shortModelName(selection.model)
            }
            return L.t("settingsHome.disabled")
        case .theme:
            return "\(schemeSummary) · \(Theme.shared.palette.title)"
        case .font:
            return Pref.face.title
        case .size:
            return "\(Int(Pref.size))pt · \(String(format: "%.2g×", Pref.lineHeight))"
        case .tone:
            return Theme.shared.plain ? L.t("styleSwitcher.dailyLabel") : L.t("styleSwitcher.literaryLabel")
        case .context:
            return "\(Int((Pref.contextShare * 100).rounded()))% · \(L.format("settingsHome.stepsCount", Pref.maxSteps))"
        case .voice:
            return voiceSummary
        case .companions:
            return L.format("settingsHome.companionsCount", team.bots.count)
        case .rooms:
            return L.format("settingsHome.roomsCount", team.rooms.count)
        case .memory:
            return L.format("settingsHome.itemsCount", team.memories.count)
        case .pet:
            return PetLibrary.shared.pack?.name
        case .morning:
            return (morningOn || diaryOn) ? L.t("settingsHome.enabled") : L.t("settingsHome.disabled")
        case .connectors:
            return hills.servers.isEmpty ? nil : L.format("settingsHome.itemsCount", hills.servers.count)
        case .searchEngine:
            return searchSummary
        case .hosts:
            return L.format("settingsHome.hostsCount", hills.hosts.count)
        case .timing:
            return team.routines.isEmpty ? nil : L.format("settingsHome.itemsCount", team.routines.count)
        case .grants:
            return Grant.Preset.current?.title
        case .lock:
            return faceLock ? L.t("settingsHome.enabled") : L.t("settingsHome.disabled")
        case .notifications:
            return (notifyDone || liveOn) ? L.t("settingsHome.enabled") : L.t("settingsHome.disabled")
        case .careStorage:
            return team.archived.isEmpty ? nil : L.format("settingsHome.archivedCount", team.archived.count)
        case .about:
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
            return "v\(version)"
        default:
            return nil
        }
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
            subpage(page) {
                SettingsServicesSection(team: team) { open(.add) }
            }
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
            subpage(page) {
                SettingsCompanionsSection(team: team, editingBot: $editingBot) { open(.memory) }
            }
        case .rooms:
            subpage(page) {
                SettingsRoomsSection(team: team, creatingRoom: $creatingRoom, editingRoom: $editingRoom)
            }
        case .pet:
            PetPage(embedded: true)
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
        case .grants:
            GrantsPage(team: team, embedded: true)
        case .connectors:
            ConnectorsPage(embedded: true)
        case .skills:
            SkillsPage(embedded: true)
        case .searchEngine:
            SearchSettingsPage()
        case .hosts:
            HillsPage(embedded: true)
        case .timing:
            RoutinesPage(team: team, embedded: true)
        case .vault:
            SecretsPage(embedded: true)
        case .notifications:
            NotificationSettingsPage()
        case .morning:
            MorningSettingsPage()
        case .lock:
            PrivacySettingsPage(showsVaultRow: false) { EmptyView() }
        case .memory:
            MemoryPageV2(team: team)
        case .careBackup:
            CarePage(team: team, scope: .backup, embedded: true)
        case .careUsage:
            CareUsagePage(team: team)
        case .careStorage:
            CarePage(team: team, scope: .storage, embedded: true)
        case .careDiagnostics:
            CarePage(team: team, scope: .diagnostics, embedded: true)
        case .about:
            CareAboutPage()
        case .add:
            EmptyView()
        }
    }

    @ViewBuilder
    private func sheetContent(_ page: SettingsPage) -> some View {
        switch page {
        case .add: SetupView(team: team) { sheet = nil }
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
}

private struct SettingsServicesSection: View {
    @ObservedObject var team: TeamModel
    let openAdd: () -> Void

    var body: some View {
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
            Button {
                Haptics.light()
                openAdd()
            } label: {
                RowLabel(SettingsPage.add.symbol, tint: Ink.Tile.dai, title: L.t(SettingsPage.add.titleKey), line: L.t(SettingsPage.add.lineKey))
            }
            .buttonStyle(PressStyle(haptic: false))
        }
    }
}

private struct SettingsCompanionsSection: View {
    @ObservedObject var team: TeamModel
    @Binding var editingBot: BotInfo?
    let openMemory: () -> Void

    var body: some View {
        RowCard {
            if team.bots.isEmpty {
                Text(L.t("settingsHome.noCompanions"))
                    .font(Ink.secondary).foregroundStyle(Ink.inkSoft)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(Ink.Space.l)
            }
            ForEach(team.bots) { companionRow($0) }
            if team.phase != .demo {
                Button {
                    Haptics.light()
                    openMemory()
                } label: {
                    RowLabel(SettingsPage.memory.symbol, tint: Ink.Tile.yan, title: L.t(SettingsPage.memory.titleKey), line: L.t(SettingsPage.memory.lineKey))
                }
                .buttonStyle(PressStyle(haptic: false))
            }
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

private struct SettingsRoomsSection: View {
    @ObservedObject var team: TeamModel
    @Binding var creatingRoom: Bool
    @Binding var editingRoom: RoomInfo?

    var body: some View {
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
}

private enum SettingsPage: String, Identifiable {
    case services, models, image, companions, rooms, pet, theme, font, size, tone
    case display, context, grants, searchEngine, connectors, skills, timing, hosts, notifications, morning, lock
    case careBackup, careUsage, careStorage, careDiagnostics, about
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
        case "care", "backup": self = .careBackup
        case "usage": self = .careUsage
        case "storage": self = .careStorage
        case "diagnostics": self = .careDiagnostics
        case "about": self = .about
        default: self.init(rawValue: link)
        }
    }

    var opensSheet: Bool {
        self == .add
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
        case .about: "settingsHome.aboutClio"
        case .add: "settings.addService"
        default: "settingsHome." + rawValue
        }
    }

    var lineKey: String {
        switch self {
        case .voice: "voiceSettings.rowFooter"
        case .about: "settingsHome.aboutClioLine"
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
        case .careBackup: "externaldrive.badge.icloud"
        case .careUsage: "chart.bar"
        case .careStorage: "internaldrive"
        case .careDiagnostics: "stethoscope"
        case .about: "info.circle"
        case .memory: "brain"
        case .vault: "lock.rectangle.stack"
        case .voice: "waveform.and.mic"
        case .add: "plus"
        }
    }

    var keywords: String {
        switch self {
        case .services: "添一家 添加模型服务 密钥 key api deepseek kimi claude openai ollama lm studio 本地 中转"
        case .models: "默认 备用 换模型 兜底 出错 失败 记忆整理模型 小模型"
        case .image: "画图 绘图 生图 图像 generate_image"
        case .companions: "人物 角色 改名 头像 性格"
        case .rooms: "群聊 雅集 开一场 成员"
        case .pet: "宠物 伴读 小克 肉包 形象 头像 气泡 安静 导入 宠物包 图片 gif"
        case .theme: "纸墨 主题 深色 夜间 纯黑 主色 设色"
        case .font: "字体 font 文楷 霞鹜 楷体 宋体 苹方 圆体 书卷 标题 题词"
        case .size: "字号 行距 大小 spacing clreq 紧凑 放大 缩小 ui 密度"
        case .tone: "叫法 名字 诗意 普通 书卷 日常 称呼 旁注"
        case .display: "思考 心绪 pulse 人味 淡入 触感 震动 耗时 用量 行迹 帧率"
        case .context: "压缩 上下文 温度 输出 长度 步数 最多步数"
        case .grants: "权限 批准 允许 智能审批 联网 浏览器 日历 提醒 位置 通讯录 照片 健康 拾遗 书案 斗室"
        case .searchEngine: "联网 搜索 引擎 anysearch tavily exa brave bing duckduckgo searxng 查资料 密钥 key"
        case .connectors: "连接 谷歌 google gmail 邮箱 邮件 云盘 云端硬盘 drive 高德 地图 导航 github notion linear jira confluence asana canva figma zapier composio rube mcp"
        case .skills: "skill 本事 技能"
        case .timing: "每天 每周 到点 定时任务"
        case .hosts: "ssh vps 服务器 远山"
        case .notifications: "通知 锁屏 灵动岛 后台 实时活动 续跑 保活 keepawake"
        case .morning: "晨信 早报 日记 手札 早上"
        case .lock: "面容 face id faceid 锁 密码 隐私"
        case .careBackup: "备份 恢复 webdav 云同步 导出 导入 care"
        case .careUsage: "用量 费用 token 余额 usage 统计"
        case .careStorage: "清理 缓存 存储 归档 空间 storage"
        case .careDiagnostics: "诊断 日志 报错 掉帧 帧率 连通 测速 养护"
        case .about: "关于 about 版本 协议 gpl 开源 字体 致谢 github"
        case .memory: "记忆 拾遗 memory 记住 忘掉"
        case .vault: "密码匣 密码 信匣 账号 vault token"
        case .voice: "语音 听写 转写 朗读 麦克风 whisper sensevoice groq siliconflow stt"
        case .add: ""
        }
    }
}
