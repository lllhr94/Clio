@testable import Craft
import Foundation
import XCTest

final class MemoryImporterTests: XCTestCase {
    func testParsesMixedHeadingsBulletsNumberedAndPlainParagraphs() {
        let input = """
        ---
        title: Exported Notes
        ---

        ## 饮食偏好
        - 不吃香菜
        • 喜欢喝乌龙茶
        * [x] 每天早上喝黑咖啡

        ## 项目开发
        1. 正在开发个人 iOS 助手应用
        2) 主力语言是 **Swift**

        **个人规则：**
        3、回答尽量简洁直接
        (4) 不要随意猜测未验证的数据

        住在成都高新区
        """

        let preview = MemoryImporter.parse(input, defaultLayer: .surface)

        XCTAssertTrue(preview.skipped.isEmpty)
        XCTAssertEqual(preview.candidates.map(\.text), [
            "不吃香菜",
            "喜欢喝乌龙茶",
            "每天早上喝黑咖啡",
            "正在开发个人 iOS 助手应用",
            "主力语言是 Swift",
            "回答尽量简洁直接",
            "不要随意猜测未验证的数据",
            "住在成都高新区",
        ])

        XCTAssertEqual(preview.candidates[0].topic, "饮食偏好")
        XCTAssertEqual(preview.candidates[0].kind, "preference")
        XCTAssertEqual(preview.candidates[3].topic, "项目开发")
        XCTAssertEqual(preview.candidates[3].kind, "project")
        XCTAssertEqual(preview.candidates[5].topic, "个人规则")
        XCTAssertEqual(preview.candidates[5].kind, "rule")
        XCTAssertEqual(preview.candidates[7].topic, "个人规则")
        XCTAssertTrue(preview.candidates.allSatisfy { $0.selected && $0.targetLayer == .surface })
    }

    func testRespectsDefaultDeepLayerForGenericSections() {
        let input = """
        ## Background
        - Used to work in Shenzhen
        - Graduated from computer science
        """

        let preview = MemoryImporter.parse(input, defaultLayer: .deep)
        XCTAssertEqual(preview.candidates.count, 2)
        XCTAssertTrue(preview.candidates.allSatisfy { $0.targetLayer == .deep })
        XCTAssertEqual(preview.candidates.first?.kind, "experience")
        XCTAssertEqual(preview.candidates.first?.topic, "Background")
    }

    func testRoundTripsClioMarkdownMirrorsAndSkipsBotAndBoilerplateLines() {
        let records = [
            MemoryRecord(
                id: "p1",
                text: "所有代码修改前先确认边界",
                layer: .pinned,
                pinned: true,
                kind: "rule",
                topic: "工程规范",
                createdAtMs: 1_000
            ),
            MemoryRecord(
                id: "s1",
                text: "平日喜欢喝凤凰单丛",
                layer: .surface,
                kind: "preference",
                topic: "茶饮",
                createdAtMs: 2_000
            ),
            MemoryRecord(
                id: "d1",
                text: "去年秋天去过京都",
                layer: .deep,
                kind: "experience",
                topic: "",
                createdAtMs: 3_000
            ),
        ]
        let bots = [
            MemoryMirrorBot(name: "小克", role: "温和管家", isMain: true),
        ]
        let dangan = MemoryMarkdownRenderer.renderDangan(records: records, bots: bots)
        let extra = "\n## 补充习惯\n- 周末喜欢骑行\n"
        let combined = MemoryMarkdownRenderer.mergeManagedSection(dangan, into: nil) + extra

        let preview = MemoryImporter.parse(combined, defaultLayer: .surface)

        XCTAssertTrue(preview.skipped.isEmpty)
        XCTAssertEqual(preview.candidates.count, 4)

        let pinned = preview.candidates[0]
        XCTAssertEqual(pinned.text, "所有代码修改前先确认边界")
        XCTAssertEqual(pinned.targetLayer, .pinned)
        XCTAssertEqual(pinned.kind, "rule")
        XCTAssertEqual(pinned.topic, "工程规范")

        let surface = preview.candidates[1]
        XCTAssertEqual(surface.text, "平日喜欢喝凤凰单丛")
        XCTAssertEqual(surface.targetLayer, .surface)
        XCTAssertEqual(surface.kind, "preference")
        XCTAssertEqual(surface.topic, "茶饮")

        let deep = preview.candidates[2]
        XCTAssertEqual(deep.text, "去年秋天去过京都")
        XCTAssertEqual(deep.targetLayer, .deep)
        XCTAssertEqual(deep.kind, "experience")

        let userExtra = preview.candidates[3]
        XCTAssertEqual(userExtra.text, "周末喜欢骑行")
        XCTAssertEqual(userExtra.targetLayer, .surface)
        XCTAssertEqual(userExtra.topic, "补充习惯")
        XCTAssertEqual(userExtra.kind, "preference")
    }

