import AgentKit
import Craft
import Darwin
import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ZIPFoundation

/// Stages, inspects, and installs skills from a GitHub directory URL, zip URL, SKILL.md URL, or local zip file.
/// Nothing is written into 书案/技能 until the user reviews the skill metadata and file list and confirms.
enum SkillInstaller {
    enum Problem: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self {
            case .message(let text): return text
            }
        }
    }

    struct FileEntry: Identifiable, Hashable, Sendable {
        let path: String
        let bytes: Int
        let isScript: Bool
        var id: String { path }
    }

    struct StagedSkill: Identifiable, Equatable, Sendable {
        let id: String
        let skill: Skill
        let directory: URL
        let folderName: String
        let files: [FileEntry]
        let willOverwrite: Bool

        var scripts: [FileEntry] { files.filter(\.isScript) }
        var totalBytes: Int { files.reduce(0) { $0 + $1.bytes } }
    }

    struct StagedBatch: Sendable {
        let scratchRoot: URL
        let skills: [StagedSkill]

        func cleanup() {
            try? FileManager.default.removeItem(at: scratchRoot)
        }
    }

    private final class PublicRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest
        ) async -> URLRequest? {
            guard let next = request.url, await URLAccessPurpose.skillDownload.allows(next) else { return nil }
            return request
        }
    }

    private static let maxArchiveBytes = 32 << 20
    private static let maxUncompressedBytes = 32 << 20
    private static let maxFileCount = 256
    private static let maxSingleTextBytes = 2 << 20
    private static let skillFileNames = ["SKILL.md", "skill.md", "技能.md"]
    private static let scriptExtensions: Set<String> = [
        "sh", "bash", "zsh", "fish", "ksh",
        "py", "pyw", "js", "mjs", "cjs", "ts", "mts", "cts",
        "rb", "pl", "php", "lua", "swift",
        "command", "bat", "cmd", "ps1", "exe", "bin", "so", "dylib",
    ]

    // MARK: Entry points

    /// Stages a local `.zip` file chosen from the Files app into a temporary directory for user review.
    static func stageLocalZip(_ url: URL) async throws -> StagedBatch {
        let scratch = makeScratchDir()
        do {
            try await Task.detached(priority: .userInitiated) {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                    throw Problem.message("读不到这个 zip 文件的大小。")
                }
                guard size <= maxArchiveBytes else {
                    throw Problem.message("压缩包太大了（超过 32 MB）。")
                }
                guard let archive = try? Archive(url: url, accessMode: .read) else {
                    throw Problem.message("打不开这个 zip 文件，可能已损坏或格式不对。")
                }
                try extract(archive, into: scratch)
            }.value
            let skills = try discoverSkills(in: scratch, preferredName: url.deletingPathExtension().lastPathComponent)
            return StagedBatch(scratchRoot: scratch, skills: skills)
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            throw error
        }
    }

    /// Stages a skill from a pasted HTTPS URL (GitHub folder/repo/SKILL.md link, remote zip URL, or raw SKILL.md URL).
    static func stageURL(_ rawText: String) async throws -> StagedBatch {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https", url.host != nil else {
            throw Problem.message("请输入完整的 https:// 链接（支持 GitHub 目录链接、zip 链接或 SKILL.md 链接）。")
        }
        guard await URLAccessPurpose.skillDownload.allows(url) else {
            throw Problem.message("不能从本机或局域网地址安装技能，请使用公网 https 链接。")
        }

        let scratch = makeScratchDir()
        do {
            if let gh = try parseGitHubURL(trimmed) {
                try await fetchGitHub(gh, into: scratch)
                let fallback = gh.subpathSegments.last ?? gh.repo
                let skills = try discoverSkills(in: scratch, preferredName: fallback)
                return StagedBatch(scratchRoot: scratch, skills: skills)
            }

            let lowerPath = url.path.lowercased()
            if lowerPath.hasSuffix(".md") || lowerPath.hasSuffix(".markdown") {
                let data = try await downloadBytes(from: url, limit: maxSingleTextBytes)
                guard String(data: data, encoding: .utf8) != nil else {
                    throw Problem.message("这个链接返回的不是有效的文本文件。")
                }
                try data.write(to: scratch.appendingPathComponent("SKILL.md"), options: .atomic)
                let fallback = url.deletingPathExtension().lastPathComponent
                let skills = try discoverSkills(in: scratch, preferredName: fallback.lowercased() == "skill" ? "新技能" : fallback)
                return StagedBatch(scratchRoot: scratch, skills: skills)
            }

            // Treat any other URL as a zip archive download.
            let zipFile = scratch.appendingPathComponent(".download.zip")
            try await downloadToFile(from: url, to: zipFile, limit: maxArchiveBytes)
            let extractRoot = scratch.appendingPathComponent("extracted", isDirectory: true)
            try FileManager.default.createDirectory(at: extractRoot, withIntermediateDirectories: true)
            try await Task.detached(priority: .userInitiated) {
                guard let archive = try? Archive(url: zipFile, accessMode: .read) else {
                    throw Problem.message("下载完成但不是有效的 zip 文件。如果是 GitHub 技能，请直接贴 GitHub 文件夹链接。")
                }
                try extract(archive, into: extractRoot)
            }.value
            try? FileManager.default.removeItem(at: zipFile)
            let skills = try discoverSkills(in: extractRoot, preferredName: url.deletingPathExtension().lastPathComponent)
            return StagedBatch(scratchRoot: scratch, skills: skills)
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            throw error
        }
    }

    /// Atomically installs a user-confirmed staged skill into `书案/技能/<folderName>/`.
    static func install(_ staged: StagedSkill) throws {
        let fm = FileManager.default
        let skillsRoot = SkillShelf.folder
        let folderName = SkillShelf.safe(staged.folderName)
        guard !folderName.isEmpty,
              !folderName.hasPrefix("."),
              folderName != ".",
              folderName != "..",
              !folderName.contains("/"),
              !folderName.contains("\\") else {
            throw Problem.message("技能目录名称无效。")
        }
        let finalFolder = skillsRoot.appendingPathComponent(folderName, isDirectory: true)
        let rootStd = skillsRoot.standardizedFileURL.path
        let rootReal = skillsRoot.resolvingSymlinksInPath().standardizedFileURL.path
        guard finalFolder.standardizedFileURL.path != rootStd,
              finalFolder.resolvingSymlinksInPath().standardizedFileURL.path != rootReal,
              Workspace.isInsideRealRoot(finalFolder, root: skillsRoot) else {
            throw Problem.message("技能安装路径越界：\(folderName)")
        }
        var finalStat = stat()
        if lstat(finalFolder.path, &finalStat) == 0, (finalStat.st_mode & S_IFMT) == S_IFLNK {
            throw Problem.message("目标技能目录是软链接，已拒绝覆盖：\(folderName)")
        }

        let tempTarget = skillsRoot.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempTarget, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempTarget) }

        let srcBase = staged.directory.resolvingSymlinksInPath().standardizedFileURL.path
        let tempBase = tempTarget.resolvingSymlinksInPath().standardizedFileURL.path
        for entry in staged.files {
            let source = entry.path.split(separator: "/").reduce(staged.directory) { $0.appendingPathComponent(String($1)) }
            let resolvedSrc = source.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolvedSrc.hasPrefix(srcBase + "/") else {
                throw Problem.message("技能包里包含异常路径：\(entry.path)")
            }
            let destination = entry.path.split(separator: "/").reduce(tempTarget) { $0.appendingPathComponent(String($1)) }
            let resolvedDest = destination.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolvedDest.hasPrefix(tempBase + "/") else {
                throw Problem.message("技能包里包含越界路径：\(entry.path)")
            }
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try Data(contentsOf: source)
            try data.write(to: destination, options: .atomic)
        }

        if fm.fileExists(atPath: finalFolder.path) {
            _ = try fm.replaceItemAt(finalFolder, withItemAt: tempTarget)
        } else {
            try fm.moveItem(at: tempTarget, to: finalFolder)
        }
        // Only after the new skill is in place: remove any case-variant directories or legacy single-file skills with the same case-insensitive name.
        if let existingEntries = try? fm.contentsOfDirectory(at: skillsRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for existing in existingEntries {
                let existingName = existing.lastPathComponent
                let matchesFolder = existingName.localizedCaseInsensitiveCompare(folderName) == .orderedSame
                let matchesSingle = existingName.localizedCaseInsensitiveCompare(folderName + ".md") == .orderedSame
                guard matchesFolder || matchesSingle else { continue }
                guard Workspace.isInsideRealRoot(existing, root: skillsRoot),
                      existing.standardizedFileURL.path != rootStd else { continue }
                if existing.standardizedFileURL.path != finalFolder.standardizedFileURL.path {
                    try? fm.removeItem(at: existing)
                }
            }
        }

        let legacySingle = skillsRoot.appendingPathComponent(folderName + ".md")
        if Workspace.isInsideRealRoot(legacySingle, root: skillsRoot), fm.fileExists(atPath: legacySingle.path) {
            try? fm.removeItem(at: legacySingle)
        }
        SkillShelf.invalidate()
    }

    // MARK: GitHub resolution

    private static func isDirectGitHubZipURL(_ rawText: String, url: URL) -> Bool {
        guard let host = url.host?.lowercased(), host == "github.com" || host == "www.github.com" else {
            return false
        }
        guard !rawText.contains("?"), !rawText.contains("#"), !rawText.contains("\\"),
              !rawText.contains(".."), !rawText.lowercased().contains("%2e"), !rawText.lowercased().contains("%2f"),
              url.user == nil, url.password == nil, url.port == nil else {
            return false
        }
        let parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard parts.count >= 4,
              let last = parts.last?.lowercased(), last.hasSuffix(".zip") else {
            return false
        }
        let kind = parts[2].lowercased()
        return kind == "archive" || kind == "releases"
    }

    static func parseGitHubURL(_ rawText: String) throws -> ValidatedSkillSource? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host?.lowercased() else {
            return nil
        }
        let isGitHubHost = host == "github.com" || host == "www.github.com" || host == "raw.githubusercontent.com"
        guard isGitHubHost else { return nil }
        if isDirectGitHubZipURL(trimmed, url: url) {
            return nil
        }
        switch SkillSourceValidator.parseAndValidate(urlString: trimmed, allowRawContentDomain: true) {
        case .success(let validated):
            return validated
        case .failure(let error):
            throw Problem.message(validationMessage(for: error))
        }
    }

    private static func validationMessage(for error: SkillSourceValidationError) -> String {
        switch error {
        case .disallowedScheme:
            return "技能链接必须使用 https:// 协议。"
        case .disallowedHost:
            return "不受支持的 GitHub 主机地址。"
        case .forbiddenURLCredentialsOrPort:
            return "技能链接不能包含用户名、密码或自定义端口。"
        case .forbiddenURLQueryOrFragment:
            return "GitHub 技能链接不能包含查询参数或锚点。"
        case .controlOrNullByte, .containsWhitespace, .containsBackslash,
             .invalidPercentEncoding, .percentEncodedTraversalOrDelimiter,
             .dotPathSegment, .forbiddenGitInternalPath:
            return "GitHub 技能链接包含不安全的路径或编码字符，已拒绝解析。"
        default:
            return "无法识别这个 GitHub 技能链接，请粘贴公开仓库、目录或 SKILL.md 的标准链接。"
        }
    }

    private static func fetchGitHub(_ target: ValidatedSkillSource, into scratch: URL) async throws {
        // First try GitHub Contents API for subpaths or repo roots (fast, fetches only the requested folder).
        do {
            try await fetchGitHubContents(target, into: scratch)
            return
        } catch {
            // Fall back to branch archive zip when API rate limit (403/429) or non-standard branch hits.
            try? clearDirectory(scratch)
        }
        try await fetchGitHubArchive(target, into: scratch)
    }

    private static func fetchGitHubContents(_ target: ValidatedSkillSource, into scratch: URL) async throws {
        var totalBytes = 0
        var fileCount = 0

        func walk(source: ValidatedSkillSource, localBase: URL) async throws {
            try Task.checkCancellation()
            guard let apiURL = URL(string: "https://api.github.com\(source.gitHubContentsAPIPath)") else {
                throw Problem.message("无法解析 GitHub 链接。")
            }
            let jsonData = try await downloadBytes(from: apiURL, limit: 4 << 20, accept: "application/vnd.github+json")
            let parsed = try JSONSerialization.jsonObject(with: jsonData)
            let entries: [[String: Any]]
            if let array = parsed as? [[String: Any]] {
                entries = array
            } else if let single = parsed as? [String: Any] {
                entries = [single]
            } else {
                throw Problem.message("GitHub 返回了无法解析的目录结构。")
            }
            for item in entries {
                try Task.checkCancellation()
                guard let name = item["name"] as? String, !name.isEmpty,
                      name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
                      let type = item["type"] as? String else { continue }
                if name == ".DS_Store" || name == "__MACOSX" { continue }
                if type == "dir" {
                    let nextSubpath = source.subpath.isEmpty ? name : "\(source.subpath)/\(name)"
                    guard case .success(let childSource) = SkillSourceValidator.validate(
                        owner: source.owner,
                        repo: source.repo,
                        ref: source.ref,
                        subpath: nextSubpath
                    ) else { continue }
                    let nextLocal = localBase.appendingPathComponent(name, isDirectory: true)
                    guard nextLocal.standardizedFileURL.path.hasPrefix(scratch.standardizedFileURL.path + "/") else { continue }
                    try FileManager.default.createDirectory(at: nextLocal, withIntermediateDirectories: true)
                    try await walk(source: childSource, localBase: nextLocal)
                } else if type == "file" {
                    fileCount += 1
                    guard fileCount <= maxFileCount else { throw Problem.message("技能目录里的文件太多了（超过 \(maxFileCount) 个）。") }
                    guard let downloadString = item["download_url"] as? String,
                          let downloadURL = URL(string: downloadString),
                          downloadURL.scheme?.lowercased() == "https",
                          await URLAccessPurpose.skillDownload.allows(downloadURL) else { continue }
                    let remaining = maxUncompressedBytes - totalBytes
                    guard remaining > 0 else { throw Problem.message("技能总大小超过了 32 MB。") }
                    let data = try await downloadBytes(from: downloadURL, limit: remaining)
                    totalBytes += data.count
                    let destination = localBase.appendingPathComponent(name)
                    guard destination.standardizedFileURL.path.hasPrefix(scratch.standardizedFileURL.path + "/") else { continue }
                    try data.write(to: destination, options: .atomic)
                }
            }
        }

        try await walk(source: target, localBase: scratch)
    }

    private static func fetchGitHubArchive(_ target: ValidatedSkillSource, into scratch: URL) async throws {
        let defaultBranch: String?
        if target.ref == nil {
            defaultBranch = await fetchDefaultBranch(encodedOwner: target.encodedOwner, encodedRepo: target.encodedRepo)
        } else {
            defaultBranch = nil
        }

        let zipPaths = target.gitHubArchiveZipPaths(resolvedDefaultBranch: defaultBranch)
        let zipFile = scratch.appendingPathComponent(".github.zip")
        var downloaded = false
        var lastError: Error?
        for path in zipPaths {
            guard let url = URL(string: "https://codeload.github.com\(path)") else { continue }
            do {
                try await downloadToFile(from: url, to: zipFile, limit: maxArchiveBytes)
                downloaded = true
                break
            } catch {
                lastError = error
                try? FileManager.default.removeItem(at: zipFile)
            }
        }
        guard downloaded else {
            throw lastError ?? Problem.message("没能从 GitHub 下载这个技能目录，请检查链接是否公开且有效。")
        }

        let extractRoot = scratch.appendingPathComponent("archive", isDirectory: true)
        try FileManager.default.createDirectory(at: extractRoot, withIntermediateDirectories: true)
        let subpath = target.subpath
        try await Task.detached(priority: .userInitiated) {
            guard let archive = try? Archive(url: zipFile, accessMode: .read) else {
                throw Problem.message("下载的 GitHub 压缩包打不开。")
            }
            try extract(archive, into: extractRoot, stripTopAndFilterSubpath: subpath.isEmpty ? nil : subpath)
        }.value
        try? FileManager.default.removeItem(at: zipFile)
    }

    private static func fetchDefaultBranch(encodedOwner: String, encodedRepo: String) async -> String? {
        guard let url = URL(string: "https://api.github.com/repos/\(encodedOwner)/\(encodedRepo)") else { return nil }
        guard let data = try? await downloadBytes(from: url, limit: 256 << 10, accept: "application/vnd.github+json"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let branch = json["default_branch"] as? String, !branch.isEmpty else { return nil }
        return branch
    }

    // MARK: Safe ZIP extraction (mirrors PetLibrary limits & path traversal checks)

    nonisolated private static func extract(_ archive: Archive, into scratch: URL, stripTopAndFilterSubpath subpath: String? = nil) throws {
        let fm = FileManager.default
        let limit = maxUncompressedBytes
        var written = 0
        var count = 0
        let normalizedSub = subpath?
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty } ?? []

        for entry in archive {
            try Task.checkCancellation()
            guard entry.type != .symlink else {
                throw Problem.message("压缩包里包含软链接，出于安全考虑已拒绝解压。")
            }
            guard entry.type == .file else { continue }
            let rawPath = entry.path
            guard !rawPath.isEmpty, !rawPath.hasPrefix("/"), !rawPath.contains("\\") else { continue }
            let parts = rawPath.split(separator: "/").map(String.init)
            guard !parts.isEmpty, !parts.contains(".."), !parts.contains("."), parts.first != "__MACOSX", parts.last != ".DS_Store" else { continue }

            let relativeParts: [String]
            if !normalizedSub.isEmpty {
                // GitHub zip entries start with `<repo>-<ref>/<subpath>/...`.
                guard parts.count > 1 + normalizedSub.count else { continue }
                let afterTop = Array(parts.dropFirst())
                guard Array(afterTop.prefix(normalizedSub.count)) == normalizedSub else { continue }
                relativeParts = Array(afterTop.dropFirst(normalizedSub.count))
            } else {
                relativeParts = parts
            }
            guard !relativeParts.isEmpty else { continue }

            count += 1
            guard count <= maxFileCount else {
                throw Problem.message("压缩包里的文件太多了（超过 \(maxFileCount) 个）。")
            }

            let target = relativeParts.reduce(scratch) { $0.appendingPathComponent($1) }.standardizedFileURL
            guard target.path.hasPrefix(scratch.standardizedFileURL.path + "/") else { continue }
            guard entry.uncompressedSize <= UInt64(limit - written) else {
                throw Problem.message("解开的文件太大了（超过 32 MB）。")
            }

            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard !fm.fileExists(atPath: target.path), fm.createFile(atPath: target.path, contents: nil) else {
                throw Problem.message("压缩包里有重复或无效的文件名。")
            }
            let handle = try FileHandle(forWritingTo: target)
            defer { try? handle.close() }
            var size = 0
            let checksum = try archive.extract(entry) { chunk in
                guard chunk.count <= limit - written else {
                    throw Problem.message("解开的文件超过 32 MB 限制。")
                }
                try Task.checkCancellation()
                try handle.write(contentsOf: chunk)
                written += chunk.count
                size += chunk.count
            }
            guard UInt64(size) == entry.uncompressedSize, checksum == entry.checksum else {
                throw Problem.message("压缩包里的文件大小或校验不对。")
            }
        }
    }

    // MARK: Skill discovery & script inspection

    private static func discoverSkills(in root: URL, preferredName: String) throws -> [StagedSkill] {
        let fm = FileManager.default
        var skillDirs: [URL] = []

        func scan(_ dir: URL, depth: Int) {
            guard depth <= 4 else { return }
            if skillFile(in: dir) != nil {
                skillDirs.append(dir)
                return
            }
            let children = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            for child in children {
                guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                scan(child, depth: depth + 1)
            }
        }

        scan(root, depth: 0)
        guard !skillDirs.isEmpty else {
            throw Problem.message("没有在里面找到 SKILL.md，不能当成技能安装。")
        }

        let existingNamesLower: Set<String> = Set(
            ((try? fm.contentsOfDirectory(at: SkillShelf.folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
                .map { $0.lastPathComponent.lowercased() }
        )

        var staged: [StagedSkill] = []
        for dir in skillDirs {
            guard let manifest = skillFile(in: dir),
                  let text = try? String(contentsOf: manifest, encoding: .utf8) else { continue }
            let dirName = dir.standardizedFileURL.path == root.standardizedFileURL.path
                ? preferredName
                : dir.lastPathComponent
            let skill = Skill.parse(text, fallback: dirName.isEmpty ? "新技能" : dirName)
            let files = collectFiles(in: dir)
            guard !files.isEmpty else { continue }
            let folderName = SkillShelf.safe(skill.name)
            let existingFolder = SkillShelf.folder.appendingPathComponent(folderName)
            let existingFile = SkillShelf.folder.appendingPathComponent(folderName + ".md")
            let lowerFolder = folderName.lowercased()
            let willOverwrite = fm.fileExists(atPath: existingFolder.path)
                || fm.fileExists(atPath: existingFile.path)
                || existingNamesLower.contains(lowerFolder)
                || existingNamesLower.contains(lowerFolder + ".md")
            staged.append(StagedSkill(
                id: dir.path,
                skill: skill,
                directory: dir,
                folderName: folderName,
                files: files,
                willOverwrite: willOverwrite
            ))
        }
        guard !staged.isEmpty else {
            throw Problem.message("找到的 SKILL.md 读不出来（请确认是 UTF-8 文本）。")
        }
        return staged
    }

    private static func skillFile(in dir: URL) -> URL? {
        let fm = FileManager.default
        for name in skillFileNames {
            let url = dir.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    private static func collectFiles(in dir: URL) -> [FileEntry] {
        let fm = FileManager.default
        let baseURL = dir.resolvingSymlinksInPath().standardizedFileURL
        let base = baseURL.path
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let walker = fm.enumerator(at: baseURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        var entries: [FileEntry] = []
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isSymbolicLink != true,
                  values.isRegularFile == true else { continue }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolved.hasPrefix(base + "/") else { continue }
            let rel = String(resolved.dropFirst(base.count + 1))
            let bytes = values.fileSize ?? 0
            entries.append(FileEntry(path: rel, bytes: bytes, isScript: isScriptFile(url: url, relativePath: rel)))
        }
        return entries.sorted { lhs, rhs in
            let lSkill = skillFileNames.contains(lhs.path)
            let rSkill = skillFileNames.contains(rhs.path)
            if lSkill != rSkill { return lSkill }
            if lhs.isScript != rhs.isScript { return lhs.isScript }
            return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
    }

    private static func isScriptFile(url: URL, relativePath: String) -> Bool {
        let ext = url.pathExtension.lowercased()
        if scriptExtensions.contains(ext) { return true }
        let fileName = url.lastPathComponent.lowercased()
        if fileName == "makefile" || fileName == "gnumakefile" || fileName.hasPrefix("makefile.") || fileName.hasSuffix(".mk") {
            return true
        }
        let lower = relativePath.lowercased()
        if lower.hasPrefix("scripts/") || lower.hasPrefix("bin/") || lower.contains("/scripts/") || lower.contains("/bin/") {
            return true
        }
        // Check for Unix shebang `#!`, ELF (`\x7FELF`), or Mach-O / Fat Mach-O magic bytes.
        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            if let head = try? handle.read(upToCount: 4) {
                let bytes = [UInt8](head)
                if bytes.count >= 2, bytes[0] == 0x23, bytes[1] == 0x21 {
                    return true
                }
                if bytes.count >= 4 {
                    if bytes[0] == 0x7F, bytes[1] == 0x45, bytes[2] == 0x4C, bytes[3] == 0x46 {
                        return true
                    }
                    let magic = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
                    switch magic {
                    case 0xFEEDFACE, 0xCEFAEDFE, 0xFEEDFACF, 0xCFFAEDFE,
                         0xCAFEBABE, 0xBEBAFECA, 0xCAFEBABF, 0xBFBAFECA:
                        return true
                    default:
                        break
                    }
                }
            }
        }
        return false
    }

    // MARK: Public HTTPS streaming download helpers

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config, delegate: PublicRedirectGuard(), delegateQueue: nil)
    }

    private static func downloadBytes(from url: URL, limit: Int, accept: String? = nil) async throws -> Data {
        guard await URLAccessPurpose.skillDownload.allows(url) else {
            throw Problem.message("只允许从公网 https 链接下载。")
        }
        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue("Clio-Skill-Installer/1.0", forHTTPHeaderField: "User-Agent")
        if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Problem.message("下载失败：服务器没有正常回应。")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Problem.message("下载失败（HTTP \(http.statusCode)）。请确认链接是公开可访问的。")
        }
        if let finalURL = http.url, !(await URLAccessPurpose.skillDownload.allows(finalURL)) {
            throw Problem.message("链接跳转到了本机或局域网地址，已中止。")
        }
        var out = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            out.append(byte)
            if out.count > limit {
                throw Problem.message("下载内容超过大小限制。")
            }
        }
        return out
    }

    private static func downloadToFile(from url: URL, to destination: URL, limit: Int) async throws {
        guard await URLAccessPurpose.skillDownload.allows(url) else {
            throw Problem.message("只允许从公网 https 链接下载。")
        }
        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue("Clio-Skill-Installer/1.0", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Problem.message("下载失败：服务器没有正常回应。")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Problem.message("下载失败（HTTP \(http.statusCode)）。请确认链接是公开可访问的。")
        }
        if let finalURL = http.url, !(await URLAccessPurpose.skillDownload.allows(finalURL)) {
            throw Problem.message("链接跳转到了本机或局域网地址，已中止。")
        }
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        guard fm.createFile(atPath: destination.path, contents: nil) else {
            throw Problem.message("没能在临时目录创建文件。")
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var total = 0
        var buffer = Data()
        buffer.reserveCapacity(16_384)
        for try await byte in bytes {
            try Task.checkCancellation()
            buffer.append(byte)
            total += 1
            if total > limit {
                throw Problem.message("压缩包太大了（超过 32 MB）。")
            }
            if buffer.count >= 16_384 {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
    }

    private static func makeScratchDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("clio-skill-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func clearDirectory(_ dir: URL) throws {
        let fm = FileManager.default
        for item in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            try fm.removeItem(at: item)
        }
    }
}

// MARK: Install Sheet UI

/// Sheet for installing a skill from a GitHub directory URL, remote zip, or local zip file with preview confirmation.
struct SkillInstallSheet: View {
    var onInstalled: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var urlText = ""
    @State private var pickingZip = false
    @State private var busy = false
    @State private var statusText: String?
    @State private var errorText: String?
    @State private var batch: SkillInstaller.StagedBatch?
    @State private var selected: SkillInstaller.StagedSkill?
    @State private var showBody = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Ink.Space.xl) {
                    if let selected {
                        previewView(selected)
                    } else if let batch, batch.skills.count > 1 {
                        chooseSkillView(batch)
                    } else {
                        sourceView
                    }
                }
                .padding(.horizontal, Ink.Space.page)
                .padding(.vertical, Ink.Space.l)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Ink.paper.ignoresSafeArea())
            .navigationTitle(selected != nil ? "确认安装技能" : "从链接 / zip 安装")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L.t("actions.cancel")) {
                        cleanup()
                        dismiss()
                    }
                }
            }
            .fileImporter(isPresented: $pickingZip, allowedContentTypes: [.zip], allowsMultipleSelection: false, onCompletion: handleZipPick)
            .onDisappear { cleanup() }
        }
    }

    // MARK: Step 1 — Pick URL or local zip

    private var sourceView: some View {
        VStack(alignment: .leading, spacing: Ink.Space.xl) {
            VStack(alignment: .leading, spacing: Ink.Space.s) {
                SectionTitle("从链接安装")
                VStack(alignment: .leading, spacing: Ink.Space.m) {
                    HStack(spacing: Ink.Space.s) {
                        TextField("https://github.com/…/tree/main/skills/…", text: $urlText)
                            .font(Ink.mono(Ink.Size.sub))
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.go)
                            .onSubmit { fetchFromURL() }
                        Button("粘贴") {
                            if let pasted = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !pasted.isEmpty {
                                urlText = pasted
                                Haptics.tick(0.5)
                            }
                        }
                        .font(.system(size: Ink.Size.small, weight: .semibold))
                        .foregroundStyle(Ink.accent)
                    }
                    Button {
                        fetchFromURL()
                    } label: {
                        HStack(spacing: Ink.Space.s) {
                            if busy { ProgressView().tint(Ink.paper) }
                            Text(busy ? (statusText ?? "正在获取并检查…") : "获取并检查")
                        }
                    }
                    .buttonStyle(WideButtonStyle())
                    .disabled(busy || urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(Ink.Space.l)
                .paperCard()
                Text("支持 GitHub 技能目录链接、zip 链接或 SKILL.md 链接。获取后会先展示文件清单，你点确认才会安装。")
                    .font(.system(size: Ink.Size.small))
                    .foregroundStyle(Ink.inkSoft)
                    .padding(.horizontal, Ink.Space.l)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: Ink.Space.s) {
                SectionTitle("从本地 zip 安装")
                RowCard {
                    Button {
                        Haptics.light()
                        pickingZip = true
                    } label: {
                        RowLabel(
                            "doc.zipper",
                            tint: Ink.Tile.dai,
                            title: "从「文件」选择 zip",
                            line: "选择包含 SKILL.md 的技能压缩包"
                        )
                    }
                    .buttonStyle(PressStyle(haptic: false))
                    .disabled(busy)
                }
            }

            if let errorText {
                errorCard(errorText)
            }
        }
    }

    // MARK: Step 2 — Choose when archive has multiple skills

    private func chooseSkillView(_ batch: SkillInstaller.StagedBatch) -> some View {
        VStack(alignment: .leading, spacing: Ink.Space.xl) {
            Text("里面找到了 \(batch.skills.count) 个技能，选一个查看详情并安装：")
                .font(Ink.secondary)
                .foregroundStyle(Ink.inkSoft)
            RowCard {
                ForEach(batch.skills) { item in
                    Button {
                        Haptics.light()
                        showBody = false
                        selected = item
                    } label: {
                        RowLabel(
                            item.scripts.isEmpty ? "books.vertical" : "terminal",
                            tint: item.scripts.isEmpty ? Ink.Tile.dai : Ink.warn,
                            title: item.skill.name,
                            line: item.skill.description.isEmpty ? "共 \(item.files.count) 个文件" : item.skill.description
                        )
                    }
                    .buttonStyle(PressStyle(haptic: false))
                }
            }
            Button("重新选择来源") {
                resetSelection()
            }
            .font(.system(size: Ink.Size.sub, weight: .medium))
            .foregroundStyle(Ink.inkSoft)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Step 3 — Review & confirm before installing

    private func previewView(_ staged: SkillInstaller.StagedSkill) -> some View {
        VStack(alignment: .leading, spacing: Ink.Space.xl) {
            infoCard(staged)
            if !staged.scripts.isEmpty {
                scriptWarningCard(staged.scripts.count)
            }
            filesCard(staged)
            bodyPreviewCard(staged)
            if let errorText {
                errorCard(errorText)
            }
            VStack(spacing: Ink.Space.s) {
                Button {
                    confirmInstall(staged)
                } label: {
                    Text(staged.willOverwrite ? "覆盖并安装" : "确认安装")
                }
                .buttonStyle(WideButtonStyle())

                Button((batch?.skills.count ?? 0) > 1 ? "返回技能列表" : "重新选择来源") {
                    Haptics.light()
                    if (batch?.skills.count ?? 0) > 1 {
                        selected = nil
                        showBody = false
                    } else {
                        resetSelection()
                    }
                }
                .font(.system(size: Ink.Size.sub, weight: .medium))
                .foregroundStyle(Ink.inkSoft)
                .padding(.vertical, Ink.Space.s)
            }
        }
    }

    private func infoCard(_ staged: SkillInstaller.StagedSkill) -> some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            Text(staged.skill.name)
                .font(.system(size: Ink.Size.title, weight: .semibold))
                .foregroundStyle(Ink.ink)
            if !staged.skill.description.isEmpty {
                Text(staged.skill.description)
                    .font(Ink.secondary)
                    .foregroundStyle(Ink.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(Words.t("将装进：书案/技能/\(staged.folderName)/"))
                .font(Ink.mono(Ink.Size.small))
                .foregroundStyle(Ink.inkFaint)
            if staged.willOverwrite {
                Text("已存在同名技能，确认安装会覆盖原文件夹。")
                    .font(Ink.footnote)
                    .foregroundStyle(Ink.warn)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Ink.Space.l)
        .paperCard()
    }

    private func scriptWarningCard(_ count: Int) -> some View {
        HStack(alignment: .top, spacing: Ink.Space.m) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: Ink.Size.body))
                .foregroundStyle(Ink.warn)
            VStack(alignment: .leading, spacing: Ink.Space.xs) {
                Text("包含 \(count) 个脚本文件")
                    .font(.system(size: Ink.Size.sub, weight: .semibold))
                    .foregroundStyle(Ink.ink)
                Text("下面已特别标出所有脚本。请确认来源可信，安装后只在你允许或明确要求时才会执行。")
                    .font(Ink.footnote)
                    .foregroundStyle(Ink.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Ink.Space.l)
        .background(Ink.warn.opacity(0.12), in: .rect(cornerRadius: Ink.Radius.card, style: .continuous))
    }

    private func filesCard(_ staged: SkillInstaller.StagedSkill) -> some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle("文件清单（共 \(staged.files.count) 个 · \(Workspace.size(staged.totalBytes))）")
            VStack(spacing: 0) {
                ForEach(Array(staged.files.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { Kit.rule(inset: Ink.Space.l) }
                    HStack(spacing: Ink.Space.m) {
                        Image(systemName: entry.isScript ? "terminal" : "doc.text")
                            .font(.system(size: Ink.Size.sub))
                            .foregroundStyle(entry.isScript ? Ink.warn : Ink.inkSoft)
                            .frame(width: 20 * UIScale.factor)
                        VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
                            Text(entry.path)
                                .font(Ink.mono(Ink.Size.small, weight: entry.isScript ? .semibold : .regular))
                                .foregroundStyle(Ink.ink)
                                .lineLimit(2)
                            Text(Workspace.size(entry.bytes))
                                .font(.system(size: Ink.Size.micro))
                                .foregroundStyle(Ink.inkFaint)
                        }
                        Spacer(minLength: Ink.Space.s)
                        if entry.isScript {
                            Text("脚本")
                                .font(.system(size: Ink.Size.micro, weight: .semibold))
                                .foregroundStyle(Ink.warn)
                                .padding(.horizontal, Ink.Space.s)
                                .padding(.vertical, Ink.Space.xs / 2)
                                .background(Ink.warn.opacity(0.16), in: .capsule)
                        }
                    }
                    .padding(.horizontal, Ink.Space.l)
                    .padding(.vertical, Ink.Space.m)
                }
            }
            .paperCard()
        }
    }

    private func bodyPreviewCard(_ staged: SkillInstaller.StagedSkill) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                Haptics.light()
                withAnimation(Ink.Motion.settle) { showBody.toggle() }
            } label: {
                HStack {
                    Text("查看 SKILL.md 说明原文")
                        .font(.system(size: Ink.Size.sub))
                        .foregroundStyle(Ink.ink)
                    Spacer()
                    Image(systemName: showBody ? "chevron.up" : "chevron.down")
                        .font(.system(size: Ink.Size.small, weight: .semibold))
                        .foregroundStyle(Ink.inkFaint)
                }
                .padding(.horizontal, Ink.Space.l)
                .frame(minHeight: Kit.rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(TapStyle())
            if showBody {
                Kit.rule(inset: Ink.Space.l)
                Text(staged.skill.body)
                    .font(Ink.mono(Ink.Size.small))
                    .foregroundStyle(Ink.inkSoft)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Ink.Space.l)
            }
        }
        .paperCard()
    }

    private func errorCard(_ text: String) -> some View {
        HStack(alignment: .top, spacing: Ink.Space.s) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Ink.stop)
            Text(text)
                .font(Ink.footnote)
                .foregroundStyle(Ink.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Ink.Space.l)
        .background(Ink.stop.opacity(0.08), in: .rect(cornerRadius: Ink.Radius.card, style: .continuous))
    }

    // MARK: Actions

    private func fetchFromURL() {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !busy else { return }
        busy = true
        statusText = "正在下载并检查…"
        errorText = nil
        cleanup()
        Task {
            do {
                let staged = try await SkillInstaller.stageURL(trimmed)
                applyStaged(staged)
            } catch {
                errorText = error.localizedDescription
                Haptics.lock()
            }
            busy = false
            statusText = nil
        }
    }

    private func handleZipPick(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            busy = true
            statusText = "正在解压并检查…"
            errorText = nil
            cleanup()
            Task {
                do {
                    let staged = try await SkillInstaller.stageLocalZip(url)
                    applyStaged(staged)
                } catch {
                    errorText = error.localizedDescription
                    Haptics.lock()
                }
                busy = false
                statusText = nil
            }
        case .failure(let error):
            errorText = error.localizedDescription
        }
    }

    private func applyStaged(_ staged: SkillInstaller.StagedBatch) {
        batch = staged
        if staged.skills.count == 1 {
            selected = staged.skills.first
        } else {
            selected = nil
        }
        showBody = false
        Haptics.tick(0.6)
    }

    private func confirmInstall(_ staged: SkillInstaller.StagedSkill) {
        errorText = nil
        do {
            try SkillInstaller.install(staged)
            Haptics.thud()
            let installedName = staged.skill.name
            cleanup()
            onInstalled(installedName)
            dismiss()
        } catch {
            errorText = error.localizedDescription
            Haptics.lock()
        }
    }

    private func resetSelection() {
        cleanup()
        errorText = nil
        showBody = false
    }

    private func cleanup() {
        batch?.cleanup()
        batch = nil
        selected = nil
    }
}
