import Craft
import Foundation
import SwiftUI
import UIKit

/// Settings and OpenAI-compatible `/audio/transcriptions` client for optional cloud speech-to-text.
enum VoiceTranscription {
    enum Mode: String, CaseIterable, Identifiable, Sendable {
        case system
        case cloud

        var id: String { rawValue }

        var title: String {
            switch self {
            case .system: "系统自带听写"
            case .cloud: "云端模型转写"
            }
        }

        var subtitle: String {
            switch self {
            case .system: "苹果系统听写，实时出字、免配置（是否设备端离线处理由系统决定）"
            case .cloud: "录完发给 Whisper / SenseVoice 等接口，中英混说专有名词更准"
            }
        }
    }

    struct Preset: Identifiable {
        let id: String
        let name: String
        let baseURL: String
        let model: String
    }

    static let presets: [Preset] = [
        Preset(id: "groq", name: "Groq", baseURL: "https://api.groq.com/openai/v1", model: "whisper-large-v3-turbo"),
        Preset(id: "siliconflow", name: "硅基流动", baseURL: "https://api.siliconflow.cn/v1", model: "FunAudioLLM/SenseVoiceSmall"),
        Preset(id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini-transcribe"),
    ]

    static let modeKey = "voice.mode"
    static let baseURLKey = "voice.baseURL"
    static let modelKey = "voice.model"
    static let languageKey = "voice.language"

    nonisolated static var mode: Mode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: modeKey),
                  let parsed = Mode(rawValue: raw) else { return .system }
            return parsed
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: modeKey) }
    }

    nonisolated static var baseURL: String {
        get { UserDefaults.standard.string(forKey: baseURLKey) ?? "" }
        set {
            // Never persist URLs carrying embedded user:pass@ credentials into plain UserDefaults.
            guard !VoiceEndpoint.containsEmbeddedCredentials(newValue) else { return }
            UserDefaults.standard.set(newValue, forKey: baseURLKey)
        }
    }

    nonisolated static var model: String {
        get { UserDefaults.standard.string(forKey: modelKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: modelKey) }
    }

    nonisolated static var language: String {
        get { UserDefaults.standard.string(forKey: languageKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: languageKey) }
    }

    /// Isolates Keychain API keys per normalized endpoint origin (`scheme://host:port`) so switching services never reuses another service's key.
    nonisolated static func vaultKey(for endpoint: URL) -> String? {
        guard let origin = VoiceEndpoint.originKey(for: endpoint) else { return nil }
        return "voice-stt-key-\(origin)"
    }

    static func readKey(for endpoint: URL) async -> String {
        guard let slot = vaultKey(for: endpoint) else { return "" }
        return (await Vault.readString(slot) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func saveKey(_ value: String, for endpoint: URL) async {
        guard let slot = vaultKey(for: endpoint) else { return }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        await Task.detached(priority: .userInitiated) {
            if trimmed.isEmpty {
                Vault.remove(slot)
            } else {
                Vault.save(trimmed, as: slot)
            }
        }.value
    }

    nonisolated static func validateEndpoint(_ rawBase: String) -> Result<URL, VoiceEndpointError> {
        VoiceEndpoint.validate(rawBase)
    }

    static func mask(_ key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.count <= 8 { return String(repeating: "•", count: trimmed.count) }
        return "\(trimmed.prefix(4))••••\(trimmed.suffix(4))"
    }

    enum Problem: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self {
            case .message(let text): return text
            }
        }
    }

    /// Rejects cross-origin redirects and protocol downgrades so audio and Bearer credentials never leave the configured origin.
    private final class SameOriginRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let origin: URL
        init(origin: URL) { self.origin = origin }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest
        ) async -> URLRequest? {
            guard let next = request.url, VoiceEndpoint.allowsRedirect(from: origin, to: next) else {
                return nil
            }
            return request
        }
    }

    /// Uploads a recorded `.m4a` file to an OpenAI-compatible `/audio/transcriptions` endpoint.
    nonisolated static func transcribe(fileURL: URL, endpoint: URL, apiKey: String, model: String, language: String) async throws -> String {
        guard VoiceEndpoint.allowsTransport(endpoint) else {
            throw VoiceEndpointError.requiresHTTPS
        }

        let audioData = try Data(contentsOf: fileURL)
        guard !audioData.isEmpty else {
            throw Problem.message("没有录到声音，请再说一次。")
        }
        guard audioData.count <= 24 << 20 else {
            throw Problem.message("录音太长了（超过 24 MB），请分段说。")
        }

        let boundary = "ClioVoice-\(UUID().uuidString)"
        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }
        appendField("model", model)
        appendField("response_format", "json")
        let cleanLang = language.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanLang.isEmpty {
            appendField("language", cleanLang)
        }
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"voice.m4a\"\r\n".utf8))
        body.append(Data("Content-Type: audio/mp4\r\n\r\n".utf8))
        body.append(audioData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: endpoint, timeoutInterval: 35)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 35
        config.timeoutIntervalForResource = 60
        let session = URLSession(configuration: config, delegate: SameOriginRedirectGuard(origin: endpoint), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Problem.message("语音转写失败：服务器没有正常回应。")
        }
        if (300..<400).contains(http.statusCode) {
            throw Problem.message("语音转写接口试图跳转到其他主机或不安全地址，已中止。")
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw Problem.message("语音转写密钥无效或无权限（HTTP \(http.statusCode)）。")
            }
            if http.statusCode == 429 {
                throw Problem.message("语音转写请求过于频繁或额度用完（HTTP 429）。")
            }
            throw Problem.message("语音转写失败（HTTP \(http.statusCode)），请检查接口地址和模型名。")
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = json["text"] as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let plain = String(data: data, encoding: .utf8) {
            return plain.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        throw Problem.message("语音转写返回的内容无法解析。")
    }
}

