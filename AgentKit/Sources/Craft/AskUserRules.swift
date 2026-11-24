import AgentKit
import Foundation

/// How a single `ask_user` question is answered.
public enum AskFieldKind: String, Codable, Hashable, Sendable {
    case single
    case multi
    case text
}

/// One selectable option for a `.single` or `.multi` question.
public struct AskOption: Codable, Hashable, Sendable, Identifiable {
    public var id: String { value }
    public var value: String
    public var label: String
    public var detail: String
    public var recommended: Bool

    public init(value: String, label: String? = nil, detail: String = "", recommended: Bool = false) {
        self.value = value
        if let label, !label.isEmpty {
            self.label = label
        } else {
            self.label = value
        }
        self.detail = detail
        self.recommended = recommended
    }
}

/// A validated question/field inside an `ask_user` prompt.
public struct AskQuestion: Codable, Hashable, Sendable, Identifiable {
    public var id: String { key }
    public var key: String
    public var label: String
    public var kind: AskFieldKind
    public var options: [AskOption]
    public var allowCustom: Bool
    public var minSelections: Int?
    public var maxSelections: Int?
    public var placeholder: String
    public var defaultValue: String
    public var defaultSelections: [String]
    public var required: Bool
    public var explicitlyOptional: Bool
    public var secret: Bool
    public var requestedSecret: Bool
    public var secretReason: String?

    /// Whether leaving this question completely unanswered (0 items / empty) is permitted.
    public var allowsEmptySelection: Bool {
        !required || minSelections == 0
    }

    /// Minimum items required overall when submitting (0 when optional).
    public var effectiveMinSelections: Int {
        if !required { return 0 }
        return max(0, minSelections ?? 1)
    }

    /// Minimum items required whenever the user chooses to answer (`minSelections` even when optional).
    public var answeredMinSelections: Int {
        if let minSelections { return max(0, minSelections) }
        return required ? 1 : 0
    }

    public init(
        key: String,
        label: String,
        kind: AskFieldKind = .text,
        options: [AskOption] = [],
        allowCustom: Bool = false,
        minSelections: Int? = nil,
        maxSelections: Int? = nil,
        placeholder: String = "",
        defaultValue: String = "",
        defaultSelections: [String] = [],
        required: Bool = true,
        explicitlyOptional: Bool = false,
        secret: Bool = false,
        requestedSecret: Bool? = nil,
        secretReason: String? = nil
    ) {
        self.key = key
        self.label = label
        self.kind = kind
        self.options = options
        self.allowCustom = allowCustom
        self.minSelections = minSelections
        self.maxSelections = maxSelections
        self.placeholder = placeholder
        self.defaultValue = defaultValue
        self.defaultSelections = defaultSelections
        self.required = required
        self.explicitlyOptional = explicitlyOptional
        self.secret = secret
        self.requestedSecret = requestedSecret ?? secret
        self.secretReason = secretReason
    }
}

/// Full parsed `ask_user` prompt including forced-Vault routing classification.
public struct AskPrompt: Codable, Hashable, Sendable {
    public var title: String
    public var reason: String
    public var site: String
    public var questions: [AskQuestion]
    public var requiresVault: Bool
    public var secretReason: String?

    public var allowsInline: Bool {
        !requiresVault && questions.count <= 3 && !questions.contains(where: \.secret)
    }

    public init(
        title: String,
        reason: String = "",
        site: String = "",
        questions: [AskQuestion],
        requiresVault: Bool = false,
        secretReason: String? = nil
    ) {
        self.title = title
        self.reason = reason
        self.site = site
        self.questions = questions
        self.requiresVault = requiresVault
        self.secretReason = secretReason
    }
}

/// User's answer to one `AskQuestion`.
public struct AskResponse: Codable, Hashable, Sendable {
    public var selected: [String]
    public var customText: String?

    public init(selected: [String] = [], customText: String? = nil) {
        self.selected = selected
        self.customText = customText
    }
}

/// Validation failures for `ask_user` schemas and user submissions.
public enum AskValidationError: Error, Equatable, Sendable {
    case invalidArguments(String)
    case emptyFields
    case tooManyQuestions(Int)
    case duplicateKey(String)
    case invalidField(String)
    case emptyOptions(String)
    case tooManyOptions(String, Int)
    case invalidBounds(String)
    case emptySelection(String)
    case invalidOption(String, String)
    case customNotAllowed(String)
    case invalidSelectionCount(String)
    case tooFewSelections(String, Int)
    case tooManySelections(String, Int)
    case textTooLong(String, Int)

    public var userMessage: String {
        switch self {
        case .invalidArguments(let detail): return detail
        case .emptyFields: return "fields 或问题内容是空的。"
        case .tooManyQuestions(let limit): return "一次最多只能提 \(limit) 个问题。"
        case .duplicateKey(let key): return "字段 key「\(key)」重复了。"
        case .invalidField(let detail): return detail
        case .emptyOptions(let key): return "选择题「\(key)」没有提供可选项。"
        case .tooManyOptions(let key, let limit): return "「\(key)」的可选项不能超过 \(limit) 个。"
        case .invalidBounds(let detail): return detail
        case .emptySelection(let key): return "「\(key)」不能为空。"
        case .invalidOption(let key, let option): return "「\(key)」中的选项「\(option)」不在可选范围内。"
        case .customNotAllowed(let key): return "「\(key)」不允许自定义输入。"
        case .invalidSelectionCount(let key): return "「\(key)」只能选 1 项。"
        case .tooFewSelections(let key, let min): return "「\(key)」至少需要选择 \(min) 项。"
        case .tooManySelections(let key, let max): return "「\(key)」最多只能选择 \(max) 项。"
        case .textTooLong(let key, let limit): return "「\(key)」的输入长度超过了 \(limit) 字上限。"
        }
    }
}

/// Pure-Swift parsing, Force-Secret classification, validation, and serialization rules for `ask_user`.
/// All Vault/secret routing decisions MUST flow through here so credentials never touch plain inline chat or tool output.
public enum AskUserRules {
    public static let maxTitleLength = 160
    public static let maxReasonLength = 500
    public static let maxLabelLength = 160
    public static let maxOptionLength = 200
    public static let maxOptionDetailLength = 240
    public static let maxOptionsCount = 24
    public static let maxQuestionsCount = 12
    public static let maxCustomTextLength = 2000
    public static let maxFieldKeyLength = 80
    public static let maxPlaceholderLength = 160

    private struct EncodedMultiResponse: Codable {
        let _clioAsk: Int
        let selected: [String]
        let custom: String?
    }

    // MARK: - Force-Secret Detector

    private static let zeroWidthScalars: Set<Unicode.Scalar> = [
        "\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}"
    ]

