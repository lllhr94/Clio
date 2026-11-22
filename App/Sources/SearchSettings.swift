import AgentKit
import SwiftUI
import UIKit

/// Stores web search provider selection and Keychain-backed API keys, and wires them into `AgentKit.WebSearchTool`.
enum SearchEngine {
    static let providerKey = "search.provider"
    static let fallbackKey = "search.fallbackToBuiltin"

    nonisolated static var primary: WebSearchProvider {
        get {
            guard let raw = UserDefaults.standard.string(forKey: providerKey),
                  let parsed = WebSearchProvider(rawValue: raw) else {
                return .anysearch
            }
            return parsed
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: providerKey)
        }
    }

    nonisolated static var fallbackToBuiltin: Bool {
        get {
            if UserDefaults.standard.object(forKey: fallbackKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: fallbackKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: fallbackKey)
        }
    }

    nonisolated static func vaultKey(for provider: WebSearchProvider) -> String {
        "search-key-\(provider.rawValue)"
    }

    /// Reads the saved Keychain key for a provider off the calling thread.
    static func readKey(for provider: WebSearchProvider) async -> String {
        guard provider.supportsKey else { return "" }
        let raw = await Vault.readString(vaultKey(for: provider)) ?? ""
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Saves or clears a provider's API key in the Keychain (never in UserDefaults or backups).
    static func saveKey(_ value: String, for provider: WebSearchProvider) async {
        guard provider.supportsKey else { return }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let keyName = vaultKey(for: provider)
        await Task.detached(priority: .userInitiated) {
            if trimmed.isEmpty {
                Vault.remove(keyName)
            } else {
                Vault.save(trimmed, as: keyName)
            }
        }.value
    }

    /// Snapshot of all configured key statuses (masked preview or empty) for the settings UI.
    static func keyPresence() async -> Set<WebSearchProvider> {
        var present: Set<WebSearchProvider> = []
        for provider in WebSearchProvider.allCases where provider.supportsKey {
            let key = await readKey(for: provider)
            if !key.isEmpty { present.insert(provider) }
        }
        return present
    }

    /// Builds the live `WebSearchConfig` for `WebSearchTool`.
    nonisolated static func currentConfig() async -> WebSearchConfig {
        let selected = primary
        let fallback = fallbackToBuiltin
        let key: String?
        if selected.supportsKey {
            let saved = await readKey(for: selected)
            key = saved.isEmpty ? nil : saved
        } else {
            key = nil
        }
        return WebSearchConfig(primary: selected, apiKey: key, fallbackToBuiltin: fallback)
    }

    /// Registers the live config loader on `WebSearchTool` at app startup.
    static func install() {
        WebSearchTool.setConfigLoader {
            await currentConfig()
        }
    }

    static func mask(_ key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.count <= 8 { return String(repeating: "•", count: trimmed.count) }
        return "\(trimmed.prefix(4))••••\(trimmed.suffix(4))"
    }
}

/// Settings page for choosing the web search backend (AnySearch, Tavily, Exa, Brave, or built-in Bing/DDG).
struct SearchSettingsPage: View {
    @AppStorage(SearchEngine.providerKey) private var providerRaw = WebSearchProvider.anysearch.rawValue
    @AppStorage(SearchEngine.fallbackKey) private var fallbackToBuiltin = true

    @State private var keyedProviders: Set<WebSearchProvider> = []
    @State private var savedMasked = ""
    @State private var keyInput = ""
    @State private var keyNotice: String?
    @State private var testing = false
    @State private var testQuery = "Swift 6"
    @State private var testResult: WebSearchTool.ProbeResult?

