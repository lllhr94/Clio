import AgentKit
import Craft
import PhotosUI
import SwiftUI

struct SettingsView: View {
    @ObservedObject var team: TeamModel
    /// The destination in a `clio://settings/<page>` link.
    var startAt: String? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @ObservedObject private var hills = Hills.shared

    @AppStorage("look.scheme") private var scheme = "system"
    @AppStorage("lock.faceid") private var faceLock = false
    @AppStorage(WebDAV.urlKey) private var davURL = ""
    @AppStorage("morning.on") private var morningOn = false
    @AppStorage("diary.on") private var diaryOn = false
    @AppStorage("notify.done") private var notifyDone = true
    @AppStorage("live.on") private var liveOn = true
    @AppStorage(VoiceTranscription.modeKey) private var voiceModeRaw = VoiceTranscription.Mode.system.rawValue
    @AppStorage(VoiceTranscription.modelKey) private var voiceModel = ""
    @AppStorage(SearchEngine.providerKey) private var searchProviderRaw = WebSearchProvider.builtin.rawValue

    @State private var storageBytes: Int64?
    @State private var path = NavigationPath()
    @State private var query = ""
    @State private var searching = false
    @State private var sheet: SettingsPage?
    @State private var creatingBot = false
    @State private var editingBot: BotInfo?
    @State private var creatingRoom = false
    @State private var editingRoom: RoomInfo?

    static let groups: [(title: String, tint: Color, pages: [SettingsPage])] = [
        ("settingsHome.modelsAndCapsGroup", Ink.Tile.dai, [.services, .models, .capabilities]),
        ("settingsHome.companionsExperienceGroup", Ink.Tile.yan, [.companions, .memoryAndRoutine, .appearance, .chatAndVoice]),
        ("settingsHome.securityAndDataGroup", Ink.Tile.mo, [.notifications, .privacy, .care]),
    ]

    static let hubChildren: [SettingsPage: [SettingsPage]] = [
        .capabilities: [.grants, .searchEngine, .connectors, .skills, .hosts],
        .memoryAndRoutine: [.memory, .timing],
        .appearance: [.theme, .size, .tone, .pet],
        .chatAndVoice: [.display, .context, .voice],
        .care: [.careBackup, .careUsage, .careStorage, .careDiagnostics],
    ]

