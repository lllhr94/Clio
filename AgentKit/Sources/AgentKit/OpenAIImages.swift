import Foundation

public enum ImageGenerationError: Error, Equatable {
    case invalidEndpoint, invalidResponse, contentRejected, insufficientQuota, invalidKey, rateLimited, timeout, serviceUnavailable
}

/// Distinguishes standard `/images/generations` endpoints (`.openai`, `.openaiResponses`)
/// from the gated experimental `.openaiCodex` subscription image pipeline.
public enum ImageEndpointMode: String, Codable, Equatable, Sendable {
    case standard
    case codexExperimental
}

/// Result of probing an experimental `.openaiCodex` endpoint's image capabilities without polluting chat models.
public struct CodexImageProbeResult: Equatable, Sendable {
    public let supported: Bool
    public let supportedModels: [String]
    public let note: String?

    public init(supported: Bool, supportedModels: [String], note: String? = nil) {
        self.supported = supported
        self.supportedModels = supportedModels
        self.note = note
    }
}

extension OpenAIProvider {
    /// Returns the image bytes from an OpenAI-compatible images endpoint.
    public func generateImage(model: String, prompt: String, size: String) async throws -> Data {
        try await generateImage(model: model, prompt: prompt, size: size, session: nil)
    }

    private static let maxImageBytes = 32_000_000
    private static let maxJSONEnvelopeBytes = 48_000_000

    func generateImage(model: String, prompt: String, size: String, session: URLSession?) async throws -> Data {
        let request = try imageRequest(model: model, prompt: prompt, size: size)
        let lease = session == nil ? HTTP.SessionPool.shared.acquireLease() : nil
        let activeSession = session ?? lease?.session ?? HTTP.session
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await activeSession.bytes(for: request, delegate: HTTP.RedirectGuardDelegate.shared)
        } catch {
            if let lease { HTTP.SessionPool.shared.releaseLease(lease) }
            throw error
        }
        if let lease { HTTP.SessionPool.shared.releaseLease(lease) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if response.expectedContentLength > Int64(Self.maxJSONEnvelopeBytes) {
            throw ImageGenerationError.invalidResponse
        }
        var data = Data()
        for try await byte in bytes {
            if (data.count & 0xFFF) == 0 { try Task.checkCancellation() }
            data.append(byte)
            if data.count > Self.maxJSONEnvelopeBytes {
                throw ImageGenerationError.invalidResponse
            }
        }
        let json = JSONValue.parse(String(decoding: data, as: UTF8.self))
        guard (200..<300).contains(status), json?["error"] == nil || json?["error"] == .null else {
            throw Self.imageFailure(status: status, json: json)
        }
        guard let item = json?["data"]?.array?.first else { throw ImageGenerationError.invalidResponse }
        if let encoded = item["b64_json"]?.string, let decoded = Data(base64Encoded: encoded), !decoded.isEmpty {
            guard decoded.count <= Self.maxImageBytes else { throw ImageGenerationError.invalidResponse }
            return decoded
        }
        guard let address = item["url"]?.string, let url = Self.imageURL(address) else {
            throw ImageGenerationError.invalidResponse
        }

        // The download may be on a CDN. Keep the model key on the generation request, and block local/private SSRF & >32 MB payloads.
        // Re-fetch from pool when session was not injected in case network/proxy rotated while the image generated.
        do {
            let downloadLease = session == nil ? HTTP.SessionPool.shared.acquireLease() : nil
            defer { if let downloadLease { HTTP.SessionPool.shared.releaseLease(downloadLease) } }
            let downloadSession = session ?? downloadLease?.session ?? HTTP.session
            let image = try await Web.publicBytes(from: url, limit: Self.maxImageBytes, timeout: 60, session: downloadSession)
            guard !image.isEmpty else { throw ImageGenerationError.invalidResponse }
            return image
        } catch let failure as ProviderError {
            if failure.status == 408 || failure.status == 504 { throw ImageGenerationError.timeout }
            throw ImageGenerationError.invalidResponse
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw ImageGenerationError.timeout
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw ImageGenerationError.invalidResponse
        }
    }

