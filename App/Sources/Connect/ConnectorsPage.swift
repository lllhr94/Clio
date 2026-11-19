import SwiftUI

/// 连接器, laid out the way other agent apps do it: a list where each service has a 「连接」 button right on
/// its row (signing in goes straight to the service's own page and comes back connected), and a detail page
/// behind the row with what it does, what it brought, and 断开.
struct ConnectorsPage: View {
    @ObservedObject private var hills = Hills.shared
    @ObservedObject private var google = Google.shared
    @ObservedObject private var work = ConnectorWork.shared
    @Environment(\.dismiss) private var dismiss
    @State private var googleOpen = false
    @State private var adding = false
    @State private var keyFor: Connector?
    @State private var query = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Ink.Space.xl) {
                    Text(Words.t("连上你的账号和服务，旅伴就能替你查邮件、改文档、规划路线。会改动东西的操作，旅伴会先问你。"))
                        .font(Ink.secondary).foregroundStyle(Ink.inkSoft)
                    if !mine.isEmpty { section("已连接", mine) }
                    if query.isEmpty || "谷歌 google gmail 邮件 云盘".contains(query.lowercased()) {
                        VStack(alignment: .leading, spacing: Ink.Space.s) {
                            heading("谷歌")
                            VStack(spacing: 0) { googleRow }.paperCard()
                        }
                    }
                    ForEach(Connector.groups, id: \.self) { group in
                        let items = Connector.catalog.filter { $0.group == group && matches($0) && work.server(of: $0) == nil }
                        if !items.isEmpty { section(group, items) }
                    }
                    Button {
                        Haptics.light()
                        adding = true
                    } label: {
                        Label("用地址添加连接器", systemImage: "plus")
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
            .navigationDestination(for: Connector.self) { ConnectorDetail(connector: $0) }
        }
        .sheet(item: $keyFor) { KeySheet(connector: $0) }
        .sheet(isPresented: $googleOpen) { GoogleSheet() }
        .sheet(isPresented: $adding) { CustomSheet() }
        .alert("没连上", isPresented: Binding(get: { work.failure != nil }, set: { if !$0 { work.failure = nil } })) {
            Button("好") { work.failure = nil }
        } message: { Text(work.failure ?? "") }
    }

    /// Everything connected: from the catalog, and the ones added by address.
    private var mine: [Connector] {
        hills.servers.compactMap { server in
            if let id = server.connector, let known = Connector.catalog.first(where: { $0.id == id }) { return known }
            return Connector(id: server.connector ?? server.id, name: server.name, icon: "point.3.connected.trianglepath.dotted",
                             line: URL(string: server.url)?.host ?? server.url, url: server.url, auth: .oauth, group: "自己加的", serverId: server.id)
        }
        .filter(matches)
    }

    private func matches(_ connector: Connector) -> Bool {
        let words = query.trimmingCharacters(in: .whitespaces).lowercased()
        return words.isEmpty || connector.name.lowercased().contains(words) || connector.line.lowercased().contains(words) || connector.group.contains(words)
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.inkSoft).padding(.leading, 4)
    }

    private func section(_ title: String, _ items: [Connector]) -> some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            heading(title)
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Rectangle().fill(Ink.rule).frame(height: 1).padding(.leading, 64) }
                    row(item)
                }
            }
            .paperCard()
        }
    }

    private func row(_ item: Connector) -> some View {
        HStack(spacing: Ink.Space.m) {
            NavigationLink(value: item) {
                HStack(spacing: Ink.Space.m) {
                    ConnectorIcon(symbol: item.icon)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(Ink.ink)
                        Text(item.line).font(Ink.footnote).foregroundStyle(Ink.inkSoft).lineLimit(2).multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            ConnectButton(connector: item) { keyFor = item }
        }
        .padding(.horizontal, Ink.Space.l)
        .padding(.vertical, Ink.Space.m)
    }

    private var googleRow: some View {
        Button {
            Haptics.light()
            googleOpen = true
        } label: {
            HStack(spacing: Ink.Space.m) {
                ConnectorIcon(symbol: "envelope.open")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Gmail 与云端硬盘").font(.system(size: 16, weight: .semibold)).foregroundStyle(Ink.ink)
                    Text(google.account ?? "用你自己的 Client ID 登录，不经过别人").font(Ink.footnote).foregroundStyle(Ink.inkSoft).lineLimit(1)
                }
                Spacer(minLength: 0)
                if google.connected { ConnectedMark() } else { Text("设置").font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.accent) }
            }
            .padding(.horizontal, Ink.Space.l)
            .padding(.vertical, Ink.Space.m)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The square with a service's symbol (never a company logo).
struct ConnectorIcon: View {
    let symbol: String
    var size: CGFloat = 40

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(Ink.accentWash)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol).font(.system(size: size * 0.44, weight: .medium)).foregroundStyle(Ink.accent)
            }
    }
}

