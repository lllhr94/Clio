import SwiftUI

/// 笺: a reply set as a page to keep or share — with the question it answered, as one long picture of the exchange.
struct NoteSheet: View {
    let text: String
    let from: String
    /// What was asked, shown above the answer when 「带上我的问题」 is on.
    var question: String? = nil
    var bot: BotInfo? = nil
    @State private var withQuestion = true
    @Environment(\.dismiss) private var dismiss
    @State private var theme: Theme = .paper
    @State private var title: String
    @State private var signed = true
    @State private var saved = false

    enum Theme: String, CaseIterable {
        case paper = "纸"
        case ink = "墨"
        case blossom = "樱"

        var ground: Color {
            switch self {
            case .paper: Ink.Artwork.paper
            case .ink: Ink.Artwork.darkPaper
            case .blossom: Ink.Artwork.blossom
            }
        }

        var words: Color {
            switch self {
            case .paper: Ink.Artwork.paperText
            case .ink: Ink.Artwork.darkPaperText
            case .blossom: Ink.Artwork.blossomText
            }
        }
    }

    init(text: String, from: String, question: String? = nil, bot: BotInfo? = nil) {
        self.text = text
        self.from = from
        self.question = question
        self.bot = bot
        let first = text.split(separator: "\n").first.map(String.init) ?? ""
        let bare = first.replacingOccurrences(of: "#", with: "").replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespaces)
        _title = State(initialValue: bare.count <= 14 ? bare : "")
    }

    /// The body, without a first line that became the title.
    private var body_: String {
        guard !title.isEmpty, let firstBreak = text.firstIndex(of: "\n") else { return text }
        let first = text[..<firstBreak].replacingOccurrences(of: "#", with: "").replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespaces)
        return first == title ? String(text[text.index(after: firstBreak)...]).trimmingCharacters(in: .whitespacesAndNewlines) : text
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Ink.Space.xl) {
                    sheet
                        .clipShape(.rect(cornerRadius: Ink.Radius.card, style: .continuous))
                        .shadow(color: Ink.Artwork.black.opacity(0.10), radius: Ink.Space.l, y: Ink.Space.s)
                    HStack(spacing: Ink.Space.s) {
                        ForEach(Theme.allCases, id: \.self) { item in
                            Button {
                                withAnimation(Ink.Motion.settle) { theme = item }
                            } label: {
                                HStack(spacing: Ink.Space.s) {
                                    Circle().fill(item.ground)
                                        .overlay(Circle().strokeBorder(Ink.rule, lineWidth: 1))
                                        .frame(width: 18, height: 18)
                                    Text(item.rawValue).font(Ink.label).foregroundStyle(Ink.ink)
                                }
                                .padding(.horizontal, Ink.Space.l)
                                .frame(height: 40)
                                .background(theme == item ? Ink.paperRaised : .clear, in: .capsule)
                                .overlay(Capsule().strokeBorder(theme == item ? Ink.accent.opacity(0.5) : Ink.rule, lineWidth: 1))
                            }
                            .buttonStyle(PressStyle())
                        }
                    }
                    VStack(spacing: Ink.Space.m) {
                        TextField("题目（可空）", text: $title)
                            .font(Ink.label)
                            .padding(.horizontal, Ink.Space.l)
                            .frame(height: 46)
                            .paperCard()
                        if question?.isEmpty == false {
                            Toggle("带上我的问题", isOn: $withQuestion)
                                .font(Ink.label)
                                .tint(Ink.accent)
                                .padding(.horizontal, Ink.Space.l)
                                .frame(height: 46)
                                .paperCard()
                        }
                        Toggle("落款写上\(from)", isOn: $signed)
                            .font(Ink.label)
                            .tint(Ink.accent)
                            .padding(.horizontal, Ink.Space.l)
                            .frame(height: 46)
                            .paperCard()
                    }
                }
                .padding(.horizontal, Ink.Space.page)
                .padding(.vertical, Ink.Space.xl)
            }
            .background(Ink.paper)
            .navigationTitle(L.t("chat.note"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L.t("actions.cancel")) { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button(saved ? "已存" : "存入相册", systemImage: saved ? "checkmark" : "square.and.arrow.down") { save() }
                    if let image = rendered() {
                        ShareLink(item: Image(uiImage: image), preview: SharePreview(title.isEmpty ? "笺" : title, image: Image(uiImage: image)))
                    }
                }
            }
        }
    }

    private var sheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !title.isEmpty {
                Text(title)
                    .font(Ink.serif(Ink.Size.title, bold: true, relativeTo: .largeTitle))
                    .foregroundStyle(theme.words)
                    .padding(.top, Ink.Space.huge)
                Rectangle().fill(theme.words.opacity(0.18)).frame(height: 1).padding(.vertical, Ink.Space.xl)
            } else {
                Spacer().frame(height: Ink.Space.huge)
            }
            if withQuestion, let question, !question.isEmpty {
                // The question, as a quiet slip above the answer.
                HStack(alignment: .top, spacing: Ink.Space.s) {
                    Text("问").font(Ink.serif(Ink.Size.small, bold: true)).foregroundStyle(theme.words.opacity(0.5))
                    Text(question)
                        .font(Ink.serif(Ink.Size.sub))
                        .foregroundStyle(theme.words.opacity(0.75))
                        .lineLimit(8)
                }
                .padding(Ink.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.words.opacity(0.06), in: .rect(cornerRadius: Ink.Radius.small, style: .continuous))
                .padding(.bottom, Ink.Space.xl)
            }
            ProseView(text: body_)
                .foregroundStyle(theme.words)
                .environment(\.noteInk, theme.words)
            HStack(spacing: Ink.Space.s) {
                Spacer()
                PetStill(size: 22, wash: theme.words.opacity(0.14), avatar: true, bot: bot)
                Text(signed ? "\(from) · Clio" : "Clio")
                    .font(Ink.serif(Ink.Size.small, relativeTo: .footnote))
                    .foregroundStyle(theme.words.opacity(0.6))
                if signed, let bot { ClioSeal(size: 18, tilt: -4, character: ClioSeal.character(for: bot)) }
                Spacer()
            }
            .padding(.top, Ink.Space.huge)
            .padding(.bottom, Ink.Space.xxl)
        }
        .padding(.horizontal, Ink.Space.xxl)
        .frame(width: 390, alignment: .leading)
        .background(theme.ground)
    }

    @MainActor
    private func rendered() -> UIImage? {
        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 3
        return renderer.uiImage
    }

    private func save() {
        guard let image = rendered() else { return }
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        Haptics.thud()
        withAnimation(Ink.Motion.settle) { saved = true }
    }
}

private struct NoteInkKey: EnvironmentKey {
    static let defaultValue: Color? = nil
}

extension EnvironmentValues {
    /// Set by a note: reading text takes the note's ink instead of the page's.
    var noteInk: Color? {
        get { self[NoteInkKey.self] }
        set { self[NoteInkKey.self] = newValue }
    }
}
