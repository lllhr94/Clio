import SwiftUI

enum CompanionSheetAction {
    case newCompanion
    case newRoom
    case importCard
    case manageSettings
}

/// Level-1 companion and gathering roster sheet opened directly from the sidebar.
struct DeskCompanionsSheet: View {
    @ObservedObject var team: TeamModel
    let onSelectChat: (Opened) -> Void
    let onAction: (CompanionSheetAction) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var cardBot: BotInfo?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Ink.Space.xl) {
                    Text(L.t("sidebar.companionsSubtitle"))
                        .font(Ink.secondary)
                        .foregroundStyle(Ink.inkSoft)
                    companionsSection
                    roomsSection
                    manageRow
                }
                .padding(.horizontal, Ink.Space.page)
                .padding(.vertical, Ink.Space.l)
            }
            .background(Ink.paper.ignoresSafeArea())
            .hitchPage("助手名录")
            .navigationTitle(L.t("sidebar.companions"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(L.t("sidebar.newCompanion"), systemImage: "person.badge.plus") {
                            trigger(.newCompanion)
                        }
                        Button(L.t("sidebar.newRoom"), systemImage: "person.3") {
                            trigger(.newRoom)
                        }
                        .disabled(team.bots.count < 2)
                        Button(L.t("sidebar.importCard"), systemImage: "square.and.arrow.down") {
                            trigger(.importCard)
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(L.t("sidebar.moreActions"))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L.t("actions.done")) {
                        Haptics.light()
                        dismiss()
                    }
                }
            }
            .sheet(item: $cardBot) { bot in
                NameCardSheet(team: team, bot: bot)
            }
        }
    }

    private var companionsSection: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle(L.t("sidebar.sectionCompanions"))
            if team.bots.isEmpty {
                EmptyNote(symbol: "person.2", words: L.t("sidebar.noCompanions"))
            } else {
                VStack(spacing: 0) {
                    ForEach(team.bots) { bot in
                        botRow(bot)
                        if bot.id != team.bots.last?.id { Kit.divider }
                    }
                }
                .paperCard()
            }
        }
    }

    private var roomsSection: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle(L.t("sidebar.sectionRooms"))
            if team.rooms.isEmpty {
                EmptyNote(symbol: "person.3", words: L.t("sidebar.noRooms"))
            } else {
                VStack(spacing: 0) {
                    ForEach(team.rooms) { room in
                        roomRow(room)
                        if room.id != team.rooms.last?.id { Kit.divider }
                    }
                }
                .paperCard()
            }
        }
    }

    private var manageRow: some View {
        RowCard {
            Button {
                trigger(.manageSettings)
            } label: {
                RowLabel("gearshape", tint: Ink.Tile.mo, title: L.t("sidebar.manageSettings"))
            }
            .buttonStyle(PressStyle(haptic: false))
        }
    }

    private func botRow(_ bot: BotInfo) -> some View {
        HStack(spacing: Ink.Space.s) {
            Button {
                Haptics.light()
                dismiss()
                onSelectChat(.companion(bot.id))
            } label: {
                HStack(spacing: Ink.Space.m) {
                    CompanionAvatar(size: 36 * UIScale.factor, wash: Ink.wash(for: bot), bot: bot)
                    VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
                        Text(bot.name)
                            .font(.system(size: Ink.Size.body, weight: .medium))
                            .foregroundStyle(Ink.ink)
                            .lineLimit(1)
                        if let subtitle = botSubtitle(bot) {
                            Text(subtitle)
                                .font(Ink.footnote)
                                .foregroundStyle(Ink.inkSoft)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle(haptic: false))

            Button {
                Haptics.light()
                cardBot = bot
            } label: {
                Image(systemName: "person.text.rectangle")
                    .font(.system(size: Ink.Size.sub))
                    .foregroundStyle(Ink.inkSoft)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L.t("chat.openCard"))
        }
        .padding(.horizontal, Ink.Space.l)
        .padding(.vertical, Ink.Space.m)
    }

    private func botSubtitle(_ bot: BotInfo) -> String? {
        if let role = bot.role, !role.isEmpty { return role }
        if let preview = bot.preview, !preview.isEmpty { return preview }
        return nil
    }

    private func roomRow(_ room: RoomInfo) -> some View {
        Button {
            Haptics.light()
            dismiss()
            onSelectChat(.gathering(room.id))
        } label: {
            RowLabel(
                "person.3",
                tint: Ink.Tile.yan,
                title: room.name,
                line: room.preview
            )
        }
        .buttonStyle(PressStyle(haptic: false))
    }

    private func trigger(_ action: CompanionSheetAction) {
        Haptics.light()
        onAction(action)
        dismiss()
    }
}
