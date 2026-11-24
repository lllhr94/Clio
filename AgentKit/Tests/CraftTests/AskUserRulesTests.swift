import AgentKit
import Craft
import Foundation
import XCTest

final class AskUserRulesTests: XCTestCase {
    // MARK: - Force-Secret Classification (Security-Critical)

    func testForceSecretOverridesExplicitSecretFalseAcrossEnglishTerms() {
        let sensitiveCases: [(key: String, label: String, placeholder: String)] = [
            ("password", "Login Password", ""),
            ("passwd", "Passwd", ""),
            ("pwd", "PWD", ""),
            ("pw", "PW", ""),
            ("secret", "Client Secret", ""),
            ("api_key", "Key", ""),
            ("apikey", "APIKey", ""),
            ("apiKey", "Service Key", ""),
            ("APIKey", "OpenAI", ""),
            ("secret_key", "Signing Key", ""),
            ("private_key", "SSH Private Key", ""),
            ("key", "Key", ""),
            ("enter_key", "Enter key", ""),
            ("token", "Access", ""),
            ("access_token", "Access Token", ""),
            ("jwt", "JWT", ""),
            ("bearer", "Authorization", ""),
            ("credential", "Credential", ""),
            ("auth", "Auth", ""),
            ("oauth", "OAuth", ""),
            ("auth_header", "Header", ""),
            ("cookie", "Cookie", ""),
            ("session", "Session ID", ""),
            ("passphrase", "SSH Passphrase", ""),
            ("pin", "PIN", ""),
            ("pin_code", "PIN Code", ""),
            ("otp", "One-Time Code", ""),
            ("totp", "Authenticator", ""),
            ("2fa", "Two-Factor", ""),
            ("cvv", "Security Code", ""),
            ("ssn", "Tax / SSN", ""),
            ("credit_card", "Card Number", ""),
            ("recovery_code", "Recovery Code", ""),
            ("seed_phrase", "Wallet Phrase", ""),
            ("connection_string", "DB Connection String", ""),
            ("val", "Value", "sk-proj-123456"),
            ("val", "Value", "ghp_abcdefghij"),
            ("val", "Value", "AIzaSyExampleKey"),
            ("val", "Value", "AKIA" + "TESTSAMPLE01"),
            ("val", "Value", "-----BEGIN OPENSSH PRIVATE KEY-----"),
            ("proxy", "Proxy URL", "https://user:secretpass@proxy.internal:8080"),
        ]

        for item in sensitiveCases {
            let args: JSONValue = [
                "title": "请补充配置",
                "fields": [[
                    "key": .string(item.key),
                    "label": .string(item.label),
                    "placeholder": .string(item.placeholder),
                    "secret": false,
                ]],
            ]
            guard case .success(let prompt) = AskUserRules.parse(args) else {
                XCTFail("Expected parse success for \(item.key)/\(item.label)")
                continue
            }
            XCTAssertTrue(prompt.requiresVault, "Must require Vault for \(item)")
            XCTAssertFalse(prompt.allowsInline, "Must forbid inline for \(item)")
            XCTAssertEqual(prompt.questions.first?.secret, true, "Must override secret: false -> true for \(item)")
        }
    }

    func testForceSecretOverridesAcrossChineseTerms() {
        let chineseCases: [(key: String, label: String)] = [
            ("v1", "登录密码"),
            ("v2", "动态口令"),
            ("v3", "API 密钥"),
            ("v4", "服务秘钥"),
            ("v5", "SSH 私钥"),
            ("v6", "访问令牌"),
            ("v7", "身份凭证"),
            ("v8", "登录凭据"),
            ("v9", "短信验证码"),
            ("v10", "银行卡号"),
            ("v11", "身份证号"),
            ("v12", "信用卡安全码"),
            ("v13", "助记词"),
            ("v14", "备用恢复码"),
            ("v15", "PIN码"),
            ("v16", "鉴权头"),
        ]

        for item in chineseCases {
            let args: JSONValue = [
                "title": "填写资料",
                "fields": [[
                    "key": .string(item.key),
                    "label": .string(item.label),
                    "secret": false,
                ]],
            ]
            guard case .success(let prompt) = AskUserRules.parse(args) else {
                XCTFail("Expected parse success for \(item.label)")
                continue
            }
            XCTAssertTrue(prompt.requiresVault, "Must require Vault for \(item.label)")
            XCTAssertFalse(prompt.allowsInline, "Must forbid inline for \(item.label)")
            XCTAssertEqual(prompt.questions.first?.secret, true, "Must force secret=true for \(item.label)")
        }
    }

