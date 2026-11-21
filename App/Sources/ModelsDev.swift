import Craft
import Foundation

/// What models can do, from models.dev: an open catalog (MIT) of thousands of models from every service, with
/// whether each takes pictures, calls tools and thinks, and its context window. Open Minis reads the same catalog.
/// Fetched at most once a day and kept on the phone; Clio's guess from the name is only the fallback.
///
/// Matching follows Open Minis' rules, written anew: relay prefixes are dropped (「openai/gpt-5」「cn:deepseek-v4-pro」),
/// dates and version tags at the end are tried away, and when one model is listed by several services their
/// answers are folded together (the larger window, any of them saying it can).
enum ModelsDev {
    struct Entry: Codable, Equatable {
        var sees: Bool
        var tools: Bool
        var thinks: Bool
        var window: Int
    }

    private static let source = URL(string: "https://models.dev/api.json")!
    private static var file: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("models-dev.json")
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var index: [String: Entry]? = nil

    /// What the catalog says about `model`, or nil when it does not know it.
    static func lookup(_ model: String) -> Entry? {
        let table = loaded()
        guard !table.isEmpty else { return nil }
        for name in candidates(model) {
            if let entry = table[name] { return entry }
        }
        return nil
    }

    /// The names to try, most exact first: the id itself, without a relay's prefix, then with trailing dates,
    /// 「-latest」「-preview」 and similar tags taken off one by one.
    static func candidates(_ model: String) -> [String] {
        var name = model.lowercased().trimmingCharacters(in: .whitespaces)
        var out: [String] = [name]
        if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]); out.append(name) }
        if let colon = name.lastIndex(of: ":") { name = String(name[name.index(after: colon)...]); out.append(name) }
        var parts = name.split(separator: "-").map(String.init)
        while parts.count > 1 {
            let last = parts.removeLast()
            let tag = last.allSatisfy(\.isNumber) || ["latest", "preview", "exp", "beta", "free", "online", "chat"].contains(last)
            guard tag else { break }
            out.append(parts.joined(separator: "-"))
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    private static func loaded() -> [String: Entry] {
        lock.lock()
        defer { lock.unlock() }
        if let index { return index }
        let kept = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
        index = kept
        return kept
    }

    /// Fetches the catalog again if what is kept is older than a day. Quiet on failure: the guess stays.
    static func refreshIfStale() async {
        let age = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { Date().timeIntervalSince($0) }
        if let age, age < 24 * 3600 { return }
        await refresh()
    }

    static func refresh() async {
        do {
            var request = URLRequest(url: source)
            request.timeoutInterval = 30
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            let table = try parse(data)
            guard table.count > 100 else { return }
            try JSONEncoder().encode(table).write(to: file, options: .atomic)
            lock.lock()
            index = table
            lock.unlock()
        } catch {
            Diag.note("模型资料库没取到：\(error.localizedDescription)")
        }
    }

    /// `{ service: { models: { id: { reasoning, tool_call, attachment, modalities: { input }, limit: { context } } } } }`
    static func parse(_ data: Data) throws -> [String: Entry] {
        guard let services = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var table: [String: Entry] = [:]
        for case let service as [String: Any] in services.values {
            guard let models = service["models"] as? [String: Any] else { continue }
            for (id, value) in models {
                guard let model = value as? [String: Any] else { continue }
                let inputs = (model["modalities"] as? [String: Any])?["input"] as? [String] ?? []
                let window = ((model["limit"] as? [String: Any])?["context"] as? NSNumber)?.intValue ?? 0
                let entry = Entry(sees: inputs.contains("image") || (model["attachment"] as? Bool ?? false) && inputs.isEmpty,
                                  tools: model["tool_call"] as? Bool ?? true,
                                  thinks: model["reasoning"] as? Bool ?? false,
                                  window: window)
                // Every name it goes by: the id as listed, and without a service's prefix.
                for name in Set([id.lowercased(), String(id.lowercased().split(separator: "/").last ?? "")]) where !name.isEmpty {
                    if let known = table[name] {
                        table[name] = Entry(sees: known.sees || entry.sees, tools: known.tools || entry.tools,
                                            thinks: known.thinks || entry.thinks, window: max(known.window, entry.window))
                    } else {
                        table[name] = entry
                    }
                }
            }
        }
        return table
    }
}

extension ModelTraits {
    /// What a model can do, best source first: the catalog, else the guess from the name.
    static func known(_ model: String) -> ModelTraits {
        var traits = ModelTraits.guess(model)
        if let entry = ModelsDev.lookup(model) {
            traits.sees = entry.sees
            traits.tools = entry.tools
            traits.thinks = entry.thinks
            if entry.window > 0 { traits.window = entry.window }
        }
        return traits
    }
}
