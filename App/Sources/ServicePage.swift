import AgentKit
import Craft
import SwiftUI
import UIKit

/// One model service, all of it: which models are in use and what each can do, the address and key, the balance.
struct ServicePage: View {
    @ObservedObject var team: TeamModel
    let id: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var note: String?
    @State private var working = false
    @State private var search = ""
    @State private var typed = ""
    @State private var editing: String?
    @State private var removing = false
    @State private var name = ""
    @State private var address = ""
    @State private var style: ThinkingStyle?
    @State private var newKey = ""
    @State private var reading: Balance.Reading?
    @State private var balanceNote: String?

    private var endpoint: Endpoint? { team.settings.endpoints.first { $0.id == id } }
    private var service: Service? { endpoint.flatMap(Service.of) }

    var body: some View {
        ScrollView {
            if let endpoint {
                VStack(alignment: .leading, spacing: Ink.Space.xl) {
                    header(endpoint)
                    inUse(endpoint)
                    if !(endpoint.listed ?? []).filter({ !endpoint.models.contains($0) }).isEmpty { more(endpoint) }
                    connection(endpoint)
                    if Balance.source(baseURL: endpoint.baseURL) != nil { balance(endpoint) }
                    Button("删掉这家服务", role: .destructive) { removing = true }
                        .font(.system(size: Ink.Size.sub, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Ink.Space.m)
                }
                .padding(.horizontal, Ink.Space.page)
                .padding(.vertical, Ink.Space.l)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Ink.paper.ignoresSafeArea())
        .navigationTitle(endpoint?.name ?? L.t("settings.modelService"))
        .navigationBarTitleDisplayMode(.inline)
        .hitchPage("服务")
        .onAppear {
            guard let endpoint else { return }
            name = endpoint.name
            address = endpoint.baseURL
            style = endpoint.style
        }
        .task { await loadBalance() }
        .sheet(item: Binding(get: { editing.map { Picked(model: $0) } }, set: { editing = $0?.model })) { picked in
            ModelSheet(team: team, endpointId: id, model: picked.model)
                .presentationDetents([.large])
        }
        .confirmationDialog(Words.t("删掉 \(endpoint?.name ?? "")？用它的旅伴会改用默认模型，密钥也一起删掉。"), isPresented: $removing, titleVisibility: .visible) {
            Button("删掉", role: .destructive) {
                team.removeEndpoint(id)
                dismiss()
            }
            Button("先留着", role: .cancel) {}
        }
    }

    private struct Picked: Identifiable {
        var model: String
        var id: String { model }
    }

    // MARK: Header

    private func header(_ endpoint: Endpoint) -> some View {
        VStack(alignment: .leading, spacing: Ink.Space.m) {
            Text(service?.note ?? (URL(string: endpoint.baseURL)?.host ?? endpoint.baseURL))
                .font(Ink.secondary).foregroundStyle(Ink.inkSoft)
            HStack(spacing: Ink.Space.s) {
                pill("试连", "bolt.horizontal") { probe(endpoint) }
                pill("刷新模型列表", "arrow.clockwise") { refresh(endpoint) }
                if let page = service?.keyPage, let url = URL(string: page) {
                    pill("管理密钥", "arrow.up.right") { openURL(url) }
                }
            }
            if let note {
                Text(note).font(Ink.footnote).foregroundStyle(Ink.inkSoft).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func pill(_ title: String, _ icon: String, _ run: @escaping () -> Void) -> some View {
        Button {
            Haptics.light()
            run()
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: Ink.Size.small, weight: .medium))
                .foregroundStyle(Ink.accent)
                .padding(.horizontal, Ink.Space.m)
                .frame(height: 30)
                .background(Ink.accentWash, in: .capsule)
        }
        .buttonStyle(PressStyle(haptic: false))
        .disabled(working)
    }

    // MARK: Models in use

    private func inUse(_ endpoint: Endpoint) -> some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            FieldTitle(text: L.t("settings.activeModels"), note: "选模型时只列这些。点一个看它能做什么，猜错了可以改")
            VStack(spacing: 0) {
                ForEach(endpoint.models, id: \.self) { model in
                    modelRow(endpoint, model)
                    Kit.rule(inset: Ink.Space.l)
                }
                HStack(spacing: Ink.Space.s) {
                    TextField(service?.modelHint ?? "手动添一个模型名", text: $typed)
                        .font(.system(size: Ink.Size.sub, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit { addTyped(endpoint) }
                    Button("添上") { addTyped(endpoint) }
                        .font(.system(size: Ink.Size.sub, weight: .semibold))
                        .foregroundStyle(Ink.accent)
                        .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(Ink.Space.l)
            }
            .paperCard()
        }
    }

    private func modelRow(_ endpoint: Endpoint, _ model: String) -> some View {
        let traits = endpoint.traits(model)
        let isDefault = team.settings.defaultModel == "\(endpoint.id)/\(model)"
        let gone = endpoint.listed.map { !$0.contains(model) } ?? false
        return Button {
            Haptics.light()
            editing = model
        } label: {
            HStack(alignment: .center, spacing: Ink.Space.m) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(model).font(.system(size: Ink.Size.sub, weight: .medium, design: .monospaced)).foregroundStyle(Ink.ink).lineLimit(1)
                        if isDefault {
                            Text("默认").font(.system(size: Ink.Size.micro, weight: .semibold)).foregroundStyle(Ink.accent)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Ink.accentWash, in: .capsule)
                        }
                    }
                    TraitChips(traits: traits, corrected: endpoint.corrected(model))
                    if gone {
                        Text("列表里没有了，可能已下线").font(Ink.footnote).foregroundStyle(Ink.warn)
                    }
                }
                Spacer(minLength: 0)
                Kit.chevron
            }
            .padding(.horizontal, Ink.Space.l)
            .padding(.vertical, Ink.Space.m)
            .contentShape(Rectangle())
        }
        .buttonStyle(TapStyle())
        .contextMenu {
            Button("设为默认模型", systemImage: "star") { team.setDefaultModel("\(endpoint.id)/\(model)") }
            Button("不用了", systemImage: "minus.circle", role: .destructive) {
                withAnimation(.smooth) { team.setModels(endpoint.id, endpoint.models.filter { $0 != model }) }
            }
        }
    }

