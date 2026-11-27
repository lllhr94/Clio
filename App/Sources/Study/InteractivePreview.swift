import SwiftUI
import UIKit
import WebKit

/// A local HTML or SVG document, viewed in an isolated web view with no connection to Roam.
struct InteractiveDocument: Equatable, Sendable {
    let url: URL
    var root = Workspace.root
    var mount: MountedFolder? = nil

    static func supports(_ url: URL) -> Bool {
        ["html", "htm", "svg"].contains(url.pathExtension.lowercased())
    }

    var shareURL: URL? {
        let resolved = url.resolvingSymlinksInPath()
        return Workspace.isInsideRealRoot(resolved, root: root) ? resolved : nil
    }

    fileprivate var fileInfo: (url: URL, revision: String)? {
        guard Self.supports(url) else { return nil }
        if let mount {
            guard MountedFolders.isCurrent(mount),
                  let opened = MountedFolders.openForUI(mount) else { return nil }
            defer { opened.token.stop() }
            let resolved = url.resolvingSymlinksInPath()
            guard Workspace.isInsideRealRoot(resolved, root: opened.url),
                  let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
                  values.isRegularFile == true, let size = values.fileSize, size <= PreparedPreview.limit else { return nil }
            let changed = values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
            return (resolved, "\(mount.id)|\(resolved.path)|\(size)|\(changed)")
        }
        guard let path = shareURL,
              let values = try? path.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size <= PreparedPreview.limit else { return nil }
        let changed = values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
        return (path, "\(path.path)|\(size)|\(changed)")
    }
}

/// Give WebKit access to one copy carrying our policy, never the original document's neighbours.
final class PreparedPreview: Sendable {
    static let limit = 12 * 1024 * 1024
    let file: URL

    private init(file: URL) { self.file = file }

    deinit { try? FileManager.default.removeItem(at: file) }

    static func make(_ document: InteractiveDocument, theme: CardStyleKit.Theme? = nil) -> PreparedPreview? {
        let mountScope = document.mount.flatMap { MountedFolders.openForUI($0) }
        defer { mountScope?.token.stop() }
        if document.mount != nil, mountScope == nil { return nil }
        let effectiveRoot = mountScope?.url ?? document.root
        let resolved = document.url.resolvingSymlinksInPath()
        guard Self.supports(document.url), Workspace.isInsideRealRoot(resolved, root: effectiveRoot),
              let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size <= limit,
              let reader = try? FileHandle(forReadingFrom: resolved) else { return nil }
        defer { try? reader.close() }
        guard let data = try? reader.read(upToCount: limit + 1), data.count <= limit,
              let source = String(data: data, encoding: .utf8) else { return nil }

        let isSVG = document.url.pathExtension.lowercased() == "svg"
        let child = (isSVG ? "<!doctype html><html><body>" : "") + source
        // Put the child policy after its doctype when present, to keep standards-mode sizing.
        let policy = """
        <meta http-equiv="x-dns-prefetch-control" content="off">
        <meta http-equiv="Content-Security-Policy" content="\(restricted); frame-src 'none'">
        """
        let assets: String
        if let theme, !isSVG, CardStyleKit.isOptedIn(source) {
            assets = CardStyleKit.injection(theme: theme)
        } else {
            assets = ""
        }
        let payload: String
        if let doctype = child.range(of: #"^\s*<!doctype\s+[^>]+>"#, options: [.regularExpression, .caseInsensitive]) {
            payload = String(child[..<doctype.upperBound]) + policy + assets + String(child[doctype.upperBound...])
        } else {
            payload = policy + assets + child
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

    private static func supports(_ url: URL) -> Bool {
        InteractiveDocument.supports(url)
    }

    // The outer and inner documents both need inline styles and scripts. The child inherits the outer policy,
    // then forbids frames as well. No local resources, workers, forms, or network connections are allowed.
    private static let restricted = """
    default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval'; style-src 'unsafe-inline';     img-src data: blob:; font-src data:; media-src data: blob:; connect-src 'none'; object-src 'none';     worker-src 'none'; form-action 'none'; base-uri 'none'
    """
}

private struct PreviewRequest: Equatable {
    let document: InteractiveDocument
    let theme: CardStyleKit.Theme
}

extension CardStyleKit.Theme {
    @MainActor
    static func current(dark: Bool) -> Self {
        let look = Clio.Theme.shared
        let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        let color = UIColor(Ink.accent).resolvedColor(with: traits)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        var snapshot = Self(scheme: dark ? "dark" : "light", palette: look.key, oled: look.oled, white: look.white)
        if color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            let rgb = [red, green, blue].map { Int((min(1, max(0, $0)) * 255).rounded()) }
            snapshot.accent = String(format: "#%02x%02x%02x", rgb[0], rgb[1], rgb[2])
        }
        return snapshot
    }
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

    init(_ preview: PreparedPreview, rules: WKContentRuleList, frame: CGRect = .zero, muted: Bool = false) {
        self.preview = preview
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.ignoresViewportScaleLimits = true
        if muted {
            configuration.mediaTypesRequiringUserActionForPlayback = .all
        }
        configuration.userContentController.add(rules)
        // WebRTC transports are separate from HTTP loading. Remove their entry points in every frame.
        var script = """
        for (const key of ['RTCPeerConnection', 'webkitRTCPeerConnection', 'mozRTCPeerConnection',
                           'RTCIceGatherer', 'RTCIceTransport', 'WebTransport']) {
            if (key in globalThis) {
                try { Object.defineProperty(globalThis, key, {value: undefined, configurable: false, writable: false}); } catch (_) {}
            }
        }
        """
        if muted {
            script += """
            \nfor (const key of ['AudioContext', 'webkitAudioContext', 'OfflineAudioContext', 'speechSynthesis']) {
                try {
                    if (key === 'speechSynthesis' && globalThis.speechSynthesis) {
                        globalThis.speechSynthesis.speak = function() {};
                        globalThis.speechSynthesis.cancel = function() {};
                    }
                    Object.defineProperty(globalThis, key, {value: undefined, configurable: false, writable: false});
                } catch (_) {}
            }
            if (typeof HTMLMediaElement !== 'undefined') {
                try { HTMLMediaElement.prototype.play = function() { return Promise.reject(); }; } catch (_) {}
            }
            """
        }
        configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
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
        _ = NotificationCenter.default.addObserver(forName: MountedFolders.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cache.removeAllObjects() }
        }
    }