    private static let chineseSecretTerms: [String] = [
        "密码", "口令", "密钥", "秘钥", "私钥", "令牌", "凭证", "凭据",
        "验证码", "校验码", "动态码", "安全码", "授权码",
        "银行卡", "卡号", "信用卡", "借记卡",
        "身份证", "证件号", "护照号",
        "助记词", "恢复码", "备用码", "种子词",
        "秘匙", "密匙", "钥匙串", "密保",
        "pin码", "pin 码",
        "鉴权", "认证头", "认证信息", "身份凭据", "会话密钥", "会话令牌"
    ]

    private static let unconditionalSecretTokens: Set<String> = [
        "secret", "secrets",
        "password", "passwords", "passwd", "passcode", "passcodes", "passphrase", "passphrases", "pwd", "pw",
        "token", "tokens", "jwt", "jwts", "bearer",
        "apikey", "apikeys", "secretkey", "secretkeys", "privatekey", "privatekeys", "privkey",
        "sshkey", "pgpkey", "gpgkey", "accesskey", "signingkey", "masterkey",
        "encryptionkey", "decryptionkey", "clientsecret", "appsecret", "webhooksecret",
        "credential", "credentials", "creds",
        "auth", "oauth", "authn", "authz", "authorization", "authenticate", "authentication",
        "cookie", "cookies", "setcookie",
        "session", "sessions", "sessionid", "sessid", "csrf", "xsrf",
        "otp", "totp", "hotp", "mfa", "2fa", "twofa",
        "cvv", "cvc", "csc", "ssn", "iban", "keychain", "mnemonic", "keystore"
    ]

    private static let secretTokenPairs: [(String, String)] = [
        ("credit", "card"), ("debit", "card"), ("bank", "card"),
        ("card", "number"), ("card", "no"), ("bank", "account"), ("routing", "number"),
        ("social", "security"), ("id", "card"), ("national", "id"),
        ("passport", "number"), ("passport", "no"),
        ("driver", "license"), ("drivers", "license"),
        ("recovery", "code"), ("recovery", "codes"),
        ("backup", "code"), ("backup", "codes"),
        ("verification", "code"), ("verify", "code"),
        ("security", "code"), ("access", "code"),
        ("pass", "code"), ("auth", "code"), ("sms", "code"),
        ("seed", "phrase"), ("recovery", "phrase"), ("secret", "phrase"),
        ("connection", "string"), ("api", "secret"), ("app", "secret"),
        ("signing", "secret"), ("webhook", "secret"),
        ("db", "pass"), ("ssh", "pass"), ("user", "pass"), ("login", "pass"),
        ("admin", "pass"), ("root", "pass"), ("wifi", "pass"), ("sudo", "pass"),
        ("proxy", "pass"), ("smtp", "pass"), ("ftp", "pass"), ("vault", "pass"),
        ("master", "pass"), ("account", "pass")
    ]

    private static let unsafeKeyCompanions: Set<String> = [
        "api", "secret", "private", "priv", "auth", "oauth", "token", "access",
        "ssh", "gpg", "pgp", "rsa", "ed25519", "ecdsa", "pem", "signing", "sign",
        "encrypt", "encryption", "decrypt", "decryption", "master", "client",
        "server", "provider", "license", "activation", "bearer", "session",
        "hmac", "aes", "kms", "vault", "wallet", "recovery", "backup",
        "webhook", "openai", "anthropic", "claude", "gemini", "deepseek",
        "tavily", "exa", "brave", "github", "gitlab", "aws", "azure", "gcp",
        "stripe", "pass"
    ]

    private static let safeKeyPreceding: Set<String> = [
        "primary", "foreign", "composite", "candidate", "surrogate", "natural",
        "partition", "sort", "clustering", "sharding", "shard", "grouping", "group",
        "cache", "index", "lookup", "search", "filter", "dictionary", "dict",
        "map", "object", "json", "xml", "yaml", "plist", "column", "row", "record",
        "shortcut", "hot", "arrow", "function", "modifier", "escape", "esc",
        "piano", "musical", "color", "chroma", "low", "high"
    ]

    private static let safeKeyFollowing: Set<String> = [
        "point", "points", "takeaway", "takeaways", "finding", "findings",
        "metric", "metrics", "factor", "factors", "feature", "features",
        "date", "dates", "step", "steps", "milestone", "milestones",
        "binding", "bindings", "mapping", "mappings", "board", "word", "words"
    ]

    private static let secretPinCompanions: Set<String> = [
        "code", "number", "no", "pass", "password", "atm", "sim", "bank",
        "card", "unlock", "login", "security", "verify", "verification",
        "device", "screen", "digit", "digits"
    ]

    private static let safePinPreceding: Set<String> = [
        "map", "location", "place", "marker", "drop", "dropped", "push",
        "safety", "hair", "bowling", "lapel", "enamel", "hat", "rolling", "bobby"
    ]

    private static let safePinFollowing: Set<String> = [
        "to", "on", "at", "top", "bottom", "bar", "tab", "chat", "thread",
        "conversation", "message", "note", "item", "post", "board", "marker",
        "location", "drop"
    ]

    private static let secretTokenPrefixes: [String] = [
        "sk-", "sk_live_", "sk_test_", "rk_live_",
        "ghp_", "gho_", "ghu_", "ghs_", "github_pat_", "glpat-",
        "xoxb-", "xoxp-", "xapp-", "hf_"
    ]

    private static let concatenatedSecretStems: [String] = [
        "password", "passwd", "passphrase", "passcode",
        "apikey", "privatekey", "privkey", "secretkey", "sshkey", "pgpkey", "gpgkey",
        "accesskey", "signingkey", "masterkey", "encryptionkey", "decryptionkey",
        "accesstoken", "refreshtoken", "bearertoken", "authtoken", "apitoken",
        "idtoken", "bottoken", "sessiontoken", "csrftoken", "xsrftoken", "oauthtoken",
        "credential", "cookie", "sessionid", "sessid", "sessionkey",
        "mnemonic", "seedphrase", "recoverycode", "backupcode", "verificationcode",
        "creditcard", "debitcard", "bankcard", "bankaccount", "cardnumber",
        "keychain", "authheader", "authorization",
        "pincode", "atmpin", "simpin", "bankpin",
        "otpcode", "emailotp", "smsotp", "totpcode", "cvvcode", "cvccode", "ssnnumber",
        "dbpwd", "userpwd", "rootpwd", "adminpwd", "loginpwd",
        "dbpass", "sshpass", "rootpass", "userpass", "adminpass", "wifipass",
        "masterpass", "sudopass", "loginpass"
    ]

