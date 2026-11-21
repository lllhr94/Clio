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
        // A conversation that could not be saved would go out as its older copy: say so instead.
        let unsaved = ChatDisk.finishWritesReportingFailures()
        if unsaved > 0 {
            throw TeamError(message: "有 \(unsaved) 段对话最近一次没存进手机（可能是空间满了），备份里会是旧的。先腾出空间、再发一条消息让它重存，然后再备份。")
        }
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

    /// One file in a backup: where it goes and where its bytes are in the archive.
    private struct Item {
        let path: String
        let range: Range<Int>
    }

    /// Reads a backup and puts it back, all or nothing (the 0.34 review, #1):
    /// 1. the whole file is checked first — every length within the file — before anything is touched;
    /// 2. the files are written into a copy of the current data, off to the side;
    /// 3. only then is that copy swapped in for the real folders, and the old ones kept until the swap is done;
    /// 4. settings and keys are applied last, once the files are in.
    /// A broken, cut-short or unwritable backup leaves what is on the phone exactly as it was. Afterwards nothing is
    /// saved until Clio is opened again, so the old state in memory cannot overwrite what was restored.
    static func restore(from url: URL) throws -> Summary {
        ChatDisk.finishWrites()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.starts(with: magic) else { throw TeamError(message: "这不是 Clio 的备份文件。") }

        // 1. Check it all.
        var items: [Item] = []
        var at = magic.count
        func take(_ length: UInt64) throws -> Range<Int> {
            guard length <= UInt64(data.count - at) else { throw TeamError(message: "备份文件不完整，本地数据没动。") }
            let end = at + Int(length)
            defer { at = end }
            return at..<end
        }
        while at < data.count {
            let nameLength = data.subdata(in: try take(4)).withUnsafeBytes { UInt64(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
            guard nameLength > 0, nameLength < 4096, let path = String(data: data.subdata(in: try take(nameLength)), encoding: .utf8) else {
                throw TeamError(message: "备份文件坏了，本地数据没动。")
            }
            let length = data.subdata(in: try take(8)).withUnsafeBytes { UInt64(bigEndian: $0.loadUnaligned(as: UInt64.self)) }
            items.append(Item(path: path, range: try take(length)))
        }

        // 2. Write into a copy of the current folders.
        let manager = FileManager.default
        let staging = support.appendingPathComponent(".restore-staging", isDirectory: true)
        let old = support.appendingPathComponent(".restore-old", isDirectory: true)
        try? manager.removeItem(at: staging)
        try? manager.removeItem(at: old)
        defer { try? manager.removeItem(at: staging) }
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        for folder in folders {
            let live = support.appendingPathComponent(folder, isDirectory: true)
            if manager.fileExists(atPath: live.path) {
                try manager.copyItem(at: live, to: staging.appendingPathComponent(folder, isDirectory: true))
            }
        }
        var count = 0
        for item in items where !item.path.hasPrefix("#") {
            let parts = item.path.split(separator: "/").map(String.init)
            guard parts.count >= 2, folders.contains(parts[0]), !parts.contains(".."), !parts.contains(".") else { continue }
            let target = staging.appendingPathComponent(item.path)
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.subdata(in: item.range).write(to: target, options: .atomic)
            count += 1
        }

        // 3. Swap, folder by folder, putting the old one back if a step fails.
        ChatDisk.finishWrites()
        Disk.frozen = true
        try manager.createDirectory(at: old, withIntermediateDirectories: true)
        var swapped: [String] = []
        do {
            for folder in folders {
                let live = support.appendingPathComponent(folder, isDirectory: true)
                let fresh = staging.appendingPathComponent(folder, isDirectory: true)
                guard manager.fileExists(atPath: fresh.path) else { continue }
                if manager.fileExists(atPath: live.path) {
                    try manager.moveItem(at: live, to: old.appendingPathComponent(folder, isDirectory: true))
                }
                swapped.append(folder)
                try manager.moveItem(at: fresh, to: live)
            }
        } catch {
            for folder in swapped.reversed() {
                let live = support.appendingPathComponent(folder, isDirectory: true)
                let kept = old.appendingPathComponent(folder, isDirectory: true)
                if manager.fileExists(atPath: kept.path) {
                    try? manager.removeItem(at: live)
                    try? manager.moveItem(at: kept, to: live)
                }
            }
            Disk.frozen = false
            throw TeamError(message: "恢复没成功（\(error.localizedDescription)），本地数据已经还原成原样。")
        }
        try? manager.removeItem(at: old)

        // 4. Settings and keys, now that the files are in.
        for item in items {
            let body = data.subdata(in: item.range)
            switch item.path {
            case "#settings":
                if let settings = try? PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any] {
                    for (key, value) in settings where prefixes.contains(where: { key.hasPrefix($0) }) {
                        UserDefaults.standard.set(value, forKey: key)
                    }
                    count += 1
                }
            case "#keys":
                if let keys = try? JSONDecoder().decode([String: String].self, from: body) {
                    for (id, key) in keys { Vault.save(key, as: "key-\(id)") }
                    count += 1
                }
            default: break
            }
        }
        return Summary(files: count, bytes: data.count)
    }
}
