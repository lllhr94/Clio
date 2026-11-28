// SPDX-License-Identifier: GPL-3.0-or-later
// SkillSourceValidator.swift
// Pure Foundation, zero-UI, zero-network GitHub skill source parser & red-team validator for Clio.
// Ready for Batch 4 integration into `AgentKit/Sources/Craft/SkillSourceValidator.swift`
// and `App/Sources/SkillInstaller.swift` (fixes CLIO-022).

import Foundation

// MARK: - Output Model & Error Taxonomy

public struct ValidatedSkillSource: Equatable, Sendable, Codable {
    public let owner: String
    public let repo: String
    /// `nil` when the user pasted a bare repository URL (`https://github.com/<owner>/<repo>`)
    /// so the installer resolves the repository's default branch.
    public let ref: String?
    /// Normalized relative skill directory path (`""` for repository root, no leading/trailing `/`).
    public let subpath: String
    /// Validated decoded path segments of `subpath` (`[]` when `subpath` is empty).
    public let subpathSegments: [String]
    /// Strictly RFC 3986 unreserved percent-encoded single-component fields (`/` encoded as `%2F`).
    public let encodedOwner: String
    public let encodedRepo: String
    /// Query-safe encoded ref (`/` encoded as `%2F`) for `?ref=...`, or `nil` if `ref == nil`.
    public let encodedRefQueryValue: String?
    /// Path-safe segment-by-segment encoded ref (`feature/foo` -> `feature/foo`) for `codeload.github.com/.../zip/...`.
    public let encodedRefPathSegments: String?
    /// Segment-by-segment RFC 3986 unreserved-encoded relative path joined with `/`.
    public let encodedSubpath: String
    /// Ready-to-append GitHub REST Contents API path (+ optional `?ref=...`).
    public let gitHubContentsAPIPath: String

    public init(
        owner: String,
        repo: String,
        ref: String?,
        subpath: String,
        subpathSegments: [String],
        encodedOwner: String,
        encodedRepo: String,
        encodedRefQueryValue: String?,
        encodedRefPathSegments: String?,
        encodedSubpath: String,
        gitHubContentsAPIPath: String
    ) {
        self.owner = owner
        self.repo = repo
        self.ref = ref
        self.subpath = subpath
        self.subpathSegments = subpathSegments
        self.encodedOwner = encodedOwner
        self.encodedRepo = encodedRepo
        self.encodedRefQueryValue = encodedRefQueryValue
        self.encodedRefPathSegments = encodedRefPathSegments
        self.encodedSubpath = encodedSubpath
        self.gitHubContentsAPIPath = gitHubContentsAPIPath
    }

    /// Safe `codeload.github.com` archive URL paths (never interpolating unvalidated `ref`).
    public func gitHubArchiveZipPaths(resolvedDefaultBranch: String? = nil) -> [String] {
        var encodedRefs: [String] = []
        if let encodedRefPathSegments {
            encodedRefs.append(encodedRefPathSegments)
        } else if let branch = resolvedDefaultBranch,
                  case .success(let validated) = SkillSourceValidator.validate(owner: owner, repo: repo, ref: branch, subpath: ""),
                  let safeBranch = validated.encodedRefPathSegments {
            encodedRefs.append(safeBranch)
        } else {
            encodedRefs = ["main", "master"]
        }

        var paths: [String] = []
        for safeRef in encodedRefs {
            paths.append("/\(encodedOwner)/\(encodedRepo)/zip/refs/heads/\(safeRef)")
            paths.append("/\(encodedOwner)/\(encodedRepo)/zip/\(safeRef)")
        }
        return paths
    }
}

public enum SkillSourceValidationError: String, Error, Equatable, Sendable, Codable {
    case emptyInput
    case inputTooLong
    case controlOrNullByte
    case containsWhitespace
    case containsBackslash
    case invalidPercentEncoding
    case percentEncodedTraversalOrDelimiter
    case invalidURLSyntax
    case disallowedScheme
    case disallowedHost
    case forbiddenURLCredentialsOrPort
    case forbiddenURLQueryOrFragment
    case unsupportedURLPathFormat
    case invalidOwner
    case invalidRepo
    case invalidRef
    case emptyPathSegment
    case dotPathSegment
    case forbiddenGitInternalPath
    case invalidSubpathSegment
    case subpathTooLong
}

// MARK: - Pure Validator

