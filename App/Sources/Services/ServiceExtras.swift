import Foundation

enum ServiceCacheTier: String, CaseIterable, Codable, Sendable {
    case off
    case fiveMinutes = "5m"
    case oneHour = "1h"
}

enum ServiceExtras {
    private static let blocked = Set([
        "authorization", "proxy-authorization", "x-api-key", "api-key",
        "cookie", "set-cookie", "x-auth-token", "host", "content-length",
        "transfer-encoding", "connection", "upgrade", "te", "trailer", "expect",
    ])
    private static let secretWords = ["secret", "token", "key", "password", "credential"]
    private static let nameBytes = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+-.^_\u{60}|~".utf8)

    static func pauseKey(_ id: String) -> String { "clio.endpoint.paused.\(id)" }

    static func isPaused(_ id: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: pauseKey(id))
    }

    static func setPaused(_ paused: Bool, for id: String, defaults: UserDefaults = .standard) {
        defaults.set(paused, forKey: pauseKey(id))
    }

    static func cacheTier(_ id: String, fallback: ServiceCacheTier = .off, defaults: UserDefaults = .standard) -> ServiceCacheTier {
        defaults.string(forKey: "clio.endpoint.cacheTier.\(id)")
            .flatMap(ServiceCacheTier.init(rawValue:)) ?? fallback
    }

    static func setCacheTier(_ tier: ServiceCacheTier, for id: String, defaults: UserDefaults = .standard) {
        defaults.set(tier.rawValue, forKey: "clio.endpoint.cacheTier.\(id)")
    }

    static func permitsHeader(_ name: String, value: String) -> Bool {
        let lower = name.lowercased()
        guard !name.isEmpty, name.utf8.allSatisfy(nameBytes.contains),
              !blocked.contains(lower), !secretWords.contains(where: { lower.contains($0) }),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return false }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let lowerValue = trimmed.lowercased()
        return !["bearer ", "basic ", "sk-", "ghp_", "github_pat_", "eyj"].contains(where: { lowerValue.hasPrefix($0) })
    }

    static func sanitizedHeaders(_ headers: [String: String]) -> [String: String] {
        var seen = Set<String>()
        var clean: [String: String] = [:]
        for name in headers.keys.sorted() {
            guard let value = headers[name], permitsHeader(name, value: value),
                  seen.insert(name.lowercased()).inserted else { continue }
            clean[name] = value
        }
        return clean
    }

    static func customHeaders(_ id: String, defaults: UserDefaults = .standard) -> [String: String] {
        guard let data = defaults.data(forKey: "clio.endpoint.customHeaders.\(id)"),
              let headers = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return sanitizedHeaders(headers)
    }

    static func setCustomHeaders(_ headers: [String: String], for id: String, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(sanitizedHeaders(headers)) else { return }
        defaults.set(data, forKey: "clio.endpoint.customHeaders.\(id)")
    }
}

@MainActor
enum RecentModelsStore {
    private static let key = "clio.models.recent"

    static func record(_ ref: String, in team: TeamModel? = nil, defaults: UserDefaults = .standard) {
        guard let slash = ref.firstIndex(of: "/"), slash != ref.startIndex,
              ref.index(after: slash) != ref.endIndex else { return }
        let candidates: [String]
        if let team {
            let endpoints = team.settings.endpoints
            guard isActive(ref, in: endpoints, defaults: defaults) else { return }
            candidates = recent(in: endpoints, defaults: defaults)
        } else {
            candidates = stored(in: defaults)
        }
        let previous = candidates.filter { $0 != ref }
        guard let data = try? JSONEncoder().encode(Array(([ref] + previous).prefix(3))) else { return }
        defaults.set(data, forKey: key)
    }

    static func recent(in team: TeamModel, defaults: UserDefaults = .standard) -> [String] {
        recent(in: team.settings.endpoints, defaults: defaults)
    }

    static func recent(in endpoints: [Endpoint], defaults: UserDefaults = .standard) -> [String] {
        stored(in: defaults).filter { ref in
            isActive(ref, in: endpoints, defaults: defaults)
        }
    }

    private static func isActive(_ ref: String, in endpoints: [Endpoint], defaults: UserDefaults) -> Bool {
        guard let resolved = TeamModel.resolveActive(ref, in: endpoints) else { return false }
        return !ServiceExtras.isPaused(resolved.endpoint.id, defaults: defaults)
    }

    private static func stored(in defaults: UserDefaults) -> [String] {
        guard let data = defaults.data(forKey: key),
              let refs = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        var seen = Set<String>()
        return Array(refs.lazy.filter { seen.insert($0).inserted }.prefix(3))
    }
}
