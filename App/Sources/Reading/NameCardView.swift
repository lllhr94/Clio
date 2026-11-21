import SwiftUI

/// 名帖 as a card you hold: tall like a playing card, the companion's portrait on its colour above,
/// its name, one line about it, three small fields (性格 · 记得 · 模型), and a 落款 with the date and the seal.
/// The back is the companion's colour with the seal and the wordmark. Learnt from HanaAgent's character cards
/// (Apache-2.0); drawn in Clio's own paper and ink.
struct NameCardView: View {
    let bot: BotInfo
    var width: CGFloat = 300
    /// How many things it remembers about you.
    var remembers = 0
    /// The model it writes with, as shown (「deepseek-v4.1-flash」).
    var model: String?

    private var wash: Color { Ink.wash(for: bot) }
    private var corner: CGFloat { Ink.Radius.card * width / 330 }

    var body: some View {
        VStack(spacing: 0) {
            portrait
            Rectangle().fill(Ink.rule).frame(height: 1)
            title
            Rectangle().fill(Ink.rule.opacity(0.7)).frame(height: 0.5)
            fields
            Spacer(minLength: 0)
            footer
        }
        .frame(width: width, height: width * 1.5)
        .background(Ink.paperRaised)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(Ink.rule, lineWidth: 1))
        .shadow(color: .black.opacity(0.10), radius: 18, y: 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(bot.name)的名帖")
    }

    /// The face on its colour: a pet drawn large, or a photo filling the frame.
    private var portrait: some View {
        ZStack {
            LinearGradient(colors: [wash.opacity(0.55), wash.opacity(0.25)], startPoint: .top, endPoint: .bottom)
            if bot.avatar == "photo", let photo = Avatars.image(bot.id) {
                Image(uiImage: photo).resizable().scaledToFill()
            } else {
                PetStill(size: width * 0.62, bot: bot, face: .some(bot.avatar))
                    .offset(y: width * 0.04)
            }
        }
        .frame(width: width, height: width * 0.86)
        .clipped()
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: Ink.Space.xs) {
            Text(bot.name)
                .font(Ink.mark(width * 0.075, bold: true))
                .foregroundStyle(Ink.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(bot.role?.isEmpty == false ? bot.role! : "还没写一句话简介")
                .font(.system(size: Ink.Size.small))
                .foregroundStyle(Ink.inkSoft)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Ink.Space.l)
        .padding(.vertical, Ink.Space.m)
    }

    /// Three small fields side by side, thin lines between them, as on a collector's card.
    private var fields: some View {
        HStack(spacing: 0) {
            field("性格", personality)
            Rectangle().fill(Ink.rule.opacity(0.7)).frame(width: 0.5)
            field("记得", remembers > 0 ? "关于你的 \(remembers) 件事" : "还没有")
            Rectangle().fill(Ink.rule.opacity(0.7)).frame(width: 0.5)
            field("模型", model ?? "跟默认")
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var personality: String {
        let text = (bot.instructions ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = text.split(whereSeparator: \.isNewline).first else { return "随性" }
        return String(first)
    }

    private func field(_ label: String, _ value: String) -> some View {
        VStack(spacing: Ink.Space.xs) {
            Text(label)
                .font(.system(size: Ink.Size.micro, weight: .semibold))
                .tracking(2)
                .foregroundStyle(Ink.inkFaint)
            Rectangle().fill(Ink.rule).frame(width: 14, height: 1)
            Text(value)
                .font(.system(size: Ink.Size.micro))
                .foregroundStyle(Ink.ink)
                .multilineTextAlignment(.center)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Ink.Space.s)
        .padding(.vertical, Ink.Space.m)
    }

    /// 落款: where it is from, when it came, and the seal.
    private var footer: some View {
        HStack(alignment: .center, spacing: Ink.Space.s) {
            Text("Clio · 名帖")
                .font(Ink.wordmark(Ink.Size.small))
                .foregroundStyle(Ink.inkFaint)
            Spacer(minLength: Ink.Space.s)
            if let since = since {
                Text(since)
                    .font(.system(size: Ink.Size.micro))
                    .foregroundStyle(Ink.inkFaint)
            }
            ClioSeal(size: 20, tilt: -4)
        }
        .padding(.horizontal, Ink.Space.l)
        .padding(.bottom, Ink.Space.m)
    }

    private var since: String? {
        guard let made = bot.createdAt else { return nil }
        let date = Date(timeIntervalSince1970: made / 1000)
        return "立于 " + date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)).replacingOccurrences(of: "/", with: ".")
    }
}

/// The back of a 名帖: the companion's colour, the seal, the wordmark.
struct NameCardBack: View {
    let bot: BotInfo
    var width: CGFloat = 300

