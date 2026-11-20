import Photos
import SwiftUI
import UIKit
import Vision
import VisionKit

/// What the ＋ can bring into a message. Like other chat apps, only the ways to bring a picture or a file;
/// pasting works in the text field, and the companion finds out where you are or reads a link by itself.
enum AttachKind: String, CaseIterable, Identifiable {
    case photos, camera, files, scan, desk

    var id: String { rawValue }

    var title: String {
        switch self {
        case .photos: "照片"
        case .camera: "拍照"
        case .files: "文件"
        case .scan: "扫描文档"
        case .desk: Words.t("书案里的文件")
        }
    }

    var symbol: String {
        switch self {
        case .photos: "photo.on.rectangle"
        case .camera: "camera"
        case .files: "folder"
        case .scan: "doc.viewfinder"
        case .desk: "books.vertical"
        }
    }
}

/// Picks files already in 书案, newest first.
struct DeskPicker: View {
    let done: ([String]) -> Void
    @State private var all: [(path: String, date: Date, size: Int)] = []
    @State private var chosen: Set<String> = []
    @State private var query = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Ink.paper.ignoresSafeArea()
                if all.isEmpty {
                    Text(Words.t("书案还空着。"))
                        .font(Ink.secondary)
                        .foregroundStyle(Ink.inkSoft)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(shown, id: \.path) { item in
                                Button {
                                    Haptics.tick(0.4)
                                    if chosen.contains(item.path) { chosen.remove(item.path) } else { chosen.insert(item.path) }
                                } label: {
                                    HStack(spacing: Ink.Space.m) {
                                        Image(systemName: chosen.contains(item.path) ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: Ink.Size.title))
                                            .foregroundStyle(chosen.contains(item.path) ? Ink.accent : Ink.inkFaint)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text((item.path as NSString).lastPathComponent).font(.system(size: Ink.Size.sub)).foregroundStyle(Ink.ink).lineLimit(1)
                                            Text(Words.t("书案/\(item.path) · \(Workspace.size(item.size))"))
                                                .font(Ink.footnote).foregroundStyle(Ink.inkFaint).lineLimit(1)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, Ink.Space.l)
                                    .padding(.vertical, Ink.Space.m)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(TapStyle())
                                Kit.rule(inset: 48)
                            }
                        }
                        .paperCard()
                        .padding(.horizontal, Ink.Space.page)
                        .padding(.vertical, Ink.Space.l)
                    }
                    .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "找文件名")
                }
            }
            .navigationTitle(L.t("chat.chooseFromFiles"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(L.t("actions.cancel")) { done([]) } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(chosen.isEmpty ? "带上" : "带上 \(chosen.count) 个") { done(Array(chosen).sorted()) }
                        .fontWeight(.semibold)
                        .disabled(chosen.isEmpty)
                }
            }
        }
        .onAppear(perform: load)
    }

    private var shown: [(path: String, date: Date, size: Int)] {
        let words = query.trimmingCharacters(in: .whitespaces)
        return words.isEmpty ? all : all.filter { $0.path.localizedCaseInsensitiveContains(words) }
    }

    private func load() {
        let root = Workspace.root
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        var found: [(path: String, date: Date, size: Int)] = []
        if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
            for case let url as URL in walker {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                found.append((Workspace.relative(url), values.contentModificationDate ?? .distantPast, values.fileSize ?? 0))
                if found.count > 2000 { break }
            }
        }
        all = found.sorted { $0.date > $1.date }
    }
}

/// The system's document scanner.
struct ScannerView: UIViewControllerRepresentable {
    let done: ([UIImage]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let done: ([UIImage]) -> Void
        init(done: @escaping ([UIImage]) -> Void) { self.done = done }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            done((0..<scan.pageCount).map { scan.imageOfPage(at: $0) })
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { done([]) }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) { done([]) }
    }
}

/// Scanned pages: kept as pictures in 书案/收件, with their words read out into a text file beside them.
enum Scan {
    /// Returns the text file's path in 书案 and how many characters were read.
    static func keep(_ pages: [UIImage]) async -> (text: String, count: Int)? {
        guard !pages.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let stamp = formatter.string(from: Date())
        let folder = Workspace.root.appendingPathComponent("收件/扫描 \(stamp)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var words: [String] = []
        for (index, page) in pages.enumerated() {
            if let data = page.jpegData(compressionQuality: 0.8) {
                try? data.write(to: folder.appendingPathComponent("第\(index + 1)页.jpg"))
            }
            let text = await read(page)
            words.append("——第 \(index + 1) 页——\n" + text)
        }
        let all = words.joined(separator: "\n\n")
        let file = folder.appendingPathComponent("识别的文字.txt")
        try? Data(all.utf8).write(to: file)
        return (Workspace.relative(file), all.count)
    }

    /// Reads the words on one picture, Chinese and English.
    static func read(_ image: UIImage) async -> String {
        guard let cgImage = image.cgImage else { return "" }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
                request.usesLanguageCorrection = true
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                try? handler.perform([request])
                let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
        }
    }
}

