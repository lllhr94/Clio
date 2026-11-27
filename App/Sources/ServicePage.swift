import AgentKit
import Craft
import Foundation
import SwiftUI
import UIKit

/// One model service, organized into three clear sections: enabled models, connection & key, and advanced.
struct ServicePage: View {
    @ObservedObject var team: TeamModel
    let id: String
    @State private var currentID: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var note: String?
    @State private var working = false
    @State private var managingModels = false
    @State private var showAdvanced = false
    @State private var editing: String?
    @State private var removing = false
    @State private var deleted = false
    @State private var name = ""
    @State private var address = ""
    @State private var style: ThinkingStyle?
    @State private var newKey = ""
    @State private var keySuffix: String?
    @State private var showConnection = false
    @State private var pausedOverride: Bool?
    @State private var cacheOverride: ServiceCacheTier?
    @State private var inFlightSave: Task<String?, Never>?
    @State private var pendingSavedFields: EndpointDraftFields?

    private struct EndpointDraftFields: Equatable {
        let name: String
        let address: String
        let style: ThinkingStyle?
    }

    init(team: TeamModel, id: String) {
        self.team = team
        self.id = id
        _currentID = State(initialValue: id)
    }

    private var endpoint: Endpoint? { team.settings.endpoints.first { $0.id == currentID } }
    private var service: Service? { endpoint.flatMap(Service.of) }

    var body: some View {
        ScrollView {
            if let endpoint {
                VStack(alignment: .leading, spacing: Ink.Space.xl) {
                    hero(endpoint)
                    if let disabledReason = endpoint.disabledProtocolReason {
                        Text(disabledReason)
                            .font(Ink.secondary)
                            .foregroundStyle(Ink.stop)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Ink.Space.l)
                            .background(Ink.stop.opacity(0.08), in: .rect(cornerRadius: Ink.Radius.card, style: .continuous))
                    }
                    if let subtitle = service?.note {
                        Text(subtitle)
                            .font(Ink.secondary)
                            .foregroundStyle(Ink.inkSoft)
                    }
                    inUse(endpoint)
                    connection(endpoint)
                    preferences(endpoint)
                    advanced(endpoint)
                    Button(L.t("actions.deleteProvider"), role: .destructive) { removing = true }
                        .font(.system(size: Ink.Size.sub, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Ink.Space.m)
                }
                .padding(.horizontal, Ink.Space.page)
                .padding(.vertical, Ink.Space.l)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollEdgeEffectStyle(.soft, for: .vertical)
        .background(Ink.paper.ignoresSafeArea())
        .navigationTitle(endpoint?.name ?? L.t("settings.modelService"))
        .navigationBarTitleDisplayMode(.inline)
        .hitchPage("服务")
        .onAppear {
            guard let endpoint else { return }
            name = endpoint.name
            address = endpoint.baseURL
            style = endpoint.style
        }
        .onChange(of: currentID) {
            pausedOverride = nil
            cacheOverride = nil
        }
        .task(id: currentID) {
            let key = await team.readAPIKey(for: currentID)
            guard !Task.isCancelled else { return }
            if let key, key.count > 8 {
                keySuffix = String(key.suffix(4))
            } else {
                keySuffix = nil
            }
        }
        .sheet(isPresented: $managingModels) {
            ManageModelsSheet(team: team, id: currentID)
        }
        .sheet(item: Binding(get: { editing.map { Picked(model: $0) } }, set: { editing = $0?.model })) { picked in
            ModelSheet(team: team, endpointId: currentID, model: picked.model)
                .detentPaperBackdrop(initial: .large, detents: [.large])
        }
        // A name or address typed and left without pressing return is kept, not lost.
        .onDisappear {
            if let endpoint, !removing, !deleted,
               name != endpoint.name || address != endpoint.baseURL || style != endpoint.style {
                let currentFields = EndpointDraftFields(name: name, address: address, style: style)
                if let pendingSavedFields, pendingSavedFields == currentFields {
                    return
                }
                let targetID = endpoint.id
                let trimmedKey = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
                let previousSave = inFlightSave
                let modelTeam = team
                Task {
                    let prevID = await previousSave?.value
                    let activeID = prevID ?? targetID
                    _ = await modelTeam.editEndpointAsync(
                        activeID,
                        name: currentFields.name,
                        baseURL: currentFields.address,
                        style: currentFields.style,
                        key: trimmedKey.isEmpty ? nil : trimmedKey
                    )
                }
            }
        }
        .confirmationDialog(L.format("servicePage.removeConfirm", endpoint?.name ?? ""), isPresented: $removing, titleVisibility: .visible) {
            Button(L.t("actions.delete"), role: .destructive) {
                deleted = true
                Task {
                    _ = await inFlightSave?.value
                    if await team.removeEndpointAsync(currentID) {
                        dismiss()
                    } else {
                        deleted = false
                        note = L.t("servicePage.settingsSaveFailed")
                        Haptics.lock()
                    }
                }
            }
            Button(L.t("actions.cancel"), role: .cancel) {}
        }
    }

    private struct Picked: Identifiable {
        var model: String
        var id: String { model }
    }

    private func pill(_ title: String, _ icon: String, _ run: @escaping () -> Void) -> some View {
        Button {
            Haptics.light()
            run()
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: Ink.Size.small, weight: .medium))
                .foregroundStyle(Ink.accent)
                .padding(.horizontal, Ink.Space.m)
                .frame(height: 30 * UIScale.factor)
                .background(Ink.accentWash, in: .capsule)
        }
        .buttonStyle(PressStyle(haptic: false))
        .disabled(working)
    }

    // MARK: 1. Enabled models

    private func inUse(_ endpoint: Endpoint) -> some View {
        ServiceActiveModelsSection(
            endpoint: endpoint,
            defaultModelRef: team.settings.defaultModel,
            onEdit: { editing = $0 },
            onManage: { managingModels = true },
            onRemove: { model in
                withAnimation(.smooth) {
                    team.setModels(endpoint.id, endpoint.models.filter { $0 != model })
                }
            }
        )
    }

    // MARK: 2. Connection and key

