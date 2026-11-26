import AgentKit
import SwiftUI

/// 应许: every ability on one page, with the user's say and the system's say side by side.
struct GrantsPage: View {
    let team: TeamModel
    var embedded = false
    @Environment(\.dismiss) private var dismiss
    @State private var asking = false
    @Environment(\.scenePhase) private var phase
    @State private var policies: [Grant: Grant.Policy] = [:]
    @State private var systems: [Grant: Grant.System] = [:]
    @State private var alwaysAllowed: [String] = []
    @State private var fakeIPCompat = PrivateNetworkPolicy.shared.fakeIPCompatEnabled
    @State private var privateGrants: [PrivateNetworkGrant] = PrivateNetworkPolicy.shared.grants
    @State private var addingPrivateGrant = false
    @AppStorage(Grant.followAfterWebKey) private var followAfterWeb = false

    private var groups: [(String, [Grant])] { [
        (L.t("permissions.web"), [.web, .browser, .links]),
        (L.t("permissions.connections"), [.hills, .mcp, .google, .vault]),
        (L.t("nav.filesAndTerminal"), [.desk, .den, .memory, .letters]),
        (L.t("permissions.onPhone"), [.calendar, .reminders, .contacts, .photos, .clipboard]),
        (L.t("permissions.personal"), [.location, .motion, .health, .device]),
    ] }

    var body: some View {
        Group {
            if embedded {
                content
            } else {
                NavigationStack { content }
            }
        }
        .onAppear {
            loadPolicies()
            syncPrivateNetworkState()
            let sorted = team.alwaysAllowed.sorted()
            if alwaysAllowed != sorted { alwaysAllowed = sorted }
        }
        .sheet(isPresented: $addingPrivateGrant, onDismiss: { syncPrivateNetworkState() }) {
            PrivateGrantEditorSheet { grant in
                if PrivateNetworkPolicy.shared.addGrant(grant) {
                    syncPrivateNetworkState()
                    team.reconcilePendingApprovals()
                }
            }
        }
        .onReceive(team.$alwaysAllowed.removeDuplicates()) { updated in
            let sorted = updated.sorted()
            if alwaysAllowed != sorted { alwaysAllowed = sorted }
        }
        .task { await loadSystems() }
        .onChange(of: phase) { _, now in
            if now == .active {
                loadPolicies()
                Task { await loadSystems() }
            }
        }
    }

