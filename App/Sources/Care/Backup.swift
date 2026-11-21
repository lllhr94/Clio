import Foundation

/// 备份: everything Clio keeps — companions, conversations, memory, portraits, settings — in one file, and back.
/// The file is a simple archive: a header, then for each file its path and bytes.
enum Backup {
    private static let magic = Data("CLIO-BACKUP-1\n".utf8)
    private static let prefixes = ["look.", "chat.", "grant.", "mascot.", "always.allowed", "persona"]

    private static var support: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0] }
    /// Folders under Application Support that are ours to keep. 斗室's Linux is left out: it is large and rebuilt from the app.
    private static let folders = ["Team", "Portraits"]

    struct Summary {
        var files: Int
        var bytes: Int
    }

    /// Writes the backup and returns where it is.
    static func make(withKeys: Bool, endpoints: [String]) throws -> (URL, Summary) {
        var out = Data()
        out.append(magic)
        var count = 0
        func add(_ path: String, _ data: Data) {
            let name = Data(path.utf8)
            var nameLength = UInt32(name.count).bigEndian
            var dataLength = UInt64(data.count).bigEndian
            out.append(Data(bytes: &nameLength, count: 4))
            out.append(name)
            out.append(Data(bytes: &dataLength, count: 8))
            out.append(data)
            count += 1
        }
        let manager = FileManager.default
        for folder in folders {
            let base = support.appendingPathComponent(folder, isDirectory: true)
            guard let walker = manager.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            for case let url as URL in walker {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                      let data = try? Data(contentsOf: url) else { continue }
                let relative = String(url.standardizedFileURL.path.dropFirst(support.standardizedFileURL.path.count + 1))
                add(relative, data)
            }
        }
        var settings: [String: Any] = [:]
        for (key, value) in UserDefaults.standard.dictionaryRepresentation() where prefixes.contains(where: { key.hasPrefix($0) }) {
            settings[key] = value
        }
        if let data = try? PropertyListSerialization.data(fromPropertyList: settings, format: .binary, options: 0) {
            add("#settings", data)
        }
        if withKeys {
            var keys: [String: String] = [:]
            for id in endpoints {
                if let key = Vault.load(String.self, key: "key-\(id)") { keys[id] = key }
            }
            if let data = try? JSONEncoder().encode(keys) { add("#keys", data) }
        }
        // Date and time in the name, so backups sort and several a day do not replace each other on a drive.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        let stamp = formatter.string(from: Date())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Clio 备份 \(stamp).clio-backup")
        try out.write(to: url, options: .atomic)
        return (url, Summary(files: count, bytes: out.count))
    }

    /// Reads a backup and puts every file back in place. Existing files with the same name are replaced.
    static func restore(from url: URL) throws -> Summary {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.starts(with: magic) else { throw TeamError(message: "这不是 Clio 的备份文件。") }
        var at = magic.count
        var count = 0
        func read(_ length: Int) throws -> Data {
            guard at + length <= data.count else { throw TeamError(message: "备份文件不完整。") }
            defer { at += length }
            return data.subdata(in: at..<(at + length))
        }
        while at < data.count {
            let nameLength = try read(4).withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
            guard let path = String(data: try read(nameLength), encoding: .utf8) else { throw TeamError(message: "备份文件坏了。") }
            let length = try read(8).withUnsafeBytes { Int(UInt64(bigEndian: $0.loadUnaligned(as: UInt64.self))) }
            let body = try read(length)
            switch path {
            case "#settings":
                if let settings = try? PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any] {
                    for (key, value) in settings { UserDefaults.standard.set(value, forKey: key) }
                }
            case "#keys":
                if let keys = try? JSONDecoder().decode([String: String].self, from: body) {
                    for (id, key) in keys { Vault.save(key, as: "key-\(id)") }
                }
            default:
                guard !path.contains(".."), folders.contains(where: { path.hasPrefix($0 + "/") }) else { continue }
                let target = support.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try body.write(to: target, options: .atomic)
            }
            count += 1
        }
        return Summary(files: count, bytes: data.count)
    }
}
