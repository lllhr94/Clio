import Craft
import Foundation
import SwiftUI

struct ServicesHubPage: View {
    @ObservedObject var team: TeamModel
    let openAdd: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Ink.Space.m) {
                if team.phase == .demo {
                    Text(L.t("settings.demoData"))
                        .font(Ink.footnote).foregroundStyle(Ink.inkSoft)
                }
                if team.settings.endpoints.isEmpty {
                    Button(action: openAdd) {
                        RowLabel("plus", tint: Ink.Tile.dai, title: L.t("settings.addService"))
                    }
                    .buttonStyle(PressStyle())
                    .paperCard()
                }
                ForEach(team.settings.endpoints) { endpoint in
                    NavigationLink {
                        ServicePage(team: team, id: endpoint.id)
                    } label: {
                        card(endpoint)
                    }
                    .buttonStyle(PressStyle())
                }
            }
            .padding(.horizontal, Ink.Space.page)
            .padding(.vertical, Ink.Space.l)
        }
        .scrollEdgeEffectStyle(.soft, for: .vertical)
        .background(Ink.paper.ignoresSafeArea())
        .navigationTitle(L.t("settings.modelService"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Haptics.light()
                    openAdd()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L.t("settings.addService"))
            }
        }
    }

    private func card(_ endpoint: Endpoint) -> some View {
        VStack(alignment: .leading, spacing: Ink.Space.m) {
            HStack {
                ServiceArchiveHeader(endpoint: endpoint)
                Spacer(minLength: Ink.Space.s)
                Kit.chevron
            }
            ServiceBalanceLine(team: team, endpoint: endpoint)
            modelStamps(endpoint)
        }
        .padding(Ink.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperCard()
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func modelStamps(_ endpoint: Endpoint) -> some View {
        if endpoint.models.isEmpty {
            Text(L.t("services.noActiveModels"))
                .font(Ink.footnote).foregroundStyle(Ink.inkSoft)
        } else {
            let models = Array(endpoint.models.prefix(4))
            let overflow = endpoint.models.count - models.count
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Ink.Space.xs) {
                    ForEach(models, id: \.self) { model in
                        ServiceStamp(title: endpoint.distinguishableDisplayName(for: model))
                    }
                    if overflow > 0 { ServiceStamp(title: "+\(overflow)") }
                }
                VStack(alignment: .leading, spacing: Ink.Space.xs) {
                    ForEach(models, id: \.self) { model in
                        ServiceStamp(title: endpoint.distinguishableDisplayName(for: model))
                    }
                    if overflow > 0 { ServiceStamp(title: "+\(overflow)") }
                }
            }
        }
    }
}

struct ServiceArchiveHeader: View {
    let endpoint: Endpoint
    @AppStorage private var paused: Bool

    init(endpoint: Endpoint) {
        self.endpoint = endpoint
        _paused = AppStorage(wrappedValue: false, ServiceExtras.pauseKey(endpoint.id))
    }

    var body: some View {
        HStack(alignment: .center, spacing: Ink.Space.m) {
            ServiceIcon(service: Service.of(endpoint), size: 40 * UIScale.factor, name: endpoint.name)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Ink.Space.xs) {
                Text(endpoint.name)
                    .font(Ink.serif(Ink.Size.title, bold: true))
                    .foregroundStyle(Ink.ink)
                HStack(spacing: Ink.Space.s) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: Ink.Space.s, height: Ink.Space.s)
                        .accessibilityLabel(statusText)
                    ServiceStamp(title: endpoint.kind.displayTitle)
                    if paused { ServiceStamp(title: L.t("services.paused"), tint: Ink.warn) }
                }
            }
        }
    }

    private var statusColor: Color {
        if !endpoint.isActiveProtocol { return Ink.stop }
        if paused || endpoint.models.isEmpty { return Ink.warn }
        return Ink.ok
    }

    private var statusText: String {
        if !endpoint.isActiveProtocol { return L.t("services.inactive") }
        if paused { return L.t("services.paused") }
        return L.t(endpoint.models.isEmpty ? "services.noActiveModels" : "services.active")
    }
}

struct ServiceStamp: View {
    let title: String
    var tint: Color = Ink.inkSoft

    var body: some View {
        Text(title)
            .font(.system(size: Ink.Size.micro, weight: .medium))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, Ink.Space.s)
            .padding(.vertical, Ink.Space.xs)
            .background(Ink.mine, in: Capsule(style: .continuous))
    }
}

struct ServiceBalanceLine: View {
    @ObservedObject var team: TeamModel
    let endpoint: Endpoint
    var showsDashboard = false
    private static let session = URLSession(configuration: .ephemeral)
    @State private var reading: Balance.Reading?
    @State private var failed = false

    private var source: Balance.Source? { Balance.source(baseURL: endpoint.baseURL) }
    private var dashboard: URL? { Balance.dashboard(baseURL: endpoint.baseURL) }
    private var canLoad: Bool { team.phase != .demo && endpoint.isActiveProtocol && source != nil }

    var body: some View {
        if canLoad || (showsDashboard && dashboard != nil && team.phase != .demo) {
            HStack(alignment: .center, spacing: Ink.Space.m) {
                if canLoad {
                    VStack(alignment: .leading, spacing: Ink.Space.xs) {
                        if let reading {
                            Text(L.t(reading.symbol == "%" ? "services.quotaRemaining" : "settings.balance"))
                                .font(Ink.footnote).foregroundStyle(Ink.inkSoft)
                            Text(reading.shown).font(Ink.serif(Ink.Size.title, bold: true)).foregroundStyle(Ink.ink)
                            if showsDashboard, let detail = reading.detail {
                                Text(detail).font(Ink.footnote).foregroundStyle(Ink.inkSoft)
                            }
                        } else {
                            Text(L.t(failed ? "services.balanceUnavailable" : "services.balanceLoading"))
                                .font(Ink.footnote).foregroundStyle(Ink.inkSoft)
                        }
                    }
                }
                if showsDashboard, let dashboard {
                    Spacer(minLength: 0)
                    Link(L.t("services.accountDashboard"), destination: dashboard)
                        .font(Ink.label).foregroundStyle(Ink.accent)
                }
            }
            .task(id: endpoint.recipientIdentity) {
                reading = nil
                failed = false
                guard canLoad, let source else { return }
                do {
                    let value = try await read(source)
                    if !Task.isCancelled { reading = value }
                } catch {
                    if !Task.isCancelled { failed = true }
                }
            }
        }
    }

    private func read(_ source: Balance.Source) async throws -> Balance.Reading {
        guard let key = await team.readAPIKey(for: endpoint), !key.isEmpty,
              team.settings.endpoints.contains(where: { $0.id == endpoint.id && $0.recipientIdentity == endpoint.recipientIdentity }) else {
            throw URLError(.userAuthenticationRequired)
        }
        try Task.checkCancellation()
        var request = URLRequest(url: source.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpShouldHandleCookies = false
        request.setValue(source.authorizationValue(for: key), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await Self.session.data(for: request, delegate: OAuthRedirectGuard())
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let balance = Balance.parse(String(decoding: data, as: UTF8.self), baseURL: endpoint.baseURL) else {
            throw URLError(.cannotParseResponse)
        }
        return balance
    }
}
