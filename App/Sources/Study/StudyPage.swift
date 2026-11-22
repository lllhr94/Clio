import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// 书案: the folder the companions work in (plus external folders mounted via security-scoped bookmarks).
/// Browse it, read what they wrote, share or throw away.
struct StudyPage: View {
    var folder: URL = Workspace.root
    @Environment(\.dismiss) private var dismiss

    struct Item: Identifiable, Hashable, Sendable {
        let url: URL
        let folder: Bool
        let bytes: Int
        let changed: Date
        var mount: MountedFolder? = nil
        var id: String { (mount?.id ?? "desk") + "|" + url.path }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationDestination(for: Item.self) { item in
                    if item.folder {
                        StudyFolder(folder: item.url, mount: item.mount)
                    } else {
                        StudyFile(url: item.url, mount: item.mount)
                    }
                }
        }
    }

    private var content: some View {
        StudyFolder(folder: folder, top: true, close: { dismiss() })
    }
}

/// One folder of the desk (or a mounted external folder), as a list.
struct StudyFolder: View {
    let folder: URL
    var top = false
    var mount: MountedFolder? = nil
    var close: (() -> Void)?

    @State private var items: [StudyPage.Item] = []
    @State private var mounts: [MountedFolders.Inspection] = []
    @State private var deleting: StudyPage.Item?
    @State private var unmounting: MountedFolder?
    @State private var reauthorizing: MountedFolder?
    @State private var importing = false
    @State private var pickingMount = false
    @State private var naming = false
    @State private var newFolder = ""
    @State private var loading = true
    @State private var mountBroken = false
    @State private var mountNotice: String?
    @State private var request: UUID?
    @State private var scope: MountedFolders.ScopeToken?
    @State private var mountRoot: URL?

