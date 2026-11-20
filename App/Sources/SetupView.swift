import AgentKit
import Craft
import SwiftUI

/// Connects a model service. On first launch it begins with a short welcome; from 调弦 it goes straight to the service.
struct SetupView: View {
    @ObservedObject var team: TeamModel
    /// Shown on first launch: a welcome first, and no way out until a service is connected.
    var first = false
    var onDone: () -> Void

    private enum Step { case welcome, service, done }

    @Environment(\.openURL) private var openURL
    @State private var step: Step = .service
    @State private var choice = Service.catalog[0]
    @State private var region = 0
    @State private var key = ""
    @State private var baseURL = ""
    @State private var name = ""
    @State private var modelName = ""
    @State private var busy = false
    @State private var advice: Explain.Advice?
    @State private var connected: Endpoint?
    /// The service's model list, fetched as soon as there is a key: models are picked before anything is saved.
    @State private var fetched: [String]?
    @State private var picked: Set<String> = []
    @State private var fetching = false
    @State private var fetchNote: String?
    @State private var modelSearch = ""
    @FocusState private var keyFocused: Bool

    private var custom: Bool { choice.custom }
    /// The key as typed; a local model that needs none gets a stand-in, since the OpenAI way always sends one.
    private var secret: String {
        let typed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty && choice.keyless ? "local" : typed
    }

    var body: some View {
        ZStack {
            Ink.paper.ignoresSafeArea()
            switch step {
            case .welcome: welcome.transition(.blurReplace)
            case .service: service.transition(.blurReplace)
            case .done: done.transition(.blurReplace)
            }
        }
        .animation(Ink.Motion.unfold, value: step)
        .onAppear { step = first ? .welcome : .service }
    }

    // MARK: Welcome

