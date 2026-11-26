@testable import Craft
import Foundation
import XCTest

final class MemorySafetyV37Tests: XCTestCase {
    func testSilentMemoryRulesAppearOnlyWhenMemoriesBlockIsActive() {
        let emptyBlock = MemorySafety.renderMemoryBlock(from: [], enabled: true)
        XCTAssertEqual(emptyBlock.fullBlock, "")
        XCTAssertFalse(emptyBlock.fullBlock.contains("如何对待记忆"))

        let disabled = MemorySafety.renderMemoryBlock(
            from: [MemorySafety.Fact(id: "f1", text: "用户喜欢乌龙茶", at: 100)],
            enabled: false
        )
        XCTAssertEqual(disabled.fullBlock, "")

        let active = MemorySafety.renderMemoryBlock(
            from: [MemorySafety.Fact(id: "f1", text: "用户喜欢乌龙茶", at: 100)],
            enabled: true
        )
        XCTAssertTrue(active.fullBlock.contains("不要主动谈论记忆的分层、来源或整理机制"))
        XCTAssertTrue(active.fullBlock.contains("记忆与用户当前亲口说的话有冲突时，一律以当前对话为准"))
    }

    func testPromptPrefixFreezeEnvChangeTailAndMidTurnVaultSecretMasking() {
        let state = MemorySafety.PromptState()
        let secretLock = NSLock()
        var vaultSecrets: [String] = []
        var memoryAllowed = true

        let initialSurface = MemorySafety.Fact(id: "s1", text: "用户每天晨跑三公里", at: 100, isDeep: false)
        let secretBearingSurface = MemorySafety.Fact(id: "s-sec", text: "测试令牌是 sk-midturn-987654321", at: 150, isDeep: false)
        let input = MemorySafety.SystemPromptInput(
            identity: "你是「小克」。",
            memories: [initialSurface, secretBearingSurface],
            memoryEnabled: true
        )
        let refresher = MemoryRecallPromptRefresher(
            input: input,
            state: state,
            isRecallAllowed: {
                secretLock.lock()
                defer { secretLock.unlock() }
                return memoryAllowed
            },
            isMemoryEnabled: {
                secretLock.lock()
                defer { secretLock.unlock() }
                return memoryAllowed
            },
            activeSecrets: {
                secretLock.lock()
                defer { secretLock.unlock() }
                return vaultSecrets
            }
        )
        let before = refresher.currentPrompt()
        XCTAssertTrue(before.prefix.contains("sk-midturn-987654321"))

        // 1. Additive remember: prefix MUST remain 100% byte-identical, while new memory enters <env-change> tail.
        let addedFact = MemorySafety.Fact(id: "s2", text: "用户最近改喝美式咖啡", at: 200, isDeep: false)
        refresher.refresh(memories: [initialSurface, secretBearingSurface, addedFact])
        let afterAdd = refresher.currentPrompt()
        XCTAssertEqual(afterAdd.prefix, before.prefix)
        XCTAssertTrue(afterAdd.tail.contains("<env-change>"))
        XCTAssertTrue(afterAdd.tail.contains("用户最近改喝美式咖啡"))
        XCTAssertFalse(afterAdd.prefix.contains("用户最近改喝美式咖啡"))

        // 2. Workplace mount change: prefix stays byte-identical, <env-change> carries mount update.
        refresher.appendEnvChange(.init(kind: .workplaceMounted(summary: "挂载了书案/挂载/Docs/")))
        let afterMount = refresher.currentPrompt()
        XCTAssertEqual(afterMount.prefix, before.prefix)
        XCTAssertTrue(afterMount.tail.contains("挂载了书案/挂载/Docs/"))

        // 3. Post-freeze added fact modified/demoted -> no stale text lingers in tail or prefix.
        let modifiedAdded = MemorySafety.Fact(id: "s2", text: "用户最近改喝拿铁", at: 200, isDeep: false)
        refresher.refresh(memories: [initialSurface, secretBearingSurface, modifiedAdded])
        let afterEdit = refresher.currentPrompt()
        XCTAssertFalse(afterEdit.full.contains("用户最近改喝美式咖啡"))
        XCTAssertTrue(afterEdit.full.contains("用户最近改喝拿铁"))

        // 4. Vault secret added mid-turn -> immediately masks frozen surface facts in BOTH prefix & full.
        secretLock.lock()
        vaultSecrets = ["sk-midturn-987654321"]
        secretLock.unlock()
        let afterSecret = refresher.currentPrompt()
        XCTAssertFalse(afterSecret.prefix.contains("sk-midturn-987654321"))
        XCTAssertFalse(afterSecret.full.contains("sk-midturn-987654321"))
        XCTAssertTrue(afterSecret.prefix.contains("〔隐去〕"))

        // 5. Permission tightening disables ALL memory injection (prefix & .memoryAdded tail) immediately.
        secretLock.lock()
        memoryAllowed = false
        secretLock.unlock()
        let afterDisable = refresher.currentPrompt()
        XCTAssertFalse(afterDisable.full.contains("用户每天晨跑三公里"))
        XCTAssertFalse(afterDisable.full.contains("用户最近改喝拿铁"))
        XCTAssertTrue(afterDisable.tail.contains("挂载了书案/挂载/Docs/"))
    }