    var body: some View {
        ZStack {
            Ink.paper.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: Ink.Space.l) {
                    if top {
                        Text(L.t("files.localPath"))
                            .font(Ink.secondary)
                            .foregroundStyle(Ink.inkSoft)
                    } else if let mount {
                        Text(Words.t("外部文件夹 · 书案/\(MountedFolders.virtualFolder)/\(mount.name)"))
                            .font(Ink.mono(Ink.Size.small))
                            .foregroundStyle(Ink.inkSoft)
                    }
                    if let mountNotice {
                        Text(mountNotice)
                            .font(Ink.footnote)
                            .foregroundStyle(Ink.inkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if top && !mounts.isEmpty {
                        mountedSection
                    }
                    if loading {
                        ProgressView(L.t("loading.generic"))
                    } else if mountBroken {
                        brokenMountView
                    } else if items.isEmpty {
                        if top && !mounts.isEmpty {
                            Text(L.t("empty.files"))
                                .font(Ink.secondary)
                                .foregroundStyle(Ink.inkSoft)
                                .padding(.horizontal, Ink.Space.xs)
                        } else {
                            emptyView
                        }
                    } else {
                        filesSection
                    }
                }
                .padding(.horizontal, Ink.Space.page)
                .padding(.vertical, Ink.Space.l)
            }
        }
        .hitchPage("书案")
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarItems }
        .background {
            Color.clear
                .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true, onCompletion: handleImport)
            Color.clear
                .fileImporter(isPresented: $pickingMount, allowedContentTypes: [.folder], allowsMultipleSelection: false, onCompletion: handlePickMount)
            Color.clear
                .confirmationDialog(
                    L.format("files.deleteConfirm", deleting?.url.lastPathComponent ?? ""),
                    isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                    titleVisibility: .visible
                ) {
                    Button(L.t("actions.delete"), role: .destructive) {
                        deleteSelectedItem()
                    }
                    Button(L.t("actions.cancel"), role: .cancel) { deleting = nil }
                }
            Color.clear
                .confirmationDialog(
                    "取消挂载「\(unmounting?.name ?? "")」？只会删掉书签连接，不会删除原文件夹里的任何文件。",
                    isPresented: Binding(get: { unmounting != nil }, set: { if !$0 { unmounting = nil } }),
                    titleVisibility: .visible
                ) {
                    Button("取消挂载", role: .destructive) {
                        if let target = unmounting {
                            MountedFolders.remove(id: target.id)
                            mountNotice = "已取消挂载「\(target.name)」，原文件夹里的文件未受影响。"
                            Haptics.lock()
                            Task { await load() }
                        }
                        unmounting = nil
                    }
                    Button(L.t("actions.cancel"), role: .cancel) { unmounting = nil }
                }
        }
        .alert(L.t("actions.newFolder"), isPresented: $naming) {
            TextField(L.t("files.folderName"), text: $newFolder)
            Button(L.t("actions.create")) { createSubfolder() }
            Button(L.t("actions.cancel"), role: .cancel) {}
        }
        .task(id: folder) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: MountedFolders.changed)) { _ in
            guard top else { return }
            Task { await load() }
        }
        .onDisappear {
            scope?.stop()
            scope = nil
        }
        .refreshable { await load() }
    }

    private var navigationTitle: String {
        if top { return L.t("nav.files") }
        if let mount, let mountRoot,
           folder.resolvingSymlinksInPath().standardizedFileURL.path == mountRoot.resolvingSymlinksInPath().standardizedFileURL.path {
            return mount.name
        }
        return folder.lastPathComponent
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        if let close {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L.t("actions.done")) { close() }
            }
        }
        if !mountBroken {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(L.t("actions.importFromFiles"), systemImage: "square.and.arrow.down") { importing = true }
                    Button(L.t("actions.newFolder"), systemImage: "folder.badge.plus") { newFolder = ""; naming = true }
                    if top {
                        Divider()
                        Button("添加外部文件夹", systemImage: "plus.rectangle.on.folder") {
                            reauthorizing = nil
                            pickingMount = true
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L.t("actions.addFilesOrFolder"))
            }
        }
    }

    private var mountedSection: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle("已挂载的文件夹")
            VStack(spacing: 0) {
                ForEach(Array(mounts.enumerated()), id: \.element.id) { index, inspection in
                    if index > 0 { Kit.divider }
                    mountRow(inspection)
                }
            }
            .paperCard()
            Text(Words.t("可挂载 iCloud、Obsidian 等文件夹，旅伴可直接读写，取消挂载不会删文件。"))
                .font(.system(size: Ink.Size.small))
                .foregroundStyle(Ink.inkSoft)
                .padding(.horizontal, Ink.Space.l)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func mountRow(_ inspection: MountedFolders.Inspection) -> some View {
        if inspection.accessible, let rootURL = inspection.url {
            let item = StudyPage.Item(url: rootURL, folder: true, bytes: 0, changed: Date(), mount: inspection.mount)
            NavigationLink(value: item) {
                RowLabel(
                    "link",
                    tint: Ink.Tile.dai,
                    title: inspection.mount.name,
                    line: Words.t("书案/\(MountedFolders.virtualFolder)/\(inspection.mount.name)")
                )
            }
            .buttonStyle(PressStyle())
            .contextMenu { mountContextMenu(inspection.mount) }
        } else {
            Button {
                Haptics.light()
                reauthorizing = inspection.mount
                pickingMount = true
            } label: {
                RowLabel(
                    "exclamationmark.triangle",
                    tint: Ink.warn,
                    title: inspection.mount.name,
                    line: "授权已失效，点这里重新选择文件夹"
                )
            }
            .buttonStyle(PressStyle(haptic: false))
            .contextMenu { mountContextMenu(inspection.mount) }
        }
    }

    @ViewBuilder
    private func mountContextMenu(_ target: MountedFolder) -> some View {
        Button("重新选择文件夹", systemImage: "arrow.clockwise") {
            reauthorizing = target
            pickingMount = true
        }
        Button("取消挂载", systemImage: "minus.circle", role: .destructive) {
            unmounting = target
        }
    }

    private var filesSection: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            if top && !mounts.isEmpty {
                SectionTitle(L.t("nav.files"))
            }
            LazyVStack(spacing: 0) {
                ForEach(items) { item in
                    NavigationLink(value: item) { row(item) }
                        .buttonStyle(PressStyle())
                        .contextMenu {
                            if !item.folder { ShareLink(item: item.url) { Label(L.t("actions.share"), systemImage: "square.and.arrow.up") } }
                            Button(L.t("actions.delete"), systemImage: "trash", role: .destructive) { deleting = item }
                        }
                    if item.id != items.last?.id { Kit.divider }
                }
            }
            .paperCard()
        }
    }

    private var emptyView: some View {
        VStack(spacing: Ink.Space.m) {
            PetStill(size: 72)
            Text(L.t("empty.files"))
                .font(Ink.secondary)
                .foregroundStyle(Ink.inkSoft)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Ink.Space.xxl)
    }

    private var brokenMountView: some View {
        RowCard {
            VStack(alignment: .leading, spacing: Ink.Space.s) {
                Text("这个外部文件夹的授权已失效或目录已移动。")
                    .font(.system(size: Ink.Size.body, weight: .medium))
                    .foregroundStyle(Ink.ink)
                Text(Words.t("请回到书案首页，点击该挂载项重新选择文件夹。"))
                    .font(Ink.secondary)
                    .foregroundStyle(Ink.inkSoft)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Ink.Space.l)
        }
    }

    private func row(_ item: StudyPage.Item) -> some View {
        let detail = (item.folder ? "" : Workspace.size(item.bytes) + " · ") + item.changed.formatted(.relative(presentation: .named))
        return RowLabel(item.folder ? "folder" : Self.icon(item.url),
                        tint: item.folder ? Ink.Tile.accent : Ink.Tile.mo,
                        title: item.url.lastPathComponent, line: detail)
    }

    static func icon(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "md", "txt": "doc.text"
        case "json", "js", "py", "sh", "swift", "html", "css": "chevron.left.forwardslash.chevron.right"
        case "csv", "tsv", "xlsx", "numbers": "tablecells"
        case "png", "jpg", "jpeg", "heic", "gif": "photo"
        case "pdf": "doc.richtext"
        default: "doc"
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        let activeRoot = mountRoot ?? Workspace.root
        guard Workspace.isInsideRealRoot(folder, root: activeRoot) else { return }
        for source in urls {
            let reach = source.startAccessingSecurityScopedResource()
            defer { if reach { source.stopAccessingSecurityScopedResource() } }
            var target = folder.appendingPathComponent(source.lastPathComponent)
            var number = 2
            while FileManager.default.fileExists(atPath: target.path) {
                let base = source.deletingPathExtension().lastPathComponent
                let ext = source.pathExtension
                target = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
                number += 1
            }
            guard Workspace.isInsideRealRoot(target, root: activeRoot) else { continue }
            try? FileManager.default.copyItem(at: source, to: target)
        }
        Haptics.thud()
        Task { await load() }
    }

    private func handlePickMount(_ result: Result<[URL], Error>) {
        let targetMount = reauthorizing
        reauthorizing = nil
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let saved: MountedFolder
                if let targetMount {
                    saved = try MountedFolders.reauthorize(id: targetMount.id, with: url)
                    mountNotice = "已重新授权「\(saved.name)」。"
                } else {
                    saved = try MountedFolders.add(url)
                    mountNotice = Words.t("已挂载「\(saved.name)」，路径为书案/\(MountedFolders.virtualFolder)/\(saved.name)。")
                }
                Haptics.thud()
                Task { await load() }
            } catch {
                mountNotice = error.localizedDescription
                Haptics.lock()
            }
        case .failure(let error):
            mountNotice = error.localizedDescription
        }
    }

    private func createSubfolder() {
        let name = newFolder.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        guard !name.isEmpty, name != ".", name != ".." else { return }
        let target = folder.appendingPathComponent(name, isDirectory: true)
        let activeRoot = mountRoot ?? Workspace.root
        guard Workspace.isInsideRealRoot(target, root: activeRoot) else { return }
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        Task { await load() }
    }

    private func deleteSelectedItem() {
        if let item = deleting {
            let activeRoot = mountRoot ?? Workspace.root
            if Workspace.isInsideRealRoot(item.url, root: activeRoot),
               item.url.resolvingSymlinksInPath().standardizedFileURL.path != activeRoot.resolvingSymlinksInPath().standardizedFileURL.path {
                try? FileManager.default.removeItem(at: item.url)
                Haptics.lock()
                Task { await load() }
            }
        }
        deleting = nil
    }

    private func load() async {
        let id = UUID()
        request = id
        let folder = self.folder
        let top = self.top
        let mount = self.mount
        if let mount {
            let opened = await Task.detached(priority: .utility) { MountedFolders.openForUI(mount) }.value
            guard !Task.isCancelled, request == id else {
                opened?.token.stop()
                return
            }
            scope?.stop()
            guard let opened else {
                scope = nil
                mountRoot = nil
                items = []
                mountBroken = true
                loading = false
                return
            }
            scope = opened.token
            mountRoot = opened.url
            mountBroken = false
            let result = await Task.detached(priority: .utility) {
                Self.readFolder(folder, root: opened.url, mount: mount)
            }.value
            guard !Task.isCancelled, request == id else { return }
            items = result
            loading = false
            return
        }

        let loaded = await Task.detached(priority: .utility) { () -> ([StudyPage.Item], [MountedFolders.Inspection]) in
            let files = Self.readFolder(folder, root: Workspace.root, mount: nil)
            let inspections = top ? MountedFolders.all(fresh: true).map(MountedFolders.inspect) : []
            return (files, inspections)
        }.value
        guard !Task.isCancelled, request == id else { return }
        items = loaded.0
        if top { mounts = loaded.1 }
        loading = false
    }

    nonisolated private static func readFolder(_ folder: URL, root baseRoot: URL, mount: MountedFolder?) -> [StudyPage.Item] {
        guard Workspace.isInsideRealRoot(folder, root: baseRoot) else { return [] }
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { url in
            guard Workspace.isInsideRealRoot(url, root: baseRoot) else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            return StudyPage.Item(url: url, folder: values?.isDirectory == true, bytes: values?.fileSize ?? 0, changed: values?.contentModificationDate ?? .distantPast, mount: mount)
        }
        .sorted { ($0.folder ? 0 : 1, $1.changed) < ($1.folder ? 0 : 1, $0.changed) }
    }
}

