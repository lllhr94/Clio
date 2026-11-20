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
    @State private var keep = true

    var body: some View {
        NavigationStack {
            ZStack {
                Ink.paper.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: Ink.Space.l) {
                        HStack(spacing: Ink.Space.m) {
                            PetStill(size: 44, state: "notification", avatar: true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L.format("forms.sender", form.from)).font(Ink.footnote).foregroundStyle(Ink.inkSoft)
                                Text(form.title).font(Ink.mark(22, bold: true, relativeTo: .title2)).foregroundStyle(Ink.ink)
                            }
                        }
                        if !form.reason.isEmpty {
                            Text(form.reason).font(Ink.secondary).foregroundStyle(Ink.inkSoft)
                        }
                        VStack(spacing: 0) {
                            ForEach(form.fields) { field in
                                row(field)
                                if field.key != form.fields.last?.key { Kit.rule(inset: Ink.Space.l) }
                            }
                        }
                        .paperCard()
                        if form.fields.contains(where: \.secret) {
                            Label(L.t("forms.secretNote"), systemImage: "lock.shield")
                                .font(Ink.footnote)
                                .foregroundStyle(Ink.inkFaint)
                        }
                    }
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
                        Asker.shared.cancel()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L.t("actions.submitForm")) { send() }.fontWeight(.semibold)
                }
            }
        }
        .interactiveDismissDisabled()
        .onAppear {
            for field in form.fields where values[field.key] == nil { values[field.key] = field.value }
        }
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { values[key] ?? "" }, set: { values[key] = $0 })
    }

    private func choices(for field: Asker.Field) -> some View {
        Picker(field.label, selection: binding(field.key)) {
            ForEach(field.choices, id: \.self) { Text($0).tag($0) }
        }
    }

    @ViewBuilder
    private func row(_ field: Asker.Field) -> some View {
        VStack(alignment: .leading, spacing: Ink.Space.xs) {
            HStack {
                Text(field.label).font(.system(size: Ink.Size.small, weight: .medium)).foregroundStyle(Ink.inkSoft)
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
                        Label(L.t("actions.pickSecret"), systemImage: "lock.rectangle.stack").font(.system(size: Ink.Size.small, weight: .medium)).foregroundStyle(Ink.accent)
                    }
                }
            }
            if !field.choices.isEmpty {
                if typeSize.isAccessibilitySize {
                    choices(for: field).pickerStyle(.menu)
                } else {
                    choices(for: field).pickerStyle(.segmented)
                }
            } else if field.secret {
                if let item = picked[field.key] {
                    HStack {
                        Image(systemName: item.kind.symbol).foregroundStyle(Ink.accent)
                        Text(L.format("forms.usePickedSecret", item.title)).font(.system(size: Ink.Size.body)).foregroundStyle(Ink.ink)
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
                            Image(systemName: shown.contains(field.key) ? "eye.slash" : "eye").foregroundStyle(Ink.inkFaint)
                        }
                        .buttonStyle(TapStyle(grow: 8))
                        .accessibilityLabel(shown.contains(field.key) ? "隐藏密码" : "显示密码")
                    }
                    .frame(height: 30)
                }
            } else {
                TextField(field.placeholder, text: binding(field.key))
                    .font(.system(size: Ink.Size.body))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .frame(height: 30)
            }
        }
        .padding(.horizontal, Ink.Space.l)
        .padding(.vertical, Ink.Space.m)
    }

    /// Plain values go back as typed; secrets are kept in 信匣 and go back as `secret:<id>`.
    private func send() {
        var out: [String: String] = [:]
        let user = values["user"] ?? values["username"] ?? values["account"] ?? ""
        for field in form.fields {
            let value = values[field.key] ?? ""
            guard field.secret else {
                out[field.key] = value
                continue
            }
            if let item = picked[field.key] {
                out[field.key] = "secret:\(item.id)"
            } else if !value.isEmpty {
                let title = form.site.isEmpty ? form.title : "\(form.title) · \(form.site)"
                let item = Secrets.Item(title: title, kind: form.kind, site: form.site.isEmpty ? (values["address"] ?? "") : form.site, user: user, note: "由\(form.from)递笺时存下")
                Secrets.shared.save(item, secret: value)
                out[field.key] = "secret:\(item.id)"
            } else {
                out[field.key] = ""
            }
        }
        Haptics.thud()
        Asker.shared.answer(out)
    }
}
