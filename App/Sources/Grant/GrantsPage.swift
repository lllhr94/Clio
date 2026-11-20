import SwiftUI

/// 应许: every ability on one page, with the user's say and the system's say side by side.
struct GrantsPage: View {
    @ObservedObject var team: TeamModel
    @Environment(\.dismiss) private var dismiss
    @State private var asking = false
    @Environment(\.scenePhase) private var phase
    @State private var policies: [Grant: Grant.Policy] = [:]
    @State private var systems: [Grant: Grant.System] = [:]

    private let groups: [(String, [Grant])] = [
        (L.t("permissions.web"), [.web, .browser, .links]),
        (L.t("permissions.connections"), [.hills, .mcp, .google, .vault]),
        (L.t("nav.filesAndTerminal"), [.desk, .den, .memory, .letters]),
        (L.t("permissions.onPhone"), [.calendar, .reminders, .contacts, .photos, .clipboard]),
        (L.t("permissions.personal"), [.location, .motion, .health, .device]),
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Ink.paper.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: Ink.Space.xl) {
                        presets
                        Button {
                            askAll()
                        } label: {
                            HStack(spacing: Ink.Space.m) {
                                Image(systemName: "checkmark.seal").font(.system(size: Ink.Size.title)).foregroundStyle(Ink.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(asking ? L.t("loading.requestingPermissions") : Words.t("一并应许")).font(Ink.serif(17, bold: true)).foregroundStyle(Ink.ink)
                                    Text("一次问完系统授权")
                                        .font(Ink.footnote).foregroundStyle(Ink.inkSoft)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(Ink.Space.l)
                            .paperCard()
                        }
                        .buttonStyle(PressStyle())
                        .disabled(asking)
                        ForEach(groups, id: \.0) { group in
                            VStack(alignment: .leading, spacing: Ink.Space.s) {
                                Text(group.0)
                                    .font(Ink.serif(15, bold: true))
                                    .foregroundStyle(Ink.inkSoft)
                                    .padding(.leading, Ink.Space.xs)
                                VStack(spacing: 0) {
                                    ForEach(group.1) { grant in
                                        row(grant)
                                        if grant != group.1.last { Kit.divider }
                                    }
                                }
                                .paperCard()
                            }
                        }
                        if !team.alwaysAllowed.isEmpty {
                            VStack(alignment: .leading, spacing: Ink.Space.s) {
                                Text(L.t("permissions.alwaysAllowed")).font(Ink.serif(15, bold: true)).foregroundStyle(Ink.inkSoft).padding(.leading, Ink.Space.xs)
                                VStack(spacing: 0) {
                                    ForEach(team.alwaysAllowed.sorted(), id: \.self) { tool in
                                        HStack {
                                            Text(tool).font(Ink.mono(Ink.Size.sub)).foregroundStyle(Ink.ink)
                                            Spacer()
                                            Button("收回") { withAnimation(.smooth) { team.revokeAlways(tool) } }
                                                .font(.system(size: Ink.Size.sub, weight: .medium)).foregroundStyle(Ink.stop)
                                        }
                                        .padding(.horizontal, Ink.Space.l)
                                        .padding(.vertical, Ink.Space.m)
                                    }
                                }
                                .paperCard()
                            }
                        }
                        Button {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        } label: {
                            Label("去系统设置里看 Clio 的权限", systemImage: "gear")
                                .font(.system(size: Ink.Size.sub, weight: .medium))
                                .foregroundStyle(Ink.accent)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, Ink.Space.m)
                        }
                        .buttonStyle(PressStyle())
                    }
                    .padding(.horizontal, Ink.Space.page)
                    .padding(.vertical, Ink.Space.l)
                }
            }
            .navigationTitle(L.t("settings.permissions"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button(L.t("actions.done")) { dismiss() } }
            }
        }
        .onAppear(perform: load)
        .onChange(of: phase) { _, now in if now == .active { load() } }
    }

    /// Asks the system about every ability not yet asked, one after another, and lets the reading ones go ahead.
    private func askAll() {
        asking = true
        Task {
            for grant in Grant.allCases where grant.system == .notAsked {
                await grant.requestSystem()
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
            await Grant.letters.requestSystem()
            for grant in [Grant.location, .photos, .motion, .health, .device, .calendar, .reminders, .contacts] where grant.policy == .ask || grant.policy == .off {
                if grant.system == .granted || grant.system == .limited || grant.system == .none { grant.policy = .allow }
            }
            load()
            asking = false
            Haptics.thud()
        }
    }

    private func load() {
        for grant in Grant.allCases {
            policies[grant] = grant.policy
            systems[grant] = grant.system
        }
    }

    /// 谨慎 / 平常 / 放手: everything at once; the items below can still be set one by one.
    private var presets: some View {
        let current = Grant.Preset.current
        return VStack(alignment: .leading, spacing: Ink.Space.s) {
            HStack(spacing: Ink.Space.s) {
                ForEach(Grant.Preset.allCases) { preset in
                    Button {
                        Haptics.tick(0.6)
                        preset.apply()
                        for grant in Grant.allCases { policies[grant] = grant.policy }
                    } label: {
                        VStack(spacing: 2) {
                            Text(preset.title).font(.system(size: Ink.Size.sub, weight: .semibold))
                            Text(preset.line).font(.system(size: Ink.Size.micro)).lineLimit(2).multilineTextAlignment(.center)
                        }
                        .foregroundStyle(current == preset ? Ink.accent : Ink.inkSoft)
                        .frame(maxWidth: .infinity, minHeight: 64)
                        .padding(.horizontal, 4)
                        .background(current == preset ? Ink.accentWash : Ink.paperRaised, in: .rect(cornerRadius: Ink.Radius.card, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Ink.Radius.card, style: .continuous).strokeBorder(current == preset ? Color.clear : Ink.rule))
                    }
                    .buttonStyle(PressStyle(haptic: false))
                    .accessibilityAddTraits(current == preset ? .isSelected : [])
                }
            }
            Text(current == nil ? "自定义：下面有几项是你单独改过的" : "下面每项还能单独改")
                .font(Ink.footnote).foregroundStyle(Ink.inkFaint).padding(.leading, Ink.Space.xs)
        }
    }

    private func row(_ grant: Grant) -> some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            HStack(alignment: .top, spacing: Ink.Space.m) {
                IconBadge(symbol: grant.symbol, tint: policies[grant] == .off ? Ink.inkFaint : Ink.accent)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Ink.Space.s) {
                        Text(grant.title).font(.system(size: Ink.Size.body, weight: .medium)).foregroundStyle(Ink.ink)
                        systemBadge(grant)
                    }
                    Text(grant.note).font(Ink.footnote).foregroundStyle(Ink.inkSoft)
                }
                Spacer(minLength: 0)
            }
            Picker(grant.title, selection: Binding(get: { policies[grant] ?? grant.policy }, set: { value in
                Haptics.tick(0.5)
                grant.policy = value
                policies[grant] = value
                if value != .off, systems[grant] == .notAsked {
                    Task {
                        await grant.requestSystem()
                        systems[grant] = grant.system
                    }
                }
            })) {
                ForEach(Grant.Policy.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.leading, Kit.badge + Ink.Space.m)
        }
        .padding(.horizontal, Ink.Space.l)
        .padding(.vertical, Ink.Space.m)
    }

    @ViewBuilder
    private func systemBadge(_ grant: Grant) -> some View {
        switch systems[grant] ?? .none {
        case .none:
            EmptyView()
        case .granted:
            badge("系统已允许", Ink.ok)
        case .limited:
            badge("系统部分允许", Ink.warn)
        case .notAsked:
            Button {
                Task {
                    await grant.requestSystem()
                    systems[grant] = grant.system
                }
            } label: { badge("向系统请求", Ink.accent) }
            .buttonStyle(PressStyle())
        case .denied:
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            } label: { badge("系统已拒绝 · 去设置", Ink.stop) }
            .buttonStyle(PressStyle())
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: Ink.Size.micro, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: .capsule)
    }
}
