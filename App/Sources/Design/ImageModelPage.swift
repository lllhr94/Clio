import SwiftUI

/// Picks a model for the images API without changing the models offered for chat.
struct ImageModelPage: View {
    @ObservedObject var team: TeamModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var allChoices: [Choice] = []
    @State private var filteredChoices: [Choice] = []

    private struct Choice: Identifiable, Equatable {
        let id: String
        let model: String
        let service: String
        let isImage: Bool
    }

    private var endpoints: [Endpoint] { team.settings.endpoints.filter { $0.kind == .openai } }

    var body: some View {
        let openAI = endpoints
        ScrollView {
            VStack(alignment: .leading, spacing: Ink.Space.xl) {
                noneCard
                if !openAI.isEmpty {
                    ImageManualModelCard(
                        endpoints: openAI,
                        initialServiceID: team.imageModelSelection?.endpoint.id ?? "",
                        onPick: pick
                    )
                    if !filteredChoices.isEmpty {
                        availableCard
                    }
                } else {
                    RowCard {
                        Text(L.t("settings.imageModelNoService"))
                            .font(Ink.secondary)
                            .foregroundStyle(Ink.inkSoft)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Ink.Space.l)
                    }
                }
            }
            .padding(.horizontal, Ink.Space.page)
            .padding(.vertical, Ink.Space.l)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Ink.paper.ignoresSafeArea())
        .navigationTitle(L.t("settings.imageModel"))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: L.t("settings.imageModelSearch"))
        .onChange(of: openAI, initial: true) { _, next in
            rebuildChoices(from: next)
        }
        .onChange(of: query) { _, _ in
            applyFilter()
        }
    }

    private var noneCard: some View {
        RowCard(note: L.t("settings.imageModelNote")) {
            Button {
                pick(nil)
            } label: {
                option(L.t("settings.imageModelNone"), detail: nil, selected: team.imageModelSelection == nil)
            }
            .buttonStyle(TapStyle())
        }
    }

    private var availableCard: some View {
        let firstID = filteredChoices.first?.id
        let selectedRef = team.settings.imageModel
        return VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle(L.t("settings.imageModelAvailable"))
            LazyVStack(spacing: 0) {
                ForEach(filteredChoices) { choice in
                    VStack(spacing: 0) {
                        if choice.id != firstID { Kit.rule(inset: Ink.Space.l) }
                        Button {
                            pick(choice.id)
                        } label: {
                            option(choice.model, detail: choice.service, selected: choice.id == selectedRef)
                        }
                        .buttonStyle(TapStyle())
                    }
                }
            }
            .paperCard()
            Text(L.t("settings.imageModelFromServicesNote"))
                .font(.system(size: Ink.Size.small))
                .foregroundStyle(Ink.inkSoft)
                .padding(.horizontal, Ink.Space.l)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func option(_ title: String, detail: String?, selected: Bool) -> some View {
        HStack(spacing: Ink.Space.m) {
            VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
                Text(title)
                    .font(detail == nil ? .system(size: Ink.Size.body) : Ink.mono(Ink.Size.sub))
                    .foregroundStyle(Ink.ink)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.system(size: Ink.Size.small))
                        .foregroundStyle(Ink.inkSoft)
                        .lineLimit(1)
                }
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
        .padding(.vertical, detail == nil ? 0 : Ink.Space.xs)
        .frame(minHeight: Kit.rowHeight)
        .contentShape(Rectangle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func rebuildChoices(from endpoints: [Endpoint]) {
        var built: [Choice] = []
        for endpoint in endpoints {
            var seen: Set<String> = []
            for model in endpoint.allModels where seen.insert(model).inserted {
                built.append(Choice(
                    id: "\(endpoint.id)/\(model)",
                    model: model,
                    service: endpoint.name,
                    isImage: Endpoint.looksLikeImageModel(model)
                ))
            }
            for model in (endpoint.imageModels ?? []) where seen.insert(model).inserted {
                built.append(Choice(
                    id: "\(endpoint.id)/\(model)",
                    model: model,
                    service: endpoint.name,
                    isImage: Endpoint.looksLikeImageModel(model)
                ))
            }
        }
        built.sort {
            if $0.isImage != $1.isImage { return $0.isImage }
            let order = $0.model.localizedStandardCompare($1.model)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        allChoices = built
        applyFilter()
    }

    private func applyFilter() {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if search.isEmpty {
            filteredChoices = allChoices
        } else {
            filteredChoices = allChoices.filter {
                $0.model.localizedCaseInsensitiveContains(search) || $0.service.localizedCaseInsensitiveContains(search)
            }
        }
    }

    private func pick(_ ref: String?) {
        Haptics.tick(0.6)
        team.setImageModel(ref)
        dismiss()
    }
}

/// Isolated manual image-model entry card so typing does not re-evaluate the large catalog list.
private struct ImageManualModelCard: View {
    let endpoints: [Endpoint]
    let initialServiceID: String
    let onPick: (String) -> Void

    @State private var serviceID = ""
    @State private var modelName = ""

    private var endpoint: Endpoint? {
        endpoints.first { $0.id == serviceID } ?? endpoints.first
    }

    private var typed: String {
        modelName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        if let endpoint {
            VStack(alignment: .leading, spacing: Ink.Space.s) {
                SectionTitle(L.t("settings.imageModelManual"))
                VStack(spacing: 0) {
                    HStack(spacing: Ink.Space.m) {
                        Text(L.t("settings.modelService"))
                            .font(.system(size: Ink.Size.body))
                            .foregroundStyle(Ink.ink)
                        Spacer(minLength: Ink.Space.s)
                        Menu {
                            ForEach(endpoints) { item in
                                Button {
                                    serviceID = item.id
                                } label: {
                                    if item.id == endpoint.id {
                                        Label(item.name, systemImage: "checkmark")
                                    } else {
                                        Text(item.name)
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: Ink.Space.xs) {
                                Text(endpoint.name)
                                    .font(.system(size: Ink.Size.sub, weight: .medium))
                                    .foregroundStyle(Ink.accent)
                                    .lineLimit(1)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: Ink.Size.micro, weight: .semibold))
                                    .foregroundStyle(Ink.inkFaint)
                            }
                        }
                    }
                    .padding(.horizontal, Ink.Space.l)
                    .frame(minHeight: Kit.rowHeight)

                    Kit.rule(inset: Ink.Space.l)

                    HStack(spacing: Ink.Space.s) {
                        TextField(L.t("settings.imageModelPlaceholder"), text: $modelName)
                            .font(Ink.mono(Ink.Size.sub))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .onSubmit { if !typed.isEmpty { onPick("\(endpoint.id)/\(typed)") } }
                        Button(L.t("actions.save")) { onPick("\(endpoint.id)/\(typed)") }
                            .font(.system(size: Ink.Size.sub, weight: .semibold))
                            .foregroundStyle(typed.isEmpty ? Ink.inkFaint : Ink.accent)
                            .disabled(typed.isEmpty)
                    }
                    .padding(.horizontal, Ink.Space.l)
                    .frame(minHeight: Kit.rowHeight)
                }
                .paperCard()
            }
            .onAppear {
                if serviceID.isEmpty && !initialServiceID.isEmpty {
                    serviceID = initialServiceID
                }
            }
        }
    }
}
