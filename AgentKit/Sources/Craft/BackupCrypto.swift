import CommonCrypto
import CryptoKit
import Foundation
import Security

/// Typed errors for Clio's passphrase-encrypted backup envelope (`CLIO-BACKUP-ENC-1`).
public enum BackupCryptoError: LocalizedError, Equatable, Sendable {
    case emptyPassphrase
    case passphraseRequired
    case invalidHeader
    case unsupportedVersion
    case invalidKDFParameters
    case authenticationFailed

    public var errorDescription: String? {
        switch self {
        case .emptyPassphrase:
            return "口令不能为空或全为空白字符。"
        case .passphraseRequired:
            return "这份备份已加密，需要输入口令才能继续。"
        case .invalidHeader:
            return "加密备份的文件头无效或已损坏。"
        case .unsupportedVersion:
            return "这份加密备份的版本太新或暂不支持，请升级 Clio 后再试。"
        case .invalidKDFParameters:
            return "加密备份的密钥派生参数不在安全范围内，已拒绝解包。"
        case .authenticationFailed:
            return "口令不对，或加密备份数据已被改动。"
        }
    }
}

/// Authenticated encryption for Clio backup payloads using PBKDF2-HMAC-SHA256 + AES-256-GCM.
///
/// Binary layout:
/// - `magic`: `"CLIO-BACKUP-ENC-1\n"` (18 bytes)
/// - `version`: `UInt8` = `1` (1 byte)
/// - `saltLength`: `UInt8` = `32` (1 byte, accepted `16...64`)
/// - `salt`: `saltLength` random bytes
/// - `iterations`: `UInt32` big-endian (4 bytes, accepted `600_000...20_000_000`)
/// - `nonce`: 12 random bytes for AES-GCM
/// - `ciphertext`: encrypted payload (`payload.count` bytes)
/// - `tag`: 16-byte AES-GCM authentication tag
///
/// The exact unencrypted header prefix (`magic + version + saltLength + salt + iterations`)
/// is bound as Additional Authenticated Data (AAD) in `AES.GCM.seal` / `AES.GCM.open`
/// so any metadata tampering invalidates authentication.
public enum BackupCrypto: Sendable {
    public static let magic = Data("CLIO-BACKUP-ENC-1\n".utf8)
    public static let formatVersion: UInt8 = 1
    public static let defaultIterations: Int = 600_000
    public static let minimumIterations: Int = 600_000
    public static let maximumIterations: Int = 20_000_000
    public static let defaultSaltLength: Int = 32
    public static let minimumSaltLength: Int = 16
    public static let maximumSaltLength: Int = 64
    public static let nonceLength: Int = 12
    public static let tagLength: Int = 16
    public static let keyLength: Int = 32

    private static let fixedPrefixLength = magic.count + 1 + 1 // magic + version + saltLength
    private static let minimumEnvelopeLength = fixedPrefixLength + minimumSaltLength + 4 + nonceLength + tagLength

    /// Returns true if `data` begins with the `CLIO-BACKUP-ENC-1\n` magic header.
    public static func isEncrypted(_ data: Data) -> Bool {
        data.starts(with: magic)
    }

    /// Encrypts `payload` with `passphrase` using a fresh 32-byte salt, fresh 12-byte nonce,
    /// PBKDF2-HMAC-SHA256 (`>= 600_000` rounds), and AES-256-GCM authenticating the header prefix.
    public static func encrypt(
        payload: Data,
        passphrase: String,
        iterations: Int = defaultIterations
    ) throws -> Data {
        guard !passphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BackupCryptoError.emptyPassphrase
        }
        guard (minimumIterations...maximumIterations).contains(iterations) else {
            throw BackupCryptoError.invalidKDFParameters
        }

        let salt = try randomBytes(count: defaultSaltLength)
        let nonceBytes = try randomBytes(count: nonceLength)
        let nonce: AES.GCM.Nonce
        do {
            nonce = try AES.GCM.Nonce(data: nonceBytes)
        } catch {
            throw BackupCryptoError.invalidKDFParameters
        }

