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

    private var spend: Spend { team.options(key).spend ?? Spend() }
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
            .background(Ink.paper.ignoresSafeArea())
            .navigationTitle(L.t("settings.usage"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L.t("actions.done")) { dismiss() } } }
        }
        .hitchPage("用量")
        .task {
            estimate = await team.contextEstimate(key)
            if let endpoint { floor = TeamModel.balanceFloor(endpoint.id) }
            await loadBalance()
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
                    Text(Self.percent(estimate.share)).font(Ink.serif(Ink.Size.title, bold: true)).foregroundStyle(Ink.ink)
                    Spacer()
                    Text("\(Tokens.short(estimate.total)) / \(Tokens.short(estimate.window))")
                        .font(.system(size: Ink.Size.sub, weight: .medium).monospacedDigit())
                        .foregroundStyle(Ink.inkSoft)
                }
                ProgressView(value: min(1, estimate.share))
                    .tint(Self.color(estimate.share))
                Text("系统 \(Tokens.short(estimate.system)) · 工具 \(Tokens.short(estimate.tools)) · 消息 \(Tokens.short(estimate.messages))")
                    .font(.system(size: Ink.Size.small).monospacedDigit())
                    .foregroundStyle(Ink.inkSoft)
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
        if spend.lastInput > 0 { words += "上一次请求，服务方实际算的是 \(Tokens.short(spend.lastInput))。" }
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

    // MARK: 本对话

    private var spendCard: some View {
        VStack(alignment: .leading, spacing: Ink.Space.m) {
            HStack(alignment: .top, spacing: 0) {
                stat(Tokens.short(spend.input), "累计输入")
                stat(Tokens.short(spend.output), "输出")
                stat("\(Int((spend.cacheShare * 100).rounded()))%", "缓存命中")
            }
            Text(spend.turns == 0 && spend.input == 0
                 ? Words.t("从 0.27 起开始记，这段絮语之后的每一轮都会算进来。")
                 : "共 \(spend.turns) 轮 · 输入含缓存命中的部分，命中越多越省钱")
                .font(Ink.footnote)
                .foregroundStyle(Ink.inkFaint)
        }
        .padding(Ink.Space.l)
        .paperCard()
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
            Text(value).font(Ink.serif(Ink.Size.title, bold: true)).foregroundStyle(Ink.ink).monospacedDigit()
            Text(label).font(Ink.footnote).foregroundStyle(Ink.inkSoft)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Every conversation's tokens side by side, to see where they go.
    @ViewBuilder
    private var allCard: some View {
        let all = team.allSpend()
        if all.count > 1 {
            let total = all.reduce(0) { $0 + $1.spend.input + $1.spend.output }
            VStack(alignment: .leading, spacing: Ink.Space.s) {
                Text("全部对话 · 共 \(Tokens.short(total))").font(Ink.footnote).foregroundStyle(Ink.inkSoft)
                ForEach(Array(all.prefix(8).enumerated()), id: \.offset) { _, item in
                    let used = item.spend.input + item.spend.output
                    HStack(spacing: Ink.Space.s) {
                        Text(item.name).font(.system(size: Ink.Size.sub)).foregroundStyle(Ink.ink).lineLimit(1).frame(width: 72, alignment: .leading)
                        GeometryReader { box in
                            Capsule().fill(Ink.accent.opacity(0.7))
                                .frame(width: max(4, box.size.width * CGFloat(used) / CGFloat(max(total, 1))))
                        }
                        .frame(height: 8)
                        Text(Tokens.short(used)).font(.system(size: Ink.Size.small).monospacedDigit()).foregroundStyle(Ink.inkSoft).frame(width: 52, alignment: .trailing)
                    }
                }
            }
            .padding(Ink.Space.l)
            .paperCard()
        }
    }

    // MARK: 余额

    private func balanceCard(_ endpoint: Endpoint, source: Balance.Source) -> some View {
        VStack(alignment: .leading, spacing: Ink.Space.m) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
                    if let reading {
                        Text(reading.shown).font(Ink.serif(Ink.Size.title, bold: true)).foregroundStyle(floor > 0 && reading.amount < floor ? Ink.stop : Ink.ink)
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
                    .fixedSize()
            }
        }
        .frame(minWidth: 28, minHeight: 34)
        .contentShape(Rectangle())
    }
}
