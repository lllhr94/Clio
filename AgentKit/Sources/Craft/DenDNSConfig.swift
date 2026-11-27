import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Configuration mode for DNS inside Clio Den.
public enum DenDNSMode: String, Codable, Sendable, CaseIterable {
    /// Follow host/system DNS automatically via Network framework + res_ninit.
    case auto
    /// Use user-supplied custom DNS servers exclusively.
    case custom
}

/// Thermal-state fork rate limits passed to `ish_set_fork_rate_limit(per_sec, burst)`.
public struct DenThermalForkLimit: Equatable, Sendable {
    public let perSecond: UInt32
    public let burst: UInt32

    public init(perSecond: UInt32, burst: UInt32) {
        self.perSecond = perSecond
        self.burst = burst
    }

    public static func limit(for state: ProcessInfo.ThermalState) -> DenThermalForkLimit {
        switch state {
        case .nominal:
            return DenThermalForkLimit(perSecond: 400, burst: 80)
        case .fair:
            return DenThermalForkLimit(perSecond: 250, burst: 50)
        case .serious:
            return DenThermalForkLimit(perSecond: 120, burst: 25)
        case .critical:
            return DenThermalForkLimit(perSecond: 60, burst: 15)
        @unknown default:
            return DenThermalForkLimit(perSecond: 120, burst: 25)
        }
    }
}

/// Decision returned when rendering `/etc/resolv.conf` for Den.
public enum DenResolvRenderDecision: Equatable, Sendable {
    case write(String)
    case preserveExisting
}

/// Pure validation, rendering, and atomic persistence helpers for Den's `/etc/clio-dns/resolv.conf`.
///
/// Designed so invalid strings never inject directives into `resolv.conf`, and transient
/// empty system DNS reads never overwrite valid config or fall back to public DNS.
public enum DenDNSConfig {
    public enum WriteError: Error, LocalizedError, Equatable {
        case openTempFailed(Int32)
        case writeFailed(Int32)
        case chmodFailed(Int32)
        case fsyncFailed(Int32)
        case renameFailed(Int32)

        public var errorDescription: String? {
            switch self {
            case .openTempFailed(let code): return "Failed to open temporary resolv.conf (errno \(code))"
            case .writeFailed(let code): return "Failed to write temporary resolv.conf (errno \(code))"
            case .chmodFailed(let code): return "Failed to chmod temporary resolv.conf (errno \(code))"
            case .fsyncFailed(let code): return "Failed to fsync temporary resolv.conf (errno \(code))"
            case .renameFailed(let code): return "Failed to atomically rename resolv.conf (errno \(code))"
            }
        }
    }

    /// Validates an IPv4 address or IPv6 address (with optional `%zone` interface suffix).
    public static func isValidNameserver(_ raw: String) -> Bool {
        normalizedNameserver(raw) != nil
    }

    /// Normalizes a candidate nameserver string, returning `nil` if invalid or unsafe.
    public static func normalizedNameserver(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 128 else { return nil }
        guard trimmed.unicodeScalars.allSatisfy({ scalar in
            scalar.isASCII && scalar.value >= 0x21 && scalar.value <= 0x7E
        }) else { return nil }

        if let percentIndex = trimmed.firstIndex(of: "%") {
            let ipPart = String(trimmed[..<percentIndex])
            let zonePart = String(trimmed[trimmed.index(after: percentIndex)...])
            guard !ipPart.isEmpty, !zonePart.isEmpty, zonePart.count <= 32 else { return nil }
            guard isValidIPv6(ipPart), isValidZoneID(zonePart) else { return nil }
            return "\(ipPart)%\(zonePart)"
        }

        if isValidIPv4(trimmed) || isValidIPv6(trimmed) {
            return trimmed
        }
        return nil
    }

    /// Filters and deduplicates a list of candidate nameservers while preserving order.
    public static func normalizeNameservers(_ candidates: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for item in candidates {
            guard let normalized = normalizedNameserver(item) else { continue }
            let key = normalized.lowercased()
            if seen.insert(key).inserted {
                result.append(normalized)
            }
        }
        return result
    }

