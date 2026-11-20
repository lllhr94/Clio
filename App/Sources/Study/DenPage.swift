import SwiftUI

/// 斗室 with its 笔砚: the little Linux, and a line to type commands into.
struct DenPage: View {
    @ObservedObject var den = Den.shared
    @Environment(\.dismiss) private var dismiss
    @State private var command = ""
    @State private var history: [String] = []
    @State private var back = 0
    @FocusState private var typing: Bool
    /// Commands typed while one is still running wait their turn, so output never interleaves.
    @State private var line: Task<Void, Never>?
    @State private var inkstone = false
    @State private var outfitting = false

    var body: some View {
        ZStack {
            Ink.paper.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            intro
                            ForEach(den.log) { line in
                                text(for: line)
                                    .id(line.id)
                            }
                            Color.clear.frame(height: 8).id("end")
                        }
                        .padding(.horizontal, Ink.Space.l)
                        .padding(.vertical, Ink.Space.m)
                    }
                    .background(Ink.paperRaised)
                    .clipShape(.rect(cornerRadius: Ink.Radius.card, style: .continuous))
                    .padding(.horizontal, Ink.Space.m)
                    .onChange(of: den.log.count) { _, _ in
                        withAnimation(.linear(duration: 0.12)) { proxy.scrollTo("end", anchor: .bottom) }
                    }
                }
                composer
            }
        }
        .task { _ = await den.wake() }
        .hitchPage("斗室")
        .fullScreenCover(isPresented: $inkstone) { InkstonePage() }
        .sheet(isPresented: $outfitting) {
            OutfitSheet { command in
                outfitting = false
                if let command { queue(command) }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var header: some View {
        HStack(spacing: Ink.Space.m) {
            Button {
                Haptics.light()
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: Ink.Size.sub, weight: .semibold))
                    .foregroundStyle(Ink.ink)
                    .frame(width: 36, height: 36)
                    .glassFace(in: Circle())
            }
            .buttonStyle(PressStyle())
            VStack(alignment: .leading, spacing: 0) {
                Text(L.t("nav.terminal")).font(Ink.serif(19, bold: true)).foregroundStyle(Ink.ink)
                HStack(spacing: 4) {
                    Circle().fill(dot).frame(width: 6, height: 6)
                    Text(status).font(Ink.footnote).foregroundStyle(Ink.inkSoft)
                }
            }
            Spacer(minLength: 0)
            if !den.running.isEmpty {
                Button("停下") {
                    Haptics.lock()
                    den.stopAll()
                }
                .font(.system(size: Ink.Size.sub, weight: .semibold))
                .foregroundStyle(Ink.stop)
            }
            Button {
                Haptics.light()
                inkstone = true
            } label: {
                Image(systemName: "apple.terminal")
                    .font(.system(size: Ink.Size.sub, weight: .semibold))
                    .foregroundStyle(Ink.ink)
                    .frame(width: 36, height: 36)
                    .glassFace(in: Circle())
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("笔砚")
            Menu {
                Button("笔砚（真终端）", systemImage: "apple.terminal") { inkstone = true }
                Button("装常用软件", systemImage: "shippingbox") { outfitting = true }
                Button("清屏", systemImage: "eraser") { den.clear() }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: Ink.Size.sub, weight: .semibold))
                    .foregroundStyle(Ink.ink)
                    .frame(width: 36, height: 36)
                    .glassFace(in: Circle())
            }
        }
        .padding(.horizontal, Ink.Space.l)
        .padding(.vertical, Ink.Space.s)
    }

    private var dot: Color {
        switch den.state {
        case .awake: den.running.isEmpty ? Ink.ok : Ink.accent
        case .broken: Ink.stop
        default: Ink.warn
        }
    }

    private var status: String {
        switch den.state {
        case .asleep: "睡着"
        case .unpacking: "第一次打开，正在铺陈（要一会儿）"
        case .waking: "正在醒来"
        case .awake: den.running.isEmpty ? "Alpine Linux · 醒着" : "在跑"
        case .broken(let why): why
        }
    }

    @ViewBuilder
    private var intro: some View {
        if den.log.isEmpty {
            Text(Words.t("手机里的 Alpine Linux，书案在 /root/desk"))
                .font(Ink.secondary)
                .foregroundStyle(Ink.inkSoft)
                .padding(.bottom, Ink.Space.m)
        }
    }

    private func text(for line: Den.Line) -> some View {
        Group {
            switch line.kind {
            case .command:
                Text("# ").foregroundStyle(Ink.accent) + Text(line.text).foregroundStyle(Ink.ink).bold()
            case .out:
                Text(line.text).foregroundStyle(Ink.ink)
            case .error:
                Text(line.text).foregroundStyle(Ink.warn)
            case .note:
                Text("— \(line.text)").foregroundStyle(Ink.inkFaint)
            }
        }
        .font(Ink.mono(Ink.Size.small))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, line.kind == .command ? Ink.Space.s : 0)
    }

    private var composer: some View {
        HStack(spacing: Ink.Space.s) {
            Text("#").font(Ink.mono(Ink.Size.body, weight: .semibold)).foregroundStyle(Ink.accent)
            TextField("命令", text: $command)
                .font(Ink.mono(Ink.Size.sub))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.send)
                .focused($typing)
                .onSubmit(send)
            if !history.isEmpty {
                Button {
                    back = min(back + 1, history.count)
                    command = history[history.count - back]
                } label: {
                    Image(systemName: "arrow.up").font(.system(size: Ink.Size.sub, weight: .semibold)).foregroundStyle(Ink.inkSoft)
                }
                .accessibilityLabel("上一条")
            }
            Button(action: send) {
                Image(systemName: "return")
                    .font(.system(size: Ink.Size.sub, weight: .semibold))
                    .foregroundStyle(Ink.paper)
                    .frame(width: 34, height: 34)
                    .background(command.isEmpty ? Ink.inkFaint : Ink.accent, in: .circle)
            }
            .disabled(command.isEmpty)
        }
        .padding(.horizontal, Ink.Space.l)
        .padding(.vertical, Ink.Space.s)
        .glassBacking(in: Capsule())
        .padding(.horizontal, Ink.Space.m)
        .padding(.vertical, Ink.Space.s)
    }

    private func send() {
        let typed = command.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return }
        Haptics.tick(0.5)
        history.append(typed)
        back = 0
        command = ""
        queue(typed)
    }

    private func queue(_ typed: String) {
        let before = self.line
        self.line = Task {
            await before?.value
            _ = await den.run(typed, timeout: 900)
        }
    }
}