    func testFiltersExistingBatchAndRetractedDuplicates() {
        let retractedText = "以前在旧公司用过 SVN"
        let retractedHash = MemorySafety.retractionHash(retractedText)
        let input = """
        - 不吃香菜！
        - 喜欢喝乌龙茶
        - 喜欢喝，乌龙茶。
        - 以前在旧公司用过 SVN
        - 住在北京朝阳区
        """

        let preview = MemoryImporter.parse(
            input,
            defaultLayer: .surface,
            existingTexts: ["不吃香菜"],
            suppressedHashes: [retractedHash]
        )

        XCTAssertEqual(preview.candidates.map(\.text), [
            "喜欢喝乌龙茶",
            "住在北京朝阳区",
        ])
        XCTAssertEqual(preview.skipped.count, 3)
        XCTAssertEqual(preview.skipped.map(\.reason), [
            .duplicateExisting,
            .duplicateInBatch,
            .retracted,
        ])
    }

    func testRejectsSecretsAndOversizedLinesWhileAllowingHarmlessMentions() {
        let syntheticVaultSecret = "vault-" + String(repeating: "s", count: 12)
        let syntheticApiToken = "sk-" + String(repeating: "a", count: 24)
        let syntheticGhToken = "ghp_" + String(repeating: "x", count: 24)
        let syntheticBearer = "Bearer " + String(repeating: "z", count: 24)
        let oversized = String(repeating: "字", count: 180)

        let input = """
        - 密钥是 \(syntheticVaultSecret)
        - OpenAI key is \(syntheticApiToken)
        - GitHub token: \(syntheticGhToken)
        - Header \(syntheticBearer)
        - password: demo-pass-9876
        - 我平时用 1Password 管理账号密码
        - OpenAI key: none
        - api_key: none
        - \(oversized)
        - 每天晚上十一点前睡觉
        """

        let preview = MemoryImporter.parse(
            input,
            defaultLayer: .surface,
            secrets: [syntheticVaultSecret]
        )

        XCTAssertEqual(preview.candidates.map(\.text), [
            "我平时用 1Password 管理账号密码",
            "OpenAI key: none",
            "api_key: none",
            "每天晚上十一点前睡觉",
        ])
        XCTAssertEqual(preview.skipped.count, 6)
        XCTAssertEqual(preview.skipped.filter { $0.reason == .secretDetected }.count, 5)
        XCTAssertEqual(preview.skipped.filter { $0.reason == .tooLong }.count, 1)

        // Ensure secret-blocked skipped items use the generic redacted placeholder and leak zero characters.
        for item in preview.skipped where item.reason == .secretDetected {
            XCTAssertEqual(item.text, MemoryImporter.redactedSecretPreview)
            XCTAssertFalse(item.text.contains(syntheticVaultSecret))
            XCTAssertFalse(item.text.contains(syntheticApiToken))
            XCTAssertFalse(item.text.contains(syntheticGhToken))
            XCTAssertFalse(item.text.contains("demo-pass-9876"))
            XCTAssertFalse(item.text.contains("OpenAI"))
            XCTAssertFalse(item.text.contains("password"))
            XCTAssertTrue(item.text.contains("〔隐去〕"))
        }
    }

    func testRetractedPredicateDeduplicatesRepeatedRetractedItems() {
        let retractedText = "以前用过某旧系统"
        let input = """
        - \(retractedText)
        - \(retractedText)
        - 喜欢喝绿茶
        """

        let preview = MemoryImporter.parse(
            input,
            defaultLayer: .surface,
            isRetracted: { $0 == retractedText }
        )

        XCTAssertEqual(preview.candidates.map(\.text), ["喜欢喝绿茶"])
        XCTAssertEqual(preview.skipped.count, 2)
        XCTAssertTrue(preview.skipped.allSatisfy { $0.reason == .retracted })
    }

    func testParsesChatGPTStyleNoteAndInlineTagSyntax() {
        let input = """
        Preferences:
        - Prefers dark mode and calm typography
        - [goal · 阅读] 今年想读完二十本书
        - [音乐] 常听爵士和古典钢琴
        """

        let preview = MemoryImporter.parse(input, defaultLayer: .surface)

        XCTAssertEqual(preview.candidates.count, 3)
        XCTAssertEqual(preview.candidates[0].kind, "preference")
        XCTAssertEqual(preview.candidates[0].topic, "Preferences")
        XCTAssertEqual(preview.candidates[1].kind, "goal")
        XCTAssertEqual(preview.candidates[1].topic, "阅读")
        XCTAssertEqual(preview.candidates[1].text, "今年想读完二十本书")
        XCTAssertEqual(preview.candidates[2].kind, "fact")
        XCTAssertEqual(preview.candidates[2].topic, "音乐")
        XCTAssertEqual(preview.candidates[2].text, "常听爵士和古典钢琴")
    }