    private static let benignSecretWords: Set<String> = [
        "secretary", "secretarial", "secretariat", "secrete", "secretion", "secretions"
    ]

    private static let benignTokenWords: Set<String> = [
        "tokenize", "tokenized", "tokenizer", "tokenizers", "tokenization"
    ]

    private static let harmlessIdentityKeys: Set<String> = [
        "user", "username", "account", "email", "mail",
        "host", "hostname", "address", "server", "port", "site", "domain", "region"
    ]

    private static let harmlessIdentityChineseLabels: Set<String> = [
        "用户名", "账号", "账户", "邮箱", "电子邮箱", "主机", "地址", "服务器", "端口", "域名", "地区", "区域"
    ]

    /// Detects whether text asks for or contains a secret, credential, token, key, or sensitive PII.
    /// Returns a safe non-secret rule tag when triggered, or `nil` when benign.
    public static func detectSecretSignal(in rawText: String) -> String? {
        let cleaned = normalizeForDetection(rawText)
        guard !cleaned.isEmpty else { return nil }
        let lower = cleaned.lowercased()

        if containsSecretURLCredential(cleaned) { return "secret_url" }
        if containsPEMHeader(lower) { return "private_key_pem" }
        if containsTokenPrefix(cleaned, lower: lower) { return "token_prefix" }

        for term in chineseSecretTerms where lower.contains(term) {
            return "zh_secret"
        }

        for stem in concatenatedSecretStems where lower.contains(stem) {
            return "stem_\(stem)"
        }

        let tokens = englishTokens(from: cleaned)
        let bases = tokens.map(stripTrailingDigits)

        for base in bases {
            if unconditionalSecretTokens.contains(base) {
                return "token_\(base)"
            }
            if base.contains("secret") && !benignSecretWords.contains(base) {
                return "stem_secret"
            }
            if base.contains("token") && !benignTokenWords.contains(base) {
                return "stem_token"
            }
        }

        if bases.count >= 2 {
            for index in 0..<(bases.count - 1) {
                let pair = (bases[index], bases[index + 1])
                if secretTokenPairs.contains(where: { $0.0 == pair.0 && $0.1 == pair.1 }) {
                    return "phrase_\(pair.0)_\(pair.1)"
                }
            }
        }

        if hasUnsafeKeyToken(bases) {
            return "ambiguous_key"
        }

        if hasUnsafePinToken(bases) {
            return "pin_secret"
        }

        return nil
    }

    /// Strips `userinfo@` (`user:pass@` or `user@` authority prefixes) from any `scheme://...` URLs.
    public static func redactURLCredentials(in raw: String) -> String {
        guard raw.contains("://") else { return raw }
        var result = ""
        var cursor = raw.startIndex

        while let schemeRange = raw.range(of: "://", range: cursor..<raw.endIndex) {
            result.append(contentsOf: raw[cursor..<schemeRange.upperBound])
            let afterScheme = raw[schemeRange.upperBound...]
            let authorityEnd = afterScheme.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" || $0.isWhitespace }) ?? afterScheme.endIndex
            let authority = afterScheme[..<authorityEnd]

            if let atIndex = authority.lastIndex(of: "@") {
                let hostStart = authority.index(after: atIndex)
                result.append(contentsOf: authority[hostStart...])
            } else {
                result.append(contentsOf: authority)
            }
            cursor = authorityEnd
        }

        result.append(contentsOf: raw[cursor..<raw.endIndex])
        return result
    }

    /// Detects whether text contains an actual credential payload (secret URL credentials, PEM block, or token prefix).
    private static func containsActualCredentialPayload(in rawText: String) -> Bool {
        let cleaned = normalizeForDetection(rawText)
        guard !cleaned.isEmpty else { return false }
        let lower = cleaned.lowercased()
        return containsSecretURLCredential(cleaned)
            || containsPEMHeader(lower)
            || containsTokenPrefix(cleaned, lower: lower)
    }

    /// Checks whether a field with the given metadata must be treated as secret.
    public static func isSecretField(
        key: String,
        label: String,
        placeholder: String = "",
        prompt: String = "",
        options: [AskOption] = [],
        allowCustom: Bool = false
    ) -> Bool {
        if !options.isEmpty && !allowCustom {
            for option in options {
                if containsActualCredentialPayload(in: option.value)
                    || containsActualCredentialPayload(in: option.label)
                    || containsActualCredentialPayload(in: option.detail) {
                    return true
                }
            }
            return false
        }
        if detectSecretSignal(in: key) != nil
            || detectSecretSignal(in: label) != nil
            || detectSecretSignal(in: placeholder) != nil
            || detectSecretSignal(in: prompt) != nil {
            return true
        }
        if allowCustom {
            for option in options {
                if detectSecretSignal(in: option.label) != nil || detectSecretSignal(in: option.detail) != nil {
                    return true
                }
            }
        }
        return false
    }

