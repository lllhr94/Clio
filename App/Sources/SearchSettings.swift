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
                return .builtin
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

/// Settings page for choosing the web search backend (built-in Bing/DDG by default, or opt-in AnySearch, Tavily, Exa, Brave).
struct SearchSettingsPage: View {
    @AppStorage(SearchEngine.providerKey) private var providerRaw = WebSearchProvider.builtin.rawValue
    @AppStorage(SearchEngine.fallbackKey) private var fallbackToBuiltin = true

    @State private var keyedProviders: Set<WebSearchProvider> = []
    @State private var savedMasked = ""
    @State private var keyInput = ""
    @State private var keyNotice: String?
    @State private var testing = false
    @State private var testQuery = "Swift 6"
    @State private var testResult: WebSearchTool.ProbeResult?
    @State private var selectionVersion = UUID()
    @State private var probeTask: Task<Void, Never>?

    private var selected: WebSearchProvider {
        WebSearchProvider(rawValue: providerRaw) ?? .builtin
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
        .onDisappear { probeTask?.cancel() }
    }

    // MARK: Provider picker

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle(L.t("searchSettings.primarySection"))
            VStack(spacing: 0) {
                ForEach(Array(WebSearchProvider.allCases.enumerated()), id: \.element.id) { index, provider in
                    if index > 0 { Kit.divider }
                    providerRow(provider)
                }
            }
            .paperCard()
            Text(L.t("searchSettings.primaryNote"))
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
            guard provider != selected else { return }
            Haptics.tick(0.5)
            probeTask?.cancel()
            probeTask = nil
            selectionVersion = UUID()
            providerRaw = provider.rawValue
            keyInput = ""
            savedMasked = ""
            keyNotice = nil
            testResult = nil
            testing = false
        } label: {
            HStack(spacing: Ink.Space.m) {
                IconBadge(symbol: providerIcon(provider), tint: isSelected ? Ink.Tile.xiang : Ink.Tile.mo)
                VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
                    HStack(spacing: Ink.Space.s) {
                        Text(providerName(provider))
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
                    Text(providerSummary(provider))
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

    private func providerName(_ provider: WebSearchProvider) -> String {
        switch provider {
        case .builtin: L.t("searchSettings.providerBuiltinName")
        case .anysearch: L.t("searchSettings.providerAnysearchName")
        case .tavily: L.t("searchSettings.providerTavilyName")
        case .exa: L.t("searchSettings.providerExaName")
        case .brave: L.t("searchSettings.providerBraveName")
        }
    }

    private func providerSummary(_ provider: WebSearchProvider) -> String {
        switch provider {
        case .builtin: L.t("searchSettings.providerBuiltinSummary")
        case .anysearch: L.t("searchSettings.providerAnysearchSummary")
        case .tavily: L.t("searchSettings.providerTavilySummary")
        case .exa: L.t("searchSettings.providerExaSummary")
        case .brave: L.t("searchSettings.providerBraveSummary")
        }
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
            return hasKey
                ? (L.t("searchSettings.badgeKeySaved"), Ink.ok)
                : (L.t("searchSettings.badgeFreeReady"), Ink.accent)
        case .tavily, .exa, .brave:
            return hasKey
                ? (L.t("searchSettings.badgeKeySaved"), Ink.ok)
                : (L.t("searchSettings.badgeKeyNeeded"), Ink.warn)
        case .builtin:
            return nil
        }
    }

    // MARK: Keychain API key editor

    private var keySection: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle(L.format("searchSettings.keySection", selected.shortName))
            VStack(alignment: .leading, spacing: Ink.Space.m) {
                HStack(spacing: Ink.Space.s) {
                    SecureField(
                        savedMasked.isEmpty ? L.format("searchSettings.keyPlaceholder", selected.shortName) : savedMasked,
                        text: $keyInput
                    )
                        .font(Ink.mono(Ink.Size.sub))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if keyInput.isEmpty {
                        Button(L.t("actions.paste")) {
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
                        Text(L.format("searchSettings.keySavedPreview", savedMasked))
                            .font(Ink.mono(Ink.Size.small))
                            .foregroundStyle(Ink.inkSoft)
                        Spacer()
                        Button(L.t("searchSettings.clearKey"), role: .destructive) { clearCurrentKey() }
                            .font(.system(size: Ink.Size.small, weight: .medium))
                            .foregroundStyle(Ink.stop)
                    }
                }
                if !selected.consoleHost.isEmpty {
                    Kit.rule(inset: 0)
                    Text(L.format("searchSettings.consoleHost", selected.consoleHost))
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
            return L.t("searchSettings.anysearchKeyNote")
        }
        return L.t("searchSettings.keyNote")
    }

    // MARK: Fallback & Live Test

    private var fallbackAndTestSection: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle(L.t("searchSettings.fallbackAndTestSection"))
            VStack(alignment: .leading, spacing: 0) {
                if selected != .builtin {
                    Toggle(L.t("searchSettings.fallbackToggle"), isOn: $fallbackToBuiltin)
                        .font(.system(size: Ink.Size.body))
                        .foregroundStyle(Ink.ink)
                        .tint(Ink.accent)
                        .padding(.horizontal, Ink.Space.l)
                        .frame(minHeight: Kit.rowHeight)
                    Kit.rule(inset: Ink.Space.l)
                }
                VStack(alignment: .leading, spacing: Ink.Space.m) {
                    HStack(spacing: Ink.Space.s) {
                        TextField(L.t("searchSettings.testPlaceholder"), text: $testQuery)
                            .font(.system(size: Ink.Size.sub))
                            .submitLabel(.search)
                            .onSubmit { runProbe() }
                        if testing {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    Button(testing ? L.t("searchSettings.testing") : L.t("searchSettings.runTest")) { runProbe() }
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
                Text(
                    result.ok
                        ? L.format("searchSettings.testPassed", result.source, result.count)
                        : L.format("searchSettings.testFailed", result.source)
                )
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
        let target = selected
        let version = selectionVersion
        let current = await SearchEngine.readKey(for: target)
        guard !Task.isCancelled, selected == target, selectionVersion == version else { return }
        savedMasked = SearchEngine.mask(current)
    }

    private func saveCurrentKey() {
        let value = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let target = selected
        let version = selectionVersion
        keyInput = ""
        Task {
            await SearchEngine.saveKey(value, for: target)
            keyedProviders.insert(target)
            guard selected == target, selectionVersion == version else { return }
            savedMasked = SearchEngine.mask(value)
            keyNotice = L.t("searchSettings.keySavedNotice")
            testResult = nil
            Haptics.thud()
        }
    }

    private func clearCurrentKey() {
        let target = selected
        let version = selectionVersion
        keyInput = ""
        Task {
            await SearchEngine.saveKey("", for: target)
            keyedProviders.remove(target)
            guard selected == target, selectionVersion == version else { return }
            savedMasked = ""
            keyNotice = L.format("searchSettings.keyClearedNotice", target.shortName)
            testResult = nil
            Haptics.lock()
        }
    }

    private func runProbe() {
        let q = testQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !testing else { return }
        probeTask?.cancel()
        testing = true
        testResult = nil
        let target = selected
        let version = selectionVersion
        let pendingInput = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        probeTask = Task {
            let keyToUse: String?
            if !target.supportsKey {
                keyToUse = nil
            } else if !pendingInput.isEmpty {
                keyToUse = pendingInput
            } else {
                let saved = await SearchEngine.readKey(for: target)
                keyToUse = saved.isEmpty ? nil : saved
            }
            guard !Task.isCancelled, selected == target, selectionVersion == version else { return }
            let config = WebSearchConfig(primary: target, apiKey: keyToUse, fallbackToBuiltin: false)
            let result = await WebSearchTool.probe(query: q, config: config)
            guard !Task.isCancelled, selected == target, selectionVersion == version else { return }
            testResult = result
            testing = false
            if result.ok { Haptics.tick(0.6) } else { Haptics.lock() }
        }
    }
}
