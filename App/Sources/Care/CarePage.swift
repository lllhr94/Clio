import AgentKit
import SwiftUI
import UniformTypeIdentifiers

/// 养护: backup and restore, and a diagnosis to paste when something goes wrong.
struct CarePage: View {
    @ObservedObject var team: TeamModel
    var openRestore = false
    @ObservedObject private var den = Den.shared
    @Environment(\.dismiss) private var dismiss
    @State private var withKeys = false
    @State private var made: URL?
    @State private var sizeText = ""
    @State private var making = false
    @State private var restoring = false
    @State private var restored = false
    @State private var notice: String?
    @State private var probes: [String: String] = [:]
    @AppStorage(WebDAV.urlKey) private var davURL = ""
    @AppStorage(WebDAV.userKey) private var davUser = ""
    /// Read from the keychain once when the page opens, kept here while typing, saved when leaving the field or page
    /// (the review, #28: reading and writing the keychain on every redraw and keystroke).
    @State private var davPassword = ""
    @State private var davPasswordLoaded = false
    @State private var davBusy = false
    @State private var probing = false
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Form {
                PaperRows {
                Section {
                    Toggle(L.t("settings.backupIncludesKeys"), isOn: $withKeys)
                    Button(making ? L.t("loading.preparingBackup") : L.t("actions.createBackup")) { make() }.disabled(making)
                    if let made {
                        ShareLink(item: made) { Label("存到「文件」或发出去", systemImage: "square.and.arrow.up") }
                    }
                    Button(L.t("actions.restoreBackup")) { restoring = true }
                } header: { Text(L.t("settings.backup")) } footer: {
                    Text(L.t("settings.backupPrivacy"))
                }

                Section {
                    TextField(L.t("settings.davAddress"), text: $davURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField(L.t("settings.davUser"), text: $davUser)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField(L.t("settings.davPassword"), text: $davPassword)
                        .onSubmit { WebDAV.setPassword(davPassword) }
                    if let problem = WebDAV.addressProblem(davURL) {
                        Text(problem).font(Ink.footnote).foregroundStyle(Ink.warn)
                    }
                    Button(davBusy ? L.t("loading.working") : L.t("actions.davUpload")) { davUpload() }
                        .disabled(davBusy || !davReady)
                    Button(davBusy ? L.t("loading.working") : L.t("actions.davRestore")) { davRestore() }
                        .disabled(davBusy || !davReady)
                } header: { Text(L.t("settings.davBackup")) } footer: {
                    Text(L.t("settings.davNote"))
                }

                Section {
                    if team.archived.isEmpty {
                        Text(L.t("empty.archivedChats")).foregroundStyle(Ink.inkSoft)
                    } else {
                        ForEach(team.archived.sorted(), id: \.self) { key in
                            HStack {
                                VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
                                    Text(team.chatName(key)).foregroundStyle(Ink.ink)
                                    if let title = team.title(of: key) {
                                        Text(title).font(Ink.footnote).foregroundStyle(Ink.inkSoft)
                                    }
                                }
                                Spacer()
                                Button(L.t("actions.restore")) {
                                    withAnimation(Ink.Motion.settle) { team.archive(key, false) }
                                    Haptics.tick(0.6)
                                }
                                .fontWeight(.medium)
                            }
                        }
                    }
                } header: { Text(L.t("settings.archivedConversations")) } footer: {
                    Text(L.t("settings.archivedRestoreNote"))
                }

                Section {
                    row("版本", "Clio \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")（\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?")）")
                    row("系统", "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
                    row(Words.t("旅伴 / 雅集"), "\(team.bots.count) / \(team.rooms.count)")
                    row(Words.t("拾遗"), Words.t("常记 \(team.surfaceMemories.count) · 旧事 \(team.deepMemories.count)"))
                    row("数据占用", sizeText.isEmpty ? L.t("loading.calculating") : sizeText)
                    row(Words.t("斗室"), denText)
                    row(Words.t("远山"), "\(Hills.shared.hosts.count) 台主机 · \(Hills.shared.servers.count) 个 MCP")
                } header: { Text(L.t("settings.diagnosticInfo")) }

                Section {
                    ForEach(team.settings.endpoints) { endpoint in
                        row(endpoint.name, probes[endpoint.id] ?? "未测")
                    }
                    Button(probing ? L.t("loading.testingModels") : L.t("actions.testProviderConnections")) { probe() }.disabled(probing || team.settings.endpoints.isEmpty)
                } header: { Text(L.t("settings.modelConnectivity")) }

                Section {
                    if Diag.log.isEmpty {
                        Text(L.t("settings.noRecentErrors")).foregroundStyle(Ink.inkSoft)
                    } else {
                        ForEach(Array(Diag.log.reversed().prefix(20).enumerated()), id: \.offset) { _, line in
                            Text(line).font(Ink.mono(Ink.Size.small)).foregroundStyle(Ink.inkSoft)
                        }
                        Button(L.t("actions.clearLogs"), role: .destructive) { Diag.clear(); notice = "清空了。" }
                    }
                } header: { Text(L.t("settings.recentErrors")) }

                HitchSettings()

                Section {
                    Button(copied ? "复制好了，贴给我就行" : "复制整份诊断") {
                        UIPasteboard.general.string = report
                        copied = true
                        Haptics.tick(0.6)
                    }
                } footer: { Text(L.t("settings.diagnosticsPrivacy")) }

                Section {
                    Link("github.com/lllhr94/Clio", destination: URL(string: "https://github.com/lllhr94/Clio")!)
                } footer: { Text(L.t("settingsHome.aboutCredits")) }
            }
            }
            .paperForm()
            .hitchPage("养护")
            .navigationTitle(L.t("settingsHome.care"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L.t("actions.done")) { dismiss() } } }
            .task { await measureStorage() }
            .task {
                guard !davPasswordLoaded else { return }
                davPassword = await Task.detached { WebDAV.password }.value
                davPasswordLoaded = true
            }
            .onDisappear { if davPasswordLoaded { WebDAV.setPassword(davPassword) } }
            .task {
                guard openRestore else { return }
                do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
                restoring = true
            }
            .fileImporter(isPresented: $restoring, allowedContentTypes: [.data, .item]) { result in
                guard case .success(let url) = result else { return }
                Task {
                    // Off the main thread: a large backup takes a while to check and write.
                    let outcome = await Task.detached { Result { try Backup.restore(from: url) } }.value
                    switch outcome {
                    case .success(let summary):
                        restored = true
                        notice = "恢复了 \(summary.files) 项。要关掉 Clio 再打开才会生效；在那之前不会再保存任何东西。"
                    case .failure(let error):
                        notice = error.localizedDescription
                    }
                }
            }
            .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                if restored {
                    Button(L.t("actions.quitApp")) { exit(0) }
                    Button(L.t("actions.cancel"), role: .cancel) {}
                } else {
                    Button(L.t("actions.done"), role: .cancel) {}
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
        case .unpacking: "准备中"
        case .waking: "醒来中"
        case .awake: "醒着"
        case .broken(let why): why
        }
    }

    private func measureStorage() async {
        let work = Task.detached(priority: .utility) {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            var total: Int64 = 0
            if let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) {
                for case let url as URL in walker {
                    if Task.isCancelled { break }
                    total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
                }
            }
            return total
        }
        let total = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        if !Task.isCancelled { sizeText = ByteCountFormatter.string(fromByteCount: total, countStyle: .file) }
    }

    private var report: String {
        var lines = ["Clio 诊断 \(Date().formatted())"]
        lines.append("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))")
        lines.append("\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
        lines.append("旅伴 \(team.bots.count)，雅集 \(team.rooms.count)，拾遗 \(team.memories.count)，数据 \(sizeText.isEmpty ? L.t("loading.calculating") : sizeText)")
        lines.append("斗室：\(denText)")
        for endpoint in team.settings.endpoints {
            lines.append("模型服务 \(endpoint.name)（\(URL(string: endpoint.baseURL)?.host ?? "?")，\(endpoint.models.count) 个模型）：\(probes[endpoint.id] ?? "未测")")
        }
        lines.append("设置：" + ["look.face", "look.size", "look.scheme", "chat.contextShare", "chat.compressShare", "chat.autoCompress", "chat.temperature", "chat.maxOutput"]
            .map { "\($0)=\(UserDefaults.standard.object(forKey: $0).map { "\($0)" } ?? "默认")" }.joined(separator: " "))
        lines.append("最近的错误：")
        lines += Diag.log.suffix(20)
        let hitches = Hitches.shared
        if !hitches.recent.isEmpty { lines.append(hitches.report.split(separator: "\n").prefix(21).joined(separator: "\n")) }
        return lines.joined(separator: "\n")
    }

    /// Address, user and password are filled in and the address is allowed.
    private var davReady: Bool {
        !davURL.isEmpty && WebDAV.addressProblem(davURL) == nil && !davUser.isEmpty && !davPassword.isEmpty
    }

    private func davUpload() {
        davBusy = true
        WebDAV.setPassword(davPassword)
        let ids = team.settings.endpoints.map(\.id)
        Task {
            do {
                // Never with the model keys: a file on a drive is out of the phone's keychain (the review, #4).
                let (url, summary) = try await Task.detached { try Backup.make(withKeys: false, endpoints: ids) }.value
                try await WebDAV.upload(url)
                notice = "备份到网盘了：\(url.lastPathComponent)，\(summary.files) 项，\(ByteCountFormatter.string(fromByteCount: Int64(summary.bytes), countStyle: .file))。"
            } catch {
                notice = "没备份成：\(error.localizedDescription)"
            }
            davBusy = false
        }
    }

    private func davRestore() {
        davBusy = true
        Task {
            do {
                guard let newest = try await WebDAV.list().first else { throw TeamError(message: "网盘的 Clio 文件夹里还没有备份。") }
                let file = try await WebDAV.download(newest)
                let summary = try await Task.detached { try Backup.restore(from: file) }.value
                restored = true
                notice = "从网盘恢复了「\(newest)」，\(summary.files) 项。要关掉 Clio 再打开才会生效。"
            } catch {
                notice = "没恢复成：\(error.localizedDescription)"
            }
            davBusy = false
        }
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
                guard let model = endpoint.models.first, let key = await Vault.readString("key-\(endpoint.id)"), !key.isEmpty else {
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


private struct HitchSettings: View {
    @State private var hitchesCopied = false
    @AppStorage("look.fps") private var fps = false
    @AppStorage("care.hitches") private var recordingHitches = false
    @ObservedObject private var hitches = Hitches.shared

    var body: some View {
        Section {
            Toggle(L.t("settings.showFrameRate"), isOn: $fps)
            Toggle(L.t("settings.recordHitches"), isOn: $recordingHitches)
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
            Text(L.t("settings.recordHitchesNote"))
        }
    }
}
