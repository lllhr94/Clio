import SwiftUI

/// 装常用软件: pick a mirror and the tools, get one command to run in 斗室.
struct OutfitSheet: View {
    let done: (String?) -> Void

    private static let mirrors: [(String, String)] = [
        ("清华", "mirrors.tuna.tsinghua.edu.cn"),
        ("中科大", "mirrors.ustc.edu.cn"),
        ("阿里云", "mirrors.aliyun.com"),
        ("官方", "dl-cdn.alpinelinux.org"),
    ]
    private static let kits: [(String, String, String)] = [
        ("Python", "python3 py3-pip", "跑脚本、处理数据"),
        ("Node.js", "nodejs npm", "跑 JavaScript 工具"),
        ("Git", "git", "拉代码"),
        ("OpenSSH", "openssh-client", "连别的主机"),
        ("常用小工具", "bash coreutils curl wget jq less file tree", "bash、curl、jq 等"),
        ("编辑器", "vim nano", "在终端里改文件"),
    ]

    @State private var mirror = "mirrors.tuna.tsinghua.edu.cn"
    @State private var chosen: Set<String> = ["Python", "常用小工具"]
    /// Milliseconds to each mirror; -1 when it did not answer.
    @State private var latency: [String: Int] = [:]
    @State private var measuring = true
    /// The user picked a mirror by hand: the speed test no longer changes it.
    @State private var pickedByHand = false

    var body: some View {
        NavigationStack {
            Form {
                PaperRows {
                Section {
                    SlidingCapsuleControl(
                        selection: Binding(get: { mirror }, set: { mirror = $0; pickedByHand = true }),
                        items: Self.mirrors.map { (value: $0.1, title: label($0)) },
                        compact: true
                    )
                    .accessibilityLabel("软件源")
                } header: { Text("软件源") } footer: {
                    Text(measuring ? L.t("loading.measuringMirrors") : "测过了：数字是毫秒，越小越快，已经替你选了最快的。没有数字的是连不上。")
                }
                Section("要装的") {
                    ForEach(Self.kits, id: \.0) { kit in
                        Button {
                            if chosen.contains(kit.0) { chosen.remove(kit.0) } else { chosen.insert(kit.0) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
                                    Text(kit.0).foregroundStyle(Ink.ink)
                                    Text(kit.2).font(Ink.footnote).foregroundStyle(Ink.inkSoft)
                                }
                                Spacer()
                                Image(systemName: chosen.contains(kit.0) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(chosen.contains(kit.0) ? Ink.accent : Ink.inkFaint)
                            }
                        }
                    }
                }
            }
            }
            .scrollContentBackground(.hidden)
            .tint(Ink.accent)
            .environment(\.defaultMinListRowHeight, 48)
            .task { await measure() }
            .navigationTitle(L.t("terminal.installSoftware"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(L.t("actions.cancel")) { done(nil) } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("开装") { done(command) }.fontWeight(.semibold).disabled(chosen.isEmpty && mirror == "dl-cdn.alpinelinux.org")
                }
            }
        }
    }

    private func label(_ mirror: (String, String)) -> String {
        guard let ms = latency[mirror.1] else { return mirror.0 }
        return ms < 0 ? mirror.0 + " ×" : "\(mirror.0) \(ms)"
    }

    /// Asks every mirror for the same small file at once and keeps the quickest answer.
    private func measure() async {
        measuring = true
        await withTaskGroup(of: (String, Int).self) { group in
            for (_, host) in Self.mirrors {
                group.addTask { (host, await Self.ping(host)) }
            }
            for await (host, ms) in group { latency[host] = ms }
        }
        measuring = false
        if !pickedByHand, let best = latency.filter({ $0.value >= 0 }).min(by: { $0.value < $1.value })?.key {
            withAnimation(Ink.Motion.settle) { mirror = best }
        }
    }

    private static func ping(_ host: String) async -> Int {
        guard let url = URL(string: "https://\(host)/alpine/latest-stable/main/aarch64/APKINDEX.tar.gz") else { return -1 }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.httpMethod = "HEAD"
        let start = Date()
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse).map({ $0.statusCode < 400 }) ?? false else { return -1 }
            return Int(Date().timeIntervalSince(start) * 1000)
        } catch {
            return -1
        }
    }

    private var command: String {
        let packages = Self.kits.filter { chosen.contains($0.0) }.map(\.1).joined(separator: " ")
        let source = "sed -i 's#https\\?://[^/]*/alpine#https://\(mirror)/alpine#g' /etc/apk/repositories && apk update"
        return packages.isEmpty ? source : source + " && apk add \(packages)"
    }
}
