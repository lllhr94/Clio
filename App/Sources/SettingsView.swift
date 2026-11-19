import AgentKit
import Craft
import SwiftUI

/// 调弦: the model services and the default model, what the companions remember, and the way to everything else.
struct SettingsView: View {
    @ObservedObject var team: TeamModel
    var onLeaveDemo: () -> Void
    /// Opened from `clio://settings/<page>`: that page comes up at once.
    var startAt: String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @Environment(\.openURL) private var openURL
    @State private var adding = false
    @State private var looking = false
    @State private var granting = false
    @State private var caring = false
    @State private var timing = false
    @State private var skilling = false
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
                        if team.phase == .demo {
                            demoCard
                        } else {
                            overview
                            services
                            defaultModel
                        }
                        abilities
                        if team.phase != .demo { memory }
                        more
                        about
                    }
                    .padding(.horizontal, Ink.Space.page)
                    .padding(.vertical, Ink.Space.l)
                    }
                }
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "找一项设置")
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
            }
            .hitchPage("调弦")
            .navigationTitle(Words.t("调弦"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("好了") {
                        Haptics.light()
                        dismiss()
                    }
                }
            }
        }
        .task { if let startAt { go(startAt) } }
        .sheet(isPresented: $adding) { SetupView(team: team) { adding = false } }
        .sheet(isPresented: $looking) { LookPage() }
        .sheet(isPresented: $granting) { GrantsPage(team: team) }
        .sheet(isPresented: $caring) { CarePage(team: team) }
        .sheet(isPresented: $timing) { RoutinesPage(team: team) }
        .sheet(isPresented: $skilling) { SkillsPage() }
        .alert(Words.t("改这条拾遗"), isPresented: Binding(get: { editingMemory != nil }, set: { if !$0 { editingMemory = nil } })) {
            TextField("", text: $memoryText)
            Button("存好") {
                if let editingMemory { team.editMemory(editingMemory.id, memoryText) }
                editingMemory = nil
            }
            Button("算了", role: .cancel) { editingMemory = nil }
        } message: {
            Text("改空就是忘掉。")
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
        Spot(title: "外观：颜色、字体、字号、行距", words: "纸墨 主题 颜色 深色 纯黑 字体 字号 行距 外观", page: "look"),
        Spot(title: "叫法：诗意或普通", words: "叫法 名字 诗意 普通 称呼", page: "look"),
        Spot(title: "用面容锁住 Clio", words: "面容 face id 锁 密码 隐私", page: "look"),
        Spot(title: "思考过程、心绪、逐字淡入、触感", words: "思考 心绪 pulse 人味 淡入 触感 震动 耗时 用量 行迹 形象", page: "look"),
        Spot(title: "压缩前文、上下文、温度", words: "压缩 上下文 温度 输出 长度", page: "look"),
        Spot(title: "通知、锁屏、灵动岛、后台续跑", words: "通知 锁屏 灵动岛 后台 实时活动 续跑", page: "look"),
        Spot(title: "晨信和日记", words: "晨信 日记 早上", page: "look"),
        Spot(title: "能做的事和要不要先问", words: "权限 批准 允许 联网 浏览器 日历 提醒 位置 通讯录 照片 健康 拾遗 书案 斗室", page: "grants"),
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
            Text("没找到「\(query)」。换个说法试试，比如「密钥」「字号」「通知」。")
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
                            Text(Words.t(spot.title)).font(.system(size: 15, weight: .medium)).foregroundStyle(Ink.ink)
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.inkFaint)
                        }
                        .padding(Ink.Space.l)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle())
                    Rectangle().fill(Ink.rule).frame(height: 1).padding(.leading, Ink.Space.l)
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
        case "grants": granting = true
        case "care": caring = true
        case "timing": timing = true
        case "skills": skilling = true
        default: query = ""
        }
    }

    // MARK: Sections

    private func heading(_ title: String, _ note: String? = nil) -> some View {
        FieldTitle(text: title, note: note)
    }

    private var demoCard: some View {
        VStack(alignment: .leading, spacing: Ink.Space.m) {
            Text("现在是演示数据").font(Ink.secondary).foregroundStyle(Ink.ink)
            Button("退出演示，去接模型") {
                dismiss()
                onLeaveDemo()
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Ink.accent)
        }
        .padding(Ink.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperCard()
    }

    private var services: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            heading("模型服务")
            VStack(spacing: 0) {
                ForEach(team.settings.endpoints) { endpoint in
                    NavigationLink {
                        ServicePage(team: team, id: endpoint.id)
                    } label: {
                        serviceRow(endpoint)
                    }
                    .buttonStyle(PressStyle(haptic: false))
                    Rectangle().fill(Ink.rule).frame(height: 1).padding(.leading, Ink.Space.l)
                }
                Button {
                    Haptics.light()
                    adding = true
                } label: {
                    Label("添一家服务", systemImage: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Ink.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Ink.Space.l)
                }
                .buttonStyle(PressStyle())
            }
            .paperCard()
        }
    }

    private func serviceRow(_ endpoint: Endpoint) -> some View {
        let seeing = endpoint.models.filter { endpoint.traits($0).sees }.count
        let host = URL(string: endpoint.baseURL)?.host ?? endpoint.baseURL
        var line = "\(host) · 在用 \(endpoint.models.count) 个"
        if !endpoint.models.isEmpty { line += seeing == 0 ? " · 都不看图" : seeing == endpoint.models.count ? " · 都能看图" : " · \(seeing) 个能看图" }
        return HStack(spacing: Ink.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(endpoint.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(Ink.ink)
                Text(line).font(Ink.footnote).foregroundStyle(Ink.inkSoft).lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Ink.inkFaint)
        }
        .padding(Ink.Space.l)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var defaultModel: some View {
        if !team.models.isEmpty {
            VStack(alignment: .leading, spacing: Ink.Space.s) {
                heading("默认模型")
                Menu {
                    ModelChoices(team: team, current: team.settings.defaultModel) { ref in
                        Haptics.tick(0.6)
                        team.setDefaultModel(ref)
                    }
                } label: {
                    HStack {
                        Image(systemName: "sparkle").foregroundStyle(Ink.accent)
                        Text(team.modelTitle(team.settings.defaultModel))
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Ink.ink)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.inkFaint)
                    }
                    .paperField()
                }
                Menu {
                    Button {
                        Haptics.tick(0.6)
                        team.setBackupModel(nil)
                    } label: {
                        if team.settings.backupModel == nil { Label("不用备用", systemImage: "checkmark") } else { Text("不用备用") }
                    }
                    ModelChoices(team: team, current: team.settings.backupModel) { ref in
                        Haptics.tick(0.6)
                        team.setBackupModel(ref)
                    }
                } label: {
                    HStack {
                        Image(systemName: "arrow.triangle.branch").foregroundStyle(Ink.inkSoft)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(team.settings.backupModel == nil ? "备用模型：没设" : "备用模型：\(team.modelTitle(team.settings.backupModel))")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Ink.ink)
                                .lineLimit(1)
                            Text("主模型出错时换它接着答，会在对话里说一声。")
                                .font(.system(size: 12))
                                .foregroundStyle(Ink.inkFaint)
                        }
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.inkFaint)
                    }
                    .paperField()
                }
            }
        }
    }

    private var memory: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            heading(Words.t("拾遗"), "常记 \(team.surfaceMemories.count) · 旧事 \(team.deepMemories.count)")
            VStack(spacing: 0) {
                HStack(spacing: Ink.Space.s) {
                    TextField("自己记一条，比如：我不吃香菜", text: $memoryDraft)
                        .font(.system(size: 15))
                        .submitLabel(.done)
                        .onSubmit(addMemory)
                    Button("记下", action: addMemory)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Ink.accent)
                        .disabled(memoryDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(Ink.Space.l)
                if !team.memories.isEmpty { Rectangle().fill(Ink.rule).frame(height: 1) }
                ForEach(team.surfaceMemories + team.deepMemories) { item in
                    HStack(alignment: .firstTextBaseline, spacing: Ink.Space.s) {
                        Text(item.text)
                            .font(.system(size: 15))
                            .foregroundStyle(item.deep == true ? Ink.inkSoft : Ink.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if item.deep == true {
                            Text("旧事").font(.system(size: 11, weight: .medium)).foregroundStyle(Ink.inkFaint)
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
                        Button("改一改", systemImage: "pencil") {
                            memoryText = item.text
                            editingMemory = item
                        }
                        if item.deep == true {
                            Button("常记在心", systemImage: "pin") { withAnimation(.smooth) { team.setDeep(item.id, false) } }
                        } else {
                            Button("收进旧事", systemImage: "archivebox") { withAnimation(.smooth) { team.setDeep(item.id, true) } }
                        }
                        Button("忘掉", systemImage: "trash", role: .destructive) { withAnimation(.smooth) { team.deleteMemory(item.id) } }
                    }
                }
            }
            .paperCard()
            Text(team.memories.isEmpty ? Words.t("聊天时说起你自己的事，旅伴会记下来。也可以在上面自己记。") : "点一条可以改，长按可以挪进旧事或忘掉。超过 \(TeamModel.surfaceLimit) 件常记时，最久没提起的会自动沉下去。")
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
                    Whale(size: 44, pose: .idle, still: true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(found.model).font(.system(size: 17, weight: .semibold)).foregroundStyle(Ink.ink).lineLimit(1)
                        Text(found.endpoint.name + " · " + found.endpoint.traits(found.model).summary)
                            .font(Ink.footnote).foregroundStyle(Ink.inkSoft).lineLimit(1)
                        if let balance {
                            Text("余额 " + balance.shown).font(Ink.footnote.monospacedDigit()).foregroundStyle(Ink.inkSoft)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.inkFaint)
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

    private var abilities: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            heading(Words.t("本事"))
            VStack(spacing: 0) {
                link("checkmark.seal", Words.t("应许"), Grant.Preset.current?.title ?? "自定义") { granting = true }
                Rectangle().fill(Ink.rule).frame(height: 1).padding(.leading, 52)
                link("books.vertical", "技能", "\(SkillShelf.enabled.count) 个") { skilling = true }
                Rectangle().fill(Ink.rule).frame(height: 1).padding(.leading, 52)
                link("alarm", "定时", team.routines.isEmpty ? "没有" : "\(team.routines.filter(\.on).count) 件") { timing = true }
            }
            .paperCard()
        }
    }

    private var more: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            heading("通用")
            VStack(spacing: 0) {
                link("textformat.size", Words.t("纸墨与絮语"), "外观与对话") { looking = true }
                Rectangle().fill(Ink.rule).frame(height: 1).padding(.leading, 52)
                link("stethoscope", Words.t("养护"), "备份与诊断") { caring = true }
            }
            .paperCard()
        }
    }

    private func link(_ icon: String, _ title: String, _ line: String, _ run: @escaping () -> Void) -> some View {
        Button {
            Haptics.light()
            run()
        } label: {
            HStack(spacing: Ink.Space.m) {
                Image(systemName: icon).font(.system(size: 17)).foregroundStyle(Ink.accent).frame(width: 28)
                Text(title).font(.system(size: 16, weight: .medium)).foregroundStyle(Ink.ink)
                Spacer()
                Text(line).font(.system(size: 14)).foregroundStyle(Ink.inkSoft).lineLimit(1)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.inkFaint)
            }
            .padding(Ink.Space.l)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(haptic: false))
    }

    private var about: some View {
        VStack(spacing: Ink.Space.xs) {
            Whale(size: 36, pose: .idle, still: true)
            Text("Clio \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                .font(Ink.serif(14, bold: true)).foregroundStyle(Ink.inkSoft)
            Text(Words.t("开源，GPL-3.0 · 斗室用 iSH，终端用 SwiftTerm，SSH 用 Citadel"))
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