    func testFormLevelPromptOrTitleTriggersForceSecretEvenWithGenericField() throws {
        let args: JSONValue = [
            "title": "需要你的 GitHub Personal Access Token",
            "reason": "用于拉取私有仓库",
            "fields": [[
                "key": "val",
                "label": "输入内容",
                "secret": false,
            ]],
        ]
        let prompt = try unwrapSuccess(AskUserRules.parse(args))
        XCTAssertTrue(prompt.requiresVault)
        XCTAssertFalse(prompt.allowsInline)
        XCTAssertTrue(prompt.questions[0].secret)

        // Shorthand `question` / `prompt` also triggers force-secret.
        let shorthand: JSONValue = [
            "question": "请输入你的登录密码",
            "secret": false,
        ]
        let prompt2 = try unwrapSuccess(AskUserRules.parse(shorthand))
        XCTAssertTrue(prompt2.requiresVault)
        XCTAssertFalse(prompt2.allowsInline)
        XCTAssertTrue(prompt2.questions[0].secret)
    }

    func testObfuscationWithZeroWidthAndFullwidthCharactersStillTriggersSecret() throws {
        let args: JSONValue = [
            "title": "配置",
            "fields": [
                ["key": "a", "label": "密\u{200B}码", "secret": false],
                ["key": "b", "label": "ａｐｉ＿ｋｅｙ", "secret": false],
                ["key": "c", "label": "pass\u{FEFF}word", "secret": false],
                ["key": "d", "label": "primary_key_and_api_key", "secret": false],
            ],
        ]
        let prompt = try unwrapSuccess(AskUserRules.parse(args))
        XCTAssertTrue(prompt.requiresVault)
        XCTAssertFalse(prompt.allowsInline)
        XCTAssertTrue(prompt.questions.allSatisfy(\.secret))
    }

    func testAdversarialOptionsAndAllowCustomCannotBypassVaultForSecrets() throws {
        let args: JSONValue = [
            "title": "请填写 API Key",
            "type": "single",
            "options": ["跳过", "稍后再填"],
            "allowCustom": true,
            "value": "sk-leaked-default",
            "secret": false,
        ]
        let prompt = try unwrapSuccess(AskUserRules.parse(args))
        XCTAssertTrue(prompt.requiresVault)
        XCTAssertFalse(prompt.allowsInline)
        let q = try XCTUnwrap(prompt.questions.first)
        XCTAssertTrue(q.secret)
        XCTAssertEqual(q.kind, .text)
        XCTAssertTrue(q.options.isEmpty)
        XCTAssertFalse(q.allowCustom)
        XCTAssertEqual(q.defaultValue, "")
    }

    func testMixedFormKeepsNonSecretUsernameReadableWhileForcingVaultSheet() throws {
        let args: JSONValue = [
            "title": "账号登录",
            "fields": [
                ["key": "username", "label": "用户名", "value": "alice"],
                ["key": "password", "label": "密码", "secret": false],
            ],
        ]
        let prompt = try unwrapSuccess(AskUserRules.parse(args))
        XCTAssertTrue(prompt.requiresVault)
        XCTAssertFalse(prompt.allowsInline)
        XCTAssertFalse(prompt.questions[0].secret)
        XCTAssertEqual(prompt.questions[0].defaultValue, "alice")
        XCTAssertTrue(prompt.questions[1].secret)
    }

    func testConcatenatedCredentialStemsTriggerSecretWhileBenignSubstringsStaySafe() throws {
        let concatenatedSecrets = [
            "dbpassword",
            "mysqlpassword",
            "rootpasswd",
            "sshpassphrase",
            "openaiapikey",
            "clientsecret",
            "secondsecret",
            "githubtoken",
            "accesstoken",
            "refreshtoken",
            "bearertoken",
            "pincode",
            "smsotp",
            "rootpwd",
            "adminpass",
        ]
        for key in concatenatedSecrets {
            let args: JSONValue = [
                "title": "配置参数",
                "fields": [[
                    "key": .string(key),
                    "label": "值",
                    "secret": false,
                ]],
            ]
            let prompt = try unwrapSuccess(AskUserRules.parse(args))
            XCTAssertTrue(prompt.requiresVault, "Must require Vault for concatenated key '\(key)'")
            XCTAssertFalse(prompt.allowsInline, "Must forbid inline for concatenated key '\(key)'")
            XCTAssertTrue(prompt.questions[0].secret, "Must force secret=true for concatenated key '\(key)'")
        }

        let benignWords = ["secretary", "tokenizer", "keyword", "primary_key"]
        for key in benignWords {
            let args: JSONValue = [
                "title": "普通设置",
                "fields": [[
                    "key": .string(key),
                    "label": "字段名",
                ]],
            ]
            let prompt = try unwrapSuccess(AskUserRules.parse(args))
            XCTAssertFalse(prompt.requiresVault, "Benign key '\(key)' must not trigger Vault")
            XCTAssertFalse(prompt.questions[0].secret, "Benign key '\(key)' must not be marked secret")
        }
    }

