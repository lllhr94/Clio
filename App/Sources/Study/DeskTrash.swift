import Darwin
import Foundation

/// Device-local index and same-volume trash payloads. All index changes and moves share one lock.
final class DeskTrash: @unchecked Sendable {
    static let directoryName = ".trash"
    static let indexName = "trash-index.json"
    static let retention: TimeInterval = 30 * 24 * 60 * 60
    static let shared = DeskTrash(
        deskRoot: Workspace.root,
        indexURL: Disk.root.deletingLastPathComponent().appendingPathComponent(indexName)
    )

    enum Failure: LocalizedError, Equatable {
        case unavailable, offline, rootChanged, itemChanged, badPath, destinationMissing, expired
        case collision, crossVolume, readOnly, operationFailed

        var errorDescription: String? {
            let key: String
            switch self {
            case .unavailable: key = "files.trashUnavailable"
            case .offline: key = "files.trashOffline"
            case .rootChanged: key = "files.trashRootChanged"
            case .itemChanged: key = "files.trashItemChanged"
            case .badPath: key = "files.trashBadPath"
            case .destinationMissing: key = "files.trashDestinationMissing"
            case .expired: key = "files.trashExpired"
            case .collision: key = "files.trashCollision"
            case .crossVolume: key = "files.trashCrossVolume"
            case .readOnly: key = "files.trashReadOnly"
            case .operationFailed: key = "files.trashOperationFailed"
            }
            return L.t(key)
        }
    }

    struct Identity: Codable, Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
        let birthSeconds: Int
        let birthNanoseconds: Int
        let kind: mode_t