    private var corner: CGFloat { Ink.Radius.card * width / 330 }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Ink.wash(for: bot).opacity(0.8), Ink.wash(for: bot).opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing)
            RoundedRectangle(cornerRadius: corner * 0.7, style: .continuous)
                .strokeBorder(Ink.paper.opacity(0.7), lineWidth: 1)
                .padding(Ink.Space.l)
            VStack(spacing: Ink.Space.l) {
                ClioSeal(size: width * 0.26, tilt: -3)
                Text("Clio")
                    .font(Ink.wordmark(width * 0.12))
                    .foregroundStyle(Ink.ink.opacity(0.8))
                Text(bot.name)
                    .font(Ink.mark(Ink.Size.sub))
                    .foregroundStyle(Ink.inkSoft)
            }
        }
        .frame(width: width, height: width * 1.5)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(Ink.rule, lineWidth: 1))
        .shadow(color: .black.opacity(0.10), radius: 18, y: 8)
        .accessibilityHidden(true)
    }
}

/// 看名帖: the card large, turned over with a tap; 改名帖 and 递出去 (as a picture and as a file) under it.
struct NameCardSheet: View {
    @ObservedObject var team: TeamModel
    let bot: BotInfo
    @Environment(\.dismiss) private var dismiss
    @State private var flipped = false
    @State private var editing = false
    @State private var shared: [URL] = []

    /// The companion as it is now (it may have been edited behind this sheet).
    private var current: BotInfo { team.bots.first { $0.id == bot.id } ?? bot }
    private var remembers: Int { team.memories.filter { $0.by == bot.id }.count }
    private var model: String? { current.model.flatMap { team.resolve($0)?.model } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Ink.Space.xl) {
                    card
                        .onTapGesture {
                            Haptics.light()
                            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { flipped.toggle() }
                        }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint("点一下翻面")
                    Text("点一下翻到背面")
                        .font(Ink.footnote)
                        .foregroundStyle(Ink.inkFaint)
                    HStack(spacing: Ink.Space.m) {
                        Button {
                            Haptics.light()
                            editing = true
                        } label: {
                            Label(Words.t("改名帖"), systemImage: "pencil")
                        }
                        .buttonStyle(WideButtonStyle(filled: false))
                        if !shared.isEmpty {
                            ShareLink(items: shared) {
                                Label(Words.t("递出去"), systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(WideButtonStyle())
                        }
                    }
                    .padding(.horizontal, Ink.Space.page)
                    Text(Words.t("递出去的是一张图和一个名帖文件。对方用 Clio 收名帖就能请到同样的旅伴；你和它的聊天、它记得的事不会带走。"))
                        .font(Ink.footnote)
                        .foregroundStyle(Ink.inkSoft)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Ink.Space.xl)
                }
                .padding(.vertical, Ink.Space.xl)
                .frame(maxWidth: .infinity)
            }
            .background(Ink.paper.ignoresSafeArea())
            .navigationTitle(Words.t("名帖"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button(L.t("actions.done")) { dismiss() } }
            }
        }
        .sheet(isPresented: $editing, onDismiss: prepareShare) { BotEditor(team: team, bot: current) }
        .task { prepareShare() }
    }

    private var card: some View {
        ZStack {
            NameCardView(bot: current, width: 300, remembers: remembers, model: model)
                .rotation3DEffect(.degrees(flipped ? 180 : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
                .opacity(flipped ? 0 : 1)
            NameCardBack(bot: current, width: 300)
                .rotation3DEffect(.degrees(flipped ? 0 : -180), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
                .opacity(flipped ? 1 : 0)
        }
    }

    /// The picture (drawn at three times its size) and the file, ready to hand over.
    @MainActor
    private func prepareShare() {
        let who = current
        let renderer = ImageRenderer(content: NameCardView(bot: who, width: 330, remembers: remembers, model: model).padding(24).background(Ink.paper))
        renderer.scale = 3
        var urls: [URL] = []
        if let image = renderer.uiImage, let data = image.pngData() {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("名帖", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("\(who.name.replacingOccurrences(of: "/", with: "-")).名帖.png")
            if (try? data.write(to: url, options: .atomic)) != nil { urls.append(url) }
        }
        urls.append(NameCard.file(for: who))
        shared = urls
    }
}
