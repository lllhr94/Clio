import AgentKit
import Craft
import SwiftUI

/// 调弦: the model services and the default model, what the companions remember, and the way to everything else.
struct SettingsView: View {
    @ObservedObject var team: TeamModel
    var onLeaveDemo: () -> Void
    @Environment(\.dismiss) private var dismiss
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

    var body: some View {
        NavigationStack {
            ZStack {
                Ink.paper.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: Ink.Space.xl) {
                        Text("旅伴靠哪个模型想事情、记得你什么，都在这里调。外观和对话习惯在「纸墨与絮语」。")
                            .font(Ink.secondary)
                            .foregroundStyle(Ink.inkSoft)

                        if team.phase == .demo {
                            demoCard
                        } else {
                            services
                            defaultModel
                            memory
                        }
                        more
                        about
                    }
                    .padding(.horizontal, Ink.Space.page)
                    .padding(.vertical, Ink.Space.l)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
            }
            .hitchPage("调弦")
            .navigationTitle("调弦")
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
        .sheet(isPresented: $adding) { SetupView(team: team) { adding = false } }
        .sheet(isPresented: $looking) { LookPage() }
        .sheet(isPresented: $granting) { GrantsPage(team: team) }
        .sheet(isPresented: $caring) { CarePage(team: team) }
        .sheet(isPresented: $timing) { RoutinesPage(team: team) }
        .sheet(isPresented: $skilling) { SkillsPage() }
        .alert("改这条拾遗", isPresented: Binding(get: { editingMemory != nil }, set: { if !$0 { editingMemory = nil } })) {
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

    // MARK: Sections

    private func heading(_ title: String, _ note: String? = nil) -> some View {
        FieldTitle(text: title, note: note)
    }

    private var demoCard: some View {
        VStack(alignment: .leading, spacing: Ink.Space.m) {
            Text("现在是演示数据。接上自己的模型后，旅伴才会真的回答。").font(Ink.secondary).foregroundStyle(Ink.ink)
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
            heading("模型服务", "点开一家：管模型、看每个模型能不能看图和思考、试连、换密钥")
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
                heading("默认模型", "没单独选模型的旅伴都用它")
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
                if let found = team.resolve(team.settings.defaultModel) {
                    Text("\(found.model)：\(found.endpoint.traits(found.model).summary)。发图片时，不能看图的模型会改用 photo_text 读图上的字。")
                        .font(Ink.footnote).foregroundStyle(Ink.inkFaint).padding(.leading, Ink.Space.xs)
                }
            }
        }
    }

    private var memory: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            heading("拾遗", "常记 \(team.surfaceMemories.count) 件，每次聊天都带着；旧事 \(team.deepMemories.count) 件，需要时翻找")
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
            Text(team.memories.isEmpty ? "聊天时说起你自己的事，旅伴会记下来。也可以在上面自己记。" : "点一条可以改，长按可以挪进旧事或忘掉。超过 \(TeamModel.surfaceLimit) 件常记时，最久没提起的会自动沉下去。")
                .font(Ink.footnote).foregroundStyle(Ink.inkFaint).padding(.leading, Ink.Space.xs)
        }
    }

    private var more: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            heading("别处")
            VStack(spacing: 0) {
                link("textformat.size", "纸墨与絮语", "字体字号、明暗、触感；压缩、上下文、温度") { looking = true }
                Rectangle().fill(Ink.rule).frame(height: 1).padding(.leading, 52)
                link("checkmark.seal", "应许", "旅伴能做什么，一项项由你定") { granting = true }
                Rectangle().fill(Ink.rule).frame(height: 1).padding(.leading, 52)
                link("books.vertical", "技能", "一页页「怎么做」，旅伴遇到对得上的事就照着做") { skilling = true }
                Rectangle().fill(Ink.rule).frame(height: 1).padding(.leading, 52)
                link("alarm", "定时", team.routines.isEmpty ? "让旅伴每天、每周到点做一件事" : "\(team.routines.filter(\.on).count) 件在走") { timing = true }
                Rectangle().fill(Ink.rule).frame(height: 1).padding(.leading, 52)
                link("stethoscope", "养护", "备份、恢复、诊断") { caring = true }
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
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 16, weight: .medium)).foregroundStyle(Ink.ink)
                    Text(line).font(Ink.footnote).foregroundStyle(Ink.inkSoft)
                }
                Spacer()
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
            Text("开源，GPL-3.0 · 斗室用 iSH，终端用 SwiftTerm，SSH 用 Citadel")
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
