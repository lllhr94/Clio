import AgentKit
import Foundation

/// Validation and canonical origin helpers for model service base URLs.
public enum EndpointAddressPolicy {
    /// Validates and normalizes an endpoint address:
    /// - public hosts require `https://`
    /// - loopback / LAN hosts (`LocalAddress.isLocal`) may use `http://` or `https://`
    /// - rejects empty strings, embedded whitespace, or embedded userinfo credentials.
    public static func normalize(_ raw: String) -> String? {
        var clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while clean.count > 8 && clean.hasSuffix("/") { clean.removeLast() }
        guard !clean.isEmpty,
              clean.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let url = URL(string: clean),
              let scheme = url.scheme?.lowercased(),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else {
            return nil
        }
        if scheme == "https" { return clean }
        if scheme == "http" && LocalAddress.isLocal(url) { return clean }
        return nil
    }

    /// Canonical `scheme://host:effectivePort` origin for a validated endpoint URL.
    public static func origin(_ raw: String) -> String? {
        guard let normalized = normalize(raw) else { return nil }
        return rawOrigin(normalized)
    }

    /// Canonical `scheme://host:effectivePort` for any syntactically valid HTTP(S) URL
    /// (used for read-time origin checks so legacy saved endpoints still parse).
    public static func rawOrigin(_ raw: String) -> String? {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty,
              let url = URL(string: clean),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        let defaultPort = (scheme == "https") ? 443 : 80
        let effectivePort = url.port ?? defaultPort
        let formattedHost = host.contains(":") ? "[\(host)]" : host
        return "\(scheme)://\(formattedHost):\(effectivePort)"
    }

    public static func isSameOrigin(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = rawOrigin(lhs), let right = rawOrigin(rhs) else { return false }
        return left == right
    }
}

public enum EndpointKeyEditOutcome: Equatable, Sendable {
    case saved(normalizedURL: String, keyUpdated: Bool)
    case invalidAddress
    case keyRequiredForNewHost
    case keySaveFailed
    case settingsSaveFailed
}

/// Coordinates origin-bound API key updates when editing an existing model service.
/// Prevents an existing service's API key from being reused across a different host/origin,
/// verifies storage writability before mutating state, and clears the old key before committing
/// a new host so a crash or key write failure can never send the old key to the new host.
public enum EndpointKeyCoordinator {
    public struct Store {
        public var readKey: (String) -> String?
        public var writeKey: (String, String) -> Bool
        public var removeKey: (String) -> Void
        public var readBoundOrigin: (String) -> String?
        public var writeBoundOrigin: (String, String?) -> Void
        public var commitSettings: (String) -> Bool

        public init(
            readKey: @escaping (String) -> String?,
            writeKey: @escaping (String, String) -> Bool,
            removeKey: @escaping (String) -> Void,
            readBoundOrigin: @escaping (String) -> String?,
            writeBoundOrigin: @escaping (String, String?) -> Void,
            commitSettings: @escaping (String) -> Bool
        ) {
            self.readKey = readKey
            self.writeKey = writeKey
            self.removeKey = removeKey
            self.readBoundOrigin = readBoundOrigin
            self.writeBoundOrigin = writeBoundOrigin
            self.commitSettings = commitSettings
        }
    }

    public static func keySlot(for endpointID: String) -> String { "key-\(endpointID)" }
    public static func stagingSlot(for endpointID: String) -> String { "key-\(endpointID).pending" }

    /// Reads an endpoint's API key only if its recorded origin matches `baseURL`'s origin
    /// (or if no origin was recorded yet for a legacy endpoint).
    public static func resolveBoundKey(
        endpointID: String,
        baseURL: String,
        readKey: (String) -> String?,
        readBoundOrigin: (String) -> String?
    ) -> String? {
        guard let currentOrigin = EndpointAddressPolicy.rawOrigin(baseURL) else { return nil }
        if let bound = readBoundOrigin(endpointID), bound != currentOrigin {
            return nil
        }
        guard let key = readKey(keySlot(for: endpointID)), !key.isEmpty else { return nil }
        return key
    }

