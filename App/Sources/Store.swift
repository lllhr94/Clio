import Foundation
import Security

struct VaultRotatedCredential<Payload: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    let rotationSeq: UInt64
    let credentialID: String
    let payload: Payload
    let updatedAt: Date
}

struct VaultRotationIntent: Codable, Equatable, Sendable {
    let credentialID: String
    let oldRotationSeq: UInt64
    let startedAt: Date
}

/// Called under the session's epoch lock. Sidecars use protected files independently of the Keychain.
struct VaultRotationStore<Payload: Codable & Equatable & Sendable> {
    typealias Credential = VaultRotatedCredential<Payload>

    enum Load: Equatable {
        case missing
        case current(Credential)
        case recovered(Credential)
        case reauthRequired
    }

    enum StorageError: Error, LocalizedError {
        case reauthRequired
        case intentNotCleared

        var errorDescription: String? {
            switch self {
            case .reauthRequired: return "无法安全保存续期令牌，请重新登录。"
            case .intentNotCleared: return "续期记录暂时无法写入，请稍后重试。"
            }
        }
    }

    struct Backing {
        var keychain: (String) -> Data?
        var protected: (String) -> Data?
        var writePrimary: (Data, String) throws -> Void
        var writeProtected: (Data, String) throws -> Void
        var removeProtected: (String) -> Bool
        var removePrimary: (String) -> Bool

        static var vault: Self {
            Self(keychain: Vault.keychainData, protected: Vault.protectedData,
                 writePrimary: { try Vault.saveRaw($0, as: $1) },
                 writeProtected: { try Vault.writeProtected($0, as: $1) },
                 removeProtected: Vault.removeProtected, removePrimary: Vault.removeRaw)
        }
    }

    let credentialID: String
    var backing: Backing = .vault

    var pendingKey: String { "pending_rotation.\(credentialID)" }
    var intentKey: String { "rotation_in_flight.\(credentialID)" }

    var hasCredential: Bool {
        backing.protected(intentKey) != nil || backing.protected(credentialID) != nil
            || backing.keychain(credentialID) != nil
    }

    var latestPayload: Payload? {
        best([backing.keychain(credentialID), backing.protected(credentialID), backing.protected(pendingKey)])?.payload
    }

    func load(legacy: (() -> Payload?)? = nil) -> Load {
        let primary = best([backing.keychain(credentialID), backing.protected(credentialID)])
        guard let intentBytes = backing.protected(intentKey) else {
            if let primary { return .current(primary) }
            if let payload = legacy?() { return .current(record(payload, sequence: 0)) }
            return .missing
        }
        guard let intent = try? JSONDecoder().decode(VaultRotationIntent.self, from: intentBytes),
              intent.credentialID == credentialID else { return .reauthRequired }
        if intent.oldRotationSeq == UInt64.max { return .missing }
        let pending = decode(backing.protected(pendingKey))
        guard let newer = [primary, pending].compactMap({ $0 })
            .filter({ $0.rotationSeq > intent.oldRotationSeq }).max(by: isOlder) else {
            return .reauthRequired
        }
        if let data = try? JSONEncoder().encode(newer),
           (try? backing.writePrimary(data, credentialID)) != nil {
            clearSidecars()
        }
        return .recovered(newer)
    }

    func begin(_ current: Credential) throws {
        guard current.rotationSeq < UInt64.max else { throw StorageError.reauthRequired }
        // A staged-only credential must be promoted before replacing its intent.
        guard backing.protected(intentKey) == nil else { throw StorageError.intentNotCleared }
        let intent = VaultRotationIntent(credentialID: credentialID, oldRotationSeq: current.rotationSeq, startedAt: Date())
        try backing.writeProtected(JSONEncoder().encode(intent), intentKey)
    }

    @discardableResult
    func finish(_ payload: Payload, replacing current: Credential) throws -> Credential {
        let next = record(payload, sequence: current.rotationSeq + 1)
        let data = try JSONEncoder().encode(next)
        let staged = (try? backing.writeProtected(data, pendingKey)) != nil
        do {
            try backing.writePrimary(data, credentialID)
            clearSidecars()
        } catch {
            guard staged else { throw StorageError.reauthRequired }
        }
        return next
    }

