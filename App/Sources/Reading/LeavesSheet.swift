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
    @State private var editingDigest = false
    @State private var digestDraft = ""
    @State private var unfolding: TeamModel.Leaf?

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
                                    if editingDigest {
                                        TextEditor(text: $digestDraft)
                                            .font(Ink.reading)
                                            .frame(minHeight: 220)
                                            .scrollContentBackground(.hidden)
                                            .padding(Ink.Space.m)
                                            .paperCard()
                                        HStack {
                                            Button("算了") {
                                                withAnimation(Ink.Motion.settle) { editingDigest = false }
                                            }
                                            Spacer()
                                            Button("存好") {
                                                team.editSummary(key, digestDraft)
                                                Haptics.thud()
                                                withAnimation(Ink.Motion.settle) { editingDigest = false }
                                                note = "前情提要改好了，之后的回复会照新的来。"
                                            }
                                            .fontWeight(.semibold)
                                        }
                                        .font(.system(size: 15))
                                    } else {
                                        ProseView(text: digest)
                                            .padding(Ink.Space.l)
                                            .paperCard()
                                            .transition(.opacity)
                                        HStack(spacing: Ink.Space.l) {
                                            Button("改一改", systemImage: "pencil") {
                                                digestDraft = digest
                                                withAnimation(Ink.Motion.settle) { editingDigest = true }
                                            }
                                            if let fold = team.undoableFold(key) {
                                                Button("拆开此叶，撤销压缩", systemImage: "arrow.uturn.backward") { unfolding = fold }
                                            }
                                        }
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(Ink.accent)
                                        .buttonStyle(TapStyle())
                                    }
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
            .confirmationDialog("拆开压缩？", isPresented: Binding(get: { unfolding != nil }, set: { if !$0 { unfolding = nil } }), titleVisibility: .visible) {
                Button("拆开，原文放回来") {
                    if let fold = unfolding {
                        withAnimation(Ink.Motion.unfold) { team.unfold(key, fold) }
                        Haptics.thud()
                        note = "拆开了：压缩前的原文放回了絮语里，前情提要退回压缩前的样子。"
                    }
                    unfolding = nil
                }
                Button("算了", role: .cancel) { unfolding = nil }
            } message: {
                Text("压缩前的整段原文会放回絮语里，压缩之后说的话都还在。前情提要退回压缩之前的样子。")
            }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("好了") { dismiss() } } }
        }
    }
}