public enum SkillSourceValidator {
    public enum Limits {
        public static let maxURLByteLength = 2048
        public static let maxOwnerLength = 39
        public static let maxRepoLength = 100
        public static let maxRefByteLength = 255
        public static let maxSubpathByteLength = 512
        public static let maxSubpathSegmentByteLength = 128
        public static let maxSubpathDepth = 16
    }

    private static let skillFileNamesLowercased: Set<String> = [
        "skill.md",
        "技能.md",
    ]

    /// Validates structured GitHub skill coordinates without making any network requests.
    /// Pass `ref: nil` only for bare repository targets (an explicit empty `""` is rejected as `.invalidRef`).
    public static func validate(
        owner: String,
        repo: String,
        ref: String? = nil,
        subpath: String = ""
    ) -> Result<ValidatedSkillSource, SkillSourceValidationError> {
        var fieldsToInspect = [owner, repo, subpath]
        if let ref { fieldsToInspect.append(ref) }
        for field in fieldsToInspect {
            if let hygieneError = inspectRawScalarAndPercentHygiene(field, allowPercentUTF8: false) {
                return .failure(hygieneError)
            }
        }

        if let ownerErr = validateOwner(owner) {
            return .failure(ownerErr)
        }
        if let repoErr = validateRepo(repo) {
            return .failure(repoErr)
        }
        if let ref, let refErr = validateRef(ref) {
            return .failure(refErr)
        }

        let segments: [String]
        switch validateAndSplitSubpath(subpath, decodePercentUTF8: false) {
        case .success(let validatedSegments):
            segments = validatedSegments
        case .failure(let err):
            return .failure(err)
        }

        let normalizedSubpath = segments.joined(separator: "/")
        let encOwner = encodeRFC3986Unreserved(owner)
        let encRepo = encodeRFC3986Unreserved(repo)
        let encRefQuery = ref.map(encodeRFC3986Unreserved)
        let encRefPath = ref.map { rawRef in
            rawRef
                .split(separator: "/", omittingEmptySubsequences: false)
                .map { encodeRFC3986Unreserved(String($0)) }
                .joined(separator: "/")
        }
        let encSubpath = segments.map(encodeRFC3986Unreserved).joined(separator: "/")

        var apiPath = "/repos/\(encOwner)/\(encRepo)/contents"
        if !encSubpath.isEmpty {
            apiPath += "/\(encSubpath)"
        }
        if let encRefQuery {
            apiPath += "?ref=\(encRefQuery)"
        }

        return .success(
            ValidatedSkillSource(
                owner: owner,
                repo: repo,
                ref: ref,
                subpath: normalizedSubpath,
                subpathSegments: segments,
                encodedOwner: encOwner,
                encodedRepo: encRepo,
                encodedRefQueryValue: encRefQuery,
                encodedRefPathSegments: encRefPath,
                encodedSubpath: encSubpath,
                gitHubContentsAPIPath: apiPath
            )
        )
    }

    /// Parses a user-pasted GitHub repository, `tree`, `blob`, or `raw` URL and validates all extracted coordinates.
    public static func parseAndValidate(
        urlString: String,
        allowRawContentDomain: Bool = true
    ) -> Result<ValidatedSkillSource, SkillSourceValidationError> {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(.emptyInput)
        }
        guard trimmed.utf8.count <= Limits.maxURLByteLength else {
            return .failure(.inputTooLong)
        }
        if let hygieneError = inspectRawScalarAndPercentHygiene(trimmed, allowPercentUTF8: true) {
            return .failure(hygieneError)
        }
        if trimmed.contains("?") || trimmed.contains("#") {
            return .failure(.forbiddenURLQueryOrFragment)
        }

        guard let schemeSeparatorRange = trimmed.range(of: "://") else {
            return .failure(.invalidURLSyntax)
        }
        let rawScheme = trimmed[..<schemeSeparatorRange.lowerBound].lowercased()
        guard rawScheme == "https" else {
            return .failure(.disallowedScheme)
        }

        let afterScheme = trimmed[schemeSeparatorRange.upperBound...]
        let authorityEnd = afterScheme.firstIndex(of: "/") ?? afterScheme.endIndex
        let rawAuthority = String(afterScheme[..<authorityEnd])
        guard !rawAuthority.isEmpty else {
            return .failure(.invalidURLSyntax)
        }
        if rawAuthority.contains("@") || rawAuthority.contains(":") || rawAuthority.contains("%") {
            return .failure(.forbiddenURLCredentialsOrPort)
        }

        let host = rawAuthority.lowercased()
        let isGitHubMain = (host == "github.com" || host == "www.github.com")
        let isGitHubRaw = allowRawContentDomain && (host == "raw.githubusercontent.com")
        guard isGitHubMain || isGitHubRaw else {
            return .failure(.disallowedHost)
        }

