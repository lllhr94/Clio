import SwiftUI

/// 絮语页: the conversation now, and the ones put aside. Turn a new leaf, or bring an old one back.
struct LeavesSheet: View {
    @ObservedObject var team: TeamModel
    let key: String
    let name: String
    @Environment(\.dismiss) private var dismiss
    @State private var folding = false
    @State private var note: String?
    @State private var showDigest = false

    private var leaves: [TeamModel.Leaf] { team.leaves(key) }
    private var hasCurrent: Bool { team.history(key).contains { $0.note != true } }

    var body: some View {
        NavigationStack {
            content
        }
    }

    private func fold() {
        folding = true
        note = nil
        Task {
            do {
                let count = try await team.compress(key)
                note = "压好了：较早的 \(count) 条写成了前情提要。"
                Haptics.thud()
            } catch {
                note = error.localizedDescription
                Haptics.lock()
            }
            folding = false
        }
    }

    private var content: some View {
        Group {
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

                        Button {
                            fold()
                        } label: {
                            HStack(spacing: Ink.Space.m) {
                                if folding { ProgressView().frame(width: 22) } else {
                                    Image(systemName: "rectangle.compress.vertical").font(.system(size: 18)).foregroundStyle(Ink.accent)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(folding ? "正在写前情提要…" : "压缩前文").font(Ink.serif(17, bold: true)).foregroundStyle(Ink.ink)
                                    Text("较早的话写成一份前情提要，只留最近 \(Pref.keepRecent) 条原样。聊得久、回复变慢时用。原文会收进下面。")
                                        .font(Ink.footnote).foregroundStyle(Ink.inkSoft)
                                    Text("眼下约 \(team.size(of: key) / 1000) 千字" + (Pref.autoCompress ? "，超过 \(Pref.compressAt / 1000) 千字会自动压缩" : ""))
                                        .font(Ink.footnote).foregroundStyle(Ink.inkFaint)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(Ink.Space.l)
                            .paperCard()
                        }
                        .buttonStyle(PressStyle())
                        .disabled(folding || !hasCurrent)

                        if let note {
                            Text(note).font(Ink.footnote).foregroundStyle(Ink.inkSoft).padding(.horizontal, Ink.Space.xs)
                        }

                        if let digest = team.summary(key) {
                            VStack(alignment: .leading, spacing: Ink.Space.s) {
                                Button {
                                    withAnimation(Ink.Motion.unfold) { showDigest.toggle() }
                                } label: {
                                    HStack {
                                        Text("前情提要").font(Ink.serif(15, bold: true)).foregroundStyle(Ink.inkSoft)
                                        Spacer()
                                        Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).foregroundStyle(Ink.inkFaint)
                                            .rotationEffect(.degrees(showDigest ? -180 : 0))
                                    }
                                }
                                .buttonStyle(TapStyle())
                                if showDigest {
                                    ProseView(text: digest)
                                        .padding(Ink.Space.l)
                                        .paperCard()
                                        .transition(.opacity)
                                }
                            }
                            .padding(.horizontal, Ink.Space.xs)
                        }

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
