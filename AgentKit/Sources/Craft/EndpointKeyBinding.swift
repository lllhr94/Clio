import AgentKit
import CryptoKit
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

/// Single atomic credential record persisted as JSON-encoded `Data`.
/// Stores the bound origin and API key together in one record so reading a credential
/// can never observe a key from one host paired with an origin from another.
/// Uses `"access_token"` so `Vault.allStrings()` redacts the key without treating `"origin"` as secret.
public struct BoundEndpointCredential: Codable, Equatable, Sendable {
    public let origin: String
    public let accessToken: String

    enum CodingKeys: String, CodingKey {
        case origin
        case accessToken = "access_token"
    }

    public init(origin: String, accessToken: String) {
        self.origin = origin
        self.accessToken = accessToken
    }

    public func encodedData() -> Data? {
        try? JSONEncoder().encode(self)
    }

    public static func decode(from data: Data) -> BoundEndpointCredential? {
        try? JSONDecoder().decode(BoundEndpointCredential.self, from: data)
    }
}

public enum EndpointKeyEditOutcome: Equatable, Sendable {
    case saved(endpointID: String, normalizedURL: String, keyUpdated: Bool)
    case invalidAddress
    case keyRequiredForNewHost
    case keySaveFailed
    case settingsSaveFailed
}

/// Coordinates origin-bound single-record credentials for model services.
/// - Same-origin edits keep the endpoint ID and reuse the existing origin-bound credential.
/// - Cross-origin edits mint a new endpoint ID, write and verify independent new credentials first,
///   atomically commit settings to the new ID + URL, and only then clean up old slots.
/// As a result, concurrent background readers, delete failures, and crashes at any point can never
/// pair host A's key with host B or host B's key with host A.
public enum EndpointKeyCoordinator {
    public struct Store {
        public var readBoundRecord: (String) -> Data?
        public var writeBoundRecord: (String, Data) -> Bool
        public var hasBoundMarker: (String) -> Bool
        public var writeBoundMarker: (String) -> Bool
        public var readLegacyKey: (String) -> String?
        public var writeLegacyKey: (String, String) -> Bool
        public var removeKey: (String) -> Void
        public var makeEndpointID: () -> String
        public var commitSettings: (_ targetID: String, _ normalizedURL: String) -> Bool

        public init(
            readBoundRecord: @escaping (String) -> Data?,
            writeBoundRecord: @escaping (String, Data) -> Bool,
            hasBoundMarker: @escaping (String) -> Bool,
            writeBoundMarker: @escaping (String) -> Bool,
            readLegacyKey: @escaping (String) -> String?,
            writeLegacyKey: @escaping (String, String) -> Bool,
            removeKey: @escaping (String) -> Void,
            makeEndpointID: @escaping () -> String = { UUID().uuidString },
            commitSettings: @escaping (_ targetID: String, _ normalizedURL: String) -> Bool
        ) {
            self.readBoundRecord = readBoundRecord
            self.writeBoundRecord = writeBoundRecord
            self.hasBoundMarker = hasBoundMarker
            self.writeBoundMarker = writeBoundMarker
            self.readLegacyKey = readLegacyKey
            self.writeLegacyKey = writeLegacyKey
            self.removeKey = removeKey
            self.makeEndpointID = makeEndpointID
            self.commitSettings = commitSettings
        }
    }

    public static func legacyKeySlot(for endpointID: String) -> String { "key-\(endpointID)" }
    public static func boundMarkerSlot(for endpointID: String) -> String { "bound-\(endpointID)" }

    /// Pure-ASCII slot uniquely scoped to `(endpointID, origin)`.
    public static func boundRecordSlot(for endpointID: String, origin: String) -> String {
        let digest = SHA256.hash(data: Data(origin.utf8))
        let hex = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        return "key-bound-\(endpointID)-\(hex)"
    }

    /// Reads the API key bound to `(endpointID, requestURL)` from its single atomic credential record.
    /// Falls back to the legacy plain-string slot only for pre-upgrade / backup-restored endpoints
    /// that do not yet have a bound marker.
    public static func resolveBoundKey(
        endpointID: String,
        requestURL: String,
        readBoundRecord: (String) -> Data?,
        hasBoundMarker: (String) -> Bool,
        readLegacyKey: (String) -> String?
    ) -> String? {
        guard let requestOrigin = EndpointAddressPolicy.rawOrigin(requestURL) else { return nil }
        let slot = boundRecordSlot(for: endpointID, origin: requestOrigin)
        if let data = readBoundRecord(slot),
           let record = BoundEndpointCredential.decode(from: data) {
            guard record.origin == requestOrigin, !record.accessToken.isEmpty else { return nil }
            return record.accessToken
        }
        guard !hasBoundMarker(boundMarkerSlot(for: endpointID)) else { return nil }
        guard let legacy = readLegacyKey(legacyKeySlot(for: endpointID)), !legacy.isEmpty else { return nil }
        return legacy
    }

