import AgentKit
import Craft
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
private final class SetupDraft {
    var key = ""
    var baseURL = "" {
        didSet {
            if EndpointAddressPolicy.rawOrigin(oldValue) != EndpointAddressPolicy.rawOrigin(baseURL) { key = "" }
        }
    }
    var name = ""
    var modelName = ""

    func secret(keyless: Bool) -> String {
        let typed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty && keyless ? "local" : typed
    }

    func address(for choice: Service, region: Int) -> String {
        if choice.custom { return baseURL.trimmingCharacters(in: .whitespacesAndNewlines) }
        return choice.addresses[min(region, choice.addresses.count - 1)].url
    }
}

/// Connects a model service. On first launch it begins with a short welcome; from 调弦 it goes straight to the service.
struct SetupView: View {
    @ObservedObject var team: TeamModel
    /// Shown on first launch: a welcome first, and no way out until a service is connected.
    var first = false
    var welcomeOnly = false
    var onDone: () -> Void

    private let preset: Service?
    @State private var saveTask: Task<Void, Never>?

    init(team: TeamModel, first: Bool = false, welcomeOnly: Bool = false, preset: Service? = nil, onDone: @escaping () -> Void) {
        self.team = team
        self.first = first
        self.welcomeOnly = welcomeOnly
        self.preset = preset
        self.onDone = onDone
        _choice = State(initialValue: preset ?? Service.catalog[0])
    }

    private enum Step { case welcome, service, done }

    @Environment(\.openURL) private var openURL
    @State private var step: Step = .service
    @State private var choice: Service
    @State private var region = 0
    @State private var draft = SetupDraft()
    @State private var busy = false
    @State private var advice: Explain.Advice?
    @State private var connected: Endpoint?
    /// The service's model list, fetched as soon as there is a key: models are picked before anything is saved.
    @State private var fetched: [String]?
    @State private var fetchedImageModels: [String]?
    @State private var fetchedWindows: [String: Int] = [:]
    @State private var picked: Set<String> = []
    @State private var fetching = false
    @State private var fetchNote: String?
    @State private var fetchFailed = false
    @FocusState private var keyFocused: Bool

    private var custom: Bool { choice.custom }

