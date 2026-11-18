import Foundation
import Security

/// What the home-screen widget shows: one companion, what it is doing, the last thing it said.
struct WidgetSnapshot: Codable, Equatable {
    var name: String
    /// 闲坐 · 在干活 · 等你批准
    var status: String
    var line: String
    /// Seconds since 1970.
    var at: Double
    /// The conversation a tap opens, bot-… or room-….
    var chat: String
}

/// A small shelf both the app and its widget can reach: a keychain item in a group shared by the two.
/// A signing profile with a wildcard app id usually allows any keychain group of its team, while App Groups need
/// an explicit id; this is why the snapshot travels through the keychain.
enum Shelf {
    private static let account = "widget.snapshot"

    /// The team prefix this copy was signed with (TEAMID.), read off a keychain item in the default group.
    private static var prefix: String? {
        let probe: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "shelf.probe",
            kSecAttrService as String: "clio.shelf",
            kSecReturnAttributes as String: true,
        ]
        var found: CFTypeRef?
        var status = SecItemCopyMatching(probe as CFDictionary, &found)
        if status == errSecItemNotFound {
            var add = probe
            add.removeValue(forKey: kSecReturnAttributes as String)
            add[kSecValueData as String] = Data()
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
            status = SecItemCopyMatching(probe as CFDictionary, &found)
        }
        guard status == errSecSuccess, let attributes = found as? [String: Any],
              let group = attributes[kSecAttrAccessGroup as String] as? String, let dot = group.firstIndex(of: ".") else { return nil }
        return String(group[...dot])
    }

    private static var group: String? { prefix.map { $0 + "io.github.lllhr94.clio.shared" } }

    private static func query() -> [String: Any]? {
        guard let group else { return nil }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "clio.shelf",
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: group,
        ]
    }

    /// False when the signing does not allow the shared group: the widget then says so instead of showing old news.
    @discardableResult
    static func put(_ snapshot: WidgetSnapshot) -> Bool {
        guard let base = query(), let data = try? JSONEncoder().encode(snapshot) else { return false }
        let update = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func take() -> WidgetSnapshot? {
        guard var base = query() else { return nil }
        base[kSecReturnData as String] = true
        var found: CFTypeRef?
        guard SecItemCopyMatching(base as CFDictionary, &found) == errSecSuccess, let data = found as? Data else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }
}
