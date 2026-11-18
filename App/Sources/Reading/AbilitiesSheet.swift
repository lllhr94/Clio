import PDFKit
import SwiftUI

/// 本事: what the companion may use in this conversation. Switching one off here leaves every other conversation alone.
struct AbilitiesSheet: View {
    @ObservedObject var team: TeamModel
    let key: String
    let name: String
    @Environment(\.dismiss) private var dismiss

    private let groups: [(String, [Grant])] = [
        ("出门", [.web, .browser, .hills, .mcp]),
        ("案头与小屋", [.desk, .den, .memory, .letters, .vault]),
        ("手机里的事", [.calendar, .reminders, .contacts, .photos, .clipboard, .links]),
        ("身边", [.location, .motion, .device]),
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Ink.paper.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: Ink.Space.xl) {
                        Text("这段絮语里，\(name)能用下面这些本事。关掉的它就看不到，只影响这一段絮语。灰掉的是在「应许」里整个关了的，要去那里打开。")
                            .font(Ink.secondary)
                            .foregroundStyle(Ink.inkSoft)
                        ForEach(groups, id: \.0) { group in
                            VStack(alignment: .leading, spacing: Ink.Space.s) {
                                Text(group.0).font(Ink.serif(15, bold: true)).foregroundStyle(Ink.inkSoft).padding(.leading, Ink.Space.xs)
                                VStack(spacing: 0) {
                                    ForEach(group.1) { grant in
                                        row(grant)
                                        if grant != group.1.last { Rectangle().fill(Ink.rule).frame(height: 1).padding(.leading, 52) }
                                    }
                                }
                                .paperCard()
                            }
                        }
                        if !team.options(key).off.isEmpty {
                            Button("这段絮语全部打开") {
                                Haptics.thud()
                                var value = team.options(key)
                                value.off = []
                                team.setOptions(key, value)
                            }
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Ink.accent)
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.horizontal, Ink.Space.page)
                    .padding(.vertical, Ink.Space.l)
                }
            }
            .navigationTitle("本事")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("好了") { dismiss() } } }
        }
    }

    private func row(_ grant: Grant) -> some View {
        let global = grant.policy
        let on = !team.options(key).off.contains(grant.rawValue)
        return HStack(spacing: Ink.Space.m) {
            Image(systemName: grant.symbol)
                .font(.system(size: 17))
                .foregroundStyle(global == .off || !on ? Ink.inkFaint : Ink.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Ink.Space.s) {
                    Text(grant.title).font(.system(size: 16, weight: .medium)).foregroundStyle(global == .off ? Ink.inkFaint : Ink.ink)
                    if global == .ask {
                        Text("用前会问你").font(.system(size: 11, weight: .medium)).foregroundStyle(Ink.inkFaint)
                    }
                }
                Text(global == .off ? "在「应许」里关着" : grant.note)
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
