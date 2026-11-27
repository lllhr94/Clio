import ImageIO
import PDFKit
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Resolves a workspace path (`书案/...`, `/root/desk/...`, `文件/...`, `挂载/<name>/...`) into a verified regular file
/// inside either the local desk or a mounted external folder, rejecting symlinks pointing outside the root.
struct WorkspaceFileRef: Equatable, Hashable, Sendable {
    let url: URL
    let rootURL: URL
    let mount: MountedFolder?
    let relativePath: String
    let byteSize: Int
    let modified: Date?

    nonisolated var isMountCurrent: Bool {
        guard let mount else { return true }
        return MountedFolders.isCurrent(mount)
    }

    nonisolated static func resolve(_ rawPath: String) -> WorkspaceFileRef? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var candidates: [String] = []
        if trimmed.hasPrefix("file://"), let fileURL = URL(string: trimmed) {
            let rootPath = Workspace.root.resolvingSymlinksInPath().standardizedFileURL.path
            let filePath = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
            if filePath.hasPrefix(rootPath + "/") {
                candidates.append(String(filePath.dropFirst(rootPath.count + 1)))
            } else {
                return nil
            }
        } else {
            let rootPath = Workspace.root.path
            let rootReal = Workspace.root.resolvingSymlinksInPath().standardizedFileURL.path
            let rootPrivate = rootReal.hasPrefix("/var/") ? "/private" + rootReal : rootReal
            if trimmed.hasPrefix(rootPath + "/") {
                candidates.append(String(trimmed.dropFirst(rootPath.count + 1)))
            } else if trimmed.hasPrefix(rootReal + "/") {
                candidates.append(String(trimmed.dropFirst(rootReal.count + 1)))
            } else if trimmed.hasPrefix(rootPrivate + "/") {
                candidates.append(String(trimmed.dropFirst(rootPrivate.count + 1)))
            } else {
                candidates.append(trimmed)
                for prefix in ["文件/", "/文件/"] where trimmed.hasPrefix(prefix) {
                    candidates.append(String(trimmed.dropFirst(prefix.count)))
                }
            }
        }
        for candidate in candidates {
            if let resolved = resolveSingle(candidate) { return resolved }
        }
        return nil
    }

    nonisolated private static func resolveSingle(_ path: String) -> WorkspaceFileRef? {
        guard let target = try? Workspace.parse(path) else { return nil }
        switch target {
        case .desk(let url, let relative):
            guard relative != "/", Workspace.isInsideRealRoot(url, root: Workspace.root) else { return nil }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = values?.fileSize ?? 0
            return WorkspaceFileRef(url: url, rootURL: Workspace.root, mount: nil, relativePath: relative, byteSize: size, modified: values?.contentModificationDate)
        case .mountsRoot:
            return nil
        case .mounted(let mount, let innerParts, let relative):
            guard !innerParts.isEmpty else { return nil }
            return try? MountedFolders.withAccess(mount, innerParts: innerParts) { rootURL, targetURL in
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
                let values = try? targetURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let size = values?.fileSize ?? 0
                return WorkspaceFileRef(url: targetURL, rootURL: rootURL, mount: mount, relativePath: relative, byteSize: size, modified: values?.contentModificationDate)
            }
        }
    }

    nonisolated static func loadImage(_ ref: WorkspaceFileRef, maxPixelSize: Int = 1280) -> UIImage? {
        if let mount = ref.mount {
            guard MountedFolders.isCurrent(mount),
                  let opened = MountedFolders.openForUI(mount) else { return nil }
            defer { opened.token.stop() }
            guard Workspace.isInsideRealRoot(ref.url, root: opened.url) else { return nil }
            return decodePreview(at: ref.url, maxPixelSize: maxPixelSize)
        }
        guard Workspace.isInsideRealRoot(ref.url, root: Workspace.root) else { return nil }
        return decodePreview(at: ref.url, maxPixelSize: maxPixelSize)
    }

    nonisolated static func decodePreview(at url: URL, maxPixelSize: Int) -> UIImage? {
        let limit = max(64, maxPixelSize)
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: limit,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return UIImage(cgImage: cgImage)
            }
        }
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let longest = max(pixelWidth, pixelHeight)
        if longest > CGFloat(limit), longest > 0 {
            let ratio = CGFloat(limit) / longest
            let target = CGSize(
                width: max(1, (pixelWidth * ratio).rounded()),
                height: max(1, (pixelHeight * ratio).rounded())
            )
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = false
            let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: target))
            }
            return rendered.preparingForDisplay() ?? rendered
        }
        return image.preparingForDisplay() ?? image
    }
}

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
        var shareURL: URL? = nil
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
    @State private var showingTrash = false
    @State private var pickingMount = false
    @State private var naming = false
    @State private var newFolder = ""
    @State private var loading = true
    @State private var mountBroken = false
    @State private var mountNotice: String?
    @State private var request: UUID?
    @State private var scope: MountedFolders.ScopeToken?
    @State private var mountRoot: URL?
    @State private var isMountRootFolder = false

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
                        Text(L.format("files.externalFolderBanner", mount.name))
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
            .scrollEdgeEffectStyle(.soft, for: .vertical)
        }
        .hitchPage("书案列表")
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
                    L.format("files.trashMoveConfirm", deleting?.url.lastPathComponent ?? ""),
                    isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                    titleVisibility: .visible
                ) {
                    Button(L.t("files.trashMove"), role: .destructive) {
                        deleteSelectedItem()
                    }
                    Button(L.t("actions.cancel"), role: .cancel) { deleting = nil }
                }
            Color.clear
                .confirmationDialog(
                    L.format("files.unmountConfirm", unmounting?.name ?? ""),
                    isPresented: Binding(get: { unmounting != nil }, set: { if !$0 { unmounting = nil } }),
                    titleVisibility: .visible
                ) {
                    Button(L.t("files.unmountAction"), role: .destructive) {
                        if let target = unmounting {
                            MountedFolders.remove(id: target.id)
                            mountNotice = nil
                            ToastCenter.shared.show(
                                L.format("files.unmountedNotice", target.name),
                                symbol: "link.badge.minus",
                                tint: Ink.inkSoft
                            )
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
        .sheet(isPresented: $showingTrash, onDismiss: { Task { await load() } }) {
            DeskTrashPage()
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
        if let mount, isMountRootFolder {
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
        if top {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L.t("files.trash"), systemImage: "trash") { showingTrash = true }
            }
        }
        if !mountBroken {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(L.t("actions.importFromFiles"), systemImage: "square.and.arrow.down") { importing = true }
                    Button(L.t("actions.newFolder"), systemImage: "folder.badge.plus") { newFolder = ""; naming = true }
                    if top {
                        Divider()
                        Button(L.t("files.addExternalFolder"), systemImage: "plus.rectangle.on.folder") {
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
            SectionTitle(L.t("files.mountedFolders"))
            VStack(spacing: 0) {
                ForEach(Array(mounts.enumerated()), id: \.element.id) { index, inspection in
                    if index > 0 { Kit.divider }
                    mountRow(inspection)
                }
            }
            .clipShape(.rect(cornerRadius: Ink.Radius.card, style: .continuous))
            .paperCard()
            Text(L.t("files.mountedNote"))
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
                    line: L.format("files.mountFolderPath", inspection.mount.name)
                )
                .background(Ink.paperRaised)
            }
            .buttonStyle(PressStyle(elevated: true))
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
                    line: L.t("files.mountExpiredTap")
                )
                .background(Ink.paperRaised)
            }
            .buttonStyle(PressStyle(haptic: false, elevated: true))
            .contextMenu { mountContextMenu(inspection.mount) }
        }
    }

    @ViewBuilder
    private func mountContextMenu(_ target: MountedFolder) -> some View {
        Button(L.t("files.reselectFolder"), systemImage: "arrow.clockwise") {
            reauthorizing = target
            pickingMount = true
        }
        Button(L.t("files.unmountAction"), systemImage: "minus.circle", role: .destructive) {
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
                    NavigationLink(value: item) {
                        row(item)
                            .background(Ink.paperRaised)
                    }
                    .buttonStyle(PressStyle(elevated: true))
                    .contextMenu {
                        if let shareURL = item.shareURL {
                            ShareLink(item: shareURL) { Label(L.t("actions.share"), systemImage: "square.and.arrow.up") }
                        }
                        Button(L.t("files.trashMove"), systemImage: "trash", role: .destructive) { deleting = item }
                    }
                    if item.id != items.last?.id { Kit.divider }
                }
            }
            .clipShape(.rect(cornerRadius: Ink.Radius.card, style: .continuous))
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
                Text(L.t("files.mountBrokenTitle"))
                    .font(.system(size: Ink.Size.body, weight: .medium))
                    .foregroundStyle(Ink.ink)
                Text(L.t("files.mountBrokenDetail"))
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
        guard case .success(let urls) = result, !urls.isEmpty else { return }
        let targetFolder = folder
        let currentMount = mount
        let fallbackRoot = mountRoot ?? Workspace.root
        Task {
            let copied = await Task.detached(priority: .userInitiated) { () -> Bool in
                let opened = currentMount.flatMap { MountedFolders.openForUI($0) }
                defer { opened?.token.stop() }
                if currentMount != nil && opened == nil { return false }
                let activeRoot = opened?.url ?? fallbackRoot
                guard Workspace.isInsideRealRoot(targetFolder, root: activeRoot) else { return false }
                for source in urls {
                    let reach = source.startAccessingSecurityScopedResource()
                    defer { if reach { source.stopAccessingSecurityScopedResource() } }
                    var target = targetFolder.appendingPathComponent(source.lastPathComponent)
                    var number = 2
                    while FileManager.default.fileExists(atPath: target.path) {
                        let base = source.deletingPathExtension().lastPathComponent
                        let ext = source.pathExtension
                        target = targetFolder.appendingPathComponent(ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
                        number += 1
                    }
                    guard Workspace.isInsideRealRoot(target, root: activeRoot) else { continue }
                    try? FileManager.default.copyItem(at: source, to: target)
                }
                return true
            }.value
            if copied {
                Haptics.thud()
                await load()
            }
        }
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
                    mountNotice = nil
                    ToastCenter.shared.show(
                        L.format("files.reauthorizedNotice", saved.name),
                        symbol: "checkmark.circle.fill",
                        tint: Ink.ok
                    )
                } else {
                    saved = try MountedFolders.add(url)
                    mountNotice = nil
                    ToastCenter.shared.show(
                        L.format("files.mountedAddedNotice", saved.name, saved.name),
                        symbol: "checkmark.circle.fill",
                        tint: Ink.ok
                    )
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
        let currentMount = mount
        let fallbackRoot = mountRoot ?? Workspace.root
        Task {
            let created = await Task.detached(priority: .userInitiated) { () -> Bool in
                let opened = currentMount.flatMap { MountedFolders.openForUI($0) }
                defer { opened?.token.stop() }
                if currentMount != nil && opened == nil { return false }
                let activeRoot = opened?.url ?? fallbackRoot
                guard Workspace.isInsideRealRoot(target, root: activeRoot) else { return false }
                return (try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)) != nil
            }.value
            if created { await load() }
        }
    }

    private func deleteSelectedItem() {
        guard let item = deleting else { return }
        deleting = nil
        let currentRoot = mountRoot
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    if let mount = item.mount {
                        guard let currentRoot else { throw DeskTrash.Failure.offline }
                        let relative = try DeskTrash.relativePath(of: item.url, in: currentRoot)
                        _ = try DeskTrash.shared.move(mount: mount, relativePath: relative, expectedRoot: currentRoot)
                    } else {
                        _ = try DeskTrash.shared.move(deskItem: item.url)
                    }
                }.value
                Haptics.lock()
                await load()
            } catch {
                ToastCenter.shared.show(error.localizedDescription, symbol: "exclamationmark.circle", tint: Ink.warn)
            }
        }
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
                isMountRootFolder = false
                items = []
                mountBroken = true
                loading = false
                return
            }
            scope = opened.token
            mountRoot = opened.url
            mountBroken = false
            let result = await Task.detached(priority: .utility) {
                let files = Self.readFolder(folder, root: opened.url, mount: mount)
                let isRoot = folder.resolvingSymlinksInPath().standardizedFileURL.path == opened.url.resolvingSymlinksInPath().standardizedFileURL.path
                return (files, isRoot)
            }.value
            guard !Task.isCancelled, request == id else { return }
            items = result.0
            isMountRootFolder = result.1
            loading = false
            return
        }

        isMountRootFolder = false
        let loaded = await Task.detached(priority: .utility) { () -> ([StudyPage.Item], [MountedFolders.Inspection]) in
            if top { _ = try? DeskTrash.shared.entries() }
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
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { url in
            guard Workspace.isInsideRealRoot(url, root: baseRoot) else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isFolder = values?.isDirectory == true
            let shareURL: URL?
            if isFolder {
                shareURL = nil
            } else if values?.isRegularFile == true {
                shareURL = url.resolvingSymlinksInPath()
            } else {
                shareURL = nil
            }
            return StudyPage.Item(
                url: url,
                folder: isFolder,
                bytes: values?.fileSize ?? 0,
                changed: values?.contentModificationDate ?? .distantPast,
                mount: mount,
                shareURL: shareURL
            )
        }
        .sorted { ($0.folder ? 0 : 1, $1.changed) < ($1.folder ? 0 : 1, $0.changed) }
    }
}

