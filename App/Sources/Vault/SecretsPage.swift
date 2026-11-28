import SwiftUI

/// 信匣: the passwords and keys kept on this phone.
struct SecretsPage: View {
    var embedded = false
    @ObservedObject private var secrets = Secrets.shared
    @Environment(\.dismiss) private var dismiss
    @State private var editing: Secrets.Item?
    @State private var pendingDelete: Secrets.Item?
    @State private var revealed: [String: String] = [:]
    @Environment(\.scenePhase) private var phase

    var body: some View {
        Group {
            if embedded {
                content
            } else {
                NavigationStack { content }
            }
        }
        // A password shown stays shown only while the app is in front: never in the app switcher.
        .onChange(of: phase) { _, now in if now != .active { revealed = [:] } }
    }

    private var content: some View {
        ZStack {
                Ink.paper.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: Ink.Space.l) {
                        Text(L.t("settings.secretsStorageNote"))
                            .font(Ink.secondary)
                            .foregroundStyle(Ink.inkSoft)
                        if secrets.items.isEmpty {
                            EmptyNote(symbol: "lock.rectangle.stack", words: L.t("empty.vault"))
                        } else {
                            LazyVStack(spacing: 0) {
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
                if !embedded {
                    ToolbarItem(placement: .topBarTrailing) { Button(L.t("actions.done")) { dismiss() } }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editing = Secrets.Item(title: "") } label: { Image(systemName: "plus") }
                        .accessibilityLabel("添加密码项目")
                }
            }
            .sheet(item: $editing) { item in SecretEditor(item: item) }
            .confirmationDialog(
                L.format("files.deleteConfirm", pendingDelete?.title ?? ""),
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button(L.t("actions.delete"), role: .destructive) {
                    guard let target = pendingDelete else { return }
                    pendingDelete = nil
                    deleteSecret(target)
                }
                Button(L.t("actions.cancel"), role: .cancel) { pendingDelete = nil }
            } message: {
                Text(L.t("errors.cannotUndo"))
            }
    }

    private func row(_ item: Secrets.Item) -> some View {
        VStack(alignment: .leading, spacing: Ink.Space.xs) {
            HStack(spacing: Ink.Space.m) {
                IconBadge(symbol: item.kind.symbol)
                VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
                    Text(item.title).font(.system(size: Ink.Size.body, weight: .medium)).foregroundStyle(Ink.ink).lineLimit(1)
                    Text([item.user, item.site].filter { !$0.isEmpty }.joined(separator: " · ").ifEmpty(item.kind.title))
                        .font(Ink.footnote).foregroundStyle(Ink.inkSoft).lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(item.id).font(Ink.mono(Ink.Size.micro)).foregroundStyle(Ink.inkFaint)
            }
            if let shown = revealed[item.id] {
                Text(shown).font(Ink.mono(Ink.Size.sub)).foregroundStyle(Ink.ink).textSelection(.enabled).padding(.leading, Kit.badge + Ink.Space.m)
            }
        }
        .padding(.horizontal, Ink.Space.l)
        .padding(.vertical, Ink.Space.m)
        .contentShape(Rectangle())
        .onTapGesture {
            Task {
                guard await Secrets.unlock("编辑「\(item.title)」") else { return }
                editing = item
            }
        }
        .contextMenu {
            Button(revealed[item.id] == nil ? L.t("actions.showPassword") : L.t("actions.hidePassword"), systemImage: "eye") {
                toggleReveal(for: item)
            }
            Button(L.t("actions.copyPassword"), systemImage: "doc.on.doc") {
                copySecret(for: item)
            }
            if !item.user.isEmpty {
                Button(L.t("actions.copyUserName"), systemImage: "person") { UIPasteboard.general.string = item.user }
            }
            Button(L.t("actions.edit"), systemImage: "pencil") {
                Task {
                    guard await Secrets.unlock("编辑「\(item.title)」") else { return }
                    editing = item
                }
            }
            Button(L.t("actions.delete"), systemImage: "trash", role: .destructive) { pendingDelete = item }
        }
    }

    private func deleteSecret(_ target: Secrets.Item) {
        let id = target.id
        let title = target.title
        Task {
            guard await Secrets.unlock("删除「\(title)」") else { return }
            await Task.detached(priority: .userInitiated) {
                Vault.remove("secret.\(id)")
            }.value
            withAnimation(.smooth) {
                revealed.removeValue(forKey: id)
                secrets.remove(target)
            }
        }
    }

    private func toggleReveal(for item: Secrets.Item) {
        if revealed[item.id] != nil {
            revealed[item.id] = nil
            return
        }
        let id = item.id
        let title = item.title
        Task {
            guard await Secrets.unlock("看「\(title)」的密码") else { return }
            let value = await Task.detached(priority: .userInitiated) {
                Secrets.secret(id)
            }.value
            revealed[id] = value ?? "（没存密码）"
        }
    }

    private func copySecret(for item: Secrets.Item) {
        let id = item.id
        let title = item.title
        Task {
            guard await Secrets.unlock("复制「\(title)」的密码") else { return }
            let secret = await Task.detached(priority: .userInitiated) {
                Secrets.secret(id)
            }.value
            guard let secret else { return }
            UIPasteboard.general.setItems(
                [[UIPasteboard.typeAutomatic: secret]],
                options: [.expirationDate: Date().addingTimeInterval(90), .localOnly: true]
            )
            Haptics.tick(0.6)
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
    @State private var hasStoredSecret: Bool?
    @State private var saving = false
    @State private var saveError: String?
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
                if let saveError {
                    Section {
                        Text(saveError)
                            .font(Ink.footnote)
                            .foregroundStyle(Ink.stop)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            }
            .paperForm()
            .navigationTitle(isNew ? L.t("vault.newItem") : item.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L.t("actions.cancel")) { dismiss() }
                        .disabled(saving)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L.t("actions.save")) { save() }
                        .disabled(saving || item.title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .interactiveDismissDisabled(saving)
        .task(id: item.id) {
            if isNew {
                hasStoredSecret = false
                return
            }
            let exists = await Self.storedSecretExists(id: item.id)
            guard !Task.isCancelled else { return }
            hasStoredSecret = exists
        }
    }

    private var placeholder: String {
        (isNew || hasStoredSecret != true) ? "密码 / 令牌" : "密码（已存，不改就留空）"
    }

    private func save() {
        guard !saving else { return }
        saving = true
        saveError = nil
        let itemToSave = item
        let secretToSave = secret.isEmpty ? nil : secret
        Task {
            if let secretToSave {
                let result = await Task.detached(priority: .userInitiated) {
                    Vault.saveResult(secretToSave, as: "secret.\(itemToSave.id)")
                }.value
                if case .failure(let error) = result {
                    saving = false
                    saveError = "密码未能存入系统钥匙串（\(error.localizedDescription)），请重试。"
                    return
                }
            }
            Secrets.shared.save(itemToSave, secret: nil)
            Haptics.thud()
            dismiss()
        }
    }

    private nonisolated static func storedSecretExists(id: String) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            Secrets.secret(id) != nil
        }.value
    }
}