    public static func applyEdit(
        endpointID: String,
        currentBaseURL: String,
        newBaseURL: String,
        replacementKey: String?,
        allowKeylessLocalReuse: Bool = false,
        store: Store
    ) -> EndpointKeyEditOutcome {
        guard let normalized = EndpointAddressPolicy.normalize(newBaseURL),
              let newOrigin = EndpointAddressPolicy.origin(normalized) else {
            return .invalidAddress
        }

        let oldOrigin = EndpointAddressPolicy.rawOrigin(currentBaseURL)
        let sameOrigin = (oldOrigin != nil && oldOrigin == newOrigin)
        let trimmedKey = replacementKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextKey: String? = (trimmedKey?.isEmpty == false) ? trimmedKey : nil

        let slot = keySlot(for: endpointID)
        let staging = stagingSlot(for: endpointID)
        let oldKey = store.readKey(slot)

        // Cross-origin change without a new key: block reuse of an existing secret key.
        if !sameOrigin && nextKey == nil {
            let hasExistingKey = (oldKey?.isEmpty == false)
            let isLocalTarget = URL(string: normalized).map(LocalAddress.isLocal) ?? false
            let isKeylessPlaceholder = allowKeylessLocalReuse
                && isLocalTarget
                && (oldKey == nil || oldKey == "" || oldKey == "local")
            if hasExistingKey && !isKeylessPlaceholder {
                return .keyRequiredForNewHost
            }
            guard store.commitSettings(normalized) else {
                return .settingsSaveFailed
            }
            store.writeBoundOrigin(endpointID, newOrigin)
            return .saved(normalizedURL: normalized, keyUpdated: false)
        }

        // Same-origin edit (path/name/style adjustment, with optional key replacement).
        if sameOrigin {
            if let nextKey {
                guard store.writeKey(staging, nextKey) else {
                    store.removeKey(staging)
                    return .keySaveFailed
                }
                guard store.commitSettings(normalized) else {
                    store.removeKey(staging)
                    return .settingsSaveFailed
                }
                guard store.writeKey(slot, nextKey) else {
                    store.removeKey(staging)
                    _ = store.commitSettings(currentBaseURL)
                    return .keySaveFailed
                }
                store.removeKey(staging)
                store.writeBoundOrigin(endpointID, newOrigin)
                return .saved(normalizedURL: normalized, keyUpdated: true)
            }
            guard store.commitSettings(normalized) else {
                return .settingsSaveFailed
            }
            if oldKey?.isEmpty == false, store.readBoundOrigin(endpointID) == nil {
                store.writeBoundOrigin(endpointID, newOrigin)
            }
            return .saved(normalizedURL: normalized, keyUpdated: false)
        }

        // Cross-origin migration with an explicit replacement key:
        // 1) Pre-verify key storage can write to a staging slot before changing anything.
        // 2) Bind origin to `newOrigin` and remove the old key BEFORE writing the new URL so neither
        //    a crash nor a final key-write failure can ever pair `oldKey` with `newOrigin`.
        // 3) Commit settings with `normalized`; roll back if settings persistence fails.
        // 4) Write `nextKey` into `slot`; on failure leave `slot` cleared (and roll back settings if possible).
        guard let nextKey else { return .keyRequiredForNewHost }
        guard store.writeKey(staging, nextKey) else {
            store.removeKey(staging)
            return .keySaveFailed
        }

        store.writeBoundOrigin(endpointID, newOrigin)
        store.removeKey(slot)

        guard store.commitSettings(normalized) else {
            store.writeBoundOrigin(endpointID, oldOrigin)
            if let oldKey, !oldKey.isEmpty {
                if !store.writeKey(slot, oldKey) {
                    store.removeKey(slot)
                }
            }
            store.removeKey(staging)
            return .settingsSaveFailed
        }

        guard store.writeKey(slot, nextKey) else {
            // Never leave an old key attached to the new host.
            store.removeKey(slot)
            store.removeKey(staging)
            if store.commitSettings(currentBaseURL) {
                store.writeBoundOrigin(endpointID, oldOrigin)
                if let oldKey, !oldKey.isEmpty {
                    if !store.writeKey(slot, oldKey) {
                        store.removeKey(slot)
                    }
                }
            }
            return .keySaveFailed
        }

        store.removeKey(staging)
        return .saved(normalizedURL: normalized, keyUpdated: true)
    }
}
