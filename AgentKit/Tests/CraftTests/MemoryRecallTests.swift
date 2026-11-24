@testable import AgentKit
@testable import Craft
import Foundation
import SQLite3
import XCTest

final class MemoryRecallTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clio-memory-recall-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func dayMs(_ daysAgo: Double, from nowMs: Double) -> Double {
        nowMs - daysAgo * 86_400_000
    }

    // MARK: 1. FTS5 Deep Recall Matching, Exclusions & Secret Redaction

    func testDeepFTS5RecallMatchesCJKAndEnglishAndExcludesPinnedSurfaceArchivedTombstones() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("clio-memory-recall-fts.db")

        let index = MemoryRecallIndex(databaseURL: dbURL)
        defer { index.close() }
        XCTAssertEqual(try index.openOrRecover(), .missing)
        XCTAssertTrue(index.needsRebuildFromSource)

        let deletedAt: Double = 50_000
        let suppressedFact = "曾经在广州天河区工作过"
        let suppressedHash = MemorySafety.retractionHash(suppressedFact)

        let records: [MemoryRecord] = [
            MemoryRecord(
                id: "pin-1",
                text: "用户住在重庆南岸区，只喝无糖乌龙茶",
                layer: .pinned,
                pinned: true,
                createdAtMs: 1_000,
                usedAtMs: 1_000
            ),
            MemoryRecord(
                id: "surf-1",
                text: "主力用 Swift 开发重庆本地美食 App",
                layer: .surface,
                createdAtMs: 2_000,
                usedAtMs: 2_000
            ),
            MemoryRecord(
                id: "arch-1",
                text: "重庆出差报销单已经归档处理",
                layer: .archived,
                createdAtMs: 3_000,
                usedAtMs: 3_000
            ),
            MemoryRecord(
                id: "tomb-1",
                text: "重庆老家以前养过一只金毛犬",
                layer: .deep,
                createdAtMs: 4_000,
                usedAtMs: 4_000,
                deletedAtMs: deletedAt
            ),
            MemoryRecord(
                id: "suppressed-1",
                text: suppressedFact,
                layer: .deep,
                createdAtMs: 5_000,
                usedAtMs: 5_000
            ),
            MemoryRecord(
                id: "deep-hotpot-old",
                text: "常去重庆解放碑老店吃麻辣火锅",
                layer: .deep,
                topic: "饮食",
                confidence: 0.9,
                createdAtMs: 6_000,
                usedAtMs: 10_000
            ),
            MemoryRecord(
                id: "deep-hotpot-recent",
                text: "常去重庆九宫格老店吃牛油火锅",
                layer: .deep,
                topic: "饮食",
                confidence: 0.9,
                createdAtMs: 6_500,
                usedAtMs: 90_000
            ),
            MemoryRecord(
                id: "deep-swift",
                text: "之前研究过 SwiftUI 的 NavigationStack 路由和 Combine",
                layer: .deep,
                topic: "开发",
                confidence: 0.95,
                createdAtMs: 7_000,
                usedAtMs: 7_000
            ),
            MemoryRecord(
                id: "deep-secret",
                text: "常用 DeepSeek 接口，测试密钥 sk-live-secret-9999",
                layer: .deep,
                topic: "工具",
                confidence: 0.85,
                createdAtMs: 8_000,
                usedAtMs: 8_000
            ),
            MemoryRecord(
                id: "deep-secret-only",
                text: "sk-live-secret-9999",
                layer: .deep,
                createdAtMs: 8_500,
                usedAtMs: 8_500
            ),
        ]

        let secrets = ["sk-live-secret-9999"]
        try index.sync(records: records, secrets: secrets)
        XCTAssertFalse(index.needsRebuildFromSource)

        // Conversational prompt matches relevant `.deep` memories, never pinned/surface/archived/tombstoned.
        let hotpotHits = try index.searchDeep(
            query: "想去重庆吃火锅，有什么推荐吗",
            surfaceTexts: ["主力用 Swift 开发重庆本地美食 App"],
            suppressedHashes: [suppressedHash],
            secrets: secrets
        )
        XCTAssertEqual(Set(hotpotHits.map(\.id)), ["deep-hotpot-recent", "deep-hotpot-old"])
        XCTAssertEqual(hotpotHits.first?.id, "deep-hotpot-recent")
        XCTAssertFalse(hotpotHits.contains(where: { ["pin-1", "surf-1", "arch-1", "tomb-1"].contains($0.id) }))

        // English / mixed technical query matches SwiftUI `.deep` memory.
        let swiftHits = try index.searchDeep(
            query: "SwiftUI NavigationStack 怎么写",
            surfaceTexts: ["主力用 Swift 开发重庆本地美食 App"],
            suppressedHashes: [suppressedHash],
            secrets: secrets
        )
        XCTAssertEqual(swiftHits.map(\.id), ["deep-swift"])

        // Suppressed hash excludes matching `.deep` memory.
        let suppressedHits = try index.searchDeep(
            query: "广州天河区工作",
            suppressedHashes: [suppressedHash],
            secrets: secrets
        )
        XCTAssertTrue(suppressedHits.isEmpty)

        // Vault secrets are redacted in recalled hits, and querying the raw secret returns zero hits.
        let deepSeekHits = try index.searchDeep(
            query: "DeepSeek 接口配置",
            suppressedHashes: [suppressedHash],
            secrets: secrets
        )
        XCTAssertEqual(deepSeekHits.map(\.id), ["deep-secret"])
        XCTAssertFalse(deepSeekHits[0].text.contains("sk-live-secret-9999"))
        XCTAssertTrue(deepSeekHits[0].text.contains("〔隐去〕"))

        let rawSecretProbe = try index.searchDeep(
            query: "sk-live-secret-9999",
            suppressedHashes: [suppressedHash],
            secrets: secrets
        )
        XCTAssertTrue(rawSecretProbe.isEmpty)

        // Duplicate text already present in surface is excluded cleanly.
        let duplicateSurfaceHits = try index.searchDeep(
            query: "SwiftUI NavigationStack",
            surfaceTexts: ["之前研究过 SwiftUI 的 NavigationStack 路由和 Combine"],
            suppressedHashes: [suppressedHash],
            secrets: secrets
        )
        XCTAssertTrue(duplicateSurfaceHits.isEmpty)

        // Filler-only prompt does not trigger noisy recall.
        let noisyHits = try index.searchDeep(
            query: "我的一个什么东西",
            suppressedHashes: [suppressedHash],
            secrets: secrets
        )
        XCTAssertTrue(noisyHits.isEmpty)
    }

    // MARK: 2. Prompt Cache Prefix Byte-Invariance & Mid-Turn Retraction

    func testRecalledDeepHintsStayStrictlyInVolatileTailAndPreserveCachePrefix() throws {
        let state = MemorySafety.PromptState()
        let surfaceFact = MemorySafety.Fact(id: "s1", text: "平时喜欢喝乌龙茶", at: 1_000)
        let deepFact1 = MemorySafety.Fact(id: "d1", text: "老家在成都武侯区", at: 500, isDeep: true)
        let deepFact2 = MemorySafety.Fact(id: "d2", text: "主力使用 SwiftUI 写原生界面", at: 600, isDeep: true)

        let baseInput = MemorySafety.SystemPromptInput(
            identity: "你是「小克」。",
            persona: "性格温和。",
            skillsBlock: "你会的技能：\n- 旅行规划：安排出行",
            memories: [surfaceFact, deepFact1, deepFact2],
            memoryEnabled: true,
            timestampLine: "现在是 2026-11-25 10:00，Asia/Shanghai。",
            workplaceLine: "这段絮语的工作地点是书案。"
        )

        let hit1 = MemoryRecall.Hit(
            id: deepFact1.id,
            text: deepFact1.text,
            textSHA256: MemorySafety.retractionHash(deepFact1.text),
            createdAtMs: deepFact1.at
        )
        let hit2 = MemoryRecall.Hit(
            id: deepFact2.id,
            text: deepFact2.text,
            textSHA256: MemorySafety.retractionHash(deepFact2.text),
            createdAtMs: deepFact2.at
        )

        let baseline = MemoryRecallPromptRefresher(input: baseInput, state: state, recalledHits: []).currentPrompt()
        let queryA = MemoryRecallPromptRefresher(input: baseInput, state: state, recalledHits: [hit1]).currentPrompt()
        let queryB = MemoryRecallPromptRefresher(input: baseInput, state: state, recalledHits: [hit2]).currentPrompt()

        // CRITICAL INVARIANT: systemCachePrefix / prefix MUST be 100% byte-identical regardless of recalled hints.
        XCTAssertEqual(baseline.prefix, queryA.prefix)
        XCTAssertEqual(baseline.prefix, queryB.prefix)
        XCTAssertFalse(queryA.prefix.contains(deepFact1.text))
        XCTAssertFalse(queryB.prefix.contains(deepFact2.text))
        XCTAssertTrue(queryA.tail.contains(deepFact1.text))
        XCTAssertTrue(queryB.tail.contains(deepFact2.text))
        XCTAssertTrue(queryA.full.hasPrefix(queryA.prefix))
        XCTAssertTrue(queryB.full.hasPrefix(queryB.prefix))

        // Verify AnthropicProvider splits cached prefix (identical) and uncached volatile tail (varying hints).
        let reqA = ModelRequest(
            model: "claude-sonnet-4-6",
            system: queryA.full,
            messages: [.user("成都有什么好吃的")],
            systemCachePrefix: queryA.prefix
        )
        let reqB = ModelRequest(
            model: "claude-sonnet-4-6",
            system: queryB.full,
            messages: [.user("SwiftUI 怎么写")],
            systemCachePrefix: queryB.prefix
        )
        let bodyA = AnthropicProvider.body(reqA, cache: true, stableSystemPrefix: queryA.prefix)
        let bodyB = AnthropicProvider.body(reqB, cache: true, stableSystemPrefix: queryB.prefix)
        let blocksA = try XCTUnwrap(bodyA["system"] as? [[String: Any]])
        let blocksB = try XCTUnwrap(bodyB["system"] as? [[String: Any]])
        XCTAssertEqual(blocksA.count, 2)
        XCTAssertEqual(blocksB.count, 2)
        XCTAssertEqual(blocksA[0]["text"] as? String, blocksB[0]["text"] as? String)
        XCTAssertEqual(blocksA[0]["cache_control"] as? [String: String], ["type": "ephemeral"])
        XCTAssertNil(blocksA[1]["cache_control"])
        XCTAssertNil(blocksB[1]["cache_control"])
        XCTAssertTrue((blocksA[1]["text"] as? String)?.contains(deepFact1.text) == true)
        XCTAssertTrue((blocksB[1]["text"] as? String)?.contains(deepFact2.text) == true)

        // Mid-turn retraction immediately removes recalled hint from volatile tail while keeping prefix intact.
        let liveRefresher = MemoryRecallPromptRefresher(
            input: baseInput,
            state: state,
            recalledHits: [hit1, hit2]
        )
        XCTAssertTrue(liveRefresher.currentPrompt().tail.contains(deepFact1.text))
        XCTAssertTrue(liveRefresher.currentPrompt().tail.contains(deepFact2.text))

        state.retract(id: deepFact1.id, textForInFlightGuard: deepFact1.text)
        let afterRetract = liveRefresher.currentPrompt()
        XCTAssertFalse(afterRetract.full.contains(deepFact1.text))
        XCTAssertTrue(afterRetract.tail.contains(deepFact2.text))

        // Mid-turn memories refresh (e.g. deleted or promoted to surface) removes stale deep hint from tail.
        let promotedFact2 = MemorySafety.Fact(id: deepFact2.id, text: deepFact2.text, at: deepFact2.at, isDeep: false)
        liveRefresher.refresh(memories: [surfaceFact, promotedFact2])
        let afterPromote = liveRefresher.currentPrompt()
        XCTAssertTrue(afterPromote.prefix.contains(deepFact2.text))
        XCTAssertFalse(afterPromote.tail.contains(deepFact2.text))
    }

    func testRecallPermissionAndMemoryDisabledGatesInjectZeroItems() {
        let state = MemorySafety.PromptState()
        let deepFact = MemorySafety.Fact(id: "d1", text: "老家在成都武侯区", at: 500, isDeep: true)
        let hit = MemoryRecall.Hit(
            id: deepFact.id,
            text: deepFact.text,
            textSHA256: MemorySafety.retractionHash(deepFact.text)
        )

        let disabledInput = MemorySafety.SystemPromptInput(
            identity: "你是「小克」。",
            memories: [deepFact],
            memoryEnabled: false
        )
        let disabledPrompt = MemoryRecallPromptRefresher(
            input: disabledInput,
            state: state,
            recalledHits: [hit],
            isRecallAllowed: { true }
        ).currentPrompt()
        XCTAssertFalse(disabledPrompt.full.contains(deepFact.text))

        // Global Grant.memory toggled off dynamically -> immediately injects zero items.
        let lock = NSLock()
        var allowGlobal = true
        let enabledInput = MemorySafety.SystemPromptInput(
            identity: "你是「小克」。",
            memories: [deepFact],
            memoryEnabled: true
        )
        let gatedRefresher = MemoryRecallPromptRefresher(
            input: enabledInput,
            state: state,
            recalledHits: [hit],
            isRecallAllowed: {
                lock.lock()
                defer { lock.unlock() }
                return allowGlobal
            }
        )
        XCTAssertTrue(gatedRefresher.currentPrompt().tail.contains(deepFact.text))

        lock.lock()
        allowGlobal = false
        lock.unlock()

        XCTAssertFalse(gatedRefresher.currentPrompt().full.contains(deepFact.text))
    }

    func testPerChatMemoryDisableMidTurnDropsSurfaceFactsAndDeepHintsImmediately() {
        let state = MemorySafety.PromptState()
        let surfaceFact = MemorySafety.Fact(id: "s-chat", text: "用户每天早上喝黑咖啡", at: 1_000)
        let deepFact = MemorySafety.Fact(id: "d-chat", text: "十年前曾住在杭州西湖边", at: 500, isDeep: true)
        let hit = MemoryRecall.Hit(
            id: deepFact.id,
            text: deepFact.text,
            textSHA256: MemorySafety.retractionHash(deepFact.text)
        )

        let gateLock = NSLock()
        var chatMemoryEnabled = true

        let input = MemorySafety.SystemPromptInput(
            identity: "你是「小克」。",
            memories: [surfaceFact, deepFact],
            memoryEnabled: true
        )
        let refresher = MemoryRecallPromptRefresher(
            input: input,
            state: state,
            recalledHits: [hit],
            isRecallAllowed: { true },
            isMemoryEnabled: {
                gateLock.lock()
                defer { gateLock.unlock() }
                return chatMemoryEnabled
            }
        )

        let before = refresher.currentPrompt()
        XCTAssertTrue(before.prefix.contains(surfaceFact.text))
        XCTAssertTrue(before.prefix.contains("另有 1 件较早的旧事"))
        XCTAssertTrue(before.tail.contains(deepFact.text))
        XCTAssertFalse(before.memoryBlock.isEmpty)

        gateLock.lock()
        chatMemoryEnabled = false
        gateLock.unlock()

        let after = refresher.currentPrompt()
        XCTAssertFalse(after.full.contains(surfaceFact.text))
        XCTAssertFalse(after.full.contains(deepFact.text))
        XCTAssertFalse(after.full.contains("另有 1 件较早的旧事"))
        XCTAssertEqual(after.memoryBlock, "")
    }

    func testPromptRefresherValidatesRecalledHitsAgainstLiveMemoriesInBuildSnapshot() {
        let state = MemorySafety.PromptState()
        let deepUpdated = MemorySafety.Fact(
            id: "d-live",
            text: "项目备用口令 sk-live-secret-99 仅本地核对",
            at: 500,
            isDeep: true
        )
        let promotedToSurface = MemorySafety.Fact(
            id: "d-promoted",
            text: "已升入常记的工作偏好",
            at: 600,
            isDeep: false
        )
        let excludedByIDFact = MemorySafety.Fact(
            id: "d-excluded-id",
            text: "不应被召回的隔离事实",
            at: 700,
            isDeep: true
        )

        let secretLock = NSLock()
        var currentSecrets = ["sk-live-secret-99"]

        let baseInput = MemorySafety.SystemPromptInput(
            identity: "你是「小克」。",
            memories: [deepUpdated, promotedToSurface, excludedByIDFact],
            memoryEnabled: true,
            excludingMemoryIDs: [excludedByIDFact.id]
        )

        let staleHits: [MemoryRecall.Hit] = [
            // Valid `.deep` hit whose cached hit text was pre-update / unredacted: must refresh & redact from `baseInput.memories`.
            MemoryRecall.Hit(
                id: deepUpdated.id,
                text: "旧文案 sk-live-secret-99",
                textSHA256: MemorySafety.retractionHash("旧文案 sk-live-secret-99")
            ),
            // Hint whose underlying fact already became `.surface` (`isDeep == false`): must be dropped from recalled tail.
            MemoryRecall.Hit(
                id: promotedToSurface.id,
                text: promotedToSurface.text,
                textSHA256: MemorySafety.retractionHash(promotedToSurface.text)
            ),
            // Hint whose underlying fact was deleted / archived (absent from `baseInput.memories`): must be dropped.
            MemoryRecall.Hit(
                id: "d-deleted-or-archived",
                text: "已删除或入藏的记忆条目",
                textSHA256: MemorySafety.retractionHash("已删除或入藏的记忆条目")
            ),
            // Hint excluded via `excludingMemoryIDs`: must be dropped.
            MemoryRecall.Hit(
                id: excludedByIDFact.id,
                text: excludedByIDFact.text,
                textSHA256: MemorySafety.retractionHash(excludedByIDFact.text)
            ),
        ]

        let refresher = MemoryRecallPromptRefresher(
            input: baseInput,
            state: state,
            recalledHits: staleHits,
            activeSecrets: {
                secretLock.lock()
                defer { secretLock.unlock() }
                return currentSecrets
            }
        )

        let prompt = refresher.currentPrompt()
        XCTAssertTrue(prompt.tail.contains("项目备用口令 〔隐去〕 仅本地核对"))
        XCTAssertFalse(prompt.full.contains("sk-live-secret-99"))
        XCTAssertFalse(prompt.full.contains("旧文案"))
        XCTAssertTrue(prompt.prefix.contains(promotedToSurface.text))
        XCTAssertFalse(prompt.tail.contains(promotedToSurface.text))
        XCTAssertFalse(prompt.full.contains("已删除或入藏的记忆条目"))
        XCTAssertFalse(prompt.full.contains(excludedByIDFact.text))

        // Runtime secret addition updates `currentPrompt()` even without PromptState generation bump.
        secretLock.lock()
        currentSecrets.append("本地核对")
        secretLock.unlock()

        let rotatedPrompt = refresher.currentPrompt()
        XCTAssertFalse(rotatedPrompt.tail.contains("本地核对"))
    }

    // MARK: 3. MemoryStore Integration & Usage Bookkeeping

    func testRecallFromMemoryStoreUpdatesUsedAtMsWithoutPromotingOutOfDeep() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MemoryStore(databaseURL: dir.appendingPathComponent("clio-memory.db"))
        defer { store.close() }
        _ = try store.openOrRecover()

        _ = try store.upsert(
            MemoryRecord(
                id: "m-deep",
                text: "喜欢秋天去川西稻城亚丁徒步",
                layer: .deep,
                createdAtMs: 1_000,
                usedAtMs: 1_000
            )
        )
        _ = try store.upsert(
            MemoryRecord(
                id: "m-surf",
                text: "目前住在北京朝阳区",
                layer: .surface,
                createdAtMs: 2_000,
                usedAtMs: 2_000
            )
        )

        let hits = try MemoryRecall.recallFromStore(
            query: "秋天去川西徒步攻略",
            store: store,
            markUsedNowMs: 50_000
        )
        XCTAssertEqual(hits.map(\.id), ["m-deep"])

        let updated = try XCTUnwrap(try store.record(id: "m-deep"))
        XCTAssertEqual(updated.layer, .deep)
        XCTAssertEqual(updated.usedAtMs, 50_000)
    }

    // MARK: 4. Self-Healing & Backup Exclusion Path

    func testRecallIndexSelfHealsOnCorruptionAndExternalDeletion() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("clio-memory-recall-fts.db")

        try Data("corrupt bytes".utf8).write(to: dbURL)
        let index = MemoryRecallIndex(databaseURL: dbURL)
        defer { index.close() }

        XCTAssertEqual(try index.openOrRecover(), .corrupt)
        XCTAssertTrue(index.needsRebuildFromSource)

        let record = MemoryRecord(
            id: "d1",
            text: "收藏了一家重庆老火锅店",
            layer: .deep,
            createdAtMs: 1_000,
            usedAtMs: 1_000
        )
        try index.sync(records: [record])
        XCTAssertFalse(index.needsRebuildFromSource)
        XCTAssertEqual(try index.searchDeep(query: "重庆火锅").map(\.id), ["d1"])

        // External deletion while handle is open.
        try FileManager.default.removeItem(at: dbURL)
        XCTAssertEqual(try index.searchDeep(query: "重庆火锅"), [])
        XCTAssertEqual(index.lastRecoveryReason, .externalDeletion)
        XCTAssertTrue(index.needsRebuildFromSource)

        try index.sync(records: [record])
        XCTAssertEqual(try index.searchDeep(query: "重庆火锅").map(\.id), ["d1"])
    }

    func testRecallIndexDefaultLocationIsUnderCachesClioIndex() {
        let url = MemoryRecallIndex.defaultDatabaseURL
        XCTAssertEqual(url.lastPathComponent, "clio-memory-recall-fts.db")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "ClioIndex")
        XCTAssertTrue(url.path.contains("/Caches/ClioIndex/"))
    }

    func testRecallIndexFallbackLikeModeWorksWithoutFTS5() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("recall-fallback.db")

        let index = MemoryRecallIndex(databaseURL: dbURL, forceDisableFTS5ForTesting: true)
        defer { index.close() }
        XCTAssertEqual(try index.openOrRecover(), .missing)
        XCTAssertFalse(index.isFTS5Active)

        try index.sync(records: [
            MemoryRecord(id: "d1", text: "喜欢去重庆吃麻辣火锅", layer: .deep, createdAtMs: 1_000),
            MemoryRecord(id: "d2", text: "使用全角 Ｘｃｏｄｅ 调试", layer: .deep, createdAtMs: 2_000),
        ])
        XCTAssertEqual(try index.searchDeep(query: "重庆火锅").map(\.id), ["d1"])
        XCTAssertEqual(try index.searchDeep(query: "Xcode").map(\.id), ["d2"])
    }

    // MARK: 5. Nightly Promotion & Archival Lifecycle Policy

    func testNightlyPromotionPolicyPromotesHotDeepArchivesStaleAndEnforcesHardInvariants() {
        let nowMs: Double = 200 * 86_400_000

        let records: [MemoryRecord] = [
            // Pinned record that is 150 days stale: MUST NEVER be demoted or archived!
            MemoryRecord(
                id: "pin-ancient",
                text: "用户对青霉素严重过敏",
                layer: .pinned,
                pinned: true,
                createdAtMs: dayMs(150, from: nowMs),
                updatedAtMs: dayMs(150, from: nowMs),
                usedAtMs: dayMs(150, from: nowMs),
                automatic: true,
                editedByUser: false
            ),
            // Recently & frequently recalled `.deep` record -> SHOULD promote to `.surface`.
            MemoryRecord(
                id: "deep-hot",
                text: "最近在写 Clio SwiftUI 记忆系统",
                layer: .deep,
                confidence: 0.95,
                createdAtMs: dayMs(30, from: nowMs),
                usedAtMs: dayMs(1, from: nowMs)
            ),
            // Newly added `.deep` record inside grace period (1 day old) -> MUST NOT archive.
            MemoryRecord(
                id: "deep-fresh",
                text: "昨天刚提过准备学攀岩",
                layer: .deep,
                createdAtMs: dayMs(1, from: nowMs),
                usedAtMs: dayMs(1, from: nowMs),
                automatic: true
            ),
            // Newly added `.surface` record inside grace period (2 days old) -> MUST NOT demote.
            MemoryRecord(
                id: "surf-fresh",
                text: "这周在读《Swift 并发编程》",
                layer: .surface,
                createdAtMs: dayMs(2, from: nowMs),
                usedAtMs: dayMs(2, from: nowMs),
                automatic: true
            ),
            // Long-stale unpinned `.surface` (30 days untouched) -> SHOULD demote to `.deep`.
            MemoryRecord(
                id: "surf-stale",
                text: "上个月临时买过一次咖啡豆",
                layer: .surface,
                createdAtMs: dayMs(30, from: nowMs),
                usedAtMs: dayMs(30, from: nowMs),
                automatic: true
            ),
            // Very stale untouched automatic `.deep` (60 days old) -> SHOULD archive.
            MemoryRecord(
                id: "deep-stale-auto",
                text: "两个月前随口提过的天气",
                layer: .deep,
                createdAtMs: dayMs(60, from: nowMs),
                usedAtMs: dayMs(60, from: nowMs),
                automatic: true,
                editedByUser: false
            ),
            // User-edited `.deep` at 60 days (< 120d manual threshold) -> stays in `.deep`!
            MemoryRecord(
                id: "deep-manual-60d",
                text: "老家住址是成都市武侯区",
                layer: .deep,
                createdAtMs: dayMs(60, from: nowMs),
                usedAtMs: dayMs(60, from: nowMs),
                automatic: false,
                editedByUser: true
            ),
            // Tombstoned `.deep` record even with recent `usedAtMs` -> MUST NEVER resurrect/promote!
            MemoryRecord(
                id: "tomb-hot",
                text: "已删除的旧住址",
                layer: .deep,
                createdAtMs: dayMs(10, from: nowMs),
                usedAtMs: dayMs(0.1, from: nowMs),
                deletedAtMs: dayMs(0.05, from: nowMs)
            ),
        ]

        let stats: [String: MemoryRecallUsageStat] = [
            "deep-hot": MemoryRecallUsageStat(lastRecalledAtMs: dayMs(0.5, from: nowMs), recallCount: 3),
            "tomb-hot": MemoryRecallUsageStat(lastRecalledAtMs: dayMs(0.1, from: nowMs), recallCount: 10),
        ]

        let plan = MemoryPromotionPolicy.evaluate(
            records: records,
            usageStats: stats,
            nowMs: nowMs,
            config: .default
        )

        XCTAssertEqual(plan.promoteToSurface, ["deep-hot"])
        XCTAssertEqual(plan.demoteToDeep, ["surf-stale"])
        XCTAssertEqual(plan.archiveIDs, ["deep-stale-auto"])

        XCTAssertFalse(plan.demoteToDeep.contains("pin-ancient"))
        XCTAssertFalse(plan.archiveIDs.contains("pin-ancient"))
        XCTAssertFalse(plan.demoteToDeep.contains("surf-fresh"))
        XCTAssertFalse(plan.archiveIDs.contains("deep-fresh"))
        XCTAssertFalse(plan.archiveIDs.contains("deep-manual-60d"))
        XCTAssertFalse(plan.promoteToSurface.contains("tomb-hot"))
    }

    func testNightlyPromotionPrefersArchivingUntouchedAutoOverUserEditedAndRespectsPinnedOverflow() {
        let nowMs: Double = 300 * 86_400_000

        // Surface limit is 3, and there are 4 pinned records: NONE of the pinned records may ever demote or archive!
        var records: [MemoryRecord] = (1...4).map { idx in
            MemoryRecord(
                id: "pin-\(idx)",
                text: "置顶核心设定 \(idx)",
                layer: .pinned,
                pinned: true,
                createdAtMs: dayMs(200, from: nowMs),
                usedAtMs: dayMs(200, from: nowMs)
            )
        }
        records.append(contentsOf: [
            MemoryRecord(
                id: "deep-hot",
                text: "频繁回忆的旧事",
                layer: .deep,
                createdAtMs: dayMs(20, from: nowMs),
                usedAtMs: dayMs(1, from: nowMs)
            ),
            MemoryRecord(
                id: "deep-stale-edited",
                text: "用户手改过的很旧记忆",
                layer: .deep,
                createdAtMs: dayMs(150, from: nowMs),
                usedAtMs: dayMs(150, from: nowMs),
                automatic: false,
                editedByUser: true
            ),
            MemoryRecord(
                id: "deep-stale-auto",
                text: "自动抽取且未碰过的很旧记忆",
                layer: .deep,
                createdAtMs: dayMs(150, from: nowMs),
                usedAtMs: dayMs(150, from: nowMs),
                automatic: true,
                editedByUser: false
            ),
        ])

        let config = MemoryPromotionPolicy.Config(
            surfaceLimit: 3,
            maxArchivalsPerRun: 1
        )
        let stats = [
            "deep-hot": MemoryRecallUsageStat(lastRecalledAtMs: dayMs(0.2, from: nowMs), recallCount: 4),
        ]

        let plan = MemoryPromotionPolicy.evaluate(
            records: records,
            usageStats: stats,
            nowMs: nowMs,
            config: config
        )

        // All 4 pinned records stay immune; no surface capacity left so deep-hot isn't forced past pinned ceiling.
        XCTAssertTrue(plan.demoteToDeep.isEmpty)
        XCTAssertTrue(plan.promoteToSurface.isEmpty)
        // Archival budget 1 picks untouched automatic entry ahead of user-edited entry.
        XCTAssertEqual(plan.archiveIDs, ["deep-stale-auto"])
    }

    func testNightlyPromotionNeverPromotesZeroRecallOrSingleRecallUntouchedDeepEntries() {
        let nowMs: Double = 200 * 86_400_000

        let records: [MemoryRecord] = [
            // Newly sunk via `settleMemory` / `setDeep(_:true)` (`usedAtMs > createdAtMs`, `confidence == 1.0`) with ZERO Channel-1 recalls (`stat == nil`).
            MemoryRecord(
                id: "deep-zero-recall-auto",
                text: "沉降到旧事但从未在对话里被召回过的自动记忆",
                layer: .deep,
                confidence: 1.0,
                createdAtMs: dayMs(2, from: nowMs),
                usedAtMs: dayMs(0.2, from: nowMs),
                automatic: true,
                editedByUser: false
            ),
            // User explicitly marked deep (`setDeep(_:true)` bumps `usedAtMs` and sets `editedByUser`). Still ZERO Channel-1 recalls!
            MemoryRecord(
                id: "deep-zero-recall-manual",
                text: "用户手动放进旧事的条目",
                layer: .deep,
                confidence: 1.0,
                createdAtMs: dayMs(10, from: nowMs),
                usedAtMs: dayMs(0.1, from: nowMs),
                automatic: false,
                editedByUser: true
            ),
            // Recalled only once (`recallCount == 1 < minRecallCountForPromotion (2)`), confidence == 1.0, untouched auto -> must NOT promote yet.
            MemoryRecord(
                id: "deep-single-recall",
                text: "只被召回过一次的旧事条目",
                layer: .deep,
                confidence: 1.0,
                createdAtMs: dayMs(15, from: nowMs),
                usedAtMs: dayMs(0.1, from: nowMs),
                automatic: true,
                editedByUser: false
            ),
            // Recalled twice (`recallCount == 2 >= minRecallCountForPromotion (2)`) -> SHOULD promote.
            MemoryRecord(
                id: "deep-twice-recalled",
                text: "连续两天被回忆到的旧事条目",
                layer: .deep,
                confidence: 1.0,
                createdAtMs: dayMs(15, from: nowMs),
                usedAtMs: dayMs(0.1, from: nowMs),
                automatic: true,
                editedByUser: false
            ),
        ]

        let stats: [String: MemoryRecallUsageStat] = [
            "deep-single-recall": MemoryRecallUsageStat(lastRecalledAtMs: dayMs(0.1, from: nowMs), recallCount: 1),
            "deep-twice-recalled": MemoryRecallUsageStat(lastRecalledAtMs: dayMs(0.1, from: nowMs), recallCount: 2),
        ]

        let plan = MemoryPromotionPolicy.evaluate(
            records: records,
            usageStats: stats,
            nowMs: nowMs,
            config: .default
        )

        XCTAssertFalse(plan.promoteToSurface.contains("deep-zero-recall-auto"))
        XCTAssertFalse(plan.promoteToSurface.contains("deep-zero-recall-manual"))
        XCTAssertFalse(plan.promoteToSurface.contains("deep-single-recall"))
        XCTAssertEqual(plan.promoteToSurface, ["deep-twice-recalled"])
    }

    func testHugeMultiTokenQueryBoundsSafelyInMemoryRecall() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let padding = (0..<2500).map { "word\($0)" }.joined(separator: " ")
        let hugeQuery = "重庆 火锅 " + padding
        XCTAssertGreaterThan(hugeQuery.utf8.count, 20_000)
        XCTAssertNotNil(MemoryRecall.buildFTS5OrMatchExpression(for: hugeQuery))

        let records: [MemoryRecord] = [
            MemoryRecord(
                id: "deep-hotpot",
                text: "常去重庆解放碑老店吃麻辣火锅",
                layer: .deep,
                topic: "饮食",
                createdAtMs: 1_000,
                usedAtMs: 1_000
            ),
            MemoryRecord(
                id: "deep-unrelated",
                text: "周末喜欢看黑白电影",
                layer: .deep,
                topic: "娱乐",
                createdAtMs: 2_000,
                usedAtMs: 2_000
            ),
        ]

        let inMemoryHits = MemoryRecall.searchDeep(query: hugeQuery, records: records)
        XCTAssertEqual(inMemoryHits.map(\.id), ["deep-hotpot"])

        let index = MemoryRecallIndex(databaseURL: dir.appendingPathComponent("clio-memory-recall-huge.db"))
        defer { index.close() }
        try index.sync(records: records)

        let ftsHits = try index.searchDeep(query: hugeQuery)
        XCTAssertEqual(ftsHits.map(\.id), ["deep-hotpot"])
    }
}
