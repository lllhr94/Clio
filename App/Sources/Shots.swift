import Craft
import SwiftUI
import UIKit

/// Screenshots for checking the look without a phone: CI launches Clio in the simulator with `-clioShot <screen>`
/// (the argument lands in UserDefaults), Clio fills in the demo and opens that screen, and CI takes the picture.
enum Shots {
    static var name: String? { UserDefaults.standard.string(forKey: "clioShot") }

    static var startsInChat: Bool {
        switch name {
        case "chat", "sidebar", "sidebar-past", "newchat", "plan", "model-error": true
        default: name?.hasPrefix("chat-") == true
        }
    }

    /// Scenes that need more than the opening picture: a long conversation, one jumped back to its foot, one with a
    /// reply arriving. They wait `clioShotDelay` seconds after the first frames before saying they are ready.
    static var delay: Double { UserDefaults.standard.double(forKey: "clioShotDelay") }

    enum StreamStage: String { case midway, finished }

    static var streamStage: StreamStage? {
        UserDefaults.standard.string(forKey: "clioShotStream").flatMap(StreamStage.init(rawValue:))
    }

    static var readyToken: String? { UserDefaults.standard.string(forKey: "clioShotToken") }
}

/// Draw the requested settings or workbench page directly, so CI and local device QA can inspect every screen.
struct ShotSettingsPage: View {
    let name: String
    @ObservedObject var team: TeamModel

    static let names: Set<String> = [
        "settings", "connectors", "look", "stops", "grants", "add", "pet",
        "network", "den", "roam", "study", "memory", "skills", "hosts", "routines", "vault",
        "services", "models", "capabilities", "appearance", "chat-voice", "care", "privacy",
        "care-diag", "about", "companions", "routine-hub", "search",
        "font", "tone", "voice", "context", "display", "search-engine", "notify",
        "selftest",
    ]

    var body: some View {
        switch name {
        case "settings": SettingsView(team: team)
        case "connectors": ConnectorsPage()
        case "look": NavigationStack { LookPage() }
        case "stops": NavigationStack { ReadingSizePage() }
        case "grants": GrantsPage(team: team)
        case "add": SetupView(team: team, onDone: {})
        case "pet": PetPage()
        case "network": NetworkSettingsPage(endpoints: team.settings.endpoints, embedded: false)
        case "den": DenPage()
        case "roam": RoamPage(browser: team.browser)
        case "study": StudyPage()
        case "memory": NavigationStack { MemoryPageV2(team: team, showsDone: true) }
        case "skills": SkillsPage(embedded: false)
        case "hosts": HillsPage(embedded: false)
        case "routines": RoutinesPage(team: team)
        case "vault": SecretsPage(embedded: false)
        case "services": NavigationStack { ServicesHubPage(team: team, openAdd: {}) }
        case "models": NavigationStack { DefaultModelsPage(team: team, openServices: {}) }
        case "capabilities": SettingsView(team: team, startAt: "capabilities")
        case "appearance": SettingsView(team: team, startAt: "appearance")
        case "chat-voice": SettingsView(team: team, startAt: "chatAndVoice")
        case "care": SettingsView(team: team, startAt: "care")
        case "privacy": SettingsView(team: team, startAt: "privacy")
        case "care-diag": CarePage(team: team, scope: .diagnostics, embedded: false)
        case "about": NavigationStack { CareAboutPage() }
        case "companions": SettingsView(team: team, startAt: "companions")
        case "routine-hub": SettingsView(team: team, startAt: "memoryAndRoutine")
        case "search": UnifiedGlobalSearchSheet(team: team, onOpenChat: { _, _ in }, onOpenMemory: {}, onOpenStudy: {})
        case "font": NavigationStack { FontPage() }
        case "tone": NavigationStack { ToneSettingsPage() }
        case "voice": NavigationStack { VoiceSettingsPage() }
        case "context": NavigationStack { ChatContextPage() }
        case "display": NavigationStack { ChatDisplayPage() }
        case "search-engine": NavigationStack { SearchSettingsPage() }
        case "notify": NavigationStack { NotificationSettingsPage() }
        #if DEBUG
        case "selftest": DeviceSelfTestPage(team: team)
        #endif
        default: EmptyView()
        }
    }
}