    static let searchAliases: [SettingsPage: SettingsPage] = [
        .grants: .capabilities,
        .searchEngine: .capabilities,
        .connectors: .capabilities,
        .skills: .capabilities,
        .hosts: .capabilities,
        .image: .models,
        .rooms: .companions,
        .memory: .memoryAndRoutine,
        .timing: .memoryAndRoutine,
        .morning: .memoryAndRoutine,
        .theme: .appearance,
        .size: .appearance,
        .font: .appearance,
        .tone: .appearance,
        .pet: .appearance,
        .display: .chatAndVoice,
        .context: .chatAndVoice,
        .voice: .chatAndVoice,
        .lock: .privacy,
        .vault: .privacy,
        .careBackup: .care,
        .careUsage: .care,
        .careStorage: .care,
        .careDiagnostics: .care,
        .about: .care,
    ]

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                listContent
            }
            .scrollEdgeEffectStyle(.soft, for: .vertical)
            .background(Ink.paper.ignoresSafeArea())
            .searchable(text: $query, isPresented: $searching, placement: .navigationBarDrawer(displayMode: .automatic),
                        prompt: L.t("settingsHome.search"))
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .hitchPage("调弦")
            .navigationTitle(L.t("nav.settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L.t("actions.done")) { Haptics.light(); dismiss() }
                }
            }
            .navigationDestination(for: SettingsPage.self, destination: destination)
            .task { await measureQuickStorage() }
        }
        .clioScheme(scheme)
        .task {
            guard let startAt, let page = SettingsPage(link: startAt) else { return }
            if page.opensSheet {
                // Wait for the full-screen settings presentation before opening a second one.
                do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
            }
            open(page)
        }
        .sheet(item: $sheet, content: sheetContent)
        .sheet(isPresented: $creatingBot) { BotEditor(team: team, bot: nil) }
        .sheet(item: $editingBot) { BotEditor(team: team, bot: $0) }
        .sheet(isPresented: $creatingRoom) { RoomEditor(team: team) }
        .sheet(item: $editingRoom) { RoomEditor(team: team, room: $0) }
    }

    private var listContent: some View {
        LazyVStack(alignment: .leading, spacing: Ink.Space.xl) {
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                identityHeader
                quickStatus
                ForEach(Self.groups, id: \.title) { group in
                    RowCard(title: L.t(group.title)) {
                        ForEach(group.pages) { page in pageRow(page, group.tint) }
                    }
                }
                aboutFooter
            } else {
                searchResults
            }
        }
        .padding(.horizontal, Ink.Space.page)
        .padding(.vertical, Ink.Space.l)
    }

    private var primaryBot: BotInfo? {
        team.bots.first { $0.id == team.mainBotId } ?? team.bots.first
    }

    private var identityHeader: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Ink.Space.m))
            : AnyLayout(HStackLayout(spacing: Ink.Space.m))
        return layout {
            Button {
                Haptics.light()
                if let bot = primaryBot {
                    editingBot = bot
                } else {
                    open(.companions)
                }
            } label: {
                HStack(spacing: Ink.Space.m) {
                    if let bot = primaryBot {
                        CompanionAvatar(size: 36 * UIScale.factor, wash: Ink.wash(for: bot), bot: bot)
                    } else {
                        IconBadge(symbol: "person.2", tint: Ink.Tile.yan, size: 36 * UIScale.factor)
                    }
                    VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
                        Text(primaryBot?.name ?? L.t("settingsHome.identityDefaultBot"))
                            .font(.system(size: Ink.Size.sub, weight: .semibold))
                            .foregroundStyle(Ink.ink)
                            .lineLimit(1)
                        Text(L.t("settingsHome.identityDefaultBot"))
                            .font(.system(size: Ink.Size.micro))
                            .foregroundStyle(Ink.inkSoft)
                            .lineLimit(1)
                    }
                    Spacer(minLength: Ink.Space.xs)
                    Kit.chevron
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle(haptic: false))
            .frame(maxWidth: .infinity, alignment: .leading)

            if typeSize.isAccessibilitySize {
                Kit.rule(inset: 0)
            } else {
                Rectangle()
                    .fill(Ink.rule)
                    .frame(width: 0.5, height: 32 * UIScale.factor)
            }

            SettingsUserAvatarButton()
        }
        .padding(Ink.Space.l)
        .paperCard()
    }

    private var servicesStatus: String {
        let count = team.settings.endpoints.count
        return count == 0 ? L.t("settingsHome.notConnected") : L.format("settingsHome.connectedCount", count)
    }

    private var servicesTint: Color { team.settings.endpoints.isEmpty ? Ink.warn : Ink.ok }

    private var defaultModelName: String {
        guard team.resolve(team.settings.defaultModel) != nil else { return L.t("settingsHome.unset") }
        return team.modelShort(team.settings.defaultModel)
    }

    private var backupStatus: String {
        L.t(davURL.isEmpty ? "settingsHome.quickBackupUnset" : "settingsHome.quickBackupReady")
    }

    private var quickStatus: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(spacing: Ink.Space.s) {
                    statusTile("settingsHome.quickServices", value: servicesStatus, dot: servicesTint, page: .services)
                    statusTile("settingsHome.quickStorage", value: storageValueText, dot: storageDotColor, page: .careStorage)
                    statusTile("settingsHome.quickModel", value: defaultModelName, page: .models)
                }
            } else {
                VStack(spacing: Ink.Space.s) {
                    HStack(spacing: Ink.Space.s) {
                        statusTile("settingsHome.quickServices", value: servicesStatus, dot: servicesTint, page: .services)
                        statusTile("settingsHome.quickStorage", value: storageValueText, dot: storageDotColor, page: .careStorage)
                    }
                    wideModelStatusTile
                }
            }
        }
    }

    private var storageValueText: String {
        storageBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? backupStatus
    }

    private var storageDotColor: Color {
        storageBytes != nil || !davURL.isEmpty ? Ink.ok : Ink.inkFaint
    }

    private func statusTile(_ title: String, value: String, dot: Color? = nil, page: SettingsPage) -> some View {
        Button {
            Haptics.light()
            open(page)
        } label: {
            VStack(alignment: .leading, spacing: Ink.Space.xs) {
                Text(L.t(title)).font(Ink.footnote).foregroundStyle(Ink.inkSoft)
                HStack(spacing: Ink.Space.xs) {
                    if let dot {
                        Circle().fill(dot).frame(width: 6 * UIScale.factor, height: 6 * UIScale.factor)
                            .accessibilityHidden(true)
                    }
                    Text(value).font(Ink.label).foregroundStyle(Ink.ink)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .padding(Ink.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .paperCard()
        }
        .buttonStyle(PressStyle(elevated: true))
    }

    private var wideModelStatusTile: some View {
        Button {
            Haptics.light()
            open(.models)
        } label: {
            HStack(spacing: Ink.Space.s) {
                Text(L.t("settingsHome.quickModel"))
                    .font(Ink.footnote)
                    .foregroundStyle(Ink.inkSoft)
                    .layoutPriority(0)
                Spacer(minLength: Ink.Space.s)
                Text(defaultModelName)
                    .font(Ink.label)
                    .foregroundStyle(Ink.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.85)
                    .layoutPriority(1)
                Kit.chevron
            }
            .padding(.horizontal, Ink.Space.l)
            .padding(.vertical, Ink.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .paperCard()
        }
        .buttonStyle(PressStyle(elevated: true))
    }

    private func measureQuickStorage() async {
        let work = Task.detached(priority: .utility) { () -> Int64? in
            guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                return nil
            }
            return StorageCleanup.totalSize(appSupportRoot: base, workspaceRoot: Workspace.root)
        }
        let bytes = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        guard !Task.isCancelled else { return }
        storageBytes = bytes
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    private var aboutFooter: some View {
        Button {
            Haptics.light()
            open(.about)
        } label: {
            HStack(spacing: Ink.Space.s) {
                ClioSeal(size: 18 * UIScale.factor)
                Text("Clio").font(Ink.wordmark(Ink.Size.body)).foregroundStyle(Ink.ink)
                Text("v\(version)").font(Ink.mono(Ink.Size.micro)).foregroundStyle(Ink.inkFaint)
            }
            .padding(Ink.Space.m)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .frame(maxWidth: .infinity)
        .accessibilityLabel(L.t("settingsHome.aboutFooter"))
        .accessibilityValue("v\(version)")
    }

    private var found: [SettingsPage] {
        Self.searchPages(matching: query)
    }

    static func searchPages(matching query: String) -> [SettingsPage] {
        let words = query.split(whereSeparator: \.isWhitespace)
        let pages = groups.flatMap(\.pages) + searchAliases.keys.sorted { $0.rawValue < $1.rawValue }
        return pages.filter { page in
            let keys = [page.titleKey, page.lineKey] + page.previousSearchKeys
            let terms = keys.flatMap { key in [L.daily[key], L.literary[key]].compactMap { $0 } } + [page.keywords]
            return words.allSatisfy { word in terms.contains { $0.localizedCaseInsensitiveContains(String(word)) } }
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        if found.isEmpty {
            Text(L.format("settings.searchNothing", query))
                .font(Ink.secondary).foregroundStyle(Ink.inkSoft)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            RowCard {
                ForEach(found) { page in
                    let parent = Self.searchAliases[page] ?? page
                    let group = Self.groups.first { $0.pages.contains(parent) }
                    let breadcrumb = group.map { "\(L.t($0.title)) · \(L.t(page.lineKey))" }
                    pageRow(page, group?.tint ?? Ink.accent, lineOverride: breadcrumb)
                }
            }
        }
    }

    private func pageRow(_ page: SettingsPage, _ tint: Color, lineOverride: String? = nil) -> some View {
        let end = rowEnd(for: page)
        return Button {
            Haptics.light()
            open(page)
        } label: {
            RowLabel(
                page.symbol,
                tint: tint,
                title: L.t(page.titleKey),
                line: lineOverride ?? L.t(page.lineKey),
                end: end
            )
        }
        .buttonStyle(PressStyle(haptic: false))
    }

    private func rowEnd(for page: SettingsPage) -> RowEnd {
        switch page {
        case .services: .dotValueChevron(servicesTint, servicesStatus)
        case .lock where faceLock, .privacy where faceLock:
            .dotValueChevron(Ink.ok, L.t("settingsHome.enabled"))
        case .careBackup, .care:
            .dotValueChevron(davURL.isEmpty ? Ink.warn : Ink.ok, backupStatus)
        default: summary(for: page).map { .valueChevron($0) } ?? .chevron
        }
    }

    private var schemeSummary: String {
        switch scheme {
        case "light": L.t("settings.lightAppearance")
        case "dark": L.t("settings.darkAppearance")
        default: L.t("settings.followSystem")
        }
    }

    private var voiceSummary: String {
        let mode = VoiceTranscription.Mode(rawValue: voiceModeRaw) ?? .system
        if mode == .cloud {
            let trimmed = voiceModel.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? L.t("voiceSettings.cloudShort") : trimmed
        }
        return mode.title
    }

    private var searchSummary: String {
        let provider = WebSearchProvider(rawValue: searchProviderRaw) ?? .builtin
        return provider == .builtin ? "内置网页" : provider.name
    }

    private func summary(for page: SettingsPage) -> String? {
        switch page {
        case .models:
            return defaultModelName
        case .capabilities:
            return Grant.Preset.current?.title ?? searchSummary
        case .memoryAndRoutine:
            return L.format("settingsHome.itemsCount", team.memories.count)
        case .appearance:
            return "\(schemeSummary) · \(Theme.shared.palette.title)"
        case .chatAndVoice:
            return voiceSummary
        case .privacy:
            return L.t("settingsHome.disabled")
        case .image:
            if let selection = team.imageModelSelection {
                return selection.endpoint.displayName(for: selection.model)
            }
            return L.t("settingsHome.disabled")
        case .theme:
            return "\(schemeSummary) · \(Theme.shared.palette.title)"
        case .font:
            return Pref.face.title
        case .size:
            return "\(Int(Pref.size))pt · \(String(format: "%.2g×", Pref.lineHeight))"
        case .tone:
            return Theme.shared.plain ? L.t("styleSwitcher.dailyLabel") : L.t("styleSwitcher.literaryLabel")
        case .context:
            return "\(Int((Pref.contextShare * 100).rounded()))% · \(L.format("settingsHome.stepsCount", Pref.maxSteps))"
        case .voice:
            return voiceSummary
        case .companions:
            return L.format("settingsHome.companionsCount", team.bots.count)
        case .rooms:
            return L.format("settingsHome.roomsCount", team.rooms.count)
        case .memory:
            return L.format("settingsHome.itemsCount", team.memories.count)
        case .pet:
            return PetLibrary.shared.pack?.name
        case .morning:
            return (morningOn || diaryOn) ? L.t("settingsHome.enabled") : L.t("settingsHome.disabled")
        case .connectors:
            return hills.servers.isEmpty ? nil : L.format("settingsHome.itemsCount", hills.servers.count)
        case .searchEngine:
            return searchSummary
        case .hosts:
            return L.format("settingsHome.hostsCount", hills.hosts.count)
        case .timing:
            return team.routines.isEmpty ? nil : L.format("settingsHome.itemsCount", team.routines.count)
        case .grants:
            return Grant.Preset.current?.title
        case .lock:
            return faceLock ? L.t("settingsHome.enabled") : L.t("settingsHome.disabled")
        case .notifications:
            return (notifyDone || liveOn) ? L.t("settingsHome.enabled") : L.t("settingsHome.disabled")
        case .careStorage:
            return team.archived.isEmpty ? nil : L.format("settingsHome.archivedCount", team.archived.count)
        case .about:
            return "v\(version)"
        default:
            return nil
        }
    }

    private func open(_ page: SettingsPage) {
        searching = false
        query = ""
        if page.opensSheet {
            sheet = page
        } else {
            path.append(page)
        }
    }

    @ViewBuilder
    private func destination(_ page: SettingsPage) -> some View {
        switch page {
        case .services:
            ServicesHubPage(team: team) { open(.add) }
        case .models:
            DefaultModelsPage(team: team) {
                path.append(SettingsPage.services)
            }
        case .capabilities:
            hubPage(.capabilities, tint: Ink.Tile.dai)
        case .memoryAndRoutine:
            hubPage(.memoryAndRoutine, tint: Ink.Tile.yan)
        case .appearance:
            hubPage(.appearance, tint: Ink.Tile.teng)
        case .chatAndVoice:
            hubPage(.chatAndVoice, tint: Ink.Tile.zhu)
        case .privacy:
            PrivacySettingsPage(title: L.t("settingsHome.privacy"), showsVaultRow: true) {
                NavigationLink(value: SettingsPage.vault) {
                    VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
                        Text(L.t(SettingsPage.vault.titleKey))
                            .foregroundStyle(Ink.ink)
                        Text(L.t(SettingsPage.vault.lineKey))
                            .font(Ink.footnote)
                            .foregroundStyle(Ink.inkSoft)
                    }
                }
            }
        case .care:
            hubPage(.care, tint: Ink.Tile.mo)
        case .image:
            ImageModelPage(team: team)
        case .companions, .rooms:
            SettingsCompanionsPage(team: team, tab: page, creatingBot: $creatingBot, editingBot: $editingBot,
                                   creatingRoom: $creatingRoom, editingRoom: $editingRoom)
        case .pet:
            PetPage(embedded: true)
        case .theme:
            LookPage()
        case .font:
            FontPage()
        case .size:
            ReadingSizePage()
        case .tone:
            ToneSettingsPage()
        case .display:
            ChatDisplayPage()
        case .voice:
            VoiceSettingsPage()
        case .context:
            ChatContextPage()
        case .grants:
            GrantsPage(team: team, embedded: true)
        case .connectors:
            ConnectorsPage(embedded: true)
        case .skills:
            SkillsPage(embedded: true)
        case .searchEngine:
            SearchSettingsPage()
        case .hosts:
            HillsPage(embedded: true)
        case .timing, .morning:
            SettingsSchedulePage(team: team, tab: page)
        case .vault:
            SecretsPage(embedded: true)
        case .notifications:
            NotificationSettingsPage()
        case .lock:
            PrivacySettingsPage(showsVaultRow: false) { EmptyView() }
        case .memory:
            MemoryPageV2(team: team)
        case .careBackup:
            CarePage(team: team, scope: .backup, embedded: true)
        case .careUsage:
            CareUsagePage(team: team)
        case .careStorage:
            CarePage(team: team, scope: .storage, embedded: true)
        case .careDiagnostics:
            CarePage(team: team, scope: .diagnostics, embedded: true)
        case .about:
            CareAboutPage()
        case .add:
            EmptyView()
        }
    }

    private func hubPage(_ hub: SettingsPage, tint: Color) -> some View {
        let children = Self.hubChildren[hub] ?? []
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: Ink.Space.xl) {
                RowCard {
                    ForEach(children) { child in pageRow(child, tint) }
                }
            }
            .padding(.horizontal, Ink.Space.page)
            .padding(.vertical, Ink.Space.l)
        }
        .scrollEdgeEffectStyle(.soft, for: .vertical)
        .background(Ink.paper.ignoresSafeArea())
        .navigationTitle(L.t(hub.titleKey))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func sheetContent(_ page: SettingsPage) -> some View {
        switch page {
        case .add: AddServiceSheet(team: team) { sheet = nil }
        default: EmptyView()
        }
    }


}

private struct SettingsUserAvatarButton: View {
    @AppStorage("me.avatar") private var face = ""
    @State private var choosingPhoto = false
    @State private var item: PhotosPickerItem?
    @State private var photoVersion = 0

    private let avatarID = "me"
    private var size: CGFloat { 36 * UIScale.factor }

    var body: some View {
        Menu {
            Button {
                Haptics.light()
                choosingPhoto = true
            } label: {
                Label(L.t("settingsHome.identityAlbum"), systemImage: "photo")
            }
            Button {
                Haptics.light()
                item = nil
                face = ""
            } label: {
                if face != "photo" {
                    Label(L.t("settingsHome.identityResetMe"), systemImage: "checkmark")
                } else {
                    Text(L.t("settingsHome.identityResetMe"))
                }
            }
        } label: {
            HStack(spacing: Ink.Space.m) {
                portrait.id(photoVersion).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
                    Text(L.t("settingsHome.identityMe"))
                        .font(.system(size: Ink.Size.sub, weight: .semibold))
                        .foregroundStyle(Ink.ink)
                    Text(L.t("settingsHome.identityTapAvatar"))
                        .font(Ink.footnote)
                        .foregroundStyle(Ink.inkSoft)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
                Kit.chevron
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(haptic: true))
        .photosPicker(isPresented: $choosingPhoto, selection: $item, matching: .images)
        .task(id: item) {
            guard let picked = item else { return }
            let data = try? await picked.loadTransferable(type: Data.self)
            guard !Task.isCancelled, item == picked else { return }
            if let data, let image = UIImage(data: data) {
                Avatars.save(image, for: avatarID)
                face = "photo"
                photoVersion += 1
            }
            item = nil
        }
    }

    @ViewBuilder
    private var portrait: some View {
        if face == "photo", let photo = Avatars.image(avatarID) {
            Image(uiImage: photo).resizable().scaledToFill().frame(width: size, height: size).clipShape(Circle())
        } else {
            Text("我")
                .font(.system(size: Ink.Size.sub, weight: .semibold))
                .foregroundStyle(Ink.paper)
                .frame(width: size, height: size)
                .background(Ink.accent, in: .circle)
        }
    }
}

private struct SettingsCompanionsPage: View {
    let team: TeamModel
    @State var tab: SettingsPage
    @Binding var creatingBot: Bool
    @Binding var editingBot: BotInfo?
    @Binding var creatingRoom: Bool
    @Binding var editingRoom: RoomInfo?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Ink.Space.xl) {
                if tab == .rooms {
                    SettingsRoomsSection(team: team, creatingRoom: $creatingRoom, editingRoom: $editingRoom)
                } else {
                    SettingsCompanionsSection(team: team, creatingBot: $creatingBot, editingBot: $editingBot)
                }
            }
            .padding(.horizontal, Ink.Space.page)
            .padding(.vertical, Ink.Space.l)
        }
        .scrollEdgeEffectStyle(.soft, for: .vertical)
        .safeAreaInset(edge: .top, spacing: 0) {
            SlidingCapsuleControl(selection: $tab, items: [
                (value: .companions, title: L.t("settingsHome.companions")),
                (value: .rooms, title: L.t("nav.groupChat")),
            ])
            .padding(.horizontal, Ink.Space.page)
            .padding(.vertical, Ink.Space.s)
            .background {
                LinearGradient(
                    stops: [
                        .init(color: Ink.paper.opacity(0.92), location: 0),
                        .init(color: Ink.paper.opacity(0.76), location: 0.72),
                        .init(color: Ink.paper.opacity(0), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)
            }
        }
        .background(Ink.paper.ignoresSafeArea())
        .navigationTitle(L.t("settingsHome.companionsAndRooms"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SettingsSchedulePage: View {
    let team: TeamModel
    @State var tab: SettingsPage

    var body: some View {
        let title = L.t("settingsHome.scheduleAndMorning")
        VStack(spacing: 0) {
            SlidingCapsuleControl(selection: $tab, items: [
                (value: .timing, title: L.t("agent.scheduledJobs")),
                (value: .morning, title: L.t("settingsHome.morning")),
            ])
            .padding(.horizontal, Ink.Space.page)
            .padding(.vertical, Ink.Space.s)

            if tab == .morning {
                MorningSettingsPage(embeddedTitle: title)
            } else {
                RoutinesPage(team: team, embedded: true, embeddedTitle: title)
            }
        }
        .background(Ink.paper.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SettingsCompanionsSection: View {
    @ObservedObject var team: TeamModel
    @Binding var creatingBot: Bool
    @Binding var editingBot: BotInfo?

    var body: some View {
        RowCard {
            if team.bots.isEmpty {
                Text(L.t("settingsHome.noCompanions"))
                    .font(Ink.secondary).foregroundStyle(Ink.inkSoft)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(Ink.Space.l)
            }
            ForEach(team.bots) { companionRow($0) }
            Button {
                Haptics.light()
                creatingBot = true
            } label: {
                RowLabel("plus", tint: Ink.Tile.yan, title: L.t("sidebar.newCompanion"))
            }
            .buttonStyle(PressStyle(haptic: false))
        }
    }

    private func companionRow(_ bot: BotInfo) -> some View {
        Button {
            Haptics.light()
            editingBot = bot
        } label: {
            RowLabel(title: bot.name, line: L.t("settingsHome.companionsLine")) {
                CompanionAvatar(size: Kit.badge, wash: Ink.wash(for: bot), bot: bot)
            }
        }
        .buttonStyle(PressStyle(haptic: false))
        .accessibilityLabel(L.format("settingsHome.editCompanion", bot.name))
    }
}

private struct SettingsRoomsSection: View {
    @ObservedObject var team: TeamModel
    @Binding var creatingRoom: Bool
    @Binding var editingRoom: RoomInfo?

    var body: some View {
        RowCard(note: team.bots.count < 2 ? L.t("settingsHome.roomsNeedCompanions") : nil) {
            ForEach(team.rooms) { room in
                Button {
                    Haptics.light()
                    editingRoom = room
                } label: {
                    RowLabel("person.3", tint: Ink.Tile.yan, title: room.name,
                             line: L.t("settingsHome.editRoomLine"))
                }
                .buttonStyle(PressStyle(haptic: false))
            }
            Button { creatingRoom = true } label: {
                RowLabel("plus", tint: Ink.Tile.yan, title: L.t("chat.newGroup"))
            }
            .buttonStyle(PressStyle())
            .disabled(team.bots.count < 2)
        }
    }
}

enum SettingsPage: String, Identifiable {
    case services, models, capabilities, companions, memoryAndRoutine, appearance, chatAndVoice, notifications, privacy, care
    case image, rooms, pet, theme, font, size, tone
    case display, context, grants, searchEngine, connectors, skills, timing, hosts, morning, lock
    case careBackup, careUsage, careStorage, careDiagnostics, about
    case memory, vault, voice, add

    var id: Self { self }

    init?(link: String) {
        switch link {
        case "model": self = .models
        case "search": self = .searchEngine
        case "look": self = .theme
        case "look#font": self = .font
        case "look#size", "look#ui": self = .size
        case "look#tone": self = .tone
        case "look#motion": self = .display
        case "look#voice", "voice": self = .voice
        case "look#context", "look#compress": self = .context
        case "look#notify": self = .notifications
        case "look#morning": self = .morning
        case "look#lock": self = .lock
        case "care": self = .care
        case "backup": self = .careBackup
        case "usage": self = .careUsage
        case "storage": self = .careStorage
        case "diagnostics": self = .careDiagnostics
        case "about": self = .about
        default: self.init(rawValue: link)
        }
    }

    var opensSheet: Bool {
        self == .add
    }

    var titleKey: String {
        switch self {
        case .services: "settings.modelService"
        case .models: "settingsHome.defaultAndSpecialModels"
        case .capabilities: "settingsHome.capabilities"
        case .companions: "settingsHome.companionsAndRooms"
        case .memoryAndRoutine: "settingsHome.memoryAndRoutine"
        case .appearance: "settingsHome.appearance"
        case .chatAndVoice: "settingsHome.chatAndVoice"
        case .privacy: "settingsHome.privacy"
        case .care: "settingsHome.care"
        case .size: "settingsHome.typography"
        case .display: "settingsHome.displayAndHaptics"
        case .image: "settings.imageModel"
        case .rooms: "nav.groupChat"
        case .pet: "nav.pet"
        case .font: "settings.fonts"
        case .tone: "styleSwitcher.title"
        case .connectors: "agent.connectors"
        case .skills: "agent.skills"
        case .timing: "settingsHome.scheduleAndMorning"
        case .hosts: "nav.remoteHost"
        case .lock: "settings.faceLock"
        case .memory: "nav.memory"
        case .vault: "settings.vault"
        case .voice: "voiceSettings.title"
        case .about: "settingsHome.aboutClio"
        case .add: "settings.addService"
        default: "settingsHome." + rawValue
        }
    }

    var lineKey: String {
        switch self {
        case .models: "settingsHome.defaultAndSpecialModelsLine"
        case .companions: "settingsHome.companionsAndRoomsLine"
        case .timing: "settingsHome.scheduleAndMorningLine"
        case .size: "settingsHome.typographyLine"
        case .display: "settingsHome.displayAndHapticsLine"
        case .care: "settingsHome.careHubLine"
        case .voice: "voiceSettings.rowFooter"
        case .about: "settingsHome.aboutClioLine"
        default: "settingsHome." + rawValue + "Line"
        }
    }

    var symbol: String {
        switch self {
        case .services: "server.rack"
        case .models: "sparkles"
        case .capabilities: "wrench.and.screwdriver"
        case .companions: "person.2"
        case .memoryAndRoutine: "brain"
        case .appearance: "paintpalette"
        case .chatAndVoice: "bubble.left.and.text.bubble.right"
        case .privacy: "lock.shield"
        case .care: "externaldrive.badge.icloud"
        case .image: "photo.badge.plus"
        case .rooms: "person.3"
        case .pet: "pawprint"
        case .theme: "paintpalette"
        case .font: "textformat"
        case .size: "textformat.size"
        case .tone: "quote.bubble"
        case .display: "bubble.left"
        case .context: "text.alignleft"
        case .grants: "checkmark.shield"
        case .searchEngine: "magnifyingglass"
        case .connectors: "powerplug"
        case .skills: "books.vertical"
        case .timing: "alarm"
        case .hosts: "server.rack"
        case .notifications: "bell"
        case .morning: "sun.horizon"
        case .lock: "faceid"
        case .careBackup: "externaldrive.badge.icloud"
        case .careUsage: "chart.bar"
        case .careStorage: "internaldrive"
        case .careDiagnostics: "stethoscope"
        case .about: "info.circle"
        case .memory: "brain"
        case .vault: "lock.rectangle.stack"
        case .voice: "waveform.and.mic"
        case .add: "plus"
        }
    }

    var previousSearchKeys: [String] {
        switch self {
        case .models, .companions, .size, .display:
            ["settingsHome." + rawValue, "settingsHome." + rawValue + "Line"]
        case .timing:
            ["agent.scheduledJobs", "settingsHome.timingLine"]
        default:
            []
        }
    }

    var keywords: String {
        switch self {
        case .services: "添一家 添加模型服务 密钥 key api deepseek kimi claude openai ollama lm studio 本地 中转"
        case .models: "默认 备用 换模型 兜底 出错 失败 记忆整理模型 小模型"
        case .capabilities: "权限 批准 联网 搜索 连接器 技能 远程主机 ssh mcp"
        case .memoryAndRoutine: "记忆 拾遗 定时任务 更漏 早报 晨信 日记 手札"
        case .appearance: "外观 主题 设色 字体 字号 行距 称谓 书卷 日常 宠物 伴读"
        case .chatAndVoice: "对话 显示 触感 震动 淡入 思考 压缩 上下文 温度 语音 听写 转写"
        case .privacy: "隐私 面容 face id 锁 密码匣 信匣 vault"
        case .care: "备份 恢复 webdav 用量 余额 存储 清理 归档 诊断 掉帧 养护"
        case .image: "画图 绘图 生图 图像 generate_image"
        case .companions: "人物 角色 改名 头像 性格 新建助手 新旅伴"
        case .rooms: "群聊 雅集 开一场 成员"
        case .pet: "宠物 伴读 小克 肉包 形象 头像 气泡 安静 导入 宠物包 图片 gif"
        case .theme: "纸墨 主题 深色 夜间 纯黑 主色 设色"
        case .font: "字体 font 文楷 霞鹜 楷体 宋体 苹方 圆体 书卷 标题 题词"
        case .size: "字号 行距 大小 spacing clreq 紧凑 放大 缩小 ui 密度"
        case .tone: "叫法 名字 诗意 普通 书卷 日常 称呼 旁注"
        case .display: "思考 心绪 pulse 人味 淡入 触感 震动 耗时 用量 行迹 帧率"
        case .context: "压缩 上下文 温度 输出 长度 步数 最多步数"
        case .grants: "权限 批准 允许 智能审批 联网 浏览器 日历 提醒 位置 通讯录 照片 健康 拾遗 书案 斗室"
        case .searchEngine: "联网 搜索 引擎 anysearch tavily exa brave bing duckduckgo searxng 查资料 密钥 key"
        case .connectors: "连接 谷歌 google gmail 邮箱 邮件 云盘 云端硬盘 drive 高德 地图 导航 github notion linear jira confluence asana canva figma zapier composio rube mcp"
        case .skills: "skill 本事 技能"
        case .timing: "每天 每周 到点 定时任务"
        case .hosts: "ssh vps 服务器 远山"
        case .notifications: "通知 锁屏 灵动岛 后台 实时活动 续跑 保活 keepawake"
        case .morning: "晨信 早报 日记 手札 早上"
        case .lock: "面容 face id faceid 锁 密码 隐私"
        case .careBackup: "备份 恢复 webdav 云同步 导出 导入 care"
        case .careUsage: "用量 费用 token 余额 usage 统计"
        case .careStorage: "清理 缓存 存储 归档 空间 storage"
        case .careDiagnostics: "诊断 日志 报错 掉帧 帧率 连通 测速 养护"
        case .about: "关于 about 版本 协议 gpl 开源 字体 致谢 github"
        case .memory: "记忆 拾遗 memory 记住 忘掉"
        case .vault: "密码匣 密码 信匣 账号 vault token"
        case .voice: "语音 听写 转写 朗读 麦克风 whisper sensevoice groq siliconflow stt"
        case .add: ""
        }
    }
}
