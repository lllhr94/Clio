import AgentKit
import SwiftUI

/// Connects a model service. On first launch it begins with a short welcome; from 调弦 it goes straight to the service.
struct SetupView: View {
    @ObservedObject var team: TeamModel
    /// Shown on first launch: a welcome first, and no way out until a service is connected.
    var first = false
    var onDone: () -> Void

    private enum Step { case welcome, service, done }

    @Environment(\.openURL) private var openURL
    @State private var step: Step = .service
    @State private var choice = Endpoint.presets[0]
    @State private var key = ""
    @State private var baseURL = ""
    @State private var name = ""
    @State private var modelName = ""
    @State private var busy = false
    @State private var advice: Explain.Advice?
    @State private var connected: Endpoint?
    @FocusState private var keyFocused: Bool

    private var custom: Bool { choice.id == "custom" }

    /// Services that speak the OpenAI way, with their addresses filled in for you.
    private static let compatible: [(name: String, url: String, note: String)] = [
        ("Kimi", "https://api.moonshot.cn/v1", "月之暗面"),
        ("通义千问", "https://dashscope.aliyuncs.com/compatible-mode/v1", "阿里云百炼"),
        ("豆包", "https://ark.cn-beijing.volces.com/api/v3", "火山方舟"),
        ("硅基流动", "https://api.siliconflow.cn/v1", "多家开源模型"),
        ("OpenRouter", "https://openrouter.ai/api/v1", "海外，模型最全"),
    ]

    var body: some View {
        ZStack {
            Ink.paper.ignoresSafeArea()
            switch step {
            case .welcome: welcome.transition(.blurReplace)
            case .service: service.transition(.blurReplace)
            case .done: done.transition(.blurReplace)
            }
        }
        .animation(Ink.Motion.unfold, value: step)
        .onAppear { step = first ? .welcome : .service }
    }

    // MARK: Welcome