#if DEBUG
private struct DeviceSelfTestPage: View {
    struct CheckItem: Identifiable {
        let id = UUID()
        let title: String
        let passed: Bool
        let detail: String
    }

    @ObservedObject var team: TeamModel
    @State private var items: [CheckItem] = []
    @State private var finished = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Ink.Space.m) {
                HStack {
                    Text(finished ? "真机功能自检完成" : "真机功能自检运行中…")
                        .font(.system(size: Ink.Size.title, weight: .bold))
                        .foregroundStyle(Ink.ink)
                    Spacer()
                    let okCount = items.filter(\.passed).count
                    Text("\(okCount)/\(items.count)")
                        .font(Ink.mono(Ink.Size.body))
                        .foregroundStyle(okCount == items.count && finished ? Ink.ok : Ink.warn)
                }
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: Ink.Space.s) {
                        Image(systemName: item.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(item.passed ? Ink.ok : Ink.stop)
                            .font(.system(size: Ink.Size.body))
                        VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
                            Text(item.title)
                                .font(.system(size: Ink.Size.sub, weight: .semibold))
                                .foregroundStyle(Ink.ink)
                            Text(item.detail)
                                .font(Ink.mono(Ink.Size.micro))
                                .foregroundStyle(Ink.inkSoft)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(Ink.Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .paperCard()
                }
            }
            .padding(Ink.Space.page)
        }
        .background(Ink.paper.ignoresSafeArea())
        .task { await runAll() }
    }

    private func record(_ title: String, _ passed: Bool, _ detail: String) {
        items.append(CheckItem(title: title, passed: passed, detail: detail))
    }

    private func runAll() async {
        // 1. CLIO-022 SkillSourceValidator
        let good = SkillSourceValidator.parseAndValidate(urlString: "https://github.com/apple/swift/tree/main/docs")
        let badAt = SkillSourceValidator.parseAndValidate(urlString: "https://evil.com@github.com/a/b")
        let badTrav = SkillSourceValidator.parseAndValidate(urlString: "https://github.com/a/b/tree/main/../secret")
        let badIP = SkillSourceValidator.parseAndValidate(urlString: "http://127.0.0.1/a/b")
        let skillOK: Bool
        if case .success = good, case .failure = badAt, case .failure = badTrav, case .failure = badIP {
            skillOK = true
        } else {
            skillOK = false
        }
        record("CLIO-022 Skill URL 校验", skillOK, "合法放行 / @注入、..穿越、内网IP均拦截")

        // 2. CLIO-025 BrandIcons SSRF / 内网域名拦截
        let brandOK = BrandIcons.isPublicIconDomain("https://api.openai.com/v1")
            && !BrandIcons.isPublicIconDomain("http://api.openai.com/v1")
            && !BrandIcons.isPublicIconDomain("https://localhost:8080")
            && !BrandIcons.isPublicIconDomain("https://192.168.1.50:11434")
            && !BrandIcons.isPublicIconDomain("https://nas.local/api")
            && !BrandIcons.isPublicIconDomain("https://mac.ts.net/api")
        record("CLIO-025 图标公网域名隔离", brandOK, "公网HTTPS放行 / HTTP、IP、.local、.ts.net全阻断")

        // 3. 设置搜索与深链
        let netSearch = SettingsView.searchPages(matching: "代理")
        let fontSearch = SettingsView.searchPages(matching: "文楷")
        let linkOK = SettingsPage(link: "network") == .network
            && SettingsPage(link: "proxy") == .network
            && SettingsPage(link: "dns") == .network
            && netSearch.contains(.network)
            && fontSearch.contains(.font)
        record("设置搜索与深链路由", linkOK, "代理→\(netSearch.count)项 / 文楷→\(fontSearch.count)项 / network/proxy/dns命中")

        // 4. ClioNetHub 本地双入口代理 + Keychain 存取 + 连通性诊断
        let rt = NetworkRuntime.shared
        let prev = rt.settings
        let tempProxy = ProxyProfile(
            name: "SelfTestSOCKS",
            kind: .socks5,
            host: "127.0.0.1",
            port: 19999,
            username: "tester",
            bypass: ["*.local", "10.0.0.0/8"]
        )
        rt.saveProxy(tempProxy, password: "selftest-secret-value")
        rt.update { s in
            s.routingEnabled = true
            s.defaultRoute = .proxy(tempProxy.id)
        }
        await rt.waitUntilApplied()
        let ep = rt.activeEndpoints
        let diagStart = Date()
        let diag = await rt.runDiagnostics()
        let diagElapsed = Date().timeIntervalSince(diagStart)
        let socksItem = diag.first { $0.name.contains("SOCKS5") }
        let httpItem = diag.first { $0.name.contains("HTTP") }
        let proxyItem = diag.first { $0.name.contains("SelfTestSOCKS") }
        let hubOK = ep != nil && ep!.socksPort > 0 && ep!.httpPort > 0
            && socksItem?.status == .ok && httpItem?.status == .ok
            && proxyItem?.status == .fail && (proxyItem?.elapsedMs ?? 99_999) < 2000
        let diagSummary = diag.map { "\($0.name):\($0.status.rawValue)(\($0.elapsedMs)ms)" }.joined(separator: " | ")
        rt.deleteProxy(id: tempProxy.id)
        rt.update { $0 = prev }
        await rt.waitUntilApplied()
        record(
            "ClioNetHub 本地双入口与快速失败",
            hubOK,
            String(format: "ports=%@ total=%.2fs | %@", ep.map { "\($0.socksPort)/\($0.httpPort)" } ?? "nil", diagElapsed, diagSummary)
        )

        // 5. Den (iSH ARM64 Alpine) 真机启动 + 统一环境变量 + /etc/clio-net 挂载
        let woke = await Den.shared.wake()
        if woke {
            let envRes = await Den.shared.run(
                "uname -m && printf 'ENV:%s|%s|%s\\n' \"$OPENSSL_armcap\" \"$GODEBUG\" \"$TZ\" && ls -d /etc/clio-net /etc/ssh/ssh_config.d/90-clio-net.conf 2>&1",
                timeout: 15,
                shown: false
            )
            let out = envRes.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let envOK = envRes.code == 0 && out.contains("ENV:0|asyncpreemptoff=1|") && out.contains("/etc/clio-net")
            record("Alpine 内核启动与环境挂载", envOK, out.replacingOccurrences(of: "\n", with: " ; "))

            // 6. killpg 整组强杀测试（子进程 sleep 30 必须在超时后迅速结束）
            let t0 = Date()
            let killRes = await Den.shared.run("sh -c 'sleep 30 & wait'", timeout: 1.2, shown: false)
            let dt = Date().timeIntervalSince(t0)
            let killOK = killRes.timedOut && dt < 5.0
            record("内核 killpg 整组强杀", killOK, String(format: "timedOut=%@ elapsed=%.2fs", "\(killRes.timedOut)", dt))

            // 7. 256 KB 无换行流防 OOM 上限测试
            let bigRes = await Den.shared.run("head -c 300000 /dev/zero | tr '\\0' 'a'", timeout: 15, shown: false)
            let bigOK = bigRes.code == 0 && bigRes.output.count >= 250_000
            record("256KB 无换行流防 OOM", bigOK, "code=\(bigRes.code) chars=\(bigRes.output.count)")
        } else {
            record("Alpine 内核启动与环境挂载", false, "wake() 返回 false: \(Den.shared.state)")
        }

        finished = true
    }
}
#endif

/// Signal the simulator after the screen has a window and had two opportunities to draw.
struct ShotReady: UIViewRepresentable {
    let token: String

    func makeUIView(context: Context) -> Probe { Probe(token: token) }
    func updateUIView(_ view: Probe, context: Context) {}

    final class Probe: UIView {
        private let token: String
        private var displayLink: CADisplayLink?
        private var frames = 0

        init(token: String) {
            self.token = token
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            displayLink?.invalidate()
            displayLink = nil
            guard window != nil, frames < 2 else { return }
            let link = CADisplayLink(target: self, selector: #selector(didRefresh))
            displayLink = link
            link.add(to: .main, forMode: .common)
        }

        @objc private func didRefresh() {
            guard bounds.width > 0, bounds.height > 0 else { return }
            frames += 1
            guard frames == 2 else { return }
            displayLink?.invalidate()
            displayLink = nil
            let token = token
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, Shots.delay)) {
                let marker = FileManager.default.temporaryDirectory.appendingPathComponent("clio-shot-ready")
                try? token.write(to: marker, atomically: true, encoding: .utf8)
            }
        }
    }
}
