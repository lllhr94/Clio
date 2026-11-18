import Foundation
import Security

/// Where the phone keeps its keys and its paired computer: the Keychain,
/// or a protected file when the Keychain refuses (some re-signed installs).
enum Vault {
    private static let service = "io.github.lllhr94.dsbot.link"

    static func save<Value: Encodable>(_ value: Value, as key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        forget()
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if SecItemAdd(item as CFDictionary, nil) == errSecSuccess {
            try? FileManager.default.removeItem(at: file(key))
        } else {
            try? data.write(to: file(key), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    static func load<Value: Decodable>(_ type: Value.Type, key: String) -> Value? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var found: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess,
           let data = found as? Data,
           let value = try? JSONDecoder().decode(type, from: data) {
            return value
        }
        guard let data = try? Data(contentsOf: file(key)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func forget() {
        lock.lock()
        cached = nil
        lock.unlock()
    }

    static func remove(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        try? FileManager.default.removeItem(at: file(key))
    }

    /// Every secret kept here that is a plain string (passwords, API keys, tokens), for hiding them from what a model reads.
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
            for data in list {
                if let text = try? JSONDecoder().decode(String.self, from: data), !text.isEmpty { values.append(text) }
            }
        }
        // Secrets that fell back to files when the Keychain refused them.
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        if let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) {
            for name in names where name.hasPrefix("link-") && name.hasSuffix(".json") {
                if let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
                   let text = try? JSONDecoder().decode(String.self, from: data), !text.isEmpty { values.append(text) }
            }
        }
        cached = (Date(), values)
        return values
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: (at: Date, values: [String])?

    private static func file(_ key: String) -> URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("link-\(key).json")
    }
}
