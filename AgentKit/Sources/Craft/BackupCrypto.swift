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
    public static let streamingMagic = Data("CLIO-BACKUP-ENC-2\n".utf8)
    public static let formatVersion: UInt8 = 1
    public static let streamingFormatVersion: UInt8 = 2
    public static let defaultIterations: Int = 600_000
    public static let minimumIterations: Int = 600_000
    public static let maximumIterations: Int = 20_000_000
    public static let defaultSaltLength: Int = 32
    public static let minimumSaltLength: Int = 16
    public static let maximumSaltLength: Int = 64
    public static let defaultChunkSize: Int = 1_048_576
    public static let minimumChunkSize: Int = 4_096
    public static let maximumChunkSize: Int = 16_777_216
    public static let nonceLength: Int = 12
    public static let tagLength: Int = 16
    public static let keyLength: Int = 32

    private static let fixedPrefixLength = magic.count + 1 + 1 // magic + version + saltLength
    private static let minimumEnvelopeLength = fixedPrefixLength + minimumSaltLength + 4 + nonceLength + tagLength
    private static let frameHeaderLength = 1 + 4 // flags + plainLength
    private static let flagIntermediate: UInt8 = 0x00
    private static let flagFinal: UInt8 = 0x01

    /// Returns true if `data` begins with either the v1 (`CLIO-BACKUP-ENC-1\n`)
    /// or streaming v2 (`CLIO-BACKUP-ENC-2\n`) encrypted backup header.
    public static func isEncrypted(_ data: Data) -> Bool {
        data.starts(with: magic) || data.starts(with: streamingMagic)
    }

    /// Streaming chunked AES-256-GCM encryptor (`CLIO-BACKUP-ENC-2\n`).
    /// Emits authenticated ciphertext chunks directly to `sink` as `chunkSize` plaintext fills up,
    /// keeping peak heap bounded to ~2x `chunkSize` while never writing plaintext to disk.
    public final class StreamEncryptor {
        private let key: SymmetricKey
        private let headerData: Data
        private let baseNonce: [UInt8]
        private let chunkSize: Int
        private let sink: (Data) throws -> Void
        private var buffer: Data
        private var chunkIndex: UInt64 = 0
        private var finished = false

        public init(
            passphrase: String,
            iterations: Int = BackupCrypto.defaultIterations,
            chunkSize: Int = BackupCrypto.defaultChunkSize,
            sink: @escaping (Data) throws -> Void
        ) throws {
            guard !passphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BackupCryptoError.emptyPassphrase
            }
            guard (BackupCrypto.minimumIterations...BackupCrypto.maximumIterations).contains(iterations),
                  (BackupCrypto.minimumChunkSize...BackupCrypto.maximumChunkSize).contains(chunkSize) else {
                throw BackupCryptoError.invalidKDFParameters
            }

            let salt = try BackupCrypto.randomBytes(count: BackupCrypto.defaultSaltLength)
            let baseNonceData = try BackupCrypto.randomBytes(count: BackupCrypto.nonceLength)
            self.baseNonce = [UInt8](baseNonceData)
            self.chunkSize = chunkSize
            self.sink = sink
            self.buffer = Data(capacity: chunkSize)

            var header = Data(capacity: BackupCrypto.streamingMagic.count + 2 + salt.count + 4 + 4 + BackupCrypto.nonceLength)
            header.append(BackupCrypto.streamingMagic)
            header.append(BackupCrypto.streamingFormatVersion)
            header.append(UInt8(salt.count))
            header.append(salt)
            var iterBE = UInt32(iterations).bigEndian
            withUnsafeBytes(of: &iterBE) { header.append(contentsOf: $0) }
            var chunkBE = UInt32(chunkSize).bigEndian
            withUnsafeBytes(of: &chunkBE) { header.append(contentsOf: $0) }
            header.append(baseNonceData)

            self.headerData = header
            self.key = try BackupCrypto.deriveKey(passphrase: passphrase, salt: salt, iterations: iterations)
            try sink(header)
        }

        public func append(_ data: Data) throws {
            guard !finished else { throw BackupCryptoError.invalidHeader }
            guard !data.isEmpty else { return }

            var offset = data.startIndex
            while offset < data.endIndex {
                let remaining = data.distance(from: offset, to: data.endIndex)
                let needed = chunkSize - buffer.count
                let take = min(remaining, needed)
                let nextOffset = data.index(offset, offsetBy: take)
                buffer.append(data[offset..<nextOffset])
                offset = nextOffset

                // Flush only when strictly full AND either more bytes follow or we stay within bounded memory.
                // Holding a full buffer until more bytes arrive (or `finish()`) ensures non-final chunks are full
                // and avoids emitting an extra empty final frame when payload is an exact multiple of `chunkSize`.
                if buffer.count == chunkSize && offset < data.endIndex {
                    try emitChunk(isFinal: false)
                }
            }
        }

        public func finish() throws {
            guard !finished else { return }
            finished = true
            try emitChunk(isFinal: true)
            zeroBuffer()
        }

        deinit {
            zeroBuffer()
        }

        private func emitChunk(isFinal: Bool) throws {
            let flags: UInt8 = isFinal ? BackupCrypto.flagFinal : BackupCrypto.flagIntermediate
            let nonce = try BackupCrypto.chunkNonce(baseNonce: baseNonce, index: chunkIndex)
            let aad = BackupCrypto.chunkAAD(headerData: headerData, index: chunkIndex, flags: flags)
            let sealed = try AES.GCM.seal(buffer, using: key, nonce: nonce, authenticating: aad)

            var frame = Data(capacity: BackupCrypto.frameHeaderLength + sealed.ciphertext.count + BackupCrypto.tagLength)
            frame.append(flags)
            var plainLenBE = UInt32(buffer.count).bigEndian
            withUnsafeBytes(of: &plainLenBE) { frame.append(contentsOf: $0) }
            frame.append(sealed.ciphertext)
            frame.append(sealed.tag)

            zeroBuffer()
            chunkIndex &+= 1
            try sink(frame)
        }

        private func zeroBuffer() {
            if !buffer.isEmpty {
                buffer.resetBytes(in: 0..<buffer.count)
                buffer.removeAll(keepingCapacity: true)
            }
        }
    }

    /// Streams plaintext from `sourceURL` into a chunked v2 encrypted file at `destinationURL` with constant memory.
    public static func encryptFile(
        from sourceURL: URL,
        to destinationURL: URL,
        passphrase: String,
        iterations: Int = defaultIterations,
        chunkSize: Int = defaultChunkSize
    ) throws {
        let reader = try FileHandle(forReadingFrom: sourceURL)
        defer { try? reader.close() }
        guard FileManager.default.createFile(atPath: destinationURL.path, contents: nil) else {
            throw BackupCryptoError.invalidHeader
        }
        let writer = try FileHandle(forWritingTo: destinationURL)
        defer { try? writer.close() }

        let encryptor = try StreamEncryptor(passphrase: passphrase, iterations: iterations, chunkSize: chunkSize) { chunk in
            try writer.write(contentsOf: chunk)
        }
        while let block = try reader.read(upToCount: chunkSize), !block.isEmpty {
            try encryptor.append(block)
        }
        try encryptor.finish()
        try writer.synchronize()
    }

    /// Decrypts either a v1 (`CLIO-BACKUP-ENC-1\n`) or streaming v2 (`CLIO-BACKUP-ENC-2\n`) encrypted file
    /// from `sourceURL` to `destinationURL`, streaming chunk-by-chunk for v2.
    public static func decryptFile(
        from sourceURL: URL,
        to destinationURL: URL,
        passphrase: String
    ) throws {
        guard !passphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BackupCryptoError.emptyPassphrase
        }
        let raw = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        guard FileManager.default.createFile(atPath: destinationURL.path, contents: nil) else {
            throw BackupCryptoError.invalidHeader
        }
        let writer = try FileHandle(forWritingTo: destinationURL)
        var completed = false
        defer {
            try? writer.close()
            if !completed {
                try? FileManager.default.removeItem(at: destinationURL)
            }
        }

        if raw.starts(with: streamingMagic) {
            try decryptStreamingV2(raw, passphrase: passphrase) { plainChunk in
                if !plainChunk.isEmpty {
                    try writer.write(contentsOf: plainChunk)
                }
            }
        } else {
            let plain = try decrypt(raw, passphrase: passphrase)
            if !plain.isEmpty {
                try writer.write(contentsOf: plain)
            }
        }
        try writer.synchronize()
        completed = true
    }

    /// Encrypts `payload` with `passphrase` using a fresh 32-byte salt, fresh 12-byte nonce,
    /// PBKDF2-HMAC-SHA256 (`>= 600_000` rounds), and AES-256-GCM authenticating the header prefix (v1 envelope).
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
    /// Supports both v1 (`CLIO-BACKUP-ENC-1\n`) and streaming chunked v2 (`CLIO-BACKUP-ENC-2\n`) envelopes.
    public static func decrypt(_ input: Data, passphrase: String) throws -> Data {
        guard !passphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BackupCryptoError.emptyPassphrase
        }

        let data = input.startIndex == 0 ? input : Data(input)
        if data.starts(with: streamingMagic) {
            var output = Data()
            try decryptStreamingV2(data, passphrase: passphrase) { chunk in
                output.append(chunk)
            }
            return output
        }

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

    private static func decryptStreamingV2(
        _ input: Data,
        passphrase: String,
        onChunk: (Data) throws -> Void
    ) throws {
        let data = input.startIndex == 0 ? input : Data(input)
        let prefixLen = streamingMagic.count + 2
        guard data.starts(with: streamingMagic),
              data.count >= prefixLen + minimumSaltLength + 4 + 4 + nonceLength + frameHeaderLength + tagLength else {
            throw BackupCryptoError.invalidHeader
        }

        let version = data[streamingMagic.count]
        guard version == streamingFormatVersion else {
            throw BackupCryptoError.unsupportedVersion
        }

        let saltLength = Int(data[streamingMagic.count + 1])
        guard (minimumSaltLength...maximumSaltLength).contains(saltLength) else {
            throw BackupCryptoError.invalidKDFParameters
        }

        let headerLength = prefixLen + saltLength + 4 + 4 + nonceLength
        guard data.count >= headerLength + frameHeaderLength + tagLength else {
            throw BackupCryptoError.invalidHeader
        }

        let saltStart = prefixLen
        let saltEnd = saltStart + saltLength
        let salt = data.subdata(in: saltStart..<saltEnd)

        let iterEnd = saltEnd + 4
        let iterations = Int(data.subdata(in: saltEnd..<iterEnd).withUnsafeBytes {
            UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))
        })
        guard (minimumIterations...maximumIterations).contains(iterations) else {
            throw BackupCryptoError.invalidKDFParameters
        }

        let chunkSizeEnd = iterEnd + 4
        let chunkSize = Int(data.subdata(in: iterEnd..<chunkSizeEnd).withUnsafeBytes {
            UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))
        })
        guard (minimumChunkSize...maximumChunkSize).contains(chunkSize) else {
            throw BackupCryptoError.invalidKDFParameters
        }

        let baseNonce = [UInt8](data.subdata(in: chunkSizeEnd..<headerLength))
        let headerData = data.subdata(in: 0..<headerLength)
        let key = try deriveKey(passphrase: passphrase, salt: salt, iterations: iterations)

        var cursor = headerLength
        var chunkIndex: UInt64 = 0
        var sawFinal = false

        while cursor < data.count {
            guard !sawFinal else {
                // Reject trailing garbage appended after final authenticated frame.
                throw BackupCryptoError.authenticationFailed
            }
            guard cursor + frameHeaderLength + tagLength <= data.count else {
                throw BackupCryptoError.authenticationFailed
            }
            let flags = data[cursor]
            guard flags == flagIntermediate || flags == flagFinal else {
                throw BackupCryptoError.authenticationFailed
            }
            let plainLen = Int(data.subdata(in: (cursor + 1)..<(cursor + 5)).withUnsafeBytes {
                UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))
            })
            guard plainLen <= chunkSize else {
                throw BackupCryptoError.authenticationFailed
            }
            if flags == flagIntermediate && plainLen == 0 {
                throw BackupCryptoError.authenticationFailed
            }

            let cipherStart = cursor + frameHeaderLength
            let cipherEnd = cipherStart + plainLen
            let tagEnd = cipherEnd + tagLength
            guard tagEnd <= data.count else {
                throw BackupCryptoError.authenticationFailed
            }

            let ciphertext = data.subdata(in: cipherStart..<cipherEnd)
            let tag = data.subdata(in: cipherEnd..<tagEnd)
            let nonce = try chunkNonce(baseNonce: baseNonce, index: chunkIndex)
            let aad = chunkAAD(headerData: headerData, index: chunkIndex, flags: flags)

            let sealedBox: AES.GCM.SealedBox
            do {
                sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            } catch {
                throw BackupCryptoError.invalidHeader
            }

            let plain: Data
            do {
                plain = try AES.GCM.open(sealedBox, using: key, authenticating: aad)
            } catch {
                throw BackupCryptoError.authenticationFailed
            }
            try onChunk(plain)

            cursor = tagEnd
            chunkIndex &+= 1
            if flags == flagFinal {
                sawFinal = true
            }
        }

        guard sawFinal else {
            throw BackupCryptoError.authenticationFailed
        }
    }

    private static func chunkNonce(baseNonce: [UInt8], index: UInt64) throws -> AES.GCM.Nonce {
        guard baseNonce.count == nonceLength else {
            throw BackupCryptoError.invalidKDFParameters
        }
        var derived = baseNonce
        var indexBE = index.bigEndian
        withUnsafeBytes(of: &indexBE) { bytes in
            for i in 0..<8 {
                derived[nonceLength - 8 + i] ^= bytes[i]
            }
        }
        do {
            return try AES.GCM.Nonce(data: derived)
        } catch {
            throw BackupCryptoError.invalidKDFParameters
        }
    }

    private static func chunkAAD(headerData: Data, index: UInt64, flags: UInt8) -> Data {
        var aad = Data(capacity: headerData.count + 9)
        aad.append(headerData)
        var indexBE = index.bigEndian
        withUnsafeBytes(of: &indexBE) { aad.append(contentsOf: $0) }
        aad.append(flags)
        return aad
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
