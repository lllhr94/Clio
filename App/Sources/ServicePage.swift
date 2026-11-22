import AgentKit
import Craft
import SwiftUI
import UIKit

/// One model service, organized into three clear sections: enabled models, connection & key, and advanced.
struct ServicePage: View {
    @ObservedObject var team: TeamModel
    let id: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var note: String?
    @State private var working = false
    @State private var managingModels = false
    @State private var showAdvanced = false
    @State private var editing: String?
    @State private var removing = false
    @State private var name = ""
    @State private var address = ""
    @State private var style: ThinkingStyle?
    @State private var newKey = ""
    @State private var keySuffix: String?
    @State private var reading: Balance.Reading?
    @State private var balanceNote: String?

    private var endpoint: Endpoint? { team.settings.endpoints.first { $0.id == id } }
    private var service: Service? { endpoint.flatMap(Service.of) }

    var body: some View {
        ScrollView {
            if let endpoint {
                VStack(alignment: .leading, spacing: Ink.Space.xl) {
                    if let subtitle = service?.note {
                        Text(subtitle)
                            .font(Ink.secondary)
                            .foregroundStyle(Ink.inkSoft)
                    }
                    inUse(endpoint)
                    connection(endpoint)
                    if Balance.source(baseURL: endpoint.baseURL) != nil { balance(endpoint) }
                    advanced(endpoint)
                    Button(L.t("actions.deleteProvider"), role: .destructive) { removing = true }
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
        .task(id: id) {
            let key = await Vault.readString("key-\(id)")
            if !Task.isCancelled, let key, key.count > 8, keySuffix == nil { keySuffix = String(key.suffix(4)) }
        }
        .sheet(isPresented: $managingModels) {
            ManageModelsSheet(team: team, id: id)
        }
        .sheet(item: Binding(get: { editing.map { Picked(model: $0) } }, set: { editing = $0?.model })) { picked in
            ModelSheet(team: team, endpointId: id, model: picked.model)
                .presentationDetents([.large])
        }
        // A name or address typed and left without pressing return is kept, not lost.
        .onDisappear {
            if let endpoint, !removing, !name.isEmpty, !address.isEmpty, name != endpoint.name || address != endpoint.baseURL { save(endpoint) }
        }
        .confirmationDialog(Words.t("删掉 \(endpoint?.name ?? "")？用它的旅伴会改用默认模型，密钥也一起删掉。"), isPresented: $removing, titleVisibility: .visible) {
            Button(L.t("actions.delete"), role: .destructive) {
                team.removeEndpoint(id)
                dismiss()
            }
            Button(L.t("actions.cancel"), role: .cancel) {}
        }
    }

    private struct Picked: Identifiable {
        var model: String
        var id: String { model }
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
                .frame(height: 30 * UIScale.factor)
                .background(Ink.accentWash, in: .capsule)
        }
        .buttonStyle(PressStyle(haptic: false))
        .disabled(working)
    }

    // MARK: 1. Enabled models

    private func inUse(_ endpoint: Endpoint) -> some View {
        let restCount = (endpoint.listed ?? []).filter { !endpoint.models.contains($0) }.count
        let manageLine = restCount > 0
            ? L.format("settings.manageModelsMoreLine", restCount)
            : L.t("settings.manageModelsLine")
        return VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle(L.t("settings.activeModels"))
            VStack(spacing: 0) {
                ForEach(endpoint.models, id: \.self) { model in
                    modelRow(endpoint, model)
                    Kit.rule(inset: Ink.Space.l)
                }
                Button {
                    Haptics.light()
                    managingModels = true
                } label: {
                    RowLabel("plus", tint: Ink.Tile.dai, title: L.t("settings.manageModels"), line: manageLine)
                }
                .buttonStyle(TapStyle())
            }
            .paperCard()
            Text("选模型时只列这些。点一个查看能力或实测。")
                .font(.system(size: Ink.Size.small))
                .foregroundStyle(Ink.inkSoft)
                .padding(.horizontal, Ink.Space.l)
                .fixedSize(horizontal: false, vertical: true)
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
                ModelIcon(model: model, service: Service.of(endpoint), size: Kit.badge, name: endpoint.name)
                VStack(alignment: .leading, spacing: Ink.Space.xs) {
                    HStack(spacing: Ink.Space.s) {
                        Text(model).font(Ink.mono(Ink.Size.sub, weight: .medium)).foregroundStyle(Ink.ink).lineLimit(1)
                        if isDefault {
                            Text(L.t("settings.defaultModelBadge"))
                                .font(.system(size: Ink.Size.micro, weight: .semibold))
                                .foregroundStyle(Ink.accent)
                                .padding(.horizontal, Ink.Space.s)
                                .padding(.vertical, Ink.Space.xs / 4)
                                .background(Ink.accentWash, in: .capsule)
                        }
                    }
                    TraitChips(traits: traits, corrected: endpoint.corrected(model))
                    if gone {
                        Text(L.t("settings.modelUnavailable")).font(Ink.footnote).foregroundStyle(Ink.warn)
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
            Button(L.t("actions.removeModel"), systemImage: "minus.circle", role: .destructive) {
                withAnimation(.smooth) { team.setModels(endpoint.id, endpoint.models.filter { $0 != model }) }
            }
        }
    }

    // MARK: 2. Connection and key

    private func connection(_ endpoint: Endpoint) -> some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle(L.t("settings.connectionAndKey"))
            VStack(alignment: .leading, spacing: Ink.Space.m) {
                labeled("称呼") {
                    TextField("称呼", text: $name)
                        .font(.system(size: Ink.Size.sub))
                        .onSubmit { save(endpoint) }
                }
                Kit.rule(inset: 0)
                labeled("地址") {
                    TextField("https://…", text: $address)
                        .font(Ink.mono(Ink.Size.sub))
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
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
                            .frame(height: 28 * UIScale.factor)
                            .background(address == option.url ? Ink.accentWash : Ink.mine, in: .capsule)
                        }
                    }
                }
                Text("实际请求：" + finalURL(endpoint))
                    .font(Ink.mono(Ink.Size.small))
                    .foregroundStyle(Ink.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
                Kit.rule(inset: 0)
                labeled("密钥") {
                    HStack(spacing: Ink.Space.s) {
                        SecureField(maskedKey, text: $newKey)
                            .font(Ink.mono(Ink.Size.sub))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if !newKey.isEmpty {
                            Button(L.t("actions.replaceKey")) { replaceKey(endpoint) }
                                .font(.system(size: Ink.Size.sub, weight: .semibold))
                                .foregroundStyle(Ink.accent)
                        }
                    }
                }
                Text(L.t("settings.keyStorageNote"))
                    .font(Ink.footnote)
                    .foregroundStyle(Ink.inkFaint)
                Kit.rule(inset: 0)
                HStack(spacing: Ink.Space.s) {
                    pill("试连", "bolt.horizontal") { probe(endpoint) }
                    pill("刷新模型列表", "arrow.clockwise") { refresh(endpoint) }
                    if let page = service?.keyPage, let url = URL(string: page) {
                        pill("管理密钥", "arrow.up.right") { openURL(url) }
                    }
                }
                if let note {
                    Text(note)
                        .font(Ink.footnote)
                        .foregroundStyle(Ink.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Ink.Space.l)
            .paperCard()
        }
    }

    // MARK: 3. Advanced (collapsed by default)

    private func advanced(_ endpoint: Endpoint) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                Haptics.light()
                withAnimation(Ink.Motion.settle) { showAdvanced.toggle() }
            } label: {
                HStack(spacing: Ink.Space.m) {
                    Text(L.t("settings.advanced"))
                        .font(.system(size: Ink.Size.body))
                        .foregroundStyle(Ink.ink)
                    Spacer(minLength: Ink.Space.s)
                    Image(systemName: showAdvanced ? "chevron.up" : "chevron.down")
                        .font(.system(size: Ink.Size.small, weight: .semibold))
                        .foregroundStyle(Ink.inkFaint)
                }
                .padding(.horizontal, Ink.Space.l)
                .frame(minHeight: Kit.rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(TapStyle())

            if showAdvanced {
                Kit.rule(inset: Ink.Space.l)
                VStack(alignment: .leading, spacing: Ink.Space.m) {
                    HStack {
                        Text(L.t("settings.apiType"))
                            .font(.system(size: Ink.Size.sub))
                            .foregroundStyle(Ink.ink)
                        Spacer()
                        Text(endpoint.kind == .anthropic ? "Claude 接口" : "OpenAI 兼容接口")
                            .font(.system(size: Ink.Size.sub))
                            .foregroundStyle(Ink.inkSoft)
                    }
                    if endpoint.kind == .openai {
                        Kit.rule(inset: 0)
                        thinkingStyleRow(endpoint)
                        Text(thinkingLevelsSummary(endpoint))
                            .font(Ink.footnote)
                            .foregroundStyle(Ink.inkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(Ink.Space.l)
                .transition(.opacity)
            }
        }
        .paperCard()
    }

    private func thinkingStyleRow(_ endpoint: Endpoint) -> some View {
        HStack(alignment: .top, spacing: Ink.Space.m) {
            VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
                Text(L.t("settings.thinkingFormat"))
                    .font(.system(size: Ink.Size.sub))
                    .foregroundStyle(Ink.ink)
                Text(L.t("settings.thinkingFormatNote"))
                    .font(Ink.footnote)
                    .foregroundStyle(Ink.inkFaint)
            }
            Spacer(minLength: Ink.Space.s)
            Menu {
                Button {
                    style = nil
                    save(endpoint)
                } label: {
                    if style == nil {
                        Label("跟着服务（\(endpoint.thinkingStyleGuess.title)）", systemImage: "checkmark")
                    } else {
                        Text("跟着服务（\(endpoint.thinkingStyleGuess.title)）")
                    }
                }
                ForEach(ThinkingStyle.allCases, id: \.self) { option in
                    Button {
                        style = option
                        save(endpoint)
                    } label: {
                        if style == option {
                            Label(option.title, systemImage: "checkmark")
                        } else {
                            Text(option.title)
                        }
                    }
                }
            } label: {
                HStack(spacing: Ink.Space.xs) {
                    Text(style?.title ?? L.t("settings.providerDefault"))
                        .font(.system(size: Ink.Size.sub, weight: .medium))
                        .foregroundStyle(Ink.accent)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: Ink.Size.micro, weight: .semibold))
                        .foregroundStyle(Ink.inkFaint)
                }
            }
        }
    }

    private func thinkingLevelsSummary(_ endpoint: Endpoint) -> String {
        let effective = style ?? endpoint.thinkingStyleGuess
        if effective == .none {
            return "不发送思考参数，仅保留「默认」。"
        }
        let offered = effective.levels(thinks: true).map(\.title).joined(separator: " · ")
        return "支持思考的模型默认提供：\(offered)"
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: Ink.Space.m) {
            Text(title)
                .font(.system(size: Ink.Size.sub))
                .foregroundStyle(Ink.inkSoft)
                .frame(width: 40 * UIScale.factor, alignment: .leading)
            content()
        }
    }