/// One file: Markdown read as prose, other text in a code face, pictures to look at, tables as a grid,
/// and everything else (PDF, Word, Excel, Keynote…) through the system's own viewer.
struct StudyFile: View {
    let url: URL
    var mount: MountedFolder? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var text: String?
    @State private var plain = false
    @State private var picture: UIImage?
    @State private var loaded = false
    @State private var mountBroken = false
    @State private var scope: MountedFolders.ScopeToken?
    @State private var allowedRoot: URL?

    private var ext: String { url.pathExtension.lowercased() }
    private var interactive: Bool { InteractiveDocument.supports(url) }
    private var shareURL: URL? {
        if mountBroken { return nil }
        if !interactive { return url }
        guard let allowedRoot else { return nil }
        return InteractiveDocument(url: url, root: allowedRoot).shareURL
    }
    private var markdown: Bool { ["md", "markdown", "txt"].contains(ext) }
    private var table: Bool { ["csv", "tsv"].contains(ext) }
    private var longPlainText: String? {
        // Keep the formatted preview for short snippets. A large TXT can create thousands of prose views.
        guard ext == "txt", let text, text.utf8.count >= 64 * 1024 else { return nil }
        return text
    }

    var body: some View {
        ZStack {
            Ink.paper.ignoresSafeArea()
            if mountBroken {
                Text(Words.t("外部文件夹的授权已失效，请回到书案首页重新选择文件夹。"))
                    .font(Ink.secondary)
                    .foregroundStyle(Ink.inkSoft)
                    .multilineTextAlignment(.center)
                    .padding(Ink.Space.page)
            } else if interactive, let allowedRoot {
                InteractivePreviewContent(document: InteractiveDocument(url: url, root: allowedRoot))
            } else if let picture {
                ScrollView([.horizontal, .vertical]) {
                    Image(uiImage: picture)
                        .resizable()
                        .scaledToFit()
                        .containerRelativeFrame(.horizontal)
                }
            } else if let longPlainText {
                LongTextPreview(text: longPlainText)
                    .id(url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let text, table, !plain {
                TableGrid(rows: CSV.rows(text, separator: ext == "tsv" ? "\t" : ","))
            } else if let text {
                ScrollView {
                    Group {
                        if markdown && !plain {
                            ProseView(text: text, streaming: false)
                        } else {
                            Text(text)
                                .font(Ink.code)
                                .foregroundStyle(Ink.ink)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, Ink.Space.page)
                    .padding(.vertical, Ink.Space.l)
                }
            } else if loaded {
                if QLPreviewController.canPreview(url as NSURL) {
                    QuickPreview(url: url).ignoresSafeArea(edges: .bottom)
                } else {
                    Text(L.t("files.previewUnavailable"))
                        .font(Ink.secondary)
                        .foregroundStyle(Ink.inkSoft)
                        .padding(Ink.Space.page)
                }
            }
        }
        .hitchPage("书案")
        .navigationTitle(url.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if (markdown || table) && text != nil && longPlainText == nil {
                    Button(plain ? (table ? L.t("files.showTable") : L.t("files.showFormatted")) : L.t("files.showSource")) { plain.toggle() }
                }
                if let shareURL {
                    ShareLink(item: shareURL) { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("分享文件")
                }
                if interactive { Button(L.t("actions.done")) { dismiss() } }
            }
        }
        .task(id: url) {
            let url = self.url
            let mount = self.mount
            if let mount {
                let opened = await Task.detached(priority: .utility) { MountedFolders.openForUI(mount) }.value
                guard !Task.isCancelled else {
                    opened?.token.stop()
                    return
                }
                scope?.stop()
                guard let opened else {
                    scope = nil
                    mountBroken = true
                    loaded = true
                    return
                }
                scope = opened.token
                mountBroken = false
                if interactive {
                    allowedRoot = opened.url
                    return
                }
                let result = await Task.detached(priority: .utility) { Self.readPreview(url, root: opened.url) }.value
                guard !Task.isCancelled else { return }
                picture = result.picture
                text = result.text
                loaded = true
                return
            }
            if interactive {
                allowedRoot = Workspace.root
                return
            }
            let result = await Task.detached(priority: .utility) { Self.readPreview(url, root: Workspace.root) }.value
            guard !Task.isCancelled else { return }
            picture = result.picture
            text = result.text
            loaded = true
        }
        .onDisappear {
            scope?.stop()
            scope = nil
            allowedRoot = nil
        }
    }

    nonisolated private static func readPreview(_ url: URL, root baseRoot: URL) -> (picture: UIImage?, text: String?) {
        guard Workspace.isInsideRealRoot(url, root: baseRoot) else { return (nil, nil) }
        if ["png", "jpg", "jpeg", "heic", "gif", "webp", "bmp", "tiff"].contains(url.pathExtension.lowercased()),
           let image = UIImage(contentsOfFile: url.path) {
            return (image.preparingForDisplay() ?? image, nil)
        }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 2_000_000,
              let data = try? Data(contentsOf: url), data.count < 2_000_000 else { return (nil, nil) }
        return (nil, String(data: data, encoding: .utf8))
    }
}

/// The text view owns scrolling so TextKit 2 can lay out the visible range without sizing the whole document.
private struct LongTextPreview: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(usingTextLayoutManager: true)
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.textContainer.lineFragmentPadding = 0
        view.textContainerInset = UIEdgeInsets(top: Ink.Space.l, left: Ink.Space.page,
                                              bottom: Ink.Space.l, right: Ink.Space.page)
        view.font = Ink.uiMono(max(12, Pref.size - 3))
        view.textColor = UIColor(Ink.ink)
        view.text = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {}
}

/// Comma- or tab-separated text as rows of cells. Quotes may hold separators, line breaks and doubled quotes.
enum CSV {
    static func rows(_ text: String, separator: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var cell = ""
        var quoted = false
        var chars = Array(text)
        if chars.first == "\u{FEFF}" { chars.removeFirst() }
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if quoted {
                if char == "\"" {
                    if index + 1 < chars.count, chars[index + 1] == "\"" { cell.append("\""); index += 1 } else { quoted = false }
                } else {
                    cell.append(char)
                }
            } else if char == "\"" && cell.isEmpty {
                quoted = true
            } else if char == separator {
                row.append(cell); cell = ""
            } else if char == "\n" || char == "\r\n" || char == "\r" {
                row.append(cell); cell = ""
                rows.append(row); row = []
            } else {
                cell.append(char)
            }
            index += 1
            if rows.count >= 2000 { break }
        }
        if !cell.isEmpty || !row.isEmpty { row.append(cell); rows.append(row) }
        return rows
    }
}

/// A grid that scrolls both ways, the first row as its header.
private struct TableGrid: View {
    let rows: [[String]]
    @State private var width: CGFloat = 0