        guard authorityEnd < afterScheme.endIndex else {
            return .failure(.unsupportedURLPathFormat)
        }
        var rawPathAfterLeadingSlash = String(afterScheme[afterScheme.index(after: authorityEnd)...])
        // Allow a single benign trailing slash (e.g. `.../owner/repo/` or `.../tree/main/skills/foo/`),
        // while still rejecting double slashes `//` as `.emptyPathSegment`.
        if rawPathAfterLeadingSlash.hasSuffix("/") && !rawPathAfterLeadingSlash.hasSuffix("//") {
            rawPathAfterLeadingSlash.removeLast()
        }
        guard !rawPathAfterLeadingSlash.isEmpty else {
            return .failure(.unsupportedURLPathFormat)
        }

        let rawSegments = rawPathAfterLeadingSlash
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        if rawSegments.contains(where: { $0.isEmpty }) {
            return .failure(.emptyPathSegment)
        }

        if isGitHubMain {
            guard rawSegments.count >= 2 else {
                return .failure(.unsupportedURLPathFormat)
            }
            let owner = rawSegments[0]
            var repo = rawSegments[1]
            // Owner and repo must never carry percent escapes.
            if owner.contains("%") { return .failure(.invalidOwner) }
            if repo.contains("%") { return .failure(.invalidRepo) }

            // Bare repo URL: `https://github.com/<owner>/<repo>` (or `.git`)
            if rawSegments.count == 2 {
                if repo.lowercased().hasSuffix(".git") {
                    repo = String(repo.dropLast(4))
                }
                return validate(owner: owner, repo: repo, ref: nil, subpath: "")
            }

            guard rawSegments.count >= 4 else {
                return .failure(.unsupportedURLPathFormat)
            }
            let mode = rawSegments[2]
            guard mode == "tree" || mode == "blob" || mode == "raw" else {
                return .failure(.unsupportedURLPathFormat)
            }

            let ref: String
            let tailSegments: [String]
            if rawSegments.count >= 6 && rawSegments[3] == "refs" && (rawSegments[4] == "heads" || rawSegments[4] == "tags") {
                ref = rawSegments[5]
                tailSegments = Array(rawSegments.dropFirst(6))
            } else {
                ref = rawSegments[3]
                tailSegments = Array(rawSegments.dropFirst(4))
            }
            if ref.contains("%") { return .failure(.invalidRef) }

            if (mode == "blob" || mode == "raw") && tailSegments.isEmpty {
                return .failure(.unsupportedURLPathFormat)
            }

            // Decode & validate every tail segment BEFORE stripping a trailing SKILL.md / 技能.md filename.
            let validatedTail: [String]
            switch validateAndSplitSubpath(tailSegments.joined(separator: "/"), decodePercentUTF8: true) {
            case .success(let decoded):
                validatedTail = decoded
            case .failure(let err):
                return .failure(err)
            }

            var normalizedTail = validatedTail
            if (mode == "blob" || mode == "raw"),
               let last = normalizedTail.last,
               skillFileNamesLowercased.contains(last.lowercased()) {
                normalizedTail.removeLast()
            }
            return validate(
                owner: owner,
                repo: repo,
                ref: ref,
                subpath: normalizedTail.joined(separator: "/")
            )
        } else {
            // raw.githubusercontent.com/<owner>/<repo>/<ref>/<path...>
            // or raw.githubusercontent.com/<owner>/<repo>/refs/{heads|tags}/<ref>/<path...>
            guard rawSegments.count >= 4 else {
                return .failure(.unsupportedURLPathFormat)
            }
            let owner = rawSegments[0]
            let repo = rawSegments[1]
            if owner.contains("%") { return .failure(.invalidOwner) }
            if repo.contains("%") { return .failure(.invalidRepo) }

            let ref: String
            let tailSegments: [String]
            if rawSegments.count >= 6 && rawSegments[2] == "refs" && (rawSegments[3] == "heads" || rawSegments[3] == "tags") {
                ref = rawSegments[4]
                tailSegments = Array(rawSegments.dropFirst(5))
            } else {
                ref = rawSegments[2]
                tailSegments = Array(rawSegments.dropFirst(3))
            }
            if ref.contains("%") { return .failure(.invalidRef) }
            guard !tailSegments.isEmpty else {
                return .failure(.unsupportedURLPathFormat)
            }

            let validatedTail: [String]
            switch validateAndSplitSubpath(tailSegments.joined(separator: "/"), decodePercentUTF8: true) {
            case .success(let decoded):
                validatedTail = decoded
            case .failure(let err):
                return .failure(err)
            }

            var normalizedTail = validatedTail
            if let last = normalizedTail.last, skillFileNamesLowercased.contains(last.lowercased()) {
                normalizedTail.removeLast()
            }
            return validate(
                owner: owner,
                repo: repo,
                ref: ref,
                subpath: normalizedTail.joined(separator: "/")
            )
        }
    }

    // MARK: - Internal Security Primitives

    private static func inspectScalarHygiene(_ input: String) -> SkillSourceValidationError? {
        for scalar in input.unicodeScalars {
            let v = scalar.value
            if v <= 0x1F || v == 0x7F || (0x80...0x9F).contains(v) {
                return .controlOrNullByte
            }
            if v == 0x200B || v == 0x200C || v == 0x200D || v == 0xFEFF
                || (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v) {
                return .controlOrNullByte
            }
            if scalar.properties.isWhitespace {
                return .containsWhitespace
            }
            if scalar == "\\" {
                return .containsBackslash
            }
        }
        return nil
    }

    private static func inspectRawScalarAndPercentHygiene(
        _ input: String,
        allowPercentUTF8: Bool
    ) -> SkillSourceValidationError? {
        if let scalarErr = inspectScalarHygiene(input) {
            return scalarErr
        }

        let utf8 = Array(input.utf8)
        var i = 0
        while i < utf8.count {
            if utf8[i] == 0x25 { // '%'
                guard i + 2 < utf8.count,
                      let hi = hexNibble(utf8[i + 1]),
                      let lo = hexNibble(utf8[i + 2]) else {
                    return .invalidPercentEncoding
                }
                let byte = (hi << 4) | lo
                if byte <= 0x1F || byte == 0x7F {
                    return .controlOrNullByte
                }
                // Always block encoded '%'(0x25 -> double encoding), '.'(0x2E), '/'(0x2F), '\'(0x5C),
                // ' '(0x20), '?'(0x3F), '#'(0x23), '@'(0x40), '&'(0x26), '='(0x3D), '+'(0x2B), ':'(0x3A), ';'(0x3B).
                if byte == 0x25 || byte == 0x2E || byte == 0x2F || byte == 0x5C ||
                   byte == 0x20 || byte == 0x3F || byte == 0x23 || byte == 0x40 ||
                   byte == 0x26 || byte == 0x3D || byte == 0x2B || byte == 0x3A || byte == 0x3B {
                    return .percentEncodedTraversalOrDelimiter
                }
                if !allowPercentUTF8 {
                    return .percentEncodedTraversalOrDelimiter
                }
                // Inside URLs, percent-encoding is permitted ONLY for non-ASCII UTF-8 bytes (>= 0x80)
                // such as Chinese skill folder names copied from Safari.
                if byte < 0x80 {
                    return .percentEncodedTraversalOrDelimiter
                }
                i += 3
            } else {
                i += 1
            }
        }
        return nil
    }

    private static func validateOwner(_ owner: String) -> SkillSourceValidationError? {
        let bytes = Array(owner.utf8)
        guard !bytes.isEmpty, bytes.count <= Limits.maxOwnerLength else {
            return .invalidOwner
        }
        if owner == "." || owner == ".." || owner.contains("..") {
            return .invalidOwner
        }
        guard isASCIIAlphaNumeric(bytes[0]), isASCIIAlphaNumeric(bytes[bytes.count - 1]) else {
            return .invalidOwner
        }
        for b in bytes {
            if !(isASCIIAlphaNumeric(b) || b == 0x2D || b == 0x5F) { // '-' or '_'
                return .invalidOwner
            }
        }
        return nil
    }

    private static func validateRepo(_ repo: String) -> SkillSourceValidationError? {
        let bytes = Array(repo.utf8)
        guard !bytes.isEmpty, bytes.count <= Limits.maxRepoLength else {
            return .invalidRepo
        }
        if repo == "." || repo == ".." || repo.contains("..")
            || repo.lowercased() == ".git" || repo.lowercased().hasSuffix(".git") {
            return .invalidRepo
        }
        for b in bytes {
            if !(isASCIIAlphaNumeric(b) || b == 0x2D || b == 0x5F || b == 0x2E) {
                return .invalidRepo
            }
        }
        return nil
    }

    private static func validateRef(_ ref: String) -> SkillSourceValidationError? {
        let bytes = Array(ref.utf8)
        guard !bytes.isEmpty, bytes.count <= Limits.maxRefByteLength else {
            return .invalidRef
        }
        if ref.hasPrefix("/") || ref.hasSuffix("/") || ref.hasPrefix(".") || ref.hasSuffix(".") ||
           ref.contains("..") || ref.lowercased().hasSuffix(".lock") {
            return .invalidRef
        }
        let segments = ref.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for seg in segments {
            guard !seg.isEmpty, !seg.hasPrefix("."), !seg.lowercased().hasSuffix(".lock") else {
                return .invalidRef
            }
            for b in seg.utf8 {
                if !(isASCIIAlphaNumeric(b) || b == 0x2D || b == 0x5F || b == 0x2E) {
                    return .invalidRef
                }
            }
        }
        return nil
    }

    private static func validateAndSplitSubpath(
        _ subpath: String,
        decodePercentUTF8: Bool
    ) -> Result<[String], SkillSourceValidationError> {
        if subpath.isEmpty {
            return .success([])
        }
        if subpath.utf8.count > Limits.maxSubpathByteLength {
            return .failure(.subpathTooLong)
        }
        let rawSegments = subpath
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        if rawSegments.count > Limits.maxSubpathDepth {
            return .failure(.subpathTooLong)
        }

        var validated: [String] = []
        validated.reserveCapacity(rawSegments.count)
        var totalDecodedBytes = 0

        for rawSeg in rawSegments {
            if rawSeg.isEmpty {
                return .failure(.emptyPathSegment)
            }
            let seg: String
            if decodePercentUTF8 && rawSeg.contains("%") {
                guard let decoded = rawSeg.removingPercentEncoding else {
                    return .failure(.invalidPercentEncoding)
                }
                seg = decoded
            } else {
                seg = rawSeg
            }

            // Re-run full scalar hygiene on decoded UTF-8 (catches percent-encoded BiDi/zero-width/C1 controls!).
            if let hygieneErr = inspectScalarHygiene(seg) {
                return .failure(hygieneErr)
            }
            if seg.contains("/") || seg.contains("\\") {
                return .failure(.percentEncodedTraversalOrDelimiter)
            }
            if seg == "." || seg == ".." || seg.contains("..") {
                return .failure(.dotPathSegment)
            }
            if seg.lowercased() == ".git" {
                return .failure(.forbiddenGitInternalPath)
            }
            let byteCount = seg.utf8.count
            if byteCount > Limits.maxSubpathSegmentByteLength {
                return .failure(.subpathTooLong)
            }
            totalDecodedBytes += byteCount + (validated.isEmpty ? 0 : 1)
            if totalDecodedBytes > Limits.maxSubpathByteLength {
                return .failure(.subpathTooLong)
            }
            for scalar in seg.unicodeScalars {
                if scalar.isASCII {
                    let b = UInt8(scalar.value)
                    if !(isASCIIAlphaNumeric(b) || b == 0x2D || b == 0x5F || b == 0x2E) {
                        return .failure(.invalidSubpathSegment)
                    }
                } else {
                    // Allow legitimate non-ASCII letters/digits (e.g. CJK skill names like `写作助手`, `技能.md`),
                    // rejecting private-use, unassigned, surrogate, or symbol injection ranges.
                    guard scalar.properties.isAlphabetic || CharacterSet.decimalDigits.contains(scalar) else {
                        return .failure(.invalidSubpathSegment)
                    }
                }
            }
            validated.append(seg)
        }
        return .success(validated)
    }

    private static func encodeRFC3986Unreserved(_ string: String) -> String {
        let hexChars: [Character] = Array("0123456789ABCDEF")
        var out = String()
        out.reserveCapacity(string.utf8.count)
        for b in string.utf8 {
            if isASCIIAlphaNumeric(b) || b == 0x2D || b == 0x2E || b == 0x5F || b == 0x7E {
                out.append(Character(UnicodeScalar(b)))
            } else {
                out.append("%")
                out.append(hexChars[Int(b >> 4)])
                out.append(hexChars[Int(b & 0x0F)])
            }
        }
        return out
    }

    private static func isASCIIAlphaNumeric(_ b: UInt8) -> Bool {
        (0x30...0x39).contains(b) || (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b)
    }

    private static func hexNibble(_ b: UInt8) -> UInt8? {
        switch b {
        case 0x30...0x39: return b - 0x30
        case 0x41...0x46: return b - 0x41 + 10
        case 0x61...0x66: return b - 0x61 + 10
        default: return nil
        }
    }
}
