import SwiftUI
import UIKit

/// 连接器, laid out the way other agent apps do it: categories along the top, one row per service, and a page
/// per service with a big sign-in button (or a key), a token as the other way in, and what it brought once connected.
struct ConnectorsPage: View {
    @ObservedObject private var hills = Hills.shared
    @ObservedObject private var google = Google.shared
    @ObservedObject private var work = ConnectorWork.shared
    @Environment(\.dismiss) private var dismiss
    @State private var googleOpen = false
    @State private var adding = false
    @State private var query = ""
    @State private var kind = "全部"
    @AppStorage("connectors.suggest") private var suggest = true
    /// Redrawn after a system permission question was answered.
    @State private var asked = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Ink.Space.xl) {
                    if query.isEmpty {
                        suggestCard
                        if kind == "全部" { onDevice }
                        categories
                    }
                    if !mine.isEmpty && kind == "全部" { section(L.t("connectors.connected"), mine) }
                    ForEach(Connector.groups.filter { kind == "全部" || $0 == kind }, id: \.self) { group in
                        let items = Connector.catalog.filter { $0.group == group && matches($0) && work.server(of: $0) == nil }
                        if !items.isEmpty { section(group, items) }
                    }
                    Button {
                        Haptics.light()
                        adding = true
                    } label: {
                        HStack(spacing: Ink.Space.m) {
                            Image(systemName: "plus").font(.system(size: Ink.Size.title, weight: .medium)).foregroundStyle(Ink.ink).frame(width: 40)
                            Text("添加自定义连接器").font(.system(size: Ink.Size.body)).foregroundStyle(Ink.ink)
                            Spacer()
                        }
                        .padding(.horizontal, Ink.Space.l)
                        .padding(.vertical, Ink.Space.l)
                        .paperCard()
                    }
                    .buttonStyle(PressStyle(haptic: false))
                    Text(Words.t("连上的服务，所有旅伴都能用；会改动东西的操作，旅伴会先问你。连接器是 MCP 服务，手机上只能用网址形式的；要在电脑上启动本地命令的那种，只能在电脑上用。"))
                        .font(Ink.footnote).foregroundStyle(Ink.inkFaint).padding(.horizontal, 4)
                }
                .padding(.horizontal, Ink.Space.page)
                .padding(.vertical, Ink.Space.l)
            }
            .background(Ink.paper.ignoresSafeArea())
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "找连接器")
            .navigationTitle(L.t("agent.connectors"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L.t("actions.done")) { dismiss() } } }
            .navigationDestination(for: Connector.self) { ConnectorDetail(connector: $0) }
        }
        .sheet(isPresented: $googleOpen) { GoogleSheet() }
        .sheet(isPresented: $adding) { CustomSheet() }
    }

    /// Clio's own suggestions: while talking, a companion may say which connector would help.
    private var suggestCard: some View {
        HStack(alignment: .top, spacing: Ink.Space.m) {
            IconBadge(symbol: "square.grid.2x2", tint: Ink.inkSoft)
            VStack(alignment: .leading, spacing: 3) {
                Text("连接器推荐").font(.system(size: Ink.Size.body)).foregroundStyle(Ink.ink)
                Text(Words.t("聊天时遇到某个连接器能帮上忙的事，旅伴会提一句，告诉你去哪里连。"))
                    .font(.system(size: Ink.Size.small)).foregroundStyle(Ink.inkSoft)
            }
            Spacer(minLength: 0)
            Toggle("连接器推荐", isOn: $suggest).labelsHidden().tint(Ink.accent)
        }
        .padding(Ink.Space.l)
        .paperCard()
    }

    /// What is on this phone itself, as connectors: the system permissions behind them, at a glance.
    private var onDevice: some View {
        let grants: [Grant] = [.health, .location, .calendar, .reminders, .contacts, .photos]
        return VStack(alignment: .leading, spacing: Ink.Space.s) {
            heading(L.t("connectors.onDevice"))
            VStack(spacing: 0) {
                ForEach(Array(grants.enumerated()), id: \.element) { index, grant in
                    if index > 0 { Kit.divider }
                    Button {
                        Haptics.light()
                        Task {
                            if grant.system == .notAsked { await grant.requestSystem() }
                            else if let url = URL(string: UIApplication.openSettingsURLString) { await UIApplication.shared.open(url) }
                            asked += 1
                        }
                    } label: {
                        RowLabel(grant.symbol, tint: Self.deviceTint(grant), title: grant.title, end: .valueChevron(deviceState(grant)))
                    }
                    .buttonStyle(PressStyle(haptic: false))
                }
            }
            .paperCard()
            .id(asked)
        }
    }

    private static func deviceTint(_ grant: Grant) -> Color {
        switch grant {
        case .health: Color(red: 0.95, green: 0.25, blue: 0.35)
        case .location: Color(red: 0.20, green: 0.48, blue: 0.95)
        case .calendar: Color(red: 0.92, green: 0.30, blue: 0.25)
        case .reminders: Color(red: 0.95, green: 0.55, blue: 0.15)
        case .contacts: Color(red: 0.45, green: 0.45, blue: 0.50)
        default: Color(red: 0.30, green: 0.65, blue: 0.40)
        }
    }

    private func deviceState(_ grant: Grant) -> String {
        if grant.policy == .off { return "在权限里关着" }
        switch grant.system {
        case .granted: return grant == .calendar || grant == .reminders ? "读取和写入" : "已允许"
        case .limited: return "部分允许"
        case .denied: return "被系统拒绝"
        case .notAsked: return "点一下允许"
        case .none: return "可用"
        }
    }

    private var categories: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Ink.Space.s) {
                ForEach(["全部"] + Connector.groups, id: \.self) { name in
                    Button {
                        Haptics.tick(0.4)
                        withAnimation(Ink.Motion.settle) { kind = name }
                    } label: {
                        Text(name)
                            .font(.system(size: Ink.Size.sub, weight: kind == name ? .semibold : .regular))
                            .foregroundStyle(kind == name ? Ink.paper : Ink.ink)
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .background(kind == name ? Ink.ink : Ink.paperRaised, in: .capsule)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .scrollIndicators(.hidden)
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
        SectionTitle(title)
    }

    private func section(_ title: String, _ items: [Connector]) -> some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            heading(title)
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Kit.divider }
                    NavigationLink(value: item) { row(item) }.buttonStyle(PressStyle(haptic: false))
                }
                // One Google, not two: the older way in (your own Client ID) is the last row of the same group.
                if title == "谷歌" {
                    Kit.divider
                    googleRow
                }
            }
            .paperCard()
        }
    }

    private func row(_ item: Connector) -> some View {
        let failed = work.server(of: item).map { hills.lastError[$0.id] != nil }
        return RowLabel(title: item.name, line: item.line, end: failed.map { RowEnd.valueChevron($0 ? "出错了" : "已连接", $0 ? Ink.stop : Ink.ok) } ?? RowEnd.chevron) {
            ConnectorIcon(connector: item)
        }
    }

    private var googleRow: some View {
        Button {
            Haptics.light()
            googleOpen = true
        } label: {
            RowLabel(title: "用自己的 Client ID 连", line: google.account ?? "备用：上面连不上时，用你自己的谷歌项目连 Gmail 和云盘", end: google.connected ? .valueChevron("已连接", Ink.ok) : .chevron) {
                ConnectorIcon(mark: "G", tint: Color(red: 0.30, green: 0.55, blue: 0.85), domain: "mail.google.com")
            }
        }
        .buttonStyle(PressStyle(haptic: false))
    }
}

