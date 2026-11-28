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
            case .system: L.t("voiceSettings.modeSystemTitle")
            case .cloud: L.t("voiceSettings.modeCloudTitle")
            }
        }

        var subtitle: String {
            switch self {
            case .system: L.t("voiceSettings.modeSystemSubtitle")
            case .cloud: L.t("voiceSettings.modeCloudSubtitle")
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
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                UserDefaults.standard.set("", forKey: baseURLKey)
                return
            }
            // Only persist fully parsed, canonical URLs free of credentials, query strings, and fragments.
            guard case .success(let parsed) = VoiceEndpoint.parse(trimmed) else { return }
            UserDefaults.standard.set(parsed.baseURL, forKey: baseURLKey)
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
        NetworkRuntime.shared.configure(config, for: .default)
        let session = URLSession(configuration: config, delegate: SameOriginRedirectGuard(origin: endpoint), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let maxResponseBytes = 1_048_576
        let (bytes, response) = try await session.bytes(for: request)
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
        if http.expectedContentLength > Int64(maxResponseBytes) {
            throw Problem.message("语音转写响应过大，请检查接口地址是否正确。")
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            data.append(byte)
            if data.count > maxResponseBytes {
                throw Problem.message("语音转写响应过大，请检查接口地址是否正确。")
            }
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = json["text"] as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if contentType.contains("text/html") {
            throw Problem.message("语音转写接口返回了网页内容，请检查接口地址是否正确。")
        }
        if let plain = String(data: data, encoding: .utf8) {
            let trimmedPlain = plain.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = trimmedPlain.prefix(256).lowercased()
            if lower.hasPrefix("<!doctype html") || lower.hasPrefix("<html") || lower.contains("<head") || lower.contains("<body") {
                throw Problem.message("语音转写接口返回了网页内容，请检查接口地址是否正确。")
            }
            return trimmedPlain
        }
        throw Problem.message("语音转写返回的内容无法解析。")
    }
}

/// Settings page for choosing between Apple system dictation and a standalone OpenAI-compatible STT endpoint.
struct VoiceSettingsPage: View {
    @AppStorage(VoiceTranscription.modeKey) private var modeRaw = VoiceTranscription.Mode.system.rawValue
    @AppStorage(VoiceTranscription.modelKey) private var model = ""
    @AppStorage(VoiceTranscription.languageKey) private var language = ""

    @State private var savedBaseURL = VoiceTranscription.baseURL
    @State private var baseURLDraft = VoiceTranscription.baseURL
    @State private var endpointNotice: String?
    @State private var activeOriginKey: String? = nil
    @State private var originVersion = UUID()
    @State private var savedMasked = ""
    @State private var keyInput = ""
    @State private var keyNotice: String?

    private var mode: VoiceTranscription.Mode {
        VoiceTranscription.Mode(rawValue: modeRaw) ?? .system
    }

    private var trimmedDraft: String {
        baseURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var draftValidation: Result<VoiceEndpoint.Parsed, VoiceEndpointError> {
        VoiceEndpoint.parse(baseURLDraft)
    }

    private var savedParsed: VoiceEndpoint.Parsed? {
        try? VoiceEndpoint.parse(savedBaseURL).get()
    }

    private var hasUnsavedEndpoint: Bool {
        trimmedDraft != savedBaseURL
    }

    private var canSaveDraft: Bool {
        guard hasUnsavedEndpoint else { return false }
        if trimmedDraft.isEmpty { return true }
        if case .success = draftValidation { return true }
        return false
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
        .navigationTitle(L.t("voiceSettings.title"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            syncSavedOrigin(savedParsed?.originKey)
            await loadSavedKey()
        }
        .onChange(of: baseURLDraft) { _, next in
            if next.trimmingCharacters(in: .whitespacesAndNewlines) != savedBaseURL {
                endpointNotice = nil
            }
        }
    }

    // MARK: Mode

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle(L.t("voiceSettings.modeSection"))
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
            SectionTitle(L.t("voiceSettings.presetSection"))
            HStack(spacing: Ink.Space.s) {
                ForEach(VoiceTranscription.presets) { preset in
                    let picked = !hasUnsavedEndpoint && savedBaseURL == preset.baseURL
                    Button {
                        applyPreset(preset)
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
            SectionTitle(L.t("voiceSettings.endpointSection"))
            VStack(alignment: .leading, spacing: Ink.Space.m) {
                VStack(alignment: .leading, spacing: Ink.Space.xs) {
                    Text(L.t("voiceSettings.endpointLabel"))
                        .font(.system(size: Ink.Size.small))
                        .foregroundStyle(Ink.inkSoft)
                    TextField("https://api.groq.com/openai/v1", text: $baseURLDraft)
                        .font(Ink.mono(Ink.Size.sub))
                        .keyboardType(.URL)
                        .submitLabel(.done)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { saveEndpointDraft() }
                }
                if !trimmedDraft.isEmpty {
                    switch draftValidation {
                    case .success(let parsed):
                        Text(L.format("voiceSettings.resolvedEndpoint", parsed.endpoint.absoluteString))
                            .font(Ink.mono(Ink.Size.small))
                            .foregroundStyle(Ink.inkFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    case .failure(let err):
                        Text(err.localizedDescription)
                            .font(.system(size: Ink.Size.small))
                            .foregroundStyle(Ink.stop)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if hasUnsavedEndpoint {
                    Text(L.t("voiceSettings.clearEndpointHint"))
                        .font(.system(size: Ink.Size.small))
                        .foregroundStyle(Ink.inkSoft)
                }
                if hasUnsavedEndpoint {
                    HStack(spacing: Ink.Space.m) {
                        Button(L.t("voiceSettings.saveEndpoint")) { saveEndpointDraft() }
                            .font(.system(size: Ink.Size.sub, weight: .semibold))
                            .foregroundStyle(canSaveDraft ? Ink.accent : Ink.inkFaint)
                            .disabled(!canSaveDraft)
                        Button(L.t("voiceSettings.revertEndpoint")) {
                            baseURLDraft = savedBaseURL
                            endpointNotice = nil
                        }
                        .font(.system(size: Ink.Size.small))
                        .foregroundStyle(Ink.inkSoft)
                        Spacer()
                    }
                } else if let endpointNotice {
                    Text(endpointNotice)
                        .font(.system(size: Ink.Size.small))
                        .foregroundStyle(Ink.ok)
                }
                Kit.rule(inset: 0)
                VStack(alignment: .leading, spacing: Ink.Space.xs) {
                    Text(L.t("voiceSettings.modelLabel"))
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
            Text(L.t("voiceSettings.endpointFooter"))
                .font(.system(size: Ink.Size.small))
                .foregroundStyle(Ink.inkSoft)
                .padding(.horizontal, Ink.Space.l)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Keychain API Key (isolated per saved origin)

    private var canEditKey: Bool {
        savedParsed != nil && !hasUnsavedEndpoint
    }

    private var keySection: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle(L.t("voiceSettings.keySection"))
            VStack(alignment: .leading, spacing: Ink.Space.m) {
                if hasUnsavedEndpoint {
                    Text(L.t("voiceSettings.unsavedEndpointWarning"))
                        .font(.system(size: Ink.Size.small))
                        .foregroundStyle(Ink.warn)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let origin = activeOriginKey {
                    Text(L.format("voiceSettings.boundOrigin", origin))
                        .font(Ink.mono(Ink.Size.small))
                        .foregroundStyle(Ink.inkFaint)
                        .lineLimit(1)
                } else {
                    Text(L.t("voiceSettings.needEndpointFirst"))
                        .font(.system(size: Ink.Size.small))
                        .foregroundStyle(Ink.inkSoft)
                }
                HStack(spacing: Ink.Space.s) {
                    SecureField(savedMasked.isEmpty ? L.t("voiceSettings.keyPlaceholder") : savedMasked, text: $keyInput)
                        .font(Ink.mono(Ink.Size.sub))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(!canEditKey)
                    if keyInput.isEmpty {
                        Button(L.t("actions.paste")) {
                            if let clip = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !clip.isEmpty {
                                keyInput = clip
                                Haptics.tick(0.4)
                            }
                        }
                        .font(.system(size: Ink.Size.small, weight: .semibold))
                        .foregroundStyle(Ink.accent)
                        .disabled(!canEditKey)
                    } else {
                        Button(L.t("actions.save")) { saveCurrentKey() }
                            .font(.system(size: Ink.Size.sub, weight: .semibold))
                            .foregroundStyle(Ink.accent)
                            .disabled(!canEditKey)
                    }
                }
                if !savedMasked.isEmpty && canEditKey {
                    Kit.rule(inset: 0)
                    HStack {
                        Text(L.format("voiceSettings.keySavedPreview", savedMasked))
                            .font(Ink.mono(Ink.Size.small))
                            .foregroundStyle(Ink.inkSoft)
                        Spacer()
                        Button(L.t("voiceSettings.clearKey"), role: .destructive) { clearCurrentKey() }
                            .font(.system(size: Ink.Size.small, weight: .medium))
                            .foregroundStyle(Ink.stop)
                    }
                }
                if let keyNotice, !hasUnsavedEndpoint {
                    Text(keyNotice)
                        .font(.system(size: Ink.Size.small))
                        .foregroundStyle(Ink.ok)
                }
            }
            .padding(Ink.Space.l)
            .paperCard()
            Text(L.t("voiceSettings.keyFooter"))
                .font(.system(size: Ink.Size.small))
                .foregroundStyle(Ink.inkSoft)
                .padding(.horizontal, Ink.Space.l)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Language Hint

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle(L.t("voiceSettings.languageSection"))
            SlidingCapsuleControl(
                selection: $language,
                items: [
                    (value: "", title: L.t("voiceSettings.languageAuto")),
                    (value: "zh", title: L.t("voiceSettings.languageZh")),
                    (value: "en", title: L.t("voiceSettings.languageEn")),
                ]
            )
            .accessibilityLabel(L.t("voiceSettings.languageSection"))
            .padding(Ink.Space.l)
            .paperCard()
        }
    }

    // MARK: Actions

    private func applyPreset(_ preset: VoiceTranscription.Preset) {
        guard case .success(let parsed) = VoiceEndpoint.parse(preset.baseURL) else { return }
        Haptics.tick(0.4)
        model = preset.model
        commitParsedEndpoint(parsed, notice: L.format("voiceSettings.switchedPresetNotice", preset.name))
    }

    private func saveEndpointDraft() {
        guard hasUnsavedEndpoint else { return }
        if trimmedDraft.isEmpty {
            VoiceTranscription.baseURL = ""
            savedBaseURL = ""
            baseURLDraft = ""
            endpointNotice = L.t("voiceSettings.clearedEndpointNotice")
            syncSavedOrigin(nil)
            Haptics.lock()
            return
        }
        guard case .success(let parsed) = VoiceEndpoint.parse(trimmedDraft) else {
            Haptics.lock()
            return
        }
        commitParsedEndpoint(parsed, notice: L.t("voiceSettings.savedEndpointNotice"))
        Haptics.thud()
    }

    private func commitParsedEndpoint(_ parsed: VoiceEndpoint.Parsed, notice: String) {
        VoiceTranscription.baseURL = parsed.baseURL
        savedBaseURL = parsed.baseURL
        baseURLDraft = parsed.baseURL
        endpointNotice = notice
        if syncSavedOrigin(parsed.originKey) {
            Task { await loadSavedKey() }
        }
    }

    /// Synchronously updates the active confirmed origin and clears transient key inputs on origin switches.
    @discardableResult
    private func syncSavedOrigin(_ nextOrigin: String?) -> Bool {
        guard nextOrigin != activeOriginKey else { return false }
        activeOriginKey = nextOrigin
        originVersion = UUID()
        keyInput = ""
        savedMasked = ""
        keyNotice = nil
        return true
    }

    private func loadSavedKey() async {
        guard let parsed = savedParsed else {
            savedMasked = ""
            return
        }
        let expectedOrigin = parsed.originKey
        let version = originVersion
        let key = await VoiceTranscription.readKey(for: parsed.endpoint)
        guard !Task.isCancelled, activeOriginKey == expectedOrigin, originVersion == version else { return }
        savedMasked = VoiceTranscription.mask(key)
    }

    private func saveCurrentKey() {
        guard canEditKey, let parsed = savedParsed else { return }
        let trimmed = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let expectedOrigin = parsed.originKey
        let version = originVersion
        keyInput = ""
        Task {
            await VoiceTranscription.saveKey(trimmed, for: parsed.endpoint)
            guard activeOriginKey == expectedOrigin, originVersion == version else { return }
            savedMasked = VoiceTranscription.mask(trimmed)
            keyNotice = L.t("voiceSettings.keySavedNotice")
            Haptics.thud()
        }
    }

    private func clearCurrentKey() {
        guard canEditKey, let parsed = savedParsed else { return }
        let expectedOrigin = parsed.originKey
        let version = originVersion
        keyInput = ""
        Task {
            await VoiceTranscription.saveKey("", for: parsed.endpoint)
            guard activeOriginKey == expectedOrigin, originVersion == version else { return }
            savedMasked = ""
            keyNotice = L.t("voiceSettings.keyClearedNotice")
            Haptics.lock()
        }
    }
}