    func testMixedAndFormFlaggedFormsDoNotLeaveUnprotectedFreeTextFields() throws {
        // Case 1: "填登录信息" + ["password", "backup_note"] must protect backup_note too.
        let loginBackup: JSONValue = [
            "title": "填登录信息",
            "fields": [
                ["key": "password", "label": "密码", "secret": false],
                ["key": "backup_note", "label": "备用信息", "secret": false],
            ],
        ]
        let prompt1 = try unwrapSuccess(AskUserRules.parse(loginBackup))
        XCTAssertTrue(prompt1.requiresVault)
        XCTAssertFalse(prompt1.allowsInline)
        XCTAssertTrue(prompt1.questions[0].secret)
        XCTAssertTrue(prompt1.questions[1].secret)

        // Case 2: ["api_key", "second_secret"] -> both forced secret.
        let dualSecret: JSONValue = [
            "title": "填登录信息",
            "fields": [
                ["key": "api_key", "label": "主密钥", "secret": false],
                ["key": "second_secret", "label": "备用项", "secret": false],
            ],
        ]
        let prompt2 = try unwrapSuccess(AskUserRules.parse(dualSecret))
        XCTAssertTrue(prompt2.requiresVault)
        XCTAssertTrue(prompt2.questions[0].secret)
        XCTAssertTrue(prompt2.questions[1].secret)

        // Case 3: Form-level secret signal protects ALL free-text fields except explicit harmless identity fields,
        // while keeping explicitly option-bounded non-secret pickers intact.
        let formFlaggedMixed: JSONValue = [
            "title": "请填写你的登录密码",
            "fields": [
                ["key": "env", "label": "环境", "choices": ["生产", "测试"]],
                ["key": "username", "label": "用户名", "secret": false],
                ["key": "password", "label": "密码", "secret": false],
                ["key": "extra_note", "label": "附加信息", "secret": false],
            ],
        ]
        let prompt3 = try unwrapSuccess(AskUserRules.parse(formFlaggedMixed))
        XCTAssertTrue(prompt3.requiresVault)
        XCTAssertFalse(prompt3.questions[0].secret)
        XCTAssertFalse(prompt3.questions[1].secret)
        XCTAssertTrue(prompt3.questions[2].secret)
        XCTAssertTrue(prompt3.questions[3].secret)

        // Case 4: Mixed non-ASCII + ASCII label (e.g. "请填你的取款暗语 (user)") must NOT bypass via ASCII token "user".
        let mixedLabelBypass: JSONValue = [
            "title": "请填写你的登录密码",
            "fields": [
                ["key": "user", "label": "请填你的取款暗语 (user)", "secret": false],
                ["key": "password", "label": "密码", "secret": false],
            ],
        ]
        let prompt4 = try unwrapSuccess(AskUserRules.parse(mixedLabelBypass))
        XCTAssertTrue(prompt4.requiresVault)
        XCTAssertTrue(prompt4.questions[0].secret)
        XCTAssertTrue(prompt4.questions[1].secret)
    }

    func testRedactURLCredentialsStripsUserinfoAndProtectsPromptMetadata() throws {
        XCTAssertEqual(
            AskUserRules.redactURLCredentials(in: "https://alice:hunter2@git.example.com/org/repo?a=1#top"),
            "https://git.example.com/org/repo?a=1#top"
        )
        XCTAssertEqual(
            AskUserRules.redactURLCredentials(in: "https://tokenonly@api.example.com/v1"),
            "https://api.example.com/v1"
        )
        XCTAssertEqual(
            AskUserRules.redactURLCredentials(in: "联系 mailto:alice@example.com 或访问 https://bob:pw@a.com/x 和 http://u:p@b.com"),
            "联系 mailto:alice@example.com 或访问 https://a.com/x 和 http://b.com"
        )

        let args: JSONValue = [
            "title": "登录 https://admin:secret@portal.example.com",
            "site": "https://admin:secret@portal.example.com/login",
            "fields": [["key": "note", "label": "说明"]],
        ]
        let prompt = try unwrapSuccess(AskUserRules.parse(args))
        XCTAssertTrue(prompt.requiresVault)
        XCTAssertFalse(AskUserRules.containsSecretURLCredential(prompt.site))
        XCTAssertFalse(AskUserRules.containsSecretURLCredential(prompt.title))
        XCTAssertEqual(prompt.site, "https://portal.example.com/login")
        XCTAssertEqual(prompt.title, "登录 https://portal.example.com")

        // Empty-username URL credentials (`scheme://:password@host:port/path`) must also trigger secret_url and redact.
        let emptyUserURL: JSONValue = [
            "title": "连接 https://:hunter2@api.example.com:8443/v1",
            "site": "https://:hunter2@api.example.com:8443/v1",
            "fields": [["key": "note", "label": "说明"]],
        ]
        let prompt2 = try unwrapSuccess(AskUserRules.parse(emptyUserURL))
        XCTAssertTrue(prompt2.requiresVault)
        XCTAssertEqual(prompt2.secretReason, "secret_url")
        XCTAssertFalse(AskUserRules.containsSecretURLCredential(prompt2.site))
        XCTAssertFalse(AskUserRules.containsSecretURLCredential(prompt2.title))
        XCTAssertEqual(prompt2.site, "https://api.example.com:8443/v1")
        XCTAssertEqual(prompt2.title, "连接 https://api.example.com:8443/v1")
    }

