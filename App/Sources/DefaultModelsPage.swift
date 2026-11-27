import AgentKit
import Craft
import SwiftUI

/// Unified global model assignment page: default chat, fallback backup, memory/diary review, and image generation.
struct DefaultModelsPage: View {
    @ObservedObject var team: TeamModel
    var openServices: () -> Void
    @State private var picking: Role?

    enum Role: String, Identifiable {
        case chat, backup, memory, vision
        var id: String { rawValue }

        var title: String {
            switch self {
            case .chat: L.t("settings.defaultChatModel")
            case .backup: L.t("settings.backupModelTitle")
            case .memory: L.t("settings.memoryModelTitle")
            case .vision: L.t("settings.visionModelTitle")
            }
        }

        var noneTitle: String? {
            switch self {
            case .chat: nil
            case .backup: L.t("settings.noBackupModel")
            case .memory: L.t("settings.followDefault")
            case .vision: L.t("settings.visionModelOff")
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Ink.Space.xl) {
                if team.settings.endpoints.isEmpty {
                    emptyCard
                } else {
                    chatGroup
                    moreGroup
                }
            }
            .padding(.horizontal, Ink.Space.page)
            .padding(.vertical, Ink.Space.l)
        }
        .scrollEdgeEffectStyle(.soft, for: .vertical)
        .scrollDismissesKeyboard(.interactively)
        .background(Ink.paper.ignoresSafeArea())
        .navigationTitle(L.t("settingsHome.defaultAndSpecialModels"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $picking) { role in
            ModelPickerSheet(
                team: team,
                role: role,
                current: current(for: role),
                pick: { apply($0, for: role) },
                openServices: {
                    picking = nil
                    openServices()
                }
            )
            .detentPaperBackdrop(initial: .large, detents: [.medium, .large])
        }
    }

    private var emptyCard: some View {
        RowCard(note: L.t("settingsHome.noChatModels")) {
            Button {
                Haptics.light()
                openServices()
            } label: {
                RowLabel("server.rack", tint: Ink.Tile.dai, title: L.t("settings.modelService"), line: L.t("settingsHome.servicesLine"))
            }
            .buttonStyle(PressStyle(haptic: false))
        }
    }

    private var chatGroup: some View {
        RowCard(
            title: L.t("settings.defaultModelsChatGroup"),
            note: team.models.isEmpty ? L.t("settingsHome.noChatModels") : nil
        ) {
            Button {
                Haptics.light()
                picking = .chat
            } label: {
                RowLabel(
                    "sparkle",
                    tint: Ink.Tile.dai,
                    title: L.t("settings.defaultChatModel"),
                    line: L.t("settings.defaultChatModelLine"),
                    end: .valueChevron(defaultLabel)
                )
            }
            .buttonStyle(PressStyle(haptic: false))

            Button {
                Haptics.light()
                picking = .backup
            } label: {
                RowLabel(
                    "arrow.triangle.branch",
                    tint: Ink.Tile.dai,
                    title: L.t("settings.backupModelTitle"),
                    line: L.t("settings.backupModelLine"),
                    end: .valueChevron(backupLabel)
                )
            }
            .buttonStyle(PressStyle(haptic: false))
        }
    }

    private var moreGroup: some View {
        RowCard(title: L.t("settings.defaultModelsMoreGroup")) {
            Button {
                Haptics.light()
                picking = .memory
            } label: {
                RowLabel(
                    "moon.stars",
                    tint: Ink.Tile.dai,
                    title: L.t("settings.memoryModelTitle"),
                    line: L.t("settings.memoryModelLine"),
                    end: .valueChevron(memoryLabel)
                )
            }
            .buttonStyle(PressStyle(haptic: false))

            NavigationLink {
                ImageModelPage(team: team)
            } label: {
                RowLabel(
                    "photo.badge.plus",
                    tint: Ink.Tile.dai,
                    title: L.t("settings.imageModel"),
                    line: L.t("settings.imageModelLine"),
                    end: .valueChevron(imageLabel)
                )
            }
            .buttonStyle(PressStyle())

            Button {
                picking = .vision
            } label: {
                RowLabel(
                    "eye",
                    tint: Ink.Tile.dai,
                    title: L.t("settings.visionModelTitle"),
                    line: L.t("settings.visionModelLine"),
                    end: .valueChevron(visionLabel)
                )
            }
            .buttonStyle(PressStyle())

            if let endpoint = team.visionModelSelection?.endpoint, let recipient = endpoint.recipientIdentity {
                OutboundConsentRows(team: team, recipient: recipient, categories: OutboundDataCategory.imageCategories)
            }

            NavigationLink {
                OutboundConsentPage(team: team)
            } label: {
                RowLabel("lock.shield", tint: Ink.Tile.dai, title: L.t("settings.outboundTitle"),
                         line: L.t("settings.outboundLine"))
            }
            .buttonStyle(PressStyle())
        }
    }

