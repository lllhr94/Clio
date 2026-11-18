import SwiftUI

/// 远山: the computers far away, and the tools borrowed from them.
struct HillsPage: View {
    @ObservedObject var hills = Hills.shared
    @Environment(\.dismiss) private var dismiss
    @State private var editingHost: Hills.Host?
    @State private var editingServer: Hills.Server?
    @State private var testing: String?
    @State private var tested: [String: String] = [:]
    @State private var refreshing: String?
    @State private var copied = false
    @State private var terminalHost: Hills.Host?
    @State private var browserAsk: Hills.Host?
    /// Host id → what the browser installation is doing now.
    @State private var installing: [String: String] = [:]

    var body: some View {
        NavigationStack {
            ZStack {
                Ink.paper.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: Ink.Space.xl) {
                        Text("远山是你在别处的电脑：用 SSH 连的主机，和提供 MCP 工具的服务（比如你 VPS 上的浏览器）。旅伴连远山前，默认会先请你落印，可以在「应许」里改。")
                            .font(Ink.secondary)
                            .foregroundStyle(Ink.inkSoft)

                        section("主机", add: { editingHost = Hills.Host(name: "", address: "", user: "root") }) {
                            if hills.hosts.isEmpty {
                                empty("还没有主机。加一台 VPS 或家里的电脑。")
                            }
                            ForEach(hills.hosts) { host in
                                hostRow(host)
                                if host.id != hills.hosts.last?.id { divider }
                            }
                        }

                        VStack(alignment: .leading, spacing: Ink.Space.s) {
                            Text("这台手机的钥匙").font(Ink.serif(15, bold: true)).foregroundStyle(Ink.inkSoft).padding(.leading, Ink.Space.xs)
                            VStack(alignment: .leading, spacing: Ink.Space.m) {
                                Text("用钥匙登录更安全。把下面这行加进服务器的 ~/.ssh/authorized_keys，主机里选「用钥匙」。")
                                    .font(Ink.footnote).foregroundStyle(Ink.inkSoft)
                                Text(Hills.publicKey)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(Ink.ink)
                                    .textSelection(.enabled)
                                    .lineLimit(3)
                                Button {
                                    UIPasteboard.general.string = Hills.publicKey
                                    Haptics.tick(0.6)
                                    copied = true
                                } label: {
                                    Label(copied ? "复制好了" : "复制公钥", systemImage: copied ? "checkmark" : "doc.on.doc")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(Ink.accent)
                                }
                                .buttonStyle(PressStyle())
                            }
                            .padding(Ink.Space.l)
                            .paperCard()
                        }

                        section("MCP 服务", add: { editingServer = Hills.Server(name: "", url: "https://") }) {
                            if hills.servers.isEmpty {
                                empty("还没有。填一个 MCP 服务地址（Streamable HTTP），它的工具就会借给旅伴用。")
                            }
                            ForEach(hills.servers) { server in
                                serverRow(server)
                                if server.id != hills.servers.last?.id { divider }
                            }
                        }
                    }
                    .padding(.horizontal, Ink.Space.page)
                    .padding(.vertical, Ink.Space.l)
                }
            }
            .navigationTitle("远山")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("好了") { dismiss() } } }
            .sheet(item: $editingHost) { host in HostEditor(host: host) }
            .sheet(item: $editingServer) { server in ServerEditor(server: server) }
            .fullScreenCover(item: $terminalHost) { host in InkstonePage(hill: host) }
            .alert("在\(browserAsk?.name ?? "")上装一个浏览器？", isPresented: Binding(get: { browserAsk != nil }, set: { if !$0 { browserAsk = nil } })) {
                Button("开始装") { if let host = browserAsk { installBrowser(host) } }
                Button("算了", role: .cancel) {}
            } message: {
                Text("会装上 Node.js、Playwright 的 MCP 服务和 Chromium（大约 400 MB，要几分钟），再在 \(Hills.browserPort) 端口开一个要令牌才能进的门，最后自动接进下面的 MCP 服务。\n\n门走 https，用那台电脑自己做的证书；手机经 SSH 读到证书指纹，只认这一张，别人冒充不了。\n\n需要 root 或免密 sudo。云服务器记得在安全组里放行 \(Hills.browserPort) 端口。")
            }
            .task { resumeInstalls() }
        }
    }

    private var divider: some View { Rectangle().fill(Ink.rule).frame(height: 1).padding(.leading, Ink.Space.l) }

    private func empty(_ text: String) -> some View {
        Text(text).font(Ink.footnote).foregroundStyle(Ink.inkFaint).padding(Ink.Space.l).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func section<Content: View>(_ title: String, add: @escaping () -> Void, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            HStack {
                Text(title).font(Ink.serif(15, bold: true)).foregroundStyle(Ink.inkSoft)
                Spacer()
                Button { Haptics.light(); add() } label: { Image(systemName: "plus").font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.accent) }
                    .accessibilityLabel("添加")
            }
            .padding(.horizontal, Ink.Space.xs)
            VStack(spacing: 0) { content() }.paperCard()
        }
    }

    private func hostRow(_ host: Hills.Host) -> some View {
        VStack(alignment: .leading, spacing: Ink.Space.xs) {
            HStack {
                Image(systemName: "server.rack").foregroundStyle(Ink.accent).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(host.name).font(.system(size: 16, weight: .medium)).foregroundStyle(Ink.ink)
                    Text("\(host.user)@\(host.address):\(host.port) · \(host.useKey ? "钥匙" : "密码")").font(Ink.footnote).foregroundStyle(Ink.inkSoft)
                }
                Spacer()
                Button(testing == host.id ? "在连…" : "试连") { test(host) }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Ink.accent)
                    .disabled(testing != nil)
            }
            if let key = HostKeyKeeper.known(host.address, host.port) {
                HStack(spacing: Ink.Space.s) {
                    Text("指纹 " + HostKeyKeeper.fingerprint(key)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Ink.inkFaint).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button("重新信任") {
                        HostKeyKeeper.forget(host.address, host.port)
                        tested[host.id] = "已忘掉旧指纹，下次连接时记住新的。"
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Ink.accent)
                }
                .padding(.leading, 32)
            }
            if let result = tested[host.id] {
                Text(result).font(.system(size: 12, design: .monospaced)).foregroundStyle(Ink.inkSoft).lineLimit(4).padding(.leading, 32)
            }
            HStack(spacing: Ink.Space.s) {
                Button {
                    Haptics.light()
                    terminalHost = host
                } label: {
                    Label("笔砚", systemImage: "terminal").font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.bordered)
                .tint(Ink.accent)
                Button {
                    Haptics.light()
                    browserAsk = host
                } label: {
                    Label(installing[host.id] == nil ? "装浏览器" : "在装…", systemImage: "safari").font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.bordered)
                .tint(Ink.accent)
                .disabled(installing[host.id] != nil)
            }
            .padding(.leading, 32)
            .padding(.top, 2)
            if let status = installing[host.id] {
                HStack(alignment: .top, spacing: Ink.Space.s) {
                    ProgressView().controlSize(.mini)
                    Text(status).font(.system(size: 12, design: .monospaced)).foregroundStyle(Ink.inkSoft).lineLimit(3)
                }
                .padding(.leading, 32)
            }
        }
        .padding(Ink.Space.l)
        .contentShape(Rectangle())
        .onTapGesture { editingHost = host }
        .contextMenu { Button("删掉", systemImage: "trash", role: .destructive) { hills.remove(host) } }
    }

    private func serverRow(_ server: Hills.Server) -> some View {
        let tools = hills.tools(of: server)
        return VStack(alignment: .leading, spacing: Ink.Space.xs) {
            HStack {
                Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(Ink.accent).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name).font(.system(size: 16, weight: .medium)).foregroundStyle(Ink.ink)
                    Text(server.url).font(Ink.footnote).foregroundStyle(Ink.inkSoft).lineLimit(1)
                }
                Spacer()
                Button(refreshing == server.id ? "在问…" : "连接") {
                    refreshing = server.id
                    Task {
                        await hills.refresh(server)
                        refreshing = nil
                    }
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Ink.accent)
                .disabled(refreshing != nil)
            }
            if let error = hills.lastError[server.id] {
                Text(error).font(Ink.footnote).foregroundStyle(Ink.stop).padding(.leading, 32)
            } else if !tools.isEmpty {
                Text("借来 \(tools.count) 件工具：" + tools.prefix(8).map(\.name).joined(separator: "、") + (tools.count > 8 ? "…" : ""))
                    .font(Ink.footnote).foregroundStyle(Ink.inkSoft).padding(.leading, 32)
            }
        }
        .padding(Ink.Space.l)
        .contentShape(Rectangle())
        .onTapGesture { editingServer = server }
        .contextMenu { Button("删掉", systemImage: "trash", role: .destructive) { hills.remove(server) } }
    }

    // MARK: A browser on the far computer

    private static func installKey(_ host: Hills.Host) -> String { "hill.browserJob.\(host.id)" }

    private func installBrowser(_ host: Hills.Host) {
        let token = (0..<4).map { _ in UUID().uuidString.replacingOccurrences(of: "-", with: "") }.joined().lowercased().prefix(48)
        installing[host.id] = "开始…"
        Task {
            do {
                let job = try await Hills.startJob(Hills.browserInstallScript(token: String(token)), on: host)
                Vault.save(String(token), as: "hill.browserToken.\(host.id)")
                UserDefaults.standard.set(job, forKey: Self.installKey(host))
                await follow(job, on: host)
            } catch {
                installing[host.id] = nil
                tested[host.id] = "没能开始装：\(error.localizedDescription)"
                Haptics.lock()
            }
        }
    }

    /// Picks up installs that were still going when the page was closed.
    private func resumeInstalls() {
        for host in hills.hosts {
            guard installing[host.id] == nil, let job = UserDefaults.standard.string(forKey: Self.installKey(host)) else { continue }
            installing[host.id] = "接着看安装进度…"
            Task { await follow(job, on: host) }
        }
    }

    private func follow(_ job: String, on host: Hills.Host) async {
        while !Task.isCancelled {
            do {
                let state = try await Hills.checkJob(job, on: host, lines: 6)
                let last = state.tail.split(separator: "\n").last.map(String.init) ?? ""
                if state.running {
                    installing[host.id] = last.isEmpty ? "在装…" : last
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    continue
                }
                UserDefaults.standard.removeObject(forKey: Self.installKey(host))
                installing[host.id] = nil
                guard state.exit == 0 else {
                    tested[host.id] = "没装成（退出码 \(state.exit.map(String.init) ?? "不明")）：\n" + state.tail.split(separator: "\n").suffix(3).joined(separator: "\n")
                    Haptics.lock()
                    return
                }
                let token = Vault.load(String.self, key: "hill.browserToken.\(host.id)")
                guard let pin = try? await Hills.browserPin(on: host) else {
                    tested[host.id] = "装好了，但读不到证书指纹（~/.clio/browser/cert.pem）。在笔砚里看看 openssl 在不在。"
                    Haptics.lock()
                    return
                }
                let url = "https://\(host.address):\(Hills.browserPort)/mcp"
                var server = hills.servers.first { $0.url == url || $0.url == "http://\(host.address):\(Hills.browserPort)/mcp" } ?? Hills.Server(name: "\(host.name) 的浏览器", url: url)
                server.url = url
                server.pin = pin
                server.enabled = true
                hills.save(server, token: token)
                let count = await hills.refresh(server)
                tested[host.id] = count > 0
                    ? "浏览器装好了，借来 \(count) 件工具，已经接进 MCP 服务。"
                    : "装好了，但连不上 \(url)。多半是安全组或防火墙没放行 \(Hills.browserPort) 端口。放行后在下面点「连接」。"
                Haptics.thud()
                return
            } catch {
                installing[host.id] = "暂时看不到进度：\(error.localizedDescription)"
                try? await Task.sleep(nanoseconds: 8_000_000_000)
            }
        }
    }

    private func test(_ host: Hills.Host) {
        testing = host.id
        tested[host.id] = nil
        Task {
            do {
                let result = try await Hills.run("uname -a; uptime", on: host, timeout: 25)
                tested[host.id] = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                Haptics.thud()
            } catch {
                tested[host.id] = "连不上：\(error.localizedDescription)"
                Haptics.lock()
            }
            testing = nil
        }
    }
}

