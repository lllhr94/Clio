import Craft
import Foundation
import XCTest

final class BackupCryptoTests: XCTestCase {
    private func makePlainArchiveSample() -> Data {
        var archive = Data("CLIO-BACKUP-1\n".utf8)
        func appendEntry(_ path: String, _ content: Data) {
            let nameData = Data(path.utf8)
            var nameLen = UInt32(nameData.count).bigEndian
            var bodyLen = UInt64(content.count).bigEndian
            archive.append(Data(bytes: &nameLen, count: 4))
            archive.append(nameData)
            archive.append(Data(bytes: &bodyLen, count: 8))
            archive.append(content)
        }
        appendEntry("Team/bots.json", Data(#"[{"id":"b1","name":"克克"}]"#.utf8))
        appendEntry("Team/media/sample.bin", Data([0x00, 0xFF, 0x10, 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        appendEntry("Skills/demo/SKILL.md", Data("# Demo\n".utf8))
        appendEntry("#keys", Data(#"{"ep-1":"sk-live-test-secret-12345"}"#.utf8))
        return archive
    }

    func testRoundTripBinaryAndKeysPayloads() throws {
        let payload = makePlainArchiveSample()
        let passphrase = " correct-horse-battery-staple "

        XCTAssertFalse(BackupCrypto.isEncrypted(payload))
        let encrypted = try BackupCrypto.encrypt(payload: payload, passphrase: passphrase)
        XCTAssertTrue(BackupCrypto.isEncrypted(encrypted))

        // Header prefix sanity: 18-byte magic + version(1) + saltLen(32) + salt(32) + iterations(600_000)
        XCTAssertEqual(encrypted.prefix(18), BackupCrypto.magic)
        XCTAssertEqual(encrypted[18], BackupCrypto.formatVersion)
        XCTAssertEqual(Int(encrypted[19]), BackupCrypto.defaultSaltLength)
        let iterOffset = 18 + 1 + 1 + BackupCrypto.defaultSaltLength
        let iterations = encrypted.subdata(in: iterOffset..<(iterOffset + 4)).withUnsafeBytes {
            UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))
        }
        XCTAssertEqual(iterations, UInt32(BackupCrypto.defaultIterations))

        // Secret key bytes must never appear in plaintext inside the encrypted container.
        XCTAssertNil(encrypted.range(of: Data("sk-live-test-secret-12345".utf8)))
        XCTAssertNil(encrypted.range(of: Data("#keys".utf8)))

        let decrypted = try BackupCrypto.decrypt(encrypted, passphrase: passphrase)
        XCTAssertEqual(decrypted, payload)

        // Exact passphrase bytes must be preserved (no silent whitespace trimming).
        XCTAssertThrowsError(try BackupCrypto.decrypt(encrypted, passphrase: "correct-horse-battery-staple")) { error in
            XCTAssertEqual(error as? BackupCryptoError, .authenticationFailed)
        }

        // Sub-slice with non-zero startIndex must decrypt cleanly without index assumptions.
        let prefixed = Data([0xAA, 0xBB, 0xCC, 0xDD]) + encrypted
        let slice = prefixed[4..<prefixed.count]
        XCTAssertTrue(BackupCrypto.isEncrypted(slice))
        XCTAssertEqual(try BackupCrypto.decrypt(slice, passphrase: passphrase), payload)
    }

    func testWrongPassphraseFailsWithAuthenticationFailed() throws {
        let payload = makePlainArchiveSample()
        let encrypted = try BackupCrypto.encrypt(payload: payload, passphrase: "right-passphrase-123")

        XCTAssertThrowsError(try BackupCrypto.decrypt(encrypted, passphrase: "wrong-passphrase-123")) { error in
            XCTAssertEqual(error as? BackupCryptoError, .authenticationFailed)
        }
    }

    func testEmptyAndWhitespacePassphraseFailWithEmptyPassphrase() throws {
        let payload = makePlainArchiveSample()
        let encrypted = try BackupCrypto.encrypt(payload: payload, passphrase: "valid-passphrase")

        for bad in ["", " ", "   \t\n  "] {
            XCTAssertThrowsError(try BackupCrypto.encrypt(payload: payload, passphrase: bad)) { error in
                XCTAssertEqual(error as? BackupCryptoError, .emptyPassphrase)
            }
            XCTAssertThrowsError(try BackupCrypto.decrypt(encrypted, passphrase: bad)) { error in
                XCTAssertEqual(error as? BackupCryptoError, .emptyPassphrase)
            }
        }
    }

    func testDistinctSaltNonceAndCiphertextAcrossEncryptions() throws {
        let payload = makePlainArchiveSample()
        let passphrase = "same-passphrase-every-time"

        let first = try BackupCrypto.encrypt(payload: payload, passphrase: passphrase)
        let second = try BackupCrypto.encrypt(payload: payload, passphrase: passphrase)

        XCTAssertNotEqual(first, second)
        let saltStart = BackupCrypto.magic.count + 2
        let saltEnd = saltStart + BackupCrypto.defaultSaltLength
        XCTAssertNotEqual(first.subdata(in: saltStart..<saltEnd), second.subdata(in: saltStart..<saltEnd))

        let nonceStart = saltEnd + 4
        let nonceEnd = nonceStart + BackupCrypto.nonceLength
        XCTAssertNotEqual(first.subdata(in: nonceStart..<nonceEnd), second.subdata(in: nonceStart..<nonceEnd))

        XCTAssertEqual(try BackupCrypto.decrypt(first, passphrase: passphrase), payload)
        XCTAssertEqual(try BackupCrypto.decrypt(second, passphrase: passphrase), payload)
    }

    func testEncryptRejectsOutOfBoundsIterations() {
        let payload = Data("CLIO-BACKUP-1\n".utf8)
        for badIterations in [0, 1, 599_999, 20_000_001] {
            XCTAssertThrowsError(
                try BackupCrypto.encrypt(payload: payload, passphrase: "valid-pass", iterations: badIterations)
            ) { error in
                XCTAssertEqual(error as? BackupCryptoError, .invalidKDFParameters)
            }
        }
    }

    func testCorruptHeadersMetadataAndPayloadAlwaysFailCleanly() throws {
        let payload = makePlainArchiveSample()
        let passphrase = "tamper-check-passphrase"
        let valid = try BackupCrypto.encrypt(payload: payload, passphrase: passphrase)

        // 1. Plaintext or corrupted magic -> invalidHeader
        XCTAssertThrowsError(try BackupCrypto.decrypt(payload, passphrase: passphrase)) { error in
            XCTAssertEqual(error as? BackupCryptoError, .invalidHeader)
        }
        var badMagic = valid
        badMagic[0] ^= 0x01
        XCTAssertThrowsError(try BackupCrypto.decrypt(badMagic, passphrase: passphrase)) { error in
            XCTAssertEqual(error as? BackupCryptoError, .invalidHeader)
        }

        // 2. Truncation at various boundaries -> invalidHeader (before min envelope) or authenticationFailed (mid-body)
        for cutoff in [0, 10, 18, 25, 51, 56, 83] {
            let truncated = valid.prefix(cutoff)
            XCTAssertThrowsError(try BackupCrypto.decrypt(truncated, passphrase: passphrase)) { error in
                XCTAssertEqual(error as? BackupCryptoError, .invalidHeader)
            }
        }
        XCTAssertThrowsError(try BackupCrypto.decrypt(valid.prefix(valid.count - 1), passphrase: passphrase)) { error in
            XCTAssertEqual(error as? BackupCryptoError, .authenticationFailed)
        }

        // 3. Unsupported version -> unsupportedVersion
        for ver in [UInt8(0), UInt8(2), UInt8(255)] {
            var badVersion = valid
            badVersion[18] = ver
            XCTAssertThrowsError(try BackupCrypto.decrypt(badVersion, passphrase: passphrase)) { error in
                XCTAssertEqual(error as? BackupCryptoError, .unsupportedVersion)
            }
        }

        // 4. Invalid saltLength -> invalidKDFParameters
        for badSaltLen in [UInt8(0), UInt8(15), UInt8(65), UInt8(255)] {
            var badSaltHeader = valid
            badSaltHeader[19] = badSaltLen
            XCTAssertThrowsError(try BackupCrypto.decrypt(badSaltHeader, passphrase: passphrase)) { error in
                XCTAssertEqual(error as? BackupCryptoError, .invalidKDFParameters)
            }
        }

        // 5. Downgrade (< 600_000) or DoS (> 20_000_000) iterations -> invalidKDFParameters
        let iterOffset = 18 + 2 + BackupCrypto.defaultSaltLength
        for badCount in [UInt32(0), UInt32(10_000), UInt32(599_999), UInt32(20_000_001), UInt32.max] {
            var badIter = valid
            var bigEndian = badCount.bigEndian
            withUnsafeBytes(of: &bigEndian) { bytes in
                badIter.replaceSubrange(iterOffset..<(iterOffset + 4), with: bytes)
            }
            XCTAssertThrowsError(try BackupCrypto.decrypt(badIter, passphrase: passphrase)) { error in
                XCTAssertEqual(error as? BackupCryptoError, .invalidKDFParameters)
            }
        }

        // 6. Valid-range AAD metadata tampering (iterations 600_000 -> 600_001) -> authenticationFailed
        var tamperedIter = valid
        var altIter = UInt32(600_001).bigEndian
        withUnsafeBytes(of: &altIter) { bytes in
            tamperedIter.replaceSubrange(iterOffset..<(iterOffset + 4), with: bytes)
        }
        XCTAssertThrowsError(try BackupCrypto.decrypt(tamperedIter, passphrase: passphrase)) { error in
            XCTAssertEqual(error as? BackupCryptoError, .authenticationFailed)
        }

        // 7. Salt byte tampering -> authenticationFailed
        var tamperedSalt = valid
        tamperedSalt[20] ^= 0x80
        XCTAssertThrowsError(try BackupCrypto.decrypt(tamperedSalt, passphrase: passphrase)) { error in
            XCTAssertEqual(error as? BackupCryptoError, .authenticationFailed)
        }

        // 8. Nonce tampering -> authenticationFailed
        let nonceOffset = iterOffset + 4
        var tamperedNonce = valid
        tamperedNonce[nonceOffset] ^= 0x40
        XCTAssertThrowsError(try BackupCrypto.decrypt(tamperedNonce, passphrase: passphrase)) { error in
            XCTAssertEqual(error as? BackupCryptoError, .authenticationFailed)
        }

        // 9. Ciphertext tampering -> authenticationFailed
        let ciphertextOffset = nonceOffset + BackupCrypto.nonceLength
        var tamperedBody = valid
        tamperedBody[ciphertextOffset] ^= 0x20
        XCTAssertThrowsError(try BackupCrypto.decrypt(tamperedBody, passphrase: passphrase)) { error in
            XCTAssertEqual(error as? BackupCryptoError, .authenticationFailed)
        }

        // 10. Auth tag tampering -> authenticationFailed
        var tamperedTag = valid
        tamperedTag[tamperedTag.count - 1] ^= 0x01
        XCTAssertThrowsError(try BackupCrypto.decrypt(tamperedTag, passphrase: passphrase)) { error in
            XCTAssertEqual(error as? BackupCryptoError, .authenticationFailed)
        }
    }

    func testArchivePathExclusionAndTraversalSafety() {
        let allowed = [
            "Team/bots.json",
            "Team/rooms.json",
            "Team/settings.json",
            "Team/memory.json",
            "Team/memory-retracted.json",
            "Team/chats/bot1.json",
            "Team/chats/~summary.json",
            "Team/media/image.jpg",
            "Portraits/p1.png",
            "Skills/旅行规划.md",
            "Skills/my-skill/SKILL.md",
            "Skills/my-skill/scripts/helper.py",
        ]
        for path in allowed {
            XCTAssertFalse(BackupArchivePolicy.isExcludedArchivePath(path), "Expected allowed path: \(path)")
        }

        let excluded = [
            // Vault & transient Team folders
            "Team/secrets.json",
            "Team/Secrets.json",
            "Team/sub/secrets.json",
            "Team/snapshots/s1.json",
            "Team/doccache/doc1.txt",
            // SQLite / WAL / SHM / journal / ClioMemory / ClioIndex / ClioQueued
            "ClioMemory/clio-memory.db",
            "ClioMemory/clio-memory.db-wal",
            "ClioMemory/clio-memory.db-shm",
            "ClioMemory/Mirrors/档案.md",
            "clioMemory/sub/notes.json",
            "ClioIndex/clio-index.db",
            "ClioINDEX/sub/index.json",
            "ClioQueued/slot.json",
            "Team/clio-memory.db",
            "Team/data.sqlite",
            "Team/data.sqlite-wal",
            "Team/data.sqlite-shm",
            "Team/data.sqlite3",
            "Team/data.db-journal",
            "Team/data.journal",
            "Skills/skill.sqlite",
            "Skills/skill.sqlite-wal",
            "Skills/skill.journal",
            // Traversal, hidden dotfiles, control chars, non-allowlisted roots
            "../Team/bots.json",
            "Team/../secrets.json",
            "Team/./bots.json",
            "/Team/bots.json",
            "Team/bots.json/",
            "Team//bots.json",
            "Team\\secrets.json",
            "Team/.DS_Store",
            "Skills/.DS_Store",
            "Skills/.git/config",
            "Skills/my-skill/.env",
            "Team",
            "Portraits",
            "Skills",
            "#keys",
            "#settings",
            "Documents/note.md",
            "书案/diary.md",
            "Den/rootfs/etc/shadow",
            "Team/bad\0file.json",
            "Team/bad\nfile.json",
            "Team/bad\rfile.json",
        ]
        for path in excluded {
            XCTAssertTrue(BackupArchivePolicy.isExcludedArchivePath(path), "Expected excluded path: \(path)")
        }
    }

    func testStreamingV2RoundTripMultiChunkExactBoundaryAndEmpty() throws {
        let passphrase = "streaming-v2-passphrase!"
        let chunkSize = 4_096

        // 1. Empty payload
        var emptyCipher = Data()
        let emptyEnc = try BackupCrypto.StreamEncryptor(passphrase: passphrase, chunkSize: chunkSize) { emptyCipher.append($0) }
        try emptyEnc.finish()
        XCTAssertTrue(BackupCrypto.isEncrypted(emptyCipher))
        XCTAssertTrue(emptyCipher.starts(with: BackupCrypto.streamingMagic))
        XCTAssertEqual(try BackupCrypto.decrypt(emptyCipher, passphrase: passphrase), Data())

        // 2. Exact multiple of chunkSize (3 * 4096 bytes) fed in irregular slices
        let exactPayload = Data((0..<(chunkSize * 3)).map { UInt8($0 % 251) })
        var exactCipher = Data()
        let exactEnc = try BackupCrypto.StreamEncryptor(passphrase: passphrase, chunkSize: chunkSize) { exactCipher.append($0) }
        var pos = 0
        for step in [17, 4_096, 1_024, 5_000, exactPayload.count] {
            guard pos < exactPayload.count else { break }
            let end = min(exactPayload.count, pos + step)
            try exactEnc.append(exactPayload[pos..<end])
            pos = end
        }
        try exactEnc.finish()
        XCTAssertEqual(try BackupCrypto.decrypt(exactCipher, passphrase: passphrase), exactPayload)

        // 3. Non-multiple multi-chunk + encryptFile / decryptFile round-trip
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("clio-v2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let srcURL = tmp.appendingPathComponent("plain.bin")
        let encURL = tmp.appendingPathComponent("enc.clio-backup")
        let decURL = tmp.appendingPathComponent("dec.bin")
        let bigPayload = Data((0..<(chunkSize * 4 + 333)).map { UInt8(($0 * 7) % 253) })
        try bigPayload.write(to: srcURL)
        try BackupCrypto.encryptFile(from: srcURL, to: encURL, passphrase: passphrase, chunkSize: chunkSize)
        try BackupCrypto.decryptFile(from: encURL, to: decURL, passphrase: passphrase)
        XCTAssertEqual(try Data(contentsOf: decURL), bigPayload)
    }

    func testStreamingV2RejectsTamperingTruncationTrailingGarbageAndWrongPassphrase() throws {
        let passphrase = "v2-tamper-passphrase"
        let chunkSize = 4_096
        let payload = Data((0..<(chunkSize * 2 + 128)).map { UInt8($0 % 199) })
        var encrypted = Data()
        let enc = try BackupCrypto.StreamEncryptor(passphrase: passphrase, chunkSize: chunkSize) { encrypted.append($0) }
        try enc.append(payload)
        try enc.finish()

        // Wrong passphrase
        XCTAssertThrowsError(try BackupCrypto.decrypt(encrypted, passphrase: "wrong-pass")) { error in
            XCTAssertEqual(error as? BackupCryptoError, .authenticationFailed)
        }

        // Truncation (drop last frame)
        let truncated = encrypted.prefix(encrypted.count - 40)
        XCTAssertThrowsError(try BackupCrypto.decrypt(Data(truncated), passphrase: passphrase)) { error in
            XCTAssertEqual(error as? BackupCryptoError, .authenticationFailed)
        }

        // Trailing garbage after final chunk
        var withTrailing = encrypted
        withTrailing.append(Data([0x01, 0x00, 0x00, 0x00, 0x00]))
        XCTAssertThrowsError(try BackupCrypto.decrypt(withTrailing, passphrase: passphrase)) { error in
            XCTAssertEqual(error as? BackupCryptoError, .authenticationFailed)
        }

        // Flip bit in first ciphertext byte
        let headerLen = BackupCrypto.streamingMagic.count + 2 + BackupCrypto.defaultSaltLength + 4 + 4 + BackupCrypto.nonceLength
        var tampered = encrypted
        tampered[headerLen + 5] ^= 0x80
        XCTAssertThrowsError(try BackupCrypto.decrypt(tampered, passphrase: passphrase)) { error in
            XCTAssertEqual(error as? BackupCryptoError, .authenticationFailed)
        }
    }
}