    func testClosedPresetAuthChoicesStaySelectableUnlessCredentialPayload() throws {
        let oauthVsApiKey: JSONValue = [
            "title": "选择认证方式",
            "fields": [[
                "key": "auth",
                "label": "登录方式",
                "choices": ["OAuth", "API Key"],
                "secret": false,
            ]],
        ]
        let prompt1 = try unwrapSuccess(AskUserRules.parse(oauthVsApiKey))
        XCTAssertFalse(prompt1.requiresVault)
        XCTAssertTrue(prompt1.allowsInline)
        XCTAssertFalse(prompt1.questions[0].secret)
        XCTAssertEqual(prompt1.questions[0].kind, .single)
        XCTAssertEqual(prompt1.questions[0].options.map(\.value), ["OAuth", "API Key"])

        let legacyAuth: JSONValue = [
            "title": "SSH 登录",
            "fields": [[
                "key": "auth",
                "label": "登录方式",
                "choices": ["密码", "钥匙"],
            ]],
        ]
        let prompt2 = try unwrapSuccess(AskUserRules.parse(legacyAuth))
        XCTAssertFalse(prompt2.requiresVault)
        XCTAssertFalse(prompt2.questions[0].secret)
        XCTAssertEqual(prompt2.questions[0].options.map(\.value), ["密码", "钥匙"])

        // Adding allowCustom: true on an auth-named field still fails closed to secret.
        let customAuth: JSONValue = [
            "title": "选择认证方式",
            "fields": [[
                "key": "auth",
                "label": "登录方式",
                "choices": ["OAuth", "API Key"],
                "allowCustom": true,
                "secret": false,
            ]],
        ]
        let prompt3 = try unwrapSuccess(AskUserRules.parse(customAuth))
        XCTAssertTrue(prompt3.requiresVault)
        XCTAssertTrue(prompt3.questions[0].secret)

        // Closed option containing an actual token prefix is still flagged secret and scrubbed.
        let payloadInChoice: JSONValue = [
            "title": "选择预设",
            "fields": [[
                "key": "preset",
                "label": "方案",
                "choices": ["sk-proj-secret123456", "default"],
            ]],
        ]
        let prompt4 = try unwrapSuccess(AskUserRules.parse(payloadInChoice))
        XCTAssertTrue(prompt4.requiresVault)
        XCTAssertTrue(prompt4.questions[0].secret)
        XCTAssertTrue(prompt4.questions[0].options.isEmpty)
    }

    func testBenignPromptsAreNotFalselyClassifiedAsSecret() throws {
        let benignCases: [JSONValue] = [
            [
                "question": "选择目标城市",
                "options": ["北京", "上海", "广州"],
            ],
            [
                "title": "排序方式",
                "fields": [[
                    "key": "sort_key",
                    "label": "排序依据",
                    "options": ["按时间", "按热度"],
                ]],
            ],
            [
                "title": "关键词筛选",
                "fields": [[
                    "key": "keyword",
                    "label": "关键词",
                    "placeholder": "输入要检索的关键词",
                ]],
            ],
            [
                "title": "数据库表结构",
                "fields": [
                    ["key": "primary_key", "label": "Primary Key 字段名"],
                    ["key": "foreign_key", "label": "Foreign Key 关联列"],
                    ["key": "author", "label": "文章作者"],
                ],
            ],
            [
                "title": "快捷键设置",
                "fields": [[
                    "key": "shortcut_key",
                    "label": "Shortcut Key",
                    "options": ["Cmd+K", "Cmd+P"],
                ]],
            ],
            [
                "title": "置顶与地图标点",
                "fields": [
                    ["key": "pin_to_top", "label": "是否置顶 (pin to top)", "options": ["是", "否"]],
                    ["key": "map_pin", "label": "Map Pin 标签"],
                ],
            ],
            [
                "title": "服务地址与联系邮箱",
                "fields": [
                    ["key": "endpoint", "label": "服务地址", "placeholder": "https://api.example.com/v1"],
                    ["key": "email", "label": "通知邮箱", "placeholder": "user@example.com"],
                ],
            ],
        ]

        for args in benignCases {
            let prompt = try unwrapSuccess(AskUserRules.parse(args))
            XCTAssertFalse(prompt.requiresVault, "False positive Vault trigger on: \(args)")
            XCTAssertTrue(prompt.allowsInline, "Should allow inline for benign prompt: \(args)")
            XCTAssertFalse(prompt.questions.contains(where: \.secret), "No field should be secret in: \(args)")
        }
    }

