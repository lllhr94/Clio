import Craft
import SwiftUI

/// 笺: what a companion asked the user to fill in. Secrets go into 信匣 and only their number goes back.
struct FormSheet: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let form: Asker.Form
    @ObservedObject private var secrets = Secrets.shared
    @State private var values: [String: String] = [:]
    /// For a secret field: the 信匣 item picked instead of typing.
    @State private var picked: [String: Secrets.Item] = [:]
    @State private var shown: Set<String> = []
    /// For non-secret structured single/multi/custom fields inside a Vault or multi-field sheet.
    @State private var selectedByKey: [String: [String]] = [:]
    @State private var customByKey: [String: String] = [:]
    @State private var customOpenKeys: Set<String> = []
    @State private var limitWarningKey: String?
    @State private var submitError: String?
    @State private var isSubmitting = false

    private var activeValidationError: String? {
        AskSheetLogic.activeInputError(for: form.fields) { field in
            if usesSegmentedPicker(field) {
                let current = values[field.key] ?? ""
                return AskResponse(selected: current.isEmpty ? [] : [current])
            }
            return currentResponse(for: field)
        }
    }

    private var canSubmit: Bool {
        for field in form.fields {
            if field.secret {
                if field.required {
                    let hasPicked = picked[field.key] != nil
                    let hasTyped = !(values[field.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    if !hasPicked && !hasTyped { return false }
                }
                continue
            }
            if usesSegmentedPicker(field) {
                let current = values[field.key] ?? ""
                if !field.effectiveOptions.contains(where: { $0.value == current }) {
                    return false
                }
                continue
            }
            let response = currentResponse(for: field)
            if AskSheetLogic.validatedNonSecretField(field, response: response) == nil {
                return false
            }
        }
        return true
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Ink.paper.ignoresSafeArea()
                ScrollView {
                    formContent
                        .padding(.horizontal, Ink.Space.page)
                        .padding(.vertical, Ink.Space.l)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L.t("actions.cancel")) {
                        Haptics.light()
                        Asker.shared.cancel(form.id)
                    }
                    .disabled(isSubmitting)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L.t("actions.submitForm")) { send() }
                        .fontWeight(.semibold)
                        .disabled(isSubmitting || !canSubmit)
                }
            }
        }
        .interactiveDismissDisabled()
        .onAppear { seedInitialValues() }
    }

    private var formContent: some View {
        VStack(alignment: .leading, spacing: Ink.Space.l) {
            HStack(spacing: Ink.Space.m) {
                PetStill(size: 44, state: "notification", avatar: true)
                VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
                    Text(L.format("forms.sender", form.from))
                        .font(Ink.footnote)
                        .foregroundStyle(Ink.inkSoft)
                    Text(form.title)
                        .font(Ink.mark(Ink.Size.title, bold: true, relativeTo: .title2))
                        .foregroundStyle(Ink.ink)
                }
            }
            if !form.reason.isEmpty {
                Text(form.reason)
                    .font(Ink.secondary)
                    .foregroundStyle(Ink.inkSoft)
            }
            VStack(spacing: 0) {
                ForEach(form.fields) { field in
                    row(field)
                    if field.key != form.fields.last?.key { Kit.rule(inset: Ink.Space.l) }
                }
            }
            .paperCard()
            if let message = activeValidationError ?? submitError {
                Text(message)
                    .font(Ink.footnote)
                    .foregroundStyle(Ink.stop)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if form.requiresVault || form.fields.contains(where: \.secret) {
                Label(L.t("forms.secretNote"), systemImage: "lock.shield")
                    .font(Ink.footnote)
                    .foregroundStyle(Ink.inkFaint)
            }
        }
    }

    private func seedInitialValues() {
        for field in form.fields where field.secret && values[field.key] == nil {
            values[field.key] = ""
        }
        AskSheetLogic.seedNonSecretState(
            fields: form.fields,
            selectedByKey: &selectedByKey,
            customByKey: &customByKey,
            customOpenKeys: &customOpenKeys,
            values: &values,
            usesSegmentedPicker: usesSegmentedPicker
        )
    }

    private func usesSegmentedPicker(_ field: Asker.Field) -> Bool {
        guard !field.secret,
              field.effectiveKind == .single,
              !field.allowCustom,
              field.askQuestion.effectiveMinSelections > 0 else {
            return false
        }
        let options = field.effectiveOptions
        guard !options.isEmpty, options.count <= 3 else { return false }
        return options.allSatisfy { $0.detail.isEmpty && !$0.recommended }
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { values[key] ?? "" }, set: { values[key] = $0 })
    }

    private func selectedBinding(for key: String) -> Binding<[String]> {
        Binding(get: { selectedByKey[key] ?? [] }, set: { selectedByKey[key] = $0 })
    }

    private func customBinding(for key: String) -> Binding<String> {
        Binding(get: { customByKey[key] ?? "" }, set: { customByKey[key] = $0 })
    }

    private func customOpenBinding(for key: String) -> Binding<Bool> {
        Binding(
            get: { customOpenKeys.contains(key) },
            set: { open in
                if open { customOpenKeys.insert(key) } else { customOpenKeys.remove(key) }
            }
        )
    }

    private func choices(for field: Asker.Field) -> some View {
        Picker(field.label, selection: binding(field.key)) {
            ForEach(field.effectiveOptions) { option in
                Text(option.label).tag(option.value)
            }
        }
    }

    @ViewBuilder
    private func row(_ field: Asker.Field) -> some View {
        VStack(alignment: .leading, spacing: Ink.Space.xs) {
            rowHeader(field)
            if field.secret {
                secretFieldInput(field)
            } else if usesSegmentedPicker(field) {
                if typeSize.isAccessibilitySize {
                    choices(for: field).pickerStyle(.menu)
                } else {
                    choices(for: field).pickerStyle(.segmented)
                }
            } else if field.effectiveKind != .text {
                AskFieldControl(
                    field: field,
                    showLabel: false,
                    showOptional: false,
                    selected: selectedBinding(for: field.key),
                    customText: customBinding(for: field.key),
                    isCustomOpen: customOpenBinding(for: field.key),
                    limitWarning: limitWarningKey == field.key,
                    onLimitHit: { triggerLimitWarning(for: field.key) }
                )
                .padding(.top, Ink.Space.xs / 2)
            } else {
                TextField(field.placeholder, text: binding(field.key))
                    .font(.system(size: Ink.Size.body))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .frame(minHeight: 30)
            }
        }
        .padding(.horizontal, Ink.Space.l)
        .padding(.vertical, Ink.Space.m)
    }

    private func rowHeader(_ field: Asker.Field) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Ink.Space.s) {
            Text(field.label)
                .font(.system(size: Ink.Size.small, weight: .medium))
                .foregroundStyle(Ink.inkSoft)
            if field.optionalBadge {
                Text(L.t("ask.optional"))
                    .font(.system(size: Ink.Size.micro))
                    .foregroundStyle(Ink.inkFaint)
            }
            Spacer()
            if field.secret, !secrets.items.isEmpty {
                Menu {
                    ForEach(secrets.items) { item in
                        Button("\(item.title)\(item.user.isEmpty ? "" : " · \(item.user)")") {
                            picked[field.key] = item
                            Haptics.tick(0.6)
                        }
                    }
                    if picked[field.key] != nil {
                        Button(L.t("actions.enterManually"), systemImage: "keyboard") { picked[field.key] = nil }
                    }
                } label: {
                    Label(L.t("actions.pickSecret"), systemImage: "lock.rectangle.stack")
                        .font(.system(size: Ink.Size.small, weight: .medium))
                        .foregroundStyle(Ink.accent)
                }
            }
        }
    }

    @ViewBuilder
    private func secretFieldInput(_ field: Asker.Field) -> some View {
        if let item = picked[field.key] {
            HStack {
                Image(systemName: item.kind.symbol).foregroundStyle(Ink.accent)
                Text(L.format("forms.usePickedSecret", item.title))
                    .font(.system(size: Ink.Size.body))
                    .foregroundStyle(Ink.ink)
                Spacer()
            }
            .frame(height: 30)
        } else {
            HStack {
                Group {
                    if shown.contains(field.key) {
                        TextField(field.placeholder, text: binding(field.key))
                    } else {
                        SecureField(field.placeholder, text: binding(field.key))
                    }
                }
                .font(.system(size: Ink.Size.body))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                Button {
                    if shown.contains(field.key) { shown.remove(field.key) } else { shown.insert(field.key) }
                } label: {
                    Image(systemName: shown.contains(field.key) ? "eye.slash" : "eye")
                        .foregroundStyle(Ink.inkFaint)
                }
                .buttonStyle(TapStyle(grow: 8))
                .accessibilityLabel(shown.contains(field.key) ? L.t("actions.hidePassword") : L.t("actions.showPassword"))
            }
            .frame(height: 30)
        }
    }

    private func currentResponse(for field: Asker.Field) -> AskResponse {
        AskSheetLogic.response(
            for: field,
            selectedByKey: selectedByKey,
            customByKey: customByKey,
            customOpenKeys: customOpenKeys,
            textValues: values
        )
    }

    private func triggerLimitWarning(for key: String) {
        Haptics.light()
        withAnimation(Ink.Motion.press) { limitWarningKey = key }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            if limitWarningKey == key {
                withAnimation(Ink.Motion.settle) { limitWarningKey = nil }
            }
        }
    }

    private func plainMetadataValue(forKeys keys: [String]) -> String {
        for key in keys {
            guard let field = form.fields.first(where: { $0.key == key }), !field.secret else { continue }
            let raw = (values[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !raw.isEmpty { return raw }
        }
        return ""
    }

    private func validationResponseForSend(_ field: Asker.Field) -> AskResponse {
        if usesSegmentedPicker(field) {
            let current = values[field.key] ?? ""
            return AskResponse(selected: current.isEmpty ? [] : [current])
        }
        return currentResponse(for: field)
    }

    /// Plain values go back as typed; secrets are kept in 信匣 and go back as `secret:<id>`.
    /// Validates ALL non-secret fields BEFORE saving any secret into Vault/Keychain.
    private func send() {
        guard !isSubmitting else { return }
        if let error = AskSheetLogic.validateAllNonSecretFields(fields: form.fields, responseProvider: validationResponseForSend) {
            submitError = error.userMessage
            Haptics.light()
            return
        }
        submitError = nil

        var out: [String: String] = [:]
        var pendingSecrets: [(item: Secrets.Item, secret: String)] = []
        let rawUser = plainMetadataValue(forKeys: ["user", "username", "account"])
        let rawAddress = plainMetadataValue(forKeys: ["address"])
        let cleanFormSite = AskUserRules.redactURLCredentials(in: form.site)
        let cleanAddress = AskUserRules.redactURLCredentials(in: rawAddress)
        let cleanFormTitle = AskUserRules.redactURLCredentials(in: form.title)
        let candidateTitle = cleanFormSite.isEmpty ? cleanFormTitle : "\(cleanFormTitle) · \(cleanFormSite)"
        let candidateSite = cleanFormSite.isEmpty ? cleanAddress : cleanFormSite
        let candidateUser = AskUserRules.redactURLCredentials(in: rawUser)

        let safeTitle = AskUserRules.containsSecretURLCredential(candidateTitle) ? "凭据" : candidateTitle
        let safeSite = AskUserRules.containsSecretURLCredential(candidateSite) ? "" : candidateSite
        let safeUser = AskUserRules.containsSecretURLCredential(candidateUser) ? "" : candidateUser

        for field in form.fields {
            if field.secret {
                let value = values[field.key] ?? ""
                if let item = picked[field.key] {
                    out[field.key] = "secret:\(item.id)"
                } else if !value.isEmpty {
                    let item = Secrets.Item(
                        title: safeTitle,
                        kind: form.kind,
                        site: safeSite,
                        user: safeUser,
                        note: "由\(form.from)请你填写时存下"
                    )
                    pendingSecrets.append((item: item, secret: value))
                    out[field.key] = "secret:\(item.id)"
                } else {
                    out[field.key] = ""
                }
                continue
            }

            if usesSegmentedPicker(field) || field.effectiveKind == .text {
                out[field.key] = values[field.key] ?? ""
            } else {
                let response = currentResponse(for: field)
                out[field.key] = AskSheetLogic.encodedNonSecretField(field, response: response)
            }
        }
        let finalOut = out
        let formID = form.id
        guard !pendingSecrets.isEmpty else {
            Haptics.thud()
            Asker.shared.answer(finalOut, to: formID)
            return
        }
        isSubmitting = true
        let entriesToWrite = pendingSecrets
        Task {
            await Task.detached(priority: .userInitiated) {
                for entry in entriesToWrite {
                    Vault.save(entry.secret, as: "secret.\(entry.item.id)")
                }
            }.value
            for entry in entriesToWrite {
                secrets.save(entry.item, secret: nil)
            }
            Haptics.thud()
            Asker.shared.answer(finalOut, to: formID)
        }
    }
}