/// The ＋ sheet, after Claude's: recent photos on top, then camera and files; below, how this conversation works
/// (where, what the companion may use, web, skills, memory). One place for what was a row of chips.
struct PlusSheet: View {
    @ObservedObject var team: TeamModel
    let key: String
    let name: String
    let isRoom: Bool
    /// A photo tapped in the strip, as JPEG data. Returns what was put in the composer (nil: not added).
    let addPhoto: (Data) -> Data?
    /// A photo tapped again: taken back out of the composer.
    let removePhoto: (Data) -> Void
    /// Camera, files or the full photo picker: opened once the sheet is gone.
    let pick: (AttachKind) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var recent: [PHAsset] = []
    @State private var thumbs: [String: UIImage] = [:]
    @State private var added: Set<String> = []
    /// What each picked photo became in the composer, to take it back out.
    @State private var placed: [String: Data] = [:]
    @State private var access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var abilities = false
    @State private var skills = false

    private var options: TeamModel.ChatOptions { team.options(key) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Ink.Space.l) {
                    strip
                    group {
                        line("camera", "拍照") { choose(.camera) }
                        divider
                        line("folder", "添加文件") { choose(.files) }
                    }
                    group {
                        NavigationLink {
                            PlacePicker(team: team, key: key)
                        } label: {
                            row("desktopcomputer", "在哪里干活", value: team.place(of: key).title)
                        }
                        .buttonStyle(TapStyle())
                        divider
                        line("checkmark.shield", Words.t("本事"), value: options.off.isEmpty ? "全开" : "关了 \(options.off.count) 项") { abilities = true }
                    }
                    group {
                        line("books.vertical", "技能", value: "\(SkillShelf.enabled.count) 个") { skills = true }
                        divider
                        toggle("brain", "拾遗", note: "记住你说过的事", isOn: !options.off.contains(Grant.memory.rawValue)) { team.setAbility(.memory, on: $0, in: key) }
                    }
                }
                .padding(.horizontal, Ink.Space.page)
                .padding(.bottom, Ink.Space.xl)
            }
            .background(Ink.paper.ignoresSafeArea())
            .navigationTitle(L.t("chat.addToConversation"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("关上")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // Picked from the strip: the corner is where you say you're done, like any photo picker.
                    if added.isEmpty {
                        Button("所有照片") { choose(.photos) }
                    } else {
                        Button {
                            Haptics.light()
                            dismiss()
                        } label: {
                            Label("完成 · \(added.count) 张", systemImage: "checkmark")
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Ink.accent)
                        .accessibilityLabel("完成，已加上 \(added.count) 张照片")
                    }
                }
            }
        }
        .sheet(isPresented: $abilities) { AbilitiesSheet(team: team, key: key, name: name) }
        .sheet(isPresented: $skills) { SkillsPage() }
        .task { loadRecent() }
    }

    // MARK: Recent photos

    @ViewBuilder
    private var strip: some View {
        if access == .authorized || access == .limited {
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(recent, id: \.localIdentifier) { asset in
                        let id = asset.localIdentifier
                        Button { take(asset) } label: {
                            ZStack(alignment: .topTrailing) {
                                Group {
                                    if let image = thumbs[id] { Image(uiImage: image).resizable().scaledToFill() } else { Ink.paperRaised }
                                }
                                .frame(width: 110, height: 110)
                                .clipped()
                                if added.contains(id) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: Ink.Size.title))
                                        .foregroundStyle(.white, Ink.accent)
                                        .padding(6)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(added.contains(id) ? "已加上，再点一下拿掉" : "加上这张照片")
                    }
                }
            }
            .scrollIndicators(.hidden)
            .clipShape(RoundedRectangle(cornerRadius: Ink.Radius.card, style: .continuous))
            .frame(height: 110)
        } else {
            Button {
                Task {
                    access = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                    loadRecent()
                }
            } label: {
                Label("允许后，这里会显示最近的照片，点一下就加上", systemImage: "photo.on.rectangle")
                    .font(Ink.footnote)
                    .foregroundStyle(Ink.inkSoft)
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .background(Ink.paperRaised, in: .rect(cornerRadius: Ink.Radius.card, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private func loadRecent() {
        guard access == .authorized || access == .limited else { return }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 24
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        recent = assets
        let manager = PHImageManager.default()
        let request = PHImageRequestOptions()
        request.deliveryMode = .opportunistic
        request.isNetworkAccessAllowed = true
        for asset in assets {
            manager.requestImage(for: asset, targetSize: CGSize(width: 240, height: 240), contentMode: .aspectFill, options: request) { image, _ in
                if let image { thumbs[asset.localIdentifier] = image }
            }
        }
    }

    private func take(_ asset: PHAsset) {
        let id = asset.localIdentifier
        // Tapped again: put back, like ticking a photo off in the Photos picker.
        if added.contains(id) {
            Haptics.tick(0.4)
            if let data = placed.removeValue(forKey: id) { removePhoto(data) }
            _ = withAnimation(Ink.Motion.settle) { added.remove(id) }
            return
        }
        Haptics.tick(0.6)
        let request = PHImageRequestOptions()
        request.deliveryMode = .highQualityFormat
        request.isNetworkAccessAllowed = true
        PHImageManager.default().requestImageDataAndOrientation(for: asset, options: request) { data, _, _, _ in
            guard let data, let kept = addPhoto(data) else { return }
            placed[id] = kept
            _ = withAnimation(Ink.Motion.settle) { added.insert(id) }
        }
    }

    // MARK: Rows

    private func choose(_ kind: AttachKind) {
        Haptics.light()
        pick(kind)
        dismiss()
    }

    private var divider: some View { Kit.rule(inset: 52) }

    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }.paperCard()
    }

    private func row(_ icon: String, _ title: String, value: String? = nil) -> some View {
        HStack(spacing: Ink.Space.m) {
            Image(systemName: icon).font(.system(size: Ink.Size.title)).foregroundStyle(Ink.ink).frame(width: 28)
            Text(title).font(.system(size: Ink.Size.body)).foregroundStyle(Ink.ink)
            Spacer(minLength: 0)
            if let value { Text(value).font(.system(size: Ink.Size.sub)).foregroundStyle(Ink.inkSoft).lineLimit(1) }
            Kit.chevron
        }
        .padding(.horizontal, Ink.Space.l)
        .frame(minHeight: 54)
        .contentShape(Rectangle())
    }

    private func line(_ icon: String, _ title: String, value: String? = nil, _ run: @escaping () -> Void) -> some View {
        Button(action: run) { row(icon, title, value: value) }.buttonStyle(TapStyle())
    }

    private func toggle(_ icon: String, _ title: String, note: String, isOn: Bool, _ set: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: Ink.Space.m) {
            Image(systemName: icon).font(.system(size: Ink.Size.title)).foregroundStyle(Ink.ink).frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: Ink.Size.body)).foregroundStyle(Ink.ink)
                Text(note).font(Ink.footnote).foregroundStyle(Ink.inkFaint)
            }
            Spacer(minLength: 0)
            Toggle(title, isOn: Binding(get: { isOn }, set: { value in
                Haptics.tick(0.5)
                set(value)
            }))
            .labelsHidden()
            .tint(Ink.accent)
        }
        .padding(.horizontal, Ink.Space.l)
        .frame(minHeight: 58)
    }
}

