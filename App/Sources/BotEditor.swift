import SwiftUI

/// A Bot's card to fill in: its name, what it does, and its color. Makes a new Bot when `bot` is nil.
struct BotEditor: View {
    @ObservedObject var team: TeamModel
    let bot: BotInfo?
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var role: String
    @State private var color: String
    @State private var model: String?
    @State private var instructions: String
    @State private var busy = false
    @State private var error: String?
    @State private var confirmingDelete = false
    @FocusState private var naming: Bool


    init(team: TeamModel, bot: BotInfo?) {
        self.team = team
        self.bot = bot
        _name = State(initialValue: bot?.name ?? "")
        _role = State(initialValue: bot?.role ?? "")
        _color = State(initialValue: bot?.color.flatMap { key in Ink.tints.contains { $0.key == key } ? key : nil } ?? "dai")
        _instructions = State(initialValue: bot?.instructions ?? "")
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !trimmed.isEmpty && !busy }

    var body: some View {
        ZStack {
            Ink.paper.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 18) {
                    HStack {
                        Button {
                            Haptics.light()
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 17, weight: .semibold))
                                .frame(width: 26, height: 26)
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .controlSize(.large)
                        .accessibilityLabel("关闭")
                        Spacer()
                    }

                    VStack(spacing: Ink.Space.m) {
                        Whale(size: 96, wash: Ink.wash(named: color))
                        Text(trimmed.isEmpty ? "新旅伴" : trimmed).font(Ink.title).foregroundStyle(Ink.ink)
                        Text(role.isEmpty ? "一句话说说它" : role).font(Ink.secondary).foregroundStyle(Ink.inkSoft)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Ink.Space.xl)
                    .paperCard()
                    .animation(Ink.Motion.unfold, value: color)

                    VStack(alignment: .leading, spacing: 8) {
                        label("名字")
                        TextField("比如：团子", text: $name)
                            .font(.system(size: 18, weight: .semibold))
                            .focused($naming)
                            .submitLabel(.done)
                            .padding(.horizontal, 16)
                            .frame(height: 52)
                            .paperCard(radius: 18)
                        label("它负责什么").padding(.top, 6)
                        TextField("比如：查资料 · 写总结", text: $role)
                            .font(.system(size: 17))
                            .submitLabel(.done)
                            .padding(.horizontal, 16)
                            .frame(height: 52)
                            .paperCard(radius: 18)
                        label("性格和说明").padding(.top, 6)
                        TextField("比如：说话温柔，爱用表情；擅长做饭，会根据冰箱里有的东西出主意。", text: $instructions, axis: .vertical)
                            .font(.system(size: 16))
                            .lineLimit(3...8)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .paperCard(radius: 18)
                        if !team.models.isEmpty {
                            label("用哪个模型").padding(.top, 6)
                            Menu {
                                Button {
                                    model = ""
                                } label: {
                                    if (model ?? bot?.model ?? "").isEmpty {
                                        Label("跟默认的走", systemImage: "checkmark")
                                    } else {
                                        Text("跟默认的走")
                                    }
                                }
                                ForEach(team.models) { item in
                                    Button {
                                        model = item.ref
                                    } label: {
                                        if (model ?? bot?.model) == item.ref {
                                            Label(Self.title(item), systemImage: "checkmark")
                                        } else {
                                            Text(Self.title(item))
                                        }
                                    }
                                }
                            } label: {
                                HStack {
                                    Text(team.models.first { $0.ref == (model ?? bot?.model) }.map(Self.title) ?? "跟默认的走（\(team.modelTitle(team.settings.defaultModel))）")
                                        .font(.system(size: 17))
                                        .lineLimit(1)
                                    Spacer()
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(Ink.inkSoft)
                                }
                                .padding(.horizontal, 16)
                                .frame(height: 52)
                                .paperCard(radius: 18)
                            }
                            .buttonStyle(.plain)
                        }
                        label("底色").padding(.top, 6)
                        HStack(spacing: Ink.Space.m) {
                            ForEach(Ink.tints, id: \.key) { tint in
                                Button {
                                    Haptics.tick(0.6)
                                    color = tint.key
                                } label: {
                                    Text(tint.title)
                                        .font(Ink.serif(16, bold: color == tint.key))
                                        .foregroundStyle(Ink.ink)
                                        .frame(width: 44, height: 44)
                                        .background(tint.color, in: .circle)
                                        .overlay(Circle().strokeBorder(color == tint.key ? Ink.accent : Ink.rule, lineWidth: color == tint.key ? 2 : 1))
                                        .scaleEffect(color == tint.key ? 1.08 : 1)
                                        .animation(Ink.Motion.press, value: color)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(tint.title)
                            }
                        }
                    }
                    .foregroundStyle(Ink.ink)

                    if let error {
                        Text(error)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Ink.stop)
                            .multilineTextAlignment(.center)
                    }

                    Button {
                        save()
                    } label: {
                        HStack(spacing: 8) {
                            if busy { ProgressView().tint(.white) }
                            Text(bot == nil ? "让它入职" : "保存")
                                .font(.system(size: 18, weight: .bold))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .disabled(!canSave)
                    .padding(.top, 4)

                    if let bot, !team.isMain(bot) {
                        Button("让它离职") { confirmingDelete = true }
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Ink.stop)
                            .buttonStyle(.plain)
                            .frame(height: 44)
                            .disabled(busy)
                            .confirmationDialog("让\(bot.name)离职？它和你的对话会一起删掉，不能恢复。", isPresented: $confirmingDelete, titleVisibility: .visible) {
                                Button("删除这个 Bot", role: .destructive) { remove(bot) }
                                Button("先留着", role: .cancel) {}
                            }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 10)
                .padding(.bottom, 30)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollIndicators(.hidden)
        }
        .onAppear { if bot == nil { naming = true } }
    }

    private static func title(_ model: ModelInfo) -> String {
        let name = model.name?.isEmpty == false ? model.name! : model.ref
        if let provider = model.providerName, !provider.isEmpty { return "\(name) · \(provider)" }
        return name
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(Ink.inkSoft)
            .padding(.leading, 6)
    }

    private func save() {
        guard canSave else { return }
        busy = true
        error = nil
        Task {
            do {
                try await team.saveBot(id: bot?.id, name: trimmed, role: role.trimmingCharacters(in: .whitespacesAndNewlines), color: color, model: model,
                                       instructions: instructions.trimmingCharacters(in: .whitespacesAndNewlines))
                Haptics.thud()
                dismiss()
            } catch {
                busy = false
                Haptics.lock()
                self.error = "没存上：\(error.localizedDescription)"
            }
        }
    }

    private func remove(_ bot: BotInfo) {
        busy = true
        error = nil
        Task {
            do {
                try await team.deleteBot(bot.id)
                Haptics.lock()
                dismiss()
            } catch {
                busy = false
                self.error = "没删掉：\(error.localizedDescription)"
            }
        }
    }
}