    var body: some View {
        ZStack {
            Ink.paper.ignoresSafeArea()
            switch step {
            case .welcome: welcome.transition(.blurReplace)
            case .service: service.transition(.blurReplace)
            case .done: done.transition(.blurReplace)
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onboardingSize = $0 }
        .animation(Ink.Motion.unfold, value: step)
        .onAppear { step = first && !UserDefaults.standard.bool(forKey: Self.introSeen) ? .welcome : .service }
        .onDisappear { saveTask?.cancel() }
    }

    // MARK: Welcome: four pages, then the service

    @State private var page = 0
    @State private var onboardingSize = CGSize.zero
    /// Once the four pages are through (to the service, or to the demo and back), they are not shown again.
    static let introSeen = "intro.seen"

    /// Whose drawings the pages use: 肉包 if that is the pet picked, else 小克.
    private var artist: String { PetLibrary.shared.choice.hasSuffix("roubao") ? "roubao" : "xiaoke" }

    private var welcome: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                introPage(1).tag(0)
                introPage(2).tag(1)
                introPage(3) { ToneCards() }.tag(2)
                introPage(4).tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(Ink.Motion.settle, value: page)

            VStack(spacing: Ink.Space.l) {
                dots
                introButtons
            }
            .padding(.horizontal, Ink.Space.xl)
            .padding(.bottom, Ink.Space.xl)
        }
    }

    private func introPage(_ n: Int) -> some View { introPage(n) { EmptyView() } }

    private func introPage<Extra: View>(_ n: Int, @ViewBuilder extra: () -> Extra) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Ink.Space.xl) {
                Image("onboarding-\(artist)-\(n)")
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(1, contentMode: .fit)
                    .frame(width: introArtSide, height: introArtSide)
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Ink.Space.s) {
                    Text(L.t("onboarding.page\(n).title"))
                        .font(Ink.mark(Ink.Size.title, bold: true, relativeTo: .largeTitle)).foregroundStyle(Ink.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L.t("onboarding.page\(n).subtitle"))
                        .font(Ink.reading).foregroundStyle(Ink.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                extra()
            }
            .frame(maxWidth: Ink.Size.body * 35)
            .padding(.horizontal, Ink.Space.xl)
            .padding(.vertical, Ink.Space.m)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.center, for: .alignment)
    }

    private var introArtSide: CGFloat {
        guard onboardingSize.width > 0, onboardingSize.height > 0 else { return Ink.Size.body * 11 }
        return min(onboardingSize.width * 0.52, onboardingSize.height * 0.28, Ink.Size.body * 17)
    }

    private var dots: some View {
        HStack(spacing: Ink.Space.s) {
            ForEach(0..<4, id: \.self) { i in
                Capsule()
                    .fill(i == page ? Ink.accent : Ink.rule)
                    .frame(width: i == page ? 18 : 6, height: 6)
            }
        }
        .animation(Ink.Motion.settle, value: page)
        .accessibilityElement()
        .accessibilityLabel("第 \(page + 1) 页，共 4 页")
    }

    @ViewBuilder
    private var introButtons: some View {
        if page < 3 {
            Button {
                Haptics.light()
                withAnimation(Ink.Motion.settle) { page += 1 }
            } label: {
                Text(L.t("onboarding.page\(page + 1).cta"))
            }
            .buttonStyle(WideButtonStyle())
        } else {
            VStack(spacing: Ink.Space.s) {
                Button {
                    Haptics.light()
                    UserDefaults.standard.set(true, forKey: Self.introSeen)
                    if welcomeOnly { onDone() } else { step = .service }
                } label: {
                    Text(L.t(welcomeOnly ? "homeThreads.continue" : "onboarding.page4.primaryCta"))
                }
                .buttonStyle(WideButtonStyle())
                Button {
                    Haptics.light()
                    UserDefaults.standard.set(true, forKey: Self.introSeen)
                    team.showDemo()
                    onDone()
                } label: {
                    Text(L.t("onboarding.page4.secondaryCta"))
                }
                .buttonStyle(WideButtonStyle(filled: false))
            }
        }
    }

    // MARK: Service

    private var service: some View {
        serviceBody
            .background {
                SetupFetchDriver(
                    draft: draft,
                    choice: choice,
                    region: region,
                    loadCatalog: { try await ServiceOnboardingEngine.loadCatalog(for: $0, secret: $1) },
                    onFetching: { fetching = $0 },
                    onResult: { result in
                        fetched = result.fetched
                        fetchedImageModels = result.imageModels
                        fetchedWindows = result.windows
                        if let pickedDefault = result.picked {
                            picked = pickedDefault
                        }
                        fetchNote = result.note
                        fetchFailed = result.failed
                    }
                )
            }
    }

    private var serviceBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Ink.Space.xl) {
                if preset == nil {
                    serviceHeading
                }
                Group {
                    servicePicker
                    SetupKeyField(draft: draft, choice: choice, keyFocused: $keyFocused, helpURL: helpURL) {
                        openURL($0)
                    }
                    modelPicker
                }
                .disabled(busy)
                adviceCard
                SetupConnectButton(draft: draft, choice: choice, fetched: fetched, pickedCount: picked.count, busy: busy, connect: connect)
            }
            .padding(.horizontal, Ink.Space.page)
            .padding(.vertical, Ink.Space.xl)
            .animation(Ink.Motion.settle, value: choice.id)
            .animation(Ink.Motion.settle, value: advice?.title)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollIndicators(.hidden)
        .onChange(of: draft.key) { clearCatalog() }
        .onChange(of: draft.baseURL) { clearCatalog() }
    }

    private var serviceHeading: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: Ink.Space.xs) {
                Text(L.t(first ? "settings.firstModel" : "settings.addModelService")).font(Ink.title).foregroundStyle(Ink.ink)
                Text(L.t("settings.moreModelServices")).font(Ink.secondary).foregroundStyle(Ink.inkSoft)
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
    }

    @ViewBuilder
    private var servicePicker: some View {
        if preset == nil {
            SetupServiceList(endpoints: team.settings.endpoints, choiceID: choice.id, onSelect: selectService)
        }

        if choice.addresses.count > 1 {
            VStack(alignment: .leading, spacing: Ink.Space.s) {
                FieldTitle(text: L.t("settings.chooseAddress"), note: "账号在哪边注册的就选哪边，密钥不通用")
                SlidingCapsuleControl(
                    selection: Binding(get: { region }, set: { next in
                        guard next != region else { return }
                        draft.key = ""
                        clearCatalog()
                        region = next
                    }),
                    options: Array(choice.addresses.indices)
                ) { index in
                    choice.addresses[index].label
                }
                .accessibilityLabel("地址")
            }
            .transition(.opacity)
        }

        if custom {
            SetupCustomAddressFields(draft: draft, choice: choice)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }

        if custom || choice.asksModel {
            SetupModelNameField(
                draft: draft,
                note: choice.asksModel ? "这家要你自己填" : "可以不填，会自动去拿列表",
                placeholder: choice.modelHint ?? "比如 gpt-5、qwen-plus"
            )
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var adviceCard: some View {
        if let advice {
            VStack(alignment: .leading, spacing: Ink.Space.xs) {
                Label(advice.displayTitle, systemImage: "exclamationmark.triangle")
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

    @ViewBuilder
    private var modelPicker: some View {
        if fetching {
            HStack(spacing: Ink.Space.s) {
                ProgressView()
                Text(L.t("loading.fetchingModels")).font(Ink.footnote).foregroundStyle(Ink.inkSoft)
            }
        } else if let fetched {
            SetupModelCatalogCard(
                fetched: fetched,
                fetchedWindows: fetchedWindows,
                picked: $picked
            )
            .transition(.opacity)
        } else if let fetchNote {
            VStack(alignment: .leading, spacing: Ink.Space.s) {
                Text(fetchNote).font(Ink.footnote).foregroundStyle(Ink.inkSoft)
                if fetchFailed && !(custom || choice.asksModel) {
                    SetupFallbackModelNameField(
                        draft: draft,
                        placeholder: choice.modelHint ?? "手动填一个模型名，比如 \(choice.suggested.first ?? "gpt-5")"
                    )
                }
            }
        }
    }

    private var helpURL: URL? { choice.keyPage.flatMap { URL(string: $0) } }

    private var address: String { draft.address(for: choice, region: region) }

    private func selectService(_ item: Service) {
        guard item.id != choice.id else { return }
        Haptics.tick(0.6)
        withAnimation(Ink.Motion.settle) {
            draft.key = ""
            draft.modelName = ""
            choice = item
            region = 0
            clearCatalog()
        }
    }

    private func clearCatalog() {
        advice = nil
        fetched = nil
        fetchedImageModels = nil
        fetchedWindows = [:]
        picked = []
        fetching = false
        fetchNote = nil
        fetchFailed = false
    }

    // MARK: Done

    private var done: some View {
        VStack(alignment: .leading, spacing: Ink.Space.xl) {
            Spacer(minLength: 0)
            PetStill(size: introArtSide * 0.58, state: "working")
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
                Text(first ? Words.t("去案头，见见旅伴") : L.t("actions.done"))
                    .font(.system(size: Ink.Size.body, weight: .semibold))
                    .foregroundStyle(Ink.paper)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Ink.accent, in: .capsule)
            }
            .buttonStyle(PressStyle(haptic: false))
        }
        .padding(.horizontal, Ink.Space.xl)
        .padding(.vertical, Ink.Space.xl)
    }

    // MARK: Connecting

    private func connect() {
        let secret = draft.secret(keyless: choice.keyless)
        let typed = draft.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let given = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let service = custom ? nil : choice
        let draftEndpoint = ServiceOnboardingEngine.endpoint(for: choice, address: address, name: given, in: team)
        let fetched = self.fetched
        let picked = self.picked
        let imageModels = fetchedImageModels
        let windows = fetchedWindows
        busy = true
        advice = nil
        keyFocused = false

        saveTask = Task {
            defer { busy = false }
            do {
                var endpoint = draftEndpoint
                if let fetched, !picked.isEmpty {
                    endpoint.listed = fetched
                    endpoint.imageModels = imageModels
                    endpoint.windows = windows.isEmpty ? nil : windows
                    endpoint.models = fetched.filter(picked.contains)
                    if !typed.isEmpty, !endpoint.models.contains(typed) { endpoint.models.insert(typed, at: 0) }
                } else {
                    endpoint = try await ServiceOnboardingEngine.discover(endpoint, secret: secret, typed: typed, service: service)
                }
                try await ServiceOnboardingEngine.save(endpoint, secret: secret, in: team)
                guard !Task.isCancelled else { return }
                draft.key = ""
                connected = endpoint
                Haptics.thud()
                if preset == nil { step = .done } else { onDone() }
            } catch {
                if !Task.isCancelled { fail(error, service: draftEndpoint.name) }
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

}

/// Shared by first-launch setup, manual service addition, and browser authorization.
@MainActor
enum ServiceOnboardingEngine {
    private static var session: URLSession { NetworkRuntime.shared.session(for: .default, ephemeral: true) }

    private static func isGo(_ endpoint: Endpoint) -> Bool {
        guard Service.of(endpoint)?.id == "opencode-go", let preset = Service.byID["opencode-go"] else { return false }
        return endpoint.baseURL == preset.baseURL
    }

    private static func verifyGoKey(for endpoint: Endpoint, secret: String) async throws {
        guard let source = Balance.source(baseURL: endpoint.baseURL) else {
            throw TeamError(message: L.t("services.goKeyRejected"))
        }
        var request = URLRequest(url: source.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue(source.authorizationValue(for: secret), forHTTPHeaderField: "Authorization")
        request.httpShouldHandleCookies = false
        let (_, response) = try await session.data(for: request, delegate: OAuthRedirectGuard())
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw TeamError(message: L.t("services.goKeyRejected"))
        }
    }

    static func endpoint(for choice: Service, address: String, name: String, in team: TeamModel) -> Endpoint {
        let id = choice.custom || team.settings.endpoints.contains(where: { $0.id == choice.id })
            ? "\(choice.custom ? "custom" : choice.id)-\(UUID().uuidString.lowercased())" : choice.id
        var title = choice.custom ? (name.isEmpty ? (URL(string: address)?.host ?? L.t("services.customName")) : name) : choice.name
        if team.settings.endpoints.contains(where: { $0.name == title }) { title += " 2" }
        return Endpoint(id: id, name: title, kind: choice.kind, baseURL: address, models: [], service: choice.custom ? nil : choice.id)
    }

    static func loadCatalog(for endpoint: Endpoint, secret: String) async throws -> (ids: [String], windows: [String: Int]) {
        if isGo(endpoint) {
            let url = URL(string: "https://opencode.ai/inference/go/v1/models")!
            let (data, response) = try await session.data(from: url, delegate: OAuthRedirectGuard())
            struct Catalog: Decodable {
                struct Item: Decodable { let id: String }
                let data: [Item]
            }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw TeamError(message: L.t("services.catalogUnavailable"))
            }
            let catalog = try JSONDecoder().decode(Catalog.self, from: data)
            return (catalog.data.map(\.id), [:])
        }
        let provider = endpoint.provider(key: secret)
        if let catalogProvider = provider as? CatalogReportingProvider {
            let catalog = try await catalogProvider.catalog()
            return (catalog.ids, catalog.windows)
        }
        return (try await provider.models(), [:])
    }

    static func discover(_ draft: Endpoint, secret: String, typed: String, service: Service?) async throws -> Endpoint {
        var endpoint = draft
        do {
            let result = try await loadCatalog(for: endpoint, secret: secret)
            let listed = TeamModel.keep(result.ids, for: endpoint)
            if endpoint.kind.supportsImages { endpoint.imageModels = result.ids }
            endpoint.windows = result.windows.isEmpty ? nil : result.windows
            var models = TeamModel.firstPicks(listed, service: service)
            if !typed.isEmpty { models = [typed] + models.filter { $0 != typed } }
            guard !models.isEmpty else { throw TeamError(message: L.t("services.catalogEmpty")) }
            endpoint.listed = listed
            endpoint.models = models
        } catch {
            try Task.checkCancellation()
            let fallback = typed.isEmpty ? (service?.suggested ?? []) : [typed]
            let status = (error as? ProviderError)?.status
            guard let first = fallback.first, status != 401, status != 403 else { throw error }
            var ask = Agent(provider: endpoint.provider(key: secret), model: first, system: "")
            ask.thinking = .off
            _ = try await ask.ask("回一个字：好")
            endpoint.models = fallback
        }
        return endpoint
    }

    static func save(_ endpoint: Endpoint, secret: String, in team: TeamModel) async throws {
        if isGo(endpoint) { try await verifyGoKey(for: endpoint, secret: secret) }
        try Task.checkCancellation()
        await team.addEndpointAsync(endpoint, key: secret)
    }
}

private struct SetupServiceList: View {
    let endpoints: [Endpoint]
    let choiceID: String
    let onSelect: (Service) -> Void

    var body: some View {
        let addedServices = Set(endpoints.compactMap(\.service))
        let firstID = Service.catalog.first?.id
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            FieldTitle(text: L.t("settings.chooseProvider"), note: "都能用自己的密钥直连。不在里面的，选最后的「自定义」")
            // One list, top to bottom, like every other list in Clio.
            VStack(spacing: 0) {
                ForEach(Service.catalog) { item in
                    if item.id != firstID { Kit.divider }
                    tile(item, added: !item.custom && addedServices.contains(item.id))
                }
            }
            .paperCard()
        }
    }

    private func tile(_ item: Service, added: Bool) -> some View {
        let selected = item.id == choiceID
        return Button {
            onSelect(item)
        } label: {
            HStack(spacing: Ink.Space.m) {
                ServiceIcon(service: item, size: Kit.badge)
                VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
                    HStack(spacing: Ink.Space.s) {
                        Text(item.name).font(.system(size: Ink.Size.body, weight: .medium)).foregroundStyle(Ink.ink).lineLimit(1)
                        if added { Text("已接").font(.system(size: Ink.Size.micro, weight: .medium)).foregroundStyle(Ink.ok) }
                    }
                    Text(item.note).font(.system(size: Ink.Size.small)).foregroundStyle(Ink.inkSoft).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: Ink.Size.title))
                    .foregroundStyle(selected ? Ink.accent : Ink.rule)
            }
            .padding(.horizontal, Ink.Space.l)
            .frame(minHeight: Kit.rowHeight + Ink.Space.s)
            .background(selected ? Ink.accentWash.opacity(0.5) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(haptic: false))
        .accessibilityLabel("\(item.name)：\(item.note)" + (added ? "，已接过" : ""))
    }
}

private struct SetupCustomAddressFields: View {
    @Bindable var draft: SetupDraft
    let choice: Service

    private var address: String {
        draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var finalURL: String {
        var base = address
        while base.hasSuffix("/") { base.removeLast() }
        return base + choice.kind.defaultRoutePath
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            FieldTitle(
                text: L.t("settings.serviceAddress"),
                note: choice.keyless
                    ? "电脑的局域网地址加端口：Ollama 是 http://电脑IP:11434/v1，LM Studio 是 http://电脑IP:1234/v1。Ollama 要先设 OLLAMA_HOST=0.0.0.0 才让手机连"
                    : choice.kind.addressHint
            )
            TextField(choice.keyless ? "称呼，比如 我的 4090" : "称呼，比如 我的中转站", text: $draft.name)
                .paperField()
            TextField(choice.keyless ? "http://192.168.1.10:11434/v1" : "https://…", text: $draft.baseURL)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .paperField()
            if draft.baseURL.hasPrefix("http") {
                Text("实际请求：" + finalURL)
                    .font(Ink.mono(Ink.Size.small)).foregroundStyle(Ink.inkFaint)
                    .padding(.leading, Ink.Space.xs)
            }
        }
    }
}

private struct SetupModelNameField: View {
    @Bindable var draft: SetupDraft
    let note: String
    let placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            FieldTitle(text: L.t("settings.modelName"), note: note)
            TextField(placeholder, text: $draft.modelName)
                .font(Ink.mono(Ink.Size.sub))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .paperField()
        }
    }
}