    private var selected: WebSearchProvider {
        WebSearchProvider(rawValue: providerRaw) ?? .anysearch
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Ink.Space.xl) {
                providerSection
                if selected.supportsKey {
                    keySection
                }
                fallbackAndTestSection
            }
            .padding(.horizontal, Ink.Space.page)
            .padding(.vertical, Ink.Space.l)
        }
        .background(Ink.paper.ignoresSafeArea())
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(L.t("settingsHome.searchEngine"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await reloadKeys() }
        .task(id: providerRaw) { await loadSelectedKey() }
    }

    // MARK: Provider picker

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle("主搜索源")
            VStack(spacing: 0) {
                ForEach(Array(WebSearchProvider.allCases.enumerated()), id: \.element.id) { index, provider in
                    if index > 0 { Kit.divider }
                    providerRow(provider)
                }
            }
            .paperCard()
            Text("联网搜索默认先走 AnySearch 免费通道；如果你有 Tavily、Exa 或 Brave 密钥，切过去并填上即可生效。")
                .font(.system(size: Ink.Size.small))
                .foregroundStyle(Ink.inkSoft)
                .padding(.horizontal, Ink.Space.l)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func providerRow(_ provider: WebSearchProvider) -> some View {
        let isSelected = provider == selected
        let hasKey = keyedProviders.contains(provider)
        let statusTag = providerBadge(for: provider, hasKey: hasKey)
        return Button {
            Haptics.tick(0.5)
            providerRaw = provider.rawValue
            keyNotice = nil
            testResult = nil
        } label: {
            HStack(spacing: Ink.Space.m) {
                IconBadge(symbol: providerIcon(provider), tint: isSelected ? Ink.Tile.xiang : Ink.Tile.mo)
                VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
                    HStack(spacing: Ink.Space.s) {
                        Text(provider.name)
                            .font(.system(size: Ink.Size.body, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(Ink.ink)
                        if let statusTag {
                            Text(statusTag.text)
                                .font(.system(size: Ink.Size.micro, weight: .semibold))
                                .foregroundStyle(statusTag.tint)
                                .padding(.horizontal, Ink.Space.s)
                                .padding(.vertical, Ink.Space.xs / 2)
                                .background(statusTag.tint.opacity(0.14), in: .capsule)
                        }
                    }
                    Text(provider.summary)
                        .font(.system(size: Ink.Size.small))
                        .foregroundStyle(Ink.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Ink.Space.s)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: Ink.Size.sub, weight: .semibold))
                        .foregroundStyle(Ink.accent)
                }
            }
            .padding(.horizontal, Ink.Space.l)
            .padding(.vertical, Ink.Space.m)
            .frame(minHeight: Kit.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(haptic: false))
    }

    private func providerIcon(_ provider: WebSearchProvider) -> String {
        switch provider {
        case .anysearch: "sparkles.rectangle.stack"
        case .tavily: "magnifyingglass.circle"
        case .exa: "brain.head.profile"
        case .brave: "shield"
        case .builtin: "globe"
        }
    }

    private func providerBadge(for provider: WebSearchProvider, hasKey: Bool) -> (text: String, tint: Color)? {
        switch provider {
        case .anysearch:
            return hasKey ? ("已填密钥", Ink.ok) : ("免密钥可用", Ink.accent)
        case .tavily, .exa, .brave:
            return hasKey ? ("已填密钥", Ink.ok) : ("需密钥", Ink.warn)
        case .builtin:
            return nil
        }
    }

    // MARK: Keychain API key editor

    private var keySection: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle("\(selected.shortName) 密钥")
            VStack(alignment: .leading, spacing: Ink.Space.m) {
                HStack(spacing: Ink.Space.s) {
                    SecureField(savedMasked.isEmpty ? "粘贴 \(selected.shortName) API Key" : savedMasked, text: $keyInput)
                        .font(Ink.mono(Ink.Size.sub))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if keyInput.isEmpty {
                        Button("粘贴") {
                            if let clip = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !clip.isEmpty {
                                keyInput = clip
                                Haptics.tick(0.4)
                            }
                        }
                        .font(.system(size: Ink.Size.small, weight: .semibold))
                        .foregroundStyle(Ink.accent)
                    } else {
                        Button(L.t("actions.save")) { saveCurrentKey() }
                            .font(.system(size: Ink.Size.sub, weight: .semibold))
                            .foregroundStyle(Ink.accent)
                    }
                }
                if !savedMasked.isEmpty {
                    Kit.rule(inset: 0)
                    HStack {
                        Text("已保存：\(savedMasked)")
                            .font(Ink.mono(Ink.Size.small))
                            .foregroundStyle(Ink.inkSoft)
                        Spacer()
                        Button("清除密钥", role: .destructive) { clearCurrentKey() }
                            .font(.system(size: Ink.Size.small, weight: .medium))
                            .foregroundStyle(Ink.stop)
                    }
                }
                if !selected.consoleHost.isEmpty {
                    Kit.rule(inset: 0)
                    Text("获取密钥：\(selected.consoleHost)")
                        .font(Ink.mono(Ink.Size.small))
                        .foregroundStyle(Ink.inkFaint)
                        .textSelection(.enabled)
                }
                if let keyNotice {
                    Text(keyNotice)
                        .font(.system(size: Ink.Size.small))
                        .foregroundStyle(Ink.ok)
                }
            }
            .padding(Ink.Space.l)
            .paperCard()

            Text(keyFootnote)
                .font(.system(size: Ink.Size.small))
                .foregroundStyle(Ink.inkSoft)
                .padding(.horizontal, Ink.Space.l)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var keyFootnote: String {
        if selected == .anysearch {
            return "不填密钥也能走免费匿名通道；填上免费密钥每天可用 1000 次、限流更少。密钥只存在本机钥匙串，不会发给模型，也不进备份。"
        }
        return "密钥只存在本机钥匙串里，不会发给模型，也不会进云端备份。"
    }

    // MARK: Fallback & Live Test

    private var fallbackAndTestSection: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle("兜底与测试")
            VStack(alignment: .leading, spacing: 0) {
                if selected != .builtin {
                    Toggle("失败或超额时自动回退内置网页", isOn: $fallbackToBuiltin)
                        .font(.system(size: Ink.Size.body))
                        .foregroundStyle(Ink.ink)
                        .tint(Ink.accent)
                        .padding(.horizontal, Ink.Space.l)
                        .frame(minHeight: Kit.rowHeight)
                    Kit.rule(inset: Ink.Space.l)
                }
                VStack(alignment: .leading, spacing: Ink.Space.m) {
                    HStack(spacing: Ink.Space.s) {
                        TextField("输入测试词", text: $testQuery)
                            .font(.system(size: Ink.Size.sub))
                            .submitLabel(.search)
                            .onSubmit { runProbe() }
                        if testing {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    Button(testing ? "正在试搜…" : "试搜一下") { runProbe() }
                        .buttonStyle(WideButtonStyle())
                        .disabled(testing || testQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let testResult {
                        probeResultView(testResult)
                    }
                }
                .padding(Ink.Space.l)
            }
            .paperCard()
        }
    }

    private func probeResultView(_ result: WebSearchTool.ProbeResult) -> some View {
        HStack(alignment: .top, spacing: Ink.Space.s) {
            Image(systemName: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(result.ok ? Ink.ok : Ink.stop)
            VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
                Text(result.ok ? "\(result.source) 可用，返回 \(result.count) 条结果" : "\(result.source) 试搜未通过")
                    .font(.system(size: Ink.Size.sub, weight: .semibold))
                    .foregroundStyle(Ink.ink)
                Text(result.detail)
                    .font(.system(size: Ink.Size.small))
                    .foregroundStyle(Ink.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Ink.Space.m)
        .background((result.ok ? Ink.ok : Ink.stop).opacity(0.10), in: .rect(cornerRadius: Ink.Radius.small, style: .continuous))
    }

    // MARK: Actions

    private func reloadKeys() async {
        keyedProviders = await SearchEngine.keyPresence()
        await loadSelectedKey()
    }

    private func loadSelectedKey() async {
        let current = await SearchEngine.readKey(for: selected)
        savedMasked = SearchEngine.mask(current)
        keyInput = ""
    }

    private func saveCurrentKey() {
        let value = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let target = selected
        Task {
            await SearchEngine.saveKey(value, for: target)
            keyedProviders.insert(target)
            savedMasked = SearchEngine.mask(value)
            keyInput = ""
            keyNotice = "已存入本机钥匙串。"
            testResult = nil
            Haptics.thud()
        }
    }

    private func clearCurrentKey() {
        let target = selected
        Task {
            await SearchEngine.saveKey("", for: target)
            keyedProviders.remove(target)
            savedMasked = ""
            keyInput = ""
            keyNotice = "已清除 \(target.shortName) 密钥。"
            testResult = nil
            Haptics.lock()
        }
    }

    private func runProbe() {
        let q = testQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !testing else { return }
        testing = true
        testResult = nil
        let target = selected
        let pendingInput = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let keyToUse: String?
            if !target.supportsKey {
                keyToUse = nil
            } else if !pendingInput.isEmpty {
                keyToUse = pendingInput
            } else {
                let saved = await SearchEngine.readKey(for: target)
                keyToUse = saved.isEmpty ? nil : saved
            }
            let config = WebSearchConfig(primary: target, apiKey: keyToUse, fallbackToBuiltin: false)
            let result = await WebSearchTool.probe(query: q, config: config)
            testResult = result
            testing = false
            if result.ok { Haptics.tick(0.6) } else { Haptics.lock() }
        }
    }
}
