import SwiftUI
import UIKit
import Vision
import VisionKit

/// What the ＋ can bring into a message.
enum AttachKind: String, CaseIterable, Identifiable {
    case photos, camera, files, desk, scan, clipboard, link, place

    var id: String { rawValue }

    var title: String {
        switch self {
        case .photos: "相册"
        case .camera: "拍照"
        case .files: "文件"
        case .desk: "书案"
        case .scan: "扫描文档"
        case .clipboard: "剪贴板"
        case .link: "网页链接"
        case .place: "位置"
        }
    }

    var line: String {
        switch self {
        case .photos: "最多四张"
        case .camera: "拍一张"
        case .files: "从「文件」app 选"
        case .desk: "旅伴写过的文件"
        case .scan: "扫完自动识字"
        case .clipboard: "刚复制的东西"
        case .link: "请旅伴去读"
        case .place: "附上你在哪"
        }
    }

    var symbol: String {
        switch self {
        case .photos: "photo.on.rectangle"
        case .camera: "camera"
        case .files: "folder"
        case .desk: "books.vertical"
        case .scan: "doc.viewfinder"
        case .clipboard: "doc.on.clipboard"
        case .link: "link"
        case .place: "location"
        }
    }
}

/// The ＋ panel: eight ways to bring something in, four to a row.
struct AttachSheet: View {
    let pick: (AttachKind) -> Void
    @Environment(\.dismiss) private var dismiss

    private let columns = Array(repeating: GridItem(.flexible(), spacing: Ink.Space.m), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: Ink.Space.l) {
            Text("带点什么进来")
                .font(Ink.serif(17, bold: true))
                .foregroundStyle(Ink.ink)
                .padding(.top, Ink.Space.l)
            LazyVGrid(columns: columns, spacing: Ink.Space.l) {
                ForEach(AttachKind.allCases) { kind in
                    Button {
                        Haptics.tick(0.5)
                        pick(kind)
                        dismiss()
                    } label: {
                        VStack(spacing: Ink.Space.xs) {
                            Image(systemName: kind.symbol)
                                .font(.system(size: 20, weight: .medium))
                                .foregroundStyle(Ink.accent)
                                .frame(width: 54, height: 54)
                                .background(Ink.paperRaised, in: .rect(cornerRadius: Ink.Radius.card))
                                .overlay(RoundedRectangle(cornerRadius: Ink.Radius.card).strokeBorder(Ink.rule))
                            Text(kind.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Ink.ink).lineLimit(1)
                            Text(kind.line).font(.system(size: 10)).foregroundStyle(Ink.inkFaint).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PressStyle(haptic: false))
                    .disabled(kind == .scan && !VNDocumentCameraViewController.isSupported)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Ink.Space.page)
        .background(Ink.paper.ignoresSafeArea())
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
                    Text("书案还空着。")
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
                                            .font(.system(size: 18))
                                            .foregroundStyle(chosen.contains(item.path) ? Ink.accent : Ink.inkFaint)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text((item.path as NSString).lastPathComponent).font(.system(size: 15)).foregroundStyle(Ink.ink).lineLimit(1)
                                            Text("书案/\(item.path) · \(Workspace.size(item.size))")
                                                .font(Ink.footnote).foregroundStyle(Ink.inkFaint).lineLimit(1)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, Ink.Space.l)
                                    .padding(.vertical, Ink.Space.m)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(TapStyle())
                                Rectangle().fill(Ink.rule).frame(height: 1).padding(.leading, 48)
                            }
                        }
                        .paperCard()
                        .padding(.horizontal, Ink.Space.page)
                        .padding(.vertical, Ink.Space.l)
                    }
                    .searchable(text: $query, prompt: "找文件名")
                }
            }
            .navigationTitle("从书案挑")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("算了") { done([]) } }
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