    func testCurrentStatusToolIsZeroApprovalReadOnly() async throws {
        let fixed = CurrentStatusSnapshot(
            localDateTime: "2026-11-27 03:30:00",
            timeZoneIdentifier: "Asia/Shanghai",
            logicalDay: "2026-11-26",
            workplaceSummary: "书案",
            activeBackgroundTasks: 2
        )
        let tool = CurrentStatusTool { fixed }
        XCTAssertTrue(tool.isReadOnlySafe)
        XCTAssertEqual(tool.spec.name, "current_status")
        let out = try await tool.run(.object([:]))
        XCTAssertFalse(out.isError)
        XCTAssertTrue(out.text.contains("2026-11-27 03:30:00"))
        XCTAssertTrue(out.text.contains("2026-11-26"))
        XCTAssertTrue(out.text.contains("书案"))
        XCTAssertTrue(out.text.contains("2"))
    }

    func testSearchAllCoversPinnedSurfaceAndDeepWhileSearchDeepStaysDeepOnly() throws {
        let pinned = MemoryRecord(
            id: "p1",
            text: "用户长期在成都写 Swift 代码",
            layer: .pinned,
            pinned: true,
            createdAtMs: 100
        )
        let surface = MemoryRecord(
            id: "s1",
            text: "用户的咖啡机也是成都买的",
            layer: .surface,
            pinned: false,
            createdAtMs: 200
        )
        let deep = MemoryRecord(
            id: "d1",
            text: "十年前曾在成都武侯区学吉他",
            layer: .deep,
            pinned: false,
            createdAtMs: 50
        )
        let archived = MemoryRecord(
            id: "a1",
            text: "已归档的成都旧地址",
            layer: .archived,
            pinned: false,
            createdAtMs: 10
        )

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("recall-all-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let store = MemoryStore(databaseURL: dir.appendingPathComponent("clio-memory.db"))
        let index = MemoryRecallIndex(databaseURL: dir.appendingPathComponent("recall.db"))
        _ = try store.upsert(pinned, explicitUserAction: true)
        _ = try store.upsert(surface, explicitUserAction: true)
        _ = try store.upsert(deep, explicitUserAction: true)
        _ = try store.upsert(archived, explicitUserAction: true)

        let deepOnly = try MemoryRecall.recallFromStore(query: "成都", store: store, index: index, markUsedNowMs: nil)
        XCTAssertEqual(deepOnly.map(\.id), ["d1"])

        let allActive = try MemoryRecall.recallAllFromStore(query: "成都", store: store, index: index, markUsedNowMs: nil)
        XCTAssertEqual(Set(allActive.map(\.id)), Set(["p1", "s1", "d1"]))
    }
}
