import AgentKit
import Craft
import Darwin
import SwiftUI
import UniformTypeIdentifiers

enum CareScope: Hashable {
    case all
    case backup
    case storage
    case diagnostics
}

/// 养护: backup and restore, and a diagnosis to paste when something goes wrong.
struct CarePage: View {
    let team: TeamModel
    var openRestore = false
    var scope: CareScope = .all
    var embedded = false
    @State private var denState = Den.State.asleep
    @State private var formSectionsReady = false
    @State private var diagnosticsReady = false
    @State private var hitchesReady = false
    @State private var recentErrors: [String] = []
    @Environment(\.dismiss) private var dismiss
    @State private var withKeys = false
    @State private var encryptLocal = false
    @State private var made: URL?
    @State private var sizeText = ""
    @State private var storage: StorageBreakdown?
    @State private var denTempBytes: Int64 = 0
    @State private var cleaningCache = false
    @State private var cleaningDenTemp = false
    @State private var denRunningBusy = false
    @State private var cleanTask: Task<Void, Never>?
    @State private var making = false
    @State private var restoring = false
    @State private var restoringBusy = false
    @State private var restored = false
    @State private var notice: String?
    @State private var probes: [String: String] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(WebDAV.urlKey) private var davURL = ""
    @AppStorage(WebDAV.userKey) private var davUser = ""
    @AppStorage(WebDAV.encryptKey) private var davEncrypt = false
    /// Read from the keychain once when the page opens, kept here while typing, saved when leaving the field or page
    /// (the review, #28: reading and writing the keychain on every redraw and keystroke).
    @State private var davPassword = ""
    @State private var davPasswordLoaded = false
    @State private var davPasswordDirty = false
    @State private var lastSavedDavPassword = ""
    @State private var davBusy = false
    /// The drive's backups, newest first, while the person picks which one to bring back.
    @State private var davChoices: [String] = []
    @State private var probing = false
    @State private var copied = false
    @State private var copyingReport = false
    @State private var uikitSpikeOpen = false
    @AppStorage("care.spikeLab") private var spikeLab = false
    @State private var versionTapCount = 0
    @State private var lastVersionTapAt = Date.distantPast
    @State private var passphraseSetup: PassphraseSetupRequest?
    @State private var pendingSetupAction: PendingSetupAction?
    @State private var pendingRestore: PendingRestore?
    @State private var deferredNoticeAfterUnlock: String?

    private var showSpikeLab: Bool {
        #if DEBUG
        return true
        #else
        return spikeLab
        #endif
    }

    private var backupOrRestoreBusy: Bool {
        making
            || restoring
            || restoringBusy
            || davBusy
            || !davChoices.isEmpty
            || restored
            || Disk.frozen
            || pendingRestore != nil
            || passphraseSetup != nil
    }

    private var navigationTitleText: String {
        switch scope {
        case .all: L.t("settingsHome.care")
        case .backup: L.t("settingsHome.careBackup")
        case .storage: L.t("settingsHome.careStorage")
        case .diagnostics: L.t("settingsHome.careDiagnostics")
        }
    }

    var body: some View {
        if embedded {
            pageContent
        } else {
            NavigationStack { pageContent }
        }
    }