    private var defaultLabel: String {
        guard let ref = team.settings.defaultModel, team.resolveActive(ref) != nil else { return L.t("settings.unset") }
        return team.modelShort(ref)
    }

    private var backupLabel: String {
        guard let ref = team.settings.effectiveBackupModels.first, team.resolveActive(ref) != nil else { return L.t("settings.unset") }
        return team.modelShort(ref)
    }

    private var memoryLabel: String {
        guard let ref = team.settings.memoryModel, team.resolveActive(ref) != nil else { return L.t("settings.followDefault") }
        return team.modelShort(ref)
    }

    private var imageLabel: String {
        guard team.imageModelSelection != nil else { return L.t("settings.unset") }
        return team.modelShort(team.settings.imageModel)
    }

    private var visionLabel: String {
        guard team.visionModelSelection != nil else { return L.t("settings.visionModelOff") }
        return team.modelShort(team.settings.visionModel)
    }

    private func current(for role: Role) -> String? {
        let raw: String? = switch role {
        case .chat: team.settings.defaultModel
        case .backup: team.settings.effectiveBackupModels.first
        case .memory: team.settings.memoryModel
        case .vision: team.visionModelSelection == nil ? nil : team.settings.visionModel
        }
        guard let raw, team.resolveActive(raw) != nil else { return nil }
        return raw
    }

    private func apply(_ ref: String?, for role: Role) {
        switch role {
        case .chat:
            if let ref { team.setDefaultModel(ref) }
        case .backup:
            team.setBackupModel(ref)
        case .memory:
            team.setMemoryModel(ref)
        case .vision:
            team.setVisionModel(ref)
        }
    }
}

private struct OutboundConsentRows: View {
    @ObservedObject var team: TeamModel
    let recipient: RecipientIdentity
    let categories: [OutboundDataCategory]

