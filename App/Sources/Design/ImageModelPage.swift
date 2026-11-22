import SwiftUI

/// Picks a model for the images API without changing the models offered for chat.
struct ImageModelPage: View {
    @ObservedObject var team: TeamModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var serviceID = ""
    @State private var modelName = ""

    private struct Choice: Identifiable {
        let id: String
        let model: String
        let service: String
    }

    private var endpoints: [Endpoint] { team.settings.endpoints.filter { $0.kind == .openai } }
    private var endpoint: Endpoint? { endpoints.first { $0.id == serviceID } ?? endpoints.first }
    private var typed: String { modelName.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var choices: [Choice] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return endpoints.flatMap { endpoint in
            Set(endpoint.allModels + (endpoint.imageModels ?? [])).map {
                Choice(id: "\(endpoint.id)/\($0)", model: $0, service: endpoint.name)
            }
        }.filter {
            search.isEmpty || $0.model.localizedCaseInsensitiveContains(search) || $0.service.localizedCaseInsensitiveContains(search)
        }.sorted {
            let first = Endpoint.looksLikeImageModel($0.model)
            let second = Endpoint.looksLikeImageModel($1.model)
            if first != second { return first }
            let order = $0.model.localizedStandardCompare($1.model)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Ink.Space.xl) {
                noneCard
                if let endpoint {
                    manualCard(endpoint)
                    if !choices.isEmpty {
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
        .onAppear {
            if let selected = team.imageModelSelection { serviceID = selected.endpoint.id }
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

    private func manualCard(_ endpoint: Endpoint) -> some View {
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
                        .onSubmit { if !typed.isEmpty { pick("\(endpoint.id)/\(typed)") } }
                    Button(L.t("actions.save")) { pick("\(endpoint.id)/\(typed)") }
                        .font(.system(size: Ink.Size.sub, weight: .semibold))
                        .foregroundStyle(typed.isEmpty ? Ink.inkFaint : Ink.accent)
                        .disabled(typed.isEmpty)
                }
                .padding(.horizontal, Ink.Space.l)
                .frame(minHeight: Kit.rowHeight)
            }
            .paperCard()
        }
    }

    private var availableCard: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle(L.t("settings.imageModelAvailable"))
            VStack(spacing: 0) {
                ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
                    if index > 0 { Kit.rule(inset: Ink.Space.l) }
                    Button {
                        pick(choice.id)
                    } label: {
                        option(choice.model, detail: choice.service, selected: choice.id == team.settings.imageModel)
                    }
                    .buttonStyle(TapStyle())
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

    private func pick(_ ref: String?) {
        Haptics.tick(0.6)
        team.setImageModel(ref)
        dismiss()
    }
}
