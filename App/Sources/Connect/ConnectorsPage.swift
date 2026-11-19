import SwiftUI

/// 连接器: the person's own accounts and services the companions can use. Most are official MCP services:
/// a tap signs in on the service's own page (MCP authorization), some take a key, some need nothing.
/// Google has its own native connector; any other MCP service can be added by its address.
struct ConnectorsPage: View {
    @ObservedObject private var hills = Hills.shared
    @ObservedObject private var google = Google.shared
    @Environment(\.dismiss) private var dismiss
    @State private var opened: Connector?
    @State private var googleOpen = false
    @State private var adding = false
    @State private var query = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Ink.Space.l) {
                    Text("连上你自己的账号和服务，旅伴就能替你查邮件、改文档、规划路线。大多数点一下就跳到那家的登录页；登录凭据只存在这台手机的钥匙串里。能做到哪一步，在「应许 → 远山 · MCP」里管。")
                        .font(Ink.secondary).foregroundStyle(Ink.inkSoft)
                    if !mine.isEmpty { section("已连上", mine) }
                    if query.isEmpty {
                        VStack(alignment: .leading, spacing: Ink.Space.s) {
                            Text("谷歌（原生）").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.inkSoft)
                            card(icon: "envelope.open", name: "谷歌", line: "Gmail 找信、读信、存草稿、发信；云端硬盘找文件、读文件。用你自己的 Client ID 登录，不经过别人",
                                 state: google.account.map { "已登录 · \($0)" }) { googleOpen = true }
                        }
                    }
                    ForEach(Connector.groups, id: \.self) { group in
                        let items = Connector.catalog.filter { $0.group == group && matches($0) && server(of: $0) == nil }
                        if !items.isEmpty { section(group, items) }
                    }
                    Button {
                        Haptics.light()
                        adding = true
                    } label: {
                        Label("自己填一个 MCP 地址", systemImage: "plus")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Ink.accent)
                            .frame(maxWidth: .infinity)
                            .padding(Ink.Space.l)
                            .paperCard()
                    }
                    .buttonStyle(PressStyle(haptic: false))
                }
                .padding(.horizontal, Ink.Space.page)
                .padding(.vertical, Ink.Space.l)
            }
            .background(Ink.paper.ignoresSafeArea())
            .searchable(text: $query, prompt: "找连接器")
            .navigationTitle("连接器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("好了") { dismiss() } } }
        }
        .sheet(item: $opened) { ConnectSheet(connector: $0) }
        .sheet(isPresented: $googleOpen) { GoogleSheet() }
        .sheet(isPresented: $adding) { CustomSheet() }
    }

    /// Everything connected: from the catalog, and the ones added by address.
    private var mine: [Connector] {
        hills.servers.compactMap { server in
            if let id = server.connector, let known = Connector.catalog.first(where: { $0.id == id }) { return known }
            return Connector(id: server.connector ?? server.id, name: server.name, icon: "point.3.connected.trianglepath.dotted",
                             line: server.url, url: server.url, auth: .oauth, group: "自己加的", serverId: server.id)
        }
        .filter(matches)
    }

    private func matches(_ connector: Connector) -> Bool {
        let words = query.trimmingCharacters(in: .whitespaces).lowercased()
        return words.isEmpty || connector.name.lowercased().contains(words) || connector.line.lowercased().contains(words) || connector.group.contains(words)
    }

    private func server(of connector: Connector) -> Hills.Server? {
        if let id = connector.serverId { return hills.servers.first { $0.id == id } }
        return hills.servers.first { $0.connector == connector.id }
    }

    private func section(_ title: String, _ items: [Connector]) -> some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.inkSoft)
            ForEach(items) { item in
                let linked = server(of: item)
                card(icon: item.icon, name: item.name, line: item.line,
                     state: linked.map { hills.lastError[$0.id] != nil ? "出错了" : "已连上 · \(hills.tools(of: $0).count) 个工具" }) { opened = item }
            }
        }
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
                        Text(state ?? "没连").font(Ink.footnote).foregroundStyle(state == nil ? Ink.inkFaint : (state == "出错了" ? Ink.stop : Ink.ok)).lineLimit(1)
                    }
                    Text(line).font(Ink.footnote).foregroundStyle(Ink.inkSoft).multilineTextAlignment(.leading).lineLimit(2)
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