    private var content: some View {
        ZStack {
            Ink.paper.ignoresSafeArea()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Ink.Space.xl) {
                    presets
                    webGuardCard
                    privateNetworkSection
                    Button {
                        askAll()
                    } label: {
                        HStack(spacing: Ink.Space.m) {
                            Image(systemName: "checkmark.seal").font(.system(size: Ink.Size.title)).foregroundStyle(Ink.accent)
                            VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
                                Text(asking ? L.t("loading.requestingPermissions") : L.t("actions.requestAllPermissions")).font(Ink.serif(Ink.Size.body, bold: true)).foregroundStyle(Ink.ink)
                                Text(L.t("settings.requestPermissionsNote"))
                                    .font(Ink.footnote).foregroundStyle(Ink.inkSoft)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(Ink.Space.l)
                        .paperCard()
                    }
                    .buttonStyle(PressStyle())
                    .disabled(asking)
                    ForEach(groups, id: \.0) { group in
                        VStack(alignment: .leading, spacing: Ink.Space.s) {
                            SectionTitle(group.0)
                            LazyVStack(spacing: 0) {
                                ForEach(group.1) { grant in
                                    row(grant)
                                    if grant != group.1.last { Kit.divider }
                                }
                            }
                            .paperCard()
                        }
                    }
                    if !alwaysAllowed.isEmpty {
                        AlwaysAllowedSection(team: team, tools: alwaysAllowed)
                    }
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    } label: {
                        Label("去系统设置里看 Clio 的权限", systemImage: "gear")
                            .font(.system(size: Ink.Size.sub, weight: .medium))
                            .foregroundStyle(Ink.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Ink.Space.m)
                    }
                    .buttonStyle(PressStyle())
                }
                .padding(.horizontal, Ink.Space.page)
                .padding(.vertical, Ink.Space.l)
            }
        }
        .navigationTitle(L.t("settings.permissions"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !embedded {
                ToolbarItem(placement: .topBarTrailing) { Button(L.t("actions.done")) { dismiss() } }
            }
        }
    }

    /// Asks the system about every enabled ability not yet asked, without overriding the user's chosen policy.
    private func askAll() {
        asking = true
        Task {
            let currentSystems = await Grant.readSystemStatuses()
            systems = currentSystems
            for grant in Grant.allCases where grant.policy != .off && currentSystems[grant] == .notAsked {
                await grant.requestSystem()
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
            if Grant.letters.policy != .off {
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                if settings.authorizationStatus == .notDetermined {
                    await Grant.letters.requestSystem()
                }
            }
            loadPolicies()
            await loadSystems()
            asking = false
            Haptics.thud()
        }
    }

    private func loadPolicies() {
        for grant in Grant.allCases {
            policies[grant] = grant.policy
        }
    }

    private func loadSystems() async {
        let fetched = await Grant.readSystemStatuses()
        guard !Task.isCancelled else { return }
        systems = fetched
    }

    /// Presets for the abilities below, which can also be set one by one.
    private var presets: some View {
        let current = Grant.Preset.current
        return VStack(alignment: .leading, spacing: Ink.Space.s) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: Ink.Space.s) {
                ForEach(Grant.Preset.allCases) { preset in
                    Button {
                        Haptics.tick(0.6)
                        preset.apply()
                        for grant in Grant.allCases { policies[grant] = grant.policy }
                        team.reconcilePendingApprovals()
                    } label: {
                        VStack(spacing: Ink.Space.xs / 2) {
                            Text(preset.title).font(.system(size: Ink.Size.sub, weight: .semibold))
                            Text(preset.line).font(.system(size: Ink.Size.micro)).lineLimit(2).multilineTextAlignment(.center)
                        }
                        .foregroundStyle(current == preset ? Ink.accent : Ink.inkSoft)
                        .frame(maxWidth: .infinity, minHeight: 64)
                        .padding(.horizontal, Ink.Space.xs)
                        .background(current == preset ? Ink.accentWash : Ink.paperRaised, in: .rect(cornerRadius: Ink.Radius.card, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Ink.Radius.card, style: .continuous).strokeBorder(current == preset ? Color.clear : Ink.rule))
                    }
                    .buttonStyle(PressStyle(haptic: false))
                    .accessibilityAddTraits(current == preset ? .isSelected : [])
                }
            }
            Text(current == nil ? L.t("settings.customPermissions") : L.t("settings.editPermissionsNote"))
                .font(Ink.footnote).foregroundStyle(Ink.inkFaint).padding(.leading, Ink.Space.xs)
        }
    }

    private var webGuardCard: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            HStack(alignment: .top, spacing: Ink.Space.m) {
                IconBadge(symbol: "exclamationmark.shield", tint: followAfterWeb ? Ink.Tile.xiang : Ink.Tile.off)
                Toggle(isOn: $followAfterWeb) {
                    VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
                        Text(L.t("permissions.followAfterWeb"))
                            .font(.system(size: Ink.Size.body, weight: .medium))
                            .foregroundStyle(Ink.ink)
                        Text(L.t("permissions.followAfterWebNote"))
                            .font(Ink.footnote)
                            .foregroundStyle(Ink.inkSoft)
                    }
                }
                .tint(Ink.warn)
            }
        }
        .padding(.horizontal, Ink.Space.l)
        .padding(.vertical, Ink.Space.m)
        .paperCard()
        .onChange(of: followAfterWeb) { _, _ in
            Haptics.tick(0.5)
            team.reconcilePendingApprovals()
        }
    }

    private func row(_ grant: Grant) -> some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            HStack(alignment: .top, spacing: Ink.Space.m) {
                IconBadge(symbol: grant.symbol, tint: policies[grant] == .off ? Ink.Tile.off : Ink.Tile.accent)
                VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
                    HStack(spacing: Ink.Space.s) {
                        Text(grant.title).font(.system(size: Ink.Size.body, weight: .medium)).foregroundStyle(Ink.ink)
                        systemBadge(grant)
                    }
                    Text(grant.note).font(Ink.footnote).foregroundStyle(Ink.inkSoft)
                }
                Spacer(minLength: 0)
            }
            Picker(grant.title, selection: Binding(get: { policies[grant] ?? grant.policy }, set: { value in
                Haptics.tick(0.5)
                grant.policy = value
                policies[grant] = value
                team.reconcilePendingApprovals()
                if value != .off, systems[grant] == .notAsked {
                    Task {
                        await grant.requestSystem()
                        systems[grant] = await grant.readSystem()
                    }
                }
            })) {
                ForEach(grant.availablePolicies, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.leading, Kit.badge + Ink.Space.m)
        }
        .padding(.horizontal, Ink.Space.l)
        .padding(.vertical, Ink.Space.m)
    }

    @ViewBuilder
    private func systemBadge(_ grant: Grant) -> some View {
        switch systems[grant] ?? .none {
        case .none:
            EmptyView()
        case .asked:
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            } label: { badge("已在系统健康中设置", Ink.inkSoft) }
            .buttonStyle(PressStyle())
        case .granted:
            badge("系统已允许", Ink.ok)
        case .limited:
            badge("系统部分允许", Ink.warn)
        case .notAsked:
            Button {
                Task {
                    await grant.requestSystem()
                    systems[grant] = await grant.readSystem()
                }
            } label: { badge("向系统请求", Ink.accent) }
            .buttonStyle(PressStyle())
        case .denied:
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            } label: { badge("系统已拒绝 · 去设置", Ink.stop) }
            .buttonStyle(PressStyle())
        }
    }

    private func syncPrivateNetworkState() {
        fakeIPCompat = PrivateNetworkPolicy.shared.fakeIPCompatEnabled
        privateGrants = PrivateNetworkPolicy.shared.grants
    }

    private var privateNetworkSection: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle(L.t("privateNet.sectionTitle"))
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: Ink.Space.xs) {
                    Toggle(isOn: Binding(
                        get: { fakeIPCompat },
                        set: { next in
                            Haptics.tick(0.5)
                            fakeIPCompat = next
                            PrivateNetworkPolicy.shared.fakeIPCompatEnabled = next
                            team.reconcilePendingApprovals()
                        }
                    )) {
                        VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
                            Text(L.t("privateNet.fakeIPToggle"))
                                .font(.system(size: Ink.Size.body, weight: .medium))
                                .foregroundStyle(Ink.ink)
                            Text(L.t("privateNet.fakeIPNote"))
                                .font(Ink.footnote)
                                .foregroundStyle(Ink.inkSoft)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .tint(Ink.accent)
                }
                .padding(.horizontal, Ink.Space.l)
                .padding(.vertical, Ink.Space.m)

                Kit.divider

                if privateGrants.isEmpty {
                    Text(L.t("privateNet.grantsEmpty"))
                        .font(Ink.footnote)
                        .foregroundStyle(Ink.inkSoft)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Ink.Space.l)
                        .padding(.vertical, Ink.Space.m)
                } else {
                    ForEach(privateGrants) { grant in
                        privateGrantRow(grant)
                        Kit.divider
                    }
                }

                Button {
                    Haptics.light()
                    addingPrivateGrant = true
                } label: {
                    RowLabel("plus", tint: Ink.Tile.xiang, title: L.t("actions.addPrivateEndpoint"))
                }
                .buttonStyle(PressStyle(haptic: false))
            }
            .paperCard()

            if !privateGrants.isEmpty {
                Text(L.t("privateNet.grantsFooter"))
                    .font(Ink.footnote)
                    .foregroundStyle(Ink.inkFaint)
                    .padding(.horizontal, Ink.Space.xs)
            }
        }
    }

    private func privateGrantRow(_ grant: PrivateNetworkGrant) -> some View {
        let portText = grant.port.map { ":\($0)" } ?? ""
        let proto = grant.allowPlainHTTP ? "HTTP/HTTPS" : "HTTPS"
        return HStack(alignment: .center, spacing: Ink.Space.m) {
            IconBadge(symbol: "network.badge.shield.half.filled", tint: Ink.Tile.zhu)
            VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
                HStack(spacing: Ink.Space.s) {
                    Text(grant.label)
                        .font(.system(size: Ink.Size.body, weight: .medium))
                        .foregroundStyle(Ink.ink)
                        .lineLimit(1)
                    badge(Self.actionTitle(grant.maxAction), Ink.accent)
                }
                Text("\(grant.hostPattern)\(portText) · \(proto)")
                    .font(Ink.mono(Ink.Size.small))
                    .foregroundStyle(Ink.inkSoft)
                    .lineLimit(1)
            }
            Spacer(minLength: Ink.Space.s)
            Button(L.t("actions.revoke")) {
                Haptics.tick(0.5)
                withAnimation(Ink.Motion.settle) {
                    PrivateNetworkPolicy.shared.revokeGrant(id: grant.id)
                    privateGrants = PrivateNetworkPolicy.shared.grants
                    team.reconcilePendingApprovals()
                }
            }
            .font(.system(size: Ink.Size.small, weight: .medium))
            .foregroundStyle(Ink.stop)
        }
        .padding(.horizontal, Ink.Space.l)
        .padding(.vertical, Ink.Space.m)
    }

    private static func actionTitle(_ action: PrivateNetworkAction) -> String {
        switch action {
        case .reach, .read: L.t("privateNet.scopeRead")
        case .write: L.t("privateNet.scopeWrite")
        case .credential, .crossNetworkExfil: L.t("privateNet.scopeCredential")
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: Ink.Size.micro, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, Ink.Space.s)
            .padding(.vertical, Ink.Space.xs / 2)
            .background(color.opacity(0.12), in: .capsule)
    }
}

