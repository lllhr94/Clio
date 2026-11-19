import SwiftUI

/// 连接器: the person's own accounts and services the companions can use: Google (Gmail and Drive),
/// 高德地图, GitHub, or any other MCP service. Each card says what it gives and what it needs.
struct ConnectorsPage: View {
    @ObservedObject private var hills = Hills.shared
    @ObservedObject private var google = Google.shared
    @Environment(\.dismiss) private var dismiss
    @State private var opened: Preset?
    @State private var googleOpen = false
    @State private var othersOpen = false

    /// An MCP service that only needs a key or token to connect.
    struct Preset: Identifiable {
        let id: String
        let name: String
        let icon: String
        let line: String
        let url: String
        /// The token is put in the address as `?<name>=…` instead of an Authorization header.
        let queryName: String?
        let keyTitle: String
        let keyPage: String
        let steps: [String]
    }

    static let presets: [Preset] = [
        Preset(id: "amap", name: "高德地图", icon: "map", line: "查地点、路线、天气、周边，算距离和到达时间",
               url: "https://mcp.amap.com/mcp", queryName: "key", keyTitle: "Web 服务 Key",
               keyPage: "https://console.amap.com/dev/key/app",
               steps: ["登录高德开放平台控制台，进「应用管理 → 我的应用」，新建一个应用。",
                       "在这个应用里点「添加 Key」，服务平台选「Web 服务」。",
                       "把这个 Key 粘到下面。个人开发者每天有免费额度。"]),
        Preset(id: "github", name: "GitHub", icon: "chevron.left.forwardslash.chevron.right", line: "看仓库、代码、议题和合并请求，替你开议题",
               url: "https://api.githubcopilot.com/mcp/", queryName: nil, keyTitle: "个人访问令牌",
               keyPage: "https://github.com/settings/personal-access-tokens/new",
               steps: ["在 GitHub 新建一个 Fine-grained 个人访问令牌。",
                       "选好它能看的仓库和权限（只读最稳妥）。",
                       "把令牌粘到下面。"]),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Ink.Space.l) {
                    Text("连上你自己的账号和服务，旅伴就能替你查邮件、找文件、规划路线。密钥和登录都只存在这台手机的钥匙串里；能做到哪一步，在「应许」里管。")
                        .font(Ink.secondary).foregroundStyle(Ink.inkSoft)
                    card(icon: "envelope.open", name: "谷歌", line: "Gmail 找信、读信、存草稿、发信；云端硬盘找文件、读文件",
                         state: google.account.map { "已登录 · \($0)" }) { googleOpen = true }
                    ForEach(Self.presets) { preset in
                        let server = hills.servers.first { $0.connector == preset.id }
                        card(icon: preset.icon, name: preset.name, line: preset.line,
                             state: server.map { "已连上 · \(hills.tools(of: $0).count) 个工具" }) { opened = preset }
                    }
                    card(icon: "point.3.connected.trianglepath.dotted", name: "其他 MCP 服务", line: "任何支持 Streamable HTTP 的 MCP 服务，填地址和令牌就能用",
                         state: othersState) { othersOpen = true }
                }
                .padding(.horizontal, Ink.Space.page)
                .padding(.vertical, Ink.Space.l)
            }
            .background(Ink.paper.ignoresSafeArea())
            .navigationTitle("连接器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("好了") { dismiss() } } }
        }
        .sheet(item: $opened) { PresetSheet(preset: $0) }
        .sheet(isPresented: $googleOpen) { GoogleSheet() }
        .sheet(isPresented: $othersOpen) { HillsPage() }
    }

    private var othersState: String? {
        let count = hills.servers.filter { $0.connector == nil }.count
        return count == 0 ? nil : "\(count) 个"
    }

    private func card(icon: String, name: String, line: String, state: String?, open: @escaping () -> Void) -> some View {
        Button {
            Haptics.light()
            open()
        } label: {
            HStack(alignment: .top, spacing: Ink.Space.m) {
                Image(systemName: icon).font(.system(size: 18)).foregroundStyle(Ink.accent).frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(name).font(.system(size: 16, weight: .semibold)).foregroundStyle(Ink.ink)
                        Spacer()
                        Text(state ?? "没连").font(Ink.footnote).foregroundStyle(state == nil ? Ink.inkFaint : Ink.ok).lineLimit(1)
                    }
                    Text(line).font(Ink.footnote).foregroundStyle(Ink.inkSoft).multilineTextAlignment(.leading)
                }
            }
            .padding(Ink.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .paperCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(haptic: false))
    }
}

/// Connecting one key-based MCP service: how to get the key, the field, and whether it worked.
private struct PresetSheet: View {
    let preset: ConnectorsPage.Preset
    @ObservedObject private var hills = Hills.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var key = ""
    @State private var busy = false
    @State private var result: String?