    func testMoreThanThreeBenignFieldsRoutesToSheetWithoutSecrets() throws {
        let args: JSONValue = [
            "title": "行程信息",
            "fields": [
                ["key": "city", "label": "城市"],
                ["key": "days", "label": "天数"],
                ["key": "budget", "label": "预算"],
                ["key": "style", "label": "偏好"],
            ],
        ]
        let prompt = try unwrapSuccess(AskUserRules.parse(args))
        XCTAssertFalse(prompt.requiresVault)
        XCTAssertFalse(prompt.allowsInline)
        XCTAssertFalse(prompt.questions.contains(where: \.secret))
    }

    // MARK: - Option Parsing, Bounds & Error Handling

    func testStructuredOptionsDedupAndMetadataParsing() throws {
        let args: JSONValue = [
            "question": "选择输出格式",
            "type": "single",
            "allowCustom": true,
            "options": [
                ["value": "md", "label": "Markdown", "description": "适合编辑", "recommended": false],
                ["value": "pdf", "label": "PDF", "description": "适合发给别人"],
                ["value": "md", "label": "Markdown 重复", "recommended": true],
                "  ",
            ],
        ]
        let prompt = try unwrapSuccess(AskUserRules.parse(args))
        let q = try XCTUnwrap(prompt.questions.first)
        XCTAssertEqual(q.key, "answer")
        XCTAssertEqual(q.kind, .single)
        XCTAssertTrue(q.allowCustom)
        XCTAssertEqual(q.options.count, 2)
        XCTAssertEqual(q.options[0].value, "md")
        XCTAssertEqual(q.options[0].label, "Markdown")
        XCTAssertEqual(q.options[0].recommended, true)
        XCTAssertEqual(q.options[1].value, "pdf")
    }

    func testInvalidJSONArgumentsFailCleanly() {
        let invalidInputs: [JSONValue] = [
            .string("not an object"),
            ["title": "空表单"],
            ["title": "空数组", "fields": []],
            ["title": "非数组", "fields": "invalid"],
            ["title": "重复键", "fields": [["key": "a", "label": "A"], ["key": "a", "label": "B"]]],
            ["title": "缺 key", "fields": [["key": "  ", "label": "A"]]],
            ["title": "未知题型", "question": "选", "type": "slider", "options": ["1", "2"]],
            ["title": "空选项", "question": "选", "type": "single", "options": ["  "], "allowCustom": false],
            ["title": "负数下限", "question": "选", "type": "multi", "options": ["A", "B"], "minSelections": -1],
            ["title": "零上限", "question": "选", "type": "multi", "options": ["A", "B"], "maxSelections": 0],
            ["title": "下限大于上限", "question": "选", "type": "multi", "options": ["A", "B", "C"], "minSelections": 3, "maxSelections": 2],
            ["title": "单选上限超 1", "question": "选", "type": "single", "options": ["A", "B"], "maxSelections": 2],
            ["title": "非整数限制", "question": "选", "type": "multi", "options": ["A", "B"], "minSelections": .number(1.5)],
            ["title": "下限超可选项", "question": "选", "type": "multi", "options": ["A", "B"], "minSelections": 3],
        ]

        for input in invalidInputs {
            if case .success(let prompt) = AskUserRules.parse(input) {
                XCTFail("Expected failure for invalid input \(input), got \(prompt)")
            }
        }
    }

    func testTooManyQuestionsAndOptionsAreRejected() {
        let thirteenFields: [JSONValue] = (1...13).map { i in
            ["key": .string("k\(i)"), "label": .string("Field \(i)")]
        }
        if case .success = AskUserRules.parse(["title": "Many", "fields": .array(thirteenFields)]) {
            XCTFail("Expected >12 questions to fail")
        }

        let twentyFiveOptions: [JSONValue] = (1...25).map { .string("Opt \($0)") }
        if case .success = AskUserRules.parse(["question": "Many opts", "options": .array(twentyFiveOptions)]) {
            XCTFail("Expected >24 options to fail")
        }

        let twentyFourOptions: [JSONValue] = (1...24).map { .string("Opt \($0)") }
        XCTAssertNoThrow(try unwrapSuccess(AskUserRules.parse(["question": "Max opts", "options": .array(twentyFourOptions)])))
    }