    func abandonRetryableRefresh() {
        clearSidecars()
    }

    func replace(_ payload: Payload) throws {
        let highest = best([backing.keychain(credentialID), backing.protected(credentialID), backing.protected(pendingKey)])
        let intent = backing.protected(intentKey).flatMap { try? JSONDecoder().decode(VaultRotationIntent.self, from: $0) }
        let previous = intent?.oldRotationSeq ?? 0
        let sequence = max(highest?.rotationSeq ?? 0, previous == UInt64.max ? 0 : previous)
        guard sequence < UInt64.max else { throw StorageError.reauthRequired }
        let next = record(payload, sequence: sequence + 1)
        try backing.writePrimary(JSONEncoder().encode(next), credentialID)
        clearSidecars()
    }

    func remove() {
        // UInt64.max cannot be a refresh intent. Keep the sign-out marker if a copy cannot be deleted.
        if hasCredential {
            let tombstone = VaultRotationIntent(credentialID: credentialID, oldRotationSeq: UInt64.max, startedAt: Date())
            if let data = try? JSONEncoder().encode(tombstone) {
                try? backing.writeProtected(data, intentKey)
            }
        }
        let primaryRemoved = backing.removePrimary(credentialID)
        let pendingRemoved = backing.removeProtected(pendingKey)
        if primaryRemoved, pendingRemoved { _ = backing.removeProtected(intentKey) }
    }

    private func clearSidecars() {
        if backing.removeProtected(pendingKey) { _ = backing.removeProtected(intentKey) }
    }

    private func record(_ payload: Payload, sequence: UInt64) -> Credential {
        Credential(rotationSeq: sequence, credentialID: credentialID, payload: payload, updatedAt: Date())
    }

    private func decode(_ data: Data?) -> Credential? {
        guard let data, let credential = try? JSONDecoder().decode(Credential.self, from: data),
              credential.credentialID == credentialID else { return nil }
        return credential
    }

    private func best(_ candidates: [Data?]) -> Credential? {
        candidates.compactMap(decode).max(by: isOlder)
    }

    private func isOlder(_ lhs: Credential, _ rhs: Credential) -> Bool {
        lhs.rotationSeq == rhs.rotationSeq ? lhs.updatedAt < rhs.updatedAt : lhs.rotationSeq < rhs.rotationSeq
    }
}

/// Where the phone keeps its keys and its paired computer: the Keychain,
/// or a protected file when the Keychain refuses (some re-signed installs).
enum Vault {
    private static let service = "io.github.lllhr94.dsbot.link"

    static func save<Value: Encodable>(_ value: Value, as key: String) {
        _ = saveResult(value, as: key)
    }

    static func saveResult<Value: Encodable>(_ value: Value, as key: String) -> Result<Void, Error> {
        Result { try saveRaw(JSONEncoder().encode(value), as: key) }
    }

    private static let writes = NSLock()