private struct DeskTrashPage: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [DeskTrash.Record] = []
    @State private var loading = true
    @State private var busy = false
    @State private var confirmEmpty = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Ink.Space.l) {
                    Text(L.t("files.trashRetention"))
                        .font(Ink.secondary)
                        .foregroundStyle(Ink.inkSoft)
                    if loading {
                        ProgressView(L.t("loading.generic"))
                    } else if let errorMessage {
                        Text(errorMessage)
                            .font(Ink.secondary)
                            .foregroundStyle(Ink.warn)
                    }
                    if !loading && entries.isEmpty && errorMessage == nil {
                        Text(L.t("files.trashEmpty"))
                            .font(Ink.secondary)
                            .foregroundStyle(Ink.inkSoft)
                    } else if !entries.isEmpty {
                        rows
                    }
                }
                .padding(.horizontal, Ink.Space.page)
                .padding(.vertical, Ink.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Ink.paper.ignoresSafeArea())
            .navigationTitle(L.t("files.trash"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L.t("actions.done")) { dismiss() }
                }
                if !entries.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(L.t("files.trashEmptyAction"), systemImage: "trash.slash") { confirmEmpty = true }
                            .disabled(busy)
                    }
                }
            }
            .confirmationDialog(L.t("files.trashEmptyAction"), isPresented: $confirmEmpty, titleVisibility: .visible) {
                Button(L.t("files.trashEmptyAction"), role: .destructive) { run { try DeskTrash.shared.empty() } }
                Button(L.t("actions.cancel"), role: .cancel) {}
            } message: {
                Text(L.t("errors.cannotUndo"))
            }
            .task { await load() }
            .refreshable { await load() }
        }
    }

    private var rows: some View {
        LazyVStack(spacing: 0) {
            ForEach(entries) { entry in
                HStack(spacing: Ink.Space.s) {
                    RowLabel(
                        entry.isFolder ? "folder" : "doc",
                        tint: entry.isFolder ? Ink.Tile.accent : Ink.Tile.mo,
                        title: entry.relativePath,
                        line: [entry.mountName, entry.deletedAt.formatted(date: .abbreviated, time: .shortened)]
                            .compactMap { $0 }.joined(separator: " · "),
                        end: .none
                    )
                    Button(L.t("files.trashRestore")) { run { try DeskTrash.shared.restore(id: entry.id) } }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.capsule)
                        .padding(.trailing, Ink.Space.m)
                        .disabled(busy)
                }
                if entry.id != entries.last?.id { Kit.divider }
            }
        }
        .paperCard()
    }

    private func load() async {
        errorMessage = nil
        do {
            entries = try await Task.detached(priority: .utility) { try DeskTrash.shared.entries() }.value
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }

    private func run(_ action: @escaping @Sendable () throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await Task.detached(priority: .userInitiated, operation: action).value
                await load()
            } catch {
                await load()
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// One file: Markdown read as prose, other text in a code face, pictures to look at, tables as a grid,
/// and everything else (PDF, Word, Excel, Keynote…) through the system's own viewer.
struct StudyFile: View {
    let url: URL
    var mount: MountedFolder? = nil
    var showsDone = false
    var initialPage: Int? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @State private var text: String?
    @State private var csvRows: [[String]]?
    @State private var csvColumns = 0
    @State private var csvColumnChars: [Int] = []
    @State private var plain = false
    @State private var picture: UIImage?
    @State private var loaded = false
    @State private var mountBroken = false
    @State private var accessDenied = false
    @State private var scope: MountedFolders.ScopeToken?
    @State private var allowedRoot: URL?
    @State private var resolvedShareURL: URL?
    @State private var quickLookURL: URL?

    private var ext: String { url.pathExtension.lowercased() }
    private var interactive: Bool { InteractiveDocument.supports(url) }
    private var taskKey: String { (mount?.id ?? "desk") + "|" + url.path + "|\(initialPage ?? 0)" }
    private var markdown: Bool { ["md", "markdown", "txt"].contains(ext) }
    private var table: Bool { ["csv", "tsv"].contains(ext) }
    private var longPlainText: String? {
        // Keep the formatted preview for short snippets. A large TXT or huge Markdown dump can create thousands of prose views.
        guard let text else { return nil }
        if ext == "txt" {
            if text.utf8.count >= 4 * 1024 || text.utf8.lazy.filter({ $0 == UInt8(ascii: "\n") }).prefix(60).count >= 60 {
                return text
            }
            return nil
        }
        if ["md", "markdown"].contains(ext), text.utf8.count >= 128 * 1024 {
            return text
        }
        return nil
    }
    private var longTextStyleSignature: String {
        let theme = Theme.shared
        return "\(theme.size)|\(theme.face.rawValue)|\(theme.code.rawValue)|\(theme.key)|\(theme.oled ? 1 : 0)|\(theme.white ? 1 : 0)|\(theme.fontsArrived)"
    }

    var body: some View {
        ZStack {
            Ink.paper.ignoresSafeArea()
            if mountBroken {
                Text(L.t("files.mountBrokenFile"))
                    .font(Ink.secondary)
                    .foregroundStyle(Ink.inkSoft)
                    .multilineTextAlignment(.center)
                    .padding(Ink.Space.page)
            } else if accessDenied {
                Text(L.t("files.symlinkBlocked"))
                    .font(Ink.secondary)
                    .foregroundStyle(Ink.inkSoft)
                    .multilineTextAlignment(.center)
                    .padding(Ink.Space.page)
            } else if interactive, let allowedRoot {
                InteractivePreviewContent(document: InteractiveDocument(url: url, root: allowedRoot, mount: mount))
            } else if let picture {
                ScrollView([.horizontal, .vertical]) {
                    Image(uiImage: picture)
                        .resizable()
                        .scaledToFit()
                        .containerRelativeFrame(.horizontal)
                }
            } else if let longPlainText {
                LongTextPreview(
                    text: longPlainText,
                    isPlainProseText: ext == "txt",
                    themeSignature: longTextStyleSignature
                )
                    .id(url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if table, !plain, let csvRows {
                TableGrid(rows: csvRows, columns: csvColumns, columnChars: csvColumnChars)
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
                .scrollEdgeEffectStyle(.soft, for: .vertical)
            } else if loaded {
                if let quickLookURL {
                    if ext == "pdf", let initialPage, initialPage >= 1 {
                        StudyPDFPreview(url: quickLookURL, initialPage: initialPage).ignoresSafeArea(edges: .bottom)
                    } else {
                        QuickPreview(url: quickLookURL).ignoresSafeArea(edges: .bottom)
                    }
                } else {
                    Text(L.t("files.previewUnavailable"))
                        .font(Ink.secondary)
                        .foregroundStyle(Ink.inkSoft)
                        .padding(Ink.Space.page)
                }
            }
        }
        .hitchPage("书案文件")
        .navigationTitle(url.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if (markdown || table) && text != nil && longPlainText == nil {
                    Button(plain ? (table ? L.t("files.showTable") : L.t("files.showFormatted")) : L.t("files.showSource")) { plain.toggle() }
                }
                if let resolvedShareURL {
                    ShareLink(item: resolvedShareURL) { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel(L.t("files.shareFile"))
                }
                if showsDone {
                    Button(L.t("actions.done")) { dismiss() }
                }
            }
        }
        .task(id: taskKey) {
            let url = self.url
            let mount = self.mount
            let screenWidth = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .map { $0.screen.bounds.width }
                .max() ?? 430
            let maxPixelSize = max(1080, Int((screenWidth * displayScale).rounded()))

            picture = nil
            text = nil
            csvRows = nil
            csvColumns = 0
            csvColumnChars = []
            loaded = false
            mountBroken = false
            accessDenied = false
            allowedRoot = nil
            resolvedShareURL = nil
            quickLookURL = nil

            let effectiveRoot: URL
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
                effectiveRoot = opened.url
            } else {
                effectiveRoot = Workspace.root
            }

            let isInteractive = interactive
            let resolvedInfo = await Task.detached(priority: .utility) { () -> (inside: Bool, resolvedURL: URL, shareURL: URL?) in
                let inside = Workspace.isInsideRealRoot(url, root: effectiveRoot)
                let resolved = inside ? url.resolvingSymlinksInPath() : url
                let interactiveShare = (inside && isInteractive)
                    ? InteractiveDocument(url: url, root: effectiveRoot, mount: mount).shareURL
                    : nil
                return (inside, resolved, interactiveShare)
            }.value
            guard !Task.isCancelled else { return }
            guard resolvedInfo.inside else {
                accessDenied = true
                loaded = true
                return
            }
            allowedRoot = effectiveRoot
            if isInteractive {
                resolvedShareURL = resolvedInfo.shareURL
                return
            }
            resolvedShareURL = resolvedInfo.resolvedURL

            let result = await Task.detached(priority: .utility) {
                Self.readPreview(url, root: effectiveRoot, maxPixelSize: maxPixelSize)
            }.value
            guard !Task.isCancelled else { return }
            picture = result.picture
            text = result.text
            csvRows = result.csvRows
            csvColumns = result.csvColumns
            csvColumnChars = result.csvColumnChars
            if result.picture == nil && result.text == nil {
                quickLookURL = QLPreviewController.canPreview(resolvedInfo.resolvedURL as NSURL) ? resolvedInfo.resolvedURL : nil
            }
            loaded = true
        }
        .onDisappear {
            scope?.stop()
            scope = nil
            allowedRoot = nil
            resolvedShareURL = nil
            quickLookURL = nil
        }
    }

    private struct PreviewResult: Sendable {
        var picture: UIImage?
        var text: String?
        var csvRows: [[String]]?
        var csvColumns: Int = 0
        var csvColumnChars: [Int] = []
    }

    nonisolated private static func readPreview(_ url: URL, root baseRoot: URL, maxPixelSize: Int) -> PreviewResult {
        guard Workspace.isInsideRealRoot(url, root: baseRoot) else { return PreviewResult() }
        let fileExt = url.pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "heic", "gif", "webp", "bmp", "tiff"].contains(fileExt),
           let image = WorkspaceFileRef.decodePreview(at: url, maxPixelSize: maxPixelSize) {
            return PreviewResult(picture: image)
        }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 2_000_000,
              let data = try? Data(contentsOf: url), data.count < 2_000_000,
              let decoded = String(data: data, encoding: .utf8) else { return PreviewResult() }
        if ["csv", "tsv"].contains(fileExt) {
            let rows = CSV.rows(decoded, separator: fileExt == "tsv" ? "\t" : ",")
            let columns = rows.map(\.count).max() ?? 0
            var colChars = [Int](repeating: 1, count: columns)
            for row in rows {
                for (col, cell) in row.enumerated() where col < columns {
                    if cell.count > colChars[col] {
                        colChars[col] = min(28, cell.count)
                    }
                }
            }
            return PreviewResult(text: decoded, csvRows: rows, csvColumns: columns, csvColumnChars: colChars)
        }
        return PreviewResult(text: decoded)
    }
}

/// The text view owns scrolling so TextKit 2 can lay out the visible range without sizing the whole document.
private struct LongTextPreview: UIViewRepresentable {
    let text: String
    var isPlainProseText = false
    var themeSignature = ""
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(usingTextLayoutManager: true)
        view.isEditable = false
        view.isSelectable = true
        view.alwaysBounceVertical = true
        view.backgroundColor = .clear
        view.textContainer.lineFragmentPadding = 0
        view.textContainerInset = UIEdgeInsets(top: Ink.Space.l, left: Ink.Space.page,
                                              bottom: Ink.Space.l, right: Ink.Space.page)
        let style = resolvedStyle()
        applyStyle(style, to: view)
        view.text = text
        context.coordinator.lastText = text
        context.coordinator.lastStyleSignature = style.signature
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let style = resolvedStyle()
        if context.coordinator.lastStyleSignature != style.signature {
            applyStyle(style, to: view)
            context.coordinator.lastStyleSignature = style.signature
        }
        if context.coordinator.lastText != text {
            view.text = text
            context.coordinator.lastText = text
        }
    }

    private func resolvedStyle() -> (font: UIFont, color: UIColor, signature: String) {
        let theme = Theme.shared
        let font = isPlainProseText
            ? Ink.uiFace(CGFloat(Pref.size))
            : Ink.uiMono(max(12, CGFloat(Pref.size) - 3))
        let traits = UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
        let color = UIColor(Ink.ink).resolvedColor(with: traits)
        let signature = "\(isPlainProseText ? 1 : 0)|\(colorScheme == .dark ? 1 : 0)|\(theme.size)|\(theme.face.rawValue)|\(theme.code.rawValue)|\(theme.key)|\(theme.oled ? 1 : 0)|\(theme.white ? 1 : 0)|\(theme.fontsArrived)|\(themeSignature)"
        return (font, color, signature)
    }

    private func applyStyle(_ style: (font: UIFont, color: UIColor, signature: String), to view: UITextView) {
        if view.font != style.font {
            view.font = style.font
        }
        if view.textColor != style.color {
            view.textColor = style.color
        }
    }

    final class Coordinator {
        var lastText = ""
        var lastStyleSignature = ""
    }
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
    let columns: Int
    let columnChars: [Int]
    @State private var width: CGFloat = 0

    private var narrowColumn: CGFloat { Ink.Size.small * 4.6 }
    private var wideColumn: CGFloat {
        width > 0 ? min(Ink.Size.body * 16, max(narrowColumn, width * 0.56)) : Ink.Size.body * 13
    }

    private func columnWidths() -> [CGFloat] {
        (0..<columns).map { column in
            let chars = column < columnChars.count ? columnChars[column] : 4
            let estimated = CGFloat(chars) * Ink.Size.small * 0.72 + Ink.Space.s * 2
            return min(wideColumn, max(narrowColumn, estimated))
        }
    }

    var body: some View {
        let widths = columnWidths()
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(0..<columns, id: \.self) { column in
                            if column > 0 {
                                Rectangle().fill(Ink.rule).frame(width: 0.5)
                            }
                            Text(column < row.count ? row[column] : "")
                                .font(index == 0 ? .system(size: Ink.Size.small, weight: .semibold) : .system(size: Ink.Size.small))
                                .foregroundStyle(Ink.ink)
                                .lineLimit(3)
                                .frame(width: widths[column], alignment: .leading)
                                .padding(.horizontal, Ink.Space.s)
                                .padding(.vertical, Ink.Space.s)
                        }
                    }
                    .background(index == 0 ? Ink.accentWash : (index % 2 == 0 ? Ink.paperRaised : Color.clear))
                    Rectangle().fill(Ink.rule).frame(height: 0.5)
                }
            }
            .overlay(Rectangle().strokeBorder(Ink.rule, lineWidth: 0.5))
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

/// PDFKit viewer used when jumping directly to a matched page number from unified search.
private struct StudyPDFPreview: UIViewRepresentable {
    let url: URL
    let initialPage: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = UIColor(Ink.paper)
        applyDocument(on: view, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        view.backgroundColor = UIColor(Ink.paper)
        applyDocument(on: view, coordinator: context.coordinator)
    }

    private func applyDocument(on view: PDFView, coordinator: Coordinator) {
        let targetKey = "\(url.path)#\(initialPage)"
        guard coordinator.appliedKey != targetKey else { return }
        coordinator.appliedKey = targetKey
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
        }
        guard let document = view.document, document.pageCount > 0 else { return }
        let clampedIndex = min(max(0, initialPage - 1), document.pageCount - 1)
        guard let page = document.page(at: clampedIndex) else { return }
        view.go(to: page)
        DispatchQueue.main.async { [weak view] in
            guard let view, let doc = view.document, doc.pageCount > 0 else { return }
            let idx = min(max(0, initialPage - 1), doc.pageCount - 1)
            if let page = doc.page(at: idx) {
                view.go(to: page)
            }
        }
    }

    final class Coordinator {
        var appliedKey = ""
    }
}
