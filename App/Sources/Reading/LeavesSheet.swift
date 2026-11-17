import SwiftUI

/// 絮语页: the conversation now, and the ones put aside. Turn a new leaf, or bring an old one back.
struct LeavesSheet: View {
    @ObservedObject var team: TeamModel
    let key: String
    let name: String
    @Environment(\.dismiss) private var dismiss

    private var leaves: [TeamModel.Leaf] { team.leaves(key) }
    private var hasCurrent: Bool { team.history(key).contains { $0.note != true } }

    var body: some View {
        NavigationStack {
            ZStack {
                Ink.paper.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: Ink.Space.l) {
                        Button {
                            Haptics.thud()
                            withAnimation(Ink.Motion.unfold) { team.turnLeaf(key) }
                            dismiss()
                        } label: {
                            HStack(spacing: Ink.Space.m) {
                                Image(systemName: "square.and.pencil").font(.system(size: 18)).foregroundStyle(Ink.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("另起一叶").font(Ink.serif(17, bold: true)).foregroundStyle(Ink.ink)
                                    Text(hasCurrent ? "眼下这段絮语收进下面，和\(name)从头聊起" : "眼下还是空白一页")
                                        .font(Ink.footnote).foregroundStyle(Ink.inkSoft)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(Ink.Space.l)
                            .paperCard()
                        }
                        .buttonStyle(PressStyle())
                        .disabled(!hasCurrent)

                        if leaves.isEmpty {
                            Text("还没有收起来的絮语。话题聊远了，就另起一叶；旧的会留在这里，随时翻回去。")
                                .font(Ink.footnote)
                                .foregroundStyle(Ink.inkFaint)
                                .padding(.horizontal, Ink.Space.xs)
                        } else {
                            Text("收起的絮语").font(Ink.serif(15, bold: true)).foregroundStyle(Ink.inkSoft).padding(.leading, Ink.Space.xs)
                            VStack(spacing: 0) {
                                ForEach(leaves) { leaf in
                                    Button {
                                        Haptics.tick(0.7)
                                        withAnimation(Ink.Motion.unfold) { team.openLeaf(key, leaf) }
                                        dismiss()
                                    } label: {
                                        HStack(spacing: Ink.Space.m) {
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(leaf.title).font(.system(size: 16)).foregroundStyle(Ink.ink).lineLimit(1)
                                                Text("\(Date(timeIntervalSince1970: leaf.at / 1000).formatted(.relative(presentation: .named))) · \(leaf.count) 条")
                                                    .font(Ink.footnote).foregroundStyle(Ink.inkFaint)
                                            }
                                            Spacer(minLength: 0)
                                            Text("翻回").font(.system(size: 13, weight: .medium)).foregroundStyle(Ink.accent)
                                        }
                                        .padding(.horizontal, Ink.Space.l)
                                        .padding(.vertical, Ink.Space.m)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(PressStyle())
                                    .contextMenu {
                                        Button("撕掉这一叶", systemImage: "trash", role: .destructive) {
                                            withAnimation(Ink.Motion.settle) { team.dropLeaf(key, leaf) }
                                        }
                                    }
                                    if leaf.id != leaves.last?.id { Rectangle().fill(Ink.rule).frame(height: 1).padding(.leading, Ink.Space.l) }
                                }
                            }
                            .paperCard()
                            Text("长按一叶可以撕掉。翻回旧的一叶时，眼下的絮语会自动收起来。")
                                .font(Ink.footnote).foregroundStyle(Ink.inkFaint).padding(.horizontal, Ink.Space.xs)
                        }
                    }
                    .padding(.horizontal, Ink.Space.page)
                    .padding(.vertical, Ink.Space.l)
                }
            }
            .navigationTitle("絮语页")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("好了") { dismiss() } } }
        }
    }
}