private struct AlwaysAllowedSection: View {
    let team: TeamModel
    let tools: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle(L.t("permissions.alwaysAllowed"))
            LazyVStack(spacing: 0) {
                ForEach(tools, id: \.self) { tool in
                    HStack {
                        Text(tool).font(Ink.mono(Ink.Size.sub)).foregroundStyle(Ink.ink)
                        Spacer()
                        Button(L.t("actions.revokePermission")) { withAnimation(.smooth) { team.revokeAlways(tool) } }
                            .font(.system(size: Ink.Size.sub, weight: .medium)).foregroundStyle(Ink.stop)
                    }
                    .padding(.horizontal, Ink.Space.l)
                    .padding(.vertical, Ink.Space.m)
                }
            }
            .paperCard()
        }
    }
}

private struct PrivateGrantEditorSheet: View {
    let onSave: (PrivateNetworkGrant) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var hostPattern = ""
    @State private var portText = ""
    @State private var allowPlainHTTP = false
    @State private var maxAction: PrivateNetworkAction = .read

    private var parsedPort: Int? {
        let trimmed = portText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let value = Int(trimmed), (1...65535).contains(value) else { return -1 }
        return value
    }

    private var portValid: Bool {
        parsedPort != -1
    }

    private var patternValid: Bool {
        PrivateNetworkGrant.isValidPattern(hostPattern)
    }

