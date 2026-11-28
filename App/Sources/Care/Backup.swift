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

    struct RestoreFileOps {
        var moveItem: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
        var removeItem: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
        static let live = RestoreFileOps()
    }

    private struct RestoreJournal: Codable, Sendable {
        enum Phase: String, Codable, Sendable {
            case swapping
            case committed
        }

        var version: Int = 1
        var phase: Phase
        var swappedFolders: [String]
        var hadLiveFolders: [String]
        var swappedSkills: Bool
        var hadLiveSkills: Bool
        var workspaceRootPath: String
        var previousEndpoints: [Endpoint]
        var preparedEndpoints: [Endpoint]
    }

    private static let restoreJournalFileName = ".restore-journal.json"
    private static let startupReconcileLock = NSLock()
    nonisolated(unsafe) private static var startupReconcileErrorMessage: String?

    static var lastStartupRestoreRecoveryError: String? {
        startupReconcileLock.withLock { startupReconcileErrorMessage }
    }

    /// Runs crash recovery BEFORE any storage singleton (`Disk.root`, `SubtaskManager`, `CasualTrackController`)
    /// can create empty skeleton directories under `Team/`. Returns `false` if recovery failed and writes must stay frozen.
    @discardableResult
    static func reconcileInterruptedRestoreBeforeStorageInit(
        support supportOverride: URL? = nil,
        workspaceRoot workspaceRootOverride: URL? = nil,
        fileOps: RestoreFileOps = .live,
        discardCredentials: (([Endpoint], [Endpoint]) -> Void)? = nil
    ) -> Bool {
        let wsRoot = workspaceRootOverride
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        do {
            _ = try reconcileInterruptedRestoreIfNeeded(
                support: supportOverride,
                workspaceRoot: wsRoot,
                fileOps: fileOps,
                discardCredentials: discardCredentials
            )
            startupReconcileLock.withLock { startupReconcileErrorMessage = nil }
            return true
        } catch {
            startupReconcileLock.withLock { startupReconcileErrorMessage = error.localizedDescription }
            return false
        }
    }

    /// Returns `true` ONLY when `directory` contains at least one real regular file (not just empty skeleton folders
    /// such as `Team/chats`, `Team/media`, `Team/diary`, `Team/subtasks`, `Team/pending-questions`).
    /// Throws if directory enumeration fails so callers never treat an unreadable directory as empty or valid.
    private static func directoryHasSubstantiveFiles(_ directory: URL) throws -> Bool {
        let manager = FileManager.default
        guard lstatExists(directory) else { return false }
        guard isRealDirectory(directory) else { return true }
        let items = try manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: []
        )
        for item in items {
            var st = stat()
            guard lstat(item.path, &st) == 0 else { continue }
            let kind = st.st_mode & S_IFMT
            if kind == S_IFDIR {
                if try directoryHasSubstantiveFiles(item) {
                    return true
                }
            } else {
                return true
            }
        }
        return false
    }

    private static func writeRestoreJournal(_ journal: RestoreJournal, to url: URL) throws {
        let data = try JSONEncoder().encode(journal)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Cold-start and pre-restore crash reconciliation for interrupted directory swaps.
    /// Guarantees `.restore-old` is NEVER deleted if it is the sole surviving valid copy of user data,
    /// if `.restore-journal.json` is corrupt/unreadable, or if `live` only holds freshly created empty skeleton dirs.
    @discardableResult
    static func reconcileInterruptedRestoreIfNeeded(
        support supportOverride: URL? = nil,
        workspaceRoot workspaceRootOverride: URL? = nil,
        fileOps: RestoreFileOps = .live,
        discardCredentials: (([Endpoint], [Endpoint]) -> Void)? = nil
    ) throws -> Bool {
        let base = supportOverride ?? Self.support
        let wsRoot = workspaceRootOverride ?? Workspace.root
        let manager = FileManager.default
        let journalURL = base.appendingPathComponent(restoreJournalFileName)
        let old = base.appendingPathComponent(".restore-old", isDirectory: true)
        let staging = base.appendingPathComponent(".restore-staging", isDirectory: true)
        let cleanupCreds: ([Endpoint], [Endpoint]) -> Void = discardCredentials ?? { discarded, active in
            TeamModel.discardCredentials(from: discarded, keeping: active)
        }

        if manager.fileExists(atPath: journalURL.path) {
            let data: Data
            let journal: RestoreJournal
            do {
                data = try Data(contentsOf: journalURL)
                journal = try JSONDecoder().decode(RestoreJournal.self, from: data)
            } catch {
                // Corrupt or unreadable journal: NEVER fall through to delete `.restore-old`!
                throw TeamError(message: "上次恢复的状态日志损坏或无法读取，已保留原始备份目录以防丢失数据（\(error.localizedDescription)）。")
            }

            switch journal.phase {
            case .committed:
                if lstatExists(old) {
                    try fileOps.removeItem(old)
                }
                if lstatExists(staging) {
                    try? fileOps.removeItem(staging)
                }
                cleanupCreds(journal.previousEndpoints, journal.preparedEndpoints)
                if journal.swappedSkills {
                    SkillShelf.invalidate()
                }
                try? manager.removeItem(at: journalURL)
                return true

            case .swapping:
                var firstError: Error?
                if journal.swappedSkills {
                    let liveSkills = URL(fileURLWithPath: journal.workspaceRootPath, isDirectory: true)
                        .appendingPathComponent("技能", isDirectory: true)
                    let backupSkills = old.appendingPathComponent("Skills", isDirectory: true)
                    if journal.hadLiveSkills {
                        if lstatExists(backupSkills) {
                            do {
                                if lstatExists(liveSkills) { try fileOps.removeItem(liveSkills) }
                                try fileOps.moveItem(backupSkills, liveSkills)
                            } catch {
                                if firstError == nil { firstError = error }
                            }
                        }
                    } else if lstatExists(liveSkills) {
                        do {
                            try fileOps.removeItem(liveSkills)
                        } catch {
                            if firstError == nil { firstError = error }
                        }
                    }
                }

                for folder in journal.swappedFolders.reversed() {
                    let live = base.appendingPathComponent(folder, isDirectory: true)
                    let backup = old.appendingPathComponent(folder, isDirectory: true)
                    let hadLive = journal.hadLiveFolders.contains(folder)
                    if hadLive {
                        if lstatExists(backup) {
                            do {
                                if lstatExists(live) { try fileOps.removeItem(live) }
                                try fileOps.moveItem(backup, live)
                            } catch {
                                if firstError == nil { firstError = error }
                            }
                        }
                    } else if lstatExists(live) {
                        do {
                            try fileOps.removeItem(live)
                        } catch {
                            if firstError == nil { firstError = error }
                        }
                    }
                }

                if lstatExists(staging) {
                    try? fileOps.removeItem(staging)
                }
                cleanupCreds(journal.preparedEndpoints, journal.previousEndpoints)
                if let firstError {
                    throw firstError
                }
                if lstatExists(old) {
                    let remaining = try manager.contentsOfDirectory(atPath: old.path)
                    if remaining.isEmpty {
                        try fileOps.removeItem(old)
                    } else {
                        throw TeamError(message: "恢复目录回滚后仍有未还原文件，已保留原目录以保护数据。")
                    }
                }
                try? manager.removeItem(at: journalURL)
                return true
            }
        }

        guard lstatExists(old) else {
            if lstatExists(staging) {
                try? fileOps.removeItem(staging)
            }
            return false
        }

        // Legacy interrupted restore without a journal:
        // Recover any folder where `live` is missing OR only contains empty skeleton directories while `.restore-old` holds real files.
        var recoveredAny = false
        for folder in folders {
            let live = base.appendingPathComponent(folder, isDirectory: true)
            let backup = old.appendingPathComponent(folder, isDirectory: true)
            guard lstatExists(backup) else { continue }
            let liveHasFiles = try directoryHasSubstantiveFiles(live)
            let backupHasFiles = try directoryHasSubstantiveFiles(backup)
            if !liveHasFiles && backupHasFiles {
                if lstatExists(live) {
                    try fileOps.removeItem(live)
                }
                try fileOps.moveItem(backup, live)
                recoveredAny = true
            }
        }
        let liveSkills = wsRoot.appendingPathComponent("技能", isDirectory: true)
        let backupSkills = old.appendingPathComponent("Skills", isDirectory: true)
        if lstatExists(backupSkills) {
            let liveSkillsHasFiles = try directoryHasSubstantiveFiles(liveSkills)
            let backupSkillsHasFiles = try directoryHasSubstantiveFiles(backupSkills)
            if !liveSkillsHasFiles && backupSkillsHasFiles {
                if lstatExists(liveSkills) {
                    try fileOps.removeItem(liveSkills)
                }
                try fileOps.moveItem(backupSkills, liveSkills)
                recoveredAny = true
            }
        }

        // Only remove `.restore-old` when confirmed empty (all real backup dirs moved back or verified empty).
        // If non-empty folders remain without a committed journal, keep `.restore-old` intact!
        let remainingItems = try manager.contentsOfDirectory(atPath: old.path)
        var allRemainingAreEmpty = true
        for name in remainingItems {
            let itemURL = old.appendingPathComponent(name)
            if try directoryHasSubstantiveFiles(itemURL) {
                allRemainingAreEmpty = false
                break
            }
        }
        if allRemainingAreEmpty {
            try fileOps.removeItem(old)
        }
        if lstatExists(staging) {
            try? fileOps.removeItem(staging)
        }
        return recoveredAny
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
        let shouldEncrypt: Bool
        if let passphrase {
            guard !passphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BackupCryptoError.emptyPassphrase
            }
            shouldEncrypt = true
        } else if withKeys {
            throw BackupCryptoError.passphraseRequired
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

        var completed = false
        defer {
            if !completed {
                if !shouldEncrypt {
                    try? manager.removeItem(at: partial)
                }
                try? manager.removeItem(at: encryptedPartial)
            }
        }

        // Build the archive strictly in memory when encrypting so plaintext `#keys` never touch disk.
        var memoryPayload = Data()
        let out: FileHandle?
        if shouldEncrypt {
            out = nil
        } else {
            guard manager.createFile(atPath: partial.path, contents: nil, attributes: protection) else {
                throw TeamError(message: "没能在手机上建备份文件。")
            }
            out = try FileHandle(forWritingTo: partial)
        }
        var outClosed = false
        defer {
            if !outClosed {
                try? out?.close()
            }
        }

        if let out {
            try out.write(contentsOf: magic)
        } else {
            memoryPayload.append(magic)
        }
        var count = 0
        var bytes = magic.count
        var unreadable: [String] = []

        func add(_ path: String, _ data: Data) throws {
            let name = Data(path.utf8)
            let headerAndNameCount = 12 + name.count
            guard data.count <= maxBackupFileBytes - bytes,
                  headerAndNameCount <= maxBackupFileBytes - bytes - data.count else {
                throw TeamError(message: "备份内容太大，超过安全体积上限，没打包成。")
            }
            var nameLength = UInt32(name.count).bigEndian
            var dataLength = UInt64(data.count).bigEndian
            if let out {
                try out.write(contentsOf: Data(bytes: &nameLength, count: 4))
                try out.write(contentsOf: name)
                try out.write(contentsOf: Data(bytes: &dataLength, count: 8))
                try out.write(contentsOf: data)
            } else {
                withUnsafeBytes(of: &nameLength) { memoryPayload.append(contentsOf: $0) }
                memoryPayload.append(name)
                withUnsafeBytes(of: &dataLength) { memoryPayload.append(contentsOf: $0) }
                memoryPayload.append(data)
            }
            bytes += headerAndNameCount + data.count
            count += 1
        }

        var archivedEndpoints: [Endpoint]?
        let supportReal = support.resolvingSymlinksInPath().standardizedFileURL.path
        func packFolder(_ folder: String) throws {
            let base = support.appendingPathComponent(folder, isDirectory: true)
            guard isRealDirectory(base) else { return }
            guard let walker = manager.enumerator(
                at: base,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey],
                options: []
            ) else { return }
            for case let file as URL in walker {
                var st = stat()
                guard lstat(file.path, &st) == 0 else { continue }
                let mode = st.st_mode & S_IFMT
                if mode == S_IFLNK {
                    walker.skipDescendants()
                    continue
                }
                if file.lastPathComponent.hasPrefix(".") || DeskTrash.isReservedName(file.lastPathComponent) {
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

        for folder in folders {
            if folder == "Team" {
                try MemoryStoreBridge.shared.withBackupBarrier {
                    try packFolder(folder)
                }
            } else {
                try packFolder(folder)
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
                    if file.lastPathComponent.hasPrefix(".") || DeskTrash.isReservedName(file.lastPathComponent) {
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

        if let out {
            try out.synchronize()
            try out.close()
            outClosed = true
        }

        if shouldEncrypt {
            guard let passphrase else { throw BackupCryptoError.passphraseRequired }
            let encryptedArchive = try BackupCrypto.encrypt(payload: memoryPayload, passphrase: passphrase)
            memoryPayload.removeAll(keepingCapacity: false)
            guard manager.createFile(atPath: encryptedPartial.path, contents: nil, attributes: protection) else {
                throw TeamError(message: "没能在手机上建加密备份文件。")
            }
            try encryptedArchive.write(to: encryptedPartial, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
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
    /// 2. reconciles any interrupted prior restore, freezes and drains all writers, and stages copies off to the side;
    /// 3. swaps staged directories under a persisted `.restore-journal.json` state machine;
    /// 4. cleans old copies/credentials and applies settings only once the swap is durably committed.
    static func restore(from url: URL, passphrase: String? = nil) throws -> Summary {
        try restore(
            from: url,
            passphrase: passphrase,
            support: nil,
            workspaceRoot: nil,
            fileOps: .live,
            skipGlobalBridges: false
        )
    }

    static func restore(
        from url: URL,
        passphrase: String? = nil,
        support supportOverride: URL?,
        workspaceRoot workspaceRootOverride: URL?,
        fileOps: RestoreFileOps = .live,
        skipGlobalBridges: Bool = false
    ) throws -> Summary {
        if !skipGlobalBridges { ChatDisk.finishWrites() }
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

        let wasEncrypted = BackupCrypto.isEncrypted(rawData)
        let data: Data
        if wasEncrypted {
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
            if !path.hasPrefix("#"), !isTrashArchivePath(path), !BackupArchivePolicy.isExcludedArchivePath(path), path.hasPrefix("Skills/") {
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

        if !wasEncrypted && items.contains(where: { $0.path == "#keys" }) {
            throw TeamError(message: "为了保护密钥安全，不能从未加密备份里导入模型密钥。请改用加密备份，或在重新导出时不勾选密钥。")
        }

        // Verify `#keys` payload in memory before freezing writers or touching disk.
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

        // 2. Freeze and drain ALL live writers BEFORE reconciling prior interrupted restores,
        // copying live folders, or swapping directories.
        let baseSupport = supportOverride ?? Self.support
        let workspaceRoot = workspaceRootOverride ?? Workspace.root
        let manager = FileManager.default
        let staging = baseSupport.appendingPathComponent(".restore-staging", isDirectory: true)
        let old = baseSupport.appendingPathComponent(".restore-old", isDirectory: true)
        let journalURL = baseSupport.appendingPathComponent(restoreJournalFileName)

        let wasFrozen = Disk.frozen
        if !skipGlobalBridges {
            Disk.frozen = true
        }
        var committed = false
        var keepFrozenOnExit = false
        defer {
            if !skipGlobalBridges && !committed && !keepFrozenOnExit {
                Disk.frozen = wasFrozen
            }
        }
        if !skipGlobalBridges {
            ChatDisk.finishWrites()
            Disk.withWriteBarrier {}
            Disk.forgetPhotos()
            SubtaskManager.sharedCanonicalStore.withWriteBarrier {}
            CasualTrackController.sharedStore.withWriteBarrier {}
            SubConversationStore.withBackupBarrier {}
            try? MemoryStoreBridge.shared.withBackupBarrier {}
        }

        do {
            _ = try reconcileInterruptedRestoreIfNeeded(
                support: baseSupport,
                workspaceRoot: workspaceRoot,
                fileOps: fileOps,
                discardCredentials: skipGlobalBridges ? { _, _ in } : nil
            )
        } catch {
            keepFrozenOnExit = true
            throw TeamError(message: "上次中断的恢复尚未完成还原（\(error.localizedDescription)），已中止本次恢复并冻结写入以保护原数据。")
        }
        if lstatExists(old) {
            keepFrozenOnExit = true
            throw TeamError(message: "检测到未清理的旧恢复目录，无法确认它是否仍是唯一数据副本，已中止本次恢复并冻结写入以保护原数据。")
        }

        try? fileOps.removeItem(staging)
        defer { try? fileOps.removeItem(staging) }
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)

        for folder in folders {
            let live = baseSupport.appendingPathComponent(folder, isDirectory: true)
            if isSymbolicLink(live) {
                throw TeamError(message: "本地数据目录异常（包含符号链接），已中止恢复。")
            }
            if manager.fileExists(atPath: live.path) {
                guard isRealDirectory(live) else {
                    throw TeamError(message: "本地数据目录不是有效文件夹，已中止恢复。")
                }
                let stagedFolder = staging.appendingPathComponent(folder, isDirectory: true)
                try manager.copyItem(at: live, to: stagedFolder)
                try stripStagedTrashArtifacts(in: stagedFolder)
                try verifyNoSymlinks(under: stagedFolder, root: staging)
            }
        }
        var strippedStagedMounts = stripDisallowedStagedArtifacts(in: staging.appendingPathComponent("Team", isDirectory: true))
        let archiveContainedMounts = items.contains { $0.path.lowercased() == "team/mounts.json" }

        let skillsStaging = staging.appendingPathComponent("Skills.staging", isDirectory: true)
        var hasStagedSkills = false
        var count = 0

        for item in items where !item.path.hasPrefix("#") {
            guard !isTrashArchivePath(item.path), !BackupArchivePolicy.isExcludedArchivePath(item.path),
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

        let stagedTeam = staging.appendingPathComponent("Team", isDirectory: true)
        if stripDisallowedStagedArtifacts(in: stagedTeam) {
            strippedStagedMounts = true
        }

        // Verify staged Skills directory and destination Workspace.root/技能 before committing.
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

        let stagedSettings = staging.appendingPathComponent("Team/settings.json")
        let liveTeam = baseSupport.appendingPathComponent("Team", isDirectory: true)
        let previousEndpoints: [Endpoint]
        if skipGlobalBridges {
            let liveSettingsURL = liveTeam.appendingPathComponent("settings.json")
            if let liveData = try? Data(contentsOf: liveSettingsURL),
               let liveSettings = try? JSONDecoder().decode(TeamSettings.self, from: liveData) {
                previousEndpoints = liveSettings.endpoints
            } else {
                previousEndpoints = []
            }
        } else {
            previousEndpoints = Disk.load(TeamSettings.self, "settings.json")?.endpoints ?? []
        }
        var preparedEndpoints: [Endpoint] = []
        var swappedTargets: [(live: URL, backup: URL?)] = []
        var journalWritten = false
        var journal = RestoreJournal(
            phase: .swapping,
            swappedFolders: [],
            hadLiveFolders: [],
            swappedSkills: false,
            hadLiveSkills: false,
            workspaceRootPath: workspaceRoot.path,
            previousEndpoints: previousEndpoints,
            preparedEndpoints: []
        )

        do {
            // Drain all live memory/experience writers inside the barrier while `Disk.frozen == true`,
            // then capture final local tombstones and apply atomic tombstone union before swap.
            let localRetractedHashes: Set<String>
            if skipGlobalBridges {
                localRetractedHashes = try collectLocalRetractedHashes(in: liveTeam, memoryStoreTombstones: [])
            } else {
                localRetractedHashes = try MemoryStoreBridge.shared.withBackupBarrier {
                    try collectLocalRetractedHashes(
                        in: liveTeam,
                        memoryStoreTombstones: MemoryStoreBridge.shared.tombstoneHashesSnapshot()
                    )
                }
            }
            try applyTombstoneUnionToStagedTeam(stagedTeam: stagedTeam, localRetractedHashes: localRetractedHashes)

            // Never let restored Casual Track outbox batches auto-dispatch on next open.
            _ = try CasualTrackStore.demoteRestoredOutboxBatches(in: stagedTeam)

            if manager.fileExists(atPath: stagedSettings.path) {
                var settings = try JSONDecoder().decode(TeamSettings.self, from: Data(contentsOf: stagedSettings))
                if skipGlobalBridges {
                    preparedEndpoints = settings.endpoints
                } else {
                    do {
                        preparedEndpoints = try TeamModel.prepareBackupServices(
                            previous: previousEndpoints, restored: settings.endpoints, keys: restoredKeys
                        )
                    } catch {
                        throw TeamError(message: "没能保存备份里的模型服务密钥。请解锁手机后再试，原来的密钥还在。")
                    }
                }
                settings.endpoints = preparedEndpoints.map { endpoint in
                    var validated = endpoint
                    // Manual thinking rules restored from backup must revalidate against the restored
                    // `(origin, protocol, route, model)` contract before being activated.
                    validated.revalidateManualThinkingRules()
                    return validated
                }
                // An older backup must not re-enable a permission revoked on this device.
                settings.clearOutboundConsents()
                try JSONEncoder().encode(settings).write(
                    to: stagedSettings,
                    options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
                )
            } else if restoredKeys?.isEmpty == false {
                throw TeamError(message: "备份缺少模型服务设置，无法确认密钥应该用在哪个地址。")
            }

            journal.preparedEndpoints = preparedEndpoints
            try manager.createDirectory(at: old, withIntermediateDirectories: true)
            try writeRestoreJournal(journal, to: journalURL)
            journalWritten = true

            // 3. Crash-recoverable swap only after credentials, settings, and staged files are all verified.
            for folder in folders {
                let live = baseSupport.appendingPathComponent(folder, isDirectory: true)
                let fresh = staging.appendingPathComponent(folder, isDirectory: true)
                guard manager.fileExists(atPath: fresh.path) else { continue }
                let backup = old.appendingPathComponent(folder, isDirectory: true)
                let hadLive = lstatExists(live)
                journal.swappedFolders.append(folder)
                if hadLive { journal.hadLiveFolders.append(folder) }
                try writeRestoreJournal(journal, to: journalURL)
                if hadLive {
                    try fileOps.moveItem(live, backup)
                }
                swappedTargets.append((live: live, backup: hadLive ? backup : nil))
                try fileOps.moveItem(fresh, live)
            }

            if hasStagedSkills {
                let backupSkills = old.appendingPathComponent("Skills", isDirectory: true)
                let hadLiveSkills = lstatExists(liveSkills)
                journal.swappedSkills = true
                journal.hadLiveSkills = hadLiveSkills
                try writeRestoreJournal(journal, to: journalURL)
                if hadLiveSkills {
                    try fileOps.moveItem(liveSkills, backupSkills)
                }
                swappedTargets.append((live: liveSkills, backup: hadLiveSkills ? backupSkills : nil))
                try fileOps.moveItem(skillsStaging, liveSkills)
            }

            // Persist committed phase BEFORE removing `.restore-old` or old credential slots.
            journal.phase = .committed
            try writeRestoreJournal(journal, to: journalURL)
        } catch {
            var rollbackClean = true
            for entry in swappedTargets.reversed() {
                if let backup = entry.backup {
                    if lstatExists(backup) {
                        do {
                            if lstatExists(entry.live) {
                                try fileOps.removeItem(entry.live)
                            }
                            try fileOps.moveItem(backup, entry.live)
                        } catch {
                            rollbackClean = false
                        }
                    } else if !lstatExists(entry.live) {
                        rollbackClean = false
                    }
                } else if lstatExists(entry.live) {
                    do {
                        try fileOps.removeItem(entry.live)
                    } catch {
                        rollbackClean = false
                    }
                }
            }
            if !skipGlobalBridges {
                TeamModel.discardCredentials(from: preparedEndpoints, keeping: previousEndpoints)
            }
            if rollbackClean {
                if (try? manager.contentsOfDirectory(atPath: old.path))?.isEmpty == true {
                    try? fileOps.removeItem(old)
                }
                if journalWritten {
                    try? manager.removeItem(at: journalURL)
                }
                throw TeamError(message: "恢复没成功（\(error.localizedDescription)），本地数据已经还原成原样。")
            } else {
                // Rollback incomplete: keep writes frozen AND keep `.restore-journal.json` + `.restore-old` intact!
                keepFrozenOnExit = true
                if !skipGlobalBridges {
                    Disk.frozen = true
                }
                throw TeamError(message: "恢复中断且自动回滚未能完整完成（\(error.localizedDescription)）。已冻结写入并保留原数据目录，请重新打开 Clio 自动还原。")
            }
        }

        committed = true
        try? fileOps.removeItem(old)
        if !skipGlobalBridges {
            TeamModel.discardCredentials(from: previousEndpoints, keeping: preparedEndpoints)
            if hasStagedSkills {
                SkillShelf.invalidate()
            }
        }
        if !lstatExists(old) {
            try? manager.removeItem(at: journalURL)
        }

        // 4. Import UI preferences, now that the restored files are in.
        if !skipGlobalBridges {
            for item in items where item.path == "#settings" {
                let body = data.subdata(in: item.range)
                if let settings = try? PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any] {
                    for (key, value) in settings where restorable.contains(where: { key.hasPrefix($0) }) {
                        UserDefaults.standard.set(value, forKey: key)
                    }
                    count += 1
                }
            }
            if archiveContainedMounts || strippedStagedMounts {
                UserDefaults.standard.set(true, forKey: "chat.backupStrippedMounts")
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
        guard isRealDirectory(root),
              isContained(parent, inside: root),
              isContained(target, inside: root),
              !hasSymlinkOrInvalidAncestor(from: root, to: parent),
              !isSymbolicLink(target),
              !isRealDirectory(target) else {
            throw TeamError(message: "备份里存在越界或符号链接路径，已中止恢复。")
        }
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        guard isRealDirectory(parent),
              isContained(parent, inside: root),
              !hasSymlinkOrInvalidAncestor(from: root, to: parent),
              !isSymbolicLink(target),
              !isRealDirectory(target),
              isContained(target, inside: root) else {
            throw TeamError(message: "备份里存在越界或符号链接路径，已中止恢复。")
        }
        try body.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private static func hasSymlinkOrInvalidAncestor(from root: URL, to targetDirectory: URL) -> Bool {
        let rootStd = root.standardizedFileURL.path
        var current = targetDirectory.standardizedFileURL
        while true {
            if isSymbolicLink(current) { return true }
            if lstatExists(current) && (!isRealDirectory(current) || !isContained(current, inside: root)) {
                return true
            }
            if current.path == rootStd || current.path == "/" { break }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return false
    }

    private static func verifyNoSymlinks(under directory: URL, root: URL) throws {
        guard isRealDirectory(directory), isContained(directory, inside: root) else {
            throw TeamError(message: "暂存的恢复目录异常，已中止恢复。")
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
                throw TeamError(message: "无法校验暂存恢复文件，已中止恢复。")
            }
            let mode = st.st_mode & S_IFMT
            guard mode == S_IFREG || mode == S_IFDIR else {
                throw TeamError(message: "恢复目录包含不支持的链接或特殊文件，已中止恢复。")
            }
            guard isContained(entry, inside: root) else {
                throw TeamError(message: "恢复目录路径越界，已中止恢复。")
            }
        }
    }

    private static func isTrashArchivePath(_ path: String) -> Bool {
        path.split(separator: "/").contains { DeskTrash.isReservedName(String($0)) }
    }

    /// Removes device-local trash from staged copies before any restored data can become live.
    static func stripStagedTrashArtifacts(in root: URL) throws {
        let manager = FileManager.default
        guard let walker = manager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ) else { return }
        var artifacts: [URL] = []
        for case let entry as URL in walker {
            if DeskTrash.isReservedName(entry.lastPathComponent) {
                if let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                   values.isDirectory == true,
                   values.isSymbolicLink != true {
                    walker.skipDescendants()
                }
                artifacts.append(entry)
            }
        }
        for artifact in artifacts { try manager.removeItem(at: artifact) }
    }

    /// Removes any SQLite / WAL / SHM artifacts, journal files, device-local trash, or mount tables (`mounts.json`)
    /// that should never stay inside `Team/` across restores while preserving `Team/secrets.json`
    /// (Vault metadata belongs exclusively to the local device) and `Team/experiences.json` / `Team/memory-revisions/rev-*.json`.
    @discardableResult
    static func stripDisallowedStagedArtifacts(in teamStaging: URL) -> Bool {
        let manager = FileManager.default
        guard manager.fileExists(atPath: teamStaging.path) else { return false }
        let mountsURL = teamStaging.appendingPathComponent("mounts.json")
        var strippedMounts = manager.fileExists(atPath: mountsURL.path)
        var toDelete: [URL] = []
        if let walker = manager.enumerator(
            at: teamStaging,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) {
            for case let entry as URL in walker {
                let name = entry.lastPathComponent.lowercased()
                if name == "mounts.json" {
                    strippedMounts = true
                    toDelete.append(entry)
                } else if DeskTrash.isReservedName(name) {
                    if let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                       values.isDirectory == true,
                       values.isSymbolicLink != true {
                        walker.skipDescendants()
                    }
                    toDelete.append(entry)
                } else if BackupArchivePolicy.isSQLiteOrCacheArtifact(entry.lastPathComponent) {
                    toDelete.append(entry)
                }
            }
        }
        for item in toDelete {
            try? manager.removeItem(at: item)
        }
        return strippedMounts
    }

    /// Collects retracted/tombstoned SHA-256 digests from the live device before swapping in a restored backup.
    /// Throws if any existing tombstone/memory/experience file is unreadable or corrupt so deletions can never be dropped silently.
    static func collectLocalRetractedHashes(
        in liveTeam: URL,
        memoryStoreTombstones: Set<String>
    ) throws -> Set<String> {
        let fm = FileManager.default
        var hashes = Set(MemorySafety.normalizedRetractionHashes(Array(memoryStoreTombstones)))

        let retractedURL = liveTeam.appendingPathComponent("memory-retracted.json")
        if fm.fileExists(atPath: retractedURL.path) {
            let data = try Data(contentsOf: retractedURL)
            let list = try JSONDecoder().decode([String].self, from: data)
            hashes.formUnion(MemorySafety.normalizedRetractionHashes(list))
        }

        let expURL = liveTeam.appendingPathComponent("experiences.json")
        if fm.fileExists(atPath: expURL.path) {
            let data = try Data(contentsOf: expURL)
            let expBook = try JSONDecoder().decode(CanonicalExperienceBook.self, from: data)
            hashes.formUnion(MemorySafety.normalizedRetractionHashes(expBook.retractedHashes))
            for record in expBook.records where record.deletedAtMs != nil {
                let hash = record.contentSHA256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if MemorySafety.isSHA256Hex(hash) { hashes.insert(hash) }
            }
        }

        let memoryURL = liveTeam.appendingPathComponent("memory.json")
        if fm.fileExists(atPath: memoryURL.path) {
            let data = try Data(contentsOf: memoryURL)
            let book = try CanonicalMemoryBook.decodeFlexible(from: data)
            hashes.formUnion(MemorySafety.normalizedRetractionHashes(book.suppressedFlushHashes))
            for ts in book.tombstones {
                let hash = ts.textSHA256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if MemorySafety.isSHA256Hex(hash) { hashes.insert(hash) }
            }
        }

        return hashes
    }

    /// Unions local retracted/tombstone hashes into the staged restore directory so a restored older archive
    /// can never resurrect facts or experiences deleted on this device. Always validates existing staged ledgers
    /// and fails cleanly before swap if any staged JSON cannot be read, decoded, or updated.
    static func applyTombstoneUnionToStagedTeam(
        stagedTeam: URL,
        localRetractedHashes: Set<String>,
        nowMs: Double = Now.ms
    ) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: stagedTeam.path) else { return }

        var mergedHashes = Set(MemorySafety.normalizedRetractionHashes(Array(localRetractedHashes)))

        let stagedRetractedURL = stagedTeam.appendingPathComponent("memory-retracted.json")
        if fm.fileExists(atPath: stagedRetractedURL.path) {
            let existingData = try Data(contentsOf: stagedRetractedURL)
            let existingList = try JSONDecoder().decode([String].self, from: existingData)
            mergedHashes.formUnion(MemorySafety.normalizedRetractionHashes(existingList))
        }

        let stagedMemoryURL = stagedTeam.appendingPathComponent("memory.json")
        var decodedMemBook: CanonicalMemoryBook?
        if fm.fileExists(atPath: stagedMemoryURL.path) {
            let memData = try Data(contentsOf: stagedMemoryURL)
            let book = try CanonicalMemoryBook.decodeFlexible(from: memData)
            mergedHashes.formUnion(MemorySafety.normalizedRetractionHashes(book.suppressedFlushHashes))
            for ts in book.tombstones {
                let hash = ts.textSHA256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if MemorySafety.isSHA256Hex(hash) { mergedHashes.insert(hash) }
            }
            decodedMemBook = book
        }

        let stagedExpURL = stagedTeam.appendingPathComponent("experiences.json")
        var decodedExpBook: CanonicalExperienceBook?
        if fm.fileExists(atPath: stagedExpURL.path) {
            let expData = try Data(contentsOf: stagedExpURL)
            let expBook = try JSONDecoder().decode(CanonicalExperienceBook.self, from: expData)
            mergedHashes.formUnion(MemorySafety.normalizedRetractionHashes(expBook.retractedHashes))
            for record in expBook.records where record.deletedAtMs != nil {
                let hash = record.contentSHA256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if MemorySafety.isSHA256Hex(hash) { mergedHashes.insert(hash) }
            }
            decodedExpBook = expBook
        }

        guard !mergedHashes.isEmpty else { return }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let encodedRetracted = try encoder.encode(mergedHashes.sorted())
        try encodedRetracted.write(to: stagedRetractedURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])

        if let decodedMemBook {
            let pruned = MemoryRevisionStore.applyTombstoneUnion(
                to: decodedMemBook,
                retractedHashes: mergedHashes,
                minimumGeneration: decodedMemBook.generation,
                nowMs: nowMs
            )
            let encodedMem = try encoder.encode(pruned)
            try encodedMem.write(to: stagedMemoryURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }

        if var expBook = decodedExpBook {
            expBook.mergeRetractionsAndPrune(hashes: mergedHashes, nowMs: nowMs)
            let encodedExp = try encoder.encode(expBook)
            try encodedExp.write(to: stagedExpURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }
}
