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
                        Text("账号、密码和密钥收在这里，密码锁在手机钥匙串里。旅伴能看到名字、地址和用户名，看不到密码；要用密码时会先请你落印。")
                            .font(Ink.secondary)
                            .foregroundStyle(Ink.inkSoft)
                        if secrets.items.isEmpty {
                            VStack(spacing: Ink.Space.m) {
                                Image(systemName: "lock.rectangle.stack").font(.system(size: 36)).foregroundStyle(Ink.inkFaint)
                                Text("信匣还空着。点右上角的 + 存一条，或者旅伴递笺时你填的密码会自动收进来。")
                                    .font(Ink.footnote).foregroundStyle(Ink.inkFaint).multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Ink.Space.xxl)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(secrets.items) { item in
                                    row(item)
                                    if item.id != secrets.items.last?.id { Rectangle().fill(Ink.rule).frame(height: 1).padding(.leading, 52) }
                                }
                            }
                            .paperCard()
                        }
                    }
                    .padding(.horizontal, Ink.Space.page)
                    .padding(.vertical, Ink.Space.l)
                }
            }
            .navigationTitle("信匣")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("好了") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editing = Secrets.Item(title: "") } label: { Image(systemName: "plus") }
                }
            }
            .sheet(item: $editing) { item in SecretEditor(item: item) }
        }
    }

    private func row(_ item: Secrets.Item) -> some View {
        VStack(alignment: .leading, spacing: Ink.Space.xs) {
            HStack(spacing: Ink.Space.m) {
                Image(systemName: item.kind.symbol).font(.system(size: 17)).foregroundStyle(Ink.accent).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.system(size: 16, weight: .medium)).foregroundStyle(Ink.ink).lineLimit(1)
                    Text([item.user, item.site].filter { !$0.isEmpty }.joined(separator: " · ").ifEmpty(item.kind.title))
                        .font(Ink.footnote).foregroundStyle(Ink.inkSoft).lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(item.id).font(.system(size: 11, design: .monospaced)).foregroundStyle(Ink.inkFaint)
            }
            if let shown = revealed[item.id] {
                Text(shown).font(.system(size: 14, design: .monospaced)).foregroundStyle(Ink.ink).textSelection(.enabled).padding(.leading, 40)
            }
        }
        .padding(.horizontal, Ink.Space.l)
        .padding(.vertical, Ink.Space.m)
        .contentShape(Rectangle())
        .onTapGesture { editing = item }
        .contextMenu {
            Button(revealed[item.id] == nil ? "看密码" : "藏起密码", systemImage: "eye") {
                if revealed[item.id] != nil { revealed[item.id] = nil; return }
                Task {
                    guard await Secrets.unlock("看「\(item.title)」的密码") else { return }
                    revealed[item.id] = Secrets.secret(item.id) ?? "（没存密码）"
                }
            }
            Button("复制密码", systemImage: "doc.on.doc") {
                Task {
                    guard await Secrets.unlock("复制「\(item.title)」的密码"), let secret = Secrets.secret(item.id) else { return }
                    UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: secret]], options: [.expirationDate: Date().addingTimeInterval(90), .localOnly: true])
                    Haptics.tick(0.6)
                }
            }
            if !item.user.isEmpty {
                Button("复制用户名", systemImage: "person") { UIPasteboard.general.string = item.user }
            }
            Button("删掉", systemImage: "trash", role: .destructive) { withAnimation(.smooth) { secrets.remove(item) } }
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
                        Button { showing.toggle() } label: { Image(systemName: showing ? "eye.slash" : "eye") }.buttonStyle(.plain)
                    }
                }
                Section("备注") { TextField("可不填", text: $item.note, axis: .vertical).lineLimit(1...4) }
            }
            .scrollContentBackground(.hidden)
            .background(Ink.paper)
            .navigationTitle(isNew ? "存一条" : item.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("算了") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("存好") {
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