        var headerData = Data(capacity: fixedPrefixLength + defaultSaltLength + 4)
        headerData.append(magic)
        headerData.append(formatVersion)
        headerData.append(UInt8(defaultSaltLength))
        headerData.append(salt)
        var iterationsBE = UInt32(iterations).bigEndian
        withUnsafeBytes(of: &iterationsBE) { headerData.append(contentsOf: $0) }

        let key = try deriveKey(passphrase: passphrase, salt: salt, iterations: iterations)
        let sealed = try AES.GCM.seal(payload, using: key, nonce: nonce, authenticating: headerData)

        var envelope = Data(capacity: headerData.count + nonceLength + sealed.ciphertext.count + tagLength)
        envelope.append(headerData)
        envelope.append(nonceBytes)
        envelope.append(sealed.ciphertext)
        envelope.append(sealed.tag)
        return envelope
    }

    /// Validates header, version, and KDF bounds, derives the AES-256 key, and decrypts/authenticates `input`.
    public static func decrypt(_ input: Data, passphrase: String) throws -> Data {
        guard !passphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BackupCryptoError.emptyPassphrase
        }

        let data = input.startIndex == 0 ? input : Data(input)
        guard data.starts(with: magic), data.count >= fixedPrefixLength + 4 + nonceLength + tagLength else {
            throw BackupCryptoError.invalidHeader
        }

        let version = data[magic.count]
        guard version == formatVersion else {
            throw BackupCryptoError.unsupportedVersion
        }

        let saltLength = Int(data[magic.count + 1])
        guard (minimumSaltLength...maximumSaltLength).contains(saltLength) else {
            throw BackupCryptoError.invalidKDFParameters
        }

        let headerLength = fixedPrefixLength + saltLength + 4
        let minimumTotalLength = headerLength + nonceLength + tagLength
        guard data.count >= minimumTotalLength, data.count >= minimumEnvelopeLength else {
            throw BackupCryptoError.invalidHeader
        }

        let saltStart = fixedPrefixLength
        let saltEnd = saltStart + saltLength
        let salt = data.subdata(in: saltStart..<saltEnd)

        let iterationsData = data.subdata(in: saltEnd..<headerLength)
        let iterationsRaw = iterationsData.withUnsafeBytes {
            UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))
        }
        let iterations = Int(iterationsRaw)
        guard (minimumIterations...maximumIterations).contains(iterations) else {
            throw BackupCryptoError.invalidKDFParameters
        }

        let headerData = data.subdata(in: 0..<headerLength)
        let nonceStart = headerLength
        let nonceEnd = nonceStart + nonceLength
        let tagStart = data.count - tagLength
        let nonceData = data.subdata(in: nonceStart..<nonceEnd)
        let ciphertext = data.subdata(in: nonceEnd..<tagStart)
        let tag = data.subdata(in: tagStart..<data.count)

        let key = try deriveKey(passphrase: passphrase, salt: salt, iterations: iterations)
        let nonce: AES.GCM.Nonce
        let sealedBox: AES.GCM.SealedBox
        do {
            nonce = try AES.GCM.Nonce(data: nonceData)
            sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        } catch {
            throw BackupCryptoError.invalidHeader
        }

        do {
            return try AES.GCM.open(sealedBox, using: key, authenticating: headerData)
        } catch {
            throw BackupCryptoError.authenticationFailed
        }
    }

    private static func randomBytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        guard status == errSecSuccess else {
            throw BackupCryptoError.invalidKDFParameters
        }
        return Data(bytes)
    }

    private static func deriveKey(passphrase: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        var passwordBytes = passphrase.utf8.map { Int8(bitPattern: $0) }
        defer {
            passwordBytes.withUnsafeMutableBytes { raw in
                _ = raw.initializeMemory(as: UInt8.self, repeating: 0)
            }
        }
        let saltBytes = [UInt8](salt)
        var derived = [UInt8](repeating: 0, count: keyLength)
        defer {
            derived.withUnsafeMutableBytes { raw in
                _ = raw.initializeMemory(as: UInt8.self, repeating: 0)
            }
        }

        let status: Int32 = passwordBytes.withUnsafeBufferPointer { pwdPtr in
            saltBytes.withUnsafeBufferPointer { saltPtr in
                derived.withUnsafeMutableBufferPointer { keyPtr in
                    guard let pwdBase = pwdPtr.baseAddress,
                          let saltBase = saltPtr.baseAddress,
                          let keyBase = keyPtr.baseAddress else {
                        return Int32(kCCParamError)
                    }
                    return CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwdBase,
                        passwordBytes.count,
                        saltBase,
                        saltBytes.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        keyBase,
                        keyLength
                    )
                }
            }
        }
        guard status == Int32(kCCSuccess) else {
            throw BackupCryptoError.invalidKDFParameters
        }
        return SymmetricKey(data: derived)
    }
}

