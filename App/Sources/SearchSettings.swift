import AgentKit
import SwiftUI
import UIKit

/// Stores web search provider selection, custom SearXNG URL, ordered fallback chain, and Keychain-backed API keys,
/// and wires them into `AgentKit.WebSearchTool`.
enum SearchEngine {
    static let providerKey = "search.provider"
    static let fallbackKey = "search.fallbackToBuiltin"
    static let searxngURLKey = "search.searxngURL"
    static let fallbackOrderKey = "search.fallbackOrder"

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

    nonisolated static var searxngURL: String {
        get {
            UserDefaults.standard.string(forKey: searxngURLKey) ?? ""
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                UserDefaults.standard.set("", forKey: searxngURLKey)
                return
            }
            guard let normalized = SearXNGEndpoint.normalize(trimmed) else { return }
            UserDefaults.standard.set(normalized, forKey: searxngURLKey)
        }
    }

    nonisolated static var fallbackOrder: [WebSearchProvider] {
        get {
            let raw = UserDefaults.standard.stringArray(forKey: fallbackOrderKey) ?? []
            var out: [WebSearchProvider] = []
            var seen: Set<WebSearchProvider> = []
            for item in raw {
                if let parsed = WebSearchProvider(rawValue: item), seen.insert(parsed).inserted {
                    out.append(parsed)
                }
            }
            return out
        }
        set {
            var unique: [String] = []
            var seen: Set<WebSearchProvider> = []
            for item in newValue where seen.insert(item).inserted {
                unique.append(item.rawValue)
            }
            UserDefaults.standard.set(unique, forKey: fallbackOrderKey)
        }
    }

    nonisolated static func vaultKey(for provider: WebSearchProvider, searxngOrigin: String? = nil) -> String? {
        if provider == .searxng {
            guard let origin = searxngOrigin?.trimmingCharacters(in: .whitespacesAndNewlines), !origin.isEmpty else {
                return nil
            }
            return "search-key-searxng-\(origin)"
        }
        guard provider.supportsKey else { return nil }
        return "search-key-\(provider.rawValue)"
    }

    /// Reads the saved Keychain key for a provider off the calling thread.
    /// For `.searxng`, requires a valid `searxngURL` and binds strictly to its `scheme://host:port` origin.
    static func readKey(for provider: WebSearchProvider, searxngURL: String? = nil) async -> String {
        let origin = provider == .searxng ? searxngURL.flatMap { SearXNGEndpoint.originKey(forBaseURL: $0) } : nil
        guard let keyName = vaultKey(for: provider, searxngOrigin: origin) else { return "" }
        let raw = await Vault.readString(keyName) ?? ""
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Saves or clears a provider's API key in the Keychain (never in UserDefaults or backups).
    /// For `.searxng`, requires a valid `searxngURL` and binds strictly to its `scheme://host:port` origin.
    static func saveKey(_ value: String, for provider: WebSearchProvider, searxngURL: String? = nil) async {
        let origin = provider == .searxng ? searxngURL.flatMap { SearXNGEndpoint.originKey(forBaseURL: $0) } : nil
        guard let keyName = vaultKey(for: provider, searxngOrigin: origin) else { return }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        await Task.detached(priority: .userInitiated) {
            if trimmed.isEmpty {
                Vault.remove(keyName)
            } else {
                Vault.save(trimmed, as: keyName)
            }
        }.value
    }

    /// Snapshot of all configured key statuses (checking `.searxng` against `searxngURL`'s exact origin).
    static func keyPresence(searxngURL: String? = nil) async -> Set<WebSearchProvider> {
        let resolvedSearxng = searxngURL ?? self.searxngURL
        var present: Set<WebSearchProvider> = []
        for provider in WebSearchProvider.allCases where provider.supportsKey {
            let key = await readKey(for: provider, searxngURL: provider == .searxng ? resolvedSearxng : nil)
            if !key.isEmpty { present.insert(provider) }
        }
        return present
    }

    /// Builds the live `WebSearchConfig` for `WebSearchTool`.
    nonisolated static func currentConfig() async -> WebSearchConfig {
        let selected = primary
        let fallback = fallbackToBuiltin
        let searxng = searxngURL
        let searxngOrigin = searxng.isEmpty ? nil : SearXNGEndpoint.originKey(forBaseURL: searxng)
        let order = fallbackOrder.filter { $0 != selected }

        var keys: [WebSearchProvider: String] = [:]
        for provider in [selected] + order where provider.supportsKey && keys[provider] == nil {
            let saved = await readKey(for: provider, searxngURL: provider == .searxng ? searxng : nil)
            if !saved.isEmpty {
                keys[provider] = saved
            }
        }
        return WebSearchConfig(
            primary: selected,
            apiKey: keys[selected],
            fallbackToBuiltin: fallback,
            apiKeys: keys,
            searxngURL: searxng.isEmpty ? nil : searxng,
            fallbackOrder: order,
            searxngKeyOrigin: searxngOrigin
        )
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

/// Settings page for choosing the web search backend (built-in Bing/DDG by default, or opt-in AnySearch, Tavily, Exa, Brave, SearXNG).
struct SearchSettingsPage: View {
    @AppStorage(SearchEngine.providerKey) private var providerRaw = WebSearchProvider.builtin.rawValue
    @AppStorage(SearchEngine.fallbackKey) private var fallbackToBuiltin = true
    @AppStorage(SearchEngine.searxngURLKey) private var savedSearxngURL = ""

    @State private var searxngDraft = SearchEngine.searxngURL
    @State private var searxngNotice: String?
    @State private var activeSearxngOrigin: String? = SearXNGEndpoint.originKey(forBaseURL: SearchEngine.searxngURL)
    @State private var originVersion = UUID()
    @State private var fallbackOrder: [WebSearchProvider] = SearchEngine.fallbackOrder
    @State private var keyedProviders: Set<WebSearchProvider> = []
    @State private var savedMasked = ""
    @State private var keyInput = ""
    @State private var keyNotice: String?
    @State private var testing = false
    @State private var testQuery = "Swift 6"
    @State private var testResult: WebSearchTool.ProbeResult?
    @State private var selectionVersion = UUID()
    @State private var probeVersion = UUID()
    @State private var probeTask: Task<Void, Never>?

    private var selected: WebSearchProvider {
        WebSearchProvider(rawValue: providerRaw) ?? .builtin
    }

    private var activeFallbackOrder: [WebSearchProvider] {
        fallbackOrder.filter { $0 != selected }
    }

    private var availableFallbackProviders: [WebSearchProvider] {
        WebSearchProvider.allCases.filter { candidate in
            candidate != selected && candidate != .builtin && !activeFallbackOrder.contains(candidate)
        }
    }

    private var showsSearxngSection: Bool {
        selected == .searxng || activeFallbackOrder.contains(.searxng)
    }

    private var trimmedSearxngDraft: String {
        searxngDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var searxngValidation: Result<SearXNGEndpoint.Parsed, SearXNGError> {
        SearXNGEndpoint.parse(searxngDraft)
    }

    private var savedSearxngOrigin: String? {
        savedSearxngURL.isEmpty ? nil : SearXNGEndpoint.originKey(forBaseURL: savedSearxngURL)
    }

    private var hasUnsavedSearxngURL: Bool {
        trimmedSearxngDraft != savedSearxngURL
    }

    private var canEditKey: Bool {
        if selected == .searxng {
            return !hasUnsavedSearxngURL && savedSearxngOrigin != nil
        }
        return selected.supportsKey
    }

    private var canSaveSearxngDraft: Bool {
        guard hasUnsavedSearxngURL else { return false }
        if trimmedSearxngDraft.isEmpty { return true }
        if case .success = searxngValidation { return true }
        return false
    }

    private var effectiveChainNames: [String] {
        var chain: [WebSearchProvider] = [selected]
        var seen: Set<WebSearchProvider> = [selected]
        for item in activeFallbackOrder where seen.insert(item).inserted {
            chain.append(item)
        }
        if fallbackToBuiltin && !seen.contains(.builtin) {
            chain.append(.builtin)
        }
        return chain.map(\.shortName)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Ink.Space.xl) {
                providerSection
                if showsSearxngSection {
                    searxngSection
                }
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
        .task(id: "\(providerRaw)|\(savedSearxngURL)") { await loadSelectedKey() }
        .onChange(of: searxngDraft) { _, next in
            invalidateProbe()
            if next.trimmingCharacters(in: .whitespacesAndNewlines) != savedSearxngURL {
                searxngNotice = nil
            }
        }
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
            invalidateProbe()
            selectionVersion = UUID()
            providerRaw = provider.rawValue
            keyInput = ""
            savedMasked = ""
            keyNotice = nil
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
        case .searxng: L.t("searchSettings.providerSearxngName")
        }
    }

    private func providerSummary(_ provider: WebSearchProvider) -> String {
        switch provider {
        case .builtin: L.t("searchSettings.providerBuiltinSummary")
        case .anysearch: L.t("searchSettings.providerAnysearchSummary")
        case .tavily: L.t("searchSettings.providerTavilySummary")
        case .exa: L.t("searchSettings.providerExaSummary")
        case .brave: L.t("searchSettings.providerBraveSummary")
        case .searxng: L.t("searchSettings.providerSearxngSummary")
        }
    }

    private func providerIcon(_ provider: WebSearchProvider) -> String {
        switch provider {
        case .anysearch: "sparkles.rectangle.stack"
        case .tavily: "magnifyingglass.circle"
        case .exa: "brain.head.profile"
        case .brave: "shield"
        case .searxng: "server.rack"
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
        case .searxng:
            return savedSearxngURL.isEmpty
                ? (L.t("searchSettings.badgeURLNeeded"), Ink.warn)
                : (L.t("searchSettings.badgeURLSaved"), Ink.ok)
        case .builtin:
            return nil
        }
    }

    // MARK: SearXNG instance URL editor

    private var searxngSection: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle(L.t("searchSettings.searxngSection"))
            VStack(alignment: .leading, spacing: Ink.Space.m) {
                VStack(alignment: .leading, spacing: Ink.Space.xs) {
                    Text(L.t("searchSettings.searxngURLLabel"))
                        .font(.system(size: Ink.Size.small))
                        .foregroundStyle(Ink.inkSoft)
                    TextField(L.t("searchSettings.searxngURLPlaceholder"), text: $searxngDraft)
                        .font(Ink.mono(Ink.Size.sub))
                        .keyboardType(.URL)
                        .submitLabel(.done)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { saveSearxngURL() }
                }
                searxngValidationView
                searxngActionRow
            }
            .padding(Ink.Space.l)
            .paperCard()
            Text(L.t("searchSettings.searxngURLFooter"))
                .font(.system(size: Ink.Size.small))
                .foregroundStyle(Ink.inkSoft)
                .padding(.horizontal, Ink.Space.l)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var searxngValidationView: some View {
        if !trimmedSearxngDraft.isEmpty {
            switch searxngValidation {
            case .success(let parsed):
                Text(L.format("searchSettings.searxngPreview", parsed.searchBaseURL + "?q=…&format=json"))
                    .font(Ink.mono(Ink.Size.small))
                    .foregroundStyle(Ink.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            case .failure(let err):
                Text(searxngErrorText(err))
                    .font(.system(size: Ink.Size.small))
                    .foregroundStyle(Ink.stop)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func searxngErrorText(_ error: SearXNGError) -> String {
        switch error {
        case .empty: L.t("searchSettings.searxngErrorEmpty")
        case .invalidFormat: L.t("searchSettings.searxngErrorInvalidFormat")
        case .embeddedCredentials: L.t("searchSettings.searxngErrorEmbeddedCredentials")
        case .queryOrFragmentNotAllowed: L.t("searchSettings.searxngErrorQueryOrFragment")
        case .requiresHTTPS: L.t("searchSettings.searxngErrorRequiresHTTPS")
        }
    }

    @ViewBuilder
    private var searxngActionRow: some View {
        if hasUnsavedSearxngURL {
            HStack(spacing: Ink.Space.m) {
                Button(L.t("searchSettings.searxngSaveURL")) { saveSearxngURL() }
                    .font(.system(size: Ink.Size.sub, weight: .semibold))
                    .foregroundStyle(canSaveSearxngDraft ? Ink.accent : Ink.inkFaint)
                    .disabled(!canSaveSearxngDraft)
                Button(L.t("searchSettings.searxngRevertURL")) {
                    searxngDraft = savedSearxngURL
                    searxngNotice = nil
                    invalidateProbe()
                }
                .font(.system(size: Ink.Size.small))
                .foregroundStyle(Ink.inkSoft)
                Spacer()
            }
        } else if !savedSearxngURL.isEmpty {
            Kit.rule(inset: 0)
            HStack {
                if let searxngNotice {
                    Text(searxngNotice)
                        .font(.system(size: Ink.Size.small))
                        .foregroundStyle(Ink.ok)
                } else {
                    Text(savedSearxngURL)
                        .font(Ink.mono(Ink.Size.small))
                        .foregroundStyle(Ink.inkSoft)
                        .lineLimit(1)
                }
                Spacer()
                Button(L.t("searchSettings.searxngClearURL"), role: .destructive) { clearSearxngURL() }
                    .font(.system(size: Ink.Size.small, weight: .medium))
                    .foregroundStyle(Ink.stop)
            }
        } else if let searxngNotice {
            Text(searxngNotice)
                .font(.system(size: Ink.Size.small))
                .foregroundStyle(Ink.ok)
        }
    }

    // MARK: Keychain API key editor

    private var keySection: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle(L.format("searchSettings.keySection", selected.shortName))
            VStack(alignment: .leading, spacing: Ink.Space.m) {
                if selected == .searxng {
                    if hasUnsavedSearxngURL {
                        Text(L.t("searchSettings.searxngKeySaveURLFirst"))
                            .font(.system(size: Ink.Size.small))
                            .foregroundStyle(Ink.warn)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let origin = activeSearxngOrigin {
                        Text(L.format("searchSettings.searxngKeyBoundOrigin", origin))
                            .font(Ink.mono(Ink.Size.small))
                            .foregroundStyle(Ink.inkFaint)
                            .lineLimit(1)
                    } else {
                        Text(L.t("searchSettings.searxngKeyNeedURL"))
                            .font(.system(size: Ink.Size.small))
                            .foregroundStyle(Ink.inkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: Ink.Space.s) {
                    SecureField(
                        savedMasked.isEmpty ? L.format("searchSettings.keyPlaceholder", selected.shortName) : savedMasked,
                        text: $keyInput
                    )
                        .font(Ink.mono(Ink.Size.sub))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(!canEditKey)
                    if keyInput.isEmpty {
                        Button(L.t("actions.paste")) {
                            if let clip = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !clip.isEmpty {
                                keyInput = clip
                                Haptics.tick(0.4)
                            }
                        }
                        .font(.system(size: Ink.Size.small, weight: .semibold))
                        .foregroundStyle(Ink.accent)
                        .disabled(!canEditKey)
                    } else {
                        Button(L.t("actions.save")) { saveCurrentKey() }
                            .font(.system(size: Ink.Size.sub, weight: .semibold))
                            .foregroundStyle(Ink.accent)
                            .disabled(!canEditKey)
                    }
                }
                if !savedMasked.isEmpty && canEditKey {
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
                if let keyNotice, canEditKey {
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
        switch selected {
        case .anysearch: L.t("searchSettings.anysearchKeyNote")
        case .searxng: L.t("searchSettings.searxngKeyNote")
        default: L.t("searchSettings.keyNote")
        }
    }

    // MARK: Fallback & Live Test

    private var fallbackAndTestSection: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle(L.t("searchSettings.fallbackAndTestSection"))
            VStack(alignment: .leading, spacing: 0) {
                fallbackOrderBlock
                Kit.rule(inset: Ink.Space.l)
                if selected != .builtin {
                    Toggle(L.t("searchSettings.fallbackToggle"), isOn: $fallbackToBuiltin)
                        .font(.system(size: Ink.Size.body))
                        .foregroundStyle(Ink.ink)
                        .tint(Ink.accent)
                        .padding(.horizontal, Ink.Space.l)
                        .frame(minHeight: Kit.rowHeight)
                    Kit.rule(inset: Ink.Space.l)
                }
                probeBlock
            }
            .paperCard()
        }
    }

    private var fallbackOrderBlock: some View {
        VStack(alignment: .leading, spacing: Ink.Space.m) {
            Text(L.t("searchSettings.fallbackOrderTitle"))
                .font(.system(size: Ink.Size.sub, weight: .medium))
                .foregroundStyle(Ink.ink)
            if activeFallbackOrder.isEmpty {
                Text(L.t("searchSettings.fallbackOrderEmpty"))
                    .font(.system(size: Ink.Size.small))
                    .foregroundStyle(Ink.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: Ink.Space.s) {
                    ForEach(Array(activeFallbackOrder.enumerated()), id: \.element.id) { index, provider in
                        fallbackOrderRow(provider: provider, index: index, total: activeFallbackOrder.count)
                    }
                }
            }
            if !availableFallbackProviders.isEmpty {
                VStack(alignment: .leading, spacing: Ink.Space.xs) {
                    Text(L.t("searchSettings.fallbackAddTitle"))
                        .font(.system(size: Ink.Size.small))
                        .foregroundStyle(Ink.inkSoft)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Ink.Space.s) {
                            ForEach(availableFallbackProviders) { provider in
                                Button {
                                    addFallbackProvider(provider)
                                } label: {
                                    HStack(spacing: Ink.Space.xs) {
                                        Image(systemName: "plus")
                                            .font(.system(size: Ink.Size.micro, weight: .semibold))
                                        Text(provider.shortName)
                                            .font(.system(size: Ink.Size.small, weight: .medium))
                                    }
                                    .foregroundStyle(Ink.accent)
                                    .padding(.horizontal, Ink.Space.m)
                                    .padding(.vertical, Ink.Space.xs + 2)
                                    .background(Ink.accentWash, in: .capsule)
                                }
                                .buttonStyle(TapStyle())
                            }
                        }
                    }
                }
            }
            if effectiveChainNames.count > 1 {
                Text(L.format("searchSettings.fallbackChainSummary", effectiveChainNames.joined(separator: " → ")))
                    .font(.system(size: Ink.Size.small))
                    .foregroundStyle(Ink.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Ink.Space.l)
    }

    private func fallbackOrderRow(provider: WebSearchProvider, index: Int, total: Int) -> some View {
        let status = fallbackStatus(for: provider)
        return HStack(spacing: Ink.Space.s) {
            Text("\(index + 1)")
                .font(.system(size: Ink.Size.micro, weight: .semibold).monospacedDigit())
                .foregroundStyle(Ink.accent)
                .frame(width: 22, height: 22)
                .background(Ink.accentWash, in: .capsule)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.shortName)
                    .font(.system(size: Ink.Size.sub, weight: .medium))
                    .foregroundStyle(Ink.ink)
                Text(status.text)
                    .font(.system(size: Ink.Size.micro))
                    .foregroundStyle(status.tint)
            }
            Spacer(minLength: Ink.Space.xs)
            Button {
                moveFallbackProvider(at: index, offset: -1)
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: Ink.Size.small, weight: .medium))
                    .foregroundStyle(index > 0 ? Ink.inkSoft : Ink.inkFaint.opacity(0.45))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(TapStyle())
            .disabled(index == 0)
            .accessibilityLabel(L.t("searchSettings.fallbackMoveUp"))

            Button {
                moveFallbackProvider(at: index, offset: 1)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: Ink.Size.small, weight: .medium))
                    .foregroundStyle(index + 1 < total ? Ink.inkSoft : Ink.inkFaint.opacity(0.45))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(TapStyle())
            .disabled(index + 1 >= total)
            .accessibilityLabel(L.t("searchSettings.fallbackMoveDown"))

            Button {
                removeFallbackProvider(provider)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: Ink.Size.sub))
                    .foregroundStyle(Ink.inkFaint)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(TapStyle())
            .accessibilityLabel(L.t("searchSettings.fallbackRemove"))
        }
        .padding(.horizontal, Ink.Space.m)
        .padding(.vertical, Ink.Space.s)
        .background(Ink.paper, in: .rect(cornerRadius: Ink.Radius.small, style: .continuous))
    }

    private func fallbackStatus(for provider: WebSearchProvider) -> (text: String, tint: Color) {
        if provider.needsURL && savedSearxngURL.isEmpty {
            return (L.t("searchSettings.fallbackNeedsURL"), Ink.warn)
        }
        if provider.needsKey && !keyedProviders.contains(provider) {
            return (L.t("searchSettings.fallbackNeedsKey"), Ink.warn)
        }
        return (L.t("searchSettings.fallbackReady"), Ink.inkSoft)
    }

    private var probeBlock: some View {
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

    private func invalidateProbe() {
        probeTask?.cancel()
        probeTask = nil
        probeVersion = UUID()
        testing = false
        testResult = nil
    }

    @discardableResult
    private func syncSearxngOrigin(_ nextOrigin: String?) -> Bool {
        guard nextOrigin != activeSearxngOrigin else { return false }
        activeSearxngOrigin = nextOrigin
        originVersion = UUID()
        keyInput = ""
        savedMasked = ""
        keyNotice = nil
        return true
    }

    private func reloadKeys() async {
        keyedProviders = await SearchEngine.keyPresence(searxngURL: savedSearxngURL)
        await loadSelectedKey()
    }

    private func loadSelectedKey() async {
        let target = selected
        let version = selectionVersion
        let expectedOrigin = target == .searxng ? savedSearxngOrigin : nil
        let expectedOriginVersion = originVersion
        if target == .searxng && expectedOrigin == nil {
            savedMasked = ""
            return
        }
        let current = await SearchEngine.readKey(
            for: target,
            searxngURL: target == .searxng ? savedSearxngURL : nil
        )
        guard !Task.isCancelled,
              selected == target,
              selectionVersion == version else { return }
        if target == .searxng {
            guard activeSearxngOrigin == expectedOrigin, originVersion == expectedOriginVersion else { return }
        }
        savedMasked = SearchEngine.mask(current)
    }

    private func saveSearxngURL() {
        let trimmed = trimmedSearxngDraft
        if trimmed.isEmpty {
            clearSearxngURL()
            return
        }
        guard case .success(let parsed) = SearXNGEndpoint.parse(trimmed) else { return }
        SearchEngine.searxngURL = parsed.baseURL
        savedSearxngURL = parsed.baseURL
        searxngDraft = parsed.baseURL
        searxngNotice = L.t("searchSettings.searxngURLSavedNotice")
        invalidateProbe()
        let originChanged = syncSearxngOrigin(parsed.originKey)
        Haptics.thud()
        Task {
            keyedProviders = await SearchEngine.keyPresence(searxngURL: parsed.baseURL)
            if originChanged || selected == .searxng {
                await loadSelectedKey()
            }
        }
    }

    private func clearSearxngURL() {
        SearchEngine.searxngURL = ""
        savedSearxngURL = ""
        searxngDraft = ""
        searxngNotice = L.t("searchSettings.searxngURLClearedNotice")
        invalidateProbe()
        syncSearxngOrigin(nil)
        keyedProviders.remove(.searxng)
        Haptics.lock()
    }

    private func addFallbackProvider(_ provider: WebSearchProvider) {
        guard provider != selected, provider != .builtin, !fallbackOrder.contains(provider) else { return }
        var next = fallbackOrder
        next.append(provider)
        fallbackOrder = next
        SearchEngine.fallbackOrder = next
        Haptics.tick(0.5)
    }

    private func moveFallbackProvider(at index: Int, offset: Int) {
        let visible = activeFallbackOrder
        let dest = index + offset
        guard visible.indices.contains(index), visible.indices.contains(dest) else { return }
        let first = visible[index]
        let second = visible[dest]
        var next = fallbackOrder
        guard let iFirst = next.firstIndex(of: first), let iSecond = next.firstIndex(of: second) else { return }
        next.swapAt(iFirst, iSecond)
        fallbackOrder = next
        SearchEngine.fallbackOrder = next
        Haptics.tick(0.4)
    }

    private func removeFallbackProvider(_ provider: WebSearchProvider) {
        let next = fallbackOrder.filter { $0 != provider }
        fallbackOrder = next
        SearchEngine.fallbackOrder = next
        Haptics.tick(0.4)
    }

    private func saveCurrentKey() {
        guard canEditKey else { return }
        let value = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let target = selected
        let version = selectionVersion
        let targetSearxngURL = savedSearxngURL
        let expectedOrigin = target == .searxng ? savedSearxngOrigin : nil
        let expectedOriginVersion = originVersion
        if target == .searxng && expectedOrigin == nil { return }
        keyInput = ""
        Task {
            await SearchEngine.saveKey(value, for: target, searxngURL: target == .searxng ? targetSearxngURL : nil)
            guard selected == target, selectionVersion == version else { return }
            if target == .searxng {
                guard activeSearxngOrigin == expectedOrigin, originVersion == expectedOriginVersion else { return }
            }
            keyedProviders.insert(target)
            savedMasked = SearchEngine.mask(value)
            keyNotice = L.t("searchSettings.keySavedNotice")
            testResult = nil
            Haptics.thud()
        }
    }

    private func clearCurrentKey() {
        guard canEditKey else { return }
        let target = selected
        let version = selectionVersion
        let targetSearxngURL = savedSearxngURL
        let expectedOrigin = target == .searxng ? savedSearxngOrigin : nil
        let expectedOriginVersion = originVersion
        if target == .searxng && expectedOrigin == nil { return }
        keyInput = ""
        Task {
            await SearchEngine.saveKey("", for: target, searxngURL: target == .searxng ? targetSearxngURL : nil)
            guard selected == target, selectionVersion == version else { return }
            if target == .searxng {
                guard activeSearxngOrigin == expectedOrigin, originVersion == expectedOriginVersion else { return }
            }
            keyedProviders.remove(target)
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
        let probeID = UUID()
        probeVersion = probeID
        testing = true
        testResult = nil
        let target = selected
        let version = selectionVersion
        let pendingInput = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let pendingSearxng = trimmedSearxngDraft.isEmpty ? savedSearxngURL : trimmedSearxngDraft
        let unsavedURL = hasUnsavedSearxngURL
        let pendingParsed = (target == .searxng) ? (try? SearXNGEndpoint.parse(pendingSearxng).get()) : nil
        let pendingOrigin = pendingParsed?.originKey
        probeTask = Task {
            let keyToUse: String?
            if !target.supportsKey {
                keyToUse = nil
            } else if target == .searxng {
                if let originBase = pendingParsed?.baseURL {
                    if !unsavedURL && !pendingInput.isEmpty && pendingOrigin == activeSearxngOrigin {
                        keyToUse = pendingInput
                    } else {
                        let saved = await SearchEngine.readKey(for: .searxng, searxngURL: originBase)
                        keyToUse = saved.isEmpty ? nil : saved
                    }
                } else {
                    keyToUse = nil
                }
            } else if !pendingInput.isEmpty {
                keyToUse = pendingInput
            } else {
                let saved = await SearchEngine.readKey(for: target)
                keyToUse = saved.isEmpty ? nil : saved
            }
            guard !Task.isCancelled,
                  selected == target,
                  selectionVersion == version,
                  probeVersion == probeID else { return }
            let config = WebSearchConfig(
                primary: target,
                apiKey: keyToUse,
                fallbackToBuiltin: false,
                searxngURL: target == .searxng ? pendingSearxng : nil,
                searxngKeyOrigin: target == .searxng ? pendingOrigin : nil
            )
            let result = await WebSearchTool.probe(query: q, config: config)
            guard !Task.isCancelled,
                  selected == target,
                  selectionVersion == version,
                  probeVersion == probeID else { return }
            testResult = result
            testing = false
            if result.ok { Haptics.tick(0.6) } else { Haptics.lock() }
        }
    }
}