        fileprivate init(_ information: stat) {
            device = information.st_dev
            inode = information.st_ino
            birthSeconds = information.st_birthtimespec.tv_sec
            birthNanoseconds = information.st_birthtimespec.tv_nsec
            kind = information.st_mode & S_IFMT
        }
    }

    struct Record: Codable, Identifiable, Sendable {
        let id: UUID
        let rootPath: String
        let rootIdentity: Identity
        let mountID: String?
        let mountName: String?
        let relativePath: String
        let itemIdentity: Identity
        let deletedAt: Date

        var isFolder: Bool { itemIdentity.kind == S_IFDIR }
    }

    private let deskRoot: URL
    private let indexURL: URL
    private let lock = NSLock()

    init(deskRoot: URL, indexURL: URL) {
        self.deskRoot = deskRoot
        self.indexURL = indexURL
    }

    static func isReservedName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower == directoryName || lower == indexName
    }

    /// Lexical path components preserve the original name and never follow a symlink into trash.
    static func relativePath(of item: URL, in root: URL) throws -> String {
        let base = root.standardizedFileURL.path
        let path = item.standardizedFileURL.path
        guard path.hasPrefix(base + "/") else { throw Failure.badPath }
        return String(path.dropFirst(base.count + 1))
    }

    /// Resolves the current mount with a fresh security scope for the duration of the move.
    func move(deskItem: URL, now: Date = Date()) throws -> Record {
        try move(root: deskRoot, relativePath: Self.relativePath(of: deskItem, in: deskRoot), now: now)
    }

    func move(mount: MountedFolder, relativePath: String, expectedRoot: URL? = nil, now: Date = Date()) throws -> Record {
        do {
            return try MountedFolders.withAccess(mount) { root, _ in
                if let expectedRoot, root.standardizedFileURL.path != expectedRoot.standardizedFileURL.path {
                    throw Failure.rootChanged
                }
                return try move(root: root, mount: mount, relativePath: relativePath, now: now)
            }
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.offline
        }
    }

    /// Both directory descriptors are held across the rename. No path lookup can redirect the
    /// source parent or destination trash directory through a replaced symlink.
    func move(root: URL, mount: MountedFolder? = nil, relativePath: String, now: Date = Date()) throws -> Record {
        try lock.withLock {
            var records = try loadIndex()
            try purgeExpired(&records, now: now)
            let parts = try Self.parts(of: relativePath)
            return try Self.withRoot(root) { rootURL, rootFD, rootIdentity in
                try Self.withParent(parts, from: rootFD) { parentFD, name in
                    guard let item = try Self.identity(at: parentFD, name: name) else { throw Failure.itemChanged }
                    guard item.device == rootIdentity.device else { throw Failure.crossVolume }
                    let record = Record(
                        id: UUID(), rootPath: rootURL.path, rootIdentity: rootIdentity, mountID: mount?.id,
                        mountName: mount?.name, relativePath: relativePath, itemIdentity: item, deletedAt: now
                    )
                    if mkdirat(rootFD, Self.directoryName, 0o700) != 0, errno != EEXIST {
                        throw Self.failure(for: errno)
                    }
                    return try Self.withDirectory(Self.directoryName, in: rootFD) { trashFD in
                        guard try Self.identity(of: trashFD).device == item.device else { throw Failure.crossVolume }
                        records.append(record)
                        // If the app is interrupted after rename, the record is already on disk.
                        try saveIndex(records)
                        do {
                            try Self.rename(from: parentFD, name: name, to: trashFD, name: record.id.uuidString)
                        } catch {
                            records.removeLast()
                            try? saveIndex(records)
                            throw error
                        }
                        return record
                    }
                }
            }
        }
    }

    func entries(now: Date = Date()) throws -> [Record] {
        try lock.withLock {
            var records = try loadIndex()
            try purgeExpired(&records, now: now)
            return records.sorted { $0.deletedAt > $1.deletedAt }
        }
    }

    func restore(id: UUID, now: Date = Date()) throws {
        try lock.withLock {
            var records = try loadIndex()
            guard let record = records.first(where: { $0.id == id }) else { throw Failure.itemChanged }
            try purgeExpired(&records, now: now)
            guard now.timeIntervalSince(record.deletedAt) < Self.retention else { throw Failure.expired }
            let parts = try Self.parts(of: record.relativePath)
            try withRecordedRoot(record) { _, rootFD in
                try Self.withDirectory(Self.directoryName, in: rootFD, missing: .itemChanged) { trashFD in
                    let name = record.id.uuidString
                    guard try Self.identity(at: trashFD, name: name) == record.itemIdentity else {
                        throw Failure.itemChanged
                    }
                    try Self.withParent(parts, from: rootFD, missing: .destinationMissing) { parentFD, original in
                        try Self.rename(from: trashFD, name: name, to: parentFD, name: original)
                    }
                }
            }
            // The rename has succeeded. If cleaning up the index fails, the file remains restored.
            records.removeAll { $0.id == id }
            try? saveIndex(records)
        }
    }

    func empty() throws {
        try lock.withLock {
            let records = try loadIndex()
            var kept: [Record] = []
            var firstError: Error?
            for record in records {
                do { try removePayload(record) }
                catch {
                    kept.append(record)
                    if firstError == nil { firstError = error }
                }
            }
            if kept.count != records.count { try saveIndex(kept) }
            if let firstError { throw firstError }
        }
    }

    private func purgeExpired(_ records: inout [Record], now: Date) throws {
        let originalCount = records.count
        records.removeAll { record in
            guard now.timeIntervalSince(record.deletedAt) >= Self.retention else { return false }
            // Keep offline or changed roots indexed, so a later access can retry expiry safely.
            return (try? removePayload(record)) != nil
        }
        if records.count != originalCount { try saveIndex(records) }
    }

    private func withRecordedRoot<T>(_ record: Record, body: (URL, Int32) throws -> T) throws -> T {
        func check(_ root: URL) throws -> T {
            try Self.withRoot(root) { url, fd, identity in
                guard url.path == record.rootPath, identity == record.rootIdentity else { throw Failure.rootChanged }
                return try body(url, fd)
            }
        }

        guard let mountID = record.mountID else { return try check(deskRoot) }
        guard let mount = MountedFolders.all().first(where: { $0.id == mountID }) else { throw Failure.offline }
        do {
            return try MountedFolders.withAccess(mount) { root, _ in try check(root) }
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.offline
        }
    }

    private func removePayload(_ record: Record) throws {
        try withRecordedRoot(record) { _, rootFD in
            guard let directory = try Self.identity(at: rootFD, name: Self.directoryName) else { return }
            guard directory.kind == S_IFDIR else { throw Failure.badPath }
            try Self.withDirectory(Self.directoryName, in: rootFD) { trashFD in
                let name = record.id.uuidString
                guard let item = try Self.identity(at: trashFD, name: name) else { return }
                guard item == record.itemIdentity else { throw Failure.itemChanged }
                try Self.removeTree(in: trashFD, name: name, known: item)
            }
        }
    }

    private func loadIndex() throws -> [Record] {
        guard !Disk.frozen else { throw Failure.unavailable }
        var information = stat()
        if lstat(indexURL.path, &information) != 0 {
            if errno == ENOENT { return [] }
            throw Failure.unavailable
        }
        guard information.st_mode & S_IFMT == S_IFREG else { throw Failure.unavailable }
        do {
            return try JSONDecoder().decode([Record].self, from: Data(contentsOf: indexURL))
        } catch {
            throw Failure.unavailable
        }
    }

    private func saveIndex(_ records: [Record]) throws {
        guard !Disk.frozen else { throw Failure.unavailable }
        do {
            let data = try JSONEncoder().encode(records)
            try data.write(to: indexURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            throw Failure.unavailable
        }
    }

    private static func parts(of path: String) throws -> [String] {
        let parts = path.components(separatedBy: "/")
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") && !isReservedName($0) }) else {
            throw Failure.badPath
        }
        return parts
    }

    private static func withRoot<T>(_ url: URL, body: (URL, Int32, Identity) throws -> T) throws -> T {
        let original = url.standardizedFileURL
        var information = stat()
        guard lstat(original.path, &information) == 0 else { throw Failure.offline }
        guard information.st_mode & S_IFMT == S_IFDIR else { throw Failure.rootChanged }
        let identity = Identity(information)
        let real = original.resolvingSymlinksInPath().standardizedFileURL
        return try withDirectory(real.path, missing: .offline) { fd in
            guard try Self.identity(of: fd) == identity else { throw Failure.rootChanged }
            return try body(real, fd, identity)
        }
    }

    private static func withDirectory<T>(
        _ name: String, in parent: Int32 = AT_FDCWD, missing: Failure = .badPath, body: (Int32) throws -> T
    ) throws -> T {
        let fd = try openDirectory(name, in: parent, missing: missing)
        defer { close(fd) }
        return try body(fd)
    }

    private static func withParent<T>(
        _ parts: [String], from rootFD: Int32, missing: Failure = .badPath, body: (Int32, String) throws -> T
    ) throws -> T {
        var parentFD = rootFD
        defer { if parentFD != rootFD { close(parentFD) } }
        for part in parts.dropLast() {
            let childFD = try openDirectory(part, in: parentFD, missing: missing)
            if parentFD != rootFD { close(parentFD) }
            parentFD = childFD
        }
        return try body(parentFD, parts[parts.count - 1])
    }

    private static func openDirectory(_ name: String, in parent: Int32, missing: Failure) throws -> Int32 {
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            let code = errno
            if code == ENOENT { throw missing }
            if code == ENOTDIR || code == ELOOP { throw Failure.badPath }
            throw failure(for: code)
        }
        return fd
    }

    private static func identity(at fd: Int32, name: String) throws -> Identity? {
        var information = stat()
        if fstatat(fd, name, &information, AT_SYMLINK_NOFOLLOW) == 0 { return Identity(information) }
        let code = errno
        if code == ENOENT { return nil }
        throw failure(for: code)
    }

    private static func identity(of fd: Int32) throws -> Identity {
        var information = stat()
        guard fstat(fd, &information) == 0 else { throw failure(for: errno) }
        return Identity(information)
    }

    private static func rename(from source: Int32, name: String, to destination: Int32, name newName: String) throws {
        guard renameatx_np(source, name, destination, newName, UInt32(RENAME_EXCL)) == 0 else {
            throw failure(for: errno)
        }
    }

    /// Removes only this payload tree. Directory traversal never follows symlinks.
    private static func removeTree(in parent: Int32, name: String, known: Identity) throws {
        let isDirectory = known.kind == S_IFDIR
        if isDirectory {
            try withDirectory(name, in: parent) { fd in
                guard try identity(of: fd) == known else { throw Failure.itemChanged }
                let copy = dup(fd)
                guard copy >= 0 else { throw failure(for: errno) }
                guard let directory = fdopendir(copy) else {
                    let code = errno
                    close(copy)
                    throw failure(for: code)
                }
                defer { closedir(directory) }
                while true {
                    errno = 0
                    guard let entry = readdir(directory) else {
                        if errno != 0 { throw failure(for: errno) }
                        break
                    }
                    let length = Int(entry.pointee.d_namlen)
                    guard let child = withUnsafePointer(to: &entry.pointee.d_name, { name in
                        name.withMemoryRebound(to: CChar.self, capacity: length + 1) {
                            String(validatingCString: $0)
                        }
                    }) else { throw Failure.badPath }
                    guard child != ".", child != ".." else { continue }
                    if let item = try identity(at: fd, name: child) {
                        guard item.device == known.device else { throw Failure.operationFailed }
                        try removeTree(in: fd, name: child, known: item)
                    }
                }
            }
        }
        guard try identity(at: parent, name: name) == known else { throw Failure.itemChanged }
        guard unlinkat(parent, name, isDirectory ? AT_REMOVEDIR : 0) == 0 else { throw failure(for: errno) }
    }

    private static func failure(for code: Int32) -> Failure {
        switch code {
        case EEXIST, ENOTEMPTY: return .collision
        case EXDEV: return .crossVolume
        case EROFS, EACCES, EPERM: return .readOnly
        case ENOENT: return .itemChanged
        default: return .operationFailed
        }
    }
}
