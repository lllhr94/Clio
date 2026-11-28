import Craft
import XCTest

final class SkillSourceValidatorTests: XCTestCase {
    func testAcceptsStandardGitHubRepoTreeBlobRawAndChineseUTF8Subpaths() throws {
        let bare = try SkillSourceValidator.parseAndValidate(urlString: "https://github.com/lllhr94/Clio").get()
        XCTAssertEqual(bare.owner, "lllhr94")
        XCTAssertEqual(bare.repo, "Clio")
        XCTAssertNil(bare.ref)
        XCTAssertEqual(bare.subpath, "")
        XCTAssertEqual(bare.gitHubContentsAPIPath, "/repos/lllhr94/Clio/contents")
        XCTAssertEqual(
            bare.gitHubArchiveZipPaths(resolvedDefaultBranch: "main"),
            ["/lllhr94/Clio/zip/refs/heads/main", "/lllhr94/Clio/zip/main"]
        )

        let tree = try SkillSourceValidator.parseAndValidate(
            urlString: "https://github.com/lllhr94/Clio/tree/release-1.0/skills/%E5%86%99%E4%BD%9C%E5%8A%A9%E6%89%8B/"
        ).get()
        XCTAssertEqual(tree.ref, "release-1.0")
        XCTAssertEqual(tree.subpath, "skills/写作助手")
        XCTAssertEqual(tree.subpathSegments, ["skills", "写作助手"])
        XCTAssertEqual(
            tree.gitHubContentsAPIPath,
            "/repos/lllhr94/Clio/contents/skills/%E5%86%99%E4%BD%9C%E5%8A%A9%E6%89%8B?ref=release-1.0"
        )

        let blob = try SkillSourceValidator.parseAndValidate(
            urlString: "https://github.com/lllhr94/Clio/blob/main/skills/demo/SKILL.md"
        ).get()
        XCTAssertEqual(blob.subpath, "skills/demo")

        let raw = try SkillSourceValidator.parseAndValidate(
            urlString: "https://raw.githubusercontent.com/lllhr94/Clio/refs/heads/main/skills/demo/%E6%8A%80%E8%83%BD.md"
        ).get()
        XCTAssertEqual(raw.ref, "main")
        XCTAssertEqual(raw.subpath, "skills/demo")
    }

    func testBlocksRefTraversalDoubleEncodingQueryAndHostSpoofing() {
        let attacks: [(String, SkillSourceValidationError)] = [
            ("https://github.com/owner/repo/tree/..%2F..%2Fvictim/skills", .percentEncodedTraversalOrDelimiter),
            ("https://github.com/owner/repo/tree/main/skills/%252e%252e/secret", .percentEncodedTraversalOrDelimiter),
            ("https://github.com/owner/repo/tree/main/skills/../secret", .dotPathSegment),
            ("https://github.com/owner/repo/tree/main/.git/config", .forbiddenGitInternalPath),
            ("https://github.com/owner/repo/tree/main/skills?ref=evil", .forbiddenURLQueryOrFragment),
            ("https://github.com/owner/repo/tree/main/skills#frag", .forbiddenURLQueryOrFragment),
            ("https://user:pass@github.com/owner/repo", .forbiddenURLCredentialsOrPort),
            ("https://github.com:8443/owner/repo", .forbiddenURLCredentialsOrPort),
            ("http://github.com/owner/repo", .disallowedScheme),
            ("https://evil.example.com/owner/repo", .disallowedHost),
            ("https://github.com/owner/repo/tree/main/skills\\evil", .containsBackslash),
            ("https://github.com/owner/repo/tree/main/skills/\u{202E}evil", .controlOrNullByte),
            ("https://github.com/owner/repo/tree/main//skills", .emptyPathSegment),
        ]

        for (url, expected) in attacks {
            switch SkillSourceValidator.parseAndValidate(urlString: url) {
            case .success(let value):
                XCTFail("Expected attack URL \(url) to fail with \(expected), got \(value)")
            case .failure(let actual):
                XCTAssertEqual(actual, expected, "Mismatch for \(url)")
            }
        }
    }

    func testArchiveZipPathsRejectPoisonedDefaultBranchAndFallBackSafely() throws {
        let bare = try SkillSourceValidator.validate(owner: "lllhr94", repo: "Clio", ref: nil, subpath: "").get()
        let poisoned = bare.gitHubArchiveZipPaths(resolvedDefaultBranch: "../../victim/repo")
        XCTAssertEqual(
            poisoned,
            [
                "/lllhr94/Clio/zip/refs/heads/main",
                "/lllhr94/Clio/zip/main",
                "/lllhr94/Clio/zip/refs/heads/master",
                "/lllhr94/Clio/zip/master",
            ]
        )

        let slashRef = try SkillSourceValidator.validate(owner: "lllhr94", repo: "Clio", ref: "feature/v1", subpath: "").get()
        XCTAssertEqual(slashRef.encodedRefQueryValue, "feature%2Fv1")
        XCTAssertEqual(slashRef.encodedRefPathSegments, "feature/v1")
        XCTAssertEqual(
            slashRef.gitHubArchiveZipPaths(),
            ["/lllhr94/Clio/zip/refs/heads/feature/v1", "/lllhr94/Clio/zip/feature/v1"]
        )
    }
}