/// Settings page for choosing between Apple system dictation and a standalone OpenAI-compatible STT endpoint.
struct VoiceSettingsPage: View {
    @AppStorage(VoiceTranscription.modeKey) private var modeRaw = VoiceTranscription.Mode.system.rawValue
    @AppStorage(VoiceTranscription.modelKey) private var model = ""
    @AppStorage(VoiceTranscription.languageKey) private var language = ""

    @State private var baseURLInput = VoiceTranscription.baseURL
    @State private var activeOriginKey: String? = nil
    @State private var originVersion = UUID()
    @State private var savedMasked = ""
    @State private var keyInput = ""
    @State private var keyNotice: String?

    private var mode: VoiceTranscription.Mode {
        VoiceTranscription.Mode(rawValue: modeRaw) ?? .system
    }

    private var validatedEndpoint: Result<URL, VoiceEndpointError> {
        VoiceTranscription.validateEndpoint(baseURLInput)
    }

    private var resolvedEndpoint: URL? {
        try? validatedEndpoint.get()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Ink.Space.xl) {
                modeSection
                if mode == .cloud {
                    presetSection
                    endpointSection
                    keySection
                    languageSection
                }
            }
            .padding(.horizontal, Ink.Space.page)
            .padding(.vertical, Ink.Space.l)
        }
        .background(Ink.paper.ignoresSafeArea())
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("语音输入与转写")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            syncOriginChange(for: baseURLInput, persist: false)
            await loadSavedKey()
        }
        .onChange(of: baseURLInput) { _, next in
            let changed = syncOriginChange(for: next, persist: true)
            if changed {
                Task { await loadSavedKey() }
            }
        }
    }

    // MARK: Mode

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle("识别方式")
            VStack(spacing: 0) {
                ForEach(Array(VoiceTranscription.Mode.allCases.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Kit.divider }
                    modeRow(item)
                }
            }
            .paperCard()
        }
    }

    private func modeRow(_ item: VoiceTranscription.Mode) -> some View {
        let active = item == mode
        return Button {
            Haptics.tick(0.5)
            modeRaw = item.rawValue
        } label: {
            HStack(spacing: Ink.Space.m) {
                IconBadge(symbol: item == .system ? "waveform" : "sparkles", tint: active ? Ink.Tile.mo : Ink.Tile.dai)
                VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
                    Text(item.title)
                        .font(.system(size: Ink.Size.body, weight: active ? .semibold : .regular))
                        .foregroundStyle(Ink.ink)
                    Text(item.subtitle)
                        .font(.system(size: Ink.Size.small))
                        .foregroundStyle(Ink.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Ink.Space.s)
                if active {
                    Image(systemName: "checkmark")
                        .font(.system(size: Ink.Size.sub, weight: .semibold))
                        .foregroundStyle(Ink.accent)
                }
            }
            .padding(.horizontal, Ink.Space.l)
            .padding(.vertical, Ink.Space.m)
            .frame(minHeight: Kit.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(haptic: false))
    }

    // MARK: Quick Presets

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle("常用服务快填")
            HStack(spacing: Ink.Space.s) {
                ForEach(VoiceTranscription.presets) { preset in
                    let picked = baseURLInput == preset.baseURL
                    Button {
                        Haptics.tick(0.4)
                        baseURLInput = preset.baseURL
                        model = preset.model
                    } label: {
                        Text(preset.name)
                            .font(.system(size: Ink.Size.small, weight: .medium))
                            .foregroundStyle(picked ? Ink.paper : Ink.ink)
                            .padding(.horizontal, Ink.Space.m)
                            .padding(.vertical, Ink.Space.s)
                            .background(picked ? Ink.accent : Ink.paperRaised, in: .capsule)
                    }
                    .buttonStyle(TapStyle())
                }
            }
        }
    }

    // MARK: Endpoint & Model

    private var endpointSection: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle("转写接口")
            VStack(alignment: .leading, spacing: Ink.Space.m) {
                VStack(alignment: .leading, spacing: Ink.Space.xs) {
                    Text("接口地址（OpenAI 兼容）")
                        .font(.system(size: Ink.Size.small))
                        .foregroundStyle(Ink.inkSoft)
                    TextField("https://api.groq.com/openai/v1", text: $baseURLInput)
                        .font(Ink.mono(Ink.Size.sub))
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                if !baseURLInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    switch validatedEndpoint {
                    case .success(let resolved):
                        Text("实际请求：\(resolved.absoluteString)")
                            .font(Ink.mono(Ink.Size.small))
                            .foregroundStyle(Ink.inkFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    case .failure(let err):
                        Text(err.localizedDescription)
                            .font(.system(size: Ink.Size.small))
                            .foregroundStyle(Ink.stop)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Kit.rule(inset: 0)
                VStack(alignment: .leading, spacing: Ink.Space.xs) {
                    Text("模型名")
                        .font(.system(size: Ink.Size.small))
                        .foregroundStyle(Ink.inkSoft)
                    TextField("whisper-large-v3-turbo", text: $model)
                        .font(Ink.mono(Ink.Size.sub))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .padding(Ink.Space.l)
            .paperCard()
            Text("公网和域名接口必须使用 https://；只有明确的本机或局域网 IP（如 127.0.0.1、192.168.x.x）允许 http://。")
                .font(.system(size: Ink.Size.small))
                .foregroundStyle(Ink.inkSoft)
                .padding(.horizontal, Ink.Space.l)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Keychain API Key (isolated per origin)

    private var keySection: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle("转写密钥")
            VStack(alignment: .leading, spacing: Ink.Space.m) {
                if let origin = activeOriginKey {
                    Text("绑定来源：\(origin)")
                        .font(Ink.mono(Ink.Size.small))
                        .foregroundStyle(Ink.inkFaint)
                        .lineLimit(1)
                }
                HStack(spacing: Ink.Space.s) {
                    SecureField(savedMasked.isEmpty ? "粘贴当前服务的 API Key" : savedMasked, text: $keyInput)
                        .font(Ink.mono(Ink.Size.sub))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(resolvedEndpoint == nil)
                    if keyInput.isEmpty {
                        Button("粘贴") {
                            if let clip = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !clip.isEmpty {
                                keyInput = clip
                                Haptics.tick(0.4)
                            }
                        }
                        .font(.system(size: Ink.Size.small, weight: .semibold))
                        .foregroundStyle(Ink.accent)
                        .disabled(resolvedEndpoint == nil)
                    } else {
                        Button(L.t("actions.save")) { saveCurrentKey() }
                            .font(.system(size: Ink.Size.sub, weight: .semibold))
                            .foregroundStyle(Ink.accent)
                            .disabled(resolvedEndpoint == nil)
                    }
                }
                if !savedMasked.isEmpty {
                    Kit.rule(inset: 0)
                    HStack {
                        Text("已保存：\(savedMasked)")
                            .font(Ink.mono(Ink.Size.small))
                            .foregroundStyle(Ink.inkSoft)
                        Spacer()
                        Button("清除密钥", role: .destructive) { clearCurrentKey() }
                            .font(.system(size: Ink.Size.small, weight: .medium))
                            .foregroundStyle(Ink.stop)
                    }
                }
                if let keyNotice {
                    Text(keyNotice)
                        .font(.system(size: Ink.Size.small))
                        .foregroundStyle(Ink.ok)
                }
            }
            .padding(Ink.Space.l)
            .paperCard()
            Text("密钥按接口来源隔离存在本机钥匙串里，切换其他服务不会复用旧密钥，也不发给聊天模型或进备份。局域网自建 Whisper 若不需要密钥可留空。")
                .font(.system(size: Ink.Size.small))
                .foregroundStyle(Ink.inkSoft)
                .padding(.horizontal, Ink.Space.l)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Language Hint

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle("语言提示")
            Picker("语言提示", selection: $language) {
                Text("自动识别（适合中英混说）").tag("")
                Text("中文（zh）").tag("zh")
                Text("English（en）").tag("en")
            }
            .pickerStyle(.segmented)
            .padding(Ink.Space.l)
            .paperCard()
        }
    }

    // MARK: Actions

    /// Persists safe base URLs (never credential-bearing URLs) and resets key inputs whenever the origin changes.
    @discardableResult
    private func syncOriginChange(for raw: String, persist: Bool) -> Bool {
        if persist && !VoiceEndpoint.containsEmbeddedCredentials(raw) {
            VoiceTranscription.baseURL = raw
        }
        let nextOrigin = (try? VoiceTranscription.validateEndpoint(raw).get()).flatMap(VoiceEndpoint.originKey(for:))
        guard nextOrigin != activeOriginKey else { return false }
        activeOriginKey = nextOrigin
        originVersion = UUID()
        keyInput = ""
        savedMasked = ""
        keyNotice = nil
        return true
    }

    private func loadSavedKey() async {
        guard let endpoint = resolvedEndpoint else {
            savedMasked = ""
            return
        }
        let expectedOrigin = VoiceEndpoint.originKey(for: endpoint)
        let version = originVersion
        let key = await VoiceTranscription.readKey(for: endpoint)
        guard !Task.isCancelled, activeOriginKey == expectedOrigin, originVersion == version else { return }
        savedMasked = VoiceTranscription.mask(key)
    }

    private func saveCurrentKey() {
        guard let endpoint = resolvedEndpoint else { return }
        let trimmed = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let expectedOrigin = VoiceEndpoint.originKey(for: endpoint)
        let version = originVersion
        keyInput = ""
        Task {
            await VoiceTranscription.saveKey(trimmed, for: endpoint)
            guard activeOriginKey == expectedOrigin, originVersion == version else { return }
            savedMasked = VoiceTranscription.mask(trimmed)
            keyNotice = "已存入本机钥匙串。"
            Haptics.thud()
        }
    }

    private func clearCurrentKey() {
        guard let endpoint = resolvedEndpoint else { return }
        let expectedOrigin = VoiceEndpoint.originKey(for: endpoint)
        let version = originVersion
        keyInput = ""
        Task {
            await VoiceTranscription.saveKey("", for: endpoint)
            guard activeOriginKey == expectedOrigin, originVersion == version else { return }
            savedMasked = ""
            keyNotice = "已清除当前来源的转写密钥。"
            Haptics.lock()
        }
    }
}