    private func addTyped(_ endpoint: Endpoint) {
        let model = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return }
        typed = ""
        guard !endpoint.models.contains(model) else { return }
        Haptics.tick(0.6)
        withAnimation(.smooth) { team.setModels(endpoint.id, endpoint.models + [model]) }
        note = "添上了 \(model)。它能做什么是按名字猜的，点开可以试试、改一改。"
    }

    // MARK: The rest of the list

    private func more(_ endpoint: Endpoint) -> some View {
        let rest = (endpoint.listed ?? []).filter { !endpoint.models.contains($0) }
        let words = search.trimmingCharacters(in: .whitespaces).lowercased()
        let found = words.isEmpty ? rest : rest.filter { $0.lowercased().contains(words) }
        let shown = Array(found.prefix(40))
        return VStack(alignment: .leading, spacing: Ink.Space.s) {
            FieldTitle(text: "列表里还有 \(rest.count) 个", note: "点 ＋ 拿来用")
            VStack(spacing: 0) {
                if rest.count > 8 {
                    HStack(spacing: Ink.Space.s) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Ink.inkFaint)
                        TextField("搜模型名，比如 qwen、vl、flash", text: $search)
                            .font(.system(size: Ink.Size.sub))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    .padding(Ink.Space.l)
                    Rectangle().fill(Ink.rule).frame(height: 1)
                }
                ForEach(shown, id: \.self) { model in
                    HStack(spacing: Ink.Space.m) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model).font(.system(size: Ink.Size.sub, design: .monospaced)).foregroundStyle(Ink.ink).lineLimit(1)
                            Text(endpoint.traits(model).summary).font(.system(size: Ink.Size.small)).foregroundStyle(Ink.inkFaint)
                        }
                        Spacer(minLength: 0)
                        Button {
                            Haptics.tick(0.6)
                            withAnimation(.smooth) { team.setModels(endpoint.id, endpoint.models + [model]) }
                        } label: {
                            Image(systemName: "plus.circle.fill").font(.system(size: 22)).foregroundStyle(Ink.accent)
                        }
                        .buttonStyle(TapStyle(grow: 8))
                        .accessibilityLabel("用 \(model)")
                    }
                    .padding(.horizontal, Ink.Space.l)
                    .padding(.vertical, Ink.Space.s + 2)
                }
                if found.count > shown.count {
                    Text("还有 \(found.count - shown.count) 个，搜一搜就能找到。")
                        .font(Ink.footnote).foregroundStyle(Ink.inkFaint)
                        .padding(Ink.Space.l)
                } else if found.isEmpty {
                    Text("没有名字里带「\(search)」的。").font(Ink.footnote).foregroundStyle(Ink.inkFaint).padding(Ink.Space.l)
                }
            }
            .paperCard()
        }
    }

    // MARK: Connection

    private func connection(_ endpoint: Endpoint) -> some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            FieldTitle(text: L.t("settings.apiType"), note: endpoint.kind == .anthropic ? "Claude 那种接口" : "OpenAI 那种接口（大多数服务都是）")
            VStack(alignment: .leading, spacing: Ink.Space.m) {
                labeled("称呼") {
                    TextField("称呼", text: $name).font(.system(size: Ink.Size.sub)).onSubmit { save(endpoint) }
                }
                labeled("地址") {
                    TextField("https://…", text: $address)
                        .font(.system(size: Ink.Size.sub, design: .monospaced))
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onSubmit { save(endpoint) }
                }
                if let service, service.addresses.count > 1 {
                    HStack(spacing: Ink.Space.s) {
                        ForEach(service.addresses, id: \.url) { option in
                            Button(option.label) {
                                Haptics.tick(0.5)
                                address = option.url
                                save(endpoint)
                            }
                            .font(.system(size: Ink.Size.small, weight: .medium))
                            .foregroundStyle(address == option.url ? Ink.accent : Ink.inkSoft)
                            .padding(.horizontal, Ink.Space.m)
                            .frame(height: 28)
                            .background(address == option.url ? Ink.accentWash : Ink.mine, in: .capsule)
                        }
                    }
                }
                Text("实际请求：" + finalURL(endpoint))
                    .font(.system(size: Ink.Size.small, design: .monospaced)).foregroundStyle(Ink.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
                if endpoint.kind == .openai {
                    Rectangle().fill(Ink.rule).frame(height: 1)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("思考参数怎么写").font(.system(size: Ink.Size.sub)).foregroundStyle(Ink.ink)
                            Text("选思考强度没效果时再换").font(Ink.footnote).foregroundStyle(Ink.inkFaint)
                        }
                        Spacer()
                        Menu {
                            Button {
                                style = nil
                                save(endpoint)
                            } label: {
                                if style == nil { Label("跟着服务（\(endpoint.thinkingStyleGuess.title)）", systemImage: "checkmark") } else { Text("跟着服务（\(endpoint.thinkingStyleGuess.title)）") }
                            }
                            ForEach(ThinkingStyle.allCases, id: \.self) { option in
                                Button {
                                    style = option
                                    save(endpoint)
                                } label: {
                                    if style == option { Label(option.title, systemImage: "checkmark") } else { Text(option.title) }
                                }
                            }
                        } label: {
                            Text(style?.title ?? "跟着服务").font(.system(size: Ink.Size.sub, weight: .medium)).foregroundStyle(Ink.accent).lineLimit(1)
                        }
                    }
                }
                Rectangle().fill(Ink.rule).frame(height: 1)
                labeled("密钥") {
                    HStack(spacing: Ink.Space.s) {
                        SecureField(maskedKey(endpoint), text: $newKey)
                            .font(.system(size: Ink.Size.sub, design: .monospaced))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        if !newKey.isEmpty {
                            Button("换上") { replaceKey(endpoint) }
                                .font(.system(size: Ink.Size.sub, weight: .semibold))
                                .foregroundStyle(Ink.accent)
                        }
                    }
                }
                Text("只存在本机钥匙串，不进备份")
                    .font(Ink.footnote).foregroundStyle(Ink.inkFaint)
            }
            .padding(Ink.Space.l)
            .paperCard()
        }
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: Ink.Space.m) {
            Text(title).font(.system(size: Ink.Size.sub)).foregroundStyle(Ink.inkSoft).frame(width: 40, alignment: .leading)
            content()
        }
    }

    private func finalURL(_ endpoint: Endpoint) -> String {
        var base = address.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        return base + (endpoint.kind == .anthropic ? "/v1/messages" : "/chat/completions")
    }

    private func maskedKey(_ endpoint: Endpoint) -> String {
        guard let key = team.apiKey(for: endpoint.id), key.count > 8 else { return "粘贴新的密钥来换掉" }
        return "已存 ••••" + key.suffix(4) + "，粘贴新的来换"
    }

    private func save(_ endpoint: Endpoint) {
        team.editEndpoint(endpoint.id, name: name, baseURL: address, style: style)
    }

    private func replaceKey(_ endpoint: Endpoint) {
        let key = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        team.replaceKey(endpoint.id, key)
        newKey = ""
        Haptics.thud()
        note = "密钥换好了。点「试连」看看通不通。"
    }

    // MARK: Balance

    private func balance(_ endpoint: Endpoint) -> some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            FieldTitle(text: L.t("settings.balance"))
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    if let reading {
                        Text(reading.shown).font(Ink.serif(24, bold: true)).foregroundStyle(Ink.ink)
                        if let detail = reading.detail { Text(detail).font(Ink.footnote).foregroundStyle(Ink.inkSoft) }
                    } else {
                        Text(balanceNote ?? "在查…").font(Ink.footnote).foregroundStyle(Ink.inkSoft)
                    }
                }
                Spacer()
                if let source = Balance.source(baseURL: endpoint.baseURL) {
                    Link("去充值", destination: source.topUp).font(.system(size: Ink.Size.sub, weight: .medium)).foregroundStyle(Ink.accent)
                }
            }
            .padding(Ink.Space.l)
            .paperCard()
        }
    }

    private func loadBalance() async {
        guard let endpoint, Balance.source(baseURL: endpoint.baseURL) != nil else { return }
        do {
            reading = try await team.balance(endpoint)
        } catch {
            balanceNote = error.localizedDescription
        }
    }

    // MARK: Doing

    private func refresh(_ endpoint: Endpoint) {
        working = true
        note = L.t("loading.fetchingModels")
        Task {
            do {
                let count = try await team.refreshModels(endpoint.id)
                let fresh = team.settings.endpoints.first { $0.id == endpoint.id }
                let waiting = (fresh?.listed ?? []).filter { !(fresh?.models ?? []).contains($0) }.count
                note = "列表里有 \(count) 个能聊天的模型" + (waiting > 0 ? "，在用的之外还有 \(waiting) 个，在下面挑。" : "。")
            } catch {
                note = Explain.model(error, service: endpoint.name).title
            }
            working = false
        }
    }

    private func probe(_ endpoint: Endpoint) {
        guard let model = (team.resolve(team.settings.defaultModel).flatMap { $0.endpoint.id == endpoint.id ? $0.model : nil }) ?? endpoint.models.first else {
            note = "还没有在用的模型：先刷新列表，或手动添一个。"
            return
        }
        working = true
        note = "在用 \(model) 试…"
        Task {
            let result = await team.probe(endpoint, model: model)
            note = result.note
            if result.ok { Haptics.thud() } else { Haptics.lock() }
            working = false
        }
    }
}

