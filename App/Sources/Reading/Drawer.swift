import SwiftUI

/// Everything the desk can open, behind the whale: companions, tools, and settings, each with a line on what it is for.
enum DrawerItem: String, Identifiable, CaseIterable {
    case newCompanion, importCard, gathering, portrait
    case study, den, hills, vault
    case tuning, look, grants, care

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newCompanion: Words.t("新旅伴")
        case .importCard: Words.t("收名帖")
        case .gathering: Words.t("雅集")
        case .portrait: "形象"
        case .study: Words.t("书案")
        case .den: Words.t("斗室")
        case .hills: Words.t("远山")
        case .vault: Words.t("信匣")
        case .tuning: Words.t("调弦")
        case .look: Words.t("纸墨与絮语")
        case .grants: Words.t("应许")
        case .care: Words.t("养护")
        }
    }

    var line: String {
        switch self {
        case .newCompanion: Words.t("写一张名帖，请一位新旅伴")
        case .importCard: Words.t("导入别人递来的名帖文件")
        case .gathering: Words.t("让几位旅伴围坐着一起聊")
        case .portrait: "换成别的样子，或用自己的画像"
        case .study: Words.t("旅伴写下的文件都在这里")
        case .den: "手机里的 Linux，能装软件、跑脚本"
        case .hills: "你的 VPS 和 MCP 服务"
        case .vault: Words.t("账号密码，旅伴只拿得到编号")
        case .tuning: Words.t("模型服务、密钥和拾遗")
        case .look: "字体字号、明暗、压缩与上下文"
        case .grants: Words.t("旅伴能做什么，一项项由你定")
        case .care: "备份、恢复、诊断"
        }
    }

    var symbol: String {
        switch self {
        case .newCompanion: "person.badge.plus"
        case .importCard: "square.and.arrow.down"
        case .gathering: "person.3"
        case .portrait: "paintpalette"
        case .study: "books.vertical"
        case .den: "terminal"
        case .hills: "mountain.2"
        case .vault: "lock.rectangle.stack"
        case .tuning: "slider.horizontal.3"
        case .look: "textformat.size"
        case .grants: "checkmark.seal"
        case .care: "stethoscope"
        }
    }

    static let groups: [(String, [DrawerItem])] = [
        ("旅伴", [.newCompanion, .gathering, .portrait, .importCard]),
        ("器物", [.study, .den, .hills, .vault]),
        ("调理", [.tuning, .look, .grants, .care]),
    ]
}

/// The drawer itself: three groups of cards, two to a row.
struct DrawerSheet: View {
    let pick: (DrawerItem) -> Void
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.flexible(), spacing: Ink.Space.m), GridItem(.flexible(), spacing: Ink.Space.m)]

    var body: some View {
        ZStack {
            Ink.paper.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: Ink.Space.xl) {
                    HStack(alignment: .center, spacing: Ink.Space.m) {
                        Whale(size: 44, pose: .idle, still: true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("抽屉").font(Ink.title).foregroundStyle(Ink.ink)
                            Text(Words.t("案头以外的东西，都收在这里。")).font(Ink.footnote).foregroundStyle(Ink.inkSoft)
                        }
                        Spacer()
                        Button {
                            Haptics.light()
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Ink.inkSoft)
                                .frame(width: 32, height: 32)
                                .background(Ink.mine, in: .circle)
                        }
                        .accessibilityLabel("关上抽屉")
                    }
                    ForEach(DrawerItem.groups, id: \.0) { group in
                        VStack(alignment: .leading, spacing: Ink.Space.s) {
                            Text(group.0)
                                .font(Ink.serif(15, bold: true))
                                .foregroundStyle(Ink.inkSoft)
                                .padding(.leading, Ink.Space.xs)
                            LazyVGrid(columns: columns, spacing: Ink.Space.m) {
                                ForEach(group.1) { item in card(item) }
                            }
                        }
                    }
                }
                .padding(.horizontal, Ink.Space.page)
                .padding(.vertical, Ink.Space.l)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func card(_ item: DrawerItem) -> some View {
        Button {
            Haptics.tick(0.5)
            pick(item)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: Ink.Space.s) {
                Image(systemName: item.symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Ink.accent)
                    .frame(width: 34, height: 34)
                    .background(Ink.accentWash, in: .rect(cornerRadius: Ink.Radius.small))
                Text(item.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.ink).lineLimit(1)
                Text(item.line).font(Ink.footnote).foregroundStyle(Ink.inkSoft).lineLimit(2).multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(Ink.Space.m)
            .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
            .paperCard()
        }
        .buttonStyle(PressStyle(haptic: false))
        .accessibilityHint(item.line)
    }
}