/// One MCP service in the catalog: where it is and how it lets Clio in.
struct Connector: Identifiable, Hashable {
    enum Auth: Hashable {
        /// Sign in on the service's own page.
        case oauth
        /// A key or token: put in the address as `?<query>=…`, or sent as a Bearer token when `query` is nil.
        case key(title: String, page: String, query: String?, steps: [String])
        /// Nothing to sign in to.
        case open
    }

    let id: String
    let name: String
    let icon: String
    let line: String
    let url: String
    let auth: Auth
    let group: String
    /// A service added by its address: the 远山 server it is.
    var serverId: String? = nil

    static let groups = ["地图与出行", "一个账号连一堆", "文档与办公", "设计", "开发", "查资料（不用登录）"]

    static let catalog: [Connector] = [
        Connector(id: "amap", name: "高德地图", icon: "map", line: "查地点、路线、天气、周边，算距离和到达时间", url: "https://mcp.amap.com/mcp",
                  auth: .key(title: "Web 服务 Key", page: "https://console.amap.com/dev/key/app", query: "key",
                             steps: ["登录高德开放平台控制台，进「应用管理 → 我的应用」，新建一个应用。",
                                     "在这个应用里点「添加 Key」，服务平台选「Web 服务」。",
                                     "把这个 Key 粘到下面。个人开发者每天有免费额度。"]), group: "地图与出行"),

        Connector(id: "rube", name: "Rube（Composio）", icon: "square.grid.3x3", line: "登录一次，再在它那里连 Gmail、谷歌日历和云盘、Slack 等几百个 App。数据会经过 Composio", url: "https://rube.app/mcp",
                  auth: .oauth, group: "一个账号连一堆"),
        Connector(id: "zapier", name: "Zapier", icon: "bolt.horizontal", line: "在 Zapier 里挑好要给的动作（发邮件、记表格…），每次调用扣 Zapier 的额度", url: "https://mcp.zapier.com/api/v1/connect",
                  auth: .key(title: "连接令牌", page: "https://mcp.zapier.com", query: nil,
                             steps: ["打开 mcp.zapier.com，新建一个 MCP 服务，AI 选「Other」。",
                                     "在里面加上你想让旅伴用的 App 和动作（比如 Gmail 发信）。",
                                     "到 Settings 生成令牌，只显示一次，复制粘到下面。"]), group: "一个账号连一堆"),

        Connector(id: "notion", name: "Notion", icon: "doc.text", line: "搜索、读写你的页面和数据库", url: "https://mcp.notion.com/mcp", auth: .oauth, group: "文档与办公"),
        Connector(id: "linear", name: "Linear", icon: "checklist", line: "查、建、改议题和项目", url: "https://mcp.linear.app/mcp", auth: .oauth, group: "文档与办公"),
        Connector(id: "atlassian", name: "Jira 与 Confluence", icon: "rectangle.3.group", line: "Atlassian：查改 Jira 议题，读写 Confluence 页面", url: "https://mcp.atlassian.com/v1/mcp", auth: .oauth, group: "文档与办公"),
        Connector(id: "asana", name: "Asana", icon: "circle.grid.cross", line: "任务、项目、负责人", url: "https://mcp.asana.com/v2/mcp", auth: .oauth, group: "文档与办公"),
        Connector(id: "monday", name: "monday.com", icon: "tablecells", line: "看板、条目和更新", url: "https://mcp.monday.com/mcp", auth: .oauth, group: "文档与办公"),
        Connector(id: "airtable", name: "Airtable", icon: "square.stack.3d.up", line: "读写你的表格和记录", url: "https://mcp.airtable.com/mcp", auth: .oauth, group: "文档与办公"),
        Connector(id: "box", name: "Box", icon: "shippingbox", line: "找、读 Box 云盘里的文件", url: "https://mcp.box.com", auth: .oauth, group: "文档与办公"),

        Connector(id: "canva", name: "Canva", icon: "paintpalette", line: "找设计、按模板生成设计、导出", url: "https://mcp.canva.com/mcp", auth: .oauth, group: "设计"),
        Connector(id: "figma", name: "Figma", icon: "pencil.and.ruler", line: "读设计稿的结构、样式和变量", url: "https://mcp.figma.com/mcp", auth: .oauth, group: "设计"),

        Connector(id: "github", name: "GitHub", icon: "chevron.left.forwardslash.chevron.right", line: "看仓库、代码、议题和合并请求，替你开议题", url: "https://api.githubcopilot.com/mcp/",
                  auth: .key(title: "个人访问令牌", page: "https://github.com/settings/personal-access-tokens/new", query: nil,
                             steps: ["在 GitHub 新建一个 Fine-grained 个人访问令牌。", "选好它能看的仓库和权限（只读最稳妥）。", "把令牌粘到下面。"]), group: "开发"),
        Connector(id: "sentry", name: "Sentry", icon: "ant", line: "查报错、问题和发布", url: "https://mcp.sentry.dev/mcp", auth: .oauth, group: "开发"),
        Connector(id: "vercel", name: "Vercel", icon: "triangle", line: "项目、部署和日志", url: "https://mcp.vercel.com", auth: .oauth, group: "开发"),
        Connector(id: "supabase", name: "Supabase", icon: "cylinder.split.1x2", line: "数据库表、查询和项目设置", url: "https://mcp.supabase.com/mcp", auth: .oauth, group: "开发"),
        Connector(id: "stripe", name: "Stripe", icon: "creditcard", line: "查客户、付款和订阅", url: "https://mcp.stripe.com", auth: .oauth, group: "开发"),

        Connector(id: "deepwiki", name: "DeepWiki", icon: "book.closed", line: "问任何公开 GitHub 仓库是怎么写的", url: "https://mcp.deepwiki.com/mcp", auth: .open, group: "查资料（不用登录）"),
        Connector(id: "context7", name: "Context7", icon: "books.vertical", line: "查各种编程库的最新文档", url: "https://mcp.context7.com/mcp", auth: .open, group: "查资料（不用登录）"),
        Connector(id: "mslearn", name: "Microsoft Learn", icon: "graduationcap", line: "查微软官方文档", url: "https://learn.microsoft.com/api/mcp", auth: .open, group: "查资料（不用登录）"),
        Connector(id: "cfdocs", name: "Cloudflare 文档", icon: "cloud", line: "查 Cloudflare 的文档", url: "https://docs.mcp.cloudflare.com/mcp", auth: .open, group: "查资料（不用登录）"),
        Connector(id: "huggingface", name: "Hugging Face", icon: "face.smiling", line: "找模型、数据集和论文", url: "https://huggingface.co/mcp", auth: .open, group: "查资料（不用登录）"),
    ]
}