    func testIsSecretFieldHelperAndNullFallbackParsing() throws {
        XCTAssertTrue(AskUserRules.isSecretField(key: "val", label: "Bearer Token"))
        XCTAssertTrue(AskUserRules.isSecretField(key: "custom", label: "其他", options: [AskOption(value: "a", label: "输入密码")], allowCustom: true))
        XCTAssertFalse(AskUserRules.isSecretField(key: "keyword", label: "关键词筛选", placeholder: "输入关键词"))
        XCTAssertFalse(AskUserRules.isSecretField(key: "primary_key", label: "Primary Key"))

        let withNulls: JSONValue = [
            "question": "选风格",
            "options": ["简洁", "详细"],
            "allowCustom": .null,
            "allow_custom": true,
            "minSelections": .null,
            "maxSelections": .null,
        ]
        let prompt = try unwrapSuccess(AskUserRules.parse(withNulls))
        XCTAssertTrue(prompt.questions[0].allowCustom)
        XCTAssertFalse(prompt.requiresVault)
    }

    // MARK: - Selection, Custom Input, Validation & Formatting

    func testSingleSelectPresetAndCustomInputValidation() throws {
        let args: JSONValue = [
            "question": "怎么称呼你？",
            "options": ["老板", "朋友"],
            "allowCustom": true,
        ]
        let prompt = try unwrapSuccess(AskUserRules.parse(args))
        let q = try XCTUnwrap(prompt.questions.first)

        // Preset pick
        let presetFormatted = try unwrapSuccess(AskUserRules.formatResult(prompt: prompt, rawValues: ["answer": "朋友"]))
        XCTAssertEqual(presetFormatted, "用户填好了：\nanswer：朋友")

        // Custom text
        let customFormatted = try unwrapSuccess(AskUserRules.formatResult(prompt: prompt, rawValues: ["answer": "  叫我阿明  "]))
        XCTAssertEqual(customFormatted, "用户填好了：\nanswer：（自定义）叫我阿明")

        // Reject empty when required
        if case .success = AskUserRules.formatResult(prompt: prompt, rawValues: ["answer": "   "]) {
            XCTFail("Empty required answer should fail")
        }

        // Reject both selected + custom in single-select
        if case .success = AskUserRules.validate(response: AskResponse(selected: ["老板"], customText: "阿明"), for: q) {
            XCTFail("Cannot submit both preset and custom in single-select")
        }
    }

    func testSingleSelectDisallowsCustomWhenAllowCustomIsFalse() throws {
        let args: JSONValue = [
            "question": "选一个",
            "options": ["A", "B"],
            "allowCustom": false,
        ]
        let prompt = try unwrapSuccess(AskUserRules.parse(args))
        if case .success = AskUserRules.formatResult(prompt: prompt, rawValues: ["answer": "C"]) {
            XCTFail("Should reject unknown option when allowCustom is false")
        }
    }

    func testMultiSelectRoundTripBoundsDedupAndCustomInput() throws {
        let args: JSONValue = [
            "question": "想保留哪些内容？",
            "type": "multi",
            "options": ["北京, 上海", "代码示例", "参考链接"],
            "allowCustom": true,
            "minSelections": 2,
            "maxSelections": 3,
        ]
        let prompt = try unwrapSuccess(AskUserRules.parse(args))
        let q = try XCTUnwrap(prompt.questions.first)

        // Too few
        let tooFewRaw = AskUserRules.encodeResponse(AskResponse(selected: ["代码示例"]), for: q)
        if case .success = AskUserRules.formatResult(prompt: prompt, rawValues: ["answer": tooFewRaw]) {
            XCTFail("Should reject < minSelections")
        }

        // Valid 2 options (including option containing comma!) + 1 custom text = 3 total
        let validResp = AskResponse(selected: ["北京, 上海", "代码示例", "代码示例"], customText: "  附带流程图  ")
        let encoded = AskUserRules.encodeResponse(validResp, for: q)
        let formatted = try unwrapSuccess(AskUserRules.formatResult(prompt: prompt, rawValues: ["answer": encoded]))
        XCTAssertEqual(formatted, "用户填好了：\nanswer：[\"北京, 上海\",\"代码示例\"]，自定义：附带流程图")

        // Too many (3 preset + 1 custom = 4 > max 3)
        let tooManyResp = AskResponse(selected: ["北京, 上海", "代码示例", "参考链接"], customText: "额外")
        if case .success = AskUserRules.validate(response: tooManyResp, for: q) {
            XCTFail("Should reject > maxSelections when custom pushes total over max")
        }

        // Custom matching an existing option deduplicates cleanly instead of counting twice
        let dupCustomResp = AskResponse(selected: ["代码示例", "参考链接"], customText: "代码示例")
        let validatedDup = try unwrapSuccess(AskUserRules.validate(response: dupCustomResp, for: q))
        XCTAssertEqual(validatedDup.selected, ["代码示例", "参考链接"])
        XCTAssertNil(validatedDup.customText)
    }