    private var narrowColumn: CGFloat { Ink.Size.small * 4.6 }
    private var wideColumn: CGFloat {
        width > 0 ? min(Ink.Size.body * 16, max(narrowColumn, width * 0.56)) : Ink.Size.body * 13
    }

    var body: some View {
        let columns = rows.map(\.count).max() ?? 0
        ScrollView([.horizontal, .vertical]) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { column in
                            Text(column < row.count ? row[column] : "")
                                .font(index == 0 ? .system(size: Ink.Size.small, weight: .semibold) : .system(size: Ink.Size.small))
                                .foregroundStyle(Ink.ink)
                                .lineLimit(3)
                                .frame(minWidth: narrowColumn, maxWidth: wideColumn, alignment: .leading)
                                .padding(.horizontal, Ink.Space.s)
                                .padding(.vertical, Ink.Space.s)
                                .background(index == 0 ? Ink.accentWash : (index % 2 == 0 ? Ink.paperRaised : Color.clear))
                                .overlay(Rectangle().strokeBorder(Ink.rule, lineWidth: 0.5))
                        }
                    }
                }
            }
            .padding(Ink.Space.l)
            .textSelection(.enabled)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

/// The system viewer, for PDFs, Office files, and anything else it knows.
struct QuickPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Source { Source(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    final class Source: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}