/// Connecting one service: sign in, paste a key, or just connect; then what it brought.
private struct ConnectSheet: View {
    let connector: Connector
    @ObservedObject private var hills = Hills.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var key = ""
    @State private var busy = false
    @State private var result: String?

    private var server: Hills.Server? {
        if let id = connector.serverId { return hills.servers.first { $0.id == id } }
        return hills.servers.first { $0.connector == connector.id }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(connector.line).font(.system(size: 14))
                    Text(connector.url).font(.system(size: 12, design: .monospaced)).foregroundStyle(Ink.inkFaint).textSelection(.enabled)
                }
                switch connector.auth {
                case .oauth:
                    Section {
                        Button {
                            Task { await connect() }
                        } label: {
                            HStack {
                                Text(server == nil ? "登录 \(connector.name)" : "重新登录")
                                if busy { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(busy)
                    } footer: { footer(note: "会打开\(connector.name)自己的登录页，你在那边同意后回到 Clio。") }
                case .key(let title, let page, _, let steps):
                    Section {
                        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(index + 1)").font(.system(size: 13, weight: .bold)).foregroundStyle(Ink.accent).frame(width: 16)
                                Text(step).font(.system(size: 14))
                            }
                        }
                        Button("去拿\(title)") { if let url = URL(string: page) { openURL(url) } }
                    } header: { Text("怎么拿到\(title)") }
                    Section {
                        SecureField(server == nil ? "粘贴\(title)" : "已存好；要换就粘新的", text: $key)
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
                    } footer: { footer(note: nil) }
                case .open:
                    Section {
                        Button {
                            Task { await connect() }
                        } label: {
                            HStack {
                                Text(server == nil ? "连上" : "重新取一次工具")
                                if busy { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(busy)
                    } footer: { footer(note: "不用登录，公开可用。") }
                }

                if let server {
                    Section {
                        ForEach(hills.tools(of: server), id: \.name) { tool in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tool.name).font(.system(size: 14, weight: .medium, design: .monospaced))
                                Text(tool.description).font(.system(size: 12)).foregroundStyle(Ink.inkSoft).lineLimit(2)
                            }
                        }
                    } header: { Text("它带来的工具（\(hills.tools(of: server).count)）") }
                    Section {
                        Button("断开\(connector.name)", role: .destructive) {
                            hills.remove(server)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(connector.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("好了") { dismiss() } } }
        }
    }

    @ViewBuilder
    private func footer(note: String?) -> some View {
        if let result { Text(result) }
        else if let server, let problem = hills.lastError[server.id] { Text("上次出错：\(problem)").foregroundStyle(Ink.stop) }
        else if let note { Text(note) }
    }

    private func connect() async {
        busy = true
        defer { busy = false }
        var entry = server ?? Hills.Server(name: connector.name, url: connector.url)
        if connector.serverId == nil { entry.connector = connector.id }
        entry.enabled = true
        var token: String?
        if case .key(_, _, let query, _) = connector.auth {
            let typed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if !typed.isEmpty { token = query.map { "?\($0)=\(typed)" } ?? typed }
        }
        hills.save(entry, token: token)
        result = await Connecting.connect(entry, signIn: connector.auth == .oauth)
        if hills.lastError[entry.id] == nil {
            key = ""
            Haptics.grab()
        }
    }
}

/// Adding any MCP service by its address. Signs in by itself when the service asks for it.
private struct CustomSheet: View {
    @ObservedObject private var hills = Hills.shared
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = "https://"
    @State private var token = ""
    @State private var busy = false
    @State private var result: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("称呼，比如 公司的知识库", text: $name)
                    TextField("https://…/mcp", text: $url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("令牌（可以空着）", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text(result ?? "支持 Streamable HTTP 的 MCP 服务。令牌空着时，要登录的服务会自己弹出登录页。旧式只有 /sse 的地址暂时连不上。")
                }
                Section {
                    Button {
                        Task { await add() }
                    } label: {
                        HStack {
                            Text("连上")
                            if busy { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(busy || !url.hasPrefix("http") || url.count < 12)
                }
            }
            .navigationTitle("自己填地址")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("算了") { dismiss() } } }
        }
    }

    private func add() async {
        busy = true
        defer { busy = false }
        let address = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = name.trimmingCharacters(in: .whitespaces).isEmpty ? (URL(string: address)?.host ?? "MCP 服务") : name
        var entry = Hills.Server(name: title, url: address)
        entry.connector = "c" + String(entry.id.prefix(6)).lowercased().filter { $0.isLetter || $0.isNumber }
        let typed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        hills.save(entry, token: typed.isEmpty ? nil : typed)
        result = await Connecting.connect(entry, signIn: typed.isEmpty)
        if hills.lastError[entry.id] == nil { Haptics.grab(); dismiss() }
    }
}

/// Connecting a saved service: ask for its tools; if it wants a sign-in, sign in and ask again.
@MainActor
enum Connecting {
    static func connect(_ server: Hills.Server, signIn: Bool) async -> String {
        let hills = Hills.shared
        var count = await hills.refresh(server)
        let refused = hills.lastError[server.id].map { $0.contains("401") || $0.contains("403") || $0.lowercased().contains("unauthorized") } ?? false
        if count < 0, signIn, refused || !MCPAuth.signedIn(server.id) {
            do {
                try await MCPAuth.shared.login(server: server.id, url: server.url)
                count = await hills.refresh(server)
            } catch {
                hills.lastError[server.id] = error.localizedDescription
                return "没登录上：\(error.localizedDescription)"
            }
        }
        if count >= 0 { return "连上了，带来 \(count) 个工具。旅伴现在就能用。" }
        return "没连上：\(hills.lastError[server.id] ?? "不明原因")"
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
