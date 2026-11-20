import AgentKit
import SwiftUI
import UniformTypeIdentifiers

/// 养护: backup and restore, and a diagnosis to paste when something goes wrong.
struct CarePage: View {
    @ObservedObject var team: TeamModel
    @ObservedObject private var den = Den.shared
    @Environment(\.dismiss) private var dismiss
    @State private var withKeys = false
    @State private var made: URL?
    @State private var making = false
    @State private var restoring = false
    @State private var restored = false
    @State private var notice: String?
    @State private var probes: [String: String] = [:]
    @State private var probing = false
    @State private var copied = false
    @State private var hitchesCopied = false
    @AppStorage("care.hitches") private var recordingHitches = false
    @ObservedObject private var hitches = Hitches.shared

    var body: some View {
        NavigationStack {
            Form {
                PaperRows {
                Section {
                    Toggle("连模型密钥一起备份", isOn: $withKeys)
                    Button(making ? L.t("loading.preparingBackup") : "做一份备份") { make() }.disabled(making)
                    if let made {
                        ShareLink(item: made) { Label("存到「文件」或发出去", systemImage: "square.and.arrow.up") }
                    }
                    Button("从备份恢复") { restoring = true }
                } header: { Text(L.t("settings.backup")) } footer: {
                    Text(Words.t("不含信匣和远山的密码"))
                }

                Section {
                    if team.archived.isEmpty {
                        Text(Words.t("没有归档的絮语")).foregroundStyle(Ink.inkSoft)
                    } else {
                        ForEach(team.archived.sorted(), id: \.self) { key in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(team.chatName(key)).foregroundStyle(Ink.ink)
                                    if let title = team.title(of: key) {
                                        Text(title).font(Ink.footnote).foregroundStyle(Ink.inkSoft)
                                    }
                                }
                                Spacer()
                                Button("拿回来") {
                                    withAnimation(Ink.Motion.settle) { team.archive(key, false) }
                                    Haptics.tick(0.6)
                                }
                                .fontWeight(.medium)
                            }
                        }
                    }
                } header: { Text(L.t("settings.archivedConversations")) } footer: {
                    Text(Words.t("拿回来后回到案头"))
                }

                Section {
                    row("版本", "Clio \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")（\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?")）")
                    row("系统", "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
                    row(Words.t("旅伴 / 雅集"), "\(team.bots.count) / \(team.rooms.count)")
                    row(Words.t("拾遗"), "常记 \(team.surfaceMemories.count) · 旧事 \(team.deepMemories.count)")
                    row("数据占用", sizeText)
                    row(Words.t("斗室"), denText)
                    row(Words.t("远山"), "\(Hills.shared.hosts.count) 台主机 · \(Hills.shared.servers.count) 个 MCP")
                } header: { Text(L.t("settings.diagnosticInfo")) }

                Section {
                    ForEach(team.settings.endpoints) { endpoint in
                        row(endpoint.name, probes[endpoint.id] ?? "未测")
                    }
                    Button(probing ? L.t("loading.testingModels") : "试一试模型连不连得上") { probe() }.disabled(probing || team.settings.endpoints.isEmpty)
                } header: { Text(L.t("settings.modelConnectivity")) }

                Section {
                    if Diag.log.isEmpty {
                        Text("最近没有出错。").foregroundStyle(Ink.inkSoft)
                    } else {
                        ForEach(Array(Diag.log.reversed().prefix(20).enumerated()), id: \.offset) { _, line in
                            Text(line).font(Ink.mono(Ink.Size.small)).foregroundStyle(Ink.inkSoft)
                        }
                        Button("清空记录", role: .destructive) { Diag.clear(); notice = "清空了。" }
                    }
                } header: { Text(L.t("settings.recentErrors")) }

                Section {
                    Toggle("掉帧记录仪", isOn: $recordingHitches)
                    if hitches.recent.isEmpty {
                        Text(recordingHitches ? "还没有记到卡顿。照常用一会儿，卡了再回来看。" : "打开后，Clio 会记下每一次卡顿。").foregroundStyle(Ink.inkSoft)
                    } else {
                        ForEach(Array(hitches.recent.reversed().prefix(15).enumerated()), id: \.offset) { _, hitch in
                            Text(hitch.line).font(Ink.mono(Ink.Size.small)).foregroundStyle(hitch.ms >= 100 ? Ink.stop : Ink.inkSoft)
                        }
                        Button(hitchesCopied ? "复制好了，贴给我就行" : "复制掉帧记录（\(hitches.recent.count) 条）") {
                            UIPasteboard.general.string = hitches.report
                            hitchesCopied = true
                            Haptics.tick(0.6)
                        }
                        Button("清空掉帧记录", role: .destructive) {
                            hitches.clear()
                            hitchesCopied = false
                        }
                    }
                } header: { Text(L.t("settings.frameDrops")) } footer: {
                    Text("记下每次卡顿和当时在做什么，开着耗电")
                }

                Section {
                    Button(copied ? "复制好了，贴给我就行" : "复制整份诊断") {
                        UIPasteboard.general.string = report
                        copied = true
                        Haptics.tick(0.6)
                    }
                } footer: { Text("不包含密钥、密码和聊天内容。") }
            }
            }
            .paperForm()
            .hitchPage("养护")
            .navigationTitle(L.t("settings.diagnostics"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L.t("actions.done")) { dismiss() } } }
            .fileImporter(isPresented: $restoring, allowedContentTypes: [.data, .item]) { result in
                guard case .success(let url) = result else { return }
                do {
                    let summary = try Backup.restore(from: url)
                    restored = true
                    notice = "恢复了 \(summary.files) 项。要关掉 Clio 再打开才会生效。"
                } catch {
                    notice = error.localizedDescription
                }
            }
            .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                if restored {
                    Button("现在关掉 Clio") { exit(0) }
                    Button("等会儿", role: .cancel) {}
                } else {
                    Button("好", role: .cancel) {}
                }
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(Ink.ink)
            Spacer()
            Text(value).foregroundStyle(Ink.inkSoft).multilineTextAlignment(.trailing).font(.system(size: Ink.Size.sub))
        }
    }

    private var denText: String {
        switch den.state {
        case .asleep: "睡着"
        case .unpacking: "铺陈中"
        case .waking: "醒来中"
        case .awake: "醒着"
        case .broken(let why): why
        }
    }

    private var sizeText: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var total: Int64 = 0
        if let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) {
            for case let url as URL in walker {
                total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
            }
        }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    private var report: String {
        var lines = ["Clio 诊断 \(Date().formatted())"]
        lines.append("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))")
        lines.append("\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
        lines.append("旅伴 \(team.bots.count)，雅集 \(team.rooms.count)，拾遗 \(team.memories.count)，数据 \(sizeText)")
        lines.append("斗室：\(denText)")
        for endpoint in team.settings.endpoints {
            lines.append("模型服务 \(endpoint.name)（\(URL(string: endpoint.baseURL)?.host ?? "?")，\(endpoint.models.count) 个模型）：\(probes[endpoint.id] ?? "未测")")
        }
        lines.append("设置：" + ["look.face", "look.size", "look.scheme", "chat.contextChars", "chat.autoCompress", "chat.temperature", "chat.maxOutput"]
            .map { "\($0)=\(UserDefaults.standard.object(forKey: $0).map { "\($0)" } ?? "默认")" }.joined(separator: " "))
        lines.append("最近的错误：")
        lines += Diag.log.suffix(20)
        if !hitches.recent.isEmpty { lines.append(hitches.report.split(separator: "\n").prefix(21).joined(separator: "\n")) }
        return lines.joined(separator: "\n")
    }

    private func make() {
        making = true
        let ids = team.settings.endpoints.map(\.id)
        let keys = withKeys
        Task.detached {
            let result = Result { try Backup.make(withKeys: keys, endpoints: ids) }
            await MainActor.run {
                making = false
                switch result {
                case .success(let (url, summary)):
                    made = url
                    notice = "打包好了：\(summary.files) 项，\(ByteCountFormatter.string(fromByteCount: Int64(summary.bytes), countStyle: .file))。点「存到文件或发出去」保存。"
                case .failure(let error):
                    notice = "没打包成：\(error.localizedDescription)"
                }
            }
        }
    }

    private func probe() {
        probing = true
        Task {
            for endpoint in team.settings.endpoints {
                probes[endpoint.id] = "在试…"
                guard let model = endpoint.models.first, let key = team.apiKey(for: endpoint.id), !key.isEmpty else {
                    probes[endpoint.id] = "没有模型或密钥"
                    continue
                }
                let started = Date()
                do {
                    var probe = Agent(provider: endpoint.provider(key: key), model: model, system: "只回答一个字。")
                    probe.outputLimit = 16
                    let agent = probe
                    let answer = try await withThrowingTaskGroup(of: String.self) { group in
                        group.addTask { try await agent.ask("回一个字：好") }
                        group.addTask {
                            try await Task.sleep(nanoseconds: 25_000_000_000)
                            throw TeamError(message: "25 秒没回音")
                        }
                        let first = try await group.next()!
                        group.cancelAll()
                        return first
                    }
                    probes[endpoint.id] = "通了 · \(String(format: "%.1f", Date().timeIntervalSince(started))) 秒 · 「\(answer.prefix(8))」"
                } catch {
                    probes[endpoint.id] = "不通：\(error.localizedDescription.prefix(60))"
                    Diag.note("试连 \(endpoint.name)：\(error.localizedDescription)")
                }
            }
            probing = false
        }
    }
}
