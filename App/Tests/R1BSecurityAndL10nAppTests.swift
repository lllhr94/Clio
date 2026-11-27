import AgentKit
@testable import Clio
import Craft
import Foundation
import XCTest

final class R1BSecurityAndL10nAppTests: XCTestCase {
    private var tempDirs: [URL] = []

    private func makeTempDir(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clio-r1b-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        tempDirs.append(url)
        return url
    }

    override func tearDown() {
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
        super.tearDown()
    }

    // MARK: - CLIO-004: AppLock URL deferral & Widget/LiveTurns privacy redaction

    @MainActor
    func testAppLockDefersIncomingURLsUntilUnlocked() {
        let previousOverride = AppLock.testUnlockedOverride
        defer {
            AppLock.testUnlockedOverride = previousOverride
            AppLock.clearDeferredIncomingURLsForTesting()
        }

        AppLock.clearDeferredIncomingURLsForTesting()
        AppLock.testUnlockedOverride = false

        let chatURL = URL(string: "clio://chat/bot-chief")!
        let askURL = URL(string: "clio://ask?text=secret")!
        let fileURL = URL(fileURLWithPath: "/tmp/dropped.txt")

        XCTAssertTrue(AppLock.deferIncomingURLIfLocked(chatURL))
        XCTAssertTrue(AppLock.deferIncomingURLIfLocked(askURL))
        XCTAssertTrue(AppLock.deferIncomingURLIfLocked(fileURL))
        XCTAssertEqual(AppLock.drainDeferredIncomingURLs(), [], "Locked state must not drain deferred URLs")

        AppLock.testUnlockedOverride = true
        XCTAssertEqual(AppLock.drainDeferredIncomingURLs(), [chatURL, askURL, fileURL])
        XCTAssertEqual(AppLock.drainDeferredIncomingURLs(), [])
        XCTAssertFalse(AppLock.deferIncomingURLIfLocked(chatURL), "Unlocked state should process immediately")
    }

    @MainActor
    func testWidgetFeedAndLiveTurnsRedactContentWhenFaceIDLockEnabled() {
        let secretPreview = "密码重置验证码是 849201，不要告诉别人\n下一行私密对话"
        XCTAssertEqual(WidgetFeed.sanitizedPreviewLine(secretPreview, faceIDLocked: true), "")
        let visible = WidgetFeed.sanitizedPreviewLine(secretPreview, faceIDLocked: false)
        XCTAssertTrue(visible.contains("849201"))
        XCTAssertFalse(visible.contains("\n"))

        let redactedDoing = LiveTurns.redactedDoing("正在读取 /Users/me/salary.xlsx", needsApproval: false, privacyRedacted: true)
        XCTAssertFalse(redactedDoing.contains("salary.xlsx"))
        XCTAssertFalse(redactedDoing.isEmpty)

        let redactedSubtask = LiveTurns.redactedSubtaskSummary("检查私密账单 PDF", privacyRedacted: true)
        XCTAssertFalse(redactedSubtask.contains("账单"))

        let redactedEnd = LiveTurns.redactedEndLine("你的银行卡尾号 1234 余额为 50000", ok: true, privacyRedacted: true)
        XCTAssertFalse(redactedEnd.contains("1234"))
        XCTAssertFalse(redactedEnd.contains("50000"))

        let plainEnd = LiveTurns.redactedEndLine("整理好了今天的日程", ok: true, privacyRedacted: false)
        XCTAssertTrue(plainEnd.contains("整理好了今天的日程"))
    }

    // MARK: - CLIO-006: Vault fallback files excluded from backup

    func testVaultFallbackAndLegacyMigrationExcludeFromBackup() throws {
        let key = "test.r1b.backup.\(UUID().uuidString)"
        let payload = Data("{\"token\":\"secret-value\"}".utf8)
        defer { _ = Vault.removeProtected(key) }

        try Vault.writeProtected(payload, as: key)
        let url = Vault.fallbackFileURL(for: key)
        let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)