private struct SetupFallbackModelNameField: View {
    @Bindable var draft: SetupDraft
    let placeholder: String

    var body: some View {
        TextField(placeholder, text: $draft.modelName)
            .font(Ink.mono(Ink.Size.sub))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .paperField()
    }
}

private struct SetupKeyField: View {
    @Bindable var draft: SetupDraft
    let choice: Service
    var keyFocused: FocusState<Bool>.Binding
    let helpURL: URL?
    let openHelpURL: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            HStack {
                FieldTitle(text: L.t("settings.apiKey"), note: choice.keyless ? "本地的一般不用，空着就行" : "只存在这台手机的钥匙串里")
                Spacer()
                if let helpURL {
                    Button("去哪拿？") { openHelpURL(helpURL) }
                        .font(.system(size: Ink.Size.small, weight: .semibold))
                        .foregroundStyle(Ink.accent)
                }
            }
            HStack(spacing: Ink.Space.s) {
                SecureField("sk-…", text: $draft.key)
                    .font(Ink.mono(Ink.Size.body))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused(keyFocused)
                Button {
                    if let pasted = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !pasted.isEmpty {
                        draft.key = pasted
                        Haptics.tick(0.5)
                    }
                } label: {
                    Text("粘贴").font(.system(size: Ink.Size.small, weight: .semibold)).foregroundStyle(Ink.accent)
                }
            }
            .paperField()
        }
    }
}