private struct ConnectedMark: View {
    var body: some View {
        Label("已连接", systemImage: "checkmark.circle.fill")
            .labelStyle(.titleAndIcon)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Ink.ok)
    }
}

/// The 「连接」 on a row: signs in or connects right there; a service that needs a key asks for it first.
private struct ConnectButton: View {
    let connector: Connector
    var needsKey: () -> Void
    @ObservedObject private var work = ConnectorWork.shared

    var body: some View {
        if work.busy.contains(connector.id) {
            ProgressView().frame(width: 64)
        } else if let server = work.server(of: connector) {
            if Hills.shared.lastError[server.id] != nil {
                Text("出错了").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.stop)
            } else {
                ConnectedMark()
            }
        } else {
            Button {
                Haptics.light()
                if case .key = connector.auth { needsKey() } else { Task { await work.connect(connector) } }
            } label: {
                Text("连接")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Ink.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Ink.accentWash, in: .capsule)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("连接\(connector.name)")
        }
    }
}

/// Connecting and disconnecting, shared by the rows and the detail pages.
@MainActor
final class ConnectorWork: ObservableObject {
    static let shared = ConnectorWork()
    @Published private(set) var busy: Set<String> = []
    /// Shown as an alert on the list when a connect from a row failed.
    @Published var failure: String?

    func server(of connector: Connector) -> Hills.Server? {
        if let id = connector.serverId { return Hills.shared.servers.first { $0.id == id } }
        return Hills.shared.servers.first { $0.connector == connector.id }
    }

    /// Returns true when it ended connected.
    @discardableResult
    func connect(_ connector: Connector, key: String? = nil) async -> Bool {
        busy.insert(connector.id)
        defer { busy.remove(connector.id) }
        let hills = Hills.shared
        var entry = server(of: connector) ?? Hills.Server(name: connector.name, url: connector.url)
        if connector.serverId == nil { entry.connector = connector.id }
        entry.enabled = true
        var token: String?
        if case .key(_, _, let query, _) = connector.auth, let typed = key?.trimmingCharacters(in: .whitespacesAndNewlines), !typed.isEmpty {
            token = query.map { "?\($0)=\(typed)" } ?? typed
        }
        hills.save(entry, token: token)
        let said = await Connecting.connect(entry, signIn: connector.auth == .oauth)
        if hills.lastError[entry.id] == nil {
            Haptics.grab()
            return true
        }
        // A first connect that failed leaves nothing half-done behind.
        if token != nil || !MCPAuth.signedIn(entry.id) {
            if hills.tools(of: entry).isEmpty { hills.remove(entry) }
        }
        failure = said
        return false
    }

    func disconnect(_ connector: Connector) {
        guard let server = server(of: connector) else { return }
        Haptics.light()
        Hills.shared.remove(server)
    }
}

/// One connector's page: what it is, 连接 or 断开, and what it brought.
private struct ConnectorDetail: View {
    let connector: Connector
    @ObservedObject private var hills = Hills.shared
    @ObservedObject private var work = ConnectorWork.shared
    @Environment(\.dismiss) private var dismiss
    @State private var keying = false
    @State private var confirming = false