    private var pageContent: some View {
        Form {
            PaperRows {
                switch scope {
                case .backup:
                    localBackupSection
                    webdavSection
                case .storage:
                    storageSection
                    archivedSection
                case .diagnostics:
                    diagnosticInfoSection
                    connectivitySection
                    recentErrorsSection
                    if hitchesReady {
                        HitchSettings()
                    }
                    if showSpikeLab {
                        spikeLabSection
                    }
                    diagnosticsActionSection
                case .all:
                    localBackupSection
                    if formSectionsReady {
                        webdavSection
                        archivedSection
                    }
                    if diagnosticsReady {
                        diagnosticInfoSection
                        storageSection
                        connectivitySection
                        recentErrorsSection
                        if hitchesReady {
                            HitchSettings()
                        }
                        if showSpikeLab {
                            spikeLabSection
                        }
                        diagnosticsActionSection
                        aboutSection
                    }
                }
            }
        }
        .scrollEdgeEffectStyle(.soft, for: .vertical)
        .paperForm()
        .hitchPage("养护")
        .navigationTitle(navigationTitleText)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !embedded {
                ToolbarItem(placement: .topBarTrailing) { Button(L.t("actions.done")) { dismiss() } }
            }
        }
        .onChange(of: withKeys) { _, includeKeys in
            if includeKeys { encryptLocal = true }
        }
        .onReceive(Den.shared.$state.removeDuplicates()) { denState = $0 }
        .onReceive(
            Den.shared.$running
                .combineLatest(Den.shared.$cleaningTemp)
                .map { !$0.isEmpty || $1 }
                .removeDuplicates()
        ) { denRunningBusy = $0 }
        .task {
            switch scope {
            case .backup:
                formSectionsReady = true
            case .storage:
                formSectionsReady = true
                await measureStorage()
            case .diagnostics:
                formSectionsReady = true
                let errors = Array((await Diag.snapshot(suffix: 20)).reversed())
                guard !Task.isCancelled else { return }
                recentErrors = errors
                diagnosticsReady = true
                await Task.yield()
                guard !Task.isCancelled else { return }
                hitchesReady = true
                await measureStorage()
            case .all:
                do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
                formSectionsReady = true
                do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
                guard !Task.isCancelled else { return }
                let errors = Array((await Diag.snapshot(suffix: 20)).reversed())
                guard !Task.isCancelled else { return }
                recentErrors = errors
                diagnosticsReady = true
                await Task.yield()
                guard !Task.isCancelled else { return }
                hitchesReady = true
                await measureStorage()
            }
        }
        .task {
            guard scope == .all || scope == .backup, !davPasswordLoaded else { return }
            let loaded = await CareWebDAVCoordinator.loadPassword()
            guard !Task.isCancelled else { return }
            lastSavedDavPassword = loaded
            davPassword = loaded
            davPasswordLoaded = true
            davPasswordDirty = false
        }
        .onChange(of: davPassword) { _, newValue in
            guard davPasswordLoaded else { return }
            davPasswordDirty = (newValue != lastSavedDavPassword)
        }
        .onDisappear {
            cleanTask?.cancel()
            persistDavPasswordIfNeeded()
            pendingSetupAction = nil
            deferredNoticeAfterUnlock = nil
            if !restoringBusy {
                let pendingURL = pendingRestore?.url
                pendingRestore = nil
                CareWebDAVCoordinator.scheduleInboxCleanup(removing: pendingURL)
            }
        }
        .task {
            guard openRestore else { return }
            do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
            restoring = true
        }
        .fileImporter(isPresented: $restoring, allowedContentTypes: [.data, .item]) { result in
            guard case .success(let url) = result else { return }
            prepareLocalRestore(from: url)
        }
        .sheet(item: $passphraseSetup, onDismiss: { runPendingSetupActionIfAny() }) { request in
            PassphraseSetupSheet(
                purpose: request.purpose,
                onCancel: {
                    pendingSetupAction = nil
                    passphraseSetup = nil
                },
                onConfirm: { passphrase in
                    pendingSetupAction = PendingSetupAction(purpose: request.purpose, passphrase: passphrase)
                    passphraseSetup = nil
                }
            )
        }
        .sheet(item: $pendingRestore, onDismiss: { handleUnlockSheetDismissed() }) { pending in
            PassphraseUnlockSheet(
                displayName: pending.displayName,
                errorMessage: pending.wrongPassphraseHint,
                busy: $restoringBusy,
                onCancel: { cancelPendingRestore() },
                onSubmit: { passphrase in
                    startUnlockRestore(pending: pending, passphrase: passphrase)
                }
            )
        }
        .confirmationDialog(
            "从网盘的哪一份恢复？",
            isPresented: Binding(get: { !davChoices.isEmpty }, set: { if !$0 { davChoices = [] } }),
            titleVisibility: .visible
        ) {
            ForEach(davChoices.prefix(8), id: \.self) { name in
                Button(Self.backupLabel(name)) { davRestore(name) }
            }
            Button(L.t("actions.cancel"), role: .cancel) { davChoices = [] }
        } message: {
            Text("恢复会换掉手机上现在的助手、对话和记忆。")
        }
        .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            if restored {
                Button(L.t("actions.quitApp")) { exit(0) }
                Button(L.t("actions.cancel"), role: .cancel) {}
            } else {
                Button(L.t("actions.done"), role: .cancel) {}
            }
        }
        .fullScreenCover(isPresented: $uikitSpikeOpen) {
            SpikeChatSheet()
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var localBackupSection: some View {
        Section {
            Toggle(L.t("settings.backupIncludesKeys"), isOn: $withKeys)
            Toggle(L.t("backupCrypto.encryptLocalToggle"), isOn: $encryptLocal)
                .disabled(withKeys)
            Button(making ? L.t("loading.preparingBackup") : L.t("actions.createBackup")) { make() }
                .disabled(making || cleaningCache || restoringBusy || restored || pendingRestore != nil)
            if let made {
                ShareLink(item: made) { Label("存到「文件」或发出去", systemImage: "square.and.arrow.up") }
            }
            Button(L.t("actions.restoreBackup")) { restoring = true }
                .disabled(cleaningCache || restoringBusy || davBusy || making || restored || pendingRestore != nil)
        } header: {
            Text(L.t("settings.backup"))
        } footer: {
            if withKeys {
                Text(L.t("backupCrypto.keysRequireEncryptionNote"))
            } else {
                Text(L.t("settings.backupPrivacy") + "\n" + L.t("backupCrypto.skillsAndEncryptionNote"))
            }
        }
    }

    @ViewBuilder
    private var webdavSection: some View {
        Section {
            TextField(L.t("settings.davAddress"), text: $davURL)
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            TextField(L.t("settings.davUser"), text: $davUser)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField(L.t("settings.davPassword"), text: $davPassword)
                .onSubmit { persistDavPasswordIfNeeded() }
            if let problem = WebDAV.addressProblem(davURL) {
                Text(problem).font(Ink.footnote).foregroundStyle(Ink.warn)
            }
            Toggle(L.t("backupCrypto.davEncryptToggle"), isOn: $davEncrypt)
            Button(davBusy ? L.t("loading.working") : L.t("actions.davUpload")) { davUpload() }
                .disabled(davBusy || !davReady || cleaningCache || restoringBusy || restored || pendingRestore != nil)
            Button(davBusy ? L.t("loading.working") : L.t("actions.davRestore")) { davRestore() }
                .disabled(davBusy || !davReady || cleaningCache || restoringBusy || making || restored || pendingRestore != nil)
        } header: {
            Text(L.t("settings.davBackup"))
        } footer: {
            Text(L.t("settings.davNote") + "\n" + L.t("backupCrypto.davEncryptNote"))
        }
    }

    @ViewBuilder
    private var archivedSection: some View {
        CareArchivedSection(team: team)
    }

    @ViewBuilder
    private var diagnosticInfoSection: some View {
        Section {
            row("版本", "Clio \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")（\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?")）")
                .contentShape(Rectangle())
                .onTapGesture { handleVersionTap() }
            row("系统", "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
            row(Words.t("旅伴 / 雅集"), "\(team.bots.count) / \(team.rooms.count)")
            row(Words.t("拾遗"), Words.t("常记 \(team.surfaceMemories.count) · 旧事 \(team.deepMemories.count)"))
            row("数据占用", sizeText.isEmpty ? L.t("loading.calculating") : sizeText)
            row(Words.t("斗室"), denText)
            row(Words.t("远山"), "\(Hills.shared.hosts.count) 台主机 · \(Hills.shared.servers.count) 个 MCP")
        } header: {
            Text(L.t("settings.diagnosticInfo"))
        }
    }

    @ViewBuilder
    private var connectivitySection: some View {
        CareConnectivitySection(team: team, probes: $probes, probing: $probing, onProbe: probe)
    }

    @ViewBuilder
    private var recentErrorsSection: some View {
        Section {
            if recentErrors.isEmpty {
                Text(L.t("settings.noRecentErrors")).foregroundStyle(Ink.inkSoft)
            } else {
                ForEach(Array(recentErrors.enumerated()), id: \.offset) { _, line in
                    Text(line).font(Ink.mono(Ink.Size.small)).foregroundStyle(Ink.inkSoft)
                }
                Button(L.t("actions.clearLogs"), role: .destructive) { Diag.clear(); recentErrors = []; notice = "清空了。" }
            }
        } header: {
            Text(L.t("settings.recentErrors"))
        }
    }

    @ViewBuilder
    private var spikeLabSection: some View {
        Section {
            Button {
                Haptics.light()
                uikitSpikeOpen = true
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
                        Text(L.t("careSpike.title")).foregroundStyle(Ink.ink)
                        Text(L.t("careSpike.subtitle")).font(Ink.footnote).foregroundStyle(Ink.inkSoft)
                    }
                    Spacer()
                    Kit.chevron
                }
            }
            if spikeLab {
                Button(L.t("careSpike.hideLab"), role: .destructive) {
                    spikeLab = false
                    Haptics.tick(0.5)
                }
            }
        } header: {
            Text(L.t("careSpike.section"))
        }
    }

    @ViewBuilder
    private var diagnosticsActionSection: some View {
        Section {
            Button(copied ? "复制好了，贴给我就行" : (copyingReport ? "正在整理诊断…" : "复制整份诊断")) {
                copyReport()
            }
            .disabled(copyingReport)
        } footer: {
            Text(L.t("settings.diagnosticsPrivacy"))
        }
    }

    @ViewBuilder
    private var aboutSection: some View {
        Section {
            Link("github.com/lllhr94/Clio", destination: URL(string: "https://github.com/lllhr94/Clio")!)
        } footer: {
            Text(L.t("settingsHome.aboutCredits"))
        }
    }

    private func handleVersionTap() {
        let now = Date()
        if now.timeIntervalSince(lastVersionTapAt) > 1.5 {
            versionTapCount = 1
        } else {
            versionTapCount += 1
        }
        lastVersionTapAt = now
        if versionTapCount >= 5 {
            versionTapCount = 0
            spikeLab.toggle()
            Haptics.tick(0.6)
            notice = spikeLab ? L.t("careSpike.labEnabled") : L.t("careSpike.labDisabled")
        }
    }

    private func row(_ title: String, _ value: String, bytes: Int64? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(Ink.ink)
            Spacer()
            Text(value).foregroundStyle(Ink.inkSoft).multilineTextAlignment(.trailing).font(.system(size: Ink.Size.sub))
                .contentTransition(bytes.map { .numericText(value: Double($0)) } ?? .identity)
        }
    }

    private var denText: String {
        switch denState {
        case .asleep: "睡着"
        case .unpacking: "准备中"
        case .waking: "醒来中"
        case .awake: "醒着"
        case .broken(let why): why
        }
    }

    @ViewBuilder
    private var storageSection: some View {
        Section {
            if let storage {
                CareStorageBreakdownView(storage: storage)
                row(L.t("careStorage.total"), Self.formatBytes(storage.totalBytes), bytes: storage.totalBytes)
                row(L.t("careStorage.media"), mediaSummary(storage), bytes: storage.mediaBytes)
                row(L.t("careStorage.docCache"), Self.formatBytes(storage.docCacheBytes), bytes: storage.docCacheBytes)
                Button {
                    cleanCache()
                } label: {
                    if cleaningCache {
                        Text(L.t("careStorage.cleaning"))
                    } else if storage.cleanableBytes > 0 {
                        Text(L.format("careStorage.cleanButton", Self.formatBytes(storage.cleanableBytes)))
                            .contentTransition(.numericText(value: Double(storage.cleanableBytes)))
                    } else {
                        Text(L.t("careStorage.cleanNothing"))
                    }
                }
                .disabled(cleaningCache || storage.cleanableBytes == 0 || backupOrRestoreBusy)
                row(Words.t("斗室临时文件"), Self.formatBytes(denTempBytes), bytes: denTempBytes)
                Button {
                    cleanDenTemp()
                } label: {
                    if cleaningDenTemp {
                        Text(Words.t("正在清理斗室临时文件…"))
                    } else if denRunningBusy {
                        Text(Words.t("斗室运行中，空闲后可清理临时文件"))
                    } else if denTempBytes > 0 {
                        Text(Words.t("清理斗室临时文件（\(Self.formatBytes(denTempBytes))）"))
                    } else {
                        Text(Words.t("清理斗室临时文件（暂无）"))
                    }
                }
                .disabled(cleaningDenTemp || denRunningBusy || denTempBytes == 0 || backupOrRestoreBusy)
            } else {
                row(L.t("careStorage.total"), L.t("loading.calculating"))
            }
        } header: {
            Text(L.t("careStorage.section"))
        } footer: {
            Text(L.t("careStorage.footer"))
        }
    }

    private func mediaSummary(_ breakdown: StorageBreakdown) -> String {
        let base = Self.formatBytes(breakdown.mediaBytes)
        if breakdown.orphanMediaCount > 0 {
            return L.format("careStorage.mediaWithOrphans", base, breakdown.orphanMediaCount)
        }
        return base
    }

    fileprivate static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }

    private func measureStorage() async {
        let referenced = team.referencedMediaNames()
        let teamRoot = Disk.root
        let work = Task.detached(priority: .utility) {
            let hasWriteFailures = ChatDisk.finishWritesReportingFailures() > 0
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let breakdown = StorageCleanup.inspect(
                appSupportRoot: base,
                teamRoot: teamRoot,
                extraReferencedMedia: referenced,
                skipOrphanMedia: hasWriteFailures,
                workspaceRoot: Workspace.root
            )
            let tempBytes = Den.managedTempBytes()
            return (breakdown, tempBytes)
        }
        let (breakdown, tempBytes) = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        guard !Task.isCancelled else { return }
        withAnimation(Ink.Motion.prefersReduced(reduceMotion) ? nil : Ink.Motion.quick) {
            storage = breakdown
            denTempBytes = tempBytes
            sizeText = Self.formatBytes(breakdown.totalBytes)
        }
    }

    private func stopCleanBeforeRestore() async {
        if let pending = cleanTask {
            pending.cancel()
            await pending.value
        }
    }

    private func cleanCache() {
        guard !cleaningCache, !backupOrRestoreBusy else { return }
        cleaningCache = true
        let referenced = team.referencedMediaNames()
        let teamRoot = Disk.root
        cleanTask = Task {
            defer {
                cleaningCache = false
                cleanTask = nil
            }
            let cancelFlag = CleanupCancelFlag()
            let outcome = await withTaskCancellationHandler {
                await StorageMaintenance.run {
                    guard !cancelFlag.isSet, !Disk.frozen else { return CleanupResult() }
                    let hasWriteFailures = ChatDisk.finishWritesReportingFailures() > 0
                    return StorageCleanup.clean(
                        teamRoot: teamRoot,
                        extraReferencedMedia: referenced,
                        skipOrphanMedia: hasWriteFailures,
                        abortIf: { Disk.frozen || cancelFlag.isSet }
                    )
                }
            } onCancel: {
                cancelFlag.set()
            }
            guard !Task.isCancelled, !Disk.frozen else { return }
            Disk.forgetPhotos()
            await measureStorage()
            guard !Task.isCancelled, !Disk.frozen else { return }
            if outcome.removedMediaCount > 0 || outcome.removedDocCacheCount > 0 {
                Haptics.thud()
                notice = L.format(
                    "careStorage.cleanedNotice",
                    Self.formatBytes(outcome.freedBytes),
                    outcome.removedMediaCount,
                    outcome.removedDocCacheCount
                )
            } else {
                notice = L.t("careStorage.nothingCleaned")
            }
        }
    }

    private func cleanDenTemp() {
        guard !cleaningDenTemp, !backupOrRestoreBusy, Den.shared.running.isEmpty else { return }
        cleaningDenTemp = true
        Task {
            defer { cleaningDenTemp = false }
            let outcome = await Den.shared.cleanManagedTempFiles()
            guard !Task.isCancelled else { return }
            await measureStorage()
            guard !Task.isCancelled else { return }
            if outcome.skippedBecauseBusy {
                notice = Words.t("斗室正在执行命令，请等待结束后再清理临时文件")
            } else if outcome.removedCount > 0 || outcome.freedBytes > 0 {
                Haptics.thud()
                notice = Words.t("已清理斗室临时文件 \(Self.formatBytes(outcome.freedBytes))")
            } else {
                notice = Words.t("斗室暂时没有需要清理的临时文件")
            }
        }
    }

    private func copyReport() {
        guard !copyingReport else { return }
        copied = false
        copyingReport = true
        var prefix = ["Clio 诊断 \(Date().formatted())"]
        prefix.append("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))")
        prefix.append("\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
        prefix.append(Words.t("旅伴 \(team.bots.count)，雅集 \(team.rooms.count)，拾遗 \(team.memories.count)，数据 \(sizeText.isEmpty ? L.t("loading.calculating") : sizeText)"))
        prefix.append(Words.t("斗室：\(denText)"))
        for endpoint in team.settings.endpoints {
            prefix.append("模型服务 \(endpoint.name)（\(URL(string: endpoint.baseURL)?.host ?? "?")，\(endpoint.models.count) 个模型）：\(probes[endpoint.id] ?? "未测")")
        }
        prefix.append("设置：" + ["look.face", "look.size", "look.scheme", "chat.contextShare", "chat.compressShare", "chat.autoCompress", "chat.temperature", "chat.maxOutput", "chat.maxSteps"]
            .map { "\($0)=\(UserDefaults.standard.object(forKey: $0).map { "\($0)" } ?? "默认")" }.joined(separator: " "))
        prefix.append("最近的错误：")
        let header = prefix
        let trail = DiagTrail.reportLines(limit: 25)
        let hitches = Hitches.shared
        let hitchReport = hitches.recent.isEmpty ? nil : hitches.report(limit: 20)
        Task { @MainActor in
            defer { copyingReport = false }
            let errors = await Diag.snapshot(suffix: 20)
            var lines = header
            lines += errors
            if !trail.isEmpty {
                lines.append("近期操作轨迹（不含聊天内容）：")
                lines += trail
            }
            if let hitchReport { lines.append(hitchReport) }
            UIPasteboard.general.string = lines.joined(separator: "\n")
            Haptics.tick(0.6)
            copied = true
        }
    }

    /// Address, user and password are filled in and the address is allowed.
    private var davReady: Bool {
        !davURL.isEmpty && WebDAV.addressProblem(davURL) == nil && !davUser.isEmpty && !davPassword.isEmpty
    }

    // MARK: Backup & Restore Actions

    private func make() {
        guard !making, !cleaningCache, !restoringBusy, !restored, !Disk.frozen, pendingRestore == nil, passphraseSetup == nil else {
            return
        }
        if withKeys || encryptLocal {
            passphraseSetup = PassphraseSetupRequest(purpose: .localBackup(withKeys: withKeys))
        } else {
            performMake(withKeys: false, passphrase: nil)
        }
    }

    private func persistDavPasswordIfNeeded() {
        guard davPasswordLoaded, davPasswordDirty else { return }
        let value = davPassword
        lastSavedDavPassword = value
        davPasswordDirty = false
        CareWebDAVCoordinator.enqueuePasswordSave(value)
    }

    private func davUpload() {
        guard !davBusy, !cleaningCache, !restoringBusy, !restored, !Disk.frozen, pendingRestore == nil, passphraseSetup == nil else {
            return
        }
        persistDavPasswordIfNeeded()
        if davEncrypt {
            passphraseSetup = PassphraseSetupRequest(purpose: .webdavUpload)
        } else {
            performDavUpload(passphrase: nil)
        }
    }

    private func runPendingSetupActionIfAny() {
        guard let action = pendingSetupAction else { return }
        pendingSetupAction = nil
        handlePassphraseSetup(action.purpose, passphrase: action.passphrase)
    }

    private func handlePassphraseSetup(_ purpose: PassphrasePurpose, passphrase: String) {
        switch purpose {
        case .localBackup(let includeKeys):
            performMake(withKeys: includeKeys, passphrase: passphrase)
        case .webdavUpload:
            performDavUpload(passphrase: passphrase)
        }
    }

    private func performMake(withKeys includeKeys: Bool, passphrase: String?) {
        guard !making, !restoringBusy, !restored, !Disk.frozen else { return }
        making = true
        made = nil
        let ids = team.settings.endpoints.map(\.id)
        Task {
            await stopCleanBeforeRestore()
            let result = await StorageMaintenance.run {
                Result { try Backup.make(withKeys: includeKeys, endpoints: ids, passphrase: passphrase) }
            }
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

    private func performDavUpload(passphrase: String?) {
        guard !davBusy, !restoringBusy, !restored, !Disk.frozen else { return }
        davBusy = true
        let ids = team.settings.endpoints.map(\.id)
        Task {
            do {
                await CareWebDAVCoordinator.flushPasswordWrites()
                await stopCleanBeforeRestore()
                // Never include model API keys in WebDAV backups: remote drives sit outside the phone's keychain (review #4).
                let (url, summary) = try await StorageMaintenance.runThrowing {
                    try Backup.make(withKeys: false, endpoints: ids, passphrase: passphrase)
                }
                defer { try? FileManager.default.removeItem(at: url) }
                if made == url { made = nil }
                try await WebDAV.upload(url)
                notice = "备份到网盘了：\(url.lastPathComponent)，\(summary.files) 项，\(ByteCountFormatter.string(fromByteCount: Int64(summary.bytes), countStyle: .file))。"
            } catch {
                notice = "没备份成：\(error.localizedDescription)"
            }
            davBusy = false
        }
    }

    /// Lists the drive's backups first; the person picks one (newest at the top), then that one comes back.
    private func davRestore() {
        guard !davBusy, !cleaningCache, !restoringBusy, !making, !restored, !Disk.frozen, pendingRestore == nil else {
            return
        }
        persistDavPasswordIfNeeded()
        davBusy = true
        Task {
            do {
                await CareWebDAVCoordinator.flushPasswordWrites()
                let names = try await WebDAV.list()
                guard !names.isEmpty else { throw TeamError(message: "网盘的 Clio 文件夹里还没有备份。") }
                davChoices = names
            } catch {
                notice = "没找到网盘里的备份：\(error.localizedDescription)"
            }
            davBusy = false
        }
    }

    private func davRestore(_ name: String) {
        davChoices = []
        guard !davBusy, !restoringBusy, !restored, !Disk.frozen, pendingRestore == nil else { return }
        persistDavPasswordIfNeeded()
        CareWebDAVCoordinator.beginRestoreSession()
        davBusy = true
        restoringBusy = true
        Task {
            do {
                await CareWebDAVCoordinator.flushPasswordWrites()
                await CareWebDAVCoordinator.awaitPendingInboxCleanup()
                let file = try await WebDAV.download(name)
                let encrypted = await Task.detached(priority: .userInitiated) {
                    Backup.isEncryptedBackup(at: file)
                }.value
                davBusy = false
                let pending = PendingRestore(url: file, displayName: name, source: .webdav, wrongPassphraseHint: nil)
                if encrypted {
                    restoringBusy = false
                    pendingRestore = pending
                } else {
                    await executeRestore(pending: pending, passphrase: nil)
                }
            } catch {
                davBusy = false
                restoringBusy = false
                notice = "没恢复成：\(error.localizedDescription)"
            }
        }
    }

    private func prepareLocalRestore(from pickedURL: URL) {
        guard !restoringBusy, !restored, !Disk.frozen, pendingRestore == nil else { return }
        CareWebDAVCoordinator.beginRestoreSession()
        restoringBusy = true
        Task {
            do {
                let stagedFile = try await CareWebDAVCoordinator.stageLocalRestore(from: pickedURL) {
                    try Self.copySecurityScopedBackupToInbox($0)
                }
                let encrypted = await Task.detached(priority: .userInitiated) {
                    Backup.isEncryptedBackup(at: stagedFile)
                }.value
                let pending = PendingRestore(
                    url: stagedFile,
                    displayName: pickedURL.lastPathComponent,
                    source: .local,
                    wrongPassphraseHint: nil
                )
                if encrypted {
                    restoringBusy = false
                    pendingRestore = pending
                } else {
                    await executeRestore(pending: pending, passphrase: nil)
                }
            } catch {
                restoringBusy = false
                notice = error.localizedDescription
            }
        }
    }

    private func startUnlockRestore(pending: PendingRestore, passphrase: String) {
        guard !restoringBusy, !restored, !Disk.frozen else { return }
        restoringBusy = true
        Task { await executeRestore(pending: pending, passphrase: passphrase) }
    }

    private func executeRestore(pending: PendingRestore, passphrase: String?) async {
        guard !restored, !Disk.frozen else {
            restoringBusy = false
            return
        }
        restoringBusy = true
        team.beginBackupRestore()
        await stopCleanBeforeRestore()
        await team.waitForOpeningLeaves()
        let file = pending.url
        // Off the main thread and serialized against cache cleanup: a large backup takes a while to check and write.
        let outcome = await StorageMaintenance.run {
            Result {
                try QueuedStore.armPreRestoreBarrier(teamRoot: Disk.root)
                do {
                    let summary = try Backup.restore(from: file, passphrase: passphrase)
                    QueuedStore.clearAllPendingLeafOpens()
                    let report = QueuedStore.isolatePreRestoreQueues()
                    return (summary, report)
                } catch {
                    QueuedStore.disarmPreRestoreBarrier()
                    throw error
                }
            }
        }
        restoringBusy = false

        switch outcome {
        case .success(let (summary, report)):
            try? FileManager.default.removeItem(at: file)
            let hadUnlockSheet = pendingRestore != nil
            team.finishBackupRestoreSucceeded()
            restored = true
            let resultNotice: String
            if pending.source == .webdav {
                resultNotice = "从网盘恢复了「\(pending.displayName)」，\(summary.files) 项。要关掉 Clio 再打开才会生效。" + Self.isolationNotice(report)
            } else {
                resultNotice = "恢复了 \(summary.files) 项。要关掉 Clio 再打开才会生效；在那之前不会再保存任何东西。" + Self.isolationNotice(report)
            }
            if hadUnlockSheet {
                deferredNoticeAfterUnlock = resultNotice
                pendingRestore = nil
            } else {
                pendingRestore = nil
                notice = resultNotice
            }
        case .failure(let error):
            team.finishBackupRestoreFailed()
            if let cryptoError = error as? BackupCryptoError,
               cryptoError == .passphraseRequired || cryptoError == .emptyPassphrase || cryptoError == .authenticationFailed {
                let hint: String?
                if passphrase == nil && cryptoError == .passphraseRequired {
                    hint = nil
                } else {
                    hint = cryptoError.localizedDescription
                }
                if var active = pendingRestore, active.id == pending.id {
                    active.wrongPassphraseHint = hint
                    pendingRestore = active
                } else {
                    pendingRestore = PendingRestore(
                        id: pending.id,
                        url: pending.url,
                        displayName: pending.displayName,
                        source: pending.source,
                        wrongPassphraseHint: hint
                    )
                }
                return
            }
            try? FileManager.default.removeItem(at: file)
            let hadUnlockSheet = pendingRestore != nil
            let failureNotice = pending.source == .webdav
                ? "没恢复成：\(error.localizedDescription)"
                : error.localizedDescription
            if hadUnlockSheet {
                deferredNoticeAfterUnlock = failureNotice
                pendingRestore = nil
            } else {
                pendingRestore = nil
                notice = failureNotice
            }
        }
    }

    private func cancelPendingRestore() {
        guard !restoringBusy else { return }
        let pendingURL = pendingRestore?.url
        deferredNoticeAfterUnlock = nil
        pendingRestore = nil
        CareWebDAVCoordinator.scheduleInboxCleanup(removing: pendingURL)
    }

    private func handleUnlockSheetDismissed() {
        if !restoringBusy && pendingRestore == nil {
            CareWebDAVCoordinator.scheduleInboxCleanup()
        }
        if let deferred = deferredNoticeAfterUnlock {
            deferredNoticeAfterUnlock = nil
            notice = deferred
        }
    }

    private nonisolated static func copySecurityScopedBackupToInbox(_ url: URL) throws -> URL {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        var st = stat()
        guard lstat(url.path, &st) == 0 else {
            throw TeamError(message: "找不到选择的备份文件。")
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            throw TeamError(message: "选择的备份不是普通文件（可能是快捷方式或文件夹），已拒绝恢复。")
        }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values?.isSymbolicLink != true, values?.isRegularFile == true else {
            throw TeamError(message: "选择的备份文件无效，已拒绝恢复。")
        }
        guard st.st_size > 0 else {
            throw TeamError(message: "备份文件是空的。")
        }
        guard st.st_size <= Int64(Backup.maxBackupFileBytes) else {
            throw TeamError(message: "备份文件太大，无法安全恢复。")
        }

        let manager = FileManager.default
        let inbox = WebDAV.restoreInboxDirectory
        try manager.createDirectory(at: inbox, withIntermediateDirectories: true)
        let target = inbox.appendingPathComponent("local-\(UUID().uuidString).clio-backup")
        let protection: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        guard manager.createFile(atPath: target.path, contents: nil, attributes: protection) else {
            throw TeamError(message: "没能在手机上暂存备份文件。")
        }

        var copied = false
        defer {
            if !copied {
                try? manager.removeItem(at: target)
            }
        }

        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        let writer = try FileHandle(forWritingTo: target)
        var writerClosed = false
        defer {
            if !writerClosed {
                try? writer.close()
            }
        }

        var totalBytes = 0
        let chunkSize = 1 << 20
        while true {
            let chunk = try autoreleasepool {
                try reader.read(upToCount: chunkSize)
            }
            guard let chunk, !chunk.isEmpty else { break }
            totalBytes += chunk.count
            guard totalBytes <= Backup.maxBackupFileBytes else {
                throw TeamError(message: "备份文件太大，无法安全恢复。")
            }
            try writer.write(contentsOf: chunk)
        }
        guard totalBytes > 0 else {
            throw TeamError(message: "备份文件是空的。")
        }
        try writer.synchronize()
        try writer.close()
        writerClosed = true
        try? manager.setAttributes(protection, ofItemAtPath: target.path)
        copied = true
        return target
    }

    private static func isolationNotice(_ report: IsolationReport) -> String {
        var notes: [String] = []
        if report.isolatedMessages > 0 {
            if report.readableExportSucceeded {
                notes.append(Words.t("恢复前有 \(report.isolatedMessages) 条未发出的排队消息，已移出活跃队列并另存到书案「恢复前排队」文件夹，不会混进恢复后的对话。"))
            } else {
                notes.append(Words.t("恢复前有 \(report.isolatedMessages) 条未发出的排队消息已移出活跃队列（不会混进恢复后的对话），但导出到书案「恢复前排队」失败，原始副本保留在应用隔离目录。"))
            }
        }
        if report.failedMessages > 0 {
            notes.append("注意：恢复前另有 \(report.failedMessages) 条排队消息暂时未能移出磁盘目录，已记录拦截标记，重启后会自动重试隔离且不会发进恢复后的对话。")
        }
        return notes.isEmpty ? "" : "\n" + notes.joined(separator: "\n")
    }

    /// 「Clio 备份 2026-11-22 0730.clio」 → 「2026-11-22 07:30」.
    private static func backupLabel(_ name: String) -> String {
        var text = name
        if text.hasPrefix("Clio 备份 ") { text.removeFirst("Clio 备份 ".count) }
        if let dot = text.lastIndex(of: ".") { text = String(text[..<dot]) }
        let parts = text.split(separator: " ")
        if parts.count == 2, parts[1].count == 4 {
            return "\(parts[0]) \(parts[1].prefix(2)):\(parts[1].suffix(2))"
        }
        return text
    }

    private func probe() {
        probing = true
        Task {
            for endpoint in team.settings.endpoints {
                probes[endpoint.id] = "在试…"
                guard let model = endpoint.models.first, let key = await team.readAPIKey(for: endpoint), !key.isEmpty else {
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

// MARK: Passphrase Sheets

private enum RestoreSource: Sendable {
    case local
    case webdav
}

private enum PassphrasePurpose: Equatable, Sendable {
    case localBackup(withKeys: Bool)
    case webdavUpload
}

private struct PassphraseSetupRequest: Identifiable, Sendable {
    let id = UUID()
    let purpose: PassphrasePurpose
}

private struct PendingSetupAction: Sendable {
    let purpose: PassphrasePurpose
    let passphrase: String
}

private struct PendingRestore: Identifiable, Equatable, Sendable {
    let id: UUID
    let url: URL
    let displayName: String
    let source: RestoreSource
    var wrongPassphraseHint: String?

    init(
        id: UUID = UUID(),
        url: URL,
        displayName: String,
        source: RestoreSource,
        wrongPassphraseHint: String?
    ) {
        self.id = id
        self.url = url
        self.displayName = displayName
        self.source = source
        self.wrongPassphraseHint = wrongPassphraseHint
    }
}

private struct PassphraseSetupSheet: View {
    private static let minimumLength = 8

    let purpose: PassphrasePurpose
    let onCancel: () -> Void
    let onConfirm: (String) -> Void

    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var reveal = false

    private var trimmedEmpty: Bool {
        passphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var validationError: String? {
        if !passphrase.isEmpty && trimmedEmpty {
            return L.t("backupCrypto.whitespaceError")
        }
        if !passphrase.isEmpty && passphrase.count < Self.minimumLength {
            return L.format("backupCrypto.minLengthError", Self.minimumLength)
        }
        if !confirmation.isEmpty && confirmation != passphrase {
            return L.t("backupCrypto.mismatchError")
        }
        return nil
    }

    private var canSubmit: Bool {
        !trimmedEmpty && passphrase.count >= Self.minimumLength && confirmation == passphrase
    }

    private var subtitle: String {
        switch purpose {
        case .localBackup:
            return L.t("backupCrypto.setupSubtitleLocal")
        case .webdavUpload:
            return L.t("backupCrypto.setupSubtitleWebDAV")
        }
    }

    private var confirmTitle: String {
        switch purpose {
        case .localBackup:
            return L.t("backupCrypto.confirmAndCreate")
        case .webdavUpload:
            return L.t("backupCrypto.confirmAndUpload")
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Ink.paper.ignoresSafeArea()
                ScrollView {
                    sheetContent
                        .padding(.horizontal, Ink.Space.page)
                        .padding(.vertical, Ink.Space.l)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L.t("actions.cancel")) {
                        Haptics.light()
                        onCancel()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(confirmTitle) {
                        Haptics.tick(0.6)
                        onConfirm(passphrase)
                    }
                    .fontWeight(.semibold)
                    .disabled(!canSubmit)
                }
            }
        }
    }

    private var sheetContent: some View {
        VStack(alignment: .leading, spacing: Ink.Space.l) {
            HStack(spacing: Ink.Space.m) {
                IconBadge(symbol: "lock", tint: Ink.Tile.zhu, size: 44 * UIScale.factor)
                VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
                    Text(L.t("backupCrypto.setupTitle"))
                        .font(Ink.mark(Ink.Size.title, bold: true, relativeTo: .title2))
                        .foregroundStyle(Ink.ink)
                    Text(subtitle)
                        .font(Ink.footnote)
                        .foregroundStyle(Ink.inkSoft)
                }
            }

            VStack(spacing: 0) {
                passphraseInputRow(
                    placeholder: L.t("backupCrypto.passphraseField"),
                    text: $passphrase,
                    showRevealToggle: true
                )
                Kit.rule(inset: Ink.Space.l)
                passphraseInputRow(
                    placeholder: L.t("backupCrypto.confirmField"),
                    text: $confirmation,
                    showRevealToggle: false
                )
            }
            .paperCard()

            if let validationError {
                Text(validationError)
                    .font(Ink.footnote)
                    .foregroundStyle(passphrase.count < Self.minimumLength && !trimmedEmpty && confirmation.isEmpty ? Ink.warn : Ink.stop)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Label(L.t("backupCrypto.unrecoverableNote"), systemImage: "exclamationmark.triangle.fill")
                .font(Ink.footnote)
                .foregroundStyle(Ink.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func passphraseInputRow(placeholder: String, text: Binding<String>, showRevealToggle: Bool) -> some View {
        HStack(spacing: Ink.Space.s) {
            if reveal {
                TextField(placeholder, text: text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(Ink.secondary)
                    .foregroundStyle(Ink.ink)
            } else {
                SecureField(placeholder, text: text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(Ink.secondary)
                    .foregroundStyle(Ink.ink)
            }
            if showRevealToggle {
                Button {
                    reveal.toggle()
                    Haptics.light()
                } label: {
                    Image(systemName: reveal ? "eye.slash" : "eye")
                        .font(Ink.secondary)
                        .foregroundStyle(Ink.inkSoft)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(TapStyle())
                .accessibilityLabel(reveal ? L.t("backupCrypto.hidePassphrase") : L.t("backupCrypto.showPassphrase"))
            }
        }
        .padding(.horizontal, Ink.Space.l)
        .frame(minHeight: Kit.rowHeight)
    }
}

private struct PassphraseUnlockSheet: View {
    let displayName: String
    let errorMessage: String?
    @Binding var busy: Bool
    let onCancel: () -> Void
    let onSubmit: (String) -> Void

    @State private var passphrase = ""
    @State private var reveal = false

    private var canSubmit: Bool {
        !busy && !passphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Ink.paper.ignoresSafeArea()
                ScrollView {
                    sheetContent
                        .padding(.horizontal, Ink.Space.page)
                        .padding(.vertical, Ink.Space.l)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L.t("actions.cancel")) {
                        Haptics.light()
                        onCancel()
                    }
                    .disabled(busy)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L.t("backupCrypto.unlockAndRestore")) {
                        guard canSubmit else { return }
                        Haptics.tick(0.6)
                        onSubmit(passphrase)
                    }
                    .fontWeight(.semibold)
                    .disabled(!canSubmit)
                }
            }
        }
        .interactiveDismissDisabled(busy)
    }

    private var sheetContent: some View {
        VStack(alignment: .leading, spacing: Ink.Space.l) {
            HStack(spacing: Ink.Space.m) {
                IconBadge(symbol: "key", tint: Ink.Tile.dai, size: 44 * UIScale.factor)
                VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
                    Text(L.t("backupCrypto.unlockTitle"))
                        .font(Ink.mark(Ink.Size.title, bold: true, relativeTo: .title2))
                        .foregroundStyle(Ink.ink)
                    Text(L.t("backupCrypto.unlockSubtitle"))
                        .font(Ink.footnote)
                        .foregroundStyle(Ink.inkSoft)
                }
            }

            Text(L.format("backupCrypto.unlockFileLabel", displayName))
                .font(Ink.footnote)
                .foregroundStyle(Ink.inkSoft)
                .lineLimit(2)

            VStack(spacing: 0) {
                HStack(spacing: Ink.Space.s) {
                    if reveal {
                        TextField(L.t("backupCrypto.passphraseField"), text: $passphrase)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(Ink.secondary)
                            .foregroundStyle(Ink.ink)
                            .disabled(busy)
                    } else {
                        SecureField(L.t("backupCrypto.passphraseField"), text: $passphrase)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(Ink.secondary)
                            .foregroundStyle(Ink.ink)
                            .disabled(busy)
                    }
                    Button {
                        reveal.toggle()
                        Haptics.light()
                    } label: {
                        Image(systemName: reveal ? "eye.slash" : "eye")
                            .font(Ink.secondary)
                            .foregroundStyle(Ink.inkSoft)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(TapStyle())
                    .disabled(busy)
                    .accessibilityLabel(reveal ? L.t("backupCrypto.hidePassphrase") : L.t("backupCrypto.showPassphrase"))
                }
                .padding(.horizontal, Ink.Space.l)
                .frame(minHeight: Kit.rowHeight)
            }
            .paperCard()

            if busy {
                HStack(spacing: Ink.Space.s) {
                    ProgressView()
                    Text(L.t("backupCrypto.decryptingAndRestoring"))
                        .font(Ink.footnote)
                        .foregroundStyle(Ink.inkSoft)
                }
            } else if let errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(Ink.footnote)
                    .foregroundStyle(Ink.stop)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct CareStorageBreakdownView: View {
    let storage: StorageBreakdown
    @Environment(\.dynamicTypeSize) private var typeSize

    private struct Segment: Identifiable {
        let id: String
        let bytes: Int64
        let tint: Color
    }

    private var segments: [Segment] {
        var list = [
            Segment(id: "careStorage.segChats", bytes: storage.chatsBytes, tint: Ink.Tile.dai),
            Segment(id: "careStorage.segStudy", bytes: storage.studyBytes, tint: Ink.Tile.zhu),
            Segment(id: "careStorage.segMedia", bytes: storage.activeMediaBytes, tint: Ink.Tile.xiang),
            Segment(id: "careStorage.segMemory", bytes: storage.memoryBytes, tint: Ink.Tile.teng),
            Segment(id: "careStorage.segCache", bytes: storage.cacheBytes, tint: Ink.Tile.mo),
        ]
        if storage.otherBytes > 0 {
            list.append(Segment(id: "careStorage.segOther", bytes: storage.otherBytes, tint: Ink.inkFaint.opacity(0.65)))
        }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            Text(L.t("careStorage.breakdownTitle")).font(Ink.label).foregroundStyle(Ink.ink)
                .accessibilityAddTraits(.isHeader)
            bar
            let columns = Array(repeating: GridItem(.flexible(), spacing: Ink.Space.m), count: typeSize.isAccessibilitySize ? 1 : 2)
            LazyVGrid(columns: columns, alignment: .leading, spacing: Ink.Space.s) {
                ForEach(segments) { legend($0) }
            }
        }
        .padding(.vertical, Ink.Space.xs)
    }

    private var bar: some View {
        let visible = segments.filter { $0.bytes > 0 }
        let counted = visible.reduce(Int64(0)) { $0 + $1.bytes }
        let total = max(counted, storage.totalBytes)
        let gap = 2 * UIScale.factor
        return GeometryReader { geometry in
            if total > 0, !visible.isEmpty {
                let available = max(0, geometry.size.width - gap * CGFloat(max(0, visible.count - 1)))
                let sliceWidths = resolvedBarWidths(for: visible, total: total, available: available)
                HStack(spacing: gap) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, segment in
                        Capsule().fill(segment.tint)
                            .frame(width: sliceWidths[index])
                    }
                }
            }
        }
        .frame(height: 10 * UIScale.factor)
        .background(Ink.surfaceSubtle, in: .capsule)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }

    private func resolvedBarWidths(for visible: [Segment], total: Int64, available: CGFloat) -> [CGFloat] {
        guard available > 0, total > 0, !visible.isEmpty else {
            return Array(repeating: 0, count: visible.count)
        }
        let minWidth = min(6 * UIScale.factor, available / CGFloat(visible.count))
        var widths = visible.map { max(minWidth, available * CGFloat($0.bytes) / CGFloat(total)) }
        let excess = widths.reduce(0, +) - available
        if excess > 0.5 {
            let reducible = widths.map { max(0, $0 - minWidth) }
            let reducibleSum = reducible.reduce(0, +)
            if reducibleSum > 0 {
                for idx in widths.indices {
                    widths[idx] -= excess * (reducible[idx] / reducibleSum)
                }
            }
        }
        return widths
    }

    private func legend(_ segment: Segment) -> some View {
        HStack(spacing: Ink.Space.xs) {
            Circle().fill(segment.tint)
                .frame(width: 6 * UIScale.factor, height: 6 * UIScale.factor)
                .accessibilityHidden(true)
            Text(L.t(segment.id)).foregroundStyle(Ink.inkSoft)
            Spacer(minLength: 0)
            Text(CarePage.formatBytes(segment.bytes))
                .foregroundStyle(Ink.ink)
                .contentTransition(.numericText(value: Double(segment.bytes)))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .font(Ink.footnote)
        .accessibilityElement(children: .combine)
    }
}

private final class CleanupCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func set() { lock.withLock { cancelled = true } }
    var isSet: Bool { lock.withLock { cancelled } }
}

/// Globally serializes cache cleanup against backup creation and restoration across CarePage lifetimes
/// so `StorageCleanup.clean` can never overlap `Backup.restore` swapping `Team/`.
private enum StorageMaintenance {
    private static let queue = DispatchQueue(label: "clio.storage-maintenance", qos: .userInitiated)

    static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: work())
            }
        }
    }

    static func runThrowing<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

private struct HitchRow: Identifiable, Equatable, Sendable {
    let id: String
    let line: String
    let severe: Bool
}

private struct HitchSettings: View {
    @State private var rows: [HitchRow] = []
    @State private var totalCount = 0
    @State private var lastVersion: UInt64 = .max
    @State private var hitchesCopied = false
    @AppStorage("look.fps") private var fps = false
    @AppStorage("care.hitches") private var recordingHitches = false

    var body: some View {
        Section {
            Toggle(L.t("settings.showFrameRate"), isOn: $fps)
            Toggle(L.t("settings.recordHitches"), isOn: $recordingHitches)
            if rows.isEmpty {
                Text(recordingHitches ? "还没有记到卡顿。照常用一会儿，卡了再回来看。" : "打开后，Clio 会记下每一次卡顿。").foregroundStyle(Ink.inkSoft)
            } else {
                ForEach(rows) { row in
                    Text(row.line).font(Ink.mono(Ink.Size.small)).foregroundStyle(row.severe ? Ink.stop : Ink.inkSoft)
                }
                Button(hitchesCopied ? "复制好了，贴给我就行" : "复制掉帧记录（\(totalCount) 条）") {
                    UIPasteboard.general.string = Hitches.shared.report
                    hitchesCopied = true
                    Haptics.tick(0.6)
                }
                Button("清空掉帧记录", role: .destructive) {
                    Hitches.shared.clear()
                    rows = []
                    totalCount = 0
                    lastVersion = Hitches.shared.version
                    hitchesCopied = false
                }
            }
        } header: { Text(L.t("settings.frameDrops")) } footer: {
            Text(L.t("settings.recordHitchesNote"))
        }
        .task(id: recordingHitches) {
            await Hitches.shared.waitForInitialLoad()
            guard !Task.isCancelled else { return }
            await refreshHitches(force: true)
            guard recordingHitches else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(1200))
                } catch {
                    return
                }
                await refreshHitches(force: false)
            }
        }
    }

    private func refreshHitches(force: Bool) async {
        let version = Hitches.shared.version
        guard force || version != lastVersion else { return }
        let rawHitches = Array(Hitches.shared.recent.suffix(15).reversed())
        let total = Hitches.shared.recent.count
        let formatted = await Task.detached(priority: .utility) {
            rawHitches.enumerated().map { index, hitch in
                HitchRow(
                    id: "\(hitch.at.timeIntervalSinceReferenceDate)-\(hitch.ms)-\(index)",
                    line: hitch.line,
                    severe: hitch.ms >= 100
                )
            }
        }.value
        guard !Task.isCancelled else { return }
        // Do not resurrect rows if the user cleared hitches while formatting ran off-main.
        if Hitches.shared.version != version && Hitches.shared.recent.isEmpty {
            rows = []
            totalCount = 0
            lastVersion = Hitches.shared.version
            hitchesCopied = false
            return
        }
        if total != totalCount || rows != formatted {
            hitchesCopied = false
        }
        rows = formatted
        totalCount = total
        lastVersion = version
    }
}

private struct ArchivedChatPreviewRow: Identifiable, Equatable, Sendable {
    let key: String
    let name: String
    let title: String?
    var id: String { key }
}

private struct ArchivedChatOptionsPayload: Decodable, Sendable {
    var title: String?
}

private struct CareArchivedSection: View {
    let team: TeamModel
    @State private var archivedKeys: [String] = []
    @State private var rows: [ArchivedChatPreviewRow] = []

    var body: some View {
        Section {
            if archivedKeys.isEmpty {
                Text(L.t("empty.archivedChats")).foregroundStyle(Ink.inkSoft)
            } else {
                ForEach(rows) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
                            Text(entry.name).foregroundStyle(Ink.ink)
                            if let title = entry.title {
                                Text(title).font(Ink.footnote).foregroundStyle(Ink.inkSoft)
                            }
                        }
                        Spacer()
                        Button(L.t("actions.restore")) {
                            withAnimation(Ink.Motion.settle) { team.archive(entry.key, false) }
                            Haptics.tick(0.6)
                        }
                        .fontWeight(.medium)
                    }
                }
            }
        } header: {
            Text(L.t("settings.archivedConversations"))
        } footer: {
            Text(L.t("settings.archivedRestoreNote"))
        }
        .onAppear {
            let sorted = team.archived.sorted()
            if archivedKeys != sorted { archivedKeys = sorted }
        }
        .onReceive(team.$archived.removeDuplicates()) { updated in
            let sorted = updated.sorted()
            if archivedKeys != sorted { archivedKeys = sorted }
        }
        .task(id: archivedKeys) {
            await loadArchivedRows(for: archivedKeys)
        }
    }

    private func loadArchivedRows(for keys: [String]) async {
        guard !keys.isEmpty else {
            rows = []
            return
        }
        let keeping = team.keeping
        let initial = keys.map { key -> (key: String, name: String, cachedTitle: String?, needsDisk: Bool, optionsURL: URL) in
            let name = team.chatName(key)
            if let cached = team.optionBook[key] {
                return (key, name, cached.title, false, Disk.url(TeamModel.optionsFile(key)))
            }
            return (key, name, nil, keeping, Disk.url(TeamModel.optionsFile(key)))
        }
        // Seed rows immediately with names and any cached titles so layout is instant.
        rows = initial.map { ArchivedChatPreviewRow(key: $0.key, name: $0.name, title: $0.cachedTitle) }
        let diskJobs = initial.filter(\.needsDisk).map { (key: $0.key, url: $0.optionsURL) }
        guard !diskJobs.isEmpty else { return }
        let loadedTitles = await Task.detached(priority: .utility) {
            var resolved: [String: String] = [:]
            for job in diskJobs {
                if Task.isCancelled { break }
                guard let data = try? Data(contentsOf: job.url),
                      let payload = try? JSONDecoder().decode(ArchivedChatOptionsPayload.self, from: data),
                      let title = payload.title else { continue }
                resolved[job.key] = title
            }
            return resolved
        }.value
        guard !Task.isCancelled else { return }
        rows = initial.map { entry in
            ArchivedChatPreviewRow(
                key: entry.key,
                name: entry.name,
                title: entry.cachedTitle ?? loadedTitles[entry.key]
            )
        }
    }
}