    fileprivate static func saveRaw(_ data: Data, as key: String) throws {
        writes.lock()
        defer { writes.unlock() }
        let query = itemQuery(key)
        let changes = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
            if status == errSecDuplicateItem {
                status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
            }
        }
        defer { forget() }
        if status == errSecSuccess {
            _ = removeProtected(key)
        } else {
            try writeProtected(data, as: key)
        }
    }

    private static func itemQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    fileprivate static func keychainData(_ key: String) -> Data? {
        var query = itemQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess else { return nil }
        return found as? Data
    }

    fileprivate static func protectedData(_ key: String) -> Data? {
        try? Data(contentsOf: file(key))
    }

    fileprivate static func writeProtected(_ data: Data, as key: String) throws {
        try data.write(to: file(key), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        forget()
    }

    @discardableResult
    fileprivate static func removeProtected(_ key: String) -> Bool {
        do {
            try FileManager.default.removeItem(at: file(key))
            forget()
            return true
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return true
        } catch {
            return false
        }
    }

    static func load<Value: Decodable>(_ type: Value.Type, key: String) -> Value? {
        writes.lock()
        defer { writes.unlock() }
        // The fallback can be newer after a failed Keychain update.
        for data in [protectedData(key), keychainData(key)].compactMap({ $0 }) {
            if let value = try? JSONDecoder().decode(type, from: data) { return value }
        }
        return nil
    }

    /// Security.framework and the fallback file can both block; use this from UI tasks.
    static func readString(_ key: String) async -> String? {
        await Task.detached(priority: .userInitiated) { load(String.self, key: key) }.value
    }

    private static func forget() {
        lock.lock()
        cached = nil
        lock.unlock()
    }

    static func remove(_ key: String) {
        _ = removeRaw(key)
    }

    fileprivate static func removeRaw(_ key: String) -> Bool {
        writes.lock()
        defer { writes.unlock() }
        let status = SecItemDelete(itemQuery(key) as CFDictionary)
        let removed = removeProtected(key)
        forget()
        return removed && (status == errSecSuccess || status == errSecItemNotFound)
    }

    /// Every secret kept here (passwords, API keys, OAuth tokens, SSH private keys), for hiding them from what a model reads.
    /// Read again at most every few seconds.
    nonisolated static func allStrings() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        if let cached, Date().timeIntervalSince(cached.at) < 5 { return cached.values }
        var values: [String] = []
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var found: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let list = found as? [Data] {
            for data in list { values += extractSecrets(from: data) }
        }
        // Secrets that fell back to files when the Keychain refused them.
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        if let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) {
            for name in names where name.hasPrefix("link-") && name.hasSuffix(".json") {
                if let data = try? Data(contentsOf: folder.appendingPathComponent(name)) {
                    values += extractSecrets(from: data)
                }
            }
        }
        cached = (Date(), values)
        return values
    }

    nonisolated static func extractSecrets(from data: Data) -> [String] {
        let secretKeys: Set<String> = [
            "access", "refresh", "clientSecret", "access_token", "refresh_token", "client_secret",
            "apiKey", "api_key", "token", "id_token", "password", "payload",
        ]
        func strings(in object: [String: Any]) -> [String] {
            object.flatMap { key, value -> [String] in
                if let nested = value as? [String: Any] { return strings(in: nested) }
                if secretKeys.contains(key), let text = value as? String, !text.isEmpty { return [text] }
                return []
            }
        }

        if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            return strings(in: object)
        }
        let decoder = JSONDecoder()
        if let raw = try? decoder.decode(Data.self, from: data), !raw.isEmpty {
            if let object = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] {
                return strings(in: object)
            }
            var candidates = [raw.base64EncodedString()]
            if let original = try? decoder.decode(String.self, from: data), !candidates.contains(original) {
                candidates.append(original)
            }
            if let text = String(data: raw, encoding: .utf8), !candidates.contains(text),
               text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                candidates.append(text)
            }
            return candidates
        }
        if let text = try? decoder.decode(String.self, from: data), !text.isEmpty { return [text] }
        return []
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: (at: Date, values: [String])?

    private static func safeFileComponent(_ key: String) -> String {
        let legacySafe = !key.isEmpty && key != "." && key != ".." && key.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39)
            || (byte >= 0x41 && byte <= 0x5A)
            || (byte >= 0x61 && byte <= 0x7A)
            || byte == 0x2E || byte == 0x5F || byte == 0x2D
        }
        if legacySafe { return key }
        var encoded = "enc~"
        for byte in key.utf8 {
            let unreserved = (byte >= 0x30 && byte <= 0x39)
                || (byte >= 0x41 && byte <= 0x5A)
                || (byte >= 0x61 && byte <= 0x7A)
                || byte == 0x2E || byte == 0x5F || byte == 0x2D
            if unreserved {
                encoded.append(Character(UnicodeScalar(byte)))
            } else {
                encoded += String(format: "%%%02X", byte)
            }
        }
        return encoded
    }

    private static func file(_ key: String) -> URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("link-\(safeFileComponent(key)).json")
    }
}
