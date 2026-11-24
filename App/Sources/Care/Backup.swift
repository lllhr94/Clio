import Craft
import Darwin
import Foundation

/// 备份: everything Clio keeps — companions, conversations, memory, portraits, skills, settings — in one file, and back.
/// The outer plaintext format is `CLIO-BACKUP-1\n`; when encrypted with a passphrase (always required when `#keys`
/// is included), the whole archive is sealed in `CLIO-BACKUP-ENC-1\n` via `BackupCrypto`.
enum Backup {
    private static let magic = Data("CLIO-BACKUP-1\n".utf8)
    private static let magicPrefix = Data("CLIO-BACKUP-".utf8)
    private static let prefixes = ["look.", "chat.", "grant.", "mascot.", "always.allowed", "persona"]
    private static let folders = ["Team", "Portraits"]
    /// Settings a backup may bring back. Permissions (「以后都允许」, 应许) and the lock are not among them: a backup
    /// file from elsewhere must not be able to loosen them.
    private static let restorable = ["look.", "chat.", "mascot.", "persona"]

    static let maxBackupFileBytes = 512 * 1024 * 1024
    static let maxSkillSingleFileBytes = 8 * 1024 * 1024
    static let maxSkillTotalBytes = 64 * 1024 * 1024
    static let maxSkillFileCount = 1024
    private static let maxArchiveEntryCount = 100_000

    private static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    struct Summary: Sendable {
        var files: Int
        var bytes: Int
    }