    func imageRequest(model: String, prompt: String, size: String) throws -> URLRequest {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = Self.imageURL(base), url.query == nil, url.fragment == nil else {
            throw ImageGenerationError.invalidEndpoint
        }
        var request = URLRequest(url: url.appendingPathComponent("images/generations"), timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        HTTP.applyNonSecretHeaders(customHeaders, to: &request)
        request.httpBody = try HTTP.json(["model": model, "prompt": prompt, "size": size, "n": 1])
        return request
    }

    private static func imageURL(_ address: String) -> URL? {
        guard let url = URL(string: address), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }

    private static func imageFailure(status: Int, json: JSONValue?) -> ImageGenerationError {
        let error = json?["error"]
        let fields = [error?["code"]?.string, error?["type"]?.string, error?["message"]?.string,
                      error?.string, json?["code"]?.string, json?["message"]?.string]
        let detail = fields.compactMap { $0 }.joined(separator: " ").lowercased()
        if ["content_policy", "content policy", "content_filter", "content filter", "safety", "moderation", "内容审核"]
            .contains(where: { detail.contains($0) }) { return .contentRejected }
        if status == 402 || ["quota", "billing", "insufficient funds", "insufficient balance", "额度", "余额"]
            .contains(where: { detail.contains($0) }) { return .insufficientQuota }
        if status == 408 || status == 504 || detail.contains("timed out") { return .timeout }
        if status == 401 || status == 403 { return .invalidKey }
        if status == 429 { return .rateLimited }
        if status >= 500 { return .serviceUnavailable }
        return .invalidResponse
    }
}

extension OpenAIResponsesProvider {
    public var imageEndpointMode: ImageEndpointMode {
        isCodex ? .codexExperimental : .standard
    }

    /// Generates an image using the appropriate pipeline:
    /// - `.openaiResponses`: standard `/images/generations` (strictly without unsupported `complexity: low`).
    /// - `.openaiCodex`: experimental gated path (never injects `complexity: low`, degrades cleanly when unpermitted).
    public func generateImage(model: String, prompt: String, size: String) async throws -> Data {
        try await generateImage(model: model, prompt: prompt, size: size, session: nil)
    }

    func generateImage(model: String, prompt: String, size: String, session: URLSession?) async throws -> Data {
        let delegate = OpenAIProvider(baseURL: baseURL, apiKey: apiKey, fixedRoute: fixedRoute, customHeaders: customHeaders)
        return try await delegate.generateImage(model: model, prompt: prompt, size: size, session: session)
    }

    /// Probes experimental `.openaiCodex` image model availability by inspecting the endpoint's `/models` catalog
    /// without injecting invalid fields (`complexity: low`) or mutating chat model filters.
    public func probeCodexImageCapabilities() async -> CodexImageProbeResult {
        await probeCodexImageCapabilities(session: nil)
    }

    func probeCodexImageCapabilities(session: URLSession?) async -> CodexImageProbeResult {
        guard isCodex else {
            return CodexImageProbeResult(supported: true, supportedModels: [], note: nil)
        }
        do {
            let discovered = try await catalog(session: session).ids
            let imageModels = discovered.filter(Self.looksLikeImageModelID)
            if imageModels.isEmpty {
                return CodexImageProbeResult(
                    supported: false,
                    supportedModels: [],
                    note: "当前 Codex 订阅账号未返回可用生图模型，已自动隐藏生图入口。"
                )
            }
            return CodexImageProbeResult(supported: true, supportedModels: imageModels, note: nil)
        } catch let failure as ProviderError where failure.status == 401 || failure.status == 403 {
            return CodexImageProbeResult(
                supported: false,
                supportedModels: [],
                note: "当前 Codex 订阅权限不支持生图探测，已温和降级。"
            )
        } catch {
            return CodexImageProbeResult(
                supported: false,
                supportedModels: [],
                note: "Codex 生图能力暂不可用，不影响聊天使用。"
            )
        }
    }

    static func looksLikeImageModelID(_ id: String) -> Bool {
        let lower = id.lowercased()
        return lower.contains("gpt-image")
            || lower.contains("dall-e")
            || lower.contains("image-generation")
            || lower.hasPrefix("imagen")
    }
}