    /// Persists an origin-bound credential record together with its bound marker and legacy mirror.
    @discardableResult
    public static func saveBoundCredential(
        endpointID: String,
        origin: String,
        key: String,
        writeBoundRecord: (String, Data) -> Bool,
        writeBoundMarker: (String) -> Bool,
        writeLegacyKey: (String, String) -> Bool,
        removeKey: (String) -> Void
    ) -> Bool {
        let record = BoundEndpointCredential(origin: origin, accessToken: key)
        guard let data = record.encodedData() else { return false }
        let boundSlot = boundRecordSlot(for: endpointID, origin: origin)
        let markerSlot = boundMarkerSlot(for: endpointID)
        let legacySlot = legacyKeySlot(for: endpointID)

        guard writeBoundRecord(boundSlot, data),
              writeBoundMarker(markerSlot),
              writeLegacyKey(legacySlot, key) else {
            removeKey(boundSlot)
            removeKey(legacySlot)
            return false
        }
        return true
    }

    /// Best-effort cleanup of an endpoint's credential slots. Keeps the bound marker in place if
    /// removing the legacy slot fails so an undeleted legacy key cannot bypass origin binding.
    public static func cleanupCredentials(
        endpointID: String,
        origin: String?,
        readLegacyKey: (String) -> String?,
        removeKey: (String) -> Void
    ) {
        if let origin {
            removeKey(boundRecordSlot(for: endpointID, origin: origin))
        }
        let legacySlot = legacyKeySlot(for: endpointID)
        removeKey(legacySlot)
        if readLegacyKey(legacySlot) == nil {
            removeKey(boundMarkerSlot(for: endpointID))
        }
    }

    /// Minimal endpoint metadata needed to bind credentials during backup export and restore.
    public struct EndpointSnapshot: Equatable, Sendable {
        public let id: String
        public let baseURL: String

        public init(id: String, baseURL: String) {
            self.id = id
            self.baseURL = baseURL
        }
    }

    /// Exports API keys for backup while keeping `#keys` format (`[endpointID: apiKey]`) unchanged.
    /// Reads each endpoint's key bound to its actual `baseURL`, never exporting mismatched or orphaned keys.
    public static func exportBackupKeys(
        endpoints: [EndpointSnapshot],
        allowedIDs: Set<String>? = nil,
        readBoundRecord: (String) -> Data?,
        hasBoundMarker: (String) -> Bool,
        readLegacyKey: (String) -> String?
    ) -> [String: String] {
        var exported: [String: String] = [:]
        for endpoint in endpoints {
            if let allowedIDs, !allowedIDs.contains(endpoint.id) { continue }
            if let key = resolveBoundKey(
                endpointID: endpoint.id,
                requestURL: endpoint.baseURL,
                readBoundRecord: readBoundRecord,
                hasBoundMarker: hasBoundMarker,
                readLegacyKey: readLegacyKey
            ), !key.isEmpty {
                exported[endpoint.id] = key
            }
        }
        return exported
    }

