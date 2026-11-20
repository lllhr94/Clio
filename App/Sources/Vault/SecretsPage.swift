import SwiftUI

/// 信匣: the passwords and keys kept on this phone.
struct SecretsPage: View {
    @ObservedObject private var secrets = Secrets.shared
    @Environment(\.dismiss) private var dismiss
    @State private var editing: Secrets.Item?
    @State private var revealed: [String: String] = [:]

    var body: some View {
        NavigationStack {
            ZStack {
                Ink.paper.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: Ink.Space.l) {
                        Text(L.t("settings.secretsStorageNote"))
                            .font(Ink.secondary)
                            .foregroundStyle(Ink.inkSoft)
                        if secrets.items.isEmpty {
                            VStack(spacing: Ink.Space.m) {
                                Image(systemName: "lock.rectangle.stack").font(.system(size: 36)).foregroundStyle(Ink.inkFaint)
                                Text(L.t("empty.vault"))
                                    .font(Ink.footnote).foregroundStyle(Ink.inkFaint).multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Ink.Space.xxl)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(secrets.items) { item in
                                    row(item)
                                    if item.id != secrets.items.last?.id { Kit.divider }
                                }
                            }
                            .paperCard()
                        }
                    }
                    .padding(.horizontal, Ink.Space.page)
                    .padding(.vertical, Ink.Space.l)
                }
            }
            .navigationTitle(L.t("settings.vault"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button(L.t("actions.done")) { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editing = Secrets.Item(title: "") } label: { Image(systemName: "plus") }
                        .accessibilityLabel("添加密码项目")
                }
            }
            .sheet(item: $editing) { item in SecretEditor(item: item) }
        }
    }

    private func row(_ item: Secrets.Item) -> some View {
        VStack(alignment: .leading, spacing: Ink.Space.xs) {
            HStack(spacing: Ink.Space.m) {
                IconBadge(symbol: item.kind.symbol)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.system(size: Ink.Size.body, weight: .medium)).foregroundStyle(Ink.ink).lineLimit(1)
                    Text([item.user, item.site].filter { !$0.isEmpty }.joined(separator: " · ").ifEmpty(item.kind.title))
                        .font(Ink.footnote).foregroundStyle(Ink.inkSoft).lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(item.id).font(Ink.mono(Ink.Size.micro)).foregroundStyle(Ink.inkFaint)
            }
            if let shown = revealed[item.id] {
                Text(shown).font(Ink.mono(Ink.Size.sub)).foregroundStyle(Ink.ink).textSelection(.enabled).padding(.leading, 40)
            }
        }
        .padding(.horizontal, Ink.Space.l)
        .padding(.vertical, Ink.Space.m)
        .contentShape(Rectangle())
        .onTapGesture { editing = item }
        .contextMenu {
            Button(revealed[item.id] == nil ? L.t("actions.showPassword") : L.t("actions.hidePassword"), systemImage: "eye") {
                if revealed[item.id] != nil { revealed[item.id] = nil; return }
                Task {
                    guard await Secrets.unlock("看「\(item.title)」的密码") else { return }
                    revealed[item.id] = Secrets.secret(item.id) ?? "（没存密码）"
                }
            }
            Button(L.t("actions.copyPassword"), systemImage: "doc.on.doc") {
                Task {
                    guard await Secrets.unlock("复制「\(item.title)」的密码"), let secret = Secrets.secret(item.id) else { return }
                    UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: secret]], options: [.expirationDate: Date().addingTimeInterval(90), .localOnly: true])
                    Haptics.tick(0.6)
                }
            }
            if !item.user.isEmpty {
                Button(L.t("actions.copyUserName"), systemImage: "person") { UIPasteboard.general.string = item.user }
            }
            Button(L.t("actions.delete"), systemImage: "trash", role: .destructive) { withAnimation(.smooth) { secrets.remove(item) } }
        }
    }
}

private extension String {
    func ifEmpty(_ other: String) -> String { isEmpty ? other : self }
}

private struct SecretEditor: View {
    @State var item: Secrets.Item
    @State private var secret = ""
    @State private var showing = false
    @Environment(\.dismiss) private var dismiss

    private var isNew: Bool { !Secrets.shared.items.contains { $0.id == item.id } }

    var body: some View {
        NavigationStack {
            Form {
                PaperRows {
                Section {
                    TextField("名字，比如：香港 VPS", text: $item.title)
                    Picker("种类", selection: $item.kind) {
                        ForEach(Secrets.Item.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
                Section {
                    TextField("地址、网址或用在哪", text: $item.site).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("用户名", text: $item.user).textInputAutocapitalization(.never).autocorrectionDisabled()
                    HStack {
                        Group {
                            if showing { TextField(placeholder, text: $secret) } else { SecureField(placeholder, text: $secret) }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        Button { showing.toggle() } label: { Image(systemName: showing ? "eye.slash" : "eye") }.buttonStyle(TapStyle(grow: 8))
                            .accessibilityLabel(showing ? "隐藏密码" : "显示密码")
                    }
                }
                Section(L.t("vault.notes")) { TextField("可不填", text: $item.note, axis: .vertical).lineLimit(1...4) }
            }
            }
            .paperForm()
            .navigationTitle(isNew ? L.t("vault.newItem") : item.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(L.t("actions.cancel")) { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L.t("actions.save")) {
                        Secrets.shared.save(item, secret: secret.isEmpty ? nil : secret)
                        Haptics.thud()
                        dismiss()
                    }
                    .disabled(item.title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private var placeholder: String {
        isNew || Secrets.secret(item.id) == nil ? "密码 / 令牌" : "密码（已存，不改就留空）"
    }
}