private struct HostEditor: View {
    @State var host: Hills.Host
    @State private var password = ""
    @State private var port = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                PaperRows {
                Section("称呼") { TextField("比如：香港 VPS", text: $host.name) }
                Section("地址") {
                    TextField("域名或 IP", text: $host.address).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("端口", text: $port).keyboardType(.numberPad)
                    TextField("用户名", text: $host.user).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section {
                    Picker("登录方式", selection: $host.useKey) {
                        Text("密码").tag(false)
                        Text("用钥匙").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if !host.useKey {
                        SecureField(Vault.load(String.self, key: "hill.\(host.id)") == nil ? "密码" : "密码（已存，不改就留空）", text: $password)
                    }
                } footer: {
                    Text(host.useKey ? "记得先把「远山」页里的公钥加到服务器上。" : "密码只存在这台手机的钥匙串里。")
                }
            }
            }
            .paperForm()
            .navigationTitle(host.name.isEmpty ? "新主机" : host.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("算了") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("存好") {
                        host.port = Int(port) ?? 22
                        if host.name.trimmingCharacters(in: .whitespaces).isEmpty { host.name = host.address }
                        Hills.shared.save(host, password: password.isEmpty ? nil : password)
                        Haptics.thud()
                        dismiss()
                    }
                    .disabled(host.address.trimmingCharacters(in: .whitespaces).isEmpty || host.user.isEmpty)
                }
            }
            .onAppear { port = String(host.port) }
        }
    }
}

private struct ServerEditor: View {
    @State var server: Hills.Server
    @State private var token = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                PaperRows {
                Section("称呼") { TextField("比如：VPS 浏览器", text: $server.name) }
                Section {
                    TextField("https://…/mcp", text: $server.url).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    SecureField(Vault.load(String.self, key: "mcp.\(server.id)") == nil ? "令牌（可不填）" : "令牌（已存，不改就留空）", text: $token)
                } header: { Text("地址") } footer: {
                    Text("支持 Streamable HTTP 的 MCP 服务。令牌会作为 Authorization: Bearer 发送。")
                }
                Section { Toggle("借给旅伴用", isOn: $server.enabled) }
            }
            }
            .paperForm()
            .navigationTitle(server.name.isEmpty ? "新 MCP 服务" : server.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("算了") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("存好") {
                        if server.name.trimmingCharacters(in: .whitespaces).isEmpty { server.name = URL(string: server.url)?.host() ?? "MCP" }
                        Hills.shared.save(server, token: token.isEmpty ? nil : token)
                        let saved = server
                        Task { await Hills.shared.refresh(saved) }
                        Haptics.thud()
                        dismiss()
                    }
                    .disabled(URL(string: server.url)?.host() == nil)
                }
            }
        }
    }
}