private struct SetupModelCatalogCard: View {
    let fetched: [String]
    let fetchedWindows: [String: Int]
    @Binding var picked: Set<String>
    @State private var modelSearch = ""

    var body: some View {
        let words = modelSearch.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = Array((words.isEmpty ? fetched : fetched.filter { $0.lowercased().contains(words) }).prefix(60))
        return VStack(alignment: .leading, spacing: Ink.Space.s) {
            FieldTitle(text: L.t("settings.chooseModels"), note: "共 \(fetched.count) 个，已选 \(picked.count) 个")
            VStack(spacing: 0) {
                if fetched.count > 10 {
                    TextField("搜模型名", text: $modelSearch)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .padding(Ink.Space.m)
                    Rectangle().fill(Ink.rule).frame(height: 1)
                }
                LazyVStack(spacing: 0) {
                    ForEach(shown, id: \.self) { model in
                        let on = picked.contains(model)
                        Button {
                            Haptics.tick(0.4)
                            if on { picked.remove(model) } else { picked.insert(model) }
                        } label: {
                            HStack(spacing: Ink.Space.m) {
                                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(on ? Ink.accent : Ink.inkFaint)
                                VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
                                    Text(model).font(Ink.mono(Ink.Size.sub)).foregroundStyle(Ink.ink).lineLimit(1)
                                    Text(traitsSummary(for: model)).font(.system(size: Ink.Size.micro)).foregroundStyle(Ink.inkFaint)
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
            }
            .paperCard()
        }
    }

    private func traitsSummary(for model: String) -> String {
        var traits = ModelTraits.known(model)
        if let reported = fetchedWindows[model] { traits.window = reported }
        return traits.summary
    }
}

private struct SetupConnectButton: View {
    let draft: SetupDraft
    let choice: Service
    let fetched: [String]?
    let pickedCount: Int
    let busy: Bool
    let connect: () -> Void

    private var canConnect: Bool {
        guard !busy, !draft.secret(keyless: choice.keyless).isEmpty else { return false }
        if choice.custom, !draft.baseURL.hasPrefix("http") { return false }
        if let fetched, !fetched.isEmpty { return pickedCount > 0 }
        if choice.asksModel, draft.modelName.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        return true
    }

    var body: some View {
        Button(action: connect) {
            HStack(spacing: Ink.Space.s) {
                if busy { ProgressView().tint(Ink.paper) }
                Text(busy ? L.t("loading.connectingModel") : (fetched != nil ? "接上，用这 \(pickedCount) 个模型" : "连上试试"))
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
}

private struct SetupFetchDriver: View {
    struct Result {
        var fetched: [String]?
        var imageModels: [String]?
        var windows: [String: Int]
        var picked: Set<String>?
        var note: String?
        var failed: Bool
    }

    let draft: SetupDraft
    let choice: Service
    let region: Int
    let loadCatalog: (Endpoint, String) async throws -> (ids: [String], windows: [String: Int])
    let onFetching: (Bool) -> Void
    let onResult: (Result) -> Void

    private var address: String { draft.address(for: choice, region: region) }
    private var secret: String { draft.secret(keyless: choice.keyless) }
    private var fetchKey: String { "\(choice.id)|\(address)|\(draft.key.trimmingCharacters(in: .whitespacesAndNewlines))" }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task(id: fetchKey) { await run() }
    }

    private func run() async {
        let secret = self.secret
        let address = self.address
        guard secret.count >= 8 || choice.keyless, address.hasPrefix("http") else {
            onFetching(false)
            onResult(Result(fetched: nil, imageModels: nil, windows: [:], picked: nil, note: nil, failed: false))
            return
        }
        try? await Task.sleep(nanoseconds: 700_000_000)
        guard !Task.isCancelled else { return }
        onFetching(true)
        onResult(Result(fetched: nil, imageModels: nil, windows: [:], picked: nil, note: nil, failed: false))
        let probe = Endpoint(id: "probe", name: choice.name, kind: choice.kind, baseURL: address, models: [], service: choice.custom ? nil : choice.id)
        do {
            let result = try await loadCatalog(probe, secret)
            let listed = TeamModel.keep(result.ids, for: probe)
            guard !Task.isCancelled else { return }
            let imageModels = probe.kind.supportsImages ? result.ids : nil
            if listed.isEmpty {
                onResult(Result(
                    fetched: nil,
                    imageModels: imageModels,
                    windows: result.windows,
                    picked: nil,
                    note: "连上了，但它没给模型列表，下面填个模型名就行",
                    failed: true
                ))
            } else {
                onResult(Result(
                    fetched: listed,
                    imageModels: imageModels,
                    windows: result.windows,
                    picked: Set(TeamModel.firstPicks(listed, service: choice.custom ? nil : choice)),
                    note: nil,
                    failed: false
                ))
            }
        } catch {
            guard !Task.isCancelled else { return }
            let advice = Explain.model(error, service: choice.name)
            onResult(Result(
                fetched: nil,
                imageModels: nil,
                windows: [:],
                picked: nil,
                note: "拿不到模型列表：\(advice.displayTitle)\n也可以直接填模型名。",
                failed: true
            ))
        }
        onFetching(false)
    }
}