/// A service's tile: its own colour and the first letter of its name. Never the company's logo.
struct ConnectorIcon: View {
    let mark: String
    let tint: Color
    var size: CGFloat = Kit.badge

    init(connector: Connector, size: CGFloat = Kit.badge) {
        mark = connector.mark
        tint = connector.tint
        domain = connector.domain
        self.size = size
    }

    init(mark: String, tint: Color, size: CGFloat = Kit.badge, domain: String? = nil) {
        self.mark = mark
        self.tint = tint
        self.size = size
        self.domain = domain
    }

    var domain: String? = nil

    var body: some View {
        BrandIcon(domain: domain, mark: mark, tint: tint, size: size)
    }
}

/// Connecting and disconnecting, shared by the pages.
@MainActor
final class ConnectorWork: ObservableObject {
    static let shared = ConnectorWork()
    @Published private(set) var busy: Set<String> = []

    func server(of connector: Connector) -> Hills.Server? {
        if let id = connector.serverId { return Hills.shared.servers.first { $0.id == id } }
        return Hills.shared.servers.first { $0.connector == connector.id }
    }

    /// Connects by signing in (`token` nil, for a service that signs in), or with a key or token.
    /// Returns nil when connected, or what went wrong.
    func connect(_ connector: Connector, token typed: String? = nil) async -> String? {
        busy.insert(connector.id)
        defer { busy.remove(connector.id) }
        let hills = Hills.shared
        var entry = server(of: connector) ?? Hills.Server(name: connector.name, url: connector.url)
        if connector.serverId == nil { entry.connector = connector.id }
        entry.enabled = true
        var token: String?
        if connector.auth == .google {
            token = Hills.googleToken
        } else if let typed = typed?.trimmingCharacters(in: .whitespacesAndNewlines), !typed.isEmpty {
            if case .key(_, _, let query, _) = connector.auth, let query { token = "?\(query)=\(typed)" } else { token = typed }
            MCPAuth.forget(entry.id)
        }
        hills.save(entry, token: token)
        let said = await Connecting.connect(entry, signIn: connector.auth == .oauth && token == nil)
        if hills.lastError[entry.id] == nil {
            Haptics.grab()
            return nil
        }
        // A first connect that failed leaves nothing half-done behind.
        if hills.tools(of: entry).isEmpty { hills.remove(entry) }
        return said
    }

