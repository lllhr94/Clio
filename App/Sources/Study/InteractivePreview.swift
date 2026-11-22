import SwiftUI
import UIKit
import WebKit

/// A local HTML or SVG document, viewed in an isolated web view with no connection to Roam.
struct InteractiveDocument: Equatable, Sendable {
    let url: URL
    var root = Workspace.root

    static func supports(_ url: URL) -> Bool {
        ["html", "htm", "svg"].contains(url.pathExtension.lowercased())
    }

    var shareURL: URL? {
        let resolved = url.resolvingSymlinksInPath()
        return Workspace.isInsideRealRoot(resolved, root: root) ? resolved : nil
    }

    fileprivate var fileInfo: (url: URL, revision: String)? {
        guard Self.supports(url), let path = shareURL,
              let values = try? path.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size <= PreparedPreview.limit else { return nil }
        let changed = values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
        return (path, "\(path.path)|\(size)|\(changed)")
    }
}

/// Give WebKit access to one copy carrying our policy, never the original document's neighbours.
private final class PreparedPreview: Sendable {
    static let limit = 12 * 1024 * 1024
    let file: URL

    private init(file: URL) { self.file = file }

    deinit { try? FileManager.default.removeItem(at: file) }

    static func make(_ document: InteractiveDocument) -> PreparedPreview? {
        guard let original = document.fileInfo?.url,
              let reader = try? FileHandle(forReadingFrom: original) else { return nil }
        defer { try? reader.close() }
        guard let data = try? reader.read(upToCount: limit + 1), data.count <= limit,
              let source = String(data: data, encoding: .utf8) else { return nil }

        let child = (document.url.pathExtension.lowercased() == "svg" ? "<!doctype html><html><body>" : "") + source
        // Put the child policy after its doctype when present, to keep standards-mode sizing.
        let policy = """
        <meta http-equiv="x-dns-prefetch-control" content="off">
        <meta http-equiv="Content-Security-Policy" content="\(restricted); frame-src 'none'">
        """
        let payload: String
        if let doctype = child.range(of: #"^\s*<!doctype\s+[^>]+>"#, options: [.regularExpression, .caseInsensitive]) {
            payload = String(child[..<doctype.upperBound]) + policy + String(child[doctype.upperBound...])
        } else {
            payload = policy + child
        }
        let quoted = payload.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
        let html = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="x-dns-prefetch-control" content="off">
        <meta http-equiv="Content-Security-Policy" content="\(restricted); frame-src 'self' about:">
        <style>html,body{margin:0;width:100%;height:100%}iframe{display:block;border:0;width:100%;height:100%}</style>
        </head><body><iframe sandbox="allow-scripts" title="Preview" srcdoc="\(quoted)"></iframe></body></html>
        """
        let file = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("clio-preview-\(UUID().uuidString).html")
        let preview = PreparedPreview(file: file)
        guard (try? Data(html.utf8).write(to: file, options: [.atomic, .completeFileProtection])) != nil else { return nil }
        return preview
    }

    // The outer and inner documents both need inline styles and scripts. The child inherits the outer policy,
    // then forbids frames as well. No local resources, workers, forms, or network connections are allowed.
    private static let restricted = """
    default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval'; style-src 'unsafe-inline';     img-src data: blob:; font-src data:; media-src data: blob:; connect-src 'none'; object-src 'none';     worker-src 'none'; form-action 'none'; base-uri 'none'
    """
}

@MainActor
private enum PreviewRules {
    private static var loading: Task<WKContentRuleList?, Never>?

    static func get() async -> WKContentRuleList? {
        if let loading { return await loading.value }
        let load = Task {
            await withCheckedContinuation { (continuation: CheckedContinuation<WKContentRuleList?, Never>) in
                WKContentRuleListStore.default().compileContentRuleList(
                    forIdentifier: "clio-offline-preview-v1",
                    encodedContentRuleList: #"""
                    [
                      {"trigger":{"url-filter":"^[a-z][a-z0-9+.-]*:"},"action":{"type":"block"}},
                      {"trigger":{"url-filter":"^(file|about|data|blob):"},"action":{"type":"ignore-previous-rules"}}
                    ]
                    """#
                ) { rules, _ in continuation.resume(returning: rules) }
            }
        }
        loading = load
        let rules = await load.value
        if rules == nil { loading = nil }
        return rules
    }
}

@MainActor
private final class OfflineWebPreview: NSObject, WKNavigationDelegate {
    let view: WKWebView
    private let preview: PreparedPreview
    private var waiting: CheckedContinuation<Bool, Never>?
    private var timer: Task<Void, Never>?
    private var snapshot: CheckedContinuation<UIImage?, Never>?
    private var snapshotTimer: Task<Void, Never>?

    init(_ preview: PreparedPreview, rules: WKContentRuleList, frame: CGRect = .zero) {
        self.preview = preview
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.ignoresViewportScaleLimits = true
        configuration.userContentController.add(rules)
        // WebRTC transports are separate from HTTP loading. Remove their entry points in every frame.
        configuration.userContentController.addUserScript(WKUserScript(source: """
        for (const key of ['RTCPeerConnection', 'webkitRTCPeerConnection', 'mozRTCPeerConnection',
                           'RTCIceGatherer', 'RTCIceTransport', 'WebTransport']) {
            if (key in globalThis) Object.defineProperty(globalThis, key, {value: undefined, configurable: false, writable: false});
        }
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        view = WKWebView(frame: frame, configuration: configuration)
        super.init()
        view.navigationDelegate = self
        view.isInspectable = false
        view.allowsLinkPreview = false
    }

