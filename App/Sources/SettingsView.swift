import AgentKit
import SwiftUI

/// 调弦: the model services and the default model, what the companions remember, and the way to everything else.
struct SettingsView: View {
    @ObservedObject var team: TeamModel
    var onLeaveDemo: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var adding = false
    @State private var removing: Endpoint?
    @State private var looking = false
    @State private var granting = false
    @State private var caring = false
    @State private var expanded: String?
    @State private var working: String?
    @State private var notes: [String: String] = [:]
    @State private var rekeying: Endpoint?
    @State private var newKey = ""
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
        .confirmationDialog("删掉 \(removing?.name ?? "")？用它的旅伴会改用默认模型。", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("删掉", role: .destructive) {
                if let removing { withAnimation(.smooth) { team.removeEndpoint(removing.id) } }
                removing = nil
            }
            Button("先留着", role: .cancel) { removing = nil }
        }
        .alert("给 \(rekeying?.name ?? "") 换密钥", isPresented: Binding(get: { rekeying != nil }, set: { if !$0 { rekeying = nil } })) {
            SecureField("新的密钥", text: $newKey)
            Button("换上") {
                if let rekeying, !newKey.trimmingCharacters(in: .whitespaces).isEmpty {
                    team.replaceKey(rekeying.id, newKey.trimmingCharacters(in: .whitespacesAndNewlines))
                    notes[rekeying.id] = "密钥换好了。"
                    Haptics.thud()
                }
                newKey = ""
                rekeying = nil
            }
            Button("算了", role: .cancel) { newKey = ""; rekeying = nil }
        } message: {
            Text("只存在这台手机的钥匙串里。")
        }
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
            heading("模型服务", "点开一家可以试连、刷新模型列表、换密钥")
            VStack(spacing: 0) {
                ForEach(team.settings.endpoints) { endpoint in
                    serviceRow(endpoint)
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
        let open = expanded == endpoint.id
        return VStack(alignment: .leading, spacing: Ink.Space.m) {
            Button {
                Haptics.light()
                withAnimation(Ink.Motion.unfold) { expanded = open ? nil : endpoint.id }
            } label: {
                HStack(spacing: Ink.Space.m) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(endpoint.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(Ink.ink)
                        Text("\(URL(string: endpoint.baseURL)?.host ?? endpoint.baseURL) · \(endpoint.models.count) 个模型" + (endpoint.vision == false ? " · 不能看图" : ""))
                            .font(Ink.footnote).foregroundStyle(Ink.inkSoft)
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Ink.inkFaint)
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let note = notes[endpoint.id] {
                Text(note).font(Ink.footnote).foregroundStyle(Ink.inkSoft)
            }

            if open {
                VStack(alignment: .leading, spacing: Ink.Space.m) {
                    HStack(spacing: Ink.Space.s) {
                        action("试连", "bolt.horizontal") { probe(endpoint) }
                        action("刷新模型", "arrow.clockwise") { refresh(endpoint) }
                        action("换密钥", "key") { rekeying = endpoint }
                        Spacer(minLength: 0)
                        Button {
                            removing = endpoint
                        } label: {
                            Image(systemName: "trash").font(.system(size: 14)).foregroundStyle(Ink.stop)
                                .frame(width: 32, height: 32)
                        }
                        .accessibilityLabel("删掉 \(endpoint.name)")
                    }
                    Text(endpoint.models.prefix(12).joined(separator: "、") + (endpoint.models.count > 12 ? " 等" : ""))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Ink.inkFaint)
                }
                .transition(.opacity)
            }
        }
        .padding(Ink.Space.l)
    }

    private func action(_ title: String, _ icon: String, _ run: @escaping () -> Void) -> some View {
        Button {
            Haptics.light()
            run()
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Ink.accent)
                .padding(.horizontal, Ink.Space.m)
                .frame(height: 30)
                .background(Ink.accentWash, in: .capsule)
        }
        .buttonStyle(PressStyle(haptic: false))
        .disabled(working != nil)
    }

    @ViewBuilder
    private var defaultModel: some View {
        if !team.models.isEmpty {
            VStack(alignment: .leading, spacing: Ink.Space.s) {
                heading("默认模型", "没单独选模型的旅伴都用它")
                Menu {
                    ForEach(team.models) { item in
                        Button {
                            Haptics.tick(0.6)
                            team.setDefaultModel(item.ref)
                        } label: {
                            if team.settings.defaultModel == item.ref {
                                Label("\(item.name ?? item.ref) · \(item.providerName ?? "")", systemImage: "checkmark")
                            } else {
                                Text("\(item.name ?? item.ref) · \(item.providerName ?? "")")
                            }
                        }
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
                Text("DeepSeek 看不了图；要发图片给旅伴，选 Claude 或别的能看图的模型。")
                    .font(Ink.footnote).foregroundStyle(Ink.inkFaint).padding(.leading, Ink.Space.xs)
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

    private func refresh(_ endpoint: Endpoint) {
        working = endpoint.id
        notes[endpoint.id] = "正在拿模型列表…"
        Task {
            do {
                let count = try await team.refreshModels(endpoint.id)
                notes[endpoint.id] = "拿到 \(count) 个模型。"
            } catch {
                notes[endpoint.id] = Explain.model(error, service: endpoint.name).title
            }
            working = nil
        }
    }

    private func probe(_ endpoint: Endpoint) {
        guard let model = endpoint.models.first, let key = team.apiKey(for: endpoint.id), !key.isEmpty else {
            notes[endpoint.id] = "还没有模型或密钥。"
            return
        }
        working = endpoint.id
        notes[endpoint.id] = "在试…"
        let started = Date()
        Task {
            do {
                var ask = Agent(provider: endpoint.provider(key: key), model: model, system: "只回答一个字。")
                ask.outputLimit = 16
                let answer = try await ask.ask("回一个字：好")
                notes[endpoint.id] = "通了：\(String(format: "%.1f", Date().timeIntervalSince(started))) 秒，回了「\(answer.prefix(6))」。"
                Haptics.thud()
            } catch {
                let advice = Explain.model(error, service: endpoint.name)
                notes[endpoint.id] = "不通：\(advice.title)。\(advice.detail)"
                Haptics.lock()
            }
            working = nil
        }
    }
}
