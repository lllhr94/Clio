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
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .fill(Color.white)
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(size * 0.16)
            } else {
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .fill(tint.gradient)
                Text(mark).font(.system(size: size * 0.44, weight: .bold, design: .rounded)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .overlay(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
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
        // The service's own touch icon first (sharp, and reachable wherever the service is), then a favicon service.
        let sources = [
            "https://\(domain)/apple-touch-icon.png",
            "https://www.google.com/s2/favicons?domain=\(domain)&sz=128",
            "https://icons.duckduckgo.com/ip3/\(domain).ico",
        ]
        for source in sources {
            guard let url = URL(string: source) else { continue }
            var request = URLRequest(url: url, timeoutInterval: 8)
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = UIImage(data: data), image.size.width >= 32 else { continue }
            try? image.pngData()?.write(to: file, options: .atomic)
            memory[domain] = image
            return image
        }
        misses.insert(domain)
        return nil
    }
}

/// A model service's icon: the maker's own, or a plain symbol for 自定义 and a computer on the network.
struct ServiceIcon: View {
    let service: Service?
    var size: CGFloat = 38

    var body: some View {
        if let symbol = service?.symbol {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(Ink.mine)
                .frame(width: size, height: size)
                .overlay { Image(systemName: symbol).font(.system(size: size * 0.44, weight: .medium)).foregroundStyle(Ink.inkSoft) }
        } else {
            BrandIcon(domain: service?.domain, mark: String(service?.name.first ?? "?"), tint: Ink.accent, size: size)
        }
    }
}