extension Endpoint {
    /// The style it would have without a choice of its own.
    var thinkingStyleGuess: ThinkingStyle {
        var plain = self
        plain.style = nil
        return plain.thinkingStyle
    }
}

/// 看图 · 思考 · 1M as small tags.
struct TraitChips: View {
    let traits: ModelTraits
    var corrected = false

    var body: some View {
        HStack(spacing: 4) {
            tag(traits.sees ? "看图" : "不看图", traits.sees ? "eye" : "eye.slash", on: traits.sees)
            if traits.thinks { tag("思考", "brain", on: true) }
            if !traits.tools { tag("不用工具", "wrench.and.screwdriver", on: false) }
            tag(Tokens.short(traits.window).replacingOccurrences(of: ".05M", with: "M").replacingOccurrences(of: ".00M", with: "M"), "text.alignleft", on: true)
            if corrected { Text("改过").font(.system(size: Ink.Size.micro, weight: .medium)).foregroundStyle(Ink.inkFaint) }
        }
    }

    private func tag(_ text: String, _ icon: String, on: Bool) -> some View {
        Label(text, systemImage: icon)
            .labelStyle(.titleAndIcon)
            .font(.system(size: Ink.Size.micro, weight: .medium))
            .foregroundStyle(on ? Ink.inkSoft : Ink.inkFaint)
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(on ? Ink.mine : Color.clear, in: .capsule)
            .overlay(Capsule().strokeBorder(on ? Color.clear : Ink.rule, lineWidth: 1))
    }
}