    static func cacheKey(revision: String, theme: CardStyleKit.Theme) -> String {
        "\(CardStyleKit.kitVersion)|\(theme.signature)|\(revision)"
    }

    func image(for document: InteractiveDocument, theme: CardStyleKit.Theme? = nil) async -> UIImage? {
        if let mount = document.mount, !MountedFolders.isCurrent(mount) { return nil }
        let theme = theme ?? .current(dark: UITraitCollection.current.userInterfaceStyle == .dark)
        let startRevision = MountedFolders.revision
        let revision = await Task.detached(priority: .utility) { document.fileInfo?.revision }.value
        guard !Task.isCancelled, let revision else { return nil }
        if let mount = document.mount, startRevision != MountedFolders.revision || !MountedFolders.isCurrent(mount) { return nil }
        let key = Self.cacheKey(revision: revision, theme: theme) as NSString
        if let image = cache.object(forKey: key) { return image }

        let previous = tail
        let id = UUID()
        let job = Task { [weak self] () -> UIImage? in
            _ = await previous?.value
            guard let self, !Task.isCancelled else { return nil }
            if let mount = document.mount, startRevision != MountedFolders.revision || !MountedFolders.isCurrent(mount) { return nil }
            if let image = self.cache.object(forKey: key) { return image }
            guard let image = await self.render(document, theme: theme) else { return nil }
            if let mount = document.mount, startRevision != MountedFolders.revision || !MountedFolders.isCurrent(mount) { return nil }
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

    private func render(_ document: InteractiveDocument, theme: CardStyleKit.Theme) async -> UIImage? {
        let prepared = await Task.detached(priority: .utility) { PreparedPreview.make(document, theme: theme) }.value
        guard let prepared, !Task.isCancelled, let rules = await PreviewRules.get(), !Task.isCancelled else { return nil }
        let frame = CGRect(x: 0, y: 0, width: 440, height: 264)
        let web = OfflineWebPreview(prepared, rules: rules, frame: frame, muted: true)
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
    @State private var scope: MountedFolders.ScopeToken?

    private var shareTarget: URL? {
        if document.mount != nil, scope == nil { return nil }
        return document.shareURL
    }

    var body: some View {
        NavigationStack {
            InteractivePreviewContent(document: document)
                .background(Ink.paper.ignoresSafeArea())
                .navigationTitle(document.url.lastPathComponent)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if let url = shareTarget {
                            ShareLink(item: url) { Label(L.t("actions.share"), systemImage: "square.and.arrow.up") }
                        }
                        Button(L.t("actions.done")) { dismiss() }
                    }
                }
        }
        .onAppear {
            if let mount = document.mount {
                scope = MountedFolders.openForUI(mount)?.token
            }
        }
        .onDisappear {
            scope?.stop()
            scope = nil
        }
    }
}

struct InteractivePreviewThumbnail: View {
    let document: InteractiveDocument
    @State private var image: UIImage?
    @Environment(\.colorScheme) private var scheme

    private var mountValid: Bool {
        document.mount.map(MountedFolders.isCurrent) ?? true
    }

    var body: some View {
        let theme = CardStyleKit.Theme.current(dark: scheme == .dark)
        Ink.paperRaised
            .aspectRatio(5.0 / 3.0, contentMode: .fit)
            .overlay {
                if mountValid, let image {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.system(size: Ink.Size.title))
                        .foregroundStyle(Ink.inkFaint)
                }
            }
            .clipShape(.rect(cornerRadius: Ink.Radius.small, style: .continuous))
            .accessibilityHidden(true)
            .task(id: PreviewRequest(document: document, theme: theme)) {
                image = nil
                guard mountValid else { image = nil; return }
                let preview = await InteractiveThumbnails.shared.image(for: document, theme: theme)
                if !Task.isCancelled { image = mountValid ? preview : nil }
            }
            .onReceive(NotificationCenter.default.publisher(for: MountedFolders.changed)) { _ in
                if !mountValid { image = nil }
            }
    }
}

struct InteractivePreviewContent: View {
    let document: InteractiveDocument
    @Environment(\.colorScheme) private var scheme
    @State private var web: OfflineWebPreview?
    @State private var ready = false
    @State private var failed = false

    var body: some View {
        let theme = CardStyleKit.Theme.current(dark: scheme == .dark)
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
        .task(id: PreviewRequest(document: document, theme: theme)) {
            web?.stop()
            web = nil
            ready = false
            failed = false
            let prepared = await Task.detached(priority: .userInitiated) { PreparedPreview.make(document, theme: theme) }.value
            let rules = await PreviewRules.get()
            guard !Task.isCancelled else { return }
            guard let prepared, let rules else { failed = true; return }
            web?.stop()
            let page = OfflineWebPreview(prepared, rules: rules)
            web = page
            let loaded = await page.load()
            guard !Task.isCancelled else { page.stop(); return }
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
