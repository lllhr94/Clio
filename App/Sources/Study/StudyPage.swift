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

    var body: some View {
        ZStack {
            Ink.paper.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: Ink.Space.l) {
                    if top {
                        Text("旅伴写下的东西都放在这里。在「文件」app 的「我的 iPhone › Clio › 书案」里也能看到。")
                            .font(Ink.secondary)
                            .foregroundStyle(Ink.inkSoft)
                    }
                    if items.isEmpty {
                        VStack(spacing: Ink.Space.m) {
                            Whale(size: 72, pose: .idle, still: true)
                            Text("书案还空着。让旅伴整理点什么，比如「把今天聊的写成笔记存到书案」。")
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
                                        if !item.folder { ShareLink(item: item.url) { Label("分享", systemImage: "square.and.arrow.up") } }
                                        Button("删掉", systemImage: "trash", role: .destructive) { deleting = item }
                                    }
                                if item.id != items.last?.id { Rectangle().fill(Ink.rule).frame(height: 1).padding(.leading, 52) }
                            }
                        }
                        .paperCard()
                    }
                }
                .padding(.horizontal, Ink.Space.page)
                .padding(.vertical, Ink.Space.l)
            }
        }
        .navigationTitle(top ? "书案" : folder.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let close {
                ToolbarItem(placement: .topBarLeading) {
                    Button("好了") { close() }
                }
            }
        }
        .onAppear(perform: load)
        .refreshable { load() }
        .confirmationDialog("删掉「\(deleting?.url.lastPathComponent ?? "")」？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("删掉", role: .destructive) {
                if let item = deleting {
                    try? FileManager.default.removeItem(at: item.url)
                    Haptics.lock()
                    withAnimation(Ink.Motion.settle) { load() }
                }
                deleting = nil
            }
            Button("留着", role: .cancel) { deleting = nil }
        }
    }

    private func row(_ item: StudyPage.Item) -> some View {
        HStack(spacing: Ink.Space.m) {
            Image(systemName: item.folder ? "folder" : Self.icon(item.url))
                .font(.system(size: 18))
                .foregroundStyle(item.folder ? Ink.accent : Ink.inkSoft)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.url.lastPathComponent).font(.system(size: 16)).foregroundStyle(Ink.ink).lineLimit(1)
                Text((item.folder ? "" : Workspace.size(item.bytes) + " · ") + item.changed.formatted(.relative(presentation: .named)))
                    .font(Ink.footnote)
                    .foregroundStyle(Ink.inkFaint)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.inkFaint)
        }
        .padding(.horizontal, Ink.Space.l)
        .padding(.vertical, Ink.Space.m)
        .contentShape(Rectangle())
    }

    static func icon(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "md", "txt": "doc.text"
        case "json", "js", "py", "sh", "swift", "html", "css", "csv": "chevron.left.forwardslash.chevron.right"
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

/// One file: Markdown read as prose, other text in a code face, anything else offered to share.
struct StudyFile: View {
    let url: URL
    @State private var text: String?
    @State private var plain = false

    private var markdown: Bool { ["md", "markdown", "txt"].contains(url.pathExtension.lowercased()) }

    var body: some View {
        ZStack {
            Ink.paper.ignoresSafeArea()
            ScrollView {
                Group {
                    if let text {
                        if markdown && !plain {
                            ProseView(text: text, streaming: false)
                        } else {
                            Text(text)
                                .font(Ink.code)
                                .foregroundStyle(Ink.ink)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        Text("这个文件不是文字，可以分享出去用别的 app 打开。")
                            .font(Ink.secondary)
                            .foregroundStyle(Ink.inkSoft)
                    }
                }
                .padding(.horizontal, Ink.Space.page)
                .padding(.vertical, Ink.Space.l)
            }
        }
        .navigationTitle(url.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if markdown && text != nil {
                    Button(plain ? "排版" : "原文") { plain.toggle() }
                }
                ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
            }
        }
        .onAppear {
            if let data = try? Data(contentsOf: url), data.count < 2_000_000 { text = String(data: data, encoding: .utf8) }
        }
    }
}
