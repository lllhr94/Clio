import AVFoundation
import AgentKit
import CoreLocation
import Craft
import PhotosUI
import Observation
import SwiftUI
import UniformTypeIdentifiers
import VisionKit

/// 出处: the pages behind an answer, as small cards with the site's name; a tap opens the page in 远游.
struct SourcesRow: View {
    let urls: [URL]
    /// What the answer called each page, where it linked one: 「中国天气网」 rather than 「weather.com.cn」.
    var titles: [URL: String] = [:]
    let open: (URL) -> Void
    @State private var listing = false

    /// One per site, in the order they were read.
    private var sites: [URL] {
        var seen: Set<String> = []
        return urls.filter { seen.insert(Self.site($0)).inserted }
    }

    var body: some View {
        // Folded like other agents do it: the sites' icons overlapping, and how many; the list opens on a tap.
        Button {
            Haptics.light()
            listing = true
        } label: {
            let iconSize = 16 * UIScale.factor
            HStack(spacing: Ink.Space.s) {
                HStack(spacing: -5) {
                    ForEach(Array(sites.prefix(3).enumerated()), id: \.offset) { index, url in
                        BrandIcon(domain: Self.site(url), mark: String(Self.site(url).first ?? "?").uppercased(), tint: Ink.inkSoft, size: iconSize)
                            .saturation(0.82)
                            .clipShape(Circle())
                            .overlay(Circle().strokeBorder(Ink.paperRaised, lineWidth: 1.5))
                            .zIndex(Double(10 - index))
                    }
                }
                Text("\(urls.count) 个来源")
                    .font(.system(size: Ink.Size.micro, weight: .medium))
                    .foregroundStyle(Ink.inkSoft)
                Image(systemName: "chevron.right")
                    .font(.system(size: Ink.Size.micro, weight: .semibold))
                    .foregroundStyle(Ink.inkFaint)
                    .scaleEffect(0.8)
            }
            .padding(.leading, 6 * UIScale.factor)
            .padding(.trailing, 10 * UIScale.factor)
            .frame(height: 28 * UIScale.factor)
            .background(Ink.paperRaised, in: .capsule)
            .overlay(Capsule().strokeBorder(Ink.rule.opacity(0.85), lineWidth: 0.5))
        }
        .buttonStyle(PressStyle(haptic: false))
        .accessibilityLabel("\(urls.count) 个来源，点开看")
        .sheet(isPresented: $listing) {
            SourcesSheet(urls: urls, titles: titles) { url in
                listing = false
                open(url)
            }
            .presentationDetents([.medium, .large])
        }
    }

    /// The links written in an answer, 「[名字](网址)」, in order.
    /// Worked out once per reply text: the chat redraws often, and every reply asks on each redraw.
    @MainActor private static var citedCache: [String: [(title: String, url: URL)]] = [:]

    @MainActor static func cited(in text: String) -> [(title: String, url: URL)] {
        if let known = citedCache[text] { return known }
        let found = findCited(in: text)
        if citedCache.count > 400 { citedCache.removeAll() }
        citedCache[text] = found
        return found
    }

    private static func findCited(in text: String) -> [(title: String, url: URL)] {
        var found: [(title: String, url: URL)] = []
        for match in text.matches(of: #/\[([^\]\n]+)\]\((https?://[^)\s]+)\)/#) {
            guard let url = URL(string: String(match.output.2)), url.host != nil, !isSearchPage(url),
                  !found.contains(where: { $0.url == url }) else { continue }
            found.append((String(match.output.1).trimmingCharacters(in: .whitespaces), url))
        }
        return found
    }

    @MainActor static func titles(in text: String) -> [URL: String] {
        Dictionary(cited(in: text).map { ($0.url, $0.title) }, uniquingKeysWith: { first, _ in first })
    }

    /// A search engine's list of results is how the pages were found, not a source.
    static func isSearchPage(_ url: URL) -> Bool {
        let host = site(url), path = url.path()
        let engines = ["bing.com", "cn.bing.com", "google.com", "baidu.com", "sogou.com", "so.com", "duckduckgo.com", "search.yahoo.com"]
        return engines.contains(host) && (path.hasPrefix("/search") || path == "/s" || path == "/web" || path == "/" || path.isEmpty)
    }

    /// 「zhihu.com」 from 「https://www.zhihu.com/question/…」.
    static func site(_ url: URL) -> String {
        var host = url.host() ?? url.absoluteString
        if host.hasPrefix("www.") { host.removeFirst(4) }
        if host.hasPrefix("m.") { host.removeFirst(2) }
        return host
    }
}

/// The sources of a reply, one per row: the site's icon, the page's address, and where it leads.
struct SourcesSheet: View {
    let urls: [URL]
    var titles: [URL: String] = [:]
    let open: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
                        if index > 0 { Kit.divider }
                        Button {
                            Haptics.light()
                            open(url)
                        } label: {
                            HStack(spacing: Ink.Space.m) {
                                BrandIcon(domain: SourcesRow.site(url), mark: String(SourcesRow.site(url).first ?? "?").uppercased(), tint: Ink.inkSoft, size: Kit.badge)
                                VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
                                    // The name the answer gave it, when it gave one; then the site.
                                    Text(titles[url] ?? SourcesRow.site(url)).font(.system(size: Ink.Size.sub, weight: .medium)).foregroundStyle(Ink.ink).lineLimit(1)
                                    Text(titles[url] == nil ? Self.path(url) : SourcesRow.site(url)).font(.system(size: Ink.Size.small)).foregroundStyle(Ink.inkFaint).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.up.right").font(.system(size: Ink.Size.small, weight: .semibold)).foregroundStyle(Ink.inkFaint)
                            }
                            .padding(.horizontal, Ink.Space.l)
                            .padding(.vertical, Ink.Space.m)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressStyle(haptic: false))
                        .contextMenu {
                            Button("复制链接", systemImage: "doc.on.doc") { UIPasteboard.general.string = url.absoluteString }
                            ShareLink(item: url) { Label("分享", systemImage: "square.and.arrow.up") }
                        }
                    }
                }
                .paperCard()
                .padding(Ink.Space.page)
            }
            .background(Ink.paper.ignoresSafeArea())
            .navigationTitle("\(urls.count) 个" + L.t("chat.source"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L.t("actions.done")) { dismiss() } } }
        }
    }

    /// What comes after the site, readable: 「/question/12345」 → 「question/12345」.
    static func path(_ url: URL) -> String {
        let rest = url.path().removingPercentEncoding ?? url.path()
        let trimmed = rest.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.isEmpty ? url.absoluteString : trimmed
    }
}