    private var canSave: Bool {
        patternValid && portValid
    }

    var body: some View {
        NavigationStack {
            Form {
                PaperRows {
                    Section {
                        TextField(L.t("privateNet.labelField"), text: $label)
                        TextField(L.t("privateNet.hostField"), text: $hostPattern)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        TextField(L.t("privateNet.portField"), text: $portText)
                            .keyboardType(.numberPad)
                    } footer: {
                        if !hostPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !patternValid {
                            Text(L.t("privateNet.invalidHostError"))
                                .foregroundStyle(Ink.stop)
                        }
                    }

                    Section {
                        Picker(L.t("privateNet.scopePicker"), selection: $maxAction) {
                            Text(L.t("privateNet.scopeRead")).tag(PrivateNetworkAction.read)
                            Text(L.t("privateNet.scopeWrite")).tag(PrivateNetworkAction.write)
                            Text(L.t("privateNet.scopeCredential")).tag(PrivateNetworkAction.credential)
                        }
                        Toggle(L.t("privateNet.allowHTTP"), isOn: $allowPlainHTTP)
                    } footer: {
                        Text(L.t("privateNet.grantsFooter"))
                    }
                }
            }
            .paperForm()
            .navigationTitle(L.t("privateNet.editorTitle"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L.t("actions.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L.t("actions.save")) {
                        let cleanHost = PrivateNetworkGrant.normalizePattern(hostPattern)
                        let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
                        let port = parsedPort == -1 ? nil : parsedPort
                        onSave(PrivateNetworkGrant(
                            label: cleanLabel.isEmpty ? cleanHost : cleanLabel,
                            hostPattern: cleanHost,
                            port: port,
                            allowPlainHTTP: allowPlainHTTP,
                            maxAction: maxAction
                        ))
                        Haptics.thud()
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }
}