    /// Reconciles origin-bound credentials after a backup's `settings.json` has been swapped onto disk.
    /// - When `#keys` supplies a key for a restored endpoint, imports it as an origin-bound credential
    ///   for the restored endpoint's `baseURL` (updating bound record, marker, and legacy mirror together)
    ///   and cleans up any prior different-origin bound slot for the same ID.
    /// - When `#keys` is absent or omits a restored endpoint:
    ///   - If the same endpoint ID previously had the same origin on this device, preserves that credential
    ///     (opportunistically upgrading an unbound legacy key into a bound record).
    ///   - If the restored endpoint's origin differs from the previous endpoint on this device (or was not
    ///     present on this device), sets the bound marker and clears legacy/old-origin slots so an existing
    ///     key for another host can never be sent to the restored host.
    /// - For previous endpoints removed by the restore, opportunistically binds any pre-upgrade legacy key
    ///   to its previous origin so a later keyless restore cannot attach it to a different host.
    public static func applyBackupRestore(
        previousEndpoints: [EndpointSnapshot],
        restoredEndpoints: [EndpointSnapshot],
        restoredKeys: [String: String]?,
        writeBoundRecord: (String, Data) -> Bool,
        hasBoundMarker: (String) -> Bool,
        writeBoundMarker: (String) -> Bool,
        readLegacyKey: (String) -> String?,
        writeLegacyKey: (String, String) -> Bool,
        removeKey: (String) -> Void
    ) {
        var previousOriginByID: [String: String] = [:]
        for previous in previousEndpoints {
            if let origin = EndpointAddressPolicy.rawOrigin(previous.baseURL) {
                previousOriginByID[previous.id] = origin
            }
        }
        let restoredIDs = Set(restoredEndpoints.map(\.id))

        for endpoint in restoredEndpoints {
            let id = endpoint.id
            let restoredOrigin = EndpointAddressPolicy.rawOrigin(endpoint.baseURL)
            let previousOrigin = previousOriginByID[id]
            let markerSlot = boundMarkerSlot(for: id)
            let legacySlot = legacyKeySlot(for: id)
            let rawProvided = restoredKeys?[id]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let providedKey: String? = (rawProvided?.isEmpty == false) ? rawProvided : nil

            if let providedKey {
                // Remove any credential bound to a different previous origin before writing the restored origin.
                if let previousOrigin, previousOrigin != restoredOrigin {
                    _ = writeBoundMarker(markerSlot)
                    removeKey(boundRecordSlot(for: id, origin: previousOrigin))
                    removeKey(legacySlot)
                }
                guard let restoredOrigin else {
                    // Restored endpoint has no valid HTTP(S) origin: refuse to store an unbound key.
                    _ = writeBoundMarker(markerSlot)
                    removeKey(legacySlot)
                    continue
                }
                let saved = saveBoundCredential(
                    endpointID: id,
                    origin: restoredOrigin,
                    key: providedKey,
                    writeBoundRecord: writeBoundRecord,
                    writeBoundMarker: writeBoundMarker,
                    writeLegacyKey: writeLegacyKey,
                    removeKey: removeKey
                )
                if !saved {
                    _ = writeBoundMarker(markerSlot)
                }
                continue
            }

            // No key provided in backup for this endpoint.
            if let previousOrigin, previousOrigin != restoredOrigin {
                // Same endpoint ID now points to a different origin (or invalid URL) without a restored key.
                // Mark bound first so even if removing the legacy slot fails, readers refuse to send
                // the previous host's key to the restored host.
                _ = writeBoundMarker(markerSlot)
                removeKey(boundRecordSlot(for: id, origin: previousOrigin))
                removeKey(legacySlot)
            } else if let restoredOrigin, previousOrigin == restoredOrigin {
                // Same ID and same origin on this device: keep existing credential, upgrading legacy keys in place.
                if !hasBoundMarker(markerSlot),
                   let legacy = readLegacyKey(legacySlot), !legacy.isEmpty,
                   let data = BoundEndpointCredential(origin: restoredOrigin, accessToken: legacy).encodedData() {
                    if writeBoundRecord(boundRecordSlot(for: id, origin: restoredOrigin), data) {
                        _ = writeBoundMarker(markerSlot)
                    }
                }
            } else {
                // Endpoint did not previously exist on this device (or had no valid origin).
                // Never allow a leftover unbound legacy key from another host to attach to this restored endpoint.
                // (An existing origin-scoped `boundRecordSlot(id, restoredOrigin)` from a prior reinstall on the
                // same host remains valid because its embedded `origin` already matches `restoredOrigin`.)
                _ = writeBoundMarker(markerSlot)
                removeKey(legacySlot)
            }
        }

        // For previous endpoints removed by this restore, lock any unbound legacy key to its prior origin
        // so it can never later fall back onto a different host if another keyless backup reintroduces that ID.
        for previous in previousEndpoints where !restoredIDs.contains(previous.id) {
            let id = previous.id
            let markerSlot = boundMarkerSlot(for: id)
            let legacySlot = legacyKeySlot(for: id)
            guard !hasBoundMarker(markerSlot),
                  let legacy = readLegacyKey(legacySlot), !legacy.isEmpty else { continue }
            if let previousOrigin = previousOriginByID[id],
               let data = BoundEndpointCredential(origin: previousOrigin, accessToken: legacy).encodedData(),
               writeBoundRecord(boundRecordSlot(for: id, origin: previousOrigin), data) {
                _ = writeBoundMarker(markerSlot)
            } else {
                _ = writeBoundMarker(markerSlot)
                removeKey(legacySlot)
            }
        }
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

        let currentKey = resolveBoundKey(
            endpointID: endpointID,
            requestURL: currentBaseURL,
            readBoundRecord: store.readBoundRecord,
            hasBoundMarker: store.hasBoundMarker,
            readLegacyKey: store.readLegacyKey
        )

        // Same-origin edit (path/name/style adjustment, with optional key rotation on the same host).
        if sameOrigin {
            if let nextKey {
                let previousBoundData = store.readBoundRecord(boundRecordSlot(for: endpointID, origin: newOrigin))
                let hadMarker = store.hasBoundMarker(boundMarkerSlot(for: endpointID))
                let previousLegacy = store.readLegacyKey(legacyKeySlot(for: endpointID))

                let written = saveBoundCredential(
                    endpointID: endpointID,
                    origin: newOrigin,
                    key: nextKey,
                    writeBoundRecord: store.writeBoundRecord,
                    writeBoundMarker: store.writeBoundMarker,
                    writeLegacyKey: store.writeLegacyKey,
                    removeKey: store.removeKey
                )
                guard written else {
                    restoreSameOrigin(
                        endpointID: endpointID,
                        origin: newOrigin,
                        previousBoundData: previousBoundData,
                        hadMarker: hadMarker,
                        previousLegacy: previousLegacy,
                        store: store
                    )
                    return .keySaveFailed
                }
                guard store.commitSettings(endpointID, normalized) else {
                    restoreSameOrigin(
                        endpointID: endpointID,
                        origin: newOrigin,
                        previousBoundData: previousBoundData,
                        hadMarker: hadMarker,
                        previousLegacy: previousLegacy,
                        store: store
                    )
                    return .settingsSaveFailed
                }
                return .saved(endpointID: endpointID, normalizedURL: normalized, keyUpdated: true)
            }

            guard store.commitSettings(endpointID, normalized) else {
                return .settingsSaveFailed
            }
            // Opportunistically upgrade a pre-existing legacy key into an atomic bound record.
            if let currentKey, !store.hasBoundMarker(boundMarkerSlot(for: endpointID)),
               let data = BoundEndpointCredential(origin: newOrigin, accessToken: currentKey).encodedData() {
                if store.writeBoundRecord(boundRecordSlot(for: endpointID, origin: newOrigin), data) {
                    _ = store.writeBoundMarker(boundMarkerSlot(for: endpointID))
                }
            }
            return .saved(endpointID: endpointID, normalizedURL: normalized, keyUpdated: false)
        }

        // Cross-origin change: determine the key for the new host.
        let keyForNewHost: String?
        if let nextKey {
            keyForNewHost = nextKey
        } else {
            let hasExistingKey = (currentKey?.isEmpty == false)
            let isLocalTarget = URL(string: normalized).map(LocalAddress.isLocal) ?? false
            let isKeylessPlaceholder = allowKeylessLocalReuse
                && isLocalTarget
                && (currentKey == nil || currentKey == "" || currentKey == "local")
            if hasExistingKey && !isKeylessPlaceholder {
                return .keyRequiredForNewHost
            }
            keyForNewHost = isKeylessPlaceholder ? currentKey : nil
        }

        // Mint an independent endpoint ID for the new host so old slots are NEVER overwritten
        // and concurrent readers or delete failures can never cross-pair credentials.
        var newID = store.makeEndpointID()
        if newID == endpointID {
            newID = UUID().uuidString
        }

        // 1. Write and verify the new host's independent credential BEFORE touching settings.
        if let keyForNewHost, !keyForNewHost.isEmpty {
            let written = saveBoundCredential(
                endpointID: newID,
                origin: newOrigin,
                key: keyForNewHost,
                writeBoundRecord: store.writeBoundRecord,
                writeBoundMarker: store.writeBoundMarker,
                writeLegacyKey: store.writeLegacyKey,
                removeKey: store.removeKey
            )
            guard written else {
                cleanupCredentials(endpointID: newID, origin: newOrigin, readLegacyKey: store.readLegacyKey, removeKey: store.removeKey)
                return .keySaveFailed
            }
        } else {
            // Even without a key, mark the new ID as bound so it can never fall back to an unexpected legacy slot.
            _ = store.writeBoundMarker(boundMarkerSlot(for: newID))
        }

        // 2. Atomically switch settings to `(newID, normalized)`.
        guard store.commitSettings(newID, normalized) else {
            cleanupCredentials(endpointID: newID, origin: newOrigin, readLegacyKey: store.readLegacyKey, removeKey: store.removeKey)
            return .settingsSaveFailed
        }

        // 3. Deferred best-effort cleanup of the old host's slots.
        cleanupCredentials(endpointID: endpointID, origin: oldOrigin, readLegacyKey: store.readLegacyKey, removeKey: store.removeKey)
        return .saved(endpointID: newID, normalizedURL: normalized, keyUpdated: nextKey != nil)
    }

    private static func restoreSameOrigin(
        endpointID: String,
        origin: String,
        previousBoundData: Data?,
        hadMarker: Bool,
        previousLegacy: String?,
        store: Store
    ) {
        let boundSlot = boundRecordSlot(for: endpointID, origin: origin)
        let markerSlot = boundMarkerSlot(for: endpointID)
        let legacySlot = legacyKeySlot(for: endpointID)
        if let previousBoundData {
            _ = store.writeBoundRecord(boundSlot, previousBoundData)
        } else {
            store.removeKey(boundSlot)
        }
        if hadMarker {
            _ = store.writeBoundMarker(markerSlot)
        } else {
            store.removeKey(markerSlot)
        }
        if let previousLegacy {
            _ = store.writeLegacyKey(legacySlot, previousLegacy)
        } else {
            store.removeKey(legacySlot)
        }
    }
}