    func testOptionalQuestionAllowsEmptyAndOversizedTextFails() throws {
        let args: JSONValue = [
            "title": "补充说明",
            "fields": [[
                "key": "note",
                "label": "备注",
                "required": false,
            ]],
        ]
        let prompt = try unwrapSuccess(AskUserRules.parse(args))
        let formattedEmpty = try unwrapSuccess(AskUserRules.formatResult(prompt: prompt, rawValues: ["note": "   "]))
        XCTAssertEqual(formattedEmpty, "用户填好了：\nnote：（没填）")

        let oversized = String(repeating: "a", count: AskUserRules.maxCustomTextLength + 1)
        if case .success = AskUserRules.formatResult(prompt: prompt, rawValues: ["note": oversized]) {
            XCTFail("Oversized text should fail validation")
        }
    }

    func testOptionalSingleSelectDerivesZeroMinSelectionsConsistently() throws {
        let directOptional = AskQuestion(
            key: "theme",
            label: "主题",
            kind: .single,
            options: [AskOption(value: "light"), AskOption(value: "dark")],
            minSelections: 1,
            required: false
        )
        XCTAssertEqual(directOptional.effectiveMinSelections, 0)
        let validatedEmpty = try unwrapSuccess(AskUserRules.validate(response: AskResponse(), for: directOptional))
        XCTAssertTrue(validatedEmpty.selected.isEmpty)

        let parsedOptional = try unwrapSuccess(AskUserRules.parse([
            "question": "可选单选",
            "choices": ["A", "B"],
            "required": false,
        ]))
        let q = try XCTUnwrap(parsedOptional.questions.first)
        XCTAssertFalse(q.required)
        XCTAssertEqual(q.effectiveMinSelections, 0)
        let formatted = try unwrapSuccess(AskUserRules.formatResult(prompt: parsedOptional, rawValues: ["answer": ""]))
        XCTAssertEqual(formatted, "用户填好了：\nanswer：（未选择）")
    }

    func testLegacyFieldsTextDefaultsOptionalWhileModernV2AndChoicesDefaultRequired() throws {
        let legacyForm: JSONValue = [
            "title": "服务器登记",
            "fields": [
                ["key": "host", "label": "地址"],
                ["key": "note", "label": "备注"],
                ["key": "mode", "label": "模式", "choices": ["快", "稳"]],
            ],
        ]
        let legacyPrompt = try unwrapSuccess(AskUserRules.parse(legacyForm))
        XCTAssertFalse(legacyPrompt.questions[0].required)
        XCTAssertFalse(legacyPrompt.questions[1].required)
        XCTAssertTrue(legacyPrompt.questions[2].required)
        let legacyOk = try unwrapSuccess(AskUserRules.formatResult(
            prompt: legacyPrompt,
            rawValues: ["host": "example.com", "note": "", "mode": "稳"]
        ))
        XCTAssertTrue(legacyOk.contains("note：（没填）"))

        // Legacy choices field still rejects empty
        if case .success = AskUserRules.formatResult(
            prompt: legacyPrompt,
            rawValues: ["host": "example.com", "note": "", "mode": ""]
        ) {
            XCTFail("Legacy choices field without selection should fail")
        }

        // Modern v2 field with `type: "text"` defaults required = true
        let modernFieldForm: JSONValue = [
            "title": "项目摘要",
            "fields": [
                ["key": "summary", "label": "摘要", "type": "text"],
            ],
        ]
        let modernPrompt = try unwrapSuccess(AskUserRules.parse(modernFieldForm))
        XCTAssertTrue(modernPrompt.questions[0].required)
        if case .success = AskUserRules.formatResult(prompt: modernPrompt, rawValues: ["summary": "   "]) {
            XCTFail("Modern v2 text field should require non-empty input by default")
        }
    }

