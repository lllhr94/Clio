import SwiftUI

/// 应许: every ability on one page, with the user's say and the system's say side by side.
struct GrantsPage: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var policies: [Grant: Grant.Policy] = [:]
    @State private var systems: [Grant: Grant.System] = [:]

    private let groups: [(String, [Grant])] = [
        ("出门寻访", [.web, .browser, .links]),
        ("远山", [.hills, .mcp]),
        ("案头与小屋", [.desk, .den, .memory, .letters]),
        ("手机里的事", [.calendar, .reminders, .contacts, .photos, .clipboard]),
        ("身边与身体", [.location, .motion, .device]),
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Ink.paper.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: Ink.Space.xl) {
                        Text("旅伴能做什么，一项一项由你定。「每次问」会在用之前请你落印；「不许」它就看不到这项本事。有些还要过手机系统那一关。")
                            .font(Ink.secondary)
                            .foregroundStyle(Ink.inkSoft)
                        ForEach(groups, id: \.0) { group in
                            VStack(alignment: .leading, spacing: Ink.Space.s) {
                                Text(group.0)
                                    .font(Ink.serif(15, bold: true))
                                    .foregroundStyle(Ink.inkSoft)
                                    .padding(.leading, Ink.Space.xs)
                                VStack(spacing: 0) {
                                    ForEach(group.1) { grant in
                                        row(grant)
                                        if grant != group.1.last { Rectangle().fill(Ink.rule).frame(height: 1).padding(.leading, 52) }
                                    }
                                }
                                .paperCard()
                            }
                        }
                        Button {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        } label: {
                            Label("去系统设置里看 Clio 的权限", systemImage: "gear")
                                .font(.system(size: 15, weight: .medium))
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
            .navigationTitle("应许")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("好了") { dismiss() } }
            }
        }
        .onAppear(perform: load)
        .onChange(of: phase) { _, now in if now == .active { load() } }
    }

    private func load() {
        for grant in Grant.allCases {
            policies[grant] = grant.policy
            systems[grant] = grant.system
        }
    }

    private func row(_ grant: Grant) -> some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            HStack(alignment: .top, spacing: Ink.Space.m) {
                Image(systemName: grant.symbol)
                    .font(.system(size: 17))
                    .foregroundStyle(policies[grant] == .off ? Ink.inkFaint : Ink.accent)
                    .frame(width: 28, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Ink.Space.s) {
                        Text(grant.title).font(.system(size: 16, weight: .medium)).foregroundStyle(Ink.ink)
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
            .padding(.leading, 40)
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
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: .capsule)
    }
}