    func load() async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: false); return }
                waiting = continuation
                if view.loadFileURL(preview.file, allowingReadAccessTo: preview.file) == nil {
                    finish(false)
                    return
                }
                timer = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(8)) } catch { return }
                    self?.stop()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.stop() }
        }
    }

    func stop() {
        view.stopLoading()
        finish(false)
        finishSnapshot(nil)
    }

    func still(in rect: CGRect) async -> UIImage? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                snapshot = continuation
                let options = WKSnapshotConfiguration()
                options.rect = rect
                options.snapshotWidth = NSNumber(value: Double(rect.width))
                snapshotTimer = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                    self?.finishSnapshot(nil)
                }
                view.takeSnapshot(with: options) { [weak self] image, _ in
                    MainActor.assumeIsolated { self?.finishSnapshot(image) }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishSnapshot(nil) }
        }
    }

    private func finishSnapshot(_ image: UIImage?) {
        snapshotTimer?.cancel()
        snapshotTimer = nil
        let continuation = snapshot
        snapshot = nil
        continuation?.resume(returning: image)
    }

    private func finish(_ ok: Bool) {
        timer?.cancel()
        timer = nil
        let continuation = waiting
        waiting = nil
        continuation?.resume(returning: ok)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url, let frame = action.targetFrame else { return .cancel }
        if !frame.isMainFrame {
            return ["about:srcdoc", "about:blank"].contains(url.absoluteString) ? .allow : .cancel
        }
        if url.isFileURL && url.standardizedFileURL.path == preview.file.path { return .allow }
        return .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(true) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(false) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(false) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(false)
        finishSnapshot(nil)
    }
}

/// A serial thumbnail renderer. Once the image is taken, the browser goes away, also in long chats.
@MainActor
final class InteractiveThumbnails {
    static let shared = InteractiveThumbnails()
    private let cache = NSCache<NSString, UIImage>()
    private var tail: Task<UIImage?, Never>?
    private var lastJob: UUID?

    private init() {
        cache.countLimit = 24
        cache.totalCostLimit = 16 * 1024 * 1024
    }

    func image(for document: InteractiveDocument) async -> UIImage? {
        let revision = await Task.detached(priority: .utility) { document.fileInfo?.revision }.value
        guard !Task.isCancelled, let revision else { return nil }
        let key = revision as NSString
        if let image = cache.object(forKey: key) { return image }

        let previous = tail
        let id = UUID()
        let job = Task { [weak self] () -> UIImage? in
            _ = await previous?.value
            guard let self, !Task.isCancelled else { return nil }
            if let image = self.cache.object(forKey: key) { return image }
            guard let image = await self.render(document) else { return nil }
            if let pixels = image.cgImage {
                self.cache.setObject(image, forKey: key, cost: pixels.bytesPerRow * pixels.height)
            }
            return image
        }
        tail = job
        lastJob = id
        defer {
            if lastJob == id { tail = nil; lastJob = nil }
        }
        return await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
    }

    private func render(_ document: InteractiveDocument) async -> UIImage? {
        let prepared = await Task.detached(priority: .utility) { PreparedPreview.make(document) }.value
        guard let prepared, !Task.isCancelled, let rules = await PreviewRules.get(), !Task.isCancelled else { return nil }
        let frame = CGRect(x: 0, y: 0, width: 440, height: 264)
        let web = OfflineWebPreview(prepared, rules: rules, frame: frame)
        // WebKit needs a window for canvas and compositing. Put this view behind the app's content.
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        guard let window = windows.first(where: { $0.isKeyWindow }) else { return nil }
        window.insertSubview(web.view, at: 0)
        web.view.isUserInteractionEnabled = false
        web.view.accessibilityElementsHidden = true
        defer { web.stop(); web.view.removeFromSuperview() }
        guard await web.load() else { return nil }
        do { try await Task.sleep(for: .milliseconds(160)) } catch { return nil }
        return await web.still(in: frame)
    }
}

