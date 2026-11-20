import SwiftUI

/// Picks a model for the images API without changing the models offered for chat.
struct ImageModelPage: View {
    @ObservedObject var team: TeamModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var serviceID = ""
    @State private var modelName = ""
    @State private var refreshing = false
    @State private var refreshNote: String?

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
        Form {
            Section {
                Button {
                    pick(nil)
                } label: {
                    option(L.t("settings.imageModelNone"), detail: nil, selected: team.imageModelSelection == nil)
                }
            } footer: {
                Text(L.t("settings.imageModelNote"))
            }

            if let endpoint {
                manual(endpoint)
                if !choices.isEmpty {
                    Section(L.t("settings.imageModelAvailable")) {
                        ForEach(choices) { choice in
                            Button {
                                pick(choice.id)
                            } label: {
                                option(choice.model, detail: choice.service, selected: choice.id == team.settings.imageModel)
                            }
                        }
                    }
                }
            } else {
                Section { Text(L.t("settings.imageModelNoService")).foregroundStyle(Ink.inkSoft) }
            }
        }
        .paperForm()
        .navigationTitle(L.t("settings.imageModel"))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: L.t("settings.imageModelSearch"))
        .onAppear {
            if let selected = team.imageModelSelection { serviceID = selected.endpoint.id }
        }
    }

    private func manual(_ endpoint: Endpoint) -> some View {
        Section(L.t("settings.imageModelManual")) {
            Picker(L.t("settings.modelService"), selection: Binding(
                get: { self.endpoint?.id ?? "" },
                set: { serviceID = $0; refreshNote = nil }
            )) {
                ForEach(endpoints) { Text($0.name).tag($0.id) }
            }
            TextField(L.t("settings.imageModelPlaceholder"), text: $modelName)
                .font(Ink.mono(Ink.Size.body))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { if !typed.isEmpty { pick("\(endpoint.id)/\(typed)") } }
            Button(L.t("actions.save")) { pick("\(endpoint.id)/\(typed)") }
                .disabled(typed.isEmpty)
            Button(L.t("settings.refreshImageModels")) { Task { await refresh(endpoint.id) } }
                .disabled(refreshing)
            if let refreshNote { Text(refreshNote).font(Ink.footnote).foregroundStyle(Ink.inkSoft) }
        }
    }

    private func option(_ title: String, detail: String?, selected: Bool) -> some View {
        HStack(spacing: Ink.Space.m) {
            VStack(alignment: .leading, spacing: Ink.Space.xs) {
                Text(title).font(detail == nil ? Ink.label : Ink.mono(Ink.Size.sub)).foregroundStyle(Ink.ink)
                if let detail { Text(detail).font(Ink.footnote).foregroundStyle(Ink.inkSoft) }
            }
            Spacer(minLength: 0)
            if selected { Image(systemName: "checkmark").foregroundStyle(Ink.accent).accessibilityHidden(true) }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func pick(_ ref: String?) {
        Haptics.tick(0.6)
        team.setImageModel(ref)
        dismiss()
    }

    private func refresh(_ id: String) async {
        refreshing = true
        refreshNote = nil
        defer { refreshing = false }
        do {
            try await team.refreshImageModels(id)
            if endpoint?.id == id { refreshNote = L.t("settings.imageModelsRefreshed") }
        } catch {
            if endpoint?.id == id { refreshNote = L.t("errors.imageModelList") }
        }
    }
}
