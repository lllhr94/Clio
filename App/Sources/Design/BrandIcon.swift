import SwiftUI
import UIKit

/// A service's own icon, fetched from the service (or a public favicon service) when first shown and kept in the
/// phone's cache. Nothing is bundled in the app or the repository. Until it arrives, or if it can't, a tile with
/// the first letter stands in.
struct BrandIcon: View {
    let domain: String?
    let mark: String
    let tint: Color
    var size: CGFloat = 44

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                RoundedRectangle(cornerRadius: Kit.iconCorner(size), style: .continuous)
                    .fill(Color.white)
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(size * 0.16)
            } else {
                RoundedRectangle(cornerRadius: Kit.iconCorner(size), style: .continuous)
                    .fill(tint.gradient)
                Text(mark).font(.system(size: size * 0.44, weight: .bold, design: .rounded)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .overlay(RoundedRectangle(cornerRadius: Kit.iconCorner(size), style: .continuous).strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
        .task(id: domain) {
            guard let domain else { return }
            image = await BrandIcons.shared.icon(for: domain)
        }
    }
}

/// Where service icons come from, and their cache (memory, then the Caches folder).
actor BrandIcons {
    static let shared = BrandIcons()
    private var memory: [String: UIImage] = [:]
    private var misses: Set<String> = []

    private var folder: URL {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("brand-icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func icon(for domain: String) async -> UIImage? {
        if let hit = memory[domain] { return hit }
        if misses.contains(domain) { return nil }
        let file = folder.appendingPathComponent(domain.replacingOccurrences(of: "/", with: "_") + ".png")
        if let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
            memory[domain] = image
            return image
        }
        // The service's own icons first: what its home page links to, then the usual places. Then favicon services,
        // the ones reachable from China before the ones that are not.
        var sources = await linked(on: domain)
        sources += [
            "https://\(domain)/apple-touch-icon.png",
            "https://\(domain)/apple-touch-icon-precomposed.png",
            "https://\(domain)/favicon.ico",
            "https://favicon.im/\(domain)?larger=true",
            "https://api.iowen.cn/favicon/\(domain).png",
            "https://www.google.com/s2/favicons?domain=\(domain)&sz=128",
            "https://icons.duckduckgo.com/ip3/\(domain).ico",
        ]
        for source in sources {
            guard let url = URL(string: source), let image = await fetch(url) else { continue }
            try? image.pngData()?.write(to: file, options: .atomic)
            memory[domain] = image
            return image
        }
        misses.insert(domain)
        return nil
    }

    private func fetch(_ url: URL) async -> UIImage? {
        var request = URLRequest(url: url, timeoutInterval: 6)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let image = UIImage(data: data), image.size.width >= 32 else { return nil }
        return image
    }

    /// The icons a site's home page points to (`apple-touch-icon`, `icon`), largest first.
    private func linked(on domain: String) async -> [String] {
        guard let home = URL(string: "https://\(domain)/") else { return [] }
        var request = URLRequest(url: home, timeoutInterval: 6)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let html = String(data: data.prefix(200_000), encoding: .utf8) ?? String(data: data.prefix(200_000), encoding: .ascii) else { return [] }
        let base = response.url ?? home
        var found: [(String, Int)] = []
        let tags = html.components(separatedBy: "<link").dropFirst().map { piece in piece.prefix { char in char != ">" } }
        for tag in tags {
            let lower = tag.lowercased()
            guard let rel = Self.attribute("rel", in: tag)?.lowercased(), rel.contains("icon"), !rel.contains("mask"),
                  let href = Self.attribute("href", in: tag), !href.hasPrefix("data:"),
                  let url = URL(string: href, relativeTo: base)?.absoluteURL else { continue }
            if lower.contains(".svg") { continue }
            let size = Self.attribute("sizes", in: tag).flatMap { Int($0.split(separator: "x").first ?? "") } ?? (rel.contains("apple") ? 180 : 32)
            found.append((url.absoluteString, size))
        }
        return found.sorted { $0.1 > $1.1 }.map(\.0)
    }

    private static func attribute(_ name: String, in tag: Substring) -> String? {
        for quote in ["\"", "'"] {
            let key = name + "=" + quote
            guard let start = tag.range(of: key, options: .caseInsensitive) else { continue }
            let rest = tag[start.upperBound...]
            guard let end = rest.firstIndex(of: Character(quote)) else { continue }
            return String(rest[..<end])
        }
        return nil
    }
}

/// A model service's icon: the maker's own, or a plain symbol for 自定义 and a computer on the network.
/// A service Clio does not know (a relay you added yourself) shows the first letter of the name you gave it;
/// with no name either, a chip.
struct ServiceIcon: View {
    let service: Service?
    var size: CGFloat = 38
    /// The endpoint's own name, for a service not in the catalog.
    var name: String? = nil

    var body: some View {
        if let symbol = service?.symbol {
            plain(symbol)
        } else if let service {
            BrandIcon(domain: service.domain, mark: String(service.name.first ?? "C"), tint: Ink.Tile.accent, size: size)
        } else if let first = name?.trimmingCharacters(in: .whitespaces).first {
            BrandIcon(domain: nil, mark: String(first).uppercased(), tint: Ink.Tile.accent, size: size)
        } else {
            plain("cpu")
        }
    }

    private func plain(_ symbol: String) -> some View {
        RoundedRectangle(cornerRadius: Kit.iconCorner(size), style: .continuous)
            .fill(Ink.mine)
            .frame(width: size, height: size)
            .overlay { Image(systemName: symbol).font(.system(size: size * 0.44, weight: .medium)).foregroundStyle(Ink.inkSoft) }
    }
}