    private func finalURL(_ endpoint: Endpoint) -> String {
        var base = address.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        return base + (endpoint.kind == .anthropic ? "/v1/messages" : "/chat/completions")
    }

    private var maskedKey: String {
        guard let keySuffix else { return "粘贴新的密钥来换掉" }
        return "已存 ••••" + keySuffix + "，粘贴新的来换"
    }

    private func save(_ endpoint: Endpoint) {
        team.editEndpoint(endpoint.id, name: name, baseURL: address, style: style)
    }

    private func replaceKey(_ endpoint: Endpoint) {
        let key = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        team.replaceKey(endpoint.id, key)
        keySuffix = key.count > 8 ? String(key.suffix(4)) : nil
        newKey = ""
        Haptics.thud()
        note = "密钥换好了。点「试连」看看通不通。"
    }

    // MARK: Balance

    private func balance(_ endpoint: Endpoint) -> some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle(L.t("settings.balance"))
            HStack {
                VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
                    if let reading {
                        Text(reading.shown).font(Ink.serif(Ink.Size.title, bold: true)).foregroundStyle(Ink.ink)
                        if let detail = reading.detail { Text(detail).font(Ink.footnote).foregroundStyle(Ink.inkSoft) }
                    } else {
                        Text(balanceNote ?? L.t("loading.checking")).font(Ink.footnote).foregroundStyle(Ink.inkSoft)
                    }
                }
                Spacer()
                if let source = Balance.source(baseURL: endpoint.baseURL) {
                    Link("去充值", destination: source.topUp)
                        .font(.system(size: Ink.Size.sub, weight: .medium))
                        .foregroundStyle(Ink.accent)
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
                note = "列表里有 \(count) 个能聊天的模型" + (waiting > 0 ? "，在用的之外还有 \(waiting) 个，点「管理 / 添模型」勾选。" : "。")
            } catch {
                note = Explain.model(error, service: endpoint.name).displayTitle
            }
            working = false
        }
    }

    private func probe(_ endpoint: Endpoint) {
        guard let model = (team.resolve(team.settings.defaultModel).flatMap { $0.endpoint.id == endpoint.id ? $0.model : nil }) ?? endpoint.models.first else {
            note = "还没有在用的模型：点「管理 / 添模型」勾选或手动添一个。"
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

/// Unified drawer for enabling/disabling models from a service's catalog and typing custom model IDs.
private struct ManageModelsSheet: View {
    @ObservedObject var team: TeamModel
    let id: String
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var typed = ""
    @State private var refreshing = false
    @State private var note: String?

    private var endpoint: Endpoint? { team.settings.endpoints.first { $0.id == id } }
    private var service: Service? { endpoint.flatMap(Service.of) }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let endpoint {
                    VStack(alignment: .leading, spacing: Ink.Space.xl) {
                        manualCard(endpoint)
                        if let note {
                            Text(note)
                                .font(Ink.footnote)
                                .foregroundStyle(Ink.inkSoft)
                                .padding(.horizontal, Ink.Space.l)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        catalogCard(endpoint)
                    }
                    .padding(.horizontal, Ink.Space.page)
                    .padding(.vertical, Ink.Space.l)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Ink.paper.ignoresSafeArea())
            .navigationTitle(L.t("settings.manageModels"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜模型名，比如 qwen、vl、flash")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if let endpoint {
                        Button {
                            Haptics.light()
                            refresh(endpoint)
                        } label: {
                            if refreshing {
                                ProgressView()
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .disabled(refreshing)
                        .accessibilityLabel(L.t("settings.refreshImageModels"))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L.t("actions.done")) {
                        Haptics.light()
                        dismiss()
                    }
                }
            }
        }
    }

    private func manualCard(_ endpoint: Endpoint) -> some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle(L.t("settings.imageModelManual"))
            HStack(spacing: Ink.Space.s) {
                TextField(service?.modelHint ?? "手动添一个模型名", text: $typed)
                    .font(Ink.mono(Ink.Size.sub))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit { addTyped(endpoint) }
                Button(L.t("actions.add")) { addTyped(endpoint) }
                    .font(.system(size: Ink.Size.sub, weight: .semibold))
                    .foregroundStyle(typed.trimmingCharacters(in: .whitespaces).isEmpty ? Ink.inkFaint : Ink.accent)
                    .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, Ink.Space.l)
            .frame(minHeight: Kit.rowHeight)
            .paperCard()
        }
    }

    private func catalogCard(_ endpoint: Endpoint) -> some View {
        let all = endpoint.allModels
        let words = search.trimmingCharacters(in: .whitespaces).lowercased()
        let found = words.isEmpty ? all : all.filter { $0.lowercased().contains(words) }
        let shown = Array(found.prefix(100))
        return VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle(all.isEmpty ? L.t("settings.imageModelAvailable") : "共 \(all.count) 个，已启用 \(endpoint.models.count) 个")
            VStack(spacing: 0) {
                if all.isEmpty {
                    VStack(alignment: .leading, spacing: Ink.Space.s) {
                        Text("还没有拉到模型列表，可以点左上角刷新，或在上面直接手填模型名。")
                            .font(Ink.secondary)
                            .foregroundStyle(Ink.inkSoft)
                        Button("刷新模型列表") { refresh(endpoint) }
                            .font(.system(size: Ink.Size.sub, weight: .semibold))
                            .foregroundStyle(Ink.accent)
                            .disabled(refreshing)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Ink.Space.l)
                } else if found.isEmpty {
                    Text("没有名字里带「\(search)」的。")
                        .font(Ink.footnote)
                        .foregroundStyle(Ink.inkFaint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Ink.Space.l)
                } else {
                    ForEach(Array(shown.enumerated()), id: \.element) { index, model in
                        if index > 0 { Kit.rule(inset: Ink.Space.l) }
                        catalogRow(endpoint, model)
                    }
                    if found.count > shown.count {
                        Kit.rule(inset: Ink.Space.l)
                        Text("还有 \(found.count - shown.count) 个，搜一搜就能找到。")
                            .font(Ink.footnote)
                            .foregroundStyle(Ink.inkFaint)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Ink.Space.l)
                    }
                }
            }
            .paperCard()
        }
    }

    private func catalogRow(_ endpoint: Endpoint, _ model: String) -> some View {
        let enabled = endpoint.models.contains(model)
        return Button {
            Haptics.tick(0.5)
            withAnimation(.smooth) {
                if enabled {
                    team.setModels(endpoint.id, endpoint.models.filter { $0 != model })
                } else {
                    team.setModels(endpoint.id, endpoint.models + [model])
                }
            }
        } label: {
            HStack(spacing: Ink.Space.m) {
                Image(systemName: enabled ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: Ink.Size.title))
                    .foregroundStyle(enabled ? Ink.accent : Ink.inkFaint)
                VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
                    Text(model)
                        .font(Ink.mono(Ink.Size.sub, weight: enabled ? .medium : .regular))
                        .foregroundStyle(Ink.ink)
                        .lineLimit(1)
                    Text(endpoint.traits(model).summary)
                        .font(.system(size: Ink.Size.small))
                        .foregroundStyle(Ink.inkSoft)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Ink.Space.l)
            .padding(.vertical, Ink.Space.m)
            .contentShape(Rectangle())
        }
        .buttonStyle(TapStyle())
        .accessibilityAddTraits(enabled ? .isSelected : [])
    }

    private func addTyped(_ endpoint: Endpoint) {
        let model = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return }
        typed = ""
        guard !endpoint.models.contains(model) else {
            note = "\(model) 已经在常用模型里了。"
            return
        }
        Haptics.tick(0.6)
        withAnimation(.smooth) { team.setModels(endpoint.id, endpoint.models + [model]) }
        note = "添上了 \(model)。回到服务页点开它，可以查看或实测能力。"
    }

    private func refresh(_ endpoint: Endpoint) {
        refreshing = true
        note = L.t("loading.fetchingModels")
        Task {
            do {
                let count = try await team.refreshModels(endpoint.id)
                note = "刷新好了，列表里共有 \(count) 个模型。"
            } catch {
                note = Explain.model(error, service: endpoint.name).displayTitle
            }
            refreshing = false
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
        HStack(spacing: Ink.Space.xs) {
            tag(traits.sees ? L.t("settings.modelVision") : "不看图", traits.sees ? "eye" : "eye.slash", on: traits.sees)
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
            .padding(.horizontal, Ink.Space.s)
            .frame(height: 20 * UIScale.factor)
            .background(on ? Ink.mine : Color.clear, in: .capsule)
            .overlay(Capsule().strokeBorder(on ? Color.clear : Ink.rule, lineWidth: 1))
    }
}

/// One model: what it can do (from catalog/API/probe or set by hand), probe verification, and removing from active list.
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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Ink.Space.xl) {
                    capabilitiesCard
                    probeCard
                    actionsCard
                }
                .padding(.horizontal, Ink.Space.page)
                .padding(.vertical, Ink.Space.l)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Ink.paper.ignoresSafeArea())
            .navigationTitle(model)
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
        .onAppear { traits = endpoint?.traits(model) ?? ModelTraits.known(model) }
        .onChange(of: traits) { _, value in
            guard value != endpoint?.traits(model) else { return }
            let baseline = endpoint?.traits(model, ignoringCorrection: true) ?? ModelTraits.known(model)
            team.setTraits(endpointId, model: model, value == baseline ? nil : value)
        }
    }

    private var capabilitiesCard: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle(L.t("settings.modelCapabilities"))
            VStack(spacing: 0) {
                toggleRow(L.t("settings.modelVision"), isOn: $traits.sees)
                Kit.rule(inset: Ink.Space.l)
                toggleRow(L.t("settings.modelTools"), isOn: $traits.tools)
                Kit.rule(inset: Ink.Space.l)
                toggleRow(L.t("settings.modelReasoning"), isOn: $traits.thinks)
                Kit.rule(inset: Ink.Space.l)
                StopRow(
                    title: L.t("settings.modelContextLabel"),
                    value: $traits.window,
                    stops: windowChoices.map { Stop(value: $0, name: Tokens.short($0) + " token") }
                )
                .padding(.horizontal, Ink.Space.l)
                .frame(minHeight: Kit.rowHeight)
                if traits.thinks || traits.levels != nil {
                    Kit.rule(inset: Ink.Space.l)
                    thinkingLevelsRow
                }
            }
            .paperCard()
            Text(footer)
                .font(.system(size: Ink.Size.small))
                .foregroundStyle(Ink.inkSoft)
                .padding(.horizontal, Ink.Space.l)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .font(.system(size: Ink.Size.body))
            .foregroundStyle(Ink.ink)
            .tint(Ink.accent)
            .padding(.horizontal, Ink.Space.l)
            .frame(minHeight: Kit.rowHeight)
    }

    private var thinkingLevelsRow: some View {
        HStack(alignment: .center, spacing: Ink.Space.m) {
            VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
                HStack(spacing: Ink.Space.s) {
                    Text(L.t("settings.thinkingLevels"))
                        .font(.system(size: Ink.Size.body))
                        .foregroundStyle(Ink.ink)
                    Text(traits.levels != nil ? L.t("settings.thinkingLevelsTested") : L.t("settings.thinkingLevelsDefault"))
                        .font(.system(size: Ink.Size.micro, weight: .medium))
                        .foregroundStyle(traits.levels != nil ? Ink.accent : Ink.inkFaint)
                        .padding(.horizontal, Ink.Space.s)
                        .padding(.vertical, Ink.Space.xs / 4)
                        .background(traits.levels != nil ? Ink.accentWash : Ink.mine, in: .capsule)
                }
                Text(displayedThinkingLevels)
                    .font(.system(size: Ink.Size.small))
                    .foregroundStyle(Ink.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Ink.Space.s)
            if traits.levels != nil {
                Button(L.t("settings.clearTestedLevels")) {
                    Haptics.tick(0.5)
                    traits.levels = nil
                }
                .font(.system(size: Ink.Size.small, weight: .semibold))
                .foregroundStyle(Ink.accent)
            }
        }
        .padding(.horizontal, Ink.Space.l)
        .padding(.vertical, Ink.Space.m)
    }

    private var displayedThinkingLevels: String {
        if let rawLevels = traits.levels {
            let parsed = rawLevels.compactMap(Thinking.init(rawValue:))
            if parsed.isEmpty { return L.t("settings.thinkingLevelsOnlyAuto") }
            return ([Thinking.auto] + parsed.filter { $0 != .auto }).map(\.title).joined(separator: " · ")
        }
        guard let endpoint else { return L.t("settings.thinkingLevelsOnlyAuto") }
        let levels: [Thinking]
        if endpoint.kind == .anthropic {
            levels = traits.thinks ? Thinking.allCases : [.auto]
        } else {
            levels = endpoint.thinkingStyle.levels(thinks: traits.thinks)
        }
        return levels.map(\.title).joined(separator: " · ")
    }

    private var probeCard: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle(L.t("settings.modelProbeSection"))
            VStack(spacing: 0) {
                actionRow(working ? L.t("loading.testingModel") : L.t("actions.testModelAll"),
                          symbol: "checklist", tint: Ink.accent, disabled: working) {
                    testAll()
                }
                Kit.rule(inset: Ink.Space.l)
                actionRow(working ? L.t("loading.testingModel") : L.t("actions.testModelOnly"),
                          symbol: "bolt.horizontal", tint: Ink.ink, disabled: working) {
                    testReply()
                }
                if let note {
                    Kit.rule(inset: Ink.Space.l)
                    Text(note)
                        .font(Ink.footnote)
                        .foregroundStyle(Ink.inkSoft)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Ink.Space.l)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .paperCard()
            Text(L.t("settings.modelProbeNote"))
                .font(.system(size: Ink.Size.small))
                .foregroundStyle(Ink.inkSoft)
                .padding(.horizontal, Ink.Space.l)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actionsCard: some View {
        VStack(spacing: 0) {
            if endpoint?.corrected(model) == true {
                actionRow(L.t("actions.resetModelCapabilities"), symbol: "arrow.uturn.backward", tint: Ink.ink, disabled: false) {
                    Haptics.tick(0.5)
                    team.setTraits(endpointId, model: model, nil)
                    traits = endpoint.map { $0.traits(model, ignoringCorrection: true) } ?? ModelTraits.known(model)
                }
                Kit.rule(inset: Ink.Space.l)
            }
            actionRow(L.t("actions.removeModel"), symbol: "minus.circle", tint: Ink.stop, disabled: false) {
                if let endpoint { team.setModels(endpointId, endpoint.models.filter { $0 != model }) }
                dismiss()
            }
        }
        .paperCard()
    }

    private func actionRow(_ title: String, symbol: String, tint: Color, disabled: Bool, run: @escaping () -> Void) -> some View {
        Button {
            Haptics.light()
            run()
        } label: {
            HStack(spacing: Ink.Space.m) {
                Image(systemName: symbol)
                    .font(.system(size: Ink.Size.body, weight: .medium))
                    .foregroundStyle(disabled ? Ink.inkFaint : tint)
                    .frame(width: 24 * UIScale.factor)
                Text(title)
                    .font(.system(size: Ink.Size.body))
                    .foregroundStyle(disabled ? Ink.inkFaint : tint)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Ink.Space.l)
            .frame(minHeight: Kit.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(TapStyle())
        .disabled(disabled)
    }

    private var windowChoices: [Int] {
        Self.windows.contains(traits.window) ? Self.windows : (Self.windows + [traits.window]).sorted()
    }

    private var capabilitySource: String {
        if endpoint?.corrected(model) == true { return "来源：已手动修改或实测。" }
        let hasAPIWindow = endpoint?.windows?[model] != nil
        let hasCatalog = ModelsDev.lookup(model) != nil
        if hasAPIWindow && hasCatalog { return "来源：服务接口与模型资料库。" }
        if hasAPIWindow { return "来源：服务接口与名称识别。" }
        if hasCatalog { return "来源：模型资料库（models.dev）。" }
        return "来源：按模型名自动识别。"
    }

    private var footer: String {
        capabilitySource + Words.t("不能看图时，发来的照片会换成编号，旅伴可以用 photo_text 读图上的字；不会用工具时，旅伴只聊天，不上网也不动手。")
    }

    /// Every ability in one go: answers at all, sees a picture, calls a tool, thinks (and can stop). What it finds
    /// is set on the switches above, as if the user had set them.
    private func testAll() {
        guard let endpoint else { return }
        working = true
        note = L.t("loading.testingModel")
        Task {
            var lines: [String] = []
            let reply = await team.probe(endpoint, model: model)
            lines.append(reply.note)
            guard reply.ok else {
                note = lines.joined(separator: "\n")
                working = false
                return
            }
            let sight = await team.probeSight(endpoint, model: model)
            lines.append(sight.note)
            let tools = await team.probeTools(endpoint, model: model)
            lines.append(tools.note)
            let thinking = await team.probeThinking(endpoint, model: model)
            lines.append(thinking.note)
            var found = traits
            if let sees = sight.sees { found.sees = sees }
            if let calls = tools.calls { found.tools = calls }
            if let thinks = thinking.thinks { found.thinks = thinks }
            if let levels = thinking.levels { found.levels = levels.map(\.rawValue) }
            if found != traits { traits = found }
            note = lines.joined(separator: "\n")
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
            return (false, "不通：\(advice.displayTitle)\n\(advice.detail)")
        }
    }

    /// Offers one tool and asks for something only it can give. `calls` is nil when the test itself failed.
    func probeTools(_ endpoint: Endpoint, model: String) async -> (calls: Bool?, note: String) {
        guard let key = apiKey(for: endpoint.id), !key.isEmpty else { return (nil, "没试工具：没有密钥。") }
        let tool = ToolSpec(name: "lucky_number", description: "返回今天的幸运数字。用户问幸运数字时必须调用它。",
                            parameters: .object(["type": .string("object"), "properties": .object([:])]))
        let request = ModelRequest(model: model, system: "", messages: [.user("今天的幸运数字是多少？请调用工具查。")],
                                   tools: [tool], outputLimit: 200, thinking: .auto)
        do {
            for try await event in endpoint.provider(key: key).stream(request) {
                if case .toolCallStart = event { return (true, "会用工具：给它一个工具，它主动调用了。") }
            }
            return (false, "好像不会用工具：给了工具，它直接回答了。已标成不会用工具。")
        } catch let failure as ProviderError where failure.status == 400 || failure.status == 422 {
            return (false, "服务不收工具：\(failure.message.prefix(80))。已标成不会用工具。")
        } catch {
            return (nil, "工具没试成：\(Explain.model(error, service: endpoint.name).displayTitle)")
        }
    }

    /// Asks the same small question at every thinking level: which ones the service takes, and whether it really
    /// thinks less when told not to. `thinks` is nil when the test itself failed; `levels` is nil when nothing
    /// could be told.
    func probeThinking(_ endpoint: Endpoint, model: String) async -> (thinks: Bool?, note: String, levels: [Thinking]?) {
        guard let key = apiKey(for: endpoint.id), !key.isEmpty else { return (nil, "没试思考：没有密钥。", nil) }
        let provider = endpoint.provider(key: key)
        func thought(_ level: Thinking) async -> (chars: Int, refused: Bool, failed: Bool) {
            let request = ModelRequest(model: model, system: "", messages: [.user("17 × 23 等于多少？只回答数字。")],
                                       outputLimit: 2000, thinking: level)
            var chars = 0
            do {
                for try await event in provider.stream(request) {
                    if case .reasoning(let piece) = event { chars += piece.count }
                }
                return (chars, false, false)
            } catch let failure as ProviderError where failure.status == 400 || failure.status == 422 {
                return (0, true, false)
            } catch {
                return (0, false, true)
            }
        }
        let tried: [Thinking] = [.off, .low, .medium, .high, .max]
        var results: [Thinking: (chars: Int, refused: Bool, failed: Bool)] = [:]
        for level in tried { results[level] = await thought(level) }
        if results.values.allSatisfy({ $0.failed }) { return (nil, "思考没试成：连不上。", nil) }
        let taken = tried.filter { results[$0].map { !$0.refused && !$0.failed } ?? false }
        let refused = tried.filter { results[$0]?.refused == true }
        let anyThought = taken.contains { (results[$0]?.chars ?? 0) > 0 }
        let deep = taken.filter { $0 != .off }.map { results[$0]?.chars ?? 0 }.max() ?? 0
        let off = results[.off].map { $0.refused || $0.failed ? -1 : $0.chars } ?? -1
        var words: [String] = []
        if !anyThought {
            words.append(refused.count == tried.count ? "不会思考：服务不接受任何思考设置。" : "没看到思考内容：要么不会思考，要么这家服务不把思考发回来。")
            words.append("已标成不会思考，思考菜单只留「默认」。")
            return (false, words.joined(), [])
        }
        words.append("能用的档：" + taken.map(\.title).joined(separator: "、") + "。")
        if !refused.isEmpty { words.append("服务不收：" + refused.map(\.title).joined(separator: "、") + "，菜单里不再出现。") }
        if off == 0 { words.append("「不想」能真的关掉思考。") }
        else if off > 0 && deep > off * 2 { words.append("「不想」关不掉，只是少想（\(off) 字，深的 \(deep) 字）。") }
        else if off > 0 { words.append("各档想的差不多多（约 \(deep) 字），档位作用不大。") }
        return (true, "会思考。" + words.joined(), taken)
    }

    /// Shows the model a red square and asks its colour. `sees` is nil when the test itself failed.
    func probeSight(_ endpoint: Endpoint, model: String) async -> (sees: Bool?, note: String) {
        let size = CGSize(width: 64, height: 64)
        let data = UIGraphicsImageRenderer(size: size).jpegData(withCompressionQuality: 0.9) { context in
            Ink.Artwork.badgeRed.setFill()
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
            return (nil, "没试成：\(Explain.model(error, service: endpoint.name).displayTitle)")
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