    func testOptionalMultiSelectAllowsEmptyButEnforcesMinSelectionsWhenAnswered() throws {
        let args: JSONValue = [
            "question": "可选标签",
            "type": "multi",
            "choices": ["Swift", "Rust", "Go"],
            "required": false,
            "minSelections": 2,
            "maxSelections": 3,
        ]
        let prompt = try unwrapSuccess(AskUserRules.parse(args))
        let q = try XCTUnwrap(prompt.questions.first)
        XCTAssertFalse(q.required)
        XCTAssertTrue(q.allowsEmptySelection)
        XCTAssertEqual(q.effectiveMinSelections, 0)
        XCTAssertEqual(q.answeredMinSelections, 2)
        XCTAssertEqual(q.minSelections, 2)

        // 0 selections succeeds cleanly
        let zeroFormatted = try unwrapSuccess(AskUserRules.formatResult(prompt: prompt, rawValues: ["answer": ""]))
        XCTAssertEqual(zeroFormatted, "用户填好了：\nanswer：（未选择）")

        // 1 selection (< minSelections 2) fails with .tooFewSelections
        let oneRaw = AskUserRules.encodeResponse(AskResponse(selected: ["Swift"]), for: q)
        if case .failure(let err) = AskUserRules.validate(response: AskResponse(selected: ["Swift"]), for: q) {
            XCTAssertEqual(err, .tooFewSelections("answer", 2))
        } else {
            XCTFail("1 selection must fail with .tooFewSelections(answer, 2)")
        }
        if case .success = AskUserRules.formatResult(prompt: prompt, rawValues: ["answer": oneRaw]) {
            XCTFail("1 selection must fail formatting validation")
        }

        // 2 selections succeeds
        let twoRaw = AskUserRules.encodeResponse(AskResponse(selected: ["Swift", "Rust"]), for: q)
        let twoFormatted = try unwrapSuccess(AskUserRules.formatResult(prompt: prompt, rawValues: ["answer": twoRaw]))
        XCTAssertEqual(twoFormatted, "用户填好了：\nanswer：[\"Swift\",\"Rust\"]")
    }

    func testZeroWidthJoinerAndNonJoinerPreservedInUserTextWhileDetectedInSecrets() throws {
        let engineerEmoji = "👩‍💻 工程师"
        let familyEmoji = "👨‍👩‍👧"
        let persianZWNJ = "می‌خواهم"

        let args: JSONValue = [
            "question": "选择角色 \(familyEmoji)",
            "type": "multi",
            "choices": [engineerEmoji, persianZWNJ],
            "allowCustom": true,
        ]
        let prompt = try unwrapSuccess(AskUserRules.parse(args))
        XCTAssertFalse(prompt.requiresVault)
        let q = try XCTUnwrap(prompt.questions.first)
        XCTAssertEqual(q.options.map(\.value), [engineerEmoji, persianZWNJ])

        let customEmoji = "团队 \(familyEmoji) & \(persianZWNJ)"
        let resp = AskResponse(selected: [engineerEmoji], customText: customEmoji)
        let encoded = AskUserRules.encodeResponse(resp, for: q)
        let decoded = AskUserRules.decodeResponse(from: encoded, for: q)
        XCTAssertEqual(decoded.selected, [engineerEmoji])
        XCTAssertEqual(decoded.customText, customEmoji)

        let formatted = try unwrapSuccess(AskUserRules.formatResult(prompt: prompt, rawValues: ["answer": encoded]))
        XCTAssertTrue(formatted.contains(engineerEmoji))
        XCTAssertTrue(formatted.contains(customEmoji))

        // Secret detection still catches ZWJ/ZWNJ obfuscated credential names
        let obfuscatedSecret: JSONValue = [
            "title": "填写",
            "fields": [["key": "x", "label": "pass\u{200D}word", "secret": false]],
        ]
        let secretPrompt = try unwrapSuccess(AskUserRules.parse(obfuscatedSecret))
        XCTAssertTrue(secretPrompt.requiresVault)
        XCTAssertTrue(secretPrompt.questions[0].secret)
    }

    func testSecretResultNeverEchoesRawValue() throws {
        let args: JSONValue = [
            "title": "服务配置",
            "fields": [
                ["key": "user", "label": "用户名"],
                ["key": "api_key", "label": "API Key", "secret": false],
            ],
        ]
        let prompt = try unwrapSuccess(AskUserRules.parse(args))
        XCTAssertTrue(prompt.requiresVault)

        // Normal Vault Keychain ID output
        let vaultFormatted = try unwrapSuccess(AskUserRules.formatResult(
            prompt: prompt,
            rawValues: ["user": "alice", "api_key": "secret:a1b2c3d4"]
        ))
        XCTAssertEqual(vaultFormatted, "用户填好了：\nuser：alice\napi_key：已存进信匣，编号 a1b2c3d4（你看不到内容）")

        // Even if a raw string somehow reached formatResult on a secret field, it must NEVER echo back!
        let leakedAttempt = try unwrapSuccess(AskUserRules.formatResult(
            prompt: prompt,
            rawValues: ["user": "alice", "api_key": "sk-super-secret-value-9999"]
        ))
        XCTAssertFalse(leakedAttempt.contains("sk-super-secret-value-9999"))
        XCTAssertTrue(leakedAttempt.contains("api_key：（已填）"))
    }

    // MARK: - Helper

    private func unwrapSuccess<T>(_ result: Result<T, AskValidationError>, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        switch result {
        case .success(let value):
            return value
        case .failure(let error):
            XCTFail("Unexpected validation failure: \(error.userMessage)", file: file, line: line)
            throw error
        }
    }
}