struct InteractivePreviewPage: View {
    let document: InteractiveDocument
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            InteractivePreviewContent(document: document)
                .background(Ink.paper.ignoresSafeArea())
                .navigationTitle(document.url.lastPathComponent)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if let url = document.shareURL {
                            ShareLink(item: url) { Label(L.t("actions.share"), systemImage: "square.and.arrow.up") }
                        }
                        Button(L.t("actions.done")) { dismiss() }
                    }
                }
        }
    }
}

struct InteractivePreviewThumbnail: View {
    let document: InteractiveDocument
    @State private var image: UIImage?

    var body: some View {
        Ink.paperRaised
            .aspectRatio(5.0 / 3.0, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.system(size: Ink.Size.title))
                        .foregroundStyle(Ink.inkFaint)
                }
            }
            .clipShape(.rect(cornerRadius: Ink.Radius.small, style: .continuous))
            .accessibilityHidden(true)
            .task(id: document.url) {
                let preview = await InteractiveThumbnails.shared.image(for: document)
                if !Task.isCancelled { image = preview }
            }
    }
}

struct InteractivePreviewContent: View {
    let document: InteractiveDocument
    @State private var web: OfflineWebPreview?
    @State private var ready = false
    @State private var failed = false

    var body: some View {
        ZStack {
            if let web {
                PreviewWebView(view: web.view).opacity(ready ? 1 : 0)
                    .ignoresSafeArea(edges: .bottom)
            }
            if failed {
                Text(L.t("interactivePreview.unavailable"))
                    .font(Ink.secondary)
                    .foregroundStyle(Ink.inkSoft)
                    .multilineTextAlignment(.center)
                    .padding(Ink.Space.page)
            } else if !ready {
                ProgressView(L.t("loading.generic"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { InteractivePreviewRotation() }
        .task(id: document.url) {
            ready = false
            failed = false
            let prepared = await Task.detached(priority: .userInitiated) { PreparedPreview.make(document) }.value
            let rules = await PreviewRules.get()
            guard !Task.isCancelled else { return }
            guard let prepared, let rules else { failed = true; return }
            let page = OfflineWebPreview(prepared, rules: rules)
            web = page
            let loaded = await page.load()
            guard !Task.isCancelled else { return }
            ready = loaded
            failed = !loaded
        }
        .onDisappear {
            web?.stop()
            web = nil
        }
    }
}

/// Keep the rest of Clio portrait. Register only the scene containing a visible preview.
@MainActor
struct InteractivePreviewRotation: UIViewRepresentable {
    private static var scenes: [ObjectIdentifier: Set<UUID>] = [:]

    static func supported(for window: UIWindow?) -> UIInterfaceOrientationMask {
        guard let scene = window?.windowScene, scenes[ObjectIdentifier(scene)]?.isEmpty == false else { return .portrait }
        return .allButUpsideDown
    }

    func makeUIView(context: Context) -> Hook { Hook() }
    func updateUIView(_ view: Hook, context: Context) {}

    final class Hook: UIView {
        private let token = UUID()
        private weak var registered: UIWindowScene?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            let next = window?.windowScene
            guard next !== registered else { return }
            if let old = registered { Self.change(old, token: token, on: false) }
            registered = next
            if let next { Self.change(next, token: token, on: true) }
        }

        private static func change(_ scene: UIWindowScene, token: UUID, on: Bool) {
            let key = ObjectIdentifier(scene)
            if on { scenes[key, default: []].insert(token) }
            else {
                scenes[key]?.remove(token)
                if scenes[key]?.isEmpty == true { scenes[key] = nil }
            }
            // Wait until the presenting controller is in place (or gone) before asking UIKit.
            Task { @MainActor [weak scene] in
                guard let scene, let window = scene.windows.first(where: \.isKeyWindow) else { return }
                var controller = window.rootViewController
                while let viewController = controller {
                    viewController.setNeedsUpdateOfSupportedInterfaceOrientations()
                    controller = viewController.presentedViewController
                }
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: supported(for: window)))
            }
        }
    }
}

private struct PreviewWebView: UIViewRepresentable {
    let view: WKWebView
    func makeUIView(context: Context) -> WKWebView { view }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
