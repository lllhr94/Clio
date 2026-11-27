import Craft
import SwiftUI

/// 用量: how full the next request's context is, what this conversation has used, and what is left on the service's account.
struct UsageSheet: View {
    @ObservedObject var team: TeamModel
    let key: String
    @Environment(\.dismiss) private var dismiss
    @State private var estimate: TeamModel.ContextEstimate?
    @State private var reading: Balance.Reading?
    @State private var balanceProblem: String?
    @State private var loadingBalance = false
    @State private var floor: Double = 0
    @State private var folding = false
    @State private var note: String?
    @State private var currentSpend = Spend()
    @State private var allSpendRows: [(name: String, spend: Spend)] = []

    private var endpoint: Endpoint? { team.chatEndpoint(key) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Ink.Space.s) {
                    heading("上下文")
                    contextCard
                    NavigationLink {
                        ModelInputPage(team: team, chat: key)
                    } label: {
                        RowLabel("doc.text.magnifyingglass", title: L.t("modelInput.open"))
                    }
                    .buttonStyle(TapStyle())
                    .paperCard()
                    heading("本对话").padding(.top, Ink.Space.m)
                    spendCard
                    allCard
                    if let endpoint, let source = Balance.source(baseURL: endpoint.baseURL) {
                        heading("\(endpoint.name) 余额").padding(.top, Ink.Space.m)
                        balanceCard(endpoint, source: source)
                    }
                }
                .padding(.horizontal, Ink.Space.page)
                .padding(.vertical, Ink.Space.l)
            }
            .navigationTitle(L.t("settings.usage"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L.t("actions.done")) { dismiss() } } }
        }
        .hitchPage("用量")
        .task {
            async let spendTask: Void = loadSpendBreakdown()
            async let estimateTask: TeamModel.ContextEstimate = team.contextEstimate(key)
            if let endpoint { floor = TeamModel.balanceFloor(endpoint.id) }
            async let balanceTask: Void = loadBalance()
            estimate = await estimateTask
            await spendTask
            await balanceTask
        }
    }

    private func heading(_ text: String) -> some View {
        SectionTitle(text)
    }

    // MARK: 上下文

    private var contextCard: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            Text("预计下次请求").font(Ink.footnote).foregroundStyle(Ink.inkSoft)
            if let estimate {
                HStack(alignment: .firstTextBaseline) {
                    Text(Self.percent(estimate.share))
                        .font(Ink.serif(Ink.Size.title, bold: true))
                        .foregroundStyle(Ink.ink)
                        .monospacedDigit()
                        .contentTransition(.numericText(value: estimate.share))
                        .animation(Ink.Motion.quick, value: estimate.share)
                    Spacer()
                    Text("\(Tokens.short(estimate.total)) / \(Tokens.short(estimate.window))")
                        .font(.system(size: Ink.Size.sub, weight: .medium).monospacedDigit())
                        .foregroundStyle(Ink.inkSoft)
                        .contentTransition(.numericText(value: Double(estimate.total)))
                        .animation(Ink.Motion.quick, value: estimate.total)
                }
                ProgressView(value: min(1, estimate.share))
                    .tint(Self.color(estimate.share))
                Text("系统 \(Tokens.short(estimate.system)) · 工具 \(Tokens.short(estimate.tools)) · 消息 \(Tokens.short(estimate.messages))")
                    .font(.system(size: Ink.Size.small).monospacedDigit())
                    .foregroundStyle(Ink.inkSoft)
                    .contentTransition(.numericText(value: Double(estimate.total)))
                    .animation(Ink.Motion.quick, value: estimate.total)
                Text(explanation(estimate))
                    .font(Ink.footnote)
                    .foregroundStyle(Ink.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(folding ? L.t("loading.compactingContext") : L.t("chat.compactContext"), systemImage: "rectangle.compress.vertical") { fold() }
                        .font(.system(size: Ink.Size.sub, weight: .medium))
                        .foregroundStyle(Ink.accent)
                        .buttonStyle(TapStyle())
                        .disabled(folding)
                    Spacer()
                }
                .padding(.top, Ink.Space.xs)
                Button(L.t("chat.toolOutputsClean"), systemImage: "sparkles") { cleanToolOutputs() }
                    .font(.system(size: Ink.Size.sub, weight: .medium))
                    .foregroundStyle(Ink.accent)
                    .buttonStyle(TapStyle())
                    .disabled(folding || team.compressing.contains(key) || team.runs[key] != nil)
                if team.toolOutputUndo[key] != nil {
                    Button(L.t("chat.toolOutputsUndo")) {
                        _ = team.undoToolOutputCompaction(key)
                        Task { self.estimate = await team.contextEstimate(key) }
                    }
                    .font(Ink.footnote)
                    .buttonStyle(TapStyle())
                }
                if let problem = team.compressionFailures[key] {
                    Text(problem).font(Ink.footnote).foregroundStyle(Ink.warn)
                    Button(L.t("chat.compressionRetry")) { team.retryCompression(key) }
                        .font(Ink.footnote)
                        .buttonStyle(TapStyle())
                        .disabled(team.compressing.contains(key))
                }
                if let note {
                    Text(note).font(Ink.footnote).foregroundStyle(Ink.inkSoft)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 80)
            }
        }
        .padding(Ink.Space.l)
        .paperCard()
    }

    private func explanation(_ estimate: TeamModel.ContextEstimate) -> String {
        var words = "按字数估算：中文一个字约 0.6 token，其他字符约 0.3。分项各自估，加起来可能和总量略有出入。"
        words += "上限按 \(estimate.model.isEmpty ? "所用模型" : estimate.model) 的上下文长度算。"
        if currentSpend.lastInput > 0 { words += "上一次请求，服务方实际算的是 \(Tokens.short(currentSpend.lastInput))。" }
        return words
    }

    private func fold() {
        folding = true
        note = nil
        Task {
            do {
                let count = try await team.compress(key)
                note = Words.t("压好了：较早的 \(count) 条写成了前情提要，原文都还在对话里，往上翻就有。")
                Haptics.thud()
                estimate = await team.contextEstimate(key)
            } catch {
                note = error.localizedDescription
            }
            folding = false
        }
    }

    private func cleanToolOutputs() {
        let count = team.compactOldToolOutputs(key)
        note = count > 0 ? L.t("chat.toolOutputsCleaned") : L.t("chat.toolOutputsNothingToClean")
        Task { estimate = await team.contextEstimate(key) }
    }

    // MARK: 本对话

    private var spendCard: some View {
        VStack(alignment: .leading, spacing: Ink.Space.m) {
            HStack(alignment: .top, spacing: 0) {
                stat(Tokens.short(currentSpend.input), "累计输入", value: Double(currentSpend.input))
                stat(Tokens.short(currentSpend.output), "输出", value: Double(currentSpend.output))
                stat("\(Int((currentSpend.cacheShare * 100).rounded()))%", "缓存命中", value: currentSpend.cacheShare)
            }
            Text(currentSpend.turns == 0 && currentSpend.input == 0
                 ? Words.t("从 0.27 起开始记，这段絮语之后的每一轮都会算进来。")
                 : "共 \(currentSpend.turns) 轮 · 输入含缓存命中的部分，命中越多越省钱")
                .font(Ink.footnote)
                .foregroundStyle(Ink.inkFaint)
                .contentTransition(.numericText(value: Double(currentSpend.turns)))
                .animation(Ink.Motion.quick, value: currentSpend.turns)
        }
        .padding(Ink.Space.l)
        .paperCard()
    }

    private func stat(_ shown: String, _ label: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
            Text(shown)
                .font(Ink.serif(Ink.Size.title, bold: true))
                .foregroundStyle(Ink.ink)
                .monospacedDigit()
                .contentTransition(.numericText(value: value))
                .animation(Ink.Motion.quick, value: value)
            Text(label).font(Ink.footnote).foregroundStyle(Ink.inkSoft)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Every conversation's tokens side by side, to see where they go.
    @ViewBuilder
    private var allCard: some View {
        if allSpendRows.count > 1 {
            let total = allSpendRows.reduce(0) { $0 + $1.spend.input + $1.spend.output }
            VStack(alignment: .leading, spacing: Ink.Space.s) {
                Text("全部对话 · 共 \(Tokens.short(total))")
                    .font(Ink.footnote)
                    .foregroundStyle(Ink.inkSoft)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(total)))
                    .animation(Ink.Motion.quick, value: total)
                ForEach(Array(allSpendRows.prefix(8).enumerated()), id: \.offset) { _, item in
                    let used = item.spend.input + item.spend.output
                    HStack(spacing: Ink.Space.s) {
                        Text(item.name).font(.system(size: Ink.Size.sub)).foregroundStyle(Ink.ink).lineLimit(1).frame(width: 72, alignment: .leading)
                        GeometryReader { box in
                            Capsule().fill(Ink.accent.opacity(0.7))
                                .frame(width: max(4, box.size.width * CGFloat(used) / CGFloat(max(total, 1))))
                        }
                        .frame(height: 8)
                        Text(Tokens.short(used))
                            .font(.system(size: Ink.Size.small).monospacedDigit())
                            .foregroundStyle(Ink.inkSoft)
                            .contentTransition(.numericText(value: Double(used)))
                            .animation(Ink.Motion.quick, value: used)
                            .frame(width: 52, alignment: .trailing)
                    }
                }
            }
            .padding(Ink.Space.l)
            .paperCard()
        }
    }

    private struct SpendOptionsPayload: Decodable, Sendable {
        var spend: Spend?
    }

    private func loadSpendBreakdown() async {
        let keeping = team.keeping
        let targetKey = key
        let keys = team.bots.map { TeamModel.key(bot: $0.id) } + team.rooms.map { TeamModel.key(room: $0.id) }

        var cachedByKey: [String: Spend] = [:]
        var jobs: [(key: String, name: String, url: URL)] = []
        var namesByKey: [String: String] = [:]
        for chatKey in keys {
            let name = team.chatName(chatKey)
            namesByKey[chatKey] = name
            if let cached = team.optionBook[chatKey] {
                if let spend = cached.spend {
                    cachedByKey[chatKey] = spend
                }
            } else if keeping {
                jobs.append((chatKey, name, Disk.url(TeamModel.optionsFile(chatKey))))
            }
        }
        let needTargetFromDisk = team.optionBook[targetKey] == nil && keeping && !keys.contains(targetKey)
        let targetURL = Disk.url(TeamModel.optionsFile(targetKey))
        if let cachedTarget = team.optionBook[targetKey]?.spend {
            currentSpend = cachedTarget
        }

        let loaded = await Task.detached(priority: .userInitiated) { () -> (target: Spend?, rows: [(name: String, spend: Spend)]) in
            var diskSpend: [String: Spend] = [:]
            for job in jobs {
                if Task.isCancelled { break }
                guard let data = try? Data(contentsOf: job.url),
                      let payload = try? JSONDecoder().decode(SpendOptionsPayload.self, from: data),
                      let spend = payload.spend else { continue }
                diskSpend[job.key] = spend
            }
            let targetResolved: Spend?
            if needTargetFromDisk {
                if let data = try? Data(contentsOf: targetURL),
                   let payload = try? JSONDecoder().decode(SpendOptionsPayload.self, from: data) {
                    targetResolved = payload.spend
                } else {
                    targetResolved = nil
                }
            } else {
                targetResolved = cachedByKey[targetKey] ?? diskSpend[targetKey]
            }
            var combined: [(name: String, spend: Spend)] = []
            for chatKey in keys {
                guard let spend = cachedByKey[chatKey] ?? diskSpend[chatKey],
                      spend.input + spend.output > 0 else { continue }
                combined.append((name: namesByKey[chatKey] ?? "", spend: spend))
            }
            combined.sort { $0.spend.input + $0.spend.output > $1.spend.input + $1.spend.output }
            return (targetResolved, combined)
        }.value

        guard !Task.isCancelled else { return }
        if let target = loaded.target {
            currentSpend = target
        }
        allSpendRows = loaded.rows
    }

    // MARK: 余额

    private func balanceCard(_ endpoint: Endpoint, source: Balance.Source) -> some View {
        VStack(alignment: .leading, spacing: Ink.Space.m) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
                    if let reading {
                        Text(reading.shown)
                            .font(Ink.serif(Ink.Size.title, bold: true))
                            .foregroundStyle(floor > 0 && reading.amount < floor ? Ink.stop : Ink.ink)
                            .monospacedDigit()
                            .contentTransition(.numericText(value: reading.amount))
                            .animation(Ink.Motion.quick, value: reading.amount)
                        if let detail = reading.detail { Text(detail).font(Ink.footnote).foregroundStyle(Ink.inkSoft) }
                    } else if loadingBalance {
                        ProgressView()
                    } else {
                        Text(balanceProblem ?? "还没查").font(Ink.footnote).foregroundStyle(Ink.stop)
                        Button("再查一次") { Task { await loadBalance() } }
                            .font(.system(size: Ink.Size.small, weight: .medium))
                            .buttonStyle(TapStyle())
                    }
                }
                Spacer()
                Link(destination: source.topUp) {
                    Label("去充值", systemImage: "arrow.up.right")
                        .labelStyle(TrailingIcon())
                        .font(.system(size: Ink.Size.sub, weight: .medium))
                        .foregroundStyle(Ink.accent)
                }
            }
            Rectangle().fill(Ink.rule).frame(height: 1)
            StopRow(title: "低余额提醒", value: Stops.snapped($floor, to: [0.0, 1, 5, 10, 20, 50]),
                    stops: [0.0, 1, 5, 10, 20, 50].map { value in
                        Stop(value: value, name: value == 0 ? "不提醒" : "低于 \(reading?.symbol ?? "¥")\(Int(value))")
                    })
            .font(.system(size: Ink.Size.sub))
            Text("低于这条线就发通知，半天一次")
                .font(Ink.footnote)
                .foregroundStyle(Ink.inkFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Ink.Space.l)
        .paperCard()
        .onChange(of: floor) { _, value in TeamModel.setBalanceFloor(endpoint.id, value) }
    }

    private func loadBalance() async {
        guard let endpoint, Balance.source(baseURL: endpoint.baseURL) != nil else { return }
        loadingBalance = true
        balanceProblem = nil
        do {
            reading = try await team.balance(endpoint)
        } catch {
            balanceProblem = error.localizedDescription
        }
        loadingBalance = false
    }

    // MARK: Shared with the ring under the composer

    /// 「1%」; anything above nothing shows at least 1%.
    static func percent(_ share: Double) -> String {
        guard share > 0 else { return "0%" }
        return "\(max(1, Int((share * 100).rounded())))%"
    }

    static func color(_ share: Double) -> Color {
        share >= 0.8 ? Ink.stop : share >= 0.5 ? Ink.warn : Ink.accent
    }
}

/// Title first, then the icon: 「去充值 ↗」.
private struct TrailingIcon: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Ink.Space.xs) {
            configuration.title
            configuration.icon
        }
    }
}

/// How full the next request's context is, as a small ring by the send button. A tap opens 用量.
struct ContextRing: View {
    let share: Double
    var showsNumber = true

    var body: some View {
        HStack(spacing: Ink.Space.xs) {
            ZStack {
                Circle().stroke(Ink.rule.opacity(0.85), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: max(0.03, min(1, share)))
                    .stroke(UsageSheet.color(share), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 14, height: 14)
            if showsNumber {
                Text(UsageSheet.percent(share))
                    .font(.system(size: Ink.Size.micro, weight: .medium).monospacedDigit())
                    .foregroundStyle(Ink.inkSoft)
                    .contentTransition(.numericText(value: share))
                    .animation(Ink.Motion.quick, value: share)
                    .fixedSize()
            }
        }
        .frame(minWidth: 28, minHeight: 34)
        .contentShape(Rectangle())
    }
}