    private var welcome: some View {
        VStack(alignment: .leading, spacing: Ink.Space.xl) {
            Spacer(minLength: 0)
            Whale(size: 120, pose: .idle)
            VStack(alignment: .leading, spacing: Ink.Space.s) {
                Text("你好，这里是 Clio").font(Ink.display).foregroundStyle(Ink.ink)
                Text("几位住在你手机里的旅伴。").font(Ink.reading).foregroundStyle(Ink.inkSoft)
            }
            VStack(alignment: .leading, spacing: Ink.Space.l) {
                point("lock", "对话只在这台手机上", "不经过任何人的服务器，旅伴直接用你自己的密钥连模型。")
                point("globe", "会上网，也会动手", "搜索、开网页、在手机里的小 Linux 跑脚本，替你记日程。")
                point("checkmark.seal", "大事都先问你", "加日程、填网页、连服务器这类事，旅伴会递一张笺等你落印。")
            }
            Spacer(minLength: 0)
            Button {
                Haptics.light()
                step = .service
            } label: {
                Text("开始：接上一个模型")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Ink.paper)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Ink.accent, in: .capsule)
            }
            .buttonStyle(PressStyle(haptic: false))
        }
        .padding(.horizontal, Ink.Space.page + 4)
        .padding(.vertical, Ink.Space.xl)
    }

    private func point(_ icon: String, _ title: String, _ words: String) -> some View {
        HStack(alignment: .top, spacing: Ink.Space.m) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Ink.accent)
                .frame(width: 32, height: 32)
                .background(Ink.accentWash, in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Ink.ink)
                Text(words).font(Ink.secondary).foregroundStyle(Ink.inkSoft).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Service

    private var service: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Ink.Space.xl) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: Ink.Space.xs) {
                        Text(first ? "第一步 · 接一个模型" : "添一个模型服务").font(Ink.title).foregroundStyle(Ink.ink)
                        Text("旅伴靠它想事情、说话。之后随时能在调弦里再加。").font(Ink.secondary).foregroundStyle(Ink.inkSoft)
                    }
                    Spacer()
                    if !first {
                        Button {
                            Haptics.light()
                            onDone()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Ink.inkSoft)
                                .frame(width: 32, height: 32)
                                .background(Ink.mine, in: .circle)
                        }
                        .accessibilityLabel("关闭")
                    }
                }

                VStack(alignment: .leading, spacing: Ink.Space.s) {
                    FieldTitle(text: "选一家")
                    ForEach(Endpoint.presets) { preset in tile(preset) }
                }

                if custom {
                    VStack(alignment: .leading, spacing: Ink.Space.s) {
                        FieldTitle(text: "是哪一家", note: "点一个自动填好地址；不在里面就自己填")
                        ScrollView(.horizontal) {
                            HStack(spacing: Ink.Space.s) {
                                ForEach(Self.compatible, id: \.name) { item in
                                    Button {
                                        Haptics.tick(0.5)
                                        name = item.name
                                        baseURL = item.url
                                    } label: {
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(item.name).font(.system(size: 14, weight: .semibold))
                                            Text(item.note).font(.system(size: 11))
                                        }
                                        .foregroundStyle(baseURL == item.url ? Ink.accent : Ink.ink)
                                        .padding(.horizontal, Ink.Space.m)
                                        .padding(.vertical, Ink.Space.s)
                                        .background(baseURL == item.url ? Ink.accentWash : Ink.paperRaised, in: .rect(cornerRadius: Ink.Radius.small))
                                    }
                                    .buttonStyle(PressStyle(haptic: false))
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                        TextField("称呼，比如 Kimi", text: $name).paperField()
                        TextField("地址，https://…/v1", text: $baseURL)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .paperField()
                        TextField("模型名（可不填，会自动去拿）", text: $modelName)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .paperField()
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                VStack(alignment: .leading, spacing: Ink.Space.s) {
                    HStack {
                        FieldTitle(text: "密钥（API Key）", note: "只存在这台手机的钥匙串里")
                        Spacer()
                        if let help = helpURL {
                            Button("去哪拿？") { openURL(help) }
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Ink.accent)
                        }
                    }
                    HStack(spacing: Ink.Space.s) {
                        SecureField("sk-…", text: $key)
                            .font(.system(size: 16, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($keyFocused)
                        Button {
                            if let pasted = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !pasted.isEmpty {
                                key = pasted
                                Haptics.tick(0.5)
                            }
                        } label: {
                            Text("粘贴").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.accent)
                        }
                    }
                    .paperField()
                }

                if let advice {
                    VStack(alignment: .leading, spacing: Ink.Space.xs) {
                        Label(advice.title, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Ink.stop)
                        Text(advice.detail).font(Ink.secondary).foregroundStyle(Ink.inkSoft)
                    }
                    .padding(Ink.Space.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Ink.stop.opacity(0.08), in: .rect(cornerRadius: Ink.Radius.card))
                    .transition(.opacity)
                }

                Button(action: connect) {
                    HStack(spacing: Ink.Space.s) {
                        if busy { ProgressView().tint(Ink.paper) }
                        Text(busy ? "正在试连，顺便拿模型列表…" : "连上试试")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .foregroundStyle(Ink.paper)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(canConnect ? Ink.accent : Ink.inkFaint, in: .capsule)
                }
                .buttonStyle(PressStyle(haptic: false))
                .disabled(!canConnect)
            }
            .padding(.horizontal, Ink.Space.page)
            .padding(.vertical, Ink.Space.xl)
            .animation(Ink.Motion.settle, value: choice.id)
            .animation(Ink.Motion.settle, value: advice?.title)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollIndicators(.hidden)
    }

    private var canConnect: Bool { !busy && !key.trimmingCharacters(in: .whitespaces).isEmpty && (!custom || baseURL.hasPrefix("http")) }

    private var helpURL: URL? {
        switch choice.id {
        case "deepseek": return URL(string: "https://platform.deepseek.com/api_keys")
        case "claude": return URL(string: "https://console.anthropic.com/settings/keys")
        default: return nil
        }
    }

    private func tile(_ preset: Endpoint) -> some View {
        let picked = preset.id == choice.id
        let note: String = switch preset.id {
        case "deepseek": "便宜，中文好，国内直连。不能看图"
        case "claude": "最聪明，能看图；国内要能连外网"
        default: "Kimi、通义、豆包、硅基流动、OpenRouter 等"
        }
        return Button {
            Haptics.tick(0.6)
            choice = preset
            advice = nil
        } label: {
            HStack(spacing: Ink.Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(Ink.ink)
                    Text(note).font(Ink.footnote).foregroundStyle(Ink.inkSoft)
                }
                Spacer()
                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(picked ? Ink.accent : Ink.inkFaint)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.horizontal, Ink.Space.l)
            .padding(.vertical, Ink.Space.m)
            .background(picked ? Ink.paperRaised : Ink.paper, in: .rect(cornerRadius: Ink.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Ink.Radius.card).strokeBorder(picked ? Ink.accent.opacity(0.55) : Ink.rule, lineWidth: picked ? 1.5 : 1))
        }
        .buttonStyle(PressStyle(haptic: false))
    }

    // MARK: Done

    private var done: some View {
        VStack(alignment: .leading, spacing: Ink.Space.xl) {
            Spacer(minLength: 0)
            Whale(size: 110, pose: .writing)
            VStack(alignment: .leading, spacing: Ink.Space.s) {
                Text("接好了").font(Ink.display).foregroundStyle(Ink.ink)
                if let connected {
                    Text("\(connected.name) 能用 \(connected.models.count) 个模型，旅伴先用 \(team.modelTitle(team.settings.defaultModel))。")
                        .font(Ink.reading).foregroundStyle(Ink.inkSoft)
                }
                Text("想换模型，可以在调弦里改默认，也可以在聊天时从输入框下另选。")
                    .font(Ink.secondary).foregroundStyle(Ink.inkFaint)
            }
            Spacer(minLength: 0)
            Button {
                Haptics.thud()
                onDone()
            } label: {
                Text(first ? "去案头，见见旅伴" : "好了")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Ink.paper)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Ink.accent, in: .capsule)
            }
            .buttonStyle(PressStyle(haptic: false))
        }
        .padding(.horizontal, Ink.Space.page + 4)
        .padding(.vertical, Ink.Space.xl)
    }

    // MARK: Connecting

    private func connect() {
        let secret = key.trimmingCharacters(in: .whitespacesAndNewlines)
        var endpoint = choice
        if custom {
            let address = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            endpoint.baseURL = address
            endpoint.id = "custom-\(UUID().uuidString.prefix(6))"
            let given = name.trimmingCharacters(in: .whitespacesAndNewlines)
            endpoint.name = given.isEmpty ? (URL(string: address)?.host ?? "自定义") : given
        }
        busy = true
        advice = nil
        keyFocused = false
        Task {
            do {
                var models = try await endpoint.provider(key: secret).models()
                if endpoint.id == "deepseek" {
                    models = models.filter { $0.hasPrefix("deepseek") }
                } else if endpoint.kind == .anthropic {
                    models = models.filter { $0.hasPrefix("claude") }
                }
                let typed = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !typed.isEmpty, !models.contains(typed) { models.insert(typed, at: 0) }
                guard !models.isEmpty else { throw TeamError(message: "连上了，但没找到能用的模型。请填上模型名再试。") }
                endpoint.models = models
                finish(endpoint, secret)
            } catch {
                // Some services do not list their models; a typed name is enough to go on.
                let typed = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
                if custom, !typed.isEmpty, (error as? ProviderError)?.status != 401 {
                    endpoint.models = [typed]
                    finish(endpoint, secret)
                    return
                }
                busy = false
                Haptics.lock()
                if let plain = error as? TeamError {
                    advice = Explain.Advice(title: plain.message, detail: "", next: nil)
                } else {
                    advice = Explain.model(error, service: endpoint.name)
                }
            }
        }
    }

    private func finish(_ endpoint: Endpoint, _ secret: String) {
        team.addEndpoint(endpoint, key: secret)
        busy = false
        connected = endpoint
        Haptics.thud()
        step = .done
    }
}
