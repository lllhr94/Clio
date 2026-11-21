import AgentKit
import Craft
import SwiftUI

/// 调弦: the model services and the default model, what the companions remember, and the way to everything else.
struct SettingsView: View {
    @ObservedObject var team: TeamModel
    var onLeaveDemo: () -> Void
    /// Opened from `clio://settings/<page>`: that page comes up at once.
    var startAt: String? = nil
    /// The companions' and tools' pages, opened by the desk once settings is closed.
    var openElsewhere: ((DrawerItem) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var textScale: CGFloat = 1
    private var accessibilityScale: CGFloat { typeSize.isAccessibilitySize ? textScale : 1 }

    @State private var query = ""
    @State private var connecting = false
    @State private var editingBot: BotInfo?
    @State private var petting = false
    @Environment(\.openURL) private var openURL
    @State private var adding = false
    @State private var looking = false
    @State private var granting = false
    @State private var caring = false
    @State private var timing = false
    @State private var skilling = false
    @State private var hilling = false
    @State private var lookFocus: String?
    @State private var memoryDraft = ""
    @State private var editingMemory: Memory?
    @State private var memoryText = ""
    @State private var balance: Balance.Reading?

    var body: some View {
        NavigationStack {
            ZStack {
                Ink.paper.ignoresSafeArea()
                ScrollView {
                    if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                        searchResults
                            .padding(.horizontal, Ink.Space.page)
                            .padding(.vertical, Ink.Space.l)
                    } else {
                    VStack(alignment: .leading, spacing: Ink.Space.xl) {
                        if team.phase == .demo { demoCard } else { overview }
                        aiGroup
                        if openElsewhere != nil { companionGroup }
                        abilityGroup
                        if openElsewhere != nil { toolGroup }
                        looksGroup
                        generalGroup
                        about
                    }
                    .padding(.horizontal, Ink.Space.page)
                    .padding(.vertical, Ink.Space.l)
                    }
                }
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "找一项设置")
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
            }
            .hitchPage("调弦")
            .navigationTitle(L.t("nav.settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L.t("actions.done")) {
                        Haptics.light()
                        dismiss()
                    }
                }
            }
        }
        .task {
            guard let startAt else { return }
            // A sheet asked for while this page is still sliding in is dropped; wait for it to settle.
            try? await Task.sleep(nanoseconds: 600_000_000)
            go(startAt)
        }
        .sheet(isPresented: $adding) { SetupView(team: team) { adding = false } }
        .sheet(isPresented: $connecting) { ConnectorsPage() }
        .sheet(isPresented: $looking, onDismiss: { lookFocus = nil }) { LookPage(focus: lookFocus) }
        .sheet(isPresented: $granting) { GrantsPage(team: team) }
        .sheet(isPresented: $caring) { CarePage(team: team) }
        .sheet(isPresented: $timing) { RoutinesPage(team: team) }
        .sheet(isPresented: $skilling) { SkillsPage() }
        .sheet(isPresented: $hilling) { HillsPage() }
        .sheet(isPresented: $petting) { PetPage() }
        .sheet(item: $editingBot) { bot in BotEditor(team: team, bot: bot) }
        .alert(Words.t("改这条拾遗"), isPresented: Binding(get: { editingMemory != nil }, set: { if !$0 { editingMemory = nil } })) {
            TextField("", text: $memoryText)
            Button(L.t("actions.save")) {
                if let editingMemory { team.editMemory(editingMemory.id, memoryText) }
                editingMemory = nil
            }
            Button(L.t("actions.cancel"), role: .cancel) { editingMemory = nil }
        } message: {
            Text(L.t("settings.clearMemoryNote"))
        }
    }

    // MARK: Search

    /// One place in the settings: what it is called, other words people use for it, and which page holds it.
    private struct Spot: Identifiable {
        var id: String { title }
        let title: String
        let words: String
        let page: String
    }

    private static let spots: [Spot] = [
        Spot(title: "添一家模型服务", words: "服务 密钥 key api deepseek kimi claude openai 本地 ollama lm studio 中转", page: "add"),
        Spot(title: "默认模型", words: "模型 默认 换模型", page: "model"),
        Spot(title: "备用模型", words: "备用 出错 失败 换模型 兜底", page: "model"),
        Spot(title: "外观：颜色、字体、字号、行距", words: "纸墨 主题 颜色 深色 纯黑 字号 行距 外观", page: "look#size"),
        Spot(title: "字体：正文和标题各选一种", words: "字体 文楷 霞鹜 楷体 宋体 苹方 圆体 书卷 标题 题词", page: "look#font"),
        Spot(title: "界面大小：整个界面放大缩小", words: "界面 缩放 大小 太大 太小 紧凑 放大 缩小 ui", page: "look#ui"),
        Spot(title: "称谓：日常或书卷", words: "称谓 叫法 名字 诗意 普通 书卷 日常 称呼 旁注", page: "look#tone"),
        Spot(title: "用面容锁住 Clio", words: "面容 face id 锁 密码 隐私", page: "look#lock"),
        Spot(title: "思考过程、心绪、逐字淡入、触感", words: "思考 心绪 pulse 人味 淡入 触感 震动 耗时 用量 行迹", page: "look#motion"),
        Spot(title: "压缩前文、上下文、温度", words: "压缩 上下文 温度 输出 长度", page: "look#context"),
        Spot(title: "通知、锁屏、灵动岛、后台续跑", words: "通知 锁屏 灵动岛 后台 实时活动 续跑", page: "look#notify"),
        Spot(title: "晨信和日记", words: "晨信 日记 早上", page: "look#morning"),
        Spot(title: "能做的事和要不要先问", words: "权限 批准 允许 联网 浏览器 日历 提醒 位置 通讯录 照片 健康 拾遗 书案 斗室", page: "grants"),
        Spot(title: "连接器：谷歌、Notion、高德地图等", words: "连接器 连接 谷歌 google gmail 邮箱 邮件 云盘 云端硬盘 drive 高德 地图 导航 github notion linear jira confluence asana canva figma zapier composio rube mcp", page: "connectors"),
        Spot(title: "宠物：选一只、大小、安静模式、导入", words: "宠物 伴读 小克 肉包 形象 头像 气泡 安静 导入 宠物包 图片 gif", page: "pet"),
        Spot(title: "定时任务", words: "定时 每天 每周 到点 任务", page: "timing"),
        Spot(title: "技能", words: "技能 skill 本事", page: "skills"),
        Spot(title: "养护：备份、日志、诊断", words: "养护 备份 恢复 日志 诊断 掉帧 清理", page: "care"),
        Spot(title: Words.t("拾遗") + "（记住的事）", words: "记忆 拾遗 记住 忘掉", page: "memory"),
    ]

    private var found: [Spot] {
        let words = query.trimmingCharacters(in: .whitespaces).lowercased()
        return Self.spots.filter { spot in
            Words.t(spot.title).lowercased().contains(words) || spot.title.lowercased().contains(words) || spot.words.lowercased().contains(words)
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        if found.isEmpty {
            Text(L.format("settings.searchNothing", query))
                .font(Ink.secondary).foregroundStyle(Ink.inkSoft)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 0) {
                ForEach(found) { spot in
                    Button {
                        Haptics.light()
                        go(spot.page)
                    } label: {
                        HStack {
                            Text(Words.t(spot.title)).font(.system(size: Ink.Size.sub, weight: .medium)).foregroundStyle(Ink.ink)
                            Spacer()
                            Kit.chevron
                        }
                        .padding(Ink.Space.l)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle())
                    Kit.rule()
                }
            }
            .paperCard()
        }
    }

    /// Opens one page of the settings: from search, or from `clio://settings/<page>`.
    private func go(_ page: String) {
        switch page {
        case "add": adding = true
        case "look": looking = true
        case let page where page.hasPrefix("look#"):
            lookFocus = String(page.dropFirst(5))
            looking = true
        case "grants": granting = true
        case "care": caring = true
        case "timing": timing = true
        case "skills": skilling = true
        case "connectors": connecting = true
        case "pet": petting = true
        default: query = ""
        }
    }

    // MARK: Sections

    private func heading(_ title: String, _ note: String? = nil) -> some View {
        FieldTitle(text: title, note: note)
    }

    private var demoCard: some View {
        VStack(alignment: .leading, spacing: Ink.Space.m) {
            Text(L.t("settings.demoData")).font(Ink.secondary).foregroundStyle(Ink.ink)
            Button(L.t("settings.exitDemoSetup")) {
                dismiss()
                onLeaveDemo()
            }
            .font(.system(size: Ink.Size.sub, weight: .semibold))
            .foregroundStyle(Ink.accent)
        }
        .padding(Ink.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperCard()
    }

    private var services: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            heading(L.t("settings.modelService"))
            VStack(spacing: 0) {
                ForEach(team.settings.endpoints) { endpoint in
                    NavigationLink {
                        ServicePage(team: team, id: endpoint.id)
                    } label: {
                        serviceRow(endpoint)
                    }
                    .buttonStyle(PressStyle(haptic: false))
                    Kit.divider
                }
                Button {
                    Haptics.light()
                    adding = true
                } label: {
                    RowLabel(title: L.t("settings.addService"), end: .none) { IconBadge(symbol: "plus") }
                }
                .buttonStyle(PressStyle(haptic: false))
                Kit.divider
                NavigationLink {
                    ImageModelPage(team: team)
                } label: {
                    let current = team.imageModelSelection.map { "\($0.model) · \($0.endpoint.name)" }
                    RowLabel("photo.badge.plus", tint: Tint.ai, title: L.t("settings.imageModel"),
                             line: current ?? L.t("settings.imageModelNone"))
                }
                .buttonStyle(PressStyle(haptic: false))
            }
            .paperCard()
        }
    }

    private func serviceRow(_ endpoint: Endpoint) -> some View {
        let seeing = endpoint.models.filter { endpoint.traits($0).sees }.count
        let host = URL(string: endpoint.baseURL)?.host ?? endpoint.baseURL
        var line = "\(host) · 在用 \(endpoint.models.count) 个"
        if !endpoint.models.isEmpty { line += seeing == 0 ? " · 都不看图" : seeing == endpoint.models.count ? " · 都能看图" : " · \(seeing) 个能看图" }
        return RowLabel(title: endpoint.name, line: line) { ServiceIcon(service: Service.of(endpoint), size: Kit.badge, name: endpoint.name) }
    }

    @ViewBuilder
    private var defaultModel: some View {
        if !team.models.isEmpty {
            VStack(alignment: .leading, spacing: Ink.Space.s) {
                heading(L.t("settings.defaultModel"))
                Menu {
                    ModelChoices(team: team, current: team.settings.defaultModel) { ref in
                        Haptics.tick(0.6)
                        team.setDefaultModel(ref)
                    }
                } label: {
                    HStack {
                        Image(systemName: "sparkle").foregroundStyle(Ink.accent)
                        Text(team.modelTitle(team.settings.defaultModel))
                            .font(.system(size: Ink.Size.body * accessibilityScale, weight: .medium))
                            .foregroundStyle(Ink.ink)
                            .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: Ink.Size.small, weight: .semibold)).foregroundStyle(Ink.inkFaint)
                    }
                    .paperField(height: typeSize.isAccessibilitySize ? nil : 50)
                }
                Menu {
                    Button {
                        Haptics.tick(0.6)
                        team.setBackupModel(nil)
                    } label: {
                        if team.settings.backupModel == nil { Label(L.t("settings.noBackupModel"), systemImage: "checkmark") } else { Text(L.t("settings.noBackupModel")) }
                    }
                    ModelChoices(team: team, current: team.settings.backupModel) { ref in
                        Haptics.tick(0.6)
                        team.setBackupModel(ref)
                    }
                } label: {
                    HStack {
                        Image(systemName: "arrow.triangle.branch").foregroundStyle(Ink.inkSoft)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(team.settings.backupModel == nil ? L.t("settings.backupModelUnset") : L.format("settings.backupModelSummary", team.modelTitle(team.settings.backupModel)))
                                .font(.system(size: Ink.Size.sub, weight: .medium))
                                .foregroundStyle(Ink.ink)
                            Text(L.t("settings.backupModelNote"))
                                .font(.system(size: Ink.Size.small))
                                .foregroundStyle(Ink.inkFaint)
                        }
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: Ink.Size.small, weight: .semibold)).foregroundStyle(Ink.inkFaint)
                    }
                    .paperField(height: typeSize.isAccessibilitySize ? nil : 50)
                }
            }
        }
    }

    private var memory: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            heading(L.t("nav.memory"), L.format("settings.memoryCounts", team.surfaceMemories.count, team.deepMemories.count))
            VStack(spacing: 0) {
                HStack(spacing: Ink.Space.s) {
                    TextField(L.t("settings.memoryPlaceholder"), text: $memoryDraft)
                        .font(.system(size: Ink.Size.sub))
                        .submitLabel(.done)
                        .onSubmit(addMemory)
                    Button(L.t("actions.save"), action: addMemory)
                        .font(.system(size: Ink.Size.sub, weight: .semibold))
                        .foregroundStyle(Ink.accent)
                        .disabled(memoryDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(Ink.Space.l)
                if !team.memories.isEmpty { Rectangle().fill(Ink.rule).frame(height: 1) }
                ForEach(team.surfaceMemories + team.deepMemories) { item in
                    HStack(alignment: .firstTextBaseline, spacing: Ink.Space.s) {
                        Text(item.text)
                            .font(.system(size: Ink.Size.sub))
                            .foregroundStyle(item.deep == true ? Ink.inkSoft : Ink.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if item.deep == true {
                            Text(L.t("organize.earlier")).font(.system(size: Ink.Size.micro, weight: .medium)).foregroundStyle(Ink.inkFaint)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Ink.rule.opacity(0.6), in: .capsule)
                        }
                    }
                    .padding(.horizontal, Ink.Space.l)
                    .padding(.vertical, Ink.Space.m)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        memoryText = item.text
                        editingMemory = item
                    }
                    .contextMenu {
                        Button(L.t("actions.edit"), systemImage: "pencil") {
                            memoryText = item.text
                            editingMemory = item
                        }
                        if item.deep == true {
                            Button(L.t("actions.pinMemory"), systemImage: "pin") { withAnimation(.smooth) { team.setDeep(item.id, false) } }
                        } else {
                            Button(L.t("actions.archiveMemory"), systemImage: "archivebox") { withAnimation(.smooth) { team.setDeep(item.id, true) } }
                        }
                        Button(L.t("actions.delete"), systemImage: "trash", role: .destructive) { withAnimation(.smooth) { team.deleteMemory(item.id) } }
                    }
                }
            }
            .paperCard()
            Text(team.memories.isEmpty ? L.t("settings.memoryEmptyNote") : Words.t("点一条可以改，长按可以挪进旧事或忘掉。超过 \(TeamModel.surfaceLimit) 件常记时，最久没提起的会自动沉下去。"))
                .font(Ink.footnote).foregroundStyle(Ink.inkFaint).padding(.leading, Ink.Space.xs)
        }
    }

    /// The one card on top: the model in use and what is left on its account.
    @ViewBuilder
    private var overview: some View {
        if let found = team.resolve(team.settings.defaultModel) {
            NavigationLink {
                ServicePage(team: team, id: found.endpoint.id)
            } label: {
                HStack(spacing: Ink.Space.m) {
                    ModelIcon(model: found.model, service: Service.of(found.endpoint), size: 46, name: found.endpoint.name)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(found.model).font(.system(size: Ink.Size.body, weight: .semibold)).foregroundStyle(Ink.ink).lineLimit(1)
                        Text(found.endpoint.name + " · " + found.endpoint.traits(found.model).summary)
                            .font(Ink.footnote).foregroundStyle(Ink.inkSoft).lineLimit(1)
                        if let balance {
                            Text("余额 " + balance.shown).font(Ink.footnote.monospacedDigit()).foregroundStyle(Ink.inkSoft)
                        }
                    }
                    Spacer(minLength: 0)
                    Kit.chevron
                }
                .padding(Ink.Space.l)
                .paperCard()
            }
            .buttonStyle(PressStyle(haptic: false))
            .task {
                if Balance.source(baseURL: found.endpoint.baseURL) != nil { balance = try? await team.balance(found.endpoint) }
            }
        }
    }

    // MARK: Groups, the way settings are laid out elsewhere: a heading, rows with a coloured icon

    /// One pigment per group (see `Ink.Tile`).
    private enum Tint {
        static let ai = Ink.Tile.dai
        static let ability = Ink.Tile.xiang
        static let looks = Ink.Tile.teng
        static let general = Ink.Tile.zhu
    }

    private func group<Content: View>(_ title: String, @ViewBuilder _ rows: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle(title)
            VStack(spacing: 0) { rows() }.paperCard()
        }
    }

    private var divider: some View { Kit.divider }

    private func badge(_ icon: String, _ tint: Color) -> some View { IconBadge(symbol: icon, tint: tint) }

    /// `title` is a dictionary key ("nav.memory") or plain words; a key also brings its 日常旁注.
    private func rowLabel(_ icon: String, _ tint: Color, _ title: String, _ value: String?, warn: Bool = false) -> some View {
        let keyed = L.daily[title] != nil
        return RowLabel(icon, tint: tint, title: keyed ? L.t(title) : title, hint: keyed ? L.hint(title) : nil,
                        end: value.map { RowEnd.valueChevron($0, warn ? Ink.warn : Ink.inkSoft) } ?? RowEnd.chevron)
    }

    /// A row that opens a sheet.
    private func row(_ icon: String, _ tint: Color, _ title: String, _ value: String?, warn: Bool = false, _ open: @escaping () -> Void) -> some View {
        Button {
            Haptics.light()
            open()
        } label: { rowLabel(icon, tint, title, value, warn: warn) }
        .buttonStyle(PressStyle(haptic: false))
    }

    /// A row that pushes a page.
    private func pushRow<Page: View>(_ icon: String, _ tint: Color, _ title: String, _ value: String?, warn: Bool = false, @ViewBuilder _ page: @escaping () -> Page) -> some View {
        NavigationLink {
            page()
        } label: { rowLabel(icon, tint, title, value, warn: warn) }
        .buttonStyle(PressStyle(haptic: false))
    }

    /// A page of its own, with the settings' paper and padding.
    private func subpage<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Ink.Space.xl) { content() }
                .padding(.horizontal, Ink.Space.page)
                .padding(.vertical, Ink.Space.l)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Ink.paper.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var aiGroup: some View {
        group(L.t("settings.ai")) {
            pushRow("sparkles", Tint.ai, "settings.models", team.settings.endpoints.isEmpty ? "还没接" : team.modelShort(team.settings.defaultModel), warn: team.settings.endpoints.isEmpty) {
                subpage(L.t("settings.models")) {
                    services
                    defaultModel
                }
            }
            if team.phase != .demo {
                divider
                pushRow("brain", Tint.ai, "nav.memory", team.memories.isEmpty ? "还没有" : "\(team.memories.count) 条") {
                    subpage(L.t("nav.memory")) { memory }
                }
            }
            divider
            row("books.vertical", Tint.ai, "agent.skills", "\(SkillShelf.enabled.count) 个") { skilling = true }
        }
    }

    private var abilityGroup: some View {
        group(L.t("agent.capabilities")) {
            row("checkmark.shield", Tint.ability, "settings.permissions", Grant.Preset.current?.title ?? "自定义") { granting = true }
            divider
            row("powerplug", Tint.ability, "agent.connectors", connectorsLine) { connecting = true }
            divider
            row("alarm", Tint.ability, "agent.scheduledJobs", team.routines.isEmpty ? "没有" : "\(team.routines.filter(\.on).count) 件") { timing = true }
            divider
            row("server.rack", Tint.ability, "nav.remoteHost", Hills.shared.hosts.isEmpty ? "没有" : "\(Hills.shared.hosts.count) 台") { hilling = true }
        }
    }

    private var looksGroup: some View {
        group(L.t("settings.appearance")) {
            row("paintpalette", Tint.looks, "主题、字号与对话", Theme.shared.palette.title + " · " + LookPage.sizes[LookPage.sizeStep(Pref.size)].title) { looking = true }
            divider
            row("pawprint", Tint.looks, "nav.pet", (PetLibrary.shared.pack?.name ?? "") + (PetLibrary.shared.visible ? "" : " · 不站出来")) { petting = true }
            divider
            HStack(spacing: Ink.Space.m) {
                badge("quote.bubble", Tint.looks)
                Text(L.t("settings.tone")).font(.system(size: Ink.Size.body)).foregroundStyle(Ink.ink)
                Spacer(minLength: Ink.Space.s)
                Picker(L.t("settings.tone"), selection: Binding(get: { Theme.shared.plain }, set: { Haptics.tick(0.5); Theme.shared.setPlain($0) })) {
                    Text(L.t("styleSwitcher.dailyLabel")).tag(true)
                    Text(L.t("styleSwitcher.literaryLabel")).tag(false)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
            }
            .padding(.horizontal, Ink.Space.l)
            .frame(minHeight: Kit.rowHeight)
        }
    }

    private enum Tint2 {
        static let people = Ink.Tile.yan
        static let tools = Ink.Tile.mo
    }

    /// Leaves settings and opens one of the desk's own pages.
    private func elsewhere(_ item: DrawerItem) {
        dismiss()
        openElsewhere?(item)
    }

    private var companionGroup: some View {
        group(L.t("nav.assistant")) {
            // Each companion its own row: tap to change the name, the character, the model.
            ForEach(team.bots) { bot in
                companionRow(bot)
                divider
            }
            row("person.badge.plus", Tint2.people, Words.t("新旅伴"), nil) { elsewhere(.newCompanion) }
            divider
            row("person.3", Tint2.people, "nav.groupChat", team.rooms.isEmpty ? "没有" : "\(team.rooms.count) 个") { elsewhere(.gathering) }
            divider
            row("square.and.arrow.down", Tint2.people, Words.t("收名帖"), nil) { elsewhere(.importCard) }
        }
    }

    private func companionRow(_ bot: BotInfo) -> some View {
        Button {
            Haptics.light()
            editingBot = bot
        } label: {
            RowLabel(title: bot.name, line: bot.role, end: .valueChevron(team.modelShort(bot.model ?? team.settings.defaultModel))) {
                PetStill(size: Kit.badge, wash: Ink.wash(for: bot), avatar: true, bot: bot)
            }
        }
        .buttonStyle(PressStyle(haptic: false))
        .accessibilityLabel("\(bot.name)，改名字、性格、模型")
    }

    private var toolGroup: some View {
        group(L.t("settings.tools")) {
            row("books.vertical", Tint2.tools, "nav.files", "旅伴写的文件") { elsewhere(.study) }
            divider
            row("terminal", Tint2.tools, "nav.terminal", "手机里的 Linux") { elsewhere(.den) }
            divider
            row("lock.rectangle.stack", Tint2.tools, "settings.vault", "账号密码") { elsewhere(.vault) }
        }
    }

    private var generalGroup: some View {
        group(L.t("settings.general")) {
            row("bell", Tint.general, "通知、锁屏与后台", nil) { lookFocus = "notify"; looking = true }
            divider
            row("lock", Tint.general, "settings.faceLock", UserDefaults.standard.bool(forKey: "lock.faceid") ? "开" : "关") { lookFocus = "lock"; looking = true }
            divider
            row("stethoscope", Tint.general, "settings.diagnostics", "备份与诊断") { caring = true }
        }
    }

    private var connectorsLine: String {
        let count = (Google.shared.connected ? 1 : 0) + Hills.shared.servers.filter { $0.connector != nil }.count
        return count == 0 ? "谷歌、Notion、高德…" : "连了 \(count) 个"
    }

    private var about: some View {
        VStack(spacing: Ink.Space.xs) {
            Text("Clio \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                .font(Ink.serif(14, bold: true)).foregroundStyle(Ink.inkSoft)
            Text("开源 · GPL-3.0\nLinux 环境用 iSH，终端画面用 SwiftTerm，SSH 用 Citadel")
                .font(Ink.footnote).foregroundStyle(Ink.inkFaint).multilineTextAlignment(.center)
            Button("github.com/lllhr94/Clio") {
                if let url = URL(string: "https://github.com/lllhr94/Clio") { openURL(url) }
            }
            .font(Ink.footnote)
            .foregroundStyle(Ink.accent)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Ink.Space.l)
    }

    // MARK: Doing

    private func addMemory() {
        let words = memoryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        withAnimation(.smooth) { team.remember(words, by: nil) }
        memoryDraft = ""
        Haptics.tick(0.6)
    }
}