    private var welcome: some View {
        VStack(alignment: .leading, spacing: Ink.Space.xl) {
            Spacer(minLength: 0)
            Whale(size: 120, pose: .idle)
            VStack(alignment: .leading, spacing: Ink.Space.s) {
                Text("你好，这里是 Clio").font(Ink.display).foregroundStyle(Ink.ink)
                Text(Words.t("几位住在你手机里的旅伴。")).font(Ink.reading).foregroundStyle(Ink.inkSoft)
            }
            VStack(alignment: .leading, spacing: Ink.Space.l) {
                point("lock", "对话只在这台手机上", Words.t("不经过任何人的服务器，旅伴直接用你自己的密钥连模型。"))
                point("globe", "会上网，也会动手", "搜索、开网页、在手机里的小 Linux 跑脚本，替你记日程。")
                point("checkmark.seal", "大事都先问你", Words.t("加日程、填网页、连服务器这类事，旅伴会递一张笺等你落印。"))
            }
            Spacer(minLength: 0)
            // 称谓, asked once and taking effect at once: this page and the next already speak in it.
            VStack(alignment: .leading, spacing: Ink.Space.s) {
                Text(L.t("onboarding.page3.title")).font(.system(size: Ink.Size.sub, weight: .medium)).foregroundStyle(Ink.inkSoft)
                ToneCards()
            }
            Button {
                Haptics.light()
                step = .service
            } label: {
                Text(L.t("onboarding.page4.primaryCta"))
                    .font(.system(size: Ink.Size.body, weight: .semibold))
                    .foregroundStyle(Ink.paper)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Ink.accent, in: .capsule)
            }
            .buttonStyle(PressStyle(haptic: false))
        }
        .padding(.horizontal, Ink.Space.page + 4)
        .padding(.vertical, Ink.Space.xl)
    }

    private func point(_ icon: String, _ title: String, _ words: String) -> some View {
        HStack(alignment: .top, spacing: Ink.Space.m) {
            Image(systemName: icon)
                .font(.system(size: Ink.Size.sub, weight: .medium))
                .foregroundStyle(Ink.accent)
                .frame(width: 32, height: 32)
                .background(Ink.accentWash, in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: Ink.Size.body, weight: .semibold)).foregroundStyle(Ink.ink)
                Text(words).font(Ink.secondary).foregroundStyle(Ink.inkSoft).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Service

    private var service: some View {
        serviceBody
            .task(id: fetchKey) { await fetchModels() }
    }

    private var serviceBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Ink.Space.xl) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: Ink.Space.xs) {
                        Text(first ? "第一步 · 接一个模型" : "添一个模型服务").font(Ink.title).foregroundStyle(Ink.ink)
                        Text(Words.t("之后随时能在调弦里再加")).font(Ink.secondary).foregroundStyle(Ink.inkSoft)
                    }
                    Spacer()
                    if !first {
                        Button {
                            Haptics.light()
                            onDone()
                        } label: {
                            Text(L.t("actions.cancel")).font(Ink.label).foregroundStyle(Ink.accent)
                        }
                    }
                }

                servicePicker
                keyField
                modelPicker
                adviceCard
                connectButton
            }
            .padding(.horizontal, Ink.Space.page)
            .padding(.vertical, Ink.Space.xl)
            .animation(Ink.Motion.settle, value: choice.id)
            .animation(Ink.Motion.settle, value: advice?.title)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private var servicePicker: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            FieldTitle(text: "选一家", note: "都能用自己的密钥直连。不在里面的，选最后的「自定义」")
            // One list, top to bottom, like every other list in Clio.
            VStack(spacing: 0) {
                ForEach(Array(Service.catalog.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Kit.divider }
                    tile(item)
                }
            }
            .paperCard()
        }

        if choice.addresses.count > 1 {
            VStack(alignment: .leading, spacing: Ink.Space.s) {
                FieldTitle(text: "用哪个地址", note: "账号在哪边注册的就选哪边，密钥不通用")
                Picker("地址", selection: $region) {
                    ForEach(choice.addresses.indices, id: \.self) { index in
                        Text(choice.addresses[index].label).tag(index)
                    }
                }
                .pickerStyle(.segmented)
            }
            .transition(.opacity)
        }

        if custom {
            VStack(alignment: .leading, spacing: Ink.Space.s) {
                FieldTitle(text: "服务的地址", note: choice.keyless ? "电脑的局域网地址加端口：Ollama 是 http://电脑IP:11434/v1，LM Studio 是 http://电脑IP:1234/v1。Ollama 要先设 OLLAMA_HOST=0.0.0.0 才让手机连" : (choice.kind == .anthropic ? "填到 /v1 前面为止，比如 https://api.example.com" : "一般以 /v1 结尾，比如 https://api.example.com/v1"))
                TextField(choice.keyless ? "称呼，比如 我的 4090" : "称呼，比如 我的中转站", text: $name).paperField()
                TextField(choice.keyless ? "http://192.168.1.10:11434/v1" : "https://…", text: $baseURL)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .paperField()
                if baseURL.hasPrefix("http") {
                    Text("实际请求：" + finalURL)
                        .font(.system(size: Ink.Size.small, design: .monospaced)).foregroundStyle(Ink.inkFaint)
                        .padding(.leading, Ink.Space.xs)
                }
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }

        if custom || choice.asksModel {
            VStack(alignment: .leading, spacing: Ink.Space.s) {
                FieldTitle(text: "模型名", note: choice.asksModel ? "这家要你自己填" : "可以不填，会自动去拿列表")
                TextField(choice.modelHint ?? "比如 gpt-5、qwen-plus", text: $modelName)
                    .font(.system(size: Ink.Size.sub, design: .monospaced))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .paperField()
            }
            .transition(.opacity)
        }

    }

    private var keyField: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            HStack {
                FieldTitle(text: "密钥（API Key）", note: choice.keyless ? "本地的一般不用，空着就行" : "只存在这台手机的钥匙串里")
                Spacer()
                if let help = helpURL {
                    Button("去哪拿？") { openURL(help) }
                        .font(.system(size: Ink.Size.small, weight: .semibold))
                        .foregroundStyle(Ink.accent)
                }
            }
            HStack(spacing: Ink.Space.s) {
                SecureField("sk-…", text: $key)
                    .font(.system(size: Ink.Size.body, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($keyFocused)
                Button {
                    if let pasted = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !pasted.isEmpty {
                        key = pasted
                        Haptics.tick(0.5)
                    }
                } label: {
                    Text("粘贴").font(.system(size: Ink.Size.small, weight: .semibold)).foregroundStyle(Ink.accent)
                }
            }
            .paperField()
        }
    }

    @ViewBuilder
    private var adviceCard: some View {
        if let advice {
            VStack(alignment: .leading, spacing: Ink.Space.xs) {
                Label(advice.title, systemImage: "exclamationmark.triangle")
                    .font(.system(size: Ink.Size.sub, weight: .semibold))
                    .foregroundStyle(Ink.stop)
                Text(advice.detail).font(Ink.secondary).foregroundStyle(Ink.inkSoft)
            }
            .padding(Ink.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Ink.stop.opacity(0.08), in: .rect(cornerRadius: Ink.Radius.card, style: .continuous))
            .transition(.opacity)
        }
    }

    // MARK: Models, before saving

    /// Fetches the list once key and address are there, a moment after typing stops.
    private var fetchKey: String { "\(choice.id)|\(address)|\(key.trimmingCharacters(in: .whitespacesAndNewlines))" }

    private func fetchModels() async {
        let secret = self.secret
        guard secret.count >= 8 || choice.keyless, address.hasPrefix("http") else { fetched = nil; fetchNote = nil; return }
        try? await Task.sleep(nanoseconds: 700_000_000)
        guard !Task.isCancelled else { return }
        fetching = true
        fetchNote = nil
        let probe = Endpoint(id: "probe", name: choice.name, kind: choice.kind, baseURL: address, models: [], service: custom ? nil : choice.id)
        do {
            let listed = TeamModel.keep(try await probe.provider(key: secret).models(), for: probe)
            guard !Task.isCancelled else { return }
            if listed.isEmpty {
                fetched = nil
                fetchNote = "连上了，但它没给模型列表，下面填个模型名就行"
            } else {
                fetched = listed
                picked = Set(TeamModel.firstPicks(listed, service: custom ? nil : choice))
            }
        } catch {
            guard !Task.isCancelled else { return }
            fetched = nil
            let status = (error as? ProviderError)?.status
            fetchNote = status == 401 || status == 403 ? "密钥不对，或者没开通" : "拿不到模型列表：\(Explain.model(error, service: choice.name).title)。也可以直接填模型名"
        }
        fetching = false
    }

    @ViewBuilder
    private var modelPicker: some View {
        if fetching {
            HStack(spacing: Ink.Space.s) {
                ProgressView()
                Text("正在拿模型列表…").font(Ink.footnote).foregroundStyle(Ink.inkSoft)
            }
        } else if let fetched {
            let words = modelSearch.trimmingCharacters(in: .whitespaces).lowercased()
            let shown = Array((words.isEmpty ? fetched : fetched.filter { $0.lowercased().contains(words) }).prefix(60))
            VStack(alignment: .leading, spacing: Ink.Space.s) {
                FieldTitle(text: "用哪些模型", note: "共 \(fetched.count) 个，已选 \(picked.count) 个")
                VStack(spacing: 0) {
                    if fetched.count > 10 {
                        TextField("搜模型名", text: $modelSearch)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .padding(Ink.Space.m)
                        Rectangle().fill(Ink.rule).frame(height: 1)
                    }
                    ForEach(shown, id: \.self) { model in
                        let on = picked.contains(model)
                        Button {
                            Haptics.tick(0.4)
                            if on { picked.remove(model) } else { picked.insert(model) }
                        } label: {
                            HStack(spacing: Ink.Space.m) {
                                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(on ? Ink.accent : Ink.inkFaint)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(model).font(.system(size: Ink.Size.sub, design: .monospaced)).foregroundStyle(Ink.ink).lineLimit(1)
                                    Text(ModelTraits.guess(model).summary).font(.system(size: Ink.Size.micro)).foregroundStyle(Ink.inkFaint)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, Ink.Space.m)
                            .padding(.vertical, Ink.Space.s)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .paperCard()
            }
            .transition(.opacity)
        } else if let fetchNote {
            Text(fetchNote).font(Ink.footnote).foregroundStyle(Ink.inkSoft)
        }
    }

    private var connectButton: some View {
        Button(action: connect) {
            HStack(spacing: Ink.Space.s) {
                if busy { ProgressView().tint(Ink.paper) }
                Text(busy ? "正在接上…" : (fetched != nil ? "接上，用这 \(picked.count) 个模型" : "连上试试"))
                    .font(.system(size: Ink.Size.body, weight: .semibold))
            }
            .foregroundStyle(Ink.paper)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(canConnect ? Ink.accent : Ink.inkFaint, in: .capsule)
        }
        .buttonStyle(PressStyle(haptic: false))
        .disabled(!canConnect)
    }

    private var canConnect: Bool {
        guard !busy, !secret.isEmpty else { return false }
        if custom, !baseURL.hasPrefix("http") { return false }
        if let fetched, !fetched.isEmpty { return !picked.isEmpty }
        if choice.asksModel, modelName.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        return true
    }

    private var helpURL: URL? { choice.keyPage.flatMap { URL(string: $0) } }

    private var address: String {
        if custom { return baseURL.trimmingCharacters(in: .whitespacesAndNewlines) }
        return choice.addresses[min(region, choice.addresses.count - 1)].url
    }

    private var finalURL: String {
        var base = address
        while base.hasSuffix("/") { base.removeLast() }
        return base + (choice.kind == .anthropic ? "/v1/messages" : "/chat/completions")
    }

    private func tile(_ item: Service) -> some View {
        let picked = item.id == choice.id
        let added = team.settings.endpoints.contains { $0.service == item.id && !item.custom }
        return Button {
            Haptics.tick(0.6)
            withAnimation(Ink.Motion.settle) {
                choice = item
                region = 0
                advice = nil
            }
        } label: {
            HStack(spacing: Ink.Space.m) {
                ServiceIcon(service: item, size: Kit.badge)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.name).font(.system(size: Ink.Size.body, weight: .medium)).foregroundStyle(Ink.ink).lineLimit(1)
                        if added { Text("已接").font(.system(size: Ink.Size.micro, weight: .medium)).foregroundStyle(Ink.ok) }
                    }
                    Text(item.note).font(.system(size: Ink.Size.small)).foregroundStyle(Ink.inkSoft).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: Ink.Size.title))
                    .foregroundStyle(picked ? Ink.accent : Ink.rule)
            }
            .padding(.horizontal, Ink.Space.l)
            .frame(minHeight: Kit.rowHeight + Ink.Space.s)
            .background(picked ? Ink.accentWash.opacity(0.5) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(haptic: false))
        .accessibilityLabel("\(item.name)：\(item.note)" + (added ? "，已接过" : ""))
    }

    // MARK: Done

    private var done: some View {
        VStack(alignment: .leading, spacing: Ink.Space.xl) {
            Spacer(minLength: 0)
            Whale(size: 110, pose: .writing)
            VStack(alignment: .leading, spacing: Ink.Space.s) {
                Text("接好了").font(Ink.display).foregroundStyle(Ink.ink)
                if let connected {
                    let listed = connected.listed?.count ?? 0
                    Text("\(connected.name) 在用 \(connected.models.count) 个模型" + (listed > connected.models.count ? "（列表里共 \(listed) 个）" : "") + Words.t("，旅伴先用 \(team.modelTitle(team.settings.defaultModel))。"))
                        .font(Ink.reading).foregroundStyle(Ink.inkSoft)
                    if let found = team.resolve(team.settings.defaultModel) {
                        TraitChips(traits: found.endpoint.traits(found.model))
                    }
                }
                Text(Words.t("更多模型和设置在调弦 › 模型服务"))
                    .font(Ink.secondary).foregroundStyle(Ink.inkFaint)
            }
            Spacer(minLength: 0)
            Button {
                Haptics.thud()
                onDone()
            } label: {
                Text(first ? Words.t("去案头，见见旅伴") : "好了")
                    .font(.system(size: Ink.Size.body, weight: .semibold))
                    .foregroundStyle(Ink.paper)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Ink.accent, in: .capsule)
            }
            .buttonStyle(PressStyle(haptic: false))
        }
        .padding(.horizontal, Ink.Space.page + 4)
        .padding(.vertical, Ink.Space.xl)
    }

    // MARK: Connecting

    private func connect() {
        let secret = self.secret
        let typed = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let given = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let taken = Set(team.settings.endpoints.map(\.id))
        var id = custom ? "custom-\(UUID().uuidString.prefix(6).lowercased())" : choice.id
        if taken.contains(id) { id += "-\(UUID().uuidString.prefix(4).lowercased())" }
        var title = custom ? (given.isEmpty ? (URL(string: address)?.host ?? "自定义") : given) : choice.name
        if team.settings.endpoints.contains(where: { $0.name == title }) { title += " 2" }
        var endpoint = Endpoint(id: id, name: title, kind: choice.kind, baseURL: address, models: [], service: custom ? nil : choice.id)
        let service = custom ? nil : choice
        busy = true
        advice = nil
        keyFocused = false
        // The list is already here and models are picked: nothing more to ask the service.
        if let fetched, !picked.isEmpty {
            endpoint.listed = fetched
            var models = fetched.filter(picked.contains)
            if !typed.isEmpty, !models.contains(typed) { models.insert(typed, at: 0) }
            endpoint.models = models
            finish(endpoint, secret)
            return
        }
        Task {
            do {
                let listed = TeamModel.keep(try await endpoint.provider(key: secret).models(), for: endpoint)
                var models = TeamModel.firstPicks(listed, service: service)
                if !typed.isEmpty { models = [typed] + models.filter { $0 != typed } }
                guard !models.isEmpty else { throw TeamError(message: "连上了，但没找到能聊天的模型。请填上模型名再试。") }
                endpoint.listed = listed
                endpoint.models = models
                finish(endpoint, secret)
            } catch {
                // Some services do not list their models: with a model name to try, a one-word question decides.
                let fallback = typed.isEmpty ? (service?.suggested ?? []) : [typed]
                let status = (error as? ProviderError)?.status
                if !fallback.isEmpty, status != 401, status != 403 {
                    do {
                        var ask = Agent(provider: endpoint.provider(key: secret), model: fallback[0], system: "")
                        ask.thinking = .off
                        _ = try await ask.ask("回一个字：好")
                        endpoint.models = fallback
                        finish(endpoint, secret)
                        return
                    } catch {
                        fail(error, service: endpoint.name)
                        return
                    }
                }
                fail(error, service: endpoint.name)
            }
        }
    }

    private func fail(_ error: Error, service: String) {
        busy = false
        Haptics.lock()
        if let plain = error as? TeamError {
            advice = Explain.Advice(title: plain.message, detail: "", next: nil)
        } else {
            advice = Explain.model(error, service: service)
        }
    }

    private func finish(_ endpoint: Endpoint, _ secret: String) {
        team.addEndpoint(endpoint, key: secret)
        busy = false
        connected = endpoint
        Haptics.thud()
        step = .done
    }
}