/// One model: what it can do (guessed or set by hand), a quick test of it, and making it the default.
struct ModelSheet: View {
    @ObservedObject var team: TeamModel
    let endpointId: String
    let model: String
    @Environment(\.dismiss) private var dismiss
    @State private var traits = ModelTraits(sees: false)
    @State private var note: String?
    @State private var working = false

    private static let windows = [32_768, 65_536, 131_072, 200_000, 262_144, 400_000, 1_048_576, 2_097_152]

    private var endpoint: Endpoint? { team.settings.endpoints.first { $0.id == endpointId } }
    private var ref: String { "\(endpointId)/\(model)" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("看图", isOn: $traits.sees)
                    Toggle("用工具", isOn: $traits.tools)
                    Toggle("会思考", isOn: $traits.thinks)
                    Picker("上下文", selection: $traits.window) {
                        ForEach(windowChoices, id: \.self) { value in
                            Text(Tokens.short(value)).tag(value)
                        }
                    }
                } header: {
                    Text("它能做什么")
                } footer: {
                    Text(footer)
                }
                Section {
                    Button(working ? "在试…" : "试试它能不能看图", systemImage: "eye") { testSight() }
                        .disabled(working)
                    Button(working ? "在试…" : "试连这个模型", systemImage: "bolt.horizontal") { testReply() }
                        .disabled(working)
                    if let note {
                        Text(note).font(.footnote).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("发一张红色小图问颜色，花一点点钱")
                }
                Section {
                    if team.settings.defaultModel == ref {
                        Label("这是默认模型", systemImage: "star.fill").foregroundStyle(.secondary)
                    } else {
                        Button("设为默认模型", systemImage: "star") {
                            team.setDefaultModel(ref)
                            Haptics.thud()
                        }
                    }
                    if endpoint?.corrected(model) == true {
                        Button("改回按名字猜的", systemImage: "arrow.uturn.backward") {
                            team.setTraits(endpointId, model: model, nil)
                            traits = ModelTraits.guess(model)
                        }
                    }
                    Button("不用这个模型", systemImage: "minus.circle", role: .destructive) {
                        if let endpoint { team.setModels(endpointId, endpoint.models.filter { $0 != model }) }
                        dismiss()
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Ink.paper.ignoresSafeArea())
            .navigationTitle(model)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("好了") { dismiss() } } }
        }
        .onAppear { traits = endpoint?.traits(model) ?? ModelTraits.guess(model) }
        .onChange(of: traits) { _, value in
            guard value != endpoint?.traits(model) else { return }
            team.setTraits(endpointId, model: model, value == ModelTraits.guess(model) ? nil : value)
        }
    }

    private var windowChoices: [Int] {
        Self.windows.contains(traits.window) ? Self.windows : (Self.windows + [traits.window]).sorted()
    }

    private var footer: String {
        let source = endpoint?.corrected(model) == true ? "你改过。" : "按名字猜的，服务不会告诉我们。"
        return source + "不能看图时，发来的照片会换成编号，旅伴可以用 photo_text 读图上的字；不会用工具时，旅伴只聊天，不上网也不动手。"
    }

    private func testSight() {
        guard let endpoint else { return }
        working = true
        note = nil
        Task {
            let result = await team.probeSight(endpoint, model: model)
            note = result.note
            if let sees = result.sees, sees != traits.sees { traits.sees = sees }
            working = false
        }
    }

    private func testReply() {
        guard let endpoint else { return }
        working = true
        note = nil
        Task {
            note = await team.probe(endpoint, model: model).note
            working = false
        }
    }
}

