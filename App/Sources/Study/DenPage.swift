import Craft
import SwiftUI

/// 斗室 with its 笔砚: the little Linux, and a line to type commands into.
struct DenPage: View {
    @ObservedObject var den = Den.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                        LazyVStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
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
                        if reduceMotion {
                            proxy.scrollTo("end", anchor: .bottom)
                        } else {
                            withAnimation(.linear(duration: 0.12)) { proxy.scrollTo("end", anchor: .bottom) }
                        }
                    }
                }
                DenCommandComposer { typed in
                    queue(typed)
                }
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
            .detentPaperBackdrop()
        }
        .sheet(isPresented: $den.showingDNSSettings) {
            DenDNSSettingsSheet(den: den)
                .detentPaperBackdrop()
        }
    }

    private var header: some View {
        HStack(spacing: Ink.Space.m) {
            VStack(alignment: .leading, spacing: 0) {
                Text(L.t("nav.terminal")).font(Ink.serif(Ink.Size.title, bold: true)).foregroundStyle(Ink.ink)
                HStack(spacing: Ink.Space.xs) {
                    Image(systemName: statusSymbol)
                        .font(.system(size: Ink.Size.micro, weight: .semibold))
                        .foregroundStyle(dot)
                        .accessibilityHidden(true)
                    Text(status).font(Ink.footnote).foregroundStyle(Ink.inkSoft)
                }
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: 0)
            if !den.running.isEmpty {
                Button(L.t("actions.stop")) {
                    Haptics.lock()
                    line?.cancel()
                    line = nil
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
                    .frame(width: Ink.Bar.height, height: Ink.Bar.height)
                    .glassFace(in: Circle())
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel(L.t("terminal.tools"))
            Menu {
                Button(Words.t("网络与 DNS"), systemImage: "network") { den.showingDNSSettings = true }
                Button(L.t("actions.installCommonPackages"), systemImage: "shippingbox") { outfitting = true }
                Button(L.t("actions.clearTerminal"), systemImage: "eraser") { den.clear() }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: Ink.Size.sub, weight: .semibold))
                    .foregroundStyle(Ink.ink)
                    .frame(width: Ink.Bar.height, height: Ink.Bar.height)
                    .glassFace(in: Circle())
            }
            .accessibilityLabel("更多终端操作")
            Button(L.t("actions.done")) {
                Haptics.light()
                dismiss()
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
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

    private var statusSymbol: String {
        switch den.state {
        case .awake: den.running.isEmpty ? "checkmark.circle.fill" : "play.circle.fill"
        case .broken: "exclamationmark.triangle.fill"
        default: "clock.fill"
        }
    }

    private var status: String {
        switch den.state {
        case .asleep: "未启动"
        case .unpacking: "第一次打开，正在准备（要一会儿）"
        case .waking: "正在启动"
        case .awake: den.running.isEmpty ? "Alpine Linux · 就绪" : "正在运行"
        case .broken(let why): why.hasPrefix("异常") ? why : "异常 · \(why)"
        }
    }

    @ViewBuilder
    private var intro: some View {
        if den.log.isEmpty {
            Text(L.t("terminal.alpineNote"))
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

    private func queue(_ typed: String) {
        let before = self.line
        self.line = Task {
            await withTaskCancellationHandler {
                await before?.value
            } onCancel: {
                before?.cancel()
            }
            guard !Task.isCancelled else { return }
            _ = await den.run(typed, timeout: 900)
        }
    }
}

/// Isolated terminal command input bar owning its own draft & history state so keystrokes never re-diff `den.log`.
private struct DenCommandComposer: View {
    let onSubmit: (String) -> Void

    @State private var command = ""
    @State private var history: [String] = []
    @State private var back = 0
    @FocusState private var typing: Bool

    var body: some View {
        HStack(spacing: Ink.Space.s) {
            Text("#").font(Ink.mono(Ink.Size.body, weight: .semibold)).foregroundStyle(Ink.accent)
            TextField(L.t("terminal.command"), text: $command)
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
                    Image(systemName: "arrow.up")
                        .font(.system(size: Ink.Size.sub, weight: .semibold))
                        .foregroundStyle(Ink.inkSoft)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(L.t("actions.previousCommand"))
            }
            Button(action: send) {
                Image(systemName: "return")
                    .font(.system(size: Ink.Size.sub, weight: .semibold))
                    .foregroundStyle(Ink.paper)
                    .frame(width: 34, height: 34)
                    .background(command.isEmpty ? Ink.inkFaint : Ink.accent, in: .circle)
            }
            .accessibilityLabel("运行命令")
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
        onSubmit(typed)
    }
}

private struct DenDNSSettingsSheet: View {
    @ObservedObject var den: Den
    @Environment(\.dismiss) private var dismiss

    @State private var mode: DenDNSMode = Den.shared.dnsMode
    @State private var customText: String = Den.shared.customDNSInput
    @State private var validationNote: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(Words.t("DNS 模式"), selection: $mode) {
                        Text(Words.t("跟随系统（自动）")).tag(DenDNSMode.auto)
                        Text(Words.t("自定义 DNS")).tag(DenDNSMode.custom)
                    }
                    .pickerStyle(.segmented)

                    if mode == .auto {
                        Text(Words.t("网络切换时自动同步系统 DNS 与搜索域；若系统暂时未返回 DNS，会保留最近一次有效配置，不会擅自切到公共 DNS。"))
                            .font(Ink.footnote)
                            .foregroundStyle(Ink.inkSoft)
                    } else {
                        TextField("例如：192.168.1.1, 10.0.0.2 或 fe80::1%en0", text: $customText, axis: .vertical)
                            .font(Ink.mono(Ink.Size.sub))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Text(Words.t("仅接受合法的 IPv4 / IPv6 地址（可用逗号、分号或换行分隔，支持 IPv6 %网卡后缀）。"))
                            .font(Ink.footnote)
                            .foregroundStyle(Ink.inkSoft)
                    }

                    if let validationNote {
                        Text(validationNote)
                            .font(Ink.footnote)
                            .foregroundStyle(.red)
                    } else if let runtimeError = den.lastDNSError {
                        Text(runtimeError)
                            .font(Ink.footnote)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text(Words.t("斗室网络解析"))
                }

                Section {
                    if den.appliedDNSServers.isEmpty {
                        Text(Words.t("尚未写入可用 DNS，联网或保存设置后生效"))
                            .font(Ink.footnote)
                            .foregroundStyle(Ink.inkFaint)
                    } else {
                        ForEach(den.appliedDNSServers, id: \.self) { server in
                            Text(server)
                                .font(Ink.mono(Ink.Size.sub))
                                .foregroundStyle(Ink.ink)
                        }
                    }
                    if !den.appliedSearchDomains.isEmpty {
                        Text("search " + den.appliedSearchDomains.joined(separator: " "))
                            .font(Ink.mono(Ink.Size.micro))
                            .foregroundStyle(Ink.inkSoft)
                    }
                } header: {
                    Text(Words.t("当前生效配置"))
                }
            }
            .navigationTitle(Words.t("网络与 DNS"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L.t("actions.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L.t("actions.save")) { save() }
                }
            }
            .onAppear {
                mode = den.dnsMode
                customText = den.customDNSInput
                validationNote = nil
            }
        }
    }

    private func save() {
        let parsed = DenDNSConfig.parseCustomDNSList(customText)
        if mode == .custom && parsed.valid.isEmpty {
            validationNote = "请填写至少一个合法的 IPv4 或 IPv6 地址"
            return
        }
        if mode == .custom && !parsed.invalid.isEmpty {
            validationNote = "存在无效地址：\(parsed.invalid.joined(separator: "、"))"
            return
        }
        validationNote = nil
        _ = den.updateDNSConfiguration(mode: mode, customInput: customText)
        dismiss()
    }
}