    /// Parses user-entered DNS text (comma, semicolon, or whitespace separated) into valid and invalid entries.
    public static func parseCustomDNSList(_ rawText: String) -> (valid: [String], invalid: [String]) {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;"))
        let tokens = rawText.components(separatedBy: separators).filter { !$0.isEmpty }
        var seenValid: Set<String> = []
        var valid: [String] = []
        var invalid: [String] = []
        for token in tokens {
            if let normalized = normalizedNameserver(token) {
                let key = normalized.lowercased()
                if seenValid.insert(key).inserted {
                    valid.append(normalized)
                }
            } else {
                invalid.append(token)
            }
        }
        return (valid, invalid)
    }

    /// Validates and normalizes a single RFC DNS search domain label sequence.
    public static func sanitizeSearchDomain(_ raw: String) -> String? {
        var candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.hasSuffix(".") {
            candidate.removeLast()
        }
        guard !candidate.isEmpty, candidate.utf8.count <= 253 else { return nil }
        guard candidate.unicodeScalars.allSatisfy({ $0.isASCII }) else { return nil }

        let labels = candidate.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return nil }
        for label in labels {
            guard !label.isEmpty, label.count <= 63 else { return nil }
            guard label.first != "-", label.last != "-" else { return nil }
            for ch in label.unicodeScalars {
                let isLetter = (ch.value >= 65 && ch.value <= 90) || (ch.value >= 97 && ch.value <= 122)
                let isDigit = (ch.value >= 48 && ch.value <= 57)
                let isHyphen = ch.value == 45
                guard isLetter || isDigit || isHyphen else { return nil }
            }
        }
        return candidate
    }

    /// Sanitizes and deduplicates search domains, capping to 6 domains cleanly within resolv.conf bounds.
    public static func sanitizeSearchDomains(_ domains: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        var bytesUsed = 0
        for raw in domains {
            guard let clean = sanitizeSearchDomain(raw) else { continue }
            let key = clean.lowercased()
            guard seen.insert(key).inserted else { continue }
            let addedBytes = (result.isEmpty ? 0 : 1) + clean.utf8.count
            if result.count >= 6 || bytesUsed + addedBytes > 250 { break }
            result.append(clean)
            bytesUsed += addedBytes
        }
        return result
    }

    /// Returns true if an existing `resolv.conf` body already contains at least one valid `nameserver` entry.
    public static func hasValidNameserver(in content: String) -> Bool {
        for rawLine in content.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(";") else { continue }
            let parts = line.split(whereSeparator: \.isWhitespace)
            if parts.count >= 2, parts[0] == "nameserver", isValidNameserver(String(parts[1])) {
                return true
            }
        }
        return false
    }

    /// Decides what to write to `resolv.conf` without ever falling back to hardcoded public DNS.
    public static func renderResolvConf(
        mode: DenDNSMode,
        systemServers: [String],
        customServers: [String],
        searchDomains: [String] = [],
        existingContent: String? = nil
    ) -> DenResolvRenderDecision {
        let validCustom = normalizeNameservers(customServers)
        let validSystem = normalizeNameservers(systemServers)
        let cleanSearch = sanitizeSearchDomains(searchDomains)

        switch mode {
        case .custom:
            if !validCustom.isEmpty {
                let body = formatResolvConf(
                    header: "# Generated by Clio Den (custom)",
                    nameservers: validCustom,
                    searchDomains: cleanSearch
                )
                return existingContent == body ? .preserveExisting : .write(body)
            }
            if let existingContent, hasValidNameserver(in: existingContent) {
                return .preserveExisting
            }
            if !validSystem.isEmpty {
                let body = formatResolvConf(
                    header: "# Generated by Clio Den (custom empty; using system DNS)",
                    nameservers: validSystem,
                    searchDomains: cleanSearch
                )
                return existingContent == body ? .preserveExisting : .write(body)
            }
            if existingContent != nil {
                return .preserveExisting
            }
            return .write("# Generated by Clio Den (custom): no valid DNS server configured\n")

        case .auto:
            if !validSystem.isEmpty {
                let body = formatResolvConf(
                    header: "# Generated by Clio Den (auto)",
                    nameservers: validSystem,
                    searchDomains: cleanSearch
                )
                return existingContent == body ? .preserveExisting : .write(body)
            }
            if let existingContent {
                if hasValidNameserver(in: existingContent) || !existingContent.isEmpty {
                    return .preserveExisting
                }
            }
            return .write("# Generated by Clio Den (auto): waiting for system DNS\n")
        }
    }

    /// Atomically writes `content` to `fileURL` using a sibling temp file, `chmod 0644`, `fsync`, and `rename`.
    public static func atomicWriteResolvConf(content: String, to fileURL: URL) throws {
        let dirURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

        let tempURL = dirURL.appendingPathComponent(".resolv.conf.tmp.\(UUID().uuidString)", isDirectory: false)
        let flags = O_WRONLY | O_CREAT | O_EXCL
        let mode: mode_t = 0o644

        let fd = tempURL.withUnsafeFileSystemRepresentation { ptr -> Int32 in
            guard let ptr else { return -1 }
            return open(ptr, flags, mode)
        }
        guard fd >= 0 else {
            throw WriteError.openTempFailed(errno)
        }

        var cleanupTemp = true
        defer {
            if cleanupTemp {
                try? FileManager.default.removeItem(at: tempURL)
            }
        }

        do {
            let data = Data(content.utf8)
            try data.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                var written = 0
                while written < rawBuffer.count {
                    let n = write(fd, base.advanced(by: written), rawBuffer.count - written)
                    if n < 0 {
                        if errno == EINTR { continue }
                        let err = errno
                        close(fd)
                        throw WriteError.writeFailed(err)
                    }
                    written += n
                }
            }

            if fchmod(fd, mode) != 0 {
                let err = errno
                close(fd)
                throw WriteError.chmodFailed(err)
            }

            if fsync(fd) != 0 {
                let err = errno
                close(fd)
                throw WriteError.fsyncFailed(err)
            }

            if close(fd) != 0 {
                throw WriteError.fsyncFailed(errno)
            }
        } catch {
            throw error
        }

        let renameResult = tempURL.withUnsafeFileSystemRepresentation { src -> Int32 in
            guard let src else { errno = EINVAL; return -1 }
            return fileURL.withUnsafeFileSystemRepresentation { dst -> Int32 in
                guard let dst else { errno = EINVAL; return -1 }
                return rename(src, dst)
            }
        }
        guard renameResult == 0 else {
            throw WriteError.renameFailed(errno)
        }

        cleanupTemp = false
    }

    private static func formatResolvConf(
        header: String,
        nameservers: [String],
        searchDomains: [String]
    ) -> String {
        var lines = [header]
        if !searchDomains.isEmpty {
            lines.append("search " + searchDomains.joined(separator: " "))
        }
        for ns in nameservers {
            lines.append("nameserver \(ns)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func isValidIPv4(_ address: String) -> Bool {
        var addr = in_addr()
        return address.withCString { inet_pton(AF_INET, $0, &addr) == 1 }
    }

    private static func isValidIPv6(_ address: String) -> Bool {
        var addr = in6_addr()
        return address.withCString { inet_pton(AF_INET6, $0, &addr) == 1 }
    }

    private static func isValidZoneID(_ zone: String) -> Bool {
        zone.unicodeScalars.allSatisfy { scalar in
            let v = scalar.value
            return (v >= 48 && v <= 57) // 0-9
                || (v >= 65 && v <= 90) // A-Z
                || (v >= 97 && v <= 122) // a-z
                || v == 45 || v == 46 || v == 95 // - . _
        }
    }
}