extension TeamModel {
    /// Asks one model once and returns its answer. Thinking is turned off when the model allows it, to be quick.
    func quickAsk(_ endpoint: Endpoint, model: String, _ message: Message) async throws -> String {
        guard let key = apiKey(for: endpoint.id), !key.isEmpty else { throw TeamError(message: "\(endpoint.name) 还没有密钥。") }
        let provider = endpoint.provider(key: key)
        func once(_ thinking: Thinking) async throws -> String {
            let request = ModelRequest(model: model, system: "", messages: [message], outputLimit: 400, thinking: thinking)
            var text = ""
            for try await event in provider.stream(request) {
                if case .text(let piece) = event { text += piece }
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        do {
            return try await once(.off)
        } catch let failure as ProviderError where failure.status == 400 || failure.status == 422 {
            return try await once(.auto)
        }
    }

    /// Does the key, address and model work: a one-word question.
    func probe(_ endpoint: Endpoint, model: String) async -> (ok: Bool, note: String) {
        let started = Date()
        do {
            let answer = try await quickAsk(endpoint, model: model, .user("回一个字：好"))
            return (true, "通了：\(model)，\(String(format: "%.1f", Date().timeIntervalSince(started))) 秒，回了「\(answer.prefix(8))」。")
        } catch {
            let advice = Explain.model(error, service: endpoint.name)
            return (false, "不通：\(advice.title)。\(advice.detail)")
        }
    }

    /// Shows the model a red square and asks its colour. `sees` is nil when the test itself failed.
    func probeSight(_ endpoint: Endpoint, model: String) async -> (sees: Bool?, note: String) {
        let size = CGSize(width: 64, height: 64)
        let data = UIGraphicsImageRenderer(size: size).jpegData(withCompressionQuality: 0.9) { context in
            UIColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        do {
            let answer = try await quickAsk(endpoint, model: model, .user("这张图是什么颜色？只回答颜色。", images: [ImagePart(data: data)]))
            let said = answer.lowercased()
            if said.contains("红") || said.contains("red") {
                return (true, "能看图：给它一张红色的图，它答「\(answer.prefix(12))」。已标成能看图。")
            }
            return (false, "好像看不到：它答「\(answer.prefix(30))」。已标成不能看图，发来的照片会换成编号。")
        } catch let failure as ProviderError where failure.status == 400 || failure.status == 422 {
            return (false, "服务不收图片：\(failure.message.prefix(80))。已标成不能看图。")
        } catch {
            return (nil, "没试成：\(Explain.model(error, service: endpoint.name).title)")
        }
    }
}

/// The models in use, by service, for a menu: each with what it can do under its name.
struct ModelChoices: View {
    @ObservedObject var team: TeamModel
    let current: String?
    let pick: (String) -> Void

    var body: some View {
        ForEach(team.settings.endpoints) { endpoint in
            Section(endpoint.name) {
                ForEach(endpoint.models, id: \.self) { model in
                    Button {
                        pick("\(endpoint.id)/\(model)")
                    } label: {
                        if current == "\(endpoint.id)/\(model)" {
                            Label(model, systemImage: "checkmark")
                        } else {
                            Text(model)
                        }
                        Text(endpoint.traits(model).summary)
                    }
                }
            }
        }
    }
}