        // Legacy pre-existing fallback files in a folder must be retroactively excluded.
        let dir = try makeTempDir("vault-migration")
        let legacyFile = dir.appendingPathComponent("link-legacy.secret.json")
        let unrelatedFile = dir.appendingPathComponent("notes.txt")
        try Data("{}".utf8).write(to: legacyFile)
        try Data("hello".utf8).write(to: unrelatedFile)

        Vault.excludeExistingFallbackFilesFromBackup(in: dir)
        let migratedValues = try legacyFile.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(migratedValues.isExcludedFromBackup, true)
    }

    // MARK: - CLIO-007: Workspace multi-hop dangling symlink & cycle defense

    func testWorkspaceIsInsideRealRootBlocksMultiHopDanglingSymlinkAndCycles() throws {
        let sandbox = try makeTempDir("symlink")
        let root = sandbox.appendingPathComponent("desk", isDirectory: true)
        let outside = sandbox.appendingPathComponent("outside", isDirectory: true)
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        let fm = FileManager.default

        // 1. Two-hop dangling symlink: root/a -> root/b -> outside/newdir/secret.txt
        let linkA = root.appendingPathComponent("a")
        let linkB = root.appendingPathComponent("b")
        let outsideTarget = outside.appendingPathComponent("newdir/secret.txt")
        try fm.createSymbolicLink(atPath: linkB.path, withDestinationPath: outsideTarget.path)
        try fm.createSymbolicLink(atPath: linkA.path, withDestinationPath: "b")
        XCTAssertFalse(Workspace.isInsideRealRoot(linkA, root: root))
        XCTAssertFalse(Workspace.isInsideRealRoot(linkA.appendingPathComponent("nested.txt"), root: root))

        // 2. Symlink cycle: root/loop1 -> loop2 -> loop1
        let loop1 = root.appendingPathComponent("loop1")
        let loop2 = root.appendingPathComponent("loop2")
        try fm.createSymbolicLink(atPath: loop1.path, withDestinationPath: "loop2")
        try fm.createSymbolicLink(atPath: loop2.path, withDestinationPath: "loop1")
        XCTAssertFalse(Workspace.isInsideRealRoot(loop1, root: root))

        // 3. Valid internal relative symlink inside root remains allowed.
        let goodFile = sub.appendingPathComponent("note.md")
        try Data("ok".utf8).write(to: goodFile)
        let goodLink = root.appendingPathComponent("good-link.md")
        try fm.createSymbolicLink(atPath: goodLink.path, withDestinationPath: "sub/note.md")
        XCTAssertTrue(Workspace.isInsideRealRoot(goodLink, root: root))
    }

    // MARK: - CLIO-009: Browser.fillSecret scheme/port/public-suffix enforcement & approval context

    func testBrowserSecretFillEnforcesHTTPSPortAndPublicSuffixBoundaries() {
        // Blocks HTTPS/bare secret on plain HTTP page.
        XCTAssertNotNil(BrowserSession.secretFillMismatchReason(
            expectedURL: URL(string: "http://example.com/login")!,
            site: "example.com",
            entry: "示例账号"
        ))
        XCTAssertNotNil(BrowserSession.secretFillMismatchReason(
            expectedURL: URL(string: "http://example.com/login")!,
            site: "https://example.com",
            entry: "示例账号"
        ))

        // Allows plain HTTP only when user explicitly bound `http://` in Vault.
        XCTAssertNil(BrowserSession.secretFillMismatchReason(
            expectedURL: URL(string: "http://192.168.1.50:8080/login")!,
            site: "http://192.168.1.50:8080",
            entry: "家用路由器"
        ))

        // Enforces explicit and default ports.
        XCTAssertNotNil(BrowserSession.secretFillMismatchReason(
            expectedURL: URL(string: "https://nas.local:9000/login")!,
            site: "https://nas.local:8443",
            entry: "NAS"
        ))
        XCTAssertNotNil(BrowserSession.secretFillMismatchReason(
            expectedURL: URL(string: "https://example.com:9443/login")!,
            site: "example.com",
            entry: "Example"
        ))
        XCTAssertNil(BrowserSession.secretFillMismatchReason(
            expectedURL: URL(string: "https://nas.local:8443/login")!,
            site: "https://nas.local:8443",
            entry: "NAS"
        ))

        // Blocks bare TLD & public-suffix / shared-hosting wildcards.
        XCTAssertNotNil(BrowserSession.secretFillMismatchReason(
            expectedURL: URL(string: "https://evil.github.io/login")!,
            site: "github.io",
            entry: "Pages"
        ))
        XCTAssertNotNil(BrowserSession.secretFillMismatchReason(
            expectedURL: URL(string: "https://evil.com.cn/login")!,
            site: "com.cn",
            entry: "CN"
        ))
        XCTAssertNotNil(BrowserSession.secretFillMismatchReason(
            expectedURL: URL(string: "https://evil.vercel.app/login")!,
            site: "vercel.app",
            entry: "Vercel"
        ))
        XCTAssertNotNil(BrowserSession.secretFillMismatchReason(
            expectedURL: URL(string: "https://evil.com/login")!,
            site: "com",
            entry: "TLD"
        ))

        // Allows exact tenant host & legitimate registrable subdomain.
        XCTAssertNil(BrowserSession.secretFillMismatchReason(
            expectedURL: URL(string: "https://my-app.github.io/login")!,
            site: "my-app.github.io",
            entry: "My App"
        ))
        XCTAssertNil(BrowserSession.secretFillMismatchReason(
            expectedURL: URL(string: "https://accounts.example.com/login")!,
            site: "example.com",
            entry: "Example"
        ))

        // Approval copy must expose item title, bound site, and current browser origin.
        let item = Secrets.Item(id: "sec01", title: "GitHub 主号", kind: .web, site: "https://github.com", user: "alice")
        let ask = Secrets.formattedFillApproval(
            arguments: .object(["id": .string("sec01"), "field": .string("password")]),
            chat: "bot-chief",
            itemOverride: item,
            currentOriginOverride: "https://github.com"
        )
        XCTAssertTrue(ask.forced)
        XCTAssertTrue(ask.reason.contains("GitHub 主号"))
        XCTAssertTrue(ask.reason.contains("https://github.com"))
        XCTAssertTrue(ask.detail?.contains("https://github.com") == true)
    }

    // MARK: - CLIO-011: MemoryStoreBridge concurrent writes preserve all updates

    @MainActor
    func testMemoryStoreBridgeConcurrentRemembersAndEditLoseZeroUpdates() async throws {
        let dir = try makeTempDir("memory-concurrency")
        let teamRoot = dir.appendingPathComponent("Team", isDirectory: true)
        let mirrorRoot = dir.appendingPathComponent("Mirrors", isDirectory: true)
        let dbURL = dir.appendingPathComponent("ClioMemory/concurrent.db")
        try FileManager.default.createDirectory(at: teamRoot, withIntermediateDirectories: true)

        let bridge = MemoryStoreBridge(databaseURL: dbURL, teamRoot: teamRoot, mirrorRoot: mirrorRoot)
        defer { bridge.flushSync() }

        let seed = CanonicalMemoryItem(id: "m-seed", text: "初始事实", at: 1_000)
        _ = try bridge.revisionStore.commitWithJournal(CanonicalMemoryBook(memories: [seed]), nowMs: 1_000)
        let boot = bridge.bootstrapOnLaunch()
        let staleSnapshot = boot.book

        // Simulate 20 concurrent `.remember` writes + 1 `.edit` all built from the same stale initial snapshot.
        let totalWrites = 20
        var lastSequences: [UInt64] = []
        try await withThrowingTaskGroup(of: UInt64?.self) { group in
            for idx in 0..<totalWrites {
                group.addTask { @MainActor in
                    let mem = Memory(
                        id: "m-conc-\(idx)",
                        text: "并发记忆第 \(idx) 条",
                        at: Double(2_000 + idx),
                        by: nil,
                        deep: nil,
                        used: Double(2_000 + idx),
                        editedByUser: true
                    )
                    var book = staleSnapshot
                    book.memories.append(mem)
                    let (committed, _) = try await bridge.commitAppBookAsync(
                        book,
                        mutation: .remember(memory: mem, explicitUserAction: true, nowMs: Double(2_000 + idx)),
                        suppressedHashes: [],
                        bots: [],
                        mainBotId: nil,
                        secrets: []
                    )
                    return committed.storeSequence
                }
            }
            group.addTask { @MainActor in
                var editBook = staleSnapshot
                editBook.memories[0].text = "已编辑的初始事实"
                let (committed, _) = try await bridge.commitAppBookAsync(
                    editBook,
                    mutation: .edit(id: "m-seed", text: "已编辑的初始事实", editedByUser: true, nowMs: 3_000),
                    suppressedHashes: [],
                    bots: [],
                    mainBotId: nil,
                    secrets: []
                )
                return committed.storeSequence
            }
            for try await seq in group {
                if let seq { lastSequences.append(seq) }
            }
        }

        XCTAssertEqual(Set(lastSequences).count, totalWrites + 1, "Every commit must receive a distinct monotonic sequence")

        let diskBook = try CanonicalMemoryBook.decodeFlexible(
            from: Data(contentsOf: bridge.revisionStore.memoryFileURL)
        )
        let diskIDs = Set(diskBook.memories.map(\.id))
        XCTAssertTrue(diskIDs.contains("m-seed"))
        for idx in 0..<totalWrites {
            XCTAssertTrue(diskIDs.contains("m-conc-\(idx)"), "Missing concurrent memory m-conc-\(idx)")
        }
        XCTAssertEqual(diskBook.memories.first(where: { $0.id == "m-seed" })?.text, "已编辑的初始事实")

        // Stale `.remember` with same ID must not overwrite newer `.edit` text.
        let staleRememberOfSeed = Memory(id: "m-seed", text: "初始事实", at: 1_000, by: nil, deep: nil, used: 4_000)
        var staleRememberBook = staleSnapshot
        staleRememberBook.memories[0] = staleRememberOfSeed
        let (afterStaleRemember, _) = try await bridge.commitAppBookAsync(
            staleRememberBook,
            mutation: .remember(memory: staleRememberOfSeed, explicitUserAction: true, nowMs: 4_000),
            suppressedHashes: [],
            bots: [],
            mainBotId: nil,
            secrets: []
        )
        XCTAssertEqual(afterStaleRemember.memories.first(where: { $0.id == "m-seed" })?.text, "已编辑的初始事实")

        // Stale full-book `.none` commit with outdated `storeSequence` must be rejected rather than clobbering newer memories.
        XCTAssertThrowsError(
            try bridge.commitAppBook(
                staleSnapshot,
                mutation: .none,
                suppressedHashes: [],
                bots: [],
                mainBotId: nil,
                secrets: []
            )
        ) {
            XCTAssertTrue(($0 as? TeamError)?.message.contains("过期覆盖写入") == true)
        }
    }

    // MARK: - CLIO-013: All 15 trace.* keys present in both daily and literary tones

    @MainActor
    func testTraceLocalizationKeysResolveInDailyAndLiteraryTones() {
        let previousPlain = Theme.shared.plain
        defer { Theme.shared.setPlain(previousPlain) }
        L.prepare()

        let keys = [
            "trace.commandTitle",
            "trace.commandsCount",
            "trace.commandsFailedCount",
            "trace.commandsUnknownCount",
            "trace.commandFailed",
            "trace.commandUnknown",
            "trace.commandFailedDetail",
            "trace.commandUnknownDetail",
            "trace.commandLabel",
            "trace.outputLabel",
            "trace.noOutput",
            "trace.outputTruncated",
            "trace.outputTrimmedNote",
            "trace.copy",
            "trace.copied",
        ]

        for isPlain in [true, false] {
            Theme.shared.setPlain(isPlain)
            for key in keys {
                let value = L.t(key)
                XCTAssertNotEqual(value, key, "Key \(key) must resolve in plain=\(isPlain)")
                XCTAssertFalse(value.isEmpty)
            }
            XCTAssertTrue(L.format("trace.commandsCount", 3).contains("3"))
            XCTAssertTrue(L.format("trace.commandsFailedCount", 2).contains("2"))
            XCTAssertTrue(L.format("trace.commandsUnknownCount", 1).contains("1"))
            XCTAssertTrue(L.format("trace.outputTruncated", 12000).contains("12000"))
        }
    }
}