    private var server: Hills.Server? { work.server(of: connector) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Ink.Space.xl) {
                VStack(spacing: Ink.Space.m) {
                    ConnectorIcon(symbol: connector.icon, size: 72)
                    Text(connector.name).font(.system(size: 22, weight: .bold)).foregroundStyle(Ink.ink)
                    Text(URL(string: connector.url)?.host ?? connector.url).font(Ink.footnote).foregroundStyle(Ink.inkFaint)
                    primary
                    if let server, let problem = hills.lastError[server.id] {
                        Text(problem).font(Ink.footnote).foregroundStyle(Ink.stop).multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, Ink.Space.l)

                block("能做什么") {
                    Text(connector.line).font(Ink.secondary).foregroundStyle(Ink.ink)
                }
                block("怎么连") {
                    Text(howText).font(Ink.secondary).foregroundStyle(Ink.inkSoft)
                }
                block("会不会先问你") {
                    Text(Words.t("只读的工具（搜索、查看）旅伴直接用；会改动东西的（新建、修改、发送），每次先问你。可以在「应许 → 远山 · MCP」里整体调成不许或放行。"))
                        .font(Ink.secondary).foregroundStyle(Ink.inkSoft)
                }
                if let server {
                    let tools = hills.tools(of: server)
                    block("带来的工具（\(tools.count)）") {
                        VStack(alignment: .leading, spacing: Ink.Space.m) {
                            ForEach(tools, id: \.name) { tool in
                                HStack(alignment: .top, spacing: Ink.Space.s) {
                                    Image(systemName: tool.readOnly == true ? "eye" : "pencil")
                                        .font(.system(size: 12)).foregroundStyle(Ink.inkFaint).frame(width: 16).padding(.top, 2)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(tool.name).font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundStyle(Ink.ink)
                                        if !tool.description.isEmpty {
                                            Text(tool.description).font(.system(size: 12)).foregroundStyle(Ink.inkSoft).lineLimit(3)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Ink.Space.page)
            .padding(.bottom, Ink.Space.xxl)
        }
        .background(Ink.paper.ignoresSafeArea())
        .navigationTitle(connector.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $keying) { KeySheet(connector: connector) }
        .confirmationDialog("断开\(connector.name)？", isPresented: $confirming, titleVisibility: .visible) {
            Button("断开", role: .destructive) { work.disconnect(connector); dismiss() }
        } message: { Text(Words.t("旅伴就用不了它的工具了；登录凭据也会从这台手机删掉。")) }
    }

    @ViewBuilder
    private var primary: some View {
        if work.busy.contains(connector.id) {
            ProgressView().frame(height: 44)
        } else if server != nil {
            HStack(spacing: Ink.Space.m) {
                Button("重新连接") {
                    if case .key = connector.auth { keying = true } else { Task { await work.connect(connector) } }
                }
                .buttonStyle(.bordered)
                .tint(Ink.accent)
                Button("断开", role: .destructive) { confirming = true }
                    .buttonStyle(.bordered)
            }
            .controlSize(.large)
        } else {
            Button {
                Haptics.light()
                if case .key = connector.auth { keying = true } else { Task { await work.connect(connector) } }
            } label: {
                Text("连接").font(.system(size: 16, weight: .semibold)).frame(maxWidth: 240)
            }
            .buttonStyle(.borderedProminent)
            .tint(Ink.accent)
            .controlSize(.large)
        }
    }

    private var howText: String {
        switch connector.auth {
        case .oauth: "点「连接」会打开\(connector.name)自己的登录页，你在那边同意后自动回到 Clio。登录凭据只存在这台手机的钥匙串里，过期了会自己续。"
        case .key(let title, _, _, _): "要一个\(title)。点「连接」会告诉你去哪里拿，粘进来就好。"
        case .open: "公开的服务，不用登录，点「连接」就能用。"
        }
    }

    private func block<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.inkSoft)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Ink.Space.l)
                .paperCard()
        }
    }
}

/// For a service that takes a key: where to get it, the field, and 连接.
private struct KeySheet: View {
    let connector: Connector
    @ObservedObject private var work = ConnectorWork.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var key = ""

    var body: some View {
        if case .key(let title, let page, _, let steps) = connector.auth {
            NavigationStack {
                Form {
                    Section {
                        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(index + 1)").font(.system(size: 13, weight: .bold)).foregroundStyle(Ink.accent).frame(width: 16)
                                Text(step).font(.system(size: 14))
                            }
                        }
                        Button("去拿\(title)") { if let url = URL(string: page) { openURL(url) } }
                    }
                    Section {
                        SecureField("粘贴\(title)", text: $key)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
                .navigationTitle("连接\(connector.name)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("算了") { dismiss() } }
                    ToolbarItem(placement: .topBarTrailing) {
                        if work.busy.contains(connector.id) {
                            ProgressView()
                        } else {
                            Button("连接") {
                                Task { if await work.connect(connector, key: key) { dismiss() } }
                            }
                            .fontWeight(.semibold)
                            .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
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
        if count >= 0 { return Words.t("连上了，带来 \(count) 个工具。旅伴现在就能用。") }
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
                        Text(Words.t("旅伴能找、读你的 Gmail 和云端硬盘，能存邮件草稿；真要发信，每次都会先问你。"))
                            .font(.system(size: 13)).foregroundStyle(Ink.inkSoft)
                        Button("重新登录") { Task { await google.signIn() } }.disabled(google.busy)
                        Button("退出谷歌", role: .destructive) { google.signOut() }
                    } footer: {
                        Text(Words.t("谷歌把还在测试的应用的登录 7 天作废；到时旅伴会说登录过期，回这里点「重新登录」。"))
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
