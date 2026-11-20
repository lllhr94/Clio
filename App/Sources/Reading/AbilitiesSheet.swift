import PDFKit
import SwiftUI

/// 本事: what the companion may use in this conversation. Switching one off here leaves every other conversation alone.
struct AbilitiesSheet: View {
    @ObservedObject var team: TeamModel
    let key: String
    let name: String
    @Environment(\.dismiss) private var dismiss

    private let groups: [(String, [Grant])] = [
        ("出门", [.web, .browser, .hills, .mcp, .google]),
        (Words.t("案头与小屋"), [.desk, .den, .memory, .letters, .vault]),
        ("手机里的事", [.calendar, .reminders, .contacts, .photos, .clipboard, .links]),
        ("身边", [.location, .motion, .device]),
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Ink.paper.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: Ink.Space.xl) {
                        Text(Words.t("只影响这段絮语"))
                            .font(Ink.secondary)
                            .foregroundStyle(Ink.inkSoft)
                        workplace
                        ForEach(groups, id: \.0) { group in
                            VStack(alignment: .leading, spacing: Ink.Space.s) {
                                SectionTitle(group.0)
                                VStack(spacing: 0) {
                                    ForEach(group.1) { grant in
                                        row(grant)
                                        if grant != group.1.last { Kit.divider }
                                    }
                                }
                                .paperCard()
                            }
                        }
                        if !team.options(key).off.isEmpty {
                            Button(Words.t("这段絮语全部打开")) {
                                Haptics.thud()
                                var value = team.options(key)
                                value.off = []
                                team.setOptions(key, value)
                            }
                            .font(.system(size: Ink.Size.sub, weight: .medium))
                            .foregroundStyle(Ink.accent)
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.horizontal, Ink.Space.page)
                    .padding(.vertical, Ink.Space.l)
                }
            }
            .navigationTitle(L.t("agent.capabilities"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L.t("actions.done")) { dismiss() } } }
        }
    }

    /// Where the work happens: 书案, 斗室 or a 远山 host. Rarely changed, so it lives here rather than under the composer.
    private var workplace: some View {
        let current = team.place(of: key)
        var places: [(WorkPlace, String)] = [(.desk, "手机里的文件夹，读写文件、算数"), (.den, "手机里的 Linux，能跑命令、装软件")]
        places += Hills.shared.hosts.map { (.hill($0.id), "\($0.user)@\($0.address)") }
        return VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle("在哪里干活")
            VStack(spacing: 0) {
                ForEach(Array(places.enumerated()), id: \.offset) { index, item in
                    Button {
                        Haptics.tick(0.5)
                        team.setPlace(item.0, in: key)
                    } label: {
                        HStack(spacing: Ink.Space.m) {
                            IconBadge(symbol: item.0.symbol)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.0.title).font(.system(size: Ink.Size.body, weight: .medium)).foregroundStyle(Ink.ink)
                                Text(item.1).font(Ink.footnote).foregroundStyle(Ink.inkSoft).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            if current == item.0 { Image(systemName: "checkmark").font(.system(size: Ink.Size.sub, weight: .semibold)).foregroundStyle(Ink.accent) }
                        }
                        .padding(.horizontal, Ink.Space.l)
                        .padding(.vertical, Ink.Space.m)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(TapStyle())
                    if index < places.count - 1 { Kit.divider }
                }
            }
            .paperCard()
            if Hills.shared.hosts.isEmpty {
                Text(Words.t("在调弦 › 远山 添一台电脑或服务器，这里就能选它。")).font(Ink.footnote).foregroundStyle(Ink.inkFaint).padding(.leading, Ink.Space.xs)
            }
        }
    }

    private func row(_ grant: Grant) -> some View {
        let global = grant.policy
        let on = !team.options(key).off.contains(grant.rawValue)
        return HStack(spacing: Ink.Space.m) {
            IconBadge(symbol: grant.symbol, tint: global == .off || !on ? Ink.Tile.off : Ink.Tile.accent)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Ink.Space.s) {
                    Text(grant.title).font(.system(size: Ink.Size.body, weight: .medium)).foregroundStyle(global == .off ? Ink.inkFaint : Ink.ink)
                    if global == .ask {
                        Text("用前会问你").font(.system(size: Ink.Size.micro, weight: .medium)).foregroundStyle(Ink.inkFaint)
                    }
                }
                Text(global == .off ? Words.t("在「应许」里关着") : grant.note)
                    .font(Ink.footnote).foregroundStyle(Ink.inkSoft).lineLimit(2)
            }
            Spacer(minLength: 0)
            Toggle(grant.title, isOn: Binding(get: { on && global != .off }, set: { value in
                Haptics.tick(0.5)
                team.setAbility(grant, on: value, in: key)
            }))
            .labelsHidden()
            .tint(Ink.accent)
            .disabled(global == .off)
        }
        .padding(.horizontal, Ink.Space.l)
        .padding(.vertical, Ink.Space.m)
    }
}