    /// Reads only the first 18 magic bytes of a backup file without loading the archive into memory.
    static func isEncryptedBackup(at url: URL) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            return false
        }
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: BackupCrypto.magic.count) else {
            return false
        }
        return BackupCrypto.isEncrypted(prefix)
    }

    /// Writes the backup and returns where it is.
    /// Hard invariant: exporting `#keys` (`withKeys == true`) requires a non-empty `passphrase` and MUST produce an
    /// encrypted `CLIO-BACKUP-ENC-1\n` file; plaintext `#keys` backups are never emitted.
    static func make(withKeys: Bool, endpoints: [String], passphrase: String? = nil) throws -> (URL, Summary) {
        let trimmedPassphrase = passphrase?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let shouldEncrypt: Bool
        if withKeys {
            guard let passphrase else {
                throw BackupCryptoError.passphraseRequired
            }
            guard !trimmedPassphrase.isEmpty else {
                throw BackupCryptoError.emptyPassphrase
            }
            shouldEncrypt = true
        } else if !trimmedPassphrase.isEmpty {
            shouldEncrypt = true
        } else {
            shouldEncrypt = false
        }

        // A conversation that could not be saved would go out as its older copy: say so instead.
        let unsaved = ChatDisk.finishWritesReportingFailures()
        if unsaved > 0 {
            throw TeamError(message: "有 \(unsaved) 段对话最近一次没存进手机（可能是空间满了），备份里会是旧的。先腾出空间、再发一条消息让它重存，然后再备份。")
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        let stamp = formatter.string(from: Date())

        // Earlier backups left in the temporary folder (one may hold keys) go first.
        let manager = FileManager.default
        let temp = manager.temporaryDirectory
        for old in (try? manager.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil)) ?? []
        where old.lastPathComponent.hasPrefix("Clio 备份 ")
            || old.pathExtension == "clio-backup"
            || old.lastPathComponent.hasSuffix(".clio-backup.part")
            || old.lastPathComponent.hasSuffix(".clio-backup.encpart") {
            try? manager.removeItem(at: old)
        }

        let url = temp.appendingPathComponent("Clio 备份 \(stamp).clio-backup")
        let partial = url.appendingPathExtension("part")
        let encryptedPartial = temp.appendingPathComponent(UUID().uuidString + ".clio-backup.encpart")
        try? manager.removeItem(at: partial)
        try? manager.removeItem(at: encryptedPartial)

        let protection: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        guard manager.createFile(atPath: partial.path, contents: nil, attributes: protection) else {
            throw TeamError(message: "没能在手机上建备份文件。")
        }

        var completed = false
        defer {
            if !completed {
                try? manager.removeItem(at: partial)
                try? manager.removeItem(at: encryptedPartial)
            }
        }

        let out = try FileHandle(forWritingTo: partial)
        var outClosed = false
        defer {
            if !outClosed {
                try? out.close()
            }
        }

        try out.write(contentsOf: magic)
        var count = 0
        var bytes = magic.count
        var unreadable: [String] = []

        func add(_ path: String, _ data: Data) throws {
            let name = Data(path.utf8)
            var nameLength = UInt32(name.count).bigEndian
            var dataLength = UInt64(data.count).bigEndian
            try out.write(contentsOf: Data(bytes: &nameLength, count: 4))
            try out.write(contentsOf: name)
            try out.write(contentsOf: Data(bytes: &dataLength, count: 8))
            try out.write(contentsOf: data)
            bytes += 12 + name.count + data.count
            count += 1
        }

        var archivedEndpoints: [Endpoint]?
        let supportReal = support.resolvingSymlinksInPath().standardizedFileURL.path
        for folder in folders {
            let base = support.appendingPathComponent(folder, isDirectory: true)
            guard isRealDirectory(base) else { continue }
            guard let walker = manager.enumerator(
                at: base,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey],
                options: []
            ) else { continue }
            for case let file as URL in walker {
                var st = stat()
                guard lstat(file.path, &st) == 0 else { continue }
                let mode = st.st_mode & S_IFMT
                if mode == S_IFLNK {
                    walker.skipDescendants()
                    continue
                }
                if file.lastPathComponent.hasPrefix(".") {
                    if mode == S_IFDIR { walker.skipDescendants() }
                    continue
                }
                guard mode == S_IFREG,
                      let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                      values.isSymbolicLink != true,
                      values.isRegularFile == true else {
                    continue
                }
                let fileReal = file.resolvingSymlinksInPath().standardizedFileURL.path
                guard fileReal.hasPrefix(supportReal + "/") else { continue }
                let relative = String(fileReal.dropFirst(supportReal.count + 1))
                if BackupArchivePolicy.isExcludedArchivePath(relative) { continue }

                // One at a time, and a file that cannot be read is named, not silently left out.
                guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
                    unreadable.append(relative)
                    continue
                }
                if relative == "Team/settings.json" {
                    archivedEndpoints = (try? JSONDecoder().decode(TeamSettings.self, from: data))?.endpoints
                }
                try autoreleasepool { try add(relative, data) }
            }
        }

        // Include 书案/技能 under archive prefix `Skills/`, skipping symlinks, hidden files, and oversized junk.
        let workspaceRoot = Workspace.root
        let skillsFolder = workspaceRoot.appendingPathComponent("技能", isDirectory: true)
        if isRealDirectory(workspaceRoot), isRealDirectory(skillsFolder) {
            let skillsReal = skillsFolder.resolvingSymlinksInPath().standardizedFileURL.path
            var skillFileCount = 0
            var skillTotalBytes = 0
            if let walker = manager.enumerator(
                at: skillsFolder,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey],
                options: []
            ) {
                for case let file as URL in walker {
                    var st = stat()
                    guard lstat(file.path, &st) == 0 else { continue }
                    let mode = st.st_mode & S_IFMT
                    if mode == S_IFLNK {
                        walker.skipDescendants()
                        continue
                    }
                    if file.lastPathComponent.hasPrefix(".") {
                        if mode == S_IFDIR { walker.skipDescendants() }
                        continue
                    }
                    guard mode == S_IFREG,
                          let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                          values.isSymbolicLink != true,
                          values.isRegularFile == true else {
                        continue
                    }
                    guard st.st_size >= 0, st.st_size <= Int64(maxSkillSingleFileBytes) else { continue }
                    let estimatedSize = Int(st.st_size)
                    guard skillFileCount < maxSkillFileCount,
                          skillTotalBytes + estimatedSize <= maxSkillTotalBytes else { continue }

                    let fileReal = file.resolvingSymlinksInPath().standardizedFileURL.path
                    guard fileReal.hasPrefix(skillsReal + "/") else { continue }
                    let inner = String(fileReal.dropFirst(skillsReal.count + 1))
                    let archivePath = "Skills/\(inner)"
                    if BackupArchivePolicy.isExcludedArchivePath(archivePath) { continue }

                    guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
                        unreadable.append(archivePath)
                        continue
                    }
                    guard data.count <= maxSkillSingleFileBytes,
                          skillFileCount < maxSkillFileCount,
                          skillTotalBytes + data.count <= maxSkillTotalBytes else { continue }

                    skillFileCount += 1
                    skillTotalBytes += data.count
                    try autoreleasepool { try add(archivePath, data) }
                }
            }
        }

        if !unreadable.isEmpty {
            throw TeamError(message: "有 \(unreadable.count) 个文件读不出来，备份没做完：\(unreadable.prefix(3).joined(separator: "、"))")
        }

        var settings: [String: Any] = [:]
        for (key, value) in UserDefaults.standard.dictionaryRepresentation() where prefixes.contains(where: { key.hasPrefix($0) }) {
            settings[key] = value
        }
        if let data = try? PropertyListSerialization.data(fromPropertyList: settings, format: .binary, options: 0) {
            try add("#settings", data)
        }

        if withKeys {
            guard shouldEncrypt else { throw BackupCryptoError.passphraseRequired }
            let currentEndpoints = archivedEndpoints ?? Disk.load(TeamSettings.self, "settings.json")?.endpoints ?? []
            let keys = TeamModel.exportBackupKeys(endpoints: currentEndpoints, allowedIDs: endpoints)
            if let data = try? JSONEncoder().encode(keys) {
                try add("#keys", data)
            }
        }

        try out.synchronize()
        try out.close()
        outClosed = true

        if shouldEncrypt {
            guard let passphrase else { throw BackupCryptoError.passphraseRequired }
            let plainArchive = try Data(contentsOf: partial, options: .mappedIfSafe)
            let encryptedArchive = try BackupCrypto.encrypt(payload: plainArchive, passphrase: passphrase)
            guard manager.createFile(atPath: encryptedPartial.path, contents: nil, attributes: protection) else {
                throw TeamError(message: "没能在手机上建加密备份文件。")
            }
            try encryptedArchive.write(to: encryptedPartial, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try? manager.removeItem(at: partial)
            try? manager.removeItem(at: url)
            try manager.moveItem(at: encryptedPartial, to: url)
            try? manager.setAttributes(protection, ofItemAtPath: url.path)
            completed = true
            return (url, Summary(files: count, bytes: encryptedArchive.count))
        }

        if withKeys {
            throw BackupCryptoError.passphraseRequired
        }

        try? manager.removeItem(at: url)
        try manager.moveItem(at: partial, to: url)
        try? manager.setAttributes(protection, ofItemAtPath: url.path)
        completed = true
        return (url, Summary(files: count, bytes: bytes))
    }

    /// One file in a backup: where it goes and where its bytes are in the archive.
    private struct Item {
        let path: String
        let range: Range<Int>
    }

    /// Reads a backup and puts it back, all or nothing (the 0.34 review, #1):
    /// 1. validates file type/size, decrypts if encrypted (`CLIO-BACKUP-ENC-1\n`), and checks every entry length;
    /// 2. stages `Team/`, `Portraits/`, and `Skills/` into temporary directories off to the side;
    /// 3. atomically swaps staged directories in while preserving rollback copies until everything succeeds;
    /// 4. applies settings and keys last, once files are in.
    static func restore(from url: URL, passphrase: String? = nil) throws -> Summary {
        ChatDisk.finishWrites()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        var st = stat()
        guard lstat(url.path, &st) == 0 else {
            throw TeamError(message: "找不到要恢复的备份文件。")
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            throw TeamError(message: "备份路径不是普通文件（可能是快捷方式或文件夹），已拒绝恢复。")
        }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values?.isSymbolicLink != true, values?.isRegularFile == true else {
            throw TeamError(message: "备份文件链接无效，已拒绝恢复。")
        }
        guard st.st_size > 0 else {
            throw TeamError(message: "备份文件是空的，本地数据没动。")
        }
        guard st.st_size <= Int64(maxBackupFileBytes) else {
            throw TeamError(message: "备份文件太大，无法安全校验并恢复。")
        }

        let rawData = try Data(contentsOf: url, options: .mappedIfSafe)
        guard rawData.count <= maxBackupFileBytes else {
            throw TeamError(message: "备份文件太大，无法安全校验并恢复。")
        }

        let data: Data
        if BackupCrypto.isEncrypted(rawData) {
            guard let passphrase, !passphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BackupCryptoError.passphraseRequired
            }
            data = try BackupCrypto.decrypt(rawData, passphrase: passphrase)
        } else {
            data = rawData
        }

        if !data.starts(with: magic) {
            if data.starts(with: magicPrefix) {
                throw TeamError(message: "这份备份的版本太新了，请先升级 Clio 再恢复。")
            }
            throw TeamError(message: "这不是 Clio 的备份文件。")
        }

        // 1. Check the entire archive structure before touching anything on disk.
        var items: [Item] = []
        var at = magic.count
        func take(_ length: UInt64) throws -> Range<Int> {
            guard length <= UInt64(data.count - at) else {
                throw TeamError(message: "备份文件不完整，本地数据没动。")
            }
            let end = at + Int(length)
            defer { at = end }
            return at..<end
        }

        var skillFileCount = 0
        var skillTotalBytes = 0
        while at < data.count {
            guard items.count < maxArchiveEntryCount else {
                throw TeamError(message: "备份里的文件数量过多，无法恢复。")
            }
            let nameLength = data.subdata(in: try take(4)).withUnsafeBytes {
                UInt64(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)))
            }
            guard nameLength > 0, nameLength < 4096,
                  let path = String(data: data.subdata(in: try take(nameLength)), encoding: .utf8) else {
                throw TeamError(message: "备份文件坏了，本地数据没动。")
            }
            let length = data.subdata(in: try take(8)).withUnsafeBytes {
                UInt64(bigEndian: $0.loadUnaligned(as: UInt64.self))
            }
            let range = try take(length)
            if !path.hasPrefix("#"), !BackupArchivePolicy.isExcludedArchivePath(path), path.hasPrefix("Skills/") {
                guard length <= UInt64(maxSkillSingleFileBytes),
                      skillFileCount < maxSkillFileCount,
                      skillTotalBytes + Int(length) <= maxSkillTotalBytes else {
                    throw TeamError(message: "备份里的技能文件体积或数量超过安全上限，本地数据没动。")
                }
                skillFileCount += 1
                skillTotalBytes += Int(length)
            }
            items.append(Item(path: path, range: range))
        }

        // 2. Stage into temporary folders off to the side.
        let manager = FileManager.default
        let staging = support.appendingPathComponent(".restore-staging", isDirectory: true)
        let old = support.appendingPathComponent(".restore-old", isDirectory: true)
        try? manager.removeItem(at: staging)
        try? manager.removeItem(at: old)
        defer { try? manager.removeItem(at: staging) }
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)

        for folder in folders {
            let live = support.appendingPathComponent(folder, isDirectory: true)
            if isSymbolicLink(live) {
                throw TeamError(message: "本地数据目录异常（包含符号链接），已中止恢复。")
            }
            if manager.fileExists(atPath: live.path) {
                try manager.copyItem(at: live, to: staging.appendingPathComponent(folder, isDirectory: true))
            }
        }
        stripDisallowedStagedArtifacts(in: staging.appendingPathComponent("Team", isDirectory: true))

        let skillsStaging = staging.appendingPathComponent("Skills.staging", isDirectory: true)
        var hasStagedSkills = false
        var count = 0

        for item in items where !item.path.hasPrefix("#") {
            guard !BackupArchivePolicy.isExcludedArchivePath(item.path),
                  let parts = BackupArchivePolicy.normalizeRelativePath(item.path),
                  let root = parts.first else {
                continue
            }

            if root == "Skills" {
                let innerParts = Array(parts.dropFirst())
                guard !innerParts.isEmpty else { continue }
                try manager.createDirectory(at: skillsStaging, withIntermediateDirectories: true)
                let target = innerParts.reduce(skillsStaging) { $0.appendingPathComponent($1) }
                try writeStagedFile(data.subdata(in: item.range), to: target, root: skillsStaging)
                hasStagedSkills = true
                count += 1
            } else {
                let target = parts.reduce(staging) { $0.appendingPathComponent($1) }
                try writeStagedFile(data.subdata(in: item.range), to: target, root: staging)
                count += 1
            }
        }

        // Verify staged Skills directory and destination Workspace.root/技能 before committing.
        let workspaceRoot = Workspace.root
        let liveSkills = workspaceRoot.appendingPathComponent("技能", isDirectory: true)
        if hasStagedSkills {
            try verifyNoSymlinks(under: skillsStaging, root: skillsStaging)
            if !manager.fileExists(atPath: workspaceRoot.path) {
                try manager.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
            }
            guard isRealDirectory(workspaceRoot) else {
                throw TeamError(message: "文件工作目录不是有效文件夹，无法恢复技能。")
            }
            if lstatExists(liveSkills) && !isRealDirectory(liveSkills) {
                throw TeamError(message: "现有技能目录包含链接或异常文件，已中止恢复。")
            }
        }

        // Verify and stage credentials before any restored settings become visible to a reader.
        let restoredKeys: [String: String]?
        if let item = items.last(where: { $0.path == "#keys" }) {
            do {
                restoredKeys = try JSONDecoder().decode([String: String].self, from: data.subdata(in: item.range))
            } catch {
                throw TeamError(message: "备份里的模型密钥读不出来，本机数据没有改动。")
            }
        } else {
            restoredKeys = nil
        }

        let stagedSettings = staging.appendingPathComponent("Team/settings.json")
        let wasFrozen = Disk.frozen
        Disk.frozen = true
        var committed = false
        defer { if !committed { Disk.frozen = wasFrozen } }
        ChatDisk.finishWrites()
        Disk.forgetPhotos()
        let previousEndpoints = Disk.load(TeamSettings.self, "settings.json")?.endpoints ?? []
        var preparedEndpoints: [Endpoint] = []
        var swappedTargets: [(live: URL, backup: URL?)] = []

        do {
            if manager.fileExists(atPath: stagedSettings.path) {
                var settings = try JSONDecoder().decode(TeamSettings.self, from: Data(contentsOf: stagedSettings))
                do {
                    preparedEndpoints = try TeamModel.prepareBackupServices(
                        previous: previousEndpoints, restored: settings.endpoints, keys: restoredKeys
                    )
                } catch {
                    throw TeamError(message: "没能保存备份里的模型服务密钥。请解锁手机后再试，原来的密钥还在。")
                }
                settings.endpoints = preparedEndpoints
                try JSONEncoder().encode(settings).write(
                    to: stagedSettings,
                    options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
                )
            } else if restoredKeys?.isEmpty == false {
                throw TeamError(message: "备份缺少模型服务设置，无法确认密钥应该用在哪个地址。")
            }

            try manager.createDirectory(at: old, withIntermediateDirectories: true)

            // 3. Atomic swap only after credentials, settings, and staged files are all verified.
            for folder in folders {
                let live = support.appendingPathComponent(folder, isDirectory: true)
                let fresh = staging.appendingPathComponent(folder, isDirectory: true)
                guard manager.fileExists(atPath: fresh.path) else { continue }
                let backup = old.appendingPathComponent(folder, isDirectory: true)
                let hadLive = lstatExists(live)
                if hadLive {
                    try manager.moveItem(at: live, to: backup)
                }
                swappedTargets.append((live: live, backup: hadLive ? backup : nil))
                try manager.moveItem(at: fresh, to: live)
            }

            if hasStagedSkills {
                let backupSkills = old.appendingPathComponent("Skills", isDirectory: true)
                let hadLiveSkills = lstatExists(liveSkills)
                if hadLiveSkills {
                    try manager.moveItem(at: liveSkills, to: backupSkills)
                }
                swappedTargets.append((live: liveSkills, backup: hadLiveSkills ? backupSkills : nil))
                try manager.moveItem(at: skillsStaging, to: liveSkills)
            }
        } catch {
            for entry in swappedTargets.reversed() {
                try? manager.removeItem(at: entry.live)
                if let backup = entry.backup, manager.fileExists(atPath: backup.path) {
                    try? manager.moveItem(at: backup, to: entry.live)
                }
            }
            if (try? manager.contentsOfDirectory(atPath: old.path))?.isEmpty == true {
                try? manager.removeItem(at: old)
            }
            TeamModel.discardCredentials(from: preparedEndpoints, keeping: previousEndpoints)
            throw TeamError(message: "恢复没成功（\(error.localizedDescription)），本地数据已经还原成原样。")
        }

        committed = true
        try? manager.removeItem(at: old)
        TeamModel.discardCredentials(from: previousEndpoints, keeping: preparedEndpoints)
        if hasStagedSkills {
            SkillShelf.invalidate()
        }

        // 4. Import UI preferences, now that the restored files are in.
        for item in items where item.path == "#settings" {
            let body = data.subdata(in: item.range)
            if let settings = try? PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any] {
                for (key, value) in settings where restorable.contains(where: { key.hasPrefix($0) }) {
                    UserDefaults.standard.set(value, forKey: key)
                }
                count += 1
            }
        }
        if restoredKeys != nil { count += 1 }
        return Summary(files: count, bytes: rawData.count)
    }

    // MARK: Security & filesystem helpers

    private static func lstatExists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFLNK
    }

    private static func isRealDirectory(_ url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFDIR
    }

    private static func isContained(_ url: URL, inside root: URL) -> Bool {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        let target = url.resolvingSymlinksInPath().standardizedFileURL.path
        return target == base || target.hasPrefix(base + "/")
    }

    private static func writeStagedFile(_ body: Data, to target: URL, root: URL) throws {
        let manager = FileManager.default
        let parent = target.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        guard isContained(parent, inside: root),
              !hasSymlinkComponent(from: root, to: target),
              isContained(target, inside: root) else {
            throw TeamError(message: "备份里存在越界或符号链接路径，已中止恢复。")
        }
        try body.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private static func hasSymlinkComponent(from root: URL, to target: URL) -> Bool {
        let rootStd = root.standardizedFileURL.path
        var current = target.standardizedFileURL
        while true {
            if isSymbolicLink(current) { return true }
            if current.path == rootStd || current.path == "/" { break }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return false
    }

    private static func verifyNoSymlinks(under directory: URL, root: URL) throws {
        guard isRealDirectory(directory), isContained(directory, inside: root) else {
            throw TeamError(message: "暂存的技能目录异常，已中止恢复。")
        }
        guard let walker = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey],
            options: []
        ) else {
            return
        }
        for case let entry as URL in walker {
            var st = stat()
            guard lstat(entry.path, &st) == 0 else {
                throw TeamError(message: "无法校验暂存技能文件，已中止恢复。")
            }
            let mode = st.st_mode & S_IFMT
            guard mode == S_IFREG || mode == S_IFDIR else {
                throw TeamError(message: "备份里的技能包含不支持的链接或特殊文件，已中止恢复。")
            }
            guard isContained(entry, inside: root) else {
                throw TeamError(message: "备份里的技能路径越界，已中止恢复。")
            }
        }
    }

    /// Removes any SQLite / WAL / SHM artifacts that should never stay inside `Team/` across restores
    /// while preserving `Team/secrets.json` (Vault metadata belongs exclusively to the local device).
    private static func stripDisallowedStagedArtifacts(in teamStaging: URL) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: teamStaging.path) else { return }
        guard let walker = manager.enumerator(
            at: teamStaging,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else { return }
        var toDelete: [URL] = []
        for case let entry as URL in walker {
            if BackupArchivePolicy.isSQLiteOrCacheArtifact(entry.lastPathComponent) {
                toDelete.append(entry)
            }
        }
        for item in toDelete {
            try? manager.removeItem(at: item)
        }
    }
}