/// 在哪里干活, as its own small page.
struct PlacePicker: View {
    @ObservedObject var team: TeamModel
    let key: String

    var body: some View {
        let current = team.place(of: key)
        var places: [(WorkPlace, String)] = [(.desk, "手机里的文件夹，读写文件、算数"), (.den, "手机里的 Linux，能跑命令、装软件")]
        places += Hills.shared.hosts.map { (.hill($0.id), "\($0.user)@\($0.address)") }
        return List {
            Section {
                ForEach(Array(places.enumerated()), id: \.offset) { _, item in
                    Button {
                        Haptics.tick(0.5)
                        team.setPlace(item.0, in: key)
                    } label: {
                        HStack {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.0.title).foregroundStyle(Ink.ink)
                                    Text(item.1).font(.footnote).foregroundStyle(Ink.inkSoft)
                                }
                            } icon: {
                                Image(systemName: item.0.symbol).foregroundStyle(Ink.accent)
                            }
                            Spacer()
                            if current == item.0 { Image(systemName: "checkmark").foregroundStyle(Ink.accent) }
                        }
                    }
                }
            } footer: {
                Text(Hills.shared.hosts.isEmpty ? Words.t("在调弦 › 远山 添一台电脑或服务器，这里就能选它。") : Words.t("换了地方，旅伴下一轮就在那里读写文件、跑命令。"))
            }
        }
        .scrollContentBackground(.hidden)
        .background(Ink.paper.ignoresSafeArea())
        .navigationTitle(L.t("chat.workLocation"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