    /// Applies Force-Secret classification to an `AskPrompt`, overriding `secret: false -> true`
    /// whenever any field key, label, placeholder, default, or prompt text triggers secret detection.
    public static func classify(prompt: AskPrompt, extraPromptTexts: [String] = []) -> AskPrompt {
        var out = prompt

        var formReason: String?
        if containsSecretURLCredential(normalizeForDetection(prompt.site)) {
            formReason = "secret_url"
        }
        if formReason == nil {
            let formTexts = [prompt.title, prompt.reason] + extraPromptTexts
            for text in formTexts {
                if let signal = detectSecretSignal(in: text) {
                    formReason = signal
                    break
                }
            }
        }

        // Redact any embedded URL credentials in prompt metadata so Vault item metadata stays credential-free.
        out.site = redactURLCredentials(in: prompt.site)
        if containsSecretURLCredential(normalizeForDetection(prompt.title)) {
            out.title = redactURLCredentials(in: prompt.title)
        }
        if containsSecretURLCredential(normalizeForDetection(prompt.reason)) {
            out.reason = redactURLCredentials(in: prompt.reason)
        }

        var questions = prompt.questions
        for index in questions.indices {
            var q = questions[index]
            var signal: String?
            if q.requestedSecret || q.secret {
                signal = q.secretReason ?? "requested_secret"
            }

            let isClosedPresetPicker = !q.requestedSecret && q.kind != .text && !q.options.isEmpty && !q.allowCustom
            if signal == nil, isClosedPresetPicker {
                // Closed option pickers (e.g. `auth: ["OAuth", "API Key"]` or `["密码", "钥匙"]`) stay non-secret
                // unless an option or default carries an actual credential payload.
                for option in q.options {
                    if containsActualCredentialPayload(in: option.value)
                        || containsActualCredentialPayload(in: option.label)
                        || containsActualCredentialPayload(in: option.detail) {
                        signal = "option_credential_payload"
                        break
                    }
                }
                if signal == nil, containsActualCredentialPayload(in: q.defaultValue) {
                    signal = "default_credential_payload"
                }
                if signal == nil {
                    for def in q.defaultSelections where containsActualCredentialPayload(in: def) {
                        signal = "default_credential_payload"
                        break
                    }
                }
            } else if signal == nil {
                if signal == nil { signal = detectSecretSignal(in: q.key) }
                if signal == nil { signal = detectSecretSignal(in: q.label) }
                if signal == nil { signal = detectSecretSignal(in: q.placeholder) }
                if signal == nil { signal = detectSecretSignal(in: q.defaultValue) }
                if signal == nil {
                    for def in q.defaultSelections {
                        if let s = detectSecretSignal(in: def) {
                            signal = s
                            break
                        }
                    }
                }
                if signal == nil, q.allowCustom {
                    for option in q.options {
                        if let s = detectSecretSignal(in: option.label) ?? detectSecretSignal(in: option.detail) {
                            signal = s
                            break
                        }
                    }
                }
            }

            if let signal {
                q.secret = true
                q.secretReason = signal
            }
            questions[index] = q
        }

        let anyFieldSecret = questions.contains(where: \.secret)
        if formReason != nil || anyFieldSecret {
            let fallbackReason = formReason.map { "form_\($0)" } ?? "mixed_secret_form"
            for index in questions.indices where !questions[index].secret {
                let q = questions[index]
                let isClosedNonSecretChoice = q.kind != .text && !q.options.isEmpty && !q.allowCustom
                if !isClosedNonSecretChoice && !isExplicitHarmlessIdentityField(q) {
                    questions[index].secret = true
                    questions[index].secretReason = fallbackReason
                }
            }
        }

        // Security invariant: forced-secret fields must NEVER render as plaintext choices or plaintext custom inputs.
        for index in questions.indices where questions[index].secret {
            questions[index].kind = .text
            questions[index].options = []
            questions[index].allowCustom = false
            questions[index].minSelections = nil
            questions[index].maxSelections = nil
            questions[index].defaultValue = ""
            questions[index].defaultSelections = []
        }

        let finalVault = formReason != nil || questions.contains(where: \.secret)
        out.questions = questions
        out.requiresVault = finalVault
        out.secretReason = formReason ?? questions.first(where: \.secret)?.secretReason
        return out
    }

    // MARK: - Parsing

    /// Parses and classifies `ask_user` JSON arguments, returning a validated `AskPrompt` or a clean error.
    public static func parse(_ arguments: JSONValue) -> Result<AskPrompt, AskValidationError> {
        guard case .object(let map) = arguments else {
            return .failure(.invalidArguments("ask_user 参数必须是 JSON 对象。"))
        }

        let rawTitle = sanitizeSingleLine(map["title"]?.string ?? "", maxLength: maxTitleLength)
        let rawReason = sanitizeMultiline(map["reason"]?.string ?? map["description"]?.string ?? "", maxLength: maxReasonLength)
        let rawSite = sanitizeSingleLine(map["site"]?.string ?? "", maxLength: maxOptionLength)
        let rawQuestion = sanitizeSingleLine(map["question"]?.string ?? "", maxLength: maxTitleLength)
        let rawPrompt = sanitizeSingleLine(map["prompt"]?.string ?? "", maxLength: maxTitleLength)

        var parsedQuestions: [AskQuestion] = []

        if let fieldsValue = map["fields"], fieldsValue != .null {
            guard case .array(let items) = fieldsValue else {
                return .failure(.invalidArguments("fields 必须是数组。"))
            }
            if items.isEmpty {
                return .failure(.emptyFields)
            }
            if items.count > maxQuestionsCount {
                return .failure(.tooManyQuestions(maxQuestionsCount))
            }
            var seenKeys: Set<String> = []
            for item in items {
                switch parseQuestionObject(item, fallbackKey: nil, fallbackLabel: nil) {
                case .failure(let err):
                    return .failure(err)
                case .success(let q):
                    guard seenKeys.insert(q.key).inserted else {
                        return .failure(.duplicateKey(q.key))
                    }
                    parsedQuestions.append(q)
                }
            }
        } else {
            let hasShorthand = !rawQuestion.isEmpty
                || !rawPrompt.isEmpty
                || map["options"] != nil
                || map["choices"] != nil
                || (!rawTitle.isEmpty && (map["type"] != nil || map["mode"] != nil || map["multi"] != nil || map["placeholder"] != nil || map["secret"] != nil))
            guard hasShorthand else {
                return .failure(.emptyFields)
            }
            let topLabel = !rawQuestion.isEmpty ? rawQuestion : (!rawPrompt.isEmpty ? rawPrompt : rawTitle)
            switch parseQuestionObject(arguments, fallbackKey: "answer", fallbackLabel: topLabel) {
            case .failure(let err):
                return .failure(err)
            case .success(let q):
                parsedQuestions.append(q)
            }
        }

        let effectiveTitle: String
        if !rawTitle.isEmpty {
            effectiveTitle = rawTitle
        } else if !rawQuestion.isEmpty {
            effectiveTitle = rawQuestion
        } else if !rawPrompt.isEmpty {
            effectiveTitle = rawPrompt
        } else {
            effectiveTitle = "请填一下"
        }

        let draft = AskPrompt(
            title: effectiveTitle,
            reason: rawReason,
            site: rawSite,
            questions: parsedQuestions
        )
        let classified = classify(prompt: draft, extraPromptTexts: [rawQuestion, rawPrompt])
        return .success(classified)
    }

