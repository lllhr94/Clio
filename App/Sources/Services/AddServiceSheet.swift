import SwiftUI

struct AddServiceSheet: View {
    @ObservedObject var team: TeamModel
    let onDone: () -> Void

    @State private var category: Service.Category = .recommended
    @State private var detent: PresentationDetent = .medium
    @State private var preset: String?
    @State private var signInTask: Task<Void, Never>?
    @State private var signInNote: String?
    @State private var showsKimiOptions = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Ink.Space.m) {
                    SlidingCapsuleControl(selection: $category, options: Service.Category.allCases, compact: true) { item in
                        L.t(item.titleKey)
                    }
                    .disabled(signInTask != nil)
                    if category == .recommended { openRouterCard }
                    if category == .codingPlan { kimiCard }
                    presets
                    if category == .codingPlan { ExperimentalOAuthSection() }
                }
                .padding(.horizontal, Ink.Space.page)
                .padding(.vertical, Ink.Space.l)
            }
            .scrollEdgeEffectStyle(.soft, for: .vertical)
            .navigationTitle(L.t("settings.addService"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L.t("actions.cancel")) {
                        signInTask?.cancel()
                        onDone()
                    }
                }
            }
            .navigationDestination(item: $preset) { id in
                if let service = Service.byID[id] {
                    SetupView(team: team, preset: service, onDone: onDone)
                        .navigationTitle(service.name)
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
        .detentPaperBackdrop(detent: $detent)
        .onDisappear { signInTask?.cancel() }
    }

    private var presets: some View {
        let items = Service.catalog.filter { $0.category == category }
        return VStack(spacing: 0) {
            ForEach(items) { service in
                if service.id != items.first?.id { Kit.divider }
                Button {
                    choose(service)
                } label: {
                    RowLabel(title: service.name, line: service.note) {
                        ServiceIcon(service: service, size: Kit.badge)
                    }
                }
                .buttonStyle(PressStyle())
                .disabled(signInTask != nil)
            }
        }
        .paperCard()
    }

    private var openRouterCard: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            Button(action: signInOpenRouter) {
                RowLabel("person.badge.key", tint: Ink.Tile.accent, title: L.t("services.openRouterSignIn"),
                         line: L.t("services.openRouterSignInNote"))
            }
            .buttonStyle(PressStyle())
            .disabled(signInTask != nil)
            if signInTask != nil || signInNote != nil {
                HStack(spacing: Ink.Space.s) {
                    if signInTask != nil { ProgressView() }
                    Text(signInNote ?? L.t("loading.checking"))
                        .font(Ink.footnote).foregroundStyle(Ink.inkSoft)
                }
                .padding([.horizontal, .bottom], Ink.Space.l)
            }
        }
        .paperCard()
    }

    private var kimiCard: some View {
        VStack(alignment: .leading, spacing: Ink.Space.m) {
            DisclosureGroup(isExpanded: $showsKimiOptions) {
                VStack(alignment: .leading, spacing: Ink.Space.m) {
                    Text(L.t("services.kimiDeviceUnavailable"))
                        .font(Ink.footnote).foregroundStyle(Ink.inkSoft)
                    Button(L.t("services.useAPIKey")) {
                        if let service = Service.byID["kimi-code"] { choose(service) }
                    }
                    .buttonStyle(WideButtonStyle(filled: false))
                }
                .padding(.top, Ink.Space.m)
            } label: {
                Text(L.t("services.kimiDeviceSignIn"))
                    .font(Ink.label).foregroundStyle(Ink.ink)
            }
            .tint(Ink.accent)
        }
        .padding(Ink.Space.l)
        .paperCard()
    }

    private func choose(_ service: Service) {
        detent = .large
        preset = service.id
    }

    private func signInOpenRouter() {
        guard signInTask == nil, let service = Service.byID["openrouter"] else { return }
        signInNote = nil
        signInTask = Task {
            defer { signInTask = nil }
            do {
                let key = try await OpenRouterKeyOAuth.authorize()
                let draft = ServiceOnboardingEngine.endpoint(for: service, address: service.baseURL, name: "", in: team)
                let endpoint = try await ServiceOnboardingEngine.discover(draft, secret: key, typed: "", service: service)
                try await ServiceOnboardingEngine.save(endpoint, secret: key, in: team)
                if !Task.isCancelled { onDone() }
            } catch is CancellationError {
                return
            } catch {
                if !Task.isCancelled { signInNote = L.t("services.oauthFailed") }
            }
        }
    }
}

private extension Service.Category {
    var titleKey: String {
        switch self {
        case .recommended: return "services.recommended"
        case .codingPlan: return "services.codingPlans"
        case .customAndLocal: return "services.customAndLocal"
        }
    }
}