    private func connection(_ endpoint: Endpoint) -> some View {
        DisclosureGroup(isExpanded: $showConnection) {
            VStack(alignment: .leading, spacing: Ink.Space.m) {
                labeled(L.t("servicePage.nameLabel")) {
                    TextField(L.t("servicePage.nameLabel"), text: $name)
                        .font(.system(size: Ink.Size.sub))
                        .onSubmit { Task { await save(endpoint) } }
                }
                Kit.rule(inset: 0)
                labeled(L.t("servicePage.addressLabel")) {
                    TextField("https://…", text: $address)
                        .font(Ink.mono(Ink.Size.sub))
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { Task { await save(endpoint) } }
                }
                if let service, service.addresses.count > 1 {
                    HStack(spacing: Ink.Space.s) {
                        ForEach(service.addresses, id: \.url) { option in
                            Button(option.label) {
                                Haptics.tick(0.5)
                                address = option.url
                                Task { await save(endpoint) }
                            }
                            .font(.system(size: Ink.Size.small, weight: .medium))
                            .foregroundStyle(address == option.url ? Ink.accent : Ink.inkSoft)
                            .padding(.horizontal, Ink.Space.m)
                            .frame(height: 28 * UIScale.factor)
                            .background(address == option.url ? Ink.accentWash : Ink.mine, in: .capsule)
                        }
                    }
                }
                Text(L.format("servicePage.resolvedURL", finalURL(endpoint)))
                    .font(Ink.mono(Ink.Size.small))
                    .foregroundStyle(Ink.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
                Kit.rule(inset: 0)
                labeled(L.t("servicePage.keyLabel")) {
                    HStack(spacing: Ink.Space.s) {
                        SecureField(maskedKey, text: $newKey)
                            .font(Ink.mono(Ink.Size.sub))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if !newKey.isEmpty {
                            Button(L.t("actions.replaceKey")) { replaceKey(endpoint) }
                                .font(.system(size: Ink.Size.sub, weight: .semibold))
                                .foregroundStyle(Ink.accent)
                        }
                    }
                }
                Text(L.t("settings.keyStorageNote"))
                    .font(Ink.footnote)
                    .foregroundStyle(Ink.inkFaint)
                Kit.rule(inset: 0)
                HStack(spacing: Ink.Space.s) {
                    pill("试连", "bolt.horizontal") { probe(endpoint) }
                    pill("刷新模型列表", "arrow.clockwise") { refresh(endpoint) }
                    if let page = service?.keyPage, let url = URL(string: page) {
                        pill(L.t("servicePage.manageKeys"), "arrow.up.right") { openURL(url) }
                    }
                }
                if let note {
                    Text(note)
                        .font(Ink.footnote)
                        .foregroundStyle(Ink.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, Ink.Space.m)
        } label: {
            Text(L.t("settings.connectionAndKey")).font(Ink.label).foregroundStyle(Ink.ink)
        }
        .tint(Ink.accent)
        .padding(Ink.Space.l)
        .paperCard()
    }

    // MARK: 3. Advanced (collapsed by default)

    private func advanced(_ endpoint: Endpoint) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                Haptics.light()
                withAnimation(Ink.Motion.settle) { showAdvanced.toggle() }
            } label: {
                HStack(spacing: Ink.Space.m) {
                    Text(L.t("settings.advanced"))
                        .font(.system(size: Ink.Size.body))
                        .foregroundStyle(Ink.ink)
                    Spacer(minLength: Ink.Space.s)
                    Image(systemName: showAdvanced ? "chevron.up" : "chevron.down")
                        .font(.system(size: Ink.Size.small, weight: .semibold))
                        .foregroundStyle(Ink.inkFaint)
                }
                .padding(.horizontal, Ink.Space.l)
                .frame(minHeight: Kit.rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(TapStyle())

            if showAdvanced {
                Kit.rule(inset: Ink.Space.l)
                VStack(alignment: .leading, spacing: Ink.Space.m) {
                    HStack {
                        Text(L.t("settings.apiType"))
                            .font(.system(size: Ink.Size.sub))
                            .foregroundStyle(Ink.ink)
                        Spacer()
                        Text(endpoint.kind.displayTitle)
                            .font(.system(size: Ink.Size.sub))
                            .foregroundStyle(endpoint.isActiveProtocol ? Ink.inkSoft : Ink.stop)
                    }
                    if endpoint.kind.supportsThinkingStyleSelection {
                        Kit.rule(inset: 0)
                        thinkingStyleRow(endpoint)
                        Text(thinkingLevelsSummary(endpoint))
                            .font(Ink.footnote)
                            .foregroundStyle(Ink.inkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if endpoint.overrides?.isEmpty == false {
                        Kit.rule(inset: 0)
                        Button {
                            Haptics.tick(0.5)
                            team.resetAllTraitsToCatalog(for: endpoint.id)
                            note = "已将此服务下所有模型的能力恢复为跟随目录。"
                        } label: {
                            HStack(spacing: Ink.Space.s) {
                                Image(systemName: "arrow.uturn.backward")
                                    .font(.system(size: Ink.Size.sub, weight: .medium))
                                Text("恢复跟随目录")
                                    .font(.system(size: Ink.Size.sub, weight: .medium))
                                Spacer()
                            }
                            .foregroundStyle(Ink.accent)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(Ink.Space.l)
                .transition(.opacity)
            }
        }
        .paperCard()
    }

    private func promptCacheRow(_ endpoint: Endpoint) -> some View {
        let stops: [Stop<ServiceCacheTier>] = [
            Stop(value: .off, name: L.t("services.cacheOff")),
            Stop(value: .fiveMinutes, name: L.t("services.cacheFiveMinutes")),
            Stop(value: .oneHour, name: L.t("services.cacheOneHour")),
        ]
        let current = cacheOverride ?? ServiceExtras.cacheTier(endpoint.id, fallback: endpoint.usesPromptCache ? .fiveMinutes : .off)
        return StopRow(
            title: L.t("services.cacheTier"),
            value: Binding(
                get: { cacheOverride ?? current },
                set: { tier in
                    ServiceExtras.setCacheTier(tier, for: endpoint.id)
                    if endpoint.usesPromptCache != (tier != .off) { team.setPromptCache(endpoint.id, enabled: tier != .off) }
                    cacheOverride = tier
                }
            ),
            stops: stops
        )
        .id(endpoint.id)
    }

    private func preferences(_ endpoint: Endpoint) -> some View {
        let paused = pausedOverride ?? ServiceExtras.isPaused(endpoint.id)
        return VStack(alignment: .leading, spacing: Ink.Space.m) {
            Toggle(isOn: Binding(
                get: { pausedOverride ?? paused },
                set: {
                    ServiceExtras.setPaused($0, for: endpoint.id)
                    pausedOverride = $0
                }
            )) {
                Text(L.t("services.pauseService")).font(Ink.label).foregroundStyle(Ink.ink)
            }
            .tint(Ink.accent)
            Text(L.t("services.pauseNote")).font(Ink.footnote).foregroundStyle(Ink.inkSoft)
            if endpoint.kind == .anthropic {
                Kit.rule(inset: 0)
                promptCacheRow(endpoint)
            }
            Kit.rule(inset: 0)
            ServiceHeaderEditor(endpointID: endpoint.id)
                .id(endpoint.id)
        }
        .padding(Ink.Space.l)
        .paperCard()
    }

    private func hero(_ endpoint: Endpoint) -> some View {
        VStack(alignment: .leading, spacing: Ink.Space.m) {
            ServiceArchiveHeader(endpoint: endpoint)
            ServiceBalanceLine(team: team, endpoint: endpoint, showsDashboard: true)
        }
        .padding(Ink.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperCard()
    }

    private func thinkingStyleRow(_ endpoint: Endpoint) -> some View {
        let followLabel = L.format("servicePage.followServiceStyle", endpoint.thinkingStyleGuess.title)
        return HStack(alignment: .top, spacing: Ink.Space.m) {
            VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
                Text(L.t("settings.thinkingFormat"))
                    .font(.system(size: Ink.Size.sub))
                    .foregroundStyle(Ink.ink)
                Text(L.t("settings.thinkingFormatNote"))
                    .font(Ink.footnote)
                    .foregroundStyle(Ink.inkFaint)
            }
            Spacer(minLength: Ink.Space.s)
            Menu {
                Button {
                    style = nil
                    Task { await save(endpoint) }
                } label: {
                    if style == nil {
                        Label(followLabel, systemImage: "checkmark")
                    } else {
                        Text(followLabel)
                    }
                }
                ForEach(ThinkingStyle.allCases, id: \.self) { option in
                    Button {
                        style = option
                        Task { await save(endpoint) }
                    } label: {
                        if style == option {
                            Label(option.title, systemImage: "checkmark")
                        } else {
                            Text(option.title)
                        }
                    }
                }
            } label: {
                HStack(spacing: Ink.Space.xs) {
                    Text(style?.title ?? L.t("settings.providerDefault"))
                        .font(.system(size: Ink.Size.sub, weight: .medium))
                        .foregroundStyle(Ink.accent)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: Ink.Size.micro, weight: .semibold))
                        .foregroundStyle(Ink.inkFaint)
                }
            }
        }
    }

    private func thinkingLevelsSummary(_ endpoint: Endpoint) -> String {
        let effective = style ?? endpoint.thinkingStyleGuess
        if effective == .none {
            return L.t("servicePage.thinkingNoneSummary")
        }
        let offered = effective.levels(thinks: true).map(\.title).joined(separator: " · ")
        return L.format("servicePage.thinkingOfferedSummary", offered)
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: Ink.Space.m) {
            Text(title)
                .font(.system(size: Ink.Size.sub))
                .foregroundStyle(Ink.inkSoft)
                .frame(width: 40 * UIScale.factor, alignment: .leading)
            content()
        }
    }

    private func finalURL(_ endpoint: Endpoint) -> String {
        var base = address.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        return base + endpoint.kind.defaultRoutePath
    }

    private var maskedKey: String {
        guard let keySuffix else { return L.t("servicePage.pasteNewKey") }
        return L.format("servicePage.savedKeyPlaceholder", keySuffix)
    }

    @discardableResult
    private func save(_ endpoint: Endpoint, quiet: Bool = false) async -> String? {
        let previous = inFlightSave
        let targetFields = EndpointDraftFields(name: name, address: address, style: style)
        pendingSavedFields = targetFields
        let task = Task<String?, Never> {
            let prevID = await previous?.value
            let activeEndpoint = prevID.flatMap { id in team.settings.endpoints.first { $0.id == id } }
                ?? team.settings.endpoints.first { $0.id == endpoint.id }
                ?? endpoint
            let trimmedKey = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let outcome = await team.editEndpointAsync(
                activeEndpoint.id,
                name: targetFields.name,
                baseURL: targetFields.address,
                style: targetFields.style,
                key: trimmedKey.isEmpty ? nil : trimmedKey
            )
            return handleEditOutcome(outcome, trimmedKey: trimmedKey, quiet: quiet)
        }
        inFlightSave = task
        let result = await task.value
        if let pendingSavedFields, pendingSavedFields == targetFields {
            self.pendingSavedFields = nil
        }
        return result
    }

    private func handleEditOutcome(_ outcome: EndpointKeyEditOutcome, trimmedKey: String, quiet: Bool) -> String? {
        switch outcome {
        case .saved(let nextID, let normalizedURL, let keyUpdated):
            currentID = nextID
            address = normalizedURL
            if keyUpdated {
                keySuffix = trimmedKey.count > 8 ? String(trimmedKey.suffix(4)) : nil
                newKey = ""
            }
            if note == L.t("servicePage.invalidAddress")
                || note == L.t("servicePage.keyRequiredForNewHost")
                || note == L.t("servicePage.keySaveFailed")
                || note == L.t("servicePage.settingsSaveFailed") {
                note = nil
            }
            return nextID
        case .invalidAddress:
            if !quiet {
                note = L.t("servicePage.invalidAddress")
                Haptics.lock()
            }
            return nil
        case .keyRequiredForNewHost:
            if !quiet {
                note = L.t("servicePage.keyRequiredForNewHost")
                Haptics.lock()
            }
            return nil
        case .keySaveFailed:
            if !quiet {
                note = L.t("servicePage.keySaveFailed")
                Haptics.lock()
            }
            return nil
        case .settingsSaveFailed:
            if !quiet {
                note = L.t("servicePage.settingsSaveFailed")
                Haptics.lock()
            }
            return nil
        }
    }

    private func replaceKey(_ endpoint: Endpoint) {
        let key = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        Task {
            guard await save(endpoint) != nil else { return }
            Haptics.thud()
            let message = L.t("servicePage.keyReplacedNotice")
            note = message
            ToastCenter.shared.show(message, symbol: "key.fill", tint: Ink.ok)
        }
    }

    // MARK: Doing

    private func refresh(_ endpoint: Endpoint) {
        guard !working else { return }
        working = true
        Task {
            defer { working = false }
            guard let activeID = await save(endpoint) else { return }
            let current = team.settings.endpoints.first { $0.id == activeID } ?? endpoint
            note = L.t("loading.fetchingModels")
            do {
                let count = try await team.refreshModels(current.id)
                let fresh = team.settings.endpoints.first { $0.id == current.id }
                let active = Set(fresh?.models ?? [])
                let waiting = (fresh?.listed ?? []).filter { !active.contains($0) }.count
                note = waiting > 0
                    ? L.format("servicePage.modelsFetchedMore", count, waiting)
                    : L.format("servicePage.modelsFetchedSummary", count)
            } catch {
                note = Explain.model(error, service: current.name).displayTitle
            }
        }
    }

    private func probe(_ endpoint: Endpoint) {
        guard !working else { return }
        working = true
        Task {
            defer { working = false }
            guard let activeID = await save(endpoint) else { return }
            let current = team.settings.endpoints.first { $0.id == activeID } ?? endpoint
            guard let model = (team.resolveActive(team.settings.defaultModel).flatMap { $0.endpoint.id == current.id ? $0.model : nil }) ?? current.models.first else {
                note = L.t("servicePage.noActiveModelsForProbe")
                return
            }
            note = L.format("servicePage.probingModel", model)
            let result = await team.probe(current, model: model)
            note = result.note
            if result.ok { Haptics.thud() } else { Haptics.lock() }
        }
    }
}

private struct ServiceActiveModelsSection: View {
    let endpoint: Endpoint
    let defaultModelRef: String?
    let onEdit: (String) -> Void
    let onManage: () -> Void
    let onRemove: (String) -> Void

    var body: some View {
        let activeSet = Set(endpoint.models)
        let restCount = (endpoint.listed ?? []).filter { !activeSet.contains($0) }.count
        let manageLine = restCount > 0
            ? L.format("settings.manageModelsMoreLine", restCount)
            : L.t("settings.manageModelsLine")
        let service = Service.of(endpoint)
        let listedSet = endpoint.listed.map(Set.init)
        return VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle(L.t("settings.activeModels"))
            LazyVStack(spacing: 0) {
                ForEach(endpoint.models, id: \.self) { model in
                    VStack(spacing: 0) {
                        modelRow(endpoint, service: service, listedSet: listedSet, model)
                        Kit.rule(inset: Ink.Space.l)
                    }
                }
                Button {
                    Haptics.light()
                    onManage()
                } label: {
                    RowLabel("plus", tint: Ink.Tile.dai, title: L.t("settings.manageModels"), line: manageLine)
                }
                .buttonStyle(TapStyle())
            }
            .paperCard()
            Text(L.t("servicePage.activeModelsNote"))
                .font(.system(size: Ink.Size.small))
                .foregroundStyle(Ink.inkSoft)
                .padding(.horizontal, Ink.Space.l)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func modelRow(_ endpoint: Endpoint, service: Service?, listedSet: Set<String>?, _ model: String) -> some View {
        let traits = endpoint.traits(model)
        let isDefault = defaultModelRef == "\(endpoint.id)/\(model)"
        let gone = listedSet.map { !$0.contains(model) } ?? false
        let custom = endpoint.customName(for: model)
        let title = endpoint.distinguishableDisplayName(for: model)
        let titleFont: Font = Ink.mono(Ink.Size.sub, weight: .semibold)
        return Button {
            Haptics.light()
            onEdit(model)
        } label: {
            HStack(alignment: .center, spacing: Ink.Space.m) {
                ModelIcon(model: model, service: service, size: Kit.badge, name: endpoint.name)
                VStack(alignment: .leading, spacing: Ink.Space.xs) {
                    HStack(spacing: Ink.Space.s) {
                        Text(title).font(titleFont).foregroundStyle(Ink.ink).lineLimit(1)
                        if isDefault {
                            Text(L.t("settings.defaultModelBadge"))
                                .font(.system(size: Ink.Size.micro, weight: .semibold))
                                .foregroundStyle(Ink.accent)
                                .padding(.horizontal, Ink.Space.s)
                                .padding(.vertical, Ink.Space.xs / 4)
                                .background(Ink.accentWash, in: .capsule)
                        }
                    }
                    if custom != nil {
                        Text(model)
                            .font(Ink.mono(Ink.Size.micro))
                            .foregroundStyle(Ink.inkFaint)
                            .lineLimit(1)
                    }
                    TraitChips(traits: traits, corrected: endpoint.corrected(model), positiveOnly: true)
                    if gone {
                        Text(L.t("settings.modelUnavailable")).font(Ink.footnote).foregroundStyle(Ink.warn)
                    }
                }
                Spacer(minLength: 0)
                Kit.chevron
            }
            .padding(.horizontal, Ink.Space.l)
            .padding(.vertical, Ink.Space.m)
            .contentShape(Rectangle())
        }
        .buttonStyle(TapStyle())
        .contextMenu {
            Button(L.t("actions.removeModel"), systemImage: "minus.circle", role: .destructive) {
                onRemove(model)
            }
        }
    }
}

/// Unified drawer for enabling/disabling models from a service's catalog and typing custom model IDs.
private struct ManageModelsSheet: View {
    @ObservedObject var team: TeamModel
    let id: String
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var refreshing = false
    @State private var note: String?

    private var endpoint: Endpoint? { team.settings.endpoints.first { $0.id == id } }
    private var service: Service? { endpoint.flatMap(Service.of) }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let endpoint {
                    VStack(alignment: .leading, spacing: Ink.Space.xl) {
                        ManualModelEntryCard(hint: service?.modelHint ?? L.t("servicePage.manualModelHint")) { model in
                            addTyped(endpoint, model: model)
                        }
                        if let note {
                            Text(note)
                                .font(Ink.footnote)
                                .foregroundStyle(Ink.inkSoft)
                                .padding(.horizontal, Ink.Space.l)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        catalogCard(endpoint)
                    }
                    .padding(.horizontal, Ink.Space.page)
                    .padding(.vertical, Ink.Space.l)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollEdgeEffectStyle(.soft, for: .vertical)
            .background(Ink.paper.ignoresSafeArea())
            .navigationTitle(L.t("settings.manageModels"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: L.t("servicePage.searchPrompt"))
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if let endpoint {
                        Button {
                            Haptics.light()
                            refresh(endpoint)
                        } label: {
                            if refreshing {
                                ProgressView()
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .disabled(refreshing)
                        .accessibilityLabel(L.t("settings.refreshImageModels"))
                    }
                    Button(L.t("actions.done")) {
                        Haptics.light()
                        dismiss()
                    }
                }
            }
        }
    }

    private func catalogCard(_ endpoint: Endpoint) -> some View {
        let all = endpoint.allModels
        let words = search.trimmingCharacters(in: .whitespaces).lowercased()
        let found = words.isEmpty ? all : all.filter { model in
            model.lowercased().contains(words)
                || (endpoint.customName(for: model)?.lowercased().contains(words) ?? false)
                || endpoint.displayName(for: model).lowercased().contains(words)
        }
        let shown = Array(found.prefix(100))
        let firstModel = shown.first
        let activeSet = Set(endpoint.models)
        return VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle(all.isEmpty ? L.t("settings.imageModelAvailable") : L.format("servicePage.catalogSummary", all.count, endpoint.models.count))
            LazyVStack(spacing: 0) {
                if all.isEmpty {
                    VStack(alignment: .leading, spacing: Ink.Space.s) {
                        Text(L.t("servicePage.catalogEmpty"))
                            .font(Ink.secondary)
                            .foregroundStyle(Ink.inkSoft)
                        Button("刷新模型列表") { refresh(endpoint) }
                            .font(.system(size: Ink.Size.sub, weight: .semibold))
                            .foregroundStyle(Ink.accent)
                            .disabled(refreshing)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Ink.Space.l)
                } else if found.isEmpty {
                    Text(L.format("servicePage.catalogNoMatch", search))
                        .font(Ink.footnote)
                        .foregroundStyle(Ink.inkFaint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Ink.Space.l)
                } else {
                    ForEach(shown, id: \.self) { model in
                        VStack(spacing: 0) {
                            if model != firstModel { Kit.rule(inset: Ink.Space.l) }
                            catalogRow(endpoint, model, enabled: activeSet.contains(model))
                        }
                    }
                    if found.count > shown.count {
                        Kit.rule(inset: Ink.Space.l)
                        Text(L.format("servicePage.catalogMore", found.count - shown.count))
                            .font(Ink.footnote)
                            .foregroundStyle(Ink.inkFaint)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Ink.Space.l)
                    }
                }
            }
            .paperCard()
        }
    }

    private func catalogRow(_ endpoint: Endpoint, _ model: String, enabled: Bool) -> some View {
        let custom = endpoint.customName(for: model)
        let titleFont: Font = Ink.mono(Ink.Size.sub, weight: enabled ? .medium : .regular)
        return Button {
            Haptics.tick(0.5)
            withAnimation(.smooth) {
                if enabled {
                    team.setModels(endpoint.id, endpoint.models.filter { $0 != model })
                } else {
                    team.setModels(endpoint.id, endpoint.models + [model])
                }
            }
        } label: {
            HStack(spacing: Ink.Space.m) {
                Image(systemName: enabled ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: Ink.Size.title))
                    .foregroundStyle(enabled ? Ink.accent : Ink.inkFaint)
                VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
                    Text(custom ?? model)
                        .font(titleFont)
                        .foregroundStyle(Ink.ink)
                        .lineLimit(1)
                    if custom != nil {
                        Text(model)
                            .font(Ink.mono(Ink.Size.micro))
                            .foregroundStyle(Ink.inkFaint)
                            .lineLimit(1)
                    }
                    Text(endpoint.traits(model).summary)
                        .font(.system(size: Ink.Size.small))
                        .foregroundStyle(Ink.inkSoft)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Ink.Space.l)
            .padding(.vertical, Ink.Space.m)
            .contentShape(Rectangle())
        }
        .buttonStyle(TapStyle())
        .accessibilityAddTraits(enabled ? .isSelected : [])
    }

    private func addTyped(_ endpoint: Endpoint, model: String) {
        guard !endpoint.models.contains(model) else {
            let message = L.format("servicePage.modelAlreadyActive", model)
            note = message
            ToastCenter.shared.show(message, symbol: "checkmark.circle", tint: Ink.inkSoft)
            return
        }
        Haptics.tick(0.6)
        withAnimation(.smooth) { team.setModels(endpoint.id, endpoint.models + [model]) }
        let message = L.format("servicePage.modelAddedNotice", model)
        note = message
        ToastCenter.shared.show(message, symbol: "checkmark.circle.fill", tint: Ink.ok)
    }

    private func refresh(_ endpoint: Endpoint) {
        refreshing = true
        note = L.t("loading.fetchingModels")
        Task {
            do {
                let count = try await team.refreshModels(endpoint.id)
                let message = L.format("servicePage.catalogRefreshedNotice", count)
                note = message
                ToastCenter.shared.show(message, symbol: "checkmark.circle.fill", tint: Ink.ok)
            } catch {
                note = Explain.model(error, service: endpoint.name).displayTitle
            }
            refreshing = false
        }
    }
}

/// Isolated manual model-ID text input so typing does not re-evaluate the 100-item catalog list.
private struct ManualModelEntryCard: View {
    let hint: String
    let onAdd: (String) -> Void
    @State private var typed = ""

    private var clean: String {
        typed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle(L.t("settings.imageModelManual"))
            HStack(spacing: Ink.Space.s) {
                TextField(hint, text: $typed)
                    .font(Ink.mono(Ink.Size.sub))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit { submit() }
                Button(L.t("actions.add")) { submit() }
                    .font(.system(size: Ink.Size.sub, weight: .semibold))
                    .foregroundStyle(clean.isEmpty ? Ink.inkFaint : Ink.accent)
                    .disabled(clean.isEmpty)
            }
            .padding(.horizontal, Ink.Space.l)
            .frame(minHeight: Kit.rowHeight)
            .paperCard()
        }
    }

    private func submit() {
        let model = clean
        guard !model.isEmpty else { return }
        typed = ""
        onAdd(model)
    }
}

extension Endpoint {
    /// The style it would have without a choice of its own.
    var thinkingStyleGuess: ThinkingStyle {
        var plain = self
        plain.style = nil
        return plain.thinkingStyle
    }
}

/// 看图 · 思考 · 1M as small tags.
struct TraitChips: View {
    let traits: ModelTraits
    var corrected = false
    var positiveOnly = false

    var body: some View {
        HStack(spacing: Ink.Space.xs) {
            if traits.sees || !positiveOnly {
                tag(traits.sees ? L.t("settings.modelVision") : L.t("servicePage.noVisionTag"), traits.sees ? "eye" : "eye.slash", on: traits.sees)
            }
            if traits.thinks { tag(L.t("settings.modelReasoning"), "brain", on: true) }
            if positiveOnly && traits.tools { tag(L.t("services.supportsTools"), "wrench", on: true) }
            if !positiveOnly && !traits.tools { tag(L.t("servicePage.noToolsTag"), "wrench.and.screwdriver", on: false) }
            tag(Tokens.short(traits.window).replacingOccurrences(of: ".05M", with: "M").replacingOccurrences(of: ".00M", with: "M"), "text.alignleft", on: true)
            if corrected { Text(L.t("servicePage.modifiedTag")).font(.system(size: Ink.Size.micro, weight: .medium)).foregroundStyle(Ink.inkFaint) }
        }
    }

    private func tag(_ text: String, _ icon: String, on: Bool) -> some View {
        Label(text, systemImage: icon)
            .labelStyle(.titleAndIcon)
            .font(.system(size: Ink.Size.micro, weight: .medium))
            .foregroundStyle(on ? Ink.inkSoft : Ink.inkFaint)
            .padding(.horizontal, Ink.Space.s)
            .frame(height: 20 * UIScale.factor)
            .background(on ? Ink.mine : Color.clear, in: .capsule)
            .overlay(Capsule().strokeBorder(on ? Color.clear : Ink.rule, lineWidth: 1))
    }
}

/// One model: what it can do (from catalog/API/probe or set by hand), probe verification, and removing from active list.
struct ModelSheet: View {
    @ObservedObject var team: TeamModel
    let endpointId: String
    let model: String
    @Environment(\.dismiss) private var dismiss
    @State private var traits = ModelTraits(sees: false)
    @State private var customName = ""
    @State private var hasLoaded = false
    @State private var removingModel = false
    @State private var note: String?
    @State private var working = false
    @State private var hasLegacyConflict = false

    private static let windows = [32_768, 65_536, 131_072, 200_000, 262_144, 400_000, 1_048_576, 2_097_152]

    private var endpoint: Endpoint? { team.settings.endpoints.first { $0.id == endpointId } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Ink.Space.xl) {
                    if hasLegacyConflict {
                        legacyConflictCard
                    }
                    nameCard
                    capabilitiesCard
                    probeCard
                    actionsCard
                }
                .padding(.horizontal, Ink.Space.page)
                .padding(.vertical, Ink.Space.l)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollEdgeEffectStyle(.soft, for: .vertical)
            .background(Ink.paper.ignoresSafeArea())
            .navigationTitle(model)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L.t("actions.done")) {
                        Haptics.light()
                        commitCustomName()
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            if let resolution = endpoint?.traitsResolution(model) {
                traits = resolution.traits
                hasLegacyConflict = resolution.hasLegacyConflict
            } else {
                traits = ModelTraits.known(model)
                hasLegacyConflict = false
            }
            customName = endpoint?.customName(for: model) ?? ""
            hasLoaded = true
        }
        .task(id: customName) {
            guard hasLoaded else { return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            commitCustomName()
        }
        .onDisappear {
            commitCustomName()
        }
    }

    private func persistTraitsChange(_ next: ModelTraits, markThinksManual: Bool = false) {
        var updated = next
        if markThinksManual {
            updated.thinksSource = .userManual
            hasLegacyConflict = false
        }
        traits = updated
        let baseline = endpoint?.traits(model, ignoringCorrection: true) ?? ModelTraits.known(model)
        let isBaseline = updated.hasSameCapabilities(as: baseline) && updated.thinksSource != .userManual
        team.setTraits(endpointId, model: model, isBaseline ? nil : updated)
    }

    private var legacyConflictCard: some View {
        VStack(alignment: .leading, spacing: Ink.Space.m) {
            Text("旧版本留下的思考能力记录与权威目录不一致。当前运行已优先遵循目录；请确认要跟随目录还是手动覆写。")
                .font(Ink.secondary)
                .foregroundStyle(Ink.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Ink.Space.s) {
                Button("跟随目录（推荐）") {
                    Haptics.tick(0.5)
                    team.setManualThinkingRule(nil, for: model, in: endpointId)
                    team.setTraits(endpointId, model: model, nil)
                    if let resolution = endpoint?.traitsResolution(model) {
                        traits = resolution.baseline
                    }
                    hasLegacyConflict = false
                }
                .font(.system(size: Ink.Size.small, weight: .semibold))
                .foregroundStyle(Ink.paper)
                .padding(.horizontal, Ink.Space.m)
                .frame(height: 30 * UIScale.factor)
                .background(Ink.accent, in: .capsule)

                Button("保持手动关闭") {
                    Haptics.tick(0.5)
                    team.setManualThinkingRule(nil, for: model, in: endpointId)
                    var manual = endpoint?.overrides?[model] ?? traits
                    manual.thinks = false
                    manual.thinksSource = .userManual
                    manual.levels = nil
                    manual.levelsSource = .userManual
                    traits = manual
                    hasLegacyConflict = false
                    team.setTraits(endpointId, model: model, manual)
                }
                .font(.system(size: Ink.Size.small, weight: .medium))
                .foregroundStyle(Ink.inkSoft)
                .padding(.horizontal, Ink.Space.m)
                .frame(height: 30 * UIScale.factor)
                .background(Ink.mine, in: .capsule)
            }
        }
        .padding(Ink.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.accentWash.opacity(0.6), in: .rect(cornerRadius: Ink.Radius.card, style: .continuous))
    }

    private var nameCard: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle(L.t("servicePage.customModelName"))
            HStack(spacing: Ink.Space.s) {
                TextField(customNamePlaceholder, text: $customName)
                    .font(.system(size: Ink.Size.body))
                    .foregroundStyle(Ink.ink)
                    .submitLabel(.done)
                    .onSubmit { commitCustomName() }
                if !customName.isEmpty {
                    Button {
                        Haptics.tick(0.4)
                        customName = ""
                        commitCustomName()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: Ink.Size.sub))
                            .foregroundStyle(Ink.inkFaint)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L.t("actions.clear"))
                }
            }
            .padding(.horizontal, Ink.Space.l)
            .frame(minHeight: Kit.rowHeight)
            .paperCard()
            Text(L.t("servicePage.customModelNameNote"))
                .font(.system(size: Ink.Size.small))
                .foregroundStyle(Ink.inkSoft)
                .padding(.horizontal, Ink.Space.l)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var customNamePlaceholder: String {
        "\(Endpoint.shortName(model)) · \(L.t("servicePage.customModelNamePlaceholder"))"
    }

    private func commitCustomName() {
        guard hasLoaded, !removingModel else { return }
        team.setModelName(customName, for: model, in: endpointId)
    }

    private var capabilitiesCard: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle(L.t("settings.modelCapabilities"))
            VStack(spacing: 0) {
                toggleRow(L.t("settings.modelVision"), isOn: Binding(
                    get: { traits.sees },
                    set: { next in
                        var updated = traits
                        updated.sees = next
                        persistTraitsChange(updated)
                    }
                ))
                Kit.rule(inset: Ink.Space.l)
                toggleRow(L.t("settings.modelTools"), isOn: Binding(
                    get: { traits.tools },
                    set: { next in
                        var updated = traits
                        updated.tools = next
                        persistTraitsChange(updated)
                    }
                ))
                Kit.rule(inset: Ink.Space.l)
                toggleRow(L.t("settings.modelReasoning"), isOn: Binding(
                    get: { traits.thinks },
                    set: { next in
                        var updated = traits
                        updated.thinks = next
                        if !next {
                            team.setManualThinkingRule(nil, for: model, in: endpointId)
                            updated.levels = nil
                            updated.levelsSource = .userManual
                        } else if updated.levels?.isEmpty == true {
                            updated.levels = nil
                            updated.levelsSource = .catalog
                        }
                        persistTraitsChange(updated, markThinksManual: true)
                    }
                ))
                Kit.rule(inset: Ink.Space.l)
                StopRow(
                    title: L.t("settings.modelContextLabel"),
                    value: Binding(
                        get: { traits.window },
                        set: { next in
                            var updated = traits
                            updated.window = next
                            persistTraitsChange(updated)
                        }
                    ),
                    stops: windowChoices.map { Stop(value: $0, name: Tokens.short($0) + " token") }
                )
                .padding(.horizontal, Ink.Space.l)
                .frame(minHeight: Kit.rowHeight)
                if traits.thinks || traits.levels != nil || hasManualThinkingRule {
                    Kit.rule(inset: Ink.Space.l)
                    thinkingLevelsRow
                }
            }
            .paperCard()
            Text(footer)
                .font(.system(size: Ink.Size.small))
                .foregroundStyle(Ink.inkSoft)
                .padding(.horizontal, Ink.Space.l)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .font(.system(size: Ink.Size.body))
            .foregroundStyle(Ink.ink)
            .tint(Ink.accent)
            .padding(.horizontal, Ink.Space.l)
            .frame(minHeight: Kit.rowHeight)
    }

    private var hasManualThinkingRule: Bool {
        endpoint?.validatedManualThinkingRule(for: model) != nil
    }

    private var currentThinkingContract: ThinkingRuleResolver.ConfirmedContract? {
        endpoint.map { team.thinkingContract(for: $0, model: model) }
    }

    private var editableThinkingOptions: [ThinkingSelection] {
        guard let endpoint else { return [] }
        if endpoint.kind.supportsThinkingStyleSelection && endpoint.thinkingStyle == .none {
            return []
        }
        var options: [ThinkingSelection] = []
        if endpoint.kind == .anthropic || endpoint.thinkingStyle.canStop {
            options.append(.explicitOff)
        }
        var effortSet: Set<String> = []
        if endpoint.kind == .anthropic {
            effortSet.formUnion(["low", "medium", "high", "max"])
        } else {
            let styleEfforts = endpoint.thinkingStyle
                .levels(thinks: true)
                .filter { $0 != .auto && $0 != .off }
                .compactMap { ThinkingSelection.fromLegacy($0).effortName }
            effortSet.formUnion(styleEfforts)
        }
        if let offered = currentThinkingContract?.offeredSelections {
            for selection in offered {
                if let name = selection.effortName {
                    effortSet.insert(name)
                }
            }
        }
        let sorted = effortSet.sorted { lhs, rhs in
            let li = ThinkingSelection.effortOrder.firstIndex(of: lhs) ?? Int.max
            let ri = ThinkingSelection.effortOrder.firstIndex(of: rhs) ?? Int.max
            if li != ri { return li < ri }
            return lhs < rhs
        }
        options += sorted.map { .effort($0) }
        return options
    }

    private var thinkingLevelsRow: some View {
        let isCustomized = hasManualThinkingRule || traits.levels != nil
        let activeOffered = currentThinkingContract?.offeredSelections ?? [.inheritDefault]
        let editable = editableThinkingOptions
        return VStack(alignment: .leading, spacing: Ink.Space.s) {
            HStack(alignment: .center, spacing: Ink.Space.m) {
                VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
                    HStack(spacing: Ink.Space.s) {
                        Text(L.t("settings.thinkingLevels"))
                            .font(.system(size: Ink.Size.body))
                            .foregroundStyle(Ink.ink)
                        Text(isCustomized ? L.t("settings.thinkingLevelsTested") : L.t("settings.thinkingLevelsDefault"))
                            .font(.system(size: Ink.Size.micro, weight: .medium))
                            .foregroundStyle(isCustomized ? Ink.accent : Ink.inkFaint)
                            .padding(.horizontal, Ink.Space.s)
                            .padding(.vertical, Ink.Space.xs / 4)
                            .background(isCustomized ? Ink.accentWash : Ink.mine, in: .capsule)
                    }
                    Text(displayedThinkingLevels)
                        .font(.system(size: Ink.Size.small))
                        .foregroundStyle(Ink.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Ink.Space.s)
                if isCustomized {
                    Button(L.t("settings.clearTestedLevels")) {
                        Haptics.tick(0.5)
                        team.setManualThinkingRule(nil, for: model, in: endpointId)
                        var updated = traits
                        updated.levels = nil
                        updated.levelsSource = .catalog
                        persistTraitsChange(updated)
                    }
                    .font(.system(size: Ink.Size.small, weight: .semibold))
                    .foregroundStyle(Ink.accent)
                }
            }
            if endpoint?.kind.supportsThinkingStyleSelection == true && endpoint?.thinkingStyle == .none {
                Text("当前服务的思考参数格式为「不设置」，请先在服务页选择对应思考格式后再配置档位。")
                    .font(.system(size: Ink.Size.micro))
                    .foregroundStyle(Ink.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            } else if endpoint?.contractKey(for: model) != nil, !editable.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: Ink.Space.s) {
                        ForEach(editable, id: \.stableID) { option in
                            let selected = activeOffered.contains(option)
                            Button {
                                Haptics.tick(0.4)
                                toggleEditableThinkingOption(option)
                            } label: {
                                HStack(spacing: Ink.Space.xs) {
                                    Image(systemName: selected ? "checkmark" : "plus")
                                        .font(.system(size: Ink.Size.micro, weight: .semibold))
                                    Text(option.title)
                                        .font(.system(size: Ink.Size.small, weight: selected ? .semibold : .regular))
                                }
                                .foregroundStyle(selected ? Ink.accent : Ink.inkSoft)
                                .padding(.horizontal, Ink.Space.m)
                                .frame(height: 30 * UIScale.factor)
                                .background(selected ? Ink.accentWash : Ink.mine, in: Capsule(style: .continuous))
                                .overlay {
                                    Capsule(style: .continuous)
                                        .strokeBorder(selected ? Ink.accent.opacity(0.35) : Ink.rule, lineWidth: 0.5)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(selected ? .isSelected : [])
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(.horizontal, Ink.Space.l)
        .padding(.vertical, Ink.Space.m)
    }

    private func toggleEditableThinkingOption(_ option: ThinkingSelection) {
        guard let endpoint, let key = endpoint.contractKey(for: model) else { return }
        guard !(endpoint.kind.supportsThinkingStyleSelection && endpoint.thinkingStyle == .none) else { return }
        let allowDisable = endpoint.kind == .anthropic || endpoint.thinkingStyle.canStop
        let current = team.thinkingContract(for: endpoint, model: model)
        var canDisable = allowDisable && current.canExplicitlyDisable && current.offeredSelections.contains(.explicitOff)
        var efforts = current.offeredSelections.compactMap(\.effortName)
        switch option {
        case .explicitOff:
            guard allowDisable else { return }
            canDisable.toggle()
        case .effort(let name, _):
            let normalized = name.lowercased()
            if let idx = efforts.firstIndex(of: normalized) {
                efforts.remove(at: idx)
            } else {
                efforts.append(normalized)
            }
        default:
            return
        }
        let sortedEfforts = efforts.sorted { lhs, rhs in
            let li = ThinkingSelection.effortOrder.firstIndex(of: lhs) ?? Int.max
            let ri = ThinkingSelection.effortOrder.firstIndex(of: rhs) ?? Int.max
            if li != ri { return li < ri }
            return lhs < rhs
        }
        let wireStyle: ThinkingStyle? = endpoint.kind.supportsThinkingStyleSelection ? endpoint.thinkingStyle : nil
        let rule = ManualThinkingRule(
            contract: key,
            canDisable: canDisable,
            supportedEfforts: sortedEfforts,
            wireStyle: wireStyle
        )
        team.setManualThinkingRule(rule, for: model, in: endpointId)
        var updated = traits
        updated.thinks = canDisable || !sortedEfforts.isEmpty
        updated.levels = nil
        updated.levelsSource = .catalog
        persistTraitsChange(updated, markThinksManual: true)
    }

    private var displayedThinkingLevels: String {
        guard let endpoint else { return L.t("settings.thinkingLevelsOnlyAuto") }
        let offered = team.thinkingContract(for: endpoint, model: model).offeredSelections
        guard offered.count > 1 else { return L.t("settings.thinkingLevelsOnlyAuto") }
        return offered.map(\.title).joined(separator: " · ")
    }

    private var probeCard: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle(L.t("settings.modelProbeSection"))
            VStack(spacing: 0) {
                actionRow(working ? L.t("loading.testingModel") : L.t("actions.testModelAll"),
                          symbol: "checklist", tint: Ink.accent, disabled: working) {
                    testAll()
                }
                Kit.rule(inset: Ink.Space.l)
                actionRow(working ? L.t("loading.testingModel") : L.t("actions.testModelOnly"),
                          symbol: "bolt.horizontal", tint: Ink.ink, disabled: working) {
                    testReply()
                }
                if let note {
                    Kit.rule(inset: Ink.Space.l)
                    Text(note)
                        .font(Ink.footnote)
                        .foregroundStyle(Ink.inkSoft)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Ink.Space.l)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .paperCard()
            Text(L.t("settings.modelProbeNote"))
                .font(.system(size: Ink.Size.small))
                .foregroundStyle(Ink.inkSoft)
                .padding(.horizontal, Ink.Space.l)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actionsCard: some View {
        VStack(spacing: 0) {
            if endpoint?.corrected(model) == true || hasManualThinkingRule {
                actionRow(L.t("actions.resetModelCapabilities"), symbol: "arrow.uturn.backward", tint: Ink.ink, disabled: false) {
                    Haptics.tick(0.5)
                    team.setManualThinkingRule(nil, for: model, in: endpointId)
                    team.setTraits(endpointId, model: model, nil)
                    traits = endpoint.map { $0.traits(model, ignoringCorrection: true) } ?? ModelTraits.known(model)
                    hasLegacyConflict = false
                }
                Kit.rule(inset: Ink.Space.l)
            }
            actionRow(L.t("actions.removeModel"), symbol: "minus.circle", tint: Ink.stop, disabled: false) {
                removingModel = true
                if let endpoint { team.setModels(endpointId, endpoint.models.filter { $0 != model }) }
                dismiss()
            }
        }
        .paperCard()
    }

    private func actionRow(_ title: String, symbol: String, tint: Color, disabled: Bool, run: @escaping () -> Void) -> some View {
        Button {
            Haptics.light()
            run()
        } label: {
            HStack(spacing: Ink.Space.m) {
                Image(systemName: symbol)
                    .font(.system(size: Ink.Size.body, weight: .medium))
                    .foregroundStyle(disabled ? Ink.inkFaint : tint)
                    .frame(width: 24 * UIScale.factor)
                Text(title)
                    .font(.system(size: Ink.Size.body))
                    .foregroundStyle(disabled ? Ink.inkFaint : tint)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Ink.Space.l)
            .frame(minHeight: Kit.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(TapStyle())
        .disabled(disabled)
    }

    private var windowChoices: [Int] {
        Self.windows.contains(traits.window) ? Self.windows : (Self.windows + [traits.window]).sorted()
    }

    private var capabilitySource: String {
        if endpoint?.corrected(model) == true { return L.t("servicePage.sourceModified") }
        let hasAPIWindow = endpoint?.windows?[model] != nil
        let hasCatalog = ModelsDev.lookup(model, providerKey: endpoint?.officialCatalogProviderKey) != nil
        if hasAPIWindow && hasCatalog { return L.t("servicePage.sourceAPIAndCatalog") }
        if hasAPIWindow { return L.t("servicePage.sourceAPIAndName") }
        if hasCatalog { return L.t("servicePage.sourceCatalog") }
        return L.t("servicePage.sourceName")
    }

    private var footer: String {
        capabilitySource + L.t("servicePage.capabilitiesFooter")
    }

    /// Every ability in one go: answers at all, sees a picture, calls a tool, and observes thinking.
    /// Vision and tool results can update switches; thinking probe is strictly observation-only and never
    /// overwrites catalog/contract `thinks` or `levels`.
    private func testAll() {
        guard let endpoint else { return }
        working = true
        note = L.t("loading.testingModel")
        Task {
            var lines: [String] = []
            let reply = await team.probe(endpoint, model: model)
            lines.append(reply.note)
            guard reply.ok else {
                note = lines.joined(separator: "\n")
                working = false
                return
            }
            let sight = await team.probeSight(endpoint, model: model)
            lines.append(sight.note)
            let tools = await team.probeTools(endpoint, model: model)
            lines.append(tools.note)
            let thinking = await team.probeThinking(endpoint, model: model)
            lines.append(thinking.note)
            var found = traits
            if let sees = sight.sees { found.sees = sees }
            if let calls = tools.calls { found.tools = calls }
            let existingContract = team.thinkingContract(for: endpoint, model: model)
            let hasExistingManualRule = endpoint.validatedManualThinkingRule(for: model) != nil
            let isUnconfirmedRelayOrModel = !existingContract.isConfirmedOfficialOrigin || !existingContract.isKnownContract
            var markThinksManual = false
            if isUnconfirmedRelayOrModel, !hasExistingManualRule, thinking.thinks == true {
                if found.effectiveThinksSource != .userManual || found.thinks {
                    found.thinks = true
                    markThinksManual = true
                }
                // Persist ONLY verified non-off efforts on unconfirmed relays; never auto-promote `canDisable: true`
                // from a single probe (user can explicitly confirm `不想` in the level chips above).
                if let probedEfforts = thinking.levels?
                    .filter({ $0 != .off && $0 != .auto })
                    .compactMap({ ThinkingSelection.fromLegacy($0).effortName }),
                   !probedEfforts.isEmpty,
                   let key = endpoint.contractKey(for: model) {
                    let wireStyle: ThinkingStyle? = endpoint.kind.supportsThinkingStyleSelection ? endpoint.thinkingStyle : nil
                    let wireStyleIsDisabled: Bool = {
                        if let wireStyle, wireStyle == ThinkingStyle.none { return true }
                        return false
                    }()
                    if !wireStyleIsDisabled {
                        let rule = ManualThinkingRule(
                            contract: key,
                            canDisable: false,
                            supportedEfforts: probedEfforts,
                            wireStyle: wireStyle
                        )
                        team.setManualThinkingRule(rule, for: model, in: endpointId)
                        lines.append("已按实测结果更新本模型思考档位（如需关闭思考请在上方手动勾选「不想」）。")
                    }
                }
            }
            if found != traits || markThinksManual {
                persistTraitsChange(found, markThinksManual: markThinksManual)
            }
            note = lines.joined(separator: "\n")
            working = false
        }
    }

    private func testReply() {
        guard let endpoint else { return }
        working = true
        note = nil
        Task {
            note = await team.probe(endpoint, model: model).note
            working = false
        }
    }
}

extension TeamModel {
    /// Collects visible text and reasoning character count from a single model stream.
    nonisolated static func collectProbeStream(
        _ stream: AsyncThrowingStream<StreamEvent, Error>
    ) async throws -> (text: String, reasoningChars: Int) {
        var text = ""
        var reasoningChars = 0
        for try await event in stream {
            switch event {
            case .text(let piece):
                text += piece
            case .reasoning(let piece):
                reasoningChars += piece.count
            default:
                break
            }
        }
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), reasoningChars)
    }

    /// Formats a connectivity probe result; rejects empty or thinking-only streams without visible text.
    nonisolated static func formatProbeOutcome(
        model: String,
        text: String,
        reasoningChars: Int,
        elapsed: TimeInterval
    ) -> (ok: Bool, note: String) {
        guard !text.isEmpty else {
            if reasoningChars > 0 {
                return (false, "不通：\(model) 只返回了思考过程（\(reasoningChars) 字），没有收到正文回复。")
            }
            return (false, "不通：\(model) 返回了空内容，未收到正文回复。")
        }
        return (true, "通了：\(model)，\(String(format: "%.1f", elapsed)) 秒，回了「\(text.prefix(8))」。")
    }

    /// Asks one model once and returns both visible text and reasoning length. Uses `preferLowLatency`
    /// intent so forced-thinking or unconfirmed relays omit questionable thinking parameters cleanly.
    func quickAskDetailed(_ endpoint: Endpoint, model: String, _ message: Message) async throws -> (text: String, reasoningChars: Int) {
        if let disabledReason = endpoint.disabledProtocolReason {
            throw TeamError(message: disabledReason)
        }
        guard let key = await readAPIKey(for: endpoint), !key.isEmpty else { throw TeamError(message: "\(endpoint.name) 还没有密钥。") }
        let provider = endpoint.provider(key: key)
        let contract = thinkingContract(for: endpoint, model: model)
        let initialThinking: Thinking = (contract.isKnownContract && contract.canExplicitlyDisable) ? .off : .auto
        func once(_ thinking: Thinking) async throws -> (text: String, reasoningChars: Int) {
            let request = ModelRequest(model: model, system: "", messages: [message], outputLimit: 400, thinking: thinking)
            return try await Self.collectProbeStream(provider.stream(request))
        }
        do {
            return try await once(initialThinking)
        } catch let failure as ProviderError where initialThinking != .auto && (failure.status == 400 || failure.status == 422) {
            return try await once(.auto)
        }
    }

    /// Asks one model once and returns its visible answer text.
    func quickAsk(_ endpoint: Endpoint, model: String, _ message: Message) async throws -> String {
        try await quickAskDetailed(endpoint, model: model, message).text
    }

    /// Does the key, address and model work: a one-word question requiring non-empty visible text.
    func probe(_ endpoint: Endpoint, model: String) async -> (ok: Bool, note: String) {
        let started = Date()
        do {
            let result = try await quickAskDetailed(endpoint, model: model, .user("回一个字：好"))
            return Self.formatProbeOutcome(
                model: model,
                text: result.text,
                reasoningChars: result.reasoningChars,
                elapsed: Date().timeIntervalSince(started)
            )
        } catch {
            let advice = Explain.model(error, service: endpoint.name)
            return (false, "不通：\(advice.displayTitle)\n\(advice.detail)")
        }
    }

    /// Offers one tool and asks for something only it can give. `calls` is nil when the test itself failed.
    func probeTools(_ endpoint: Endpoint, model: String) async -> (calls: Bool?, note: String) {
        guard let key = await readAPIKey(for: endpoint), !key.isEmpty else { return (nil, "没试工具：没有密钥。") }
        let tool = ToolSpec(name: "lucky_number", description: "返回今天的幸运数字。用户问幸运数字时必须调用它。",
                            parameters: .object(["type": .string("object"), "properties": .object([:])]))
        let request = ModelRequest(model: model, system: "", messages: [.user("今天的幸运数字是多少？请调用工具查。")],
                                   tools: [tool], outputLimit: 200, thinking: .auto)
        do {
            for try await event in endpoint.provider(key: key).stream(request) {
                if case .toolCallStart = event { return (true, "会用工具：给它一个工具，它主动调用了。") }
            }
            return (false, "好像不会用工具：给了工具，它直接回答了。已标成不会用工具。")
        } catch let failure as ProviderError where failure.status == 400 || failure.status == 422 {
            return (false, "服务不收工具：\(failure.message.prefix(80))。已标成不会用工具。")
        } catch {
            return (nil, "工具没试成：\(Explain.model(error, service: endpoint.name).displayTitle)")
        }
    }

    /// Probes thinking using the same wire-field compilation path as real chat turns.
    /// Requires non-empty visible text to count a level as accepted and never returns `.off` as auto-confirmed.
    func probeThinking(_ endpoint: Endpoint, model: String) async -> (thinks: Bool?, note: String, levels: [Thinking]?) {
        guard endpoint.isActiveProtocol, let key = await readAPIKey(for: endpoint), !key.isEmpty else {
            return (nil, "没试思考：没有密钥或协议未启用。", nil)
        }
        let provider = endpoint.provider(key: key)
        let style: ThinkingStyle? = endpoint.kind.supportsThinkingStyleSelection ? endpoint.thinkingStyle : nil
        let contractKey = endpoint.contractKey(for: model) ?? EndpointContractKey(
            origin: endpoint.baseURL,
            protocolKind: endpoint.kind.rawValue,
            route: endpoint.kind.defaultRoutePath,
            modelID: model
        )
        func thought(_ level: Thinking) async -> (chars: Int, textChars: Int, refused: Bool, failed: Bool) {
            let selection = ThinkingSelection.fromLegacy(level)
            var bodyFields: [String: ThinkingWireValue]? = nil
            if endpoint.kind.isOpenAIFamily, level != .auto {
                let probeRule = ManualThinkingRule(
                    contract: contractKey,
                    canDisable: level == .off,
                    supportedEfforts: selection.effortName.map { [$0] } ?? [],
                    wireStyle: style
                )
                let probeContract = ThinkingRuleResolver.contract(for: contractKey, style: style, manualRule: probeRule)
                let resolved = ThinkingRuleResolver.resolve(selection: selection, contract: probeContract, style: style)
                bodyFields = resolved.bodyFields
            }
            let request = ModelRequest(
                model: model,
                system: "",
                messages: [.user("17 × 23 等于多少？只回答数字。")],
                outputLimit: 2000,
                thinking: level,
                thinkingBodyFields: bodyFields
            )
            do {
                let collected = try await Self.collectProbeStream(provider.stream(request))
                if collected.text.isEmpty && collected.reasoningChars == 0 {
                    return (0, 0, false, true)
                }
                return (collected.reasoningChars, collected.text.count, false, false)
            } catch let failure as ProviderError where failure.status == 400 || failure.status == 422 {
                return (0, 0, true, false)
            } catch {
                return (0, 0, false, true)
            }
        }
        let styleCandidates: [Thinking] = endpoint.kind.supportsThinkingStyleSelection
            ? endpoint.thinkingStyle.levels(thinks: true).filter { $0 != .auto }
            : [.off, .low, .medium, .high, .max]
        if styleCandidates.isEmpty {
            let autoRun = await thought(.auto)
            if autoRun.failed { return (nil, "思考观察未完成：连不上或返回空内容。", nil) }
            if autoRun.chars > 0 { return (true, "观察到思考输出（仅作参考，未改写目录规则）。", nil) }
            return (false, "未观察到思考输出（仅作参考，未改写目录规则）。", nil)
        }
        let tried = styleCandidates
        var results: [Thinking: (chars: Int, textChars: Int, refused: Bool, failed: Bool)] = [:]
        for level in tried { results[level] = await thought(level) }
        if results.values.allSatisfy({ $0.failed }) { return (nil, "思考观察未完成：连不上或返回空内容。", nil) }
        let taken = tried.filter {
            guard let r = results[$0] else { return false }
            return !r.refused && !r.failed && r.textChars > 0
        }
        let refused = tried.filter { results[$0]?.refused == true }
        let anyThought = tried.contains {
            guard let r = results[$0] else { return false }
            return !r.refused && !r.failed && r.chars > 0
        }
        let deep = taken.filter { $0 != .off }.map { results[$0]?.chars ?? 0 }.max() ?? 0
        let off = results[.off].map { ($0.refused || $0.failed || $0.textChars == 0) ? -1 : $0.chars } ?? -1
        var words: [String] = []
        if !anyThought {
            words.append(refused.count == tried.count ? "本次观察未接受思考参数" : "本次观察未返回思考文本")
            words.append("（目录与手动规则保持不变）。")
            return (false, words.joined(), nil)
        }
        let observedEfforts = taken.filter { $0 != .off }
        if !taken.isEmpty {
            words.append("本次接口接受并正常回复：" + taken.map(\.title).joined(separator: "、") + "。")
        }
        if !refused.isEmpty { words.append("拒绝：" + refused.map(\.title).joined(separator: "、") + "。") }
        if off == 0 { words.append("「不想」正常回复且返回 0 字思考。") }
        else if off > 0 && deep > off * 2 { words.append("「不想」仍有少量思考（\(off) 字，深档 \(deep) 字）。") }
        else if off > 0 { words.append("各档思考字数接近（约 \(deep) 字）。") }
        return (true, "观察到思考。" + words.joined(), observedEfforts.isEmpty ? nil : observedEfforts)
    }

    /// Shows the model a red square and asks its colour. `sees` is nil when the test itself failed.
    func probeSight(_ endpoint: Endpoint, model: String) async -> (sees: Bool?, note: String) {
        let size = CGSize(width: 64, height: 64)
        let data = UIGraphicsImageRenderer(size: size).jpegData(withCompressionQuality: 0.9) { context in
            Ink.Artwork.badgeRed.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        do {
            let answer = try await quickAsk(endpoint, model: model, .user("这张图是什么颜色？只回答颜色。", images: [ImagePart(data: data)]))
            let said = answer.lowercased()
            if said.contains("红") || said.contains("red") {
                return (true, "能看图：给它一张红色的图，它答「\(answer.prefix(12))」。已标成能看图。")
            }
            return (false, "好像看不到：它答「\(answer.prefix(30))」。已标成不能看图，发来的照片会换成编号。")
        } catch let failure as ProviderError where failure.status == 400 || failure.status == 422 {
            return (false, "服务不收图片：\(failure.message.prefix(80))。已标成不能看图。")
        } catch {
            return (nil, "没试成：\(Explain.model(error, service: endpoint.name).displayTitle)")
        }
    }
}

/// The models in use, by service, for a menu: each with what it can do under its name.
struct ModelChoices: View {
    @ObservedObject var team: TeamModel
    let current: String?
    let pick: (String) -> Void

    static func selectableEndpoints(in endpoints: [Endpoint], defaults: UserDefaults = .standard) -> [Endpoint] {
        endpoints.filter { $0.isActiveProtocol && !ServiceExtras.isPaused($0.id, defaults: defaults) && !$0.models.isEmpty }
    }

    var body: some View {
        let recent = RecentModelsStore.recent(in: team)
        if !recent.isEmpty {
            Section(L.t("services.recentModels")) {
                ForEach(recent, id: \.self) { ref in
                    if let resolved = team.resolveActive(ref) {
                        modelButton(resolved.endpoint, model: resolved.model)
                    }
                }
            }
        }
        ForEach(Self.selectableEndpoints(in: team.settings.endpoints)) { endpoint in
            Section(endpoint.name) {
                ForEach(endpoint.models, id: \.self) { model in
                    modelButton(endpoint, model: model)
                }
            }
        }
    }

    private func modelButton(_ endpoint: Endpoint, model: String) -> some View {
        let ref = "\(endpoint.id)/\(model)"
        return Button {
            RecentModelsStore.record(ref, in: team)
            pick(ref)
        } label: {
            let title = endpoint.distinguishableDisplayName(for: model)
            if current == ref {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
            Text(endpoint.traits(model).summary)
        }
    }
}

private struct ServiceHeaderEditor: View {
    let endpointID: String

    @State private var expanded = false
    @State private var headers: [String: String] = [:]
    @State private var name = ""
    @State private var value = ""
    @State private var rejected = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: Ink.Space.m) {
                Text(L.t("services.headersNote")).font(Ink.footnote).foregroundStyle(Ink.inkSoft)
                ForEach(headers.keys.sorted(), id: \.self) { field in
                    HStack {
                        Button {
                            name = field
                            value = headers[field] ?? ""
                            rejected = false
                        } label: {
                            VStack(alignment: .leading, spacing: Ink.Space.xs) {
                                Text(field).font(Ink.mono(Ink.Size.sub)).foregroundStyle(Ink.ink)
                                Text(headers[field] ?? "").font(Ink.footnote).foregroundStyle(Ink.inkSoft)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        Button(role: .destructive) {
                            headers.removeValue(forKey: field)
                            ServiceExtras.setCustomHeaders(headers, for: endpointID)
                            if name.caseInsensitiveCompare(field) == .orderedSame { clearDraft() }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .accessibilityLabel(L.format("services.removeHeader", field))
                    }
                }
                TextField(L.t("services.headerName"), text: $name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .paperField()
                TextField(L.t("services.headerValue"), text: $value)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .paperField()
                if rejected {
                    Text(L.t("services.headerRejected")).font(Ink.footnote).foregroundStyle(Ink.stop)
                }
                Button(L.t("actions.save"), action: save)
                    .buttonStyle(WideButtonStyle(filled: false))
                    .disabled(name.isEmpty)
            }
            .padding(.top, Ink.Space.m)
        } label: {
            Text(L.t("services.headers")).font(Ink.label).foregroundStyle(Ink.ink)
        }
        .tint(Ink.accent)
        .onAppear { headers = ServiceExtras.customHeaders(endpointID) }
    }

    private func save() {
        let field = name.trimmingCharacters(in: .whitespaces)
        guard ServiceExtras.permitsHeader(field, value: value) else {
            rejected = true
            return
        }
        if let old = headers.keys.first(where: { $0.caseInsensitiveCompare(field) == .orderedSame }) {
            headers.removeValue(forKey: old)
        }
        headers[field] = value
        ServiceExtras.setCustomHeaders(headers, for: endpointID)
        clearDraft()
    }

    private func clearDraft() {
        name = ""
        value = ""
        rejected = false
    }
}