    private static func parseQuestionObject(
        _ item: JSONValue,
        fallbackKey: String?,
        fallbackLabel: String?
    ) -> Result<AskQuestion, AskValidationError> {
        guard case .object(let map) = item else {
            return .failure(.invalidField("fields 里的每一项都必须是对象。"))
        }

        let rawKey: String
        if let explicitKey = map["key"]?.string {
            rawKey = sanitizeSingleLine(explicitKey, maxLength: maxFieldKeyLength)
        } else if let fallbackKey {
            rawKey = fallbackKey
        } else {
            rawKey = ""
        }
        guard !rawKey.isEmpty else {
            return .failure(.invalidField("fields 里每一项都需要非空的 key。"))
        }

        let candidateLabel = sanitizeSingleLine(
            map["label"]?.string ?? map["question"]?.string ?? map["prompt"]?.string ?? fallbackLabel ?? rawKey,
            maxLength: maxLabelLength
        )
        let label = candidateLabel.isEmpty ? rawKey : candidateLabel

        let optionsValue = (map["options"] != nil && map["options"] != .null) ? map["options"] : map["choices"]
        var options: [AskOption] = []
        if let optionsValue, optionsValue != .null {
            switch parseOptions(optionsValue, key: rawKey) {
            case .failure(let err): return .failure(err)
            case .success(let list): options = list
            }
        }

        let explicitTypeRaw = firstNonNull(map["type"], map["mode"], map["kind"])?.string?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let multiFlag = parseBool(map["multi"])
        let kind: AskFieldKind
        if let explicitTypeRaw, !explicitTypeRaw.isEmpty {
            switch explicitTypeRaw {
            case "single", "single_select", "radio":
                kind = .single
            case "multi", "multi_select", "multiple", "checkbox":
                kind = .multi
            case "text", "input", "free_text":
                kind = .text
            default:
                return .failure(.invalidField("「\(rawKey)」不支持的题型：\(explicitTypeRaw)"))
            }
        } else if multiFlag == true {
            kind = .multi
        } else if !options.isEmpty {
            kind = .single
        } else {
            kind = .text
        }

        let allowCustom = parseBool(firstNonNull(map["allowCustom"], map["allow_custom"], map["custom"])) ?? false

        if (kind == .single || kind == .multi), options.isEmpty, !allowCustom {
            return .failure(.emptyOptions(rawKey))
        }

        let minParsed: Int?
        switch parseExactInt(firstNonNull(map["minSelections"], map["min_selections"], map["min"])) {
        case .failure(let err): return .failure(err)
        case .success(let val): minParsed = val
        }

        let maxParsed: Int?
        switch parseExactInt(firstNonNull(map["maxSelections"], map["max_selections"], map["max"])) {
        case .failure(let err): return .failure(err)
        case .success(let val): maxParsed = val
        }

        if let min = minParsed, min < 0 {
            return .failure(.invalidBounds("最少选择数不能小于 0。"))
        }
        if let max = maxParsed, max < 1 {
            return .failure(.invalidBounds("最多选择数至少为 1。"))
        }
        if let min = minParsed, let max = maxParsed, min > max {
            return .failure(.invalidBounds("最少选择数不能大于最多选择数。"))
        }

        let availableChoices = options.count + (allowCustom ? 1 : 0)
        if kind == .single {
            if let min = minParsed, min > 1 {
                return .failure(.invalidBounds("单选题最少选择数不能大于 1。"))
            }
            if let max = maxParsed, max != 1 {
                return .failure(.invalidBounds("单选题最多只能选 1 项。"))
            }
        } else if kind == .multi {
            if let min = minParsed, min > availableChoices {
                return .failure(.invalidBounds("「\(rawKey)」最少选择数超过了可选项数量。"))
            }
        }

        let optionalFlag = parseBool(map["optional"])
        let requiredFlag = parseBool(map["required"])
        let isFromFieldsArray = fallbackKey == nil
        let v2SchemaKeys = [
            "type", "mode", "kind", "options",
            "allowCustom", "allow_custom", "custom",
            "minSelections", "min_selections", "min",
            "maxSelections", "max_selections", "max",
            "multi",
        ]
        let hasModernV2Keys = v2SchemaKeys.contains { key in
            if let v = map[key], v != .null { return true }
            return false
        }

        let required: Bool
        let explicitlyOptional: Bool
        if let requiredFlag {
            required = requiredFlag
            explicitlyOptional = !requiredFlag
        } else if let optionalFlag {
            required = !optionalFlag
            explicitlyOptional = optionalFlag
        } else if isFromFieldsArray && !hasModernV2Keys && kind == .text {
            // Legacy `fields` plain-text entries (without v2 keys or explicit required/optional) remain optional.
            required = false
            explicitlyOptional = false
        } else if kind != .text, minParsed == 0 {
            required = false
            explicitlyOptional = true
        } else {
            required = true
            explicitlyOptional = false
        }

        let placeholder = sanitizeSingleLine(map["placeholder"]?.string ?? "", maxLength: maxPlaceholderLength)
        let requestedSecret = parseBool(map["secret"]) ?? false

        var defaultValue = ""
        var defaultSelections: [String] = []
        let rawDefault = firstNonNull(map["value"], map["default"], map["defaultValue"])
        if kind == .multi {
            if case .array(let arr) = rawDefault {
                let validValues = Set(options.map(\.value))
                var seen: Set<String> = []
                for item in arr {
                    if let s = item.string {
                        let clean = sanitizeSingleLine(s, maxLength: maxOptionLength)
                        if validValues.contains(clean), seen.insert(clean).inserted {
                            defaultSelections.append(clean)
                        }
                    }
                }
            } else if let str = rawDefault?.string {
                let clean = sanitizeSingleLine(str, maxLength: maxOptionLength)
                if options.contains(where: { $0.value == clean }) {
                    defaultSelections = [clean]
                }
            }
            if let maxParsed, defaultSelections.count > maxParsed {
                defaultSelections = Array(defaultSelections.prefix(maxParsed))
            }
        } else if kind == .single {
            if let str = rawDefault?.string {
                let clean = sanitizeSingleLine(str, maxLength: maxOptionLength)
                if !clean.isEmpty, options.contains(where: { $0.value == clean }) || allowCustom {
                    defaultValue = clean
                }
            }
        } else {
            if let str = rawDefault?.string {
                defaultValue = sanitizeMultiline(str, maxLength: maxCustomTextLength)
            }
        }

        return .success(AskQuestion(
            key: rawKey,
            label: label,
            kind: kind,
            options: options,
            allowCustom: kind == .text ? false : allowCustom,
            minSelections: minParsed,
            maxSelections: maxParsed,
            placeholder: placeholder,
            defaultValue: defaultValue,
            defaultSelections: defaultSelections,
            required: required,
            explicitlyOptional: explicitlyOptional,
            secret: requestedSecret,
            requestedSecret: requestedSecret
        ))
    }