    private var server: Hills.Server? { hills.servers.first { $0.connector == preset.id } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(Array(preset.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(index + 1)").font(.system(size: 13, weight: .bold)).foregroundStyle(Ink.accent).frame(width: 16)
                            Text(step).font(.system(size: 14))
                        }
                    }
                    Button("去申请\(preset.keyTitle)") { if let url = URL(string: preset.keyPage) { openURL(url) } }
                } header: { Text("怎么拿到\(preset.keyTitle)") }

                Section {
                    SecureField(server == nil ? "粘贴\(preset.keyTitle)" : "已存好；要换就粘新的", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        Task { await connect() }
                    } label: {
                        HStack {
                            Text(server == nil ? "连上" : (key.isEmpty ? "重新取一次工具" : "换上新的并连上"))
                            if busy { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(busy || (server == nil && key.trimmingCharacters(in: .whitespaces).isEmpty))
                } footer: {
                    if let result { Text(result) }
                    else if let server, let problem = hills.lastError[server.id] { Text("上次出错：\(problem)").foregroundStyle(Ink.stop) }
                }

                if let server {
                    Section {
                        ForEach(hills.tools(of: server), id: \.name) { tool in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tool.name).font(.system(size: 14, weight: .medium, design: .monospaced))
                                Text(tool.description).font(.system(size: 12)).foregroundStyle(Ink.inkSoft).lineLimit(2)
                            }
                        }
                    } header: { Text("它带来的工具") }
                    Section {
                        Button("断开\(preset.name)", role: .destructive) {
                            hills.remove(server)
                            Vault.remove("mcp.\(server.id)")
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(preset.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("好了") { dismiss() } } }
        }
    }

    private func connect() async {
        busy = true
        defer { busy = false }
        let typed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        var entry = server ?? Hills.Server(name: preset.name, url: preset.url)
        entry.connector = preset.id
        entry.enabled = true
        let token: String? = typed.isEmpty ? nil : (preset.queryName.map { "?\($0)=\(typed)" } ?? typed)
        hills.save(entry, token: token)
        let count = await hills.refresh(entry)
        if count >= 0 {
            key = ""
            Haptics.grab()
            result = "连上了，带来 \(count) 个工具。旅伴现在就能用。"
        } else {
            result = "没连上：\(hills.lastError[entry.id] ?? "不明原因")。看看\(preset.keyTitle)对不对。"
        }
    }
}

/// Signing in to Google with the person's own OAuth client.
private struct GoogleSheet: View {
    @ObservedObject private var google = Google.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var client = Google.shared.clientId

    var body: some View {
        NavigationStack {
            Form {
                if let account = google.account {
                    Section {
                        Label(account, systemImage: "checkmark.circle.fill").foregroundStyle(Ink.ok)
                        Text("旅伴能找、读你的 Gmail 和云端硬盘，能存邮件草稿；真要发信，每次都会先问你。")
                            .font(.system(size: 13)).foregroundStyle(Ink.inkSoft)
                        Button("重新登录") { Task { await google.signIn() } }.disabled(google.busy)
                        Button("退出谷歌", role: .destructive) { google.signOut() }
                    } footer: {
                        Text("谷歌把还在测试的应用的登录 7 天作废；到时旅伴会说登录过期，回这里点「重新登录」。")
                    }
                } else {
                    Section {
                        step(1, "打开 Google Cloud 控制台，新建一个项目（名字随意）。")
                        step(2, "「API 和服务 → 库」里启用 Gmail API 和 Google Drive API。")
                        step(3, "「OAuth 同意屏幕」：用户类型选「外部」，把你自己的 Gmail 加进「测试用户」。")
                        step(4, "「凭据 → 创建凭据 → OAuth 客户端 ID」，应用类型选「iOS」，软件包 ID 填 io.github.lllhr94.clio。")
                        step(5, "复制生成的客户端 ID，粘到下面，点登录。")
                        Button("打开 Google Cloud 控制台") { if let url = URL(string: "https://console.cloud.google.com/apis/credentials") { openURL(url) } }
                    } header: { Text("第一次：做一个你自己的登录凭据") } footer: {
                        Text("Clio 不经过任何别人的服务器：手机直接向谷歌登录，令牌只存在钥匙串里。")
                    }
                    Section {
                        TextField("xxxx.apps.googleusercontent.com", text: $client)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(size: 14, design: .monospaced))
                        Button {
                            google.clientId = client
                            Task { await google.signIn() }
                        } label: {
                            HStack {
                                Text("用谷歌账号登录")
                                if google.busy { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(google.busy || !client.contains(".apps.googleusercontent.com"))
                    } header: { Text("客户端 ID") } footer: {
                        if let problem = google.problem { Text(problem).foregroundStyle(Ink.stop) }
                    }
                }
            }
            .navigationTitle("谷歌")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("好了") { dismiss() } } }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)").font(.system(size: 13, weight: .bold)).foregroundStyle(Ink.accent).frame(width: 16)
            Text(text).font(.system(size: 14))
        }
    }
}