    var body: some View {
        VStack(alignment: .leading, spacing: Ink.Space.m) {
            Text(recipient.canonicalOrigin + recipient.route)
                .font(Ink.mono(Ink.Size.small))
                .foregroundStyle(Ink.inkSoft)
                .textSelection(.enabled)
            ForEach(categories, id: \.self) { category in
                Toggle(L.t(category.titleKey), isOn: Binding(
                    get: { team.settings.allowsOutbound(recipient, category) },
                    set: { team.setOutboundConsent($0, for: recipient, category: category) }
                ))
                .font(Ink.body(Double(Ink.Size.body), bold: false))
                .tint(Ink.accent)
            }
        }
        .padding(Ink.Space.l)
    }
}

private struct OutboundConsentPage: View {
    @ObservedObject var team: TeamModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Ink.Space.l) {
                ForEach(team.settings.endpoints) { endpoint in
                    if let recipient = endpoint.recipientIdentity {
                        RowCard(title: endpoint.name) {
                            OutboundConsentRows(team: team, recipient: recipient,
                                                categories: OutboundDataCategory.imageCategories + [.memoryCompress])
                        }
                    }
                }
            }
            .padding(.horizontal, Ink.Space.page)
            .padding(.vertical, Ink.Space.l)
        }
        .background(Ink.paper.ignoresSafeArea())
        .navigationTitle(L.t("settings.outboundTitle"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Unified picker sheet for selecting one enabled chat model across connected services.
private struct ModelPickerSheet: View {
    @ObservedObject var team: TeamModel
    let role: DefaultModelsPage.Role
    let current: String?
    let pick: (String?) -> Void
    let openServices: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filteredEndpoints: [(endpoint: Endpoint, models: [String])] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return team.settings.endpoints.compactMap { endpoint in
            let candidates = role == .vision ? endpoint.models.filter { endpoint.traits($0).sees } : endpoint.models
            let matchesProvider = search.isEmpty || endpoint.name.localizedCaseInsensitiveContains(search)
            let models = matchesProvider ? candidates : candidates.filter { model in
                model.localizedCaseInsensitiveContains(search)
                    || endpoint.displayName(for: model).localizedCaseInsensitiveContains(search)
            }
            return models.isEmpty ? nil : (endpoint, models)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Ink.Space.xl) {
                    if let noneTitle = role.noneTitle {
                        noneCard(noneTitle)
                    }
                    if filteredEndpoints.isEmpty {
                        RowCard {
                            Text(team.models.isEmpty ? L.t("settingsHome.noChatModels") : L.format("settings.modelSearchEmpty", query))
                                .font(Ink.secondary)
                                .foregroundStyle(Ink.inkSoft)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(Ink.Space.l)
                        }
                    } else {
                        ForEach(filteredEndpoints, id: \.endpoint.id) { group in
                            endpointCard(group.endpoint, models: group.models)
                        }
                    }
                    manageServicesCard
                }
                .padding(.horizontal, Ink.Space.page)
                .padding(.vertical, Ink.Space.l)
            }
            .scrollEdgeEffectStyle(.soft, for: .vertical)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(role.title)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: L.t("settings.imageModelSearch"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L.t("actions.done")) {
                        Haptics.light()
                        dismiss()
                    }
                }
            }
        }
    }

    private func noneCard(_ title: String) -> some View {
        RowCard {
            Button {
                Haptics.tick(0.6)
                pick(nil)
                dismiss()
            } label: {
                HStack(spacing: Ink.Space.m) {
                    Text(title)
                        .font(.system(size: Ink.Size.body))
                        .foregroundStyle(Ink.ink)
                    Spacer(minLength: Ink.Space.s)
                    if current == nil {
                        Image(systemName: "checkmark")
                            .font(.system(size: Ink.Size.sub, weight: .semibold))
                            .foregroundStyle(Ink.accent)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, Ink.Space.l)
                .frame(minHeight: Kit.rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(TapStyle())
            .accessibilityAddTraits(current == nil ? .isSelected : [])
        }
    }

    private func endpointCard(_ endpoint: Endpoint, models: [String]) -> some View {
        let firstModel = models.first
        let service = Service.of(endpoint)
        return VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle(endpoint.name)
            LazyVStack(spacing: 0) {
                ForEach(models, id: \.self) { model in
                    VStack(spacing: 0) {
                        if model != firstModel { Kit.rule(inset: Ink.Space.l) }
                        modelRow(endpoint, service: service, model)
                    }
                }
            }
            .paperCard()
        }
    }

    private func modelRow(_ endpoint: Endpoint, service: Service?, _ model: String) -> some View {
        let ref = "\(endpoint.id)/\(model)"
        let selected = current == ref
        return Button {
            Haptics.tick(0.6)
            pick(ref)
            dismiss()
        } label: {
            HStack(spacing: Ink.Space.m) {
                ModelIcon(model: model, service: service, size: Kit.badge, name: endpoint.name)
                VStack(alignment: .leading, spacing: Ink.Space.xs) {
                    Text(endpoint.distinguishableDisplayName(for: model))
                        .font(Ink.mono(Ink.Size.sub, weight: selected ? .semibold : .medium))
                        .foregroundStyle(Ink.ink)
                        .lineLimit(1)
                    if endpoint.customName(for: model) != nil {
                        Text(model).font(Ink.mono(Ink.Size.micro)).foregroundStyle(Ink.inkFaint).lineLimit(1)
                    }
                    TraitChips(traits: endpoint.traits(model), corrected: endpoint.corrected(model))
                }
                Spacer(minLength: Ink.Space.s)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: Ink.Size.sub, weight: .semibold))
                        .foregroundStyle(Ink.accent)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, Ink.Space.l)
            .padding(.vertical, Ink.Space.m)
            .contentShape(Rectangle())
        }
        .buttonStyle(TapStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var manageServicesCard: some View {
        RowCard {
            Button {
                Haptics.light()
                openServices()
            } label: {
                RowLabel("server.rack", tint: Ink.Tile.dai, title: L.t("settings.manageServicesShortcut"))
            }
            .buttonStyle(PressStyle(haptic: false))
        }
    }
}