    private static func parseOptions(_ value: JSONValue, key: String) -> Result<[AskOption], AskValidationError> {
        guard case .array(let items) = value else {
            return .failure(.invalidField("「\(key)」的 options 必须是数组。"))
        }
        var out: [AskOption] = []
        var indexByValue: [String: Int] = [:]

        for item in items {
            let parsed: AskOption?
            switch item {
            case .string(let s):
                let clean = sanitizeSingleLine(s, maxLength: maxOptionLength)
                parsed = clean.isEmpty ? nil : AskOption(value: clean)
            case .number(let n):
                let str = JSONValue.whole(n).map(String.init) ?? String(n)
                parsed = AskOption(value: str)
            case .object(let map):
                let rawVal = map["value"]?.string ?? map["id"]?.string ?? map["label"]?.string ?? map["title"]?.string ?? map["name"]?.string ?? ""
                let rawLab = map["label"]?.string ?? map["title"]?.string ?? map["name"]?.string ?? map["value"]?.string ?? map["id"]?.string ?? ""
                let cleanVal = sanitizeSingleLine(rawVal, maxLength: maxOptionLength)
                let cleanLab = sanitizeSingleLine(rawLab, maxLength: maxOptionLength)
                let cleanDetail = sanitizeSingleLine(map["description"]?.string ?? map["detail"]?.string ?? map["hint"]?.string ?? map["note"]?.string ?? "", maxLength: maxOptionDetailLength)
                let rec = parseBool(map["recommended"]) ?? false
                if cleanVal.isEmpty && cleanLab.isEmpty {
                    parsed = nil
                } else {
                    let finalVal = cleanVal.isEmpty ? cleanLab : cleanVal
                    let finalLab = cleanLab.isEmpty ? finalVal : cleanLab
                    parsed = AskOption(value: finalVal, label: finalLab, detail: cleanDetail, recommended: rec)
                }
            default:
                return .failure(.invalidField("「\(key)」的选项格式不对。"))
            }

            guard let option = parsed else { continue }
            if let existingIndex = indexByValue[option.value] {
                if option.recommended && !out[existingIndex].recommended {
                    out[existingIndex].recommended = true
                }
                if out[existingIndex].detail.isEmpty && !option.detail.isEmpty {
                    out[existingIndex].detail = option.detail
                }
            } else {
                if out.count >= maxOptionsCount {
                    return .failure(.tooManyOptions(key, maxOptionsCount))
                }
                indexByValue[option.value] = out.count
                out.append(option)
            }
        }
        return .success(out)
    }

    // MARK: - Response Encoding, Validation, Formatting

    /// Encodes an `AskResponse` into `[String: String]` dictionary transport for `Asker.Answer`.
    public static func encodeResponse(_ response: AskResponse, for question: AskQuestion) -> String {
        switch question.kind {
        case .text:
            return response.customText ?? ""
        case .single:
            if let first = response.selected.first, !first.isEmpty {
                return first
            }
            return response.customText ?? ""
        case .multi:
            let cleanSelected = deduplicated(response.selected.map { sanitizeSingleLine($0, maxLength: maxOptionLength) }.filter { !$0.isEmpty })
            let cleanCustom = sanitizeMultiline(response.customText ?? "", maxLength: maxCustomTextLength)
            if cleanSelected.isEmpty && cleanCustom.isEmpty { return "" }
            let payload = EncodedMultiResponse(
                _clioAsk: 1,
                selected: cleanSelected,
                custom: cleanCustom.isEmpty ? nil : cleanCustom
            )
            if let data = try? JSONEncoder().encode(payload) {
                return String(decoding: data, as: UTF8.self)
            }
            return ""
        }
    }

    /// Decodes a raw `[String: String]` entry back into `AskResponse`.
    public static func decodeResponse(from raw: String, for question: AskQuestion) -> AskResponse {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return AskResponse() }

        if question.secret || question.kind == .text {
            return AskResponse(selected: [], customText: raw)
        }

        if question.kind == .single {
            if question.options.contains(where: { $0.value == trimmed }) {
                return AskResponse(selected: [trimmed], customText: nil)
            }
            return AskResponse(selected: [], customText: trimmed)
        }