    func disconnect(_ connector: Connector) {
        guard let server = server(of: connector) else { return }
        Haptics.light()
        Hills.shared.remove(server)
    }
}

/// One connector's page: big tile, status, the sign-in button (or a key), a token as the other way in,
/// and once connected what it brought and 断开.
private struct ConnectorDetail: View {
    let connector: Connector
    @ObservedObject private var hills = Hills.shared
    @ObservedObject private var work = ConnectorWork.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var token = ""
    @State private var problem: String?
    @State private var confirming = false
    @State private var googleOpen = false
    @ObservedObject private var google = Google.shared

    private var server: Hills.Server? { work.server(of: connector) }
    private var busy: Bool { work.busy.contains(connector.id) }

    var body: some View {
        ScrollView {
            VStack(spacing: Ink.Space.xl) {
                VStack(spacing: Ink.Space.s) {
                    ConnectorIcon(connector: connector, size: 92)
                        .padding(.bottom, Ink.Space.s)
                    Text(connector.name).font(.system(size: 24, weight: .bold)).foregroundStyle(Ink.ink)
                    Text(connector.line).font(.system(size: Ink.Size.sub)).foregroundStyle(Ink.inkSoft).multilineTextAlignment(.center)
                    status
                }
                .padding(.top, Ink.Space.xl)

                if server == nil { connectArea } else { connectedArea }
                details

                if let problem = problem ?? server.flatMap({ hills.lastError[$0.id] }) {
                    Text(problem).font(Ink.footnote).foregroundStyle(Ink.stop).multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, Ink.Space.page)
            .padding(.bottom, Ink.Space.xxl)
        }
        .background(Ink.paper.ignoresSafeArea())
        .navigationTitle(connector.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $googleOpen) { GoogleSheet() }
        .confirmationDialog("断开\(connector.name)？", isPresented: $confirming, titleVisibility: .visible) {
            Button("断开", role: .destructive) { work.disconnect(connector); dismiss() }
        } message: { Text(Words.t("旅伴就用不了它的工具了；登录凭据也会从这台手机删掉。")) }
    }

    /// 详情: what kind of service it is, how it lets Clio in, and its address.
    private var details: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle(L.t("connectors.details"))
            VStack(spacing: 0) {
                detailRow("类别", connector.group)
                Kit.rule(inset: Ink.Space.l)
                detailRow("登录", {
                    switch connector.auth {
                    case .oauth: return "在它的登录页登录"
                    case .key(let title, _, _, _): return "要一个\(title)"
                    case .open: return "不用"
                    case .google: return "用谷歌登录"
                    }
                }())
                Kit.rule(inset: Ink.Space.l)
                HStack(alignment: .top, spacing: Ink.Space.m) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("连接器地址").font(.system(size: Ink.Size.sub)).foregroundStyle(Ink.ink)
                        Text(connector.url).font(Ink.mono(Ink.Size.small)).foregroundStyle(Ink.inkSoft).textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                    Button {
                        UIPasteboard.general.string = connector.url
                        Haptics.tick(0.5)
                    } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: Ink.Size.sub)).foregroundStyle(Ink.inkSoft).frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("复制地址")
                }
                .padding(Ink.Space.l)
            }
            .paperCard()
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.system(size: Ink.Size.sub)).foregroundStyle(Ink.ink)
            Spacer()
            Text(value).font(.system(size: Ink.Size.sub)).foregroundStyle(Ink.inkSoft)
        }
        .padding(Ink.Space.l)
    }

    private var status: some View {
        let connected = server != nil && server.flatMap { hills.lastError[$0.id] } == nil
        return Text(server == nil ? "未连接" : (connected ? "已连接" : "出错了"))
            .font(.system(size: Ink.Size.small, weight: .medium))
            .foregroundStyle(server == nil ? Ink.inkSoft : (connected ? Ink.ok : Ink.stop))
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(Ink.paperRaised, in: .capsule)
            .padding(.top, 4)
    }

    private func bigButton(_ title: String, _ run: @escaping () -> Void) -> some View {
        Button {
            Haptics.light()
            run()
        } label: {
            ZStack {
                if busy { ProgressView().tint(Ink.paper) } else { Text(title).font(.system(size: Ink.Size.body, weight: .semibold)) }
            }
            .foregroundStyle(Ink.paper)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(Ink.ink, in: .capsule)
        }
        .buttonStyle(PressStyle(haptic: false))
        .disabled(busy)
    }

    @ViewBuilder
    private var connectArea: some View {
        switch connector.auth {
        case .oauth:
            VStack(spacing: Ink.Space.s) {
                bigButton("用 \(connector.name) 账号登录") { go(token: nil) }
                Text("会打开\(connector.name)的登录页，登录完回到这里。").font(Ink.footnote).foregroundStyle(Ink.inkSoft)
            }
            tokenBox(title: "或者粘贴令牌", placeholder: "访问令牌（Access Token）", page: connector.tokenPage)
        case .open:
            VStack(spacing: Ink.Space.s) {
                bigButton("连接") { go(token: nil) }
                Text("公开的服务，不用登录。").font(Ink.footnote).foregroundStyle(Ink.inkSoft)
            }
        case .google:
            VStack(spacing: Ink.Space.s) {
                if !google.connected || google.needsMoreScopes {
                    bigButton(google.connected ? "重新登录谷歌，授权新的权限" : "先登录谷歌") { googleOpen = true }
                } else {
                    bigButton("连接") { go(token: nil) }
                }
                Text("用的是谷歌官方的 MCP 服务，和 Claude 里的一样。手机直接连谷歌，用你在「谷歌」里的登录，不经过别人。")
                    .font(Ink.footnote).foregroundStyle(Ink.inkSoft).multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: Ink.Space.s) {
                SectionTitle(L.t("connectors.googleSetup"))
                Text("谷歌的官方 MCP 目前在开发者预览：你的 Google Cloud 项目要加入 Workspace Developer Preview，并启用这项 API 和对应的 MCP 服务（比如 gmail.googleapis.com 和 gmailmcp.googleapis.com）。没开的话，连接时会提示具体缺哪一项。")
                    .font(Ink.secondary).foregroundStyle(Ink.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Ink.Space.l)
                    .paperCard()
            }
        case .key(let title, let page, _, let steps):
            VStack(alignment: .leading, spacing: Ink.Space.m) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: Ink.Space.s) {
                        Text("\(index + 1)").font(.system(size: Ink.Size.small, weight: .bold)).foregroundStyle(Ink.accent).frame(width: 18)
                        Text(step).font(.system(size: Ink.Size.sub)).foregroundStyle(Ink.ink)
                    }
                }
                Button("去拿\(title)") { if let url = URL(string: page) { openURL(url) } }
                    .font(.system(size: Ink.Size.sub, weight: .semibold)).foregroundStyle(Ink.accent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Ink.Space.l)
            .paperCard()
            tokenBox(title: title, placeholder: "粘贴\(title)", page: nil)
        }
    }

    private func tokenBox(title: String, placeholder: String, page: String?) -> some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            HStack {
                Text(title).font(.system(size: Ink.Size.sub, weight: .semibold)).foregroundStyle(Ink.inkSoft)
                Spacer()
                if let page, let url = URL(string: page) {
                    Button("去生成") { openURL(url) }.font(.system(size: Ink.Size.small, weight: .semibold)).foregroundStyle(Ink.accent)
                }
            }
            .padding(.leading, 4)
            VStack(spacing: 0) {
                SecureField(placeholder, text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: Ink.Size.body))
                    .padding(Ink.Space.l)
                Kit.rule(inset: Ink.Space.l)
                Button {
                    go(token: token)
                } label: {
                    Text(connector.auth == .oauth ? "用令牌连接" : "连接")
                        .font(.system(size: Ink.Size.body, weight: .medium))
                        .foregroundStyle(token.trimmingCharacters(in: .whitespaces).isEmpty ? Ink.inkFaint : Ink.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Ink.Space.l)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(busy || token.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .paperCard()
        }
    }

    @ViewBuilder
    private var connectedArea: some View {
        if let server {
            let tools = hills.tools(of: server)
            VStack(alignment: .leading, spacing: Ink.Space.s) {
                SectionTitle("带来的工具（\(tools.count)）")
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(tools.enumerated()), id: \.element.name) { index, tool in
                        if index > 0 { Kit.rule(inset: 40) }
                        HStack(alignment: .top, spacing: Ink.Space.m) {
                            Image(systemName: tool.readOnly == true ? "eye" : "pencil")
                                .font(.system(size: Ink.Size.small)).foregroundStyle(Ink.inkFaint).frame(width: 18).padding(.top, 2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tool.name).font(Ink.mono(Ink.Size.sub, weight: .medium)).foregroundStyle(Ink.ink)
                                if !tool.description.isEmpty {
                                    Text(tool.description).font(.system(size: Ink.Size.small)).foregroundStyle(Ink.inkSoft).lineLimit(2)
                                }
                            }
                        }
                        .padding(.horizontal, Ink.Space.l)
                        .padding(.vertical, Ink.Space.m)
                    }
                }
                .paperCard()
                Text(Words.t("眼睛是只读的，旅伴直接用；笔是会改动东西的，每次先问你。"))
                    .font(Ink.footnote).foregroundStyle(Ink.inkFaint).padding(.leading, 4)
            }
            HStack(spacing: Ink.Space.m) {
                Button("重新连接") { go(token: nil) }
                    .buttonStyle(.bordered).tint(Ink.accent)
                Button("断开", role: .destructive) { confirming = true }
                    .buttonStyle(.bordered)
            }
            .controlSize(.large)
            .disabled(busy)
        }
    }

    private func go(token: String?) {
        problem = nil
        Task {
            problem = await work.connect(connector, token: token)
            if problem == nil { self.token = "" }
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
        /// Google's official MCP services: the Google sign-in on this page.
        case google
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
    /// Where to make a token, for connecting without signing in.
    var tokenPage: String? = nil

    init(id: String, name: String, icon: String, line: String, url: String, auth: Auth, group: String, serverId: String? = nil, tokenPage: String? = nil) {
        self.id = id; self.name = name; self.icon = icon; self.line = line; self.url = url
        self.auth = auth; self.group = group; self.serverId = serverId; self.tokenPage = tokenPage
    }

    /// Where its icon is fetched from (see `BrandIcon`).
    var domain: String? {
        let known: [String: String] = [
            "amap": "amap.com", "rube": "rube.app", "zapier": "zapier.com", "notion": "notion.so", "linear": "linear.app",
            "atlassian": "atlassian.com", "asana": "asana.com", "monday": "monday.com", "airtable": "airtable.com", "box": "box.com",
            "canva": "canva.com", "figma": "figma.com", "github": "github.com", "sentry": "sentry.io", "vercel": "vercel.com",
            "supabase": "supabase.com", "stripe": "stripe.com", "cloudflare": "cloudflare.com", "netlify": "netlify.com",
            "neon": "neon.tech", "exa": "exa.ai", "wolfram": "wolframalpha.com", "deepwiki": "deepwiki.com",
            "context7": "context7.com", "mslearn": "learn.microsoft.com", "cfdocs": "developers.cloudflare.com",
            "huggingface": "huggingface.co", "g-gmail": "mail.google.com", "g-drive": "drive.google.com",
            "g-calendar": "calendar.google.com", "g-docs": "docs.google.com", "g-sheets": "sheets.google.com",
            "g-slides": "slides.google.com",
        ]
        if let found = known[id] { return found }
        return URL(string: url)?.host
    }

    /// The letter on its tile until (or unless) its icon arrives: 「N」, 「高」.
    var mark: String {
        let first = name.first.map(String.init) ?? "?"
        return first.uppercased()
    }

    /// A colour of its own, the same every time.
    var tint: Color {
        let colors: [Color] = [
            Color(red: 0.36, green: 0.42, blue: 0.86), Color(red: 0.89, green: 0.49, blue: 0.27), Color(red: 0.25, green: 0.66, blue: 0.62),
            Color(red: 0.72, green: 0.36, blue: 0.62), Color(red: 0.30, green: 0.55, blue: 0.85), Color(red: 0.46, green: 0.62, blue: 0.30),
            Color(red: 0.80, green: 0.36, blue: 0.38), Color(red: 0.55, green: 0.45, blue: 0.80), Color(red: 0.20, green: 0.24, blue: 0.30),
        ]
        let sum = id.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return colors[sum % colors.count]
    }

    static let groups = ["谷歌", "开发", "文档与资料", "协作办公", "设计", "地图与出行", "搜索与查资料", "一个账号连一堆"]

    static let catalog: [Connector] = [
        Connector(id: "g-gmail", name: "Gmail", icon: "envelope", line: "找信、读整串邮件、写草稿", url: "https://gmailmcp.googleapis.com/mcp/v1", auth: .google, group: "谷歌"),
        Connector(id: "g-drive", name: "Google 云端硬盘", icon: "externaldrive", line: "找文件、读文件内容", url: "https://drivemcp.googleapis.com/mcp/v1", auth: .google, group: "谷歌"),
        Connector(id: "g-calendar", name: "Google 日历", icon: "calendar", line: "查日程、空闲时间，建活动", url: "https://calendarmcp.googleapis.com/mcp/v1", auth: .google, group: "谷歌"),
        Connector(id: "g-docs", name: "Google 文档", icon: "doc.text", line: "读写文档", url: "https://docsmcp.googleapis.com/mcp/v1", auth: .google, group: "谷歌"),
        Connector(id: "g-sheets", name: "Google 表格", icon: "tablecells", line: "读写表格", url: "https://sheetsmcp.googleapis.com/mcp/v1", auth: .google, group: "谷歌"),
        Connector(id: "g-slides", name: "Google 幻灯片", icon: "rectangle.on.rectangle", line: "读写演示文稿", url: "https://slidesmcp.googleapis.com/mcp/v1", auth: .google, group: "谷歌"),
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

        Connector(id: "notion", name: "Notion", icon: "doc.text", line: "搜索、读写你的页面和数据库", url: "https://mcp.notion.com/mcp", auth: .oauth, group: "文档与资料"),
        Connector(id: "linear", name: "Linear", icon: "checklist", line: "查、建、改议题和项目", url: "https://mcp.linear.app/mcp", auth: .oauth, group: "协作办公"),
        Connector(id: "atlassian", name: "Jira 与 Confluence", icon: "rectangle.3.group", line: "Atlassian：查改 Jira 议题，读写 Confluence 页面", url: "https://mcp.atlassian.com/v1/mcp", auth: .oauth, group: "协作办公"),
        Connector(id: "asana", name: "Asana", icon: "circle.grid.cross", line: "任务、项目、负责人", url: "https://mcp.asana.com/v2/mcp", auth: .oauth, group: "协作办公"),
        Connector(id: "monday", name: "monday.com", icon: "tablecells", line: "看板、条目和更新", url: "https://mcp.monday.com/mcp", auth: .oauth, group: "协作办公"),
        Connector(id: "airtable", name: "Airtable", icon: "square.stack.3d.up", line: "读写你的表格和记录", url: "https://mcp.airtable.com/mcp", auth: .oauth, group: "文档与资料"),
        Connector(id: "box", name: "Box", icon: "shippingbox", line: "找、读 Box 云盘里的文件", url: "https://mcp.box.com", auth: .oauth, group: "文档与资料"),

        Connector(id: "canva", name: "Canva", icon: "paintpalette", line: "找设计、按模板生成设计、导出", url: "https://mcp.canva.com/mcp", auth: .oauth, group: "设计"),
        Connector(id: "figma", name: "Figma", icon: "pencil.and.ruler", line: "读设计稿的结构、样式和变量", url: "https://mcp.figma.com/mcp", auth: .oauth, group: "设计"),

        Connector(id: "github", name: "GitHub", icon: "chevron.left.forwardslash.chevron.right", line: "仓库、代码、Issue 和拉取请求", url: "https://api.githubcopilot.com/mcp/",
                  auth: .oauth, group: "开发", tokenPage: "https://github.com/settings/personal-access-tokens/new"),
        Connector(id: "sentry", name: "Sentry", icon: "ant", line: "查报错、问题和发布", url: "https://mcp.sentry.dev/mcp", auth: .oauth, group: "开发"),
        Connector(id: "vercel", name: "Vercel", icon: "triangle", line: "项目、部署和日志", url: "https://mcp.vercel.com", auth: .oauth, group: "开发"),
        Connector(id: "supabase", name: "Supabase", icon: "cylinder.split.1x2", line: "数据库表、查询和项目设置", url: "https://mcp.supabase.com/mcp", auth: .oauth, group: "开发"),
        Connector(id: "stripe", name: "Stripe", icon: "creditcard", line: "查客户、付款和订阅", url: "https://mcp.stripe.com", auth: .oauth, group: "开发"),

        Connector(id: "cloudflare", name: "Cloudflare", icon: "cloud", line: "Workers、KV、R2 和 D1", url: "https://bindings.mcp.cloudflare.com/mcp", auth: .oauth, group: "开发"),
        Connector(id: "netlify", name: "Netlify", icon: "globe", line: "站点、部署和表单", url: "https://netlify-mcp.netlify.app/mcp", auth: .oauth, group: "开发"),
        Connector(id: "neon", name: "Neon", icon: "cylinder", line: "Postgres 数据库、分支和查询", url: "https://mcp.neon.tech/mcp", auth: .oauth, group: "开发"),
        Connector(id: "exa", name: "Exa", icon: "magnifyingglass", line: "给智能体用的网页搜索，不用登录", url: "https://mcp.exa.ai/mcp", auth: .open, group: "搜索与查资料"),
        Connector(id: "wolfram", name: "Wolfram", icon: "function", line: "算数学、查数据和单位换算，不用登录", url: "https://agenttools.wolfram.com/mcp", auth: .open, group: "搜索与查资料"),
        Connector(id: "deepwiki", name: "DeepWiki", icon: "book.closed", line: "问任何公开 GitHub 仓库是怎么写的", url: "https://mcp.deepwiki.com/mcp", auth: .open, group: "搜索与查资料"),
        Connector(id: "context7", name: "Context7", icon: "books.vertical", line: "查各种编程库的最新文档", url: "https://mcp.context7.com/mcp", auth: .open, group: "搜索与查资料"),
        Connector(id: "mslearn", name: "Microsoft Learn", icon: "graduationcap", line: "查微软官方文档", url: "https://learn.microsoft.com/api/mcp", auth: .open, group: "搜索与查资料"),
        Connector(id: "cfdocs", name: "Cloudflare 文档", icon: "cloud", line: "查 Cloudflare 的文档", url: "https://docs.mcp.cloudflare.com/mcp", auth: .open, group: "搜索与查资料"),
        Connector(id: "huggingface", name: "Hugging Face", icon: "face.smiling", line: "找模型、数据集和论文", url: "https://huggingface.co/mcp", auth: .open, group: "搜索与查资料"),
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
            .navigationTitle(L.t("connectors.customAddress"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button(L.t("actions.cancel")) { dismiss() } } }
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
                        if google.needsMoreScopes {
                            Text("Clio 现在能连更多谷歌服务（日历、文档、表格、幻灯片），要重新登录一次授权。")
                                .font(.system(size: Ink.Size.small)).foregroundStyle(Ink.warn)
                        }
                        Text(Words.t("旅伴能找、读你的 Gmail 和云端硬盘，能存邮件草稿；真要发信，每次都会先问你。"))
                            .font(.system(size: Ink.Size.small)).foregroundStyle(Ink.inkSoft)
                        Button("重新登录") { Task { await google.signIn() } }.disabled(google.busy)
                        Button("退出谷歌", role: .destructive) { google.signOut() }
                    } footer: {
                        Text(Words.t("谷歌把还在测试的应用的登录 7 天作废；到时旅伴会说登录过期，回这里点「重新登录」。"))
                    }
                } else {
                    Section {
                        step(1, "打开 Google Cloud 控制台，新建一个项目（名字随意）。")
                        step(2, "「API 和服务 → 库」里启用要用的：Gmail、Google Drive、Calendar、Docs、Sheets、Slides 的 API。想用谷歌官方连接器，还要启用对应的 MCP 服务（gmailmcp、drivemcp…），项目需加入 Workspace Developer Preview。")
                        step(3, "「OAuth 同意屏幕」：用户类型选「外部」，把你自己的 Gmail 加进「测试用户」。")
                        step(4, "「凭据 → 创建凭据 → OAuth 客户端 ID」，应用类型选「iOS」，软件包 ID 填 io.github.lllhr94.clio。")
                        step(5, "复制生成的客户端 ID，粘到下面，点登录。")
                        Button("打开 Google Cloud 控制台") { if let url = URL(string: "https://console.cloud.google.com/apis/credentials") { openURL(url) } }
                    } header: { Text(L.t("connectors.googleCredentials")) } footer: {
                        Text("Clio 不经过任何别人的服务器：手机直接向谷歌登录，令牌只存在钥匙串里。")
                    }
                    Section {
                        TextField("xxxx.apps.googleusercontent.com", text: $client)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(Ink.mono(Ink.Size.sub))
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
                    } header: { Text(L.t("connectors.clientId")) } footer: {
                        if let problem = google.problem { Text(problem).foregroundStyle(Ink.stop) }
                    }
                }
            }
            .navigationTitle(L.t("connectors.google"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L.t("actions.done")) { dismiss() } } }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)").font(.system(size: Ink.Size.small, weight: .bold)).foregroundStyle(Ink.accent).frame(width: 16)
            Text(text).font(.system(size: Ink.Size.sub))
        }
    }
}