private struct CareConnectivitySection: View {
    let team: TeamModel
    @Binding var probes: [String: String]
    @Binding var probing: Bool
    let onProbe: () -> Void
    @State private var endpoints: [Endpoint] = []

    var body: some View {
        Section {
            ForEach(endpoints) { endpoint in
                HStack(alignment: .firstTextBaseline) {
                    Text(endpoint.name).foregroundStyle(Ink.ink)
                    Spacer()
                    Text(probes[endpoint.id] ?? "未测")
                        .foregroundStyle(Ink.inkSoft)
                        .multilineTextAlignment(.trailing)
                        .font(.system(size: Ink.Size.sub))
                }
            }
            Button(probing ? L.t("loading.testingModels") : L.t("actions.testProviderConnections")) { onProbe() }
                .disabled(probing || endpoints.isEmpty)
        } header: {
            Text(L.t("settings.modelConnectivity"))
        }
        .onAppear {
            if endpoints != team.settings.endpoints { endpoints = team.settings.endpoints }
        }
        .onReceive(team.$settings) { updated in
            if endpoints != updated.endpoints { endpoints = updated.endpoints }
        }
    }
}

private enum CareWebDAVCoordinator {
    private static let passwordQueue = DispatchQueue(label: "clio.care.webdav.password", qos: .userInitiated)
    private static let inboxQueue = DispatchQueue(label: "clio.care.webdav.inbox", qos: .userInitiated)
    private static let stateLock = NSLock()
    nonisolated(unsafe) private static var inboxGeneration: UInt64 = 0