        if let data = trimmed.data(using: .utf8),
           let payload = try? JSONDecoder().decode(EncodedMultiResponse.self, from: data),
           payload._clioAsk == 1 {
            return AskResponse(selected: payload.selected, customText: payload.custom)
        }
        if case .array(let items)? = JSONValue.parse(trimmed) {
            return AskResponse(selected: items.compactMap(\.string), customText: nil)
        }
        if question.options.contains(where: { $0.value == trimmed }) {
            return AskResponse(selected: [trimmed], customText: nil)
        }
        return AskResponse(selected: [], customText: trimmed)
    }

    /// Validates and normalizes one `AskResponse` against its `AskQuestion`.
    public static func validate(response: AskResponse, for question: AskQuestion, enforceRequired: Bool = true) -> Result<AskResponse, AskValidationError> {
        if question.secret {
            let trimmed = (response.customText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                if enforceRequired && question.required {
                    return .failure(.emptySelection(question.key))
                }
                return .success(AskResponse())
            }
            return .success(AskResponse(selected: [], customText: trimmed))
        }

        var cleanedSelected: [String] = []
        var seen: Set<String> = []
        for item in response.selected {
            let clean = sanitizeSingleLine(item, maxLength: maxOptionLength + 1)
            if !clean.isEmpty, seen.insert(clean).inserted {
                cleanedSelected.append(clean)
            }
        }

        let rawCustom = stripScalars(response.customText ?? "", allowNewlines: question.kind == .text || question.allowCustom, stripZeroWidth: false)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if rawCustom.count > maxCustomTextLength {
            return .failure(.textTooLong(question.key, maxCustomTextLength))
        }
        var cleanedCustom: String? = rawCustom.isEmpty ? nil : rawCustom

        let validOptionSet = Set(question.options.map(\.value))

        switch question.kind {
        case .text:
            if !cleanedSelected.isEmpty {
                return .failure(.invalidSelectionCount(question.key))
            }
            if cleanedCustom == nil, enforceRequired && question.required {
                return .failure(.emptySelection(question.key))
            }
            return .success(AskResponse(selected: [], customText: cleanedCustom))

        case .single:
            if let custom = cleanedCustom {
                guard question.allowCustom else {
                    return .failure(.customNotAllowed(question.key))
                }
                guard cleanedSelected.isEmpty else {
                    return .failure(.invalidSelectionCount(question.key))
                }
                if validOptionSet.contains(custom) {
                    return .success(AskResponse(selected: [custom], customText: nil))
                }
                return .success(AskResponse(selected: [], customText: custom))
            }

            if cleanedSelected.count > 1 {
                return .failure(.invalidSelectionCount(question.key))
            }
            if let picked = cleanedSelected.first {
                if validOptionSet.contains(picked) {
                    return .success(AskResponse(selected: [picked], customText: nil))
                }
                if question.allowCustom {
                    if picked.count > maxCustomTextLength {
                        return .failure(.textTooLong(question.key, maxCustomTextLength))
                    }
                    return .success(AskResponse(selected: [], customText: picked))
                }
                return .failure(.invalidOption(question.key, picked))
            }

            let minSel = question.effectiveMinSelections
            if enforceRequired && minSel > 0 {
                return .failure(.emptySelection(question.key))
            }
            return .success(AskResponse())

        case .multi:
            for item in cleanedSelected where !validOptionSet.contains(item) {
                return .failure(.invalidOption(question.key, item))
            }
            if let custom = cleanedCustom {
                guard question.allowCustom else {
                    return .failure(.customNotAllowed(question.key))
                }
                if validOptionSet.contains(custom) {
                    if seen.insert(custom).inserted {
                        cleanedSelected.append(custom)
                    }
                    cleanedCustom = nil
                }
            }

            let totalCount = cleanedSelected.count + (cleanedCustom != nil ? 1 : 0)
            let minRequiredOverall = question.effectiveMinSelections
            let minWhenAnswered = question.answeredMinSelections
            if enforceRequired {
                if totalCount == 0 {
                    if minRequiredOverall > 0 {
                        return .failure(.emptySelection(question.key))
                    }
                } else if totalCount < minWhenAnswered {
                    return .failure(.tooFewSelections(question.key, minWhenAnswered))
                }
            }
            if let maxSel = question.maxSelections, totalCount > maxSel {
                return .failure(.tooManySelections(question.key, maxSel))
            }
            return .success(AskResponse(selected: cleanedSelected, customText: cleanedCustom))
        }
    }

    /// Validates all fields of an `AskPrompt` against a `[String: String]` answer map.
    public static func validateSubmission(
        _ rawValues: [String: String],
        for prompt: AskPrompt,
        enforceRequired: Bool = true
    ) -> Result<[String: AskResponse], AskValidationError> {
        var validated: [String: AskResponse] = [:]
        for question in prompt.questions {
            let decoded = decodeResponse(from: rawValues[question.key] ?? "", for: question)
            switch validate(response: decoded, for: question, enforceRequired: enforceRequired) {
            case .failure(let err):
                return .failure(err)
            case .success(let ok):
                validated[question.key] = ok
            }
        }
        return .success(validated)
    }

    /// Formats validated answers into tool output text for the model.
    /// Secrets are NEVER echoed: only `"secret:<id>"` Keychain IDs or `"（已填）"`/`"（没填）"` are emitted.
    public static func formatResult(prompt: AskPrompt, rawValues: [String: String]) -> Result<String, AskValidationError> {
        switch validateSubmission(rawValues, for: prompt, enforceRequired: true) {
        case .failure(let err):
            return .failure(err)
        case .success(let validated):
            let lines = prompt.questions.map { question -> String in
                let response = validated[question.key] ?? AskResponse()
                if question.secret {
                    let raw = (rawValues[question.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if raw.hasPrefix("secret:") {
                        let id = String(raw.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !id.isEmpty {
                            return "\(question.key)：已存进信匣，编号 \(id)（你看不到内容）"
                        }
                    }
                    return raw.isEmpty ? "\(question.key)：（没填）" : "\(question.key)：（已填）"
                }

                switch question.kind {
                case .text:
                    if let text = response.customText, !text.isEmpty {
                        return "\(question.key)：\(text)"
                    }
                    return "\(question.key)：（没填）"
                case .single:
                    if let chosen = response.selected.first {
                        return "\(question.key)：\(chosen)"
                    }
                    if let custom = response.customText, !custom.isEmpty {
                        return "\(question.key)：（自定义）\(custom)"
                    }
                    return "\(question.key)：（未选择）"
                case .multi:
                    let selectedJSON = JSONValue.array(response.selected.map { .string($0) }).compact
                    if !response.selected.isEmpty, let custom = response.customText, !custom.isEmpty {
                        return "\(question.key)：\(selectedJSON)，自定义：\(custom)"
                    }
                    if !response.selected.isEmpty {
                        return "\(question.key)：\(selectedJSON)"
                    }
                    if let custom = response.customText, !custom.isEmpty {
                        return "\(question.key)：（自定义）\(custom)"
                    }
                    return "\(question.key)：（未选择）"
                }
            }
            return .success("用户填好了：\n" + lines.joined(separator: "\n"))
        }
    }

    // MARK: - Helpers

    private static func normalizeForDetection(_ raw: String) -> String {
        let stripped = stripScalars(raw, allowNewlines: true, stripZeroWidth: true)
        return stripped.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? stripped
    }

    private static func stripScalars(_ text: String, allowNewlines: Bool, stripZeroWidth: Bool) -> String {
        var out = String.UnicodeScalarView()
        out.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            if stripZeroWidth && zeroWidthScalars.contains(scalar) { continue }
            if scalar.value < 0x20 || scalar.value == 0x7F {
                if allowNewlines {
                    if scalar == "\n" || scalar == "\t" {
                        out.append(scalar)
                    }
                } else if scalar == "\r" || scalar == "\n" || scalar == "\t" {
                    out.append(" ")
                }
                continue
            }
            out.append(scalar)
        }
        return String(out)
    }

    private static func sanitizeSingleLine(_ raw: String, maxLength: Int) -> String {
        let stripped = stripScalars(raw, allowNewlines: false, stripZeroWidth: false)
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= maxLength { return trimmed }
        return String(trimmed.prefix(maxLength))
    }

    private static func sanitizeMultiline(_ raw: String, maxLength: Int) -> String {
        let stripped = stripScalars(raw, allowNewlines: true, stripZeroWidth: false)
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= maxLength { return trimmed }
        return String(trimmed.prefix(maxLength))
    }

    private static func isExplicitHarmlessIdentityField(_ question: AskQuestion) -> Bool {
        guard question.kind == .text, !question.allowCustom else { return false }
        let cleanKey = normalizeForDetection(question.key).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.unicodeScalars.contains(where: { !$0.isASCII && CharacterSet.letters.contains($0) }) else {
            return false
        }
        let keyTokens = englishTokens(from: cleanKey).map(stripTrailingDigits)
        guard !keyTokens.isEmpty, keyTokens.allSatisfy({ harmlessIdentityKeys.contains($0) }) else {
            return false
        }
        let cleanLabel = normalizeForDetection(question.label).trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanLabel.isEmpty { return true }
        if harmlessIdentityChineseLabels.contains(cleanLabel) { return true }
        guard !cleanLabel.unicodeScalars.contains(where: { !$0.isASCII && CharacterSet.letters.contains($0) }) else {
            return false
        }
        let labelTokens = englishTokens(from: cleanLabel).map(stripTrailingDigits)
        if !labelTokens.isEmpty && labelTokens.allSatisfy({ harmlessIdentityKeys.contains($0) }) {
            return true
        }
        return false
    }

    private static func firstNonNull(_ values: JSONValue?...) -> JSONValue? {
        for value in values {
            if let value, value != .null { return value }
        }
        return nil
    }

    private static func deduplicated(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for item in values where seen.insert(item).inserted {
            result.append(item)
        }
        return result
    }

    private static func parseBool(_ value: JSONValue?) -> Bool? {
        guard let value, value != .null else { return nil }
        switch value {
        case .bool(let b): return b
        case .string(let s):
            let clean = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if clean == "true" { return true }
            if clean == "false" { return false }
            return nil
        default: return nil
        }
    }

    private static func parseExactInt(_ value: JSONValue?) -> Result<Int?, AskValidationError> {
        guard let value, value != .null else { return .success(nil) }
        switch value {
        case .number(let n):
            guard let whole = JSONValue.whole(n) else {
                return .failure(.invalidBounds("选择数量限制必须是整数。"))
            }
            return .success(whole)
        case .string(let s):
            let clean = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsed = Int(clean) else {
                return .failure(.invalidBounds("选择数量限制必须是整数。"))
            }
            return .success(parsed)
        default:
            return .failure(.invalidBounds("选择数量限制必须是整数。"))
        }
    }

    public static func containsSecretURLCredential(_ text: String) -> Bool {
        let lower = text.lowercased()
        var searchStart = lower.startIndex
        while let schemeRange = lower.range(of: "://", range: searchStart..<lower.endIndex) {
            let afterScheme = lower[schemeRange.upperBound...]
            let authorityEnd = afterScheme.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" || $0.isWhitespace }) ?? afterScheme.endIndex
            let authority = afterScheme[..<authorityEnd]
            if let atIndex = authority.lastIndex(of: "@") {
                let userinfo = authority[..<atIndex]
                if let colonIndex = userinfo.firstIndex(of: ":") {
                    let passPart = userinfo[userinfo.index(after: colonIndex)...]
                    if !passPart.isEmpty {
                        return true
                    }
                }
            }
            searchStart = schemeRange.upperBound
        }
        return false
    }

    private static func containsPEMHeader(_ lower: String) -> Bool {
        guard lower.contains("-----begin") else { return false }
        return lower.contains("private key")
            || lower.contains("rsa ")
            || lower.contains("ec ")
            || lower.contains("openssh")
            || lower.contains("pgp ")
    }

    private static func containsTokenPrefix(_ original: String, lower: String) -> Bool {
        let bytes = Array(lower.utf8)
        let origBytes = Array(original.utf8)

        func isBoundaryBefore(_ index: Int) -> Bool {
            if index == 0 { return true }
            let b = bytes[index - 1]
            let isAlnum = (b >= 48 && b <= 57) || (b >= 97 && b <= 122)
            return !isAlnum
        }

        for prefix in secretTokenPrefixes {
            var searchStart = lower.startIndex
            while let range = lower.range(of: prefix, range: searchStart..<lower.endIndex) {
                let offset = lower.distance(from: lower.startIndex, to: range.lowerBound)
                if isBoundaryBefore(offset) {
                    return true
                }
                searchStart = range.upperBound
            }
        }

        // Case-sensitive AWS/Google key prefixes to avoid matching benign words.
        for sensitivePrefix in ["AKIA", "ASIA", "AIza"] {
            var searchStart = original.startIndex
            while let range = original.range(of: sensitivePrefix, range: searchStart..<original.endIndex) {
                let offset = original.distance(from: original.startIndex, to: range.lowerBound)
                let beforeOK = offset == 0 || !isASCIIAlnum(origBytes[offset - 1])
                if beforeOK { return true }
                searchStart = range.upperBound
            }
        }
        return false
    }

    private static func isASCIIAlnum(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
    }

    /// Splits ASCII alphanumeric segments on delimiters and camelCase boundaries, returning lowercased tokens.
    static func englishTokens(from text: String) -> [String] {
        var rawRuns: [String] = []
        var current = ""
        for scalar in text.unicodeScalars {
            if (scalar.value >= 48 && scalar.value <= 57)
                || (scalar.value >= 65 && scalar.value <= 90)
                || (scalar.value >= 97 && scalar.value <= 122) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                rawRuns.append(current)
                current = ""
            }
        }
        if !current.isEmpty { rawRuns.append(current) }

        var tokens: [String] = []
        for run in rawRuns {
            let chars = Array(run)
            var part = ""
            for index in chars.indices {
                let ch = chars[index]
                if !part.isEmpty {
                    let prev = chars[index - 1]
                    let next: Character? = index + 1 < chars.count ? chars[index + 1] : nil
                    let prevLower = prev.isASCII && prev.isLowercase
                    let prevUpper = prev.isASCII && prev.isUppercase
                    let currUpper = ch.isASCII && ch.isUppercase
                    let nextLower = next.map { $0.isASCII && $0.isLowercase } ?? false
                    if (prevLower && currUpper) || (prevUpper && currUpper && nextLower) {
                        tokens.append(part.lowercased())
                        part = ""
                    }
                }
                part.append(ch)
            }
            if !part.isEmpty { tokens.append(part.lowercased()) }
        }
        return tokens
    }

    private static func stripTrailingDigits(_ token: String) -> String {
        guard token.contains(where: { $0.isLetter }) else { return token }
        var end = token.endIndex
        while end > token.startIndex {
            let prev = token.index(before: end)
            if token[prev].isASCII && token[prev].isNumber {
                end = prev
            } else {
                break
            }
        }
        return end == token.startIndex ? token : String(token[..<end])
    }

    private static func hasUnsafeKeyToken(_ bases: [String]) -> Bool {
        guard bases.contains(where: { $0 == "key" || $0 == "keys" }) else { return false }
        if bases.contains(where: { unsafeKeyCompanions.contains($0) }) { return true }

        var masked = Array(repeating: false, count: bases.count)
        for index in bases.indices where bases[index] == "key" || bases[index] == "keys" {
            if index > 0 && safeKeyPreceding.contains(bases[index - 1]) {
                masked[index] = true
                continue
            }
            if index + 1 < bases.count && safeKeyFollowing.contains(bases[index + 1]) {
                masked[index] = true
                continue
            }
        }
        for index in bases.indices where (bases[index] == "key" || bases[index] == "keys") && !masked[index] {
            return true
        }
        return false
    }

    private static func hasUnsafePinToken(_ bases: [String]) -> Bool {
        guard bases.contains("pin") else { return false }
        if bases.contains(where: { secretPinCompanions.contains($0) }) { return true }

        var masked = Array(repeating: false, count: bases.count)
        for index in bases.indices where bases[index] == "pin" {
            if index > 0 && safePinPreceding.contains(bases[index - 1]) {
                masked[index] = true
                continue
            }
            if index + 1 < bases.count && safePinFollowing.contains(bases[index + 1]) {
                masked[index] = true
                continue
            }
        }
        for index in bases.indices where bases[index] == "pin" && !masked[index] {
            return true
        }
        return false
    }
}
