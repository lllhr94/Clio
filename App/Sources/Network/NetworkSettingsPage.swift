import Craft
import SwiftUI
import UIKit

/// Unified per-device network routing, upstream proxy management, Den DNS configuration,
/// and live network diagnostics. Replaces the old standalone `DenDNSSettingsSheet`.
struct NetworkSettingsPage: View {
    var endpoints: [Endpoint] = []
    var embedded: Bool = true

    @ObservedObject private var runtime = NetworkRuntime.shared
    @ObservedObject private var den = Den.shared
    @Environment(\.dismiss) private var dismiss

    @State private var editingProxy: ProxyProfile?
    @State private var addingProxy = false

    @State private var dnsMode: DenDNSMode = Den.shared.dnsMode
    @State private var dnsCustomText: String = Den.shared.customDNSInput
    @State private var dnsValidationNote: String?

    @State private var diagnosing = false
    @State private var diagnosticItems: [ClioNetHub.DiagnosticItem] = []
    @State private var copiedReport = false

    var body: some View {
        let content = ScrollView {
            LazyVStack(alignment: .leading, spacing: Ink.Space.xl) {
                if let alert = runtime.alertMessage {
                    alertCard(alert)
                }
                routingMasterSection
                proxiesSection
                scopesSection
                if !endpoints.isEmpty {
                    servicesSection
                }
                denDNSSection
                diagnosticsSection
            }
            .padding(.horizontal, Ink.Space.page)
            .padding(.vertical, Ink.Space.l)
        }
        .scrollEdgeEffectStyle(.soft, for: .vertical)
        .background(Ink.paper.ignoresSafeArea())
        .navigationTitle(L.t("settingsHome.network"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $addingProxy) {
            ProxyEditorSheet(profile: nil) { saved, password in
                runtime.saveProxy(saved, password: password)
            }
        }
        .sheet(item: $editingProxy) { item in
            ProxyEditorSheet(profile: item) { saved, password in
                runtime.saveProxy(saved, password: password)
            }
        }

        if embedded {
            content
        } else {
            NavigationStack {
                content
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(L.t("actions.done")) {
                                Haptics.light()
                                dismiss()
                            }
                            .buttonStyle(.glass)
                            .buttonBorderShape(.capsule)
                        }
                    }
            }
        }
    }

    // MARK: Alert Banner

    private func alertCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: Ink.Space.m) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: Ink.Size.body, weight: .semibold))
                .foregroundStyle(Ink.warn)
            Text(message)
                .font(Ink.secondary)
                .foregroundStyle(Ink.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Ink.Space.l)
        .paperCard()
    }

    // MARK: Master Switch & Local Entry Status

    private var routingMasterSection: some View {
        let statusLine: String = {
            if !runtime.settings.routingEnabled {
                return L.t("network.statusOff")
            }
            if let entry = runtime.activeEndpoints {
                return L.format("network.statusActive", Int(entry.socksPort), Int(entry.httpPort))
            }
            return L.t("network.statusDirect")
        }()

        return RowCard(
            title: L.t("network.routingSection"),
            note: L.t("network.routingNote")
        ) {
            Toggle(isOn: Binding(
                get: { runtime.settings.routingEnabled },
                set: { enabled in
                    Haptics.light()
                    runtime.update { $0.routingEnabled = enabled }
                }
            )) {
                VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
                    Text(L.t("network.enableRouting"))
                        .font(Ink.label)
                        .foregroundStyle(Ink.ink)
                    Text(statusLine)
                        .font(Ink.footnote)
                        .foregroundStyle(Ink.inkSoft)
                }
            }
            .tint(Ink.accent)
            .padding(.horizontal, Ink.Space.l)
            .padding(.vertical, Ink.Space.m)

            if runtime.settings.routingEnabled {
                Kit.divider
                routePickerRow(
                    title: L.t("network.defaultRoute"),
                    subtitle: L.t("network.defaultRouteLine"),
                    scope: .default,
                    allowFollowDefault: false
                )
            }
        }
    }

    // MARK: Proxies List

    private var proxiesSection: some View {
        RowCard(
            title: L.t("network.proxiesSection"),
            note: L.t("network.proxiesNote")
        ) {
            if runtime.settings.proxies.isEmpty {
                Text(L.t("network.noProxies"))
                    .font(Ink.secondary)
                    .foregroundStyle(Ink.inkSoft)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Ink.Space.l)
            } else {
                ForEach(runtime.settings.proxies) { proxy in
                    proxyRow(proxy)
                    Kit.divider
                }
            }
            Button {
                Haptics.light()
                addingProxy = true
            } label: {
                RowLabel("plus", tint: Ink.Tile.dai, title: L.t("network.addProxy"))
            }
            .buttonStyle(PressStyle(haptic: false))
        }
    }

    private func proxyRow(_ proxy: ProxyProfile) -> some View {
        let bypassNote = proxy.bypass.isEmpty
            ? "\(proxy.kind.displayName) · \(proxy.host):\(proxy.port)"
            : "\(proxy.kind.displayName) · \(proxy.host):\(proxy.port) · \(L.format("network.bypassCount", proxy.bypass.count))"
        return HStack(spacing: Ink.Space.m) {
            Button {
                Haptics.light()
                editingProxy = proxy
            } label: {
                RowLabel(
                    "network",
                    tint: Ink.Tile.dai,
                    title: proxy.displayName,
                    line: bypassNote,
                    end: .chevron
                )
            }
            .buttonStyle(PressStyle(haptic: false))
        }
        .contextMenu {
            Button(L.t("network.editProxy"), systemImage: "pencil") {
                editingProxy = proxy
            }
            Button(L.t("actions.delete"), systemImage: "trash", role: .destructive) {
                runtime.deleteProxy(id: proxy.id)
            }
        }
    }

    // MARK: Per-Scope Routes

    private var scopesSection: some View {
        RowCard(
            title: L.t("network.scopesSection"),
            note: L.t("network.scopesNote")
        ) {
            routePickerRow(title: L.t("nav.terminal"), subtitle: L.t("network.scopeShellLine"), scope: .shell, allowFollowDefault: true)
            Kit.divider
            routePickerRow(title: L.t("nav.browser"), subtitle: L.t("network.scopeBrowserLine"), scope: .browser, allowFollowDefault: true)
            Kit.divider
            routePickerRow(title: L.t("agent.connectors"), subtitle: L.t("network.scopeMCPLine"), scope: .mcp, allowFollowDefault: true)
            Kit.divider
            routePickerRow(title: L.t("settingsHome.careBackup"), subtitle: L.t("network.scopeBackupLine"), scope: .backup, allowFollowDefault: true)
        }
        .opacity(runtime.settings.routingEnabled ? 1 : 0.5)
        .disabled(!runtime.settings.routingEnabled)
    }

    // MARK: Per-Service Routes

    private var servicesSection: some View {
        RowCard(
            title: L.t("network.servicesSection"),
            note: L.t("network.servicesNote")
        ) {
            ForEach(Array(endpoints.enumerated()), id: \.element.id) { idx, endpoint in
                if idx > 0 { Kit.divider }
                routePickerRow(
                    title: endpoint.name,
                    subtitle: endpoint.baseURL,
                    scope: .service(endpoint.id),
                    allowFollowDefault: true
                )
            }
        }
        .opacity(runtime.settings.routingEnabled ? 1 : 0.5)
        .disabled(!runtime.settings.routingEnabled)
    }

    private func routePickerRow(
        title: String,
        subtitle: String,
        scope: NetworkScope,
        allowFollowDefault: Bool
    ) -> some View {
        let current = runtime.settings.configuredRoute(for: scope)
        return HStack(spacing: Ink.Space.m) {
            VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
                Text(title)
                    .font(Ink.label)
                    .foregroundStyle(Ink.ink)
                    .lineLimit(1)
                Text(subtitle)
                    .font(Ink.footnote)
                    .foregroundStyle(Ink.inkSoft)
                    .lineLimit(1)
            }
            Spacer(minLength: Ink.Space.s)
            Menu {
                if allowFollowDefault {
                    Button {
                        runtime.update { $0 = $0.settingRoute(.followDefault, for: scope) }
                    } label: {
                        routeMenuLabel(L.t("network.routeFollowDefault"), selected: current == .followDefault)
                    }
                }
                Button {
                    runtime.update { $0 = $0.settingRoute(.direct, for: scope) }
                } label: {
                    routeMenuLabel(L.t("network.routeDirect"), selected: current == .direct)
                }
                if !runtime.settings.proxies.isEmpty {
                    Divider()
                    ForEach(runtime.settings.proxies) { proxy in
                        Button {
                            runtime.update { $0 = $0.settingRoute(.proxy(proxy.id), for: scope) }
                        } label: {
                            routeMenuLabel(proxy.displayName, selected: current == .proxy(proxy.id))
                        }
                    }
                }
            } label: {
                HStack(spacing: Ink.Space.xs) {
                    Text(routeLabel(for: current))
                        .font(Ink.secondary)
                        .foregroundStyle(Ink.accent)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: Ink.Size.micro, weight: .semibold))
                        .foregroundStyle(Ink.inkFaint)
                }
                .padding(.horizontal, Ink.Space.m)
                .padding(.vertical, Ink.Space.xs)
                .background(Ink.accentWash, in: Capsule())
            }
        }
        .padding(.horizontal, Ink.Space.l)
        .padding(.vertical, Ink.Space.m)
    }

    @ViewBuilder
    private func routeMenuLabel(_ title: String, selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private func routeLabel(for route: NetworkRoute) -> String {
        switch route {
        case .followDefault:
            let eff = runtime.settings.defaultRoute
            let suffix = routeLabel(for: eff)
            return "\(L.t("network.routeFollowDefault"))（\(suffix)）"
        case .direct:
            return L.t("network.routeDirect")
        case .proxy(let id):
            return runtime.settings.proxy(id: id)?.displayName ?? L.t("network.routeDirect")
        }
    }

    // MARK: Den DNS (Unified from legacy DenDNSSettingsSheet)

    private var denDNSSection: some View {
        RowCard(
            title: L.t("network.dnsSection"),
            note: L.t("network.dnsNote")
        ) {
            VStack(alignment: .leading, spacing: Ink.Space.m) {
                Picker(L.t("network.dnsMode"), selection: $dnsMode) {
                    Text(L.t("network.dnsAuto")).tag(DenDNSMode.auto)
                    Text(L.t("network.dnsCustom")).tag(DenDNSMode.custom)
                }
                .pickerStyle(.segmented)
                .onChange(of: dnsMode) { _, newMode in
                    if newMode == .auto {
                        dnsValidationNote = nil
                        den.updateDNSConfiguration(mode: .auto, customInput: dnsCustomText)
                    }
                }

                if dnsMode == .custom {
                    TextField("192.168.1.1, 10.0.0.2 或 fe80::1%en0", text: $dnsCustomText, axis: .vertical)
                        .font(Ink.mono(Ink.Size.small))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(Ink.Space.m)
                        .background(Ink.paper, in: RoundedRectangle(cornerRadius: Ink.Radius.small, style: .continuous))

                    HStack {
                        Spacer()
                        Button(L.t("network.applyDNS")) {
                            Haptics.light()
                            let parsed = DenDNSConfig.parseCustomDNSList(dnsCustomText)
                            if parsed.valid.isEmpty {
                                dnsValidationNote = "请输入至少一个有效的 IPv4 或 IPv6 地址。"
                                return
                            }
                            dnsValidationNote = parsed.invalid.isEmpty
                                ? nil
                                : "已忽略无效地址：\(parsed.invalid.joined(separator: "、"))"
                            dnsCustomText = parsed.valid.joined(separator: ", ")
                            den.updateDNSConfiguration(mode: .custom, customInput: dnsCustomText)
                        }
                        .font(Ink.label)
                        .foregroundStyle(Ink.paper)
                        .padding(.horizontal, Ink.Space.l)
                        .padding(.vertical, Ink.Space.s)
                        .background(Ink.accent, in: Capsule())
                    }
                }

                if let note = dnsValidationNote ?? den.lastDNSError {
                    Text(note)
                        .font(Ink.footnote)
                        .foregroundStyle(Ink.stop)
                }

                Kit.rule(inset: 0)

                VStack(alignment: .leading, spacing: Ink.Space.xs) {
                    Text(L.t("network.currentDNS"))
                        .font(Ink.footnote)
                        .foregroundStyle(Ink.inkSoft)
                    if den.appliedDNSServers.isEmpty {
                        Text(L.t("network.dnsPending"))
                            .font(Ink.footnote)
                            .foregroundStyle(Ink.inkFaint)
                    } else {
                        ForEach(den.appliedDNSServers, id: \.self) { server in
                            Text(server)
                                .font(Ink.mono(Ink.Size.small))
                                .foregroundStyle(Ink.ink)
                        }
                    }
                    if !den.appliedSearchDomains.isEmpty {
                        Text("search \(den.appliedSearchDomains.joined(separator: " "))")
                            .font(Ink.mono(Ink.Size.micro))
                            .foregroundStyle(Ink.inkSoft)
                    }
                }
            }
            .padding(Ink.Space.l)
        }
    }

    // MARK: Built-in Diagnostics

    private var diagnosticsSection: some View {
        RowCard(
            title: L.t("network.diagnosticsSection"),
            note: L.t("network.diagnosticsNote")
        ) {
            VStack(alignment: .leading, spacing: Ink.Space.m) {
                HStack(spacing: Ink.Space.m) {
                    Button {
                        Haptics.light()
                        Task {
                            diagnosing = true
                            diagnosticItems = await runtime.runDiagnostics()
                            diagnosing = false
                        }
                    } label: {
                        HStack(spacing: Ink.Space.s) {
                            if diagnosing {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "stethoscope")
                            }
                            Text(diagnosing ? L.t("network.diagnosing") : L.t("network.runDiagnostics"))
                                .font(Ink.label)
                        }
                        .foregroundStyle(Ink.paper)
                        .padding(.horizontal, Ink.Space.l)
                        .padding(.vertical, Ink.Space.s)
                        .background(Ink.accent, in: Capsule())
                    }
                    .disabled(diagnosing)

                    if !diagnosticItems.isEmpty {
                        Button {
                            Haptics.light()
                            UIPasteboard.general.string = runtime.formattedDiagnosticReport(items: diagnosticItems)
                            copiedReport = true
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                copiedReport = false
                            }
                        } label: {
                            Text(copiedReport ? L.t("network.copiedReport") : L.t("network.copyReport"))
                                .font(Ink.secondary)
                                .foregroundStyle(Ink.ink)
                                .padding(.horizontal, Ink.Space.m)
                                .padding(.vertical, Ink.Space.s)
                                .background(Ink.paper, in: Capsule())
                        }
                    }
                    Spacer(minLength: 0)
                }

                if !diagnosticItems.isEmpty {
                    Kit.rule(inset: 0)
                    VStack(alignment: .leading, spacing: Ink.Space.s) {
                        ForEach(diagnosticItems) { item in
                            HStack(alignment: .top, spacing: Ink.Space.s) {
                                Image(systemName: icon(for: item.status))
                                    .font(.system(size: Ink.Size.small, weight: .semibold))
                                    .foregroundStyle(color(for: item.status))
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: Ink.Space.xs) {
                                        Text(item.name)
                                            .font(Ink.label)
                                            .foregroundStyle(Ink.ink)
                                        if item.elapsedMs > 0 {
                                            Text("\(item.elapsedMs)ms")
                                                .font(Ink.mono(Ink.Size.micro))
                                                .foregroundStyle(Ink.inkFaint)
                                        }
                                    }
                                    Text(item.detail)
                                        .font(Ink.footnote)
                                        .foregroundStyle(Ink.inkSoft)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
            }
            .padding(Ink.Space.l)
        }
    }

    private func icon(for status: ClioNetHub.DiagnosticItem.Status) -> String {
        switch status {
        case .ok: "checkmark.circle.fill"
        case .warn: "exclamationmark.circle.fill"
        case .fail: "xmark.circle.fill"
        case .skip: "minus.circle"
        }
    }

    private func color(for status: ClioNetHub.DiagnosticItem.Status) -> Color {
        switch status {
        case .ok: Ink.ok
        case .warn: Ink.warn
        case .fail: Ink.stop
        case .skip: Ink.inkFaint
        }
    }
}

// MARK: Proxy Editor Sheet

private struct ProxyEditorSheet: View {
    let profile: ProxyProfile?
    let onSave: (ProxyProfile, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var kind: ProxyKind = .socks5
    @State private var host: String = ""
    @State private var portText: String = "1080"
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var clearExistingPassword = false
    @State private var bypassText: String = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section(L.t("network.proxyBasics")) {
                    TextField(L.t("network.proxyNamePlaceholder"), text: $name)
                    Picker(L.t("network.proxyType"), selection: $kind) {
                        ForEach(ProxyKind.allCases, id: \.self) { item in
                            Text(item.displayName).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    TextField(L.t("network.proxyHostPlaceholder"), text: $host)
                        .font(Ink.mono(Ink.Size.sub))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField(L.t("network.proxyPortPlaceholder"), text: $portText)
                        .font(Ink.mono(Ink.Size.sub))
                        .keyboardType(.numberPad)
                }

                Section {
                    TextField(L.t("network.proxyUserPlaceholder"), text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField(passwordPlaceholder, text: $password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if let profile, NetworkRuntime.shared.hasStoredPassword(for: profile.id), password.isEmpty {
                        Toggle(L.t("network.clearSavedPassword"), isOn: $clearExistingPassword)
                    }
                } header: {
                    Text(L.t("network.proxyAuthSection"))
                } footer: {
                    Text(L.t("network.proxyPasswordKeychainNote"))
                }

                Section {
                    TextField("38.39.24.229, *.cn, 10.0.0.0/8, 192.168.0.0/16", text: $bypassText, axis: .vertical)
                        .font(Ink.mono(Ink.Size.small))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text(L.t("network.bypassSection"))
                } footer: {
                    Text(L.t("network.bypassFooter"))
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(Ink.footnote)
                            .foregroundStyle(Ink.stop)
                    }
                }

                if let profile {
                    Section {
                        Button(L.t("actions.delete"), role: .destructive) {
                            NetworkRuntime.shared.deleteProxy(id: profile.id)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(profile == nil ? L.t("network.addProxy") : L.t("network.editProxy"))
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
                guard let profile else { return }
                name = profile.name
                kind = profile.kind
                host = profile.host
                portText = "\(profile.port)"
                username = profile.username
                bypassText = profile.bypass.joined(separator: ", ")
            }
        }
    }

    private var passwordPlaceholder: String {
        if let profile, NetworkRuntime.shared.hasStoredPassword(for: profile.id) {
            return L.t("network.proxyPasswordSavedPlaceholder")
        }
        return L.t("network.proxyPasswordPlaceholder")
    }

    private func save() {
        guard let port = Int(portText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorMessage = "端口必须是数字。"
            return
        }
        let candidate = ProxyProfile(
            id: profile?.id ?? UUID().uuidString.uppercased(),
            name: name,
            kind: kind,
            host: host,
            port: port,
            username: username,
            bypass: NetworkBypassMatcher.parseBypassText(bypassText)
        )
        if let err = candidate.validationError() {
            errorMessage = err
            return
        }
        let passwordToStore: String?
        if clearExistingPassword {
            passwordToStore = ""
        } else if !password.isEmpty {
            passwordToStore = password
        } else {
            passwordToStore = nil
        }
        onSave(candidate, passwordToStore)
        dismiss()
    }
}