    func testHandlesCRLFHorizontalRulesAndCodeFenceWrappers() {
        let input = "\u{FEFF}```markdown\r\n## 生活\r\n- 喜欢早起散步\r\n---\r\n> 家里养了一只橘猫\r\n```"
        let preview = MemoryImporter.parse(input, defaultLayer: .deep)

        XCTAssertTrue(preview.skipped.isEmpty)
        XCTAssertEqual(preview.candidates.map(\.text), [
            "喜欢早起散步",
            "家里养了一只橘猫",
        ])
        XCTAssertTrue(preview.candidates.allSatisfy { $0.targetLayer == .deep && $0.topic == "生活" })
    }

    func testBlocksMultilinePEMBlocksAndMultiWordSecretsAndSecretHeadings() {
        let vaultSecret = "VaultSecretMixedCase99"
        let pemBegin = "-----BEGIN " + "PRIVATE KEY-----"
        let pemEnd = "-----END " + "PRIVATE KEY-----"
        let input = """
        \(pemBegin)
        MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7FakeBodyLine1
        FakeBase64KeyMaterialLine2WithSlash+AndEquals==
        \(pemEnd)

        ## \(vaultSecret)
        - 平时喜欢喝茶

        \(vaultSecret):
        - [\(vaultSecret) · 饮食] 喜欢绿茶
        - [\(vaultSecret)] 喜欢红茶
        - password: my real passphrase
        """

        let preview = MemoryImporter.parse(input, defaultLayer: .surface, secrets: [vaultSecret])

        XCTAssertEqual(preview.candidates.map(\.text), ["平时喜欢喝茶"])
        XCTAssertEqual(preview.candidates.first?.topic, "")
        XCTAssertGreaterThanOrEqual(preview.skipped.count, 8)
        XCTAssertTrue(preview.skipped.allSatisfy { $0.reason == .secretDetected && $0.text == MemoryImporter.redactedSecretPreview })
    }

    func testPreservesCompoundTopicsLikeIOSSwiftVerbatim() {
        let records = [
            MemoryRecord(
                id: "t1",
                text: "喜欢用 SwiftUI 和 Combine",
                layer: .surface,
                kind: "fact",
                topic: "iOS / Swift",
                createdAtMs: 1_000
            ),
            MemoryRecord(
                id: "t2",
                text: "代码保持简洁",
                layer: .pinned,
                pinned: true,
                kind: "rule",
                topic: "iOS / Swift",
                createdAtMs: 2_000
            ),
        ]

        let dangan = MemoryMarkdownRenderer.renderDangan(records: records)
        let preview = MemoryImporter.parse(dangan, defaultLayer: .surface)

        XCTAssertTrue(preview.skipped.isEmpty)
        XCTAssertEqual(preview.candidates.count, 2)
        // `renderDangan` outputs `.pinned` section first, then `.surface` section.
        XCTAssertEqual(preview.candidates[0].kind, "rule")
        XCTAssertEqual(preview.candidates[0].topic, "iOS / Swift")
        XCTAssertEqual(preview.candidates[1].kind, "preference")
        XCTAssertEqual(preview.candidates[1].topic, "iOS / Swift")
    }

    func testBlocksQuotedJSONAndYAMLSecretKeysWhileAllowingHarmlessPlaceholders() {
        let input = #"""
        "password": "my-secret-123"
        'api_key': 'token-9999'
        {"client_secret": "topsecret"}
        {"password": "my-secret-pass", "host": "a"}
        "password": "none"
        {"api_key": "none"}
        """#

        let preview = MemoryImporter.parse(input, defaultLayer: .surface)

        XCTAssertEqual(preview.candidates.map(\.text), [
            "\"password\": \"none\"",
            "{\"api_key\": \"none\"}",
        ])
        XCTAssertEqual(preview.skipped.count, 4)
        XCTAssertTrue(preview.skipped.allSatisfy {
            $0.reason == .secretDetected && $0.text == MemoryImporter.redactedSecretPreview
        })

        for item in preview.skipped {
            XCTAssertFalse(item.text.contains("my-secret-123"))
            XCTAssertFalse(item.text.contains("token-9999"))
            XCTAssertFalse(item.text.contains("topsecret"))
            XCTAssertFalse(item.text.contains("my-secret-pass"))
            XCTAssertFalse(item.text.contains("client_secret"))
        }

        let singleJsonPlaceholder = MemoryImporter.parse(#"{"password": "none"}"#, defaultLayer: .surface)
        XCTAssertTrue(singleJsonPlaceholder.skipped.isEmpty)
        XCTAssertEqual(singleJsonPlaceholder.candidates.map(\.text), [#"{"password": "none"}"#])
    }
}
