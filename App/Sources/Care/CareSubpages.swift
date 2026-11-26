import AgentKit
import Craft
import SwiftUI

/// Global usage summary, per-chat token breakdown, and balance status pushed from Settings › Data & Care.
struct CareUsagePage: View {
    @ObservedObject var team: TeamModel
    @State private var spendRows: [ChatSpendRow] = []
    @State private var totalSpend = Spend()
    @State private var loadingSpend = true
    @State private var readings: [String: Balance.Reading] = [:]
    @State private var loadingBalances: Set<String> = []
    @State private var balanceErrors: [String: String] = [:]

    private struct ChatSpendRow: Identifiable, Sendable {
        let id: String
        let name: String
        let spend: Spend
    }

    private struct OptionsPayload: Decodable, Sendable {
        var spend: Spend?
    }

    private var balanceEndpoints: [(endpoint: Endpoint, source: Balance.Source)] {
        team.settings.endpoints.compactMap { endpoint in
            guard let source = Balance.source(baseURL: endpoint.baseURL) else { return nil }
            return (endpoint, source)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Ink.Space.xl) {
                summarySection
                perChatSection
                if !balanceEndpoints.isEmpty {
                    balancesSection
                }
            }
            .padding(.horizontal, Ink.Space.page)
            .padding(.vertical, Ink.Space.l)
        }
        .background(Ink.paper.ignoresSafeArea())
        .hitchPage("全量用量")
        .navigationTitle(L.t("settingsHome.careUsage"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadAllSpend()
        }
        .task(id: team.settings.endpoints) {
            await loadAllBalances()
        }
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle(L.t("careUsage.summaryTitle"))
            VStack(alignment: .leading, spacing: Ink.Space.m) {
                if loadingSpend && spendRows.isEmpty && totalSpend.turns == 0 {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 56)
                } else {
                    HStack(alignment: .top, spacing: 0) {
                        stat(Tokens.short(totalSpend.input), L.t("careUsage.inputTokens"))
                        stat(Tokens.short(totalSpend.output), L.t("careUsage.outputTokens"))
                        stat("\(Int((totalSpend.cacheShare * 100).rounded()))%", L.t("careUsage.cacheRate"))
                    }
                    Text(L.format("careUsage.turnsCount", totalSpend.turns))
                        .font(Ink.footnote)
                        .foregroundStyle(Ink.inkFaint)
                }
            }
            .padding(Ink.Space.l)
            .paperCard()
        }
    }

    private var perChatSection: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle(L.t("careUsage.perChatTitle"))
            VStack(alignment: .leading, spacing: Ink.Space.s) {
                if !loadingSpend && spendRows.isEmpty {
                    Text(L.t("careUsage.noUsageYet"))
                        .font(Ink.secondary)
                        .foregroundStyle(Ink.inkSoft)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    let grandTotal = max(1, spendRows.reduce(0) { $0 + $1.spend.input + $1.spend.output })
                    ForEach(spendRows.prefix(12)) { item in
                        let used = item.spend.input + item.spend.output
                        HStack(spacing: Ink.Space.s) {
                            Text(item.name)
                                .font(.system(size: Ink.Size.sub))
                                .foregroundStyle(Ink.ink)
                                .lineLimit(1)
                                .frame(width: 84 * UIScale.factor, alignment: .leading)
                            GeometryReader { box in
                                Capsule()
                                    .fill(Ink.accent.opacity(0.72))
                                    .frame(width: max(4, box.size.width * CGFloat(used) / CGFloat(grandTotal)))
                            }
                            .frame(height: 8)
                            Text(Tokens.short(used))
                                .font(.system(size: Ink.Size.small).monospacedDigit())
                                .foregroundStyle(Ink.inkSoft)
                                .frame(width: 56 * UIScale.factor, alignment: .trailing)
                        }
                    }
                }
            }
            .padding(Ink.Space.l)
            .paperCard()
        }
    }

    private var balancesSection: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle(L.t("careUsage.balancesTitle"))
            VStack(spacing: 0) {
                let items = balanceEndpoints
                ForEach(items, id: \.endpoint.id) { item in
                    balanceRow(item.endpoint, source: item.source)
                    if item.endpoint.id != items.last?.endpoint.id {
                        Kit.divider
                    }
                }
            }
            .paperCard()
        }
    }

    private func balanceRow(_ endpoint: Endpoint, source: Balance.Source) -> some View {
        HStack(alignment: .center, spacing: Ink.Space.m) {
            ServiceIcon(service: Service.of(endpoint), size: Kit.badge, name: endpoint.name)
            VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
                Text(endpoint.name)
                    .font(.system(size: Ink.Size.body))
                    .foregroundStyle(Ink.ink)
                if loadingBalances.contains(endpoint.id) {
                    ProgressView()
                        .controlSize(.small)
                } else if let reading = readings[endpoint.id] {
                    Text(reading.shown)
                        .font(.system(size: Ink.Size.sub, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Ink.ink)
                    if let detail = reading.detail {
                        Text(detail)
                            .font(Ink.footnote)
                            .foregroundStyle(Ink.inkSoft)
                    }
                } else if let error = balanceErrors[endpoint.id] {
                    Text(error)
                        .font(Ink.footnote)
                        .foregroundStyle(Ink.stop)
                        .lineLimit(2)
                } else {
                    Text(L.t("careUsage.unmeasured"))
                        .font(Ink.footnote)
                        .foregroundStyle(Ink.inkFaint)
                }
            }
            Spacer(minLength: Ink.Space.s)
            Link(L.t("careUsage.topUp"), destination: source.topUp)
                .font(.system(size: Ink.Size.small, weight: .medium))
                .foregroundStyle(Ink.accent)
        }
        .padding(.horizontal, Ink.Space.l)
        .padding(.vertical, Ink.Space.m)
        .contentShape(Rectangle())
        .onTapGesture {
            Task { await refreshBalance(endpoint) }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
            Text(value)
                .font(Ink.serif(Ink.Size.title, bold: true))
                .foregroundStyle(Ink.ink)
                .monospacedDigit()
            Text(label)
                .font(Ink.footnote)
                .foregroundStyle(Ink.inkSoft)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func loadAllSpend() async {
        loadingSpend = true
        let keeping = team.keeping
        let keys = team.bots.map { TeamModel.key(bot: $0.id) } + team.rooms.map { TeamModel.key(room: $0.id) }
        var cachedByKey: [String: Spend] = [:]
        var namesByKey: [String: String] = [:]
        var jobs: [(key: String, url: URL)] = []

        for chatKey in keys {
            namesByKey[chatKey] = team.chatName(chatKey)
            if let cached = team.optionBook[chatKey] {
                if let spend = cached.spend {
                    cachedByKey[chatKey] = spend
                }
            } else if keeping {
                jobs.append((chatKey, Disk.url(TeamModel.optionsFile(chatKey))))
            }
        }

        let loaded = await Task.detached(priority: .userInitiated) { () -> [String: Spend] in
            var diskSpend: [String: Spend] = [:]
            for job in jobs {
                if Task.isCancelled { break }
                guard let data = try? Data(contentsOf: job.url),
                      let payload = try? JSONDecoder().decode(OptionsPayload.self, from: data),
                      let spend = payload.spend else { continue }
                diskSpend[job.key] = spend
            }
            return diskSpend
        }.value

        guard !Task.isCancelled else { return }

        var aggregate = Spend()
        var rows: [ChatSpendRow] = []
        for chatKey in keys {
            guard let spend = cachedByKey[chatKey] ?? loaded[chatKey] else { continue }
            aggregate.input += spend.input
            aggregate.output += spend.output
            aggregate.cached += spend.cached
            aggregate.turns += spend.turns
            if spend.input + spend.output > 0 {
                rows.append(ChatSpendRow(id: chatKey, name: namesByKey[chatKey] ?? chatKey, spend: spend))
            }
        }
        rows.sort { $0.spend.input + $0.spend.output > $1.spend.input + $1.spend.output }
        totalSpend = aggregate
        spendRows = rows
        loadingSpend = false
    }

    private func loadAllBalances() async {
        for item in balanceEndpoints {
            await refreshBalance(item.endpoint)
        }
    }

    private func refreshBalance(_ endpoint: Endpoint) async {
        guard !loadingBalances.contains(endpoint.id) else { return }
        loadingBalances.insert(endpoint.id)
        balanceErrors.removeValue(forKey: endpoint.id)
        do {
            let result = try await team.balance(endpoint)
            if !Task.isCancelled {
                readings[endpoint.id] = result
            }
        } catch {
            if !Task.isCancelled {
                balanceErrors[endpoint.id] = error.localizedDescription
            }
        }
        loadingBalances.remove(endpoint.id)
    }
}

/// Standalone About Clio page pushed as the "+1" tail group of the 8+1 Settings hierarchy.
struct CareAboutPage: View {
    @AppStorage("care.spikeLab") private var spikeLab = false
    @State private var tapCount = 0
    @State private var lastTapAt = Date.distantPast
    @State private var notice: String?

    private var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    private var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Ink.Space.xl) {
                identityHeader
                detailsCard
                creditsCard
            }
            .padding(.horizontal, Ink.Space.page)
            .padding(.vertical, Ink.Space.l)
        }
        .background(Ink.paper.ignoresSafeArea())
        .hitchPage("关于")
        .navigationTitle(L.t("settingsHome.aboutClio"))
        .navigationBarTitleDisplayMode(.inline)
        .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button(L.t("actions.done"), role: .cancel) { notice = nil }
        }
    }

    private var identityHeader: some View {
        VStack(spacing: Ink.Space.s) {
            HStack(spacing: Ink.Space.s) {
                Text("Clio")
                    .font(Ink.wordmark((36 * UIScale.factor).rounded()))
                    .foregroundStyle(Ink.ink)
                ClioSeal(size: (22 * UIScale.factor).rounded())
            }
            Text("\(shortVersion) (\(buildNumber))")
                .font(Ink.mono(Ink.Size.small))
                .foregroundStyle(Ink.inkFaint)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Ink.Space.l)
        .paperCard()
        .contentShape(Rectangle())
        .onTapGesture { handleVersionTap() }
    }

    private var detailsCard: some View {
        VStack(spacing: 0) {
            infoRow(L.t("settingsHome.aboutVersion"), "\(shortVersion) (\(buildNumber))")
            Kit.divider
            infoRow(L.t("settingsHome.aboutLicense"), "GNU GPL-3.0")
            Kit.divider
            HStack {
                Text(L.t("settingsHome.aboutRepo"))
                    .foregroundStyle(Ink.ink)
                Spacer()
                Link("github.com/lllhr94/Clio", destination: URL(string: "https://github.com/lllhr94/Clio")!)
                    .font(.system(size: Ink.Size.sub))
            }
            .padding(.horizontal, Ink.Space.l)
            .frame(minHeight: Kit.rowHeight)
        }
        .paperCard()
    }

    private var creditsCard: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle(L.t("settingsHome.aboutCreditsTitle"))
            Text(L.t("settingsHome.aboutOpenSource"))
                .font(Ink.secondary)
                .foregroundStyle(Ink.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Ink.Space.l)
                .paperCard()
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(Ink.ink)
            Spacer()
            Text(value)
                .font(.system(size: Ink.Size.sub))
                .foregroundStyle(Ink.inkSoft)
        }
        .padding(.horizontal, Ink.Space.l)
        .frame(minHeight: Kit.rowHeight)
    }

    private func handleVersionTap() {
        let now = Date()
        tapCount = now.timeIntervalSince(lastTapAt) > 1.5 ? 1 : (tapCount + 1)
        lastTapAt = now
        if tapCount >= 5 {
            tapCount = 0
            spikeLab.toggle()
            Haptics.tick(0.6)
            notice = spikeLab ? L.t("careSpike.labEnabled") : L.t("careSpike.labDisabled")
        }
    }
}