/// Pure archive entry path normalization and exclusion policy shared by backup creation,
/// backup restoration, and unit tests.
public enum BackupArchivePolicy: Sendable {
    public static let allowedArchiveRoots: Set<String> = ["Team", "Portraits", "Skills"]

    private static let excludedTeamChildren: Set<String> = [
        "secrets.json",
        "snapshots",
        "doccache",
        "mounts.json",
        "trash-index.json",
    ]

    private static let excludedStoreDirectories: Set<String> = [
        "cliomemory",
        "clioindex",
        "clioqueued",
    ]

    private static let sqliteArtifactSuffixes: [String] = [
        ".db",
        ".db-wal",
        ".db-shm",
        ".db-journal",
        ".sqlite",
        ".sqlite-wal",
        ".sqlite-shm",
        ".sqlite-journal",
        ".sqlite3",
        ".sqlite3-wal",
        ".sqlite3-shm",
        ".sqlite3-journal",
        ".journal",
        ".wal",
        ".shm",
    ]

    /// Splits a relative archive path into safe components, or returns `nil` if the path contains
    /// traversal (`..`, `.`), empty segments (`//`, leading/trailing `/`), backslashes, hidden
    /// dot-segments, NUL bytes, or control characters.
    public static func normalizeRelativePath(_ raw: String) -> [String]? {
        guard !raw.isEmpty,
              !raw.hasPrefix("/"),
              !raw.hasSuffix("/"),
              !raw.contains("\\"),
              !raw.contains("\0"),
              !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }

        let parts = raw.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty else { return nil }
        for part in parts {
            if part.isEmpty || part == "." || part == ".." || part.hasPrefix(".") {
                return nil
            }
        }
        return parts
    }

    /// True if `filename` has a SQLite database, WAL, SHM, or journal suffix (case-insensitive).
    public static func isSQLiteOrCacheArtifact(_ filename: String) -> Bool {
        let lower = filename.lowercased()
        return sqliteArtifactSuffixes.contains { lower.hasSuffix($0) }
    }

    /// Returns `true` if `path` must NEVER be packed into or restored from a Clio archive file tree.
    /// Metadata entries starting with `#` are handled separately and also return `true` here.
    public static func isExcludedArchivePath(_ path: String) -> Bool {
        guard let parts = normalizeRelativePath(path), parts.count >= 2 else {
            return true
        }
        let root = parts[0]
        guard allowedArchiveRoots.contains(root) else {
            return true
        }
        for part in parts {
            if excludedStoreDirectories.contains(part.lowercased()) || isSQLiteOrCacheArtifact(part) {
                return true
            }
        }
        if root == "Team" {
            let child = parts[1].lowercased()
            if excludedTeamChildren.contains(child) || parts.last?.lowercased() == "secrets.json" {
                return true
            }
        }
        return false
    }
}