    static func loadPassword() async -> String {
        await withCheckedContinuation { continuation in
            passwordQueue.async {
                continuation.resume(returning: WebDAV.password)
            }
        }
    }

    static func enqueuePasswordSave(_ value: String) {
        passwordQueue.async {
            WebDAV.setPassword(value)
        }
    }

    static func flushPasswordWrites() async {
        await withCheckedContinuation { continuation in
            passwordQueue.async {
                continuation.resume()
            }
        }
    }

    static func scheduleInboxCleanup(removing pendingURL: URL? = nil) {
        let token = stateLock.withLock { inboxGeneration }
        inboxQueue.async {
            let current = stateLock.withLock { inboxGeneration }
            guard current == token else { return }
            if let pendingURL {
                try? FileManager.default.removeItem(at: pendingURL)
            }
            WebDAV.cleanupRestoreInbox()
        }
    }

    static func beginRestoreSession() {
        stateLock.withLock {
            inboxGeneration &+= 1
        }
    }

    static func awaitPendingInboxCleanup() async {
        await withCheckedContinuation { continuation in
            inboxQueue.async {
                continuation.resume()
            }
        }
    }

    static func stageLocalRestore(
        from pickedURL: URL,
        copy: @escaping @Sendable (URL) throws -> URL
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            inboxQueue.async {
                do {
                    continuation.resume(returning: try copy(pickedURL))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
