import SwiftUI
import Craft

/// A ring around a companion's face that breathes while it works (in its own colour), and fades when it is done.
/// Still at a steady brightness when Reduce Motion is on. After Cindy's presence ring (Apache-2.0).
struct BreathingRing: ViewModifier {
    let on: Bool
    var tint: Color
    var gap: CGFloat = 2
    @Environment(\.accessibilityReduceMotion) private var still
    @State private var bright = false

    func body(content: Content) -> some View {
        content.overlay {
            if on {
                Circle()
                    .strokeBorder(tint, lineWidth: 2)
                    .padding(-gap - 2)
                    .opacity(still ? 0.8 : (bright ? 1 : 0.3))
                    .onAppear {
                        guard !still else { return }
                        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { bright = true }
                    }
                    .onDisappear { bright = false }
                    .transition(.opacity.animation(.easeOut(duration: 0.15)))
                    .accessibilityHidden(true)
            }
        }
    }
}

extension View {
    func breathing(_ on: Bool, tint: Color) -> some View { modifier(BreathingRing(on: on, tint: tint)) }
}

/// 一眼看旅伴: tap its face in the conversation. What it is doing, what it made lately, what it does on a schedule,
/// and the way to its 名帖. After Cindy's companion glance (Apache-2.0).
struct GlanceCard: View {
    @ObservedObject var team: TeamModel
    let bot: BotInfo
    let key: String
    var openCard: () -> Void
    var openDetail: () -> Void
    @State private var files: [Snapshots.Kept] = []

    private var routines: [Routine] { team.routines.filter { $0.botId == bot.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: Ink.Space.m) {
            HStack(spacing: Ink.Space.m) {
                PetStill(size: 48, wash: Ink.wash(for: bot), avatar: true, bot: bot)
                    .breathing(team.doing[key] != nil, tint: Ink.accent)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Ink.Space.xs) {
                        Text(bot.name).font(Ink.mark(Ink.Size.title, bold: true)).foregroundStyle(Ink.ink)
                        Text(Temper.of(bot).symbol).foregroundStyle(Ink.accent)
                    }
                    Text(team.doing[key] ?? (bot.role?.isEmpty == false ? bot.role! : Temper.of(bot).line))
                        .font(.system(size: Ink.Size.small))
                        .foregroundStyle(Ink.inkSoft)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                ClioSeal(size: 26, tilt: -4, character: ClioSeal.character(for: bot))
            }

            if !files.isEmpty {
                section("最近做出来的") {
                    ForEach(Array(files.suffix(3).reversed().enumerated()), id: \.offset) { _, file in
                        Label((file.path as NSString).lastPathComponent, systemImage: file.backup == nil ? "doc.badge.plus" : "doc.text")
                            .font(.system(size: Ink.Size.small))
                            .foregroundStyle(Ink.ink)
                            .lineLimit(1)
                    }
                }
            }
            if !routines.isEmpty {
                section(L.t("agent.scheduledJobs")) {
                    ForEach(routines.prefix(3)) { routine in
                        HStack {
                            Text(routine.title).lineLimit(1)
                            Spacer(minLength: Ink.Space.s)
                            Text(routine.when).foregroundStyle(Ink.inkFaint)
                        }
                        .font(.system(size: Ink.Size.small))
                        .foregroundStyle(routine.on ? Ink.ink : Ink.inkFaint)
                    }
                }
            }

            HStack(spacing: Ink.Space.s) {
                Button(Words.t("看名帖"), systemImage: "person.text.rectangle", action: openCard)
                    .buttonStyle(WideButtonStyle(filled: false))
                Button("这段对话", systemImage: "list.bullet.rectangle", action: openDetail)
                    .buttonStyle(WideButtonStyle(filled: false))
            }
        }
        .padding(Ink.Space.l)
        .frame(width: min(340, UIScreen.main.bounds.width - Ink.Space.xl * 2))
        .background(Ink.paper)
        // Again when the work in progress ends, so what it just made shows.
        .task(id: team.doing[key] == nil) { files = team.allChangedFiles(key) }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Ink.Space.xs) {
            Text(title).font(.system(size: Ink.Size.micro, weight: .semibold)).foregroundStyle(Ink.inkFaint)
            content()
        }
    }
}
