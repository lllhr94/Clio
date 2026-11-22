import SwiftUI

/// 新对话, the HanaAgent way: pick who to talk with and whether this conversation looks at memory, then start.
/// Turning memory off is cheaper too (the model's cache hits more often) and keeps this one out of what is remembered.
struct NewChatSheet: View {
    @ObservedObject var team: TeamModel
    let start: (String, Bool) -> Void
    @State private var pick: String
    @State private var memory = true
    @State private var detent = PresentationDetent.large
    @Environment(\.dismiss) private var dismiss

    init(team: TeamModel, first: String?, start: @escaping (String, Bool) -> Void) {
        self.team = team
        self.start = start
        _pick = State(initialValue: first.flatMap { id in team.bots.first { $0.id == id }?.id } ?? team.bots.first?.id ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                PaperRows {
                    Section {
                        ForEach(team.bots) { bot in
                            Button {
                                Haptics.tick(0.5)
                                pick = bot.id
                            } label: {
                                HStack(spacing: Ink.Space.m) {
                                    PetStill(size: 32, wash: Ink.wash(for: bot), avatar: true, bot: bot)
                                    Text(bot.name).foregroundStyle(Ink.ink)
                                    Spacer()
                                    if pick == bot.id {
                                        Image(systemName: "checkmark").font(.system(size: Ink.Size.sub, weight: .semibold)).foregroundStyle(Ink.accent)
                                    }
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                    } header: { Text(L.t("chat.newCompanion")) }
                    Section {
                        Toggle(L.t("chat.newMemory"), isOn: $memory).tint(Ink.accent)
                    } footer: {
                        Text(L.t("chat.newMemoryNote"))
                    }
                }
            }
            .paperForm()
            .navigationTitle(L.t("chat.newConversation"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(L.t("actions.cancel")) { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L.t("actions.start")) {
                        Haptics.light()
                        start(pick, memory)
                    }
                    .disabled(!team.bots.contains { $0.id == pick })
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
    }
}
