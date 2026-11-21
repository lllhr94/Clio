import QuickLook
import SwiftUI

/// 书案: the folder the companions work in. Browse it, read what they wrote, share or throw away.
struct StudyPage: View {
    var folder: URL = Workspace.root
    @Environment(\.dismiss) private var dismiss
    @State private var items: [Item] = []
    @State private var deleting: Item?

    struct Item: Identifiable, Hashable {
        let url: URL
        let folder: Bool
        let bytes: Int
        let changed: Date
        var id: URL { url }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationDestination(for: Item.self) { item in
                    if item.folder { StudyFolder(folder: item.url) } else { StudyFile(url: item.url) }
                }
        }
    }

    private var content: some View {
        StudyFolder(folder: folder, top: true, close: { dismiss() })
    }
}

/// One folder of the desk, as a list.
struct StudyFolder: View {
    let folder: URL
    var top = false
    var close: (() -> Void)?
    @State private var items: [StudyPage.Item] = []
    @State private var deleting: StudyPage.Item?
    @State private var importing = false
    @State private var naming = false
    @State private var newFolder = ""

    var body: some View {
        ZStack {
            Ink.paper.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: Ink.Space.l) {
                    if top {
                        Text(L.t("files.localPath"))
                            .font(Ink.secondary)
                            .foregroundStyle(Ink.inkSoft)
                    }
                    if items.isEmpty {
                        VStack(spacing: Ink.Space.m) {
                            PetStill(size: 72)
                            Text(L.t("empty.files"))
                                .font(Ink.secondary)
                                .foregroundStyle(Ink.inkSoft)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Ink.Space.xxl)
                    } else {
                        VStack(spacing: 0) {
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
                .padding(.horizontal, Ink.Space.page)
                .padding(.vertical, Ink.Space.l)
            }
        }
        .hitchPage("书案")
        .navigationTitle(top ? L.t("nav.files") : folder.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let close {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L.t("actions.done")) { close() }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(L.t("actions.importFromFiles"), systemImage: "square.and.arrow.down") { importing = true }
                    Button(L.t("actions.newFolder"), systemImage: "folder.badge.plus") { newFolder = ""; naming = true }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L.t("actions.addFilesOrFolder"))
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
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
                try? FileManager.default.copyItem(at: source, to: target)
            }
            Haptics.thud()
            withAnimation(Ink.Motion.settle) { load() }
        }
        .alert(L.t("actions.newFolder"), isPresented: $naming) {
            TextField(L.t("files.folderName"), text: $newFolder)
            Button(L.t("actions.create")) {
                let name = newFolder.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
                guard !name.isEmpty else { return }
                try? FileManager.default.createDirectory(at: folder.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: true)
                withAnimation(Ink.Motion.settle) { load() }
            }
            Button(L.t("actions.cancel"), role: .cancel) {}
        }
        .onAppear(perform: load)
        .refreshable { load() }
        .confirmationDialog(L.format("files.deleteConfirm", deleting?.url.lastPathComponent ?? ""), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button(L.t("actions.delete"), role: .destructive) {
                if let item = deleting {
                    try? FileManager.default.removeItem(at: item.url)
                    Haptics.lock()
                    withAnimation(Ink.Motion.settle) { load() }
                }
                deleting = nil
            }
            Button(L.t("actions.cancel"), role: .cancel) { deleting = nil }
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

    private func load() {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        items = urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return StudyPage.Item(url: url, folder: values?.isDirectory == true, bytes: values?.fileSize ?? 0, changed: values?.contentModificationDate ?? .distantPast)
        }
        .sorted { ($0.folder ? 0 : 1, $1.changed) < ($1.folder ? 0 : 1, $0.changed) }
    }
}

/// One file: Markdown read as prose, other text in a code face, pictures to look at, tables as a grid,
/// and everything else (PDF, Word, Excel, Keynote…) through the system's own viewer.
struct StudyFile: View {
    let url: URL
    @State private var text: String?
    @State private var plain = false
    @State private var picture: UIImage?
    @State private var loaded = false

    private var ext: String { url.pathExtension.lowercased() }
    private var markdown: Bool { ["md", "markdown", "txt"].contains(ext) }
    private var table: Bool { ["csv", "tsv"].contains(ext) }

    var body: some View {
        ZStack {
            Ink.paper.ignoresSafeArea()
            if let picture {
                ScrollView([.horizontal, .vertical]) {
                    Image(uiImage: picture)
                        .resizable()
                        .scaledToFit()
                        .containerRelativeFrame(.horizontal)
                }
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
        .navigationTitle(url.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if (markdown || table) && text != nil {
                    Button(plain ? (table ? L.t("files.showTable") : L.t("files.showFormatted")) : L.t("files.showSource")) { plain.toggle() }
                }
                ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("分享文件")
            }
        }
        .onAppear {
            defer { loaded = true }
            if ["png", "jpg", "jpeg", "heic", "gif", "webp", "bmp", "tiff"].contains(ext), let image = UIImage(contentsOfFile: url.path) {
                picture = image
                return
            }
            if let data = try? Data(contentsOf: url), data.count < 2_000_000 { text = String(data: data, encoding: .utf8) }
        }
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
                                .frame(minWidth: 60, maxWidth: 220, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(index == 0 ? Ink.accentWash : (index % 2 == 0 ? Ink.paperRaised : Color.clear))
                                .overlay(Rectangle().strokeBorder(Ink.rule, lineWidth: 0.5))
                        }
                    }
                }
            }
            .padding(Ink.Space.l)
            .textSelection(.enabled)
        }
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
